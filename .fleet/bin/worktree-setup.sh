#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
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
# `|| true`: _coord_unlock now returns non-zero if our lock was stolen. In an EXIT trap
# under `set -e` that would rewrite the script's exit status, failing a `git worktree add`
# that actually succeeded. The warning on stderr is the signal; the exit code stays ours.
trap '_coord_unlock worktree || true' EXIT
git -C "$ROOT" worktree add -b "$BRANCH" "$WT" "$BASE" >&2
echo "$WT"
