---
description: Release a claimed issue — close its draft PR, remove the worktree, return it to agent-ready
argument-hint: <issue-number> [--delete-remote]
allowed-tools: Bash(.fleet/bin/agent-release.sh:*), Bash(.fleet/bin/fleet:*), Bash(gh pr list:*)
---
Release the claim on issue **#$1** (abandoning or handing off). Run:

```
.fleet/bin/fleet release $ARGUMENTS
```

Closes the draft PR, removes the `agent/issue-$1` worktree, deletes the local branch,
drops the ledger + ownership entries, and relabels the issue back to `agent-ready`. The
remote branch is kept unless you add `--delete-remote`. Run from the MAIN checkout.
