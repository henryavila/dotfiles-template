#!/usr/bin/env bash
# tests/mesh-status-markdown-surgery.test.sh — covers --write idempotence
# and edge cases for the awk-based replacement between mesh-status markers.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/scripts/lib/mesh-status"
MD_FIXTURES="$HERE/fixtures/markdown"
SNAP_FIXTURES="$HERE/fixtures/snapshots"

[[ -x "$STATUS" ]] || { echo "mesh-status not executable at $STATUS" >&2; exit 1; }
[[ -d "$MD_FIXTURES" ]] || { echo "markdown fixtures missing at $MD_FIXTURES" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

TESTROOT=$(mktemp -d /tmp/mesh-status-md-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

_stage_sync() {
    local sync="$1"; shift
    rm -rf "$sync"
    mkdir -p "$sync"
    local f
    for f in "$@"; do
        cp "$SNAP_FIXTURES/$f" "$sync/${f%-*}.json"
    done
}

_run_write() {
    local target="$1"; shift
    # MESH_STATUS_CONF=/dev/null isolates the test from the user's real
    # ~/.config/dotfiles/mesh-status.conf which would otherwise override
    # MESH_SYNC_DIR. See note in tests/mesh-status.test.sh _run_status.
    NO_COLOR=1 MESH_STATUS_CONF=/dev/null MESH_SYNC_DIR="$1" bash "$STATUS" --no-snap --write --target "$target" 2>&1
}

# ─── Tests ───────────────────────────────────────────────────────────

test_replaces_between_markers() {
    local sync="$TESTROOT/sync-rep"
    _stage_sync "$sync" "ultron-fresh.json" "mac-stale.json" "crc-offline.json"
    local target="$TESTROOT/with-markers.md"
    cp "$MD_FIXTURES/with-markers.md" "$target"
    _run_write "$target" "$sync" >/dev/null
    if grep -q "Mesh snapshot" "$target" \
       && grep -q "old payload that should be replaced" "$target"; then
        _fail "old payload still present after --write"
    elif grep -q "Mesh snapshot" "$target" \
         && grep -q "preserved narrative" "$target"; then
        _pass "--write replaces between markers, preserves narrative outside"
    else
        _fail "--write produced unexpected output" "$(cat "$target")"
    fi
}

test_idempotent() {
    local sync="$TESTROOT/sync-idem"
    _stage_sync "$sync" "ultron-fresh.json" "mac-stale.json"
    local target="$TESTROOT/idem.md"
    cp "$MD_FIXTURES/with-markers.md" "$target"
    _run_write "$target" "$sync" >/dev/null
    local hash1
    hash1=$(md5 -q "$target" 2>/dev/null || md5sum "$target" | awk '{print $1}')
    _run_write "$target" "$sync" >/dev/null
    local hash2
    hash2=$(md5 -q "$target" 2>/dev/null || md5sum "$target" | awk '{print $1}')
    # Captured timestamp uses minute resolution — same minute → same payload.
    if [[ "$hash1" == "$hash2" ]]; then
        _pass "two consecutive --write runs produce byte-identical output"
    else
        _fail "non-idempotent: hashes differ ($hash1 vs $hash2)"
    fi
}

test_missing_markers_fails_loud() {
    local sync="$TESTROOT/sync-nomark"
    _stage_sync "$sync" "ultron-fresh.json"
    local target="$TESTROOT/no-markers.md"
    cp "$MD_FIXTURES/no-markers.md" "$target"
    local out rc
    out=$(_run_write "$target" "$sync"); rc=$?
    if (( rc != 0 )) \
       && echo "$out" | grep -q "markers absent" \
       && echo "$out" | grep -q "<!-- mesh-status:start"; then
        _pass "missing markers: exit non-zero with copy-paste hint"
    else
        _fail "missing-markers error path broken (rc=$rc)" "$out"
    fi
}

test_target_missing_fails() {
    local sync="$TESTROOT/sync-tgt"
    _stage_sync "$sync" "ultron-fresh.json"
    local out rc
    out=$(_run_write "$TESTROOT/does-not-exist.md" "$sync"); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "target not found"; then
        _pass "missing target file: exit non-zero, actionable message"
    else
        _fail "missing target error path broken (rc=$rc)" "$out"
    fi
}

test_whitespace_outside_markers_preserved() {
    # Verify that lines BEFORE the start marker and AFTER the end marker
    # are kept verbatim, including blank lines.
    local sync="$TESTROOT/sync-ws"
    _stage_sync "$sync" "ultron-fresh.json"
    local target="$TESTROOT/ws.md"
    {
        echo "# Heading"
        echo
        echo
        echo "Line with two blanks above"
        echo
        echo "<!-- mesh-status:start - auto-generated -->"
        echo "WILL BE REPLACED"
        echo "<!-- mesh-status:end -->"
        echo
        echo "Trailing line"
    } > "$target"
    _run_write "$target" "$sync" >/dev/null
    # Expected: lines 1..6 unchanged, payload replaced, lines after end marker preserved.
    if [[ "$(sed -n '1p'    "$target")" == "# Heading" ]] \
       && [[ -z              "$(sed -n '2p' "$target")" ]] \
       && [[ -z              "$(sed -n '3p' "$target")" ]] \
       && [[ "$(sed -n '4p' "$target")" == "Line with two blanks above" ]] \
       && grep -q "Trailing line" "$target" \
       && ! grep -q "WILL BE REPLACED" "$target"; then
        _pass "whitespace + content outside markers preserved across surgery"
    else
        _fail "whitespace preservation regression" "$(cat "$target")"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────
echo
echo "${C_DIM}── mesh-status --write markdown surgery${C_RST}"
echo

test_replaces_between_markers
test_idempotent
test_missing_markers_fails_loud
test_target_missing_fails
test_whitespace_outside_markers_preserved

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
