# Sharing claude-fleet

Copy for announcing / sharing the repo, plus social-preview setup.

## One-liner
Run many parallel Claude Code agents on one repo — without conflicts. Git-worktree branch-ref locks, crash recovery, a merge gate, and guard hooks. Stack-agnostic.

## Tweet / X (~280 chars)
> Shipped **claude-fleet** 🛳️ — run *many* parallel Claude Code agents on one git repo without conflicts.
>
> The git branch ref **is** the lock (local mutex + remote compare-and-swap). Crash recovery, a merge gate, guard hooks. Pure shell + python3, any stack. MIT.
>
> github.com/jellologic/claude-fleet

## LinkedIn / longer post
> If you run more than one Claude Code agent on the same repo, they collide. **claude-fleet** fixes that.
>
> Each agent claims work as a git **worktree on its own branch** — and that branch ref *is* the lock:
> a local mutex plus a server-side compare-and-swap on push, so two agents (even on two machines) can
> never hold the same work. Add crash recovery (a reaper for dead agents), a sequential **merge gate**
> that rolls back any branch that doesn't build, an optional **file-ownership gate**, and tool-layer
> guard hooks that block `--no-verify` and direct pushes to `main`.
>
> The core is pure shell + python3 + git + gh — drop it into any repo regardless of language. Install,
> update, and uninstall are driven through Claude Code itself, and it removes cleanly (no forever-tax).
>
> MIT · github.com/jellologic/claude-fleet

## Hacker News / Show HN title
> Show HN: claude-fleet – run many parallel Claude Code agents on one repo, conflict-free

## Hashtags
`#ClaudeCode #AIagents #DevTools #git #automation`

## GitHub social preview image
GitHub doesn't expose the social-preview image via API — set it once in the browser:
**Repo → Settings → General → Social preview → Upload an image** (1280×640 PNG/JPG).
Use `assets/banner.png` (render it from `assets/banner.svg`, e.g. `rsvg-convert -w 1280 -h 640 assets/banner.svg -o assets/banner.png`).
Suggested alt text: *"claude-fleet — parallel Claude Code agents, conflict-free."*
