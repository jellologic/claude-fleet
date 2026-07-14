#!/usr/bin/env bash
# NEGATIVE: `fleet reaper` must SEE claims held by other hosts (the lock is a REMOTE ref),
# must FULLY reclaim the ones it can prove are dead, and must NOT shred the ones it cannot.
#
# Regression for #21. The lock `agent-claim.sh` takes is a REMOTE ref — it pushes
# `agent/issue-<N>` as a compare-and-swap and refuses any issue whose remote branch already
# exists. So the lock namespace is GLOBAL. But the reaper enumerated claims from
# `git worktree list` — LOCAL worktrees only. Host B claims #57, pushes the ref, then dies
# (laptop wiped / CI runner terminated): host A's reaper never sees #57, reports nothing,
# and `fleet claim 57` dies forever on "claimed on another host". The one tool whose entire
# job is reclamation was structurally incapable of reclaiming it; only a human running
# `git push origin --delete` could.
#
# The fix enumerates the UNION of local worktrees and `ls-remote --heads origin
# 'refs/heads/agent/issue-*'`. Two ways that fix can be WORSE than the bug, both asserted
# here:
#   1. THE SHREDDER. A foreign claim has no LOCAL branch, so the old ahead-count
#      (`rev-list origin/main..agent/issue-57 || echo 0`) resolves to nothing → 0 → "no work,
#      abandoned" → every foreign claim in the fleet reaped on the next default run, real
#      pushed work and all. The count must be taken against the REMOTE-TRACKING ref
#      (`origin/agent/issue-57`), after a fetch, and must fail closed if it cannot be taken.
#   2. THE RACE. A remote ref that appeared 30 seconds ago is not a dead host — it is an
#      agent that has not pushed work yet. The remote ref (the CAS lock) is dropped only on
#      POSITIVE evidence of death: gh answered "no open PR" (rc 0), no uncommitted work,
#      nothing past the claim commit, AND the claim is older than the stale window.
#
# #22's guarantees (fail closed on gh; never reap uncommitted work) must survive all of it.
#
# gh is stubbed on PATH and "origin" is a local bare repo, so this test needs no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- gh stub -------------------------------------------------------------------------
# FLEET_TEST_GH=ok   → `pr list` succeeds and answers "no open PR" (exit 0, empty stdout)
# FLEET_TEST_GH=down → `pr list` FAILS (exit 1) like a 5xx / rate-limit / network drop
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "pr list")
    if [ "${FLEET_TEST_GH:-ok}" = "down" ]; then
      echo "gh: API rate limit exceeded / could not connect to api.github.com" >&2
      exit 1
    fi
    exit 0 ;;                       # answered: no open PR
  "pr close"|"issue edit"|"pr create") exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"; export PATH
command -v gh | grep -q "^$TMP/bin/gh$" || fail "gh stub is not first on PATH"

# --- origin + host A ------------------------------------------------------------------
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/repo"
cd "$TMP/repo"
git config user.email t@t; git config user.name t
git remote add origin "$TMP/origin.git"
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
git push -q -u origin main

# Commit dates git accepts verbatim: 48h ago (a claim from a host that died two days ago)
# and now (a claim another host took seconds ago).
OLD="$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time()-48*3600)) + "+0000")')"
NOW="$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "+0000")')"

# --- host B: another machine. It claims issues, pushes the CAS refs… and dies. ---------
# Everything it leaves behind on THIS host is a remote ref. No worktree, no local branch:
# exactly the state that made #21 unreclaimable.
git clone -q "$TMP/origin.git" "$TMP/hostB"
git -C "$TMP/hostB" config user.email b@b; git -C "$TMP/hostB" config user.name b
foreign_claim() {  # issue when [extra-commits]
  local n="$1" when="$2" extra="${3:-0}" br="agent/issue-$1" i
  git -C "$TMP/hostB" checkout -q -b "$br" origin/main
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$TMP/hostB" commit --allow-empty -q -m "chore(agent): claim #$n"
  i=0; while [ "$i" -lt "$extra" ]; do
    echo "real work $i on #$n" >> "$TMP/hostB/work-$n.txt"
    git -C "$TMP/hostB" add -A
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
      git -C "$TMP/hostB" commit -q -m "feat: real work $i on #$n"
    i=$((i+1))
  done
  git -C "$TMP/hostB" push -q origin "$br"
  git -C "$TMP/hostB" checkout -q main
}
foreign_claim 201 "$OLD"          # dead host: stale, no PR, claim commit only  → RECLAIM
foreign_claim 202 "$OLD" 1        # dead host BUT it pushed real work (ahead 2) → KEEP
foreign_claim 203 "$NOW"          # claimed seconds ago on another host          → KEEP
rm -rf "$TMP/hostB"               # host B is gone. Only its remote refs remain.

# --- host A: one LOCAL claim, live, hours of uncommitted work (the #22 guarantee) ------
git worktree add -q -b agent/issue-204 .fleet/worktrees/agent/issue-204 main
git -C .fleet/worktrees/agent/issue-204 commit --allow-empty -q -m "chore(agent): claim #204"
git -C .fleet/worktrees/agent/issue-204 push -q -u origin agent/issue-204
echo "hours of uncommitted work" > .fleet/worktrees/agent/issue-204/wip.txt

# --- preconditions --------------------------------------------------------------------
git fetch -q origin
for n in 201 202 203; do
  git ls-remote --exit-code --heads origin "agent/issue-$n" >/dev/null 2>&1 \
    || fail "precondition: remote claim ref agent/issue-$n was not created"
  [ -d ".fleet/worktrees/agent/issue-$n" ] && fail "precondition: #$n must have NO local worktree (it is a foreign claim)"
  git show-ref -q --verify "refs/heads/agent/issue-$n" \
    && fail "precondition: #$n must have NO local branch — that is the whole point of #21"
done
# The shredder trap, made explicit: the BARE branch name resolves to nothing for a foreign
# claim. Anything counting `origin/main..agent/issue-202` gets an error (and, pre-fix, `|| echo 0`).
git rev-list --count origin/main..agent/issue-202 >/dev/null 2>&1 \
  && fail "precondition: agent/issue-202 resolves locally — the foreign-claim setup is wrong"
a="$(git rev-list --count origin/main..origin/agent/issue-202)"
[ "$a" -eq 2 ] || fail "precondition: #202 is $a commits ahead via the remote-tracking ref, expected 2 (claim + real work)"
for n in 201 203; do
  a="$(git rev-list --count "origin/main..origin/agent/issue-$n")"
  [ "$a" -eq 1 ] || fail "precondition: #$n is $a commits ahead, expected 1 (the claim commit only — the ahead<=1 trap)"
done
# …and they differ ONLY in age: #201's claim is 48h old, #203's is minutes old.
[ "$(( $(date +%s) - $(git log -1 --format=%ct origin/agent/issue-201) ))" -ge 86400 ] \
  || fail "precondition: #201's claim commit is not stale — the reclamation window is not being exercised"
[ "$(( $(date +%s) - $(git log -1 --format=%ct origin/agent/issue-203) ))" -lt 3600 ] \
  || fail "precondition: #203's claim commit is not fresh — the recency guard is not being exercised"
git -C .fleet/worktrees/agent/issue-204 status --porcelain | grep -q wip.txt \
  || fail "precondition: #204's worktree is not dirty — the #22 regression guard is inert"

# === 1. gh DOWN → reap NOTHING, foreign claims included (fail closed, #22) =============
export FLEET_TEST_GH=down
out="$(.fleet/bin/fleet reaper 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [gh down] /'
[ "$rc" -eq 0 ] || fail "reaper exited $rc with gh down"
echo "$out" | grep -q "reaped=0" || fail "reaper REAPED while gh could not answer — fail-closed broken through the new remote path (#21/#22)"
for n in 201 202 203 204; do
  git ls-remote --exit-code --heads origin "agent/issue-$n" >/dev/null 2>&1 \
    || fail "gh outage dropped #$n's remote ref — the CAS lock was released on 'gh could not answer'"
done

# === 2. PRE-FIX behaviour: the foreign claims are INVISIBLE ============================
# Synthesize the pre-fix reaper by deleting the remote-enumeration block (worktree-only
# enumeration, exactly the #21 bug) and confirm it cannot even SEE #201/#202/#203.
sed '/--- REMOTE CLAIM ENUMERATION (#21)/,/--- END REMOTE CLAIM ENUMERATION/d' \
  .fleet/bin/agent-reaper.sh > .fleet/bin/agent-reaper-prefix.sh
chmod +x .fleet/bin/agent-reaper-prefix.sh
export FLEET_TEST_GH=ok
out="$(.fleet/bin/agent-reaper-prefix.sh --dry-run 2>&1)"
echo "$out" | sed 's/^/    | [pre-fix] /'
echo "$out" | grep -q "#204" || fail "the synthesized pre-fix reaper does not even see the LOCAL claim — the test's sed broke it"
for n in 201 202 203; do
  echo "$out" | grep -q "#$n" \
    && fail "the pre-fix (worktree-only) reaper reported #$n — the remote-enumeration block is not what makes foreign claims visible"
done
rm -f .fleet/bin/agent-reaper-prefix.sh

# === 3. DEFAULT run, gh OK ============================================================
out="$(.fleet/bin/fleet reaper 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [default] /'
[ "$rc" -eq 0 ] || fail "default reaper exited $rc"

# 3a. #201 — the #21 deadlock. Foreign, stale, gh says no PR, nothing past the claim
#     commit. POSITIVE evidence of death → discovered AND FULLY reclaimed: the remote ref
#     is dropped, so agent-claim.sh's ls-remote guard would now permit a re-claim.
echo "$out" | grep -q "reaped #201" \
  || fail "the dead foreign claim #201 was NOT reaped — the reaper still cannot see claims held on other hosts (#21)"
git ls-remote --exit-code --heads origin agent/issue-201 >/dev/null 2>&1 \
  && fail "#201's remote ref SURVIVED the reap — agent-claim.sh's ls-remote guard still refuses the issue: still HALF-reclaimed, still deadlocked (#21)"

# 3b. THE ANTI-SHREDDER (§2). #202 is foreign and stale too — but it has REAL PUSHED WORK
#     (ahead 2 against origin/main, visible ONLY through origin/agent/issue-202). A default
#     run must keep it. If the ahead-count is being taken against the nonexistent LOCAL ref,
#     it reads 0, #202 looks abandoned, and its work is deleted from the remote.
echo "$out" | grep -q "kept #202 (ORPHAN+WORK: 2 commits ahead" \
  || fail "#202 (foreign, 2 commits of REAL WORK) was not kept as ORPHAN+WORK — the ahead-count is not resolving against origin/agent/issue-202. This is the shredder: every foreign claim reads '0 ahead' and gets reaped."
echo "$out" | grep -q "reaped #202" && fail "SHREDDER: the reaper REAPED foreign claim #202, destroying pushed work"
git ls-remote --exit-code --heads origin agent/issue-202 >/dev/null 2>&1 \
  || fail "SHREDDER: #202's remote ref (and its real work) was deleted by a default run"

# 3c. #203 — foreign but claimed seconds ago. Not stale = no evidence of death = keep.
echo "$out" | grep -q "kept #203" \
  || fail "#203 (a foreign claim made seconds ago) was reaped — the reaper is racing live agents on other hosts"
git ls-remote --exit-code --heads origin agent/issue-203 >/dev/null 2>&1 \
  || fail "#203's CAS lock was released while the claim was still fresh"

# 3d. #22 regression guard: local, live, uncommitted work, no PR, ahead==1 → untouched.
echo "$out" | grep -q "kept #204" || fail "#204 (live local claim, uncommitted work) was not reported kept (#22)"
[ -f .fleet/worktrees/agent/issue-204/wip.txt ] \
  || fail "the default run DESTROYED #204's uncommitted work — #22's guarantee regressed"
git ls-remote --exit-code --heads origin agent/issue-204 >/dev/null 2>&1 \
  || fail "the default run dropped #204's remote ref under a LIVE agent (#22)"

echo "PASS: foreign (remote-only) claims are enumerated; a stale, PR-less, work-free one is FULLY reclaimed (remote CAS ref dropped); a foreign claim with pushed work is kept (ahead counted against origin/<branch>, not a nonexistent local ref); a fresh foreign claim is kept; gh outage reaps nothing; #22's live local claim with uncommitted work survives"
