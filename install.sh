#!/usr/bin/env bash
# dotfiles-template installer — self-contained, zero external deps.
#
# Iterates over every non-".example" file under ssh/, git/, shell/ and deploys
# it to its canonical home location using diff+backup+replace.
#
# Usage:
#   bash install.sh              deploy everything
#   DRY_RUN=1 bash install.sh    show what would change without writing
#
# This script is intentionally independent of dev-bootstrap so that it
# works from a fresh clone on any machine.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# Map <src-relative-to-repo> → <absolute destination>
declare -A MAP
MAP["ssh/config"]="$HOME/.ssh/config"
MAP["git/gitconfig.local"]="$HOME/.gitconfig.local"
MAP["shell/bashrc.local"]="$HOME/.bashrc.local"
MAP["shell/zshrc.local"]="$HOME/.zshrc.local"

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
    # SSH config must be 0600
    if [[ "$dst" == "$HOME/.ssh/config" ]]; then
        chmod 0600 "$dst"
    fi
    ok "deployed $dst"
}

found_any=0
for src in "${!MAP[@]}"; do
    if [[ -f "$HERE/$src" ]]; then
        found_any=1
        deploy_one "$src" "${MAP[$src]}"
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
