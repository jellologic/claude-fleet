#!/usr/bin/env python3
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
"""Validate the in-flight ownership manifest before launching parallel writers.
Pure Python3 (no node/bun). Exits 0 if claims own disjoint files, else 1 (2 for a PORT violation).
  check-claims.py [manifest]        # a claims manifest, OR a `fanout` manifest ({"units":[…]})
Lockfile coupling is env-driven: FLEET_DEP_MANIFEST (default **/package.json) +
FLEET_LOCKFILE (default empty = disabled).

── PORTS: from disjoint FILES to disjoint INTERFACES (#48) ──────────────────────────────
The disjointness proof below proves the units own non-overlapping FILES. It proves nothing
about their INTERFACES: two units can own disjoint paths and still build to incompatible
contracts, and the collision only surfaces at integration. Anthropic's `current_tasks/`
file lock was fully in force when their 16 agents still hit "every agent would hit the same
bug, fix that bug, and then overwrite each other's changes … each was stuck solving the same
task" — file-level locking enforces distinct task NAMES, not distinct semantic WORK.

So a unit may declare `provides` / `consumes` port ids, resolved against .fleet/ports.json
(FLEET_PORTS overrides), and this file gains three STATIC, cheaply-decidable proofs:
  (a) every `consumes` resolves to EXACTLY ONE `provides` — in this manifest, or to a port
      whose ARTIFACT already exists on the base branch (git HEAD). No dangling; and two
      units declaring the same `provides` is a REFUSAL (they would implement the same port
      twice — Anthropic's duplicate-code tax);
  (b) the provides→consumes DAG is ACYCLIC. A cycle means the units are NOT semantically
      independent, and the manifest is refused exactly as an overlapping glob is;
  (c) a port ARTIFACT is READ-ONLY to every unit that does not `provides` it — a unit may not
      even OWN it. Changing a frozen port takes an explicit `fleet spec amend`.
The artifact is a TYPED, machine-checkable file (.d.ts / .pyi / trait / protobuf / OpenAPI),
never prose: every N-agent project that worked froze something a machine could check.
A manifest with no `provides`/`consumes` behaves EXACTLY as it did before this existed.
"""
import json
import os
import re
import subprocess
import sys

PORT_EXIT = 2   # a PORT violation exits 2 (an ownership violation still exits 1)


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

DEFAULT_BRANCH_RE = r"^(agent|worktree|pr|lockfile|chore|feat|feature|fix)[/-][a-z0-9][a-z0-9._/-]*$"
WILD_RE = re.compile(r"[*?\[\]{}]")


def fanout_to_claims(fm):
    """Accept a `fanout` manifest ({"units":[…]}) anywhere a claims manifest is accepted, so
    `fleet spec check <fanout.json>` runs the IDENTICAL prover `fanout` runs. Ownership POLICY
    (forbidden / hotFiles / branchPattern) still comes from the repo's own claims manifest."""
    policy = {}
    for cand in (os.path.join(ROOT, ".claude", "agent-claims.json"),
                 os.path.join(ROOT, ".claude", "agent-claims.template.json")):
        try:
            with open(cand) as fh:
                policy = json.load(fh)
            break
        except Exception:
            continue
    out = []
    for k, u in enumerate(fm.get("units") or []):
        if not isinstance(u, dict):
            fail(f"{manifest}: units[{k}] is not an object")
        norm = []
        for g in (u.get("owns") or []):
            # A bare directory means its whole subtree — spelling it as a glob is what lets the
            # prover SEE the nesting (as `fanout` itself does when it synthesises its claims).
            if isinstance(g, str) and g and not WILD_RE.search(g) \
                    and (g.endswith("/") or os.path.isdir(os.path.join(ROOT, g))):
                g = g.rstrip("/") + "/**"
            norm.append(g)
        out.append({
            "agentId": u.get("id"),
            "branch": u.get("branch") or f"agent/fanout/{u.get('id')}",
            "status": "claimed",
            "globs": norm,
            "newFiles": [g for g in norm if isinstance(g, str) and not WILD_RE.search(g)],
            "provides": u.get("provides", []),
            "consumes": u.get("consumes", []),
        })
    return {"branchPattern": policy.get("branchPattern", DEFAULT_BRANCH_RE),
            "hotFiles": policy.get("hotFiles", []),
            "forbidden": policy.get("forbidden", []),
            "claims": out}


if isinstance(m, dict) and "units" in m and "claims" not in m:
    m = fanout_to_claims(m)

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

# 4) PORTS — the CONTRACT layer (#48). Everything below is a NO-OP for a manifest that
#    declares no `provides`/`consumes` and a repo with no .fleet/ports.json: the three proofs
#    are STATIC and cheaply decidable, and they REFUSE the manifest (exit 2) rather than let
#    two agents negotiate an interface at integration time, which is where it is most expensive.
PORTS_FILE = os.environ.get("FLEET_PORTS") or os.path.join(ROOT, ".fleet", "ports.json")
registry = {}
if os.path.exists(PORTS_FILE):
    try:
        with open(PORTS_FILE) as fh:
            pj = json.load(fh)
    except Exception as e:
        fail(f"cannot read/parse the port registry {PORTS_FILE}: {e}")
    if not isinstance(pj, dict) or not isinstance(pj.get("ports", {}), dict):
        fail(f"{PORTS_FILE}: top level must be an object with a \"ports\" object")
    registry = pj.get("ports", {})
    for pid, e in registry.items():
        if not isinstance(e, dict) or not isinstance(e.get("artifact"), str) or not e["artifact"]:
            fail(f"{PORTS_FILE}: port '{pid}' must be an object with a non-empty \"artifact\" "
                 f"(the FROZEN, machine-checkable interface file — a .d.ts/.pyi/trait/protobuf/"
                 f"OpenAPI, never prose)")

port_errors = []


def artifact_of(pid):
    e = registry.get(pid)
    return e.get("artifact") if isinstance(e, dict) else None


# Files present on the BASE BRANCH. A `consumes` may resolve to a port that ALREADY EXISTS
# there (frozen by an earlier run, or hand-written and committed) with no unit providing it —
# that is the normal steady state, not a dangling reference.
head = git(["-C", ROOT, "ls-tree", "-r", "--name-only", "HEAD"])
base_files = set(f for f in head.stdout.split("\n") if f) if head.returncode == 0 else set(tracked)


def port_list(c, key):
    v = c.get(key, [])
    if not isinstance(v, list) or not all(isinstance(p, str) and p for p in v):
        port_errors.append(f"claim '{c.get('agentId')}': \"{key}\" must be an array of port ids")
        return []
    return v


providers, consumers = {}, {}
for c in claims:
    cid = c.get("agentId")
    for pid in port_list(c, "provides"):
        providers.setdefault(pid, []).append(cid)
    for pid in port_list(c, "consumes"):
        consumers.setdefault(pid, []).append(cid)

for pid in sorted(set(list(providers) + list(consumers))):
    if pid not in registry:
        port_errors.append(
            f"UNDECLARED PORT '{pid}': not in {os.path.relpath(PORTS_FILE, ROOT)}. A port is a "
            f"FROZEN, MACHINE-CHECKABLE artifact (a .d.ts/.pyi/trait/protobuf/OpenAPI file), never "
            f"prose — declare it (`fleet spec init`) and commit the artifact before fanning out.")

# (a) NO DUPLICATE PROVIDERS. Two units implementing the same port is the duplicate-code tax
#     Anthropic paid: "LLM-written code frequently re-implements existing functionality, so I
#     tasked one agent with coalescing any duplicate code it found."
for pid, who in sorted(providers.items()):
    u = sorted(set(who))
    if len(u) > 1:
        port_errors.append(
            f"DUPLICATE PROVIDER for '{pid}': {', '.join(u)} (must be EXACTLY ONE). Two units "
            f"would silently implement the same interface twice; the divergence surfaces at "
            f"integration, and the duplicate has to be coalesced by hand afterwards.")

# (a) NO DANGLING CONSUMES.
for pid, who in sorted(consumers.items()):
    if pid in providers:
        continue
    art = artifact_of(pid)
    if art and art in base_files:
        continue          # already frozen on the base branch — the normal, healthy case
    port_errors.append(
        f"DANGLING PORT '{pid}': consumed by {', '.join(sorted(set(who)))}, but NO unit provides it "
        f"and its artifact "
        + (f"'{art}' does not exist on the base branch (git HEAD)" if art else "is unknown")
        + ". A consumer with no provider has no contract to build against — it will invent one, and "
          "the mismatch will only surface at integration.")

# (b) THE provides→consumes DAG MUST BE ACYCLIC. A cycle means the units are NOT semantically
#     independent — no ordering of them exists in which each can be built against a frozen
#     interface. Refuse the manifest, exactly as an overlapping glob is refused.
edges = {}   # consumer -> [(provider, port)] : "consumer DEPENDS ON provider"
for pid, who in consumers.items():
    for cid in who:
        for prov in providers.get(pid, []):
            edges.setdefault(cid, []).append((prov, pid))

cycles, state, stack = [], {}, []


def walk(n):
    state[n] = 1
    stack.append(n)
    for nxt, pid in edges.get(n, []):
        if state.get(nxt) == 1:                       # back-edge → cycle
            i = stack.index(nxt)
            path = stack[i:] + [nxt]
            ring = " → ".join(path)
            ports = []
            for a, b in zip(path, path[1:]):
                ports += [p for (t, p) in edges.get(a, []) if t == b]
            sig = tuple(sorted(set(path)))
            if sig not in [x[0] for x in cycles]:
                cycles.append((sig, ring, sorted(set(ports))))
        elif not state.get(nxt):
            walk(nxt)
    stack.pop()
    state[n] = 2


for c in claims:
    if not state.get(c.get("agentId")):
        walk(c.get("agentId"))

for _sig, ring, ports in cycles:
    port_errors.append(
        f"CYCLE in the provides→consumes graph: {ring} (via {', '.join(ports)}). These units are "
        f"NOT semantically independent: each needs the other's interface before it can build its "
        f"own. There is no order in which they can be fanned out. Break the cycle — extract the "
        f"shared port into its own unit, or merge them into one.")

# (c) A FROZEN PORT ARTIFACT IS READ-ONLY to every unit that does not `provides` it. Enforced
#     here — in the same place `owns` is enforced — so a unit cannot even CLAIM the artifact.
#     (`fleet spec check` enforces the same invariant against the unit's DIFF, inside fleet_gate.)
for c in claims:
    cid = c.get("agentId")
    mine = set(c.get("provides", []) if isinstance(c.get("provides"), list) else [])
    owns_all = owned(c) | set(c.get("newFiles", []))
    for pid, e in sorted(registry.items()):
        art = artifact_of(pid)
        if not art or pid in mine:
            continue
        if art in owns_all or any(matches(g, art) for g in c.get("globs", [])):
            port_errors.append(
                f"FROZEN PORT '{art}' ({pid}) is inside the `owns` set of '{cid}', which does NOT "
                f"provide it. A port artifact is READ-ONLY to every unit but its provider: a unit "
                f"that can rewrite the contract it was handed can drift it silently, and every "
                f"other unit is still building against the old one. To change it, run "
                f"`fleet spec amend {pid}` on the base branch — which re-runs every consumer.")

if errors or port_errors:
    n = len(errors) + len(port_errors)
    print(f"check-claims: {n} violation(s) in {manifest}:", file=sys.stderr)
    for e in errors + port_errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(PORT_EXIT if port_errors else 1)

np = sum(len(c.get("provides", []) or []) for c in claims)
nc = sum(len(c.get("consumes", []) or []) for c in claims)
extra = f", {np} provides / {nc} consumes — ACYCLIC, no dangling, no duplicate providers" if (np or nc) else ""
print(f"check-claims: OK — {len(claims)} in-flight claim(s), disjoint ownership{extra}.")
