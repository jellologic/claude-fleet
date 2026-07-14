#!/usr/bin/env bash
# NEGATIVE: `fleet delegate fanout` must REFUSE non-disjoint work, cap concurrency, and create
# worktrees SERIALLY. Regression for #37.
#
# The two walls this verb exists to design around — neither of them the model:
#
#   WALL 1 (Anthropic, 16 agents, C compiler, anthropic.com/engineering/building-c-compiler):
#     "every agent would hit the same bug, fix that bug, and then overwrite each other's changes.
#      Having 16 agents running didn't help because each was stuck solving the same task."
#     => N agents on work that is NOT disjoint is strictly WORSE than N=1. A concurrency CAP does
#        not help; the manifest must be REFUSED. That is the load-bearing assertion below: an
#        overlapping manifest must launch NOTHING — no worktree, no branch, no worker.
#
#   WALL 2 (Bun, ~64 agents, bun.com/blog/bun-in-rust):
#     "The machine ran out of disk space and crashed several times anyway"
#     "One slow `grep` command was all it took to freeze disk reads & writes for minutes."
#     => the ceiling is DISK and IOPS. Hence a disk preflight, and a --jobs cap that is actually
#        enforced (a cap you do not enforce is not a cap).
#
#   WALL 3 (RFC part 3): 16 concurrent `git worktree add` → 4/16 FAILED on shared-.git contention;
#     the same 16 created serially → 16/16 succeeded. Worktree creation must be SERIAL.
#
# Asserted here:
#   1. An OVERLAPPING manifest is REFUSED with exit 2, names the colliding units and the offending
#      path, cites WHY — and creates NO worktree, NO branch, and spawns NO worker.
#   2. A properly DISJOINT manifest runs to completion (so 1 is a filter, not a wall).
#   3. Worktree creation is SERIAL: a wrapper around worktree-setup.sh logs enter/exit timestamps
#      and NO TWO creations overlap.
#   4. --jobs N is RESPECTED: the `claude` stub logs enter/exit and max concurrency is <= N — and
#      also > 1, so the cap assertion is not vacuously true of a serial implementation.
#   5. One unit's FAILURE does not abort its siblings; fanout still exits non-zero overall.
#   6. --dry-run launches NOTHING.
#   7. --resume skips units already `done` and re-runs only the rest.
#   8. The DISK PREFLIGHT refuses when free space is below the requirement — before anything runs.
#
# `claude` is stubbed on PATH: no model, no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) : ;;
  *) echo 'SKIP: fanout workers are `delegate` workers, whose confinement is sandbox-exec (macOS) only'; exit 0 ;;
esac

EV="$TMP/evidence"; mkdir -p "$EV"        # outside the repo → writable from inside the sandbox
export FLEET_TEST_EVIDENCE="$EV"
: > "$EV/calls"; : > "$EV/units.log"; : > "$EV/concurrency.log"; : > "$EV/wt.log"

# --- the fake worker ------------------------------------------------------------------
# Stands in for `claude -p --output-format json`. It records ENTER/EXIT timestamps (so the suite
# can compute the MAX CONCURRENCY actually in flight and prove --jobs is enforced), notes which
# unit it was (the fanout prompt carries `unit: <id>`), takes a beat, and reports success — or
# failure, for exactly the unit named in FLEET_TEST_FAIL_UNIT.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
EV="${FLEET_TEST_EVIDENCE:?}"
now() { python3 -c 'import time; print("%.6f" % time.time())'; }
id="$(printf '%s\n' "$*" | sed -n 's/^unit: \([a-z0-9._-]*\)$/\1/p' | head -1)"
[ -n "$id" ] || id="UNKNOWN"

printf 'x\n'                    >> "$EV/calls"
printf '%s\n' "$id"             >> "$EV/units.log"
printf 'ENTER %s %s\n' "$(now)" "$id" >> "$EV/concurrency.log"
sleep "${FLEET_TEST_WORK_S:-0.7}"
printf 'EXIT %s %s\n'  "$(now)" "$id" >> "$EV/concurrency.log"

if [ "$id" = "${FLEET_TEST_FAIL_UNIT:-}" ]; then
  printf '{"type":"result","subtype":"error","is_error":true,"session_id":"s-%s","result":"unit %s could not do the work","total_cost_usd":0.0011,"num_turns":1,"duration_ms":700}\n' "$id" "$id"
  exit 0
fi
printf '{"type":"result","subtype":"success","is_error":false,"session_id":"s-%s","result":"unit %s done","total_cost_usd":0.0011,"num_turns":1,"duration_ms":700}\n' "$id" "$id"
CLAUDE
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH
command -v claude | grep -q "^$TMP/bin/claude$" || fail "claude stub is not first on PATH"

# --- the test repo --------------------------------------------------------------------
git init -q -b main "$TMP/repo"
REPO="$TMP/repo"
cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .fleet src/parser src/codegen docs
cp -R "$SRC/lib" "$SRC/bin" .fleet/
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
fleet_gate() { echo "  gate: ok"; return 0; }
CFG
printf '.fleet/worktrees/\n.fleet/locks/\n.fleet/fanout/\n.fleet/delegate/\n' > .gitignore
printf '#!/usr/bin/env bash\necho parser\n' > src/parser/parser.sh
printf '#!/usr/bin/env bash\necho codegen\n' > src/codegen/codegen.sh
printf 'docs\n' > docs/index.md
git add -A; git commit -qm base

# --- INSTRUMENT worktree creation (WALL 3) --------------------------------------------
# Wrap worktree-setup.sh so every creation logs an enter/exit pair with timestamps. The sleeps
# widen each creation into a window that a CONCURRENT creation would demonstrably overlap.
mv .fleet/bin/worktree-setup.sh .fleet/bin/worktree-setup-real.sh
cat > .fleet/bin/worktree-setup.sh <<'WT'
#!/usr/bin/env bash
EV="${FLEET_TEST_EVIDENCE:?}"
H="$(cd "$(dirname "$0")" && pwd)"
now() { python3 -c 'import time; print("%.6f" % time.time())'; }
printf 'ENTER %s %s\n' "$(now)" "$1" >> "$EV/wt.log"
sleep 0.3
out="$("$H/worktree-setup-real.sh" "$@")"; rc=$?
sleep 0.3
printf 'EXIT %s %s\n' "$(now)" "$1" >> "$EV/wt.log"
printf '%s\n' "$out"
exit "$rc"
WT
chmod +x .fleet/bin/worktree-setup.sh

# --- max-concurrency oracle ------------------------------------------------------------
# Reads an ENTER/EXIT log and prints the maximum number of overlapping windows. Ties are resolved
# EXIT-before-ENTER, i.e. leniently: only a REAL overlap can push this above 1.
cat > "$TMP/maxconc.py" <<'PY'
import sys
ev = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) < 3:
        continue
    ev.append((float(p[1]), 1 if p[0] == "ENTER" else -1))
ev.sort(key=lambda t: (t[0], t[1]))   # -1 (EXIT) sorts before +1 (ENTER) at an identical instant
cur = mx = 0
for _, d in ev:
    cur += d
    mx = max(mx, cur)
print(mx)
PY
maxconc() { python3 "$TMP/maxconc.py" "$1"; }

export FLEET_DELEGATE_BACKOFF_MS=1
D=".fleet/bin/fleet delegate"
mkdir -p m

n_worktrees() { ls -1 "$REPO/.fleet/worktrees/agent/fanout/$1" 2>/dev/null | wc -l | tr -d ' '; }
n_branches()  { git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/agent/fanout/$1/*" | wc -l | tr -d ' '; }

# ======================================================================================
# 1. THE LOAD-BEARING ASSERTION: an OVERLAPPING manifest is REFUSED, and NOTHING launches.
# ======================================================================================
cat > m/overlap.json <<'JSON'
{ "units": [
    { "id": "alpha", "owns": ["src/parser/**"], "task": "make the parser faster" },
    { "id": "beta",  "owns": ["src/**"],        "task": "make everything faster" }
] }
JSON
: > "$EV/calls"; : > "$EV/wt.log"; : > "$EV/concurrency.log"
out="$($D fanout m/overlap.json --jobs 3 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [overlap] /'

[ "$rc" -eq 2 ] \
  || fail "an OVERLAPPING manifest exited $rc, expected 2. fanout MUST REFUSE work that is not provably disjoint — Anthropic ran 16 agents at one task and 'every agent would hit the same bug, fix that bug, and then overwrite each other's changes'. A --jobs cap does not rescue that; only refusing the manifest does."
[ -s "$EV/calls" ] \
  && fail "A WORKER WAS LAUNCHED ON A NON-DISJOINT MANIFEST. This is the exact Anthropic failure: the agents will overwrite each other's changes. $(wc -l < "$EV/calls" | tr -d ' ') worker invocation(s) recorded."
[ -s "$EV/wt.log" ] \
  && fail "a WORKTREE was created for a manifest that fanout was supposed to REFUSE — a partial fanout on a bad manifest is not allowed to exist"
[ "$(n_worktrees overlap)" = "0" ] || fail "worktree directories exist for the refused manifest"
[ "$(n_branches overlap)" = "0" ]  || fail "branches exist for the refused manifest"
echo "$out" | grep -q "OVERLAP" \
  || fail "the refusal never printed an OVERLAP line — it does not name the collision"
echo "$out" | grep -q "alpha" && echo "$out" | grep -q "beta" \
  || fail "the refusal does not name BOTH colliding units (alpha, beta)"
echo "$out" | grep -q "src/parser/parser.sh" \
  || fail "the refusal does not name the offending path (src/parser/parser.sh, owned by both units)"
echo "$out" | grep -qi "stuck solving the same task" \
  || fail "the refusal does not cite WHY parallelism on non-disjoint work is worse than N=1 (the Anthropic 16-agent result)"
echo "$out" | grep -qi "NOTHING was launched" \
  || fail "the refusal does not state that nothing was launched"
echo "    ok: a NON-DISJOINT manifest is REFUSED (exit 2) — no worktree, no branch, no worker, and the refusal names the colliding units, the offending path, and why"

# ======================================================================================
# 2+3+4. A DISJOINT manifest RUNS; worktrees are created SERIALLY; --jobs is ENFORCED.
# ======================================================================================
cat > m/wide.json <<'JSON'
{ "units": [
    { "id": "parser",  "owns": ["src/parser/**"],  "task": "tidy the parser" },
    { "id": "codegen", "owns": ["src/codegen/**"], "task": "tidy the codegen" },
    { "id": "docs",    "owns": ["docs/**"],        "task": "tidy the docs" }
] }
JSON
: > "$EV/calls"; : > "$EV/wt.log"; : > "$EV/concurrency.log"; : > "$EV/units.log"
out="$($D fanout m/wide.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [wide] /'

[ "$rc" -eq 0 ] || fail "a properly DISJOINT manifest exited $rc — the refusal in (1) would then be indistinguishable from fanout simply never working"
[ "$(wc -l < "$EV/calls" | tr -d ' ')" -eq 3 ] \
  || fail "expected 3 worker invocations for 3 disjoint units, got $(wc -l < "$EV/calls" | tr -d ' ')"
[ "$(n_worktrees wide)" = "3" ] || fail "expected 3 worktrees, got $(n_worktrees wide)"
[ "$(n_branches wide)" = "3" ]  || fail "expected 3 branches, got $(n_branches wide)"
for u in parser codegen docs; do
  grep -qx "$u" "$EV/units.log" || fail "unit '$u' never reached a worker"
  [ "$(cat "$REPO/.fleet/fanout/wide/units/$u/state")" = "done" ] \
    || fail "unit '$u' is not 'done' (state: $(cat "$REPO/.fleet/fanout/wide/units/$u/state" 2>/dev/null))"
done
echo "    ok: a DISJOINT manifest launches 3 units in 3 worktrees and all complete"

# --- 3. WORKTREE CREATION IS SERIAL (WALL 3) ------------------------------------------
wtc="$(maxconc "$EV/wt.log")"
[ "$(grep -c '^ENTER' "$EV/wt.log")" -eq 3 ] \
  || fail "the worktree-creation log has $(grep -c '^ENTER' "$EV/wt.log") entries, not 3 — the serialization assertion would be vacuous"
[ "$wtc" -eq 1 ] \
  || fail "WORKTREE CREATION OVERLAPPED: max $wtc concurrent \`git worktree add\` (expected 1). RFC part 3: firing 16 concurrently, 4/16 FAILED on shared-.git contention; created serially, 16/16 succeeded. fanout must create worktrees SERIALLY and parallelize only the WORK."
echo "    ok: worktree creation is STRICTLY SERIAL (max concurrency $wtc across 3 creations)"

# --- 4. --jobs IS ENFORCED (WALL 2) ---------------------------------------------------
wc_="$(maxconc "$EV/concurrency.log")"
[ "$wc_" -le 2 ] \
  || fail "MAX $wc_ WORKERS WERE IN FLIGHT AT ONCE with --jobs 2 — the cap is not enforced. A cap you do not enforce is not a cap, and the ceiling Bun hit at ~64 agents was disk/IOPS: 'The machine ran out of disk space and crashed several times anyway.'"
[ "$wc_" -ge 2 ] \
  || fail "max concurrency was only $wc_ with --jobs 2 and 3 units — fanout is running SERIALLY, so the '<= 2' assertion above is vacuously true and proves nothing about the cap"
echo "    ok: --jobs 2 is RESPECTED — max $wc_ workers in flight (and it IS actually parallel, so the cap assertion is not vacuous)"

# ======================================================================================
# 5. ONE UNIT'S FAILURE DOES NOT ABORT ITS SIBLINGS; fanout exits non-zero overall.
# ======================================================================================
cat > m/flaky.json <<'JSON'
{ "units": [
    { "id": "parser",  "owns": ["src/parser/**"],  "task": "tidy the parser" },
    { "id": "codegen", "owns": ["src/codegen/**"], "task": "tidy the codegen" },
    { "id": "docs",    "owns": ["docs/**"],        "task": "tidy the docs" }
] }
JSON
: > "$EV/calls"; : > "$EV/units.log"; : > "$EV/concurrency.log"
out="$(FLEET_TEST_FAIL_UNIT=codegen $D fanout m/flaky.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [flaky] /'

[ "$rc" -ne 0 ] \
  || fail "fanout exited 0 with a FAILED unit. fanout IS a work-runner: it must exit non-zero iff a unit failed. (`review` is the opposite — advisory, never blocks. Do not confuse the two.)"
[ "$(wc -l < "$EV/calls" | tr -d ' ')" -eq 3 ] \
  || fail "only $(wc -l < "$EV/calls" | tr -d ' ') of 3 units ran — a failing unit ABORTED its siblings. They are provably disjoint, therefore independent: one failure must not kill the rest."
[ "$(cat "$REPO/.fleet/fanout/flaky/units/codegen/state")" = "failed" ] \
  || fail "the failing unit is not recorded as 'failed'"
for u in parser docs; do
  [ "$(cat "$REPO/.fleet/fanout/flaky/units/$u/state")" = "done" ] \
    || fail "sibling unit '$u' did not complete (state: $(cat "$REPO/.fleet/fanout/flaky/units/$u/state" 2>/dev/null)) — a unit's failure aborted its siblings"
done
echo "$out" | grep -qE '^  codegen +failed' \
  || fail "the report does not show the per-unit failed status"
echo "    ok: a unit's FAILURE does not abort the others (they still complete) and fanout exits non-zero overall"

# ======================================================================================
# 7. --resume SKIPS units already `done`
# ======================================================================================
: > "$EV/calls"; : > "$EV/units.log"; : > "$EV/wt.log"
out="$($D fanout m/flaky.json --jobs 2 --resume 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [resume] /'

[ "$rc" -eq 0 ] || fail "--resume of the one remaining unit exited $rc"
[ "$(wc -l < "$EV/calls" | tr -d ' ')" -eq 1 ] \
  || fail "--resume re-ran $(wc -l < "$EV/calls" | tr -d ' ') units; it must re-run ONLY the 1 that is not 'done'"
grep -qx codegen "$EV/units.log" || fail "--resume did not re-run the unit that FAILED"
grep -qx parser  "$EV/units.log" && fail "--resume re-ran a unit that was already 'done' — that is duplicated work and a duplicated bill"
echo "$out" | grep -q "skip  parser" || fail "--resume did not report skipping the already-done 'parser'"
echo "$out" | grep -q "skip  docs"   || fail "--resume did not report skipping the already-done 'docs'"
[ -s "$EV/wt.log" ] && fail "--resume created a worktree again instead of REUSING the existing one"
[ "$(cat "$REPO/.fleet/fanout/flaky/units/codegen/state")" = "done" ] \
  || fail "the resumed unit is not 'done'"
echo "    ok: --resume re-runs ONLY the units that are not already 'done', and reuses their worktrees"

# ======================================================================================
# 6. --dry-run LAUNCHES NOTHING
# ======================================================================================
cat > m/dry.json <<'JSON'
{ "units": [
    { "id": "parser",  "owns": ["src/parser/**"],  "task": "tidy the parser" },
    { "id": "codegen", "owns": ["src/codegen/**"], "task": "tidy the codegen" }
] }
JSON
: > "$EV/calls"; : > "$EV/wt.log"; : > "$EV/concurrency.log"
out="$($D fanout m/dry.json --jobs 2 --dry-run 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [dry-run] /'

[ "$rc" -eq 0 ] || fail "--dry-run on a valid manifest exited $rc"
[ -s "$EV/calls" ] && fail "--dry-run LAUNCHED A WORKER — it must validate and print the plan, nothing else"
[ -s "$EV/wt.log" ] && fail "--dry-run CREATED A WORKTREE"
[ "$(n_worktrees dry)" = "0" ] || fail "--dry-run created worktree directories"
[ "$(n_branches dry)" = "0" ]  || fail "--dry-run created branches"
echo "$out" | grep -qi "Nothing launched" || fail "--dry-run does not say it launched nothing"
echo "$out" | grep -q "parser" && echo "$out" | grep -q "codegen" \
  || fail "--dry-run did not print the plan"
echo "    ok: --dry-run validates the manifest + preflight and prints the plan — no worktree, no branch, no worker"

# ======================================================================================
# 8. DISK PREFLIGHT (WALL 2 — Bun "ran out of disk space and crashed several times")
# ======================================================================================
: > "$EV/calls"; : > "$EV/wt.log"
out="$(FLEET_FANOUT_DISK_MB_PER_JOB=99999999 $D fanout m/dry.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [disk] /'

[ "$rc" -eq 2 ] \
  || fail "the disk preflight exited $rc, expected 2 — fanout must REFUSE to launch when the filesystem cannot hold the worktrees. Bun's ~64-agent run 'ran out of disk space and crashed several times anyway'."
[ -s "$EV/calls" ] && fail "a WORKER RAN despite insufficient disk — the preflight is not a preflight"
[ -s "$EV/wt.log" ] && fail "a WORKTREE was created despite insufficient disk"
[ "$(n_worktrees dry)" = "0" ] || fail "worktrees exist after a disk-preflight refusal"
echo "$out" | grep -qi "INSUFFICIENT DISK" || fail "the disk refusal does not say why"
echo "$out" | grep -qi "ran out of disk space" \
  || fail "the disk refusal does not cite the evidence it exists for (Bun ran out of disk space and crashed)"
echo "    ok: the DISK PREFLIGHT refuses (exit 2) before creating a single worktree when headroom is short"

echo "PASS: fanout REFUSES a non-disjoint manifest (exit 2, no worktree, no branch, NO worker — the Anthropic 16-agent failure cannot happen); a disjoint manifest runs; worktrees are created STRICTLY SERIALLY (the shared-.git race); --jobs is ENFORCED and genuinely parallel; a unit's failure does not abort its siblings and fanout still exits non-zero; --dry-run launches nothing; --resume re-runs only what is not done; and the disk preflight refuses before launching anything"
