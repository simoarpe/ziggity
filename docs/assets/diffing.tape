# VHS tape for the diffing mode gif in the README.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zshot, a
# ziggity clone with local branches), then from the repo root:
#   vhs docs/assets/diffing.tape
# Shows the W flow: one press marks the selected branch as the base and opens
# the explanatory note; the marked row keeps a diamond; the Diff title tracks
# the comparison in git's own notation as the selection moves; W again opens
# the options (invert, dot mode, exit).

Output docs/assets/ziggity-diffing.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zshot/ziggity && $Z"
Enter
Sleep 2.5s
Type "3"
Sleep 500ms
Type "j"
Sleep 500ms
Show
Sleep 600ms

# One W marks the branch as the base and opens the explanatory note.
Type "W"
Sleep 3.5s
Escape
Sleep 1.2s

# The marked row keeps its diamond; the title tracks each selection with the
# real ref names around the dots.
Type "j"
Sleep 1.6s
Type "j"
Sleep 1.6s

# W again: the options menu (invert, switch the dots, exit).
Type "W"
Sleep 2.5s
Escape
Sleep 1s
