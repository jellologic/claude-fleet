---
description: Update claude-fleet to a newer version, preserving local config + CLAUDE.md (Claude-driven)
argument-hint: [path-to-claude-fleet-clone]
allowed-tools: Bash, Read, Edit
---
Update the vendored claude-fleet. **Read `.fleet/UPDATE.md` and follow it:** pull the latest
claude-fleet source (clone path: $1 — ask me if not given), re-run its `install.sh` against this repo
(this preserves `.fleet/config.sh` and the `CLAUDE.md` managed block), refresh the `CLAUDE.md` section
only if the protocol changed, verify, and report what changed.

Review `git status` with me; commit only with my approval.
