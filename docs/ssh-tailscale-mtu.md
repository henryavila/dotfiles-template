# SSH via Tailscale trava em Key Exchange

**Contexto:** 2026-04-19, migração WSL → Mac via Tailscale MagicDNS.

## Sintoma

`ssh <host>.ts.net` fica travado indefinidamente (>30s, até matar com Ctrl+C) mesmo com Tailscale mostrando conexão saudável:

```bash
$ tailscale ping code-server
pong from code-server (100.71.187.99) via 192.168.68.63:41641 in 1ms

$ time ssh mac 'echo ok'
^C
real    0m36.815s
```

## Diagnóstico

`ssh -vvv` mostra que a conexão TCP é estabelecida, o banner é trocado, KEXINIT é enviado, mas trava esperando a resposta do KEX ECDH:

```
debug1: kex: algorithm: sntrup761x25519-sha512@openssh.com
debug1: expecting SSH2_MSG_KEX_ECDH_REPLY
Connection to 100.71.187.99 port 22 timed out
```

## Causa raiz

**Tailscale (WireGuard) usa MTU 1280**, bem menor que os 1500 do Ethernet padrão.

**OpenSSH 9.6+ negocia key exchange pós-quântico** (`sntrup761x25519-sha512`) por default, que produz mensagens KEX de ~3–4 KB. Essas mensagens viram múltiplos segmentos TCP. Se path MTU discovery não funciona (ICMP blocked, ou rota esquisita), os fragmentos somem e o cliente espera eternamente um reply que não chega.

ICMP (ping) funciona porque pacotes são <100 bytes. KEX clássico (`curve25519-sha256` puro) também funcionaria porque mensagens são <500 bytes.

**Variação**: OpenSSH do Windows (versões pre-9.6) geralmente não tem PQ KEX habilitado. Por isso `ssh` do PowerShell pode funcionar via Tailscale enquanto o WSL trava — engana o diagnóstico inicial.

## Soluções

### A. Usar LAN direto quando possível

Se estiver na mesma rede física que o destino, ignore Tailscale e use o IP LAN:

```
Host mac
    HostName 192.168.68.63
    ...
```

Zero problema. Tailscale fica reservado para acesso remoto.

### B. Workaround no client config (parcial)

Forçar KEX clássico:

```
Host mac-ts
    KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
```

Nem sempre suficiente — dependendo de chave do host e certs, outros pacotes podem ultrapassar o MTU.

### C. Reduzir MTU do túnel (fix robusto, requer sudo)

```bash
sudo ip link set tailscale0 mtu 1200
```

Não persiste reboot. Para tornar permanente, adicionar em systemd unit ou `tailscale up --mtu=1200` se a versão suportar.

### D. No servidor (se controla o sshd)

Desabilitar algoritmos PQ no `sshd_config` do destino:

```
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
```

Reinicie o sshd. Fix completo para todos os clientes.

## Detecção rápida

```bash
# Se este for <5s mas `ssh <host-tailscale>` travar, é MTU/KEX PQ:
tailscale ping <host>

# Se via IP LAN funciona instantaneamente mas Tailscale não, confirma:
ssh -o ConnectTimeout=5 user@<lan-ip> 'echo ok'
ssh -o ConnectTimeout=5 user@<tailscale-host> 'echo ok'
```
