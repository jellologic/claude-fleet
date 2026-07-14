#!/usr/bin/env python3
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
"""PreToolUse Bash coord-guard — deny git operations that bypass the fleet controls
at the TOOL layer (before git runs), closing the --no-verify hole. Denies (only
when 'git' is in the command): --no-verify; push to main/master/release/*;
git worktree add --force/-f; --ignore-other-worktrees; and anything that unwires
`core.hooksPath` (#30). Fails OPEN on parse error.

EXIT CODES (#31): only exit 2 BLOCKS. Claude Code treats exit 1 as a non-blocking
error and PROCEEDS with the action, so an `exit 1` on a deny path would fail OPEN.
Every deny goes through deny() → exit 2; every allow is exit 0. Never exit 1.

WHY core.hooksPath (#30): the pre-push hook IS fleet's merge gate, and it hangs off
`core.hooksPath`. Anything that repoints or unsets that config disables the gate
SILENTLY — `git -c core.hooksPath=/dev/null push origin main` pushes straight to main
and the hook never fires (reproduced). A check *inside* the hook cannot help: a disabled
hook does not run. So the denial must happen here, at the tool layer, before git runs.

This guard is defence-in-depth ONLY. Per RFC 2a it does NOT bind subprocesses — a nested
`claude`, `python3`, or shell can still do all of this. The load-bearing rails are the OS
sandbox (`fleet delegate`) and the GitHub ruleset.
"""
import json
import os
import shlex
import sys

# Config keys that, if WRITTEN or overridden, disable or relocate the merge gate.
GATE_KEYS = ("core.hookspath", "extensions.worktreeconfig")
# Env prefixes git reads config from — a way to set core.hooksPath without `-c`.
GIT_CONFIG_ENV = ("GIT_CONFIG_COUNT=", "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_",
                  "GIT_CONFIG_GLOBAL=", "GIT_CONFIG_SYSTEM=")
# `git config` READ flags. Reading core.hooksPath is harmless (check-gate-integrity.sh
# does exactly that); only writes are denied. Without this the guard over-fires and
# blocks its own integrity check.
CONFIG_READ_FLAGS = ("--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l")


def deny(reason):
    sys.stderr.write("[coord-guard] BLOCKED: " + reason + "\n"); sys.exit(2)


def check_gate_integrity(toks, low):
    """Deny every way of unwiring core.hooksPath (#30)."""
    # 1. Config via environment: `GIT_CONFIG_KEY_0=core.hooksPath ... git push`.
    for t in toks:
        for pfx in GIT_CONFIG_ENV:
            if t.startswith(pfx):
                deny("`" + pfx.rstrip("=") + "…` can inject core.hooksPath and silently "
                     "disable the pre-push merge gate. Remove it.")
    if "git" not in low:
        return
    # 2. One-shot override: `git -c core.hooksPath=… <cmd>` (and the `-ccore.x=…` form).
    for i, t in enumerate(low):
        key = None
        if t == "-c" and i + 1 < len(low):
            key = low[i + 1].split("=", 1)[0]
        elif t.startswith("-c") and len(t) > 2:
            key = t[2:].split("=", 1)[0]
        if key in GATE_KEYS:
            deny("`git -c " + key + "=…` repoints the hook path — the pre-push merge gate "
                 "would not run. That gate is the point; do not disable it.")
    # 3. Persistent write: `git config [--worktree|--local|--global] core.hooksPath …`.
    #    Reads are fine.
    if "config" in low:
        if any(f in low for f in CONFIG_READ_FLAGS):
            return
        for t in low:
            if t.split("=", 1)[0].lstrip("-") in GATE_KEYS:
                deny("`git config … " + t + "` rewires or disables the pre-push merge gate. "
                     "It must keep pointing at .fleet/githooks.")


# Shell operators that end one command and begin the next. shlex.split keeps them as
# bare tokens, so they are what tells `a && git reset --hard` apart from `echo git reset`.
SHELL_SEPS = ("&&", "||", ";", "|", "&")
# `git` global options that take a VALUE, so the value must not be mistaken for the
# subcommand: `git -C /path reset --hard`.
GIT_GLOBAL_WITH_ARG = ("-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path")


def git_invocations(toks):
    """Yield (subcommand, args) for each REAL `git` invocation in the command line.

    The rest of this guard tests `"git" in toks`, which is a bag-of-tokens heuristic: it
    fires on `echo git reset --hard`, where nothing is executed at all. That is tolerable
    for the deny rules that predate this one, but the destructive-git rules must not
    over-fire — a guard that blocks routine work teaches agents to switch it off, and then
    it protects nothing.

    So: a `git` token only starts an invocation if it is at the start of a command (index
    0, or right after a shell separator, or after `env`/VAR=val prefixes). Global options
    are skipped so `git -C /path reset --hard` still resolves to ("reset", [...]).
    """
    out = []
    i, n = 0, len(toks)
    cmd_start = True
    while i < n:
        t = toks[i]
        if t in SHELL_SEPS:
            cmd_start = True
            i += 1
            continue
        # `env FOO=1 git ...` and `FOO=1 git ...` still start a command.
        if cmd_start and (t == "env" or ("=" in t and not t.startswith("-"))):
            i += 1
            continue
        if cmd_start and t == "git":
            j = i + 1
            while j < n:                     # skip git's global options
                a = toks[j]
                if a in GIT_GLOBAL_WITH_ARG:
                    j += 2
                    continue
                if a.startswith("-"):
                    j += 1
                    continue
                break
            if j < n:
                sub = toks[j].lower()
                args, k = [], j + 1
                while k < n and toks[k] not in SHELL_SEPS:
                    args.append(toks[k])
                    k += 1
                out.append((sub, args))
                i = k
                cmd_start = True
                continue
        cmd_start = False
        i += 1
    return out


def check_destructive_git(toks, low):
    """Deny WORKTREE-WIDE destructive git (#38).

    Bun's first parallel run died about two minutes in: "one Claude ran `git stash`
    before committing. Another ran `git stash pop`. And then `git reset HEAD --hard`.
    They were stepping on each other!" Their fix was a PROMPT RULE ("never run git stash
    or git reset"). A prompt rule is not a rail — so fleet enforces it.

    fleet's worktree isolation already makes CROSS-agent collisions unlikely (each agent
    owns its worktree). The remaining damage is self-inflicted and still severe: since
    #22 the reaper treats uncommitted work as its primary liveness signal, so an agent
    that `reset --hard`s itself LOOKS DEAD and can be reaped.

    DELIBERATELY NARROW — deny only the WHOLE-TREE forms; path-scoped discards
    (`git checkout -- src/foo.py`, `git restore src/foo.py`) are routine and stay
    allowed. Over-firing here would be worse than the bug: it would train agents to
    reach for an escape hatch. FLEET_ALLOW_DESTRUCTIVE_GIT=1 is that hatch, for humans.
    """
    if os.environ.get("FLEET_ALLOW_DESTRUCTIVE_GIT") == "1":
        return

    for sub, args in git_invocations(toks):
        low_args = [a.lower() for a in args]

        def has(*flags):
            return any(f in low_args for f in flags)

        # Real path operands: not flags, and not the whole-tree stand-ins "." / "*".
        paths = [a for a in args if not a.startswith("-") and a not in (".", "*", "./")]

        # `git reset --hard` discards every uncommitted change. soft/mixed are harmless.
        if sub == "reset" and has("--hard"):
            deny("`git reset --hard` destroys ALL uncommitted work in this worktree. Since #22 the "
                 "reaper reads uncommitted work as its liveness signal, so this can also make a LIVE "
                 "agent look dead and get reaped. Commit to your agent/* branch instead. "
                 "(Human override: FLEET_ALLOW_DESTRUCTIVE_GIT=1)")

        # `git clean -f` deletes untracked files. `-n`/`--dry-run` is safe.
        if sub == "clean" and not has("-n", "--dry-run"):
            forced = any(a.startswith("-") and not a.startswith("--") and "f" in a for a in low_args)
            if forced or has("--force"):
                deny("`git clean -f` deletes untracked files outright — including work an agent has "
                     "not committed yet. Use `git clean -n` to see what it would remove. "
                     "(Human override: FLEET_ALLOW_DESTRUCTIVE_GIT=1)")

        # `git stash` is worktree-wide — the exact command that broke Bun's first run.
        # Read-only subcommands are fine.
        if sub == "stash" and not (low_args and low_args[0] in ("list", "show")):
            deny("`git stash` moves the ENTIRE worktree's changes onto a stack. This is what broke "
                 "Bun's first parallel run ('They were stepping on each other!'). Commit to your "
                 "agent/* branch instead — that is what the branch is for. "
                 "(Human override: FLEET_ALLOW_DESTRUCTIVE_GIT=1)")

        # Whole-tree discards only. Path-scoped forms stay ALLOWED — that is the point:
        # `git checkout -- src/foo.py` is routine, and a guard that blocks it gets disabled.
        if sub == "checkout":
            whole_tree = "." in args or has("-f", "--force")
            discarding = "--" in args or "." in args or has("-f", "--force")
            if whole_tree and discarding:
                deny("`git checkout` with --force or a whole-tree path (`.`) discards uncommitted "
                     "work across the worktree. Scope it to a file: `git checkout -- path/to/file`. "
                     "(Human override: FLEET_ALLOW_DESTRUCTIVE_GIT=1)")
        if sub == "restore" and not paths:
            deny("`git restore` with no path (or `.`) discards uncommitted work across the worktree. "
                 "Scope it to a file: `git restore path/to/file`. "
                 "(Human override: FLEET_ALLOW_DESTRUCTIVE_GIT=1)")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    try:
        toks = shlex.split((data.get("tool_input") or {}).get("command", "") or "")
    except Exception:
        sys.exit(0)

    low = [t.lower() for t in toks]
    # Checked before the `git in toks` gate below: the GIT_CONFIG_* env forms can arm a
    # bypass without `git` being a token we would otherwise inspect.
    check_gate_integrity(toks, low)

    if "git" not in toks:
        sys.exit(0)
    tset = set(toks)
    if "--no-verify" in tset:
        deny("`--no-verify` bypasses the commit/push guards — fix what the hook flags instead.")
    if "--ignore-other-worktrees" in tset:
        deny("`--ignore-other-worktrees` breaks the one-branch-one-worktree lock.")
    if "worktree" in tset and "add" in tset and ("--force" in tset or "-f" in tset):
        deny("`git worktree add --force` can put one branch in two worktrees — use a unique branch.")
    if "push" in tset:
        for t in toks:
            base = t.split(":")[-1].replace("refs/heads/", "")
            if base in ("main", "master") or base.startswith("release/"):
                deny("direct push to '" + base + "' is forbidden — open a PR from your agent/* branch.")
    check_destructive_git(toks, low)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write("[coord-guard] internal error, allowing: " + str(e) + "\n")
        sys.exit(0)
