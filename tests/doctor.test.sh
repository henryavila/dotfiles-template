#!/usr/bin/env bash
# tests/doctor.test.sh — covers scripts/doctor.sh drift detection.
#
# Strategy: build a synthetic dotfiles repo + $HOME under $TESTROOT,
# stage MAPPINGS in a fake install.sh, deploy/skew files according to
# the scenario, run doctor.sh against that fixture, assert exit code +
# drift_items count from the JSON output.
#
# Coverage:
#   - managed_block in sync (block matches src; user lines preserved) → ok
#   - managed_block content drift (block mutated)                     → drift
#   - managed_block markers missing                                   → drift
#   - managed_block + src has trailing newline edge case              → ok
#   - overwrite in sync                                               → ok (regression)
#   - overwrite drift                                                 → drift (regression)
#   - once mode                                                       → ok (regression)
#   - missing dst                                                     → missing (regression)
#
# Bash 3.2 compatible (macOS default).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DOCTOR_SRC="$ROOT/scripts/doctor.sh"

[[ -x "$DOCTOR_SRC" ]] || { echo "doctor.sh not executable at $DOCTOR_SRC" >&2; exit 1; }

PASS=0
FAIL=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_RST=""
fi

_pass() { PASS=$((PASS+1)); printf "  ${C_OK}✓${C_RST} %s\n" "$1"; }
_fail() { FAIL=$((FAIL+1)); printf "  ${C_ERR}✗${C_RST} %s\n" "$1" >&2; [[ -n "${2:-}" ]] && printf "    output: %s\n" "$2" >&2; }

TESTROOT=$(mktemp -d /tmp/doctor-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

echo
echo "── doctor.sh drift detection tests"
echo

# ─── Fixture builder ───────────────────────────────────────────────
# Build an isolated synthetic "fork" with:
#   $fork/scripts/doctor.sh   — copy of the doctor we're testing
#   $fork/install.sh          — minimal stub holding only the MAPPINGS array
#                               we want exercised in this scenario
#   $fork/<src files>         — the actual repo sources to compare against
#   $fake_home                — the destination side of the deploy
_make_fork() {
    local fork="$1"
    rm -rf "$fork"
    mkdir -p "$fork/scripts"
    cp "$DOCTOR_SRC" "$fork/scripts/doctor.sh"
    chmod +x "$fork/scripts/doctor.sh"
}

# Write a minimal install.sh whose only job is to hold MAPPINGS in the
# exact format doctor.sh's awk parser expects (between `MAPPINGS=(` and
# the closing `)` line).
_write_install_with_mappings() {
    local fork="$1"; shift
    {
        echo '#!/usr/bin/env bash'
        echo 'MAPPINGS=('
        for entry in "$@"; do
            echo "    \"$entry\""
        done
        echo ')'
    } > "$fork/install.sh"
}

# Run doctor.sh in JSON mode against the synthetic fork. Returns the
# json blob on stdout; rc=0 if green, rc=1 if drift/missing.
_run_doctor_json() {
    local fork="$1" fake_home="$2"
    local out rc
    out=$(HOME="$fake_home" NO_COLOR=1 bash "$fork/scripts/doctor.sh" --json 2>/dev/null); rc=$?
    printf '%s\n' "$out"
    return $rc
}

# Quick JSON field extractor — avoids a jq dependency.
_jq_count() {
    local key="$1" json="$2"
    echo "$json" | grep -oE "\"$key\":[0-9]+" | head -1 | cut -d: -f2
}

# ─── Scenarios ─────────────────────────────────────────────────────

test_managed_block_in_sync() {
    local fork="$TESTROOT/fork-mb-sync"
    local fake_home="$TESTROOT/home-mb-sync"
    _make_fork "$fork"
    mkdir -p "$fork/ssh" "$fake_home/.ssh"

    # Source the deploy: 2 mesh keys.
    cat > "$fork/ssh/authorized_keys" <<'EOF'
ssh-ed25519 AAAA...mac mac@mesh
ssh-ed25519 AAAA...crc crc@mesh
EOF

    # Destination has the managed block + an external user-owned line
    # outside the markers (matching install.sh's preserve-outside semantics).
    cat > "$fake_home/.ssh/authorized_keys" <<'EOF'
ssh-rsa AAAAB3NzaC1yc2E...ci ci-runner@build-server
# >>> BEGIN dotfiles-managed: ssh/authorized_keys >>>
ssh-ed25519 AAAA...mac mac@mesh
ssh-ed25519 AAAA...crc crc@mesh
# <<< END dotfiles-managed: ssh/authorized_keys <<<
EOF

    _write_install_with_mappings "$fork" \
        "ssh/authorized_keys|\$HOME/.ssh/authorized_keys|managed_block"

    local json drift ok
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    ok=$(_jq_count ok "$json")
    if [[ "$drift" == "0" ]] && [[ "$ok" == "1" ]]; then
        _pass "managed_block in-sync (preserved outside lines, block matches src) → no drift"
    else
        _fail "in-sync managed_block reported drift" "$json"
    fi
}

test_managed_block_content_drifted() {
    local fork="$TESTROOT/fork-mb-drift"
    local fake_home="$TESTROOT/home-mb-drift"
    _make_fork "$fork"
    mkdir -p "$fork/ssh" "$fake_home/.ssh"

    cat > "$fork/ssh/authorized_keys" <<'EOF'
ssh-ed25519 AAAA...mac mac@mesh
ssh-ed25519 AAAA...crc crc@mesh
EOF

    # dst has the markers but the block content disagrees with src
    # (only 1 of the 2 mesh keys present — simulates a stale machine).
    cat > "$fake_home/.ssh/authorized_keys" <<'EOF'
# >>> BEGIN dotfiles-managed: ssh/authorized_keys >>>
ssh-ed25519 AAAA...mac mac@mesh
# <<< END dotfiles-managed: ssh/authorized_keys <<<
EOF

    _write_install_with_mappings "$fork" \
        "ssh/authorized_keys|\$HOME/.ssh/authorized_keys|managed_block"

    local json drift ok
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    ok=$(_jq_count ok "$json")
    if [[ "$drift" == "1" ]] && [[ "$ok" == "0" ]]; then
        _pass "managed_block content drift (block lacks one mesh key) → reported"
    else
        _fail "content drift not detected" "$json"
    fi
}

test_managed_block_markers_missing() {
    local fork="$TESTROOT/fork-mb-missing"
    local fake_home="$TESTROOT/home-mb-missing"
    _make_fork "$fork"
    mkdir -p "$fork/ssh" "$fake_home/.ssh"

    cat > "$fork/ssh/authorized_keys" <<'EOF'
ssh-ed25519 AAAA...mac mac@mesh
EOF

    # dst exists but has no managed-block markers at all (e.g. user
    # rebuilt the file by hand and forgot to leave the splice region in).
    cat > "$fake_home/.ssh/authorized_keys" <<'EOF'
ssh-rsa AAAAB3NzaC1yc2E...adhoc adhoc-key@laptop
EOF

    _write_install_with_mappings "$fork" \
        "ssh/authorized_keys|\$HOME/.ssh/authorized_keys|managed_block"

    local json drift ok
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    ok=$(_jq_count ok "$json")
    if [[ "$drift" == "1" ]] && [[ "$ok" == "0" ]]; then
        _pass "managed_block markers absent → reported as drift"
    else
        _fail "missing markers not flagged" "$json"
    fi
}

test_managed_block_src_no_trailing_newline() {
    # install.sh's print_with_eol appends \n iff src is non-empty AND its
    # last byte is non-newline. The doctor must mirror that exactly or
    # cmp will lie. This pins the matching behavior.
    local fork="$TESTROOT/fork-mb-nonl"
    local fake_home="$TESTROOT/home-mb-nonl"
    _make_fork "$fork"
    mkdir -p "$fork/ssh" "$fake_home/.ssh"

    # src deliberately ends without \n (printf, not echo).
    printf 'ssh-ed25519 AAAA...mac mac@mesh' > "$fork/ssh/authorized_keys"

    # dst has the block as install.sh would have produced it (with
    # appended \n).
    cat > "$fake_home/.ssh/authorized_keys" <<'EOF'
# >>> BEGIN dotfiles-managed: ssh/authorized_keys >>>
ssh-ed25519 AAAA...mac mac@mesh
# <<< END dotfiles-managed: ssh/authorized_keys <<<
EOF

    _write_install_with_mappings "$fork" \
        "ssh/authorized_keys|\$HOME/.ssh/authorized_keys|managed_block"

    local json drift
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    if [[ "$drift" == "0" ]]; then
        _pass "managed_block src without trailing newline → no false drift"
    else
        _fail "trailing-newline edge case false-positive" "$json"
    fi
}

test_overwrite_in_sync() {
    local fork="$TESTROOT/fork-ow-sync"
    local fake_home="$TESTROOT/home-ow-sync"
    _make_fork "$fork"
    mkdir -p "$fork/git" "$fake_home"
    echo "[user]" > "$fork/git/gitconfig.local"
    cp "$fork/git/gitconfig.local" "$fake_home/.gitconfig.local"

    _write_install_with_mappings "$fork" \
        "git/gitconfig.local|\$HOME/.gitconfig.local"

    local json drift ok
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    ok=$(_jq_count ok "$json")
    if [[ "$drift" == "0" ]] && [[ "$ok" == "1" ]]; then
        _pass "overwrite mode in-sync → no drift (regression)"
    else
        _fail "overwrite in-sync miscounted" "$json"
    fi
}

test_overwrite_drifted() {
    local fork="$TESTROOT/fork-ow-drift"
    local fake_home="$TESTROOT/home-ow-drift"
    _make_fork "$fork"
    mkdir -p "$fork/git" "$fake_home"
    echo "[user]" > "$fork/git/gitconfig.local"
    echo "[user.different]" > "$fake_home/.gitconfig.local"

    _write_install_with_mappings "$fork" \
        "git/gitconfig.local|\$HOME/.gitconfig.local"

    local json drift
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    if [[ "$drift" == "1" ]]; then
        _pass "overwrite mode out-of-sync → drift reported (regression)"
    else
        _fail "overwrite drift not flagged" "$json"
    fi
}

test_once_mode_skips_drift() {
    local fork="$TESTROOT/fork-once"
    local fake_home="$TESTROOT/home-once"
    _make_fork "$fork"
    mkdir -p "$fork/config" "$fake_home"
    echo "real-token-not-template" > "$fork/config/s3cfg"
    # dst differs (placeholder edited locally) — once mode must skip.
    echo "user-edited-locally" > "$fake_home/.s3cfg"

    _write_install_with_mappings "$fork" \
        "config/s3cfg|\$HOME/.s3cfg|once"

    local json drift ok
    json=$(_run_doctor_json "$fork" "$fake_home")
    drift=$(_jq_count drift "$json")
    ok=$(_jq_count ok "$json")
    if [[ "$drift" == "0" ]] && [[ "$ok" == "1" ]]; then
        _pass "once mode skips drift (regression)"
    else
        _fail "once mode wrongly flagged drift" "$json"
    fi
}

test_missing_dst() {
    local fork="$TESTROOT/fork-missing"
    local fake_home="$TESTROOT/home-missing"
    _make_fork "$fork"
    mkdir -p "$fork/git" "$fake_home"
    echo "[user]" > "$fork/git/gitconfig.local"
    # No file at $fake_home/.gitconfig.local → expect missing.

    _write_install_with_mappings "$fork" \
        "git/gitconfig.local|\$HOME/.gitconfig.local"

    local json missing
    json=$(_run_doctor_json "$fork" "$fake_home")
    missing=$(_jq_count missing "$json")
    if [[ "$missing" == "1" ]]; then
        _pass "missing dst counted as missing (regression)"
    else
        _fail "missing dst not detected" "$json"
    fi
}

# ─── Run ───────────────────────────────────────────────────────────

test_managed_block_in_sync
test_managed_block_content_drifted
test_managed_block_markers_missing
test_managed_block_src_no_trailing_newline
test_overwrite_in_sync
test_overwrite_drifted
test_once_mode_skips_drift
test_missing_dst

echo
total=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "${C_OK}%d/%d passed${C_RST}\n" "$PASS" "$total"
    exit 0
else
    printf "${C_ERR}%d/%d failed${C_RST}\n" "$FAIL" "$total"
    exit 1
fi
