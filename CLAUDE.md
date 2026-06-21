# claude-fleet

This repo **is** claude-fleet — and it **dogfoods itself**: changes go through the same
parallel-agent workflow the tool provides. (`README.md` is the product docs.)

<!-- >>> claude-fleet (managed) >>> -->
## Working on this repo (claude-fleet coordination)

Don't commit to `main` directly — go through the fleet flow:
```sh
.fleet/bin/fleet claim <issue>          # branch-ref lock + worktree + draft PR
cd .fleet/worktrees/agent/issue-<N>     # do ALL work here
# …edit, commit to your agent/* branch…
git fetch origin && git rebase origin/main && git push
gh pr ready                             # human reviews + merges
.fleet/bin/fleet release <issue>        # when done
```
Ad-hoc (no issue): `.fleet/bin/fleet wt new <task>`. Update/remove the tooling: `/fleet-update`, `/fleet-uninstall`.

### Hard rules (enforced by `.fleet/githooks` + the GitHub ruleset)
- NEVER commit/push/merge to `main`. Open a PR.
- One worktree per session; rebase (don't merge); never `--no-verify` (the coord-guard blocks it).

### Edit the SOURCE in `src/`, not the vendored `.fleet/`
`.fleet/` here is claude-fleet **installed into itself** (a mirror of `src/fleet/`). Make product
changes in `src/`; `.fleet/` is refreshed by `install.sh` / `/fleet-update`.

### Ownership seams (safe to edit in parallel when disjoint)
- `src/fleet/bin/**` — the tools (one file per concern).
- `src/fleet/lib/**` — shared shell library.
- `src/fleet/githooks/**` — git hooks · `src/claude/**` — Claude hooks/commands/manifest.
- `src/templates/**`, `examples/**`, `assets/**`, root `*.md` — docs/templates/assets.
- Root scripts (`install.sh`, `uninstall.sh`, `*.py`) — single-owner; coordinate.

### Gate
`fleet_gate` lints shell (`bash -n`/`sh -n`) + parses python (`py_compile`). Keep it green.

### Bug in the tooling? See `.fleet/SELF-REPORT.md` (human approval before any outward report).
<!-- <<< claude-fleet (managed) <<< -->
