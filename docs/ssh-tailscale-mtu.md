# SSH over Tailscale hangs in Key Exchange

**Context:** 2026-04-19, WSL → Mac migration via Tailscale MagicDNS.

## Symptom

`ssh <host>.ts.net` hangs forever (>30 s, until you Ctrl+C) even though Tailscale reports a healthy connection:

```bash
$ tailscale ping code-server
pong from code-server (100.71.187.99) via 192.168.68.63:41641 in 1ms

$ time ssh mac 'echo ok'
^C
real    0m36.815s
```

## Diagnosis

`ssh -vvv` shows the TCP connection established, banner exchanged, KEXINIT sent, but it stalls waiting on the KEX ECDH reply:

```
debug1: kex: algorithm: sntrup761x25519-sha512@openssh.com
debug1: expecting SSH2_MSG_KEX_ECDH_REPLY
Connection to 100.71.187.99 port 22 timed out
```

## Root cause

**Tailscale (WireGuard) uses MTU 1280** — well below the 1500 of standard Ethernet.

**OpenSSH 9.6+ negotiates post-quantum key exchange** (`sntrup761x25519-sha512`) by default, producing ~3–4 KB KEX messages. Those messages split into multiple TCP segments. When Path MTU Discovery doesn't work (ICMP blocked, or a weird route), the fragments are silently dropped and the client waits forever for a reply that never comes.

ICMP (ping) works because the packets are <100 bytes. Classic KEX (`curve25519-sha256` alone) would also work because its messages are <500 bytes.

**Variant:** Windows OpenSSH (pre-9.6) usually has PQ KEX disabled. So `ssh` from PowerShell can work over Tailscale while WSL hangs — which throws off the initial diagnosis.

## Fixes

### A. Use the LAN directly when possible

If you're on the same physical network as the destination, skip Tailscale and use the LAN IP:

```
Host mac
    HostName 192.168.68.63
    ...
```

Zero issue. Tailscale is reserved for remote access.

### B. Client-side workaround (partial)

Force classic KEX:

```
Host mac-ts
    KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
```

Not always enough — depending on host keys and certs, other packets might still exceed the MTU.

### C. Lower the tunnel MTU (robust fix, needs sudo)

```bash
sudo ip link set tailscale0 mtu 1200
```

Does not persist across reboot. To make it permanent, add a systemd unit or use `tailscale up --mtu=1200` if your version supports it.

### D. On the server (if you control sshd)

Disable PQ algorithms in the target's `sshd_config`:

```
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
```

Restart sshd. Full fix for every client.

## Quick detection

```bash
# If this is <5 s but `ssh <tailscale-host>` hangs, it's MTU/PQ KEX:
tailscale ping <host>

# If LAN IP works instantly but Tailscale doesn't, that confirms it:
ssh -o ConnectTimeout=5 user@<lan-ip> 'echo ok'
ssh -o ConnectTimeout=5 user@<tailscale-host> 'echo ok'
```
