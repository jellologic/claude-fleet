#!/usr/bin/env bash
# NEGATIVE: a delegated `claude -p` worker must be CONFINED BY THE OS, must fail closed when
# it cannot be, must self-heal or escalate, must survive gateway back-pressure, and must never
# leak its bearer token.
#
# Regression for #23. Delegation runs the worker with `--dangerously-skip-permissions`, so the
# ONLY thing standing between it and the rest of the filesystem is confinement. fleet's
# `PreToolUse` write-guard (.claude/hooks/claude-worktree-guard.py) is NOT that thing: it binds
# Claude's own Write/Edit tools and a handful of recognised bash builtins, but not arbitrary
# subprocesses. `echo ESCAPED > ../outside.txt`, `sed -i`, `python3 open(...,'w')` — every one of
# them sails through the hook (Claude Code's docs say as much: "deny rules … don't apply to
# arbitrary subprocesses that read or write files indirectly … For OS-level enforcement … enable
# the sandbox"). So the confinement rail has to be an OS sandbox — on macOS, `sandbox-exec` with
# a generated deny-file-write profile — and it has to FAIL CLOSED, because a wrapper that
# silently runs the worker unsandboxed when the sandbox is unavailable is worse than no wrapper:
# it looks safe.
#
# The subtle trap this suite exists to catch: the profile must allow /tmp + $TMPDIR (toolchains
# need scratch space) AND still confine a repo that happens to LIVE under /tmp or $TMPDIR — as
# every repo in this test does. SBPL is last-match-wins, so the repo root and the sibling
# worktrees are re-denied AFTER the broad scratch allow. Get that order wrong and the sandbox is
# a no-op for exactly the repos this test uses, and the suite would pass while proving nothing.
#
# `claude` is stubbed on PATH, so this test needs no model and no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) : ;;
  *) echo "SKIP: delegate confinement is sandbox-exec (macOS) only; on this platform fleet delegate refuses to run at all"; exit 0 ;;
esac

EV="$TMP/evidence"; mkdir -p "$EV"       # outside the repo → writable from inside the sandbox
export FLEET_TEST_EVIDENCE="$EV"

# --- the fake headless worker ---------------------------------------------------------
# Stands in for `claude -p --output-format json`. Records its argv and the provider env it was
# handed (so the suite can prove the token travelled by ENV and never by ARGV), then behaves as
# FLEET_TEST_WORKER dictates. It runs INSIDE the sandbox — that is the whole point.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
EV="${FLEET_TEST_EVIDENCE:?}"
printf '%s\n' "$*" >> "$EV/argv.log"
printf 'AUTH=%s BASE=%s SONNET=%s OPUS=%s TIMEOUT=%s\n' \
  "${ANTHROPIC_AUTH_TOKEN:-<unset>}" "${ANTHROPIC_BASE_URL:-<unset>}" \
  "${ANTHROPIC_DEFAULT_SONNET_MODEL:-<unset>}" "${ANTHROPIC_DEFAULT_OPUS_MODEL:-<unset>}" \
  "${API_TIMEOUT_MS:-<unset>}" >> "$EV/env.log"
echo x >> "$EV/calls"; N="$(wc -l < "$EV/calls" | tr -d ' ')"

sid="sess-abc123"
ok_json() { printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"%s","total_cost_usd":0.0123,"num_turns":3,"duration_ms":4200}\n' "$sid" "$1"; }

case "${FLEET_TEST_WORKER:-ok}" in
  escape)
    # The RFC's exact repro, in the three shapes the Python write-guard misses.
    echo ESCAPED > "$FLEET_TEST_OUTSIDE"  2>>"$EV/escape.err"   # Bash redirect out of the worktree
    echo ESCAPED > "$FLEET_TEST_SIBLING"  2>>"$EV/escape.err"   # into ANOTHER agent's worktree
    python3 -c "open('$FLEET_TEST_OUTSIDE_PY','w').write('ESCAPED')" 2>>"$EV/escape.err"  # subprocess
    ok_json "did the work (and tried to escape)" ;;
  gitcommit)
    echo "worker output" > worker.txt
    git add -A >>"$EV/git.err" 2>&1 && git commit -qm "worker commit" >>"$EV/git.err" 2>&1 \
      && echo COMMIT_OK >> "$EV/git.err" || echo COMMIT_FAILED >> "$EV/git.err"
    ok_json "committed" ;;
  flaky529)
    # Gateway back-pressure: overloaded once, then fine.
    if [ "$N" -le 1 ]; then echo "API Error: 529 {\"type\":\"overloaded_error\"}" >&2; exit 1; fi
    ok_json "succeeded after back-pressure" ;;
  hardfail)
    # A genuine TASK failure — must NOT be retried.
    echo "the task is impossible; giving up" >&2; exit 1 ;;
  fixloop)
    # Self-heal: only gets it right on the second go.
    if [ "$N" -ge 2 ]; then echo fixed > fixed.txt; fi
    ok_json "attempted the fix" ;;
  neverfix)
    ok_json "did nothing useful" ;;
  *) ok_json "ok" ;;
esac
CLAUDE
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH
command -v claude | grep -q "^$TMP/bin/claude$" || fail "claude stub is not first on PATH"

# --- a repo with two agent worktrees --------------------------------------------------
git init -q -b main "$TMP/repo"
REPO="$TMP/repo"
cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .fleet
cp -R "$SRC/lib" "$SRC/bin" .fleet/
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
fleet_gate() { return 0; }
CFG
echo base > file.txt
git add -A; git commit -qm base
git worktree add -q -b agent/issue-900 .fleet/worktrees/agent/issue-900 main   # the worker's
git worktree add -q -b agent/issue-901 .fleet/worktrees/agent/issue-901 main   # a SIBLING agent's

WT="$REPO/.fleet/worktrees/agent/issue-900"
SIB="$REPO/.fleet/worktrees/agent/issue-901"

# Escape targets, all OUTSIDE the worker's worktree.
export FLEET_TEST_OUTSIDE="$REPO/OUTSIDE.txt"          # the primary checkout (`echo > ../../main/file`)
export FLEET_TEST_OUTSIDE_PY="$REPO/OUTSIDE-PY.txt"    # …same, via a python3 subprocess
export FLEET_TEST_SIBLING="$SIB/PWNED.txt"             # another agent's worktree

# The repo lives under $TMPDIR. If the sandbox profile's scratch allow were the last word, every
# assertion below would pass vacuously — so pin that this is genuinely the hazardous layout.
case "$REPO" in
  /private/var/*|/var/*|/tmp/*|/private/tmp/*) : ;;
  *) echo "  note: repo is at $REPO (not under a scratch dir) — the /tmp-overlap trap is not being exercised" ;;
esac

export FLEET_DELEGATE_BACKOFF_MS=1     # keep the retry test fast; the backoff maths is unchanged
D=".fleet/bin/fleet delegate"

# === 1. A SANDBOXED WORKER CANNOT WRITE OUTSIDE ITS WORKTREE ==========================
export FLEET_TEST_WORKER=escape
: > "$EV/calls"
out="$($D delegate agent/issue-900 "do the thing" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [escape] /'
[ "$rc" -eq 0 ] || fail "delegate exited $rc — the sandboxed worker should still have RUN (it just must not escape)"
[ -s "$EV/calls" ] || fail "the worker never ran — this test is not exercising anything"

[ -f "$FLEET_TEST_OUTSIDE" ] \
  && fail "ESCAPED (#23/RFC-2a): a Bash redirect wrote $FLEET_TEST_OUTSIDE, OUTSIDE the worktree — the OS sandbox is not binding subprocesses"
[ -f "$FLEET_TEST_OUTSIDE_PY" ] \
  && fail "ESCAPED (#23/RFC-2a): a python3 subprocess wrote $FLEET_TEST_OUTSIDE_PY, OUTSIDE the worktree — exactly what the Python write-guard cannot stop"
[ -f "$FLEET_TEST_SIBLING" ] \
  && fail "ESCAPED (#23/RFC-2a): the worker wrote into a SIBLING agent's worktree ($FLEET_TEST_SIBLING) — cross-agent contamination"
grep -q "Operation not permitted" "$EV/escape.err" 2>/dev/null \
  || fail "the escape attempts did not even hit an EPERM — the worker was probably not sandboxed at all"
echo "    ok: out-of-worktree redirect, python3 subprocess write and sibling-worktree write ALL blocked (EPERM)"

# === 2. …AND THE SANDBOX IS STILL USEFUL: git commit works inside the worktree ========
# (A sandbox that also breaks `git commit` from a linked worktree is one nobody will keep on.)
export FLEET_TEST_WORKER=gitcommit
before="$(git -C "$WT" rev-parse HEAD)"
out="$($D delegate agent/issue-900 "commit your work" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [gitcommit] /'
[ "$rc" -eq 0 ] || fail "delegate exited $rc on the git-commit worker"
grep -q COMMIT_OK "$EV/git.err" 2>/dev/null \
  || { sed 's/^/      /' "$EV/git.err" >&2; fail "the SANDBOXED worker could not \`git commit\` in its own worktree — the shared .git common dir is not writable, so this sandbox is useless"; }
after="$(git -C "$WT" rev-parse HEAD)"
[ "$before" != "$after" ] || fail "no new commit landed on agent/issue-900"
git -C "$WT" show --stat --oneline HEAD | head -1 | sed 's/^/    ok: commit landed: /'

# === 3. FAIL CLOSED — no sandbox, no worker ==========================================
# 3a. sandbox-exec missing.
: > "$EV/calls"
out="$(FLEET_DELEGATE_SANDBOX_EXEC=/nonexistent/sandbox-exec $D delegate agent/issue-900 "x" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [no-sandbox-exec] /'
[ "$rc" -ne 0 ] || fail "delegate exited 0 with the sandbox binary MISSING — it ran a --dangerously-skip-permissions worker unconfined (fail-open)"
[ -s "$EV/calls" ] && fail "the worker RAN even though the sandbox was unavailable — fail-open"
echo "$out" | grep -qi "refusing to run" || fail "the fail-closed death did not say why"

# 3b. a platform with no supported OS sandbox: `uname` stubbed to Linux.
cat > "$TMP/bin/uname" <<'UN'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] && { echo Linux; exit 0; }
exec /usr/bin/uname "$@"
UN
chmod +x "$TMP/bin/uname"
: > "$EV/calls"
out="$($D delegate agent/issue-900 "x" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [linux] /'
[ "$rc" -ne 0 ] || fail "delegate exited 0 on a platform with no OS sandbox — fail-open"
[ -s "$EV/calls" ] && fail "the worker RAN on a platform with no OS sandbox — fail-open"
echo "$out" | grep -q "sandboxing" || fail "the non-macOS death should point at Claude Code's native sandbox as the portable path"
rm -f "$TMP/bin/uname"

# 3c. The explicit, LOUD opt-out really is an opt-out — and, run against the same escape
#     worker as case 1, it proves the sandbox is what did the blocking there rather than some
#     accident of the test rig. (This is the mutation check, built into the suite.)
export FLEET_TEST_WORKER=escape
rm -f "$FLEET_TEST_OUTSIDE" "$FLEET_TEST_SIBLING" "$FLEET_TEST_OUTSIDE_PY"
out="$(FLEET_DELEGATE_SANDBOX=0 $D delegate agent/issue-900 "do the thing" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [sandbox=0] /'
echo "$out" | grep -q "UNCONFINED" || fail "FLEET_DELEGATE_SANDBOX=0 did not print a prominent warning"
[ -f "$FLEET_TEST_OUTSIDE" ] && [ -f "$FLEET_TEST_SIBLING" ] \
  || fail "with the sandbox OFF the escape did NOT happen — the escape worker is broken, so case 1 proves nothing"
echo "    ok: with FLEET_DELEGATE_SANDBOX=0 the very same worker DOES escape — case 1's blocks are the sandbox's doing"
rm -f "$FLEET_TEST_OUTSIDE" "$FLEET_TEST_SIBLING" "$FLEET_TEST_OUTSIDE_PY"
git -C "$REPO" checkout -q -- . 2>/dev/null || true

# === 4. BACK-PRESSURE: 429/529 is retried; a real task failure is NOT ==================
export FLEET_TEST_WORKER=flaky529
: > "$EV/calls"
out="$($D delegate agent/issue-900 "flaky" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [529] /'
[ "$rc" -eq 0 ] || fail "a 529 from the gateway killed the unit — there is no retry-with-backoff (RFC part 3)"
n="$(wc -l < "$EV/calls" | tr -d ' ')"
[ "$n" -ge 2 ] || fail "the worker was invoked $n time(s) — the 529 was not retried"
echo "$out" | grep -qi "back-pressure" || fail "the retry was silent — it must say it is backing off"
echo "    ok: 529 → backed off → retried → succeeded (worker invoked $n times)"

export FLEET_TEST_WORKER=hardfail
: > "$EV/calls"
out="$($D delegate agent/issue-900 "impossible" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [hardfail] /'
[ "$rc" -ne 0 ] || fail "a worker that genuinely failed the task reported success"
n="$(wc -l < "$EV/calls" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "a genuine task failure was RETRIED $n times — retries are only for transient transport errors"
echo "    ok: genuine task failure surfaced immediately, not retried"

# === 5. loop --until: self-heals via an IN-CONTEXT resume, or escalates ================
export FLEET_TEST_WORKER=fixloop
: > "$EV/calls"; : > "$EV/argv.log"; rm -f "$WT/fixed.txt"
out="$($D loop agent/issue-900 --until 'test -f fixed.txt' --max-iters 3 "make the check pass" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [loop-green] /'
[ "$rc" -eq 0 ] || fail "loop exited $rc even though the check went green"
echo "$out" | grep -q "check GREEN" || fail "loop did not report the check going green"
grep -q -- "--resume" "$EV/argv.log" \
  || fail "loop started a COLD session on iteration 2 — the failure must be fed back via --resume (in context)"
echo "    ok: loop self-healed and the retry resumed the SAME session (--resume seen in argv)"
rm -f "$WT/fixed.txt"; git -C "$WT" checkout -q -- . 2>/dev/null || true

export FLEET_TEST_WORKER=neverfix
: > "$EV/calls"
out="$($D loop agent/issue-900 --until 'test -f fixed.txt' --max-iters 2 "make the check pass" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [loop-red] /'
[ "$rc" -ne 0 ] || fail "loop exited 0 although the check NEVER went green — a red unit would be reported as done"
echo "$out" | grep -q "ESCALATE" || fail "loop exhausted its iterations without escalating"
n="$(wc -l < "$EV/calls" | tr -d ' ')"
[ "$n" -eq 2 ] || fail "loop ran the worker $n times with --max-iters 2 — the bound is not honoured"
echo "    ok: loop escalated with a non-zero exit after exactly 2 bounded iterations"

# === 6. THE TOKEN NEVER REACHES A COMMAND LINE OR A LOG ===============================
SECRET='SEKRET-sk-do-not-log-9f3a'
printf '%s' "$SECRET" > "$TMP/token"
chmod 644 "$TMP/token"                       # deliberately NOT 600 → expect a loud warning
export FLEET_WORKER_TOKEN_FILE="$TMP/token"
export FLEET_WORKER_BASE_URL="https://api.z.ai/api/anthropic"
export FLEET_WORKER_MODEL="glm-5.2"
export FLEET_TEST_WORKER=ok
: > "$EV/argv.log"; : > "$EV/env.log"
out="$($D delegate agent/issue-900 "secret handling" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [secret] /'
[ "$rc" -eq 0 ] || fail "delegate exited $rc with a token file configured"

echo "$out" | grep -q "$SECRET" && fail "THE TOKEN WAS PRINTED TO THE LOG"
grep -q "$SECRET" "$EV/argv.log" && fail "THE TOKEN WAS PASSED ON THE WORKER'S COMMAND LINE — it is visible in \`ps\` to every user on the box"
grep -q "AUTH=$SECRET" "$EV/env.log" \
  || fail "the token did not reach the worker via the ENVIRONMENT — provider config is broken"
grep -q "BASE=https://api.z.ai/api/anthropic" "$EV/env.log" \
  || fail "FLEET_WORKER_BASE_URL was not mapped onto the child's ANTHROPIC_BASE_URL"
grep -q "SONNET=glm-5.2" "$EV/env.log" && grep -q "OPUS=glm-5.2" "$EV/env.log" \
  || fail "FLEET_WORKER_MODEL must pin EVERY tier — the child has ONE endpoint, so a Sonnet-tier subagent would otherwise be dispatched to a model this gateway does not serve"
echo "$out" | grep -qi "mode 644" || fail "a world-readable token file did not raise a warning"
echo "    ok: token delivered by env only (never argv, never logged); every model tier pinned; non-600 token file warned about"

# === 7. --bare is refused (RFC 2d) ====================================================
out="$(FLEET_DELEGATE_CLAUDE_ARGS='--bare' $D delegate agent/issue-900 "x" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "--bare was accepted — it disables EVERY hook and is slated to become the -p default"
echo "$out" | grep -q -- "--bare" || fail "the --bare refusal did not name the flag"
grep -q -- "--bare" "$EV/argv.log" && fail "--bare was actually forwarded to the worker"
echo "    ok: --bare refused, never forwarded"

echo "PASS: sandboxed worker cannot write outside its worktree (redirect, python3 subprocess, sibling worktree — all EPERM) yet CAN git commit inside it; delegate fails CLOSED when the sandbox is unavailable and only escapes with the loud explicit opt-out; 529 retried with backoff while a genuine task failure is not; loop --until self-heals via an in-context --resume and escalates non-zero when it cannot; the bearer token never touches argv or a log; --bare refused"
