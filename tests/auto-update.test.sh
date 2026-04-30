#!/usr/bin/env bash
# tests/auto-update.test.sh — covers spec §9 smoke scenarios for auto-update.sh.
#
# Standalone (no test framework). Each scenario sets up a fake upstream + local
# clone in a tmpdir, manipulates state, runs auto-update.sh with custom CONF
# and STATE_DIR (env-var overrides), and asserts expected behavior.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/scripts/auto-update.sh"

[[ -x "$SCRIPT" ]] || { echo "auto-update.sh not executable at $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

# ─── Fixture setup ───────────────────────────────────────────────
TESTROOT=$(mktemp -d /tmp/auto-update-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

UPSTREAM="$TESTROOT/upstream.git"
LOCAL="$TESTROOT/local"
STATE="$TESTROOT/state"
CONF="$TESTROOT/auto-update.conf"
NAME="$(basename "$LOCAL")"

mkdir -p "$STATE"

git init --bare --quiet --initial-branch=main "$UPSTREAM"

git init --quiet --initial-branch=main "$LOCAL"
( cd "$LOCAL"
  git config user.email "test@test"
  git config user.name "test"
  git remote add origin "$UPSTREAM"
  echo "init" > README
  git add README
  git -c commit.gpgsign=false commit -q -m "init"
  git push -q -u origin main
)

# Conf — explicit echo lines (avoids heredoc escaping headaches)
{
    echo "AUTO_UPDATE_REPOS=(\"$LOCAL\")"
    echo 'AUTO_UPDATE_RELOAD=("*/.tmux.conf:tmux source-file ~/.tmux.conf" "*/test-rc:exec-shell-advice")'
    echo 'AUTO_UPDATE_FOLLOWUPS=("*/special.json:rode \`special-cmd\` para aplicar")'
    echo ': "${AUTO_EXEC_SHELL:=0}"'
    echo ': "${AUTO_UPDATE_FETCH_TIMEOUT:=3}"'
    echo ': "${AUTO_UPDATE_VERBOSE:=0}"'
    echo ': "${AUTO_UPDATE_SUDO_REGEX:=\\b(apt|brew|sudo)\\b}"'
} > "$CONF"

# Helpers
_run() {
    AUTO_UPDATE_CONF="$CONF" AUTO_UPDATE_STATE_DIR="$STATE" NO_COLOR=1 \
        bash "$SCRIPT" "$@" 2>&1
}

_reset() {
    rm -f "$STATE"/* 2>/dev/null || true
    ( cd "$LOCAL"
      git checkout -q main 2>/dev/null || true
      git branch -D experiment 2>/dev/null || true
      git fetch -q origin 2>/dev/null || true
      git reset -q --hard origin/main 2>/dev/null || true
      git clean -qfd 2>/dev/null || true
    )
}

# Push a commit through a sidecar clone (simulates another machine)
_push_via_sidecar() {
    local content="$1" path="$2" msg="$3"
    local sc="$TESTROOT/sidecar.$$"
    git clone -q "$UPSTREAM" "$sc"
    ( cd "$sc"
      git config user.email "other@test"
      git config user.name "other"
      mkdir -p "$(dirname "$path")"
      printf '%s\n' "$content" > "$path"
      git add "$path"
      git -c commit.gpgsign=false commit -q -m "$msg"
      git push -q origin main
    )
    rm -rf "$sc"
}

# ─── Scenarios ───────────────────────────────────────────────────

test_help() {
    if _run --help 2>&1 | grep -q "Usage:"; then _pass "--help shows usage"
    else _fail "--help missing Usage section"; fi
}

test_reset_auth() {
    _reset
    touch "$STATE/auth-failed-fake-repo"
    _run --reset-auth >/dev/null 2>&1 || true
    if [[ ! -f "$STATE/auth-failed-fake-repo" ]]; then
        _pass "--reset-auth clears auth-failed-* flags"
    else
        _fail "--reset-auth left flag in place"
    fi
}

test_unknown_arg() {
    # Capture in var first; pipefail + non-zero _run + grep success would
    # make `if ! ... | grep -q ...` lie. Capture-then-grep avoids the pipe.
    local out; out=$(_run --bogus || true)
    if echo "$out" | grep -q "unknown arg"; then
        _pass "unknown arg rejected with message"
    else
        _fail "unknown arg not rejected" "$out"
    fi
}

test_branch_skip() {
    _reset
    ( cd "$LOCAL"; git checkout -q -b experiment )
    local out; out=$(_run)
    ( cd "$LOCAL"; git checkout -q main; git branch -D experiment 2>/dev/null || true )
    if echo "$out" | grep -q "pulado.*experiment"; then
        _pass "non-main branch is skipped with notice"
    else
        _fail "non-main branch not detected" "$out"
    fi
}

test_dirty_skip() {
    _reset
    echo "wip" >> "$LOCAL/README"
    local out; out=$(_run)
    if echo "$out" | grep -q "pulado.*não-commitadas"; then
        _pass "dirty tree is skipped with notice"
    else
        _fail "dirty tree not detected" "$out"
    fi
}

test_first_run_seed() {
    _reset
    local out; out=$(_run)
    local expected; expected=$(cd "$LOCAL" && git rev-parse HEAD)
    if [[ -f "$STATE/last-applied-$NAME" ]] && \
       [[ "$(cat "$STATE/last-applied-$NAME")" == "$expected" ]] && \
       [[ -z "$out" ]]; then
        _pass "first run seeds last-applied silently"
    else
        _fail "first run seed broke" "$out"
    fi
}

test_up_to_date() {
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    local out; out=$(_run)
    if [[ -z "$out" ]]; then
        _pass "up-to-date repo produces no output"
    else
        _fail "up-to-date emitted output" "$out"
    fi
}

test_ahead_skip() {
    _reset
    ( cd "$LOCAL"
      git rev-parse HEAD > "$STATE/last-applied-$NAME"
      git -c commit.gpgsign=false commit -q --allow-empty -m "local-only"
    )
    # Now simulate an upstream commit so last-applied != head_remote forces
    # the script past the "up to date" check.
    _push_via_sidecar "x" "newup" "upstream after local"
    local out; out=$(_run)
    if echo "$out" | grep -qE "pulado.*$NAME.*commit"; then
        _pass "local commits ahead is skipped"
    else
        _fail "ahead detection failed" "$out"
    fi
}

test_happy_path() {
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "from other machine" "newfile" "from other machine"
    local out; out=$(_run)
    if [[ -f "$LOCAL/newfile" ]] && echo "$out" | grep -q "atualizado"; then
        _pass "happy path: upstream commit pulled and applied"
    else
        _fail "happy path failed" "$out"
    fi
}

test_reload_shell_rc() {
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    # Push to a subdir so the glob `*/test-rc` (one path component before
    # filename, mirroring production conf shape `*/.bashrc.d/*`) matches.
    _push_via_sidecar "config" "subdir/test-rc" "test-rc change"
    local out; out=$(_run)
    if echo "$out" | grep -q "shell config mudou"; then
        _pass "reload table fires exec-shell-advice on glob match"
    else
        _fail "reload table miss" "$out"
    fi
}

test_followup_summary() {
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "{}" "sub/special.json" "special.json change"
    local out; out=$(_run)
    if echo "$out" | grep -q "Manual follow-ups:" && echo "$out" | grep -q "special-cmd"; then
        _pass "followup table emits summary message"
    else
        _fail "followup did not emit" "$out"
    fi
}

test_pending_sudo_silent() {
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "no-op" "x" "trivial"
    # Now pre-seed pending-sudo with the new head_remote SHA
    ( cd "$LOCAL" && git fetch -q )
    ( cd "$LOCAL" && git rev-parse '@{upstream}' ) > "$STATE/pending-sudo-$NAME"
    local out; out=$(_run)
    if [[ -z "$out" ]]; then
        _pass "pending-sudo with matching SHA stays silent"
    else
        _fail "pending-sudo not silent" "$out"
    fi
}

test_repo_filter_match() {
    # --repo NAME where NAME matches a configured repo basename — same outcome as no filter.
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "match-test" "newfile-filter-match" "filter match"
    local out; out=$(_run --repo "$NAME")
    if [[ -f "$LOCAL/newfile-filter-match" ]] && echo "$out" | grep -q "atualizado"; then
        _pass "--repo NAME matches and processes the configured repo"
    else
        _fail "--repo NAME match failed" "$out"
    fi
}

test_repo_filter_miss() {
    # --repo BOGUS errors with non-zero exit and does not process anything.
    # Exit-code assertion matters: a typo (`bup --repo dotfile`) silently
    # returning 0 would let `bup --repo dotfile && dotup` proceed as if
    # bup had succeeded.
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "miss-test" "newfile-should-not-pull" "filter miss"
    local out rc
    out=$(_run --repo nonexistent-repo); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "did not match" && \
       [[ ! -f "$LOCAL/newfile-should-not-pull" ]]; then
        _pass "--repo BOGUS warns, exits non-zero, and skips processing"
    else
        _fail "--repo miss did not exit non-zero / not warn / pulled anyway (rc=$rc)" "$out"
    fi
}

test_repo_filter_rejects_flag_value() {
    # `--repo --full` would otherwise consume `--full` as the repo name.
    _reset
    local out rc
    out=$(_run --repo --full); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "requires a repo name"; then
        _pass "--repo rejects flag-like value (--full)"
    else
        _fail "--repo --full not rejected (rc=$rc)" "$out"
    fi
}

test_help_doesnt_lie_silently() {
    # When the script can read $0, --help should print the Usage section.
    # If a future refactor breaks $0 reading, sed -n exits 0 silently with
    # no output — the new fail-loud guard surfaces that.
    local out; out=$(_run --help)
    if echo "$out" | grep -q "Usage:" && echo "$out" | grep -q "auto-update.sh"; then
        _pass "--help prints non-trivial Usage block"
    else
        _fail "--help body missing or malformed" "$out"
    fi
}

test_reset_auth_scoped_to_repo_filter() {
    # `bup --reset-auth` (i.e. --repo dev-bootstrap --reset-auth) must
    # only clear dev-bootstrap's flag, not dotfiles'.
    _reset
    touch "$STATE/auth-failed-dev-bootstrap" "$STATE/auth-failed-dotfiles"
    _run --repo dev-bootstrap --reset-auth >/dev/null 2>&1 || true
    if [[ ! -f "$STATE/auth-failed-dev-bootstrap" ]] && \
       [[ -f "$STATE/auth-failed-dotfiles" ]]; then
        _pass "--reset-auth honors --repo (clears only that domain)"
    else
        _fail "--reset-auth ignored --repo or over-cleared"
    fi
}

test_empty_repos_array_fails_loud() {
    # AUTO_UPDATE_REPOS=() would previously exit 0 silently — confused
    # users with mistyped `AUTO_UPDATE_REPO=` (singular) singular.
    local empty_conf="$TESTROOT/empty-conf"
    {
        echo 'AUTO_UPDATE_REPOS=()'
        echo 'AUTO_UPDATE_RELOAD=()'
        echo 'AUTO_UPDATE_FOLLOWUPS=()'
        echo ': "${AUTO_EXEC_SHELL:=0}"'
        echo ': "${AUTO_UPDATE_FETCH_TIMEOUT:=3}"'
        echo ': "${AUTO_UPDATE_VERBOSE:=0}"'
        echo ': "${AUTO_UPDATE_SUDO_REGEX:=\\b(sudo)\\b}"'
    } > "$empty_conf"
    local out rc
    out=$(AUTO_UPDATE_CONF="$empty_conf" AUTO_UPDATE_STATE_DIR="$STATE" NO_COLOR=1 \
        bash "$SCRIPT" 2>&1); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "AUTO_UPDATE_REPOS is empty"; then
        _pass "empty AUTO_UPDATE_REPOS fails loud"
    else
        _fail "empty config did not fail loud (rc=$rc)" "$out"
    fi
}

test_incremental_dotfiles_runs_install_sh() {
    # CRITICAL gap before this test: the existing fixture's $NAME is
    # `local`, never `dotfiles` or `dev-bootstrap`, so the dispatch sites
    # at process_repo (incremental: $name == "dotfiles" → bash install.sh,
    # and the doctor.sh check) were NEVER exercised. Mutation testing
    # showed inverting those branches kept the suite green. This test
    # closes that hole using a fixture renamed `dotfiles` with a real
    # install.sh stub.
    _setup_full_fixture "dotfiles" "install.sh"
    # Seed last-applied with current HEAD so the next push triggers a
    # diff-based incremental run (NOT --full, which is tested elsewhere).
    ( cd "$FULL_LOCAL" && git rev-parse HEAD ) > "$FULL_STATE/last-applied-dotfiles"
    # Push a new commit via sidecar.
    local sc="$TESTROOT/sidecar-incr.$$"
    git clone -q "$FULL_UPSTREAM" "$sc"
    ( cd "$sc"
      git config user.email "other@test"; git config user.name "other"
      echo "diff" > newfile-incr
      git add newfile-incr
      git -c commit.gpgsign=false commit -q -m "incremental change"
      git push -q origin main )
    rm -rf "$sc"
    local out rc
    out=$(_run_full); rc=$?
    if (( rc == 0 )) && echo "$out" | grep -q "stub install.sh ran" && \
       echo "$out" | grep -q "atualizado"; then
        _pass "incremental dispatch hits install.sh on dotfiles repo"
    else
        _fail "incremental dotfiles dispatch failed (rc=$rc)" "$out"
    fi
}

# Helper: prepend a sudo shim to PATH that returns a controlled exit code
# for `sudo -v`. Lets us deterministically test the --full dev-bootstrap
# happy AND abort paths regardless of the developer machine's sudo cache.
_sudo_shim() {
    local rc="$1"  # 0 = sudo OK, 1 = sudo cancelled
    SUDO_SHIM_DIR=$(mktemp -d "$TESTROOT/sudo-shim.XXXX")
    cat > "$SUDO_SHIM_DIR/sudo" <<EOF
#!/usr/bin/env bash
# Test shim: \$1 is typically "-v" (validate). Exit with the seeded rc.
exit $rc
EOF
    chmod +x "$SUDO_SHIM_DIR/sudo"
    echo "$SUDO_SHIM_DIR"
}

_run_full_with_sudo_shim() {
    local sudo_rc="$1"; shift
    local shim; shim="$(_sudo_shim "$sudo_rc")"
    PATH="$shim:$PATH" \
    AUTO_UPDATE_CONF="$FULL_CONF" AUTO_UPDATE_STATE_DIR="$FULL_STATE" NO_COLOR=1 \
        bash "$SCRIPT" "$@" 2>&1
}

test_full_dev_bootstrap_aborts_when_sudo_cancels() {
    # Replaces the original `skips_when_no_sudo` test with a deterministic
    # variant: PATH-shim sudo to always exit 1 regardless of host cache.
    _setup_full_fixture "dev-bootstrap" "bootstrap.sh"
    local out rc
    out=$(_run_full_with_sudo_shim 1 --full); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "sudo cancelado" && \
       ! echo "$out" | grep -q "stub bootstrap.sh ran" && \
       [[ ! -f "$FULL_STATE/last-applied-dev-bootstrap" ]]; then
        _pass "--full dev-bootstrap aborts non-zero when sudo cancels (deterministic)"
    else
        _fail "--full dev-bootstrap sudo abort regressed (rc=$rc)" "$out"
    fi
}

test_full_dev_bootstrap_runs_bootstrap_when_sudo_ok() {
    # Positive path: sudo shim returns 0, bootstrap.sh stub runs, last-applied
    # gets bumped, exit 0. Previously uncovered.
    _setup_full_fixture "dev-bootstrap" "bootstrap.sh"
    local out rc head
    out=$(_run_full_with_sudo_shim 0 --full); rc=$?
    head=$(cd "$FULL_LOCAL" && git rev-parse HEAD)
    if (( rc == 0 )) && echo "$out" | grep -q "stub bootstrap.sh ran" && \
       echo "$out" | grep -q "reaplicado em modo --full" && \
       [[ -f "$FULL_STATE/last-applied-dev-bootstrap" ]] && \
       [[ "$(cat "$FULL_STATE/last-applied-dev-bootstrap")" == "$head" ]]; then
        _pass "--full dev-bootstrap runs bootstrap.sh and bumps last-applied (sudo shim)"
    else
        _fail "--full dev-bootstrap positive path failed (rc=$rc)" "$out"
    fi
}

test_full_dotfiles_install_failure_does_not_bump() {
    # Adversarial: stub install.sh exits 1, motor must NOT bump last-applied
    # and overall exit must be non-zero.
    _setup_full_fixture "dotfiles" "install.sh"
    # Replace the stub to always fail.
    cat > "$FULL_LOCAL/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "[install.sh stub: simulated failure]"
exit 1
EOF
    chmod +x "$FULL_LOCAL/install.sh"
    ( cd "$FULL_LOCAL"
      git -c commit.gpgsign=false commit -q -am "fail stub"
      git push -q origin main )
    local out rc
    out=$(_run_full --full); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "install.sh --full falhou" && \
       [[ ! -f "$FULL_STATE/last-applied-dotfiles" ]]; then
        _pass "--full dotfiles install.sh failure: exit non-zero, last-applied NOT bumped"
    else
        _fail "--full dotfiles install failure handling regressed (rc=$rc)" "$out"
    fi
}

test_lock_blocks_concurrent_run() {
    # Pre-create the lock dir; second invocation should silently exit 0
    # because the contender is "running".
    _reset
    mkdir -p "$STATE/update.lock.d"
    touch "$STATE/update.lock.d"  # fresh — shouldn't be stolen
    local out rc
    out=$(_run); rc=$?
    rmdir "$STATE/update.lock.d" 2>/dev/null || true
    if (( rc == 0 )) && [[ -z "$out" ]]; then
        _pass "lock contention: silent exit 0 when another instance holds lock"
    else
        _fail "lock contention regression (rc=$rc)" "$out"
    fi
}

test_lock_recovers_stale() {
    # Lock dir older than 1 minute is stolen.
    _reset
    mkdir -p "$STATE/update.lock.d"
    # Backdate to 2 minutes ago — `touch -t` is portable Linux+macOS.
    touch -t "$(date -d '2 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null || \
                date -v-2M '+%Y%m%d%H%M.%S' 2>/dev/null)" "$STATE/update.lock.d"
    # First run on a fresh repo just seeds; that's fine — the lock-steal
    # is what we're verifying.
    local out
    out=$(_run)
    if [[ ! -d "$STATE/update.lock.d" ]] && \
       [[ -f "$STATE/last-applied-$NAME" ]]; then
        _pass "lock recovery: stale lock (>1 min) is stolen, run proceeds"
    else
        _fail "stale lock not recovered" "$out"
    fi
}

test_wrapper_bup_passes_dev_bootstrap_repo() {
    # Smoke-test scripts/bup: it should `exec` motor with --repo dev-bootstrap.
    # We verify by intercepting via a stub motor.
    local stub_dir; stub_dir=$(mktemp -d "$TESTROOT/wrap-bup.XXXX")
    mkdir -p "$stub_dir/dotfiles/scripts"
    cat > "$stub_dir/dotfiles/scripts/auto-update.sh" <<'EOF'
#!/usr/bin/env bash
echo "MOTOR-INVOKED-WITH: $*"
exit 0
EOF
    chmod +x "$stub_dir/dotfiles/scripts/auto-update.sh"
    local out
    out=$(HOME="$stub_dir" bash "$ROOT/scripts/bup" --full 2>&1)
    if echo "$out" | grep -q "MOTOR-INVOKED-WITH: --repo dev-bootstrap --full"; then
        _pass "bup wrapper dispatches to motor with --repo dev-bootstrap"
    else
        _fail "bup wrapper dispatch wrong" "$out"
    fi
}

test_wrapper_dotup_passes_dotfiles_repo() {
    local stub_dir; stub_dir=$(mktemp -d "$TESTROOT/wrap-dotup.XXXX")
    mkdir -p "$stub_dir/dotfiles/scripts"
    cat > "$stub_dir/dotfiles/scripts/auto-update.sh" <<'EOF'
#!/usr/bin/env bash
echo "MOTOR-INVOKED-WITH: $*"
exit 0
EOF
    chmod +x "$stub_dir/dotfiles/scripts/auto-update.sh"
    local out
    out=$(HOME="$stub_dir" bash "$ROOT/scripts/dotup" --reset-auth 2>&1)
    if echo "$out" | grep -q "MOTOR-INVOKED-WITH: --repo dotfiles --reset-auth"; then
        _pass "dotup wrapper dispatches to motor with --repo dotfiles"
    else
        _fail "dotup wrapper dispatch wrong" "$out"
    fi
}

test_wrapper_pre_flight_motor_missing() {
    # If motor file is absent, wrapper must emit actionable error, not
    # the opaque `exec: not found` from bash.
    local stub_dir; stub_dir=$(mktemp -d "$TESTROOT/wrap-missing.XXXX")
    local out rc
    out=$(HOME="$stub_dir" bash "$ROOT/scripts/bup" 2>&1); rc=$?
    if (( rc == 1 )) && echo "$out" | grep -q "motor not found" && \
       echo "$out" | grep -q "install.sh"; then
        _pass "wrapper pre-flight: actionable error when motor missing"
    else
        _fail "wrapper missing-motor error not actionable (rc=$rc)" "$out"
    fi
}

# --full tests use a separate fixture: the repo basename must equal "dotfiles"
# (or "dev-bootstrap") because the motor branches on $name to pick install.sh
# vs bootstrap.sh. We stub the orchestrator with `exit 0` so the test exercises
# the dispatch path without actually rebootstrapping anything.
_setup_full_fixture() {
    local name="$1"  # "dotfiles" or "dev-bootstrap"
    local stub="$2"  # "install.sh" or "bootstrap.sh"
    FULL_UPSTREAM="$TESTROOT/$name-upstream.git"
    FULL_LOCAL="$TESTROOT/$name"
    FULL_STATE="$TESTROOT/$name-state"
    FULL_CONF="$TESTROOT/$name-conf"
    rm -rf "$FULL_UPSTREAM" "$FULL_LOCAL" "$FULL_STATE"
    mkdir -p "$FULL_STATE"
    git init --bare --quiet --initial-branch=main "$FULL_UPSTREAM"
    git init --quiet --initial-branch=main "$FULL_LOCAL"
    ( cd "$FULL_LOCAL"
      git config user.email "test@test"
      git config user.name "test"
      git remote add origin "$FULL_UPSTREAM"
      printf '#!/usr/bin/env bash\necho "[stub %s ran]"\nexit 0\n' "$stub" > "$stub"
      chmod +x "$stub"
      git add "$stub"
      git -c commit.gpgsign=false commit -q -m "init with stub $stub"
      git push -q -u origin main
    )
    {
        echo "AUTO_UPDATE_REPOS=(\"$FULL_LOCAL\")"
        echo 'AUTO_UPDATE_RELOAD=()'
        echo 'AUTO_UPDATE_FOLLOWUPS=()'
        echo ': "${AUTO_EXEC_SHELL:=0}"'
        echo ': "${AUTO_UPDATE_FETCH_TIMEOUT:=3}"'
        echo ': "${AUTO_UPDATE_VERBOSE:=0}"'
        echo ': "${AUTO_UPDATE_SUDO_REGEX:=\\b(apt|brew|sudo)\\b}"'
    } > "$FULL_CONF"
}

_run_full() {
    AUTO_UPDATE_CONF="$FULL_CONF" AUTO_UPDATE_STATE_DIR="$FULL_STATE" NO_COLOR=1 \
        bash "$SCRIPT" "$@" 2>&1
}

test_full_dotfiles() {
    # --full on dotfiles forces install.sh even with no diff and no last-applied.
    _setup_full_fixture "dotfiles" "install.sh"
    local out; out=$(_run_full --full)
    local head; head=$(cd "$FULL_LOCAL" && git rev-parse HEAD)
    if echo "$out" | grep -q "stub install.sh ran" && \
       echo "$out" | grep -q "reaplicado em modo --full" && \
       [[ -f "$FULL_STATE/last-applied-dotfiles" ]] && \
       [[ "$(cat "$FULL_STATE/last-applied-dotfiles")" == "$head" ]]; then
        _pass "--full runs dotfiles install.sh and bumps last-applied"
    else
        _fail "--full dotfiles path failed" "$out"
    fi
}

_OBSOLETE_replaced_by_sudo_shim_variant() { :; }

# ─── Run ──────────────────────────────────────────────────────────
echo
echo "${C_DIM}── auto-update.sh smoke tests${C_RST}"
echo

test_help
test_reset_auth
test_unknown_arg
test_branch_skip
test_dirty_skip
test_first_run_seed
test_up_to_date
test_ahead_skip
test_happy_path
test_reload_shell_rc
test_followup_summary
test_pending_sudo_silent
test_repo_filter_match
test_repo_filter_miss
test_repo_filter_rejects_flag_value
test_help_doesnt_lie_silently
test_reset_auth_scoped_to_repo_filter
test_empty_repos_array_fails_loud
test_incremental_dotfiles_runs_install_sh
test_full_dotfiles
test_full_dotfiles_install_failure_does_not_bump
test_full_dev_bootstrap_aborts_when_sudo_cancels
test_full_dev_bootstrap_runs_bootstrap_when_sudo_ok
test_lock_blocks_concurrent_run
test_lock_recovers_stale
test_wrapper_bup_passes_dev_bootstrap_repo
test_wrapper_dotup_passes_dotfiles_repo
test_wrapper_pre_flight_motor_missing

test_wrapper_honors_dotfiles_dir_override() {
    # Closes adversarial-review HIGH (D41 audit): without this test, reverting
    # `MOTOR=${DOTFILES_DIR:-$HOME/dotfiles}/...` back to `MOTOR=$HOME/dotfiles/...`
    # in scripts/{bup,dotup} ships green because every other test sets HOME
    # to a stub_dir that ALSO ends with `/dotfiles`. We need a fixture where
    # $DOTFILES_DIR explicitly points elsewhere AND `$HOME/dotfiles` does NOT
    # exist — only then does the wrapper actually exercise the env override.
    local stub_dir; stub_dir=$(mktemp -d "$TESTROOT/wrap-dotfilesdir.XXXX")
    local custom_dir="$stub_dir/work-dotfiles"
    mkdir -p "$custom_dir/scripts"
    cat > "$custom_dir/scripts/auto-update.sh" <<'EOF'
#!/usr/bin/env bash
echo "MOTOR-AT: $0 ARGS: $*"
exit 0
EOF
    chmod +x "$custom_dir/scripts/auto-update.sh"

    # CRUCIAL: do NOT create $stub_dir/dotfiles/. If the wrapper falls back
    # to the hardcoded $HOME/dotfiles path, it will fail loudly here.
    local out
    out=$(HOME="$stub_dir" DOTFILES_DIR="$custom_dir" bash "$ROOT/scripts/bup" --reset-auth 2>&1)
    if echo "$out" | grep -q "MOTOR-AT: $custom_dir/scripts/auto-update.sh"; then
        _pass "bup honors DOTFILES_DIR (motor at custom path, not \$HOME/dotfiles)"
    else
        _fail "bup ignored DOTFILES_DIR — refactor regressed" "$out"
    fi

    out=$(HOME="$stub_dir" DOTFILES_DIR="$custom_dir" bash "$ROOT/scripts/dotup" --reset-auth 2>&1)
    if echo "$out" | grep -q "MOTOR-AT: $custom_dir/scripts/auto-update.sh"; then
        _pass "dotup honors DOTFILES_DIR (motor at custom path, not \$HOME/dotfiles)"
    else
        _fail "dotup ignored DOTFILES_DIR — refactor regressed" "$out"
    fi
}
test_wrapper_honors_dotfiles_dir_override

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
