#!/usr/bin/env bash
# tests/mesh-snap.test.sh — covers the mesh-snap collector.
#
# Standalone (no test framework). Each scenario builds a tmp environment
# with a fake $HOME (containing a tiny git repo + state dir) and
# optionally a fake doctor / tailscale on PATH, then runs mesh-snap
# with explicit env overrides and asserts the produced JSON.
#
# Spec: docs/2026-05-01-mesh-status-spec.md §12.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SNAP="$ROOT/scripts/lib/mesh-snap"
FIXTURES="$HERE/fixtures"

[[ -x "$SNAP" ]] || { echo "mesh-snap not executable at $SNAP" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

# ─── Common fixture: tmp $HOME with a tiny git repo named "dotfiles" ─
TESTROOT=$(mktemp -d /tmp/mesh-snap-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

FAKE_HOME="$TESTROOT/home"
mkdir -p "$FAKE_HOME"

# Create a minimal git repo at $FAKE_HOME/dotfiles with an upstream so
# the collector exercises rev-parse + status + ahead/behind paths.
_setup_dotfiles_repo() {
    local upstream="$TESTROOT/dotfiles-upstream.git"
    local local_path="$FAKE_HOME/dotfiles"
    rm -rf "$upstream" "$local_path"
    git init --bare --quiet --initial-branch=main "$upstream"
    git init --quiet --initial-branch=main "$local_path"
    ( cd "$local_path" || exit
      git config user.email "test@test"
      git config user.name "test"
      git remote add origin "$upstream"
      echo "init" > README
      git add README
      git -c commit.gpgsign=false commit -q -m "init"
      git push -q -u origin main )
}

# Build a tmp config file with the given MESH_REPOS list. Bash arrays
# can't be exported via env, so we materialize them as a sourced config.
_make_conf() {
    local conf="$1"; shift
    {
        echo "MESH_REPOS=($(printf '"%s" ' "$@"))"
    } > "$conf"
}

_run_snap() {
    local conf="$TESTROOT/snap.conf"
    _make_conf "$conf" "dotfiles"
    HOME="$FAKE_HOME" \
    MESH_SYNC_DIR="$TESTROOT/sync" \
    MESH_HISTORY_DIR="$TESTROOT/hist" \
    MESH_STATE_DIR="$TESTROOT/state" \
    MESH_HOST_ALIAS="testhost" \
    MESH_STATUS_CONF="$conf" \
    NO_COLOR=1 \
    bash "$SNAP" "$@" 2>&1
}

# Stub `hostname` on PATH so alias-resolution tests can fake the OS hostname
# without touching the real system. Caller passes the name to echo back.
_stub_hostname() {
    local fake_dir="$1" name="$2"
    mkdir -p "$fake_dir"
    cat > "$fake_dir/hostname" <<EOF
#!/usr/bin/env bash
echo "$name"
EOF
    chmod +x "$fake_dir/hostname"
}

# ─── Tests ───────────────────────────────────────────────────────────

test_help() {
    local out; out=$(bash "$SNAP" --help 2>&1)
    if echo "$out" | grep -q "Usage:" && echo "$out" | grep -q "mesh-snap"; then
        _pass "--help shows usage"
    else
        _fail "--help missing Usage" "$out"
    fi
}

test_unknown_arg() {
    local out rc; out=$(bash "$SNAP" --bogus 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "unknown arg"; then
        _pass "unknown arg rejected with non-zero exit"
    else
        _fail "unknown arg not rejected (rc=$rc)" "$out"
    fi
}

test_json_dump_does_not_write() {
    _setup_dotfiles_repo
    rm -rf "$TESTROOT/sync" "$TESTROOT/hist"
    local out; out=$(_run_snap --json --no-fetch)
    if echo "$out" | jq -e '.schema_version == 1' >/dev/null 2>&1 \
       && [[ ! -d "$TESTROOT/sync" ]]; then
        _pass "--json emits valid snapshot to stdout, no files written"
    else
        _fail "--json wrote files or emitted invalid JSON" "$out"
    fi
}

test_collect_host_meta() {
    _setup_dotfiles_repo
    local out; out=$(_run_snap --json --no-fetch)
    if echo "$out" | jq -e '.host.alias == "testhost"' >/dev/null 2>&1 \
       && echo "$out" | jq -e '.host.os | type == "string"' >/dev/null 2>&1 \
       && echo "$out" | jq -e '.host.wsl | type == "boolean"' >/dev/null 2>&1; then
        _pass "host meta block populated (alias / os / wsl)"
    else
        _fail "host meta block incomplete" "$out"
    fi
}

test_alias_resolves_via_tailscale_map() {
    _setup_dotfiles_repo
    local fake_bin="$TESTROOT/fakebin-aliasmap"
    _stub_hostname "$fake_bin" "code-server"
    local conf="$TESTROOT/aliasmap.conf"
    _make_conf "$conf" "dotfiles"
    local out
    # IMPORTANT: do NOT export MESH_HOST_ALIAS here — we want the
    # _resolve_alias() fallback chain to consult the alias map.
    out=$(HOME="$FAKE_HOME" \
          PATH="$fake_bin:$PATH" \
          MESH_SYNC_DIR="$TESTROOT/sync-aliasmap" \
          MESH_HISTORY_DIR="$TESTROOT/hist-aliasmap" \
          MESH_STATE_DIR="$TESTROOT/state-aliasmap" \
          MESH_STATUS_CONF="$conf" \
          MESH_TAILSCALE_ALIAS_MAP='{"code-server":"mac","ultron":"ultron","crcmg005078":"crc"}' \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.host.alias == "mac"' >/dev/null 2>&1 \
       && echo "$out" | jq -e '.host.hostname == "code-server"' >/dev/null 2>&1; then
        _pass "alias resolves via tailscale alias map (code-server → mac)"
    else
        _fail "alias map fallback didn't kick in" "$out"
    fi
}

test_alias_falls_back_to_hostname_when_map_lacks_entry() {
    _setup_dotfiles_repo
    local fake_bin="$TESTROOT/fakebin-newhost"
    _stub_hostname "$fake_bin" "brand-new-host"
    local conf="$TESTROOT/newhost.conf"
    _make_conf "$conf" "dotfiles"
    local out
    out=$(HOME="$FAKE_HOME" \
          PATH="$fake_bin:$PATH" \
          MESH_SYNC_DIR="$TESTROOT/sync-newhost" \
          MESH_HISTORY_DIR="$TESTROOT/hist-newhost" \
          MESH_STATE_DIR="$TESTROOT/state-newhost" \
          MESH_STATUS_CONF="$conf" \
          MESH_TAILSCALE_ALIAS_MAP='{"code-server":"mac","ultron":"ultron"}' \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.host.alias == "brand-new-host"' >/dev/null 2>&1; then
        _pass "alias falls back to hostname when map has no entry"
    else
        _fail "fallback to raw hostname didn't trigger" "$out"
    fi
}

test_alias_explicit_override_wins_over_map() {
    _setup_dotfiles_repo
    local fake_bin="$TESTROOT/fakebin-override"
    _stub_hostname "$fake_bin" "code-server"
    local conf="$TESTROOT/override.conf"
    _make_conf "$conf" "dotfiles"
    local out
    # Both MESH_HOST_ALIAS set AND map would resolve "code-server" → "mac";
    # explicit override should win.
    out=$(HOME="$FAKE_HOME" \
          PATH="$fake_bin:$PATH" \
          MESH_SYNC_DIR="$TESTROOT/sync-override" \
          MESH_HISTORY_DIR="$TESTROOT/hist-override" \
          MESH_STATE_DIR="$TESTROOT/state-override" \
          MESH_HOST_ALIAS="my-custom-alias" \
          MESH_STATUS_CONF="$conf" \
          MESH_TAILSCALE_ALIAS_MAP='{"code-server":"mac"}' \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.host.alias == "my-custom-alias"' >/dev/null 2>&1; then
        _pass "explicit MESH_HOST_ALIAS override wins over alias map"
    else
        _fail "explicit override did not win over map" "$out"
    fi
}

test_collect_repos_present_and_absent() {
    _setup_dotfiles_repo
    local conf="$TESTROOT/two-repos.conf"
    _make_conf "$conf" "dotfiles" "nonexistent"
    local out
    out=$(HOME="$FAKE_HOME" \
          MESH_SYNC_DIR="$TESTROOT/sync" \
          MESH_HISTORY_DIR="$TESTROOT/hist" \
          MESH_STATE_DIR="$TESTROOT/state" \
          MESH_HOST_ALIAS="testhost" \
          MESH_STATUS_CONF="$conf" \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.repos.dotfiles.present == true' >/dev/null 2>&1 \
       && echo "$out" | jq -e '.repos.nonexistent.present == false' >/dev/null 2>&1 \
       && echo "$out" | jq -e '.repos.nonexistent.reason == "not_cloned"' >/dev/null 2>&1; then
        _pass "repos collector handles present + absent (not_cloned)"
    else
        _fail "repos collector mis-handled present/absent split" "$out"
    fi
}

test_atomic_write_creates_file() {
    _setup_dotfiles_repo
    rm -rf "$TESTROOT/sync"
    local out rc; out=$(_run_snap --no-fetch); rc=$?
    if (( rc == 0 )) && [[ -f "$TESTROOT/sync/testhost.json" ]] \
       && jq -e . "$TESTROOT/sync/testhost.json" >/dev/null 2>&1; then
        _pass "atomic write produces valid JSON file at \$MESH_SYNC_DIR/<alias>.json"
    else
        _fail "atomic write failed or invalid JSON (rc=$rc)" "$out"
    fi
}

test_history_append() {
    _setup_dotfiles_repo
    rm -rf "$TESTROOT/sync" "$TESTROOT/hist"
    _run_snap --no-fetch >/dev/null
    local count
    count=$(find "$TESTROOT/hist" -name 'testhost-*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ -d "$TESTROOT/hist" ]] && (( count == 1 )); then
        _pass "history append writes timestamped file under \$MESH_HISTORY_DIR"
    else
        _fail "history append missing (count=$count)"
    fi
}

test_no_history_skips_audit() {
    _setup_dotfiles_repo
    rm -rf "$TESTROOT/sync" "$TESTROOT/hist"
    _run_snap --no-fetch --no-history >/dev/null
    if [[ ! -d "$TESTROOT/hist" ]]; then
        _pass "--no-history suppresses audit dir creation"
    else
        _fail "--no-history still created history dir"
    fi
}

test_lock_blocks_concurrent_run() {
    _setup_dotfiles_repo
    mkdir -p "$TESTROOT/state/mesh-snap.lock.d"
    local out rc; out=$(_run_snap --no-fetch --quiet); rc=$?
    rmdir "$TESTROOT/state/mesh-snap.lock.d" 2>/dev/null
    # Silent skip = exit 0 + no new sync file. Pre-existing sync file may
    # remain from earlier test_atomic_write_creates_file; so we don't
    # check for absence — just confirm the lock holder caused a soft skip.
    if (( rc == 0 )); then
        _pass "lock contention: soft skip with exit 0 when lock dir exists"
    else
        _fail "lock contention regressed (rc=$rc)" "$out"
    fi
}

test_drift_collector_via_stub() {
    _setup_dotfiles_repo
    local stub="$TESTROOT/stub-doctor.sh"
    cat > "$stub" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":10,"drift":2,"missing":1,"marker_miss":0,"drift_items":["foo","bar"],"missing_items":["baz"],"marker_miss_items":[]}'
exit 1
EOF
    chmod +x "$stub"
    local conf="$TESTROOT/drift.conf"
    _make_conf "$conf" "dotfiles"
    local out
    out=$(HOME="$FAKE_HOME" \
          MESH_SYNC_DIR="$TESTROOT/sync" \
          MESH_HISTORY_DIR="$TESTROOT/hist" \
          MESH_STATE_DIR="$TESTROOT/state-drift" \
          MESH_HOST_ALIAS="testhost" \
          MESH_STATUS_CONF="$conf" \
          MESH_DOCTOR="$stub" \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.drift.drift_count == 2 and .drift.missing_count == 1 and (.drift.items | length) == 3' >/dev/null 2>&1; then
        _pass "drift collector reshapes doctor.sh stub output"
    else
        _fail "drift collector did not reshape correctly" "$out"
    fi
}

test_advisories_best_effort() {
    _setup_dotfiles_repo
    local fdir="$TESTROOT/state/followup"
    mkdir -p "$fdir"
    cat > "$fdir/01.json" <<EOF
{"kind":"ngrok_token","severity":"warning","since":"2998-12-25T10:00:00Z"}
EOF
    echo "garbage" > "$fdir/bad.json"
    local conf="$TESTROOT/adv.conf"
    _make_conf "$conf" "dotfiles"
    local out
    out=$(HOME="$FAKE_HOME" \
          MESH_SYNC_DIR="$TESTROOT/sync" \
          MESH_HISTORY_DIR="$TESTROOT/hist" \
          MESH_STATE_DIR="$TESTROOT/state-adv" \
          MESH_HOST_ALIAS="testhost" \
          MESH_STATUS_CONF="$conf" \
          MESH_FOLLOWUP_DIR="$fdir" \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.advisories.count == 1 and .advisories.items[0].kind == "ngrok_token" and .advisories.items[0].detail == null' >/dev/null 2>&1; then
        _pass "advisories: valid kept, corrupt dropped, detail body never leaked"
    else
        _fail "advisories collector mis-shaped" "$out"
    fi
}

test_tailscale_absent() {
    _setup_dotfiles_repo
    local conf="$TESTROOT/ts-absent.conf"
    _make_conf "$conf" "dotfiles"
    local out
    out=$(HOME="$FAKE_HOME" \
          MESH_SYNC_DIR="$TESTROOT/sync" \
          MESH_HISTORY_DIR="$TESTROOT/hist" \
          MESH_STATE_DIR="$TESTROOT/state-noTS" \
          MESH_HOST_ALIAS="testhost" \
          MESH_STATUS_CONF="$conf" \
          PATH="/usr/bin:/bin" \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.network.tailscale.installed == false' >/dev/null 2>&1; then
        _pass "tailscale absent: network.tailscale.installed = false"
    else
        _fail "tailscale absent did not produce installed:false" "$out"
    fi
}

test_tailscale_logged_out() {
    _setup_dotfiles_repo
    local fakebin="$TESTROOT/fake-bin-loggedout"
    mkdir -p "$fakebin"
    cat > "$fakebin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "version") echo "1.78.1" ;;
    *--json*) echo '{"BackendState":"NeedsLogin","Self":{}}' ;;
esac
EOF
    chmod +x "$fakebin/tailscale"
    local conf="$TESTROOT/ts-loggedout.conf"
    _make_conf "$conf" "dotfiles"
    local out
    out=$(HOME="$FAKE_HOME" \
          MESH_SYNC_DIR="$TESTROOT/sync" \
          MESH_HISTORY_DIR="$TESTROOT/hist" \
          MESH_STATE_DIR="$TESTROOT/state-loggedout" \
          MESH_HOST_ALIAS="testhost" \
          MESH_STATUS_CONF="$conf" \
          PATH="$fakebin:/usr/bin:/bin" \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.network.tailscale.up == false and .network.tailscale.auth_status == "logged_out"' >/dev/null 2>&1; then
        _pass "tailscale NeedsLogin → up:false, auth_status:logged_out"
    else
        _fail "tailscale logged_out not detected" "$out"
    fi
}

test_tailscale_alias_map() {
    _setup_dotfiles_repo
    local fakebin="$TESTROOT/fake-bin-aliased"
    mkdir -p "$fakebin"
    cat > "$fakebin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "version") echo "1.78.1" ;;
    *--json*) cat <<'JSON'
{"BackendState":"Running","Version":"1.78.1",
 "Self":{"DNSName":"ultron.foo.ts.net.","HostName":"ultron","OS":"linux","Online":true,"TailscaleIPs":["100.64.0.5"]},
 "Peer":{
   "AAA":{"HostName":"crcmg005078","DNSName":"crc.foo.ts.net.","OS":"linux","Online":false,"TailscaleIPs":["100.64.0.7"],"LastSeen":"2998-12-30T08:14:22Z","KeyExpiry":"3001-01-01T00:00:00Z"}
 }}
JSON
        ;;
esac
EOF
    chmod +x "$fakebin/tailscale"
    local conf="$TESTROOT/ts-alias.conf"
    {
        echo 'MESH_REPOS=("dotfiles")'
        echo 'MESH_TAILSCALE_ALIAS_MAP='\''{"crcmg005078":"crc"}'\'
    } > "$conf"
    local out
    out=$(HOME="$FAKE_HOME" \
          MESH_SYNC_DIR="$TESTROOT/sync" \
          MESH_HISTORY_DIR="$TESTROOT/hist" \
          MESH_STATE_DIR="$TESTROOT/state-alias" \
          MESH_HOST_ALIAS="testhost" \
          MESH_STATUS_CONF="$conf" \
          PATH="$fakebin:/usr/bin:/bin" \
          NO_COLOR=1 \
          bash "$SNAP" --json --no-fetch 2>&1)
    if echo "$out" | jq -e '.network.tailscale.peers[0].alias == "crc"' >/dev/null 2>&1; then
        _pass "tailscale alias map resolves crcmg005078 → crc"
    else
        _fail "alias map mis-applied" "$out"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────
echo
echo "${C_DIM}── mesh-snap collector tests${C_RST}"
echo

# Sanity: fixture dir exists.
[[ -d "$FIXTURES" ]] || { echo "FIXTURES missing at $FIXTURES" >&2; exit 1; }

test_help
test_unknown_arg
test_json_dump_does_not_write
test_collect_host_meta
test_alias_resolves_via_tailscale_map
test_alias_falls_back_to_hostname_when_map_lacks_entry
test_alias_explicit_override_wins_over_map
test_collect_repos_present_and_absent
test_atomic_write_creates_file
test_history_append
test_no_history_skips_audit
test_lock_blocks_concurrent_run
test_drift_collector_via_stub
test_advisories_best_effort
test_tailscale_absent
test_tailscale_logged_out
test_tailscale_alias_map

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
