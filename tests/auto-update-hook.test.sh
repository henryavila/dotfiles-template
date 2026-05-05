#!/usr/bin/env zsh
# shellcheck shell=bash
# (zsh-only at runtime — the bash directive above is just so shellcheck
# can parse the file. The non-bash bits we use, like `add-zsh-hook`,
# resolve at runtime under zsh and are invisible to the static checker.)
# tests/auto-update-hook.test.sh — covers the precmd-deferred hook in
# shell/auto-update.zsh.
#
# Standalone (no test framework). Spawns zsh with a stripped-down hook
# (interactive + tty guards bypassed via a wrapper file) and asserts:
#   1. Hook is registered into precmd_functions on source.
#   2. First simulated precmd cycle invokes the motor with --from-shell-start.
#   3. After first call, the hook is removed from precmd_functions and the
#      function is unfunction'd.
#
# This is the FIRST automated coverage of shell/auto-update.zsh — D38
# adversarial review flagged that someone could delete `add-zsh-hook -d`
# and the bash suite would stay green (because it exercises the bash motor
# only). This file closes that gap.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/shell/auto-update.zsh.example"

[[ -r "$HOOK" ]] || { echo "hook not readable at $HOOK" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

# Run a zsh probe that:
#   - Strips the interactive/tty guards from the hook (test runs non-tty).
#   - Replaces the motor invocation with a stub that records args.
#   - Sources the (modified) hook.
#   - Manually iterates `precmd_functions`, simulating the first prompt.
#   - Reports state before/after via stdout markers.
_probe() {
    local probe_dir; probe_dir=$(mktemp -d "/tmp/hook-probe.XXXXXX")
    local stub_motor="$probe_dir/auto-update.sh"
    local fake_dotfiles="$probe_dir/dotfiles/scripts"
    mkdir -p "$fake_dotfiles"
    # The hook hardcodes $HOME/dotfiles/scripts/auto-update.sh — we
    # symlink probe_dir to act as $HOME so the path resolves.
    ln -s "$stub_motor" "$fake_dotfiles/auto-update.sh"

    cat > "$stub_motor" <<EOF
#!/usr/bin/env bash
echo "MOTOR-CALLED-WITH: \$*" >> "$probe_dir/motor.log"
exit 0
EOF
    chmod +x "$stub_motor"

    # Strip tty/interactive guards so the hook proceeds in a non-tty zsh.
    # Also strip the in-function `-t 1 || -t 2` defensive check (production
    # bails out there to avoid running while P10K's fd-capture is active —
    # in the test we explicitly want the motor to be invoked).
    local hook_test="$probe_dir/auto-update-test.zsh"
    sed -e '/\[\[ -o interactive \]\]/d' \
        -e '/\/dev\/tty/d' \
        -e '/-t 1 || ! -t 2/,/^    fi$/d' \
        "$HOOK" > "$hook_test"

    HOME="$probe_dir" zsh -f <<EOF >>"$probe_dir/probe.out" 2>&1
unset AUTO_UPDATE_RECURSED
typeset -ga precmd_functions
. "$hook_test"
echo "BEFORE: precmd_functions=(\${precmd_functions[*]})"
echo "BEFORE: function_defined=\$(typeset -f _auto_update_first_precmd >/dev/null 2>&1 && echo yes || echo no)"
# Simulate first prompt cycle.
for f in \$precmd_functions; do
    "\$f" 2>/dev/null
done
echo "AFTER:  precmd_functions=(\${precmd_functions[*]})"
echo "AFTER:  function_defined=\$(typeset -f _auto_update_first_precmd >/dev/null 2>&1 && echo yes || echo no)"
# Simulate second prompt cycle to ensure no re-fire.
for f in \$precmd_functions; do
    "\$f" 2>/dev/null
done
EOF
    cat "$probe_dir/probe.out"
    echo "MOTOR_LOG_BEGIN"
    cat "$probe_dir/motor.log" 2>/dev/null || true
    echo "MOTOR_LOG_END"
    rm -rf "$probe_dir"
}

test_hook_registers_runs_once_then_self_removes() {
    local out; out=$(_probe)
    # Assertions:
    #   1. BEFORE: hook registered, function defined.
    #   2. AFTER:  hook NOT in precmd_functions, function undefined.
    #   3. Motor called exactly once with --from-shell-start.
    local motor_calls
    motor_calls=$(echo "$out" | grep -c "MOTOR-CALLED-WITH:" || true)
    if echo "$out" | grep -q "BEFORE: .*_auto_update_first_precmd" && \
       echo "$out" | grep -q "BEFORE: function_defined=yes" && \
       echo "$out" | grep -qE 'AFTER: +precmd_functions=\(\)' && \
       echo "$out" | grep -q "AFTER:  function_defined=no" && \
       echo "$out" | grep -q "MOTOR-CALLED-WITH: --from-shell-start" && \
       (( motor_calls == 1 )); then
        _pass "hook registers, fires once on first precmd, then self-removes"
    else
        _fail "hook lifecycle regression (motor_calls=$motor_calls)" "$out"
    fi
}

test_hook_recursion_guard_skips_when_flag_set() {
    # When AUTO_UPDATE_RECURSED=1, the hook short-circuits before
    # registration. Motor must NOT be called.
    local probe_dir; probe_dir=$(mktemp -d "/tmp/hook-recur.XXXXXX")
    local stub_motor="$probe_dir/auto-update.sh"
    mkdir -p "$probe_dir/dotfiles/scripts"
    ln -s "$stub_motor" "$probe_dir/dotfiles/scripts/auto-update.sh"
    cat > "$stub_motor" <<EOF
#!/usr/bin/env bash
echo "MOTOR-WAS-CALLED" >> "$probe_dir/motor.log"
EOF
    chmod +x "$stub_motor"
    local hook_test="$probe_dir/auto-update-test.zsh"
    sed -e '/\[\[ -o interactive \]\]/d' \
        -e '/\/dev\/tty/d' \
        "$HOOK" > "$hook_test"

    HOME="$probe_dir" AUTO_UPDATE_RECURSED=1 zsh -f -c "
        typeset -ga precmd_functions
        . '$hook_test'
        echo \"precmd_count=\${#precmd_functions[@]}\"
        echo \"recursed_after=\${AUTO_UPDATE_RECURSED:-unset}\"
    " > "$probe_dir/probe.out" 2>&1

    local out; out=$(cat "$probe_dir/probe.out")
    local motor_log; motor_log=$(cat "$probe_dir/motor.log" 2>/dev/null || true)
    rm -rf "$probe_dir"

    if echo "$out" | grep -q "precmd_count=0" && \
       echo "$out" | grep -q "recursed_after=unset" && \
       [[ -z "$motor_log" ]]; then
        _pass "AUTO_UPDATE_RECURSED=1 short-circuits + clears flag, motor NOT called"
    else
        _fail "recursion guard regression" "$out|MOTOR=$motor_log"
    fi
}

# ─── Run ──────────────────────────────────────────────────────────
echo
echo "${C_DIM}── auto-update hook (zsh) tests${C_RST}"
echo

test_hook_registers_runs_once_then_self_removes
test_hook_recursion_guard_skips_when_flag_set

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
