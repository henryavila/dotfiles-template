# dotfiles-template

Skeleton for personal dotfiles of any dev. Click **"Use this template"** on GitHub to create your own repo (recommended: private).

> **Languages:** English (this file) · [Português](README.pt-BR.md)

## Role of this layer

One of three repos in a layered stack:

```
┌──────────────────────────────────────────────────────────────┐
│  dev-bootstrap      →  tools + universal configs             │
│                         (bashrc, inputrc, global gitconfig,  │
│                         ~/.bashrc.d/ fragments, Syncthing…)  │
├──────────────────────────────────────────────────────────────┤
│  dotfiles-template  →  THIS REPO — scaffold + install.sh     │
│                         (.example files + deploy logic)      │
├──────────────────────────────────────────────────────────────┤
│  <you>/dotfiles     →  your private fork: identity + overrides │
│                         (SSH, gitconfig.local, aliases, tokens) │
└──────────────────────────────────────────────────────────────┘
```

**Mental rule:** baseline that every dev receives goes in `dev-bootstrap`. Whatever varies per person or is your own preference goes in a fork of this template.

## Initial setup (fresh fork)

1. Click **"Use this template"** on GitHub → pick "Private" → name it `dotfiles`.
2. Clone and customize:

   ```bash
   git clone git@github.com:YOUR_USER/dotfiles.git ~/dotfiles
   cd ~/dotfiles

   # Rename .example → plain and edit whatever you want to adopt:
   cp ssh/config.example ssh/config                       # hostnames, IdentityFile
   cp git/gitconfig.local.example git/gitconfig.local     # name + email
   cp shell/bashrc.local.example shell/bashrc.local       # (optional)
   cp shell/aliases.sh.example shell/aliases.sh           # (optional)
   cp claude/manifest/mcps-user.sh.example claude/manifest/mcps-user.sh  # user-scope MCPs

   bash install.sh
   ```

3. Normal commits: `git add`, `git commit`, `git push`. **Private is mandatory** if the repo contains internal hostnames, emails, or tokens.

## How it works

`install.sh` is self-contained (zero dependency on dev-bootstrap). For each entry in `MAPPINGS`, it processes files **without** the `.example` suffix:

- **`overwrite` mode** (default): diffs against the destination, keeps a timestamped backup when content changed, then copies.
- **`once` mode** (marked in `MAPPINGS`): deploys only if the destination doesn't exist yet. Meant for files with secret placeholders — after the first install you edit `~/.s3cfg` / `~/.npmrc` directly with real values, and the script preserves them.

```bash
DRY_RUN=1 bash install.sh   # preview without executing
bash install.sh             # apply
```

## What this template deploys

| repo src | destination | mode |
|----------|-------------|------|
| `ssh/config` | `~/.ssh/config` (chmod 600) | overwrite |
| `git/gitconfig.local` | `~/.gitconfig.local` (pulled in via `include.path` set by `dev-bootstrap/50-git` in `~/.gitconfig`) | overwrite |
| `git/gitignore_global` | `~/.config/git/ignore` | overwrite |
| `shell/bashrc.local` | `~/.bashrc.local` (loaded **last** by the bootstrap's `~/.bashrc`) | overwrite |
| `shell/zshrc.local` | `~/.zshrc.local` | overwrite |
| `shell/aliases.sh` | `~/.bashrc.d/99-personal-aliases.sh` **and** `~/.zshrc.d/99-personal-aliases.sh` (the `99-` prefix forces loading after the bootstrap fragments) | overwrite |
| `config/htoprc` | `~/.config/htop/htoprc` (heads-up: htop rewrites this file when you change settings in its UI) | overwrite |
| `config/s3cfg` | `~/.s3cfg` (chmod 600) | **once** |
| `npm/npmrc` | `~/.npmrc` (chmod 600) | **once** |
| `claude/manifest/mcps-user.sh` | `~/.claude/manifest/mcps-user.sh` | overwrite |
| `claude/stignore/claude-config.stignore` | `~/.claude/.stignore` (controls Syncthing under `~/.claude/`) | overwrite |
| `claude/stignore/claude-mem.stignore` | `~/.claude-mem/.stignore` | overwrite |

### What this template does NOT manage (comes from `dev-bootstrap`)

- `~/.inputrc` — bootstrap/30-shell (word-kill, completion niceties)
- `~/.bashrc`, `~/.zshrc` — bootstrap/30-shell loaders
- Shell-level git aliases (`g`, `gs`, `gco`, `whoops`, `gmm`…) — bootstrap/50-git fragment
- Global `~/.gitconfig` — bootstrap/50-git via `git config --global`
- `~/.config/starship.toml`, `~/.tmux.conf` — bootstrap/20-terminal-ux, 40-tmux

If you catch yourself re-declaring any of these, stop. The bootstrap already covers them; your fork should only hold **identity + overrides**.

## Claude Sync (since v2026-04-20)

The `claude/` folder introduces cross-machine sync of Claude Code config using **Syncthing P2P** (the daemon is installed by `dev-bootstrap/80-claude-code`).

2-problem-2-tool model:

| Problem | Solution |
|---------|----------|
| **Continuous sync** across N already-configured personal machines | Syncthing with a curated `.stignore` inside `~/.claude/` and `~/.claude-mem/`. Skill discovery on any machine propagates automatically. |
| **Cold-start reproducibility** (fresh machine) | `manifest/mcps-user.sh` — idempotent script that reapplies user-scope MCPs (plugins come via Syncthing once paired). |
| **Initial convergence** (4 already-diverged machines) | Scripts in `claude/scripts/` — `inventory.sh`, `backup.sh`, `merge-claude-mem.py` (preserves memory via `content_hash` dedup). Six-phase playbook in `claude/README.md`. |

Read `claude/README.md` for full details and `claude/scripts/syncthing-setup.md` for the pairing flow.

## Adding a new file to your fork

1. Create `<area>/<name>.example` with commented content explaining each field.
2. Copy `.example` → plain and customize.
3. Add a line to the `MAPPINGS` array in `install.sh`.
4. Add a row to the table in your fork's README.
5. `DRY_RUN=1 bash install.sh` → `bash install.sh`.
6. Commit with a message that explains **why**.

## Shell load order

When opening an interactive shell:

1. `~/.bashrc` (bootstrap/30-shell) — minimal loader.
2. `~/.bashrc.d/NN-<topic>.sh` in alphabetical order — bootstrap fragments:
   - `10-languages.sh` (fnm, composer PATH)
   - `20-terminal-ux.sh` (starship, fzf, zoxide, basic ls/cat aliases)
   - `30-shell.sh` (dircolors, bash-completion)
   - `50-git.sh` (git aliases)
3. `~/.bashrc.d/99-personal-aliases.sh` — **your fork** (the `99-` prefix guarantees it's the last file in `.bashrc.d/`).
4. `~/.bashrc.local` — **your fork**, loaded last of all by the loader.

**Consequence:** your fork always wins if you want to override something from the bootstrap. No forking the bootstrap, no manual edits in `~/.bashrc`.

## Template ↔ your fork evolution

GitHub Templates create repos **without shared history** with the original, so `git merge upstream/main` doesn't work. Alternative model — **release-driven manual** (same as `create-react-app`, `vite`, `create-t3-app`):

1. **In the template** (maintainer side): every structural change to `*.example`, `install.sh`, or `MAPPINGS` gets:
   - a commit with a **migration note** in the body (concrete steps to apply in the fork).
   - a dated tag: `git tag -a v2026-MM-DD -m "..."`.
   - a GitHub release: `gh release create v2026-MM-DD --notes-from-tag`.

2. **In your fork** (periodically, or on release notification):
   ```bash
   git clone --depth 1 git@github.com:henryavila/dotfiles-template.git /tmp/tpl
   cd /tmp/tpl && git checkout v2026-MM-DD
   diff -r /tmp/tpl/ ~/dotfiles/ | less
   ```
   Apply selectively whatever you care about. Nothing is automatic.

### Releases so far

| Tag | Highlights |
|-----|------------|
| `v2026-04-19` | Enriched `.example` files (aliases.sh, bashrc.local, gitconfig.local, htoprc, s3cfg); dropped the `shell/inputrc` mapping (bootstrap covers it). |
| `v2026-04-20` | New `claude/` folder with manifest + stignore + sync/merge scripts. `install.sh` picked up 3 new MAPPINGS. |

## Docs

`docs/` — universally useful learnings:

- [`ssh-tailscale-mtu.md`](docs/ssh-tailscale-mtu.md) — SSH over Tailscale hanging in post-quantum KEX (fix: `tailscale0` MTU set to 1200).

Infra-specific learnings (real machine names, contextual migration patterns) live in the private fork, not here.

## See also

- [`dev-bootstrap`](https://github.com/henryavila/dev-bootstrap) — installs the dev stack + applies this template.
- Your own fork — reference it by the name you chose (convention: `<user>/dotfiles` private).
