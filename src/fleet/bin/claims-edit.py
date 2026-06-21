#!/usr/bin/env python3
"""Add/remove a claim in the ownership manifest. Idempotent. Pure Python3.
  claims-edit.py <manifest> add <agentId> <branch> <globsCSV>
  claims-edit.py <manifest> remove <agentId>
"""
import json
import sys

if len(sys.argv) < 4:
    print("usage: claims-edit.py <manifest> add|remove <agentId> [branch] [globsCSV]", file=sys.stderr)
    sys.exit(2)
f, op, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
branch = sys.argv[4] if len(sys.argv) > 4 else ""
globs_csv = sys.argv[5] if len(sys.argv) > 5 else ""

with open(f) as fh:
    m = json.load(fh)
m["claims"] = [c for c in m.get("claims", []) if c.get("agentId") != agent_id]
if op == "add":
    m["claims"].append({
        "agentId": agent_id, "branch": branch, "status": "in-progress",
        "globs": [g.strip() for g in globs_csv.split(",") if g.strip()],
    })
elif op != "remove":
    print("unknown op: " + op, file=sys.stderr)
    sys.exit(2)
with open(f, "w") as fh:
    fh.write(json.dumps(m, indent=2) + "\n")
