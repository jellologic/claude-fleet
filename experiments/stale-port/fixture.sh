#!/usr/bin/env bash
# THE ADVERSARIAL ARM (#61). Build ONE trial fixture.
#   fixture.sh <dir> <arm:prose|stale-port>
#
# THE QUESTION. The literature's sharpest warning about enforcement:
#
#   "When the constrainer is INCOMPLETE, performance drops by up to 97% relative to the
#    complete-constraining-model baseline."  — arXiv 2606.21619
#
# ...and the 97% catastrophe belongs to the STRONGEST model tested. A stale, under-specified,
# overload-missing interface file is not an edge case: it is the NORMAL state of a hand-maintained
# contract. So the question that decides `fleet spec`'s fate is not "does a good port help?" —
# it is "what does a ROTTEN port cost, now that we enforce it?"
#
# WHY THIS IS A FAIR TEST AND NOT A RIGGED ONE. Both arms get the SAME accurate prose brief,
# describing exactly what the oracle needs. The stale-port arm gets that brief PLUS a frozen .pyi
# that has DRIFTED from the truth — modelling a contract that rotted while the tests and the docs
# moved on — with the #57 CONFORMANCE CHECK switched ON, so the provider is FORCED to conform to
# the stale contract.
#
# That is exactly what production looks like: the tests are the source of truth, the .pyi is a
# hand-maintained artifact, and it rots. Enforcement then enforces the ROT.
#
# The nasty part we expect to observe: the implementation will CONFORM to the stale port (so the
# conformance gate goes GREEN) and FAIL the oracle. Enforcement enforcing the wrong thing,
# confidently. If that is what happens, `fleet spec` is a liability and should be deleted.
set -euo pipefail
DIR="${1:?usage: fixture.sh <dir> <prose|stale-port>}"
ARM="${2:?usage: fixture.sh <dir> <prose|stale-port>}"
FLEET_SRC="${FLEET_SRC:?set FLEET_SRC to a claude-fleet checkout}"

rm -rf "$DIR"; mkdir -p "$DIR"; cd "$DIR"
git init -q -b main .
git config user.email trial@local; git config user.name trial

mkdir -p .fleet .claude ports src/store src/api tests
cp -R "$FLEET_SRC/src/fleet/lib" "$FLEET_SRC/src/fleet/bin" .fleet/
cp "$FLEET_SRC/src/claude/agent-claims.template.json" .claude/ 2>/dev/null || true

# ── THE ORACLE — the source of truth, identical in both arms, read-only to both units ──
cat > tests/test_integration.py <<'EOF'
"""The oracle. It calls api, which must call store. Neither unit can pass it alone."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from src.api.api import TaskApi          # noqa: E402
from src.store.store import Store        # noqa: E402


def test_add_list_complete():
    api = TaskApi(Store())
    a = api.add("write the report")
    b = api.add("ship it")
    assert isinstance(a, str) and a, "add() must return the task's id"
    open_ids = [t["id"] for t in api.list(done=False)]
    assert a in open_ids and b in open_ids, f"both tasks should be open, got {open_ids}"
    api.complete(a)
    assert [t["id"] for t in api.list(done=False)] == [b]
    assert [t["id"] for t in api.list(done=True)] == [a]
    t = api.get(a)
    assert t["title"] == "write the report" and t["done"] is True


if __name__ == "__main__":
    test_add_list_complete()
    print("INTEGRATION OK")
EOF

printf '__pycache__/\n*.pyc\n.fleet/fanout/\n.fleet/delegate/\n.fleet/locks/\n' > .gitignore
: > src/store/__init__.py; : > src/api/__init__.py

# ── THE TRUTH, in prose. IDENTICAL in both arms. ──────────────────────────────────────
TRUTH='The Store is an in-memory task store. It must expose exactly:
  Store()                      -> constructor, no args
  put(task: dict) -> str       -> stores the task, RETURNS ITS ID (a str)
  get(id: str) -> dict | None  -> the task, or None
  all() -> list[dict]          -> every task, in insertion order
A task dict has exactly these keys: "id" (str), "title" (str), "done" (bool).
The Store assigns the id inside put() if the task has none. The Store knows NOTHING about
"complete" or filtering by done — that is the api layer'"'"'s job.'

if [ "$ARM" = "stale-port" ]; then
  # ── A ROTTEN CONTRACT — and the gate now ENFORCES it (#57) ────────────────────────
  # This .pyi was written for an OLDER version of the store and never updated. The rot is
  # ordinary, not exotic: two methods renamed, and put() lost its return value.
  #
  #   truth:  put(task) -> str     get(id)  -> Task|None    all()   -> list[Task]
  #   stale:  save(task) -> None   fetch(key) -> Task|None  items() -> list[Task]
  #
  # The prose brief still tells the truth. The frozen, MACHINE-CHECKED port does not.
  cat > ports/store.pyi <<'EOF'
"""FROZEN PORT — read-only to every fanout unit. Change it only via `fleet spec amend`."""
from typing import TypedDict


class Task(TypedDict):
    id: str
    title: str
    done: bool


class Store:
    def __init__(self) -> None: ...
    def save(self, task: Task) -> None: ...        # stores it
    def fetch(self, key: str) -> Task | None: ...  # the task, or None
    def items(self) -> list[Task]: ...             # every task, insertion order
EOF
  cat > .fleet/ports.json <<'EOF'
{ "ports": { "port:Store": { "artifact": "ports/store.pyi" } } }
EOF
  # CONFORMANCE IS ON. This is the whole point: the gate will force the provider onto the
  # stale contract, and will go GREEN when it complies.
  cat > .fleet/config.sh <<'EOF'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
fleet_spec_conform() {   # $1 = port artifact, $2 = the unit's owns paths
  python3 .fleet/bin/spec-conform.py "$1" src/store/store.py 2>&1
}
fleet_gate() {
  python3 -m py_compile $(git ls-files '*.py') 2>&1 || return 1
  if [ -f src/store/store.py ] && [ -f ports/store.pyi ]; then
    python3 .fleet/bin/spec-conform.py ports/store.pyi src/store/store.py >/dev/null 2>&1 \
      || { echo "  CONFORMANCE FAILED (impl does not match the frozen port)" >&2; return 1; }
  fi
  python3 tests/test_integration.py >/dev/null 2>&1 || { echo "  INTEGRATION TEST FAILED" >&2; return 1; }
  echo "  gate: conformance + integration OK"
}
EOF
  cp "$FLEET_SRC/src/fleet/bin/spec-conform.py" .fleet/bin/ 2>/dev/null || true
  python3 - "$TRUTH" <<'PY'
import json, sys
truth = sys.argv[1]
units = [
 {"id":"store","owns":["src/store/**"],"provides":["port:Store"],
  "task":"Implement src/store/store.py: a class `Store`, in-memory, no persistence.\n\n"
         + truth +
         "\n\nA FROZEN, MACHINE-CHECKED PORT exists at ports/store.pyi. It is READ-ONLY — you may "
         "not edit it — and the gate CHECKS YOUR IMPLEMENTATION AGAINST IT. Conform to it.\n\n"
         "Do not touch src/api/ or tests/."},
 {"id":"api","owns":["src/api/**"],"consumes":["port:Store"],
  "task":"Implement src/api/api.py: a class `TaskApi(store)` taking a Store, exposing "
         "add(title)->id, get(id)->task, complete(id)->None, list(done: bool)->list[task] "
         "filtered by done.\n\nThe Store is described here:\n\n" + truth +
         "\n\nA FROZEN, MACHINE-CHECKED PORT for the Store exists at ports/store.pyi (READ-ONLY). "
         "Build against it.\n\nDo not touch src/store/ or tests/."},
]
json.dump({"units": units}, open("manifest.json","w"), indent=1)
PY
else
  # ── CONTROL: the same truthful prose, no port, no conformance gate ─────────────────
  cat > .fleet/config.sh <<'EOF'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
fleet_gate() {
  python3 -m py_compile $(git ls-files '*.py') 2>&1 || return 1
  python3 tests/test_integration.py >/dev/null 2>&1 || { echo "  INTEGRATION TEST FAILED" >&2; return 1; }
  echo "  gate: integration OK"
}
EOF
  python3 - "$TRUTH" <<'PY'
import json, sys
truth = sys.argv[1]
units = [
 {"id":"store","owns":["src/store/**"],
  "task":"Implement src/store/store.py: a class `Store`, in-memory, no persistence.\n\n"
         + truth + "\n\nDo not touch src/api/ or tests/."},
 {"id":"api","owns":["src/api/**"],
  "task":"Implement src/api/api.py: a class `TaskApi(store)` taking a Store, exposing "
         "add(title)->id, get(id)->task, complete(id)->None, list(done: bool)->list[task] "
         "filtered by done.\n\nThe Store is described here:\n\n" + truth +
         "\n\nDo not touch src/store/ or tests/."},
]
json.dump({"units": units}, open("manifest.json","w"), indent=1)
PY
fi

git add -A >/dev/null
git commit -qm "fixture: $ARM — oracle + manifest, no implementations yet"
echo "$DIR ($ARM)"
