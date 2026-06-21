#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Hidden setup for assets/demo.tape — builds a throwaway repo in /tmp/cf-demo with
# claude-fleet installed from the current checkout. SOURCED by the tape (no `set -e`,
# so a failure can't kill the interactive shell). No GitHub side effects.
FLEET_SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
D=/tmp/cf-demo
rm -rf "$D" && mkdir -p "$D/src" && cd "$D" || return
git init -q && git config user.email demo@local && git config user.name demo
printf 'export const app = 1\n' > src/app.ts
git add -A && git commit -qm init >/dev/null 2>&1
git branch -M main >/dev/null 2>&1
bash "$FLEET_SRC/install.sh" "$D" >/dev/null 2>&1
export PATH="$D/.fleet/bin:$PATH"
export PS1='❯ '
clear
