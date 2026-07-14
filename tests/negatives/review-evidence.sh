#!/usr/bin/env bash
# NEGATIVE: `fleet delegate review` must produce EVIDENCE, not verdicts — and must never be a gate.
#
# Regression for #36. Bun ran exactly this loop over a 535k-line Zig→Rust port: "1 implementer,
# 2 or more adversarial reviewers per implementer", each reviewer getting "the diff and nothing
# else — none of the implementer's reasoning". But review was NEVER their correctness gate: that
# was `cargo check` plus a suite with 1,386,826 assertions. The LLM-as-judge literature says why
# it must not be — judge-vs-oracle agreement is weak (kappa 0.21/0.10), and ten reviewers once
# unanimously endorsed an OpenSSL padding oracle that did not exist, killed by ONE instance that
# actually compiled the code and ran three tests. The one intervention with a measured ~3x
# improvement is the FIX-GUIDED VERIFICATION FILTER: make every finding ship a runnable artifact
# and let the REAL test suite adjudicate original-vs-patched.
#
# So the properties under test are exactly the ones that are easy to get wrong and impossible to
# notice when you do:
#   1. A finding with NO executable artifact is DISCARDED, never escalated. ("Vague logic error
#      with no falsifiable counterexample" is precisely what LLM reviewers over-produce.)
#   2. A `repro` that PASSES on HEAD is DISCARDED as REFUTED — it does not reproduce anything.
#   3. A `patch` that does not apply is DISCARDED.
#   4. A `patch` that leaves `fleet_gate`'s outcome UNCHANGED is DISCARDED (the fix-guided filter).
#   5. A `repro` that genuinely FAILS on HEAD IS reported as SUBSTANTIATED (so 1–4 are a filter,
#      not a shredder), and so is a patch that flips the REAL gate RED → GREEN.
#   6. `review` EXITS 0 EVEN WITH SUBSTANTIATED FINDINGS. It must not block a merge. This is the
#      single most important behavioural property in the file: the moment an LLM reviewer becomes
#      a merge gate, fleet has swapped a real oracle for a bad one.
#   7. Reviewers are READ-ONLY: writes into the reviewed worktree are EPERM, and the worktree is
#      byte-for-byte unchanged (same `git status --porcelain`, same HEAD) after a review run.
#   8. CONTEXT ASYMMETRY: the implementer's session id / transcript NEVER reaches a reviewer —
#      no `--resume`, and the sid appears nowhere in the reviewer's argv or prompt.
#   9. N defaults to 2 (Bun's number).
#
# `claude` is stubbed on PATH, so this test needs no model and no network. The stub emits five
# canned findings covering every branch of the filter.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) : ;;
  *) echo "SKIP: review confinement is sandbox-exec (macOS) only; on this platform fleet delegate refuses to run at all"; exit 0 ;;
esac

EV="$TMP/evidence"; mkdir -p "$EV"       # outside the repo → writable from inside the sandbox
export FLEET_TEST_EVIDENCE="$EV"

# --- the fake adversarial reviewer ----------------------------------------------------
# Stands in for `claude -p --output-format json`. Records its argv (so the suite can prove the
# implementer's session id never reached it), TRIES TO WRITE INTO THE WORKTREE IT IS REVIEWING
# (it must get EPERM), then drops five canned findings into its scratch dir — one per branch of
# the evidence filter.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
EV="${FLEET_TEST_EVIDENCE:?}"
printf '%s\n' "$*" >> "$EV/argv.log"
echo x >> "$EV/calls"

sid="sess-abc123"
ok_json() { printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"%s","total_cost_usd":0.0042,"num_turns":2,"duration_ms":900}\n' "$sid" "$1"; }

case "${FLEET_TEST_WORKER:-ok}" in
  reviewer)
    S="${FLEET_REVIEW_SCRATCH:?the reviewer was never told where to put its findings}"

    # --- a reviewer must not be able to touch the code it is judging ------------------
    echo PWNED > ./REVIEWER-PWNED.txt                      2>>"$EV/review-escape.err"
    python3 -c "open('REVIEWER-PWNED-PY.txt','w').write('x')" 2>>"$EV/review-escape.err"
    git commit -q --allow-empty -m "reviewer commit"       2>>"$EV/review-escape.err"

    # --- the five canned findings -----------------------------------------------------
    # A patch that FIXES the (real) syntax error the diff introduced: fleet_gate RED → GREEN.
    cat > "$S/fix.diff" <<'PATCH'
--- a/src/broken.sh
+++ b/src/broken.sh
@@ -1,3 +1,3 @@
 #!/usr/bin/env bash
-if then
-fi
+if true; then :
+fi
PATCH
    # A patch that APPLIES cleanly but the real gate cannot see: fleet_gate stays RED.
    cat > "$S/noop.diff" <<'PATCH'
--- a/src/ok.sh
+++ b/src/ok.sh
@@ -1,2 +1,3 @@
 #!/usr/bin/env bash
+# a cosmetic comment the oracle cannot see
 echo ok
PATCH
    # A patch against a file that does not exist: `git apply --check` rejects it.
    cat > "$S/bogus.diff" <<'PATCH'
--- a/src/nonexistent.sh
+++ b/src/nonexistent.sh
@@ -1,1 +1,1 @@
-foo
+bar
PATCH
    python3 - "$S" <<'PY'
import json, os, sys
S = sys.argv[1]
FD = os.path.join(S, 'findings')
os.makedirs(FD, exist_ok=True)
def w(name, obj):
    with open(os.path.join(FD, name), 'w') as fh:
        json.dump(obj, fh)
def rd(name):
    with open(os.path.join(S, name)) as fh:
        return fh.read()

# 1. REAL: a repro that genuinely FAILS on HEAD.
w('1.json', {"title": "src/broken.sh does not parse",
             "explanation": "the diff introduces a shell script with a syntax error",
             "repro": "bash -n src/broken.sh"})
# 2. REFUTED: a repro that PASSES on HEAD — the claimed bug does not reproduce.
w('2.json', {"title": "file.txt was deleted by this diff",
             "explanation": "I am confident the file is gone",
             "repro": "test -f file.txt"})
# 3. NO ARTIFACT: the classic unfalsifiable LLM finding.
w('3.json', {"title": "possible race condition somewhere in the changed code",
             "explanation": "this looks like it could be wrong under concurrency"})
# 4. UNAPPLIABLE PATCH.
w('4.json', {"title": "off-by-one in src/nonexistent.sh",
             "explanation": "the bound is wrong", "patch": rd('bogus.diff')})
# 5. UNSUBSTANTIATED PATCH: applies, but leaves fleet_gate's outcome unchanged.
w('5.json', {"title": "missing comment makes src/ok.sh unmaintainable",
             "explanation": "the code is unclear", "patch": rd('noop.diff')})
# 6. REAL: a patch that flips the REAL gate RED -> GREEN.
w('6.json', {"title": "src/broken.sh syntax error breaks the build",
             "explanation": "`if then` is not valid bash", "patch": rd('fix.diff')})
PY
    ok_json "reviewed the diff and filed 6 findings" ;;
  silent)
    ok_json "found nothing" ;;
  *) ok_json "ok" ;;
esac
CLAUDE
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH
command -v claude | grep -q "^$TMP/bin/claude$" || fail "claude stub is not first on PATH"

# --- a repo whose gate is a REAL oracle -----------------------------------------------
# fleet_gate here actually parses the shell under src/ — so a patch can flip it, and the
# fix-guided verification filter has something to adjudicate against. A stub gate that always
# returns 0 would make assertion 4 pass vacuously.
git init -q -b main "$TMP/repo"
REPO="$TMP/repo"
cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .fleet src
cp -R "$SRC/lib" "$SRC/bin" .fleet/
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
fleet_pkg_for() { echo ""; }
fleet_gate() {
  rc=0
  for f in $(git ls-files src 2>/dev/null); do
    case "$f" in
      *.sh) bash -n "$f" 2>/dev/null || { echo "  shell syntax error: $f" >&2; rc=1; } ;;
    esac
  done
  [ "$rc" = 0 ] && echo "  gate: shell OK"
  return $rc
}
CFG
printf '%s\n' 'base' > file.txt
printf '%s\n' '#!/usr/bin/env bash' 'echo ok' > src/ok.sh
git add -A; git commit -qm base

git worktree add -q -b agent/issue-900 .fleet/worktrees/agent/issue-900 main   # the implementer's
git worktree add -q -b agent/issue-901 .fleet/worktrees/agent/issue-901 main   # nothing to review
WT="$REPO/.fleet/worktrees/agent/issue-900"
CLEAN="$REPO/.fleet/worktrees/agent/issue-901"

# THE DIFF UNDER REVIEW: the implementer added a shell script that does not parse. The REAL gate
# is RED on this HEAD — which is exactly what makes the fix-guided filter meaningful.
printf '%s\n' '#!/usr/bin/env bash' 'if then' 'fi' > "$WT/src/broken.sh"
git -C "$WT" add -A; git -C "$WT" commit -qm "add src/broken.sh"

( cd "$WT" && . "$REPO/.fleet/config.sh" && fleet_gate ) >/dev/null 2>&1 \
  && fail "the test repo's fleet_gate is GREEN on the reviewed HEAD — the RED→GREEN patch case would prove nothing"

export FLEET_DELEGATE_BACKOFF_MS=1
D=".fleet/bin/fleet delegate"

# === 0. Give the IMPLEMENTER a session, so we can prove it never leaks to a reviewer ===
export FLEET_TEST_WORKER=ok
: > "$EV/argv.log"
out="$($D delegate agent/issue-900 "implement the thing" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "the setup delegate run failed (exit $rc): $out"
SID="$(cat "$REPO/.fleet/delegate/agent-issue-900/session" 2>/dev/null)"
[ -n "$SID" ] || fail "no implementer session was recorded — assertion 8 would prove nothing"
echo "    setup: implementer session $SID recorded"

# === 1. THE REVIEW RUN =================================================================
export FLEET_TEST_WORKER=reviewer
: > "$EV/calls"; : > "$EV/argv.log"; : > "$EV/review-escape.err"
BEFORE_STATUS="$(git -C "$WT" status --porcelain)"
BEFORE_HEAD="$(git -C "$WT" rev-parse HEAD)"

out="$($D review agent/issue-900 --reviewers 1 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [review] /'

[ -s "$EV/calls" ] || fail "no reviewer ever ran — this test is not exercising anything"

# --- 6. REVIEW NEVER BLOCKS (the load-bearing property) -------------------------------
[ "$rc" -eq 0 ] \
  || fail "review exited $rc — it MUST exit 0 whenever it RAN. A non-zero exit on findings turns an LLM reviewer into a merge gate, which is exactly what Bun did NOT do (their gate was cargo + 1.39M assertions) and exactly what the judge-vs-oracle literature says you must not do."
echo "$out" | grep -qE "^SUBSTANTIATED \([1-9]" \
  || fail "review reported ZERO substantiated findings — the exit-0 assertion above would then be vacuous (it must exit 0 *while carrying real findings*)"
echo "    ok: review exited 0 WITH substantiated findings — it reports, it does not block"
echo "$out" | grep -qi "does NOT block" \
  || fail "the report never says out loud that review is advisory and fleet_gate is the gate"

# --- 5. GENUINE EVIDENCE SURVIVES -----------------------------------------------------
sub="$(echo "$out" | sed -n '/^SUBSTANTIATED/,/^DISCARDED/p')"
echo "$sub" | grep -q "src/broken.sh does not parse" \
  || fail "a repro that genuinely FAILS on HEAD (\`bash -n src/broken.sh\`) was NOT substantiated — the filter is a shredder, not a filter"
echo "$sub" | grep -q "repro FAILS on HEAD" \
  || fail "the substantiated repro finding does not carry its executed evidence"
echo "$sub" | grep -q "syntax error breaks the build" \
  || fail "a patch that flips the REAL fleet_gate RED→GREEN was NOT substantiated"
echo "$sub" | grep -q "flips fleet_gate RED" \
  || fail "the substantiated patch finding does not say that the REAL gate adjudicated it"
echo "    ok: the repro that fails on HEAD, and the patch that flips fleet_gate RED→GREEN, BOTH survive"

# --- 1..4. EVERY UNFALSIFIABLE / REFUTED / BROKEN FINDING IS DISCARDED -----------------
disc="$(echo "$out" | sed -n '/^DISCARDED/,$p')"

echo "$sub" | grep -qi "race condition" \
  && fail "a finding with NO EXECUTABLE ARTIFACT was reported as SUBSTANTIATED — the evidence filter is not running"
echo "$disc" | grep -qi "NO EXECUTABLE ARTIFACT" \
  || fail "the artifact-less finding was not discarded with a reason (\"vague logic error with no falsifiable counterexample\" is the exact class this filter exists to delete)"
echo "    ok: a finding with no repro and no patch is DISCARDED, never escalated"

echo "$sub" | grep -qi "file.txt was deleted" \
  && fail "a repro that PASSES on HEAD was reported as SUBSTANTIATED — a bug that does not reproduce is not a bug"
echo "$disc" | grep -qi "REFUTED" \
  || fail "a repro that PASSES on HEAD was not discarded as REFUTED"
echo "    ok: a repro that PASSES on HEAD is DISCARDED as refuted"

echo "$sub" | grep -qi "src/nonexistent.sh" \
  && fail "a finding whose patch does not even apply was reported as SUBSTANTIATED"
echo "$disc" | grep -qi "patch does not apply" \
  || fail "the unappliable patch was not discarded with a reason"
echo "    ok: a patch that does not apply is DISCARDED"

echo "$sub" | grep -qi "unmaintainable" \
  && fail "a patch that leaves fleet_gate's outcome UNCHANGED was reported as SUBSTANTIATED — the fix-guided verification filter is not running"
echo "$disc" | grep -qi "fleet_gate outcome UNCHANGED" \
  || fail "the gate-invisible patch was not discarded by the fix-guided verification filter"
echo "    ok: a patch the REAL gate cannot see is DISCARDED (fix-guided verification filter)"

# …and the arithmetic: exactly the two artifact-bearing, gate-verified findings survive.
echo "$out" | grep -q "SUBSTANTIATED (2 of 6)" \
  || fail "expected exactly 2 of 6 findings to survive adjudication; got: $(echo "$out" | grep -i 'SUBSTANTIATED (' || echo '<no substantiated line>')"
echo "$out" | grep -q "DISCARDED (4 of 6)" \
  || fail "expected exactly 4 of 6 findings discarded; got: $(echo "$out" | grep -i '^DISCARDED (' || echo '<no discarded line>')"

# --- 7. THE REVIEWER IS READ-ONLY -----------------------------------------------------
[ -f "$WT/REVIEWER-PWNED.txt" ] \
  && fail "ESCAPED: a reviewer WROTE INTO THE WORKTREE IT IS REVIEWING ($WT/REVIEWER-PWNED.txt) — it is not read-only, so it can 'fix' the code it is meant to be an independent observer of"
[ -f "$WT/REVIEWER-PWNED-PY.txt" ] \
  && fail "ESCAPED: a python3 subprocess of the reviewer wrote into the reviewed worktree — exactly what the Python write-guard cannot stop"
grep -q "Operation not permitted" "$EV/review-escape.err" 2>/dev/null \
  || { sed 's/^/      /' "$EV/review-escape.err" >&2; fail "the reviewer's write attempts did not even hit an EPERM — it was probably not sandboxed read-only at all"; }
[ "$(git -C "$WT" status --porcelain)" = "$BEFORE_STATUS" ] \
  || { git -C "$WT" status --porcelain >&2; fail "the reviewed worktree's \`git status --porcelain\` CHANGED across a review run"; }
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE_HEAD" ] \
  || fail "the reviewed worktree's HEAD MOVED across a review run — a reviewer committed"
echo "    ok: reviewer writes to the worktree AND the shared .git are EPERM; worktree byte-for-byte unchanged (same porcelain, same HEAD)"

# --- 8. CONTEXT ASYMMETRY: the implementer's session never reaches a reviewer ----------
grep -q -- "--resume" "$EV/argv.log" \
  && fail "the reviewer was --resume'd into the IMPLEMENTER's session — it now sees the implementer's reasoning, which destroys the adversarial asymmetry the whole design rests on"
grep -q "$SID" "$EV/argv.log" \
  && fail "the implementer's session id ($SID) appears in the reviewer's argv/prompt — the reviewer must get the diff and NOTHING ELSE"
grep -q "diff.patch" "$EV/argv.log" \
  || fail "the reviewer was never handed the diff"
grep -qi "FIND THE WAY THIS DIFF IS WRONG" "$EV/argv.log" \
  || fail "the reviewer's prompt is not refute-framed"
echo "    ok: no --resume, no session id, no transcript — just the diff, and a refute-framed brief"

# === 9. N DEFAULTS TO 2 (Bun's number) ================================================
: > "$EV/calls"
out="$($D review agent/issue-900 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "the default review run exited $rc"
n="$(wc -l < "$EV/calls" | tr -d ' ')"
[ "$n" -eq 2 ] || fail "default --reviewers is $n, not 2 (Bun ran 2 adversarial reviewers per implementer)"
echo "    ok: N defaults to 2"

# === 10. NOTHING TO REVIEW → exit 0, no reviewer spawned ==============================
: > "$EV/calls"
out="$($D review agent/issue-901 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [empty] /'
[ "$rc" -eq 0 ] || fail "review of an empty diff exited $rc — nothing to review is not a failure"
echo "$out" | grep -qi "nothing to review" || fail "an empty diff did not say so"
[ -s "$EV/calls" ] && fail "a reviewer was spawned for an EMPTY diff — that is a model call for nothing"
echo "    ok: an empty diff exits 0 without spawning a reviewer"

# === 11. FAIL CLOSED — no sandbox, no reviewer ========================================
: > "$EV/calls"
out="$(FLEET_DELEGATE_SANDBOX_EXEC=/nonexistent/sandbox-exec $D review agent/issue-900 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "review exited 0 with the sandbox binary MISSING — it ran a --dangerously-skip-permissions reviewer unconfined (fail-open). Infrastructure failure is the ONE thing review may exit non-zero on."
[ -s "$EV/calls" ] && fail "a reviewer RAN even though the sandbox was unavailable — fail-open"
echo "    ok: no sandbox → no reviewer, and THAT is what a non-zero review exit means"

echo "PASS: reviewers emit EVIDENCE and the real gate returns the VERDICTS — an artifact-less finding, a repro that passes on HEAD, a patch that does not apply, and a patch fleet_gate cannot see are all DISCARDED, while a repro that genuinely fails on HEAD and a patch that flips the gate RED→GREEN survive; review EXITS 0 with substantiated findings (it never blocks a merge); reviewers are READ-ONLY (worktree + shared .git EPERM, worktree byte-for-byte unchanged); the implementer's session/transcript never reaches a reviewer; N defaults to 2; an empty diff spawns nobody; and review fails CLOSED when the sandbox is unavailable"
