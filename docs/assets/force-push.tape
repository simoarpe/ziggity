# VHS tape for the force push ladder screenshot in the README.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zdemo-push,
# a clone pair whose histories diverged), then from the repo root:
#   vhs docs/assets/force-push.tape
# A push is rejected because the remote moved, and ziggity offers the first
# rung of the ladder: force with lease, confirmed before anything runs.

# Scrap gif (deleted after the run); the real output is the screenshot.
Output docs/assets/scrap-force.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-push/ours && $Z"
Enter
Sleep 2.5s
Show
Sleep 500ms

# Push. The remote moved, the push is rejected, and the lease force is
# offered with a y/n confirmation.
Type "P"
Sleep 2.5s
Screenshot docs/screenshots/17-force-push.png
Sleep 300ms
Type "n"
Sleep 500ms
