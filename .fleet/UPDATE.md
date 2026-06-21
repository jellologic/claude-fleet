# claude-fleet — update playbook (for Claude Code)

Update the vendored machinery to a newer claude-fleet, preserving local customization.

1. **Get the latest source:** ask the human for the claude-fleet clone path, then `git -C <clone> pull`.
2. **Re-vendor:** `bash <clone>/install.sh "$(git rev-parse --show-toplevel)"`.
   install.sh is idempotent: it re-vendors `.fleet/bin|lib|githooks` + `.claude/hooks|commands`,
   **preserves** your `.fleet/config.sh`, and (because the markers already exist) does **not** touch
   your `CLAUDE.md` managed block or re-add `.gitignore` markers.
3. **Refresh docs if the protocol changed:** skim `<clone>/SELF-REPORT.md` / `git -C <clone> log`.
   If commands or rules changed materially, update the `CLAUDE.md` managed block per `INSTALL.md` step 3,
   and re-check `.fleet/config.sh` against the latest `examples/`.
4. **Verify + report:** `.fleet/bin/fleet --help`; `git config --get core.hooksPath` = `.fleet/githooks`.
   Summarize what changed. Review `git status` with the human; **commit only with approval.**

---
_Found a bug in claude-fleet itself? See `.fleet/SELF-REPORT.md` — all outward reporting needs human approval._
