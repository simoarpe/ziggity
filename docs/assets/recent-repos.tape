# VHS tape for the recent-repositories switcher screenshot (ctrl+r), on the
# shared canvas (3000x1600, FontSize 40) so it matches the other screenshots.
# Regenerate: run docs/assets/demo-repos.sh first (it builds /tmp/zrecent, a set
# of demo repos plus a seeded recent list under a private state dir), then from
# the repo root:
#   vhs docs/assets/recent-repos.tape
# Safe keys only: this opens a throwaway demo repo and only presses ctrl+r.

# Scrap gif (deleted after the run); the real output is the screenshot.
Output docs/assets/scrap-recent.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 40ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

# Point the switcher at the seeded recent list and open the "aurora" demo repo
# (ziggity prepends it, and the switcher hides it as the current repo).
Hide
Type "Z=$PWD/zig-out/bin/ziggity; export XDG_STATE_HOME=/tmp/zrecent/state; cd /tmp/zrecent/projects/aurora && $Z"
Enter
Sleep 3s
Show
Sleep 500ms

# ctrl+r: the recent-repositories switcher, five repos on their branches.
Ctrl+R
Sleep 1.5s
Screenshot docs/screenshots/19-recent-repos.png
Sleep 300ms
