#!/usr/bin/env bash
# tests/mesh-status.test.sh — covers mesh-status flag handling and rendering.
#
# Uses pre-built snapshot fixtures under tests/fixtures/snapshots/. The
# files use far-future timestamps (2999-...) so age math always shows
# "stale" or "fresh" relative to current real time without flake.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATUS="$ROOT/scripts/lib/mesh-status"
SNAP_FIXTURES="$HERE/fixtures/snapshots"

[[ -x "$STATUS" ]] || { echo "mesh-status not executable at $STATUS" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

TESTROOT=$(mktemp -d /tmp/mesh-status-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

# Stage fixture snapshots into a fresh sync dir for each test.
_stage_fixtures() {
    local sync="$1"; shift
    rm -rf "$sync"
    mkdir -p "$sync"
    local f
    for f in "$@"; do
        cp "$SNAP_FIXTURES/$f" "$sync/${f%-*}.json"
    done
}

_run_status() {
    # MESH_STATUS_CONF=/dev/null prevents the user's real
    # ~/.config/dotfiles/mesh-status.conf from leaking MESH_SYNC_DIR
    # into the test (would override the test's TESTROOT and read from
    # the user's real ~/Sync/mesh-status/). /dev/null is readable but
    # has no shell-source side effects → MESH_SYNC_DIR stays at the
    # value the caller passed via env.
    NO_COLOR=1 MESH_STATUS_CONF=/dev/null bash "$STATUS" --no-snap "$@" 2>&1
}

# ─── Tests ───────────────────────────────────────────────────────────

test_help() {
    local out; out=$(NO_COLOR=1 bash "$STATUS" --help 2>&1)
    if echo "$out" | grep -q "Usage:" && echo "$out" | grep -q "mesh-status"; then
        _pass "--help shows usage"
    else
        _fail "--help missing Usage" "$out"
    fi
}

test_unknown_arg() {
    local out rc; out=$(NO_COLOR=1 bash "$STATUS" --bogus 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "unknown arg"; then
        _pass "unknown arg rejected with non-zero exit"
    else
        _fail "unknown arg not rejected (rc=$rc)" "$out"
    fi
}

test_overview_three_hosts() {
    local sync="$TESTROOT/sync-3hosts"
    _stage_fixtures "$sync" "ultron-fresh.json" "mac-stale.json" "crc-offline.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status)
    if echo "$out" | grep -q "ultron" \
       && echo "$out" | grep -q "mac" \
       && echo "$out" | grep -q "crc" \
       && echo "$out" | grep -q "Mesh consensus"; then
        _pass "overview renders all 3 hosts + consensus block"
    else
        _fail "overview missing hosts or consensus" "$out"
    fi
}

test_overview_corrupt_snapshot_skipped() {
    local sync="$TESTROOT/sync-corrupt"
    _stage_fixtures "$sync" "ultron-fresh.json" "crc-corrupt.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status)
    if echo "$out" | grep -qi "is not valid JSON" \
       && echo "$out" | grep -q "ultron"; then
        _pass "corrupt snapshot warned, valid hosts still rendered"
    else
        _fail "corrupt snapshot not handled gracefully" "$out"
    fi
}

test_overview_empty_mesh() {
    local sync="$TESTROOT/sync-empty"
    rm -rf "$sync"
    mkdir -p "$sync"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status)
    if echo "$out" | grep -q "no snapshots found"; then
        _pass "empty mesh shows actionable message"
    else
        _fail "empty mesh no actionable hint" "$out"
    fi
}

test_detail_existing_host() {
    local sync="$TESTROOT/sync-detail"
    _stage_fixtures "$sync" "ultron-fresh.json" "mac-stale.json" "crc-offline.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status --detail crc)
    if echo "$out" | grep -q "Host: crc" \
       && echo "$out" | grep -q "branch:" \
       && echo "$out" | grep -q "consensus:"; then
        _pass "--detail crc renders host meta + repo block"
    else
        _fail "--detail did not render expected sections" "$out"
    fi
}

test_detail_nonexistent_host() {
    local sync="$TESTROOT/sync-detail2"
    _stage_fixtures "$sync" "ultron-fresh.json"
    local out rc
    out=$(MESH_SYNC_DIR="$sync" _run_status --detail bogus); rc=$?
    if (( rc != 0 )) \
       && echo "$out" | grep -q "not found" \
       && echo "$out" | grep -q "Available hosts:"; then
        _pass "--detail unknown alias errors with host list"
    else
        _fail "--detail unknown alias error path broken (rc=$rc)" "$out"
    fi
}

test_detail_drift_section() {
    local sync="$TESTROOT/sync-drift"
    _stage_fixtures "$sync" "crc-offline.json"
    # crc fixture has drift_count=2, missing_count=1, total=3
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status --detail crc)
    if echo "$out" | grep -q "Drift" && echo "$out" | grep -q "/home/y/.bashrc"; then
        _pass "--detail surfaces drift items when non-empty"
    else
        _fail "--detail drift section missing" "$out"
    fi
}

test_json_aggregates_all() {
    local sync="$TESTROOT/sync-json"
    _stage_fixtures "$sync" "ultron-fresh.json" "mac-stale.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status --json)
    if echo "$out" | jq -e 'has("ultron") and has("mac")' >/dev/null 2>&1 \
       && echo "$out" | jq -e '.ultron.host.alias == "ultron"' >/dev/null 2>&1; then
        _pass "--json aggregates by alias and round-trips through jq"
    else
        _fail "--json output malformed" "$out"
    fi
}

test_gc_removes_old_snapshot() {
    local sync="$TESTROOT/sync-gc"
    _stage_fixtures "$sync" "ultron-fresh.json"
    # Build a synthetic "ancient" snapshot inline (captured_at well before
    # any reasonable --days cutoff). Fixtures use future timestamps for
    # other tests; here we want a real-past timestamp so gc sees it as old.
    cat > "$sync/ancient.json" <<EOF
{"schema_version":1,"captured_at":"1990-01-01T00:00:00Z","captured_by":"mesh-snap/0.1.0","host":{"alias":"ancient"},"repos":{},"drift":null,"advisories":null,"network":null}
EOF
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status --gc --days 30)
    if echo "$out" | grep -q "removed: " \
       && [[ ! -f "$sync/ancient.json" ]] \
       && [[ -f "$sync/ultron.json" ]]; then
        _pass "--gc removes snapshots with old captured_at, keeps fresh"
    else
        _fail "--gc didn't remove ancient or kept-the-wrong-one" "$out"
    fi
}

test_overview_consensus_marks_winner() {
    local sync="$TESTROOT/sync-cons"
    _stage_fixtures "$sync" "ultron-fresh.json" "mac-stale.json" "crc-offline.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status)
    # ultron has the freshest fetch → consensus row should reference it.
    if echo "$out" | grep -E "dev-bootstrap.*via ultron" >/dev/null \
       && echo "$out" | grep -E "dotfiles.*via ultron" >/dev/null; then
        _pass "consensus block names the host with freshest fetch"
    else
        _fail "consensus block didn't pick ultron" "$out"
    fi
}

test_detail_tailscale_consensus_block() {
    local sync="$TESTROOT/sync-tsconsensus"
    _stage_fixtures "$sync" "ultron-fresh.json" "mac-peers.json" "crc-offline.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status --detail crc)
    if echo "$out" | grep -q "consensus from OTHER hosts NOW about crc" \
       && echo "$out" | grep -qE "per ultron:.*offline" \
       && echo "$out" | grep -qE "per mac:.*offline" \
       && echo "$out" | grep -q "all peers report crc offline"; then
        _pass "--detail renders cross-host tailscale consensus (spec §6.3)"
    else
        _fail "--detail crc missing tailscale consensus block" "$out"
    fi
}

test_detail_consensus_skipped_for_single_host() {
    local sync="$TESTROOT/sync-single"
    _stage_fixtures "$sync" "ultron-fresh.json"
    local out; out=$(MESH_SYNC_DIR="$sync" _run_status --detail ultron)
    # With only one host in mesh, the §6.3 block must NOT render
    if ! echo "$out" | grep -q "consensus from OTHER hosts NOW"; then
        _pass "tailscale consensus block skipped silently when mesh has 1 host"
    else
        _fail "consensus block rendered when only target was in mesh" "$out"
    fi
}

test_no_snap_does_not_invoke_snap() {
    # Stage a sync dir with one host. With --no-snap, no new snapshot
    # should be created for the local hostname even if mesh-snap is
    # available — the file count must stay the same.
    local sync="$TESTROOT/sync-nosnap"
    _stage_fixtures "$sync" "ultron-fresh.json"
    local before after
    before=$(find "$sync" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
    MESH_SYNC_DIR="$sync" _run_status >/dev/null
    after=$(find "$sync" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
    if [[ "$before" == "$after" ]]; then
        _pass "--no-snap: sync dir file count unchanged before/after render"
    else
        _fail "--no-snap still triggered a write (before=$before after=$after)"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────
echo
echo "${C_DIM}── mesh-status viewer tests${C_RST}"
echo

test_help
test_unknown_arg
test_overview_three_hosts
test_overview_corrupt_snapshot_skipped
test_overview_empty_mesh
test_detail_existing_host
test_detail_nonexistent_host
test_detail_drift_section
test_json_aggregates_all
test_gc_removes_old_snapshot
test_overview_consensus_marks_winner
test_detail_tailscale_consensus_block
test_detail_consensus_skipped_for_single_host
test_no_snap_does_not_invoke_snap

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
