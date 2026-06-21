# claude-fleet — install playbook (for Claude Code)

You (Claude Code) are installing claude-fleet into the **current repo**. The lifecycle
is meant to run through you, not a blind script — you tailor config + CLAUDE.md to this
repo. Follow these steps; ask the human before any push / ruleset / `--force`.

## 0. Preconditions
- `git rev-parse --show-toplevel` succeeds (you're in the target repo).
- `python3`, `git`, `gh` are available (`gh auth status`).

## 1. Vendor the machinery (mechanical)
From the claude-fleet clone the human points you at:
```sh
bash <claude-fleet-clone>/install.sh "$(git rev-parse --show-toplevel)"
```
This vendors `.fleet/` (lib, bin, githooks, config stub, uninstall, playbooks) + `.claude/`
(hooks, commands, manifest template), merges `settings.json`, adds `.gitignore` markers, and
wires `core.hooksPath`. It deliberately does **NOT** modify `CLAUDE.md` — that's step 3.

## 2. Tailor `.fleet/config.sh` to THIS repo's stack
Inspect the repo (package.json scripts / turbo / Cargo.toml / Makefile / pyproject…) and set:
- `fleet_bootstrap` — commands to make a fresh worktree runnable (install deps, codegen).
- `fleet_gate "$@"` — the build/test that must pass to integrate (scope by changed unit if you can).
- `FLEET_LOCKFILE`, `FLEET_GENERATED_RE`, `FLEET_MAIN` as appropriate.
See `<clone>/examples/` for references. **Verify** `fleet_bootstrap` and `fleet_gate` actually run.

## 3. Author the CLAUDE.md section — THIS IS YOUR JUDGEMENT, not a paste
There may already be a `CLAUDE.md` with its own structure and voice. Do **not** blindly paste.
- Read the existing `CLAUDE.md` (if any). Note its sections, tone, and what it already covers.
- Write a **concise** claude-fleet section **in this repo's style**, inside these EXACT markers
  (so it stays surgically removable on uninstall):
  ```
  <!-- >>> claude-fleet (managed) >>> -->
  …your tailored section…
  <!-- <<< claude-fleet (managed) <<< -->
  ```
  Append it (or replace an existing managed block). If there's no `CLAUDE.md`, create one with a
  short project header + this block.
- The section MUST convey (phrase for THIS repo, don't just copy):
  1. Claim/finish flow: `.fleet/bin/fleet claim <issue>` → work in the printed worktree → PR → `fleet release <issue>`.
  2. Hard rules: never commit/push/merge to main; one worktree per session; rebase don't merge; **never `--no-verify`** (the coord-guard blocks it anyway).
  3. The **repo-specific ownership seams** — which dirs are safe to edit in parallel vs single-owner — inferred from the repo's actual layout.
  4. The exact `fleet_bootstrap` / `fleet_gate` you set in step 2, so agents know how worktrees are provisioned & gated.
  5. Pointers: `.fleet/CLAUDE.fleet.md` (generic reference) and `.fleet/SELF-REPORT.md` (bug reporting).
- Keep it tight. Integrate with the repo's existing guidance; don't duplicate it.

## 4. Labels, commit, protection
- `gh label create agent-ready; gh label create agent-working` (idempotent).
- Stage the `.fleet/` + `.claude/` + `CLAUDE.md` changes. **Ask the human** before committing/pushing to main.
- `.fleet/bin/fleet ruleset` to protect main (needs admin) — **ask first**.

## 5. Verify + report
- `.fleet/bin/fleet --help` runs; `git config --get core.hooksPath` = `.fleet/githooks`.
- Tell the human: what you set in `config.sh`, a summary of what you wrote in `CLAUDE.md`, and the remaining manual steps (commit/push/ruleset) you held for their approval.

---
_Found a bug in claude-fleet itself? See `.fleet/SELF-REPORT.md` — all outward reporting needs human approval._
