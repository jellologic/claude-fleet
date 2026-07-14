#!/usr/bin/env bash
# NEGATIVE: `fleet spec` — the CONTRACT / PORT layer. Regression for #48.
#
# `fanout` proves the units own disjoint FILES. It proves NOTHING about their INTERFACES. Two
# agents can own non-overlapping paths and still build to incompatible contracts; the collision
# surfaces only at INTEGRATION, which is the most expensive place for it to surface.
#
#   Anthropic, 16 agents, C compiler (anthropic.com/engineering/building-c-compiler), VERBATIM:
#     "Every agent would hit the same bug, fix that bug, and then overwrite each other's changes.
#      Having 16 agents running didn't help because each was stuck solving the same task."
#   Their `current_tasks/` git-file lock was FULLY IN FORCE the whole time. File-level locking
#   enforces distinct task NAMES, not distinct semantic WORK.
#
# Asserted here:
#   1. A `consumes` with NO matching `provides` (dangling port) → manifest REFUSED, exit 2, and
#      NOTHING is created (no worktree, no branch, no worker).
#   2. TWO units declaring the same `provides` → REFUSED (the duplicate-code tax).
#   3. A provides→consumes CYCLE (a→b→a) → REFUSED, and the CYCLE IS NAMED in the error.
#   4. A valid DAG (store provides KV; api consumes KV) → ACCEPTED, fanout proceeds and runs.
#   5. A `consumes` resolving to a port ALREADY ON THE BASE BRANCH (artifact in HEAD, no unit
#      provides it) → ACCEPTED. That is the steady state, not a dangling reference.
#   6. A unit whose DIFF touches a frozen port artifact it does not `provides` → GATE FAILURE.
#      (The read-only property. This is the one that stops silent contract drift.)
#   7. BACKWARDS COMPATIBILITY: a manifest with NO provides/consumes behaves exactly as before —
#      the `fanout-disjoint.sh` scenarios (overlap REFUSED / disjoint ACCEPTED) run unchanged
#      through the new code path.
#   8. `fleet spec stub` produces a stub that makes a CONSUMER's typecheck pass with NO provider
#      present (trivial `fleet_stub_for` + trivial `fleet_gate` in the test repo).
#   9. `fleet fronts` output (which has no provides/consumes) still passes `fleet spec check` —
#      no regression in the generator.
#
# The contract check is a PRE-GATE, never the oracle: STVR 2025 measured 41/53 (77%) of seeded
# integration defects caught, and 11 of the 12 misses were value-range changes. "They could not
# replace the service black-box tests but only complement them." The TEST SUITE decides.
#
# No model, no network: `claude` is stubbed on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

EV="$TMP/evidence"; mkdir -p "$EV"
export FLEET_TEST_EVIDENCE="$EV"
: > "$EV/calls"

# --- the fake worker (no model, no network) -------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
EV="${FLEET_TEST_EVIDENCE:?}"
id="$(printf '%s\n' "$*" | sed -n 's/^unit: \([a-z0-9._-]*\)$/\1/p' | head -1)"
[ -n "$id" ] || id="UNKNOWN"
printf '%s\n' "$id" >> "$EV/calls"
# The prompt a fanout worker gets is evidence too: record it, so the suite can prove the FROZEN
# PORT was actually piped into the unit's brief.
printf '%s\n' "$*" > "$EV/prompt-$id.txt"
printf '{"type":"result","subtype":"success","is_error":false,"session_id":"s-%s","result":"unit %s done","total_cost_usd":0.001,"num_turns":1,"duration_ms":10}\n' "$id" "$id"
CLAUDE
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH
command -v claude | grep -q "^$TMP/bin/claude$" || fail "claude stub is not first on PATH"

# --- the test repo --------------------------------------------------------------------
git init -q -b main "$TMP/repo"
REPO="$TMP/repo"
cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .fleet src/store src/api src/ports src/parser
cp -R "$SRC/lib" "$SRC/bin" .fleet/

# A trivial, HONEST toy type-checker: `fleet_gate` fails unless every symbol the CONSUMER uses is
# declared by something on disk (the real port artifact, or its STUB). That is the whole CDCT
# decoupling property reduced to something a shell can decide.
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }

# `fleet_stub_for <artifact> <stub-path>` — the per-repo, STACK-AGNOSTIC stub hook. Here: copy the
# frozen signatures out of the port and give them a NotImplemented body. A stub only has to
# satisfy the type-checker; it is not the implementation.
fleet_stub_for() {
  { echo "# STUB generated from $1 by fleet_stub_for — NOT an implementation."
    sed -n 's/^sig \(.*\)$/def \1: raise NotImplementedError/p' "$1"
  } > "$2"
}

# The toy type-checker (the ORACLE): every `use <sym>` in src/api must resolve to a `def <sym>` in
# a real IMPLEMENTATION — the provider's, or the STUB. The port artifact only DECLARES (`sig`);
# a declaration alone does not make a consumer run.
fleet_typecheck() {
  rc=0
  for u in $(grep -ho '^use [a-z_]*' src/api/*.py 2>/dev/null | awk '{print $2}'); do
    grep -qh "^def $u" src/ports/*_stub.py src/store/*.py 2>/dev/null \
      || { echo "  typecheck: undefined symbol '$u' (no provider, no stub)"; rc=1; }
  done
  return $rc
}

fleet_gate() {
  # The contract check is a PRE-GATE — cheap, static, and it REFUSES silent contract drift. It is
  # NOT the oracle: the typecheck below is. (STVR 2025: contract tests caught 77% of seeded
  # integration defects and missed nearly every value-range bug — they complement the black-box
  # tests, they never replace them.)
  .fleet/bin/fleet spec check >/dev/null 2>&1 || return 2
  fleet_typecheck || return 1
  echo "  gate: ok"
  return 0
}
CFG
printf '.fleet/worktrees/\n.fleet/locks/\n.fleet/fanout/\n.fleet/delegate/\n' > .gitignore

# THE FROZEN PORT — a TYPED, MACHINE-CHECKABLE artifact (a .pyi), never prose.
cat > src/ports/kv.pyi <<'PORT'
sig kv_get(key: str) -> str
sig kv_put(key: str, value: str) -> None
PORT
cat > .fleet/ports.json <<'PORTS'
{ "ports": {
    "port:KV":   { "artifact": "src/ports/kv.pyi",   "stub": "src/ports/kv_stub.py" },
    "port:Auth": { "artifact": "src/ports/auth.pyi", "stub": "src/ports/auth_stub.py" },
    "port:Log":  { "artifact": "src/ports/log.pyi",  "stub": "src/ports/log_stub.py" }
} }
PORTS
printf 'use kv_get\n' > src/api/api.py
printf '# store\n' > src/store/store.py
printf '# parser\n' > src/parser/parser.py
git add -A; git commit -qm base

D=".fleet/bin/fleet delegate"
S=".fleet/bin/fleet spec"
mkdir -p m
n_worktrees() { ls -1 "$REPO/.fleet/worktrees/agent/fanout/$1" 2>/dev/null | wc -l | tr -d ' '; }
n_branches()  { git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/agent/fanout/$1/*" | wc -l | tr -d ' '; }

# ======================================================================================
# 1. DANGLING PORT: a `consumes` with no matching `provides` → REFUSED, exit 2, nothing created.
# ======================================================================================
cat > m/dangling.json <<'JSON'
{ "units": [
    { "id": "api",   "owns": ["src/api/**"],   "consumes": ["port:Auth"], "task": "call auth" },
    { "id": "store", "owns": ["src/store/**"], "task": "tidy the store" }
] }
JSON
: > "$EV/calls"
out="$($D fanout m/dangling.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [dangling] /'

[ "$rc" -eq 2 ] \
  || fail "a DANGLING consumes exited $rc, expected 2. A consumer with no provider has no contract to build against — it will INVENT one, and the mismatch surfaces at integration. fanout must REFUSE the manifest, exactly as it refuses an overlapping glob."
[ -s "$EV/calls" ] && fail "A WORKER WAS LAUNCHED on a manifest with a dangling port"
[ "$(n_worktrees dangling)" = "0" ] || fail "worktrees exist for the refused manifest"
[ "$(n_branches dangling)" = "0" ]  || fail "branches exist for the refused manifest"
echo "$out" | grep -q "DANGLING PORT" \
  || fail "the refusal never printed a DANGLING PORT line — it does not name the failure"
echo "$out" | grep -q "port:Auth" \
  || fail "the refusal does not name the dangling port (port:Auth)"
echo "$out" | grep -q "api" \
  || fail "the refusal does not name the unit that consumes it (api)"
echo "    ok: a DANGLING consumes is REFUSED (exit 2) — no worktree, no branch, no worker; the port and the consumer are both named"

# ======================================================================================
# 2. DUPLICATE PROVIDER: two units declaring the same `provides` → REFUSED.
#    Anthropic's duplicate-code tax: "LLM-written code frequently re-implements existing
#    functionality, so I tasked one agent with coalescing any duplicate code it found."
# ======================================================================================
cat > m/dup.json <<'JSON'
{ "units": [
    { "id": "store",  "owns": ["src/store/**"],  "provides": ["port:KV"], "task": "implement kv" },
    { "id": "parser", "owns": ["src/parser/**"], "provides": ["port:KV"], "task": "also implement kv" }
] }
JSON
: > "$EV/calls"
out="$($D fanout m/dup.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [duplicate] /'

[ "$rc" -eq 2 ] \
  || fail "TWO units providing the same port exited $rc, expected 2. They would silently implement the same interface twice; the divergence surfaces at integration and the duplicate has to be coalesced by hand."
[ -s "$EV/calls" ] && fail "A WORKER WAS LAUNCHED on a manifest with two providers of one port"
[ "$(n_worktrees dup)" = "0" ] || fail "worktrees exist for the refused manifest"
echo "$out" | grep -q "DUPLICATE PROVIDER" || fail "the refusal never printed a DUPLICATE PROVIDER line"
echo "$out" | grep -q "store" && echo "$out" | grep -q "parser" \
  || fail "the refusal does not name BOTH duplicate providers (store, parser)"
echo "    ok: TWO units providing the same port are REFUSED (exit 2) and both are named"

# ======================================================================================
# 3. CYCLE: a → b → a in the provides→consumes DAG → REFUSED, and the CYCLE IS NAMED.
# ======================================================================================
cat > m/cycle.json <<'JSON'
{ "units": [
    { "id": "alpha", "owns": ["src/store/**"], "provides": ["port:KV"],   "consumes": ["port:Auth"], "task": "kv" },
    { "id": "beta",  "owns": ["src/api/**"],   "provides": ["port:Auth"], "consumes": ["port:KV"],   "task": "auth" }
] }
JSON
: > "$EV/calls"
out="$($D fanout m/cycle.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [cycle] /'

[ "$rc" -eq 2 ] \
  || fail "a provides→consumes CYCLE exited $rc, expected 2. A cycle means the units are NOT semantically independent — each needs the other's interface before it can build its own, and there is no order in which they can be fanned out."
[ -s "$EV/calls" ] && fail "A WORKER WAS LAUNCHED on a manifest whose units form an interface cycle"
[ "$(n_worktrees cycle)" = "0" ] || fail "worktrees exist for the refused manifest"
echo "$out" | grep -q "CYCLE" || fail "the refusal never printed a CYCLE line"
echo "$out" | grep -qE 'alpha → beta → alpha|beta → alpha → beta' \
  || fail "the refusal does not NAME THE CYCLE (expected 'alpha → beta → alpha' or 'beta → alpha → beta'). An unnamed cycle is not actionable."
echo "$out" | grep -q "port:KV" && echo "$out" | grep -q "port:Auth" \
  || fail "the refusal does not name the ports the cycle runs through"
echo "    ok: a provides→consumes CYCLE is REFUSED (exit 2) and the cycle is NAMED, with its ports"

# ======================================================================================
# 4. A VALID DAG is ACCEPTED and fanout PROCEEDS (so 1–3 are a filter, not a wall).
#    …and the FROZEN PORT is piped into the unit's brief.
# ======================================================================================
cat > m/valid.json <<'JSON'
{ "units": [
    { "id": "store", "owns": ["src/store/**"], "provides": ["port:KV"], "task": "implement the kv store" },
    { "id": "api",   "owns": ["src/api/**"],   "consumes": ["port:KV"], "task": "call the kv store" }
] }
JSON
: > "$EV/calls"
out="$($D fanout m/valid.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [valid-dag] /'

[ "$rc" -eq 0 ] \
  || fail "a VALID provides/consumes DAG exited $rc — the refusals above would then be indistinguishable from ports simply never working"
[ "$(wc -l < "$EV/calls" | tr -d ' ')" -eq 2 ] \
  || fail "expected 2 worker invocations for the valid DAG, got $(wc -l < "$EV/calls" | tr -d ' ')"
for u in store api; do
  [ "$(cat "$REPO/.fleet/fanout/valid/units/$u/state")" = "done" ] || fail "unit '$u' did not complete"
done
echo "$out" | grep -qE 'provides / .* consumes' \
  || fail "check-claims did not report the port proofs it ran on an accepted manifest"
# The FREE WIN: the frozen port is in the worker's prompt.
grep -q "FROZEN PORTS" "$EV/prompt-api.txt" \
  || fail "the frozen port block was NOT piped into the consumer's brief"
grep -q "sig kv_get" "$EV/prompt-api.txt" \
  || fail "the CONTENT of the frozen port artifact (src/ports/kv.pyi) was not piped into the consumer's brief — a port the worker cannot read is not a contract"
grep -q "READ-ONLY to you unless you PROVIDE them" "$EV/prompt-api.txt" \
  || fail "the consumer's brief does not tell it the port is read-only"
echo "    ok: a VALID DAG is ACCEPTED, both units run, and the FROZEN PORT (contents and all) is piped into the unit's brief"

# ======================================================================================
# 5. A `consumes` resolving to a port ALREADY ON THE BASE BRANCH → ACCEPTED (not dangling).
# ======================================================================================
cat > m/onbase.json <<'JSON'
{ "units": [
    { "id": "api",    "owns": ["src/api/**"],    "consumes": ["port:KV"], "task": "use the frozen kv port" },
    { "id": "parser", "owns": ["src/parser/**"], "task": "tidy the parser" }
] }
JSON
out="$($D fanout m/onbase.json --jobs 2 --dry-run 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [on-base] /'
[ "$rc" -eq 0 ] \
  || fail "a consumes of a port whose artifact ALREADY EXISTS on the base branch (src/ports/kv.pyi, committed, no unit provides it) was REFUSED with exit $rc. That is the steady state — a port frozen on main with N consumers and no in-flight provider — and refusing it would make the whole layer unusable."
echo "    ok: a consumes that resolves to a port already frozen on the BASE BRANCH is ACCEPTED (not dangling)"

# --- and it really is the base branch that saves it: an UNCOMMITTED artifact does NOT count -----
printf 'sig log(msg: str) -> None\n' > src/ports/log.pyi     # exists on disk, NOT in HEAD
cat > m/notcommitted.json <<'JSON'
{ "units": [
    { "id": "api", "owns": ["src/api/**"], "consumes": ["port:Log"], "task": "use the log port" }
] }
JSON
out="$($D fanout m/notcommitted.json --jobs 1 --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  || fail "a consumes of a port whose artifact exists ONLY IN THE WORKING TREE (never committed) was ACCEPTED (exit $rc). Fanout units branch off the BASE: an uncommitted port does not exist for them, and every consumer would build against nothing."
echo "$out" | grep -q "DANGLING PORT" || fail "the uncommitted-artifact refusal does not say DANGLING PORT"
rm -f src/ports/log.pyi
echo "    ok: 'already on the base branch' means IN GIT HEAD — an uncommitted artifact is still DANGLING"

# ======================================================================================
# 6. THE READ-ONLY PROPERTY: a unit whose DIFF touches a frozen port artifact it does not
#    `provides` → GATE FAILURE. This is the one that stops SILENT CONTRACT DRIFT.
# ======================================================================================
API_WT="$REPO/.fleet/worktrees/agent/fanout/valid/api"
[ -d "$API_WT" ] || fail "the api unit worktree from the valid fanout is missing — the read-only assertion would be vacuous"

# The consumer unit edits the contract it was handed. Nothing else about it is wrong.
( cd "$API_WT" \
  && printf 'sig kv_get(key: str) -> bytes\nsig kv_put(key: str, value: bytes) -> None\n' > src/ports/kv.pyi \
  && git add -A && git commit -qm "drift the port" ) || fail "could not set up the drifting-unit commit"

out="$( cd "$API_WT" && .fleet/bin/fleet spec check 2>&1 )"; rc=$?
echo "$out" | sed 's/^/    | [frozen-port] /'
[ "$rc" -eq 2 ] \
  || fail "a unit whose DIFF touches a FROZEN PORT it does not provide exited $rc, expected 2. A unit that can rewrite the contract it was handed will drift it silently — every sibling is still building against the OLD one, and the mismatch only surfaces at integration."
echo "$out" | grep -q "FROZEN PORT VIOLATION" || fail "the gate failure does not say FROZEN PORT VIOLATION"
echo "$out" | grep -q "src/ports/kv.pyi" || fail "the gate failure does not name the port artifact that was touched"
echo "$out" | grep -q "fleet spec amend port:KV" \
  || fail "the gate failure does not name the ONLY sanctioned way to change a frozen port (fleet spec amend)"

# …and it is a GATE failure, not just a lint: fleet_gate itself must go RED.
grc=0; ( cd "$API_WT" && . .fleet/config.sh && fleet_gate ) >/dev/null 2>&1 || grc=$?
[ "$grc" -ne 0 ] \
  || fail "fleet_gate stayed GREEN in a worktree that drifted a frozen port — \`fleet spec check\` is wired as a PRE-GATE, so the gate must be RED"

# The PROVIDER, by contrast, may edit its own port artifact.
STORE_WT="$REPO/.fleet/worktrees/agent/fanout/valid/store"
( cd "$STORE_WT" && printf 'sig kv_get(key: str) -> str\nsig kv_put(key: str, value: str) -> None\nsig kv_del(key: str) -> None\n' > src/ports/kv.pyi \
  && git add -A && git commit -qm "extend the port I provide" ) || fail "could not set up the provider commit"
out="$( cd "$STORE_WT" && .fleet/bin/fleet spec check 2>&1 )"; rc=$?
echo "$out" | sed 's/^/    | [provider] /'
[ "$rc" -eq 0 ] \
  || fail "the PROVIDER of a port was blocked (exit $rc) from touching its OWN port artifact. Read-only means read-only to everyone ELSE; the provider owns it."
( cd "$API_WT" && git reset -q --hard HEAD~1 )
echo "    ok: a unit whose DIFF touches a frozen port it does NOT provide is a GATE FAILURE (exit 2, fleet_gate RED, \`fleet spec amend\` named) — and the PROVIDER is not blocked from its own port"

# ======================================================================================
# 6b. `fleet spec amend` — the ONLY sanctioned way to change a frozen port. It must (a) NAME the
#     units that consume it and (b) REQUIRE them to be re-run. A contract change that does not
#     re-run its consumers IS the silent drift the read-only rule exists to prevent.
# ======================================================================================
for u in store api; do
  [ "$(cat "$REPO/.fleet/fanout/valid/units/$u/state")" = "done" ] || fail "precondition: unit '$u' should be done before the amend"
done
out="$($S amend port:KV --manifest m/valid.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [amend] /'
[ "$rc" -eq 0 ] || fail "\`fleet spec amend port:KV\` exited $rc"
echo "$out" | grep -q "src/ports/kv.pyi" || fail "amend does not name the artifact it is amending"
echo "$out" | grep -qE 'CONSUMERS: *api' \
  || fail "amend does not NAME the units that CONSUME the port (api) — (a) of its two jobs"
for u in store api; do
  [ "$(cat "$REPO/.fleet/fanout/valid/units/$u/state")" = "pending" ] \
    || fail "amend left unit '$u' as '$(cat "$REPO/.fleet/fanout/valid/units/$u/state")' — a port change that does not REQUIRE its consumers to be RE-RUN is exactly the silent drift this layer exists to prevent — (b) of its two jobs"
done
: > "$EV/calls"
out="$($D fanout m/valid.json --jobs 2 --resume 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "the post-amend --resume exited $rc"
[ "$(sort -u "$EV/calls" | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "the post-amend --resume re-ran $(sort -u "$EV/calls" | wc -l | tr -d ' ') unit(s); the amended port's provider AND its consumer must BOTH be re-run"
# A UNIT may not amend the contract it was handed.
out="$( cd "$API_WT" && .fleet/bin/fleet spec amend port:KV 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] \
  || fail "a fanout UNIT was allowed to \`fleet spec amend\` its own contract (exit $rc). Amending is the orchestrator's job, on the base branch: a unit that can amend the port can drift it with extra steps."
echo "    ok: \`fleet spec amend\` NAMES the consumers and MARKS them for a re-run (--resume re-runs provider + consumer), and a UNIT may not amend its own contract"

# ======================================================================================
# 7. BACKWARDS COMPATIBILITY: a manifest with NO provides/consumes behaves EXACTLY as before.
#    (The fanout-disjoint.sh scenarios, run through the new code path.)
# ======================================================================================
cat > m/bc-overlap.json <<'JSON'
{ "units": [
    { "id": "alpha", "owns": ["src/parser/**"], "task": "make the parser faster" },
    { "id": "beta",  "owns": ["src/**"],        "task": "make everything faster" }
] }
JSON
: > "$EV/calls"
out="$($D fanout m/bc-overlap.json --jobs 2 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "BC BROKEN: an OVERLAPPING manifest with no ports exited $rc, expected 2"
[ -s "$EV/calls" ] && fail "BC BROKEN: a worker was launched on a non-disjoint manifest"
echo "$out" | grep -q "OVERLAP" || fail "BC BROKEN: the file-disjointness refusal no longer names the OVERLAP"
echo "$out" | grep -qi "stuck solving the same task" \
  || fail "BC BROKEN: the refusal no longer cites the Anthropic 16-agent result"

cat > m/bc-wide.json <<'JSON'
{ "units": [
    { "id": "parser", "owns": ["src/parser/**"], "task": "tidy the parser" },
    { "id": "store",  "owns": ["src/store/**"],  "task": "tidy the store" },
    { "id": "api",    "owns": ["src/api/**"],    "task": "tidy the api" }
] }
JSON
: > "$EV/calls"
out="$($D fanout m/bc-wide.json --jobs 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [backwards-compat] /'
[ "$rc" -eq 0 ] || fail "BC BROKEN: a DISJOINT manifest with no provides/consumes exited $rc"
[ "$(wc -l < "$EV/calls" | tr -d ' ')" -eq 3 ] \
  || fail "BC BROKEN: expected 3 worker invocations, got $(wc -l < "$EV/calls" | tr -d ' ')"
grep -q "FROZEN PORTS" "$EV/prompt-parser.txt" \
  && fail "BC BROKEN: a unit that declares no ports got a FROZEN PORTS block in its brief"
echo "    ok: BACKWARDS COMPATIBLE — a manifest with NO provides/consumes is refused/accepted exactly as before, and gets no port block"

# ======================================================================================
# 8. STUB-FIRST BOOTSTRAP: `fleet spec stub` makes the CONSUMER typecheck with NO PROVIDER.
# ======================================================================================
# Day zero: the port is frozen but nobody implements it. src/api/api.py says `use kv_get`.
git -C "$REPO" checkout -q main
rm -f "$REPO/src/ports/kv_stub.py"
grc=0; ( cd "$REPO" && . .fleet/config.sh && fleet_typecheck ) >/dev/null 2>&1 || grc=$?
[ "$grc" -ne 0 ] \
  || fail "the toy typecheck PASSES with no provider and no stub — the stub assertion below would be vacuously true and would prove nothing"

out="$($S stub m/valid.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [stub] /'
[ "$rc" -eq 0 ] || fail "\`fleet spec stub\` exited $rc"
[ -f "$REPO/src/ports/kv_stub.py" ] \
  || fail "\`fleet spec stub\` did not generate src/ports/kv_stub.py via the fleet_stub_for hook"
grep -q "NotImplementedError" "$REPO/src/ports/kv_stub.py" \
  || fail "the generated stub has no body — it must COMPILE, that is its entire job"
grc=0; ( cd "$REPO" && . .fleet/config.sh && fleet_typecheck ) >/dev/null 2>&1 || grc=$?
[ "$grc" -eq 0 ] \
  || fail "the CONSUMER still does not typecheck after \`fleet spec stub\` — with NO provider unit in existence, the stub is the only thing that can decouple them (STVR 2025: 'the CDC tests don't require running the consumer and the provider simultaneously')"
# It only stubs what the manifest PROVIDES: port:Auth is not in m/valid.json.
[ -f "$REPO/src/ports/auth_stub.py" ] \
  && fail "\`fleet spec stub <manifest>\` stubbed a port no unit in that manifest provides"
echo "    ok: \`fleet spec stub\` generates a stub (via the stack-agnostic fleet_stub_for hook) that makes the CONSUMER typecheck on DAY ZERO with NO provider in existence"

# ======================================================================================
# 9. NO REGRESSION IN `fleet fronts`: its output (no provides/consumes) still passes spec check.
# ======================================================================================
rm -f "$REPO/src/ports/kv_stub.py"
out="$(.fleet/bin/fleet fronts --oracle 'echo "src/parser/parser.py:1:1: error: boom"; echo "src/store/store.py:2:1: error: bang"; exit 1' -o m/fronts.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [fronts] /'
[ "$rc" -eq 0 ] || fail "\`fleet fronts\` exited $rc — it must still emit a manifest with the port proofs in the prover"
out="$($S check m/fronts.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [fronts→spec check] /'
[ "$rc" -eq 0 ] \
  || fail "the manifest \`fleet fronts\` generated (which declares NO provides/consumes) is REJECTED by \`fleet spec check\` (exit $rc). A generator whose output the new prover refuses is a regression."
echo "    ok: \`fleet fronts\` output still passes \`fleet spec check\` — no regression"

echo "PASS: fleet spec extends the disjointness proof from FILES to INTERFACES — a DANGLING consumes, TWO providers of one port, and a provides→consumes CYCLE (named in the error) are each REFUSED with exit 2 and launch nothing; a valid DAG runs and gets the FROZEN PORT piped into its brief; a port already frozen on the BASE BRANCH is not dangling (but an uncommitted one is); a unit whose diff touches a frozen port it does not provide is a GATE FAILURE while its provider is not; \`fleet spec stub\` makes a consumer typecheck on day zero with no provider; and a manifest with NO provides/consumes behaves exactly as it always did"
