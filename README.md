# dotfiles-template

Skeleton para dotfiles pessoais de qualquer dev. Clique **"Use this template"** no GitHub para criar seu próprio repo (recomendado: privado).

## Como funciona

Cada arquivo em `ssh/`, `git/`, `shell/` com sufixo `.example` é um placeholder. Para adotar uma config:

```bash
cp ssh/config.example ssh/config
$EDITOR ssh/config                # customize
bash install.sh                   # deploy no home
```

`install.sh` é self-contained: para cada arquivo não-`.example`, calcula o destino, faz diff, cria backup timestamped se mudou, e copia.

| src no repo | destino |
|-------------|---------|
| `ssh/config` | `~/.ssh/config` (chmod 600) |
| `git/gitconfig.local` | `~/.gitconfig.local` |
| `shell/bashrc.local` | `~/.bashrc.local` |
| `shell/zshrc.local` | `~/.zshrc.local` |

O `~/.bashrc.local` e `~/.zshrc.local` são carregados **no fim** do `~/.bashrc` / `~/.zshrc` gerados pelo [dev-bootstrap](https://github.com/henryavila/dev-bootstrap) — use-os para overrides pessoais (prompt, aliases, identidade de shell).

## Integração com dev-bootstrap

```bash
# Num ambiente recém-bootstrapped:
DOTFILES_REPO=git@github.com:SEU_USER/dotfiles.git bash ~/dev-bootstrap/bootstrap.sh
```

O topic `95-dotfiles-personal` clona seu repo em `~/dotfiles` e roda `install.sh`.

## Adicionando um novo arquivo

1. Criar `<area>/<nome>.example` com conteúdo comentado explicando cada campo.
2. Adicionar entrada em `install.sh` — na associação `MAP`.
3. Adicionar linha na tabela do README acima.

## Docs

- `docs/` — aprendizados gerais de config (SSH gotchas, migration patterns, etc.).

## Setup inicial (um fork novo)

```bash
git clone git@github.com:SEU_USER/dotfiles.git ~/dotfiles
cd ~/dotfiles
cp ssh/config.example ssh/config              # e edite
cp git/gitconfig.local.example git/gitconfig.local
cp shell/bashrc.local.example shell/bashrc.local
bash install.sh
```

Depois, commits normais: `git add`, `git commit`, `git push`. Seu repo deve ser **privado** se contém hostnames internos, emails ou identidades.
