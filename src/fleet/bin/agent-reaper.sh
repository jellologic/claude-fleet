#!/usr/bin/env bash
# Reclaim crashed/abandoned claims. ORPHAN (no PR) reaped by default — clean ones
# also drop their remote ref so the issue is re-claimable; ORPHAN+WORK kept unless
# --force; STALE (idle PR > --stale h) reaped in stale mode; LIVE kept.
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
ROOT="$(repo_root)"; git -C "$ROOT" worktree prune
reaped=0; kept=0

reap() {  # issue cls [force_remote]
  local n="$1" cls="$2" fr="${3:-0}" args
  if [ "$DRY" = 1 ]; then echo "  [dry-run] would reap #$n ($cls)"; return; fi
  if [ "$DELREMOTE" = 1 ] || [ "$fr" = 1 ]; then args="$n --delete-remote"; else args="$n"; fi
  # shellcheck disable=SC2086
  if "$HERE/agent-release.sh" $args >/dev/null 2>&1; then echo "  reaped #$n ($cls)"; reaped=$((reaped+1)); else echo "  WARN: reap #$n failed"; fi
}

while read -r br; do
  [ -z "$br" ] && continue
  n="${br#agent/issue-}"
  meta="$(gh pr list --head "$br" --state open --json number,updatedAt --jq '(.[0] // empty) | "\(.number) \(.updatedAt)"' 2>/dev/null || true)"
  if [ -z "$meta" ]; then
    ahead="$(git -C "$ROOT" rev-list --count "origin/$FLEET_MAIN..$br" 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -le 1 ]; then reap "$n" "ORPHAN" 1
    elif [ "$FORCE" = 1 ]; then reap "$n" "ORPHAN+WORK(forced)"
    else echo "  kept #$n (ORPHAN+WORK: $ahead commits ahead — use --force)"; kept=$((kept+1)); fi
  elif [ -n "$STALE" ]; then
    upd="${meta#* }"
    age="$(python3 -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()//3600))' "$upd" 2>/dev/null || echo 0)"
    if [ "$age" -ge "$STALE" ]; then reap "$n" "STALE(${age}h)"; else echo "  kept #$n (LIVE ${age}h)"; kept=$((kept+1)); fi
  else
    echo "  kept #$n (LIVE: open PR)"; kept=$((kept+1))
  fi
done < <(git -C "$ROOT" worktree list --porcelain | awk '/^branch refs\/heads\/agent\/issue-/{sub(/^branch refs\/heads\//,"");print}')
echo "reaper: reaped=$reaped kept=$kept"
