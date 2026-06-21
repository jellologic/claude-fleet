#!/usr/bin/env sh
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Wire the committed git hooks via core.hooksPath. Run once per clone (also done
# by install.sh). core.hooksPath is shared by a clone and all its worktrees.
set -eu
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: run inside the git repo." >&2; exit 1; }
root=$(git rev-parse --show-toplevel)
if ! ls "$root"/.fleet/githooks/* >/dev/null 2>&1; then
  echo "ERROR: $root/.fleet/githooks has no hooks." >&2; exit 1
fi
git config core.hooksPath .fleet/githooks
chmod +x "$root"/.fleet/githooks/* 2>/dev/null || true
echo "OK: core.hooksPath -> .fleet/githooks (this clone + all its worktrees)."
echo "Note: hooks are LOCAL feedback (bypassable with --no-verify); the GitHub ruleset is the wall."
