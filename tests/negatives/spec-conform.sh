#!/usr/bin/env bash
# NEGATIVE: `fleet spec conform` — the PORT CONFORMANCE CHECK. Regression for #57.
#
# `fleet spec` does three things with a frozen port: it SHOWS the artifact to the worker, it makes
# it READ-ONLY (a unit's diff touching a port it does not `provides` = gate failure), and it
# GENERATES A STUB. It never did the fourth and most important thing:
#
#   NOTHING CHECKED THAT THE IMPLEMENTATION CONFORMS TO THE PORT.
#
# A unit could `provides: ["port:Store"]`, leave ports/store.pyi untouched (satisfying the read-only
# rule), and implement a COMPLETELY DIFFERENT interface. The three existing proofs — dangling /
# duplicate-provider / cycle — are all about the MANIFEST GRAPH, not the CODE. So a frozen port was
# prose the worker could read plus a file it must not edit: A SUGGESTION, NOT A CONTRACT.
#
# That is not hypothetical. It is what the #50 experiment produced and failed to notice: its
# `fleet_gate` was py_compile + an integration test with NO type-checker, the port declared
# put/get/all, the implementation shipped add/get/complete/list, and the gate was GREEN. The
# experiment's null result ("a typed port is no better than prose") measured NOTHING — the
# treatment was never applied. The drift below is modelled on that REAL drift.
#
# Asserted here:
#   1. THE LOAD-BEARING ONE: an implementation that DRIFTS from its frozen port is CAUGHT — exit 2,
#      naming the PORT, the UNIT, and WHAT drifted.
#   2. A CONFORMING implementation PASSES (exit 0) — the check does not over-fire.
#   3. NO `fleet_spec_conform` configured → the LOUD WARNING is emitted and the port is explicitly
#      called DECORATIVE. (The anti-silent-failure assertion: a port with no conformance check must
#      never look like a port that has one.)
#   4. A MISSING METHOD is caught; a WRONG PARAMETER LIST on a present method is caught.
#   5. The shipped `spec-conform.py` works STANDALONE on a .pyi + impl pair (drift → 1, conform → 0).
#   6. The conformance check is wired as a PRE-GATE: `fleet_gate` goes RED on drift.
#   7. NO REGRESSION: a unit with no ports, and a repo with no ports.json, are unaffected.
#
# The contract check is a PRE-GATE, never the oracle: STVR 2025 measured 41/53 (77%) of seeded
# integration defects caught, and 11 of the 12 misses were value-range changes. The TEST SUITE
# decides correctness. This test asserts the check EXISTS and FIRES — not that it is sufficient.
#
# No model, no network. Throwaway repos.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ======================================================================================
# 0. THE SHIPPED CHECKER, STANDALONE: a .pyi + an impl. Drift → exit 1, conform → exit 0.
#    (spec-conform.py is fleet's DEFAULT fleet_spec_conform for Python: stdlib only, because
#    fleet's own stack is shell+python3 and mypy is frequently unavailable under PEP 668.)
# ======================================================================================
CONF="$SRC/bin/spec-conform.py"
[ -f "$CONF" ] || fail "the shipped conformance checker $CONF does not exist — #57 ships a WORKING default, not just a hook"

mkdir -p "$TMP/standalone/ports" "$TMP/standalone/impl"
cd "$TMP/standalone"
# THE FROZEN PORT — a TYPED, MACHINE-CHECKABLE artifact.
cat > ports/store.pyi <<'PORT'
class Store:
    def put(self, key: str, value: str) -> None: ...
    def get(self, key: str) -> str: ...
    def all(self) -> list: ...
PORT
# THE DRIFT, verbatim from the #50 experiment: the port says put/get/all, the code says
# add/get/complete/list. It compiles. It passes its own tests. It is a different interface.
cat > impl/store.py <<'IMPL'
class Store:
    def add(self, item): self._x = item
    def get(self, key): return None
    def complete(self, i): pass
    def list(self): return []
IMPL
out="$(python3 "$CONF" ports/store.pyi 'impl/**' 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [standalone-drift] /'
[ "$rc" -eq 1 ] \
  || fail "the shipped spec-conform.py exited $rc on a DRIFTING implementation, expected 1. The port declares put/get/all; the code has add/get/complete/list. If this passes, the port is DECORATIVE — which is the entire bug #57 fixes."
echo "$out" | grep -qi "NON-CONFORMANCE" || fail "the standalone drift report never says NON-CONFORMANCE"
echo "$out" | grep -q "put" || fail "the standalone drift report does not name the drifted method (put)"

cat > impl/store.py <<'IMPL'
class Store:
    def put(self, key, value): pass
    def get(self, key): return ""
    def all(self): return []
IMPL
out="$(python3 "$CONF" ports/store.pyi 'impl/**' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  || fail "the shipped spec-conform.py exited $rc on a CONFORMING implementation, expected 0. A checker that fails everything is as useless as one that passes everything."
echo "    ok: the shipped spec-conform.py works STANDALONE — drift → exit 1 (naming it), conform → exit 0"

# --- the two CLASSES of drift, separately ---------------------------------------------
cat > impl/store.py <<'IMPL'
class Store:
    def put(self, key, value): pass
    def get(self, key): return ""
IMPL
out="$(python3 "$CONF" ports/store.pyi 'impl/**' 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "a MISSING METHOD (the port declares all(), the impl omits it) was NOT caught (exit $rc)"
echo "$out" | grep -qi "MISSING METHOD" || fail "a missing method is not reported as a MISSING METHOD"
echo "$out" | grep -q "all" || fail "the missing-method report does not name the missing method (all)"
echo "    ok: a MISSING METHOD is caught and named"

cat > impl/store.py <<'IMPL'
class Store:
    def put(self, key): pass
    def get(self, key): return ""
    def all(self): return []
IMPL
out="$(python3 "$CONF" ports/store.pyi 'impl/**' 2>&1)"; rc=$?
[ "$rc" -eq 1 ] \
  || fail "a WRONG PARAMETER LIST on a PRESENT method (port: put(key, value); impl: put(key)) was NOT caught (exit $rc). Name-only checking is not conformance: every caller passing a value breaks at integration."
echo "$out" | grep -qi "PARAMETER DRIFT" || fail "a wrong parameter list is not reported as PARAMETER DRIFT"
echo "$out" | grep -q "value" || fail "the parameter-drift report does not name the dropped parameter (value)"
echo "    ok: a WRONG PARAMETER LIST on a present method is caught and named"

# ======================================================================================
# The test repo — a frozen port, a manifest, and a unit that PROVIDES the port.
# ======================================================================================
git init -q -b main "$TMP/repo"
REPO="$TMP/repo"
cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .fleet src/store src/api src/ports
cp -R "$SRC/lib" "$SRC/bin" .fleet/

printf '.fleet/worktrees/\n.fleet/locks/\n.fleet/fanout/\n.fleet/delegate/\n' > .gitignore

# THE FROZEN PORT — the #50 contract, verbatim.
cat > src/ports/store.pyi <<'PORT'
class Store:
    def put(self, key: str, value: str) -> None: ...
    def get(self, key: str) -> str: ...
    def all(self) -> list: ...
PORT
cat > .fleet/ports.json <<'PORTS'
{ "ports": { "port:Store": { "artifact": "src/ports/store.pyi", "stub": "src/ports/store_stub.py" } } }
PORTS
cat > m.json <<'JSON'
{ "units": [
    { "id": "store", "owns": ["src/store/**"], "provides": ["port:Store"], "task": "implement the store" },
    { "id": "api",   "owns": ["src/api/**"],   "consumes": ["port:Store"], "task": "call the store" }
] }
JSON

# THE CONFORMING implementation.
cat > src/store/store.py <<'IMPL'
class Store:
    def put(self, key, value): pass
    def get(self, key): return ""
    def all(self): return []
IMPL
printf '# api\n' > src/api/api.py

# The config WITHOUT a fleet_spec_conform hook — this is the DECORATIVE-PORT state, and the state
# every existing claude-fleet repo is in today.
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
fleet_gate() { .fleet/bin/fleet spec conform m.json || return $?; echo "  gate: ok"; return 0; }
CFG
git add -A; git commit -qm base

S=".fleet/bin/fleet spec"

# ======================================================================================
# 1. NO HOOK CONFIGURED → THE LOUD WARNING. The single most important behaviour in #57: a port
#    with no conformance check must NEVER look like a port that has one. Silence here is what
#    made the #50 experiment's frozen port decorative without anything saying so.
# ======================================================================================
out="$($S conform m.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [no-hook] /'
[ "$rc" -eq 0 ] \
  || fail "\`fleet spec conform\` with NO hook exited $rc — an unconfigured hook is a WARNING, not a hard failure; it must not break every existing repo"
echo "$out" | grep -q "WARNING: no fleet_spec_conform hook configured" \
  || fail "NO LOUD WARNING when fleet_spec_conform is unconfigured. This is the anti-silent-failure assertion: a port with nothing checking it is DECORATIVE, and if fleet does not SAY SO, the user cannot tell a real port from a fake one. That is exactly how the #50 experiment ran a 'typed port' arm with the check switched off."
echo "$out" | grep -qi "DECORATIVE" \
  || fail "the no-hook warning never calls the port DECORATIVE — the word is the point: it tells the user the port is checking NOTHING"
echo "$out" | grep -qi "Nothing checks that your implementation matches it" \
  || fail "the no-hook warning does not say that nothing checks the implementation against the port"
echo "$out" | grep -q "#57" || fail "the no-hook warning does not point at #57"
# …and `fleet spec check` must say it too — that is the verb people already run inside fleet_gate.
out="$($S check m.json 2>&1)"; rc=$?
echo "$out" | grep -q "WARNING: no fleet_spec_conform hook configured" \
  || fail "\`fleet spec check\` (the verb wired into fleet_gate) does NOT emit the decorative-port warning — the user who never runs \`conform\` would never learn their port checks nothing"
echo "    ok: with NO fleet_spec_conform hook, BOTH \`spec conform\` and \`spec check\` emit the LOUD warning and call the port DECORATIVE"

# ======================================================================================
# 2. WITH the hook wired (at the SHIPPED checker): a CONFORMING implementation PASSES.
# ======================================================================================
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
# The per-repo, stack-agnostic conformance hook (#57). $2 is UNQUOTED on purpose: it is a
# space-separated list of the unit's `owns` paths.
fleet_spec_conform() { python3 .fleet/bin/spec-conform.py "$1" $2; }
fleet_gate() { .fleet/bin/fleet spec conform m.json || return $?; echo "  gate: ok"; return 0; }
CFG
git add -A; git commit -qm "wire the conformance hook"

out="$($S conform m.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [conforming] /'
[ "$rc" -eq 0 ] \
  || fail "a CONFORMING implementation was REJECTED (exit $rc). A check that fires on correct code is worse than no check: it will be turned off, and then the port is decorative again."
echo "$out" | grep -q "WARNING: no fleet_spec_conform hook configured" \
  && fail "the decorative-port warning is STILL printed even though a hook IS configured — the warning would become noise and be ignored"
echo "$out" | grep -qi "CONFORM" || fail "the passing run does not report that conformance was checked"
echo "    ok: a CONFORMING implementation PASSES (exit 0) and the decorative warning is GONE — the check does not over-fire"

# ======================================================================================
# 3. THE LOAD-BEARING ASSERTION: the implementation DRIFTS from the frozen port → CAUGHT.
#    The port is UNTOUCHED (so the read-only rule is satisfied and every existing proof is green).
#    Only the CODE moved — put/get/all became add/get/complete/list, exactly as in #50.
# ======================================================================================
cat > src/store/store.py <<'IMPL'
class Store:
    def add(self, item): self._x = item
    def get(self, key): return None
    def complete(self, i): pass
    def list(self): return []
IMPL
git add -A; git commit -qm "drift the implementation away from the port"

# Every PRE-EXISTING proof still passes — that is the whole point. The graph is fine and the port
# artifact was never touched. Nothing but a conformance check can see this.
out="$(FLEET_SPEC_MANIFEST=m.json python3 .fleet/bin/check-claims.py m.json 2>&1)"; grc=$?
[ "$grc" -eq 0 ] \
  || fail "precondition broken: the static graph proofs should still PASS on the drifted repo (the manifest is unchanged and legal). If they fail, the drift assertion below proves nothing about the CONFORMANCE check."
git diff --name-only HEAD~1 HEAD | grep -q "src/ports/store.pyi" \
  && fail "precondition broken: the drift commit touched the PORT ARTIFACT — then the READ-ONLY rule would catch it, and this test would not be testing conformance at all"

out="$($S conform m.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [DRIFT] /'
[ "$rc" -eq 2 ] \
  || fail "AN IMPLEMENTATION THAT DRIFTS FROM ITS FROZEN PORT EXITED $rc, EXPECTED 2. The port declares put/get/all; the unit shipped add/get/complete/list and never touched the artifact, so every other proof is green. This is #57: without this exit code the frozen port is DECORATIVE — prose the worker can read plus a file it must not edit — and that is precisely why the #50 experiment measured nothing."
echo "$out" | grep -q "port:Store" \
  || fail "the drift failure does not name the PORT (port:Store)"
echo "$out" | grep -q "store" \
  || fail "the drift failure does not name the UNIT (store)"
echo "$out" | grep -qi "CONFORMANCE FAILURE" \
  || fail "the drift failure never says PORT CONFORMANCE FAILURE"
echo "$out" | grep -q "put" \
  || fail "the drift failure does not say WHAT drifted (the port's \`put\` is missing from the implementation) — an unnamed drift is not actionable"
echo "$out" | grep -q "src/ports/store.pyi" \
  || fail "the drift failure does not name the port ARTIFACT"
echo "    ok: AN IMPLEMENTATION THAT DRIFTS FROM ITS FROZEN PORT IS CAUGHT — exit 2, naming the port, the unit, and WHAT drifted"

# …and it is a GATE failure, not a lint: `fleet spec conform` is wired as a PRE-GATE.
grc=0; ( . .fleet/config.sh && fleet_gate ) >/dev/null 2>&1 || grc=$?
[ "$grc" -ne 0 ] \
  || fail "fleet_gate stayed GREEN on an implementation that does not conform to its frozen port. \`fleet spec conform\` is designed to run INSIDE fleet_gate as a fast pre-gate — if the gate does not go RED, nothing stops the drift from reaching integration."
echo "    ok: the conformance check is a PRE-GATE — fleet_gate goes RED on drift"

# ======================================================================================
# 4. THE OTHER TWO CLASSES OF DRIFT, through the FULL fleet path (not just standalone).
# ======================================================================================
cat > src/store/store.py <<'IMPL'
class Store:
    def put(self, key, value): pass
    def get(self, key): return ""
IMPL
out="$($S conform m.json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "a MISSING METHOD (all) was NOT caught through \`fleet spec conform\` (exit $rc)"
echo "$out" | grep -qi "MISSING METHOD" || fail "\`fleet spec conform\` does not report a missing method as such"

cat > src/store/store.py <<'IMPL'
class Store:
    def put(self, key): pass
    def get(self, key): return ""
    def all(self): return []
IMPL
out="$($S conform m.json 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  || fail "a WRONG PARAMETER LIST (port: put(key, value); impl: put(key)) was NOT caught through \`fleet spec conform\` (exit $rc)"
echo "$out" | grep -qi "PARAMETER DRIFT" || fail "\`fleet spec conform\` does not report a wrong parameter list as PARAMETER DRIFT"
echo "$out" | grep -q "value" || fail "the parameter-drift failure does not name the dropped parameter (value)"
echo "    ok: BOTH classes of drift — a MISSING METHOD and a WRONG PARAMETER LIST — are caught through the full \`fleet spec conform\` path"

# ======================================================================================
# 5. NO REGRESSION: a manifest with NO provides/consumes, and a repo with no ports at all, are
#    untouched by any of this. (The three graph proofs live in spec-ports.sh and still pass.)
# ======================================================================================
cat > src/store/store.py <<'IMPL'
class Store:
    def put(self, key, value): pass
    def get(self, key): return ""
    def all(self): return []
IMPL
cat > noports.json <<'JSON'
{ "units": [
    { "id": "store", "owns": ["src/store/**"], "task": "tidy the store" },
    { "id": "api",   "owns": ["src/api/**"],   "task": "tidy the api" }
] }
JSON
out="$($S conform noports.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [no-ports] /'
[ "$rc" -eq 0 ] \
  || fail "a manifest with NO provides/consumes exited $rc from \`fleet spec conform\` — a repo that does not use ports must be completely unaffected"
out="$($S check m.json 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  || fail "\`fleet spec check\` on a CONFORMING repo with a hook wired exited $rc — the conformance stage must not break the existing static proofs"
echo "    ok: NO REGRESSION — a manifest with no ports is unaffected, and \`spec check\` still passes on a conforming repo"

# ---- 7. A REALISTIC PORT MUST CONFORM (#69) ------------------------------------------
# The bug that made the whole check unusable, and slipped through because every fixture above
# used a port with NO __init__ and NO TypedDict. A real .pyi has both: a constructor, and the
# data shapes its signatures refer to. Two failures compounded:
#   - a port declaring `__init__` could NEVER conform: the impl-side scan dropped ALL dunders, so
#     `__init__` was reported MISSING against code whose first line is `def __init__`.
#   - a `class Task(TypedDict)` in the port was treated as an interface the IMPLEMENTATION must
#     redefine, rather than a type the port's signatures use.
# Together: every realistic port failed conformance forever, which would train users to disable
# the hook — restoring the decorative-port state #57 existed to end.
SC="$CONF"
RT="$TMP/realistic"; mkdir -p "$RT"
cat > "$RT/store.pyi" <<'EOF'
from typing import TypedDict
class Task(TypedDict):
    id: str
    title: str
    done: bool
class Store:
    def __init__(self) -> None: ...
    def put(self, task: Task) -> str: ...
    def get(self, id: str) -> Task | None: ...
    def all(self) -> list[Task]: ...
EOF
cat > "$RT/store.py" <<'EOF'
class Store:
    def __init__(self): self._t = {}; self._o = []
    def put(self, task):
        tid = task.get("id") or str(len(self._o) + 1); task["id"] = tid
        if tid not in self._t: self._o.append(tid)
        self._t[tid] = task; return tid
    def get(self, id): return self._t.get(id)
    def all(self): return [self._t[i] for i in self._o]
EOF
python3 "$SC" "$RT/store.pyi" "$RT/store.py" >"$RT/out" 2>&1 \
  || fail "a CONFORMING implementation of a REALISTIC port (with __init__ and a TypedDict) was REJECTED (#69). Output: $(cat "$RT/out")"
grep -qi 'MISSING METHOD.*__init__' "$RT/out" 2>/dev/null \
  && fail "the checker still reports __init__ MISSING against an impl that defines it (#69)"
grep -qi 'MISSING CLASS.*Task' "$RT/out" 2>/dev/null \
  && fail "the checker still demands the impl redefine the TypedDict \`Task\` (#69)"
# And it must still CATCH a real drift on a realistic port (not merely pass everything).
cat > "$RT/drift.py" <<'EOF'
class Store:
    def __init__(self): self._t = {}
    def save(self, task): pass
    def fetch(self, key): return None
    def items(self): return []
EOF
python3 "$SC" "$RT/store.pyi" "$RT/drift.py" >/dev/null 2>&1 \
  && fail "a DRIFTING impl of a realistic port passed conformance — the #69 fix over-corrected into always-pass"
echo "    ok: a realistic port (with __init__ + a TypedDict) conforms when it should and is caught when it drifts (#69)"

echo "PASS: a frozen port is no longer DECORATIVE — an implementation that DRIFTS from it (port: put/get/all; impl: add/get/complete/list, the artifact untouched and every graph proof green) is CAUGHT with exit 2, naming the port, the unit and the drift; a MISSING METHOD and a WRONG PARAMETER LIST are both caught; a CONFORMING implementation passes; a REALISTIC port with __init__ and a TypedDict conforms (#69); the check is a PRE-GATE that turns fleet_gate RED; the shipped stdlib spec-conform.py works standalone; and with NO fleet_spec_conform hook configured, BOTH \`spec check\` and \`spec conform\` LOUDLY warn that the port is DECORATIVE and nothing is checking it"
