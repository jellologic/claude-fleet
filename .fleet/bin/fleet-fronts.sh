#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# fronts: the WORK-FRONT GENERATOR. (#49)
#
#     run a machine ORACLE → collect its FAILURES → shard them into DISJOINT units → fan out.
#
# This is the one coordination primitive that BOTH flagship N-agent projects arrived at
# independently, and in one of them it is a *negative* result — the strongest evidence class
# available here.
#
#   Bun (~64 agents, 535k-line Zig→Rust port, bun.com/blog/bun-in-rust):
#     "`cargo check` wrote ≈16,000 errors to a file, GROUPED BY CRATE; the workflow divvied them
#      up among 64 Claudes."
#     => the compiler's error list WAS the work queue. The type-checker was the front generator.
#
#   Anthropic (16 agents, C compiler, anthropic.com/engineering/building-c-compiler):
#     "Unlike a test suite with hundreds of independent tests, compiling the Linux kernel is one
#      giant task. Every agent would hit the same bug, fix that bug, and then overwrite each
#      other's changes. Having 16 agents running didn't help because each was stuck solving the
#      same task. The fix was to use GCC as an online known-good compiler oracle to compare
#      against." … "This let each agent work in parallel, fixing different bugs in different files."
#     => the failure was a DECOMPOSITION failure, not a contract failure. What fixed it was an
#        oracle that SHATTERED one blocking failure into N independent ones.
#
# fleet already had the oracle (`fleet_gate`) and the fan-out (`fanout`) and NOTHING BETWEEN THEM:
# a human hand-wrote the manifest and GUESSED the decomposition. `fronts` is that missing middle.
#
# THE ORACLE DECIDES THE DECOMPOSITION — NOT A MODEL. A model asked "how would you split this
# work?" will always answer with N plausible-sounding units, because that is what the question
# rewards; it cannot know whether independent work exists. A compiler can. Everything below is
# deterministic code over the oracle's output: no `claude`, no network, no judgement.
#
# Hence the load-bearing behaviour: when every failure traces to ONE file/package/dir, `fronts`
# emits exactly ONE unit and says NOT DECOMPOSABLE — loudly. Manufacturing N units there IS the
# Anthropic kernel failure, and the whole point of running the oracle first is to see it coming
# BEFORE burning 16 agents on it.
#
# usage:
#   fleet fronts [--oracle '<cmd>'] [--shard-by file|package|dir] [-o <manifest.json>]
#                [--max-units N] [--task '<template>'] [--dry-run] [--require-parallel]
#   fleet fronts -o m.json && fleet delegate fanout m.json --jobs 4
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { echo "fleet fronts: not a git repository." >&2; exit 1; }

usage() {
  cat <<EOF
fleet fronts — run an oracle, shard its failures into PROVABLY DISJOINT work fronts, emit a
               fanout manifest. The oracle decides the decomposition; no model is consulted.

usage: fleet fronts [options]
  --oracle '<cmd>'     the machine oracle. Default: \`fleet_gate\` from .fleet/config.sh.
                       Anything that exits non-zero and names files works:
                         'cargo check'  'tsc --noEmit'  'pytest -q'  'bash -n src/*.sh'
                         'make 2>&1'    a differential run against a known-good reference binary
                       EXIT 0 = nothing failing = no work fronts (not an error).
  --shard-by <how>     file (default) — one unit per failing file
                       package        — group by \`fleet_pkg_for <file>\` (Bun's "grouped by crate")
                       dir            — group by the path's top-level directory
  -o <manifest.json>   write the manifest here. Default: stdout (so it pipes).
  --max-units N        at most N units. Excess fronts are MERGED (smallest first) and logged.
                       A failing file is NEVER dropped.
  --task '<template>'  override the derived task text. {files} {count} {messages} interpolate.
  --dry-run            print the plan + the decomposability verdict; write nothing.
  --require-parallel   exit 2 if the work is NOT decomposable (for CI). Default: exit 0 with a
                       single unit and a loud warning.

The emitted manifest is proven disjoint with check-claims.py — the same prover \`fanout\` runs —
BEFORE it is written. A generator whose own consumer would reject its output is worthless.
EOF
}

ORACLE=""; SHARD="file"; OUT=""; MAXU=0; TASK_TMPL=""; DRY=0; REQPAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --oracle)           [ $# -ge 2 ] || { echo "fleet fronts: --oracle needs a command" >&2; exit 2; }; ORACLE="$2"; shift 2 ;;
    --shard-by)         [ $# -ge 2 ] || { echo "fleet fronts: --shard-by needs file|package|dir" >&2; exit 2; }; SHARD="$2"; shift 2 ;;
    -o|--out|--output)  [ $# -ge 2 ] || { echo "fleet fronts: -o needs a path" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --max-units)        [ $# -ge 2 ] || { echo "fleet fronts: --max-units needs N" >&2; exit 2; }; MAXU="$2"; shift 2 ;;
    --task)             [ $# -ge 2 ] || { echo "fleet fronts: --task needs a template" >&2; exit 2; }; TASK_TMPL="$2"; shift 2 ;;
    --dry-run)          DRY=1; shift ;;
    --require-parallel) REQPAR=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "fleet fronts: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$SHARD" in
  file|package|dir) : ;;
  *) echo "fleet fronts: --shard-by must be one of: file, package, dir (got '$SHARD')" >&2; exit 2 ;;
esac
case "$MAXU" in
  ''|*[!0-9]*) echo "fleet fronts: --max-units must be a positive integer (got '$MAXU')" >&2; exit 2 ;;
esac   # 0 = unlimited (the default)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-fronts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Everything human-readable goes to STDERR, because STDOUT is the manifest when -o is absent.
say() { printf '%s\n' "$*" >&2; }

# ── 1. RUN THE ORACLE ────────────────────────────────────────────────────────────────────
# The oracle is the only thing in this program that gets an opinion about what is broken.
if [ -f "$ROOT/.fleet/config.sh" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/.fleet/config.sh"
elif [ -z "$ORACLE" ]; then
  say "fleet fronts: no .fleet/config.sh, so there is no \`fleet_gate\` to use as the default oracle."
  say "             Pass one explicitly:  fleet fronts --oracle 'cargo check'"
  exit 1
fi

ORACLE_DESC="$ORACLE"
if [ -z "$ORACLE" ]; then
  if [ "$(type -t fleet_gate 2>/dev/null || true)" != "function" ]; then
    say "fleet fronts: .fleet/config.sh does not define fleet_gate; pass --oracle '<cmd>'."
    exit 1
  fi
  ORACLE_DESC="fleet_gate"
fi

say "fleet fronts"
say "  oracle:   $ORACLE_DESC"
say "  shard-by: $SHARD"

RAW="$TMP/oracle.out"
orc=0
if [ -z "$ORACLE" ]; then
  ( cd "$ROOT" && fleet_gate ) > "$RAW" 2>&1 || orc=$?
else
  ( cd "$ROOT" && eval "$ORACLE" ) > "$RAW" 2>&1 || orc=$?
fi

if [ "$orc" -eq 0 ]; then
  # Not an error. An oracle with nothing to say is the state you want to be in.
  say "  oracle is green — no work fronts."
  say "  (Nothing failing means nothing to shard. This is success, not an error: exit 0, no manifest.)"
  exit 0
fi
say "  oracle exited $orc — parsing its failures"

# ── 2. PARSE FAILURES → REPO-RELATIVE, GIT-TRACKED FILE PATHS ────────────────────────────
python3 - "$RAW" "$ROOT" "$TMP/failures.json" "$TMP/files.txt" <<'PY' || exit 1
import json, os, re, subprocess, sys

raw, root, out_json, out_files = sys.argv[1:5]

tracked = set(
    p for p in subprocess.run(["git", "-C", root, "ls-files"],
                              capture_output=True, text=True).stdout.split("\n") if p
)

# Compiler/linter/runtime failure formats. Every one of these was picked because a real oracle
# a fleet user would plausibly run emits it. Anything NOT matched here is simply not a failure
# we can attribute to a file — and an unattributable failure cannot become a work front.
PATTERNS = [
    # tsc:            src/a.ts(12,5): error TS2322: Type 'x' is not assignable to 'y'.
    (re.compile(r'^\s*(?P<f>[^\s(][^()]*?)\((?P<l>\d+),(?P<c>\d+)\):\s*(?P<m>.*)$'), 'tsc'),
    # python:         File "src/a.py", line 12, in f
    (re.compile(r'^\s*File "(?P<f>[^"]+)", line (?P<l>\d+)(?P<m>.*)$'), 'python'),
    # rustc 2nd form: --> src/a.rs:12:5
    (re.compile(r'^\s*-->\s+(?P<f>\S+?):(?P<l>\d+):(?P<c>\d+)\s*$'), 'rustc-arrow'),
    # bash -n:        src/a.sh: line 12: syntax error near unexpected token
    (re.compile(r'^\s*(?P<f>[^\s:][^:]*?): line (?P<l>\d+): (?P<m>.*)$'), 'shell'),
    # rustc/gcc/clang/eslint/shellcheck:
    #                 src/a.c:12:5: error: expected ';'      /      src/a.c:12: warning: …
    (re.compile(r'^\s*(?P<f>[^\s:][^:]*?):(?P<l>\d+)(?::(?P<c>\d+))?:\s*(?P<m>.+)$'), 'posix'),
]

# rustc/cargo print the message on the line BEFORE the `--> file:line:col`. Carry it forward so a
# `-->` front still gets a human-readable representative message.
PENDING_RE = re.compile(r'^\s*(?:error|warning|note)\b.*$', re.I)

def relativise(p):
    p = p.strip().strip('"').strip("'")
    if not p:
        return None
    if os.path.isabs(p):
        try:
            rp = os.path.relpath(os.path.realpath(p), os.path.realpath(root))
        except Exception:
            return None
        if rp.startswith(".."):
            return None          # outside the repo: a system header, /tmp scratch, a toolchain path
        p = rp
    while p.startswith("./"):
        p = p[2:]
    return p or None

order, fails = [], {}
pending = ""
for line in open(raw, errors="replace").read().split("\n"):
    hit = None
    for rx, kind in PATTERNS:
        m = rx.match(line)
        if m:
            hit = (m, kind)
            break
    if not hit:
        if PENDING_RE.match(line):
            pending = line.strip()
        continue
    m, kind = hit
    p = relativise(m.group("f"))
    # THE HARD FILTER. A path only becomes a work front if git actually tracks it. This is what
    # kills absolute system paths (/usr/include/stdio.h), /tmp scratch files, toolchain internals,
    # and any hallucinated path an LLM-ish oracle might emit. No tracked file, no unit.
    if not p or p not in tracked:
        pending = ""
        continue
    msg = (m.groupdict().get("m") or "").strip().strip(",").strip()
    if kind == "rustc-arrow" and pending:
        msg = pending          # rustc prints the diagnostic on the line BEFORE the `--> file:l:c`
    if kind == "python":
        msg = line.strip()     # a traceback frame is only meaningful whole
    if not msg:
        msg = line.strip()
    if p not in fails:
        fails[p] = {"count": 0, "messages": []}
        order.append(p)
    fails[p]["count"] += 1
    if len(fails[p]["messages"]) < 3 and msg not in fails[p]["messages"]:
        fails[p]["messages"].append(msg[:200])
    pending = ""

with open(out_json, "w") as fh:
    json.dump({"order": order, "files": fails}, fh)
with open(out_files, "w") as fh:
    fh.write("".join(p + "\n" for p in order))
PY

NFILES="$(python3 -c 'import sys;print(sum(1 for l in open(sys.argv[1]) if l.strip()))' "$TMP/files.txt")"
if [ "$NFILES" -eq 0 ]; then
  say ""
  say "  the oracle FAILED (exit $orc) but not one of its failures could be attributed to a"
  say "  git-tracked file in this repo. Nothing here can become a work front."
  say "  Either the oracle's output format is not one fronts parses (rustc/gcc/clang/eslint/"
  say "  shellcheck/tsc/python-traceback/bash), or every path it named is untracked (a system"
  say "  header, a /tmp scratch file, a build artefact). Its output was:"
  sed -n '1,20p' "$RAW" | sed 's/^/    | /' >&2
  exit 1
fi
say "  failures attributed to $NFILES tracked file(s)"

# ── 3. SHARD ─────────────────────────────────────────────────────────────────────────────
# `fleet_pkg_for` is a SHELL function from the repo's own config, so the package key has to be
# computed out here and handed to the sharder. (Bun: "grouped by crate".)
: > "$TMP/pkgmap.tsv"
if [ "$SHARD" = "package" ]; then
  if [ "$(type -t fleet_pkg_for 2>/dev/null || true)" != "function" ]; then
    say "fleet fronts: --shard-by package needs \`fleet_pkg_for\` in .fleet/config.sh"
    exit 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    pk="$( cd "$ROOT" && fleet_pkg_for "$f" 2>/dev/null || true )"
    printf '%s\t%s\n' "$f" "$pk" >> "$TMP/pkgmap.tsv"
  done < "$TMP/files.txt"
fi

python3 - "$TMP/failures.json" "$TMP/pkgmap.tsv" "$SHARD" "$MAXU" "$TASK_TMPL" "$ORACLE_DESC" \
          "$ROOT" "$TMP/manifest.json" "$TMP/claims.json" "$TMP/verdict" <<'PY' || exit 1
import json, os, re, sys

(fj, pkgmap, shard, maxu, tmpl, oracle, root, out_manifest, out_claims, out_verdict) = sys.argv[1:11]
maxu = int(maxu)

d = json.load(open(fj))
order, files = d["order"], d["files"]

pkg = {}
if os.path.exists(pkgmap):
    for line in open(pkgmap):
        line = line.rstrip("\n")
        if not line:
            continue
        f, _, p = line.partition("\t")
        pkg[f] = p.strip()

def key_for(p):
    if shard == "file":
        return p
    if shard == "dir":
        return p.split("/", 1)[0] if "/" in p else ""
    k = pkg.get(p, "")
    return k.strip("/")

# group key -> ordered file list (insertion-ordered = deterministic in the oracle's own order)
korder, groups = [], {}
for p in order:
    k = key_for(p)
    if k not in groups:
        groups[k] = []
        korder.append(k)
    groups[k].append(p)

# `package`/`dir` fronts own a GLOB (the whole crate/dir — a fix may need a sibling file), so two
# keys where one NESTS inside the other are not disjoint and check-claims would rightly refuse
# them. Merge the nested key into its ancestor rather than emit a manifest our own prover rejects.
merge_log = []
if shard in ("package", "dir"):
    isdir = lambda k: bool(k) and os.path.isdir(os.path.join(root, k))
    for k in list(korder):
        if not isdir(k):
            continue
        anc = next((a for a in korder
                    if isdir(a) and a != k and k.startswith(a + "/")), None)
        if anc is not None and k in groups:
            merge_log.append(f"nested key '{k}' folded into '{anc}' (a glob under a glob is not disjoint)")
            groups[anc].extend(groups.pop(k))
            korder.remove(k)

def slug(s, fallback):
    s = (s or fallback).lower()
    s = re.sub(r"[^a-z0-9._-]+", "-", s).strip("-._")
    if not s or not re.match(r"^[a-z0-9]", s):
        s = "unit-" + s
    return s

def owns_for(k, fs):
    # A package/dir front owns the WHOLE subtree — fixing a crate's errors may mean touching a
    # sibling file the oracle never named. But only when the key really IS a directory: a
    # `fleet_pkg_for` that returns a file path (or a key with no directory at all) must own the
    # exact files, never a glob that matches nothing and claims a subtree that does not exist.
    if shard == "file" or k == "" or not os.path.isdir(os.path.join(root, k)):
        return list(fs)
    return [k.rstrip("/") + "/**"]

fronts, used = [], set()
for k in korder:
    fs = groups[k]
    base = slug(k, "root")
    uid, n = base, 1
    while uid in used:
        n += 1
        uid = f"{base}-{n}"
    used.add(uid)
    fronts.append({
        "id": uid,
        "key": k,
        "files": fs,
        "owns": owns_for(k, fs),
        "count": sum(files[f]["count"] for f in fs),
        "messages": [m for f in fs for m in files[f]["messages"]][:5],
    })

pre_merge = len(fronts)

# ── --max-units: MERGE, never DROP ────────────────────────────────────────────────────────
# Dropping a failing file would mean the oracle is still red after every unit lands, and nobody
# would know why. Merging is strictly worse than more parallelism but it is CORRECT.
if maxu and len(fronts) > maxu:
    ranked = sorted(fronts, key=lambda u: (-u["count"], u["id"]))   # biggest fronts keep their own unit
    keep, tail = ranked[:maxu - 1], ranked[maxu - 1:]
    tail = sorted(tail, key=lambda u: (u["count"], u["id"]))
    merged = {
        "id": "merged-tail",
        "key": "",
        "files": [f for u in tail for f in u["files"]],
        "owns": [g for u in tail for g in u["owns"]],
        "count": sum(u["count"] for u in tail),
        "messages": [m for u in tail for m in u["messages"]][:5],
    }
    while merged["id"] in used:
        merged["id"] += "-x"
    merge_log.append(
        "--max-units %d: MERGED the %d smallest fronts (%s) into a single unit '%s' carrying "
        "%d failure(s) across %d file(s). Nothing was dropped."
        % (maxu, len(tail), ", ".join(u["id"] for u in tail), merged["id"],
           merged["count"], len(merged["files"])))
    fronts = sorted(keep, key=lambda u: u["id"]) + [merged]

DEFAULT_TMPL = """The oracle `{oracle}` reports {count} failure(s) in the file(s) you own:
{files}

Representative failures:
{messages}

Fix them. Re-run the oracle to confirm they are gone.

Do NOT edit any file outside your `owns` set. Other agents are concurrently fixing the OTHER
files this same oracle run flagged; if you touch their files you will overwrite their work. If
the real fix genuinely lives outside your paths, STOP and say so in your final message — that
means the failures are not independent, and this manifest is wrong."""

for u in fronts:
    filelist = "\n".join("  - " + f for f in u["files"])
    msgs = "\n".join("  - " + m for m in u["messages"]) or "  (none captured)"
    t = tmpl if tmpl else DEFAULT_TMPL
    u["task"] = (t.replace("{files}", filelist)
                  .replace("{count}", str(u["count"]))
                  .replace("{messages}", msgs)
                  .replace("{oracle}", oracle))

manifest = {
    "$schema": "./fanout.schema.json",
    "_comment": ("generated by `fleet fronts` (#49). The ORACLE decided this decomposition, not a "
                 "model: `%s` was run, its failures were attributed to git-tracked files, and the "
                 "files were sharded by %s. Bun did this with `cargo check` errors 'grouped by "
                 "crate'; Anthropic's 16-agent kernel run failed precisely because it had no such "
                 "oracle and every agent was 'stuck solving the same task'." % (oracle, shard)),
    "units": [{"id": u["id"], "owns": u["owns"], "task": u["task"]} for u in fronts],
}
with open(out_manifest, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")

# ── SELF-PROOF: synthesise exactly the claims manifest `fanout` will, so check-claims.py sees
# the identical thing. If our own consumer would refuse this, it is a bug in fronts, not advice.
WILD = re.compile(r"[*?\[\]{}]")
policy = {}
for cand in (os.path.join(root, ".claude", "agent-claims.json"),
             os.path.join(root, ".claude", "agent-claims.template.json")):
    try:
        policy = json.load(open(cand))
        break
    except Exception:
        continue
claims = {
    "branchPattern": policy.get(
        "branchPattern",
        r"^(agent|worktree|pr|lockfile|chore|feat|feature|fix)[/-][a-z0-9][a-z0-9._/-]*$"),
    "hotFiles": policy.get("hotFiles", []),
    "forbidden": policy.get("forbidden", []),
    "claims": [{
        "agentId": u["id"],
        "branch": "agent/fronts/" + u["id"],
        "status": "claimed",
        "globs": u["owns"],
        "newFiles": [g for g in u["owns"] if not WILD.search(g)],
    } for u in fronts],
}
with open(out_claims, "w") as fh:
    json.dump(claims, fh, indent=2)

# ── the plan, on stderr (stdout is the manifest) ─────────────────────────────────────────
e = sys.stderr
print("", file=e)
print("  work fronts (%d):" % len(fronts), file=e)
for u in fronts:
    print("    %-24s %3d failure(s)  %d file(s)  owns: %s"
          % (u["id"], u["count"], len(u["files"]), ", ".join(u["owns"][:3])
             + (" …" if len(u["owns"]) > 3 else "")), file=e)
for m in merge_log:
    print("  merge: " + m, file=e)

total_files = sum(len(u["files"]) for u in fronts)
with open(out_verdict, "w") as fh:
    fh.write("%d\n%d\n%d\n%s\n%d\n" % (
        len(fronts), pre_merge, sum(u["count"] for u in fronts),
        fronts[0]["key"] or (fronts[0]["files"][0] if fronts[0]["files"] else "?"),
        total_files))
PY

NUNITS="$(sed -n 1p "$TMP/verdict")"
PREMERGE="$(sed -n 2p "$TMP/verdict")"
NFAIL="$(sed -n 3p "$TMP/verdict")"
TARGET="$(sed -n 4p "$TMP/verdict")"

# ── 5. SELF-PROVE THE OUTPUT — run OUR manifest through the prover `fanout` will run ─────
say ""
say "  --- disjointness self-proof (check-claims.py — the same prover \`fanout\` runs)"
cc=0
( cd "$ROOT" && python3 "$HERE/check-claims.py" "$TMP/claims.json" ) > "$TMP/cc.out" 2>&1 || cc=$?
sed 's/^/  /' "$TMP/cc.out" >&2
if [ "$cc" != "0" ]; then
  say ""
  say "  fleet fronts: BUG — the manifest I just generated is NOT provably disjoint, so \`fanout\`"
  say "  would REFUSE it (exit 2). A generator that emits a manifest its own consumer rejects is"
  say "  worthless. Nothing was written. Please file this at github.com/jellologic/claude-fleet."
  exit 1
fi

# ── 4. REFUSE TO MANUFACTURE FAKE PARALLELISM ────────────────────────────────────────────
if [ "$PREMERGE" -eq 1 ]; then
  say ""
  say "  ############################################################################"
  say "  NOT DECOMPOSABLE: all $NFAIL failure(s) trace to $TARGET."
  say "  This is ONE work front, not N. Fanning out here is the Anthropic kernel failure:"
  say "  '16 agents ... each was stuck solving the same task' — 'every agent would hit the"
  say "  same bug, fix that bug, and then overwrite each other's changes'."
  say ""
  say "  Run it as a SINGLE unit, or find an oracle that SHATTERS this failure into"
  say "  independent ones. A differential oracle against a known-good reference is what"
  say "  fixed it there: 'The fix was to use GCC as an online known-good compiler oracle to"
  say "  compare against ... This let each agent work in parallel, fixing different bugs in"
  say "  different files.'"
  say ""
  say "  The manifest below contains EXACTLY ONE unit. That is not a bug; it is the answer."
  say "  ############################################################################"
  if [ "$REQPAR" -eq 1 ]; then
    say "  --require-parallel: the work is not decomposable → exit 2."
    exit 2
  fi
fi

# ── 7. --dry-run: the plan, and nothing else ─────────────────────────────────────────────
if [ "$DRY" -eq 1 ]; then
  say ""
  say "  verdict: $NUNITS unit(s) from $NFAIL failure(s) — $([ "$PREMERGE" -gt 1 ] && echo "DECOMPOSABLE" || echo "NOT DECOMPOSABLE")"
  say "  --dry-run: nothing written."
  exit 0
fi

# ── 8. EMIT ──────────────────────────────────────────────────────────────────────────────
if [ -n "$OUT" ]; then
  cat "$TMP/manifest.json" > "$OUT"
  say ""
  say "  wrote $OUT ($NUNITS unit(s), $NFAIL failure(s))"
  say "  next:  fleet delegate fanout $OUT --jobs $NUNITS"
else
  cat "$TMP/manifest.json"
  say ""
  say "  emitted $NUNITS unit(s) on stdout ($NFAIL failure(s))"
fi
exit 0
