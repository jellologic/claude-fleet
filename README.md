# claude-fleet

<p align="center"><img src="assets/banner.svg" alt="claude-fleet — run many parallel Claude Code agents on one repo, without conflicts" width="100%"></p>

> Run **many parallel [Claude Code](https://claude.com/claude-code) agents** on one git repo — without conflicts.

![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![runtime: bash + python3](https://img.shields.io/badge/runtime-bash%20%2B%20python3-success)
![stack-agnostic](https://img.shields.io/badge/stack-agnostic-orange)
![for: Claude Code](https://img.shields.io/badge/for-Claude%20Code-8A2BE2)

Coordinate a **fleet of parallel AI coding agents** with **git-worktree branch-ref locks**,
**crash recovery**, a **sequential merge gate**, and **tool-layer guard hooks** — so two agents
never touch the same work, broken branches never reach `main`, and a dead agent never holds a lock.

Then **point the fleet programmatically**: `fleet delegate` hands a work-unit to a **headless,
OS-sandboxed `claude -p` worker** — on *any* provider, including a cheaper model behind an
Anthropic-compatible gateway — `fleet review` runs **N=2 adversarial diff-only reviewers** whose
findings must ship a **runnable repro or patch**, and `fleet fanout` runs many units in parallel
but **refuses a manifest whose units are not provably disjoint**.

The through-line: **workers and reviewers produce evidence; the gate produces verdicts.** An LLM is
never the correctness oracle — your build and test suite are.

Stack-agnostic: the core is pure **shell + python3 + git + gh** (no node/bun); your language and
toolchain specifics live in one small per-repo `config.sh`. Install, update, and remove are all
driven through Claude Code itself.

## Demo
![claude-fleet demo — parallel worktrees, protected main, reviewed PRs](assets/demo.gif)

## Why
The git branch ref **is** the lock. Claiming work = `git worktree add` (local mutex)
+ `git push` of `agent/issue-<N>` (server-side compare-and-swap). Two agents — even on
two machines — can never hold the same work. Disjoint file ownership, crash recovery,
and a merge-time build gate close the rest.

## What you get
| Tool | Purpose |
|------|---------|
| `fleet claim <issue>` / `release` | atomic issue claim (lock + worktree + draft PR + labels + ledger); `release` abandons |
| `fleet done <issue>` | post-merge cleanup — worktree + branch + claim, issue stays closed |
| `fleet wt {new,bootstrap,rebase,reap,…}` | worktree lifecycle |
| `fleet integrate <branch> <branches…>` | sequential merge + per-merge gate + rollback; `--cohort a b` merges a **co-dependent** set first and gates it **once** |
| `fleet reap [--stale H\|--force]` | reclaim crashed/abandoned claims |
| `fleet delegate {delegate,feedback,loop}` | hand a work-unit to a headless, **OS-sandboxed** `claude -p` worker on any provider; `loop --until '<check>'` self-heals against *your* oracle |
| `fleet delegate review <wt> [--reviewers N]` | **N=2 adversarial, diff-only, READ-ONLY reviewers.** Every finding must ship a runnable repro or patch, adjudicated by the real gate. **Advisory — never blocks** |
| `fleet delegate fanout <manifest> [--jobs N]` | N units in parallel worktrees — **refuses a manifest whose units are not provably disjoint** (a `--jobs` cap cannot rescue overlap) |
| `fleet check` | validate disjoint file ownership |
| `fleet gate-check` | assert the merge gate is still wired (`core.hooksPath`) — a disabled hook cannot object to its own disabling |
| git hooks | block main commits, branch naming, lockfile serialization; non-ff allowed only on CAS-owned agent branches |
| Claude hooks | confine writes to the worktree, block secrets, deny `--no-verify` / main-push / `core.hooksPath` tampering / worktree-wide destructive git, at the tool layer |
| OS sandbox | `sandbox-exec` profile binding **every subprocess** of a headless worker — the Python hooks do not |
| GitHub ruleset | PR-only, no force-push, linear (the authoritative wall) |

## Delegation — point the fleet *programmatically* (`fleet delegate`)
Everything above coordinates **human-driven** agents. `fleet delegate` adds the missing "who
drives the agent" primitive: it hands a self-contained work-unit to a **headless `claude -p`
worker** running inside a fleet worktree. The **orchestrator** (a stronger model, or you) reviews;
the **worker** does the labour.

| Verb | What it does |
|------|--------------|
| `fleet delegate delegate <wt> "<task>"` | run one unit headless in that worktree; capture `session_id` / `result` / cost from `--output-format json` |
| `fleet delegate feedback <wt> "<fix…>"` | `--resume` that worktree's session — continue **in context**, not from a cold start |
| `fleet delegate loop <wt> --until '<check>' "<task>"` | **self-heal**: run → run the check → feed its failure back → repeat, bounded by `--max-iters` (default 3). Exit 0 when the check goes green; non-zero (escalate) when it never does. |
| `fleet delegate review <wt> [--reviewers N] [--base <ref>]` | **N=2 adversarial, diff-only, read-only reviewers.** Every finding must ship a runnable repro or patch; the artifact is *executed* and adjudicated by `fleet_gate`. **Advisory — it never blocks.** |
| `fleet delegate fanout <manifest.json> [--jobs N] [--dry-run] [--resume]` | **N units, one worktree each, run in parallel — but only if they are PROVABLY DISJOINT.** Refuses (exit 2) a manifest whose `owns` globs overlap. Worktrees created *serially*, work run *concurrently*. Exits non-zero iff a unit failed. |
| `fleet spec {init\|check\|conform\|stub\|amend <port>}` | ⚠️ **EXPERIMENTAL — unvalidated, see the warning below.** `fanout` proves the units own disjoint **files**; it proves nothing about their **interfaces**. `spec` freezes a **typed, machine-checkable port** on the base branch, makes it **read-only to every unit but its provider**, and extends the disjointness proof to `provides`/`consumes`: **no dangling port, no duplicate provider, no cycle** — or the manifest is REFUSED. `conform` then checks the **implementation against the port** (`fleet_spec_conform`; exit 2 on drift) — **without it a frozen port is DECORATIVE**, and `spec` says so loudly (#57). A **pre-gate**, never the oracle. |
| `fleet fronts [--oracle '<cmd>'] [--shard-by file\|package\|dir] [-o m.json]` | **WORK-FRONT GENERATOR** — writes the manifest `fanout` consumes. Runs the oracle, shards its **failures** into disjoint units. **The oracle decides the decomposition, never a model.** Says **NOT DECOMPOSABLE** and emits ONE unit when the failures don't actually split. |

```sh
.fleet/bin/fleet claim 42
.fleet/bin/fleet delegate loop agent/issue-42 --until 'cargo clippy -- -D warnings' \
  "Fix every clippy warning in src/parser.rs. Do not change behaviour."
# → worker runs headless, the check is the oracle, failures are fed straight back in-context
```
The `--until` check is **your** oracle and runs unsandboxed in the worktree — correctness is gated
by the check, not by trusting the worker.

### `review` — reviewers emit **evidence**, the gate returns the **verdicts**
```sh
.fleet/bin/fleet delegate review agent/issue-42               # N=2, diff = origin/main...HEAD
.fleet/bin/fleet delegate review agent/issue-42 --reviewers 3 --base v1.2.0
```
Bun ran exactly this loop over a 535k-line Zig→Rust port: *"1 implementer, 2 or more adversarial
reviewers per implementer. The reviewer's only job: find bugs & reasons why the code does not
work"*, and each reviewer *"gets the diff and nothing else — none of the implementer's reasoning"*.
So: **N defaults to 2** (that is Bun's number, not a derived optimum), the input is
**context-asymmetric** (the diff, never the implementer's session/transcript/rationale — `review`
never passes a session id and never `--resume`s), and the prompt is **refute-framed**: *find the way
this diff is WRONG*.

But review was never Bun's *gate* — their oracle was `cargo check` plus a suite with 1,386,826
assertions. So `review` is built on one rule:

> **Reviewers produce EVIDENCE. `fleet_gate` produces VERDICTS.**

* **Every finding must ship an executable artifact** — a `repro` (a shell command that *fails* on
  HEAD) or a `patch` (a `git apply`-able diff). A finding with neither is **DISCARDED, not
  escalated**: "a vague logic error with no falsifiable counterexample" is exactly what oracle-less
  LLM reviewers over-produce.
* **The artifact is executed**, in a *throwaway* worktree — never in the worktree under review. A
  repro that **passes** on HEAD is `REFUTED` (the bug does not reproduce). A patch that does not
  apply is discarded. A patch that applies but leaves **`fleet_gate`'s outcome unchanged** is
  `UNSUBSTANTIATED` — this is the *fix-guided verification filter*, the one intervention in the
  literature with a measured ~3x improvement in false-rejection rate.
* **`review` never blocks a merge.** It exits **0 whenever it RAN** — findings or no findings.
  A non-zero exit means the review could not run (no sandbox, no worktree, the reviewer died).
  `fleet_gate` and the pre-push hook are **the gate**; `review` is advisory evidence you go and
  verify.
* **Reviewers are READ-ONLY.** They get a *different* sandbox profile from `delegate` workers: the
  worktree **and** the shared `.git` are denied, and the only writable place is a per-reviewer
  scratch dir under `$TMPDIR` where the findings land. A reviewer that can "fix" the diff is no
  longer an independent observer of it.

**Never let the implementer's own model grade its own diff.** That is the one thing you must not
do: the errors correlate, and a model is subject to self-preference bias on its own output. Point
the reviewer at a *different family* — `FLEET_REVIEW_{BASE_URL,MODEL,TOKEN_FILE,TOKEN}`, each
falling back to its `FLEET_WORKER_*` twin when unset. (`review` warns loudly when the two are
identical.) Spend budget on **decorrelation**, not on more reviewers: ten reviewers once
unanimously endorsed an OpenSSL padding oracle that did not exist — they shared a false premise,
and it took *one* instance that actually compiled the code and ran three tests to kill it.

### `fanout` — the ceiling is **I/O and decomposability**, not the model
```sh
.fleet/bin/fleet delegate fanout units.json --dry-run     # validate + preflight, launch nothing
.fleet/bin/fleet delegate fanout units.json --jobs 4      # N workers, N worktrees, in parallel
.fleet/bin/fleet delegate fanout units.json --resume      # re-run only the units that aren't done
```
```json
{ "units": [
    { "id": "parser",  "owns": ["src/parser/**"],  "task": "…" },
    { "id": "codegen", "owns": ["src/codegen/**"], "task": "…" }
] }
```
Schema + a worked example: [`examples/fanout.schema.json`](examples/fanout.schema.json) ·
[`examples/fanout.example.json`](examples/fanout.example.json). Each unit becomes one `delegate` run
(sandbox, `FLEET_WORKER_*` provider, 429/529 retry) on branch `agent/fanout/<manifest>/<id>` in its
own worktree. Per-unit state lives in `.fleet/fanout/<manifest>/` (gitignored) so `--resume` can pick
up after a crash. **A unit's failure does not abort its siblings** — they are disjoint, so they are
independent — but fanout **exits non-zero iff any unit failed**. (`review` is the opposite: advisory,
never blocks. `fanout` is a work-runner. Do not confuse the two.)

**Disjointness is a PRECONDITION, enforced, not advice.** Anthropic pointed **16 agents** at
compiling the Linux kernel with their C compiler
([source](https://www.anthropic.com/engineering/building-c-compiler)):

> *"every agent would hit the same bug, fix that bug, and then overwrite each other's changes.*
> ***Having 16 agents running didn't help because each was stuck solving the same task.***"

N agents on work that isn't genuinely disjoint don't go faster — they duplicate the work and then
**destroy each other's edits**. That is *worse* than N=1, and **no `--jobs` value rescues it**. So
`fanout` **proves** the units' `owns` globs pairwise disjoint before it launches anything — using
`check-claims.py`, fleet's existing ownership gate, driven with a claims manifest synthesised from
the units — and if they collide it **refuses the whole manifest** (exit 2, naming the colliding units
and the offending path) rather than capping and hoping. **Nothing is created: no worktree, no branch,
no worker.** Repartition, don't crank `--jobs`.

**The cap is derived from I/O headroom, not from a number someone liked.** Bun ran ~64 agents over a
535k-line Zig→Rust port ([source](https://bun.com/blog/bun-in-rust)). What broke was never the model:

> *"The machine ran out of disk space and crashed several times anyway"*
> *"One slow `grep` command was all it took to freeze disk reads & writes for minutes."*

Hence: a **disk preflight** before a single worktree is created (`units × FLEET_FANOUT_DISK_MB_PER_JOB`,
default 512 MB — refuses if headroom is short), `nice` on every worker, and `ionice` where it exists.
`--jobs` defaults to `min(cpu_count / 2, 4)` — an intentionally conservative **proxy** for I/O
headroom and an explicit **starting point to tune per machine**, not a measured optimum. No source
gives a measured per-repo parallel-agent ceiling; Bun's ~64 and Anthropic's 16 are anecdotes from two
projects of very different shape. Set it empirically and instrument it.

> **macOS has no `ionice`.** There, `nice` bounds **CPU, not IOPS** — and IOPS is the thing that
> actually bit Bun. On Linux, prefer a real cgroup (`systemd-run --scope -p IOWeight=…`, which is what
> Bun ended up doing) for an I/O bound. fleet won't pretend otherwise.

**Worktrees are created serially; only the work is parallel.** Firing 16 `git worktree add`
concurrently, **4 of 16 failed** on shared-`.git` contention; created serially, 16/16 succeeded.
Concurrent *commits* from separate worktrees are fine — it's creation that races.

### `integrate --cohort` — co-dependent units are gated **together**, or not at all

```sh
fleet integrate integ --cohort store api        # merge BOTH, THEN gate ONCE
fleet integrate integ a b c                     # default: gate each, roll back each
fleet integrate integ --cohort a b -- c d       # mixed: {a,b} together, then c, then d
```

**A `provides`/`consumes` port edge is precisely a declaration that its units are *not independently
gateable*.** The whole point of a port is to let a consumer and its provider be built **in parallel**
and only meet at **integration** — so if your `fleet_gate` is an integration test (which is exactly
what fleet tells you the oracle should be), the provider alone is **red** (no consumer) and the
consumer alone is **red** (no provider). `integrate`'s per-branch gate then rejects and rolls back
**both perfectly good units** and integrates **nothing**. The gate is unsatisfiable **by
construction**. That is not hypothetical: it is what the #50 experiment hit — every unit rejected, in
all 6 trials, in both arms (#55).

`--cohort` merges every named branch **first** and runs `fleet_gate` **once** on the combined tree. A
cohort is **one atomic unit of work**: if the combined gate is red the **whole cohort** rolls back to
the pre-cohort tip — never an individual member, which is the bug. A **merge conflict** is still
reported **per-branch** (it is not a gate verdict, and the gate never runs). After a red cohort gate,
each member is also gated alone as a **DIAGNOSTIC hint** at which diff is the likely cause — it is
**labelled as a hint and vetoes nothing**, because for genuinely co-dependent units *every* member is
red alone, by construction.

**The per-branch gate stays the default for independent branches** — there it is genuinely useful,
catching one bad branch early without poisoning the integration tree.

`fanout` prints the exact command to run: a manifest declaring **any** port edge emits its units as a
**cohort**; one with no port edge emits a plain list. It never integrates for you — `fanout` is a
work-runner, integration is a human/CI decision.

### `fronts` — the **oracle** decides the decomposition, **not a model**
`fanout` needs a manifest. Where does the manifest come from? Until now: a human wrote it and
**guessed** at the decomposition. That guess is the single highest-stakes decision in a parallel
agent run — and it is exactly the decision a model is worst at, because "how would you split this
work?" always yields N plausible-sounding units whether or not N independent units exist.

**Both flagship N-agent projects independently converged on the same answer, and it was not a spec
registry.** It was: **run a machine oracle → take its list of failures → shard the failures into N
disjoint units → fan out.** The compiler's error list *is* the work queue.

Bun, ~64 agents over a 535k-line Zig→Rust port ([source](https://bun.com/blog/bun-in-rust)):

> *"`cargo check` wrote ≈16,000 errors to a file, **grouped by crate**; the workflow divvied them up
> among 64 Claudes."*

Anthropic, 16 agents on a C compiler — the **negative** result
([source](https://www.anthropic.com/engineering/building-c-compiler)):

> *"Unlike a test suite with hundreds of independent tests, compiling the Linux kernel is one giant
> task. Every agent would hit the same bug, fix that bug, and then overwrite each other's changes.
> Having 16 agents running didn't help because each was stuck solving the same task. **The fix was to
> use GCC as an online known-good compiler oracle to compare against.**"* … *"**This let each agent
> work in parallel, fixing different bugs in different files.**"*

Their kernel failure was a **decomposition** failure, not a contract failure — and what fixed it was
an oracle that **shattered one blocking failure into N independent ones**. fleet already had the
oracle (`fleet_gate`) and the fan-out (`fanout`) and **nothing in between**. `fronts` is that middle.

```sh
.fleet/bin/fleet fronts --dry-run                              # what would the oracle shard into?
.fleet/bin/fleet fronts -o m.json && \
  .fleet/bin/fleet delegate fanout m.json --jobs 4             # generator ▸ consumer
.fleet/bin/fleet fronts --oracle 'cargo check' --shard-by package -o m.json   # Bun's exact move
.fleet/bin/fleet fronts --oracle 'tsc --noEmit' --max-units 8 -o m.json
```

| Flag | |
|------|--|
| `--oracle '<cmd>'` | the machine oracle. Default: **`fleet_gate`**. Anything that exits non-zero and names files: `cargo check`, `tsc --noEmit`, `pytest -q`, `bash -n`, or a **differential run against a known-good reference** (the thing that actually fixed Anthropic's kernel run). **Exit 0 = nothing failing = no work fronts.** That is success, not an error: it emits nothing and exits 0. |
| `--shard-by file\|package\|dir` | one unit per failing **file** (default); per **`fleet_pkg_for`** package (Bun's *"grouped by crate"*); or per top-level **dir**. |
| `-o <manifest.json>` | default **stdout**, so it pipes. |
| `--max-units N` | cap the units. Excess fronts are **MERGED** (smallest first) and **logged**. A failing file is **never dropped** — a dropped file is a failure nobody is assigned to, and the oracle stays red forever with no one to say why. |
| `--task '<tmpl>'` | override the derived task text (`{files}` `{count}` `{messages}`). |
| `--dry-run` / `--require-parallel` | print the plan and write nothing / **exit 2** when the work is not decomposable (for CI). |

Failures are parsed into **repo-relative paths** (rustc/gcc/clang/eslint/shellcheck `path:line:col:`,
rustc's `--> path:line:col`, tsc's `path(line,col):`, python tracebacks, `bash -n`) and then filtered
**hard**: a path becomes a work front **only if `git ls-files` tracks it**. That one filter is what
keeps a compiler's noisy output from pointing an agent at `/usr/include/stdio.h`, a `/tmp` build
artefact, or a path that simply does not exist. Before writing anything, `fronts` runs its own
manifest through **`check-claims.py`** — the same prover `fanout` will run it through — and dies if
its own consumer would refuse it.

**And it refuses to manufacture parallelism that isn't there.** If every failure traces to one file,
one package, one dir, then there is **one** work front:

```
NOT DECOMPOSABLE: all 5 failure(s) trace to src/parser/parser.rs.
This is ONE work front, not N. Fanning out here is the Anthropic kernel failure:
'16 agents ... each was stuck solving the same task' ...
Run it as a SINGLE unit, or find an oracle that SHATTERS this failure into independent ones.
```

It emits **exactly one unit** and says so, loudly. Splitting there would *be* the 16-agent kernel
failure — and detecting it **before** you burn 16 agents on it is the entire reason to run the oracle
first. When that happens the answer is not a bigger `--jobs`; it is **a better oracle**.

### `spec` — ⚠️ **EXPERIMENTAL AND UNVALIDATED. Do not rely on it.**

> **We built this, measured it, and the evidence does not support it. It ships only because the
> experiment that would settle it ([#61](https://github.com/jellologic/claude-fleet/issues/61))
> cannot run without it.** Read this before using it.
>
> **What IS measured (and does hold):** an **unspecified** interface across parallel agents cost
> **2/4 integration failures** plus systematic duplicate implementation — agents with *provably
> disjoint file ownership* invented incompatible interfaces. **Specify your interfaces.**
> ([`experiments/port-contract/`](experiments/port-contract/RESULTS.md))
>
> **What is NOT measured — the claim this feature rests on:** that a **typed, machine-checkable**
> port beats a **precise prose** brief. In our pilot it did **not**: 0/3 vs 0/3, and the typed arm
> was *slower*. The literature predicted exactly that tie — strong models hold ~7–8 constraints
> before compliance decays, so a 2-unit brief sits in the flat region of every published curve. Our
> pilot was **underpowered**, not conclusive: it measured the forecast, not the feature.
>
> **The risk you are taking on.** Enforcement's benefit **decays to zero as models get stronger**
> ([PLDI 2025](https://arxiv.org/abs/2504.09246): +0.3% at 32B — noise;
> [arXiv 2606.21619](https://arxiv.org/abs/2606.21619): *equivalent* for a frontier code model,
> which emits well-shaped output 99.8% of the time). And an **incomplete** contract is far worse
> than none — **up to −97% functional correctness, worst for the strongest model**. A stale,
> under-specified, or overload-missing port file is the *normal* state of a hand-maintained
> interface. **A rotting `.pyi` may be worse than no `.pyi` at all.**
>
> **The conformance check now exists — and that changes what is at stake, not what is proven.**
> `fleet spec conform` + the `fleet_spec_conform` hook ([#57](https://github.com/jellologic/claude-fleet/issues/57))
> compare the **implementation** against the frozen port and fail the gate on drift. Until it
> existed, nothing did: a unit could `provides` a port, never touch the artifact (satisfying the
> read-only rule), and ship a completely different interface. **That is why the pilot above measured
> nothing — the treatment was never applied.** Its gate was `py_compile` + an integration test, with
> no type-checker, so the "typed port" arm was a typed port *nobody checked*. **A port with no
> conformance check is decorative**, and `fleet spec` now says so, loudly, whenever the hook is unset.
> This makes [#61](https://github.com/jellologic/claude-fleet/issues/61) — the experiment that would
> settle the feature — **runnable**. It is **not evidence the feature works.** Nothing here is
> evidence yet.
>
> **And it cuts the other way too:** a conformance check turns a decorative port into a **real** one,
> which means a **stale port now actively FAILS THE GATE** — that is the intended behaviour, and it
> is exactly the failure mode the **−97%** result above warns about. **Keep your ports current, or
> turn the hook off.** A rotting `.pyi` wired into your gate is the worst of both worlds.
>
> Use `fanout` + a precise prose brief. That is what the evidence supports today.

<details>
<summary>What it does, for anyone running the experiment</summary>

**freeze a machine-checkable port, and extend the proof from files to interfaces**
`fanout` proves the units own **disjoint files**. It proves **nothing about their interfaces**. Two
agents can own non-overlapping paths and still build to **incompatible contracts** — and the
collision surfaces only at **integration**, which is the most expensive place for it to surface.

That is not a hypothetical. Anthropic ran 16 agents on a C compiler with their `current_tasks/`
git-file lock **fully in force**, and got ([source](https://www.anthropic.com/engineering/building-c-compiler)):

> *"Every agent would hit the same bug, fix that bug, and then overwrite each other's changes.
> Having 16 agents running didn't help because each was stuck solving the same task."*

**File-level locking enforces distinct task *names*, not distinct semantic *work*.** That is the gap.

**"But Bun and Anthropic ran 64 and 16 agents with no contract layer."** They did — and both had a
**complete frozen reference for free**. Bun's Zig source: **1,448 `.zig` → 1,448 `.rs`, 1:1**, so
every module boundary and signature was fixed in advance and no interface **negotiation** ever
happened. Anthropic had the C standard plus GCC as a differential oracle. **Greenfield fanout has
neither.** Read their success as *"they already had the best possible contract layer"*, not *"you
don't need one"*.

```sh
.fleet/bin/fleet spec init                 # scaffold .fleet/ports.json
.fleet/bin/fleet spec stub                 # a COMPILING stub for every provided port
.fleet/bin/fleet spec check m.json         # the static proofs — exit 2 on violation
.fleet/bin/fleet spec conform m.json       # THE CODE vs THE PORT — exit 2 on drift
.fleet/bin/fleet spec amend port:KV        # the ONLY sanctioned way to change a frozen port
```

**1. The frozen artifact is TYPED, never prose.** Every N-agent project that worked froze something
a **machine could check** (Zig source; the C standard + a GCC binary; 1.39M assertions). Every
prose-spec tool has effectively **zero** published evidence. So a port is a `.d.ts`, a `.pyi`, a
trait file, a protobuf schema, an OpenAPI document — declared in `.fleet/ports.json` and **committed
to the base branch before fanout**. A prose contract cannot be checked, so it cannot be enforced, so
it is not a contract: N agents will each read a different one out of it.

```json
{ "ports": { "port:KV": { "artifact": "src/ports/kv.d.ts", "stub": "src/ports/kv.stub.ts" } } }
```

**2. `provides:` / `consumes:` + two static proofs — the highest-value part.**

```json
{ "units": [
    { "id": "store", "owns": ["src/store/**"], "provides": ["port:KV"],  "task": "…" },
    { "id": "api",   "owns": ["src/api/**"],   "consumes": ["port:KV"],  "task": "…" } ] }
```
`check-claims.py` — fleet's **one** ownership prover, *extended, never forked* — gains three static,
cheaply-decidable proofs, each refusing the manifest with **exit 2** before anything launches:

| | |
|-|-|
| **no dangling, no duplicate provider** | every `consumes` resolves to **exactly one** `provides` — in the manifest, or to a port whose artifact **already exists in git HEAD**. Two units declaring the same `provides` is a **refusal**: they would silently implement the same interface twice. That is Anthropic's duplicate-code tax — *"LLM-written code frequently re-implements existing functionality, so I tasked one agent with coalescing any duplicate code it found."* |
| **the provides→consumes DAG is ACYCLIC** | a cycle means the units are **not semantically independent** — there is no order in which each can build against a frozen interface. Refused, exactly as an overlapping glob is, and **the cycle is named** in the error. |
| **the port artifact is READ-ONLY** | any unit whose `owns` **or whose diff** touches a frozen port it does not `provides` is an automatic **gate failure**. This is the one that stops **silent contract drift**: a unit that can rewrite the contract it was handed will, and every sibling is still building against the old one. |

**A manifest with no `provides`/`consumes` behaves exactly as it did before.**

**3. Stub-first bootstrap.** `fleet spec stub` generates a **compiling stub** for every provided port
on the base branch, so a **consumer** unit typechecks and runs its own tests **on day zero, with no
provider in existence**. ([STVR 2025](https://doi.org/10.1002/stvr.70003): *"By decoupling the
consumer and provider via the contract file, the CDC tests don't require running the consumer and
the provider simultaneously."*) Stub generation is inherently stack-specific, so it is a per-repo
hook — `fleet_stub_for <artifact> <stub-path>` in `.fleet/config.sh`, alongside `fleet_gate` /
`fleet_pkg_for`, with a **documented no-op default**. Nothing here is TypeScript-specific.

**3b. The CONFORMANCE check — the thing that makes a port a port.** ([#57](https://github.com/jellologic/claude-fleet/issues/57))
The three proofs above are about the **manifest graph**. The read-only rule is about the **diff**.
**None of them look at the code.** A unit can `provides: ["port:Store"]`, leave `ports/store.pyi`
untouched — so the read-only rule passes — and implement a **completely different interface**, and
every proof stays green. That is not hypothetical: it is exactly what the pilot experiment produced
(port: `put`/`get`/`all`; implementation: `add`/`get`/`complete`/`list`) and exactly what its gate
failed to notice. **A frozen port that nothing checks is a suggestion, not a contract.**

```sh
# .fleet/config.sh — stack-agnostic, exactly like fleet_gate / fleet_pkg_for / fleet_stub_for
fleet_spec_conform() {   # $1 = the frozen port artifact, $2 = the unit's `owns` paths
  python3 .fleet/bin/spec-conform.py "$1" $2   # shipped, stdlib-only: a .pyi vs the impl
  # or: mypy --strict $2 / pyright / npx tsc --noEmit / cargo check / protoc --lint
}
```
`fleet spec conform` runs it per unit, for every port it `provides` (`--consumes` for the other
side), and **exits 2 naming the port, the unit, and what drifted**. It is shipped **undefined, not
as a no-op**: a no-op default passes silently, which is indistinguishable from a real check that
found nothing. With no hook configured, `spec check`/`conform` print a **loud warning** — *"the
frozen port is DECORATIVE"* — every single run. A port with no conformance check must never look
like a port that has one.

fleet ships a **working default for Python** (`.fleet/bin/spec-conform.py`, **stdlib only** — no
mypy, no PEP 668 fight): it parses the `.pyi` with `ast`, loads the implementation (by import, with
an `ast` fallback), and compares **classes, methods, and parameter lists**. It is the checker of
**last resort** — it compares *shapes*, not types, and never behaviour. **If you have mypy or tsc,
point the hook at them: they are strictly stronger.**

> ⚠️ Enforcing conformance means a **stale port now fails the gate**. That is intended — and it is
> the **−97%** failure mode in the warning box above. Keep your ports current, or turn the hook off.

**4. The oracle stays the test suite. The contract check is a PRE-GATE, never the verdict.**
Put `fleet spec check` first inside `fleet_gate`; it never decides correctness. The measured ceiling
(STVR 2025, peer-reviewed): consumer-driven contract tests caught **41/53 seeded integration defects
(77%)** — and **11 of the 12 misses were value-range changes**, because contracts spot-check single
values. The authors: *"They could not replace the service black-box tests but only complement them."*
Same architecture fleet already uses for `review`: **evidence, not verdicts.**

**5. The port goes into the reviewers' prompt.** *"Does this diff conform to the frozen port?"* is a
far better-defined, evidence-emitting question than *"is this code good?"*. Bun's reviewers checked
conformance to `PORTING.md`/`LIFETIMES.tsv` **and** behavioural equivalence — and so must ours: the
prompt says, in so many words, **do not degenerate into a schema-linter**, because the type-checker
already does that job deterministically and for free. The reviewer's edge is the part a type-checker
**cannot** see: a signature honoured in form and violated in behaviour.

#### Be honest about the evidence
- **Nothing in the literature measures the actual question.** There is **no** study of whether a
  frozen interface reduces integration-failure rate across N parallel coding agents. The STVR
  numbers are human microservice teams. Every transfer to this setting is **reasoned inference**.
- The **77%** is a **synthetic, syntactic** defect taxonomy on **one** 4-service project, seeded by
  an author who is a core developer of that project. It is not a field escape rate.
- The peer-reviewed base for contract testing is **thin**: a 2025 SLR found **11** peer-reviewed
  articles in total, no prior SLR, single-case action research, hypotheses **explicitly not**
  statistically validated.

So: this layer is a **cheap, static refusal** of manifests that provably cannot work, plus a
read-only rail. It is not a claim that frozen ports make N agents succeed. Treat it as such.

### The worker is a separate process — that's the whole trick
`ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` are **global per process**. You *cannot* route one
model tier to one provider and another tier elsewhere inside a single Claude Code process — one
process, one endpoint, one credential. Delegation makes multi-provider work possible **precisely
because the worker is spawned as its own process**, so its provider is whatever `FLEET_WORKER_*`
says, entirely independent of the orchestrator you're sitting in. Nothing here is Anthropic-specific:

| env | mapped onto the worker's | |
|-----|--------------------------|-|
| `FLEET_WORKER_BASE_URL` | `ANTHROPIC_BASE_URL` | unset = inherit the ambient default |
| `FLEET_WORKER_TOKEN_FILE` | `ANTHROPIC_AUTH_TOKEN` | a **mode-600** file; never argv, never committed |
| `FLEET_WORKER_MODEL` | `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | *all* tiers — the child has **one** endpoint |
| `FLEET_WORKER_TIMEOUT_MS` | `API_TIMEOUT_MS` | default `3000000` |

Worked example — a cheap GLM worker via the z.ai Anthropic-compatible gateway, while your
orchestrator stays on Opus (see [`examples/worker-zai.env.example`](examples/worker-zai.env.example)):
```sh
printf '%s' 'YOUR_TOKEN' > ~/.claudez_token && chmod 600 ~/.claudez_token   # never in the repo
export FLEET_WORKER_BASE_URL=https://api.z.ai/api/anthropic
export FLEET_WORKER_MODEL=glm-5.2
export FLEET_WORKER_TOKEN_FILE=$HOME/.claudez_token
.fleet/bin/fleet delegate delegate agent/issue-42 "…"
```
Leave all four unset and the worker just inherits your normal Anthropic setup. The token is read
from the file and passed to the child **through the environment only** — it never appears in argv
(i.e. never in `ps`), in a log, or in this repo.

Requests are retried with **jittered exponential backoff** on `429`/`529`/transport errors — a
headless fleet against a hosted gateway *will* hit them. A worker that genuinely *failed the task*
is **not** retried; that's what `feedback`/`loop` are for.

### Confinement: an OS sandbox, not the Python hook
The worker runs with `--dangerously-skip-permissions`, so confinement is the whole ballgame — and
**fleet's Python write-guard cannot provide it**. That `PreToolUse` hook binds Claude's own
Write/Edit tools; it does **not** bind arbitrary subprocesses. A `Bash` `echo ESCAPED >
../outside.txt`, a `sed -i`, a `python3 open(…,'w')` all sail straight through it. (Claude Code's
own docs: *"deny rules … don't apply to arbitrary subprocesses that read or write files indirectly
… For OS-level enforcement … enable the sandbox"*.)

So `fleet delegate` wraps every worker in an **OS sandbox** — on macOS, `sandbox-exec` with a
generated profile that denies file-writes outside the worktree, while still allowing the shared
`.git` common dir (or `git commit` from a linked worktree would break), `/tmp`/`$TMPDIR`, and the
`~/.claude` `~/.cache` `~/.npm` caches. Verified: an out-of-worktree redirect, a `python3`
subprocess write, and a write into a **sibling agent's worktree** are all `EPERM`, while
`git commit` inside the worktree still works.

It **fails closed**: `FLEET_DELEGATE_SANDBOX` defaults to `1`, and if the sandbox is unavailable
(`sandbox-exec` missing, or a non-macOS host) `fleet delegate` **dies rather than run a worker
unconfined**. On Linux, use Claude Code's [native sandbox](https://code.claude.com/docs/en/sandboxing)
(`allowUnsandboxedCommands:false` + `failIfUnavailable:true`) — fleet won't fake it. There is a
loud, explicit `FLEET_DELEGATE_SANDBOX=0` opt-out; it prints a large warning, and you should not
use it outside a throwaway box.

> **Never launch a headless agent with `--bare`.** It skips auto-discovery of *all* hooks — and is
> slated to become the `-p` default — so a routine Claude Code upgrade would silently turn every
> fleet hook-rail into a no-op. `fleet delegate` never emits it and refuses to forward it. The
> durable rails (the OS sandbox and the pre-push gate) survive `--bare`; the hook rails do not.

### What each rail actually binds
Be clear-eyed about this: the rails are not equal, and the ones that *look* strongest are the
weakest. If you assume the Python guards confine an agent, you will be wrong.

| Rail | Binds | Survives `--bare`? | Survives a subprocess? | Load-bearing? |
|---|---|---|---|---|
| **OS sandbox** (`sandbox-exec`) | every descendant of the worker | yes | **yes** | **yes** |
| **GitHub ruleset** (server-side) | anything reaching `origin` | yes | yes | **yes** |
| pre-push hook (`core.hooksPath`) | pushes from this client | yes | yes | partly — client-side, so disable-able by whoever controls the client (`fleet gate-check`, #30) |
| `coord-guard` / `worktree-guard` (Claude hooks) | Claude's **own** tool calls | **no** | **no** | no — defence-in-depth |

The Python guards catch Claude's Write/Edit/Bash tool calls. They do **not** see a `python3`,
`node`, `sed -i`, or a nested `claude` that the agent spawns — Claude Code's docs say so plainly.
Treat them as guardrails against *accidents*, never as a boundary against a determined or confused
agent. The only things that hold under a subprocess are the OS sandbox and the server.

**Pin your Claude Code version.** The hook rails depend on undocumented-by-default discovery
behaviour that is explicitly slated to change (`--bare` becoming the `-p` default). Pin the version
the fleet runs, and re-verify the negatives suite (`tests/negatives/`) on every upgrade — it is
designed to fail loudly if a rail has silently become a no-op.


</details>

## Requirements
`bash`/`sh`, `git`, `python3` (guards + ownership gate), and `gh` (issue-driven claiming).
No node/bun required by the core. `fleet delegate` additionally needs the `claude` CLI and, on
macOS, `sandbox-exec` (ships with the OS).

## Install — drive it through Claude Code
The lifecycle (install / update / uninstall) runs **through Claude Code**, so `.fleet/config.sh`
and `CLAUDE.md` get *tailored to your repo*: Claude reads your existing `CLAUDE.md` and writes a
fitting section — it never blindly pastes a canned block.

```sh
git clone https://github.com/jellologic/claude-fleet ~/dev/claude-fleet
```
Then open **Claude Code in your target repo** and ask it to install:
> "Install claude-fleet from ~/dev/claude-fleet — follow its INSTALL.md."

Claude then: vendors the machinery (`bash ~/dev/claude-fleet/install.sh .`), tailors `.fleet/config.sh`
to your stack, **authors** a `CLAUDE.md` section (inside `claude-fleet (managed)` markers), creates the
labels, verifies, and holds commit / push / `ruleset` for your approval.

After install, Claude natively knows the tool — through the `CLAUDE.md` section **and** the slash
commands `/claim`, `/release`, `/fleet-update`, `/fleet-uninstall`.

> **Engine, not magic.** `install.sh` only vendors files — idempotent, non-destructive (merges
> `settings.json`, adds marker blocks, preserves `config.sh`, and leaves `CLAUDE.md` to Claude). You
> *can* run it standalone for CI/advanced use, then do the `config.sh` + `CLAUDE.md` steps it prints.

## Configure (per-repo `.fleet/config.sh`)
Four functions are the only stack-specific bits:
- `fleet_bootstrap` — make a fresh worktree runnable (`bun install`, `cargo fetch`, codegen…).
- `fleet_gate "$@"` — gate the integrated tree (units passed as args; empty = full). Return 0/non-zero.
- `fleet_stub_for <artifact> <stub>` — emit a **compiling stub** for a frozen port (`fleet spec stub`),
  so a consumer unit builds on day zero without its provider. Documented **no-op** by default.
- `fleet_spec_conform <artifact> <owns…>` — check the **implementation against the frozen port**
  (`fleet spec conform`): `mypy --strict` / `tsc --noEmit` / `cargo check` / the shipped stdlib
  `spec-conform.py`. Shipped **undefined**, not as a no-op — a silent pass is the failure it exists
  to prevent — and `fleet spec` warns **loudly** while it is unset: the port is **decorative** (#57).

Plus optional vars: `FLEET_MAIN`, `FLEET_LOCKFILE`, `FLEET_GENERATED_RE`, `FLEET_BRANCH_RE`, …

`FLEET_LOCK_STALE_SECS` (default `60`) tunes the coordination mutex: a lock older than this is
*inspected*, not summarily broken — it is only reclaimed if its recorded owner is provably gone
(`kill -0`), so a slow-but-alive holder (a cold `git worktree add`, a big manifest rewrite) keeps
its lock instead of having it stolen mid-critical-section.

## Layout (vendored into your repo)
```
.fleet/{config.sh,ports.json,lib/,bin/,githooks/,worktrees/,locks/}
.claude/{settings.json,hooks/,commands/,agent-claims.{template,schema}.json}
WORKTREES.md  .worktreeinclude
```

## Remove / update it (clean, no leftovers)
claude-fleet is designed to evict cleanly — it never lives forever in a repo. Drive both through
Claude Code so the `CLAUDE.md` section and config are handled too:
```
/fleet-uninstall      # (or: .fleet/bin/fleet uninstall)  — surgical reverse of install
/fleet-update [path]  # re-vendor a newer claude-fleet, preserving config.sh + CLAUDE.md
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

## FAQ

**Can I run multiple Claude Code agents / instances on the same repo at once?**
Yes — that's the point. Each agent works in its own **git worktree** on its own branch, and the
branch ref *is* the lock, so two agents (even on two machines) can't grab the same work.

**Won't parallel agents overwrite each other or conflict?**
No. Disjoint worktrees + an atomic claim lock prevent collisions; an optional file-ownership gate
rejects overlapping claims at claim time; and a sequential merge gate rolls back any branch that
doesn't build — so `main` never breaks.

**Does it work with my stack (Rust, Go, Python, Node, TypeScript…)?**
Yes. The core is pure **shell + python3 + git + gh** — no node/bun required. Your build/test/bootstrap
commands live in one small `.fleet/config.sh`.

**Does it commit to `main` or force-push anything?**
Never directly — all work lands via PR. git + Claude Code hooks block `--no-verify`, force-push, and
writes outside your worktree; a GitHub ruleset is the authoritative wall.

**How is this different from just using `git worktree`?**
Worktrees give isolation; claude-fleet adds the **lock** (so agents don't claim the same work),
**crash recovery**, the **merge gate**, and native Claude Code integration (slash commands + CLAUDE.md).

**How do I remove it?**
`/fleet-uninstall` (or `.fleet/bin/fleet uninstall`) — surgical and non-destructive. It never lives forever in your repo.

## Pedigree
Extracted from a production monorepo, where it was stress- and chaos-tested: same-issue races
(8-way local + 2-host compare-and-swap), a 10-agent end-to-end fleet, 80-way ledger concurrency,
25 concurrent worktree creations, `kill -9` mid-claim (no corruption, full self-heal), and an
11-case ownership-gate / reaper suite.

## Contributing
Found a bug or have an improvement? See **[SELF-REPORT.md](SELF-REPORT.md)** — the protocol every
script points to: understand the issue → check existing issues → open one with a repro + root cause
→ propose a fix. (AI agents must get human approval before any outward action.)

## Changelog
See **[CHANGELOG.md](CHANGELOG.md)**.

## License
[MIT](LICENSE) © 2026 jellologic
