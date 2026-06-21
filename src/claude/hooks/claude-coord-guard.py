#!/usr/bin/env python3
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
"""PreToolUse Bash coord-guard — deny git operations that bypass the fleet controls
at the TOOL layer (before git runs), closing the --no-verify hole. Denies (only
when 'git' is in the command): --no-verify; push to main/master/release/*;
git worktree add --force/-f; --ignore-other-worktrees. Fails OPEN on parse error.
"""
import json
import shlex
import sys


def deny(reason):
    sys.stderr.write("[coord-guard] BLOCKED: " + reason + "\n"); sys.exit(2)


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
