#!/usr/bin/env bash
# NEGATIVE: a guard that means to BLOCK must exit 2 — never 1 (#31).
#
# Claude Code treats exit 1 as a NON-BLOCKING error and PROCEEDS with the action
# (code.claude.com/docs/en/hooks). Only exit 2 (or a JSON permissionDecision:"deny")
# actually blocks. So a deny path that reaches `exit 1` — an uncaught exception, a stray
# return, a refactor that "cleans up" the exit code — silently converts a BLOCK into an
# ALLOW, and every existing test still passes because the guard *did* print its reason.
#
# Today both guards are correct: every deny is exit 2, every allow is exit 0, and there
# is no exit 1 anywhere. This test exists so that stays true. It is a tripwire, not a fix.
#
# It also PINS the deliberate fail-open paths (malformed JSON, non-Bash tool, unparseable
# command → exit 0). Those are a real decision — a guard that hard-blocks on its own parse
# errors would wedge the agent — but they should be an explicit, tested decision rather
# than an accident nobody remembers making.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COORD="$ROOT/src/claude/hooks/claude-coord-guard.py"
WTG="$ROOT/src/claude/hooks/claude-worktree-guard.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

jq_cmd() {  # $1 = tool_name, $2 = command/path payload → hook stdin JSON
  python3 - "$@" <<'PY'
import json, sys
tool, payload, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
ti = {"command": payload} if tool == "Bash" else {"file_path": payload}
print(json.dumps({"tool_name": tool, "tool_input": ti, "cwd": cwd}))
PY
}
run() {  # $1 = guard, $2 = tool, $3 = payload → exit code
  jq_cmd "$2" "$3" "$TMP" | python3 "$1" >/dev/null 2>&1; echo $?
}

mkdir -p "$TMP/wt"; cd "$TMP/wt"; git init -q -b main .; cd "$ROOT"

# --- 1. Every DENY path exits exactly 2 (and specifically NOT 1) ----------------------
# coord-guard: one case per distinct deny() call site.
COORD_DENIES=(
  'git commit --no-verify -m x'
  'git push --no-verify origin feature'
  'git worktree add --force ../wt2 branch'
  'git worktree add -f ../wt2 branch'
  'git checkout --ignore-other-worktrees main'
  'git push origin main'
  'git push origin master'
  'git push origin release/1.0'
  'git push origin HEAD:refs/heads/main'
  'git -c core.hooksPath=/dev/null push origin feature'
  'git config core.hooksPath /dev/null'
  'git config extensions.worktreeConfig true'
  'GIT_CONFIG_KEY_0=core.hooksPath git push origin feature'
)
for c in "${COORD_DENIES[@]}"; do
  rc="$(run "$COORD" Bash "$c")"
  [ "$rc" = "1" ] && fail "coord-guard exited 1 — Claude Code PROCEEDS on 1, so this BLOCK is actually an ALLOW: $c"
  [ "$rc" = "2" ] || fail "coord-guard should BLOCK with exit 2 (got $rc): $c"
done
echo "    ok: all ${#COORD_DENIES[@]} coord-guard deny paths exit 2 (none exit 1)"

# worktree-guard: secret reads/writes and tamper paths.
WTG_DENIES=( "$HOME/.ssh/id_rsa" "$HOME/.aws/credentials" "$HOME/.claude/.credentials.json" )
for p in "${WTG_DENIES[@]}"; do
  rc="$(run "$WTG" Write "$p")"
  [ "$rc" = "1" ] && fail "worktree-guard exited 1 (FAILS OPEN) on a secret path: $p"
  [ "$rc" = "2" ] || fail "worktree-guard should BLOCK with exit 2 (got $rc) on: $p"
done
echo "    ok: all ${#WTG_DENIES[@]} worktree-guard deny paths exit 2 (none exit 1)"

# --- 2. NO input may ever produce exit 1 from either guard ----------------------------
# Includes deliberate garbage: if a guard ever raises and the handler regresses, this
# catches the fail-open before it ships.
JUNK=( '' '{' 'not json at all' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'
       '{"tool_name":"Bash","tool_input":{"command":"git push \"unterminated"}}'
       '{"tool_name":"Weird","tool_input":{"command":"rm -rf /"}}' )
for j in "${JUNK[@]}"; do
  for g in "$COORD" "$WTG"; do
    printf '%s' "$j" | python3 "$g" >/dev/null 2>&1; rc=$?
    [ "$rc" = "1" ] && fail "$(basename "$g") exited 1 on malformed input — a hook error that FAILS OPEN. Input: $j"
    case "$rc" in 0|2) : ;; *) fail "$(basename "$g") exited $rc (expected 0 or 2). Input: $j" ;; esac
  done
done
echo "    ok: malformed/garbage input never yields exit 1 from either guard"

# --- 3. The deliberate fail-open paths are exit 0, on purpose -------------------------
[ "$(printf 'not json' | python3 "$COORD" >/dev/null 2>&1; echo $?)" = "0" ] \
  || fail "coord-guard no longer fails OPEN on unparseable JSON — that is a deliberate design choice; if you changed it, update this test and the docstring"
[ "$(run "$COORD" Bash 'ls -la')" = "0" ] || fail "coord-guard blocked a non-git command"
[ "$(run "$COORD" Bash 'git status')" = "0" ] || fail "coord-guard blocked a harmless git command"
echo "    ok: documented fail-open paths (bad JSON, non-Bash, non-git) exit 0 deliberately"

# --- 4. Belt and braces: no literal `exit 1` in either guard's source -----------------
for g in "$COORD" "$WTG"; do
  if grep -nE 'sys\.exit\(1\)|exit\(1\)' "$g"; then
    fail "$(basename "$g") contains a literal exit(1) — on a deny path that FAILS OPEN"
  fi
done
echo "    ok: neither guard contains a literal exit(1)"

echo "PASS: every guard deny path exits 2, no input produces the fail-open exit 1, and the deliberate exit-0 fail-open paths are pinned"
