#!/usr/bin/env bash
# doctor.sh — status + drift detector for the dotfiles deploy surface.
#
# What it checks:
#   1. For each mapping in install.sh (src|dst[|mode]):
#        ✓ src matches dst byte-for-byte (deploy up to date)
#        ! dst missing (install.sh never ran, or user deleted)
#        ✗ dst drifted (content differs from src)
#   2. For dev-bootstrap-managed files (~/.bashrc, ~/.zshrc, ~/.tmux.conf):
#        ✓ header "managed by dev-bootstrap" present
#        ! marker absent (hand-edited or deployed by another tool)
#   3. Fragments in ~/.bashrc.d/ and ~/.zshrc.d/:
#        Lists owners (topic NN-name) inferred from filename prefix.
#
# Exit codes:
#   0  everything in sync
#   1  drift / missing files detected
#
# Usage:
#   bash scripts/doctor.sh            # human-readable report
#   bash scripts/doctor.sh --quiet    # only drift/missing lines
#   bash scripts/doctor.sh --json     # structured output (for automation)
#
# Override knobs (forks using a non-dev-bootstrap installer):
#   DOCTOR_MARKER_FILES   space-separated list of files to check for the
#                         "managed by" marker. Default: ~/.bashrc ~/.zshrc
#                         ~/.tmux.conf (the three files dev-bootstrap manages).
#   DOCTOR_MARKER_STRING  the substring to look for. Default:
#                         "managed by dev-bootstrap".
#   Example: DOCTOR_MARKER_FILES="$HOME/.zshrc" DOCTOR_MARKER_STRING="managed by chezmoi" bash doctor.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALL="$REPO/install.sh"

QUIET=0
JSON=0
for a in "$@"; do
    case "$a" in
        --quiet|-q) QUIET=1 ;;
        --json)     JSON=1  ;;
        --help|-h)
            sed -n '2,32p' "$0"
            exit 0
            ;;
    esac
done

# ─── Colors ────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RESET=""
fi

# ─── Accumulators ──────────────────────────────────────────────────
count_ok=0 count_drift=0 count_missing=0 count_marker_miss=0
drift_items=() missing_items=() marker_miss_items=()

# ─── Parse MAPPINGS from install.sh ────────────────────────────────
# Pulls lines between `MAPPINGS=(` and the closing `)`, strips quotes,
# expands $HOME, feeds each `src|dst[|mode]` triple through the checker.
parse_mappings() {
    awk '
        /^MAPPINGS=\(/ { inside=1; next }
        inside && /^\)/ { inside=0; next }
        # Skip whitespace-only and comment lines inside the array. Without
        # this, a comment containing a "|" would be passed downstream as if
        # it were a real mapping triple. None today carry "|", but blocks
        # like `# Plugin replication trio (manifest-based; alternative to ...)`
        # could grow into trouble; cheaper to filter at the source.
        inside && /^[ \t]*#/ { next }
        inside {
            gsub(/^[ \t]*"/, "")
            gsub(/"[ \t]*$/, "")
            if ($0 != "") print
        }
    ' "$INSTALL"
}

check_mapping() {
    local raw="$1"
    local src dst mode
    IFS='|' read -r src dst mode <<< "$raw"
    mode="${mode:-overwrite}"
    # Expand $HOME literally (install.sh does the same)
    dst="${dst//\$HOME/$HOME}"
    local src_abs="$REPO/$src"

    # Skip entries whose src is a placeholder we haven't filled in
    [[ ! -f "$src_abs" ]] && return 0

    if [[ ! -e "$dst" ]]; then
        count_missing=$((count_missing + 1))
        missing_items+=("$dst  (src=$src)")
        return 0
    fi

    if [[ "$mode" == "once" ]]; then
        # "once" entries are user-editable after deploy — drift is expected
        # and fine. We only report that the file exists.
        count_ok=$((count_ok + 1))
        return 0
    fi

    if cmp -s "$src_abs" "$dst"; then
        count_ok=$((count_ok + 1))
    else
        count_drift=$((count_drift + 1))
        drift_items+=("$dst  (src=$src)")
    fi
}

# ─── Managed-by marker check ───────────────────────────────────────
# Defaults match the dev-bootstrap convention. Override via env if your
# fork uses a different installer that writes its own marker string.
DOCTOR_MARKER_STRING="${DOCTOR_MARKER_STRING:-managed by dev-bootstrap}"
if [[ -n "${DOCTOR_MARKER_FILES:-}" ]]; then
    # Word-split the env value (space-separated paths, no globbing).
    read -r -a MARKER_FILES <<< "$DOCTOR_MARKER_FILES"
else
    MARKER_FILES=(
        "$HOME/.bashrc"
        "$HOME/.zshrc"
        "$HOME/.tmux.conf"
    )
fi
check_markers() {
    local f
    for f in "${MARKER_FILES[@]}"; do
        [[ ! -f "$f" ]] && continue
        if ! grep -q "$DOCTOR_MARKER_STRING" "$f" 2>/dev/null; then
            count_marker_miss=$((count_marker_miss + 1))
            marker_miss_items+=("$f")
        fi
    done
}

# ─── Fragments listing ─────────────────────────────────────────────
list_fragments() {
    local dir label
    for pair in "$HOME/.bashrc.d:bash" "$HOME/.zshrc.d:zsh"; do
        dir="${pair%%:*}"
        label="${pair##*:}"
        [[ ! -d "$dir" ]] && continue
        if [[ "$QUIET" == 0 ]] && [[ "$JSON" == 0 ]]; then
            echo
            echo "${C_DIM}Fragments in $dir ($label):${C_RESET}"
            # shellcheck disable=SC2012  # human-readable listing
            ls -1 "$dir" 2>/dev/null | sed 's/^/  /'
        fi
    done
}

# ─── Run ───────────────────────────────────────────────────────────
while IFS= read -r line; do
    check_mapping "$line"
done < <(parse_mappings)

check_markers

# ─── Output ────────────────────────────────────────────────────────
if [[ "$JSON" == 1 ]]; then
    # Minimal JSON without jq (so the script has no runtime deps)
    printf '{"ok":%d,"drift":%d,"missing":%d,"marker_miss":%d,' \
        "$count_ok" "$count_drift" "$count_missing" "$count_marker_miss"
    printf '"drift_items":['
    sep=""
    for d in "${drift_items[@]}"; do
        printf '%s"%s"' "$sep" "${d//\"/\\\"}"
        sep=","
    done
    printf '],"missing_items":['
    sep=""
    for d in "${missing_items[@]}"; do
        printf '%s"%s"' "$sep" "${d//\"/\\\"}"
        sep=","
    done
    printf '],"marker_miss_items":['
    sep=""
    for d in "${marker_miss_items[@]}"; do
        printf '%s"%s"' "$sep" "${d//\"/\\\"}"
        sep=","
    done
    printf ']}\n'
else
    if [[ "$QUIET" == 0 ]]; then
        echo "${C_DIM}dotfiles doctor :: $REPO${C_RESET}"
        echo "  ${C_OK}✓${C_RESET} up-to-date  : $count_ok"
        echo "  ${C_WARN}!${C_RESET} missing     : $count_missing"
        echo "  ${C_ERR}✗${C_RESET} drift       : $count_drift"
        echo "  ${C_WARN}!${C_RESET} marker miss : $count_marker_miss"
    fi

    if (( count_missing > 0 )); then
        echo
        echo "${C_WARN}Missing (install.sh never ran, or user deleted):${C_RESET}"
        for m in "${missing_items[@]}"; do echo "  ! $m"; done
    fi
    if (( count_drift > 0 )); then
        echo
        echo "${C_ERR}Drifted (dst differs from src — run install.sh to sync):${C_RESET}"
        for d in "${drift_items[@]}"; do echo "  ✗ $d"; done
    fi
    if (( count_marker_miss > 0 )); then
        echo
        echo "${C_WARN}Missing '$DOCTOR_MARKER_STRING' marker (hand-edited? not from your installer?):${C_RESET}"
        for m in "${marker_miss_items[@]}"; do echo "  ! $m"; done
    fi

    list_fragments
fi

# Exit code: 0 iff no drift/missing
if (( count_drift > 0 || count_missing > 0 )); then
    exit 1
fi
exit 0
