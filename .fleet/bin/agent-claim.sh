#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Atomically claim a GitHub issue. Lock = branch ref `agent/issue-<N>`
# (local worktree mutex + remote push compare-and-swap). Optional ownership gate
# via FLEET_CLAIM_OWNS. Stack-agnostic (provisioning via fleet_bootstrap).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

ISSUE="${1:?Usage: agent-claim.sh <issue> [--dry-run]}"
DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number: $ISSUE"
command -v gh >/dev/null || die "gh CLI not found"
ROOT="$(repo_root)"; BRANCH="$(branch_for_issue "$ISSUE")"; WT="$ROOT/.fleet/worktrees/$BRANCH"

rollback_claim() {  # tear down a claim WE fully created (after our own push)
  git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null || true
  git -C "$ROOT" push origin --delete "$BRANCH" >/dev/null 2>&1 || true
}

echo "==> fetching origin"; git -C "$ROOT" fetch origin --quiet
TITLE="$(gh issue view "$ISSUE" --json title --jq .title 2>/dev/null)" || die "issue #$ISSUE not found"
[ "$(gh issue view "$ISSUE" --json state --jq .state)" = "OPEN" ] || die "issue #$ISSUE is not OPEN"
labels="$(gh issue view "$ISSUE" --json labels --jq '.labels[].name')"
printf '%s\n' "$labels" | grep -Fxq "$LABEL_WORKING" && die "issue #$ISSUE already $LABEL_WORKING — pick another"
printf '%s\n' "$labels" | grep -Fxq "$LABEL_READY" || echo "WARN: #$ISSUE not labelled $LABEL_READY (claiming anyway)"
git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 && die "remote $BRANCH exists — #$ISSUE claimed on another host"
[ "$DRY" = 1 ] && { echo "[dry-run] would claim #$ISSUE on $BRANCH"; exit 0; }

echo "==> creating worktree (LOCAL lock)"
"$HERE/worktree-setup.sh" "$BRANCH" "$FLEET_MAIN" >/dev/null || die "could not create worktree for $BRANCH — another local agent holds it"
git -C "$WT" commit --allow-empty -q -m "chore(agent): claim #$ISSUE — $TITLE"

echo "==> pushing $BRANCH (REMOTE compare-and-swap lock)"
LOG="$(mktemp)"
if ! git -C "$WT" push -u origin "$BRANCH" >"$LOG" 2>&1; then
  cat "$LOG" >&2; rm -f "$LOG"
  git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null || true
  die "issue #$ISSUE was claimed by another agent first; pick another"
fi
rm -f "$LOG"

OWNS="${FLEET_CLAIM_OWNS:-${SP_CLAIM_OWNS:-}}"
if [ -n "$OWNS" ]; then
  command -v python3 >/dev/null || { rollback_claim; die "ownership gate needs python3"; }
  echo "==> ownership gate: $OWNS"; MAN="$ROOT/.claude/agent-claims.json"; GLOG="$(mktemp)"
  _coord_lock claims || { rm -f "$GLOG"; rollback_claim; die "ownership gate: lock timeout"; }
  [ -f "$MAN" ] || cp "$ROOT/.claude/agent-claims.template.json" "$MAN"
  if ! python3 "$HERE/claims-edit.py" "$MAN" add "issue-$ISSUE" "$BRANCH" "$OWNS"; then
    _coord_unlock claims; rm -f "$GLOG"; rollback_claim; die "ownership gate: could not record claim"; fi
  if python3 "$HERE/check-claims.py" "$MAN" >"$GLOG" 2>&1; then
    _coord_unlock claims; rm -f "$GLOG"; echo "    ownership registered (disjoint)."
  else
    python3 "$HERE/claims-edit.py" "$MAN" remove "issue-$ISSUE" 2>/dev/null || true
    _coord_unlock claims; grep -E 'OVERLAP|HOT-FILE|forbidden|violation' "$GLOG" | head -5 | sed 's/^/    /' >&2
    rm -f "$GLOG"; rollback_claim; die "claim #$ISSUE REJECTED: declared files overlap an active claim"
  fi
fi

if [ "${FLEET_SKIP_BOOTSTRAP:-${SP_SKIP_BOOTSTRAP:-0}}" = 1 ]; then
  echo "==> skipping bootstrap (run 'fleet wt bootstrap' in the worktree)"
else
  echo "==> bootstrap"; ( cd "$WT" && fleet_bootstrap ) || echo "WARN: bootstrap incomplete"
fi

echo "==> draft PR + labels + ledger"
gh pr create --draft --head "$BRANCH" --base "$FLEET_MAIN" --title "wip(agent): #$ISSUE $TITLE" \
  --body "Closes #$ISSUE

Claimed by agent worktree \`$BRANCH\`." >/dev/null 2>&1 || echo "WARN: draft PR not created (branch lock still holds)"
gh issue edit "$ISSUE" --add-label "$LABEL_WORKING" --remove-label "$LABEL_READY" >/dev/null 2>&1 || true
ledger_add "$ISSUE" "$BRANCH" "$WT" "$TITLE" || true
echo "CLAIMED #$ISSUE → $WT  (branch $BRANCH).  cd in and work; release: fleet release $ISSUE"
