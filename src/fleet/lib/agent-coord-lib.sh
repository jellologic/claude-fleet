#!/usr/bin/env bash
# claude-fleet coordination library — sourced by the bin/ scripts.
# Stack-agnostic: locks, ledger, repo-root resolution, config loading.

# Resolve the PRIMARY checkout root even from inside a linked worktree.
repo_root() {
  local cd
  cd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd" in /*) : ;; *) cd="$(git rev-parse --show-toplevel)/$cd" ;; esac
  cd="${cd%/.git}"; cd="${cd%/}"
  echo "${cd:-/}"
}

# Load per-repo config (defines fleet_bootstrap/fleet_gate/fleet_pkg_for + FLEET_* vars).
_FLEET_ROOT="$(repo_root 2>/dev/null || echo "")"
[ -n "$_FLEET_ROOT" ] && [ -f "$_FLEET_ROOT/.fleet/config.sh" ] && . "$_FLEET_ROOT/.fleet/config.sh"

# Defaults for anything config did not set.
: "${FLEET_MAIN:=main}"
: "${FLEET_PROTECTED_RE:=^(main|master|release/.*)$}"
: "${FLEET_BRANCH_RE:=^(agent|worktree|pr|lockfile|chore|feat|feature|fix)[/-]}"
: "${FLEET_LOCK_BRANCH_RE:=^(lockfile|chore)[/-]}"
: "${FLEET_LOCKFILE:=}"
: "${FLEET_DEP_MANIFEST:=**/package.json}"
: "${FLEET_GENERATED_RE:=}"
: "${FLEET_ENV_FILES:=.env .env.local .env.development .env.development.local}"
: "${FLEET_LABEL_READY:=agent-ready}"
: "${FLEET_LABEL_WORKING:=agent-working}"
LABEL_READY="$FLEET_LABEL_READY"; LABEL_WORKING="$FLEET_LABEL_WORKING"
export FLEET_LOCKFILE FLEET_DEP_MANIFEST

# Fallback hook implementations if the config didn't define them.
type fleet_bootstrap >/dev/null 2>&1 || fleet_bootstrap() { echo "  (no fleet_bootstrap configured in .fleet/config.sh)" >&2; }
type fleet_gate      >/dev/null 2>&1 || fleet_gate()      { echo "    WARNING: no fleet_gate configured — treating as PASS" >&2; return 0; }
type fleet_pkg_for   >/dev/null 2>&1 || fleet_pkg_for()   { echo ""; }

die() { echo "error: $*" >&2; exit 1; }
branch_for_issue() { echo "agent/issue-$1"; }
# Unique id without any JS runtime (urandom → hex; fallback to time+pid).
_fleet_id() { head -c4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo "$(date +%s)$$"; }

# --- Named mkdir mutex (locks under .fleet/locks/, stale-broken after 60s) ---
_coord_lock() {  # $1 = lock name
  local dir="$(repo_root)/.fleet/locks" lock; lock="$dir/$1.lock"; mkdir -p "$dir"
  local tries=0 mtime now
  while ! mkdir "$lock" 2>/dev/null; do
    mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt 60 ]; then rmdir "$lock" 2>/dev/null || true; fi
    tries=$((tries + 1)); [ "$tries" -gt 2400 ] && { echo "coord: $1 lock timeout" >&2; return 1; }
    sleep 0.05
  done
}
_coord_unlock() { rmdir "$(repo_root)/.fleet/locks/$1.lock" 2>/dev/null || true; }
_ledger_lock() { _coord_lock ledger; }
_ledger_unlock() { _coord_unlock ledger; }

# --- WORKTREES.md ledger (human-readable mirror; lock is the branch ref) ---
ledger_add() {
  local issue="$1" branch="$2" wt="$3" title="$4" f root rel ts row tmp rc=0
  root="$(repo_root)"; f="$root/WORKTREES.md"; [ -f "$f" ] || return 0
  rel="${wt#"$root"/}"; ts="$(date -u +%Y-%m-%dT%H:%MZ)"
  row="| #$issue | \`$branch\` | \`$rel\` | $title | $ts |"
  _ledger_lock || return 1
  tmp="$(mktemp)"
  awk -v row="$row" '/<!-- AGENT-LEDGER:END -->/ { print row } { print }' "$f" > "$tmp" && mv "$tmp" "$f" || rc=1
  _ledger_unlock; return $rc
}
ledger_remove() {
  local issue="$1" f tmp rc=0
  f="$(repo_root)/WORKTREES.md"; [ -f "$f" ] || return 0
  _ledger_lock || return 1
  tmp="$(mktemp)"
  awk -v pat="| #$issue |" 'index($0, pat)==1 { next } { print }' "$f" > "$tmp" && mv "$tmp" "$f" || rc=1
  _ledger_unlock; return $rc
}
