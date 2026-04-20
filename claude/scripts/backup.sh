#!/usr/bin/env bash
# backup.sh — tarball the Claude directories into a timestamped path,
# excluding bulky state. Meant for Phase 0 of the convergence playbook
# (see this directory's README.md).
#
# Usage: bash backup.sh [dest_dir]
#   dest_dir default: $HOME
#
# Output: dest_dir/claude-full-backup-<hostname>-<timestamp>.tgz

set -euo pipefail

DEST_DIR="${1:-$HOME}"
HOST="$(hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST_DIR/claude-full-backup-${HOST}-${TS}.tgz"

if [ ! -d "$HOME/.claude" ] && [ ! -d "$HOME/.claude-mem" ]; then
    echo "! No Claude directory under $HOME — nothing to do."
    exit 0
fi

echo "→ Creating $OUT"

# Exclude bulky paths / per-machine state / secrets… except secrets must be
# included so a rollback actually restores a working config.
tar czf "$OUT" \
    -C "$HOME" \
    --exclude='.claude/projects' \
    --exclude='.claude/cache' \
    --exclude='.claude/file-history' \
    --exclude='.claude/session-data' \
    --exclude='.claude/debug' \
    --exclude='.claude/statsig' \
    --exclude='.claude/backups' \
    --exclude='.claude/shell-snapshots' \
    --exclude='.claude/plugins/cache' \
    --exclude='.claude-mem/logs' \
    --exclude='*.db-shm' \
    --exclude='*.db-wal' \
    .claude .claude-mem 2>/dev/null || true

# Sanity check
if [ ! -f "$OUT" ]; then
    echo "✗ Backup failed — output file not created"
    exit 1
fi

size=$(du -sh "$OUT" | cut -f1)
sha=$(sha256sum "$OUT" | awk '{print $1}')
echo "✓ Backup created: $OUT ($size)"
echo "  sha256: $sha"
echo
echo "To restore:"
echo "  rm -rf ~/.claude ~/.claude-mem   # careful"
echo "  tar xzf $OUT -C \$HOME"
