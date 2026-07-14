# Changelog

All notable changes to claude-fleet are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is [SemVer](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-07-14
**Delegation, adversarial review, and a hard look at the rails.** `fleet` gains three verbs that let
you point the fleet *programmatically* — `delegate` (headless OS-sandboxed `claude -p` workers, any
provider), `review` (N=2 adversarial diff-only reviewers whose findings must ship runnable evidence),
and `fanout` (parallel units, refused unless provably disjoint). Alongside them, **eight coordination
and confinement bugs** — several of which could destroy a live agent's work, hand two agents the same
issue, or let a broken tree reach `main` while reporting success. Every fix ships a mutation-checked
negative test: it fails against the buggy code and passes against the fix.
### Added
- `tests/negatives/destructive-git.sh` — 20 deny cases, 19 allow cases, mutation-checked both ways (removing the check lets `reset --hard` through; over-firing blocks `git checkout -- src/foo.py`). (#38)
- **`fleet delegate fanout <manifest.json> [--jobs N] [--dry-run] [--resume]` — N units, one worktree
  each, in parallel — but only if they are PROVABLY DISJOINT.** Two walls shaped this verb, and
  neither of them was the model. **(1) Parallelism does nothing on work that is not disjoint.**
  Anthropic pointed 16 agents at compiling the Linux kernel with their C compiler: *"every agent
  would hit the same bug, fix that bug, and then overwrite each other's changes. Having 16 agents
  running didn't help because each was stuck solving the same task."* N agents on overlapping work is
  strictly **worse** than N=1 — they duplicate the work and then destroy each other's edits — so no
  `--jobs` value can rescue a bad manifest. `fanout` therefore **PROVES** the units' `owns` globs
  pairwise disjoint *before launching anything*, reusing **`check-claims.py`** (fleet's existing
  ownership gate, driven with a claims manifest synthesised from the units, so glob-overlap logic is
  not reimplemented), and **REFUSES the manifest with exit 2** — naming the colliding units and the
  offending path — rather than capping and hoping. Nothing is created: no worktree, no branch, no
  worker. **(2) The ceiling is disk and IOPS.** Bun ran ~64 agents over a 535k-line Zig→Rust port:
  *"The machine ran out of disk space and crashed several times anyway"* and *"One slow `grep`
  command was all it took to freeze disk reads & writes for minutes."* So: a **disk preflight**
  (`units × FLEET_FANOUT_DISK_MB_PER_JOB`, default 512MB) refuses before a single worktree is
  created; workers run under `nice` (and `ionice` where it exists — **macOS has neither, so `nice`
  there bounds CPU, not IOPS; on Linux prefer a cgroup**); and `--jobs` defaults to
  `min(cpu_count/2, 4)` — a conservative **proxy** for I/O headroom and an explicit starting point to
  **tune per machine**, not a measured optimum. Worktrees are created **strictly serially** (16
  concurrent `git worktree add` → 4/16 FAILED on shared-`.git` contention; serially → 16/16
  succeeded) and only the *work* is parallel, never exceeding `--jobs` in flight. Each unit is a
  normal `delegate` run (sandbox, `FLEET_WORKER_*` provider, 429/529 retry-with-backoff) on
  `agent/fanout/<manifest>/<id>`. **A unit's failure does not abort its siblings** — but `fanout`
  **exits non-zero iff any unit failed** (it is a work-runner; `review` is advisory and must never
  block). Per-unit state (`pending`/`running`/`done`/`failed`) + logs persist under
  `.fleet/fanout/<manifest-slug>/` (gitignored) so `--resume` skips units already `done` after a
  crash; `--dry-run` validates the manifest + preflight, prints the plan, and launches nothing.
  Manifest schema and a worked example: `examples/fanout.schema.json`, `examples/fanout.example.json`.
  (#37)
- `tests/negatives/fanout-disjoint.sh` — mutation-checked. Asserts that an **overlapping manifest is
  REFUSED (exit 2) with NO worktree, NO branch and NO worker created** (the load-bearing one — that
  is the Anthropic failure); that a disjoint manifest does run; that **worktree creation is strictly
  serial** (instrumented wrapper, zero overlapping creations); that **`--jobs N` is enforced** (the
  `claude` stub logs enter/exit timestamps and max concurrency must be ≤ N — *and* > 1, so the cap
  assertion cannot pass vacuously on a serial implementation); that one unit's failure does not abort
  its siblings while fanout still exits non-zero; that `--dry-run` launches nothing; that `--resume`
  re-runs only what is not `done`; and that the disk preflight refuses before anything is created.
  Mutation-verified: removing the disjointness check, parallelizing worktree creation, and ignoring
  `--jobs` each make the corresponding assertion fail. (#37)
- **`fleet delegate review <wt> [--reviewers N] [--base <ref>]` — adversarial diff-only reviewers
  that emit EVIDENCE, never verdicts.** N defaults to **2** (Bun ran "1 implementer, 2 or more
  adversarial reviewers per implementer" over a 535k-line Zig→Rust port). Each reviewer is
  **context-asymmetric** — it gets `git diff <base>...HEAD` and *nothing else*: no session id, no
  `--resume`, none of the implementer's reasoning — and its prompt is **refute-framed** ("find the
  way this diff is WRONG"). Reviewers run under a **different, READ-ONLY sandbox profile** from
  `delegate` workers: the worktree *and* the shared `.git` are denied, and the only writable path
  is a per-reviewer scratch dir under `$TMPDIR`. **Every finding must ship an executable artifact**
  — a `repro` (a shell command that must FAIL on HEAD) or a `patch` (a `git apply`-able diff); a
  finding with neither is **DISCARDED, not escalated**. Surviving findings are **adjudicated by the
  REAL gate** in a throwaway worktree: a repro that PASSES on HEAD is REFUTED; a patch that does
  not apply is discarded; a patch that leaves `fleet_gate`'s outcome unchanged is UNSUBSTANTIATED
  (the *fix-guided verification filter*). **`review` NEVER BLOCKS a merge** — it exits 0 whenever
  it RAN, and non-zero only on infrastructure failure. Bun's oracle was `cargo check` + 1.39M test
  assertions, *not* the reviewers; `fleet_gate` and the pre-push hook are fleet's. New
  `FLEET_REVIEW_{BASE_URL,MODEL,TOKEN_FILE,TOKEN}` (each falling back to its `FLEET_WORKER_*` twin)
  let the reviewer be a **different model family** from the implementer — letting a model grade its
  own diff is the one thing you must not do (self-preference bias), and `review` warns when the two
  providers are identical. (#36)
- `tests/negatives/review-evidence.sh` — mutation-checked. Asserts that an artifact-less finding, a
  repro that passes on HEAD, an unappliable patch, and a patch the real gate cannot see are all
  DISCARDED; that a repro which genuinely fails on HEAD and a patch that flips `fleet_gate`
  RED→GREEN survive; that **`review` exits 0 even with substantiated findings**; that a reviewer's
  writes into the reviewed worktree are EPERM and the worktree is byte-for-byte unchanged; and that
  the implementer's session id never reaches a reviewer. (#36)
- Docs: a **rail table** stating exactly what each control binds — the OS sandbox and the GitHub ruleset are load-bearing; the Python guards do **not** bind subprocesses and do **not** survive `--bare`, so they are defence-in-depth only. Plus the standing rules: never launch headless agents with `--bare`, and pin the Claude Code version (re-run `tests/negatives/` on upgrade). (#32)
- `tests/negatives/guard-exit-codes.sh` — tripwire asserting every guard deny path exits **2**, that no input (including malformed JSON and unterminated quotes) yields the fail-open **exit 1**, and that the deliberate exit-0 fail-open paths stay deliberate. Mutation-checked against both guards. Claude Code treats exit 1 as non-blocking and PROCEEDS, so a deny that exits 1 is silently an ALLOW. (#31)
- `fleet gate-check` (`check-gate-integrity.sh`) — asserts the pre-push merge gate is still wired: `core.hooksPath` resolves to `.fleet/githooks`, the hook exists **and is executable** (git silently skips a non-executable hook), `extensions.worktreeConfig` is unset, and no `.git/worktrees/*/config.worktree` overrides `hooksPath`. Called by `fleet integrate` before it will merge anything (`FLEET_SKIP_GATE_CHECK=1` to opt out where hooks are managed elsewhere). It cannot live *inside* the hook — a disabled hook does not run. (#30)
- `tests/negatives/gate-integrity.sh` — mutation-checked; it first proves the bypass is real, then asserts every form is denied. (#30)
- **`fleet delegate` — delegation as a fleet primitive.** Hands a self-contained work-unit to a
  HEADLESS `claude -p` worker running inside a fleet worktree; the orchestrator (a stronger model,
  or a human) reviews, the worker does the labour. Three verbs: `delegate <wt> "<task>"` (one unit,
  `--output-format json`, capturing `session_id`/`result`/cost, session persisted under
  `.fleet/delegate/<wt>/session`), `feedback <wt> "<fix…>"` (`--resume` that session — continues IN
  CONTEXT rather than cold), and `loop <wt> --until '<check>' "<task>"` (self-heal: run → check →
  feed the failure back → repeat, bounded by `--max-iters`, default 3; exit 0 when the check goes
  green, non-zero/escalate when it never does). The `--until` check is the orchestrator's own
  oracle — correctness is gated by it, not by trusting the worker. (#23)
- **Provider-agnostic workers.** `FLEET_WORKER_{BASE_URL,TOKEN_FILE,TOKEN,MODEL,TIMEOUT_MS}` are
  mapped onto the CHILD process's `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` /
  `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` / `API_TIMEOUT_MS`. `ANTHROPIC_BASE_URL` and
  `ANTHROPIC_AUTH_TOKEN` are GLOBAL PER PROCESS — you cannot route different model tiers to
  different providers within one Claude Code process — so delegation is what makes multi-provider
  possible at all: the worker is a SEPARATE process. All tiers are pinned to `FLEET_WORKER_MODEL`
  because the child has exactly one endpoint. The bearer token is read from a mode-600
  `FLEET_WORKER_TOKEN_FILE` (a non-600 file warns loudly) and reaches the worker through the
  environment ONLY — never argv (never `ps`), never a log, never the repo.
  `examples/worker-zai.env.example` ships the z.ai/GLM preset and the Anthropic default, with
  placeholders only. (#23)
- **OS-sandbox confinement for headless workers, fail-closed.** Workers run with
  `--dangerously-skip-permissions`, and fleet's Python `PreToolUse` write-guard does NOT bind
  subprocesses (a `Bash` out-of-worktree redirect, a `sed -i`, a `python3 open(…,'w')` all sail
  through it — it is a Write/Edit-only rail). `fleet delegate` therefore wraps every worker in
  macOS `sandbox-exec` with a generated profile that denies file-writes outside the worktree while
  still permitting the shared `.git` common dir (so `git commit` works from a linked worktree),
  `/tmp`/`$TMPDIR` and the `~/.claude`/`~/.cache`/`~/.npm` caches. `FLEET_DELEGATE_SANDBOX`
  defaults to `1`: if the sandbox is unavailable (`sandbox-exec` missing, or a non-macOS host)
  delegate DIES rather than silently running unconfined, pointing Linux users at Claude Code's
  native sandbox. `FLEET_DELEGATE_SANDBOX=0` is a loud, explicit opt-out. `--bare` is refused
  outright: it disables every hook and is slated to become the `-p` default. (#23)
- **Back-pressure.** Worker invocations retry with jittered exponential backoff on `429`/`529` and
  transport/overload errors (`FLEET_DELEGATE_RETRIES`, default 4) — a headless fleet against a
  hosted gateway will hit them. A worker that genuinely failed the *task* is never retried. (#23)
- `tests/negatives/delegate-confinement.sh` — mutation-tested negative suite (`claude` stubbed on
  `PATH`; no model, no network) asserting that a sandboxed worker CANNOT write outside its worktree
  (out-of-worktree redirect, `python3` subprocess write, and a write into a SIBLING agent's
  worktree — all `EPERM`) yet CAN still `git commit` inside it; that delegate fails CLOSED when the
  sandbox is unavailable and the worker never runs; that the same escape DOES succeed under the
  explicit `FLEET_DELEGATE_SANDBOX=0` opt-out (so the blocks are provably the sandbox's doing); that
  a `529` is retried to success while a genuine task failure is not; that `loop --until` self-heals
  via an in-context `--resume` and escalates non-zero when the check never goes green; and that the
  bearer token never reaches argv or a log. (#23)
- `tests/negatives/pre-push-nonff.sh` — mutation-checked both ways: removing the exemption makes the agent-branch case fail; over-exempting makes the non-CAS case fail. (#41)
- Demo GIF in the README, rendered from `assets/demo.tape` (charmbracelet/vhs) via `assets/demo-setup.sh`. (#11)
- `tests/negatives/reaper-liveness.sh` — negative test (gh stubbed on `PATH`, no network) asserting that a live claim with uncommitted work is not reaped by a default run, that a failing `gh pr list` reaps nothing, and that a genuinely abandoned claim still is. (#22)
- `tests/negatives/reaper-foreign-claims.sh` — negative test (gh stubbed on `PATH`, local bare repo as `origin`, no network) asserting that a claim held on another host (remote ref, no local worktree) is enumerated at all, that a stale/PR-less/work-free one is FULLY reclaimed, that one with pushed work is NOT reaped (the ahead-count must resolve against `origin/<branch>`, not a nonexistent local ref), that a freshly-taken foreign claim is kept, and that #22's fail-closed guarantees hold through the new path. (#21)
- `tests/negatives/coord-lock-ownership.sh` — mutation-checked regression test for the coordination
  mutex: a broken-out holder must not unlock its successor, a slow-but-live holder must not be
  stale-broken, and a genuinely dead holder's lock must still be reclaimable. (#20)
- `FLEET_LOCK_STALE_SECS` (default `60`) — tunes the mutex's staleness window (documented in the
  README; the negative test uses a short one). (#20)
### Fixed
- `tests/negatives/integrate-final-gate.sh`: set `FLEET_SKIP_GATE_CHECK=1`. Since #30, `fleet-integrate` refuses to run unless the pre-push merge gate is wired — so in this test's throwaway (hook-less) repo it died at the gate-integrity check and **never reached the FINAL gate the test exists to exercise**. Two individually-correct changes that only collided once both were on `main`. The test's own precondition assertions caught it and refused to report a vacuous pass. Re-verified mutation-checked: with #18's fix reverted it still fails on the real assertion (`exited 0 with a FAILING final gate`). (#44)
- `coord-guard`: **worktree-wide destructive git is now denied** (`git reset --hard`, `git clean -f`, `git stash`, whole-tree `checkout`/`restore`). This is the exact failure that killed Bun's first parallel run — *"one Claude ran `git stash` before committing. Another ran `git stash pop`. And then `git reset HEAD --hard`. They were stepping on each other!"* — which they fixed with a **prompt rule**. A prompt rule is not a rail. fleet's worktree isolation already prevents the cross-agent version; what remains is self-inflicted and still severe, because since #22 the reaper reads uncommitted work as its liveness signal, so an agent that `reset --hard`s itself looks DEAD and can be reaped out from under its own PR. Deliberately narrow: **path-scoped discards (`git checkout -- src/foo.py`, `git restore src/foo.py`) stay allowed** — a guard that blocks routine work just teaches agents to switch it off. `FLEET_ALLOW_DESTRUCTIVE_GIT=1` is the human override. (#38)
- `coord-guard`: **`core.hooksPath` can no longer silently disable the merge gate.** The pre-push hook *is* fleet's gate and hangs off that config, so `git -c core.hooksPath=/dev/null push origin main` pushed straight to `main` with the gate never firing (reproduced: `* [new branch] main -> main`, exit 0). For a no-CI repo whose only pre-merge check is that hook, this was the whole ballgame. Now denied with `exit 2` in every form: `git -c core.hooksPath=…`, `git config [--worktree|--local|--global] core.hooksPath …`, `git config extensions.worktreeConfig true`, and the `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_*`/`GIT_CONFIG_VALUE_*` env route. Reads (`git config --get core.hooksPath`) are still allowed. Note this guard is defence-in-depth only — per RFC 2a it does not bind subprocesses; the OS sandbox and the GitHub ruleset remain the load-bearing rails. (#30)
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
- `pre-push`: the non-fast-forward block no longer forbids fleet's **own** workflow. It applied to all of `refs/heads/*`, but `fleet claim` pushes a claim commit cut from `main`, and CLAUDE.md then tells you to `git rebase origin/main && git push` — which is non-ff by construction, as is stacking one agent branch on another. Every escape was another rail: `--no-verify` (coord-guard denies it), `core.hooksPath` tampering (#30), or `push --delete` (which releases the CAS lock and closes the PR). A rail whose only escapes are the other rails is a bug, and it pressured agents toward exactly the habit fleet exists to prevent. Protected refs (`main`/`master`/`release/*`) stay **absolutely** blocked; branches in the CAS-owned namespaces (`agent/*`, `worktree/*`, `fix/*`, …) are exempt from the non-ff rule ONLY — the branch-ref CAS gives them exactly one owner, so a force-push there is a rebase of your own history, not a clobber of a peer's. Every other ref keeps the old protection. (#41)
- `tests/negatives/claim-cas-nonce.sh` — forces the same-second two-host claim race in a local bare repo (no GitHub needed) and asserts the loser's push is rejected. Mutation-checked: it fails against the pre-fix code. (#19)
### Fixed
- `fleet claim`: the claim commit now carries a `Claim-Id:` nonce trailer, and the lock push is an explicit create-if-absent compare-and-swap (`--force-with-lease="refs/heads/<branch>:"`). Previously the claim commit had **zero entropy** — identical tree (`--allow-empty` off `main`), identical parent (both hosts had just fetched), identical message (the title comes from `gh issue view`), commonly identical author/committer (one shared fleet identity), and a same-second timestamp — so two hosts racing a freshly-labelled issue built the **byte-identical commit object**. The loser's push of that same sha to that same ref was therefore not a non-fast-forward but a **no-op**: git printed "Everything up-to-date" and exited **0**, so `if ! git push` never fired and **both** hosts won the lock, labelled the issue, wrote the ledger and printed CLAIMED — two agents then worked the same issue on the same branch until one force-pushed over the other. The nonce makes the two claim commits genuine siblings so the CAS can reject the loser; the lease form also closes the TOCTOU window left by the advisory `ls-remote` pre-check. The misleading `WARN: draft PR not created (branch lock still holds)` message — which asserted the very thing that was false in this scenario — is now accurate. (#19)
- `tests/negatives/` — negative tests that assert the guards actually bite. First entry: `integrate-final-gate.sh` (mutation-checked: it fails against the pre-fix code). (#18)
### Fixed
- `fleet-integrate`: a failing **FINAL gate now fails the command**. Previously its status was swallowed by `if gate …; then … else echo FAIL; fi`, and the exit code was taken from the per-branch `FAIL[]` array alone — so an integration where every branch merged and passed individually but the *combined* tree was broken printed `FINAL: FAIL` and still exited **0**. Since a FINAL failure (unlike a per-branch one) is never rolled back, the integration branch was left at the broken merge while reporting success to any caller doing `fleet integrate … && git push`. (#18)
- `fleet-integrate`: the FINAL gate now scopes to the union of changed packages (`git diff <base>..HEAD` → `fleet_pkg_for`) instead of always building the full tree, so unchanged packages (e.g. a web app needing a generated route tree absent in the integration worktree) no longer cause a false FAIL. (#13)
- Example `fleet_bootstrap` + `config.sh.example`: guard against bun's fresh-worktree no-op with `[ -d node_modules ] || bun install --force`. (#14)
- `_coord_lock`/`_coord_unlock`: the mkdir mutex could admit two holders and then free the wrong
  lock. Staleness was decided purely by the lock dir's mtime (set at mkdir, never refreshed), so a
  merely SLOW holder — a cold `git worktree add`, a big `agent-claims.json` rewrite, swap — was
  broken out as if dead; the intruder entered the critical section alongside it (concurrent
  read-modify-write of the claims manifest → a claim silently lost), and the original holder's
  unconditional `rmdir` then deleted the *intruder's* lock, so from then on every unlock freed a
  stranger's lock. Two waiters could also both break the same stale lock and both acquire. Locks now
  carry an `owner` token (host:pid:nonce): unlock is ownership-checked and refuses (warning on
  stderr) if the lock is no longer ours, a stale lock is only broken when its owner is provably gone
  (`kill -0`), and the break is serialized and performed as an atomic rename. (#20)
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

[Unreleased]: https://github.com/jellologic/claude-fleet/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jellologic/claude-fleet/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/jellologic/claude-fleet/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jellologic/claude-fleet/releases/tag/v0.1.0
