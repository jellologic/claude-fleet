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
#   review   <wt> [--reviewers N] [--base <ref>]  N adversarial diff-only reviewers → EVIDENCE
#
# ── `review`: reviewers produce EVIDENCE, the gate produces VERDICTS (#36) ─────────────
# Bun ran exactly this loop over a 535k-line Zig→Rust port (bun.com/blog/bun-in-rust):
# "1 implementer, 2 or more adversarial reviewers per implementer. The reviewer's only job:
# find bugs & reasons why the code does not work" — and the reviewer "gets the diff and
# nothing else — none of the implementer's reasoning". Hence: N=2 by default, CONTEXT-
# ASYMMETRIC input (the diff, never the implementer's session/transcript/rationale), and a
# REFUTE-framed prompt.
#
# But review was NEVER Bun's correctness gate: that was `cargo check` plus a suite with
# 1,386,826 assertions. Anthropic's C compiler used differential testing against GCC. The
# LLM-as-judge literature is damning on using a reviewer AS a gate (judge-vs-oracle Cohen's
# kappa 0.21/0.10; ten reviewers unanimously endorsed a padding oracle that did not exist —
# killed by ONE instance that actually compiled the code and ran three tests). The single
# intervention with a measured ~3x improvement is the FIX-GUIDED VERIFICATION FILTER: make
# every finding ship a runnable artifact, then let the REAL test suite adjudicate
# original-vs-patched.
#
# So `review`:
#   * gives each reviewer the DIFF and nothing else, with the filesystem READ-ONLY;
#   * DISCARDS any finding with no executable artifact (a repro or a patch) — that class,
#     "vague logic error with no falsifiable counterexample", is precisely what LLM
#     reviewers over-produce;
#   * ADJUDICATES every surviving finding in a THROWAWAY worktree: a `repro` that PASSES on
#     HEAD is REFUTED; a `patch` that does not apply, or that leaves `fleet_gate`'s outcome
#     unchanged, is UNSUBSTANTIATED;
#   * NEVER BLOCKS. Its exit code says whether the review RAN, not whether the code is good.
#     `fleet_gate` / the pre-push hook is the gate. `review` is advisory evidence.
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
: "${FLEET_REVIEW_REVIEWERS:=2}"      # Bun's number. Spend budget on DECORRELATION, not count.

usage() {
  cat <<'EOF'
usage: fleet delegate <verb> [args]
  delegate <worktree> "<task>"                       run one unit headless in that worktree
  feedback <worktree> "<fix…>"                       resume that worktree's session, in context
  loop     <worktree> --until '<check>' "<task>" [--max-iters N]
                                                     run → check → feed failure back → repeat
  review   <worktree> [--reviewers N] [--base <ref>]
                                                     N (default 2) ADVERSARIAL, READ-ONLY,
                                                     diff-only reviewers. Every finding must
                                                     ship a repro or a patch; the artifact is
                                                     EXECUTED in a throwaway worktree and
                                                     adjudicated by `fleet_gate`. ALWAYS exits
                                                     0 when the review RAN — review is advisory
                                                     EVIDENCE; the GATE is the gate.

worktree: an absolute path, or a name under .fleet/worktrees/ (e.g. `agent/issue-23`).

worker provider (all optional; unset = inherit the ambient Anthropic default):
  FLEET_WORKER_BASE_URL    → ANTHROPIC_BASE_URL
  FLEET_WORKER_TOKEN_FILE  → mode-600 file holding the bearer token → ANTHROPIC_AUTH_TOKEN
  FLEET_WORKER_TOKEN       → same, from the env (the FILE is preferred)
  FLEET_WORKER_MODEL       → ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL (one endpoint → all tiers)
  FLEET_WORKER_TIMEOUT_MS  → API_TIMEOUT_MS (default 3000000)

reviewer provider (each falls back to its FLEET_WORKER_* twin when unset):
  FLEET_REVIEW_BASE_URL / FLEET_REVIEW_TOKEN_FILE / FLEET_REVIEW_TOKEN / FLEET_REVIEW_MODEL
  Point these at a DIFFERENT model family from the worker. Letting the implementer's own
  model grade its own diff is the one thing you must not do (self-preference bias): the
  errors correlate, and a reviewer that shares the implementer's false premise will
  cheerfully confirm it.

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
#
# A THIRD argument switches the profile to READ-ONLY (reviewer) mode: the worktree AND the
# shared .git are DENIED, and the only writable project-adjacent path is the per-reviewer
# scratch dir. That is the one structural difference between a `delegate` worker (which must
# be able to edit and commit) and a `review` reviewer (which must not be able to touch the
# code it is judging — a reviewer that can "fix" the diff is no longer an independent
# observer of it). The last-match-wins ordering matters even more here: the broad /tmp +
# $TMPDIR allow that Claude Code and node genuinely need would otherwise re-open the worktree
# of any repo living under a scratch dir, so worktree/.git are re-denied AFTER it and ONLY
# the scratch dir is re-allowed at the very end.
sandbox_profile() {  # $1 = worktree, $2 = profile path to write, $3 = scratch dir → READ-ONLY mode
  local wt="$1" out="$2" scratch="${3:-}" common gitroot w rw sibs=""
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
    if [ -z "$scratch" ]; then
      echo "(allow file-write* (subpath \"$wt\"))"
      # The shared .git common dir: git MUST write here from a linked worktree (objects,
      # refs, logs, and .git/worktrees/<name>/{HEAD,index}) or `git commit` cannot work.
      echo "(allow file-write* (subpath \"$common\"))"
    fi
    # Scratch + the caches Claude Code and the toolchain need.
    echo '(allow file-write* (subpath "/tmp") (subpath "/private/tmp") (subpath "/var/folders") (subpath "/private/var/folders"))'
    [ -n "${TMPDIR:-}" ] && echo "(allow file-write* (subpath \"${TMPDIR%/}\"))"
    echo "(allow file-write* (subpath \"$HOME/.claude\") (subpath \"$HOME/.cache\") (subpath \"$HOME/.npm\"))"
    echo '(allow file-write-data (regex #"^/dev/"))'
    echo '(allow file-ioctl)'
    # ---- LAST WORD (see the note above): the repo, and every sibling worktree, are
    # ---- denied even if they live under /tmp or $TMPDIR.
    echo "(deny file-write* (subpath \"$gitroot\"))"
    [ -n "$sibs" ] && echo "(deny file-write*$sibs)"
    if [ -n "$scratch" ]; then
      # READ-ONLY reviewer: the worktree and the shared .git stay DENIED — a reviewer cannot
      # mutate, stage, commit or `git checkout` the code it is reviewing. Its findings go in
      # the scratch dir, which is the last word and lives outside the repo.
      echo "(deny file-write* (subpath \"$wt\") (subpath \"$common\"))"
      echo "(allow file-write* (subpath \"$scratch\"))"
    else
      echo "(allow file-write* (subpath \"$wt\"))"
      echo "(allow file-write* (subpath \"$common\"))"
    fi
  } > "$out"
}

# Emits the sandbox command PREFIX (as positional args) into the global SANDBOX_ARGV, or
# dies. Fail closed: sandboxing is on unless someone explicitly, loudly turns it off.
SANDBOX_ARGV=""
sandbox_prefix() {  # $1 = worktree, $2 = profile path, $3 = scratch dir → READ-ONLY mode
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
      sandbox_profile "$1" "$2" "${3:-}"
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

# ── which provider is the CURRENT invocation using? ───────────────────────────────────
# The implementer and the reviewer must be able to be DIFFERENT MODEL FAMILIES — that is
# the decorrelation point of the whole review design, and it is only possible because each
# is a separate process (ANTHROPIC_BASE_URL/_AUTH_TOKEN are global per process). The active
# role's provider is selected into ACTIVE_* once, and run_worker/worker_banner/worker_token
# only ever read ACTIVE_*.
ACTIVE_ROLE="worker"
ACTIVE_BASE_URL=""; ACTIVE_MODEL=""; ACTIVE_TOKEN_FILE=""; ACTIVE_TOKEN=""; ACTIVE_TOKEN_VAR=""
use_worker_provider() {
  ACTIVE_ROLE="worker"
  ACTIVE_BASE_URL="${FLEET_WORKER_BASE_URL:-}"
  ACTIVE_MODEL="${FLEET_WORKER_MODEL:-}"
  ACTIVE_TOKEN_FILE="${FLEET_WORKER_TOKEN_FILE:-}"
  ACTIVE_TOKEN="${FLEET_WORKER_TOKEN:-}"
  ACTIVE_TOKEN_VAR="FLEET_WORKER_TOKEN"
}
# Each FLEET_REVIEW_* falls back to its FLEET_WORKER_* twin. If they end up IDENTICAL the
# implementer's own model is grading its own diff — say so, loudly: self-preference bias is
# the one failure mode this design exists to avoid.
use_review_provider() {
  ACTIVE_ROLE="reviewer"
  ACTIVE_BASE_URL="${FLEET_REVIEW_BASE_URL:-${FLEET_WORKER_BASE_URL:-}}"
  ACTIVE_MODEL="${FLEET_REVIEW_MODEL:-${FLEET_WORKER_MODEL:-}}"
  ACTIVE_TOKEN_FILE="${FLEET_REVIEW_TOKEN_FILE:-${FLEET_WORKER_TOKEN_FILE:-}}"
  ACTIVE_TOKEN="${FLEET_REVIEW_TOKEN:-${FLEET_WORKER_TOKEN:-}}"
  ACTIVE_TOKEN_VAR="FLEET_REVIEW_TOKEN"
}
use_worker_provider

# Read the active role's bearer token WITHOUT ever putting it on a command line. The file is
# preferred over the env; a non-600 file is a loud warning (a token readable by every
# process on the box is not a secret).
worker_token() {
  local f="$ACTIVE_TOKEN_FILE" mode
  if [ -n "$f" ]; then
    [ -f "$f" ] || die "token file $f does not exist"
    mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null || echo '')"
    if [ -n "$mode" ] && [ "$mode" != "600" ]; then
      echo "  WARNING: $f is mode $mode, not 600 — a worker token readable by other users/processes is not a secret. chmod 600 it." >&2
    fi
    # tr -d strips the trailing newline without a subshell that could land in `ps`.
    tr -d '\r\n' < "$f"
    return 0
  fi
  [ -n "$ACTIVE_TOKEN" ] && printf '%s' "$ACTIVE_TOKEN"
  return 0
}

# Describe the active role's provider WITHOUT ever printing the token.
worker_banner() {
  local url="${ACTIVE_BASE_URL:-<ambient Anthropic default>}"
  local model="${ACTIVE_MODEL:-<provider default>}"
  local auth="inherited"
  [ -n "$ACTIVE_TOKEN_FILE" ] && auth="file:${ACTIVE_TOKEN_FILE} (redacted)"
  [ -z "$ACTIVE_TOKEN_FILE" ] && [ -n "$ACTIVE_TOKEN" ] && auth="env:${ACTIVE_TOKEN_VAR} (redacted)"
  echo "  $ACTIVE_ROLE: endpoint=$url model=$model auth=$auth timeout=${FLEET_WORKER_TIMEOUT_MS}ms"
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
      [ -n "$ACTIVE_BASE_URL" ] && export ANTHROPIC_BASE_URL="$ACTIVE_BASE_URL"
      [ -n "$tok" ] && export ANTHROPIC_AUTH_TOKEN="$tok"
      if [ -n "$ACTIVE_MODEL" ]; then
        # ONE endpoint per process → every tier must point at the same model, or a
        # Sonnet-tier subagent would be dispatched to a model this gateway does not serve.
        export ANTHROPIC_DEFAULT_OPUS_MODEL="$ACTIVE_MODEL"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="$ACTIVE_MODEL"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="$ACTIVE_MODEL"
        export ANTHROPIC_MODEL="$ACTIVE_MODEL"
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

# ── review: adversarial, diff-only, read-only reviewers → EVIDENCE (#36) ─────────────
# Resolve the ref to diff against. Default: origin/$FLEET_MAIN, then $FLEET_MAIN.
review_base() {  # $1 = worktree, $2 = explicit --base or ""
  local wt="$1" b="$2" c
  if [ -n "$b" ]; then
    git -C "$wt" rev-parse --verify --quiet "$b^{commit}" >/dev/null \
      || die "--base $b is not a commit in $wt"
    printf '%s' "$b"; return 0
  fi
  for c in "origin/$FLEET_MAIN" "$FLEET_MAIN"; do
    if git -C "$wt" rev-parse --verify --quiet "$c^{commit}" >/dev/null; then
      printf '%s' "$c"; return 0
    fi
  done
  die "cannot resolve a diff base (tried origin/$FLEET_MAIN and $FLEET_MAIN) — pass --base <ref>"
}

# The refute-framed prompt. It carries the DIFF and NOTHING ELSE: no session id, no
# --resume, no transcript, no rationale. Context asymmetry is the point — a reviewer that
# has read the implementer's justification is no longer an independent observer, it is an
# audience.
review_prompt() {  # $1 = scratch dir, $2 = base ref
  cat <<EOF
You are an ADVERSARIAL REVIEWER. You did NOT write this code, and you are deliberately NOT
being shown the implementer's reasoning, transcript, session, or intent. Your ONLY job is to
FIND THE WAY THIS DIFF IS WRONG. Assume it is broken and prove it.

The diff under review (\`git diff $2...HEAD\`) is at:
    $1/diff.patch
You may READ the whole repository around it. The filesystem is READ-ONLY to you: do not try
to edit, stage, commit or check anything out. The ONLY directory you can write to is
    $1            (also exported as \$FLEET_REVIEW_SCRATCH)

YOU ARE NOT A GATE. \`fleet_gate\` — the real build and test suite, plus the pre-push hook —
decides whether this code merges. You produce EVIDENCE, never verdicts. An assertion with no
runnable artifact is worthless here and will be DISCARDED, not escalated.

EVERY finding MUST ship an executable artifact. Write ONE JSON object per finding to
    $1/findings/<n>.json
using EXACTLY one of these two shapes:

  {"title": "...", "explanation": "...", "repro": "<shell command>"}
      A shell command, run from the repo root, that FAILS (exits non-zero) on the CURRENT
      HEAD and thereby demonstrates the bug. It will be EXECUTED. If it passes, your finding
      is REFUTED and discarded.

  {"title": "...", "explanation": "...", "patch": "<unified diff>"}
      A \`git apply\`-able unified diff (a/… b/… paths) that FIXES the bug. It will be applied
      to a THROWAWAY copy of HEAD and \`fleet_gate\` will adjudicate patched vs unpatched. If it
      does not apply, or if it leaves the gate's outcome unchanged, it is UNSUBSTANTIATED and
      discarded.

If you cannot produce a repro or a patch for a suspicion, DO NOT WRITE IT DOWN. A "vague logic
error with no falsifiable counterexample" is exactly the noise this filter exists to delete.
Reporting ZERO findings is a perfectly good outcome. Reporting a confident, unfalsifiable one
is not.
EOF
}

# Adjudicate ONE finding in the throwaway worktree. Echoes "SUBSTANTIATED\t<how>" or
# "DISCARDED\t<why>". This is the fix-guided verification filter: the REAL gate — not a
# model — decides whether the evidence holds.
review_adjudicate() {  # $1 = finding json, $2 = adj worktree, $3 = baseline gate rc, $4 = scratch
  local f="$1" adj="$2" base_rc="$3" scratch="$4" repro patch pf rc grc log
  repro="$(_json_get "$f" repro)"
  patch="$(_json_get "$f" patch)"
  log="$scratch/adjudication.log"

  git -C "$adj" reset -q --hard HEAD >/dev/null 2>&1
  git -C "$adj" clean -qfd >/dev/null 2>&1

  if [ -n "$repro" ]; then
    # The repro must FAIL on HEAD. A repro that passes does not reproduce anything.
    ( cd "$adj" && sh -c "$repro" ) >>"$log" 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'DISCARDED\tREFUTED: the repro `%s` PASSES (exit 0) on HEAD — the claimed bug does not reproduce\n' "$repro"
    else
      printf 'SUBSTANTIATED\trepro FAILS on HEAD (exit %s): %s\n' "$rc" "$repro"
    fi
    return 0
  fi

  if [ -n "$patch" ]; then
    pf="$scratch/$(basename "$f").patch"
    printf '%s\n' "$patch" > "$pf"
    if ! git -C "$adj" apply --check "$pf" >>"$log" 2>&1; then
      printf 'DISCARDED\tthe patch does not apply to HEAD (git apply --check failed)\n'
      return 0
    fi
    git -C "$adj" apply "$pf" >>"$log" 2>&1 || {
      printf 'DISCARDED\tthe patch does not apply to HEAD (git apply failed)\n'; return 0; }
    grc=0; ( cd "$adj" && fleet_gate ) >>"$log" 2>&1 || grc=$?
    git -C "$adj" reset -q --hard HEAD >/dev/null 2>&1
    git -C "$adj" clean -qfd >/dev/null 2>&1
    if [ "$base_rc" -ne 0 ] && [ "$grc" -eq 0 ]; then
      printf 'SUBSTANTIATED\tthe patch flips fleet_gate RED (%s) → GREEN (0) on a throwaway copy of HEAD\n' "$base_rc"
      return 0
    fi
    if [ "$base_rc" -eq 0 ] && [ "$grc" -ne 0 ]; then
      printf 'DISCARDED\tthe patch BREAKS fleet_gate (0 → %s) — the "fix" is a regression\n' "$grc"
      return 0
    fi
    printf 'DISCARDED\tUNSUBSTANTIATED: fleet_gate outcome UNCHANGED by the patch (unpatched=%s patched=%s) — the real oracle cannot see the claimed bug (fix-guided verification filter)\n' "$base_rc" "$grc"
    return 0
  fi

  printf 'DISCARDED\tNO EXECUTABLE ARTIFACT — neither a repro nor a patch. A vague logic error with no falsifiable counterexample is not a finding.\n'
}

review_run() {  # $1 = worktree, $2 = N reviewers, $3 = base ref or ""
  local wt="$1" n="$2" base="$3"
  local work adj head_sha diff_f i scratch prof out rc f verdict how title
  local n_raw=0 n_sub=0 n_disc=0 base_rc=0

  base="$(review_base "$wt" "$base")" || exit 1
  head_sha="$(git -C "$wt" rev-parse HEAD)" || die "cannot resolve HEAD in $wt"

  work="$(mktemp -d -t fleet-review)"; work="$(cd "$work" && pwd -P)"
  adj="$work/adjudication"
  # shellcheck disable=SC2064
  trap "git -C '$wt' worktree remove --force '$adj' >/dev/null 2>&1; rm -rf '$work'" EXIT INT TERM

  diff_f="$work/diff.patch"
  git -C "$wt" diff "$base...HEAD" > "$diff_f" || die "cannot diff $base...HEAD in $wt"

  echo "review → $wt"
  echo "  base: $base   head: $head_sha   reviewers: $n"
  if [ ! -s "$diff_f" ]; then
    echo "  nothing to review (no diff against $base)"
    exit 0
  fi
  echo "  diff: $(wc -l < "$diff_f" | tr -d ' ') lines"

  use_review_provider
  if [ "$ACTIVE_MODEL" = "${FLEET_WORKER_MODEL:-}" ] && [ "$ACTIVE_BASE_URL" = "${FLEET_WORKER_BASE_URL:-}" ]; then
    echo "  NOTE: the reviewer and the implementer share a provider/model. Errors CORRELATE:" >&2
    echo "        a model grading its own diff is subject to self-preference bias and will" >&2
    echo "        confirm its own false premises. Set FLEET_REVIEW_{MODEL,BASE_URL,TOKEN_FILE}" >&2
    echo "        to a DIFFERENT family. (This is a warning, not an error — review is advisory.)" >&2
  fi

  mkdir -p "$work/findings"
  i=1
  while [ "$i" -le "$n" ]; do
    scratch="$work/reviewer-$i"
    mkdir -p "$scratch/findings"
    cp "$diff_f" "$scratch/diff.patch"
    prof="$work/reviewer-$i.sb"
    out="$work/reviewer-$i.json"

    echo "  --- reviewer $i/$n (adversarial, diff-only, READ-ONLY)"
    sandbox_prefix "$wt" "$prof" "$scratch"
    [ -n "$SANDBOX_ARGV" ] \
      && echo "  sandbox: sandbox-exec — the worktree AND the shared .git are READ-ONLY; writes only to $scratch"
    worker_banner

    # NO session id, NO --resume, NO transcript: the reviewer gets the diff and nothing else.
    export FLEET_REVIEW_SCRATCH="$scratch"
    run_worker "$wt" "$prof" "$out" "$(review_prompt "$scratch" "$base")" ""
    rc=$?
    if [ "$rc" -ne 0 ]; then
      # INFRASTRUCTURE failure — the reviewer could not be RUN. This, and only this, is fatal.
      echo "  reviewer $i could not be run (exit $rc)" >&2
      [ -s "$out" ] && sed 's/^/    | /' "$out" >&2
      exit "$rc"
    fi
    report "$out" || echo "  (reviewer $i reported an error; its findings, if any, are still adjudicated)"

    for f in "$scratch"/findings/*.json; do
      [ -f "$f" ] || continue
      cp "$f" "$work/findings/r$i-$(basename "$f")"
      n_raw=$((n_raw + 1))
    done
    i=$((i + 1))
  done

  echo "  --- adjudication ($n_raw raw finding(s)) — in a THROWAWAY worktree, never in $wt"
  git -C "$wt" worktree add -q --detach "$adj" HEAD \
    || die "cannot create the throwaway adjudication worktree — refusing to adjudicate inside the worktree under review"
  base_rc=0; ( cd "$adj" && fleet_gate ) >"$work/gate-base.log" 2>&1 || base_rc=$?
  echo "  fleet_gate on UNPATCHED HEAD: exit $base_rc  ← the oracle every patch is measured against"

  : > "$work/SUBSTANTIATED"; : > "$work/DISCARDED"
  for f in "$work"/findings/*.json; do
    [ -f "$f" ] || continue
    title="$(_json_get "$f" title)"; [ -n "$title" ] || title="(untitled)"
    verdict="$(review_adjudicate "$f" "$adj" "$base_rc" "$work" | head -1)"
    how="$(printf '%s' "$verdict" | cut -f2-)"
    case "$verdict" in
      SUBSTANTIATED*)
        n_sub=$((n_sub + 1))
        { printf '  [%s] %s\n' "$(basename "$f" .json)" "$title"
          printf '      EVIDENCE : %s\n' "$how"
          printf '      why      : %s\n' "$(_json_get "$f" explanation)"; } >> "$work/SUBSTANTIATED" ;;
      *)
        n_disc=$((n_disc + 1))
        { printf '  [%s] %s\n' "$(basename "$f" .json)" "$title"
          printf '      DISCARDED: %s\n' "$how"; } >> "$work/DISCARDED" ;;
    esac
  done

  echo ""
  echo "══ review report — $wt @ ${head_sha} (base $base) ═══════════════════════════════"
  echo ""
  echo "SUBSTANTIATED ($n_sub of $n_raw) — the evidence ACTUALLY EXECUTED:"
  if [ "$n_sub" -eq 0 ]; then echo "  (none)"; else cat "$work/SUBSTANTIATED"; fi
  echo ""
  echo "DISCARDED ($n_disc of $n_raw) — the evidence did not hold up:"
  if [ "$n_disc" -eq 0 ]; then echo "  (none)"; else cat "$work/DISCARDED"; fi
  echo ""
  echo "  review is ADVISORY EVIDENCE, not a verdict, and it does NOT block: this command"
  echo "  exits 0 whenever the review RAN, findings or no findings. \`fleet_gate\` and the"
  echo "  pre-push hook are THE GATE. Bun reviewed 535k lines with 2 adversarial reviewers"
  echo "  per implementer — and their oracle was still \`cargo check\` + 1.39M test assertions,"
  echo "  never the reviewers. Treat every line above as a lead to verify, not a decision."
  echo "═══════════════════════════════════════════════════════════════════════════════"
  exit 0
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

  review)
    wt="$(resolve_wt "${1:?usage: fleet delegate review <worktree> [--reviewers N] [--base <ref>]}")" || exit 1; shift
    n="$FLEET_REVIEW_REVIEWERS"; base=""
    while [ $# -gt 0 ]; do case "$1" in
      --reviewers) n="${2:?--reviewers needs N}"; shift 2 ;;
      --base)      base="${2:?--base needs a ref}"; shift 2 ;;
      -*)          die "unknown arg: $1" ;;
      *)           die "review takes no task: the reviewer gets the DIFF AND NOTHING ELSE — no brief, no rationale, no session. That asymmetry is the design (unexpected argument: $1)" ;;
    esac; done
    case "$n" in ''|*[!0-9]*) die "--reviewers needs a positive integer" ;; esac
    [ "$n" -ge 1 ] || die "--reviewers needs a positive integer"
    review_run "$wt" "$n" "$base"
    ;;

  # `fanout <manifest> --jobs N` (concurrency-capped independent units) is the last RFC verb;
  # it is OUT OF SCOPE here and lands as a follow-up — it composes on top of these four.
  fanout)
    die "\`fanout\` is not implemented yet — it is a follow-up to #23/#36"
    ;;

  ""|-h|--help) usage ;;
  *) echo "unknown delegate verb: $cmd (try: fleet delegate --help)" >&2; exit 2 ;;
esac
