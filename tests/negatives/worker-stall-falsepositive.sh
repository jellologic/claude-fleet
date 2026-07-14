#!/usr/bin/env bash
# NEGATIVE: the supervisor must not kill a HEALTHY worker (#70).
#
# The stall detector measured growth of the worker's stdout+stderr. But the worker runs with
# `--output-format json`, which prints the ENTIRE result at the END, in one blob. A perfectly
# healthy worker therefore emits ZERO incremental output for its whole run — so "quiet" is ALWAYS
# true, and FLEET_WORKER_STALL_S was not a liveness signal at all. It was a hidden SECOND wall-clock
# timeout that killed any worker slower than the threshold.
#
# It corrupted a live experiment (#61): healthy `api` workers were killed at 600s, and because the
# arm under test had a longer prompt (and so ran slower), the false positive hit THAT arm harder —
# biasing the result toward the hypothesis. A monitor whose input is constant is worse than no
# monitor: it fires on the wrong thing and you believe it.
#
# So stall detection is OFF by default, the WALL-CLOCK timeout is the real protection against a
# wedged worker (it needs no output at all), and a supervisor kill is reported DISTINCTLY from a
# task failure — or a caller silently counts infrastructure as a result.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'pkill -f "$TMP/bin/claude" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/r"; cd "$TMP/r"
git init -q -b main .; git config user.email t@t; git config user.name t
mkdir -p .fleet
cp -R "$ROOT/src/fleet/lib" "$ROOT/src/fleet/bin" .fleet/
printf 'FLEET_MAIN="main"\nfleet_bootstrap(){ :; }\nfleet_pkg_for(){ echo ""; }\nfleet_gate(){ :; }\n' > .fleet/config.sh
echo x > f; git add -A >/dev/null; git commit -qm init >/dev/null
git worktree add -q .fleet/worktrees/w -b w 2>/dev/null
V="$TMP/r/.fleet/worktrees/w"
export PATH="$TMP/bin:$PATH"

# ---- 1. A HEALTHY worker that is SLOW and SILENT must survive -------------------------
# This is exactly what `--output-format json` looks like from the outside: nothing, nothing,
# nothing… then the whole result at once. It must NOT be mistaken for a stall.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 6                      # working. silent, because json only prints at the end.
echo '{"type":"result","session_id":"s1","result":"done","total_cost_usd":0.01}'
EOF
chmod +x "$TMP/bin/claude"

out="$(FLEET_DELEGATE_SANDBOX=0 .fleet/bin/agent-delegate.sh delegate "$V" "work" 2>&1)"; rc=$?
echo "$out" | grep -qi 'STALL-KILL\|STALLED' \
  && fail "a HEALTHY worker (silent for 6s, then a valid JSON result) was STALL-KILLED under the DEFAULT config. With --output-format json a healthy worker emits nothing until it finishes — 'quiet' is always true, so stall detection is meaningless and must be OFF by default (#70)."
[ "$rc" -eq 0 ] || fail "a healthy slow worker exited $rc under the default config (expected 0). Output: $(echo "$out" | tail -2)"
echo "    ok: a healthy, slow, SILENT worker survives under the default config"

# ---- 2. The default really is OFF (assert it, don't assume) --------------------------
grep -qE '^: "\$\{FLEET_WORKER_STALL_S:=0\}"' "$ROOT/src/fleet/bin/agent-delegate.sh" \
  || fail "FLEET_WORKER_STALL_S does not default to 0 — a non-streaming worker will be killed on a signal that does not exist (#70)"
echo "    ok: FLEET_WORKER_STALL_S defaults to 0 (OFF)"

# ---- 3. A genuinely WEDGED worker is STILL killed — by the wall clock ----------------
# The real protection. It needs no output at all, so it works regardless of output format.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 3600      # wedged. never returns.
EOF
chmod +x "$TMP/bin/claude"
start=$(date +%s)
out="$(FLEET_WORKER_WALL_TIMEOUT_S=5 FLEET_DELEGATE_SANDBOX=0 \
       .fleet/bin/agent-delegate.sh delegate "$V" "work" 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 40 ] || fail "a wedged worker was not killed by the wall-clock timeout (took ${elapsed}s)"
echo "$out" | grep -qi 'WALL-TIMEOUT' || fail "a wall-clock kill was not reported as WALL-TIMEOUT"
[ "$(pgrep -f "$TMP/bin/claude" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || fail "the wedged worker's process group survived the wall-clock kill"
echo "    ok: a genuinely wedged worker IS still killed by the wall clock, and its group is reaped"

# ---- 4. A supervisor kill must NOT masquerade as a task failure ----------------------
# If it does, a CI run or an experiment silently counts infrastructure as a result — which is
# exactly what corrupted #61.
echo "$out" | grep -qi 'NOT a task failure' \
  || fail "a supervisor kill was not distinguished from a task failure. A caller cannot tell 'the unit failed' from 'we killed the unit', and will count infrastructure as a result (#70)."
echo "$out" | grep -qi 'worker could not be run (exit 124)' \
  && fail "the wall-clock kill was reported with the generic 'worker could not be run' text — indistinguishable from a real failure"
echo "    ok: a supervisor kill is reported DISTINCTLY from a task failure"

echo "PASS: a healthy silent worker is not stall-killed (stall detection is OFF by default because --output-format json emits nothing until the end), a wedged worker is still killed by the wall clock, and a supervisor kill is never mistaken for a task failure"
