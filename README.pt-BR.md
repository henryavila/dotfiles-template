# dotfiles-template

Skeleton para dotfiles pessoais de qualquer dev. Clique **"Use this template"** no GitHub para criar seu repo (recomendado: privado).

> **Idiomas:** [English](README.md) · Português (este arquivo)

## Preview

![](./assets/previews/p10k-bundled-hero.png)

Features: prompt p10k · syntax highlight via bat · diff render via delta · preview de arquivo/diretório via fzf-tab · Catppuccin Mocha em toda a stack.

<details>
<summary>Zoom — preview de conteúdo de diretório via fzf-tab</summary>

![](./assets/previews/p10k-bundled-segments.png)

</details>

<details>
<summary>Zoom — preview de conteúdo de arquivo via fzf-tab + git status</summary>

![](./assets/previews/p10k-bundled-fzf-tab.png)

</details>

## Papel desta camada

Um dos três repos de um stack em camadas:

```
┌──────────────────────────────────────────────────────────────┐
│  dev-bootstrap      →  ferramentas + configs universais       │
│                         (bashrc, inputrc, gitconfig global,   │
│                         fragments ~/.bashrc.d/, Syncthing…)   │
├──────────────────────────────────────────────────────────────┤
│  dotfiles-template  →  ESTE REPO — scaffold + install.sh      │
│                         (.example files + lógica de deploy)   │
├──────────────────────────────────────────────────────────────┤
│  <you>/dotfiles     →  seu fork privado: identidade + overrides │
│                         (SSH, gitconfig.local, aliases, tokens) │
└──────────────────────────────────────────────────────────────┘
```

**Regra mental:** baseline que todo dev recebe vai no `dev-bootstrap`. O que varia por pessoa ou é preferência sua vai no fork deste template.

## Setup inicial (fork novo)

1. **"Use this template"** no GitHub → escolha "Private" → nome `dotfiles`.
2. Clone e customize:

   ```bash
   git clone git@github.com:SEU_USER/dotfiles.git ~/dotfiles
   cd ~/dotfiles

   # Renomeie .example → nome plain e edite o que quer adotar:
   cp ssh/config.example ssh/config                       # hostnames, IdentityFile
   cp git/gitconfig.local.example git/gitconfig.local     # nome + email
   cp shell/bashrc.local.example shell/bashrc.local       # (opcional)
   cp shell/aliases.sh.example shell/aliases.sh           # (opcional)
   cp claude/manifest/mcps-user.sh.example claude/manifest/mcps-user.sh  # MCPs user-scope

   bash install.sh
   ```

3. Commits normais: `git add`, `git commit`, `git push`. **Privado obrigatório** se contém hostnames internos, emails, tokens.

## Como funciona

`install.sh` é self-contained (zero dependência do dev-bootstrap). Para cada entrada em `MAPPINGS`, processa arquivos **sem** sufixo `.example`:

- **modo `overwrite`** (default): diff contra o destino, backup timestamped se mudou, copia.
- **modo `once`** (marcado no `MAPPINGS`): deploya só se destino não existe. Para arquivos com placeholders de secrets — depois do 1º install você edita `~/.s3cfg` / `~/.npmrc` direto com valores reais e o script preserva.

```bash
DRY_RUN=1 bash install.sh   # plano sem executar
bash install.sh             # aplicar
```

## O que este template deploya

| src no repo | destino | modo |
|-------------|---------|------|
| `ssh/config` | `~/.ssh/config` (chmod 600) | overwrite |
| `git/gitconfig.local` | `~/.gitconfig.local` (puxado via `include.path` que o `dev-bootstrap/50-git` seta em `~/.gitconfig`) | overwrite |
| `git/gitignore_global` | `~/.config/git/ignore` | overwrite |
| `shell/bashrc.local` | `~/.bashrc.local` (carregado **por último** pelo `~/.bashrc` do bootstrap) | overwrite |
| `shell/zshrc.local` | `~/.zshrc.local` | overwrite |
| `shell/aliases.sh` | `~/.bashrc.d/99-personal-aliases.sh` **e** `~/.zshrc.d/99-personal-aliases.sh` (prefixo `99-` força carregar depois dos fragments do bootstrap) | overwrite |
| `config/htoprc` | `~/.config/htop/htoprc` (atenção: htop reescreve este arquivo ao mudar settings na UI) | overwrite |
| `config/s3cfg` | `~/.s3cfg` (chmod 600) | **once** |
| `npm/npmrc` | `~/.npmrc` (chmod 600) | **once** |
| `claude/manifest/mcps-user.sh` | `~/.claude/manifest/mcps-user.sh` | overwrite |
| `claude/stignore/claude-config.stignore` | `~/.claude/.stignore` (controla Syncthing em `~/.claude/`) | overwrite |
| `claude/stignore/claude-mem.stignore` | `~/.claude-mem/.stignore` | overwrite |
| `shell/zinit-uninstall.list` | _(lido in-place; não é deployado)_ | drift cleanup |

> `shell/zinit-uninstall.list` é consumido durante `bash install.sh` para purgar o cache do zinit de qualquer plugin que você parou de carregar do `shell/zshrc.local`. Ver [Removendo plugins zinit](#removendo-plugins-zinit-drift-cleanup) abaixo.

### O que o template NÃO gerencia (vem do `dev-bootstrap`)

- `~/.inputrc` — bootstrap/30-shell (word-kill, completion niceties)
- `~/.bashrc`, `~/.zshrc` — loaders do bootstrap/30-shell
- Aliases git de shell (`g`, `gs`, `gco`, `whoops`, `gmm`…) — bootstrap/50-git fragment
- `~/.gitconfig` global — bootstrap/50-git via `git config --global`
- `~/.config/starship.toml`, `~/.tmux.conf` — bootstrap/20-terminal-ux, 40-tmux

Se você se pegar re-declarando algo disso, pare. O bootstrap já cobre; seu fork só precisa **identidade + overrides**.

## Claude Sync (desde v2026-04-20)

A pasta `claude/` introduz sync cross-machine da config Claude Code usando **Syncthing P2P** (daemon instalado pelo `dev-bootstrap/80-claude-code`).

Modelo 2-problemas-2-ferramentas:

| Problema | Solução |
|----------|---------|
| **Sync contínuo** entre N máquinas pessoais já configuradas | Syncthing com `.stignore` curado nas pastas `~/.claude/` e `~/.claude-mem/`. Descoberta de skill em qualquer máquina propaga automaticamente. |
| **Reprodutibilidade cold-start** (máquina zero) | `manifest/mcps-user.sh` — script idempotente que reaplica MCPs user-scope (plugins vêm via Syncthing quando pareado). |
| **Convergência inicial** (4 máquinas já divergentes) | Scripts em `claude/scripts/` — `inventory.sh`, `backup.sh`, `merge-claude-mem.py` (preserva memória via `content_hash` dedup). Playbook 6 fases em `claude/README.md`. |

Leia `claude/README.md` pros detalhes completos e `claude/scripts/syncthing-setup.md` pro fluxo de pairing.

## Adicionando um novo arquivo ao seu fork

1. Cria `<area>/<nome>.example` com conteúdo comentado explicando cada campo.
2. Renomeia `.example` → plain e customiza.
3. Adiciona linha no array `MAPPINGS` em `install.sh`.
4. Adiciona linha na tabela do README do seu fork.
5. `DRY_RUN=1 bash install.sh` → `bash install.sh`.
6. Commit com mensagem explicando **por quê**.

## Precedência de carregamento no shell

Quando abre um shell interativo:

1. `~/.bashrc` (bootstrap/30-shell) — loader minimal
2. `~/.bashrc.d/NN-<topic>.sh` em ordem alfabética — fragments do bootstrap:
   - `10-languages.sh` (fnm, composer PATH)
   - `20-terminal-ux.sh` (starship, fzf, zoxide, ls/cat básicos)
   - `30-shell.sh` (dircolors, bash-completion)
   - `50-git.sh` (aliases git)
3. `~/.bashrc.d/99-personal-aliases.sh` — **seu fork** (prefixo 99- garante ser o último em `.bashrc.d/`)
4. `~/.bashrc.local` — **seu fork**, carregado por último pelo loader

**Consequência**: seu fork sempre vence se quiser sobrescrever algo do bootstrap. Sem fork do bootstrap, sem edit manual em `~/.bashrc`.

## Removendo plugins zinit (drift cleanup)

Remover `zinit light owner/repo` do `shell/zshrc.local` para de carregar o plugin em **novas** sessões zsh, mas **não** limpa o cache do zinit em `~/.local/share/zinit/plugins/<owner>---<repo>/`. Em máquinas que você já provisionou, o cache fica para sempre.

Para resolver isso de forma limpa:

1. Ative o manifest uma vez: `cp shell/zinit-uninstall.list.example shell/zinit-uninstall.list`.
2. Quando remover uma linha `zinit light owner/repo`, adicione `owner/repo` em `shell/zinit-uninstall.list` **no mesmo commit**.
3. Rode `bash install.sh`. O script faz `rm -rf` no diretório de cache de cada entrada (idempotente — silencioso quando já está ausente).

Formato e racional documentados dentro do arquivo. Companion ao `lib/uninstall.sh` do `dev-bootstrap` (que cobre o lado brew/apt/clone da mesma aposentadoria, quando o plugin foi instalado por um topic).

## Evolução do template ↔ seu fork

GitHub Templates criam repos **sem história compartilhada** com o original, então `git merge upstream/main` não funciona. Modelo alternativo — **release-driven manual** (igual `create-react-app`, `vite`, `create-t3-app`):

1. **No template** (quem mantém): cada mudança estrutural em `*.example`, `install.sh` ou `MAPPINGS` recebe:
   - commit com **migration note** no corpo (passos concretos pra aplicar no fork)
   - tag datada: `git tag -a v2026-MM-DD -m "..."`
   - release no GitHub: `gh release create v2026-MM-DD --notes-from-tag`

2. **No seu fork** (periodicamente, ou ao receber notificação de release):
   ```bash
   git clone --depth 1 git@github.com:henryavila/dotfiles-template.git /tmp/tpl
   cd /tmp/tpl && git checkout v2026-MM-DD
   diff -r /tmp/tpl/ ~/dotfiles/ | less
   ```
   Aplica seletivamente o que interessa. Nada automático.

### Releases até agora

| Tag | Destaque |
|-----|---------|
| `v2026-04-19` | `.example` files enriquecidos (aliases.sh, bashrc.local, gitconfig.local, htoprc, s3cfg); remove mapping `shell/inputrc` (bootstrap cobre). |
| `v2026-04-20` | Nova pasta `claude/` com manifest + stignore + scripts de sync/merge. `install.sh` ganha 3 MAPPINGS. |
| `v2026-04-30` | Novo `shell/zinit-uninstall.list.example` + `install.sh` consome para purgar cache de plugins zinit aposentados. Mecanismo genérico — sem opinião sobre quais plugins você usa. Companion do novo `lib/uninstall.sh` do `dev-bootstrap` (cobre lado brew/apt/clone). |

## Docs

`docs/` — aprendizados universalmente úteis:

- [`ssh-tailscale-mtu.md`](docs/ssh-tailscale-mtu.md) — SSH via Tailscale travando em KEX pós-quântico (fix: MTU do `tailscale0` pra 1200).

Aprendizados específicos de infra (nomes de máquinas reais, padrões de migração contextuais) ficam no fork privado, não aqui.

## Veja também

- [`dev-bootstrap`](https://github.com/henryavila/dev-bootstrap) — instala o stack de dev + aplica este template.
- Seu próprio fork — referencie pelo nome que você escolheu (convenção: `<user>/dotfiles` privado).
