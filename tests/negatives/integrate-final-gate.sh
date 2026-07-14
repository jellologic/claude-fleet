#!/usr/bin/env bash
# NEGATIVE: fleet-integrate must FAIL (non-zero) when the FINAL gate fails.
#
# Regression for #18. The FINAL gate runs on the *integrated* result and, unlike a
# per-branch gate failure, is NOT rolled back — the integration branch is left at the
# broken merge. The exit code is therefore the only signal a caller (CI, a script,
# `fleet integrate ... && git push`) ever gets. If it exits 0, a broken tree ships.
#
# The trap this guards against: every branch merges cleanly, so the per-branch FAIL
# array is empty — only the FINAL gate objects. Pre-fix, its status was swallowed by
# `if gate ...; then ...; else echo FAIL; fi` and the script exited 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The scenario that matters: the branch passes its own gate and merges cleanly, and
# ONLY the integrated result is broken (a semantic conflict — each branch is fine
# alone, the combination is not). That leaves the per-branch FAIL array EMPTY, so the
# exit code can only come from the FINAL gate. A stub that fails unconditionally would
# also trip the per-branch gate and exit non-zero for the wrong reason — the test would
# then pass against the buggy code and prove nothing.
git init -q -b main "$TMP/repo"
cd "$TMP/repo"
git config user.email t@t; git config user.name t
mkdir -p .fleet
cp -R "$SRC/lib" "$SRC/bin" .fleet/
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }        # force a full-tree gate
# Passes for every per-branch call; fails only on the LAST call, which is the FINAL
# gate on the integrated tree. Counter lives outside the repo so it survives resets.
fleet_gate() {
  local n
  n=$(( $(cat "$FLEET_TEST_COUNTER" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FLEET_TEST_COUNTER"
  if [ "$n" -ge "$FLEET_TEST_FAIL_ON" ]; then
    echo "    [stub gate] call #$n = FINAL → FAILING ON PURPOSE"; return 1
  fi
  echo "    [stub gate] call #$n = per-branch → pass"; return 0
}
CFG
echo base > file.txt
git add -A; git commit -qm base

# A feature branch that merges without conflict.
git checkout -qb feat
echo feat > feat.txt
git add -A; git commit -qm feat

# Integrate from a clean integration branch, as fleet-integrate requires.
# One branch → gate call #1 is per-branch (passes), call #2 is FINAL (fails).
git checkout -q main
git checkout -qb integ
export FLEET_TEST_COUNTER="$TMP/gate-calls"
export FLEET_TEST_FAIL_ON=2
set +e
out="$(.fleet/bin/fleet-integrate.sh integ feat 2>&1)"; rc=$?
set -e

echo "$out" | sed 's/^/    | /'

# Preconditions — if these don't hold, the test isn't exercising #18 at all.
echo "$out" | grep -q "RESULT: PASS"     || fail "branch was rejected per-branch — FAIL[] is non-empty, so a non-zero exit would prove nothing"
echo "$out" | grep -q "rejected     (0)" || fail "FAIL[] is non-empty — the exit code would come from the per-branch path, not FINAL"
echo "$out" | grep -q "FINAL: FAIL"      || fail "FINAL gate did not report FAIL — the test is not exercising the bug"

# The actual assertion: with FAIL[] empty, ONLY the FINAL gate can drive the exit code.
[ "$rc" -ne 0 ] || fail "fleet-integrate exited 0 with a FAILING final gate (#18) — a broken tree reports success"

# Opposite direction: an all-passing run must still exit 0, or the fix over-fires.
: > "$FLEET_TEST_COUNTER"
export FLEET_TEST_FAIL_ON=99
git checkout -q main; git branch -qD integ; git checkout -qb integ
set +e
.fleet/bin/fleet-integrate.sh integ feat >/dev/null 2>&1; rc_pass=$?
set -e
[ "$rc_pass" -eq 0 ] || fail "fleet-integrate exited $rc_pass with an all-PASSING gate — the fix over-fires"

echo "PASS: clean merge + passing branch gate + FAILING final gate → exit $rc (was 0 pre-fix); all-pass → exit 0"
