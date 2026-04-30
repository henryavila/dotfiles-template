#!/usr/bin/env bash
# claude-replicate — align THIS machine with the curated shared.json.
#
# Default: dry-run report (read-only). With --apply, installs missing
# marketplaces + plugins via `claude plugin install`.
#
# EXTRAS (local-only plugins/marketplaces not in shared.json) are NEVER
# removed — they're per-machine experiments and removal would be destructive.
# Use `claude plugin disable` manually if you want to clean up locally.

set -euo pipefail

DOTFILES="${DOTFILES_DIR:-$HOME/dotfiles}"
SHARED="$DOTFILES/claude/manifest/shared.json"
KNOWN_MP="$HOME/.claude/plugins/known_marketplaces.json"
SETTINGS="$HOME/.claude/settings.json"

APPLY=0
case "${1:-}" in
    --apply)            APPLY=1 ;;
    -h|--help|"")       ;;
    *)                  echo "Usage: claude-replicate [--apply]" >&2; exit 1 ;;
esac

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,/^$/p' "$0" | sed 's/^# //;s/^#//'
    exit 0
fi

for f in "$SHARED" "$KNOWN_MP" "$SETTINGS"; do
    [[ -f $f ]] || { echo "ERROR: $f missing" >&2; exit 2; }
done
command -v jq >/dev/null || { echo "ERROR: jq not in PATH" >&2; exit 3; }

# ── Compute diffs ──────────────────────────────────────────────────────
MP_SHARED=$(jq -r '.marketplaces | keys[]' "$SHARED" | sort -u)
MP_LOCAL=$(jq -r 'keys[]' "$KNOWN_MP" | sort -u)
MP_MISSING=$(comm -23 <(echo "$MP_SHARED") <(echo "$MP_LOCAL"))
MP_EXTRA=$(comm -13 <(echo "$MP_SHARED") <(echo "$MP_LOCAL"))

PL_SHARED=$(jq -r '.plugins | keys[]' "$SHARED" | sort -u)
PL_LOCAL=$(jq -r '.enabledPlugins // {} | with_entries(select(.value == true)) | keys[]' "$SETTINGS" | sort -u)
PL_MISSING=$(comm -23 <(echo "$PL_SHARED") <(echo "$PL_LOCAL"))
PL_EXTRA=$(comm -13 <(echo "$PL_SHARED") <(echo "$PL_LOCAL"))

# ── Report ─────────────────────────────────────────────────────────────
echo "=== Marketplaces ==="
if [[ -n "$MP_MISSING" ]]; then
    echo "MISSING (em shared, falta local — replicate vai instalar):"
    echo "$MP_MISSING" | sed 's/^/  - /'
else
    echo "MISSING: nada"
fi
if [[ -n "$MP_EXTRA" ]]; then
    echo "EXTRA (local-only, NÃO em shared — experimento ou esqueceu de promover):"
    echo "$MP_EXTRA" | sed 's/^/  - /'
fi

echo
echo "=== Plugins ==="
if [[ -n "$PL_MISSING" ]]; then
    echo "MISSING (em shared, falta local — replicate vai instalar):"
    echo "$PL_MISSING" | sed 's/^/  - /'
else
    echo "MISSING: nada"
fi
if [[ -n "$PL_EXTRA" ]]; then
    echo "EXTRA (local-only, NÃO em shared — experimento ou esqueceu de promover):"
    echo "$PL_EXTRA" | sed 's/^/  - /'
fi

# ── Apply or hint ──────────────────────────────────────────────────────
if [[ $APPLY -eq 0 ]]; then
    echo
    if [[ -n "$MP_MISSING" || -n "$PL_MISSING" ]]; then
        echo "→ Run 'claude-replicate --apply' to install MISSING items."
    fi
    if [[ -n "$PL_EXTRA" ]]; then
        echo "→ Para promover algum EXTRA pra todas as máquinas: 'claude-promote NOME[@MARKETPLACE]'"
    fi
    exit 0
fi

# ── --apply mode ───────────────────────────────────────────────────────
command -v claude >/dev/null || { echo "ERROR: claude CLI not in PATH — install Claude Code first" >&2; exit 4; }

echo
echo "=== Applying ==="
if [[ -n "$MP_MISSING" ]]; then
    while IFS= read -r mp; do
        [[ -z "$mp" ]] && continue
        repo=$(jq -r --arg k "$mp" '.marketplaces[$k].repo' "$SHARED")
        if [[ -z "$repo" || "$repo" == "null" ]]; then
            echo "✗ marketplace '$mp' has no .repo in shared.json — skipping" >&2
            continue
        fi
        echo "→ claude plugin marketplace add $repo"
        claude plugin marketplace add "$repo"
    done <<< "$MP_MISSING"
fi

if [[ -n "$PL_MISSING" ]]; then
    while IFS= read -r pl; do
        [[ -z "$pl" ]] && continue
        echo "→ claude plugin install $pl"
        claude plugin install "$pl"
    done <<< "$PL_MISSING"
fi

echo
echo "✓ apply done. Restart Claude Code para garantir que carregou os novos plugins."
