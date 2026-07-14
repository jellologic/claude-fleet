#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Assert the merge gate is still wired (#30). The pre-push hook IS fleet's gate, and it
# hangs off `core.hooksPath`. Anything that repoints or unsets that config disables the
# gate SILENTLY: `git -c core.hooksPath=/dev/null push origin main` pushes straight to
# main and the hook never fires.
#
# This CANNOT live inside the pre-push hook — a disabled hook does not run, so it would
# never get the chance to object. It has to be an out-of-band assertion, which is why it
# is its own command, called by the fleet verbs.
#
# It is also NOT a security boundary. Whoever controls the client can unset the config
# and skip this check too. It catches accident and drift; the GitHub ruleset (and an
# out-of-band re-verify of origin/main) is the authoritative wall.
#
#   fleet gate-check [--quiet]
# exit 0 = wired, exit 2 = TAMPERED/UNWIRED.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
ROOT="$(repo_root)" || { echo "gate-check: not in a git repo" >&2; exit 2; }
say() { [ "$QUIET" = 1 ] || echo "$@"; }
bad() { echo "GATE TAMPERED: $*" >&2; echo "  the pre-push merge gate would NOT run. See issue #30." >&2; exit 2; }

EXPECT=".fleet/githooks"

# 1. core.hooksPath must still resolve to .fleet/githooks.
HP="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"
[ -n "$HP" ] || bad "core.hooksPath is UNSET — run 'fleet install-hooks'"
case "$HP" in
  "$EXPECT"|"$ROOT/$EXPECT") : ;;
  *) bad "core.hooksPath = '$HP' (expected '$EXPECT')" ;;
esac

# 2. The hook it points at must actually exist and be executable.
HOOK="$HP/pre-push"; case "$HP" in /*) : ;; *) HOOK="$ROOT/$HP/pre-push" ;; esac
[ -f "$HOOK" ] || bad "no pre-push hook at '$HOOK'"
[ -x "$HOOK" ] || bad "pre-push hook at '$HOOK' is NOT EXECUTABLE — git silently skips it"

# 3. extensions.worktreeConfig must be unset. With it on, a LINKED worktree can set its
#    own core.hooksPath into .git/worktrees/<n>/config.worktree — invisible from the main
#    worktree, and the gate dies only for that agent.
WTC="$(git -C "$ROOT" config --get extensions.worktreeConfig 2>/dev/null || true)"
case "$WTC" in
  ""|false|"0") : ;;
  *) bad "extensions.worktreeConfig = '$WTC' — a linked worktree can now override core.hooksPath privately" ;;
esac

# 4. Even if the extension is off, an existing per-worktree config file setting hooksPath
#    is a loaded gun (it takes effect the moment the extension is turned back on).
COMMON="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || echo "$ROOT/.git")"
case "$COMMON" in /*) : ;; *) COMMON="$ROOT/$COMMON" ;; esac
if [ -d "$COMMON/worktrees" ]; then
  for cfg in "$COMMON"/worktrees/*/config.worktree; do
    [ -f "$cfg" ] || continue
    if grep -qi 'hookspath' "$cfg" 2>/dev/null; then
      bad "per-worktree config sets hooksPath: $cfg"
    fi
  done
fi

say "gate-check: OK (core.hooksPath=$HP, pre-push present + executable, no per-worktree override)"
exit 0
