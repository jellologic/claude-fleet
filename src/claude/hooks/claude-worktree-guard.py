#!/usr/bin/env python3
"""PreToolUse guard — confine an agent's writes to its worktree and block writes
to secrets/system paths. Wired via .claude/settings.json. Block = exit 2 + reason.
Fails OPEN on internal errors; fails CLOSED on protected secret/system paths.

Allowed root: $CLAUDE_GUARD_ROOT, else the git worktree toplevel of the call's cwd,
else $CLAUDE_PROJECT_DIR.
"""
import json
import os
import shlex
import subprocess
import sys

HOME = os.path.expanduser("~")
PROTECTED = [
    os.path.join(HOME, ".claude", ".credentials.json"),
    os.path.join(HOME, ".claude", "settings.json"),
    os.path.join(HOME, ".claude", "settings.local.json"),
    os.path.join(HOME, ".ssh"), os.path.join(HOME, ".aws"), os.path.join(HOME, ".gnupg"),
    os.path.join(HOME, ".config", "gh"), os.path.join(HOME, ".npmrc"),
    os.path.join(HOME, ".cargo", "credentials.toml"), os.path.join(HOME, ".cargo", "config.toml"),
    "/etc", "/boot", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/root",
]
SAFE_ALLOW = [
    "/tmp", "/var/tmp", "/dev/null", "/dev/stdout", "/dev/stderr",
    os.path.join(HOME, ".cache"), os.path.join(HOME, ".claude", "projects"),
]
SECRETS = [
    os.path.join(HOME, ".claude", ".credentials.json"), os.path.join(HOME, ".ssh"),
    os.path.join(HOME, ".aws"), os.path.join(HOME, ".gnupg"), os.path.join(HOME, ".config", "gh"),
    os.path.join(HOME, ".npmrc"), os.path.join(HOME, ".cargo", "credentials.toml"),
]
# Repo-relative paths an agent must never rewrite (the guard machinery itself).
TAMPER = [".claude/settings.json", ".claude/hooks", ".fleet/githooks", ".fleet/lib", ".fleet/bin"]


def block(reason):
    sys.stderr.write("[worktree-guard] BLOCKED: " + reason + "\n"); sys.exit(2)


def realpath(p):
    return os.path.realpath(os.path.abspath(os.path.expanduser(p)))


def under(path, base):
    try:
        rp, rb = realpath(path), realpath(base)
        return rp == rb or rp.startswith(rb.rstrip("/") + "/")
    except Exception:
        return False


def allowed_root(cwd):
    pin = os.environ.get("CLAUDE_GUARD_ROOT")
    if pin:
        return realpath(pin)
    try:
        r = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return realpath(r.stdout.strip())
    except Exception:
        pass
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    return realpath(proj) if proj else None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    tool = data.get("tool_name", "")
    ti = data.get("tool_input", {}) or {}
    cwd = data.get("cwd") or os.getcwd()

    if tool == "Bash":
        try:
            toks = shlex.split(ti.get("command", "") or "")
        except Exception:
            sys.exit(0)
        for t in toks:
            if ("/" in t or t.startswith("~")) and any(under(t, s) for s in SECRETS):
                block("Bash command references a secret path: " + t)
        sys.exit(0)

    path = ti.get("file_path") or ti.get("notebook_path") or ti.get("path")
    if not path:
        sys.exit(0)
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    if any(under(path, pp) for pp in PROTECTED):
        block("write to protected secret/system path: " + path)
    root = allowed_root(cwd)
    if root and any(under(path, os.path.join(root, t)) for t in TAMPER):
        block("modifying the fleet guard machinery is not allowed: " + path)
    if any(under(path, sp) for sp in SAFE_ALLOW):
        sys.exit(0)
    if root is None:
        sys.exit(0)
    if under(path, root):
        sys.exit(0)
    block("write outside the allowed root (" + root + "): " + path)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write("[worktree-guard] internal error, allowing: " + str(e) + "\n")
        sys.exit(0)
