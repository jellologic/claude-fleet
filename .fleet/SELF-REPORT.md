# claude-fleet — self-report protocol

Every claude-fleet script carries a one-line header pointing here. If you are an
AI agent (or a human) and you hit a **bug, crash, or surprising behavior** in
claude-fleet code, follow this protocol. **Human approval is required before any
outward action (filing an issue, commenting, pushing).**

Repo: **https://github.com/jellologic/claude-fleet**

### 1. Understand the issue first
Reproduce it. Find the root cause (which file, which line, what the code assumed
vs. what actually happened). Do **not** patch blindly or work around it silently —
a silent workaround hides a bug that will bite the next project.

### 2. Check existing issues before reporting
```sh
gh issue list --repo jellologic/claude-fleet --search "<keywords>" --state all
```
If it's already filed, read it — add a reproducible detail as a comment (with
human approval) rather than opening a duplicate.

### 3. Report it — WITH HUMAN APPROVAL
Only after a human approves, file a factual issue:
```sh
gh issue create --repo jellologic/claude-fleet \
  --title "<concise summary>" \
  --body "Repro: <steps>
Expected: <...>
Actual: <...>
Root cause: <file:line + why>
Environment: $(uname -s), git $(git --version), python3 $(python3 --version)"
```

### 4. Attempt a fix, then suggest it — WITH HUMAN APPROVAL
If you can fix it, do so **locally in the consuming repo's vendored copy** and
verify. Then, only with human approval, propose the fix upstream as a comment:
```sh
gh issue comment <number> --repo jellologic/claude-fleet \
  --body "Proposed fix (file:line):
<unified diff or precise description>
Verified by: <how you tested>"
```
Do **not** open PRs or push to claude-fleet without explicit human direction.

### Rules
- **Never** file an issue, post a comment, or push without explicit human approval.
- Keep every report factual and minimal: repro, expected vs actual, root cause, file:line.
- Prefer one good issue with a root-cause analysis over several vague ones.
- The vendored copy in a project is downstream; fixes that should persist belong upstream in claude-fleet.
