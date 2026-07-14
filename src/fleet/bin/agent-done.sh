#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Post-merge cleanup: the work LANDED. Remove the worktree + the (verified-merged)
# local branch + ledger/ownership entries, and clear the agent-working label WITHOUT
# relabeling agent-ready (the merge already closed the issue). Use `fleet release`
# instead to ABANDON unmerged work.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/fleet/lib/agent-coord-lib.sh
. "$HERE/../lib/agent-coord-lib.sh"

ISSUE="${1:?Usage: agent-done.sh <issue> [--force] [--delete-remote]}"; shift || true
FORCE=0; DELREMOTE=0
for a in "$@"; do case "$a" in --force) FORCE=1 ;; --delete-remote) DELREMOTE=1 ;; esac; done
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number: $ISSUE"
command -v gh >/dev/null || die "gh CLI not found"
ROOT="$(repo_root)"; BRANCH="$(branch_for_issue "$ISSUE")"; WT="$ROOT/.fleet/worktrees/$BRANCH"
case "$(pwd -P)/" in "$WT"/*) die "run from the MAIN checkout, not inside $WT" ;; esac

# Confirm the work actually merged, so force-deleting the local branch is safe
# (rebase/squash merges land under new SHAs, so the branch is not a ff-ancestor of main).
merged="$(gh pr list --head "$BRANCH" --state merged --json number --jq '.[0].number' 2>/dev/null || true)"
if [ -z "$merged" ] && [ "$FORCE" != 1 ]; then
  die "no MERGED PR for $BRANCH — merge it first, or 'fleet release $ISSUE' to abandon (or --force to clean anyway)."
fi

git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
git -C "$ROOT" worktree prune
git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null || true
ledger_remove "$ISSUE" || true
if [ -f "$ROOT/.claude/agent-claims.json" ] && command -v python3 >/dev/null && _coord_lock claims; then
  python3 "$HERE/claims-edit.py" "$ROOT/.claude/agent-claims.json" remove "issue-$ISSUE" 2>/dev/null || true
  _coord_unlock claims || true   # warns (stderr) if our lock was stolen; cleanup continues
fi
# Issue is already closed by the merge (Closes #N); just drop the working label.
gh issue edit "$ISSUE" --remove-label "$LABEL_WORKING" >/dev/null 2>&1 || true
if [ "$DELREMOTE" = 1 ]; then git -C "$ROOT" push origin --delete "$BRANCH" >/dev/null 2>&1 || true; fi

echo "DONE #$ISSUE — work landed; worktree + branch + claim cleaned up (issue left closed)."
