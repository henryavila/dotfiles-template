#!/usr/bin/env bash
# dotfiles-template installer — self-contained, zero external deps.
#
# Iterates over MAPPINGS (src|dst[|mode]) and deploys each one:
#   mode = overwrite (default) — diff, backup-if-different, overwrite.
#   mode = once                — deploy only if destination is missing.
#                                Use for files with placeholders that the
#                                user fills in after first install (tokens,
#                                secrets) so subsequent runs don't wipe them.
#
# Usage:
#   bash install.sh              deploy everything
#   DRY_RUN=1 bash install.sh    show what would change without writing
#
# Intentionally independent of dev-bootstrap. Uses indexed arrays (not
# `declare -A`) so it works on macOS's default bash 3.2.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# src|dst[|mode]  — mode is "overwrite" (default) or "once".
MAPPINGS=(
    "ssh/config|$HOME/.ssh/config"
    "git/gitconfig.local|$HOME/.gitconfig.local"
    "git/gitignore_global|$HOME/.config/git/ignore"
    "shell/bashrc.local|$HOME/.bashrc.local"
    "shell/zshrc.local|$HOME/.zshrc.local"
    "shell/aliases.sh|$HOME/.bashrc.d/99-personal-aliases.sh"
    "shell/aliases.sh|$HOME/.zshrc.d/99-personal-aliases.sh"
    "config/htoprc|$HOME/.config/htop/htoprc"
    "config/s3cfg|$HOME/.s3cfg|once"
    "npm/npmrc|$HOME/.npmrc|once"
    "claude/manifest/mcps-user.sh|$HOME/.claude/manifest/mcps-user.sh"
    "claude/stignore/claude-config.stignore|$HOME/.claude/.stignore"
    "claude/stignore/claude-mem.stignore|$HOME/.claude-mem/.stignore"
)

# Track placeholder deploys so we can remind the user at the end.
needs_edit=()

deploy_one() {
    local src="$1" dst="$2" mode="${3:-overwrite}"
    local src_abs="$HERE/$src"

    if [[ ! -f "$src_abs" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$dst")"

    # "once" mode — do nothing if destination already exists.
    if [[ "$mode" == "once" ]] && [[ -e "$dst" ]]; then
        ok "$dst preserved (once mode; edit directly, not in the repo)"
        return 0
    fi

    if [[ -f "$dst" ]] && cmp -s "$src_abs" "$dst"; then
        ok "$dst up to date"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "would deploy $src → $dst ($mode)"
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
        "$HOME/.s3cfg"|"$HOME/.npmrc")
            chmod 0600 "$dst"
            ;;
        "$HOME"/.bashrc.d/*|"$HOME"/.zshrc.d/*)
            chmod 0644 "$dst"
            ;;
    esac

    ok "deployed $dst"

    # Flag files that still contain placeholders after deploy
    if grep -q '<REPLACE-WITH-YOUR-' "$dst" 2>/dev/null; then
        needs_edit+=("$dst")
    fi
}

found_any=0
for pair in "${MAPPINGS[@]}"; do
    # Split src|dst|mode — at most 3 fields.
    IFS='|' read -r src dst mode <<< "$pair"
    mode="${mode:-overwrite}"
    if [[ -f "$HERE/$src" ]]; then
        found_any=1
        deploy_one "$src" "$dst" "$mode"
    fi
done

if [[ "$found_any" -eq 0 ]]; then
    warn "no non-'.example' files found — copy an .example to its plain name and edit it"
    echo
    echo "Example:"
    echo "  cp ssh/config.example ssh/config"
    echo "  \$EDITOR ssh/config"
    echo "  bash install.sh"
    exit 0
fi

# Final reminder if any deployed file still has placeholders
if [[ "${#needs_edit[@]}" -gt 0 ]]; then
    echo
    warn "the following files were deployed with placeholders — edit them with real values:"
    for f in "${needs_edit[@]}"; do
        echo "  $f"
    done
    echo
    echo "These are 'once' files — install.sh will NOT overwrite them on subsequent runs."
fi
