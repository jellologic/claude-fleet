---
description: Atomically claim a GitHub issue (branch-ref lock + draft PR) and spin its worktree
argument-hint: <issue-number>
allowed-tools: Bash(.fleet/bin/agent-claim.sh:*), Bash(.fleet/bin/fleet:*), Bash(gh issue list:*), Bash(gh issue view:*)
---
Open issues ready to claim (label `agent-ready`):

!`gh issue list --label agent-ready --state open --limit 30 2>/dev/null || echo "(none, or gh not authenticated)"`

Claim issue **#$1** for this agent. Run exactly:

```
.fleet/bin/fleet claim $1
```

The branch ref `agent/issue-$1` **is** the lock: the worktree is the local mutex, the
`git push` is a server-side compare-and-swap (a second host is rejected). On success it
bootstraps the worktree, opens a draft PR (`Closes #$1`), flips the issue to `agent-working`,
and records it in `WORKTREES.md`. If rejected, the issue is already claimed — pick another.
On success, `cd` into the printed worktree and do ALL work there. To also gate file ownership,
set `FLEET_CLAIM_OWNS="<glob>,<glob>"` before claiming.
