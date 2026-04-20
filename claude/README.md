# Claude Sync — configuração cross-machine

Esta pasta contém o conteúdo pra manter N máquinas pessoais com o mesmo stack Claude Code: plugins, skills, MCPs, rules, memórias. O modelo é **híbrido por design**: duas ferramentas para dois problemas diferentes.

## Modelo de 2 problemas, 2 ferramentas

| Problema | Ferramenta | Frequência |
|----------|-----------|------------|
| **Sync contínuo** entre máquinas já configuradas | Syncthing (P2P, sem cloud) com `.stignore` curado | Diário, zero esforço após setup |
| **Reprodutibilidade cold-start** numa máquina zero | Manifest declarativo (`mcps-user.sh`) + `dev-bootstrap` | Raro: máquina nova, reinstall |

O encontro das duas acontece no `dev-bootstrap` (topic `80-claude-code`): instala Claude CLI + Syncthing daemon. O resto é este conteúdo do dotfiles pessoal.

## Estrutura

```
claude/
├── README.md                         ← este arquivo
├── manifest/
│   ├── mcps-user.sh.example          ← scaffold; copie para mcps-user.sh e edite
│   └── oauth-mcps.md.example         ← documentação do re-auth OAuth manual
├── stignore/
│   ├── claude-config.stignore.example  ← deploy → ~/.claude/.stignore
│   └── claude-mem.stignore.example     ← deploy → ~/.claude-mem/.stignore
└── scripts/
    ├── inventory.sh                  ← gera snapshot do estado Claude numa máquina
    ├── backup.sh                     ← tarball pré-merge (Fase 0)
    ├── merge-claude-mem.py           ← merge N DBs em 1 via content_hash dedup
    └── syncthing-setup.md            ← pairing + folders step-by-step
```

## O que cada pedaço resolve

### `manifest/mcps-user.sh`

MCPs que você registrou via `claude mcp add -s user` ficam em `~/.claude.json`, que **não é sincronizado** (é majoritariamente telemetry). Este script re-aplica as registrations declarativamente. `claude mcp add` é idempotente.

MCPs instalados via plugin propagam automaticamente junto com os plugins (via Syncthing). Não entram aqui.

### `manifest/oauth-mcps.md`

MCPs HTTP com OAuth (Gmail, Drive, Calendar, Notion, Hugging Face) precisam re-auth manual por máquina. Não automatizável por design do OAuth. Este arquivo documenta quais e como.

### `stignore/*.stignore`

Controlam o que Syncthing replica ou ignora nas 2 pastas (`~/.claude/` e `~/.claude-mem/`). Modelo: **allowlist por exclusão** — listar o que NÃO sincronizar (state, cache, secrets). O que sobra, sincroniza.

### `scripts/inventory.sh`

Primeiro passo do setup inicial: cada máquina gera relatório do seu estado Claude. Você consolida os 4 e decide estratégia.

### `scripts/backup.sh`

Rollback insurance. **Rodar em todas as máquinas antes** de qualquer mudança destrutiva. Exclui state volumoso (`projects/`, `cache/`) mas preserva tudo o mais.

### `scripts/merge-claude-mem.py`

O mais delicado. Junta N DBs SQLite do claude-mem em 1, preservando todas as observations via `content_hash` dedup. Zero perda. Leia o docstring do script pra detalhes.

### `scripts/syncthing-setup.md`

Pairing + criação das 2 folders, com flip "Send Only → Send & Receive" pra evitar conflicts no primeiro sync.

## Setup inicial — fluxo das 6 fases

**Convergir 4 máquinas já em uso** (cada uma com conteúdo potencialmente divergente) é um problema maior do que operação contínua. Siga o playbook:

1. **Fase 0 — Backup**: `bash scripts/backup.sh` em cada máquina.
2. **Fase 1 — Inventário**: `bash scripts/inventory.sh > ~/claude-inventory-$(hostname).txt` em cada, depois scp pra M1.
3. **Fase 2 — Análise**: diffs cruzados pra decidir se 1 máquina é superset (Golden Master) ou se cada tem itens únicos (União Controlada).
4. **Fase 3 — Consolidação em M1**: rsync com `--ignore-existing` pra união; merge do claude-mem via `merge-claude-mem.py`; regenerar chroma (deletar + re-embed).
5. **Fase 4 — Seed**: Syncthing Send Only em M1, Receive Only em M2/M3/M4. Aguardar "Up to Date".
6. **Fase 5 — Validação**: hashes consistentes entre as 4.
7. **Fase 6 — Go Live**: flip pra Send & Receive em todas.

Tempo total: 4–6h (única vez). Após isso, zero esforço perpétuo.

## Operação diária

**Zero.** Descoberta em qualquer máquina propaga pras outras:
- Instalou skill via `claude plugin install` → arquivos em `~/.claude/plugins/marketplaces/` → Syncthing replica → outras máquinas reconhecem na próxima session.
- Instalou skill via `npx @autor/plugin install` → idem.
- Nova observação em uma sessão Claude → grava em `~/.claude-mem/claude-mem.db` → Syncthing replica.

**Única disciplina residual**: ao registrar MCP user-scope novo (`claude mcp add -s user`), adicionar a linha no `manifest/mcps-user.sh` + commit do dotfiles. Isso porque `~/.claude.json` não sincroniza. MCPs user-scope são adicionados com baixa frequência, logo disciplina é leve.

## Re-auth OAuth em máquina nova

Após Syncthing convergir, 5 MCPs OAuth ficam marcados "Needs authentication" no `claude mcp list`. Abra Claude Code, use uma ferramenta que use cada MCP, siga flow OAuth via browser. Uma vez por máquina. Documentado em `manifest/oauth-mcps.md`.

## Estratégia release manual (mudanças neste conjunto)

Seguindo o padrão dos outros repos: mudanças estruturais em `claude/` vão com commit message detalhado + tag datada. Ver README raiz do dotfiles para discipline de release.
