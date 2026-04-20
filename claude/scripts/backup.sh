#!/usr/bin/env bash
# backup.sh — tarball dos diretórios Claude em um path timestamped,
# excluindo state volumoso. Destinado à Fase 0 do playbook de convergência
# (ver README.md deste diretório).
#
# Uso: bash backup.sh [dest_dir]
#   dest_dir default: $HOME
#
# Saída: dest_dir/claude-full-backup-<hostname>-<timestamp>.tgz

set -euo pipefail

DEST_DIR="${1:-$HOME}"
HOST="$(hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST_DIR/claude-full-backup-${HOST}-${TS}.tgz"

if [ ! -d "$HOME/.claude" ] && [ ! -d "$HOME/.claude-mem" ]; then
    echo "! Nenhum diretório Claude em $HOME — nada a fazer."
    exit 0
fi

echo "→ Creating $OUT"

# Excluir paths grandes / state per-machine / secretos
# (mas secrets precisam estar no backup pra rollback funcionar — incluir)
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

# Sanidade
if [ ! -f "$OUT" ]; then
    echo "✗ Backup falhou — arquivo não criado"
    exit 1
fi

size=$(du -sh "$OUT" | cut -f1)
sha=$(sha256sum "$OUT" | awk '{print $1}')
echo "✓ Backup criado: $OUT ($size)"
echo "  sha256: $sha"
echo
echo "Para restaurar:"
echo "  rm -rf ~/.claude ~/.claude-mem   # cuidado"
echo "  tar xzf $OUT -C \$HOME"
