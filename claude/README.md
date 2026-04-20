# Claude Sync — cross-machine configuration

This folder holds the content that keeps N personal machines on the same Claude Code stack: plugins, skills, MCPs, rules, memories. The model is **hybrid by design**: two tools for two different problems.

## 2-problem, 2-tool model

| Problem | Tool | Frequency |
|---------|------|-----------|
| **Continuous sync** across already-configured machines | Syncthing (P2P, no cloud) with a curated `.stignore` | Daily, zero effort after setup |
| **Cold-start reproducibility** on a fresh machine | Declarative manifest (`mcps-user.sh`) + `dev-bootstrap` | Rare: new machine, reinstall |

The two meet inside `dev-bootstrap` (topic `80-claude-code`): it installs the Claude CLI + Syncthing daemon. The rest is this personal-dotfiles content.

## Layout

```
claude/
├── README.md                         ← this file
├── manifest/
│   ├── mcps-user.sh.example          ← scaffold; copy to mcps-user.sh and edit
│   └── oauth-mcps.md.example         ← docs for the manual OAuth re-auth flow
├── stignore/
│   ├── claude-config.stignore.example  ← deploy → ~/.claude/.stignore
│   └── claude-mem.stignore.example     ← deploy → ~/.claude-mem/.stignore
└── scripts/
    ├── inventory.sh                  ← snapshot of the Claude state on a machine
    ├── backup.sh                     ← pre-merge tarball (Phase 0)
    ├── merge-claude-mem.py           ← merge N DBs into 1 via content_hash dedup
    └── syncthing-setup.md            ← pairing + folders step-by-step
```

## What each piece solves

### `manifest/mcps-user.sh`

MCPs you registered via `claude mcp add -s user` live in `~/.claude.json`, which **doesn't get synced** (it's mostly telemetry). This script reapplies the registrations declaratively. `claude mcp add` is idempotent.

MCPs installed via plugin propagate automatically with the plugins (via Syncthing). They don't go here.

### `manifest/oauth-mcps.md`

HTTP MCPs with OAuth (Gmail, Drive, Calendar, Notion, Hugging Face) require manual re-auth per machine. Not automatable by OAuth design. This file documents which ones and how.

### `stignore/*.stignore`

Controls what Syncthing replicates or ignores in the two folders (`~/.claude/` and `~/.claude-mem/`). Model: **allowlist via exclusion** — list what NOT to sync (state, cache, secrets). Everything else syncs.

### `scripts/inventory.sh`

First step of initial setup: each machine produces a report of its Claude state. You consolidate the N and decide the strategy.

### `scripts/backup.sh`

Rollback insurance. **Run on every machine before** any destructive change. Excludes bulky state (`projects/`, `cache/`) but preserves everything else.

### `scripts/merge-claude-mem.py`

The trickiest one. Merges N claude-mem SQLite DBs into 1, preserving every observation via `content_hash` dedup. Zero loss. Read the script's docstring for details.

### `scripts/syncthing-setup.md`

Pairing + creation of the two folders, with a "Send Only → Send & Receive" flip to avoid conflicts on the initial sync.

## Initial setup — 6-phase flow

**Converging 4 already-in-use machines** (each with potentially divergent content) is a harder problem than continuous operation. Follow the playbook:

1. **Phase 0 — Backup:** `bash scripts/backup.sh` on every machine.
2. **Phase 1 — Inventory:** `bash scripts/inventory.sh > ~/claude-inventory-$(hostname).txt` on each, then scp to M1.
3. **Phase 2 — Analysis:** cross-diffs to decide whether one machine is a superset (Golden Master) or if each has unique items (Controlled Union).
4. **Phase 3 — Consolidation on M1:** rsync with `--ignore-existing` for the union; merge claude-mem via `merge-claude-mem.py`; regenerate chroma (delete + re-embed).
5. **Phase 4 — Seed:** Syncthing Send Only on M1, Receive Only on M2/M3/M4. Wait for "Up to Date".
6. **Phase 5 — Validation:** consistent hashes across all N.
7. **Phase 6 — Go Live:** flip to Send & Receive on all.

Total time: 4–6 h (one-off). After that, zero ongoing effort.

## Daily operation

**Zero.** A discovery on any machine propagates to the others:
- Install a skill via `claude plugin install` → files under `~/.claude/plugins/marketplaces/` → Syncthing replicates → other machines pick it up on the next session.
- Install a skill via `npx @author/plugin install` → same.
- New observation in a Claude session → writes to `~/.claude-mem/claude-mem.db` → Syncthing replicates.

**The only residual discipline:** when registering a new user-scope MCP (`claude mcp add -s user`), add the line to `manifest/mcps-user.sh` + commit in your dotfiles. That's because `~/.claude.json` doesn't sync. User-scope MCPs are added rarely, so the overhead is light.

## OAuth re-auth on a new machine

After Syncthing converges, the 5 OAuth MCPs show up as "Needs authentication" in `claude mcp list`. Open Claude Code, use a tool that needs each MCP, follow the OAuth flow in the browser. Once per machine. Documented in `manifest/oauth-mcps.md`.

## Manual release strategy (changes to this bundle)

Following the pattern of the other repos: structural changes under `claude/` ship with a detailed commit message + dated tag. See the root README for the release discipline.
