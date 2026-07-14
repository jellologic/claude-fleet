#!/usr/bin/env bash
# NEGATIVE: the coord mutex must never let two holders into the critical section, and a
# holder whose lock WAS broken must never unlock its successor.
#
# Regression for #20. Pre-fix, `_coord_lock` decided staleness purely from the lock dir's
# mtime (set once, at mkdir, never refreshed) and `_coord_unlock` was an unconditional
# `rmdir` of the shared path. Two interleavings follow from that:
#
#   1. LOCK STEALING + CROSS-UNLOCK. A holds the lock and is merely SLOW (a cold
#      `git worktree add`, a big JSON rewrite, swap, SIGSTOP) — past the stale window it
#      is indistinguishable from dead, so B breaks A's LIVE lock and enters. Both are now
#      read-modify-writing .claude/agent-claims.json and a claim is silently lost. Then A
#      finishes and its `rmdir` deletes *B's* lock; C acquires while B still holds. From
#      then on every unlock frees a stranger's lock — the mutex is permanently degraded.
#
#   2. TWO-WAITER BREAK RACE. A's lock is genuinely stale. B and C both stat it and both
#      see it stale. B rmdir's + re-mkdir's, acquiring a fresh lock. C — still acting on
#      its PRE-BREAK snapshot — rmdir's B's brand-new 0-second-old lock and acquires too.
#      Both hold. That defeats even the crashed-holder recovery the stale rule exists for.
#
# The fix: an `owner` token file (host:pid:nonce) inside the lock dir; ownership-CHECKED
# unlock; a `kill -0` liveness check before breaking; and an atomic, serialized break.
#
# Every simulated agent is a REAL separate process, because the owner token is
# (host, pid, nonce) — subshells share `$$`, so only real processes prove anything.
# FLEET_LOCK_STALE_SECS shrinks the 60s stale window so this need not sleep a minute.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
await() { local f="$1" n=0; while [ ! -e "$f" ]; do n=$((n+1)); [ "$n" -gt 200 ] && return 1; sleep 0.05; done; }

# A real repo: repo_root() is git-derived, and so is the lock path.
git init -q -b main "$TMP/repo" >/dev/null
cd "$TMP/repo"
git config user.email t@t; git config user.name t
mkdir -p .fleet
cp -R "$SRC/lib" .fleet/
: > .fleet/config.sh
echo base > file.txt
git add -A; git commit -qm base

LIB="$TMP/repo/.fleet/lib/agent-coord-lib.sh"
LOCK="$TMP/repo/.fleet/locks/claims.lock"
export FLEET_LOCK_STALE_SECS=1   # "old enough to inspect" in ~1s instead of 60s

# HOLDER: acquire, announce, hold (alive!) until told to go, then unlock and report rc.
# Killing it with -9 instead leaves the lock behind — that is our crashed holder.
cat > "$TMP/hold.sh" <<'EOS'
#!/usr/bin/env bash
. "$LIB"
_coord_lock claims || { echo timeout > "$TMP/$1.acquired"; exit 1; }
echo ok > "$TMP/$1.acquired"
while [ ! -e "$TMP/$1.go" ]; do sleep 0.05; done   # slow, but unmistakably ALIVE
_coord_unlock claims; echo "$?" > "$TMP/$1.rc"
EOS
# WAITER: try to acquire; only ever reports if it actually got in.
cat > "$TMP/try.sh" <<'EOS'
#!/usr/bin/env bash
. "$LIB"
_coord_lock claims && echo ACQUIRED > "$TMP/$1.result"
EOS
chmod +x "$TMP/hold.sh" "$TMP/try.sh"
export LIB TMP

owner_of() { cat "$LOCK/owner" 2>/dev/null || echo ""; }   # empty pre-fix: no owner file

# ---------------------------------------------------------------------------------
# 1. CROSS-UNLOCK IS IMPOSSIBLE.
#    A acquires. Its lock is then broken (exactly as the stale path would break it) and B
#    acquires a fresh one. A, still alive, now unlocks. Pre-fix that `rmdir`s the shared
#    path and B's lock evaporates *while B is inside the critical section*. Post-fix A
#    must see the owner token is not its own, REFUSE, warn, and leave B's lock standing.
# ---------------------------------------------------------------------------------
bash "$TMP/hold.sh" a 2>"$TMP/a.err" &
A_PID=$!
await "$TMP/a.acquired" || fail "A never acquired the lock — test is not set up"
[ "$(cat "$TMP/a.acquired")" = ok ] || fail "A timed out acquiring — test is not set up"
[ -d "$LOCK" ] || fail "no lock dir after A acquired — test is not set up"

# Break A's live lock by hand. (We do NOT wait for the stale timer here: post-fix a live
# holder is never broken — that is asserted in part 2. Part 1 needs the *aftermath* of a
# break to exist so we can test what A's unlock does to the lock that replaced its own.)
rm -rf "$LOCK"

bash "$TMP/hold.sh" b 2>"$TMP/b.err" &
B_PID=$!
await "$TMP/b.acquired" || fail "B never acquired after the break — test is not set up"
[ -d "$LOCK" ] || fail "B reports acquired but there is no lock dir — test is not set up"
B_TOKEN="$(owner_of)"

# A wakes and unlocks. THIS is the assertion.
touch "$TMP/a.go"
wait "$A_PID" 2>/dev/null || true

[ -d "$LOCK" ] || fail "#20 CROSS-UNLOCK: A's _coord_unlock removed B's lock — B is in the critical section with the mutex now free, so the next acquirer walks in alongside it (and every later unlock frees a stranger's lock)"
if [ -n "$B_TOKEN" ]; then
  [ "$(owner_of)" = "$B_TOKEN" ] || fail "#20 CROSS-UNLOCK: the lock dir survived but its owner changed ('$(owner_of)' != B's '$B_TOKEN')"
fi
[ "$(cat "$TMP/a.rc" 2>/dev/null || echo 0)" != 0 ] || fail "#20: A's _coord_unlock reported SUCCESS while removing a lock it does not own"
grep -qi stolen "$TMP/a.err" || fail "#20: A's _coord_unlock did not warn on stderr that its lock had been stolen"

touch "$TMP/b.go"; wait "$B_PID" 2>/dev/null || true
rm -rf "$LOCK"

# ---------------------------------------------------------------------------------
# 2. A LIVE HOLDER IS NOT STALE-BROKEN.
#    The root cause of interleaving 1: "held longer than the stale window" must NOT be
#    read as "dead". The lock's mtime is set at mkdir and NEVER refreshed, so a holder
#    that is merely slow eventually looks exactly like a corpse.
#
#    We AGE THE LOCK BY BACKDATING ITS MTIME rather than by sleeping. That is not just a
#    speed trick — it is what makes this assertion mutation-proof: the buggy lib ignores
#    FLEET_LOCK_STALE_SECS entirely (it hardcodes 60), so a 2-second-old lock and a short
#    window would leave it untouched and this part would pass VACUOUSLY against the bug.
#    Backdating past 60s makes the lock look stale to the buggy and the fixed lib alike.
# ---------------------------------------------------------------------------------
backdate() {  # $1 = path, $2 = seconds into the past
  local ts
  ts="$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$2 seconds" +%Y%m%d%H%M.%S)" || return 1
  touch -t "$ts" "$1"
}

bash "$TMP/hold.sh" h 2>"$TMP/h.err" &
H_PID=$!
await "$TMP/h.acquired" || fail "H never acquired the lock — test is not set up"
H_TOKEN="$(owner_of)"

backdate "$LOCK" 120 || fail "could not backdate the lock's mtime — test is not set up"
age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK") ))
[ "$age" -gt 60 ] || fail "lock is only ${age}s old — not stale even to the hardcoded 60s rule, so this would prove nothing"
kill -0 "$H_PID" 2>/dev/null || fail "H died — test is not set up"

bash "$TMP/try.sh" w 2>/dev/null &   # a waiter, given plenty of tries
W_PID=$!
sleep 2
kill "$W_PID" 2>/dev/null || true; wait "$W_PID" 2>/dev/null || true

[ ! -e "$TMP/w.result" ] || fail "#20 LIVE HOLDER BROKEN: a waiter broke the lock of a slow-but-ALIVE holder (${age}s old, but its pid is running) and entered the critical section alongside it — two concurrent read-modify-writes of agent-claims.json, and one claim is silently lost"
[ -d "$LOCK" ] || fail "#20: the live holder's lock dir was destroyed"
if [ -n "$H_TOKEN" ]; then
  [ "$(owner_of)" = "$H_TOKEN" ] || fail "#20: the live holder's lock changed owner underneath it"
fi

# ---------------------------------------------------------------------------------
# 3. A DEAD HOLDER'S LOCK IS STILL RECLAIMABLE (the fix must not over-fire).
#    Refusing to break a *live* holder must not become refusing to break a *dead* one —
#    that would trade a stolen lock for a permanent deadlock. Kill H with -9 so it can
#    never run its unlock, and leave its lock dir (owner file and all) behind.
# ---------------------------------------------------------------------------------
kill -9 "$H_PID" 2>/dev/null || true; wait "$H_PID" 2>/dev/null || true
[ -d "$LOCK" ] || fail "the killed holder's lock vanished on its own — part 3 would prove nothing"
kill -0 "$H_PID" 2>/dev/null && fail "H is somehow still alive — part 3 would prove nothing"

backdate "$LOCK" 120 || fail "could not backdate the lock's mtime — test is not set up"
bash "$TMP/try.sh" r 2>/dev/null &
R_PID=$!
sleep 3
kill "$R_PID" 2>/dev/null || true; wait "$R_PID" 2>/dev/null || true

[ "$(cat "$TMP/r.result" 2>/dev/null || echo "")" = ACQUIRED ] || fail "REGRESSION: the stale lock of a provably DEAD holder was not reclaimed — crash recovery is broken (permanent deadlock)"

echo "PASS: cross-unlock refused (A could not free B's lock), a live holder past the stale window was not broken, and a dead holder's lock was still reclaimed"
