#!/usr/bin/env python3
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
"""Validate the in-flight ownership manifest before launching parallel writers.
Pure Python3 (no node/bun). Exits 0 if claims own disjoint files, else 1.
  check-claims.py [manifest]
Lockfile coupling is env-driven: FLEET_DEP_MANIFEST (default **/package.json) +
FLEET_LOCKFILE (default empty = disabled).
"""
import json
import os
import re
import subprocess
import sys


def fail(msg):
    print(f"check-claims: {msg}", file=sys.stderr)
    sys.exit(1)


def git(args):
    return subprocess.run(["git"] + args, capture_output=True, text=True)


try:
    cd = git(["rev-parse", "--git-common-dir"]).stdout.strip()
    if not cd:
        raise RuntimeError("not a git repo")
    if not os.path.isabs(cd):
        top = git(["rev-parse", "--show-toplevel"]).stdout.strip()
        cd = os.path.join(top, cd)
    ROOT = re.sub(r"/\.git/?$", "", cd).rstrip("/") or "/"
except Exception:
    fail("not a git repository (or git unavailable on PATH).")

manifest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".claude", "agent-claims.json")
try:
    with open(manifest) as fh:
        m = json.load(fh)
except Exception as e:
    fail(f"cannot read/parse {manifest}: {e}")

tracked = [f for f in git(["-C", ROOT, "ls-files"]).stdout.split("\n") if f]
LOCKFILE = os.environ.get("FLEET_LOCKFILE", "")
DEP_MANIFEST = os.environ.get("FLEET_DEP_MANIFEST", "**/package.json")


def glob_to_re(g):
    out, i = "^", 0
    while i < len(g):
        if g[i:i + 2] == "**":
            out += ".*"; i += 2
            if i < len(g) and g[i] == "/":
                i += 1
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile(out + "$")


def matches(glob, path):
    return glob_to_re(glob).match(path) is not None


hot_files = m.get("hotFiles", [])
forbidden = m.get("forbidden", [])
branch_re = re.compile(m.get("branchPattern", r"^(agent|worktree|pr|lockfile|chore|feat|feature|fix)[/-][a-z0-9][a-z0-9._/-]*$"))
claims = [c for c in m.get("claims", []) if c.get("status") in ("claimed", "in-progress")]
errors = []


def is_forbidden(p):
    return any(matches(fb, p) for fb in forbidden)


def owned(c):
    s = set(c.get("newFiles", []))
    for g in c.get("globs", []):
        for f in tracked:
            if matches(g, f):
                s.add(f)
    return s


def base_prefix(g):
    mm = re.search(r"[*?\[\]{}]", g)
    head = g if not mm else g[:mm.start()]
    return head.rsplit("/", 1)[0] if "/" in head else ""


def nests(a, b):
    return a != "" and (a == b or b.startswith(a + "/"))


def has_wild(g):
    return bool(re.search(r"[*?\[\]{}]", g))


def touches_dep_manifest(c):
    if any(matches(DEP_MANIFEST, f) for f in c.get("newFiles", [])):
        return True
    if any(matches(DEP_MANIFEST, f) for f in owned(c)):
        return True
    return any(matches(DEP_MANIFEST, g) or g == DEP_MANIFEST for g in c.get("globs", []))


# 1) branch policy + forbidden-path targeting
for c in claims:
    if not c.get("agentId"):
        errors.append(f"claim missing agentId: {c}")
    if not c.get("branch") or not branch_re.match(c["branch"]):
        errors.append(f"claim '{c.get('agentId')}': branch '{c.get('branch')}' violates naming policy")
    for p in list(c.get("globs", [])) + list(c.get("newFiles", [])):
        if is_forbidden(p):
            errors.append(f"claim '{c.get('agentId')}': '{p}' targets a generated/forbidden path")
    for f in owned(c):
        if is_forbidden(f):
            errors.append(f"claim '{c.get('agentId')}': owns forbidden file '{f}'")

# 2) pairwise disjointness
od = [{"id": c.get("agentId"), "files": owned(c), "new": c.get("newFiles", []),
       "globs": c.get("globs", []), "wild": [g for g in c.get("globs", []) if has_wild(g)]} for c in claims]
for i in range(len(od)):
    for j in range(i + 1, len(od)):
        a, b = od[i], od[j]
        inter = a["files"] & b["files"]
        if inter:
            errors.append(f"OVERLAP '{a['id']}' ∩ '{b['id']}': {', '.join(sorted(inter)[:8])}")
            continue
        cross = next((f for f in a["new"] if any(matches(g, f) for g in b["globs"])), None) \
            or next((f for f in b["new"] if any(matches(g, f) for g in a["globs"])), None)
        if cross:
            errors.append(f"OVERLAP '{a['id']}' / '{b['id']}': future file '{cross}' inside the other's glob")
            continue
        if any(nests(base_prefix(ga), base_prefix(gb)) or nests(base_prefix(gb), base_prefix(ga))
               for ga in a["wild"] for gb in b["wild"]):
            errors.append(f"POTENTIAL OVERLAP '{a['id']}' / '{b['id']}': glob namespaces nest")

# 3) hot files + dep-manifest→lockfile coupling
hot_req = {}
for c in claims:
    for hf in c.get("hotFilesRequested", []):
        if hf not in hot_files:
            errors.append(f"claim '{c.get('agentId')}': '{hf}' is not a declared hotFile")
        hot_req.setdefault(hf, []).append(c.get("agentId"))
    if LOCKFILE and LOCKFILE in hot_files and touches_dep_manifest(c) \
            and LOCKFILE not in c.get("hotFilesRequested", []):
        hot_req.setdefault(LOCKFILE, []).append(c.get("agentId"))
for hf, owners in hot_req.items():
    u = sorted(set(owners))
    if len(u) > 1:
        errors.append(f"HOT-FILE CONTENTION on '{hf}': {', '.join(u)} (must be exactly one)")

if errors:
    print(f"check-claims: {len(errors)} violation(s) in {manifest}:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"check-claims: OK — {len(claims)} in-flight claim(s), disjoint ownership.")
