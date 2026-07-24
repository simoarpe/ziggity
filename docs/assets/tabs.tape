# VHS tape for the panel-key tab cycling demo GIF (issue #6), on the shared
# canvas (3000x1600, FontSize 40) so it matches the other README assets.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/ztabs, a repo
# with local branches, a remote and tags), then from the repo root:
#   vhs docs/assets/tabs.tape
# Safe: it opens a throwaway demo repo and only presses number keys.

Output docs/assets/ziggity-tabs.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/ztabs/repo && $Z"
Enter
Sleep 3s
Show
Sleep 800ms

# Press 3 to focus Branches (Local tab), then 3 again to walk the tabs.
Type "3"
Sleep 1.6s
Type "3"
Sleep 1.6s
Type "3"
Sleep 1.6s
Type "3"
Sleep 1.2s

# 4 walks the Commits panel tabs: Commits -> Reflog -> Divergence.
Type "4"
Sleep 1.4s
Type "4"
Sleep 1.4s
Type "4"
Sleep 1.6s
