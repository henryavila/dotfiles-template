#!/usr/bin/env bash
# tests/zsh-completions.test.sh - validates zsh completion metadata shipped by the template.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

echo
echo "-- zsh completion tests"
echo

if ! command -v zsh >/dev/null 2>&1; then
    echo "zsh not available; skipping"
    exit 0
fi

test_mesh_subcommands_have_descriptions() {
    local out rc
    out=$(ROOT="$ROOT" zsh -f 2>&1 <<'ZSH'
set -u
curcontext=""
words=(mesh '')
CURRENT=2
_arguments() {
    state=subcommand
    return 0
}
_describe() {
    local array_name="${@[-1]}"
    print -rl -- "${(@P)array_name}"
}
_files() { return 0 }
source "$ROOT/shell/completions/_mesh"
ZSH
)
    rc=$?
    if (( rc == 0 )) && \
       echo "$out" | grep -q "status:show cross-mesh status" && \
       echo "$out" | grep -q "update:pull and apply dotfiles ecosystem updates" && \
       echo "$out" | grep -q "run:run a mesh subcommand on selected hosts"; then
        _pass "_mesh exposes subcommands with descriptions"
    else
        _fail "_mesh subcommand descriptions missing (rc=$rc)" "$out"
    fi
}

test_mesh_run_subcommands_have_descriptions() {
    local out rc
    out=$(ROOT="$ROOT" zsh -f 2>&1 <<'ZSH'
set -u
curcontext=""
words=(mesh run '')
CURRENT=3
_arguments() {
    state=run_subcommand
    return 0
}
_describe() {
    local array_name="${@[-1]}"
    print -rl -- "${(@P)array_name}"
}
_files() { return 0 }
source "$ROOT/shell/completions/_mesh"
ZSH
)
    rc=$?
    if (( rc == 0 )) && \
       echo "$out" | grep -q "status:show cross-mesh status on selected hosts" && \
       echo "$out" | grep -q "update:pull and apply updates on selected hosts"; then
        _pass "_mesh exposes run subcommands with descriptions"
    else
        _fail "_mesh run subcommand descriptions missing (rc=$rc)" "$out"
    fi
}

test_mesh_completion_syntax() {
    local out rc
    out=$(zsh -n "$ROOT/shell/completions/_mesh" 2>&1); rc=$?
    if (( rc == 0 )); then
        _pass "_mesh syntax is valid zsh"
    else
        _fail "_mesh syntax check failed (rc=$rc)" "$out"
    fi
}

test_mesh_subcommands_have_descriptions
test_mesh_run_subcommands_have_descriptions
test_mesh_completion_syntax

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
