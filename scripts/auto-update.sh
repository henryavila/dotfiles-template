#!/usr/bin/env bash
# scripts/auto-update.sh — propagate dev-bootstrap + dotfiles changes across machines.
#
# Spec: docs/2026-04-25-auto-update-spec.md
#
# Usage:
#   bash scripts/auto-update.sh                     manual run, all repos, incremental
#   bash scripts/auto-update.sh --from-shell-start  hook invocation (allows auto-exec)
#   bash scripts/auto-update.sh -o|--only NAME      restrict to repo NAME (dev-bootstrap | dotfiles)
#   bash scripts/auto-update.sh -f|--full           force full apply: bash bootstrap.sh / install.sh
#                                                   ignoring last-applied diff
#   bash scripts/auto-update.sh -i|--interactive    in --full + dev-bootstrap, run bootstrap.sh
#                                                   WITHOUT --non-interactive (i.e. show the menu).
#                                                   Silently ignored for dotfiles or incremental runs.
#   bash scripts/auto-update.sh --reset-auth        clear auth-failed-* flags and exit
#   bash scripts/auto-update.sh -h|--help           this help
#
# Exit codes:
#   0  no work, or successful apply across all repos
#   1  fatal error (config missing, etc.)
#
# Side effects:
#   ~/.local/state/dev-bootstrap/last-applied-<repo>  SHA aplicada por repo
#   ~/.local/state/dev-bootstrap/update.lock          flock mutex
#   ~/.local/state/dev-bootstrap/pending-sudo-<repo>  marker se sudo cancelado
#   ~/.local/state/dev-bootstrap/auth-failed-<repo>   marker se git fetch deu 401/403

set -uo pipefail
# NOTE: not -e — we handle per-repo failures gracefully; lib funcs return non-zero
# without aborting the loop.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CONF lookup priority (first hit wins):
#   1. $AUTO_UPDATE_CONF                            — explicit override (tests, manual relocation)
#   2. $HOME/.config/dotfiles/auto-update.conf      — fork-de-template layout
#                                                     (template install.sh deploys
#                                                     auto-update.conf.example here in `once` mode)
#   3. $HERE/auto-update.conf                       — in-tree (private dotfiles repo layout)
# Both real-world layouts therefore work without manual env wiring.
# STATE_DIR overridable via env for test fixtures (see tests/auto-update.test.sh).
CONF="${AUTO_UPDATE_CONF:-}"
if [[ -z "$CONF" ]]; then
    if [[ -r "$HOME/.config/dotfiles/auto-update.conf" ]]; then
        CONF="$HOME/.config/dotfiles/auto-update.conf"
    else
        CONF="$HERE/auto-update.conf"
    fi
fi
STATE_DIR="${AUTO_UPDATE_STATE_DIR:-$HOME/.local/state/dev-bootstrap}"
# (Legacy `LOCK="$STATE_DIR/update.lock"` removed — see LOCK_DIR below;
# the mkdir-based mutex superseded the file-based one and the unused
# variable was tripping shellcheck SC2034.)

# ─── Args ────────────────────────────────────────────────────────────
FROM_SHELL_START=0
RESET_AUTH=0
FULL=0
INTERACTIVE=0
ONLY=""
while (( $# > 0 )); do
    case "$1" in
        --from-shell-start) FROM_SHELL_START=1 ;;
        --reset-auth)       RESET_AUTH=1 ;;
        --full|-f)          FULL=1 ;;
        --interactive|-i)   INTERACTIVE=1 ;;
        --only|-o)
            shift
            ONLY="${1:-}"
            # Reject empty AND flag-like values (e.g. `--only --full` would
            # otherwise consume `--full` as the repo name and emit a confusing
            # "did not match" warning). Both long and short forms route here.
            if [[ -z "$ONLY" || "$ONLY" == -* ]]; then
                echo "auto-update: -o/--only requires a repo name (e.g. dev-bootstrap, dotfiles)" >&2
                exit 1
            fi
            ;;
        --help|-h)
            # Fail loud if we can't read $0 — silent empty help would mislead.
            if ! sed -n '2,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; then
                echo "auto-update: cannot read self for --help (\$0=$0)" >&2
                exit 1
            fi
            exit 0
            ;;
        *)
            echo "auto-update: unknown arg: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Fail-loud on STATE_DIR creation: if we can't persist state, the motor is
# pointless. Silent failure here was a pure footgun (script kept going,
# lock acquisition then failed, exited 0 — user saw nothing).
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "auto-update: cannot create state dir $STATE_DIR" >&2
    exit 1
fi

if (( RESET_AUTH )); then
    # Honor -o/--only when set: only clear that domain's flag — `mesh update
    # -o dev-bootstrap --reset-auth` shouldn't touch dotfiles auth state.
    if [[ -n "$ONLY" ]]; then
        rm -f "$STATE_DIR/auth-failed-$ONLY"
        echo "auto-update: cleared auth-failed flag for $ONLY"
    else
        rm -f "$STATE_DIR"/auth-failed-*
        echo "auto-update: cleared auth-failed flags"
    fi
    exit 0
fi

if [[ ! -r "$CONF" ]]; then
    echo "auto-update: config not found at $CONF" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# Per-host override — never tracked in git. Sourced AFTER the main conf so
# re-assignments (e.g., AUTO_UPDATE_REPOS=(...)) take effect. Use this to
# point AUTO_UPDATE_REPOS at non-canonical paths (e.g. /Volumes/External
# on Mac) without forking the public conf. Path overridable via env for
# test fixtures.
LOCAL_CONF="${AUTO_UPDATE_LOCAL_CONF:-$HOME/.config/dotfiles/auto-update.conf.local}"
if [[ -r "$LOCAL_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$LOCAL_CONF"
fi

# ─── Lock (mkdir-based mutex; portable across Linux + macOS) ────────
# Why not flock(1): GNU-only, not shipped on macOS without `brew install
# flock`. `mkdir` is atomic on POSIX and fails when target exists — gives
# us mutex semantics for free with zero deps. Stale-lock recovery via
# mtime heuristic (auto-update normally finishes in <2s; if dir is older
# than 60s, assume crashed prior run and steal).
LOCK_DIR="$STATE_DIR/update.lock.d"
_acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    if [[ -d "$LOCK_DIR" ]] && \
       [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null
        mkdir "$LOCK_DIR" 2>/dev/null && return 0
    fi
    return 1
}
if ! _acquire_lock; then
    # Another instance running, or lock contention — silent skip.
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# ─── Output helpers ─────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_DIM=$'\e[2m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_RST=$'\e[0m'
else
    C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

notice() { printf '%s↻%s %s\n' "$C_DIM" "$C_RST" "$1"; }
ok()     { printf '%s✓%s %s\n' "$C_OK" "$C_RST" "$1"; }
warn()   { printf '%s!%s %s\n' "$C_WARN" "$C_RST" "$1" >&2; }
err()    { printf '%s✗%s %s\n' "$C_ERR" "$C_RST" "$1" >&2; }
dbg()    { (( ${AUTO_UPDATE_VERBOSE:-0} )) && printf '%s· %s%s\n' "$C_DIM" "$1" "$C_RST" >&2; return 0; }

# OS suffix used by dev-bootstrap install.<suffix>.sh convention.
_uname_suffix() {
    case "$(uname -s)" in
        Linux*)  echo "wsl" ;;
        Darwin*) echo "mac" ;;
        *)       echo "" ;;
    esac
}

# Canonical retry hint for user-facing messages. The old `bup`/`dotup`
# wrappers were retired in D41 (mesh-cli refactor); messages now point at
# the unified `mesh update -o <repo>` form so the suggestion matches what
# the user actually has on PATH.
wrapper_for() {
    echo "mesh update -o $1"
}

# Detect timeout(1) — Linux ships `timeout`, macOS may ship `gtimeout` via
# `brew install coreutils`, neither is guaranteed. If absent, _run_with_timeout
# degrades to running the command without bound (last-resort fallback;
# `git fetch` will use its own internal protocol timeouts).
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_BIN=gtimeout
else
    _TIMEOUT_BIN=""
fi
_run_with_timeout() {
    local sec="$1"; shift
    if [[ -n "$_TIMEOUT_BIN" ]]; then
        "$_TIMEOUT_BIN" "$sec" "$@"
    else
        "$@"
    fi
}

# ─── Accumulators ───────────────────────────────────────────────────
SHELL_RC_CHANGED=0
FOLLOWUPS=()

# ─── Per-repo logic ─────────────────────────────────────────────────
# Returns 0 if repo was inspected (whether or not work was done).
# Returns 1 only on fatal error (we keep going to next repo).
process_repo() {
    local repo="$1"
    local name
    name="$(basename "$repo")"

    # Visible diagnostic (was `dbg`, silent by default): a configured path
    # that isn't a git repo means AUTO_UPDATE_REPOS is wrong for this host.
    # Silent skip used to leave users with a 3-second exit and zero hints.
    if [[ ! -d "$repo/.git" ]]; then
        notice "pulado: $name (caminho '$repo' não é repo git)"
        notice "  → ajuste AUTO_UPDATE_REPOS em $CONF, ou crie $LOCAL_CONF para override per-host"
        return 0
    fi

    local wrap; wrap="$(wrapper_for "$name")"

    # Auth-fail flag silences this repo until user resolves and runs --reset-auth.
    # --full bypasses with an explicit notice — user invoking `bup --full`
    # explicitly intends to force, silent skip would be confusing.
    if [[ -f "$STATE_DIR/auth-failed-$name" ]]; then
        if (( FULL )); then
            notice "$name: auth-failed flag present; clearing for --full attempt (rode \`gh auth refresh\` se preciso)"
            rm -f "$STATE_DIR/auth-failed-$name"
        else
            dbg "skip $name (auth-failed flag present; run \`$wrap --reset-auth\` after fixing)"
            return 0
        fi
    fi

    # ─── Pre-flight: branch must be main ────────────────────────────
    local branch
    branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo '')"
    if [[ -z "$branch" ]]; then
        dbg "skip $name (detached HEAD or unreadable branch)"
        return 0
    fi
    if [[ "$branch" != "main" ]]; then
        notice "pulado: $name em branch $branch"
        return 0
    fi

    # ─── Pre-flight: working tree must be clean ─────────────────────
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
        notice "pulado: $name tem mudanças não-commitadas"
        return 0
    fi

    # ─── Fetch (with timeout + auth-fail detection) ─────────────────
    local fetch_err fetch_rc
    fetch_err="$(_run_with_timeout "$AUTO_UPDATE_FETCH_TIMEOUT" git -C "$repo" fetch --quiet 2>&1)" \
        && fetch_rc=0 || fetch_rc=$?
    if (( fetch_rc != 0 )); then
        if echo "$fetch_err" | grep -qE 'Authentication failed|Permission denied|could not read Username|HTTP/.*40[13]'; then
            warn "$name: auth failed — rode \`gh auth refresh\` então \`$wrap --reset-auth\`"
            touch "$STATE_DIR/auth-failed-$name"
        fi
        # Other failures (timeout, transient network): NOOP silencioso (spec §4.5).
        dbg "$name: fetch rc=$fetch_rc (silent skip)"
        return 0
    fi

    # ─── Pre-flight: upstream must be configured ────────────────────
    local head_remote
    head_remote="$(git -C "$repo" rev-parse '@{upstream}' 2>/dev/null || echo '')"
    if [[ -z "$head_remote" ]]; then
        dbg "skip $name (no upstream tracking branch)"
        return 0
    fi

    # ─── --full path: force bootstrap.sh / install.sh, ignore diff ──
    # Skips last-applied/diff/pending-sudo logic and runs the orchestrator
    # in full. Used by `bup --full` (rebootstrap dev-bootstrap from scratch)
    # and `dotup --full` (re-deploy dotfiles). Bumps last-applied on success
    # so the next incremental run sees a fresh baseline.
    if (( FULL )); then
        notice "atualizando $name (--full)"
        # Pre-emptive sudo for dev-bootstrap (bootstrap.sh runs apt/brew/services).
        # dotfiles install.sh is HOME-only — no sudo needed.
        if [[ "$name" == "dev-bootstrap" ]]; then
            notice "$name: --full requer sudo (bootstrap.sh roda apt/brew/services)"
            if ! sudo -v 2>/dev/null; then
                warn "$name: sudo cancelado — abortando --full"
                return 1
            fi
        fi
        # Pull and ABORT on failure — `--full` against a stale tree would then
        # bump last-applied to upstream HEAD even though the working tree
        # never received those commits, creating invisible state divergence.
        # Pre-flights above guarantee FF-safe; capture stderr to surface why
        # if a hook / lock / FS error breaks pull anyway.
        local pull_err
        if ! pull_err="$(git -C "$repo" pull --ff-only --quiet 2>&1)"; then
            err "$name: git pull --ff-only falhou em --full — abortando sem rebootstrap"
            [[ -n "$pull_err" ]] && printf '    %s\n' "$pull_err" >&2
            return 1
        fi
        if [[ "$name" == "dev-bootstrap" ]]; then
            # -i/--interactive drops --non-interactive so bootstrap.sh shows
            # its whiptail menu (used to validate new opt-ins like postgres
            # without committing config.env tweaks first). Default stays
            # automated so the shell-start hook never blocks on a prompt.
            #
            # CRITICAL: do NOT pipe through `sed` when interactive — the pipe
            # makes stdout a non-TTY, and whiptail (plus any other dialog)
            # falls back to non-interactive mode silently. The pretty-prefix
            # cosmetic loses to having the menu actually render. Default
            # mode keeps the pipe so the shell-start hook output stays
            # uniform.
            local bootstrap_rc=0
            if (( INTERACTIVE )); then
                notice "$name: --interactive — bootstrap.sh roda com menu (output direto pro TTY, sem prefix)"
                bash "$repo/bootstrap.sh" || bootstrap_rc=$?
            else
                bash "$repo/bootstrap.sh" --non-interactive 2>&1 | sed 's/^/    /' || bootstrap_rc=$?
            fi
            if (( bootstrap_rc != 0 )); then
                warn "$name: bootstrap.sh --full falhou — last-applied NÃO bumped"
                return 1
            fi
        elif [[ "$name" == "dotfiles" ]]; then
            if ! bash "$repo/install.sh" 2>&1 | sed 's/^/    /'; then
                warn "$name: install.sh --full falhou — last-applied NÃO bumped"
                return 1
            fi
            # Capture doctor output so the warn is actionable — silent
            # `>/dev/null 2>&1` previously made the user re-run by hand.
            if [[ -f "$repo/scripts/doctor.sh" ]]; then
                local doctor_out doctor_rc=0
                doctor_out="$(bash "$repo/scripts/doctor.sh" --quiet 2>&1)" || doctor_rc=$?
                if (( doctor_rc != 0 )); then
                    warn "$name: doctor.sh reporta drift residual após --full"
                    [[ -n "$doctor_out" ]] && printf '%s\n' "$doctor_out" | sed 's/^/    /' >&2
                fi
            fi
        fi
        # Defense in depth: never write empty last-applied. head_remote was
        # validated non-empty above, but a future refactor might move the
        # FULL branch — keep this guard so the worst case is a no-op.
        if [[ -n "$head_remote" ]]; then
            echo "$head_remote" > "$STATE_DIR/last-applied-$name"
        fi
        rm -f "$STATE_DIR/pending-sudo-$name"
        ok "$name reaplicado em modo --full"
        # --full skips the reload + followup tables on purpose: a full
        # rebootstrap re-deploys everything, so per-path reload triggers
        # are redundant. Document via this comment + spec §3.4.
        return 0
    fi

    # ─── Determine baseline (last-applied SHA, or current upstream on first run) ──
    local last_applied
    last_applied="$(cat "$STATE_DIR/last-applied-$name" 2>/dev/null || echo '')"
    if [[ -z "$last_applied" ]]; then
        # First run on this machine: seed with current upstream HEAD; do nothing this round.
        echo "$head_remote" > "$STATE_DIR/last-applied-$name"
        dbg "$name: seeded last-applied=$head_remote (first run, no apply)"
        return 0
    fi

    # ─── Nothing new on remote? → return ────────────────────────────
    if [[ "$last_applied" == "$head_remote" ]]; then
        dbg "$name: up to date ($head_remote)"
        return 0
    fi

    # ─── Pre-flight: local commits ahead → skip ─────────────────────
    local ahead
    ahead="$(git -C "$repo" rev-list --count "${head_remote}..HEAD" 2>/dev/null || echo 0)"
    if (( ahead > 0 )); then
        notice "pulado: $name tem $ahead commit(s) local(is) não-pushed"
        return 0
    fi

    # ─── Pre-flight: fast-forward feasibility ───────────────────────
    if ! git -C "$repo" merge-base --is-ancestor HEAD "$head_remote" 2>/dev/null; then
        warn "$name: pull não fast-forward — resolva manualmente (\`cd $repo && git status\`)"
        return 0
    fi

    # ─── Diff content + paths (used by Phases 3+4) ──────────────────
    local diff_paths diff_content
    diff_paths="$(git -C "$repo" diff --name-only "$last_applied" "$head_remote" 2>/dev/null)"
    diff_content="$(git -C "$repo" diff "$last_applied" "$head_remote" 2>/dev/null)"
    if [[ -z "$diff_paths" ]]; then
        # Edge case: empty diff but SHAs differ (merge commit?). Bump baseline silently.
        echo "$head_remote" > "$STATE_DIR/last-applied-$name"
        dbg "$name: empty diff between $last_applied..$head_remote — baseline bumped"
        return 0
    fi

    # ─── Pending-sudo short-circuit ─────────────────────────────────
    # If user previously cancelled sudo for THIS exact head_remote, stay silent
    # until new commits arrive (so we don't re-prompt every shell start).
    local pending_sudo_file="$STATE_DIR/pending-sudo-$name"
    if [[ -f "$pending_sudo_file" ]]; then
        local pending_sha
        pending_sha="$(cat "$pending_sudo_file" 2>/dev/null || echo '')"
        if [[ "$pending_sha" == "$head_remote" ]]; then
            dbg "$name: pending-sudo for $pending_sha matches current head — silent until new commits"
            return 0
        fi
        # New commits arrived since last cancel — stale flag, drop it.
        rm -f "$pending_sudo_file"
    fi

    notice "atualizando $name ($(echo "$diff_paths" | wc -l | tr -d ' ') arquivo(s))…"
    dbg "diff_paths:"$'\n'"$diff_paths"

    # ─── Apply: sudo heuristic + prompt ─────────────────────────────
    local needs_sudo=0
    if echo "$diff_content" | grep -qE "$AUTO_UPDATE_SUDO_REGEX"; then
        needs_sudo=1
    fi

    local skip_install=0
    if (( needs_sudo )); then
        notice "$name: precisa de sudo para mudanças detectadas"
        if ! sudo -v 2>/dev/null; then
            warn "$name: sudo cancelado — pulando install scripts (re-tente com \`$wrap\`)"
            echo "$head_remote" > "$pending_sudo_file"
            skip_install=1
            # Continua: pull ainda é safe (só atualiza arquivos do repo, não toca sistema).
        fi
    fi

    # ─── Apply: pull (fast-forward, já validado em pre-flight) ──────
    if ! git -C "$repo" pull --ff-only --quiet 2>/dev/null; then
        err "$name: git pull --ff-only falhou (inesperado pós pre-flight)"
        return 1
    fi

    # ─── Apply: re-run install scripts of affected topics (dev-bootstrap) ──
    if (( ! skip_install )) && [[ "$name" == "dev-bootstrap" ]]; then
        local affected_topics
        affected_topics="$(echo "$diff_paths" | grep -oE '^topics/[0-9]+-[^/]+' | sort -u || true)"
        if [[ -n "$affected_topics" ]]; then
            local suffix
            suffix="$(_uname_suffix)"
            local topic installer
            while IFS= read -r topic; do
                installer=""
                for cand in \
                    "$repo/$topic/install.${suffix}.sh" \
                    "$repo/$topic/install.sh"; do
                    if [[ -f "$cand" ]]; then
                        installer="$cand"
                        break
                    fi
                done
                if [[ -n "$installer" ]]; then
                    dbg "$name: re-running $installer"
                    if ! bash "$installer" 2>&1 | sed 's/^/    /'; then
                        warn "$name: $topic install falhou (continuando)"
                    fi
                else
                    dbg "$name: $topic — no install script for suffix=$suffix"
                fi
            done <<< "$affected_topics"
        fi
    fi

    # ─── Apply: re-run install.sh of dotfiles (idempotent, no sudo) ─
    if (( ! skip_install )) && [[ "$name" == "dotfiles" ]]; then
        if ! bash "$repo/install.sh" 2>&1 | sed 's/^/    /'; then
            warn "$name: install.sh falhou (continuando)"
        fi
    fi

    # ─── Validador (apenas dotfiles no MVP) ─────────────────────────
    if (( ! skip_install )) && [[ "$name" == "dotfiles" ]] && [[ -f "$repo/scripts/doctor.sh" ]]; then
        if ! bash "$repo/scripts/doctor.sh" --quiet >/dev/null 2>&1; then
            warn "$name: doctor.sh reporta drift residual — rode \`bash $repo/scripts/doctor.sh\` para detalhes"
        fi
    fi

    # ─── Apply: success — bump last-applied SHA (only if NOT skip_install) ──
    if (( ! skip_install )); then
        echo "$head_remote" > "$STATE_DIR/last-applied-$name"
        ok "$name atualizado"
    else
        # Pull happened but install scripts skipped — DO NOT bump last-applied.
        # Next run will re-detect the same diff and re-prompt sudo.
        # The pending-sudo-<name>-with-matching-SHA short-circuit silences re-prompt
        # until new commits arrive.
        warn "$name: pull aplicado, install scripts pendentes — \`$wrap\` para retentar com sudo"
    fi

    # ─── Reload table matching ──────────────────────────────────────
    # For each diff path × each reload entry: if glob matches, run cmd.
    # "exec-shell-advice" is special — sets SHELL_RC_CHANGED instead of running.
    # bash 3.2 quirk: under `set -u`, "${AUTO_UPDATE_RELOAD[@]}" aborts when
    # the array is empty (e.g. test fixtures with a minimal conf). The
    # ${arr[@]+...} substitution checks set-ness before expansion. Same
    # pattern as scripts/doctor.sh; see feedback_bash32_compat_macos.md.
    local entry glob cmd path
    for entry in "${AUTO_UPDATE_RELOAD[@]+"${AUTO_UPDATE_RELOAD[@]}"}"; do
        glob="${entry%%:*}"
        cmd="${entry#*:}"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            # Bash pattern match — $glob must be UNquoted to act as pattern.
            # shellcheck disable=SC2053
            if [[ "$path" == $glob ]]; then
                if [[ "$cmd" == "exec-shell-advice" ]]; then
                    SHELL_RC_CHANGED=1
                    dbg "$name: shell rc affected by $path"
                else
                    dbg "$name: reload via \`$cmd\` (matched $path)"
                    # eval needed for cmd with args + redirection; we trust the conf.
                    # Capture stderr so the warn is actionable — bare `2>/dev/null`
                    # left users with `reload \`X\` falhou` and zero context.
                    local reload_err
                    if ! reload_err="$(eval "$cmd" 2>&1)"; then
                        warn "reload \`$cmd\` falhou${reload_err:+: $reload_err}"
                    fi
                fi
            fi
        done <<< "$diff_paths"
    done

    # ─── Followup table matching ────────────────────────────────────
    # Same bash 3.2 empty-array guard as the reload loop above.
    local msg
    for entry in "${AUTO_UPDATE_FOLLOWUPS[@]+"${AUTO_UPDATE_FOLLOWUPS[@]}"}"; do
        glob="${entry%%:*}"
        msg="${entry#*:}"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            # shellcheck disable=SC2053
            if [[ "$path" == $glob ]]; then
                FOLLOWUPS+=("$msg")
                dbg "$name: followup queued for $path → $msg"
                break  # one followup per glob entry, even if multiple paths match
            fi
        done <<< "$diff_paths"
    done

    return 0
}

# ─── Main loop ──────────────────────────────────────────────────────
# -o/--only NAME restricts processing to that repo (matched against the basename
# of each entry in AUTO_UPDATE_REPOS). Used by `mesh update -o <repo>` to scope
# each invocation. Unfiltered runs (e.g. shell-start hook, `mesh update`) still
# cover all repos.
#
# EXIT_RC is the script's overall outcome:
#   0  no work, or all per-repo work succeeded
#   1  any process_repo returned non-zero (e.g. --full bootstrap.sh failed),
#      or -o/--only NAME did not match anything, or no repos configured.
# Honest exit codes matter for piped composition — without this
# the user's `&&` composition would silently mask first-stage failures.
EXIT_RC=0

if (( ${#AUTO_UPDATE_REPOS[@]} == 0 )); then
    err "auto-update: AUTO_UPDATE_REPOS is empty in $CONF"
    exit 1
fi

for repo in "${AUTO_UPDATE_REPOS[@]}"; do
    if [[ -n "$ONLY" && "$(basename "$repo")" != "$ONLY" ]]; then
        continue
    fi
    process_repo "$repo" || { warn "process_repo failed for $repo (continuing)"; EXIT_RC=1; }
done

if [[ -n "$ONLY" ]]; then
    # Sanity check: -o/--only NAME must match at least one configured repo.
    # Typo `-o dotfile` is a user error — fail loud, NOT silent exit 0.
    matched=0
    for repo in "${AUTO_UPDATE_REPOS[@]}"; do
        [[ "$(basename "$repo")" == "$ONLY" ]] && matched=1
    done
    if (( ! matched )); then
        err "auto-update: -o/--only $ONLY did not match any configured repo (AUTO_UPDATE_REPOS in $CONF)"
        EXIT_RC=1
    fi
fi

# ─── Followup summary ───────────────────────────────────────────────
if (( ${#FOLLOWUPS[@]} > 0 )); then
    echo
    echo "${C_DIM}Manual follow-ups:${C_RST}"
    for msg in "${FOLLOWUPS[@]}"; do
        echo "  - $msg"
    done
fi

# ─── mesh snap hook (best-effort, never fails auto-update) ──────────
# After every successful auto-update run (incremental or --full), refresh
# this host's mesh snapshot so the cross-host panel reflects the new
# state without requiring the user to do anything. Hook is intentionally
# silent + tolerant: missing binary, mesh snap exiting non-zero, or
# config gaps must NOT propagate as auto-update failures.
# Spec: docs/2026-05-01-mesh-status-spec.md §5.3.1 + the mesh-cli refactor
# spec (docs/2026-05-02-mesh-cli-refactor-spec.md §4.3) which made `mesh
# snap` the canonical entrypoint replacing the old `mesh-snap` binary.
if command -v mesh >/dev/null 2>&1; then
    mesh snap --quiet >/dev/null 2>&1 || true
fi

# ─── Auto-exec (Phase 5 final wiring) ───────────────────────────────
if (( SHELL_RC_CHANGED )); then
    if (( FROM_SHELL_START )) && (( ${AUTO_EXEC_SHELL:-0} )); then
        notice "shell config mudou — exec zsh"
        # Recursion guard: replaced shell will sourced auto-update.zsh again,
        # but it short-circuits on this flag. See shell/auto-update.zsh.
        export AUTO_UPDATE_RECURSED=1
        exec zsh
    else
        notice "shell config mudou — reabra esta janela ou rode \`exec zsh\`"
    fi
fi

exit "$EXIT_RC"
