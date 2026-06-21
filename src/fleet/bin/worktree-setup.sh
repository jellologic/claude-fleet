#!/usr/bin/env bash
# Create a worktree holding <branch> (the LOCAL lock). Serializes the actual
# `git worktree add` to avoid the concurrent .git/config race.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

BRANCH="${1:?usage: worktree-setup.sh <branch> [base-ref]}"
BASE="${2:-$FLEET_MAIN}"
ROOT="$(repo_root)"
WT="$ROOT/.fleet/worktrees/$BRANCH"

if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "branch $BRANCH already exists locally (held by another worktree)" >&2; exit 1
fi
mkdir -p "$(dirname "$WT")"

_coord_lock worktree || { echo "worktree lock timeout" >&2; exit 1; }
trap '_coord_unlock worktree' EXIT
git -C "$ROOT" worktree add -b "$BRANCH" "$WT" "$BASE" >&2
echo "$WT"
