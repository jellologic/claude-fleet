# Contributing to claude-fleet

claude-fleet coordinates parallel Claude Code agents — and it **dogfoods itself**, so changes go
through the same flow it provides.

## Reporting bugs
Every script points to **[SELF-REPORT.md](SELF-REPORT.md)**. In short: understand the issue, search
existing issues, then open one with a repro + root cause + `file:line`. (AI agents: get human
approval before filing or commenting.)

## Making changes
`main` is protected — work through a PR:
```sh
.fleet/bin/fleet claim <issue>     # or ad-hoc:  .fleet/bin/fleet wt new <task>
# edit the SOURCE in src/ (not the vendored .fleet/), commit to your agent/* branch, push
gh pr create --fill
.fleet/bin/fleet done <issue>      # after the PR merges
```
- Keep `fleet_gate` green: `bash -n` on shell + `python3 -m py_compile` on python.
- Edit `src/`; the vendored `.fleet/` is refreshed by `install.sh` / `/fleet-update`.
- Keep the core dependency-light: **shell + python3 + git + gh**. No node/bun in the core.

## Scope & philosophy
Small, composable shell/python. Locks are git-native (branch refs). Enforcement is layered
(hooks → gate → ruleset). Anything that lives in a user's repo must be **cleanly removable**.
