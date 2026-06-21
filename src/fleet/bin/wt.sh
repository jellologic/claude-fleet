#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Worktree helper. Stack-agnostic: provisioning is delegated to fleet_bootstrap.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"
root="$(repo_root)"; WT_DIR="$root/.fleet/worktrees"

bootstrap() {
  wt="$1"
  for f in $FLEET_ENV_FILES; do [ -f "$root/$f" ] && [ ! -f "$wt/$f" ] && cp "$root/$f" "$wt/$f"; done
  ( cd "$wt" && fleet_bootstrap )
}

case "${1:-}" in
  new)
    task="${2:?usage: wt.sh new <task>}"
    id="$(_fleet_id)"; branch="agent/${task}-${id}"; wt="$WT_DIR/${task}-${id}"
    git -C "$root" show-ref --verify --quiet "refs/heads/$branch" && die "branch $branch exists; retry"
    git -C "$root" fetch origin --quiet 2>/dev/null || true
    base="$(git -C "$root" rev-parse --verify --quiet "refs/heads/$FLEET_MAIN" || git -C "$root" rev-parse --verify --quiet "origin/$FLEET_MAIN")"
    [ -n "$base" ] || die "no '$FLEET_MAIN' branch to base on"
    mkdir -p "$WT_DIR"
    trap 'git -C "$root" worktree remove --force "$wt" 2>/dev/null || true; git -C "$root" branch -D "$branch" 2>/dev/null || true' EXIT
    "$HERE/worktree-setup.sh" "$branch" "$base" >/dev/null
    bootstrap "$wt"; trap - EXIT
    echo "Worktree ready: $wt  (branch $branch)"; echo "  cd '$wt' && claude" ;;
  bootstrap) bootstrap "$(repo_root)" ;;
  rebase)
    cur="$(git symbolic-ref --short -q HEAD || echo "")"
    case "$cur" in ""|"$FLEET_MAIN"|main|master|release/*) die "rebase must run on a feature branch, not '$cur'";; esac
    git fetch origin --quiet; git rebase "origin/$FLEET_MAIN"; echo "rebased '$cur' onto origin/$FLEET_MAIN" ;;
  reap)
    name="${2:?usage: wt.sh reap <name>}"; case "$name" in /*) target="$name";; *) target="$WT_DIR/$name";; esac
    br="$(git -C "$root" worktree list --porcelain | awk -v p="$target" '$1=="worktree"{w=($2==p)} w&&$1=="branch"{sub(/^refs\/heads\//,"",$2);print $2;exit}')"
    git -C "$root" worktree remove "$target" 2>/dev/null || git -C "$root" worktree remove --force "$target"
    git -C "$root" worktree prune
    if [ -n "$br" ]; then git -C "$root" branch -d "$br" 2>/dev/null && echo "  deleted merged branch $br" || echo "  kept branch $br (unmerged — git branch -D $br)"; fi
    echo "Reaped: $target" ;;
  list) git -C "$root" worktree list ;;
  prune) git -C "$root" worktree prune; echo "pruned" ;;
  *) echo "usage: wt.sh {new <task>|bootstrap|rebase|reap <name>|list|prune}" >&2; exit 1 ;;
esac
