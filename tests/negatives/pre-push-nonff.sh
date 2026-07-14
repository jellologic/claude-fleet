#!/usr/bin/env sh
# NEGATIVE: pre-push must block a non-ff push to a PROTECTED ref, and ALLOW one to a
# CAS-owned agent branch (#41).
#
# The non-ff rule exists to stop one agent clobbering another. It must not apply to a
# claimed agent branch, because the branch-ref CAS gives it exactly one owner — so a
# rebase-force-push there is a rewrite of your OWN history, not a clobber of someone
# else's. Blocking it made fleet forbid its own documented workflow (CLAUDE.md:
# "git rebase origin/main && git push"), and the only escapes were the other rails:
# --no-verify (coord-guard denies it), core.hooksPath tampering (#30), or deleting the
# branch — which releases the CAS lock.
#
# Both directions are asserted. Deleting the exemption must break the agent case; deleting
# the protected-branch block must break the main case. Neither may pass vacuously.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$HERE/../.." && pwd)/src/fleet/githooks/pre-push"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Drive the hook exactly as git does: one "<lref> <lsha> <rref> <rsha>" line on stdin.
# A non-ff push is any <rsha> that is NOT an ancestor of <lsha>.
zero='0000000000000000000000000000000000000000'
git init -q -b main "$TMP/r"
cd "$TMP/r"
git config user.email t@t; git config user.name t
echo a > f; git add -A; git commit -qm a
A="$(git rev-parse HEAD)"
# A sibling commit: not an ancestor of A, so pushing A over B is non-fast-forward.
git checkout -q --detach
echo b > f; git commit -qam b
B="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$B" "$A" 2>/dev/null \
  && fail "precondition broken: B IS an ancestor of A, so this is not a non-ff push at all"
echo "    precondition ok: pushing $(echo "$A" | cut -c1-7) over $(echo "$B" | cut -c1-7) IS non-fast-forward"

# NOTE: `set -e` would kill this script the moment the hook legitimately exits non-zero
# (which is most of what we are testing), so every invocation must swallow the status and
# hand it back explicitly.
try() {  # $1 = remote ref → prints the hook's exit code
  rc=0
  printf 'refs/heads/x %s %s %s\n' "$A" "$1" "$B" | sh "$HOOK" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
try_ff() {  # $1 = remote ref, new branch (rsha = 0) → prints the hook's exit code
  rc=0
  printf 'refs/heads/x %s %s %s\n' "$A" "$1" "$zero" | sh "$HOOK" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# --- 1. Protected refs: non-ff MUST still be blocked (no regression) -----------------
for ref in refs/heads/main refs/heads/master refs/heads/release/1.0; do
  rc="$(try "$ref")"
  [ "$rc" -ne 0 ] || fail "non-ff push to $ref was ALLOWED — the protected-branch block is gone"
done
echo "    ok: non-ff push to main/master/release/* still BLOCKED"

# --- 2. CAS-owned agent branches: non-ff MUST be allowed (the #41 fix) ---------------
# These are the branches agent-claim.sh mints; the remote ref IS the exclusive lock.
for ref in refs/heads/agent/issue-37 refs/heads/agent/issue-1 refs/heads/worktree/foo refs/heads/fix/bar; do
  rc="$(try "$ref")"
  [ "$rc" -eq 0 ] || fail "non-ff push to $ref was BLOCKED (exit $rc) — fleet's own rebase/stack workflow is unpushable, and the only escapes are --no-verify or releasing the CAS lock (#41)"
done
echo "    ok: non-ff push to a CAS-owned agent branch is ALLOWED (rebase, not clobber)"

# --- 3. Everything else keeps the old non-ff protection (do not over-exempt) ---------
for ref in refs/heads/random-branch refs/heads/experimental; do
  rc="$(try "$ref")"
  [ "$rc" -ne 0 ] || fail "non-ff push to $ref was ALLOWED — the exemption is too broad; only CAS-owned namespaces may skip the non-ff rule"
done
echo "    ok: non-ff push to a NON-CAS branch is still BLOCKED (exemption is not a blanket)"

# --- 4. A fast-forward push is always fine, everywhere it is not protected -----------
rc="$(try_ff refs/heads/agent/issue-37)"
[ "$rc" -eq 0 ] || fail "a NEW-branch push (rsha=0) to an agent branch was blocked"
echo "    ok: new-branch / fast-forward pushes unaffected"

# --- 5. Direct push to main is blocked even when it IS a fast-forward ----------------
rc="$(try_ff refs/heads/main)"
[ "$rc" -ne 0 ] || fail "a fast-forward push to main was ALLOWED — protected refs must be blocked unconditionally"
echo "    ok: main is blocked even on a fast-forward"

echo "PASS: protected refs stay absolutely blocked; CAS-owned agent branches may be force-pushed (rebase/stack); non-CAS branches keep the old non-ff rule"
