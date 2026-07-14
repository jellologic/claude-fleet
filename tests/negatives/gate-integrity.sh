#!/usr/bin/env bash
# NEGATIVE: the merge gate cannot be silently unwired (#30).
#
# fleet's pre-push hook IS the merge gate, and it hangs off `core.hooksPath`. Anything
# that repoints that config turns the gate off SILENTLY — verified:
#     $ git -c core.hooksPath=/dev/null push origin main
#     * [new branch] main -> main      # gate never ran, push landed
# For a no-CI repo whose only pre-merge check is that hook, this is the whole ballgame.
#
# Two rails are asserted here:
#   1. coord-guard DENIES (exit 2) every form of the bypass at the TOOL layer.
#   2. check-gate-integrity DETECTS a gate that has already been unwired, out of band
#      (a check inside the hook is useless — a disabled hook does not run).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUARD="$ROOT/src/claude/hooks/claude-coord-guard.py"
GATECHECK="$ROOT/src/fleet/bin/check-gate-integrity.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Feed a Bash command to the guard exactly as Claude Code would. Echoes the exit code.
guard_rc() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" "$TMP" \
    | python3 "$GUARD" >/dev/null 2>&1; echo $?
}

# ---- 0. FIRST prove the bypass is real, or the rest of this test is theatre. ---------
git init -q -b main "$TMP/o.git" --bare
git init -q -b main "$TMP/r"; cd "$TMP/r"
git config user.email t@t; git config user.name t
mkdir -p .fleet/githooks
printf '#!/usr/bin/env sh\necho "GATE RAN" >&2\nexit 1\n' > .fleet/githooks/pre-push
chmod +x .fleet/githooks/pre-push
git config core.hooksPath .fleet/githooks
echo x > f; git add -A; git commit -qm init
git remote add origin "$TMP/o.git"
git push origin main >/dev/null 2>&1 && fail "precondition: the always-blocking gate did NOT block a normal push"
git -c core.hooksPath=/dev/null push origin main >/dev/null 2>&1 \
  || fail "precondition: the -c core.hooksPath bypass did not push — this test is not exercising #30"
echo "    precondition ok: 'git -c core.hooksPath=/dev/null push' DOES bypass the gate (that's the bug)"
cd "$ROOT"

# ---- 1. coord-guard must DENY every bypass form, with exit 2 (NOT 1 — 1 fails open) --
# Each of these disables or relocates the gate.
DENY_CASES=(
  'git -c core.hooksPath=/dev/null push origin main'
  'git -c core.hooksPath=/tmp/x push origin feature'
  'git config core.hooksPath /dev/null'
  'git config --worktree core.hooksPath /dev/null'
  'git config --local core.hooksPath /tmp/nope'
  'git config extensions.worktreeConfig true'
  'git -c extensions.worktreeConfig=true config --worktree core.hooksPath /dev/null'
  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git push origin main'
)
for c in "${DENY_CASES[@]}"; do
  rc="$(guard_rc "$c")"
  [ "$rc" = "2" ] || fail "coord-guard did NOT block (exit $rc, need 2): $c"
  # exit 1 is the fail-open trap (#31): Claude Code PROCEEDS on 1.
  [ "$rc" = "1" ] && fail "coord-guard exited 1 (FAILS OPEN — Claude proceeds) on: $c"
done
echo "    ok: all ${#DENY_CASES[@]} hooksPath bypass forms denied with exit 2"

# ---- 2. ...without breaking legitimate git usage (no over-firing) --------------------
ALLOW_CASES=(
  'git push origin agent/issue-30'
  'git config user.email me@example.com'
  'git -c color.ui=always log --oneline -5'
  'git commit -m "core.hooksPath is only mentioned in this message"'
  'git config --get core.hooksPath'
)
for c in "${ALLOW_CASES[@]}"; do
  rc="$(guard_rc "$c")"
  [ "$rc" = "0" ] || fail "coord-guard OVER-FIRED (exit $rc) on a legitimate command: $c"
done
echo "    ok: legitimate git commands still allowed (guard does not over-fire)"

# ---- 3. check-gate-integrity must DETECT an already-unwired gate ---------------------
cd "$TMP/r"
"$GATECHECK" --quiet || fail "gate-check called a correctly-wired gate TAMPERED"
echo "    ok: gate-check passes on a correctly wired gate"

git config core.hooksPath /dev/null
"$GATECHECK" --quiet 2>/dev/null && fail "gate-check did NOT detect a repointed core.hooksPath"
git config core.hooksPath .fleet/githooks

chmod -x .fleet/githooks/pre-push
"$GATECHECK" --quiet 2>/dev/null && fail "gate-check did NOT detect a NON-EXECUTABLE pre-push hook (git silently skips it)"
chmod +x .fleet/githooks/pre-push

git config extensions.worktreeConfig true
"$GATECHECK" --quiet 2>/dev/null && fail "gate-check did NOT detect extensions.worktreeConfig (enables a private per-worktree hooksPath)"
git config --unset extensions.worktreeConfig

git config --unset core.hooksPath
"$GATECHECK" --quiet 2>/dev/null && fail "gate-check did NOT detect an UNSET core.hooksPath"
echo "    ok: gate-check detects repointed / unset / non-executable / worktree-overridable gates"

echo "PASS: every core.hooksPath bypass is denied at the tool layer with exit 2 (never 1, which fails open), legitimate git still works, and an already-unwired gate is detected out of band"
