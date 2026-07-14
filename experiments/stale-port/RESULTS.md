# Does an ENFORCED but STALE contract poison the output? (#61, adversarial arm)

**A pilot, n=6 per arm, one task, GLM-5.2.** Reported because it inverts a specific prediction from
the literature, and because getting to a clean result required fixing three separate ways the
experiment tried to hand me a fabricated one.

## The question

The literature's sharpest warning about enforcement ([arXiv 2606.21619](https://arxiv.org/abs/2606.21619)):

> *"When the constrainer is incomplete, performance drops by up to 97% ... worst for the strongest model."*

A stale, under-specified, overload-missing interface file is the **normal** state of a hand-maintained
contract. So the question that decides `fleet spec`'s fate is not "does a good port help?" — it is
**"what does a ROTTEN port cost, now that #57 enforces it?"**

## Setup

Two parallel GLM-5.2 workers build a `store` (provider) + `api` (consumer) against a real
integration-test oracle. **Both arms get the same truthful prose brief.** The `stale-port` arm
*additionally* gets a frozen `.pyi` that has **drifted** from the truth — two methods renamed, and
`put()`'s return value dropped — with the #57 **conformance check ON**, so the gate forces the
provider onto the stale contract.

```
truth (prose + tests):  put(task)->str   get(id)   all()
stale port (enforced):  save(task)->None fetch(k)  items()
```

The trap, validated before spending a cent: an implementation conforming to the stale port passes the
conformance gate (GREEN) and fails the oracle; a *truthful* implementation is *rejected* by the gate (RED).

## Results (n=6 per arm, 0 invalid)

| | prose | stale-port |
|---|---:|---:|
| oracle PASS | **6/6** | 2/6 |
| shipped (gate said YES) | 6/6 | 2/6 |
| **escalated / refused** | 0/6 | **4/6** |
| **shipped-but-WRONG** (conform GREEN, oracle FAIL, shipped) | **0/6** | **0/6** |
| median wall-clock | ~205s | ~390s |
| median cost | ~$0.77 | ~$1.46 |

## The finding — the opposite of the predicted catastrophe

**A stale enforced contract cost THROUGHPUT, not CORRECTNESS.** The dangerous outcome — code that
passes the conformance gate but fails the oracle, shipped silently — happened **0 times in 12 trials.**
The −97% "confidently wrong" mechanism **did not fire** against a capable agent with a real test suite
present.

What the stale port actually produced was one of two safe behaviours, chosen non-deterministically:

- **ESCALATE (4/6).** The agent detected that the frozen port contradicts the truth, **wrote nothing**,
  and asked the orchestrator to fix the contract — verbatim:
  > *"Did NOT write src/store/store.py — any implementation is knowingly inconsistent with one binding
  >  contract."* … *"Blocked on: `fleet spec amend` aligning ports/store.pyi to put/get/all."*
  This is **exactly the escalation path #57's own conformance-error text prescribes.** The tool told
  the agent what to do when a port is wrong, and the agent did it.

- **HEDGE (2/6).** The agent built **both** interfaces (`put/get/all` *and* `save/fetch/items`), so it
  conformed to the stale port *and* passed the oracle. Correct, shipped — but bloated.

(A third behaviour — **TRUST THE PORT over the tests**, build to the stale spec, ship conform-GREEN /
oracle-FAIL — was observed once in an earlier *contaminated* run: *"the port is internally consistent
and correct, the prose is merely stale."* It did **not** recur in the clean n=6. So the dangerous tail
is real but rare here; a larger n is needed to bound its rate, and it is the only number that could
still condemn the feature.)

## What this does and does NOT establish

**Removes my strongest argument AGAINST the feature.** I expected the stale port to reproduce the −97%
catastrophe. It did not. Enforcement of a rotten contract **degraded gracefully** (stop-and-ask), not
catastrophically (silent wrong code) — given a capable model and a real oracle. The failure mode is
**fail-safe**.

**Does NOT supply an argument FOR the feature.** This is the trap to avoid. The decisive #61 question is
whether a typed port beats **precise prose**. This experiment did not test that — **prose alone scored
6/6.** The stale-port arm shipped *less* (2/6) and cost *more* (~2× time, ~2× tokens). On this task, the
enforced contract was pure overhead when the prose was already truthful, and a source of escalation
stalls when it wasn't.

**The honest one-line verdict:** an enforced contract is not *dangerous* the way the literature feared,
but it is not *helpful* here either — it is **expensive insurance against a failure mode (silent
interface drift) that a truthful prose brief did not exhibit at this scale (N=2 units).** Whether it
earns that cost is still the open question of #61's scaling sweep — does prose break down at N=8 where
the enforced contract would not?

## Threats to validity

- **n=6, one task, one model, N=2 units.** Effect *direction* only. The "trust the port" tail was seen
  once and not in this clean run; its true rate is unmeasured and is the number that matters most.
- The stall/kill contamination (#70) and the escalation-vs-failure scoring bug were both found and
  fixed *during* this experiment; earlier partial runs are not comparable and were discarded.
- The escalation behaviour depends on the port artifact being *visibly* contradictory (renamed
  methods). A subtler rot — a wrong *return type* or an off-by-one in a value range — is exactly the
  class contract tests miss (STVR: 11/12 misses were value-range), and the agent may not catch it
  either. That is the untested worse case.

## Reproduce

```sh
export FLEET_SRC=/path/to/claude-fleet
export FLEET_WORKER_BASE_URL=... FLEET_WORKER_MODEL=... FLEET_WORKER_TOKEN_FILE=...
export FLEET_WORKER_STALL_S=0            # #70 — do not let a false stall kill a healthy worker
bash run.sh stale-port 1 results.tsv
bash run.sh prose      1 results.tsv
```
