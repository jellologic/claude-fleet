#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# SessionStart hook — orient every agent with the rules + current claims.
# Plain stdout is injected into context. Always exits 0 (non-blocking).
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$ROOT" ] && exit 0
echo "## claude-fleet coordination is ACTIVE (see docs/PARALLEL_AGENTS.md)."
echo "Rules: never commit/push/merge to main; one worktree per session; rebase (don't merge);"
echo "never --no-verify (coord-guard blocks it). Claim: .fleet/bin/fleet claim <issue>  Release: fleet release <issue>."
if [ -f "$ROOT/WORKTREES.md" ]; then
  rows="$(awk '/AGENT-LEDGER:BEGIN/{f=1;next}/AGENT-LEDGER:END/{f=0}f&&/^\| #/{print}' "$ROOT/WORKTREES.md")"
  [ -n "$rows" ] && { echo "Currently claimed (do NOT touch these areas):"; printf '%s\n' "$rows"; }
fi
exit 0
