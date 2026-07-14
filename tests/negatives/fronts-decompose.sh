#!/usr/bin/env bash
# NEGATIVE: `fleet fronts` must DERIVE the decomposition from the ORACLE — and REFUSE to
# manufacture parallelism that the oracle does not actually support. Regression for #49.
#
# The primitive both flagship N-agent projects independently arrived at:
#
#   run a machine ORACLE → collect its FAILURES → shard them into DISJOINT units → fan out.
#
#   Bun (~64 agents, bun.com/blog/bun-in-rust):
#     "`cargo check` wrote ≈16,000 errors to a file, GROUPED BY CRATE; the workflow divvied them
#      up among 64 Claudes." => the compiler's error list WAS the work queue.
#
#   Anthropic (16 agents, C compiler, anthropic.com/engineering/building-c-compiler) — the
#   NEGATIVE result that makes assertion (2) below load-bearing:
#     "compiling the Linux kernel is one giant task. Every agent would hit the same bug, fix that
#      bug, and then overwrite each other's changes. Having 16 agents running didn't help because
#      each was stuck solving the same task. The fix was to use GCC as an online known-good
#      compiler oracle to compare against." … "This let each agent work in parallel, fixing
#      different bugs in different files."
#
# So: N units may only exist when the ORACLE says N independent failures exist. When every failure
# traces to ONE file, `fronts` must emit ONE unit and SAY SO — splitting there is exactly the
# 16-agent kernel failure, and the entire reason to run the oracle first is to see it coming.
#
# Asserted here:
#   1. Failures across 3 distinct files → 3 units, pairwise disjoint, and the emitted manifest
#      PASSES check-claims.py (the same prover `fanout` runs).
#   2. THE LOAD-BEARING ONE: every failure in ONE file → EXACTLY 1 unit, and the output says
#      NOT DECOMPOSABLE. It must NOT emit one unit per failure.
#   3. A GREEN oracle (exit 0) → exit 0, no units, no manifest churn.
#   4. Paths the repo does not TRACK (/usr/... , /tmp/... , hallucinated files) are IGNORED.
#   5. --shard-by package groups a package's files into ONE unit (Bun's "grouped by crate").
#   6. --max-units N MERGES the excess fronts and NEVER DROPS a failing file.
#   7. The emitted manifest is actually CONSUMABLE: `fleet delegate fanout <m> --dry-run` accepts it.
#   8. Parser coverage: rustc/gcc, tsc and python-traceback forms each yield the right file.
#   9. --require-parallel turns the not-decomposable verdict into exit 2 (for CI).
#
# The oracle is a STUB that prints canned compiler output. NO model, NO network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)/src/fleet"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the test repo --------------------------------------------------------------------
git init -q -b main "$TMP/repo"
REPO="$TMP/repo"
cd "$REPO" || exit 1
git config user.email t@t; git config user.name t
mkdir -p .fleet src/parser src/codegen docs
cp -R "$SRC/lib" "$SRC/bin" .fleet/ 2>/dev/null || cp -R "$SRC/bin" .fleet/
cat > .fleet/config.sh <<'CFG'
FLEET_MAIN="main"
fleet_bootstrap() { : ; }
# package = the top-level directory (stands in for a crate / workspace member)
fleet_pkg_for() { printf '%s\n' "${1%%/*}"; }
fleet_gate() { echo "  gate: ok"; return 0; }
CFG
printf '.fleet/worktrees/\n.fleet/locks/\n.fleet/fanout/\n.fleet/delegate/\n' > .gitignore
printf 'fn parse() {}\n'  > src/parser/parser.rs
printf 'fn lex() {}\n'    > src/parser/lex.rs
printf 'const x = 1;\n'   > src/codegen/emit.ts
printf 'def go(): pass\n' > docs/tool.py
git add -A; git commit -qm base

FRONTS=".fleet/bin/fleet fronts"
mkdir -p bin

# ── ORACLE STUBS ──────────────────────────────────────────────────────────────────────
# Each prints canned output in a real compiler's format and exits non-zero, exactly as the real
# thing would. Nothing here runs a model or touches the network.

# THREE distinct files, in THREE different formats (rustc `-->`, gcc `path:l:c:`, tsc `path(l,c):`,
# and a python traceback) — this is also the parser-coverage fixture for assertion (8).
cat > bin/oracle-wide <<'O'
#!/usr/bin/env bash
cat <<'EOF'
error[E0308]: mismatched types
  --> src/parser/parser.rs:12:5
   |
src/parser/lex.rs:3:1: error: expected `;`, found `}`
src/codegen/emit.ts(9,4): error TS2322: Type 'string' is not assignable to type 'number'.
EOF
exit 1
O

# EVERY failure in ONE file. This is the Anthropic kernel shape.
cat > bin/oracle-one <<'O'
#!/usr/bin/env bash
cat <<'EOF'
src/parser/parser.rs:4:1: error: undefined symbol `a`
src/parser/parser.rs:9:1: error: undefined symbol `b`
src/parser/parser.rs:14:1: error: undefined symbol `c`
src/parser/parser.rs:20:1: error: undefined symbol `d`
src/parser/parser.rs:25:1: error: undefined symbol `e`
EOF
exit 1
O

# GREEN.
cat > bin/oracle-green <<'O'
#!/usr/bin/env bash
echo "all checks passed"
exit 0
O

# Real failures MIXED WITH paths this repo does not track: a system header, a /tmp scratch file,
# an absolute path outside the repo, and a file that simply does not exist (the shape a
# hallucinating tool emits). Only src/parser/lex.rs is real.
cat > bin/oracle-bogus <<'O'
#!/usr/bin/env bash
cat <<'EOF'
/usr/include/stdio.h:42:1: error: this is a system header, not our work
/tmp/scratch-build/gen.c:7:2: error: a build artefact in /tmp
/opt/homebrew/lib/rt.rs:1:1: error: outside the repo entirely
src/does-not-exist.rs:1:1: error: hallucinated path, not tracked by git
build/generated.ts(3,3): error TS1005: untracked generated output
src/parser/lex.rs:5:5: error: the ONE real failure
EOF
exit 1
O

# TWO files in the SAME package (src) plus one in another (docs) — for --shard-by package.
cat > bin/oracle-pkg <<'O'
#!/usr/bin/env bash
cat <<'EOF'
src/parser/parser.rs:1:1: error: a
src/parser/lex.rs:1:1: error: b
src/codegen/emit.ts(2,2): error TS1000: c
Traceback (most recent call last):
  File "docs/tool.py", line 3, in go
NameError: name 'q' is not defined
EOF
exit 1
O

# FOUR distinct files with UNEQUAL failure counts — for --max-units merging.
cat > bin/oracle-four <<'O'
#!/usr/bin/env bash
cat <<'EOF'
src/parser/parser.rs:1:1: error: p1
src/parser/parser.rs:2:1: error: p2
src/parser/parser.rs:3:1: error: p3
src/parser/lex.rs:1:1: error: l1
src/parser/lex.rs:2:1: error: l2
src/codegen/emit.ts(1,1): error TS1: c1
docs/tool.py:1: error: d1
EOF
exit 1
O
chmod +x bin/oracle-wide bin/oracle-one bin/oracle-green bin/oracle-bogus bin/oracle-pkg bin/oracle-four
git add -A; git commit -qm oracles

# --- helpers ---------------------------------------------------------------------------
n_units() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["units"]))' "$1"; }
unit_ids() { python3 -c 'import json,sys; [print(u["id"]) for u in json.load(open(sys.argv[1]))["units"]]' "$1"; }
owns_of()  { python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
for u in m["units"]:
    if u["id"]==sys.argv[2]:
        [print(g) for g in u["owns"]]' "$1" "$2"; }
all_owns() { python3 -c 'import json,sys; [print(g) for u in json.load(open(sys.argv[1]))["units"] for g in u["owns"]]' "$1"; }

# Independent disjointness oracle: no two units may name the same glob, and no glob may nest
# inside another unit's glob. (Deliberately NOT check-claims.py — that is asserted separately,
# and a test that only re-runs the code under test proves nothing.)
assert_disjoint() { python3 - "$1" <<'PY' || fail "the emitted manifest's units are NOT pairwise disjoint"
import json, sys
u = json.load(open(sys.argv[1]))["units"]
def base(g): return g[:-3] if g.endswith("/**") else g
for i in range(len(u)):
    for j in range(i + 1, len(u)):
        for a in u[i]["owns"]:
            for b in u[j]["owns"]:
                A, B = base(a), base(b)
                if A == B or A.startswith(B + "/") or B.startswith(A + "/"):
                    print(f"OVERLAP {u[i]['id']} '{a}' vs {u[j]['id']} '{b}'", file=sys.stderr)
                    sys.exit(1)
PY
}

# ======================================================================================
# 1 + 8. Failures across 3 DISTINCT files → 3 units, disjoint, PASSING check-claims.py.
#        The three files arrive in three DIFFERENT compiler formats (parser coverage).
# ======================================================================================
out="$($FRONTS --oracle 'bin/oracle-wide' -o m-wide.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [wide] /'
[ "$rc" -eq 0 ] || fail "fronts exited $rc on a decomposable oracle"
[ -f m-wide.json ] || fail "no manifest was written"
[ "$(n_units m-wide.json)" -eq 3 ] \
  || fail "the oracle failed in 3 DISTINCT files but fronts emitted $(n_units m-wide.json) unit(s). The failure list IS the work queue: 3 independent failing files = 3 independent work fronts (Bun: ~16,000 \`cargo check\` errors 'grouped by crate', divvied among 64 Claudes)."
assert_disjoint m-wide.json
# fronts SELF-PROVES its output with check-claims.py and refuses to write a manifest that fails —
# so a clean exit here already means its own consumer's prover accepted it.
$FRONTS --oracle 'bin/oracle-wide' -o m-wide.json >/dev/null 2>&1 \
  || fail "fronts refused to emit; its own self-proof (check-claims.py) rejected its manifest"

# parser coverage — one file per FORMAT, each attributed correctly
for f in src/parser/parser.rs src/parser/lex.rs src/codegen/emit.ts; do
  all_owns m-wide.json | grep -qxF "$f" \
    || fail "the parser did not attribute a failure to '$f'. Coverage regression: rustc's '--> path:l:c' form, gcc/clang/eslint's 'path:l:c: error:' form, and tsc's 'path(l,c): error TSnnnn:' form must EACH yield the right file, or the oracle's work queue is silently truncated and those failures get no owner."
done
echo "    ok: 3 distinct failing files (in rustc, gcc and tsc formats) → 3 pairwise-disjoint units"

# --- 1b. it PASSES check-claims.py, exactly as `fanout` will run it -------------------
cat > "$TMP/claims-of.py" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
W = re.compile(r"[*?\[\]{}]")
json.dump({"claims": [{"agentId": u["id"], "branch": "agent/fronts/" + u["id"],
                       "status": "claimed", "globs": u["owns"],
                       "newFiles": [g for g in u["owns"] if not W.search(g)]}
                      for u in m["units"]]}, open(sys.argv[2], "w"), indent=2)
PY
python3 "$TMP/claims-of.py" m-wide.json "$TMP/claims.json"
cc="$(python3 .fleet/bin/check-claims.py "$TMP/claims.json" 2>&1)"; ccrc=$?
echo "$cc" | sed 's/^/    | [check-claims] /'
[ "$ccrc" -eq 0 ] \
  || fail "the manifest fronts emitted is REJECTED by check-claims.py — the very prover \`fanout\` runs before it launches anything. A generator whose output its own consumer refuses is worthless."
echo "    ok: the emitted manifest PASSES check-claims.py (fanout's disjointness prover)"

# ======================================================================================
# 2. THE LOAD-BEARING ASSERTION — 5 failures, ONE file → EXACTLY 1 unit + NOT DECOMPOSABLE.
# ======================================================================================
out="$($FRONTS --oracle 'bin/oracle-one' -o m-one.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [one-file] /'
[ "$rc" -eq 0 ] || fail "fronts exited $rc on a not-decomposable oracle; it must still emit a valid single-unit manifest and exit 0"
[ -f m-one.json ] || fail "no manifest was written for the single-front case"
n="$(n_units m-one.json)"
[ "$n" -eq 1 ] \
  || fail "ALL 5 FAILURES ARE IN ONE FILE AND FRONTS EMITTED $n UNITS. This is the Anthropic kernel failure, manufactured on purpose: 'Having 16 agents running didn't help because each was stuck solving the same task' — 'every agent would hit the same bug, fix that bug, and then overwrite each other's changes.' N agents on ONE file is strictly worse than N=1. There is exactly ONE work front here and fronts must say so."
[ "$n" -ne 5 ] \
  || fail "fronts sharded PER-FAILURE instead of per-front: 5 failures in one file became 5 units"
echo "$out" | grep -q "NOT DECOMPOSABLE" \
  || fail "fronts emitted the single unit but never SAID 'NOT DECOMPOSABLE'. Silently emitting one unit looks identical to a bug; the operator who asked for parallel work must be told, in words, that the oracle found none."
echo "$out" | grep -q "src/parser/parser.rs" \
  || fail "the NOT DECOMPOSABLE message does not name the file all the failures trace to"
echo "$out" | grep -qi "stuck solving the same task" \
  || fail "the NOT DECOMPOSABLE message does not cite WHY fanning out here is harmful (the Anthropic 16-agent result)"
echo "$out" | grep -qi "known-good" \
  || fail "the NOT DECOMPOSABLE message does not tell the operator what actually FIXED it (a differential oracle against a known-good reference)"
echo "    ok: 5 failures in ONE file → EXACTLY 1 unit, and it says NOT DECOMPOSABLE (no fake parallelism)"

# --- 9. --require-parallel makes that a HARD failure, for CI --------------------------
out="$($FRONTS --oracle 'bin/oracle-one' -o m-req.json --require-parallel 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  || fail "--require-parallel exited $rc on not-decomposable work, expected 2"
[ -f m-req.json ] && fail "--require-parallel wrote a manifest despite refusing"
echo "    ok: --require-parallel turns the not-decomposable verdict into exit 2 and writes nothing"

# ======================================================================================
# 3. A GREEN ORACLE → exit 0, NO units, NO manifest churn.
# ======================================================================================
cp m-wide.json m-green.json          # pre-existing manifest: it must NOT be clobbered
before="$(md5 -q m-green.json 2>/dev/null || md5sum m-green.json | cut -d' ' -f1)"
out="$($FRONTS --oracle 'bin/oracle-green' -o m-green.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [green] /'
[ "$rc" -eq 0 ] \
  || fail "a GREEN oracle exited $rc. Nothing failing means nothing to shard — that is SUCCESS, not an error."
after="$(md5 -q m-green.json 2>/dev/null || md5sum m-green.json | cut -d' ' -f1)"
[ "$before" = "$after" ] \
  || fail "a GREEN oracle CLOBBERED the output manifest. It must emit nothing at all: a zero-unit or truncated manifest handed to \`fanout\` is a footgun."
echo "$out" | grep -qi "green" || fail "the green run does not say the oracle is green"
echo "    ok: a GREEN oracle → exit 0, no units, no manifest churn"

# ======================================================================================
# 4. UNTRACKED / BOGUS PATHS ARE IGNORED — no work front may exist for a file git does not track.
# ======================================================================================
out="$($FRONTS --oracle 'bin/oracle-bogus' -o m-bogus.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [bogus] /'
[ "$rc" -eq 0 ] || fail "fronts exited $rc on an oracle whose output mixes real and untracked paths"
[ "$(n_units m-bogus.json)" -eq 1 ] \
  || fail "the oracle named 5 UNTRACKED paths (/usr/include/stdio.h, /tmp/scratch-build/gen.c, /opt/homebrew/lib/rt.rs, src/does-not-exist.rs, build/generated.ts) and exactly ONE real tracked file, yet fronts emitted $(n_units m-bogus.json) units. A path git does not track cannot be a work front: you would hand an agent a file that does not exist, or point it at a system header it must never edit."
owns="$(all_owns m-bogus.json)"
printf '%s\n' "$owns" | grep -qxF "src/parser/lex.rs" \
  || fail "the ONE real tracked failure (src/parser/lex.rs) did not become a unit"
for bogus in /usr/include/stdio.h /tmp/scratch-build/gen.c /opt/homebrew/lib/rt.rs src/does-not-exist.rs build/generated.ts; do
  printf '%s\n' "$owns" | grep -qF "$bogus" \
    && fail "the untracked path '$bogus' became part of a unit's ownership. The \`git ls-files\` filter is the only thing standing between a compiler's noisy output and an agent editing /usr/include."
done
unit_ids m-bogus.json | grep -qiE 'stdio|scratch|homebrew|does-not-exist|generated' \
  && fail "an untracked path leaked into a unit ID"
echo "    ok: untracked paths (system headers, /tmp, outside-repo, hallucinated, generated) are IGNORED — only the 1 tracked failure became a unit"

# ======================================================================================
# 5. --shard-by package: a package's files collapse into ONE unit (Bun's "grouped by crate").
# ======================================================================================
out="$($FRONTS --oracle 'bin/oracle-pkg' --shard-by package -o m-pkg.json 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [package] /'
[ "$rc" -eq 0 ] || fail "--shard-by package exited $rc"
# fleet_pkg_for maps by top dir → packages are `src` (3 files) and `docs` (1 file)
[ "$(n_units m-pkg.json)" -eq 2 ] \
  || fail "4 failing files across 2 packages (src, docs) → expected 2 units, got $(n_units m-pkg.json). Bun grouped ~16,000 cargo errors BY CRATE, not by file: two files of one crate are one work front, because a crate-level fix is one agent's job."
assert_disjoint m-pkg.json
# per-file sharding of the SAME oracle would have produced 4 — prove the grouping is real
[ "$($FRONTS --oracle 'bin/oracle-pkg' -o m-pkgf.json >/dev/null 2>&1; n_units m-pkgf.json)" -eq 4 ] \
  || fail "the same oracle sharded BY FILE did not give 4 units — the package-grouping assertion is vacuous"
srcowns="$(owns_of m-pkg.json src)"
printf '%s\n' "$srcowns" | grep -qxF 'src/**' \
  || fail "the 'src' package unit does not own the whole package subtree (src/**); it owns: $srcowns"
# python-traceback coverage (assertion 8): docs/tool.py was found via `File "…", line N`
unit_ids m-pkg.json | grep -qxF docs \
  || fail "the python TRACEBACK form ('File \"docs/tool.py\", line 3') did not yield a unit — parser coverage regression"
echo "    ok: --shard-by package collapses a package's 3 files into 1 unit (4 files → 2 units, vs 4 by file), and the python-traceback form parses"

# ======================================================================================
# 6. --max-units N MERGES the excess fronts and NEVER DROPS A FAILING FILE.
# ======================================================================================
out="$($FRONTS --oracle 'bin/oracle-four' -o m-cap.json --max-units 2 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | [max-units] /'
[ "$rc" -eq 0 ] || fail "--max-units exited $rc"
[ "$(n_units m-cap.json)" -eq 2 ] \
  || fail "--max-units 2 over 4 fronts emitted $(n_units m-cap.json) units"
assert_disjoint m-cap.json
# EVERY failing file the oracle named must appear in EXACTLY ONE unit. Dropping one means the
# oracle is still red after every agent lands and nobody can say why.
python3 - m-cap.json <<'PY' || fail "--max-units DROPPED a failing file (or double-owned one). Merging the smallest fronts is the only correct way to honour a cap: a dropped file is a failure nobody is assigned to, and the oracle stays red forever."
import json, sys
want = ["src/parser/parser.rs", "src/parser/lex.rs", "src/codegen/emit.ts", "docs/tool.py"]
units = json.load(open(sys.argv[1]))["units"]
for f in want:
    n = sum(1 for u in units for g in u["owns"] if g == f)
    if n != 1:
        print(f"failing file {f!r} appears in {n} unit(s), expected exactly 1", file=sys.stderr)
        sys.exit(1)
PY
echo "$out" | grep -qi "MERGED" \
  || fail "--max-units did not LOG what it merged. A cap that silently reshapes the work queue is indistinguishable from one that silently drops from it."
echo "    ok: --max-units 2 over 4 fronts → 2 units, MERGED (and logged), and all 4 failing files still owned exactly once"

# ======================================================================================
# 7. THE OUTPUT IS ACTUALLY CONSUMABLE: `fleet delegate fanout <m> --dry-run` accepts it.
# ======================================================================================
case "$(uname -s)" in
  Darwin)
    out="$(.fleet/bin/fleet delegate fanout m-wide.json --jobs 2 --dry-run 2>&1)"; rc=$?
    echo "$out" | sed 's/^/    | [fanout] /'
    [ "$rc" -eq 0 ] \
      || fail "\`fleet delegate fanout\` REFUSED the manifest that \`fleet fronts\` generated (exit $rc). The generator and the consumer disagree — which makes the generator useless."
    echo "$out" | grep -qi "Nothing launched" || fail "fanout --dry-run did not report a dry run"
    for u in $(unit_ids m-wide.json); do
      echo "$out" | grep -q "$u" || fail "fanout's plan does not mention unit '$u'"
    done
    echo "    ok: the emitted manifest is CONSUMED by \`fleet delegate fanout --dry-run\` (exit 0) — generator and consumer agree"
    ;;
  *) echo "    skip: \`fanout\` consumption check is macOS-only (its workers are sandbox-exec confined)" ;;
esac

echo "PASS: fronts derives the decomposition from the ORACLE — 3 failing files → 3 provably disjoint units that check-claims.py and \`fanout\` both accept; 5 failures in ONE file → EXACTLY 1 unit and a loud NOT DECOMPOSABLE (the Anthropic 16-agent failure, refused rather than manufactured); a green oracle emits nothing; untracked/hallucinated paths never become units; --shard-by package groups by crate; --max-units MERGES and never drops a failing file"
