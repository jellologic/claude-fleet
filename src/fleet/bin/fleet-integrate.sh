#!/usr/bin/env bash
# Sequentially merge agent branches into an integration branch, gating EACH merge
# with fleet_gate (scoped via fleet_pkg_for) and rolling back any branch that
# conflicts or fails. Run from a worktree on <integration-branch>. Never pushes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

INTEG="${1:?usage: fleet-integrate.sh <integration-branch> <branch>...}"
shift
[ "$#" -gt 0 ] || { echo "no branches to merge" >&2; exit 2; }
cur="$(git branch --show-current)"
[ "$cur" = "$INTEG" ] || { echo "error: run from a worktree on '$INTEG' (currently on '$cur')" >&2; exit 2; }

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

PASS=(); FAIL=()
for BR in "$@"; do
  echo "==================================================================="
  echo "merging: $BR"
  if ! git rev-parse --verify --quiet "$BR" >/dev/null; then echo "  RESULT: FAIL (no such branch)"; FAIL+=("$BR :: missing"); continue; fi
  base="$(git merge-base "$INTEG" "$BR" 2>/dev/null || true)"
  changed="$(git diff --name-only "${base:-$INTEG}..$BR" 2>/dev/null)"
  echo "  changed files: $(printf '%s\n' "$changed" | grep -c .)"
  if ! git merge --no-ff --no-edit "$BR" >/tmp/fi-merge.$$ 2>&1; then
    echo "  RESULT: FAIL (merge conflict)"; grep -i conflict /tmp/fi-merge.$$ | head | sed 's/^/    /'
    git merge --abort 2>/dev/null || true; FAIL+=("$BR :: merge-conflict"); continue
  fi
  if gate "$changed"; then echo "  RESULT: PASS"; PASS+=("$BR")
  else echo "  RESULT: FAIL (gate) → rolling back"; git reset --hard HEAD~1 >/dev/null 2>&1; FAIL+=("$BR :: gate"); fi
done
rm -f /tmp/fi-merge.$$
echo "==================================================================="
if [ "${SKIP_FINAL:-0}" = 1 ]; then echo "FINAL gate: SKIPPED"; else echo "FINAL gate on integrated result:"; if gate ""; then echo "  FINAL: PASS"; else echo "  FINAL: FAIL"; fi; fi
echo "==================================================================="
echo "INTEGRATION SUMMARY"
echo "  merged clean (${#PASS[@]}): ${PASS[*]:-none}"
echo "  rejected     (${#FAIL[@]}): ${FAIL[*]:-none}"
echo "  '$INTEG' now at $(git rev-parse --short HEAD)"
[ "${#FAIL[@]}" -eq 0 ]
