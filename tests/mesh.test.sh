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
#   - subcommand routing (status, snap, update, run)
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
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_RST=""
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
echo "MOTOR-ENV: DEV_BOOTSTRAP_TMUX_AUTO_MAIN=${DEV_BOOTSTRAP_TMUX_AUTO_MAIN-unset}"
echo "MOTOR: $*"
EOF
    chmod +x "$dir/lib/mesh-status" "$dir/lib/mesh-snap" "$dir/auto-update.sh"
}

_run() {
    MESH_HOME="$STUB" bash "$MESH" "$@" 2>&1
}

_make_run_conf() {
    local path="$1"
    cat > "$path" <<'EOF'
MESH_RUN_HOSTS=("ultron=ultron-wsl" "mac=mac" "crc=crc")
MESH_TAILSCALE_ALIAS_MAP='{"ultron":"ultron","code-server":"mac","crcmg005078":"crc"}'
EOF
}

_make_ssh_stub() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
{
    printf 'SSH:'
    for arg in "$@"; do
        printf ' <%s>' "$arg"
    done
    printf '\n'
} >> "$MESH_TEST_SSH_LOG"
echo "SSH-STUB: $*"
EOF
    chmod +x "$path"
}

_make_fzf_stub() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
{
    printf 'FZF-ARGS:'
    for arg in "$@"; do
        printf ' <%s>' "$arg"
    done
    printf '\n'
} >> "$MESH_TEST_FZF_ARGS_LOG"
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$MESH_TEST_FZF_INPUT_LOG"
done
printf '%s\n' "$MESH_TEST_FZF_OUTPUT"
EOF
    chmod +x "$path"
}

_make_tailscale_stub() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
    cat <<'JSON'
{
  "Self": {
    "HostName": "Mac mini M4 de Henry",
    "DNSName": "code-server.bream-goldeye.ts.net."
  },
  "Peer": {
    "peer-ultron": {
      "Online": true,
      "HostName": "ULTRON",
      "DNSName": "ultron.bream-goldeye.ts.net."
    },
    "peer-crc": {
      "Online": false,
      "HostName": "CRCMG005078",
      "DNSName": "crcmg005078.bream-goldeye.ts.net."
    }
  }
}
JSON
    exit 0
fi
exit 1
EOF
    chmod +x "$path"
}

_run_run() {
    MESH_HOME="$STUB" \
    MESH_STATUS_CONF="$RUN_CONF" \
    MESH_RUN_SELF_ALIAS="${MESH_RUN_SELF_ALIAS-ultron}" \
    MESH_RUN_ONLINE_HOSTS="${MESH_RUN_ONLINE_HOSTS-ultron mac}" \
    MESH_RUN_SSH="$SSH_STUB" \
    MESH_RUN_SELECTOR="${MESH_RUN_SELECTOR:-}" \
    MESH_RUN_FZF="${MESH_RUN_FZF:-$FZF_STUB}" \
    MESH_TEST_SSH_LOG="$SSH_LOG" \
    MESH_TEST_FZF_OUTPUT="${MESH_TEST_FZF_OUTPUT:-}" \
    MESH_TEST_FZF_INPUT_LOG="$FZF_INPUT_LOG" \
    MESH_TEST_FZF_ARGS_LOG="$FZF_ARGS_LOG" \
    bash "$MESH" run "$@" 2>&1
}

_reset_run_state() {
    _make_run_conf "$RUN_CONF"
    : > "$SSH_LOG"
    : > "$FZF_INPUT_LOG"
    : > "$FZF_ARGS_LOG"
}

STUB="$TESTROOT/stub"
_make_stub_mesh_home "$STUB"
RUN_CONF="$TESTROOT/mesh-status.conf"
SSH_STUB="$TESTROOT/ssh-stub"
SSH_LOG="$TESTROOT/ssh.log"
FZF_STUB="$TESTROOT/fzf-stub"
FZF_INPUT_LOG="$TESTROOT/fzf-input.log"
FZF_ARGS_LOG="$TESTROOT/fzf-args.log"
TAILSCALE_STUB_DIR="$TESTROOT/tailscale-bin"
mkdir -p "$TAILSCALE_STUB_DIR"
_make_run_conf "$RUN_CONF"
_make_ssh_stub "$SSH_STUB"
_make_fzf_stub "$FZF_STUB"
_make_tailscale_stub "$TAILSCALE_STUB_DIR/tailscale"
: > "$SSH_LOG"
: > "$FZF_INPUT_LOG"
: > "$FZF_ARGS_LOG"

echo
echo "── mesh dispatcher tests"
echo

# ─── Help / version ────────────────────────────────────────────────

test_help() {
    local out; out=$(bash "$MESH" --help 2>&1)
    if echo "$out" | grep -q "Mesh CLI" && echo "$out" | grep -q "mesh status" && echo "$out" | grep -q "mesh update" && echo "$out" | grep -q "mesh run"; then
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

test_update_no_only_runs_both() {
    local out; out=$(_run update)
    local lines; lines=$(echo "$out" | grep -c "MOTOR:")
    if (( lines == 2 )) && \
       echo "$out" | grep -q "MOTOR: --only dev-bootstrap" && \
       echo "$out" | grep -q "MOTOR: --only dotfiles"; then
        _pass "mesh update (no -o) runs motor twice (dev-bootstrap + dotfiles)"
    else
        _fail "update without -o did not run both" "$out"
    fi
}

test_update_help_runs_motor_help_once() {
    local out; out=$(_run update --help)
    local lines; lines=$(echo "$out" | grep -c "MOTOR:")
    if (( lines == 1 )) && echo "$out" | grep -q "MOTOR: --help"; then
        _pass "mesh update --help delegates to motor help once"
    else
        _fail "update --help should not run both repos" "$out"
    fi
}

test_update_only_long_form() {
    local out; out=$(_run update --only dev-bootstrap)
    if echo "$out" | grep -q "MOTOR-ENV: DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0" \
       && echo "$out" | grep -q "MOTOR: --only dev-bootstrap" \
       && ! echo "$out" | grep -q "MOTOR: --only dotfiles"; then
        _pass "mesh update --only dev-bootstrap → motor --only dev-bootstrap (single-repo)"
    else
        _fail "--only long form dispatch wrong" "$out"
    fi
}

test_update_only_short_form() {
    local out; out=$(_run update -o dev-bootstrap)
    if echo "$out" | grep -q "MOTOR: --only dev-bootstrap" && ! echo "$out" | grep -q "MOTOR: --only dotfiles"; then
        _pass "mesh update -o dev-bootstrap (short form) is equivalent to --only"
    else
        _fail "-o short form dispatch wrong" "$out"
    fi
}

test_update_bootstrap_brevity_alias() {
    # `bootstrap` is accepted as a brevity alias for `dev-bootstrap`. The
    # dispatcher translates it to the canonical name before forwarding,
    # so the motor never sees the alias.
    local out; out=$(_run update -o bootstrap)
    if echo "$out" | grep -q "MOTOR: --only dev-bootstrap" && ! echo "$out" | grep -q "MOTOR: --only bootstrap\b"; then
        _pass "-o bootstrap → motor --only dev-bootstrap (brevity alias translated)"
    else
        _fail "bootstrap brevity alias not translated" "$out"
    fi
}

test_update_dotfiles_with_full_short() {
    # -f/--full is forwarded as --full, -i/--interactive as --interactive.
    # Both short forms exercised here in one go to keep the test focused.
    local out; out=$(_run update -o dotfiles -f)
    if echo "$out" | grep -q "MOTOR: --only dotfiles --full"; then
        _pass "-o dotfiles -f → motor --only dotfiles --full"
    else
        _fail "dotfiles + -f dispatch wrong" "$out"
    fi
}

test_update_full_and_interactive_forwarded() {
    local out; out=$(_run update -o bootstrap -f -i)
    if echo "$out" | grep -q "MOTOR: --only dev-bootstrap --full --interactive"; then
        _pass "-f and -i both forwarded to motor as --full --interactive"
    else
        _fail "full+interactive dispatch wrong" "$out"
    fi
}

test_update_no_only_full_interactive_runs_both_with_flags() {
    local out; out=$(_run update -f -i)
    local lines; lines=$(echo "$out" | grep -c "MOTOR:")
    if (( lines == 2 )) \
       && echo "$out" | grep -q "MOTOR: --only dev-bootstrap --full --interactive" \
       && echo "$out" | grep -q "MOTOR: --only dotfiles --full --interactive"; then
        _pass "mesh update -f -i runs both repos and preserves --interactive"
    else
        _fail "mesh update -f -i did not preserve flags for both repos" "$out"
    fi
}

test_update_only_requires_value() {
    # `-o --full` would otherwise consume --full as the repo name.
    local out rc
    out=$(_run update -o --full 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "requires a repo name"; then
        _pass "-o rejects flag-like value (--full)"
    else
        _fail "-o --full not rejected (rc=$rc)" "$out"
    fi
}

test_update_unknown_arg_fails() {
    # Positional `bootstrap` was removed in the redesign — anything that
    # isn't a known flag (`-o`/`--only`/`-f`/`--full`/`-i`/`--interactive`/
    # passthrough flag) is rejected. Catches typos like
    # `mesh update boostrap` (missing `t`).
    local out rc
    out=$(_run update boostrap 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "unknown arg"; then
        _pass "mesh update <typo> exits non-zero with error"
    else
        _fail "unknown arg did not fail loud (rc=$rc)" "$out"
    fi
}

# ─── Run subcommand ────────────────────────────────────────────────

test_run_hosts_automation_uses_ssh_only_for_remotes() {
    _reset_run_state

    local out log
    out=$(_run_run --hosts mac,crc update -f)
    log=$(cat "$SSH_LOG")

    if ! echo "$out" | grep -q "MOTOR:" \
       && echo "$log" | grep -q "SSH: <-tt> <mac>" \
       && echo "$log" | grep -q "SSH: <-tt> <crc>" \
       && echo "$log" | grep -q "DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0; export DEV_BOOTSTRAP_TMUX_AUTO_MAIN;" \
       && echo "$log" | grep -q "mesh update -f"; then
        _pass "mesh run --hosts mac,crc update -f runs remotes over ssh"
    else
        _fail "mesh run --hosts did not route remotes correctly" "out=[$out] log=[$log]"
    fi
}

test_run_hosts_includes_local_without_ssh() {
    _reset_run_state

    local out log ssh_lines
    out=$(_run_run --hosts ultron,mac update -f)
    log=$(cat "$SSH_LOG")
    ssh_lines=$(echo "$log" | grep -c "^SSH:")

    if echo "$out" | grep -q "MOTOR: --only dev-bootstrap --full" \
       && echo "$out" | grep -q "MOTOR: --only dotfiles --full" \
       && echo "$out" | grep -q "MOTOR-ENV: DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0" \
       && (( ssh_lines == 1 )) \
       && echo "$log" | grep -q "SSH: <-tt> <mac>"; then
        _pass "mesh run executes the selected self alias locally"
    else
        _fail "mesh run did not separate local and remote execution" "out=[$out] log=[$log]"
    fi
}

test_run_default_selector_uses_online_hosts() {
    _reset_run_state

    local out log
    out=$(printf '\n' | \
        MESH_HOME="$STUB" \
        MESH_STATUS_CONF="$RUN_CONF" \
        MESH_RUN_SELF_ALIAS="ultron" \
        MESH_RUN_ONLINE_HOSTS="ultron mac" \
        MESH_RUN_SELECTOR="text" \
        MESH_RUN_SSH="$SSH_STUB" \
        MESH_TEST_SSH_LOG="$SSH_LOG" \
        bash "$MESH" run update -f 2>&1)
    log=$(cat "$SSH_LOG")

    if echo "$out" | grep -q "MOTOR: --only dev-bootstrap --full" \
       && echo "$out" | grep -q "MOTOR: --only dotfiles --full" \
       && echo "$log" | grep -q "SSH: <-tt> <mac>" \
       && ! echo "$log" | grep -q "SSH: <-tt> <crc>"; then
        _pass "mesh run default selector preselects online hosts"
    else
        _fail "mesh run default selector did not use online defaults" "out=[$out] log=[$log]"
    fi
}

test_run_fzf_selector_allows_dynamic_multi_select() {
    _reset_run_state

    local out log fzf_input fzf_args
    out=$(MESH_RUN_SELECTOR=fzf \
        MESH_TEST_FZF_OUTPUT=$'mac\tonline\t\tssh:mac\ncrc\toffline\t\tssh:crc' \
        _run_run update -f)
    log=$(cat "$SSH_LOG")
    fzf_input=$(cat "$FZF_INPUT_LOG")
    fzf_args=$(cat "$FZF_ARGS_LOG")

    if ! echo "$out" | grep -q "MOTOR:" \
       && echo "$log" | grep -q "SSH: <-tt> <mac>" \
       && echo "$log" | grep -q "SSH: <-tt> <crc>" \
       && ! echo "$log" | grep -q "SSH: <-tt> <ultron-wsl>" \
       && echo "$fzf_input" | grep -q $'^ultron\tonline' \
       && echo "$fzf_input" | grep -q $'^mac\tonline' \
       && echo "$fzf_input" | grep -q $'^crc\toffline' \
       && echo "$fzf_args" | grep -q "<--sync>" \
       && echo "$fzf_args" | grep -q "start:select+down+select+down+first"; then
        _pass "mesh run default selector uses fzf multi-select with online preselected"
    else
        _fail "mesh run fzf selector did not behave as a dynamic multi-select" "out=[$out] log=[$log] fzf_input=[$fzf_input] fzf_args=[$fzf_args]"
    fi
}

test_run_online_no_prompt() {
    _reset_run_state

    local out log
    out=$(_run_run --online snap --quiet)
    log=$(cat "$SSH_LOG")

    if echo "$out" | grep -q "SNAP-LIB: --quiet" \
       && echo "$log" | grep -q "SSH: <-tt> <mac>" \
       && echo "$log" | grep -q "mesh snap --quiet" \
       && ! echo "$log" | grep -q "SSH: <-tt> <crc>"; then
        _pass "mesh run --online executes online hosts without selector"
    else
        _fail "mesh run --online routing wrong" "out=[$out] log=[$log]"
    fi
}

test_run_online_resolves_self_from_tailscale_dnsname() {
    _reset_run_state

    local out log
    out=$(PATH="$TAILSCALE_STUB_DIR:$PATH" \
        MESH_RUN_SELF_ALIAS="" \
        MESH_RUN_ONLINE_HOSTS="" \
        _run_run --online update -f)
    log=$(cat "$SSH_LOG")

    if echo "$out" | grep -q "MOTOR: --only dev-bootstrap --full" \
       && echo "$out" | grep -q "MOTOR: --only dotfiles --full" \
       && echo "$log" | grep -q "SSH: <-tt> <ultron-wsl>" \
       && ! echo "$log" | grep -q "SSH: <-tt> <mac>" \
       && ! echo "$log" | grep -q "SSH: <-tt> <crc>"; then
        _pass "mesh run --online resolves local alias from Tailscale DNSName fallback"
    else
        _fail "mesh run --online did not resolve local alias from Tailscale DNSName" "out=[$out] log=[$log]"
    fi
}

test_run_dry_run_executes_nothing() {
    _reset_run_state

    local out log
    out=$(_run_run --dry-run --hosts mac update -f)
    log=$(cat "$SSH_LOG")

    if echo "$out" | grep -q "DRY-RUN: mac (ssh mac): mesh update -f" \
       && [[ -z "$log" ]] \
       && ! echo "$out" | grep -q "MOTOR:"; then
        _pass "mesh run --dry-run shows command and does not execute"
    else
        _fail "mesh run --dry-run executed or logged unexpected work" "out=[$out] log=[$log]"
    fi
}

test_run_rejects_interactive_update() {
    _reset_run_state

    local out rc log
    out=$(_run_run --hosts mac update -f -i 2>&1); rc=$?
    log=$(cat "$SSH_LOG")

    if (( rc != 0 )) \
       && echo "$out" | grep -q "interactive is not supported across hosts" \
       && [[ -z "$log" ]]; then
        _pass "mesh run update rejects -i/--interactive"
    else
        _fail "mesh run update -i was not rejected cleanly (rc=$rc)" "out=[$out] log=[$log]"
    fi
}

test_run_rejects_unknown_mesh_subcommand() {
    _reset_run_state

    local out rc
    out=$(_run_run --hosts mac garbage 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "unsupported mesh subcommand"; then
        _pass "mesh run rejects unsupported mesh subcommands"
    else
        _fail "mesh run accepted unsupported subcommand (rc=$rc)" "$out"
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
test_update_no_only_runs_both
test_update_help_runs_motor_help_once
test_update_only_long_form
test_update_only_short_form
test_update_bootstrap_brevity_alias
test_update_dotfiles_with_full_short
test_update_full_and_interactive_forwarded
test_update_no_only_full_interactive_runs_both_with_flags
test_update_only_requires_value
test_update_unknown_arg_fails
test_run_hosts_automation_uses_ssh_only_for_remotes
test_run_hosts_includes_local_without_ssh
test_run_default_selector_uses_online_hosts
test_run_fzf_selector_allows_dynamic_multi_select
test_run_online_no_prompt
test_run_online_resolves_self_from_tailscale_dnsname
test_run_dry_run_executes_nothing
test_run_rejects_interactive_update
test_run_rejects_unknown_mesh_subcommand
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
