# VHS tape for the line-wrapping demo GIF (ctrl+w), on the shared canvas
# (3000x1600, FontSize 40) so it matches the other README assets.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zwrap, a repo
# with a long-paragraph markdown edit), then from the repo root:
#   vhs docs/assets/wrap.tape
# Safe: it opens a throwaway demo repo and only presses ctrl+w and esc.

Output docs/assets/ziggity-wrap.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

# Open the demo repo; the modified notes.md is selected, so its diff (with long
# prose lines) shows in the Diff panel right away.
Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zwrap && $Z"
Enter
Sleep 3s
Show

# Truncated: the long paragraphs run off the right edge.
Sleep 2.5s

# ctrl+w: soft-wrap, the whole paragraph (and the changed word) is visible.
Ctrl+W
Sleep 3.5s

# ctrl+w again: back to truncating.
Ctrl+W
Sleep 2s
