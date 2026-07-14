#!/usr/bin/env bash
# NEGATIVE: fleet-integrate must merge a COHORT first and gate it ONCE (#55).
#
# THE BUG. `fleet integrate` gates each branch AS IT MERGES IT and rolls back any branch whose
# gate is red. That encodes a latent assumption — EVERY BRANCH IS INDEPENDENTLY GREEN — which
# `fanout` + `spec` break ON PURPOSE: a `provides`/`consumes` port edge exists precisely so a
# consumer and its provider can be built in PARALLEL and only meet at INTEGRATION. If the repo's
# `fleet_gate` is an integration test (which is exactly what fleet says the oracle should be):
#     merge the provider alone → the integration test has no consumer → RED → rolled back
#     merge the consumer alone → the integration test has no provider → RED → rolled back
#     the FINAL gate then runs on a tree containing NEITHER
# Both units were perfectly good; the gate is UNSATISFIABLE BY CONSTRUCTION. That is what the #50
# experiment hit — it rejected every unit in all 6 trials. `--cohort` merges the whole set FIRST
# and gates the combined tree ONCE, and rolls back the WHOLE cohort (never one member) if it is red.
#
# THE ORACLE IN THIS TEST IS A REAL INTEGRATION TEST, not a stub that returns 1. That matters: a
# stub that always fails would also reject the branches, and the test would "pass" against the buggy
# code while proving nothing. Here `store` and `api` are each GREEN alone only in combination, which
# is the actual shape of the bug — and the same gate, scoped, is genuinely green for the independent
# branches, so the per-branch path can be shown to be UNCHANGED by the same oracle.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
have() { git cat-file -e "HEAD:$1" 2>/dev/null; }
gone() { ! git cat-file -e "HEAD:$1" 2>/dev/null; }

# ── the ORACLE: one integration test, scoped by package ───────────────────────────────
# core    = store.py / api.py / reserved.txt   (the store↔api PORT)
# plugins = plugins/*.py
# The seam test needs BOTH units of the port. The cross-package check can only be seen by a gate
# that SPANS both packages — which is what makes a FINAL-gate-only failure reachable (#18).
cat > "$TMP/gate.py" <<'PY'
import glob, os, sys
sys.path.insert(0, os.getcwd())
units = sys.argv[1:]
full = not units
def has(u): return full or (u in units)
def red(m):
    print("    [gate] RED: %s" % m)
    sys.exit(1)

names = []
if has("plugins"):
    for f in sorted(glob.glob("plugins/*.py")):
        ns = {}
        try:
            exec(compile(open(f).read(), f, "exec"), ns)
        except Exception as e:
            red("plugin %s does not load: %r" % (f, e))
        names.append(ns.get("NAME"))

if has("core"):
    # THE SEAM. A real integration test across the store↔api port: it needs BOTH units. A provider
    # with no consumer and a consumer with no provider are each RED here, by construction.
    try:
        from store import Store
        from api import Api
    except Exception as e:
        red("the store/api integration test cannot import the units: %r" % (e,))
    try:
        a = Api(Store())
        a.save("k", "v")
        if a.load("k") != "v":
            red("the store/api roundtrip returned the wrong value")
    except Exception as e:
        red("the store/api roundtrip raised: %r" % (e,))

if has("core") and has("plugins"):
    reserved = []
    if os.path.exists("reserved.txt"):
        reserved = [l.strip() for l in open("reserved.txt") if l.strip()]
    for n in names:
        if n in reserved:
            red("plugin NAME %r collides with a RESERVED core name" % (n,))

print("    [gate] GREEN units=%s plugins=%s" % (units or ["<full>"], names))
PY
export FLEET_TEST_GATE="$TMP/gate.py"

# fleet-integrate refuses to run unless the pre-push merge gate is wired (#30). These throwaway
# repos have no hooks installed, so without the documented opt-out ("hooks are managed elsewhere")
# integrate dies at the gate-integrity check and never reaches the code this test exercises. Same
# reason as tests/negatives/integrate-final-gate.sh. The gate-check is about hook WIRING; this test
# is about cohort semantics.
export FLEET_SKIP_GATE_CHECK=1

# ── repo scaffolding ──────────────────────────────────────────────────────────────────
STORE_PY='class Store:
    def __init__(self): self._d = {}
    def put(self, k, v): self._d[k] = v
    def get(self, k): return self._d.get(k)
'
API_PY='from store import Store          # the CONSUMER: useless — unimportable — without its provider
class Api:
    def __init__(self, store): self._s = store
    def save(self, k, v): self._s.put(k, v)
    def load(self, k): return self._s.get(k)
'
BADAPI_PY='from store import Store
class Api:                              # merges clean, imports clean — and gets the CONTRACT wrong
    def __init__(self, store): self._s = store
    def save(self, k, v): self._s.write(k, v)   # no such method on Store
    def load(self, k): return self._s.read(k)
'

mkrepo() {  # $1 = dir, $2 = "seeded" to commit a GREEN store+api base
  git init -q -b main "$1"
  cd "$1"
  git config user.email t@t; git config user.name t
  mkdir -p .fleet
  cp -R "$SRC/lib" "$SRC/bin" .fleet/
  cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { case "$1" in plugins/*) echo "plugins" ;; *) echo "core" ;; esac; }
fleet_gate() { PYTHONDONTWRITEBYTECODE=1 python3 "$FLEET_TEST_GATE" "$@"; }
CFG
  echo readme > README
  if [ "${2:-}" = seeded ]; then printf '%s' "$STORE_PY" > store.py; printf '%s' "$API_PY" > api.py; fi
  git add -A; git commit -qm base
}

mkbranch() {  # $1 = branch, $2 = path, $3 = content
  git checkout -q main
  git checkout -qb "$1"
  mkdir -p "$(dirname "$2")"
  printf '%s' "$3" > "$2"
  git add -A; git commit -qm "$1"
  git checkout -q main
}

fresh_integ() { git checkout -q main; git branch -qD integ 2>/dev/null; git checkout -qb integ; }

# ══ REPO 1 — the CO-DEPENDENT pair. Base has NEITHER unit. ════════════════════════════
mkrepo "$TMP/codep"
BASE="$(git rev-parse main)"
mkbranch store   store.py         "$STORE_PY"
mkbranch api     api.py           "$API_PY"
mkbranch badapi  api.py           "$BADAPI_PY"
mkbranch altstore store.py        '# a DIFFERENT store.py — add/add conflicts with `store`
class Store: pass
'
mkbranch p_ok    plugins/ok.py    'NAME = "ok"
'
mkbranch res_k   reserved.txt     'k
'
mkbranch p_x     plugins/x.py     'NAME = "k"
'

# ── 1a. THE LOAD-BEARING ONE, part 1: WITHOUT --cohort the co-dependent pair is annihilated.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ store api 2>&1)"; rc=$?
echo "$out" | sed 's/^/  1a| /'
[ "$rc" -ne 0 ]                                 || fail "1a: exited 0 on a tree that integrated nothing"
echo "$out" | grep -q "rejected     (2)"        || fail "1a: expected BOTH co-dependent units rejected by the per-branch gate — the bug did not reproduce, so nothing below proves anything"
echo "$out" | grep -q "store :: gate"           || fail "1a: 'store' was not rejected by the per-branch GATE"
echo "$out" | grep -q "api :: gate"             || fail "1a: 'api' was not rejected by the per-branch GATE"
echo "$out" | grep -q "FINAL: FAIL"             || fail "1a: the FINAL gate did not object to the empty tree"
gone store.py                                   || fail "1a: store.py survived — the per-branch rollback did not happen"
gone api.py                                     || fail "1a: api.py survived — the per-branch rollback did not happen"
[ "$(git rev-parse HEAD)" = "$BASE" ]           || fail "1a: integ is not back at base — the tree is not empty"

# ── 1b. THE LOAD-BEARING ONE, part 2: WITH --cohort, BOTH land and the gate is GREEN.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ --cohort store api 2>&1)"; rc=$?
echo "$out" | sed 's/^/  1b| /'
[ "$rc" -eq 0 ]                                 || fail "1b: --cohort exited $rc — the co-dependent pair must integrate GREEN together (this is the whole point of #55)"
echo "$out" | grep -q "COHORT RESULT: PASS"     || fail "1b: the cohort gate did not PASS"
echo "$out" | grep -q "merged clean (2)"        || fail "1b: both units must be reported merged clean"
echo "$out" | grep -q "rejected     (0)"        || fail "1b: nothing may be rejected — a cohort is gated ONCE, after every member is in"
echo "$out" | grep -q "FINAL: PASS"             || fail "1b: the FINAL gate must be green on the combined tree"
have store.py                                   || fail "1b: store.py did NOT land"
have api.py                                     || fail "1b: api.py did NOT land"

# ── 2. A cohort whose COMBINED gate fails rolls back the WHOLE cohort, not one member.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ --cohort store badapi 2>&1)"; rc=$?
echo "$out" | sed 's/^/  2 | /'
[ "$rc" -ne 0 ]                                          || fail "2: a red cohort gate must fail the command"
echo "$out" | grep -q "COHORT RESULT: FAIL (gate)"       || fail "2: the cohort gate did not report a gate failure"
echo "$out" | grep -q "store :: cohort-gate"             || fail "2: 'store' not rejected as part of the cohort"
echo "$out" | grep -q "badapi :: cohort-gate"            || fail "2: 'badapi' not rejected as part of the cohort"
gone store.py                                            || fail "2: store.py is STILL MERGED — the cohort was not rolled back as a WHOLE (only the last member was)"
gone api.py                                              || fail "2: api.py is STILL MERGED — the cohort was not rolled back as a WHOLE"
[ "$(git rev-parse HEAD)" = "$BASE" ]                    || fail "2: integ is not back at its pre-cohort tip"

# ── 3. A genuine MERGE CONFLICT inside a cohort is reported PER-BRANCH and is NOT a gate verdict.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ --cohort store altstore 2>&1)"; rc=$?
echo "$out" | sed 's/^/  3 | /'
[ "$rc" -ne 0 ]                                          || fail "3: a conflicting cohort must fail the command"
echo "$out" | grep -q "RESULT: FAIL (merge conflict)"    || fail "3: the merge conflict was not reported"
echo "$out" | grep -q "altstore :: merge-conflict"       || fail "3: 'altstore' must be rejected as a MERGE CONFLICT, per-branch"
echo "$out" | grep -q "COHORT RESULT: FAIL (gate)"       && fail "3: a merge conflict MASQUERADED as a gate failure — the gate never even ran"
echo "$out" | grep -q "cohort-gate"                      && fail "3: a merge conflict was attributed to the cohort GATE"
[ "$(git rev-parse HEAD)" = "$BASE" ]                    || fail "3: the cohort is atomic — a member that cannot merge must roll the whole cohort back"

# ── 4. MIXED GRAMMAR + the cohort rollback returns to the PRE-COHORT tip, not to base.
#    --cohort store api      → lands (co-dependent, green together)
#    -- p_ok                 → an INDEPENDENT branch, gated ALONE, lands
#    --cohort res_k p_x      → each member is GREEN ALONE; only their COMBINATION is red
#                              → the whole cohort rolls back, and the work already integrated STAYS.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ --cohort store api -- p_ok --cohort res_k p_x 2>&1)"; rc=$?
echo "$out" | sed 's/^/  4 | /'
[ "$rc" -ne 0 ]                                          || fail "4: the red second cohort must fail the command"
echo "$out" | grep -q "COHORT RESULT: PASS"              || fail "4: the first cohort {store,api} did not pass"
echo "$out" | grep -q "res_k :: cohort-gate"             || fail "4: 'res_k' not rolled back with its cohort"
echo "$out" | grep -q "p_x :: cohort-gate"               || fail "4: 'p_x' not rolled back with its cohort"
have store.py                                            || fail "4: the FIRST cohort was destroyed by the SECOND cohort's rollback"
have api.py                                              || fail "4: the FIRST cohort was destroyed by the SECOND cohort's rollback"
have plugins/ok.py                                       || fail "4: the independent branch merged between the cohorts was destroyed by the cohort rollback"
gone reserved.txt                                        || fail "4: res_k survived the cohort rollback"
gone plugins/x.py                                        || fail "4: p_x survived the cohort rollback"
# The DIAGNOSTIC is a hint, never a veto: both members are green ALONE here, so it must say so —
# and it must not have changed a single verdict (asserted by the file checks above).
echo "$out" | grep -q "DIAGNOSTIC (a HINT — never a veto)" || fail "4: no diagnostic was produced for the failing cohort"
echo "$out" | grep -q "every member is green alone"        || fail "4: the diagnostic misreported members that ARE green alone"
echo "$out" | grep -q "FINAL: PASS"                        || fail "4: the surviving tree must be green — the rollback left a broken tree"

# ══ REPO 2 — INDEPENDENT branches. Base is a GREEN store+api. ═════════════════════════
mkrepo "$TMP/indep" seeded
mkbranch p_ok   plugins/ok.py  'NAME = "ok"
'
mkbranch p_bad  plugins/bad.py 'raise RuntimeError("this plugin is broken")
'
mkbranch p_ok2  plugins/ok2.py 'NAME = "ok2"
'
mkbranch res_k  reserved.txt   'k
'
mkbranch p_x    plugins/x.py   'NAME = "k"
'

# ── 5. The per-branch (NON-cohort) path is UNCHANGED: one bad branch is rejected and rolled back
#    on its own, and the good ones still land. This is why the per-branch gate is kept as the
#    DEFAULT — for genuinely independent branches it catches the bad one without poisoning the tree.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ p_ok p_bad p_ok2 2>&1)"; rc=$?
echo "$out" | sed 's/^/  5 | /'
[ "$rc" -ne 0 ]                                 || fail "5: a rejected branch must fail the command"
echo "$out" | grep -q "merged clean (2)"        || fail "5: the two GOOD independent branches must land"
echo "$out" | grep -q "p_bad :: gate"           || fail "5: the bad branch was not rejected by the per-branch gate"
echo "$out" | grep -q "rejected     (1)"        || fail "5: exactly ONE branch (the bad one) must be rejected"
have plugins/ok.py                              || fail "5: a good independent branch was rolled back"
have plugins/ok2.py                             || fail "5: a good independent branch merged AFTER the bad one was rolled back"
gone plugins/bad.py                             || fail "5: the bad branch was NOT rolled back"
echo "$out" | grep -q "FINAL: PASS"             || fail "5: the surviving tree must be green"

# ── 6. NO #18 REGRESSION: the FINAL gate still fails the command. Both branches merge clean AND
#    pass their own (scoped) per-branch gate — res_k is only `core`, p_x is only `plugins` — so the
#    per-branch FAIL[] is EMPTY and the exit code can come from NOWHERE but the FINAL gate, which
#    spans both packages and sees the collision.
fresh_integ
out="$(.fleet/bin/fleet-integrate.sh integ res_k p_x 2>&1)"; rc=$?
echo "$out" | sed 's/^/  6 | /'
echo "$out" | grep -q "rejected     (0)"        || fail "6: FAIL[] is non-empty — a non-zero exit would prove nothing about the FINAL gate"
echo "$out" | grep -q "FINAL: FAIL"             || fail "6: the FINAL gate did not report FAIL — the test is not exercising #18"
[ "$rc" -ne 0 ]                                 || fail "6: fleet-integrate exited 0 with a FAILING final gate — #18 has REGRESSED"

echo "PASS: co-dependent pair annihilated WITHOUT --cohort and GREEN WITH it; red cohort rolls back"
echo "      whole; conflict ≠ gate verdict; per-branch path unchanged; FINAL gate still fatal (#18)"
