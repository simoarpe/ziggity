# VHS tape for the conflict-resolution doc screenshots (docs/conflict-resolution.md),
# on the shared canvas (3000x1600, FontSize 40) so they match the rest of the suite.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zconflict, a repo
# left mid-merge with a conflicted settings.conf), then from the repo root:
#   vhs docs/assets/conflicts.tape
# Safe keys only; this records against a throwaway repo, never a real one.

# Scrap gif (deleted after the run); the real outputs are the screenshots.
Output docs/assets/scrap-conflicts.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 40ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zconflict && $Z"
Enter
Sleep 3s
# Files auto-focuses on the conflicted file; re-focus deterministically (1 then
# 2 avoids tab-cycling) so settings.conf is selected.
Type "1"
Sleep 500ms
Type "2"
Sleep 700ms
Show
Sleep 500ms

# 25: the Files panel during a conflict, with the entry-point footer
# (enter resolve one by one / space resolve menu / m continue-abort / d discard).
Screenshot docs/screenshots/25-conflict-files.png
Sleep 300ms

# 26: the `space` "Resolve conflicts" menu with every route.
Type " "
Sleep 1s
Screenshot docs/screenshots/26-conflict-menu.png
Sleep 300ms
Escape
Sleep 500ms

# 24: the per-conflict resolver (enter), ours tinted green / theirs red with the
# labels, and the j/k next/prev conflict footer.
Enter
Sleep 1.5s
Screenshot docs/screenshots/24-conflict-resolver.png
Sleep 300ms
