# claude-fleet

Drop-in coordination for running **many Claude Code agents in parallel** on one git
repo without conflicts — branch-ref locks, git worktrees, crash recovery, a merge
gate, and tool-layer guards. Stack-agnostic: the core is pure **shell + python3 + git
+ gh**; language/toolchain specifics live in a small per-repo `config.sh`.

## Why
The git branch ref **is** the lock. Claiming work = `git worktree add` (local mutex)
+ `git push` of `agent/issue-<N>` (server-side compare-and-swap). Two agents — even on
two machines — can never hold the same work. Disjoint file ownership, crash recovery,
and a merge-time build gate close the rest.

## What you get
| Tool | Purpose |
|------|---------|
| `fleet claim <issue>` / `release` | atomic issue claim (lock + worktree + draft PR + labels + ledger) |
| `fleet wt {new,bootstrap,rebase,reap,…}` | worktree lifecycle |
| `fleet integrate <branch> <branches…>` | sequential merge + per-merge gate + rollback |
| `fleet reap [--stale H\|--force]` | reclaim crashed/abandoned claims |
| `fleet check` | validate disjoint file ownership |
| git hooks | block main commits, branch naming, lockfile serialization, force-push |
| Claude hooks | confine writes to the worktree, block secrets, deny `--no-verify`/main-push at the tool layer, session primer |
| GitHub ruleset | PR-only, no force-push, linear (the authoritative wall) |

## Requirements
`bash`/`sh`, `git`, `python3` (guards + ownership gate), and `gh` (issue-driven claiming).
No node/bun required by the core.

## Install
```sh
git clone https://github.com/jellologic/claude-fleet
./claude-fleet/install.sh /path/to/your/repo
```
Then, in your repo:
1. Edit **`.fleet/config.sh`** → set `fleet_bootstrap` (provision a worktree) and
   `fleet_gate` (the integration build/test). See [`examples/`](examples/).
2. `gh label create agent-ready && gh label create agent-working`
3. Commit `.fleet/` + `.claude/` to `main` and push.
4. `.fleet/bin/fleet ruleset` to protect `main`.

`install.sh` is idempotent (re-run to update) and non-destructive (merges `settings.json`,
appends `.gitignore`/`CLAUDE.md`, preserves your `config.sh`).

## Configure (per-repo `.fleet/config.sh`)
Two functions are the only stack-specific bits:
- `fleet_bootstrap` — make a fresh worktree runnable (`bun install`, `cargo fetch`, codegen…).
- `fleet_gate "$@"` — gate the integrated tree (units passed as args; empty = full). Return 0/non-zero.

Plus optional vars: `FLEET_MAIN`, `FLEET_LOCKFILE`, `FLEET_GENERATED_RE`, `FLEET_BRANCH_RE`, …

## Layout (vendored into your repo)
```
.fleet/{config.sh,lib/,bin/,githooks/,worktrees/,locks/}
.claude/{settings.json,hooks/,commands/,agent-claims.{template,schema}.json}
WORKTREES.md  .worktreeinclude
```

## Remove it (clean, no leftovers)
claude-fleet is designed to evict cleanly — it never lives forever in a repo:
```sh
.fleet/bin/fleet uninstall          # surgical reverse of install (--force to also drop active worktrees)
```
It removes `.fleet/`, the fleet-only `.claude/` files, **unmerges only its own hooks** from
`settings.json`, strips the managed marker blocks from `.gitignore`/`CLAUDE.md`, and unsets
`core.hooksPath` (only if it's ours). Your own settings, hooks, and ignores are left untouched.
Then review `git status` and commit.

## Found a bug?
Every script carries a one-line **self-report** header pointing to [`SELF-REPORT.md`](SELF-REPORT.md):
understand the issue → check existing issues → file/comment on
[github.com/jellologic/claude-fleet](https://github.com/jellologic/claude-fleet) → propose a fix —
**always with human approval**. This lets a Claude Code agent spelunking the vendored code know
exactly how to surface a problem upstream instead of silently working around it.

## Pedigree
Extracted from `shippostrepo`, where it was stress- and chaos-tested: same-issue races
(8-way local + 2-host CAS), 10-agent end-to-end fleet, 80-way ledger concurrency,
25 concurrent worktree creations, `kill -9` mid-claim (no corruption, self-heal),
and an 11-case ownership-gate / reaper suite.
