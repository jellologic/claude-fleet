
## Parallel work — claude-fleet coordination

This repo runs MANY agents in parallel. Follow this protocol (full details in `docs/PARALLEL_AGENTS.md` if present).

### Start a task
```sh
.fleet/bin/fleet claim <issue>      # branch-ref lock + worktree + draft PR; cd into the printed worktree
#   (ad-hoc, no issue:  .fleet/bin/fleet wt new <task>)
# …work only in your worktree, commit to YOUR branch…
git fetch origin && git rebase origin/main
git push && gh pr ready             # a human reviews + merges
.fleet/bin/fleet release <issue>    # when done/abandoning
```

### Hard rules (enforced by hooks + the GitHub ruleset)
- NEVER commit/push/merge to `main`/`master`/`release/*`. Open a PR.
- One worktree per session. Rebase (don't merge). Never `--no-verify` (the coord-guard blocks it).
- Dependency/lockfile changes go on a `lockfile/<name>` branch only.
- Write only inside your worktree (the worktree-guard blocks writes elsewhere + to secrets).

### Coordinating who-touches-what
Optionally gate file ownership: claim with `FLEET_CLAIM_OWNS="<glob>,<glob>"` — overlapping
claims are rejected. The integrator merges a batch with `.fleet/bin/fleet integrate <branch> <branches...>`
(per-merge gate + rollback). Reclaim crashed claims with `.fleet/bin/fleet reap`.

### Headless agents (`fleet delegate`)
- **Never** launch a headless agent with `--bare` — it disables every hook, and is slated to become
  the `-p` default. `fleet delegate` refuses it.
- **Pin the Claude Code version** the fleet runs; re-run `tests/negatives/` after any upgrade.
- The Python guards are defence-in-depth, **not** a boundary: they do not bind subprocesses. The OS
  sandbox and the GitHub ruleset are the load-bearing rails. See the README rail table.
- **`fanout` refuses non-disjoint manifests — that is a feature.** If it rejects your manifest,
  **repartition the units; do not crank `--jobs`.** Anthropic's 16 agents on one task "would hit the
  same bug, fix that bug, and then overwrite each other's changes" — N agents on overlapping work is
  worse than N=1. And `--jobs` is a **starting point to tune**, not an optimum: Bun's real ceiling at
  ~64 agents was disk/IOPS ("ran out of disk space and crashed several times").
