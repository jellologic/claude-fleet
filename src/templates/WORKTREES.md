# Active agent worktrees — claim ledger

Live coordination surface for the parallel-agent fleet. Maintained automatically by
`fleet claim` / `fleet release`. Rows are local working-tree state — a human-readable
**mirror, not the lock itself**. The real lock is the branch ref `agent/issue-<N>`
(local worktree mutex + remote `git push` compare-and-swap).

| issue | branch | worktree | title | claimed (UTC) |
|-------|--------|----------|-------|---------------|
<!-- AGENT-LEDGER:BEGIN -->
<!-- AGENT-LEDGER:END -->
