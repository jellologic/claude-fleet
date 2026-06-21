#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Install claude-fleet into a target git repo (vendoring). Idempotent — re-run to update.
# Removable: writes managed marker blocks + vendors uninstall.sh (see `fleet uninstall`).
#   ./install.sh <target-repo-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
TARGET="${1:?usage: install.sh <target-repo-dir>}"
TARGET="$(cd "$TARGET" && pwd)"
git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: $TARGET is not a git repo" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required (guards + ownership gate)" >&2; exit 1; }

echo "Installing claude-fleet into $TARGET"

# 1) .fleet/ — lib, bin, githooks, removal tooling, self-report doc. Preserve config.sh.
mkdir -p "$TARGET/.fleet"
cp -R "$SRC/fleet/lib" "$SRC/fleet/bin" "$SRC/fleet/githooks" "$TARGET/.fleet/"
cp "$HERE/uninstall.sh" "$HERE/unmerge-settings.py" "$HERE/SELF-REPORT.md" "$TARGET/.fleet/"
chmod +x "$TARGET/.fleet/bin/"* "$TARGET/.fleet/githooks/"* "$TARGET/.fleet/uninstall.sh" 2>/dev/null || true
if [ ! -f "$TARGET/.fleet/config.sh" ]; then
  cp "$SRC/fleet/config.sh.example" "$TARGET/.fleet/config.sh"
  echo "  created .fleet/config.sh (EDIT fleet_bootstrap + fleet_gate for your stack)"
else
  echo "  kept existing .fleet/config.sh"
fi

# 2) .claude/ — hooks, commands, manifest template + schema.
mkdir -p "$TARGET/.claude/hooks" "$TARGET/.claude/commands"
cp "$SRC/claude/hooks/"* "$TARGET/.claude/hooks/"; chmod +x "$TARGET/.claude/hooks/"* 2>/dev/null || true
cp "$SRC/claude/commands/"* "$TARGET/.claude/commands/"
cp "$SRC/claude/agent-claims.template.json" "$SRC/claude/agent-claims.schema.json" "$TARGET/.claude/"

# 3) Merge hook wiring into .claude/settings.json (non-destructive).
python3 "$HERE/install-merge-settings.py" "$SRC/claude/settings.fleet.json" "$TARGET/.claude/settings.json"

# 4) Templates (don't clobber existing).
[ -f "$TARGET/WORKTREES.md" ]     || cp "$SRC/templates/WORKTREES.md" "$TARGET/WORKTREES.md"
[ -f "$TARGET/.worktreeinclude" ] || cp "$SRC/templates/worktreeinclude" "$TARGET/.worktreeinclude"

# 5) .gitignore — managed marker block (clean to remove on uninstall).
touch "$TARGET/.gitignore"
if ! grep -q '# >>> claude-fleet (managed) >>>' "$TARGET/.gitignore"; then
  {
    echo "# >>> claude-fleet (managed) >>>"
    echo ".fleet/worktrees/"
    echo ".fleet/locks/"
    echo ".claude/worktrees/"
    echo ".claude/settings.local.json"
    echo ".claude/agent-claims.json"
    echo "# <<< claude-fleet (managed) <<<"
  } >> "$TARGET/.gitignore"
fi

# 6) CLAUDE.md — managed marker block.
if ! grep -q '<!-- >>> claude-fleet (managed) >>> -->' "$TARGET/CLAUDE.md" 2>/dev/null; then
  {
    echo "<!-- >>> claude-fleet (managed) >>> -->"
    cat "$SRC/templates/CLAUDE.fleet.md"
    echo "<!-- <<< claude-fleet (managed) <<< -->"
  } >> "$TARGET/CLAUDE.md"
  echo "  appended fleet section to CLAUDE.md"
fi

# 7) Wire the git hooks.
( cd "$TARGET" && sh .fleet/bin/install-hooks.sh )

cat <<EOF

claude-fleet installed. Next:
  1. Edit $TARGET/.fleet/config.sh  → set fleet_bootstrap + fleet_gate (see $HERE/examples/)
  2. gh label create agent-ready; gh label create agent-working
  3. Commit the .fleet/ + .claude/ files to main (and push)
  4. .fleet/bin/fleet ruleset      # protect main
  5. .fleet/bin/fleet claim <issue>
To remove later:  .fleet/bin/fleet uninstall   (clean, surgical reverse)
EOF
