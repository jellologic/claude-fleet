#!/usr/bin/env python3
# claude-fleet — bug in this file? SELF-REPORT before fixing: understand, check/file issues at github.com/jellologic/claude-fleet, propose fix — ALL with HUMAN APPROVAL. See SELF-REPORT.md
"""Remove ONLY claude-fleet's hook entries from a target .claude/settings.json
(matched by the fleet guard script names). Non-destructive to other hooks/keys.
Removes the file if it ends up empty. Idempotent.
  unmerge-settings.py <target-settings.json>
"""
import json
import os
import sys

f = sys.argv[1] if len(sys.argv) > 1 else ""
if not f or not os.path.exists(f):
    sys.exit(0)
try:
    with open(f) as fh:
        s = json.load(fh)
except Exception:
    sys.exit(0)

MARKERS = ("claude-worktree-guard.py", "claude-coord-guard.py", "coord-session-start.sh")
hooks = s.get("hooks", {})


def is_fleet(entry):
    return any(any(m in (h.get("command", "") or "") for m in MARKERS) for h in entry.get("hooks", []))


for ev in list(hooks.keys()):
    hooks[ev] = [e for e in hooks[ev] if not is_fleet(e)]
    if not hooks[ev]:
        del hooks[ev]
if not hooks:
    s.pop("hooks", None)

if s:
    with open(f, "w") as fh:
        fh.write(json.dumps(s, indent=2) + "\n")
    print(f"removed claude-fleet hooks from {f}")
else:
    os.remove(f)
    print(f"removed {f} (was fleet-only)")
