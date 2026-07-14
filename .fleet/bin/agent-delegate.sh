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
#   fanout   <manifest.json> [--jobs N]           N PROVABLY DISJOINT units, one worktree each
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
# ── worker liveness (#58) ── API_TIMEOUT_MS is an *API* timeout: a worker wedged in a tool
# loop never trips it. These bound the PROCESS.
: "${FLEET_WORKER_WALL_TIMEOUT_S:=3600}"   # hard ceiling on a single worker invocation
# STALL DETECTION IS OFF BY DEFAULT, and that is deliberate (#70).
#
# The worker runs with `--output-format json`, which prints the ENTIRE result at the END, in one
# blob. A perfectly healthy worker therefore produces ZERO incremental output for its whole run.
# An output-growth "stall" detector measuring that stream is measuring NOTHING — "quiet" is always
# true — so a non-zero FLEET_WORKER_STALL_S is not a liveness signal at all. It is a hidden SECOND
# wall-clock timeout that kills any worker slower than the threshold.
#
# It did exactly that: in the #61 experiment it killed healthy `api` workers at 600s, and because
# the arm under test had a longer prompt (and so ran slower), it hit that arm HARDER — corrupting
# the result in the direction of the hypothesis. A monitor whose input is constant is worse than no
# monitor: it fires on the wrong thing, and you believe it.
#
# So: 0 (off) unless the caller opts in, and it is only meaningful once the worker STREAMS
# (`--output-format stream-json`, the follow-up). The WALL-CLOCK timeout below is the real
# protection against a wedged worker, and it does not depend on any output at all.
: "${FLEET_WORKER_STALL_S:=0}"             # 0 = OFF. Only meaningful with a STREAMING output format.
: "${FLEET_WORKER_TICK_S:=30}"             # emit a liveness line this often. 0 disables.
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
  fanout   <manifest.json> [--jobs N] [--dry-run] [--resume] [--base <ref>]
                                                     N units, each a `delegate` run in its OWN
                                                     worktree. REFUSES (exit 2) a manifest whose
                                                     units' `owns` globs are not PROVABLY DISJOINT
                                                     — a cap cannot rescue overlapping work, it
                                                     only makes N agents overwrite each other more
                                                     slowly. Worktrees are created SERIALLY, the
                                                     work runs in parallel. Exits non-zero iff a
                                                     unit failed.

worktree: an absolute path, or a name under .fleet/worktrees/ (e.g. `agent/issue-23`).

fanout manifest (see examples/fanout.example.json + examples/fanout.schema.json):
  { "units": [ { "id": "parser", "owns": ["src/parser/**"], "task": "…" },
               { "id": "codegen", "owns": ["src/codegen/**"], "task": "…" } ] }
  id       [a-z0-9][a-z0-9._-]*  — becomes a branch (agent/fanout/<manifest>/<id>) and a directory
  owns     the unit's file partition. A bare directory means its whole subtree. PAIRWISE DISJOINT
           across units, PROVEN by check-claims.py before anything is launched.
  task     the unit's brief, handed to a headless worker in that unit's worktree.
  branch   (optional) override the derived branch name.
  provides / consumes   (optional, #48) port ids from .fleet/ports.json. Every `consumes` must
           resolve to EXACTLY ONE `provides` — in this manifest, or to a port already frozen on the
           base branch — the provides→consumes DAG must be ACYCLIC, and a port's ARTIFACT is
           READ-ONLY to every unit but its provider. Disjoint FILES do not imply compatible
           INTERFACES. A manifest without them behaves exactly as it always did. See `fleet spec`.

fanout tuning (both defaults are STARTING POINTS, not measured optima):
  --jobs N / FLEET_FANOUT_JOBS        default min(cpu/2, 4). The real ceiling Bun hit at ~64 agents
                                      was DISK and IOPS ("ran out of disk space and crashed"), and
                                      the one Anthropic hit at 16 was task decomposability. Neither
                                      was the model. Tune per machine and instrument it.
  FLEET_FANOUT_DISK_MB_PER_JOB=512    per-worktree estimate for the disk preflight.
  state: .fleet/fanout/<manifest-slug>/ (gitignored) — per-unit pending/running/done/failed + logs.

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

# ── WORKER LIFECYCLE (#58) ────────────────────────────────────────────────────────────
# A worker is a SEPARATE PROCESS that we must own for its whole life. Before this, the
# worker inherited our process group and NOTHING ever killed it: when the supervisor died
# — Ctrl-C, a harness/CI timeout, an interrupted `fanout`, a closed terminal — the worker
# was ORPHANED and kept running with --dangerously-skip-permissions, still writing into the
# worktree. Reproduced: kill the supervisor, and the worker wrote a file afterwards.
#
# The OS sandbox does NOT save you here. It confines writes TO THE WORKTREE — which is
# exactly where the zombie writes. Confinement is not lifecycle. A zombie can mutate a unit
# AFTER `fanout` recorded it done and AFTER `fleet integrate` merged it; the commit and the
# working tree then disagree and nothing notices.
#
# So: every worker is put in its OWN SESSION (os.setsid → pid == pgid), its group id is
# recorded, and EVERY exit path kills the whole GROUP — not just the leader, because
# `claude` spawns children (bash tools, python, a nested claude) that would otherwise
# orphan in turn.
_WORKER_PGIDS=""          # bash 3.2: a space-separated list, not an array

_kill_group() {  # $1 = pgid. TERM the group, grace, then KILL. Never leave a stray.
  local g="$1" i=0
  [ -n "$g" ] || return 0
  kill -TERM "-$g" 2>/dev/null || true
  while kill -0 "-$g" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  kill -KILL "-$g" 2>/dev/null || true
}

reap_workers() {  # every exit path lands here
  local g
  for g in $_WORKER_PGIDS; do _kill_group "$g"; done
  _WORKER_PGIDS=""
}
trap 'reap_workers' EXIT
trap 'echo "  interrupted — killing worker(s)" >&2; reap_workers; exit 130' INT TERM HUP

# Watch a live worker: wall-clock timeout + stall detection + a heartbeat the operator (and
# any other process) can read. API_TIMEOUT_MS is an *API* timeout — a worker wedged in a tool
# loop never trips it, so it is not a liveness signal.
_watch_worker() {  # $1 = pid(=pgid)  $2 = outfile  $3 = errfile  $4 = heartbeat path
  local pid="$1" out="$2" errf="$3" hb="$4"
  local start now size last_size=-1 last_change quiet elapsed
  start="$(date +%s)"; last_change="$start"
  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"; elapsed=$((now - start))
    size=$(( $(wc -c < "$out" 2>/dev/null || echo 0) + $(wc -c < "$errf" 2>/dev/null || echo 0) ))
    if [ "$size" -ne "$last_size" ]; then last_size="$size"; last_change="$now"; fi
    quiet=$((now - last_change))

    # Heartbeat: mtime = last sign of life. Any process can read this, including a
    # supervisor that restarted — it is what lets a stray be detected and reaped later.
    [ -n "$hb" ] && printf 'pgid=%s elapsed=%ss quiet=%ss bytes=%s\n' \
      "$pid" "$elapsed" "$quiet" "$size" > "$hb" 2>/dev/null

    if [ "$elapsed" -ge "$FLEET_WORKER_WALL_TIMEOUT_S" ]; then
      echo "  WALL TIMEOUT after ${elapsed}s — killing the worker's process group" >&2
      _kill_group "$pid"; return 124
    fi
    if [ "$FLEET_WORKER_STALL_S" -gt 0 ] && [ "$quiet" -ge "$FLEET_WORKER_STALL_S" ]; then
      echo "  STALLED: no output for ${quiet}s (elapsed ${elapsed}s) — killing the process group" >&2
      _kill_group "$pid"; return 125
    fi
    # Periodic liveness line, so N parallel workers are not a silent black box.
    if [ "$FLEET_WORKER_TICK_S" -gt 0 ] && [ $((elapsed % FLEET_WORKER_TICK_S)) -eq 0 ] \
       && [ "$elapsed" -gt 0 ]; then
      echo "    · worker alive ${elapsed}s (quiet ${quiet}s, ${size}B)" >&2
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null; return $?
}

# run_worker <worktree> <profile> <outfile> <prompt> [resume_session_id]
# → 0 on a worker that ran, non-zero on a worker that could not be run. The JSON body
#   lands in <outfile>. Retries ONLY transient transport failures, with jittered
#   exponential backoff (RFC part 3 — a headless fleet against a hosted gateway WILL see
#   429/529 and a transient overload must not kill a unit).
run_worker() {
  local wt="$1" prof="$2" out="$3" prompt="$4" resume="${5:-}"
  local attempt=1 rc errf combined sleep_s tok wpid hb

  errf="$(mktemp)"
  tok="$(worker_token)"
  hb="$(state_dir "$wt")/heartbeat"; mkdir -p "$(dirname "$hb")" 2>/dev/null || true

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
      # os.setsid() makes this the leader of a NEW session, so its pid IS its pgid and we can
      # kill the entire tree by group. `setsid(1)` is absent on macOS; python3 is already a
      # hard dependency of fleet, so this is the portable form.
      # shellcheck disable=SC2086
      if [ -n "$resume" ]; then
        exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
          $SANDBOX_ARGV claude --resume "$resume" -p "$prompt" \
          --output-format json --dangerously-skip-permissions $FLEET_DELEGATE_CLAUDE_ARGS
      else
        exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
          $SANDBOX_ARGV claude -p "$prompt" \
          --output-format json --dangerously-skip-permissions $FLEET_DELEGATE_CLAUDE_ARGS
      fi
    ) > "$out" 2> "$errf" &
    wpid=$!
    _WORKER_PGIDS="$_WORKER_PGIDS $wpid"     # so EVERY exit path can reap it
    printf '%s\n' "$wpid" > "$(dirname "$hb")/pgid" 2>/dev/null || true

    _watch_worker "$wpid" "$out" "$errf" "$hb"
    rc=$?
    _kill_group "$wpid"                       # belt and braces: never leave the group alive
    _WORKER_PGIDS="$(printf '%s' "$_WORKER_PGIDS" | tr ' ' '\n' | grep -v "^${wpid}$" | tr '\n' ' ')"
    rm -f "$(dirname "$hb")/pgid" 2>/dev/null || true

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
    # A KILL BY THE SUPERVISOR IS NOT A TASK FAILURE (#70). Say which, distinctly, or a caller —
    # a CI run, an experiment — silently counts an infrastructure kill as a result. That is exactly
    # what happened in #61: healthy workers were killed by a broken stall detector and the trials
    # recorded them as failures of the thing under test.
    case "$rc" in
      124) echo "  WALL-TIMEOUT: the worker exceeded FLEET_WORKER_WALL_TIMEOUT_S (${FLEET_WORKER_WALL_TIMEOUT_S}s) and was killed by the SUPERVISOR." >&2
           echo "               This is NOT a task failure — the unit never got to finish. Exclude it or re-run it." >&2 ;;
      125) echo "  STALL-KILL: the worker was killed by the SUPERVISOR (FLEET_WORKER_STALL_S=${FLEET_WORKER_STALL_S}s)." >&2
           echo "              This is NOT a task failure. NOTE: with --output-format json a healthy worker emits" >&2
           echo "              NOTHING until it finishes, so stall detection is meaningless there and is OFF by" >&2
           echo "              default. If you turned it on, this is very likely a FALSE POSITIVE (#70)." >&2 ;;
      *)   echo "  worker could not be run (exit $rc)" >&2 ;;
    esac
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
review_prompt() {  # $1 = scratch dir, $2 = base ref, $3 = frozen-port block or ""
  cat <<EOF
You are an ADVERSARIAL REVIEWER. You did NOT write this code, and you are deliberately NOT
being shown the implementer's reasoning, transcript, session, or intent. Your ONLY job is to
FIND THE WAY THIS DIFF IS WRONG. Assume it is broken and prove it.

The diff under review (\`git diff $2...HEAD\`) is at:
    $1/diff.patch
${3:+${3}
CONFORMANCE TO THE FROZEN PORT IS A REVIEWABLE QUESTION — and a far better-defined one than "is
this code good?". Bun's reviewers checked conformance to the frozen reference AND behavioural
equivalence, and you must do BOTH. But DO NOT DEGENERATE INTO A SCHEMA LINTER: the type-checker
already checks the signatures, deterministically, for free, and a reviewer that only re-does the
type-checker's job is worth nothing. Your edge is the part a type-checker CANNOT see — a signature
honoured in form and violated in BEHAVIOUR (an error swallowed where the port says it throws, a
null returned where the port says non-null, an ordering/lifetime/concurrency assumption the types
cannot express). Find BUGS. The port is context that makes the bugs easier to name, not a checklist.
}
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
  local work adj head_sha diff_f i scratch prof out rc f verdict how title ports
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

  # FREE WIN (#48): hand the reviewer the FROZEN PORT(s) this unit provides/consumes. Empty unless
  # the worktree is a fanout unit whose manifest declares ports.
  ports="$("$HERE/fleet-spec.sh" context --worktree "$wt" 2>/dev/null || true)"
  [ -n "$ports" ] && echo "  ports: the frozen port artifact(s) for this unit are in the reviewer's prompt"

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
    run_worker "$wt" "$prof" "$out" "$(review_prompt "$scratch" "$base" "$ports")" ""
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

# ── fanout: N disjoint units, concurrency-capped, worktrees created SERIALLY (#37) ────
#
# TWO WALLS, neither of them the model. `fanout` is designed around both.
#
# WALL 1 — parallelism does NOTHING on work that is not genuinely disjoint. Anthropic ran 16
# agents at compiling the Linux kernel with their C compiler (anthropic.com/engineering/
# building-c-compiler): "every agent would hit the same bug, fix that bug, and then overwrite
# each other's changes. Having 16 agents running didn't help because each was stuck solving the
# same task." A concurrency CAP does not help with that at all — N agents on overlapping work
# is strictly WORSE than N=1, because they also destroy each other's edits. So disjointness is a
# PRECONDITION here, PROVEN before anything launches, and a manifest that fails it is REFUSED
# (exit 2) rather than capped-and-hoped. The prover is `check-claims.py` — fleet's existing
# ownership gate — driven with a claims manifest synthesised from the fanout units. We do not
# reimplement glob-overlap logic; there is exactly one such enforcer in this repo and this is it.
#
# WALL 2 — the ceiling is DISK and IOPS, not the model. Bun ran ~64 agents over a 535k-line
# Zig→Rust port (bun.com/blog/bun-in-rust): "The machine ran out of disk space and crashed
# several times anyway", and "One slow `grep` command was all it took to freeze disk reads &
# writes for minutes." Hence: a DISK PREFLIGHT before we create a single worktree, `nice` on
# every worker, `ionice` where it exists (Linux), and a --jobs default derived from CPU count as
# a conservative PROXY for I/O headroom — explicitly a starting point to tune, not a measured
# optimum. No source gives a measured per-repo parallel-agent ceiling; Bun's ~64 and Anthropic's
# 16 are anecdotes from two projects of very different shape.
#
# WALL 3 — concurrent `git worktree add` RACES on the shared .git (RFC part 3: firing 16 at once,
# 4/16 FAILED; created serially, 16/16 succeeded). So worktree creation is SERIAL, and only the
# WORK is parallel. Concurrent commits from separate worktrees are fine.
: "${FLEET_FANOUT_DISK_MB_PER_JOB:=512}"   # per-worktree disk estimate for the preflight
: "${FLEET_FANOUT_JOBS:=}"                 # default: min(cpu/2, 4) — see fanout_default_jobs

die2() { echo "error: $*" >&2; exit 2; }   # 2 = REFUSED at preflight; nothing was launched

# A conservative PROXY for I/O headroom, not a measured optimum. Tune per machine: the real
# ceiling Bun hit was disk/IOPS, and the one Anthropic hit was task decomposability.
fanout_default_jobs() {
  local n
  n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)"
  case "$n" in ''|*[!0-9]*) n=2 ;; esac
  n=$((n / 2))
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt 4 ] && n=4
  echo "$n"
}

fanout_free_mb() {  # $1 = a path on the filesystem to measure
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}'
}

fanout_slug() {  # $1 = manifest path → a filesystem/branch-safe slug
  local b; b="$(basename "$1")"; b="${b%.json}"
  printf '%s' "$b" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' \
    | sed 's/-\{1,\}/-/g; s/^-//; s/-$//'
}

# `nice`, plus `ionice` where it exists. macOS has NO ionice — `nice` alone is all we get there,
# and that governs CPU, not IOPS. Say so rather than pretend. On Linux, prefer cgroups
# (systemd-run --scope -p IOWeight=…) for a real I/O bound; this is the portable floor.
FANOUT_NICE=""
fanout_nice_prefix() {
  FANOUT_NICE="nice -n 10"
  if command -v ionice >/dev/null 2>&1; then
    FANOUT_NICE="ionice -c2 -n7 $FANOUT_NICE"
  fi
}

# The unit prompt. A fanout worker is told, in so many words, that it owns a partition and that
# stepping outside it is the failure mode this whole design exists to prevent.
fanout_prompt() {  # $1 = unit id, $2 = task, $3 = owns (one glob per line), $4 = port block or ""
  cat <<EOF
You are ONE unit of a FANOUT. Several headless agents are working in PARALLEL right now, each in
its own git worktree, on a partition of this repository that has been PROVEN pairwise disjoint
before any of you were launched.

unit: $1

You OWN — and may ONLY create or modify — files matching:
$(printf '%s\n' "$3" | sed 's/^/  - /')

Do NOT touch any file outside that set, for any reason: not a "quick fix", not a shared helper,
not a config file, not a test outside your paths. Another agent owns it and is editing it right
now; your write would be overwritten, or would overwrite theirs. If your task genuinely cannot be
done inside your paths, STOP and say so in your final message — that is a manifest bug, and it is
the correct outcome. Do not widen your own scope.

Commit your work on this worktree's branch when you are done.
${4:-}

TASK:
$2
EOF
}

# Parse + validate the manifest, synthesise the claims manifest, lay out the state dir.
# Prints nothing on success (the state dir IS the output); exits 2 with a reason on a bad manifest.
fanout_prepare() {  # $1 = manifest, $2 = claims out, $3 = state dir, $4 = slug, $5 = base ref
  python3 - "$1" "$2" "$3" "$4" "$5" "$ROOT" <<'PY' || exit 2
import json, os, re, sys

manifest, claims_out, state, slug, base, root = sys.argv[1:7]

def die(msg):
    print(f"error: {manifest}: {msg}", file=sys.stderr)
    sys.exit(2)

try:
    with open(manifest) as fh:
        m = json.load(fh)
except Exception as e:
    die(f"cannot read/parse: {e}")

if not isinstance(m, dict):
    die("top level must be a JSON object")
units = m.get("units")
if not isinstance(units, list) or not units:
    die('"units" must be a non-empty array')

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
WILD = re.compile(r"[*?\[\]{}]")

seen, out = set(), []
for k, u in enumerate(units):
    if not isinstance(u, dict):
        die(f"units[{k}] is not an object")
    uid = u.get("id")
    if not isinstance(uid, str) or not ID_RE.match(uid):
        die(f'units[{k}]: "id" must match {ID_RE.pattern} (it becomes a branch and a directory)')
    if uid in seen:
        die(f'duplicate unit id "{uid}"')
    seen.add(uid)

    owns = u.get("owns")
    if not isinstance(owns, list) or not owns or not all(isinstance(g, str) and g for g in owns):
        die(f'unit "{uid}": "owns" must be a non-empty array of non-empty strings')
    norm = []
    for g in owns:
        if g.startswith("/") or ".." in g.split("/"):
            die(f'unit "{uid}": owns entry "{g}" must be a repo-relative path without ".."')
        # A bare directory means its whole subtree. Spelling it as a glob is what lets the
        # disjointness prover SEE the nesting — `src/parser` and `src/parser/x.c` look unrelated
        # to a literal-vs-literal comparison, `src/parser/**` and `src/parser/x.c` do not.
        if not WILD.search(g) and (g.endswith("/") or os.path.isdir(os.path.join(root, g))):
            g = g.rstrip("/") + "/**"
        norm.append(g)

    task = u.get("task")
    if not isinstance(task, str) or not task.strip():
        die(f'unit "{uid}": "task" must be a non-empty string')

    branch = u.get("branch") or f"agent/fanout/{slug}/{uid}"
    if not isinstance(branch, str):
        die(f'unit "{uid}": "branch" must be a string')

    # PORTS (#48). Optional, and a manifest without them behaves EXACTLY as it did before. They are
    # carried STRAIGHT THROUGH into the synthesised claims so that check-claims.py — fleet's ONE
    # ownership prover, extended and never forked — can run the three static interface proofs
    # (no dangling, no duplicate provider, acyclic DAG) in the SAME pass as the file-disjointness
    # proof. Disjoint FILES do not imply compatible INTERFACES.
    ports = {}
    for rel in ("provides", "consumes"):
        v = u.get(rel, [])
        if not isinstance(v, list) or not all(isinstance(p, str) and p for p in v):
            die(f'unit "{uid}": "{rel}" must be an array of port ids (e.g. ["port:KV"])')
        ports[rel] = v
    out.append({"id": uid, "owns": norm, "task": task, "branch": branch,
                "provides": ports["provides"], "consumes": ports["consumes"]})

# Ownership POLICY (hotFiles / forbidden / branchPattern) comes from the repo's own claims
# manifest, so a fanout unit cannot own a generated path that a normal claim could not own.
policy = {}
for cand in (os.path.join(root, ".claude", "agent-claims.json"),
             os.path.join(root, ".claude", "agent-claims.template.json")):
    try:
        with open(cand) as fh:
            policy = json.load(fh)
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
        "branch": u["branch"],
        "status": "claimed",
        "globs": u["owns"],
        # Every non-wildcard entry is also declared as a FUTURE file, so check-claims' cross-check
        # ("future file X inside the other's glob") fires even when the path is not yet tracked.
        "newFiles": [g for g in u["owns"] if not WILD.search(g)],
        "provides": u["provides"],
        "consumes": u["consumes"],
    } for u in out],
}
with open(claims_out, "w") as fh:
    json.dump(claims, fh, indent=2)

os.makedirs(os.path.join(state, "units"), exist_ok=True)
with open(os.path.join(state, "base"), "w") as fh:
    fh.write(base + "\n")
for u in out:
    d = os.path.join(state, "units", u["id"])
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "task"), "w") as fh:
        fh.write(u["task"])
    with open(os.path.join(d, "owns"), "w") as fh:
        fh.write("\n".join(u["owns"]) + "\n")
    with open(os.path.join(d, "branch"), "w") as fh:
        fh.write(u["branch"] + "\n")
    sf = os.path.join(d, "state")
    if not os.path.exists(sf):
        with open(sf, "w") as fh:
            fh.write("pending\n")
with open(os.path.join(state, "plan"), "w") as fh:
    fh.write("\n".join(u["id"] for u in out) + "\n")

# COHORT (#55). A provides/consumes edge is PRECISELY a declaration that these units are NOT
# independently gateable: the consumer needs its provider, and a provider alone has no consumer,
# so an integration-test oracle is RED for either one on its own and GREEN only for both. Merging
# them one at a time and gating each — `fleet integrate`'s default — rejects and rolls back BOTH
# perfectly good units. So a manifest with ANY port edge integrates as a COHORT by default: merge
# every unit, THEN gate once. Recorded here; `fanout` prints the exact command in its report.
with open(os.path.join(state, "cohort"), "w") as fh:
    fh.write("1\n" if any(u["provides"] or u["consumes"] for u in out) else "0\n")
PY
}

# Run ONE unit to completion inside its worktree. Runs in a background subshell; its ONLY output
# channel is the state dir, and its last act is to write `rc` — which is what the scheduler counts
# to decide a slot has freed up.
fanout_unit() {  # $1 = state dir, $2 = unit id, $3 = worktree
  local sd="$1" id="$2" wt="$3" d rc=0 task owns ports
  d="$sd/units/$id"
  task="$(cat "$d/task")"
  owns="$(cat "$d/owns")"
  # The FROZEN PORTS this unit provides/consumes, inlined into its brief (#48). Empty for a manifest
  # with no provides/consumes — which is every manifest that predates this.
  ports="$("$HERE/fleet-spec.sh" context --worktree "$wt" 2>/dev/null || true)"
  printf 'running\n' > "$d/state"

  # nice/ionice govern the WORKER; the sandbox governs its WRITES. Neither bounds IOPS on macOS —
  # that is a real, documented gap (Bun needed cgroups for it).
  # shellcheck disable=SC2086
  ( cd "$wt" && exec $FANOUT_NICE "$HERE/agent-delegate.sh" delegate "$wt" "$(fanout_prompt "$id" "$task" "$owns" "$ports")" ) \
    > "$d/log" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then printf 'done\n' > "$d/state"; else printf 'failed\n' > "$d/state"; fi
  printf '%s\n' "$rc" > "$d/rc"      # LAST — the scheduler polls for this file.
}

fanout_run() {  # $1 = manifest, $2 = jobs, $3 = dry-run, $4 = resume, $5 = base
  local manifest="$1" jobs="$2" dry="$3" resume="$4" base="$5"
  local slug state claims plan id d st n_units=0 n_run=0 n_skip=0
  local need_mb free_mb wt branch todo="" launched=0 finished pids="" p
  local rc any_fail=0 n_done=0 n_failed=0 cost

  [ -f "$manifest" ] || die2 "no such manifest: $manifest"
  slug="$(fanout_slug "$manifest")"
  [ -n "$slug" ] || die2 "cannot derive a slug from the manifest filename: $manifest"
  state="$ROOT/.fleet/fanout/$slug"
  mkdir -p "$state"
  claims="$state/claims.json"
  cp "$manifest" "$state/manifest.json"

  # ── PRECONDITION 1: the units must be PROVABLY DISJOINT ────────────────────────────
  fanout_prepare "$manifest" "$claims" "$state" "$slug" "$base"
  plan="$state/plan"

  echo "fanout → $manifest"
  n_units="$(wc -l < "$plan" | tr -d ' ')"
  echo "  units: $n_units   state: ${state#"$ROOT"/}"

  echo "  --- disjointness precondition (check-claims.py — fleet's ownership gate + the port proofs)"
  local cc_out cc_rc=0
  cc_out="$state/check-claims.out"
  ( cd "$ROOT" && python3 "$HERE/check-claims.py" "$claims" ) > "$cc_out" 2>&1 || cc_rc=$?
  sed 's/^/    | /' "$cc_out"
  if [ "$cc_rc" -ne 0 ]; then
    echo "" >&2
    echo "  REFUSED: the units of this manifest are NOT provably independent (see the lines above," >&2
    echo "  which name the colliding units and the offending path or port)." >&2
    echo "" >&2
    echo "  OVERLAP … = the units do not own disjoint FILES." >&2
    echo "  DANGLING PORT / DUPLICATE PROVIDER / CYCLE / FROZEN PORT = the units do not have" >&2
    echo "  independent INTERFACES (#48). Disjoint files do NOT imply compatible contracts: two" >&2
    echo "  agents can own non-overlapping paths and still build to incompatible interfaces, and" >&2
    echo "  that collision only surfaces at INTEGRATION, which is the most expensive place for it." >&2
    echo "  Anthropic's file lock was fully in force when their 16 agents were still 'stuck solving" >&2
    echo "  the same task': file-level locking enforces distinct task NAMES, not distinct WORK." >&2
    echo "" >&2
    echo "  This is not a warning that fanout is capping around. Anthropic ran 16 agents at one" >&2
    echo "  task with their C compiler and got: \"every agent would hit the same bug, fix that bug," >&2
    echo "  and then overwrite each other's changes. Having 16 agents running didn't help because" >&2
    echo "  each was stuck solving the same task.\" Agents on overlapping work do not go faster —" >&2
    echo "  they duplicate the work and then DESTROY each other's edits. N agents on non-disjoint" >&2
    echo "  work is strictly WORSE than N=1, so no --jobs value can rescue this manifest." >&2
    echo "  Repartition the units so their \`owns\` globs are pairwise disjoint, then re-run." >&2
    echo "  NOTHING was launched: no worktree, no branch, no worker." >&2
    exit 2
  fi

  # Which units actually have to run?
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    st="$(cat "$state/units/$id/state" 2>/dev/null || echo pending)"
    if [ "$resume" = "1" ] && [ "$st" = "done" ]; then
      echo "  skip  $id — already done (--resume)"
      n_skip=$((n_skip + 1))
      continue
    fi
    todo="$todo $id"
    n_run=$((n_run + 1))
  done < "$plan"

  if [ "$n_run" -eq 0 ]; then
    echo "  nothing to do — all $n_units unit(s) are already done"
    exit 0
  fi

  # ── PRECONDITION 2: DISK. Bun "ran out of disk space and crashed several times". ───
  need_mb=$((n_run * FLEET_FANOUT_DISK_MB_PER_JOB))
  free_mb="$(fanout_free_mb "$ROOT")"
  case "$free_mb" in ''|*[!0-9]*) free_mb=0 ;; esac
  echo "  --- disk preflight: need ~${need_mb}MB ($n_run × ${FLEET_FANOUT_DISK_MB_PER_JOB}MB/worktree), free ${free_mb}MB"
  if [ "$free_mb" -lt "$need_mb" ]; then
    die2 "INSUFFICIENT DISK: ${free_mb}MB free on the filesystem holding $ROOT, but $n_run worktree(s)
  need about ${need_mb}MB (FLEET_FANOUT_DISK_MB_PER_JOB=${FLEET_FANOUT_DISK_MB_PER_JOB}). Bun's ~64-agent
  fanout \"ran out of disk space and crashed several times\" — that is the ceiling this preflight
  exists to stop you walking into. Free space, or lower FLEET_FANOUT_DISK_MB_PER_JOB if your
  worktrees are genuinely smaller than that. NOTHING was launched."
  fi

  fanout_nice_prefix
  echo "  --- plan: $n_run unit(s) to run, $n_skip already done, --jobs $jobs"
  echo "      workers: $FANOUT_NICE"
  case "$(uname -s)" in
    Darwin) echo "      (macOS has no ionice: \`nice\` bounds CPU, NOT IOPS. Bun's ceiling was disk/IOPS" ;;
    *)      echo "      (on Linux prefer a cgroup — systemd-run --scope -p IOWeight= — for a real I/O bound" ;;
  esac
  echo "       and Anthropic's was decomposability; --jobs is a starting point to TUNE, not an optimum.)"
  for id in $todo; do
    printf '      %-20s owns %s → %s\n' "$id" \
      "$(tr '\n' ' ' < "$state/units/$id/owns")" "$(cat "$state/units/$id/branch")"
  done

  if [ "$dry" = "1" ]; then
    echo ""
    echo "  --dry-run: manifest VALIDATED, units PROVABLY DISJOINT, disk OK. Nothing launched."
    exit 0
  fi

  # ── worktrees: created STRICTLY SERIALLY ───────────────────────────────────────────
  # RFC part 3: 16 concurrent `git worktree add` → 4 FAILED on shared-.git contention; the same
  # 16 created serially → 16/16 succeeded. Creation is serial; only the WORK below is parallel.
  echo "  --- creating $n_run worktree(s) SERIALLY (concurrent \`git worktree add\` races the shared .git)"
  for id in $todo; do
    branch="$(cat "$state/units/$id/branch")"
    wt="$ROOT/.fleet/worktrees/$branch"
    if [ -d "$wt" ]; then
      echo "      reuse $id → $wt"
    else
      "$HERE/worktree-setup.sh" "$branch" "$base" >/dev/null \
        || die "cannot create the worktree for unit '$id' (branch $branch) — refusing to run a partial fanout"
      echo "      +     $id → $wt"
    fi
    printf '%s\n' "$wt" > "$state/units/$id/worktree"
  done

  # ── the work: parallel, never more than $jobs in flight ────────────────────────────
  echo "  --- running (max $jobs concurrent)"
  # Clear every rc file up front: a STALE rc (from a previous, e.g. failed, run being --resume'd)
  # would be counted as "finished" below and would let the scheduler over-launch past the cap.
  for id in $todo; do rm -f "$state/units/$id/rc"; done
  for id in $todo; do
    # Free a slot. A unit is IN FLIGHT until it writes its `rc` file, which it does as its very
    # last act — so counting rc files can never UNDER-count the in-flight set, and the cap holds.
    while :; do
      finished=0
      for p in $todo; do [ -f "$state/units/$p/rc" ] && finished=$((finished + 1)); done
      [ $((launched - finished)) -lt "$jobs" ] && break
      sleep 0.2
    done
    echo "      → $id"
    fanout_unit "$state" "$id" "$(cat "$state/units/$id/worktree")" &
    pids="$pids $!"
    launched=$((launched + 1))
  done
  for p in $pids; do wait "$p" 2>/dev/null || true; done

  # ── report ────────────────────────────────────────────────────────────────────────
  echo ""
  echo "══ fanout report — $manifest ═════════════════════════════════════════════════"
  printf '  %-18s %-10s %-8s %s\n' UNIT STATUS EXIT "BRANCH / WORKTREE"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    d="$state/units/$id"
    st="$(cat "$d/state" 2>/dev/null || echo pending)"
    rc="$(cat "$d/rc" 2>/dev/null || echo '-')"
    cost="$(grep -m1 '^  cost:' "$d/log" 2>/dev/null | sed 's/^ *cost: *//')"
    printf '  %-18s %-10s %-8s %s\n' "$id" "$st" "$rc" "$(cat "$d/branch" 2>/dev/null)"
    [ -n "$cost" ] && printf '  %-18s %s\n' "" "$cost"
    case "$st" in
      done)   n_done=$((n_done + 1)) ;;
      failed) n_failed=$((n_failed + 1)); any_fail=1
              printf '  %-18s log: %s\n' "" "${d#"$ROOT"/}/log" ;;
    esac
  done < "$plan"
  echo ""
  echo "  $n_done done, $n_failed failed, $n_skip skipped (of $n_units unit(s)). Logs: ${state#"$ROOT"/}/units/<id>/log"
  echo "  A unit's failure does NOT abort its siblings — they are disjoint, so they are independent."
  echo "  Re-run with --resume to retry only what did not finish."
  echo "  fanout IS a work-runner: it exits NON-ZERO iff a unit failed. (\`review\` is the opposite —"
  echo "  it is advisory evidence and must never block. Do not confuse the two.)"
  fanout_integrate_hint "$state" "$plan"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  exit "$any_fail"
}

# Print the exact `fleet integrate` line for the branches this fanout produced (#55). fanout is a
# WORK-RUNNER; integration stays a human/CI decision, so we print the command and never run it.
# A manifest that declares ANY provides/consumes edge integrates as a COHORT by default: a port
# edge IS the declaration that its units are not independently gateable, and `fleet integrate`'s
# default per-branch gate would reject and roll back BOTH a consumer and its provider — each is
# red alone, by construction, and green only together.
fanout_integrate_hint() {  # $1 = state dir, $2 = plan
  local state="$1" plan="$2" id st branches="" is_cohort
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    st="$(cat "$state/units/$id/state" 2>/dev/null || echo pending)"
    [ "$st" = "done" ] || continue
    branches="$branches $(cat "$state/units/$id/branch" 2>/dev/null)"
  done < "$plan"
  [ -n "$branches" ] || return 0
  is_cohort="$(cat "$state/cohort" 2>/dev/null || echo 0)"
  echo ""
  if [ "$is_cohort" = 1 ]; then
    echo "  INTEGRATE (this manifest declares a provides/consumes PORT edge → COHORT):"
    echo "      fleet integrate <integ-branch> --cohort$branches"
    echo "  --cohort merges ALL of them and gates the combined tree ONCE. A port edge declares that"
    echo "  these units are NOT independently gateable — a consumer is red without its provider and"
    echo "  a provider is red without its consumer, so the DEFAULT per-branch gate would reject and"
    echo "  roll back BOTH perfectly good units and integrate NOTHING (#55)."
  else
    echo "  INTEGRATE (no port edge → the units are independently gateable):"
    echo "      fleet integrate <integ-branch>$branches"
    echo "  Each branch is gated on its own and rolled back on its own, so one bad unit cannot"
    echo "  poison the integration tree. If these units are in fact co-dependent, declare the port"
    echo "  (\`fleet spec\`) or integrate them with \`--cohort\` (#55)."
  fi
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

  fanout)
    mf="${1:-}"; [ -n "$mf" ] || die2 "usage: fleet delegate fanout <manifest.json> [--jobs N] [--dry-run] [--resume]"
    shift
    jobs="${FLEET_FANOUT_JOBS:-}"; dry=0; resume=0; fbase="$FLEET_MAIN"
    while [ $# -gt 0 ]; do case "$1" in
      --jobs)     jobs="${2:?--jobs needs N}"; shift 2 ;;
      --base)     fbase="${2:?--base needs a ref}"; shift 2 ;;
      --dry-run)  dry=1; shift ;;
      --resume)   resume=1; shift ;;
      -*)         die2 "unknown arg: $1" ;;
      *)          die2 "fanout takes exactly one manifest; the per-unit tasks live IN it (unexpected argument: $1)" ;;
    esac; done
    [ -n "$jobs" ] || jobs="$(fanout_default_jobs)"
    case "$jobs" in ''|*[!0-9]*) die2 "--jobs needs a positive integer" ;; esac
    [ "$jobs" -ge 1 ] || die2 "--jobs needs a positive integer"
    fanout_run "$mf" "$jobs" "$dry" "$resume" "$fbase"
    ;;

  ""|-h|--help) usage ;;
  *) echo "unknown delegate verb: $cmd (try: fleet delegate --help)" >&2; exit 2 ;;
esac
