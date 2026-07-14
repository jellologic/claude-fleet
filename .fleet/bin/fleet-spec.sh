#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# spec: the CONTRACT / PORT layer. (#48)
#
#     fanout proves the units own disjoint FILES. It proves NOTHING about their INTERFACES.
#
# Two agents can own non-overlapping paths and still build to incompatible contracts; the
# collision surfaces only at integration, which is the most expensive place for it to surface.
#
#   Anthropic, 16 agents, C compiler (anthropic.com/engineering/building-c-compiler), VERBATIM:
#     "Every agent would hit the same bug, fix that bug, and then overwrite each other's changes.
#      Having 16 agents running didn't help because each was stuck solving the same task."
#   Their `current_tasks/` git-file lock was FULLY IN FORCE throughout. File-level locking
#   enforces distinct task NAMES, not distinct semantic WORK. That is the gap this file closes.
#
# ── WHY THE FROZEN ARTIFACT MUST BE MACHINE-CHECKABLE, NEVER PROSE ────────────────────────
# Every N-agent project that actually worked froze something a MACHINE could check — and got it
# for free. Bun's Zig source: 1,448 .zig → 1,448 .rs, 1:1, so every module boundary and signature
# was fixed in advance and no interface NEGOTIATION was ever needed. Anthropic had the C standard
# plus GCC as a differential oracle. Every prose-spec tool has effectively zero published evidence.
# GREENFIELD FANOUT HAS NEITHER of those free references — so it must MAKE one, and it must make
# the kind that worked: a TYPED artifact. A `.d.ts`, a `.pyi`, a trait/interface file, a protobuf
# schema, an OpenAPI document. Never a markdown "spec". A prose contract cannot be checked, so it
# cannot be enforced, so it is not a contract — it is a suggestion, and N agents will each read a
# different one out of it.
#
# ── THE CONTRACT IS A PRE-GATE, NEVER THE ORACLE ──────────────────────────────────────────
# `fleet spec check` is designed to run INSIDE `fleet_gate` as a fast pre-gate. It NEVER decides
# correctness. Measured ceiling (STVR 2025, peer-reviewed, doi:10.1002/stvr.70003): consumer-driven
# contract tests caught 41/53 seeded integration defects (77%) — and 11 of the 12 MISSES were
# value-range changes, because contracts spot-check single values. The authors: "They could not
# replace the service black-box tests but only complement them." The ORACLE STAYS THE TEST SUITE.
# This mirrors exactly what fleet already does with `review`: evidence, not verdicts.
#
# usage:
#   fleet spec init                      scaffold .fleet/ports.json
#   fleet spec check [manifest]          the static proofs + the frozen-port diff proof (exit 2)
#   fleet spec stub [manifest]           generate a COMPILING stub for every `provides` port
#   fleet spec amend <port> [--manifest] the ONLY sanctioned way to change a frozen port
#   fleet spec context [--worktree wt]   the port block fed to fanout workers and reviewers
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

ROOT="$(repo_root)" || { echo "fleet spec: not inside a git repository" >&2; exit 1; }
# From a LINKED worktree, --git-common-dir points at the MAIN repo's .git — that is where the
# fanout state (and therefore this unit's manifest) lives.
CD="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
case "$CD" in /*) : ;; *) CD="$(git rev-parse --show-toplevel)/$CD" ;; esac
MAIN_ROOT="$(cd "$(dirname "$CD")" && pwd -P)"

PORTS="${FLEET_PORTS:-$MAIN_ROOT/.fleet/ports.json}"

die2() { echo "fleet spec: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
usage: fleet spec <verb> [args]
  init [--force]              scaffold .fleet/ports.json (the port registry)
  check [manifest]            REFUSE (exit 2) a manifest whose interfaces are not independent:
                                (a) every `consumes` resolves to EXACTLY ONE `provides` — in the
                                    manifest, or to a port already frozen on the base branch. No
                                    dangling; no duplicate providers (the duplicate-code tax).
                                (b) the provides→consumes DAG is ACYCLIC (a cycle = the units are
                                    NOT independent; the cycle is NAMED in the error).
                                (c) a frozen port ARTIFACT is READ-ONLY to every unit that does not
                                    `provides` it — checked against the unit's `owns` AND its DIFF.
                              Runs inside `fleet_gate` as a fast PRE-GATE. It is NOT the oracle:
                              the TEST SUITE is. Contract tests catch ~77% of integration defects
                              (STVR 2025) and miss every value-range bug. Evidence, not verdicts.
  stub [manifest] [--force]   generate a COMPILING stub for every `provides` port, so a CONSUMER
                              unit typechecks and runs its own tests on DAY ZERO without the
                              provider existing. Stack-agnostic: the generator is the per-repo hook
                              `fleet_stub_for <artifact> <stub-path>` in .fleet/config.sh.
  amend <port> [--manifest m] the ONLY sanctioned way to change a frozen port: names every unit
                              that CONSUMES it and marks them (and its provider) for a RE-RUN.
  context [--worktree <wt>]   print the port block for a unit (used by the fanout worker prompt and
                              by `fleet delegate review`).

port registry — .fleet/ports.json (FLEET_PORTS overrides):
  { "ports": { "port:KV": { "artifact": "src/ports/kv.d.ts", "stub": "src/ports/kv.stub.ts" } } }
  `artifact` is the FROZEN PORT: a TYPED, MACHINE-CHECKABLE file (.d.ts / .pyi / trait / protobuf /
  OpenAPI). NEVER prose. A prose contract cannot be checked, therefore cannot be enforced,
  therefore is not a contract. It is committed to the BASE BRANCH before fanout, and it is
  READ-ONLY to every unit that does not `provides` it.

manifest — a `fanout` manifest, extended:
  { "units": [ { "id": "store", "owns": ["src/store/**"], "provides": ["port:KV"], "task": "…" },
               { "id": "api",   "owns": ["src/api/**"],   "consumes": ["port:KV"], "task": "…" } ] }
  A manifest with no provides/consumes behaves EXACTLY as it did before this existed.
EOF
}

# Resolve the unit CONTEXT: which fanout unit is this worktree, and which manifest describes it?
# FLEET_SPEC_UNIT / FLEET_SPEC_MANIFEST / FLEET_SPEC_BASE override; otherwise it is derived from
# the branch name (`agent/fanout/<slug>/<id>`) and the fanout state dir. No context = no diff proof.
SPEC_UNIT=""; SPEC_MANIFEST=""; SPEC_BASE=""
spec_context() {  # $1 = worktree (default: cwd)
  local wt="${1:-$PWD}" br slug
  SPEC_UNIT="${FLEET_SPEC_UNIT:-}"; SPEC_MANIFEST="${FLEET_SPEC_MANIFEST:-}"
  SPEC_BASE="${FLEET_SPEC_BASE:-}"
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  case "$br" in
    agent/fanout/*/*)
      slug="${br#agent/fanout/}"; slug="${slug%/*}"
      [ -n "$SPEC_UNIT" ]     || SPEC_UNIT="${br##*/}"
      [ -n "$SPEC_MANIFEST" ] || SPEC_MANIFEST="$MAIN_ROOT/.fleet/fanout/$slug/manifest.json"
      [ -n "$SPEC_BASE" ] || SPEC_BASE="$(cat "$MAIN_ROOT/.fleet/fanout/$slug/base" 2>/dev/null || echo "")"
      ;;
  esac
  [ -n "$SPEC_BASE" ] || SPEC_BASE="${FLEET_MAIN:-main}"
  [ -f "${SPEC_MANIFEST:-/nonexistent}" ] || SPEC_MANIFEST=""
  [ -n "$SPEC_MANIFEST" ] || SPEC_UNIT=""
}

# Print, one per line: "<provides|consumes>\t<port>\t<artifact>" for the given unit.
unit_ports() {  # $1 = manifest, $2 = unit id
  python3 - "$1" "$2" "$PORTS" <<'PY'
import json, sys
manifest, uid, ports = sys.argv[1:4]
try:
    reg = json.load(open(ports)).get("ports", {})
except Exception:
    reg = {}
try:
    units = json.load(open(manifest)).get("units", [])
except Exception:
    units = []
for u in units:
    if u.get("id") != uid:
        continue
    for rel in ("provides", "consumes"):
        for p in (u.get(rel) or []):
            a = (reg.get(p) or {}).get("artifact", "")
            print("%s\t%s\t%s" % (rel, p, a))
PY
}

# ── check ────────────────────────────────────────────────────────────────────────────────
cmd_check() {
  local manifest="${1:-}" rc=0 art rel pid changed
  echo "fleet spec check"
  if [ ! -f "$PORTS" ]; then
    echo "  no port registry (${PORTS#"$MAIN_ROOT"/}) — nothing to freeze. \`fleet spec init\` to add one."
  else
    echo "  registry: ${PORTS#"$MAIN_ROOT"/}"
  fi

  # 1) THE STATIC PROOFS. check-claims.py is fleet's ONE ownership prover — it is EXTENDED, never
  #    forked. It accepts a fanout manifest as readily as a claims manifest.
  [ -n "$manifest" ] || manifest="$MAIN_ROOT/.claude/agent-claims.json"
  if [ -f "$manifest" ]; then
    echo "  --- static proofs on $manifest (dangling / duplicate providers / cycles / frozen owns)"
    ( cd "$MAIN_ROOT" && FLEET_PORTS="$PORTS" python3 "$HERE/check-claims.py" "$manifest" ) 2>&1 \
      | sed 's/^/    | /'
    rc="${PIPESTATUS[0]}"
    [ "$rc" -eq 0 ] || exit 2
  else
    echo "  --- no manifest at $manifest — skipping the static proofs"
  fi

  # 2) THE FROZEN-PORT DIFF PROOF (the read-only property). This is the one that stops SILENT
  #    CONTRACT DRIFT: a unit that can rewrite the contract it was handed will drift it, and every
  #    other unit is still building against the old one. It needs a UNIT CONTEXT (which unit am I?);
  #    without one — a human on the base branch, an integration worktree — there is nothing to
  #    enforce and we say so rather than block ordinary work.
  spec_context "$PWD"
  if [ -z "$SPEC_UNIT" ]; then
    echo "  --- no fanout unit context (branch is not agent/fanout/<slug>/<id>) — the frozen-port"
    echo "      diff proof does not apply here. Ports are read-only to UNITS; the base branch owns them."
    echo "  OK"
    return 0
  fi
  echo "  --- frozen-port diff proof: unit '$SPEC_UNIT' vs base '$SPEC_BASE'"
  changed="$(
    { git diff --name-only "$SPEC_BASE"...HEAD 2>/dev/null
      git diff --name-only HEAD 2>/dev/null
      git diff --name-only --cached 2>/dev/null; } | sort -u
  )"
  rc=0
  # Every port in the registry, not just this unit's: a unit must not touch ANY port artifact it
  # does not `provides` — including ports it does not even consume.
  while IFS="$(printf '\t')" read -r pid art; do
    [ -n "${art:-}" ] || continue
    printf '%s\n' "$changed" | grep -qxF "$art" || continue
    if unit_ports "$SPEC_MANIFEST" "$SPEC_UNIT" | grep -qxF "$(printf 'provides\t%s\t%s' "$pid" "$art")"; then
      echo "      provider '$SPEC_UNIT' modified its OWN port artifact $art ($pid) — allowed."
      continue
    fi
    echo "" >&2
    echo "  FROZEN PORT VIOLATION: unit '$SPEC_UNIT' modified $art ($pid), which it does NOT provide." >&2
    echo "" >&2
    echo "  A port artifact is READ-ONLY to every unit but its provider. Your sibling units are" >&2
    echo "  building against the version of this contract that is frozen on '$SPEC_BASE' RIGHT NOW." >&2
    echo "  Changing it here changes it for nobody but you: they will not see it, they will not be" >&2
    echo "  re-run, and the mismatch surfaces at integration — which is the single most expensive" >&2
    echo "  place for it to surface, and the entire failure this layer exists to prevent." >&2
    echo "" >&2
    echo "  Revert it. If the contract is genuinely WRONG, that is a MANIFEST bug, not a unit bug:" >&2
    echo "  stop, say so, and let the orchestrator run \`fleet spec amend $pid\` on the base branch —" >&2
    echo "  which names every consumer of this port and RE-RUNS them against the new contract." >&2
    rc=2
  done <<EOF
$(python3 - "$PORTS" <<'PY'
import json, sys
try:
    reg = json.load(open(sys.argv[1])).get("ports", {})
except Exception:
    reg = {}
for p, e in reg.items():
    print("%s\t%s" % (p, (e or {}).get("artifact", "")))
PY
)
EOF
  [ "$rc" -eq 0 ] || exit 2
  echo "      no frozen port artifact was touched by '$SPEC_UNIT'."
  echo "  OK — this is a PRE-GATE, not the oracle. The TEST SUITE decides correctness: contract"
  echo "  checks caught 77% of seeded integration defects (STVR 2025) and missed every value-range"
  echo "  bug. They complement the black-box tests; they never replace them."
}

# ── init ─────────────────────────────────────────────────────────────────────────────────
cmd_init() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  if [ -f "$PORTS" ] && [ "$force" -eq 0 ]; then
    echo "fleet spec init: $PORTS already exists (--force to overwrite)."
    exit 0
  fi
  mkdir -p "$(dirname "$PORTS")"
  cat > "$PORTS" <<'JSON'
{
  "$schema": "https://github.com/jellologic/claude-fleet/examples/ports.schema.json",
  "_comment": "The PORT REGISTRY. Each `artifact` is a FROZEN, MACHINE-CHECKABLE interface file — a .d.ts, a .pyi, a trait/interface file, a protobuf schema, an OpenAPI document. NEVER prose: a prose contract cannot be checked, so it cannot be enforced, so it is not a contract. Commit the artifact to the BASE BRANCH before you fan out; it is then READ-ONLY to every unit that does not `provides` it, and `fleet spec amend <port>` is the only sanctioned way to change it.",
  "ports": {
  }
}
JSON
  cat <<EOF
fleet spec init
  wrote ${PORTS#"$MAIN_ROOT"/}

  next:
    1. Write the FROZEN PORT — a TYPED artifact, never prose:
         src/ports/kv.d.ts   .pyi   a trait file   .proto   openapi.yaml
    2. Register it:
         { "ports": { "port:KV": { "artifact": "src/ports/kv.d.ts",
                                   "stub": "src/ports/kv.stub.ts" } } }
    3. COMMIT it to the base branch. It is now read-only to every fanout unit.
    4. Add \`fleet_stub_for\` to .fleet/config.sh, then: fleet spec stub
    5. Declare provides/consumes in the fanout manifest, then: fleet spec check m.json
EOF
}

# ── stub ─────────────────────────────────────────────────────────────────────────────────
# The CDCT decoupling property, reduced to the simplest thing that works. STVR 2025: "By
# decoupling the consumer and provider via the contract file, the CDC tests don't require running
# the consumer and the provider simultaneously." A CONSUMER unit must typecheck and run its own
# tests on DAY ZERO, without the provider unit existing at all.
cmd_stub() {
  local manifest="" force=0 n=0 made=0 pid art stub
  while [ $# -gt 0 ]; do case "$1" in
    --force) force=1; shift ;;
    -*)      die2 "unknown arg: $1" ;;
    *)       manifest="$1"; shift ;;
  esac; done

  [ -f "$PORTS" ] || die2 "no port registry at $PORTS — run \`fleet spec init\` first"
  # shellcheck disable=SC1091
  [ -f "$MAIN_ROOT/.fleet/config.sh" ] && . "$MAIN_ROOT/.fleet/config.sh"
  if [ "$(type -t fleet_stub_for 2>/dev/null || true)" != "function" ]; then
    # Documented NO-OP default. fleet is stack-agnostic: it will not hardcode TypeScript, and it
    # will not pretend to have generated something it did not.
    echo "fleet spec stub: no \`fleet_stub_for\` hook in .fleet/config.sh — NOTHING was generated." >&2
    echo "  Stub generation is inherently stack-specific, so it is a per-repo hook (alongside" >&2
    echo "  fleet_gate / fleet_pkg_for). Define it and re-run:" >&2
    echo "    fleet_stub_for() {  # \$1 = frozen port artifact, \$2 = stub path to write" >&2
    echo "      case \"\$1\" in *.d.ts) …emit a compiling stub…;; *.pyi) …;; esac" >&2
    echo "    }" >&2
    exit 0
  fi

  echo "fleet spec stub"
  while IFS="$(printf '\t')" read -r pid art stub; do
    [ -n "${stub:-}" ] || { echo "  skip  $pid — no \"stub\" path declared"; continue; }
    n=$((n + 1))
    if [ -e "$MAIN_ROOT/$stub" ] && [ "$force" -eq 0 ]; then
      echo "  keep  $pid → $stub (exists; --force to regenerate)"
      continue
    fi
    mkdir -p "$(dirname "$MAIN_ROOT/$stub")"
    ( cd "$MAIN_ROOT" && fleet_stub_for "$art" "$stub" ) \
      || die2 "fleet_stub_for failed for $pid ($art → $stub)"
    [ -e "$MAIN_ROOT/$stub" ] \
      || die2 "fleet_stub_for returned 0 for $pid but did NOT create $stub — a stub that does not exist cannot make a consumer compile"
    echo "  +     $pid → $stub (from the frozen port $art)"
    made=$((made + 1))
  done <<EOF
$(python3 - "$PORTS" "${manifest:-}" <<'PY'
import json, sys
ports, manifest = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
reg = json.load(open(ports)).get("ports", {})
want = None
if manifest:
    try:
        units = json.load(open(manifest)).get("units", [])
        want = set(p for u in units for p in (u.get("provides") or []))
    except Exception:
        want = None
for p, e in reg.items():
    if want is not None and p not in want:
        continue
    print("%s\t%s\t%s" % (p, (e or {}).get("artifact", ""), (e or {}).get("stub", "")))
PY
)
EOF
  echo "  $made stub(s) generated of $n declared."
  echo "  Commit them to the BASE BRANCH: a consumer unit can now typecheck and run its own tests"
  echo "  on day zero, with NO provider unit in existence. That decoupling is the whole point."
}

# ── amend ────────────────────────────────────────────────────────────────────────────────
# The ONLY sanctioned way to change a frozen port. It must (a) say which units consume it and
# (b) require them to be re-run — a contract change that does not re-run its consumers is exactly
# the silent drift the read-only rule exists to prevent.
cmd_amend() {
  local pid="${1:-}" manifest="" br mf slug found=0
  [ -n "$pid" ] || die2 "usage: fleet spec amend <port> [--manifest <fanout.json>]"
  shift
  while [ $# -gt 0 ]; do case "$1" in
    --manifest) manifest="${2:?--manifest needs a path}"; shift 2 ;;
    -*)         die2 "unknown arg: $1" ;;
    *)          die2 "unexpected argument: $1" ;;
  esac; done

  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  case "$br" in
    agent/fanout/*) die2 "you are on a fanout UNIT branch ($br). A unit may not amend the contract it
  was handed — that is the drift this layer exists to prevent. Stop, say so in your final message,
  and let the orchestrator amend the port on the base branch." ;;
  esac

  [ -f "$PORTS" ] || die2 "no port registry at $PORTS"
  python3 - "$PORTS" "$pid" <<'PY' || exit 2
import json, sys
reg = json.load(open(sys.argv[1])).get("ports", {})
p = sys.argv[2]
if p not in reg:
    print("fleet spec: unknown port '%s' — not in the registry. Known: %s"
          % (p, ", ".join(sorted(reg)) or "(none)"), file=sys.stderr)
    sys.exit(2)
print("fleet spec amend %s" % p)
print("  artifact: %s   (the FROZEN, machine-checkable contract)" % reg[p].get("artifact"))
PY

  # Which manifests describe units that touch this port? Explicit --manifest, else every live
  # fanout's manifest.
  for mf in ${manifest:-$(ls "$MAIN_ROOT"/.fleet/fanout/*/manifest.json 2>/dev/null)}; do
    [ -f "$mf" ] || continue
    # The fanout STATE dir is keyed by the manifest's SLUG — exactly as `fanout` derives it
    # (basename minus .json). The copy fanout keeps at .fleet/fanout/<slug>/manifest.json is the
    # one case where the slug is the PARENT directory instead.
    if [ "$(basename "$mf")" = "manifest.json" ]; then
      slug="$(basename "$(dirname "$mf")")"
    else
      slug="$(basename "$mf")"; slug="${slug%.json}"
      slug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' \
              | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')"
    fi
    python3 - "$mf" "$pid" "$MAIN_ROOT/.fleet/fanout/$slug" "$slug" <<'PY' && found=1
import json, os, sys
mf, pid, state, slug = sys.argv[1:5]
try:
    units = json.load(open(mf)).get("units", [])
except Exception:
    sys.exit(1)
prov = [u["id"] for u in units if pid in (u.get("provides") or [])]
cons = [u["id"] for u in units if pid in (u.get("consumes") or [])]
if not prov and not cons:
    sys.exit(1)
print("  manifest: %s" % mf)
print("    provider : %s" % (", ".join(prov) or "(none — the port is frozen on the base branch)"))
print("    CONSUMERS: %s" % (", ".join(cons) or "(none)"))
n = 0
for uid in prov + cons:
    sf = os.path.join(state, "units", uid, "state")
    if os.path.exists(sf):
        with open(sf, "w") as fh:
            fh.write("pending\n")
        n += 1
if n:
    print("    marked %d unit(s) PENDING — `fleet delegate fanout <manifest> --resume` RE-RUNS them" % n)
    with open(os.path.join(state, "amend.log"), "a") as fh:
        fh.write("amend %s -> re-run: %s\n" % (pid, ", ".join(prov + cons)))
PY
  done

  [ "$found" -eq 1 ] || echo "  no live fanout manifest declares this port (nothing to re-run)."
  cat <<EOF

  Now, ON THE BASE BRANCH (never inside a unit worktree):
    1. edit the artifact — it stays a TYPED, machine-checkable file, never prose;
    2. \`fleet spec stub\` to regenerate the stub, and COMMIT both;
    3. \`fleet delegate fanout <manifest> --resume\` — every unit named above is re-run against
       the NEW contract. A contract change that does not re-run its consumers is precisely the
       silent drift the read-only rule exists to prevent.
EOF
}

# ── context — the port block handed to workers and reviewers ─────────────────────────────
# Free win: pipe the FROZEN PORT into `fleet delegate review`'s prompt. Bun's reviewers checked
# conformance to PORTING.md/LIFETIMES.tsv AND behavioural equivalence. "Does this diff conform to
# the frozen port?" is a far better-defined, evidence-emitting question than "is this code good?".
#
# WATCH THE FAILURE MODE: a reviewer handed a schema will happily degenerate into a SCHEMA LINTER,
# duplicating the type-checker — which does that job better, cheaper and deterministically. That
# reviewer is worth nothing. Bun's did BOTH: conformance AND bug-hunting. The prompt below says so
# explicitly, and it is the reason the port block is framed as CONTEXT, not as a checklist.
cmd_context() {
  local wt="$PWD" rel pid art n=0
  while [ $# -gt 0 ]; do case "$1" in
    --worktree) wt="${2:?--worktree needs a path}"; shift 2 ;;
    -*)         die2 "unknown arg: $1" ;;
    *)          die2 "unexpected argument: $1" ;;
  esac; done
  spec_context "$wt"
  [ -n "$SPEC_UNIT" ] || return 0
  [ -f "$PORTS" ] || return 0

  while IFS="$(printf '\t')" read -r rel pid art; do
    [ -n "${art:-}" ] || continue
    if [ "$n" -eq 0 ]; then
      cat <<EOF

── FROZEN PORTS (the CONTRACT) ─────────────────────────────────────────────────────────
These files are the interface contract for unit '$SPEC_UNIT'. They are FROZEN on '$SPEC_BASE' and
READ-ONLY to you unless you PROVIDE them. Every sibling unit is building against exactly these
signatures right now. Conform to them EXACTLY. If a port is genuinely wrong, STOP and say so —
that is a manifest bug, and the orchestrator fixes it with \`fleet spec amend\`. Do not edit it.
EOF
    fi
    n=$((n + 1))
    echo ""
    echo "  $(echo "$rel" | tr '[:lower:]' '[:upper:]') $pid → $art"
    if [ -f "$wt/$art" ]; then
      sed -n '1,200p' "$wt/$art" | sed 's/^/    | /'
    else
      echo "    | (not present on this branch)"
    fi
  done <<EOF
$(unit_ports "$SPEC_MANIFEST" "$SPEC_UNIT")
EOF
  [ "$n" -eq 0 ] || echo "────────────────────────────────────────────────────────────────────────────────────────"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  init)    cmd_init "$@" ;;
  check)   cmd_check "$@" ;;
  stub)    cmd_stub "$@" ;;
  amend)   cmd_amend "$@" ;;
  context) cmd_context "$@" ;;
  ""|-h|--help) usage ;;
  *) echo "unknown spec verb: $cmd (try: fleet spec --help)" >&2; exit 2 ;;
esac
