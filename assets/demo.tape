# claude-fleet demo tape (charmbracelet/vhs).
# Render:  vhs assets/demo.tape   (requires: vhs, ttyd, ffmpeg; run from the repo root)
# Hidden setup lives in assets/demo-setup.sh (throwaway /tmp/cf-demo repo; no GitHub side effects).

Output assets/demo.gif

Set Shell bash
Set FontSize 16
Set Width 1280
Set Height 700
Set Padding 26
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set TypingSpeed 40ms
Set CursorBlink false

Hide
Type "source assets/demo-setup.sh" Enter
Show

Type "# claude-fleet — run MANY parallel Claude Code agents on one repo, conflict-free" Enter
Sleep 1.5s
Type "fleet wt new auth" Enter
Sleep 1.6s
Type "fleet wt new payments" Enter
Sleep 1.6s
Type "# each agent gets its own worktree + branch — the branch ref IS the lock" Enter
Sleep 900ms
Type "fleet wt list" Enter
Sleep 2.6s
Type "# and main is protected — an agent can't corrupt it:" Enter
Sleep 900ms
Type "echo oops > hot.txt && git add hot.txt && git commit -m 'straight to main'" Enter
Sleep 3s
Type "# work lands only via reviewed PRs.   github.com/jellologic/claude-fleet" Enter
Sleep 2.5s
