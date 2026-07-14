#!/usr/bin/env bash
# Build ONE trial fixture: a greenfield repo whose feature genuinely SPANS two units.
#   fixture.sh <dir> <arm:control|ports>
#
# The whole experiment turns on this fixture being HONEST, so read this before trusting a number.
#
# The feature is deliberately chosen so the two units MUST agree on an interface:
#   store  — persists tasks
#   api    — add/list/complete, built ON TOP of store
# Neither unit can satisfy the integration test alone, and the integration test is the ONLY
# oracle. It imports both and calls through api into store, so ANY signature/shape mismatch
# between them fails it. That is the integration failure we are trying to measure.
#
# The two arms differ in EXACTLY ONE thing — whether the interface is frozen:
#
#   control : both units get a PROSE description of the interface in their task text.
#             This is what `fanout` does today: disjoint `owns` globs, no contract.
#   ports   : a frozen, machine-checkable `ports/store.pyi` is committed to the base branch,
#             read-only to both units, declared in .fleet/ports.json, with store `provides`
#             it and api `consumes` it. api also gets a generated stub so it typechecks and
#             runs on day zero without store existing.
#
# CRITICAL FAIRNESS PROPERTY: the prose in the control arm describes the SAME interface, in
# the same detail, as the .pyi. If the control arm were given a vaguer brief, we would be
# measuring brief quality, not the contract mechanism. The ONLY difference is machine-
# checkability + read-only enforcement + the stub.
set -euo pipefail
DIR="${1:?usage: fixture.sh <dir> <control|ports>}"
ARM="${2:?usage: fixture.sh <dir> <control|ports>}"
FLEET_SRC="${FLEET_SRC:?set FLEET_SRC to a claude-fleet checkout containing src/fleet}"

rm -rf "$DIR"; mkdir -p "$DIR"; cd "$DIR"
git init -q -b main .
git config user.email trial@local; git config user.name trial

mkdir -p .fleet .claude ports src/store src/api tests
cp -R "$FLEET_SRC/src/fleet/lib" "$FLEET_SRC/src/fleet/bin" .fleet/
cp "$FLEET_SRC/src/claude/agent-claims.template.json" .claude/ 2>/dev/null || true

# ── the ORACLE ────────────────────────────────────────────────────────────────────────
# A real integration test. It is written BEFORE either unit exists, it is read-only to both
# units, and it is the sole arbiter. It exercises api -> store end to end, so it fails on any
# interface mismatch between them. This is fleet's whole thesis: the test suite is the oracle.
cat > tests/test_integration.py <<'EOF'
"""The oracle. Neither unit can pass this alone; it calls api, which must call store."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from src.api.api import TaskApi          # noqa: E402
from src.store.store import Store        # noqa: E402


def test_add_list_complete(tmp_path=None):
    api = TaskApi(Store())
    a = api.add("write the report")
    b = api.add("ship it")
    open_ids = [t["id"] for t in api.list(done=False)]
    assert a in open_ids and b in open_ids, f"both tasks should be open, got {open_ids}"
    api.complete(a)
    assert [t["id"] for t in api.list(done=False)] == [b], "completing a should leave only b open"
    assert [t["id"] for t in api.list(done=True)] == [a], "a should now be done"
    t = api.get(a)
    assert t["title"] == "write the report" and t["done"] is True


if __name__ == "__main__":
    test_add_list_complete()
    print("INTEGRATION OK")
EOF

cat > .fleet/config.sh <<'EOF'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
# THE ORACLE: the integration test. Not a linter — it actually calls across the seam.
fleet_gate() {
  python3 -m py_compile $(git ls-files '*.py') 2>&1 || return 1
  python3 tests/test_integration.py >/dev/null 2>&1 || { echo "  INTEGRATION TEST FAILED" >&2; return 1; }
  echo "  gate: integration OK"
}
EOF

printf '__pycache__/\n*.pyc\n.fleet/fanout/\n.fleet/delegate/\n.fleet/locks/\n' > .gitignore
: > src/store/__init__.py; : > src/api/__init__.py; : > tests/__init__.py 2>/dev/null || true

# The interface, in prose. IDENTICAL in content for both arms — only its FORM differs.
IFACE_PROSE='The Store is a plain in-memory task store. It must expose exactly:
  Store()                      -> constructor, no args
  put(task: dict) -> str       -> stores the task, returns its id (a str)
  get(id: str) -> dict | None  -> the task, or None
  all() -> list[dict]          -> every task, in insertion order
A task dict has exactly these keys: "id" (str), "title" (str), "done" (bool).
The Store assigns the id inside put() if the task has none. The Store knows NOTHING about
"complete" or filtering by done — that is the api layer'"'"'s job.'

if [ "$ARM" = "ports" ]; then
  # ── FROZEN, MACHINE-CHECKABLE PORT ─────────────────────────────────────────────────
  cat > ports/store.pyi <<'EOF'
"""FROZEN PORT — read-only to every fanout unit. Change it only via `fleet spec amend`."""
from typing import TypedDict


class Task(TypedDict):
    id: str
    title: str
    done: bool


class Store:
    def __init__(self) -> None: ...
    def put(self, task: Task) -> str: ...          # stores it, returns its id
    def get(self, id: str) -> Task | None: ...     # the task, or None
    def all(self) -> list[Task]: ...               # every task, insertion order
EOF
  cat > .fleet/ports.json <<'EOF'
{ "ports": { "port:Store": { "artifact": "ports/store.pyi", "stub": "ports/store_stub.py" } } }
EOF
  # the stub: api can run its own tests on day zero, with NO store implementation present
  cat > ports/store_stub.py <<'EOF'
"""Generated stub for port:Store — lets a CONSUMER unit run before the PROVIDER exists."""
class Store:
    def __init__(self): self._t = {}; self._order = []
    def put(self, task):
        tid = task.get("id") or str(len(self._order) + 1)
        task["id"] = tid
        if tid not in self._t: self._order.append(tid)
        self._t[tid] = task
        return tid
    def get(self, id): return self._t.get(id)
    def all(self): return [self._t[i] for i in self._order]
EOF
  python3 - "$IFACE_PROSE" <<'PY'
import json, sys
prose = sys.argv[1]
units = [
 {"id":"store","owns":["src/store/**"],"provides":["port:Store"],
  "task":"Implement src/store/store.py: a class `Store` conforming EXACTLY to the frozen port "
         "`ports/store.pyi` (read-only — do not edit it). In-memory, no persistence. "
         "Do not touch src/api/ or tests/."},
 {"id":"api","owns":["src/api/**"],"consumes":["port:Store"],
  "task":"Implement src/api/api.py: a class `TaskApi(store)` taking a Store (the frozen port "
         "`ports/store.pyi` — read-only) and exposing add(title)->id, get(id)->task, "
         "complete(id)->None, list(done: bool)->list[task] filtered by done. "
         "Build against the port. Do not touch src/store/ or tests/."},
]
json.dump({"units": units}, open("manifest.json","w"), indent=1)
PY
elif [ "$ARM" = "vague" ]; then
  # ── VAGUE: the brief a human ACTUALLY writes. No frozen artifact, no stub, no ports.json.
  #
  # WHY THIS ARM EXISTS. The first run of this experiment was a NULL result: control 3/3,
  # ports 3/3, zero integration failures. The reason was a flaw in the design — the `control`
  # arm's prose described the interface at EXACTLY the same precision as the .pyi, so the
  # control already HAD a frozen contract; only its FORM differed. That is a fair comparison of
  # prose-vs-types, but it is not the question anyone actually faces. It engineered away the
  # independent variable.
  #
  # The real question is what happens when the brief is as underspecified as a human would
  # really write it — the units are told WHAT to build and that they must work together, but
  # NOT the exact signatures. Now each agent must INVENT the interface, and the two must
  # coincide by luck. This is the condition a contract layer exists to fix.
  python3 - <<'PY'
import json
units = [
 {"id":"store","owns":["src/store/**"],
  "task":"Implement src/store/store.py: a class `Store` that keeps tasks in memory. "
         "A task has a title and a done flag, and needs an id. "
         "The api layer (built separately, in parallel) will use your Store to save and "
         "retrieve tasks. Do not touch src/api/ or tests/."},
 {"id":"api","owns":["src/api/**"],
  "task":"Implement src/api/api.py: a class `TaskApi(store)` taking a Store object, exposing "
         "add(title)->id, get(id)->task, complete(id)->None, and list(done: bool)->list of "
         "tasks filtered by done. Persist through the Store you are given (built separately, "
         "in parallel). A task has an id, a title and a done flag. "
         "Do not touch src/store/ or tests/."},
]
json.dump({"units": units}, open("manifest.json","w"), indent=1)
PY
else
  # ── CONTROL: same interface, PROSE ONLY, no frozen artifact, no stub, no ports.json ──
  python3 - "$IFACE_PROSE" <<'PY'
import json, sys
prose = sys.argv[1]
units = [
 {"id":"store","owns":["src/store/**"],
  "task":"Implement src/store/store.py.\n\n" + prose + "\n\nDo not touch src/api/ or tests/."},
 {"id":"api","owns":["src/api/**"],
  "task":"Implement src/api/api.py: a class `TaskApi(store)` taking a Store and exposing "
         "add(title)->id, get(id)->task, complete(id)->None, list(done: bool)->list[task] "
         "filtered by done.\n\nThe Store you are given behaves like this:\n\n" + prose +
         "\n\nDo not touch src/store/ or tests/."},
]
json.dump({"units": units}, open("manifest.json","w"), indent=1)
PY
fi

git add -A >/dev/null
git commit -qm "fixture: $ARM arm — oracle (integration test) + manifest, no implementations yet"
echo "$DIR ($ARM)"
