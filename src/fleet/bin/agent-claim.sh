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
# The claim commit MUST carry entropy. Without it, two hosts racing the same issue build
# a byte-identical commit object (same tree — --allow-empty off the same $FLEET_MAIN; same
# parent — both just fetched; same message — the title comes from `gh issue view`; commonly
# the same author/committer identity; and a same-second timestamp, since a freshly-labelled
# issue is picked up simultaneously). Identical tree+parent+ident+message+time = identical
# SHA, so the loser's push is a NO-OP ("Everything up-to-date", exit 0) rather than a
# rejection, and BOTH hosts "win" the compare-and-swap. A per-claim nonce makes the two
# commits genuine siblings, so the CAS below can actually reject the loser.
CLAIM_ID="$(hostname -s 2>/dev/null || echo host)-$$-$(_fleet_id)"
git -C "$WT" commit --allow-empty -q -m "chore(agent): claim #$ISSUE — $TITLE" -m "Claim-Id: $CLAIM_ID"

echo "==> pushing $BRANCH (REMOTE compare-and-swap lock)"
# Explicit create-if-absent CAS: an EMPTY expected value in --force-with-lease=<ref>: means
# "the remote ref must not exist". This does not lean on the fast-forward rule and it closes
# the TOCTOU window left by the advisory `ls-remote` pre-check above.
LOG="$(mktemp)"
if ! git -C "$WT" push --force-with-lease="refs/heads/$BRANCH:" origin "HEAD:refs/heads/$BRANCH" >"$LOG" 2>&1; then
  cat "$LOG" >&2; rm -f "$LOG"
  git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null || true
  die "issue #$ISSUE was claimed by another agent first; pick another"
fi
rm -f "$LOG"
# This push form takes no -u, so track the branch separately.
git -C "$WT" branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true

OWNS="${FLEET_CLAIM_OWNS:-${SP_CLAIM_OWNS:-}}"
if [ -n "$OWNS" ]; then
  command -v python3 >/dev/null || { rollback_claim; die "ownership gate needs python3"; }
  echo "==> ownership gate: $OWNS"; MAN="$ROOT/.claude/agent-claims.json"; GLOG="$(mktemp)"
  _coord_lock claims || { rm -f "$GLOG"; rollback_claim; die "ownership gate: lock timeout"; }
  [ -f "$MAN" ] || cp "$ROOT/.claude/agent-claims.template.json" "$MAN"
  if ! python3 "$HERE/claims-edit.py" "$MAN" add "issue-$ISSUE" "$BRANCH" "$OWNS"; then
    _coord_unlock claims || true;rm -f "$GLOG"; rollback_claim; die "ownership gate: could not record claim"; fi
  if python3 "$HERE/check-claims.py" "$MAN" >"$GLOG" 2>&1; then
    _coord_unlock claims || true;rm -f "$GLOG"; echo "    ownership registered (disjoint)."
  else
    python3 "$HERE/claims-edit.py" "$MAN" remove "issue-$ISSUE" 2>/dev/null || true
    _coord_unlock claims || true;grep -E 'OVERLAP|HOT-FILE|forbidden|violation' "$GLOG" | head -5 | sed 's/^/    /' >&2
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

Claimed by agent worktree \`$BRANCH\`." >/dev/null 2>&1 || echo "WARN: draft PR not created for $BRANCH — cause unknown (a PR may already exist, or gh may be unauthenticated). Verify with 'gh pr list --head $BRANCH' before working; open one manually."
gh issue edit "$ISSUE" --add-label "$LABEL_WORKING" --remove-label "$LABEL_READY" >/dev/null 2>&1 || true
ledger_add "$ISSUE" "$BRANCH" "$WT" "$TITLE" || true
echo "CLAIMED #$ISSUE → $WT  (branch $BRANCH).  cd in and work; release: fleet release $ISSUE"
