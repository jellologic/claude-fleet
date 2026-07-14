#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
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

# --- Named mkdir mutex (locks under .fleet/locks/) --------------------------------
# The lock dir holds an `owner` file: "<host>:<pid>:<nonce>". That token is what makes
# the mutex safe:
#   * unlock is OWNERSHIP-CHECKED — we only remove a lock whose owner file is still OUR
#     token, so a holder that was wrongly broken can never delete its successor's lock
#     (the old unconditional `rmdir` cascaded: every unlock freed a stranger's lock).
#   * a stale lock is only broken if the holder is provably GONE (`kill -0` on this host)
#     — age alone no longer means "dead", so a slow-but-live holder (cold `git worktree
#     add`, swap, SIGSTOP) keeps its lock instead of being evicted mid-critical-section.
#   * the break is serialized by a nested `.breaking` mutex and performed as an atomic
#     `mv` aside, so two waiters that both saw the same stale lock cannot both win — the
#     loser re-checks under the break mutex, sees a fresh lock, and goes back to waiting.
# Staleness window (seconds) — only used to decide when a lock is worth *inspecting*;
# an inspected-but-alive holder is never broken. Overridable (tests use a short window).
: "${FLEET_LOCK_STALE_SECS:=60}"

_coord_host() { hostname 2>/dev/null || echo unknown; }
_coord_locks_dir() { echo "$(repo_root)/.fleet/locks"; }
# bash 3.2 has no associative arrays: remember our token in a name-mangled scalar.
_coord_tokvar() { echo "_COORD_TOKEN_$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; }
_coord_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Break "$1" ONLY if it is both stale and provably abandoned. Never rmdir's a path a
# racer may have re-created: the whole decision runs under the `.breaking` mutex and the
# removal is an atomic rename out of the way.
_coord_break_stale() {  # $1 = lock dir
  local lock="$1" brk="$1.breaking" mtime now owner ohost opid dead
  mtime="$(_coord_mtime "$lock")"; now="$(date +%s)"
  [ "$mtime" -gt 0 ] || return 0
  [ $((now - mtime)) -gt "$FLEET_LOCK_STALE_SECS" ] || return 0   # young → hands off

  if ! mkdir "$brk" 2>/dev/null; then
    # Someone else is breaking. Reclaim only a *abandoned* breaker (the break section is
    # a handful of syscalls; older than the stale window means its owner died in it).
    mtime="$(_coord_mtime "$brk")"
    if [ "$mtime" -gt 0 ] && [ $(($(date +%s) - mtime)) -gt "$FLEET_LOCK_STALE_SECS" ]; then
      dead="$brk.abandoned.$(_fleet_id)"; mv "$brk" "$dead" 2>/dev/null && rm -rf "$dead"
    fi
    return 0                       # let the winner finish; we retry on the next tick
  fi

  # Under the break mutex: RE-CHECK. A racer may have broken + re-acquired since our
  # snapshot above, in which case the lock we see now is young and belongs to someone
  # alive — this is the re-read that kills the two-waiter double-break.
  mtime="$(_coord_mtime "$lock")"; now="$(date +%s)"
  if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt "$FLEET_LOCK_STALE_SECS" ]; then
    owner="$(cat "$lock/owner" 2>/dev/null || echo "")"
    ohost="${owner%%:*}"; opid="${owner#*:}"; opid="${opid%%:*}"
    if [ -n "$owner" ] && [ "$ohost" = "$(_coord_host)" ]; then
      case "$opid" in
        ''|*[!0-9]*) : ;;                                    # malformed → treat as dead
        *) if kill -0 "$opid" 2>/dev/null; then rmdir "$brk"; return 0; fi ;;  # ALIVE → keep waiting
      esac
    fi
    # Provably dead, on another host, or an unreadable owner on a stale dir → reclaim.
    dead="$lock.stale.$(_fleet_id)"
    if mv "$lock" "$dead" 2>/dev/null; then
      echo "coord: broke stale lock $(basename "$lock") (owner '${owner:-unknown}' gone)" >&2
      rm -rf "$dead"
    fi
  fi
  rmdir "$brk"
}

_coord_lock() {  # $1 = lock name
  local dir lock tries=0 token
  dir="$(_coord_locks_dir)"; lock="$dir/$1.lock"; mkdir -p "$dir"
  token="$(_coord_host):$$:$(_fleet_id)"
  while ! mkdir "$lock" 2>/dev/null; do
    _coord_break_stale "$lock"
    tries=$((tries + 1)); [ "$tries" -gt 2400 ] && { echo "coord: $1 lock timeout" >&2; return 1; }
    sleep 0.05
  done
  printf '%s\n' "$token" > "$lock/owner"
  eval "$(_coord_tokvar "$1")=\$token"
}

# Refuses to remove a lock that is no longer ours — returns 1 and warns instead. Without
# this, a holder that overran the stale window would delete the lock of whoever broke it,
# and every subsequent unlock would free a stranger's lock (permanent mutex failure).
_coord_unlock() {  # $1 = lock name
  local lock var mine cur
  lock="$(_coord_locks_dir)/$1.lock"; var="$(_coord_tokvar "$1")"
  eval "mine=\${$var:-}"; eval "unset $var"
  [ -d "$lock" ] || return 0                                   # already gone (broken as stale)
  cur="$(cat "$lock/owner" 2>/dev/null || echo "")"
  if [ -z "$mine" ] || [ "$cur" != "$mine" ]; then
    echo "coord: refusing to unlock '$1' — lock was stolen (now held by '${cur:-unknown}', not us '${mine:-none}')" >&2
    return 1
  fi
  rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || rm -rf "$lock"
}
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
  _ledger_unlock || true; return $rc   # a stolen-lock warning must not mask awk's status
}
ledger_remove() {
  local issue="$1" f tmp rc=0
  f="$(repo_root)/WORKTREES.md"; [ -f "$f" ] || return 0
  _ledger_lock || return 1
  tmp="$(mktemp)"
  awk -v pat="| #$issue |" 'index($0, pat)==1 { next } { print }' "$f" > "$tmp" && mv "$tmp" "$f" || rc=1
  _ledger_unlock || true; return $rc   # a stolen-lock warning must not mask awk's status
}
