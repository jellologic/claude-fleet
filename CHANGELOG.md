# Changelog

All notable changes to claude-fleet are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [SemVer](https://semver.org/).

## [Unreleased]
### Added
- Demo GIF in the README, rendered from `assets/demo.tape` (charmbracelet/vhs) via `assets/demo-setup.sh`. (#11)
- `tests/negatives/reaper-liveness.sh` — negative test (gh stubbed on `PATH`, no network) asserting that a live claim with uncommitted work is not reaped by a default run, that a failing `gh pr list` reaps nothing, and that a genuinely abandoned claim still is. (#22)
- `tests/negatives/reaper-foreign-claims.sh` — negative test (gh stubbed on `PATH`, local bare repo as `origin`, no network) asserting that a claim held on another host (remote ref, no local worktree) is enumerated at all, that a stale/PR-less/work-free one is FULLY reclaimed, that one with pushed work is NOT reaped (the ahead-count must resolve against `origin/<branch>`, not a nonexistent local ref), that a freshly-taken foreign claim is kept, and that #22's fail-closed guarantees hold through the new path. (#21)
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
- `fleet reaper`: **can now reclaim a claim held by a host that died.** The claim lock is a
  REMOTE ref — `fleet claim` pushes `agent/issue-<N>` as a compare-and-swap and its `ls-remote`
  guard refuses any issue whose remote branch exists — so the lock namespace is GLOBAL, but the
  reaper enumerated claims from `git worktree list`, i.e. LOCAL worktrees only. A host that
  claimed an issue, pushed the ref and then died (laptop wiped, CI runner terminated) left an
  issue that no reaper anywhere could see and that `fleet claim` refused forever ("claimed on
  another host"): only a human running `git push origin --delete` could free it. The reaper now
  enumerates the UNION of local worktrees and `ls-remote --heads origin 'refs/heads/agent/issue-*'`,
  feeding foreign claims through the same fail-closed classifier. Two safeguards come with it:
  commits-ahead is counted against the REMOTE-TRACKING ref (`origin/<branch>`) after an explicit
  `git fetch`, never a bare local branch name that does not exist for a foreign claim (which would
  read "0 commits ahead" and reap every foreign claim in the fleet, pushed work and all), and any
  ref that cannot be resolved or counted is kept, not reaped. (#21)
- `fleet reaper`: **full reclamation restored, on positive evidence only.** #22 correctly stopped
  the default path from dropping the remote ref, but that left the reaper HALF-reclaiming — the
  worktree went, the issue went back to `agent-ready`, yet the CAS lock stayed and `fleet claim`
  still refused the issue until someone re-ran with `--delete-remote`. The remote ref is now
  dropped by a default run when, and only when, every one of these holds: `gh` POSITIVELY answered
  (rc 0) that there is no open PR, there is no uncommitted work (or no local worktree at all),
  the branch is no further than the claim commit (`ahead <= 1` vs `origin/<main>`), and the claim
  is older than the stale window (`--stale`, default 24h — a claim taken 30 seconds ago on another
  host is not a dead host). If any of those is false or unknown the claim is kept and the reason is
  printed. (#21)
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
