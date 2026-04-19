#!/usr/bin/env bash
# dotfiles-template installer — self-contained, zero external deps.
#
# Iterates over every non-".example" file listed in MAPPINGS and deploys
# it to its canonical home location using diff+backup+replace.
#
# Usage:
#   bash install.sh              deploy everything
#   DRY_RUN=1 bash install.sh    show what would change without writing
#
# Kept intentionally independent of dev-bootstrap so it works from a
# fresh clone on any machine. Uses indexed arrays (not `declare -A`) so
# it runs on macOS's default bash 3.2.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# src|dst pairs. A single src may appear multiple times (different destinations).
MAPPINGS=(
    "ssh/config|$HOME/.ssh/config"
    "git/gitconfig.local|$HOME/.gitconfig.local"
    "shell/bashrc.local|$HOME/.bashrc.local"
    "shell/zshrc.local|$HOME/.zshrc.local"
    "shell/inputrc|$HOME/.inputrc"
    "shell/aliases.sh|$HOME/.bashrc.d/99-personal-aliases.sh"
    "shell/aliases.sh|$HOME/.zshrc.d/99-personal-aliases.sh"
)

deploy_one() {
    local src="$1" dst="$2"
    local src_abs="$HERE/$src"

    if [[ ! -f "$src_abs" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$dst")"

    if [[ -f "$dst" ]] && cmp -s "$src_abs" "$dst"; then
        ok "$dst up to date"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "would deploy $src → $dst"
        return 0
    fi

    if [[ -e "$dst" ]]; then
        local ts backup
        ts="$(date +%Y%m%d-%H%M%S)"
        backup="${dst}.bak-${ts}"
        cp -p "$dst" "$backup"
        log "backed up previous $dst → $backup"
    fi

    cp "$src_abs" "$dst"

    # Permissions
    case "$dst" in
        "$HOME/.ssh/config")
            chmod 0600 "$dst"
            ;;
        "$HOME"/.bashrc.d/*|"$HOME"/.zshrc.d/*)
            chmod 0644 "$dst"
            ;;
    esac

    ok "deployed $dst"
}

found_any=0
for pair in "${MAPPINGS[@]}"; do
    src="${pair%%|*}"
    dst="${pair#*|}"
    if [[ -f "$HERE/$src" ]]; then
        found_any=1
        deploy_one "$src" "$dst"
    fi
done

if [[ "$found_any" -eq 0 ]]; then
    warn "no non-'.example' files found — copy an .example to its plain name and edit it"
    echo
    echo "Example:"
    echo "  cp ssh/config.example ssh/config"
    echo "  \$EDITOR ssh/config"
    echo "  bash install.sh"
fi
