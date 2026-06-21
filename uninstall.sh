#!/usr/bin/env bash
# claude-fleet — bug in this file? SELF-REPORT before fixing: understand, check/file issues at github.com/jellologic/claude-fleet, propose fix — ALL with HUMAN APPROVAL. See SELF-REPORT.md
#
# Cleanly REMOVE claude-fleet from a project (surgical reverse of install.sh).
# Run from the target repo:  sh .fleet/uninstall.sh   (or: .fleet/bin/fleet uninstall)
#   --force   also remove active fleet worktrees (otherwise it refuses and lists them)
set -euo pipefail

# Relocate out of .fleet/ so we can delete that dir from under ourselves safely.
if [ "${FLEET_UNINSTALL_RELOCATED:-0}" != 1 ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$ROOT" ] || { echo "ERROR: run inside the target git repo" >&2; exit 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-fleet-uninstall.XXXXXX")"
  cp "$0" "$tmp"
  FLEET_UNINSTALL_RELOCATED=1 FLEET_TARGET_ROOT="$ROOT" exec bash "$tmp" "$@"
fi

ROOT="${FLEET_TARGET_ROOT:?}"
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
echo "Removing claude-fleet from $ROOT"

# 1) Active fleet worktrees — refuse unless --force (don't nuke in-progress work).
active="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep '/\.fleet/worktrees/' || true)"
if [ -n "$active" ]; then
  if [ "$FORCE" != 1 ]; then
    echo "Refusing: active fleet worktrees exist —" >&2; printf '  %s\n' $active >&2
    echo "Reap them (fleet wt reap <name>) or re-run: sh .fleet/uninstall.sh --force" >&2; exit 1
  fi
  printf '%s\n' "$active" | while read -r w; do [ -n "$w" ] && git -C "$ROOT" worktree remove --force "$w" 2>/dev/null || true; done
  git -C "$ROOT" worktree prune
fi

# 2) Unset core.hooksPath only if WE set it.
if [ "$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)" = ".fleet/githooks" ]; then
  git -C "$ROOT" config --unset core.hooksPath && echo "  unset core.hooksPath"
fi

# 3) Unmerge only fleet's hooks from settings.json.
[ -f "$ROOT/.fleet/unmerge-settings.py" ] && command -v python3 >/dev/null && \
  python3 "$ROOT/.fleet/unmerge-settings.py" "$ROOT/.claude/settings.json" | sed 's/^/  /' || true

# 4) Remove fleet-owned .claude files (leave the user's own hooks/commands/settings).
rm -f "$ROOT/.claude/hooks/claude-worktree-guard.py" "$ROOT/.claude/hooks/claude-coord-guard.py" \
      "$ROOT/.claude/hooks/coord-session-start.sh" \
      "$ROOT/.claude/commands/claim.md" "$ROOT/.claude/commands/release.md" \
      "$ROOT/.claude/commands/fleet-update.md" "$ROOT/.claude/commands/fleet-uninstall.md" \
      "$ROOT/.claude/agent-claims.template.json" "$ROOT/.claude/agent-claims.schema.json" \
      "$ROOT/.claude/agent-claims.json"
rmdir "$ROOT/.claude/hooks" "$ROOT/.claude/commands" 2>/dev/null || true

# 5) Strip the managed marker blocks from .gitignore and CLAUDE.md.
[ -f "$ROOT/.gitignore" ] && { sed '/# >>> claude-fleet (managed) >>>/,/# <<< claude-fleet (managed) <<</d' "$ROOT/.gitignore" > "$ROOT/.gitignore.tmp" && mv "$ROOT/.gitignore.tmp" "$ROOT/.gitignore"; }
[ -f "$ROOT/CLAUDE.md" ] && { sed '/<!-- >>> claude-fleet (managed) >>> -->/,/<!-- <<< claude-fleet (managed) <<< -->/d' "$ROOT/CLAUDE.md" > "$ROOT/CLAUDE.md.tmp" && mv "$ROOT/CLAUDE.md.tmp" "$ROOT/CLAUDE.md"; }

# 6) Remove fleet-owned root file(s).
rm -f "$ROOT/WORKTREES.md"

# 7) Remove the whole .fleet/ tree last (this script is a /tmp copy, so it's safe).
rm -rf "$ROOT/.fleet"

echo "claude-fleet removed. Review 'git status' and commit."
echo "Left in place (generic / possibly yours): .worktreeinclude — delete if unused."
