# .fleet/config.sh — claude-fleet dogfooding ITSELF. Stack: shell + python3 + markdown.
FLEET_MAIN="main"
FLEET_LOCKFILE=""          # no package lockfile
FLEET_DEP_MANIFEST=""      # n/a
FLEET_GENERATED_RE=""      # nothing generated

# No dependencies to install for a shell/python/markdown repo.
fleet_bootstrap() { : ; }

# Small repo → always gate the full tree.
fleet_pkg_for() { echo ""; }

# Gate: lint shell + parse python. Keep it green before integrating.
fleet_gate() {
  rc=0
  for f in $(git ls-files '*.sh' 'src/fleet/githooks/*' '.fleet/githooks/*' 'src/fleet/bin/fleet' '.fleet/bin/fleet' 2>/dev/null); do
    [ -f "$f" ] || continue
    sh -n "$f" 2>/dev/null || bash -n "$f" || { echo "  shell syntax error: $f" >&2; rc=1; }
  done
  for f in $(git ls-files '*.py' 2>/dev/null); do
    python3 -m py_compile "$f" 2>/dev/null || { echo "  python parse error: $f" >&2; rc=1; }
  done
  [ "$rc" = 0 ] && echo "  gate: shell + python OK"
  return $rc
}
