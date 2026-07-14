# Does a frozen interface reduce integration failure across parallel agents?

**A pilot, not a study.** n=3–4 per arm, one task, one model. Reported because nobody has
published *any* number here — not because these numbers settle anything.

## Setup

Two units built **in parallel**, in isolated worktrees, by headless GLM-5.2 workers that never
see each other's code:

- `store` — persists tasks (the **provider**)
- `api` — `add` / `get` / `complete` / `list(done)`, built **on top of** store (the **consumer**)

The **oracle** is a real integration test, committed before either unit exists and read-only to
both. It calls `api → store` across the seam, so any interface mismatch fails it. Verified
honest: it **fails on an empty tree** and **passes on a hand-written correct pair**.

Integration = merge both units as a **cohort**, then run the oracle **once**. (Not `fleet
integrate` — its per-branch gate rejects co-dependent units and rolled both back. That is a real
bug, filed as #55, and it is what this experiment found first.)

### The three arms

| arm | the interface is… |
|---|---|
| `vague` | **unspecified.** Units are told what to build and that they must work together — not the signatures. Each agent must **invent** the interface. This is the brief a human actually writes. |
| `control` | **specified in prose**, precisely — the exact methods, args and task-dict shape, in the task text. |
| `ports` | **specified as a frozen `.pyi`**, read-only, declared in `.fleet/ports.json`, with `provides`/`consumes` in the manifest and a generated stub so the consumer runs on day zero. |

`control` and `ports` describe the **identical** interface at the **identical** precision. Only the
*form* differs (prose vs machine-checkable + enforceable). That is deliberate: give the control a
vaguer brief and you are measuring brief quality, not the contract mechanism.

## Results

| arm | integration failures | pass rate |
|---|---|---|
| **`vague`** | **2 / 4** | 50% |
| `control` (precise prose) | 0 / 3 | 100% |
| `ports` (frozen `.pyi`) | 0 / 3 | 100% |

**Cost:** 20 GLM-5.2 worker runs, **$9.79 total**, ~$0.49/worker.
**Wall-clock:** `control` 167–196s · `ports` 165–405s · `vague` 277–518s per trial (2 workers, parallel).

## What actually went wrong in the failures

Both `vague` failures are textbook interface drift between agents that **never touched the same file**.

**vague #1** — `store` built `add(title)->int`, `get`, `complete`, `list`. `api` expected
`save`/`put`/`store`/`upsert`. The api even wrote a **defensive probe** across several possible
method names before giving up:

```
TypeError: store cannot persist a task (expected save/put/store/upsert or item assignment)
```

**vague #2** — same drift; the tasks never reached the store at all:

```
AssertionError: both tasks should be open, got []
```

**The duplicate-code tax, reproduced.** In *every* `vague` trial, `store` implemented `complete`
and `list` — **the api layer's job**. One trial's store grew **thirteen** methods (`add, create,
save, get, all, list, update, complete, delete, __len__, __contains__, __iter__`). This is exactly
Anthropic's finding: *"LLM-written code frequently re-implements existing functionality, so I
tasked one agent with coalescing any duplicate code it found."*

## Conclusions — including the one against my own feature

**1. An unspecified interface is expensive. ~50% integration failure, plus systematic duplicate
implementation.** Disjoint `owns` globs did nothing to prevent it — which is precisely the gap
`fanout` had. This is the clearest measured result here, and it argues that fleet should **require**
an interface declaration for any fanout whose units interact.

**2. A frozen typed port showed NO measured advantage over precise prose. 0/3 vs 0/3.**

What the data supports is the value of **specifying** the interface — *not* of machine-checking it.
On a task this small, with a capable model, precise prose was sufficient. **#48's core value
proposition is therefore not demonstrated by this experiment.** Anyone citing this as evidence for
typed ports is misreading it.

**3. The typed port's real advantage is one this experiment could not measure.** Prose cannot be
*enforced*: it cannot gate a merge, nothing stops a unit from silently drifting the contract, and
there is no read-only guarantee. The `.pyi` has all three. On a 2-unit toy with a well-behaved
model that advantage never gets a chance to matter. It should matter as N and complexity grow —
but **that is a hypothesis, not a result.**

**4. `ports` was not free.** It was slower in 2 of 3 trials (up to 405s vs ~180s), because the stub
and port artifact add work. On a task where prose already suffices, that is pure overhead.

## Threats to validity

- **n=3–4, one task, one model (GLM-5.2), one language.** Effect *direction* only. No significance
  is claimed and none should be inferred.
- The task is **small and unusually clean** — a single seam between exactly two units. Real fanouts
  have more units, deeper dependency chains, and messier seams. The null result between `control`
  and `ports` is most likely a **ceiling effect**: the task is too easy to separate them.
- `vague`'s 2/4 is 4 trials. It could plausibly be 1/4 or 3/4 on a re-run.
- The oracle is a single integration test. A richer suite would catch semantic drift that this one
  misses (the STVR result — contracts catch ~77% of *syntactic* drift and systematically miss
  value-range/semantic bugs — applies here too).

## What I would do next

- **Raise N.** Go to 5–8 units with a dependency chain, not 2. The prose-vs-typed distinction should
  only start paying once a human can no longer hold the whole interface in one brief.
- **Test enforcement, not just specification.** Have one unit *deliberately* drift the contract and
  see which arm catches it. Prose catches nothing by construction — that is the experiment that
  would actually vindicate #48, and it is the one I did not run.
- **Re-run `vague` at higher n** to firm up the 50%.

## Reproduce

```sh
export FLEET_SRC=/path/to/claude-fleet
export FLEET_WORKER_BASE_URL=... FLEET_WORKER_MODEL=... FLEET_WORKER_TOKEN_FILE=...
bash run.sh vague   1 results.tsv
bash run.sh control 1 results.tsv
bash run.sh ports   1 results.tsv
```
