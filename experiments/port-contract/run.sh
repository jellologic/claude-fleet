#!/usr/bin/env bash
# One trial: fixture → fanout (2 parallel GLM workers) → fleet integrate → the oracle.
#   run.sh <arm:control|ports> <trial-n> <results.tsv>
#
# WHAT IS MEASURED. The two units are built in parallel, in isolated worktrees, by workers that
# never see each other's code. Then `fleet integrate` merges both and runs the FINAL gate — the
# integration test, which calls api -> store across the seam. A FINAL-gate failure IS an
# integration failure: the two units passed alone and are incompatible together. That is the
# number nobody has published.
#
# (Since #18, a failing FINAL gate actually fails the command. Before that fix this experiment
# would have silently reported success on a broken tree — which is a nice illustration of why
# the fix mattered.)
set -uo pipefail
ARM="${1:?arm}"; N="${2:?trial}"; OUT="${3:?results.tsv}"
FLEET_SRC="${FLEET_SRC:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
D="/tmp/exp-$ARM-$N"

START=$(python3 -c 'import time;print(int(time.time()))')
FLEET_SRC="$FLEET_SRC" bash "$HERE/fixture.sh" "$D" "$ARM" >/dev/null
cd "$D"

# The manifest proof runs BEFORE any worker. In the ports arm this includes the port proofs
# (dangling / duplicate provider / cycle). A refusal here is itself a result worth recording.
REFUSED=0
if [ "$ARM" = "ports" ]; then
  .fleet/bin/fleet-spec.sh check manifest.json >/dev/null 2>&1 || REFUSED=1
fi

# Two units, both in flight — the thing under test.
FLEET_SKIP_GATE_CHECK=1 .fleet/bin/agent-delegate.sh fanout manifest.json --jobs 2 \
  > "$D/fanout.log" 2>&1
FANOUT_RC=$?

# Did each unit build something at all?
STORE_FILE=0; API_FILE=0
git show "agent/fanout/manifest/store:src/store/store.py" >/dev/null 2>&1 && STORE_FILE=1
git show "agent/fanout/manifest/api:src/api/api.py"       >/dev/null 2>&1 && API_FILE=1

# ── INTEGRATE AS A COHORT (#55) ───────────────────────────────────────────────────────
# NOT `fleet integrate`: its per-branch gate rejects co-dependent units. store alone cannot
# pass an integration test that calls api, and api alone cannot pass one that calls store —
# so it gated BOTH red on arrival and rolled BOTH back, leaving an empty tree. That is a real
# bug in fleet (#55), and it is exactly the assumption `fanout`+`spec` break on purpose: a
# port edge DECLARES that a consumer and its provider are not independently gateable.
#
# So: merge the whole cohort, THEN gate ONCE. That is the integration event we are measuring.
git checkout -q -b integ main 2>/dev/null || git checkout -q integ
MERGE_RC=0
for br in agent/fanout/manifest/store agent/fanout/manifest/api; do
  git merge --no-ff --no-edit "$br" >>"$D/integrate.log" 2>&1 || MERGE_RC=1
done

# The oracle, run ONCE on the combined tree. This is the integration-failure measurement.
ORACLE=1
python3 tests/test_integration.py >"$D/oracle.log" 2>&1 && ORACLE=0
INTEG_RC=$([ "$MERGE_RC" = 0 ] && [ "$ORACLE" = 0 ] && echo 0 || echo 1)

END=$(python3 -c 'import time;print(int(time.time()))')
SECS=$((END - START))

# Cost: agent-delegate reports per-worker cost. Keep it on ONE line or it corrupts the TSV.
COST=$(grep -oE 'cost: \$[0-9.]+' "$D/fanout.log" 2>/dev/null | grep -oE '[0-9.]+' \
       | python3 -c 'import sys; v=[float(x) for x in sys.stdin.read().split()]; print(round(sum(v),4))' 2>/dev/null)
COST="${COST:-0}"; COST="$(printf '%s' "$COST" | tr -d '\n')"

# The interface the store actually built (the drift, if any) — this is the qualitative payload.
SIG=$(git show "agent/fanout/manifest/store:src/store/store.py" 2>/dev/null \
      | grep -oE '^\s*def [a-z_]+\(' | tr -d ' ' | sed 's/def //;s/($//;s/(//' | paste -sd, - || echo "-")

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$ARM" "$N" "$INTEG_RC" "$ORACLE" "$SECS" "$COST" "$STORE_FILE$API_FILE" "$REFUSED" "$SIG" >> "$OUT"

echo "  [$ARM #$N] integrate_rc=$INTEG_RC oracle=$([ $ORACLE -eq 0 ] && echo PASS || echo FAIL) ${SECS}s \$$COST  store_sigs=[$SIG]"
