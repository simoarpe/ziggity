# VHS tape that recaptures every README screenshot on the shared canvas
# (3000x1600, FontSize 40), so screenshots and gifs have identical text size
# and the whole visual suite regenerates from tapes.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zshot, a
# ziggity clone with a curated working tree state), then from the repo root:
#   vhs docs/assets/screenshots.tape
# Safe keys only; this records against a throwaway clone, never a real repo.

# Scrap gif (deleted after the run); the real outputs are the screenshots.
Output docs/assets/scrap-screens.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 40ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zshot/ziggity && $Z"
Enter
Sleep 3s
Show
Sleep 500ms

# 01: the main view, Files focused, first change selected, live diff.
Screenshot docs/screenshots/01-overview.png
Sleep 300ms

# 02: staging view of a modified tracked file (second row: src/tui.zig).
Type "j"
Sleep 500ms
Enter
Sleep 1.5s
Screenshot docs/screenshots/02-staging.png
Sleep 300ms
Escape
Sleep 800ms

# 03: the Commits panel with a diff preview a few rows in.
Type "4"
Sleep 600ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 1.5s
Screenshot docs/screenshots/03-commits.png
Sleep 300ms

# 10: the interactive rebase plan editor for the commits down to here.
Type "i"
Sleep 1.5s
Screenshot docs/screenshots/10-rebase-plan.png
Sleep 300ms
Escape
Sleep 800ms

# 13: the reset menu on the selected commit.
Type "g"
Sleep 1s
Screenshot docs/screenshots/13-reset-menu.png
Sleep 300ms
Escape
Sleep 800ms

# 14: the diffing menu.
Type "W"
Sleep 1s
Screenshot docs/screenshots/14-diffing-menu.png
Sleep 300ms
Escape
Sleep 800ms

# 04: the commit graph, current branch plus upstream.
Ctrl+L
Sleep 3s
Screenshot docs/screenshots/04-commit-graph.png
Sleep 300ms
Escape
Sleep 800ms

# 05: the Branches panel (a local branch, tracking state, time column).
Type "3"
Sleep 1s
Screenshot docs/screenshots/05-branches.png
Sleep 300ms

# 06: the Tags tab, real tags with their messages.
Type "]"
Sleep 500ms
Type "]"
Sleep 1s
Screenshot docs/screenshots/06-tags.png
Sleep 300ms

# 07: the Stash panel with named stashes and a diff preview.
Type "5"
Sleep 1s
Screenshot docs/screenshots/07-stash.png
Sleep 300ms

# 12: the stash menu.
Type "2"
Sleep 600ms
Type "s"
Sleep 1s
Screenshot docs/screenshots/12-stash-menu.png
Sleep 300ms
Escape
Sleep 800ms

# 08: the commit dialog with a subject, body, counter and wrap guide.
Type "c"
Sleep 1s
Type "Cache rendered previews across refreshes"
Sleep 500ms
Tab
Sleep 400ms
Type "Preview text now survives a scoped refresh, so reselecting a commit"
Enter
Type "renders instantly instead of rerunning git show."
Sleep 1s
Screenshot docs/screenshots/08-commit-dialog.png
Sleep 300ms
Escape
Sleep 800ms

# 09: the keybindings overlay, opened to the current panel's section.
Type "?"
Sleep 1s
Screenshot docs/screenshots/09-help.png
Sleep 300ms
Escape
Sleep 800ms

# 11: the about splash on the Status panel.
Type "1"
Sleep 2s
Screenshot docs/screenshots/11-about-splash.png
Sleep 300ms
