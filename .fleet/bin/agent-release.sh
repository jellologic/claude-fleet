#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Release a claimed issue: close draft PR, remove worktree, delete local branch,
# drop ledger + ownership entries, relabel agent-ready. Remote kept unless --delete-remote.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

ISSUE="${1:?Usage: agent-release.sh <issue> [--delete-remote]}"
DEL_REMOTE=0; [ "${2:-}" = "--delete-remote" ] && DEL_REMOTE=1
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number: $ISSUE"
command -v gh >/dev/null || die "gh CLI not found"
ROOT="$(repo_root)"; BRANCH="$(branch_for_issue "$ISSUE")"; WT="$ROOT/.fleet/worktrees/$BRANCH"
case "$(pwd -P)/" in "$WT"/*) die "run from the MAIN checkout, not inside $WT" ;; esac

pr="$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
[ -n "${pr:-}" ] && gh pr close "$pr" --comment "Released claim on #$ISSUE." >/dev/null 2>&1 || true
git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
git -C "$ROOT" worktree prune
git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null || true
ledger_remove "$ISSUE" || true
if [ -f "$ROOT/.claude/agent-claims.json" ] && command -v python3 >/dev/null && _coord_lock claims; then
  python3 "$HERE/claims-edit.py" "$ROOT/.claude/agent-claims.json" remove "issue-$ISSUE" 2>/dev/null || true
  _coord_unlock claims || true   # warns (stderr) if our lock was stolen; cleanup continues
fi
gh issue edit "$ISSUE" --add-label "$LABEL_READY" --remove-label "$LABEL_WORKING" >/dev/null 2>&1 || true
if [ "$DEL_REMOTE" = 1 ]; then git -C "$ROOT" push origin --delete "$BRANCH" >/dev/null 2>&1 || echo "WARN: could not delete remote $BRANCH"; fi
echo "RELEASED #$ISSUE — remote branch $( [ "$DEL_REMOTE" = 1 ] && echo deleted || echo kept )."
