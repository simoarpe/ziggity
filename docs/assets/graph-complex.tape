# VHS tape for the complex commit graph screenshot in the README.
# Regenerate: run docs/assets/demo-repos.sh first (it clones git/git shallow
# into /tmp/zdemo-graph, a history with real merge lanes), then from the repo
# root:  vhs docs/assets/graph-complex.tape
# Safe keys only: focus Commits (4), open the graph (ctrl+l), scroll with j.

# Scrap gif (deleted after the run); the real output is the screenshot.
Output docs/assets/scrap-graph.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-graph && $Z"
Enter
Sleep 2.5s
Type "4"
Sleep 500ms
Ctrl+L
Sleep 3s
Type "j"
Sleep 150ms
Type "j"
Sleep 150ms
Type "j"
Sleep 150ms
Type "j"
Sleep 150ms
Type "j"
Sleep 150ms
Type "j"
Sleep 150ms
Type "j"
Sleep 1s
Show
Sleep 500ms
Screenshot docs/screenshots/16-commit-graph-complex.png
Sleep 300ms
