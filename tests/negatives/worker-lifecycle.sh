#!/usr/bin/env bash
# NEGATIVE: a worker must NEVER outlive its supervisor (#58).
#
# Reported from the field: a claudez worker kept running after returning its result and went on
# EDITING FILES. Root cause: `claude` inherited the supervisor's process group and nothing ever
# killed it. When the supervisor died — Ctrl-C, a harness/CI timeout, an interrupted `fanout`, a
# closed terminal — the worker was orphaned and kept writing, with --dangerously-skip-permissions.
#
# THE OS SANDBOX DOES NOT HELP. It confines writes TO THE WORKTREE, which is exactly where the
# zombie writes. Confinement is not lifecycle. A zombie can mutate a unit AFTER fanout recorded it
# done and AFTER fleet integrate merged it — the commit and the working tree then disagree, and
# nothing in fleet notices.
#
# The test kills the GROUP, not the leader, and asserts BOTH the worker and a CHILD it forked are
# dead — because `claude` spawns bash tools / python / nested claude, and killing only the leader
# orphans those in turn.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'pkill -f "$TMP/bin/claude" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/r"
cd "$TMP/r"
git init -q -b main .; git config user.email t@t; git config user.name t
mkdir -p .fleet
cp -R "$ROOT/src/fleet/lib" "$ROOT/src/fleet/bin" .fleet/
printf 'FLEET_MAIN="main"\nfleet_bootstrap(){ :; }\nfleet_pkg_for(){ echo ""; }\nfleet_gate(){ :; }\n' > .fleet/config.sh
echo x > f; git add -A >/dev/null; git commit -qm init >/dev/null
git worktree add -q .fleet/worktrees/victim -b victim 2>/dev/null

# A stub worker that behaves like the real thing: forks a child, works a while, THEN writes.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
( sleep 8; echo grandchild > GRANDCHILD.txt ) &     # the forked child — must ALSO die
sleep 5
echo zombie > ZOMBIE.txt                            # the write that must never happen
echo '{"type":"result","session_id":"s1","result":"done","total_cost_usd":0}'
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

V="$TMP/r/.fleet/worktrees/victim"

# ---- 1. PRECONDITION: the stub really would write, if left alone --------------------
# The stub's forked child writes at t=8s. Let BOTH writes land, THEN clean up — otherwise the
# precondition's own grandchild lands after the cleanup and gets mistaken for an orphan in step 2.
# (That contamination is exactly what this test caught on its first run.)
( cd "$V" && "$TMP/bin/claude" >/dev/null 2>&1 ) &
sleep 10
[ -f "$V/ZOMBIE.txt" ]     || fail "precondition: the stub worker did not write even when left alone — the test proves nothing"
[ -f "$V/GRANDCHILD.txt" ] || fail "precondition: the stub's forked CHILD did not write — the group-kill assertion below would pass vacuously"
pkill -f "$TMP/bin/claude" 2>/dev/null || true
wait 2>/dev/null || true
sleep 1
rm -f "$V/ZOMBIE.txt" "$V/GRANDCHILD.txt"
[ -f "$V/ZOMBIE.txt" ] || [ -f "$V/GRANDCHILD.txt" ] && fail "cleanup failed — leftovers would contaminate the orphan assertions"
echo "    precondition ok: the stub AND its forked child DO write if nothing kills them"

# ---- 2. Kill the supervisor. The worker and its child must BOTH die. ----------------
FLEET_DELEGATE_SANDBOX=0 .fleet/bin/agent-delegate.sh delegate "$V" "work" >/dev/null 2>&1 &
SUP=$!
sleep 2
kill -0 "$SUP" 2>/dev/null || fail "the supervisor exited on its own — the test is not exercising the orphan path"
kill -TERM "$SUP" 2>/dev/null
wait "$SUP" 2>/dev/null || true
sleep 1

ALIVE="$(pgrep -f "$TMP/bin/claude" 2>/dev/null | wc -l | tr -d ' ')"
[ "$ALIVE" = "0" ] || fail "ORPHANED: $ALIVE worker process(es) still running after the supervisor died. A worker with --dangerously-skip-permissions that outlives its supervisor keeps EDITING FILES (#58)"

sleep 9   # long enough for BOTH the worker's write and its child's write to have happened
[ -f "$V/ZOMBIE.txt" ] && fail "ORPHANED: the worker wrote ZOMBIE.txt into the worktree AFTER its supervisor died. The OS sandbox permits this — it confines writes to the worktree, which is exactly where the zombie writes. Confinement is not lifecycle."
[ -f "$V/GRANDCHILD.txt" ] && fail "the worker's CHILD survived and wrote GRANDCHILD.txt. Killing the process-group LEADER is not enough — claude spawns bash/python/nested-claude children. Kill the GROUP."
echo "    ok: supervisor death kills the worker AND its forked child (the whole process group)"

# ---- 3. A worker that exits normally must be reaped too (no lingering group) --------
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
( sleep 20; echo late > LATE.txt ) &   # a child that outlives the parent's own exit
echo '{"type":"result","session_id":"s2","result":"done","total_cost_usd":0}'
EOF
chmod +x "$TMP/bin/claude"
FLEET_DELEGATE_SANDBOX=0 .fleet/bin/agent-delegate.sh delegate "$V" "work" >/dev/null 2>&1
sleep 1
ALIVE="$(pgrep -f "$TMP/bin/claude" 2>/dev/null | wc -l | tr -d ' ')"
[ "$ALIVE" = "0" ] || fail "a worker that RETURNED ITS RESULT left $ALIVE process(es) behind. This is the reported symptom: 'it returned results and kept editing files'."
sleep 21
[ -f "$V/LATE.txt" ] && fail "a child of a COMPLETED worker survived and wrote LATE.txt — the group is not reaped on the success path either"
echo "    ok: a worker that returns normally leaves NO surviving process group"

echo "PASS: workers cannot outlive their supervisor — the process group is killed on supervisor death AND on normal completion, including forked children"
