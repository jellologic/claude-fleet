#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Reclaim crashed/abandoned claims — FAIL CLOSED. A claim is only reaped when gh
# positively answers "no open PR" AND the worktree holds no uncommitted work. If gh
# cannot answer (outage / rate-limit / auth), nothing is reaped.
#
# The claim lock is a REMOTE ref: `agent-claim.sh` pushes `agent/issue-<N>` as a
# compare-and-swap and refuses any issue whose remote branch already exists. The lock
# namespace is therefore GLOBAL while worktrees are LOCAL, so claims are enumerated from
# the UNION of local worktrees and remote `agent/issue-*` refs — a claim held by a host
# that has since died is visible here, and reclaimable, even though this host never had a
# worktree for it.
#
# The remote ref (the CAS lock) is dropped only on POSITIVE evidence the claim is dead:
# gh answered "no open PR" AND there is no uncommitted work AND nothing beyond the claim
# commit AND the claim is older than the stale window. Anything unknown → keep, and say
# why. ORPHAN+UNCOMMITTED / ORPHAN+WORK kept unless --force; STALE (idle PR > --stale h)
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
# A foreign claim has no local branch — its commits are reachable ONLY through the
# remote-tracking ref, so this fetch is a hard precondition for counting them. Fail closed
# rather than judge a claim whose work we cannot see.
git -C "$ROOT" fetch origin --quiet 2>/dev/null || die "could not fetch origin — refusing to reap (cannot see the remote claim refs that hold the locks)"

# How old a claim must be before its remote ref (the CAS lock) may be dropped. Reuses
# --stale when given, 24h otherwise. Stops the reaper from declaring dead a claim another
# host made 30 seconds ago and simply has not pushed work to yet.
RECLAIM_H="${STALE:-24}"
reaped=0; kept=0

reap() {  # issue cls [force_remote]
  local n="$1" cls="$2" fr="${3:-0}" args rem
  if [ "$DELREMOTE" = 1 ] || [ "$fr" = 1 ]; then args="$n --delete-remote"; rem="remote ref dropped (issue fully reclaimable)"
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
# unreadable, assume there IS work. No local worktree (a foreign claim) = nothing local to
# destroy = not dirty.
worktree_dirty() {  # worktree-path (empty = no local worktree)
  local wt="${1:-}" st rc
  [ -n "$wt" ] || return 1
  [ -d "$wt" ] || return 1
  st="$(git -C "$wt" status --porcelain 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && return 0
  [ -n "$st" ]
}

# The ref that actually carries a claim's history. A FOREIGN claim (held by another host)
# has NO local branch, so the bare branch name resolves to nothing: `rev-list
# origin/main..agent/issue-57` errors out, and an `|| echo 0` fallback would then report
# every foreign claim as "0 commits ahead" — i.e. instantly abandoned. That is a fleet-wide
# shredder. Resolve against the remote-tracking ref instead, and print NOTHING when neither
# ref exists so the caller fails closed.
claim_ref() {  # branch
  local br="$1"
  if git -C "$ROOT" rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1; then echo "$br"
  elif git -C "$ROOT" rev-parse --verify -q "refs/remotes/origin/$br" >/dev/null 2>&1; then echo "origin/$br"; fi
}

# Age in hours of a claim's tip commit (committer date). Empty when undeterminable → the
# caller treats "unknown age" as "not provably stale" and keeps the claim.
claim_age_h() {  # ref
  local ct now
  ct="$(git -C "$ROOT" log -1 --format=%ct "$1" 2>/dev/null)" || return 0
  [ -n "$ct" ] || return 0
  now="$(date +%s)"
  echo $(( (now - ct) / 3600 ))
}

# Classify + act on ONE claim. Takes the branch and its local worktree ("" when there is
# none, i.e. a claim held by another host), so local and foreign claims inherit exactly the
# same fail-closed + liveness rules.
process_claim() {  # branch worktree-or-empty
  local br="$1" wt="${2:-}" n ref meta prc ahead upd age cage
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
    ref="$(claim_ref "$br")"
    if [ -z "$ref" ]; then
      echo "  kept #$n (UNKNOWN: neither $br nor origin/$br resolves here — cannot see its work, failing closed)"; kept=$((kept+1)); return
    fi
    ahead="$(git -C "$ROOT" rev-list --count "origin/$FLEET_MAIN..$ref" 2>/dev/null)"
    if [ -z "${ahead:-}" ]; then
      echo "  kept #$n (UNKNOWN: cannot count commits on $ref — failing closed, not reaping)"; kept=$((kept+1)); return
    fi
    if [ "$ahead" -le 1 ]; then
      # Clean (or absent) tree, no PR, nothing but the claim commit. If the claim is ALSO
      # older than the stale window we have POSITIVE evidence it is dead and no work can be
      # lost: fully reclaim it, remote ref included. Otherwise `agent-claim.sh`'s ls-remote
      # guard would keep refusing the issue forever and the reaper would only ever
      # HALF-reclaim. If the claim is RECENT we know nothing — another host may have claimed
      # it seconds ago and not pushed work yet — so keep it and say why. Never the old blind
      # force-remote.
      cage="$(claim_age_h "$ref")"
      if [ -n "$cage" ] && [ "$cage" -ge "$RECLAIM_H" ]; then
        reap "$n" "ORPHAN(dead ${cage}h: gh says no PR, no commits past the claim, no uncommitted work)" 1
      elif [ -n "$wt" ]; then
        # Local, clean, but too recent to call dead: clear the local worktree (nothing to
        # lose) and leave the CAS lock alone (--force / --delete-remote frees the issue).
        reap "$n" "ORPHAN" "$FORCE"
      elif [ "$FORCE" = 1 ]; then
        reap "$n" "FOREIGN(forced)" "$FORCE"
      else
        echo "  kept #$n (FOREIGN-RECENT: claim held on another host, ${cage:-?}h old (< ${RECLAIM_H}h) — too recent to declare dead; use --force or --stale)"; kept=$((kept+1))
      fi
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
LOCAL_BRANCHES=""
while IFS="$TAB" read -r br wt; do
  [ -z "$br" ] && continue
  LOCAL_BRANCHES="$LOCAL_BRANCHES$br
"
  process_claim "$br" "$wt"
done < <(git -C "$ROOT" worktree list --porcelain | awk '
  /^worktree /                         { wt = substr($0, 10) }
  /^branch refs\/heads\/agent\/issue-/ { print substr($0, 19) "\t" wt }')

# --- REMOTE CLAIM ENUMERATION (#21) ---------------------------------------------------
# The lock is a remote ref, so the claim namespace is GLOBAL while worktrees are LOCAL.
# Enumerating worktrees alone left a claim held by a dead host permanently unreclaimable:
# the reaper never saw it (no local worktree) and `fleet claim` kept dying on "claimed on
# another host" (the ls-remote guard). Feed every remote claim ref with no local worktree
# through the SAME process_claim, with an empty worktree arg — there is no local
# uncommitted work to destroy — inheriting the fail-closed + liveness rules verbatim.
while read -r _sha ref; do
  [ -z "${ref:-}" ] && continue
  br="${ref#refs/heads/}"
  case "$br" in agent/issue-*) : ;; *) continue ;; esac
  case "${br#agent/issue-}" in ''|*[!0-9]*) continue ;; esac
  printf '%s' "$LOCAL_BRANCHES" | grep -Fxq "$br" && continue
  process_claim "$br" ""
done < <(git -C "$ROOT" ls-remote --heads origin 'refs/heads/agent/issue-*' 2>/dev/null)
# --- END REMOTE CLAIM ENUMERATION -----------------------------------------------------
echo "reaper: reaped=$reaped kept=$kept"
