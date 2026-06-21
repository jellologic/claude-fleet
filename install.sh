#!/usr/bin/env bash
# Install claude-fleet into a target git repo (vendoring). Idempotent — re-run to update.
#   ./install.sh <target-repo-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
TARGET="${1:?usage: install.sh <target-repo-dir>}"
TARGET="$(cd "$TARGET" && pwd)"
git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: $TARGET is not a git repo" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required (guards + ownership gate)" >&2; exit 1; }

echo "Installing claude-fleet into $TARGET"

# 1) .fleet/ — lib, bin, githooks. Preserve an existing per-repo config.sh.
mkdir -p "$TARGET/.fleet"
cp -R "$SRC/fleet/lib" "$SRC/fleet/bin" "$SRC/fleet/githooks" "$TARGET/.fleet/"
chmod +x "$TARGET/.fleet/bin/"* "$TARGET/.fleet/githooks/"* 2>/dev/null || true
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
[ -f "$TARGET/WORKTREES.md" ]    || cp "$SRC/templates/WORKTREES.md" "$TARGET/WORKTREES.md"
[ -f "$TARGET/.worktreeinclude" ] || cp "$SRC/templates/worktreeinclude" "$TARGET/.worktreeinclude"

# 5) .gitignore entries (idempotent).
add_ignore() { grep -qxF "$1" "$TARGET/.gitignore" 2>/dev/null || echo "$1" >> "$TARGET/.gitignore"; }
touch "$TARGET/.gitignore"
for p in ".fleet/worktrees/" ".fleet/locks/" ".claude/worktrees/" ".claude/settings.local.json" ".claude/agent-claims.json"; do add_ignore "$p"; done

# 6) Append the CLAUDE.md fleet section once.
if ! grep -q "claude-fleet coordination" "$TARGET/CLAUDE.md" 2>/dev/null; then
  cat "$SRC/templates/CLAUDE.fleet.md" >> "$TARGET/CLAUDE.md"
  echo "  appended fleet section to CLAUDE.md"
fi

# 7) Wire the git hooks.
( cd "$TARGET" && sh .fleet/bin/install-hooks.sh )

cat <<EOF

claude-fleet installed. Next:
  1. Edit $TARGET/.fleet/config.sh  → set fleet_bootstrap + fleet_gate for your stack
     (see $HERE/examples/ for a Bun/Turborepo example)
  2. Create labels:  gh label create agent-ready; gh label create agent-working
  3. Commit the .fleet/ + .claude/ files to your main branch (and push)
  4. Protect main:   .fleet/bin/fleet ruleset
  5. Claim work:     .fleet/bin/fleet claim <issue>
EOF
