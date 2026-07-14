#!/usr/bin/env bash
# NEGATIVE: the claim commit must be UNIQUE per host, so the remote push is a real
# compare-and-swap and the LOSER of a race is actually rejected.
#
# Regression for #19. `agent-claim.sh` locks an issue with a branch ref: it makes an
# empty claim commit and pushes it, relying on the push to fail for the second host.
# Pre-fix the claim commit carried ZERO entropy, and a git commit SHA is just sha1 over
# tree+parent+author+committer+message:
#   tree       — `--allow-empty` off $FLEET_MAIN → identical to main's tree on both hosts
#   parent     — local main tip; both hosts just fetched, so routinely the same sha
#   message    — "chore(agent): claim #N — <title>"; the title comes from `gh issue view`
#   ident      — commonly one identity across a fleet (shared dotfiles / a CI bot)
#   timestamp  — `now` at SECOND resolution; two agents racing a freshly-labelled issue
#                land in the same second regularly
# All equal → the two hosts build the BYTE-IDENTICAL commit object. The loser's push of
# that same sha to that same ref is then not a non-fast-forward at all — it is a NO-OP.
# Git prints "Everything up-to-date" and exits 0, the `if !` never fires, and BOTH hosts
# win the lock: both label the issue agent-working, both ledger_add, both print CLAIMED.
# Two agents then work the same issue on the same branch and one force-pushes the other away.
#
# This test needs neither two machines nor GitHub: a bare repo plays "origin", two clones
# play the hosts, they share one identity, and GIT_*_DATE is PINNED to the same value on
# both sides so the same-second collision is forced deterministically instead of hoped for.
#
# The commands under test are EXTRACTED FROM THE SOURCE rather than retyped, so reverting
# the fix necessarily fails this test (that is the whole point of a mutation-checked test).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLAIM_SH="$ROOT/src/fleet/bin/agent-claim.sh"
LIB="$ROOT/src/fleet/lib/agent-coord-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$CLAIM_SH" ] || fail "cannot find $CLAIM_SH"

# --- Pull the real claim-commit and push commands out of agent-claim.sh -------------
# CLAIM_ID_CMD is absent pre-fix (no nonce line at all) — that is exactly the state we
# want to reproduce when this test is run against the buggy code.
CLAIM_ID_CMD="$(grep -E '^CLAIM_ID=' "$CLAIM_SH" || true)"
COMMIT_CMD="$(grep -F 'commit --allow-empty' "$CLAIM_SH" | head -1)"
# The push lives inside `if ! … >"$LOG" 2>&1; then`; strip the wrapper, keep the git call.
# (`push origin --delete` in rollback_claim is not the claim push — exclude it.)
PUSH_CMD="$(grep -F 'push' "$CLAIM_SH" | grep -F 'origin' | grep -Fv -- '--delete' | head -1 \
  | sed -e 's/^[[:space:]]*if[[:space:]]*![[:space:]]*//' -e 's/>"\$LOG"[[:space:]]*2>&1;[[:space:]]*then[[:space:]]*$//')"
[ -n "$COMMIT_CMD" ] || fail "could not extract the claim-commit command from agent-claim.sh"
[ -n "$PUSH_CMD" ]   || fail "could not extract the claim push command from agent-claim.sh"
echo "    [extracted] commit: $COMMIT_CMD"
echo "    [extracted] push  : $PUSH_CMD"

# --- Build "origin" + two hosts ------------------------------------------------------
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/seed"
git -C "$TMP/seed" config user.email fleet@example.com
git -C "$TMP/seed" config user.name  "Fleet Bot"
echo base > "$TMP/seed/file.txt"
git -C "$TMP/seed" add -A
git -C "$TMP/seed" commit -qm base
git -C "$TMP/seed" remote add origin "$TMP/origin.git"
git -C "$TMP/seed" push -q origin main

git clone -q "$TMP/origin.git" "$TMP/hostA"
git clone -q "$TMP/origin.git" "$TMP/hostB"
for h in hostA hostB; do
  # The realistic fleet case: ONE identity shared across every host.
  git -C "$TMP/$h" config user.email fleet@example.com
  git -C "$TMP/$h" config user.name  "Fleet Bot"
done

# Force the same-second race deterministically. Note this also pins hostname/$$ to be
# identical for both "hosts" (same machine, same test process) — so the ONLY thing that
# can separate the two claim commits is the random nonce itself.
export GIT_AUTHOR_DATE="2026-07-14T12:00:00+0000"
export GIT_COMMITTER_DATE="2026-07-14T12:00:00+0000"

# _fleet_id lives in the shared lib; agent-claim.sh calls it, so we must too.
# shellcheck source=/dev/null
( cd "$TMP/hostA" && . "$LIB" && type _fleet_id ) >/dev/null 2>&1 || fail "_fleet_id not found in $LIB"
cd "$TMP/hostA"
# shellcheck source=/dev/null
. "$LIB"

ISSUE=42
TITLE="claim lock is not a compare-and-swap"
BRANCH="agent/issue-$ISSUE"

reset_origin() {  # drop the claim ref and rewind both hosts to a fresh branch off main
  git -C "$TMP/origin.git" update-ref -d "refs/heads/$BRANCH" 2>/dev/null || true
  for h in hostA hostB; do
    git -C "$TMP/$h" checkout -q main
    git -C "$TMP/$h" branch -qD "$BRANCH" 2>/dev/null || true
    git -C "$TMP/$h" checkout -q -b "$BRANCH" main
    git -C "$TMP/$h" fetch -q --prune origin
  done
}

# =====================================================================================
# PRECONDITION — reproduce the pre-fix behaviour with the OLD (nonce-free) claim commit.
# If this does not hold, #19 was never real and the post-fix assertions prove nothing.
# =====================================================================================
reset_origin
for h in hostA hostB; do
  WT="$TMP/$h"
  git -C "$WT" commit --allow-empty -q -m "chore(agent): claim #$ISSUE — $TITLE"
done
OLD_A="$(git -C "$TMP/hostA" rev-parse HEAD)"
OLD_B="$(git -C "$TMP/hostB" rev-parse HEAD)"
echo "    [pre-fix] hostA claim sha: $OLD_A"
echo "    [pre-fix] hostB claim sha: $OLD_B"
[ "$OLD_A" = "$OLD_B" ] || fail "pre-fix claim commits differ — the same-second race is not being reproduced, so this test cannot prove #19 is fixed"

git -C "$TMP/hostA" push -u origin "$BRANCH" >/dev/null 2>&1 || fail "hostA could not take the (empty) lock"
out_b="$(git -C "$TMP/hostB" push -u origin "$BRANCH" 2>&1)"; rc_b=$?
echo "$out_b" | sed 's/^/    | /'
[ "$rc_b" -eq 0 ] || fail "pre-fix hostB push was rejected — the collision is not being reproduced"
echo "$out_b" | grep -qi "up-to-date" || fail "pre-fix hostB push did not no-op — the collision is not being reproduced"
echo "    [pre-fix] CONFIRMED: identical sha → hostB's push is a NO-OP (exit 0) → BOTH hosts win the lock (#19)"

# =====================================================================================
# THE ACTUAL ASSERTION — the SAME race, run through the CURRENT agent-claim.sh commands.
# =====================================================================================
reset_origin
for h in hostA hostB; do
  WT="$TMP/$h"
  # shellcheck disable=SC2034  # $WT/$ISSUE/$TITLE are consumed by the extracted commands
  eval "$CLAIM_ID_CMD"
  eval "$COMMIT_CMD" || fail "the extracted claim-commit command failed on $h"
done
NEW_A="$(git -C "$TMP/hostA" rev-parse HEAD)"
NEW_B="$(git -C "$TMP/hostB" rev-parse HEAD)"
echo "    [post-fix] hostA claim sha: $NEW_A"
echo "    [post-fix] hostB claim sha: $NEW_B"

# 1. The commit objects must differ. Same tree, same parent, same ident, same pinned
#    timestamp, same hostname, same pid — only a per-claim nonce can separate them.
[ "$NEW_A" != "$NEW_B" ] || fail "the two hosts STILL build an identical claim commit ($NEW_A) — the claim commit has no entropy, so the push cannot be a compare-and-swap (#19)"

# 2. The winner takes the ref.
WT="$TMP/hostA"
eval "$PUSH_CMD" >/dev/null 2>&1 || fail "hostA (the winner) could not create the claim ref — the CAS over-fires and NOBODY can claim"

# 3. The loser MUST be rejected. hostB has not fetched the new ref — exactly the race.
WT="$TMP/hostB"
out_b="$(eval "$PUSH_CMD" 2>&1)"; rc_b=$?
echo "$out_b" | sed 's/^/    | /'
[ "$rc_b" -ne 0 ] || fail "hostB's push exited 0 — the loser of the race also won the lock (#19): two agents will now work issue #$ISSUE on branch $BRANCH"
echo "$out_b" | grep -qi "up-to-date" && fail "hostB's push no-opped instead of being rejected — the claim commits still collide (#19)"

# 4. And origin must still point at the WINNER, not the loser.
REMOTE="$(git -C "$TMP/origin.git" rev-parse "refs/heads/$BRANCH")"
[ "$REMOTE" = "$NEW_A" ] || fail "origin/$BRANCH is at $REMOTE, not hostA's claim $NEW_A — the loser overwrote the winner's lock"

echo "PASS: forced same-second race → distinct claim commits ($NEW_A vs $NEW_B), loser's push REJECTED (exit $rc_b; pre-fix it exited 0), origin holds the winner's claim"
