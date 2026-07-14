#!/usr/bin/env bash
# One trial: fixture → fanout (2 parallel GLM workers) → COHORT integrate → the oracle.
#   run.sh <arm:prose|stale-port> <trial-n> <results.tsv>
#
# Integration uses `fleet integrate --cohort` (#55). The two units are co-dependent by
# construction — the consumer needs its provider — so the per-branch gate would reject BOTH and
# leave an empty tree. That is exactly what happened in the first pilot, and it is why #55 had to
# land before this experiment could measure anything at all.
#
# We record TWO signals, and the gap between them is the finding:
#   conformance : did the implementation match the FROZEN PORT?   (the gate's verdict)
#   oracle      : did the integration test pass?                  (the truth)
# A stale port that goes GREEN on conformance and RED on the oracle is enforcement enforcing the
# wrong thing, confidently — the -97% failure mode, in the wild.
set -uo pipefail
ARM="${1:?arm}"; N="${2:?trial}"; OUT="${3:?results.tsv}"
FLEET_SRC="${FLEET_SRC:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
D="/tmp/sp-$ARM-$N"

START=$(python3 -c 'import time;print(int(time.time()))')
FLEET_SRC="$FLEET_SRC" bash "$HERE/fixture.sh" "$D" "$ARM" >/dev/null
cd "$D"

# Stall detection OFF (#70) — with --output-format json a healthy worker emits nothing until it
# finishes, so a stall kill is a FALSE POSITIVE, and it hits the slower (longer-prompt) arm harder.
# That corrupted the first run of this experiment. The wall clock is the real guard.
export FLEET_WORKER_STALL_S=0
export FLEET_WORKER_WALL_TIMEOUT_S="${FLEET_WORKER_WALL_TIMEOUT_S:-1800}"

FLEET_SKIP_GATE_CHECK=1 .fleet/bin/agent-delegate.sh fanout manifest.json --jobs 2 \
  > "$D/fanout.log" 2>&1

# ── THREE OUTCOMES, NOT TWO ───────────────────────────────────────────────────────────
# The first scoring pass conflated three completely different things and would have produced a
# fabricated finding. They must be separated:
#
#   INFRA     the SUPERVISOR killed the worker (wall-clock / stall). NOT a result — our tooling
#             failed, not the thing under test. Marked INVALID and excluded. (#70)
#
#   ESCALATED the worker RAN, SUCCEEDED (exit 0), and DELIBERATELY WROTE NOTHING because it
#             detected that the frozen port CONTRADICTS the truth, and asked the orchestrator to
#             run `fleet spec amend`. Verbatim from a real trial:
#               "Did NOT write src/store/store.py — any implementation is knowingly inconsistent
#                with one binding contract."
#               "Blocked on: fleet spec amend aligning ports/store.pyi to put/get/all."
#             THIS IS NOT A FAILURE. It is the escalation path #57's own conformance error text
#             prescribes, and it is arguably the BEST possible outcome for a rotten contract: the
#             rot is SURFACED instead of shipped around. Scoring it as "no output / broken" — which
#             the first pass did — would have inverted the entire finding.
#
#   BUILT     the worker produced code. Only then do `oracle` and `conform` mean anything.
INFRA=""
grep -qiE 'WALL-TIMEOUT|STALL-KILL' .fleet/fanout/manifest/units/*/log 2>/dev/null && INFRA="supervisor-kill"

ESCALATED=""
for u in store api; do
  if ! git show "agent/fanout/manifest/$u:src/$u/$u.py" >/dev/null 2>&1; then
    # No code. Did the worker FAIL, or did it deliberately DECLINE and escalate?
    if grep -qiE 'spec amend|contradict|inconsistent with .*contract|frozen port .*(wrong|stale|conflict)|blocked on' \
         ".fleet/fanout/manifest/units/$u/log" 2>/dev/null \
       && grep -qE "^\s+$u\s+done" fanout.log 2>/dev/null; then
      ESCALATED="${ESCALATED:+$ESCALATED,}$u"
    else
      INFRA="${INFRA:+$INFRA,}no-output:$u"
    fi
  fi
done

# ── What the agents ACTUALLY BUILT — measured on the UNIT BRANCHES ─────────────────────
# NOT on `integ`: a red cohort gate rolls the whole cohort back (#55), leaving an empty tree. The
# first run measured that empty tree and learned nothing. Probe-merge the units with NO gate so the
# artifacts survive, then ask the two questions separately.
git checkout -q -B probe main
for b in agent/fanout/manifest/store agent/fanout/manifest/api; do
  git merge -q --no-ff --no-edit "$b" >/dev/null 2>&1
done

CONFORM="n/a"
if [ -f ports/store.pyi ] && [ -f src/store/store.py ]; then
  python3 .fleet/bin/spec-conform.py ports/store.pyi src/store/store.py >/dev/null 2>&1 \
    && CONFORM=GREEN || CONFORM=RED
fi
ORACLE=FAIL
python3 tests/test_integration.py >"$D/oracle.log" 2>&1 && ORACLE=PASS

# ── And what the real merge gate DID (the shipping decision) ──────────────────────────
git checkout -q -B integ main
FLEET_SKIP_GATE_CHECK=1 .fleet/bin/fleet-integrate.sh integ \
  --cohort agent/fanout/manifest/store agent/fanout/manifest/api > "$D/integrate.log" 2>&1
SHIPPED=$([ $? -eq 0 ] && echo YES || echo NO)

END=$(python3 -c 'import time;print(int(time.time()))')
SECS=$((END - START))
COST=$(grep -ohE 'cost: \$[0-9.]+' .fleet/fanout/manifest/units/*/log 2>/dev/null \
       | grep -oE '[0-9.]+' \
       | python3 -c 'import sys;v=[float(x) for x in sys.stdin.read().split()];print(round(sum(v),3))' 2>/dev/null)
COST="${COST:-0}"

SIG=$(git show probe:src/store/store.py 2>/dev/null | grep -oE '^    def [a-z_]+' | sed 's/    def //' | paste -sd, - | tr -d '\n')
ERR=$(grep -oE '(AttributeError|TypeError|KeyError|AssertionError)[^\n]*' "$D/oracle.log" 2>/dev/null | head -1 | cut -c1-52 | tr -d '\n')
if [ -n "$INFRA" ]; then VALID=INVALID
elif [ -n "$ESCALATED" ]; then VALID=ESCALATED
else VALID=VALID; fi

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$ARM" "$N" "$VALID" "$ORACLE" "$CONFORM" "$SHIPPED" "$SECS" "$COST" "${SIG:--}" "${INFRA:-${ESCALATED:+escalated:$ESCALATED}}" >> "$OUT"
echo "  [$ARM #$N] $VALID oracle=$ORACLE conform=$CONFORM shipped=$SHIPPED ${SECS}s \$$COST ${INFRA:+<INFRA:$INFRA>}${ESCALATED:+<ESCALATED:$ESCALATED — refused to build against a contradictory port>}"
