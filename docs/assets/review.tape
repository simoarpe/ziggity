# VHS tape for the side-by-side review screenshots, on the shared canvas
# (3000x1600, FontSize 40) so they match the other README screenshots.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zreview, a
# short Zig file with two separated edits), then from the repo root:
#   vhs docs/assets/review.tape
# Safe: it opens a throwaway demo repo and only reads the diff.

Output docs/assets/scrap-review.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

# Open the demo repo; the modified net.zig is selected on launch, so pressing
# `|` opens the full-screen side-by-side review of its diff.
Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zreview && $Z"
Enter
Sleep 3s
Show
Sleep 500ms

# The compact review: the first change boxed and selected with its header
# pinned, aligned old/new columns, changed words picked out, a second hunk below.
Type "|"
Sleep 1.5s
Screenshot docs/screenshots/27-side-by-side-review.png
Sleep 300ms

# The whole-file toggle (`=`): the unchanged lines between the hunks filled in,
# each change still its own boxed hunk.
Type "="
Sleep 1.5s
Screenshot docs/screenshots/28-side-by-side-whole.png
Sleep 300ms
