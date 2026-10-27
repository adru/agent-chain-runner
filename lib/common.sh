#!/usr/bin/env bash
# Shared setup, sourced by the other scripts (never run directly).
#
# Sets: REPO (work tree root), COMMON (the shared .git dir), CHAIN_HOME (state root), LOCKS.
#   CHAIN_REPO   repo to work on (default: the repo containing the current directory)
#   CHAIN_HOME   where runs, worktrees and logs live (default: <repo>/.chain)
#   CHAIN_LOCKS  where lock slots live (default: a per-user folder under $TMPDIR)

chain_resolve() {
  REPO=$(git -C "${CHAIN_REPO:-$PWD}" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "chain: not inside a git repository (set CHAIN_REPO)" >&2; return 2; }
  COMMON=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd)
  CHAIN_HOME=${CHAIN_HOME:-$REPO/.chain}
  LOCKS=${CHAIN_LOCKS:-${TMPDIR:-/tmp}/agent-chain-locks-$(id -u)}
}

# Keep the runner's files out of `git status` without touching the repo's tracked .gitignore.
chain_ignore() {
  local ex="$COMMON/info/exclude" p
  mkdir -p "$COMMON/info"
  for p in "$@"; do
    grep -qxF "$p" "$ex" 2>/dev/null || echo "$p" >> "$ex"
  done
}

chain_valid_id() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]{2,40}$ ]] \
    || { echo "chain: run id must be 3-41 characters: lowercase letters, digits and dashes" >&2; return 2; }
}
