#!/usr/bin/env bash
# NEGATIVE: `fleet reaper` must NOT destroy a live agent's uncommitted work, and must
# reap NOTHING when gh cannot answer.
#
# Regression for #22. The reaper's only liveness signal was "does an open PR exist for
# this branch". `agent-claim.sh` writes EXACTLY ONE empty claim commit, so an agent that
# has worked for hours but not committed yet sits at `ahead == 1` forever — and its draft
# PR is trivially missing, because agent-claim treats `gh pr create` as best-effort (a
# rate-limit just prints WARN and the agent keeps working). Pre-fix that combination hit
# the DEFAULT path — `ahead <= 1 → reap ORPHAN` with force-remote — and
# `agent-release.sh --delete-remote` then ran `git worktree remove --force` (ALL
# uncommitted work gone), `git branch -D`, and `git push origin --delete` (the CAS lock
# released, so a second agent can claim the same issue).
#
# The amplifier: `gh pr list`'s status was swallowed by `2>/dev/null || true`, so "gh could
# not answer" (outage / 5xx / rate-limit) was indistinguishable from "there is no PR".
# During a GitHub outage EVERY branch looks PR-less, so ONE default `fleet reaper` run
# mass-reaps every not-yet-committed claim in the fleet. --dry-run is opt-in; the default
# run is destructive.
#
# gh is stubbed on PATH, so this test needs no network.
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

# --- repo + two claims ---------------------------------------------------------------
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

# Exactly what agent-claim.sh produces: a worktree + ONE empty claim commit, pushed.
claim() {  # issue
  local n="$1" br="agent/issue-$1" wt=".fleet/worktrees/agent/issue-$1"
  git worktree add -q -b "$br" "$wt" main
  git -C "$wt" commit --allow-empty -q -m "chore(agent): claim #$n"
  git -C "$wt" push -q -u origin "$br"
}
claim 101   # LIVE agent: has been working for hours, nothing committed yet
claim 102   # genuinely abandoned: crashed right after claiming, worktree clean

# #101's real, uncommitted work — the thing a bad reap destroys.
echo "hours of uncommitted work" > .fleet/worktrees/agent/issue-101/wip.txt
git -C .fleet/worktrees/agent/issue-101 status --porcelain | grep -q wip.txt \
  || fail "precondition: #101's worktree is not dirty — the test is not exercising #22"

# Preconditions. Both claims sit at ahead==1 with no PR: pre-fix, BOTH take the default
# ORPHAN path. Only the working tree tells the live one from the dead one.
for n in 101 102; do
  a="$(git rev-list --count "origin/main..agent/issue-$n")"
  [ "$a" -eq 1 ] || fail "precondition: #$n is $a commits ahead, expected 1 (the ahead<=1 trap)"
done

# === 1. gh DOWN → reap NOTHING (fail closed) ==========================================
export FLEET_TEST_GH=down
out="$(.fleet/bin/fleet reaper 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [gh down] /'
[ "$rc" -eq 0 ] || fail "reaper exited $rc with gh down (should keep claims, not crash)"
echo "$out" | grep -q "reaped=0" \
  || fail "reaper REAPED a claim while gh could not answer (#22) — one outage mass-reaps the fleet"
for n in 101 102; do
  [ -d ".fleet/worktrees/agent/issue-$n" ] || fail "gh outage destroyed #$n's worktree — fail-open mass-reap (#22)"
  git show-ref -q --verify "refs/heads/agent/issue-$n" || fail "gh outage deleted #$n's local branch (#22)"
  git ls-remote --exit-code --heads origin "agent/issue-$n" >/dev/null 2>&1 \
    || fail "gh outage dropped #$n's remote ref — the CAS lock was released (#22)"
done
[ -f .fleet/worktrees/agent/issue-101/wip.txt ] || fail "gh outage destroyed #101's uncommitted work (#22)"

# === 2. gh OK, default run: live+uncommitted kept, abandoned reaped ===================
export FLEET_TEST_GH=ok
out="$(.fleet/bin/fleet reaper 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [default] /'
[ "$rc" -eq 0 ] || fail "default reaper exited $rc"

# 2a. THE data-destroying scenario: live agent, uncommitted work, no PR, ahead==1.
[ -d .fleet/worktrees/agent/issue-101 ] \
  || fail "default reaper DESTROYED the live agent's worktree #101 (#22) — hours of uncommitted work gone"
[ -f .fleet/worktrees/agent/issue-101/wip.txt ] \
  || fail "default reaper destroyed #101's UNCOMMITTED work (#22) — git worktree remove --force"
grep -q "hours of uncommitted work" .fleet/worktrees/agent/issue-101/wip.txt \
  || fail "#101's uncommitted work was clobbered (#22)"
git show-ref -q --verify refs/heads/agent/issue-101 || fail "default reaper deleted live branch agent/issue-101 (#22)"
git ls-remote --exit-code --heads origin agent/issue-101 >/dev/null 2>&1 \
  || fail "default reaper dropped #101's remote ref — CAS lock released under a LIVE agent (#22)"
echo "$out" | grep -q "kept #101" || fail "#101 was not reported kept"

# 2b. …and the reaper is still USEFUL: the genuinely abandoned, clean claim IS reaped.
echo "$out" | grep -q "reaped #102" || fail "abandoned clean claim #102 was NOT reaped — the fix broke the reaper"
[ -d .fleet/worktrees/agent/issue-102 ] && fail "#102's worktree still present after a reported reap"
git show-ref -q --verify refs/heads/agent/issue-102 && fail "#102's local branch survived the reap"

# 2c. …but the reap must NOT implicitly drop the remote ref (the CAS lock).
git ls-remote --exit-code --heads origin agent/issue-102 >/dev/null 2>&1 \
  || fail "default reaper auto-dropped #102's remote ref — the CAS lock must need --force/--delete-remote (#22)"

# === 3. --dry-run still works, and --force still reaps the dirty worktree =============
out="$(.fleet/bin/fleet reaper --force --dry-run 2>&1)"
echo "$out" | sed 's/^/    | [dry-run] /'
echo "$out" | grep -q "\[dry-run\] would reap #101" || fail "--dry-run did not report the forced reap of #101"
[ -f .fleet/worktrees/agent/issue-101/wip.txt ] || fail "--dry-run DESTROYED #101's work — dry-run must not act"

out="$(.fleet/bin/fleet reaper --force 2>&1)"
echo "$out" | sed 's/^/    | [force] /'
echo "$out" | grep -q "reaped #101" || fail "--force did not reap #101 — the escape hatch is broken"
[ -d .fleet/worktrees/agent/issue-101 ] && fail "--force reported a reap but left #101's worktree"

echo "PASS: gh outage reaps nothing (fail closed); live claim with uncommitted work + no PR + ahead==1 survives a default run; abandoned clean claim still reaped, remote CAS lock kept; --dry-run inert; --force still reaps"
