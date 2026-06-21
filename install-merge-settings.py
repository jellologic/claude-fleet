#!/usr/bin/env python3
"""Merge claude-fleet hook entries into a target .claude/settings.json without
duplicating (matches on the hooks' command strings). Creates the file if absent.
  install-merge-settings.py <fleet-settings.json> <target-settings.json>
"""
import json
import os
import sys

fleet_f, target_f = sys.argv[1], sys.argv[2]
with open(fleet_f) as fh:
    fleet = json.load(fh)
target = {}
if os.path.exists(target_f):
    try:
        with open(target_f) as fh:
            target = json.load(fh)
    except Exception:
        target = {}
target.setdefault("hooks", {})


def cmds(entry):
    return tuple(h.get("command") for h in entry.get("hooks", []))


for event, entries in fleet.get("hooks", {}).items():
    cur = target["hooks"].setdefault(event, [])
    existing = {cmds(e) for e in cur}
    for e in entries:
        if cmds(e) not in existing:
            cur.append(e)
with open(target_f, "w") as fh:
    fh.write(json.dumps(target, indent=2) + "\n")
print(f"merged claude-fleet hooks into {target_f}")
