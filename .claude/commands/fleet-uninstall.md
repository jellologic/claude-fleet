---
description: Cleanly remove claude-fleet from this repo (Claude-driven, reviewed)
allowed-tools: Bash(.fleet/bin/fleet:*), Bash(git status:*), Bash(git worktree list:*), Read
---
Remove claude-fleet from this repository. **Read `.fleet/UNINSTALL.md` and follow it exactly:**
check for active fleet worktrees, run `.fleet/bin/fleet uninstall`, then verify a clean removal
(`.fleet/` gone, `core.hooksPath` unset, no `claude-fleet (managed)` block left in `CLAUDE.md`,
my own settings/hooks/ignores preserved). Show `git status` and ask me to review + commit.

Do NOT commit, push, or pass `--force` without my explicit approval.
