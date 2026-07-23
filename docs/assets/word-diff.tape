# VHS tape for the word-level (intra-line) diff screenshot, on the shared canvas
# (3000x1600, FontSize 40) so it matches the other README screenshots.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zword, a small
# repo with a few intra-line edits), then from the repo root:
#   vhs docs/assets/word-diff.tape
# Safe: it opens a throwaway demo repo and only shows the diff.

Output docs/assets/scrap-word-diff.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

# Open the demo repo; the modified config.zig is selected on launch, so its diff
# (with the changed words highlighted) shows in the Diff panel right away.
Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zword && $Z"
Enter
Sleep 3s
Show
Sleep 500ms

Screenshot docs/screenshots/20-word-diff.png
Sleep 300ms
