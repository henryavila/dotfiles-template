# docs

Aprendizados **universalmente úteis** (qualquer fork se beneficia). Contextualmente específicos (paths, nomes de máquinas, tokens) vão no seu fork privado.

## Índice

| Doc | Tópico | Quando vai salvar tempo |
|-----|--------|-------------------------|
| [`ssh-tailscale-mtu.md`](ssh-tailscale-mtu.md) | SSH trava em KEX via Tailscale | Quando `ssh <host>.ts.net` trava >30s mas `tailscale ping` responde em ms. Fix: reduzir MTU do `tailscale0` pra 1200. O topic `70-remote-access` do dev-bootstrap automatiza esse fix no Linux desde `v2026-04-21`. |

## Quando adicionar um doc aqui (critérios)

- Não é trivialmente Googleable — combina múltiplas tecnologias ou requer diagnóstico por sintoma
- Tem sintoma reproduzível (outros devs vão encontrar via `grep`)
- **Universal** — não menciona hostname/path/token específicos de uma pessoa

Se for específico do seu setup, cria em `~/dotfiles/docs/` no fork (privado), não aqui.
