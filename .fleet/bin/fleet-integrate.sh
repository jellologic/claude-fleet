#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Sequentially merge agent branches into an integration branch, gating EACH merge
# with fleet_gate (scoped via fleet_pkg_for) and rolling back any branch that
# conflicts or fails. Run from a worktree on <integration-branch>. Never pushes.
#
# COHORTS (#55). The per-branch gate encodes a latent assumption: EVERY BRANCH IS
# INDEPENDENTLY GREEN. That held while fleet only coordinated agents each doing a
# self-contained issue. `fanout` + `spec` break it ON PURPOSE: a `provides`/`consumes`
# port edge exists precisely so that a consumer and its provider can be built in
# PARALLEL and only meet at INTEGRATION. Such units are green only TOGETHER —
#   merge the provider alone → the integration test has no consumer → RED → rolled back
#   merge the consumer alone → the integration test has no provider → RED → rolled back
# — and the gate is UNSATISFIABLE BY CONSTRUCTION. `--cohort` merges a set of branches
# FIRST and gates the combined tree ONCE; the cohort is ONE atomic unit of work, so a red
# combined gate rolls back the WHOLE cohort, never an individual member.
#
# usage: fleet-integrate.sh <integ> [<branch>...] [--cohort <b>... [--] <branch>...]...
#   bare branches           gated INDIVIDUALLY, rolled back individually (the default; right
#                           for independent branches — one bad branch fails fast without
#                           poisoning the integration tree)
#   --cohort b1 b2 ...      merge ALL, THEN gate ONCE; roll back the WHOLE cohort if red
#   --                      ends the current cohort; following branches are individual again
# `--cohort` may appear more than once. Example:
#   fleet integrate integ --cohort a b -- c d      # {a,b} gated together, then c, then d
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

INTEG="${1:?usage: fleet-integrate.sh <integration-branch> [--cohort] <branch>...}"
shift
[ "$#" -gt 0 ] || { echo "no branches to merge" >&2; exit 2; }
cur="$(git branch --show-current)"
[ "$cur" = "$INTEG" ] || { echo "error: run from a worktree on '$INTEG' (currently on '$cur')" >&2; exit 2; }

# The merge gate must still be WIRED before we trust anything it says (#30). If some agent
# repointed core.hooksPath, the pre-push hook is a no-op and integrating is unsafe.
# Escape hatch for environments that legitimately manage hooks elsewhere (CI).
if [ "${FLEET_SKIP_GATE_CHECK:-0}" != 1 ]; then
  "$HERE/check-gate-integrity.sh" --quiet || {
    echo "error: refusing to integrate — the merge gate is not wired (see 'fleet gate-check')" >&2
    echo "       set FLEET_SKIP_GATE_CHECK=1 only if hooks are managed elsewhere." >&2
    exit 2; }
fi

# ── parse the plan: a left-to-right list of items, each SOLO or a COHORT ───────────────
# The grammar is deliberately the simplest unambiguous one: `--cohort` OPENS a group and
# swallows branches until `--`, the next `--cohort`, or end of args.
ITEMS=()          # "solo:<branch>"  |  "cohort:<b1> <b2> ..."
_mode=solo; _cur=""
_flush() { if [ -n "$_cur" ]; then ITEMS+=("cohort:$_cur"); _cur=""; fi; }
for a in "$@"; do
  case "$a" in
    --cohort) if [ "$_mode" = cohort ] && [ -z "$_cur" ]; then echo "error: empty --cohort group" >&2; exit 2; fi
              _flush; _mode=cohort ;;
    --)       if [ "$_mode" = cohort ] && [ -z "$_cur" ]; then echo "error: empty --cohort group" >&2; exit 2; fi
              _flush; _mode=solo ;;
    -*)       echo "error: unknown flag '$a' (expected --cohort or --)" >&2; exit 2 ;;
    *)        if [ "$_mode" = cohort ]; then _cur="$_cur${_cur:+ }$a"; else ITEMS+=("solo:$a"); fi ;;
  esac
done
if [ "$_mode" = cohort ] && [ -z "$_cur" ]; then echo "error: empty --cohort group" >&2; exit 2; fi
_flush
[ "${#ITEMS[@]}" -gt 0 ] || { echo "no branches to merge" >&2; exit 2; }

INTEG_BASE="$(git rev-parse HEAD)"   # integration tip BEFORE any merge — used to scope the FINAL gate
MERGE_LOG="/tmp/fi-merge.$$"

gate() {
  local files="$1" units="" full=0 u
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    u="$(fleet_pkg_for "$f")"
    if [ -z "$u" ]; then full=1; break; fi
    case " $units " in *" $u "*) : ;; *) units="$units $u" ;; esac
  done <<EOF
$files
EOF
  if [ "$full" = 1 ] || [ -z "$units" ]; then echo "    [gate] full tree"; fleet_gate; else echo "    [gate] scoped:$units"; fleet_gate $units; fi
}

# Merge ONE branch into the current tip. Sets CHANGED to that branch's diff.
# 0 = merged, 1 = no such branch, 2 = merge conflict (aborted, tree untouched).
CHANGED=""
merge_branch() {
  local BR="$1" base
  CHANGED=""
  git rev-parse --verify --quiet "$BR" >/dev/null || return 1
  base="$(git merge-base "$INTEG" "$BR" 2>/dev/null || true)"
  CHANGED="$(git diff --name-only "${base:-$INTEG}..$BR" 2>/dev/null)"
  echo "  changed files: $(printf '%s\n' "$CHANGED" | grep -c .)"
  git merge --no-ff --no-edit "$BR" >"$MERGE_LOG" 2>&1 && return 0
  git merge --abort 2>/dev/null || true
  return 2
}

PASS=(); FAIL=()

# The default path: gate each branch on its own and roll IT back if red. Correct for
# INDEPENDENT branches — it catches one bad branch early, before it poisons the tree.
solo_run() {  # $1 = branch
  local BR="$1" rc
  echo "==================================================================="
  echo "merging: $BR"
  merge_branch "$BR"; rc=$?
  case "$rc" in
    1) echo "  RESULT: FAIL (no such branch)"; FAIL+=("$BR :: missing"); return ;;
    2) echo "  RESULT: FAIL (merge conflict)"; grep -i conflict "$MERGE_LOG" | head | sed 's/^/    /'
       FAIL+=("$BR :: merge-conflict"); return ;;
  esac
  if gate "$CHANGED"; then echo "  RESULT: PASS"; PASS+=("$BR")
  else echo "  RESULT: FAIL (gate) → rolling back"; git reset --hard HEAD~1 >/dev/null 2>&1; FAIL+=("$BR :: gate"); fi
}

# DIAGNOSTIC, never a veto (#55). After a cohort's combined gate goes red, gate each member
# ALONE purely to HINT at which diff is the likely cause. For genuinely co-dependent units
# EVERY member is red alone — that is the whole point of a port — so this can never be
# allowed to reject anything. It runs from, and returns to, the pre-cohort tip.
cohort_diagnose() {  # $1 = pre-cohort tip, $2.. = members that merged
  local pre="$1"; shift
  local BR base changed red="" nred=0 restore
  restore="$(git rev-parse HEAD)"   # put the tree back exactly as we found it: the ROLLBACK is the
                                    # caller's decision, never the diagnostic's.
  echo "  --- DIAGNOSTIC (a HINT — never a veto): gating each member ALONE"
  for BR in "$@"; do
    git reset --hard "$pre" >/dev/null 2>&1
    if ! git merge --no-ff --no-edit "$BR" >"$MERGE_LOG" 2>&1; then
      git merge --abort 2>/dev/null || true
      echo "      $BR: cannot be gated alone (conflicts with the pre-cohort tip)"
      continue
    fi
    base="$(git merge-base "$pre" "$BR" 2>/dev/null || true)"
    changed="$(git diff --name-only "${base:-$pre}..$BR" 2>/dev/null)"
    if gate "$changed" >/dev/null 2>&1; then
      echo "      $BR: green alone"
    else
      echo "      $BR: RED alone"; red="$red $BR"; nred=$((nred + 1))
    fi
  done
  git reset --hard "$restore" >/dev/null 2>&1
  if [ "$nred" -eq 1 ]; then
    echo "      HINT: only$red is red alone — its diff is the most likely cause. Still ONLY a hint."
  elif [ "$nred" -gt 1 ]; then
    echo "      HINT: $nred members are red alone ($red). For CO-DEPENDENT units that is EXPECTED"
    echo "            (a consumer without its provider is red by construction) and indicts nobody."
  else
    echo "      HINT: every member is green alone — the failure is in their COMBINATION"
    echo "            (a semantic conflict), not in any single diff."
  fi
}

# A cohort is ONE atomic unit of work: merge every member, THEN gate once.
cohort_run() {  # $@ = member branches
  local pre merged="" bad="" BR rc allchanged=""
  pre="$(git rev-parse HEAD)"
  echo "==================================================================="
  echo "cohort: $*"
  echo "  merging ALL members, THEN gating ONCE on the combined tree — these units are"
  echo "  co-dependent (a port edge declares they are NOT independently gateable)."
  for BR in "$@"; do
    echo "  --- merging: $BR"
    merge_branch "$BR"; rc=$?
    case "$rc" in
      1) echo "  RESULT: FAIL (no such branch)"; FAIL+=("$BR :: missing"); bad="$bad $BR" ;;
      2) echo "  RESULT: FAIL (merge conflict)"; grep -i conflict "$MERGE_LOG" | head | sed 's/^/    /'
         FAIL+=("$BR :: merge-conflict"); bad="$bad $BR" ;;
      0) echo "  RESULT: merged (gate deferred to the cohort)"; merged="$merged $BR"
         allchanged="$allchanged
$CHANGED" ;;
    esac
  done

  # A merge conflict is NOT a gate failure and must never be reported as one. The cohort is
  # atomic, so an incomplete cohort is not gateable at all: roll the members that DID merge
  # back out and report the conflict per-branch.
  if [ -n "$bad" ]; then
    echo "  COHORT RESULT: FAIL (merge conflict/missing:$bad) — NOT a gate verdict; the gate never ran."
    echo "  a cohort is atomic: rolling back the members that did merge (${merged:-none})"
    git reset --hard "$pre" >/dev/null 2>&1
    for BR in $merged; do FAIL+=("$BR :: cohort-incomplete"); done
    return
  fi

  echo "  --- COHORT GATE (once, on the combined tree of:$merged)"
  if gate "$allchanged"; then
    echo "  COHORT RESULT: PASS ($merged)"
    for BR in $merged; do PASS+=("$BR"); done
  else
    echo "  COHORT RESULT: FAIL (gate) → rolling back the WHOLE cohort"
    cohort_diagnose "$pre" $merged
    git reset --hard "$pre" >/dev/null 2>&1
    for BR in $merged; do FAIL+=("$BR :: cohort-gate"); done
  fi
}

for item in "${ITEMS[@]}"; do
  case "$item" in
    solo:*)   solo_run "${item#solo:}" ;;
    cohort:*) cohort_run ${item#cohort:} ;;
  esac
done
rm -f "$MERGE_LOG"
echo "==================================================================="
FINAL_RC=0
if [ "${SKIP_FINAL:-0}" = 1 ]; then echo "FINAL gate: SKIPPED"; else echo "FINAL gate on integrated result (scoped to changed packages):"; if gate "$(git diff --name-only "$INTEG_BASE..HEAD" 2>/dev/null)"; then echo "  FINAL: PASS"; else echo "  FINAL: FAIL"; FINAL_RC=1; fi; fi
echo "==================================================================="
echo "INTEGRATION SUMMARY"
echo "  merged clean (${#PASS[@]}): ${PASS[*]:-none}"
echo "  rejected     (${#FAIL[@]}): ${FAIL[*]:-none}"
echo "  '$INTEG' now at $(git rev-parse --short HEAD)"
# The FINAL gate is not rolled back (unlike a per-branch failure): the integrated
# tree stays at the broken merge, so the exit code is the only signal a caller gets.
[ "$FINAL_RC" -eq 0 ] || echo "  WARNING: FINAL gate FAILED — '$INTEG' is BROKEN; do not merge it" >&2
[ "${#FAIL[@]}" -eq 0 ] && [ "$FINAL_RC" -eq 0 ]
