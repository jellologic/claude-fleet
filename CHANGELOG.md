# Changelog

All notable changes to claude-fleet are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [SemVer](https://semver.org/).

## [Unreleased]
### Added
- Demo GIF in the README, rendered from `assets/demo.tape` (charmbracelet/vhs) via `assets/demo-setup.sh`. (#11)
- `tests/negatives/reaper-liveness.sh` — negative test (gh stubbed on `PATH`, no network) asserting that a live claim with uncommitted work is not reaped by a default run, that a failing `gh pr list` reaps nothing, and that a genuinely abandoned claim still is. (#22)
### Fixed
- `fleet reaper`: **no longer destroys a live agent's uncommitted work.** Three independent
  faults, all on the default (non-`--force`, non-`--dry-run`) path: (a) `gh pr list`'s exit
  status was swallowed (`2>/dev/null || true`), so "gh could not answer" (outage / 5xx /
  rate-limit / unauthenticated) was indistinguishable from "there is no PR" — one run during
  a GitHub outage mass-reaped every not-yet-committed claim in the fleet; (b) with no PR, the
  only other signal was commits ahead of `main`, and since `fleet claim` writes exactly ONE
  empty claim commit, a live agent that had not committed yet sat at `ahead == 1` forever and
  was classified `ORPHAN`; (c) that path force-deleted the remote ref, releasing the CAS lock
  so a second agent could claim the same issue. The reaper now fails closed on any `gh`
  failure, refuses to reap a worktree with uncommitted work (`git status --porcelain`) without
  `--force`, and never drops the remote ref implicitly (`--force`/`--delete-remote` required). (#22)
- `fleet-integrate`: the FINAL gate now scopes to the union of changed packages (`git diff <base>..HEAD` → `fleet_pkg_for`) instead of always building the full tree, so unchanged packages (e.g. a web app needing a generated route tree absent in the integration worktree) no longer cause a false FAIL. (#13)
- Example `fleet_bootstrap` + `config.sh.example`: guard against bun's fresh-worktree no-op with `[ -d node_modules ] || bun install --force`. (#14)
- Example `fleet_gate` + `config.sh.example`: run **build before check-types** (two sequential `turbo` invocations, not one `turbo run check-types build`) so codegen like the TanStack `routeTree.gen.ts` exists before the typecheck — merges that ADD routes/codegen no longer false-FAIL against a stale generated file. (#16)

## [0.1.1] — 2026-06-21
### Added
- `fleet done <issue>` — post-merge cleanup that removes the worktree, force-deletes the
  verified-merged local branch, drops ledger + ownership-manifest entries, and clears the
  `agent-working` label **without** relabeling `agent-ready` (use `fleet release` to abandon). (#7)
- `/fleet-done` slash command (parity with `/claim`, `/release`). (#9)
- `CONTRIBUTING.md` and a README **FAQ** (discoverability / onboarding).

## [0.1.0] — 2026-06-21
Initial public release.

### Added
- **Branch-ref-as-lock claiming** (`fleet claim` / `fleet release`): local worktree mutex + remote
  `git push` compare-and-swap, draft PR (`Closes #N`), `agent-ready`/`agent-working` labels, and a
  `WORKTREES.md` ledger mirror.
- **Worktree helper** (`fleet wt new|bootstrap|rebase|reap|list|prune`).
- **Crash-recovery reaper** (`fleet reap`): reclaims orphaned/stale claims; clean orphans free the remote ref.
- **Sequential merge gate** (`fleet integrate`): per-merge `fleet_gate` + rollback so broken branches never land.
- **Optional file-ownership launch gate** (`FLEET_CLAIM_OWNS` + `check-claims.py`): rejects overlapping claims at claim time.
- **git hooks** (block `main` commits, branch naming, lockfile serialization, force-push) and
  **Claude Code hooks** (worktree write-guard, coord-guard that blocks `--no-verify`/main-push, SessionStart primer).
- **GitHub ruleset helper** (`fleet ruleset`): PR-only, no force-push, linear, admin break-glass.
- **Stack-agnostic core** — pure shell + python3 + git + gh; per-repo `.fleet/config.sh` (`fleet_bootstrap`, `fleet_gate`).
- **Claude-driven lifecycle** — `INSTALL.md` / `UPDATE.md` / `UNINSTALL.md` playbooks + `/fleet-update`,
  `/fleet-uninstall` slash commands; install **authors a tailored `CLAUDE.md`** managed block.
- **Clean uninstall** (`fleet uninstall`) — surgical, non-destructive, fully removable.
- **Self-report protocol** (`SELF-REPORT.md`) referenced from every script.
- MIT license.

[Unreleased]: https://github.com/jellologic/claude-fleet/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/jellologic/claude-fleet/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jellologic/claude-fleet/releases/tag/v0.1.0
