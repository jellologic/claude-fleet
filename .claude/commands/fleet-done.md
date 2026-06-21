---
description: Post-merge cleanup of a landed claim (worktree + branch + claim; issue stays closed)
argument-hint: <issue-number> [--delete-remote]
allowed-tools: Bash(.fleet/bin/fleet:*), Bash(git status:*), Bash(gh pr list:*)
---
Clean up after issue **#$1**'s PR has **merged**. Run from the MAIN checkout:

```
.fleet/bin/fleet done $ARGUMENTS
```

This verifies the PR merged, removes the `agent/issue-$1` worktree, force-deletes the
(merged) local branch, drops the ledger + ownership-manifest entries, and clears the
`agent-working` label — leaving the issue closed. Use `/release` instead to **abandon**
unmerged work. Don't pass `--force` unless I confirm the work really landed.
