#!/usr/bin/env bash
# tests/repo-boundary.test.sh - guards responsibility split with dev-bootstrap.

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
echo "-- repository boundary tests"
echo

test_shell_completion_owned_by_bootstrap() {
    local completion_path="$ROOT/shell/completions/_mesh"

    if [[ -e "$completion_path" ]]; then
        _fail "mesh zsh completion is not shipped by dotfiles-template" "$completion_path exists"
        return
    fi

    _pass "mesh zsh completion is not shipped by dotfiles-template"
}

test_installer_does_not_deploy_zsh_site_functions() {
    local hits
    hits="$(grep -En 'deploy_zsh_completions|shell/completions|site-functions' "$ROOT/install.sh" 2>/dev/null || true)"

    if [[ -n "$hits" ]]; then
        _fail "template installer does not own zsh site-functions" "$hits"
        return
    fi

    _pass "template installer does not own zsh site-functions"
}

test_shell_completion_owned_by_bootstrap
test_installer_does_not_deploy_zsh_site_functions

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
