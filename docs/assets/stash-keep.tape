# VHS tape for the keep stash screenshot in the README.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zshot, a
# ziggity clone with staged, unstaged and untracked changes), then from the
# repo root:  vhs docs/assets/stash-keep.tape
# Opens the stash menu and highlights the variant that snapshots everything,
# untracked included, while leaving the working tree untouched.

# Scrap gif (deleted after the run); the real output is the screenshot.
Output docs/assets/scrap-stash.gif

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
Show
Sleep 500ms

# Open the stash menu from the Files panel and select the keep variant.
Type "s"
Sleep 1s
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 800ms
Screenshot docs/screenshots/18-stash-keep.png
Sleep 300ms
Escape
Sleep 400ms
