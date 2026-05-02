#!/usr/bin/env bash
# tests/mesh.test.sh — covers the unified `mesh` dispatcher.
#
# Replaces the old per-binary dispatch coverage that lived in
# auto-update.test.sh (bup/dotup wrappers) — those binaries are gone in
# the mesh-CLI refactor; their job is now `mesh update bootstrap` /
# `mesh update dotfiles`.
#
# Strategy: stub each companion (lib/mesh-status, lib/mesh-snap,
# auto-update.sh) inside a temp $MESH_HOME so we can observe what args
# the dispatcher passes through. Asserts cover:
#   - help / version flags
#   - subcommand routing (status, snap, update)
#   - positional drill-down for status (alias → --detail)
#   - flag passthrough
#   - top-level flag fallback (mesh --json → status --json)
#   - unknown subcommand fails
#   - update repo aliasing (bootstrap → dev-bootstrap)
#   - update without repo runs both
#   - update with --full forwards the flag
#   - missing companion → exit 1 with actionable error
#
# Bash 3.2 compatible.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MESH="$ROOT/scripts/mesh"

[[ -x "$MESH" ]] || { echo "mesh not executable at $MESH" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

TESTROOT=$(mktemp -d /tmp/mesh-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

# Build a stub MESH_HOME with companions that echo their args.
_make_stub_mesh_home() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/lib"
    cat > "$dir/lib/mesh-status" <<'EOF'
#!/usr/bin/env bash
echo "STATUS-LIB: $*"
EOF
    cat > "$dir/lib/mesh-snap" <<'EOF'
#!/usr/bin/env bash
echo "SNAP-LIB: $*"
EOF
    cat > "$dir/auto-update.sh" <<'EOF'
#!/usr/bin/env bash
echo "MOTOR: $*"
EOF
    chmod +x "$dir/lib/mesh-status" "$dir/lib/mesh-snap" "$dir/auto-update.sh"
}

_run() {
    MESH_HOME="$STUB" bash "$MESH" "$@" 2>&1
}

STUB="$TESTROOT/stub"
_make_stub_mesh_home "$STUB"

echo
echo "── mesh dispatcher tests"
echo

# ─── Help / version ────────────────────────────────────────────────

test_help() {
    local out; out=$(bash "$MESH" --help 2>&1)
    if echo "$out" | grep -q "Mesh CLI" && echo "$out" | grep -q "mesh status" && echo "$out" | grep -q "mesh update"; then
        _pass "--help renders Mesh CLI usage"
    else
        _fail "--help output missing canonical entries" "$out"
    fi
}

test_help_short_flag() {
    local out_long out_short
    out_long=$(bash "$MESH" --help 2>&1)
    out_short=$(bash "$MESH" -h 2>&1)
    if [[ "$out_long" == "$out_short" ]]; then
        _pass "-h identical to --help"
    else
        _fail "-h differs from --help"
    fi
}

test_version() {
    local out; out=$(bash "$MESH" --version 2>&1)
    if echo "$out" | grep -qE "mesh CLI v[0-9]"; then
        _pass "--version emits version string"
    else
        _fail "--version output unexpected" "$out"
    fi
}

# ─── Bare invocation defaults to status ────────────────────────────

test_bare_runs_status() {
    local out; out=$(_run)
    if echo "$out" | grep -q "STATUS-LIB:"; then
        _pass "bare \`mesh\` invokes lib/mesh-status"
    else
        _fail "bare mesh did not route to status" "$out"
    fi
}

# ─── Status subcommand ─────────────────────────────────────────────

test_status_no_args() {
    local out; out=$(_run status)
    if echo "$out" | grep -q "STATUS-LIB: $"; then
        _pass "mesh status (no args) → lib/mesh-status with no args"
    else
        _fail "status (no args) routing wrong" "$out"
    fi
}

test_status_positional_alias() {
    local out; out=$(_run status crc)
    if echo "$out" | grep -q "STATUS-LIB: --detail crc"; then
        _pass "mesh status crc → lib/mesh-status --detail crc"
    else
        _fail "positional alias did not become --detail" "$out"
    fi
}

test_status_flag_passthrough() {
    local out; out=$(_run status --json)
    if echo "$out" | grep -q "STATUS-LIB: --json"; then
        _pass "mesh status --json → flag forwarded"
    else
        _fail "flag passthrough wrong" "$out"
    fi
}

test_status_positional_with_flag() {
    local out; out=$(_run status crc --no-snap)
    if echo "$out" | grep -q "STATUS-LIB: --detail crc --no-snap"; then
        _pass "mesh status crc --no-snap → --detail crc + flag preserved"
    else
        _fail "mixed positional + flag wrong" "$out"
    fi
}

test_top_level_flag_falls_to_status() {
    local out; out=$(_run --json)
    if echo "$out" | grep -q "STATUS-LIB: --json"; then
        _pass "mesh --json (top-level flag) → status --json"
    else
        _fail "top-level flag fallback failed" "$out"
    fi
}

# ─── Snap subcommand ───────────────────────────────────────────────

test_snap_passthrough() {
    local out; out=$(_run snap --json --no-history)
    if echo "$out" | grep -q "SNAP-LIB: --json --no-history"; then
        _pass "mesh snap → lib/mesh-snap with all args forwarded"
    else
        _fail "snap passthrough wrong" "$out"
    fi
}

# ─── Update subcommand ─────────────────────────────────────────────

test_update_no_repo_runs_both() {
    local out; out=$(_run update)
    local lines; lines=$(echo "$out" | grep -c "MOTOR:")
    if (( lines == 2 )) && \
       echo "$out" | grep -q "MOTOR: --repo dev-bootstrap" && \
       echo "$out" | grep -q "MOTOR: --repo dotfiles"; then
        _pass "mesh update (no repo) runs motor twice (dev-bootstrap + dotfiles)"
    else
        _fail "update without repo did not run both" "$out"
    fi
}

test_update_bootstrap_alias() {
    local out; out=$(_run update bootstrap)
    if echo "$out" | grep -q "MOTOR: --repo dev-bootstrap" && ! echo "$out" | grep -q "MOTOR: --repo dotfiles"; then
        _pass "mesh update bootstrap → motor --repo dev-bootstrap (alias works, single-repo)"
    else
        _fail "bootstrap alias dispatch wrong" "$out"
    fi
}

test_update_dev_bootstrap_literal() {
    local out; out=$(_run update dev-bootstrap)
    if echo "$out" | grep -q "MOTOR: --repo dev-bootstrap"; then
        _pass "mesh update dev-bootstrap (literal name) accepted"
    else
        _fail "literal dev-bootstrap not accepted" "$out"
    fi
}

test_update_dotfiles() {
    local out; out=$(_run update dotfiles --full)
    if echo "$out" | grep -q "MOTOR: --repo dotfiles --full"; then
        _pass "mesh update dotfiles --full → motor with both args forwarded"
    else
        _fail "dotfiles + --full dispatch wrong" "$out"
    fi
}

test_update_unknown_repo_fails() {
    local out rc
    out=$(_run update tmpl 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "unknown arg"; then
        _pass "mesh update <unknown-repo> exits non-zero with error"
    else
        _fail "update with unknown repo did not fail loud (rc=$rc)" "$out"
    fi
}

# ─── Unknown subcommand ────────────────────────────────────────────

test_unknown_subcommand_fails() {
    local out rc
    out=$(_run garbage 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "unknown subcommand"; then
        _pass "mesh garbage → exit non-zero with error message"
    else
        _fail "unknown subcommand did not fail loud (rc=$rc)" "$out"
    fi
}

# ─── Companion missing ─────────────────────────────────────────────

test_missing_companion_fails_loud() {
    # All 3 tiers must miss for the dispatcher to error. Copy `mesh` to an
    # isolated temp dir so HERE (tier 2) won't see lib/ next to it. Pair with
    # empty MESH_HOME (tier 1) and fake HOME (tier 3).
    local iso_dir; iso_dir=$(mktemp -d "$TESTROOT/missing-co.XXXX")
    cp "$MESH" "$iso_dir/mesh"
    chmod +x "$iso_dir/mesh"
    local empty_home="$TESTROOT/empty-mesh-home"
    local fake_home="$TESTROOT/fake-home"
    mkdir -p "$empty_home" "$fake_home"

    local out rc
    out=$(MESH_HOME="$empty_home" HOME="$fake_home" bash "$iso_dir/mesh" status 2>&1); rc=$?
    if (( rc == 1 )) && echo "$out" | grep -q "lib/mesh-status not found"; then
        _pass "missing companion → exit 1 with actionable error"
    else
        _fail "missing companion did not fail loud (rc=$rc)" "$out"
    fi
}

# ─── Run all ───────────────────────────────────────────────────────

test_help
test_help_short_flag
test_version
test_bare_runs_status
test_status_no_args
test_status_positional_alias
test_status_flag_passthrough
test_status_positional_with_flag
test_top_level_flag_falls_to_status
test_snap_passthrough
test_update_no_repo_runs_both
test_update_bootstrap_alias
test_update_dev_bootstrap_literal
test_update_dotfiles
test_update_unknown_repo_fails
test_unknown_subcommand_fails
test_missing_companion_fails_loud

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
