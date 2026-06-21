# claude-fleet — uninstall playbook (for Claude Code)

Run from the target repo. Removal must be clean and human-reviewed.

1. **Check for active work:** `.fleet/bin/fleet wt list` (and `git worktree list`). If any
   `.fleet/worktrees/*` are active, tell the human and get approval before using `--force`.
2. **Remove:** `.fleet/bin/fleet uninstall` (add `--force` only with explicit approval).
   This removes `.fleet/`, the fleet-only `.claude/` files (hooks, claim/release/fleet-* commands,
   manifest), unmerges only fleet's hooks from `settings.json`, strips the `claude-fleet (managed)`
   marker blocks from `.gitignore` and `CLAUDE.md`, and unsets `core.hooksPath` (only if it's ours).
3. **Verify:** `.fleet/` gone; `git config --get core.hooksPath` empty; no `claude-fleet (managed)`
   block left in `CLAUDE.md`; the human's own hooks/settings/ignores untouched.
4. `.worktreeinclude` is generic Claude Code config — leave it unless the human wants it gone.
5. Show `git status` and ask the human to review + commit the removal. **Do not commit/push without approval.**

---
_Found a bug in claude-fleet itself? See `.fleet/SELF-REPORT.md` — all outward reporting needs human approval._
