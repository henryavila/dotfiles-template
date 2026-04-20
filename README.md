# dotfiles-template

Skeleton para dotfiles pessoais de qualquer dev. Clique **"Use this template"** no GitHub para criar seu próprio repo (recomendado: privado).

## Conceito: template é a camada de overrides, não o baseline

Este template **não tenta ser um dotfiles completo**. A maior parte da configuração (bashrc, zshrc, inputrc, prompt, fzf, zoxide, aliases git, git defaults) vem do [`dev-bootstrap`](https://github.com/henryavila/dev-bootstrap), que roda antes e instala o stack + fragments em `~/.bashrc.d/` / `~/.zshrc.d/` / `~/.gitconfig`.

O seu fork deste template só precisa versionar:

1. **Dados pessoais que variam por pessoa** — ssh hosts, identidade git, tokens
2. **Overrides** sobre o baseline do bootstrap — por exemplo, `[merge] conflictstyle=diff3` se você prefere ao `zdiff3` que o bootstrap aplica
3. **Preferências que o bootstrap não tem opinião** — ble.sh, Typora como editor, eza com icons

Se você se pegar duplicando algo que o bootstrap já deploya, delete do seu fork — o bootstrap vence no baseline, seu fork vence nas overrides pelo prefixo `99-` (ver §Precedência no fim).

## Como funciona

Cada arquivo em `ssh/`, `git/`, `shell/`, `config/`, `npm/` com sufixo `.example` é um placeholder. Para adotar uma config:

```bash
cp ssh/config.example ssh/config
$EDITOR ssh/config                 # customize
bash install.sh                    # deploy no home
```

`install.sh` é self-contained (sem dependências do bootstrap). Para cada arquivo não-`.example`: calcula o destino, faz diff, cria backup timestamped se mudou, e copia. Suporta dois modos:

- **overwrite** (default): arquivo no repo é a fonte da verdade. Diff + backup + copia.
- **once**: deploya só se destino não existe. Use para arquivos com placeholders de secrets — depois do primeiro install, você edita `~/.s3cfg` / `~/.npmrc` diretamente com seus tokens reais e `install.sh` nunca mais sobrescreve.

## O que é gerenciado

| src no repo | destino | modo | observações |
|-------------|---------|------|-------------|
| `ssh/config` | `~/.ssh/config` | overwrite (chmod 600) | hosts, IdentityFile |
| `git/gitconfig.local` | `~/.gitconfig.local` | overwrite | identidade + overrides — referenciado por `include.path` que o bootstrap 50-git seta em `~/.gitconfig` |
| `git/gitignore_global` | `~/.config/git/ignore` | overwrite | patterns ignorados em todo repo |
| `shell/bashrc.local` | `~/.bashrc.local` | overwrite | carregado **por último** pelo `~/.bashrc` do bootstrap |
| `shell/zshrc.local` | `~/.zshrc.local` | overwrite | idem para zsh |
| `shell/aliases.sh` | `~/.bashrc.d/99-personal-aliases.sh` e `~/.zshrc.d/99-personal-aliases.sh` | overwrite | prefixo `99-` garante que carrega depois dos fragments do bootstrap e sobrescreve se necessário |
| `config/htoprc` | `~/.config/htop/htoprc` | overwrite | atenção: htop reescreve este arquivo ao salvar na UI |
| `config/s3cfg` | `~/.s3cfg` | **once** (chmod 600) | edite direto no home após o primeiro deploy |
| `npm/npmrc` | `~/.npmrc` | **once** (chmod 600) | idem |

**Não é gerenciado** pelo template (intencionalmente):

- `~/.inputrc` — bootstrap/30-shell cuida disso
- `~/.bashrc`, `~/.zshrc` — bootstrap/30-shell cuida
- aliases git (g, gs, gco…) — bootstrap/50-git fragment deploya em `~/.bashrc.d/50-git.sh`
- `~/.gitconfig` global — bootstrap/50-git seta via `git config --global`

## Integração com dev-bootstrap

```bash
# Num ambiente recém-bootstrapped:
DOTFILES_REPO=git@github.com:SEU_USER/dotfiles.git bash ~/dev-bootstrap/bootstrap.sh
```

O topic `95-dotfiles-personal` clona seu repo em `~/dotfiles` e roda `install.sh`.

## Adicionando um novo arquivo

1. Criar `<area>/<nome>.example` com conteúdo comentado explicando cada campo.
2. Adicionar entrada no array `MAPPINGS` em `install.sh`.
3. Adicionar linha na tabela "O que é gerenciado" neste README.
4. Commit com mensagem explicando **por quê** — ver §Evolução do template abaixo.

## Setup inicial (um fork novo)

```bash
git clone git@github.com:SEU_USER/dotfiles.git ~/dotfiles
cd ~/dotfiles
cp ssh/config.example ssh/config                       # e edite
cp git/gitconfig.local.example git/gitconfig.local     # ponha seu nome/email
cp shell/bashrc.local.example shell/bashrc.local       # (opcional) descomente o que quer
cp shell/aliases.sh.example shell/aliases.sh           # (opcional)
bash install.sh
```

Depois, commits normais: `git add`, `git commit`, `git push`. Seu repo deve ser **privado** se contém hostnames internos, emails ou identidades.

## Evolução do template (migração manual via release)

Não há sincronização automática template ↔ forks. Repos criados via "Use this template" no GitHub não têm história compartilhada com o template original, então `git merge upstream/main` não funciona.

Em vez disso, adotamos o modelo **release-driven manual**, como `create-react-app`, `vite`, `create-t3-app`:

1. **No template** (quem mantém): cada mudança estrutural em `*.example`, `install.sh` ou MAPPINGS vira um commit com mensagem detalhada e uma tag datada:
   ```bash
   git commit -m "feat: add inputrc example + htoprc expanded..."  # com migration notes no corpo
   git tag -a v2026-04-19 -m "…"
   gh release create v2026-04-19 --notes-from-tag
   ```
2. **No seu fork**: periodicamente (ou quando receber notificação de release), cheque:
   ```bash
   git clone --depth 1 git@github.com:henryavila/dotfiles-template.git /tmp/tpl
   diff -r /tmp/tpl/ ~/dotfiles/ | less
   ```
3. Copiar/aplicar seletivamente o que interessa. Nada automático — você decide o que vale portar.

### Formato esperado da migration note (no commit message do template)

Toda mudança estrutural deve trazer no corpo do commit:

```
## Migration (forks existentes)

Tempo estimado: 5min. Arquivos afetados: shell/inputrc, install.sh.

1. Clone o template: git clone --depth 1 <url> /tmp/tpl
2. cp /tmp/tpl/shell/inputrc.example shell/
3. Adicionar ao MAPPINGS: "shell/inputrc|$HOME/.inputrc"
4. DRY_RUN=1 bash install.sh
5. bash install.sh
```

Sem migration note, não tem tag/release — essa é a única disciplina do processo.

## Precedência (quem vence quando há conflito)

Quando o shell interativo carrega, em ordem:

1. `~/.bashrc` (gerado por bootstrap/30-shell) — loader minimal
2. `~/.bashrc.d/NN-<topic>.sh` em ordem alfabética — fragments do bootstrap (10-languages, 20-terminal-ux, 50-git, …)
3. `~/.bashrc.d/99-personal-aliases.sh` — seu dotfiles (prefixo `99-` força ser o último)
4. `~/.bashrc.local` — seu dotfiles (carregado por último pelo loader)

Então **seu dotfiles sempre vence** se quiser sobrescrever algo do bootstrap — sem edição no bootstrap, sem fork.

## Docs

`docs/` — aprendizados gerais de config (SSH gotchas, migration patterns, etc.). Ficam no template se são universalmente úteis; aprendizados específicos de infra (nomes de máquinas reais, etc.) ficam no seu fork pessoal.
