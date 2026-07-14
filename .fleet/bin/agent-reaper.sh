#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Reclaim crashed/abandoned claims — FAIL CLOSED. A claim is only reaped when gh
# positively answers "no open PR" AND the worktree holds no uncommitted work. If gh
# cannot answer (outage / rate-limit / auth), nothing is reaped. Dropping the remote ref
# (the CAS lock) never happens implicitly — it needs --force or --delete-remote.
# ORPHAN+UNCOMMITTED / ORPHAN+WORK kept unless --force; STALE (idle PR > --stale h)
# reaped in stale mode; LIVE kept.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

STALE=""; DRY=0; FORCE=0; DELREMOTE=0
while [ $# -gt 0 ]; do case "$1" in
  --stale) STALE="${2:?--stale needs hours}"; shift 2 ;;
  --force) FORCE=1; shift ;;
  --delete-remote) DELREMOTE=1; shift ;;
  --dry-run) DRY=1; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done
command -v gh >/dev/null || die "gh CLI required"
# gh is the ONLY liveness signal we have. If it cannot speak for this repo we cannot tell
# "no open PR" from "no answer" — and guessing costs a live agent its uncommitted work.
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — refusing to reap (cannot distinguish 'no open PR' from 'gh could not answer')"
ROOT="$(repo_root)"; git -C "$ROOT" worktree prune
reaped=0; kept=0

reap() {  # issue cls [force_remote]
  local n="$1" cls="$2" fr="${3:-0}" args rem
  if [ "$DELREMOTE" = 1 ] || [ "$fr" = 1 ]; then args="$n --delete-remote"; rem="remote ref dropped"
  else args="$n"; rem="remote ref KEPT (CAS lock held — re-run with --delete-remote to free the issue)"; fi
  if [ "$DRY" = 1 ]; then echo "  [dry-run] would reap #$n ($cls) — $rem"; return; fi
  # shellcheck disable=SC2086
  if "$HERE/agent-release.sh" $args >/dev/null 2>&1; then echo "  reaped #$n ($cls) — $rem"; reaped=$((reaped+1)); else echo "  WARN: reap #$n failed"; fi
}

# Open-PR lookup that keeps gh's FAILURE separate from gh's ANSWER. Three outcomes:
#   rc 0 + stdout    → an open PR exists (prints "<number> <updatedAt>")
#   rc 0 + no stdout → gh positively answered: there is NO open PR
#   rc 2             → gh COULD NOT ANSWER (network, 5xx, rate-limit, auth). NEVER "no PR".
# Pre-fix this was `... 2>/dev/null || true`, collapsing the third case into the second:
# during a GitHub outage every branch looked PR-less, so a single default run mass-reaped
# every not-yet-committed claim in the fleet.
pr_meta() {  # branch
  local out rc
  out="$(gh pr list --head "$1" --state open --json number,updatedAt --jq '(.[0] // empty) | "\(.number) \(.updatedAt)"' 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && return 2
  printf '%s' "$out"
  return 0
}

# Uncommitted-work liveness probe. `agent-claim.sh` writes EXACTLY ONE empty claim commit,
# so an agent that has worked for hours without committing sits at `ahead == 1` forever —
# by commit count alone it is indistinguishable from a crashed claim, and its draft PR is
# trivially missing (agent-claim treats `gh pr create` as best-effort). The working tree is
# the signal that tells them apart, and it is precisely what a reap destroys
# (agent-release → `git worktree remove --force`). Fail closed: if the status is
# unreadable, assume there IS work.
worktree_dirty() {  # worktree-path (empty = no local worktree)
  local wt="${1:-}" st rc
  [ -n "$wt" ] || return 1
  [ -d "$wt" ] || return 1
  st="$(git -C "$wt" status --porcelain 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && return 0
  [ -n "$st" ]
}

# Classify + act on ONE claim. Takes the branch and its local worktree ("" when there is
# none), so a future remote-claim enumerator can feed it foreign-host claims and inherit
# the same fail-closed + liveness rules unchanged.
process_claim() {  # branch worktree-or-empty
  local br="$1" wt="${2:-}" n meta prc ahead upd age
  n="${br#agent/issue-}"
  meta="$(pr_meta "$br")"; prc=$?

  if [ "$prc" -ne 0 ]; then
    echo "  kept #$n (UNKNOWN: gh could not list PRs — failing closed, not reaping)"; kept=$((kept+1)); return
  fi

  if [ -z "$meta" ]; then
    # gh positively answered: no open PR. That is still not proof the agent is dead.
    if worktree_dirty "$wt"; then
      if [ "$FORCE" = 1 ]; then reap "$n" "ORPHAN+UNCOMMITTED(forced)" "$FORCE"
      else echo "  kept #$n (ORPHAN+UNCOMMITTED: uncommitted work in the worktree — use --force)"; kept=$((kept+1)); fi
      return
    fi
    ahead="$(git -C "$ROOT" rev-list --count "origin/$FLEET_MAIN..$br" 2>/dev/null || echo 0)"
    # ahead<=1 = claim commit only + clean tree + no PR → abandoned. Reap it, but do NOT
    # drop the remote ref implicitly: that releases the CAS lock out from under a claim we
    # may still be wrong about, letting a second agent claim the same issue. The lock drop
    # requires --force or an explicit --delete-remote.
    if [ "${ahead:-0}" -le 1 ]; then reap "$n" "ORPHAN" "$FORCE"
    elif [ "$FORCE" = 1 ]; then reap "$n" "ORPHAN+WORK(forced)" "$FORCE"
    else echo "  kept #$n (ORPHAN+WORK: $ahead commits ahead — use --force)"; kept=$((kept+1)); fi
  elif [ -n "$STALE" ]; then
    upd="${meta#* }"
    age="$(python3 -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()//3600))' "$upd" 2>/dev/null || echo 0)"
    if [ "$age" -ge "$STALE" ]; then reap "$n" "STALE(${age}h)"; else echo "  kept #$n (LIVE ${age}h)"; kept=$((kept+1)); fi
  else
    echo "  kept #$n (LIVE: open PR)"; kept=$((kept+1))
  fi
}

TAB="$(printf '\t')"
while IFS="$TAB" read -r br wt; do
  [ -z "$br" ] && continue
  process_claim "$br" "$wt"
done < <(git -C "$ROOT" worktree list --porcelain | awk '
  /^worktree /                         { wt = substr($0, 10) }
  /^branch refs\/heads\/agent\/issue-/ { print substr($0, 19) "\t" wt }')
echo "reaper: reaped=$reaped kept=$kept"
