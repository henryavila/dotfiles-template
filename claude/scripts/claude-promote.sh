#!/usr/bin/env bash
# claude-promote — add a plugin to shared.json (mark as "should be on every machine")
#
# Usage:
#   claude-promote PLUGIN[@MARKETPLACE] [--note "explanation"]
#
# If you pass just PLUGIN (without @marketplace), looks it up in your local
# enabledPlugins to find the marketplace automatically.
#
# Adds the marketplace to shared.json's marketplaces map too if not already
# there (so other machines know where to fetch from).
#
# Idempotent: re-running on an already-promoted plugin is a no-op + reports OK.

set -euo pipefail

DOTFILES="${DOTFILES_DIR:-$HOME/dotfiles}"
SHARED="$DOTFILES/claude/manifest/shared.json"
KNOWN_MP="$HOME/.claude/plugins/known_marketplaces.json"
SETTINGS="$HOME/.claude/settings.json"

[[ $# -ge 1 ]] || { echo "Usage: claude-promote PLUGIN[@MARKETPLACE] [--note 'explanation']" >&2; exit 1; }

NAME="$1"; shift
NOTE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --note) NOTE="${2:-}"; shift 2 ;;
        *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
    esac
done

[[ -f $SHARED ]] || { echo "ERROR: $SHARED missing" >&2; exit 2; }
[[ -f $SETTINGS ]] || { echo "ERROR: $SETTINGS missing" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not in PATH" >&2; exit 3; }

# ── If user passed bare NAME, look up @marketplace from local state ────
if [[ "$NAME" != *"@"* ]]; then
    FULL=$(jq -r --arg n "$NAME" '
        .enabledPlugins // {}
        | to_entries[]
        | select(.value == true)
        | .key
        | select(startswith($n + "@"))' "$SETTINGS" | head -1)
    if [[ -z "$FULL" ]]; then
        echo "ERROR: '$NAME' not found in local enabled plugins." >&2
        echo "       Specify explicitly as PLUGIN@MARKETPLACE, or check 'claude plugin list'." >&2
        exit 1
    fi
    echo "→ resolved '$NAME' → '$FULL'"
    NAME="$FULL"
fi

MARKET_NAME="${NAME#*@}"

# ── Already in shared? ─────────────────────────────────────────────────
if jq -e --arg k "$NAME" '.plugins[$k]' "$SHARED" >/dev/null; then
    echo "✓ $NAME already in shared.json (no-op)"
    exit 0
fi

# ── Add marketplace if missing ─────────────────────────────────────────
if ! jq -e --arg k "$MARKET_NAME" '.marketplaces[$k]' "$SHARED" >/dev/null; then
    REPO=$(jq -r --arg k "$MARKET_NAME" '.[$k].source.repo // ""' "$KNOWN_MP")
    if [[ -z "$REPO" || "$REPO" == "null" ]]; then
        echo "ERROR: marketplace '$MARKET_NAME' not in local $KNOWN_MP" >&2
        echo "       Add it via 'claude plugin marketplace add <github-repo>' first." >&2
        exit 1
    fi
    echo "→ adding marketplace '$MARKET_NAME' ($REPO) to shared.json"
    tmp=$(mktemp)
    jq --arg k "$MARKET_NAME" --arg repo "$REPO" \
       '.marketplaces[$k] = {source: "github", repo: $repo, note: "auto-added by claude-promote — set a better note manually"}' \
       "$SHARED" > "$tmp" && mv "$tmp" "$SHARED"
fi

# ── Add plugin ─────────────────────────────────────────────────────────
echo "→ adding plugin '$NAME' to shared.json${NOTE:+ (note: $NOTE)}"
tmp=$(mktemp)
if [[ -n "$NOTE" ]]; then
    jq --arg k "$NAME" --arg note "$NOTE" \
       '.plugins[$k] = {note: $note}' \
       "$SHARED" > "$tmp" && mv "$tmp" "$SHARED"
else
    jq --arg k "$NAME" \
       '.plugins[$k] = {note: "(set explanation manually)"}' \
       "$SHARED" > "$tmp" && mv "$tmp" "$SHARED"
fi

echo "✓ shared.json updated"
echo
if command -v git >/dev/null && git -C "$DOTFILES" rev-parse >/dev/null 2>&1; then
    git -C "$DOTFILES" --no-pager diff --no-color claude/manifest/shared.json | head -20
fi
echo
echo "Next:"
echo "  cd $DOTFILES && git add claude/manifest/shared.json"
echo "  git commit -m 'claude: promote $NAME'"
echo "  git push"
echo "  # then on other machines: 'cd $DOTFILES && git pull && claude-replicate --apply'"
