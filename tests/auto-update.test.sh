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
( cd "$LOCAL" || exit
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
# AUTO_UPDATE_LOCAL_CONF is pinned to a non-existent path so any real
# `~/.config/dotfiles/auto-update.conf.local` on the developer's machine
# (M2 has one) doesn't leak in via the motor's per-host override fallback
# and silently override AUTO_UPDATE_REPOS away from the fixture.
_run() {
    AUTO_UPDATE_CONF="$CONF" AUTO_UPDATE_STATE_DIR="$STATE" \
        AUTO_UPDATE_LOCAL_CONF="$TESTROOT/never-exists.conf.local" \
        NO_COLOR=1 bash "$SCRIPT" "$@" 2>&1
}

_reset() {
    rm -f "$STATE"/* 2>/dev/null || true
    ( cd "$LOCAL" || exit
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
    ( cd "$sc" || exit
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
    ( cd "$LOCAL" || exit; git checkout -q -b experiment )
    local out; out=$(_run)
    ( cd "$LOCAL" || exit; git checkout -q main; git branch -D experiment 2>/dev/null || true )
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
    ( cd "$LOCAL" || exit
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

test_only_match() {
    # -o/--only NAME where NAME matches a configured repo basename — same outcome as no filter.
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "match-test" "newfile-filter-match" "filter match"
    local out; out=$(_run --only "$NAME")
    if [[ -f "$LOCAL/newfile-filter-match" ]] && echo "$out" | grep -q "atualizado"; then
        _pass "--only NAME matches and processes the configured repo"
    else
        _fail "--only NAME match failed" "$out"
    fi
}

test_only_short_form() {
    # -o is the short alias of --only. Same behavior as the long form above.
    # Anchored separately so a regression that breaks short→long mapping in
    # the arg parser fails this test even if --only stays green.
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "short-form" "newfile-short-form" "short form"
    local out; out=$(_run -o "$NAME")
    if [[ -f "$LOCAL/newfile-short-form" ]] && echo "$out" | grep -q "atualizado"; then
        _pass "-o NAME (short form) is equivalent to --only NAME"
    else
        _fail "-o NAME short form regressed" "$out"
    fi
}

test_only_miss() {
    # -o/--only BOGUS errors with non-zero exit and does not process anything.
    # Exit-code assertion matters: a typo silently returning 0 would let
    # `mesh update -o dotfile && other-cmd` proceed as if it had succeeded.
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "miss-test" "newfile-should-not-pull" "filter miss"
    local out rc
    out=$(_run --only nonexistent-repo); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "did not match" && \
       [[ ! -f "$LOCAL/newfile-should-not-pull" ]]; then
        _pass "--only BOGUS warns, exits non-zero, and skips processing"
    else
        _fail "--only miss did not exit non-zero / not warn / pulled anyway (rc=$rc)" "$out"
    fi
}

test_only_rejects_flag_value() {
    # `-o --full` (and likewise --only --full) would otherwise consume --full
    # as the repo name. Both forms route through the same parser branch but
    # we exercise both to pin the short→long routing too.
    _reset
    local out rc
    out=$(_run --only --full); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "requires a repo name"; then
        _pass "--only rejects flag-like value (--full)"
    else
        _fail "--only --full not rejected (rc=$rc)" "$out"
        return
    fi
    out=$(_run -o -f); rc=$?
    if (( rc != 0 )) && echo "$out" | grep -q "requires a repo name"; then
        _pass "-o rejects flag-like value (-f)"
    else
        _fail "-o -f not rejected (rc=$rc)" "$out"
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

test_reset_auth_scoped_to_only() {
    # `mesh update -o dev-bootstrap --reset-auth` (i.e. --only dev-bootstrap
    # --reset-auth at the motor level) must only clear dev-bootstrap's flag,
    # not dotfiles'.
    _reset
    touch "$STATE/auth-failed-dev-bootstrap" "$STATE/auth-failed-dotfiles"
    _run --only dev-bootstrap --reset-auth >/dev/null 2>&1 || true
    if [[ ! -f "$STATE/auth-failed-dev-bootstrap" ]] && \
       [[ -f "$STATE/auth-failed-dotfiles" ]]; then
        _pass "--reset-auth honors --only (clears only that domain)"
    else
        _fail "--reset-auth ignored --only or over-cleared"
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
    out=$(AUTO_UPDATE_CONF="$empty_conf" AUTO_UPDATE_STATE_DIR="$STATE" \
        AUTO_UPDATE_LOCAL_CONF="$TESTROOT/never-exists.conf.local" NO_COLOR=1 \
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
    ( cd "$sc" || exit
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
    AUTO_UPDATE_CONF="$FULL_CONF" AUTO_UPDATE_STATE_DIR="$FULL_STATE" \
    AUTO_UPDATE_LOCAL_CONF="$TESTROOT/never-exists.conf.local" \
    NO_COLOR=1 \
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
    ( cd "$FULL_LOCAL" || exit
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

# NOTE: bup/dotup wrapper tests removed in the mesh-cli refactor —
# those wrappers are no longer shipped (`mesh update bootstrap` and
# `mesh update dotfiles` replace them via the unified dispatcher).
# Dispatch coverage moved to tests/mesh.test.sh.

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
    ( cd "$FULL_LOCAL" || exit
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
    AUTO_UPDATE_CONF="$FULL_CONF" AUTO_UPDATE_STATE_DIR="$FULL_STATE" \
        AUTO_UPDATE_LOCAL_CONF="$TESTROOT/never-exists.conf.local" \
        NO_COLOR=1 bash "$SCRIPT" "$@" 2>&1
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

# ─── --interactive flag wiring ──────────────────────────────────────
# In `--full` + dev-bootstrap, default behavior is to invoke
# `bash bootstrap.sh --non-interactive` so the shell-start hook never
# blocks on a prompt. The new -i/--interactive flag drops that arg so
# the user can see the whiptail menu (e.g. to validate a new opt-in).

test_default_full_bootstrap_uses_non_interactive() {
    # Sanity check — default --full path on dev-bootstrap MUST pass
    # --non-interactive to bootstrap.sh. Mutation-deleting the
    # `if (( ! INTERACTIVE ))` guard would make this test red.
    _setup_full_fixture "dev-bootstrap" "bootstrap.sh"
    # Replace stub with one that records args.
    cat > "$FULL_LOCAL/bootstrap.sh" <<EOF
#!/usr/bin/env bash
echo "args=\$*" > "$FULL_STATE/bootstrap-args.log"
exit 0
EOF
    chmod +x "$FULL_LOCAL/bootstrap.sh"
    ( cd "$FULL_LOCAL" || exit
      git -c commit.gpgsign=false commit -q -am "args-recording stub"
      git push -q origin main )

    _run_full_with_sudo_shim 0 --full >/dev/null
    local args; args="$(cat "$FULL_STATE/bootstrap-args.log" 2>/dev/null)"

    if echo "$args" | grep -q -- "--non-interactive"; then
        _pass "default --full passes --non-interactive to bootstrap.sh"
    else
        _fail "default --full did NOT pass --non-interactive" "args=$args"
    fi
}

test_interactive_drops_non_interactive_in_full_bootstrap() {
    # Layer B: --full + --interactive on dev-bootstrap must NOT pass
    # --non-interactive to bootstrap.sh. The whiptail menu only shows
    # when bootstrap.sh runs without that flag.
    _setup_full_fixture "dev-bootstrap" "bootstrap.sh"
    cat > "$FULL_LOCAL/bootstrap.sh" <<EOF
#!/usr/bin/env bash
echo "args=\$*" > "$FULL_STATE/bootstrap-args.log"
exit 0
EOF
    chmod +x "$FULL_LOCAL/bootstrap.sh"
    ( cd "$FULL_LOCAL" || exit
      git -c commit.gpgsign=false commit -q -am "args-recording stub"
      git push -q origin main )

    _run_full_with_sudo_shim 0 --full --interactive >/dev/null
    local args; args="$(cat "$FULL_STATE/bootstrap-args.log" 2>/dev/null)"

    if echo "$args" | grep -q "args=" && ! echo "$args" | grep -q -- "--non-interactive"; then
        _pass "--interactive drops --non-interactive in --full + dev-bootstrap"
    else
        _fail "--interactive did not drop --non-interactive" "args=$args"
    fi
}

test_interactive_short_form() {
    # -i is the short alias of --interactive. Pin both forms route to
    # the same arg-parser branch.
    _setup_full_fixture "dev-bootstrap" "bootstrap.sh"
    cat > "$FULL_LOCAL/bootstrap.sh" <<EOF
#!/usr/bin/env bash
echo "args=\$*" > "$FULL_STATE/bootstrap-args.log"
exit 0
EOF
    chmod +x "$FULL_LOCAL/bootstrap.sh"
    ( cd "$FULL_LOCAL" || exit
      git -c commit.gpgsign=false commit -q -am "args-recording stub"
      git push -q origin main )

    _run_full_with_sudo_shim 0 -f -i >/dev/null
    local args; args="$(cat "$FULL_STATE/bootstrap-args.log" 2>/dev/null)"

    if echo "$args" | grep -q "args=" && ! echo "$args" | grep -q -- "--non-interactive"; then
        _pass "-i (short form) is equivalent to --interactive"
    else
        _fail "-i short form regressed" "args=$args"
    fi
}

# ─── Per-host conf.local override + invalid-path diagnostic ─────────
# Spec: docs/2026-05-05-auto-update-per-host-override-handoff.md
# Background: M2 (Mac, /Volumes/External/code/dev-bootstrap clone) hit
# `mesh update bootstrap --full` exiting silently in 3s because the
# default `AUTO_UPDATE_REPOS=("$HOME/dev-bootstrap")` didn't match the
# host's layout. Two coupled gaps: (1) no per-host override, (2) the
# "not a git repo" branch was `dbg` (silent unless VERBOSE).

test_local_conf_anchored_in_motor() {
    # Layer A contract: greps motor source for the LOCAL_CONF wiring +
    # the visible notice. Mutation-resistant: deleting either line makes
    # this test fail before any behavior test runs, surfacing intent
    # loss in code review (per feedback_test_fixture_pitfalls.md).
    local missing=()
    grep -q 'LOCAL_CONF=' "$SCRIPT" || missing+=("LOCAL_CONF= assignment")
    grep -q 'source "$LOCAL_CONF"' "$SCRIPT" || missing+=('source "$LOCAL_CONF"')
    grep -q 'não é repo git' "$SCRIPT" || missing+=("notice 'não é repo git'")
    if (( ${#missing[@]} == 0 )); then
        _pass "motor sources LOCAL_CONF + uses notice for invalid paths"
    else
        _fail "motor missing intended changes: ${missing[*]}"
    fi
}

test_local_conf_override_redirects_repos() {
    # Layer B execution: main conf points to a NON-existent path; the
    # .conf.local re-assigns AUTO_UPDATE_REPOS to the real fixture.
    # If `source "$LOCAL_CONF"` regresses, this test goes red because
    # the motor would target the bogus path and emit the new notice
    # instead of pulling the upstream commit.
    _reset
    ( cd "$LOCAL" && git rev-parse HEAD ) > "$STATE/last-applied-$NAME"
    _push_via_sidecar "override" "newfile-localconf" "via .conf.local"
    local main_conf="$TESTROOT/main-bogus.conf"
    local local_conf="$TESTROOT/auto-update.conf.local"
    {
        echo "AUTO_UPDATE_REPOS=(\"$TESTROOT/nonexistent-host-path\")"
        echo 'AUTO_UPDATE_RELOAD=()'
        echo 'AUTO_UPDATE_FOLLOWUPS=()'
        echo ': "${AUTO_EXEC_SHELL:=0}"'
        echo ': "${AUTO_UPDATE_FETCH_TIMEOUT:=3}"'
        echo ': "${AUTO_UPDATE_VERBOSE:=0}"'
        echo ': "${AUTO_UPDATE_SUDO_REGEX:=\\b(sudo)\\b}"'
    } > "$main_conf"
    echo "AUTO_UPDATE_REPOS=(\"$LOCAL\")" > "$local_conf"
    local out
    out=$(AUTO_UPDATE_CONF="$main_conf" AUTO_UPDATE_LOCAL_CONF="$local_conf" \
        AUTO_UPDATE_STATE_DIR="$STATE" NO_COLOR=1 \
        bash "$SCRIPT" 2>&1)
    if [[ -f "$LOCAL/newfile-localconf" ]] && echo "$out" | grep -q "atualizado"; then
        _pass ".conf.local override redirects AUTO_UPDATE_REPOS to real fixture"
    else
        _fail ".conf.local override did not take effect" "$out"
    fi
}

test_invalid_repo_path_emits_notice() {
    # Layer C diagnostic: conf points to a path that is NOT a git repo,
    # NO .conf.local. Output MUST include "não é repo git" + a reference
    # to AUTO_UPDATE_REPOS so the user can self-heal — replaces the silent
    # skip that left users with a 3-second exit and no clue.
    _reset
    local bogus_conf="$TESTROOT/bogus-path.conf"
    local bogus_path="$TESTROOT/not-a-git-repo"
    mkdir -p "$bogus_path"  # exists as dir but lacks .git/
    {
        echo "AUTO_UPDATE_REPOS=(\"$bogus_path\")"
        echo 'AUTO_UPDATE_RELOAD=()'
        echo 'AUTO_UPDATE_FOLLOWUPS=()'
        echo ': "${AUTO_EXEC_SHELL:=0}"'
        echo ': "${AUTO_UPDATE_FETCH_TIMEOUT:=3}"'
        echo ': "${AUTO_UPDATE_VERBOSE:=0}"'
        echo ': "${AUTO_UPDATE_SUDO_REGEX:=\\b(sudo)\\b}"'
    } > "$bogus_conf"
    # Point .conf.local discovery at a non-existent path so it can't mask the test.
    local out
    out=$(AUTO_UPDATE_CONF="$bogus_conf" \
        AUTO_UPDATE_LOCAL_CONF="$TESTROOT/never-exists.conf.local" \
        AUTO_UPDATE_STATE_DIR="$STATE" NO_COLOR=1 \
        bash "$SCRIPT" 2>&1)
    if echo "$out" | grep -q "não é repo git" && echo "$out" | grep -q "AUTO_UPDATE_REPOS"; then
        _pass "invalid AUTO_UPDATE_REPOS path emits visible notice with hint"
    else
        _fail "invalid path silent or hint missing" "$out"
    fi
}

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
test_only_match
test_only_short_form
test_only_miss
test_only_rejects_flag_value
test_help_doesnt_lie_silently
test_reset_auth_scoped_to_only
test_empty_repos_array_fails_loud
test_incremental_dotfiles_runs_install_sh
test_full_dotfiles
test_full_dotfiles_install_failure_does_not_bump
test_full_dev_bootstrap_aborts_when_sudo_cancels
test_full_dev_bootstrap_runs_bootstrap_when_sudo_ok
test_lock_blocks_concurrent_run
test_lock_recovers_stale
test_default_full_bootstrap_uses_non_interactive
test_interactive_drops_non_interactive_in_full_bootstrap
test_interactive_short_form
test_local_conf_anchored_in_motor
test_local_conf_override_redirects_repos
test_invalid_repo_path_emits_notice

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
