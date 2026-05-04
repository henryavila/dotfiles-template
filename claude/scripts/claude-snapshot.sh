#!/usr/bin/env bash
# claude-snapshot — refresh ~/dotfiles/claude/manifest/snapshots/<host>.json
#
# Captures CURRENT marketplaces + enabled plugins of THIS machine into a
# descriptive (audit/reference) JSON file. Idempotent — overwrite safe.
#
# This is NOT the source of truth for replication; that's shared.json.
# The snapshot exists so you can see "what's actually on machine X right now"
# at a glance + compare across machines via `git diff`.

set -euo pipefail

DOTFILES="${DOTFILES_DIR:-$HOME/dotfiles}"
SNAPSHOT_DIR="$DOTFILES/claude/manifest/snapshots"
KNOWN_MP="$HOME/.claude/plugins/known_marketplaces.json"
SETTINGS="$HOME/.claude/settings.json"
HOST_LC=$(hostname | tr '[:upper:]' '[:lower:]')
OUT="$SNAPSHOT_DIR/$HOST_LC.json"

[[ -d "$DOTFILES/claude" ]] || { echo "ERROR: $DOTFILES/claude not found — set DOTFILES_DIR if non-default" >&2; exit 1; }
[[ -f $KNOWN_MP ]] || { echo "ERROR: $KNOWN_MP missing — Claude Code never ran on this machine?" >&2; exit 2; }
[[ -f $SETTINGS ]] || { echo "ERROR: $SETTINGS missing" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not in PATH" >&2; exit 3; }

mkdir -p "$SNAPSHOT_DIR"

jq -n --slurpfile mp "$KNOWN_MP" --slurpfile st "$SETTINGS" \
      --arg now "$(date -Iseconds)" --arg host "$(hostname)" '
{
  "_doc": "Auto-generated descriptive snapshot. DO NOT edit by hand — re-run `claude-snapshot` to refresh. Reference/audit only; not used by claude-replicate (which reads shared.json).",
  "_generated_at": $now,
  "_generated_by": "claude-snapshot",
  "_machine": $host,
  marketplaces: ($mp[0] | with_entries({key: .key, value: {source: .value.source.source, repo: .value.source.repo}})),
  plugins_enabled: ($st[0].enabledPlugins // {} | with_entries(select(.value == true)) | with_entries({key: .key, value: {}}))
}' > "$OUT"

echo "✓ snapshot written: $OUT"
echo "  marketplaces:    $(jq '.marketplaces | length' "$OUT")"
echo "  plugins enabled: $(jq '.plugins_enabled | length' "$OUT")"
echo
if command -v git >/dev/null && git -C "$DOTFILES" rev-parse >/dev/null 2>&1; then
    if ! git -C "$DOTFILES" diff --quiet "claude/manifest/snapshots/$HOST_LC.json" 2>/dev/null; then
        echo "git diff (vs last commit):"
        git -C "$DOTFILES" --no-pager diff --stat "claude/manifest/snapshots/$HOST_LC.json"
        echo
        # Snapshots embed hostname + plugin list. claude/manifest/snapshots/.gitignore
        # blocks `*.json` by default. Only print the commit hint when the user
        # has explicitly opted in (private fork) via ALLOW_SNAPSHOT_COMMIT=1.
        if [[ "${ALLOW_SNAPSHOT_COMMIT:-0}" == "1" ]]; then
            echo "Commit when ready:  git -C $DOTFILES commit -m 'claude: snapshot $HOST_LC' claude/manifest/snapshots/$HOST_LC.json"
        else
            echo "Snapshot is local-only (claude/manifest/snapshots/.gitignore blocks *.json)."
            echo "On a PRIVATE fork where machine-by-machine reproducibility is wanted,"
            echo "set ALLOW_SNAPSHOT_COMMIT=1 to see the commit hint, then add an exception"
            echo "to .gitignore (\`!$HOST_LC.json\` or remove the \`*.json\` line)."
        fi
    else
        echo "(no diff vs last commit — snapshot unchanged)"
    fi
fi
