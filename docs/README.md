# docs

**Universally useful** learnings (any fork benefits). Contextually specific things (paths, machine names, tokens) belong in your private fork.

## Index

| Doc | Topic | When it saves time |
|-----|-------|--------------------|
| [`ssh-tailscale-mtu.md`](ssh-tailscale-mtu.md) | SSH hangs in KEX over Tailscale | When `ssh <host>.ts.net` stalls >30 s but `tailscale ping` replies in ms. Fix: drop `tailscale0` MTU to 1200. The `70-remote-access` topic in dev-bootstrap automates the fix on Linux since `v2026-04-21`. |

## When to add a doc here (criteria)

- Not trivially Googleable — combines multiple technologies or requires symptom-driven diagnosis.
- Has a reproducible symptom (other devs will find it via `grep`).
- **Universal** — doesn't mention a specific person's hostname, path, or token.

If it's specific to your setup, add it under `~/dotfiles/docs/` in your (private) fork, not here.
