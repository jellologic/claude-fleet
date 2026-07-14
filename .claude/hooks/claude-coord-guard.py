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
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write("[coord-guard] internal error, allowing: " + str(e) + "\n")
        sys.exit(0)
