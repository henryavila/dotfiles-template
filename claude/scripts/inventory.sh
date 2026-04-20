#!/usr/bin/env bash
# inventory.sh — deterministic snapshot of the Claude state on a machine.
#
# Usage: bash inventory.sh > ~/claude-inventory-$(hostname).txt
# Then, collect the inventories on one machine and diff them to choose a
# merge strategy (golden master vs union).
#
# Read-only — safe to run anytime.

set -u

echo "=== HOST: $(hostname) ==="
echo "=== DATE: $(date -u +%FT%TZ) ==="
echo "=== USER: $USER  HOME: $HOME ==="
echo

echo "=== claude CLI version ==="
command -v claude >/dev/null 2>&1 && claude --version 2>&1 | head -1 || echo "(claude not installed)"
echo

echo "=== PLUGINS (via claude CLI) ==="
claude plugin list 2>&1 || echo "(failed)"
echo

echo "=== MARKETPLACES ==="
claude plugin marketplace list 2>/dev/null || ls "$HOME/.claude/plugins/marketplaces/" 2>/dev/null || echo "(none)"
echo

echo "=== MCPs (all — plugin and user-scope) ==="
claude mcp list 2>&1 || echo "(failed)"
echo

echo "=== SKILLS (~/.claude/skills/) ==="
find "$HOME/.claude/skills" -maxdepth 2 -type d 2>/dev/null | sort
echo

echo "=== AGENTS (~/.claude/agents/) ==="
find "$HOME/.claude/agents" -type f 2>/dev/null | sort
echo

echo "=== COMMANDS (~/.claude/commands/) ==="
find "$HOME/.claude/commands" -type f 2>/dev/null | sort
echo

echo "=== RULES (~/.claude/rules/) ==="
find "$HOME/.claude/rules" -type f 2>/dev/null | sort
echo

echo "=== HOOKS (~/.claude/hooks/hooks.json) ==="
python3 -m json.tool "$HOME/.claude/hooks/hooks.json" 2>/dev/null || echo "(no hooks.json)"
echo

echo "=== SETTINGS keys (~/.claude/settings.json) ==="
python3 -c "import json; print('\n'.join(sorted(json.load(open('$HOME/.claude/settings.json')).keys())))" 2>/dev/null
echo

echo "=== FILE CHECKSUMS (contentful config files) ==="
# Only the stable content files — excluding marketplaces/ (huge) and state
if [ -d "$HOME/.claude" ]; then
    (cd "$HOME/.claude" && find skills agents commands rules hooks manifest -type f \
        \( -name "*.md" -o -name "*.json" -o -name "*.sh" -o -name "*.js" -o -name "*.cjs" -o -name "*.py" \) \
        -exec sha256sum {} \; 2>/dev/null | sort -k2)
fi
echo

echo "=== SCHEMA VERSION (claude-mem) ==="
python3 -c "
import sqlite3
try:
    db = sqlite3.connect('$HOME/.claude-mem/claude-mem.db')
    v = db.execute('SELECT MAX(version) FROM schema_versions').fetchone()[0]
    print(f'schema version: {v}')
except Exception as e:
    print(f'(claude-mem DB read failed: {e})')
" 2>/dev/null
echo

echo "=== CLAUDE-MEM STATS ==="
ls -la "$HOME/.claude-mem/"*.db 2>/dev/null | head -5
echo "chroma size: $(du -sh $HOME/.claude-mem/chroma 2>/dev/null | cut -f1)"
python3 -c "
import sqlite3
try:
    db = sqlite3.connect('$HOME/.claude-mem/claude-mem.db')
    for table in ('sdk_sessions','observations','user_prompts','session_summaries'):
        try:
            row = db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()
            print(f'  {table}: {row[0]} rows')
        except Exception as e:
            print(f'  {table}: (failed: {e})')
    # Top projects by observation count
    print()
    print('  observations per project:')
    for row in db.execute('SELECT project, COUNT(*) FROM observations GROUP BY project ORDER BY 2 DESC LIMIT 10'):
        print(f'    {row[0]}: {row[1]}')
except Exception as e:
    print(f'(failed: {e})')
" 2>/dev/null
echo

echo "=== SYNCTHING ==="
if command -v syncthing >/dev/null 2>&1; then
    echo "syncthing version: $(syncthing --version 2>&1 | head -1)"
    echo "device ID: $(syncthing --device-id 2>/dev/null || echo '(not initialized)')"
else
    echo "(syncthing not installed)"
fi
