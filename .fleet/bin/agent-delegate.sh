#!/usr/bin/env bash
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Delegation: hand a self-contained work-unit to a HEADLESS `claude -p` worker running
# INSIDE a fleet worktree. The orchestrator (a stronger model, or a human) reviews the
# output; the worker does the labour. (#23)
#
# Verbs:
#   delegate <wt> "<task>"                        one unit, headless, in that worktree
#   feedback <wt> "<fix…>"                        --resume that worktree's session, IN CONTEXT
#   loop     <wt> --until '<check>' "<task>"      run → check → feed the failure back → repeat
#
# ── Why an OS sandbox and not the Python write-guard ──────────────────────────────────
# The worker runs with `--dangerously-skip-permissions`. fleet's `PreToolUse` write-guard
# (.claude/hooks/claude-worktree-guard.py) covers Claude's OWN file tools — it does NOT
# bind arbitrary subprocesses. A `Bash` `echo ESCAPED > ../outside.txt`, a `sed -i`, a
# `python3 open(...,'w')` all sail straight through it; Claude Code's own docs say so
# ("deny rules … don't apply to arbitrary subprocesses … For OS-level enforcement, enable
# the sandbox" — code.claude.com/docs/en/permissions). A hook is a Write/Edit-only rail.
# The only thing that binds EVERY descendant of the worker is an OS sandbox, so that is
# the confinement rail here: on macOS, `sandbox-exec` with a generated deny-file-write
# profile. It FAILS CLOSED — no sandbox, no worker.
#
# ── Provider-agnostic by construction ─────────────────────────────────────────────────
# ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN are GLOBAL PER PROCESS: you cannot route one
# model tier to one provider and another tier elsewhere inside a single Claude Code
# process. Delegation works precisely BECAUSE the worker is a SEPARATE process — so its
# provider is whatever FLEET_WORKER_* says, independent of the orchestrator's. See
# examples/worker-zai.env.example.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/agent-coord-lib.sh"

: "${FLEET_DELEGATE_SANDBOX:=1}"      # 1 = require an OS sandbox (fail closed). 0 = loud opt-out.
: "${FLEET_DELEGATE_SANDBOX_EXEC:=/usr/bin/sandbox-exec}"
: "${FLEET_DELEGATE_RETRIES:=4}"      # attempts per worker invocation (back-pressure, RFC part 3)
: "${FLEET_DELEGATE_MAX_ITERS:=3}"    # default `loop --max-iters`
: "${FLEET_WORKER_TIMEOUT_MS:=3000000}"

usage() {
  cat <<'EOF'
usage: fleet delegate <verb> [args]
  delegate <worktree> "<task>"                       run one unit headless in that worktree
  feedback <worktree> "<fix…>"                       resume that worktree's session, in context
  loop     <worktree> --until '<check>' "<task>" [--max-iters N]
                                                     run → check → feed failure back → repeat

worktree: an absolute path, or a name under .fleet/worktrees/ (e.g. `agent/issue-23`).

worker provider (all optional; unset = inherit the ambient Anthropic default):
  FLEET_WORKER_BASE_URL    → ANTHROPIC_BASE_URL
  FLEET_WORKER_TOKEN_FILE  → mode-600 file holding the bearer token → ANTHROPIC_AUTH_TOKEN
  FLEET_WORKER_TOKEN       → same, from the env (the FILE is preferred)
  FLEET_WORKER_MODEL       → ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL (one endpoint → all tiers)
  FLEET_WORKER_TIMEOUT_MS  → API_TIMEOUT_MS (default 3000000)

confinement:
  FLEET_DELEGATE_SANDBOX=1 (default)  require an OS sandbox; die if unavailable
  FLEET_DELEGATE_SANDBOX=0            LOUD opt-out — the worker is UNCONFINED
  FLEET_DELEGATE_RETRIES=4            attempts per invocation on 429/529/transport errors
EOF
}

# ── worktree resolution ───────────────────────────────────────────────────────────────
ROOT="$(repo_root)" || die "not inside a git repository"

# NOTE: callers MUST invoke this as `wt="$(resolve_wt "$x")" || exit 1`.
# `die` here runs inside the caller's command substitution — i.e. in a SUBSHELL — so it
# can only exit that subshell. This script deliberately does not `set -e` (the worker's
# non-zero exits are handled explicitly), which means a bare `wt="$(resolve_wt bogus)"`
# would print the error, assign an EMPTY string, and sail on to build a sandbox profile
# with an empty confinement path. Fail closed: check the status at every call site.
resolve_wt() {  # $1 = path or name → absolute, physical path
  local a="$1" p
  case "$a" in
    /*) p="$a" ;;
    *)  if [ -d "$ROOT/.fleet/worktrees/$a" ]; then p="$ROOT/.fleet/worktrees/$a"
        elif [ -d "$a" ]; then p="$a"
        else die "no such worktree: $a (looked in .fleet/worktrees/ and as a path)"; fi ;;
  esac
  [ -d "$p" ] || die "no such worktree: $a"
  ( cd "$p" && pwd -P )
}

# State (session ids) lives under .fleet/delegate/<slug>/ — gitignored, like .fleet/locks/.
state_dir() {  # $1 = absolute worktree path
  local slug; slug="${1#"$ROOT"/.fleet/worktrees/}"; slug="${slug#/}"
  slug="$(echo "$slug" | tr '/' '-' | tr -cd '[:alnum:]._-')"
  echo "$ROOT/.fleet/delegate/${slug:-default}"
}

# ── the sandbox (RFC 2a) ──────────────────────────────────────────────────────────────
# Generated SBPL profile. SBPL is LAST-MATCH-WINS, which the tail of this profile relies
# on: the broad /tmp + $TMPDIR allow (toolchains genuinely need it) would otherwise punch
# a hole straight through confinement for any repo that happens to live under /tmp or
# $TMPDIR — so the repo root and every SIBLING worktree are re-denied AFTERWARDS, and only
# this worktree + the shared git dir are re-allowed. Order here is load-bearing.
sandbox_profile() {  # $1 = worktree, $2 = profile path to write
  local wt="$1" out="$2" common gitroot w rw sibs=""
  common="$(cd "$(git -C "$wt" rev-parse --git-common-dir)" && pwd -P)" \
    || die "cannot resolve the shared git dir for $wt"
  gitroot="${common%/.git}"

  # Every OTHER worktree git knows about — denied explicitly, so confinement does not
  # depend on siblings happening to live under the repo root.
  for w in $(git -C "$wt" worktree list --porcelain | awk '$1=="worktree"{print $2}'); do
    rw="$(cd "$w" 2>/dev/null && pwd -P)" || continue
    [ "$rw" = "$wt" ] && continue
    sibs="$sibs (subpath \"$rw\")"
  done

  {
    echo '(version 1)'
    echo '(allow default)'
    echo '(deny file-write*)'
    echo "(allow file-write* (subpath \"$wt\"))"
    # The shared .git common dir: git MUST write here from a linked worktree (objects,
    # refs, logs, and .git/worktrees/<name>/{HEAD,index}) or `git commit` cannot work.
    echo "(allow file-write* (subpath \"$common\"))"
    # Scratch + the caches Claude Code and the toolchain need.
    echo '(allow file-write* (subpath "/tmp") (subpath "/private/tmp") (subpath "/var/folders") (subpath "/private/var/folders"))'
    [ -n "${TMPDIR:-}" ] && echo "(allow file-write* (subpath \"${TMPDIR%/}\"))"
    echo "(allow file-write* (subpath \"$HOME/.claude\") (subpath \"$HOME/.cache\") (subpath \"$HOME/.npm\"))"
    echo '(allow file-write-data (regex #"^/dev/"))'
    echo '(allow file-ioctl)'
    # ---- LAST WORD (see the note above): the repo, and every sibling worktree, are
    # ---- denied even if they live under /tmp or $TMPDIR. Then this worktree is restored.
    echo "(deny file-write* (subpath \"$gitroot\"))"
    [ -n "$sibs" ] && echo "(deny file-write*$sibs)"
    echo "(allow file-write* (subpath \"$wt\"))"
    echo "(allow file-write* (subpath \"$common\"))"
  } > "$out"
}

# Emits the sandbox command PREFIX (as positional args) into the global SANDBOX_ARGV, or
# dies. Fail closed: sandboxing is on unless someone explicitly, loudly turns it off.
SANDBOX_ARGV=""
sandbox_prefix() {  # $1 = worktree, $2 = profile path
  SANDBOX_ARGV=""
  if [ "$FLEET_DELEGATE_SANDBOX" = "0" ]; then
    echo "  ****************************************************************" >&2
    echo "  * WARNING: FLEET_DELEGATE_SANDBOX=0 — the worker is UNCONFINED. *" >&2
    echo "  * It runs with --dangerously-skip-permissions and NOTHING stops *" >&2
    echo "  * a subprocess of it writing anywhere on this filesystem: your  *" >&2
    echo "  * other worktrees, main, ~/.ssh. fleet's Python write-guard does*" >&2
    echo "  * NOT bind subprocesses. Do not do this outside a throwaway box. *" >&2
    echo "  ****************************************************************" >&2
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      [ -x "$FLEET_DELEGATE_SANDBOX_EXEC" ] || die "FLEET_DELEGATE_SANDBOX=1 but $FLEET_DELEGATE_SANDBOX_EXEC is missing — refusing to run a --dangerously-skip-permissions worker unconfined"
      sandbox_profile "$1" "$2"
      SANDBOX_ARGV="$FLEET_DELEGATE_SANDBOX_EXEC -f $2"
      ;;
    *)
      die "FLEET_DELEGATE_SANDBOX=1 but this platform ($(uname -s)) has no supported OS sandbox.
  A --dangerously-skip-permissions worker is NOT confined by fleet's Python write-guard —
  that hook binds Claude's Write/Edit tools only, never its subprocesses. The portable path
  is Claude Code's native sandbox (code.claude.com/docs/en/sandboxing) with
  allowUnsandboxedCommands:false + failIfUnavailable:true. fleet will not fake confinement:
  set FLEET_DELEGATE_SANDBOX=0 only if you accept an UNCONFINED worker."
      ;;
  esac
}

# ── worker invocation ─────────────────────────────────────────────────────────────────
# NEVER `--bare`. Docs: "--bare … skip[s] auto-discovery of hooks, skills, plugins, MCP
# servers … will become the default for -p in a future release" (code.claude.com/docs/en/
# headless). A routine Claude Code upgrade would then silently turn every fleet hook-rail
# into a no-op for headless agents. We pass an explicit verb list and never forward --bare;
# there is no positive "--no-bare" flag today, so the defence is (a) never emit it and
# (b) reject it if a caller tries to smuggle it in via FLEET_DELEGATE_CLAUDE_ARGS. The
# durable confinement invariant lives in the OS sandbox and the pre-push gate, both of
# which survive --bare.
: "${FLEET_DELEGATE_CLAUDE_ARGS:=}"
case " $FLEET_DELEGATE_CLAUDE_ARGS " in
  *" --bare "*) die "--bare disables ALL hooks (and is slated to become the -p default). fleet will not launch a headless worker with it." ;;
esac

# Transient transport / overload errors ONLY. A worker that ran and simply failed the task
# is NOT retried — that is a job for `feedback`/`loop`, not for a retry.
_TRANSIENT_RE='429|529|rate.?limit|overloaded|Overloaded|too many requests|502|503|504|Bad Gateway|Service Unavailable|Gateway Time-?out|Connection reset|Connection refused|ECONNRESET|ETIMEDOUT|EAI_AGAIN|socket hang up|network error'

# Read the worker's bearer token WITHOUT ever putting it on a command line. The file is
# preferred over the env; a non-600 file is a loud warning (a token readable by every
# process on the box is not a secret).
worker_token() {
  local f="${FLEET_WORKER_TOKEN_FILE:-}" mode
  if [ -n "$f" ]; then
    [ -f "$f" ] || die "FLEET_WORKER_TOKEN_FILE=$f does not exist"
    mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null || echo '')"
    if [ -n "$mode" ] && [ "$mode" != "600" ]; then
      echo "  WARNING: $f is mode $mode, not 600 — a worker token readable by other users/processes is not a secret. chmod 600 it." >&2
    fi
    # tr -d strips the trailing newline without a subshell that could land in `ps`.
    tr -d '\r\n' < "$f"
    return 0
  fi
  [ -n "${FLEET_WORKER_TOKEN:-}" ] && printf '%s' "$FLEET_WORKER_TOKEN"
  return 0
}

# Describe the worker's provider WITHOUT ever printing the token.
worker_banner() {
  local url="${FLEET_WORKER_BASE_URL:-<ambient Anthropic default>}"
  local model="${FLEET_WORKER_MODEL:-<provider default>}"
  local auth="inherited"
  [ -n "${FLEET_WORKER_TOKEN_FILE:-}" ] && auth="file:${FLEET_WORKER_TOKEN_FILE} (redacted)"
  [ -z "${FLEET_WORKER_TOKEN_FILE:-}" ] && [ -n "${FLEET_WORKER_TOKEN:-}" ] && auth="env:FLEET_WORKER_TOKEN (redacted)"
  echo "  worker: endpoint=$url model=$model auth=$auth timeout=${FLEET_WORKER_TIMEOUT_MS}ms"
}

_json_get() {  # $1 = json file, $2 = dotted key → prints value or empty
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
cur = d
for k in sys.argv[2].split('.'):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(0)
if cur is None: sys.exit(0)
print(cur if not isinstance(cur,(dict,list)) else json.dumps(cur))
PY
}

# run_worker <worktree> <profile> <outfile> <prompt> [resume_session_id]
# → 0 on a worker that ran, non-zero on a worker that could not be run. The JSON body
#   lands in <outfile>. Retries ONLY transient transport failures, with jittered
#   exponential backoff (RFC part 3 — a headless fleet against a hosted gateway WILL see
#   429/529 and a transient overload must not kill a unit).
run_worker() {
  local wt="$1" prof="$2" out="$3" prompt="$4" resume="${5:-}"
  local attempt=1 rc errf combined sleep_s tok

  errf="$(mktemp)"
  tok="$(worker_token)"

  while :; do
    : > "$out"
    (
      # The provider is configured ENTIRELY through the child's environment — never argv,
      # so the token cannot show up in `ps`, in a log, or in a crash dump of this shell.
      [ -n "${FLEET_WORKER_BASE_URL:-}" ] && export ANTHROPIC_BASE_URL="$FLEET_WORKER_BASE_URL"
      [ -n "$tok" ] && export ANTHROPIC_AUTH_TOKEN="$tok"
      if [ -n "${FLEET_WORKER_MODEL:-}" ]; then
        # ONE endpoint per process → every tier must point at the same model, or a
        # Sonnet-tier subagent would be dispatched to a model this gateway does not serve.
        export ANTHROPIC_DEFAULT_OPUS_MODEL="$FLEET_WORKER_MODEL"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="$FLEET_WORKER_MODEL"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="$FLEET_WORKER_MODEL"
        export ANTHROPIC_MODEL="$FLEET_WORKER_MODEL"
      fi
      export API_TIMEOUT_MS="$FLEET_WORKER_TIMEOUT_MS"
      cd "$wt" || exit 97
      # shellcheck disable=SC2086
      if [ -n "$resume" ]; then
        exec $SANDBOX_ARGV claude --resume "$resume" -p "$prompt" \
          --output-format json --dangerously-skip-permissions $FLEET_DELEGATE_CLAUDE_ARGS
      else
        exec $SANDBOX_ARGV claude -p "$prompt" \
          --output-format json --dangerously-skip-permissions $FLEET_DELEGATE_CLAUDE_ARGS
      fi
    ) > "$out" 2> "$errf"
    rc=$?

    [ "$rc" -eq 0 ] && { cat "$errf" >&2; rm -f "$errf"; return 0; }

    combined="$(cat "$out" "$errf" 2>/dev/null)"
    if echo "$combined" | grep -qE "$_TRANSIENT_RE" && [ "$attempt" -lt "$FLEET_DELEGATE_RETRIES" ]; then
      # Exponential backoff with full jitter, capped. FLEET_DELEGATE_BACKOFF_MS scales the
      # base so the negative tests can exercise the retry path without sleeping for real.
      sleep_s="$(python3 -c "import random;print(round(random.uniform(0, min(30000, ${FLEET_DELEGATE_BACKOFF_MS:-1000} * (2 ** ($attempt - 1)))) / 1000.0, 3))" 2>/dev/null || echo 1)"
      echo "  back-pressure: worker hit a transient error (attempt $attempt/$FLEET_DELEGATE_RETRIES) — retrying in ${sleep_s}s" >&2
      sleep "$sleep_s"
      attempt=$((attempt + 1))
      continue
    fi
    # Not transient (or out of attempts): a real failure. Surface it, do not paper over it.
    cat "$errf" >&2; rm -f "$errf"
    return "$rc"
  done
}

# Print the worker's result + cost. Returns non-zero if the worker reported is_error.
report() {  # $1 = json file
  local res err cost turns dur sid
  sid="$(_json_get "$1" session_id)"
  res="$(_json_get "$1" result)"
  err="$(_json_get "$1" is_error)"
  cost="$(_json_get "$1" total_cost_usd)"
  turns="$(_json_get "$1" num_turns)"
  dur="$(_json_get "$1" duration_ms)"
  echo "  session: ${sid:-<none>}"
  [ -n "$cost" ] && echo "  cost: \$${cost}  turns: ${turns:-?}  duration: ${dur:-?}ms"
  if [ -n "$res" ]; then
    echo "  result:"
    echo "$res" | sed 's/^/    | /'
  fi
  case "$err" in True|true) return 1 ;; esac
  return 0
}

# delegate_once <worktree> <prompt> [resume_sid] → 0 ok / non-zero worker failed
delegate_once() {
  local wt="$1" prompt="$2" resume="${3:-}" sd prof out rc sid
  sd="$(state_dir "$wt")"; mkdir -p "$sd"
  prof="$(mktemp -t fleet-sb)"
  out="$(mktemp -t fleet-out)"
  sandbox_prefix "$wt" "$prof"
  [ -n "$SANDBOX_ARGV" ] && echo "  sandbox: sandbox-exec (writes confined to $wt + the shared .git)"
  worker_banner

  run_worker "$wt" "$prof" "$out" "$prompt" "$resume"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  worker could not be run (exit $rc)" >&2
    [ -s "$out" ] && sed 's/^/    | /' "$out" >&2
    rm -f "$prof" "$out"; return "$rc"
  fi

  sid="$(_json_get "$out" session_id)"
  [ -n "$sid" ] && printf '%s\n' "$sid" > "$sd/session"
  report "$out"; rc=$?
  rm -f "$prof" "$out"
  return "$rc"
}

# ── verbs ────────────────────────────────────────────────────────────────────────────
cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
  delegate)
    wt="$(resolve_wt "${1:?usage: fleet delegate delegate <worktree> \"<task>\"}")" || exit 1; shift
    task="${1:?usage: fleet delegate delegate <worktree> \"<task>\"}"
    echo "delegate → $wt"
    delegate_once "$wt" "$task" || die "worker failed"
    echo "  OK"
    ;;

  feedback)
    wt="$(resolve_wt "${1:?usage: fleet delegate feedback <worktree> \"<fix…>\"}")" || exit 1; shift
    fix="${1:?usage: fleet delegate feedback <worktree> \"<fix…>\"}"
    sd="$(state_dir "$wt")"
    [ -f "$sd/session" ] || die "no delegate session for $wt — run \`fleet delegate delegate\` first"
    sid="$(cat "$sd/session")"
    echo "feedback → $wt (resuming session $sid — IN CONTEXT, not a cold start)"
    delegate_once "$wt" "$fix" "$sid" || die "worker failed"
    echo "  OK"
    ;;

  loop)
    wt="$(resolve_wt "${1:?usage: fleet delegate loop <worktree> --until '<check>' \"<task>\"}")" || exit 1; shift
    check=""; max="$FLEET_DELEGATE_MAX_ITERS"; task=""
    while [ $# -gt 0 ]; do case "$1" in
      --until)     check="${2:?--until needs a shell check}"; shift 2 ;;
      --max-iters) max="${2:?--max-iters needs N}"; shift 2 ;;
      -*)          die "unknown arg: $1" ;;
      *)           task="$1"; shift ;;
    esac; done
    [ -n "$check" ] || die "loop needs --until '<shell check>'"
    [ -n "$task" ]  || die "loop needs a task"

    echo "loop → $wt (max $max iterations)"
    echo "  oracle: $check"
    i=1; sid=""; last=""; sid_prompt=""; crc=0
    while [ "$i" -le "$max" ]; do
      echo "  --- iteration $i/$max"
      if [ -z "$sid" ]; then
        delegate_once "$wt" "$task" || echo "  (worker reported a failure — running the check anyway)"
      else
        delegate_once "$wt" "$sid_prompt" "$sid" || echo "  (worker reported a failure — running the check anyway)"
      fi
      sd="$(state_dir "$wt")"; [ -f "$sd/session" ] && sid="$(cat "$sd/session")"

      # The ORACLE runs UNSANDBOXED, in the worktree: it is the orchestrator's own trusted
      # check, not worker-authored code, and correctness is gated by it rather than by
      # trusting the worker (cf. the Bun Zig→Rust port + Anthropic's C-compiler).
      echo "  --- check"
      last="$( cd "$wt" && sh -c "$check" 2>&1 )"; crc=$?
      if [ "$crc" -eq 0 ]; then
        echo "$last" | sed 's/^/    | /'
        echo "  check GREEN after $i iteration(s)"
        exit 0
      fi
      echo "$last" | sed 's/^/    | /'
      echo "  check RED (exit $crc)"
      # Feed the failure straight back into the SAME session — in context.
      sid_prompt="The check \`$check\` still fails. Fix it. Output:
$last"
      i=$((i + 1))
    done
    echo "" >&2
    echo "ESCALATE: check never went green in $max iteration(s). Last failure:" >&2
    echo "$last" | sed 's/^/    | /' >&2
    exit 1
    ;;

  # `review <wt> --reviewers N` (adversarial diff-only reviewers) and `fanout <manifest>
  # --jobs N` (concurrency-capped independent units) are the other two RFC verbs. Both are
  # OUT OF SCOPE for this PR and land as follow-ups — they compose on top of these three.
  review|fanout)
    die "\`$cmd\` is not implemented yet — it is a follow-up to #23 (this PR ships delegate/feedback/loop)"
    ;;

  ""|-h|--help) usage ;;
  *) echo "unknown delegate verb: $cmd (try: fleet delegate --help)" >&2; exit 2 ;;
esac
