#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Regression guard for the WORKTREES.md write-mutex: N concurrent ledger_add must
# not lose rows. Non-destructive (backs up + restores). Exits non-zero on loss.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"
N="${1:-30}"; F="$(repo_root)/WORKTREES.md"
[ -f "$F" ] || { echo "no WORKTREES.md"; exit 1; }
BAK="$(mktemp)"; cp "$F" "$BAK"; trap 'cp "$BAK" "$F"; rm -f "$BAK"' EXIT
awk '/AGENT-LEDGER:BEGIN/{print;b=1;next}/AGENT-LEDGER:END/{b=0}b{next}{print}' "$F" > "$F.t" && mv "$F.t" "$F"
for i in $(seq 1 "$N"); do ( ledger_add "$i" "agent/issue-$i" "/x/$i" "t$i" ) & done
wait
rows=$(awk '/AGENT-LEDGER:BEGIN/{f=1;next}/AGENT-LEDGER:END/{f=0}f&&/^\| #/{c++}END{print c+0}' "$F")
[ "$rows" -ne "$N" ] && { echo "FAIL: only $rows/$N rows survived (lost updates)"; exit 1; }
echo "OK: $rows/$N concurrent ledger_add rows survived — no lost updates."
