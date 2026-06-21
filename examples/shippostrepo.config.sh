# Example .fleet/config.sh for a Bun + Turborepo + TanStack Start repo (shippostrepo).
# Copy to .fleet/config.sh in such a project.

FLEET_MAIN="main"
FLEET_LOCKFILE="bun.lock"
FLEET_DEP_MANIFEST="**/package.json"
FLEET_GENERATED_RE='(^|/)routeTree\.gen\.ts$'

# Provision a fresh worktree: install deps + generate the TanStack route tree via a
# short-lived dev server (the @tanstack/react-start plugin emits routeTree.gen.ts).
fleet_bootstrap() {
  bun install
  ( cd apps/web && {
      bun run dev >/dev/null 2>&1 &
      p=$!; i=0
      while [ "$i" -lt 60 ]; do [ -f src/routeTree.gen.ts ] && break; sleep 0.5; i=$((i+1)); done
      kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
    } )
}

# Map a changed path to its turbo package filter (empty = full workspace gate).
fleet_pkg_for() {
  case "$1" in
    apps/web/*)      echo "web" ;;
    packages/core/*) echo "@shippost/core" ;;
    packages/ui/*)   echo "@shippost/ui" ;;
    *)               echo "" ;;
  esac
}

# Gate: scoped check-types + build for the changed packages, full workspace otherwise.
fleet_gate() {
  if [ "$#" -eq 0 ]; then
    bunx turbo run check-types build
  else
    f=""; for u in "$@"; do f="$f --filter=$u"; done
    # shellcheck disable=SC2086
    bunx turbo run check-types build $f
  fi
}
