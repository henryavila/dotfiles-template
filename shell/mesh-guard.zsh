# shellcheck shell=bash disable=all
# shell/mesh-guard.zsh — redirects `claude` to your $DOTFILES_DIR when invoked
# from any "mesh" repo so that PROJECT_STATUS.md / autoMemoryDirectory load.
#
# Why this exists: when you have a private dotfiles repo with rich Claude
# memory (`.ai/memory/`) and you `cd` into a sibling public repo (template,
# bootstrap, work projects) and start `claude`, the Claude session loads with
# NO context. Mesh-guard intercepts those invocations and offers to redirect
# you to the canonical dotfiles repo first.
#
# Activation (opt-in by file existence):
#   1. Define your mesh repo paths in $MESH_REPOS_FILE (default:
#      "$DOTFILES_DIR/shell/mesh-repos.list", one path per line).
#   2. Source this file from your shell startup (the template's
#      shell/aliases.sh.example does it conditionally).
#   3. Forks that don't create the list → mesh-guard becomes a no-op.
#
# Override at runtime:
#   `claude --here`      runs in the current cwd without prompt.
#   $DOTFILES_DIR        target dir for redirect (default: $HOME/dotfiles).
#   $MESH_REPOS_FILE     path to the list (default: $DOTFILES_DIR/shell/mesh-repos.list).
#
# Sourced from shell/aliases.sh under a `[[ -n "$ZSH_VERSION" ]]` guard;
# uses zsh-specific syntax (`read -r "var?prompt"`, `print -u2`).
[[ -n "${ZSH_VERSION:-}" ]] || return 0

_MESH_DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
_MESH_REPOS_FILE="${MESH_REPOS_FILE:-$_MESH_DOTFILES_DIR/shell/mesh-repos.list}"

# Load the repo list lazily (file may not exist on a fresh fork — that's OK).
_mesh_load_repos() {
    _MESH_REPOS=()
    [[ -f "$_MESH_REPOS_FILE" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # Skip blanks and comments
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # Expand ~ and $HOME for portability across forks
        line="${line/#\~/$HOME}"
        line="${line//\$HOME/$HOME}"
        # Reject relative paths early — `[[ "$PWD" == "$repo"* ]]` would never
        # match (PWD is always absolute), so a relative entry is dead weight
        # that suggests a misconfigured list. Warn once on shell start so the
        # user notices rather than silently losing the redirect.
        if [[ "$line" != /* ]]; then
            print -u2 "mesh-guard: skipping non-absolute path in $_MESH_REPOS_FILE: $line"
            continue
        fi
        _MESH_REPOS+=("$line")
    done < "$_MESH_REPOS_FILE"
}

claude() {
    # `local -a` declares the array in the caller's frame; zsh's dynamic
    # scoping means assignments inside _mesh_load_repos modify THIS local
    # binding, not a global. Without `local`, `_MESH_REPOS=()` inside the
    # helper would leak the array into the user's shell namespace forever.
    local -a _MESH_REPOS
    if [[ "$1" == "--here" ]]; then
        shift
    else
        _mesh_load_repos
        if (( ${#_MESH_REPOS[@]} > 0 )); then
            local repo
            for repo in "${_MESH_REPOS[@]}"; do
                if [[ "$PWD" == "$repo"* ]]; then
                    print -u2 "↻ You are in $(basename "$PWD") — mesh repo without memory."
                    read -r "ans?Open Claude in $_MESH_DOTFILES_DIR? [Y/n] "
                    [[ "$ans" =~ ^[Nn] ]] || cd "$_MESH_DOTFILES_DIR"
                    break
                fi
            done
        fi
    fi
    command claude "$@"
}
