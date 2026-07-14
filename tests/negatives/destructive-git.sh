#!/usr/bin/env bash
# NEGATIVE: coord-guard must deny WORKTREE-WIDE destructive git, and must NOT over-fire
# on path-scoped or read-only forms (#38).
#
# Bun's first parallel run died about two minutes in: "one Claude ran `git stash` before
# committing. Another ran `git stash pop`. And then `git reset HEAD --hard`. They were
# stepping on each other!" Their fix was a PROMPT RULE. A prompt rule is not a rail.
#
# fleet's worktree isolation already prevents the cross-agent version. The damage that
# REMAINS is self-inflicted and still severe: since #22 the reaper reads uncommitted work
# as its liveness signal, so an agent that `reset --hard`s itself looks DEAD and can be
# reaped out from under its own PR.
#
# The over-firing assertions are load-bearing, not decoration. `git checkout -- one/file`
# is routine; a guard that blocks it trains agents to set FLEET_ALLOW_DESTRUCTIVE_GIT=1
# and lose the rail entirely. Deny the whole-tree forms; allow the scoped ones.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUARD="$ROOT/src/claude/hooks/claude-coord-guard.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Feed a Bash command to the guard exactly as Claude Code does. Echoes the exit code.
guard_rc() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" "$TMP" \
    | env -u FLEET_ALLOW_DESTRUCTIVE_GIT python3 "$GUARD" >/dev/null 2>&1; echo $?
}

# ---- 1. WORKTREE-WIDE destruction must be DENIED with exit 2 (never 1 — 1 fails open) --
DENY=(
  'git reset --hard'
  'git reset --hard HEAD'
  'git reset HEAD --hard'
  'git reset --hard origin/main'
  'git clean -fd'
  'git clean -f'
  'git clean -fdx'
  'git stash'
  'git stash push'
  'git stash pop'
  'git stash save wip'
  'git checkout -f main'
  'git checkout .'
  'git checkout -- .'
  'git restore .'
  'git restore'
  # Real invocations that a bag-of-tokens check would still catch, but that a naive
  # "is toks[0] == git" check would MISS. These must be denied.
  'cd /repo && git reset --hard'
  'git fetch origin && git reset --hard origin/main'
  'git -C /some/worktree reset --hard'
  'env FOO=1 git stash'
)
for c in "${DENY[@]}"; do
  rc="$(guard_rc "$c")"
  [ "$rc" = "1" ] && fail "coord-guard exited 1 (Claude PROCEEDS on 1 — this BLOCK is an ALLOW): $c"
  [ "$rc" = "2" ] || fail "coord-guard did NOT block (exit $rc, need 2): $c"
done
echo "    ok: all ${#DENY[@]} worktree-wide destructive forms denied with exit 2"

# ---- 2. It must NOT over-fire. These are routine and MUST stay allowed. ---------------
# This half matters as much as the first: a guard that blocks everyday work gets disabled.
ALLOW=(
  'git checkout -- src/foo.py'          # scoped discard — routine
  'git checkout -- a.txt b.txt'
  'git restore src/foo.py'              # scoped discard — routine
  'git restore --staged src/foo.py'
  'git checkout main'                   # switching branches destroys nothing
  'git checkout -b agent/issue-38'
  'git reset'                           # mixed reset — non-destructive
  'git reset --soft HEAD~1'
  'git reset HEAD src/foo.py'           # unstage — non-destructive
  'git clean -n'                        # dry run
  'git clean --dry-run'
  'git stash list'                      # read-only
  'git stash show'
  'git status'
  'git commit -m "reset --hard is only mentioned in this message"'
  'git log --oneline -5'
  # Not an invocation at all — the words merely APPEAR. A bag-of-tokens guard fires here;
  # a guard that parses real invocations does not. This is the precision assertion.
  'echo git reset --hard'
  'grep -rn "git stash" docs/'
  'echo "do not run git clean -fd"'
)
for c in "${ALLOW[@]}"; do
  rc="$(guard_rc "$c")"
  [ "$rc" = "0" ] || fail "coord-guard OVER-FIRED (exit $rc) on a routine command — this is how a rail gets disabled: $c"
done
echo "    ok: all ${#ALLOW[@]} routine/path-scoped/read-only commands still allowed"

# ---- 3. The human escape hatch works, and ONLY via the env var ------------------------
rc="$(printf '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"},"cwd":"%s"}' "$TMP" \
      | FLEET_ALLOW_DESTRUCTIVE_GIT=1 python3 "$GUARD" >/dev/null 2>&1; echo $?)"
[ "$rc" = "0" ] || fail "FLEET_ALLOW_DESTRUCTIVE_GIT=1 did not permit an explicit human override (exit $rc)"
rc="$(printf '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"},"cwd":"%s"}' "$TMP" \
      | FLEET_ALLOW_DESTRUCTIVE_GIT=0 python3 "$GUARD" >/dev/null 2>&1; echo $?)"
[ "$rc" = "2" ] || fail "FLEET_ALLOW_DESTRUCTIVE_GIT=0 should NOT open the hatch (exit $rc)"
echo "    ok: FLEET_ALLOW_DESTRUCTIVE_GIT=1 overrides; =0 does not"

# ---- 4. Non-git commands are none of this guard's business ----------------------------
for c in 'rm -rf build' 'echo git reset --hard' 'ls -la'; do
  rc="$(guard_rc "$c")"
  [ "$rc" = "0" ] || fail "coord-guard fired on a non-git command (exit $rc): $c"
done
echo "    ok: non-git commands untouched"

echo "PASS: worktree-wide destructive git (reset --hard, clean -f, stash, whole-tree checkout/restore) denied with exit 2; path-scoped and read-only forms still allowed; human override honoured"
