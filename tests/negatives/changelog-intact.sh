#!/usr/bin/env bash
# NEGATIVE: the CHANGELOG must not be silently destroyed (#65).
#
# It was. `CHANGELOG.md` went to ZERO BYTES on main and shipped that way in the v0.3.0 tag — every
# entry from v0.1.0 onward, gone — and nothing noticed. Not the gate, not the tests, not the release
# process. Two subagents flagged it in passing before a human did.
#
# CAUSE, worth remembering because it LOOKS correct:
#
#     open(p,'w').write('\n'.join(l for l in open(p).read().split('\n') if ...))
#
# Python evaluates `open(p,'w')` FIRST — which TRUNCATES the file — and only THEN evaluates the
# argument. So `open(p).read()` reads an already-empty file and writes back nothing. Read first,
# write last. Always.
#
# This is the same class as #18: a check that silently passes on a destroyed artifact is worse than
# no check at all. So the artifact itself gets a tripwire.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

CL="$ROOT/CHANGELOG.md"
V="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null)"

# ---- 1. It exists and is not empty ---------------------------------------------------
[ -f "$CL" ] || fail "CHANGELOG.md is MISSING"
BYTES=$(wc -c < "$CL" | tr -d ' ')
[ "$BYTES" -gt 0 ] || fail "CHANGELOG.md is ZERO BYTES. This exact thing shipped in v0.3.0 (#65) — a truncating rebase resolver emptied it and every later commit preserved the emptiness."
[ "$BYTES" -gt 2000 ] || fail "CHANGELOG.md is only ${BYTES} bytes — implausibly small for a project with released versions. It was probably truncated (#65)."
echo "    ok: CHANGELOG.md exists and is ${BYTES} bytes"

# ---- 2. The CURRENT VERSION has a section -------------------------------------------
# A release whose own version is missing from its changelog is a release nobody can read.
[ -n "$V" ] || fail "VERSION is empty or missing"
grep -qE "^## \[${V}\]" "$CL" \
  || fail "VERSION is ${V} but CHANGELOG.md has no '## [${V}]' section. Either the release forgot to roll [Unreleased], or the changelog was truncated (#65)."
echo "    ok: CHANGELOG.md has a section for the current VERSION (${V})"

# ---- 3. History is intact — every released tag has a section -------------------------
# The truncation destroyed EVERY prior version's entries, not just the newest. Guard the whole file,
# not just the tip.
MISSING=""
for tag in $(git -C "$ROOT" tag --list 'v*' 2>/dev/null); do
  ver="${tag#v}"
  grep -qE "^## \[${ver}\]" "$CL" || MISSING="$MISSING $ver"
done
[ -z "$MISSING" ] || fail "released version(s) with NO changelog section:$MISSING — the file has lost history (#65)"
echo "    ok: every released tag has a changelog section"

# ---- 4. Structure is sane ------------------------------------------------------------
grep -qE '^## \[Unreleased\]' "$CL" || fail "no '## [Unreleased]' section — new entries have nowhere to go"
grep -qE '^\[Unreleased\]: ' "$CL" || fail "no [Unreleased] link reference at the foot of the file"
echo "    ok: [Unreleased] section and link refs present"

# ---- 5. No unresolved conflict markers ----------------------------------------------
# The truncation happened during a CHANGELOG merge conflict. Its sibling failure is committing the
# markers themselves — which the union-resolve strips, but a hand-resolve might not.
if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$CL" >/dev/null 2>&1; then
  fail "CHANGELOG.md contains unresolved merge-conflict markers"
fi
echo "    ok: no conflict markers"

echo "PASS: CHANGELOG.md is intact — non-empty, has a section for the current VERSION and for every released tag, and carries no conflict markers"
