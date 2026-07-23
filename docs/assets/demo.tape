# VHS tape: a short product-tour MP4 of Ziggity, opening on the animated donut.
# Regenerate: build the demo repo first (a LOCAL clone of ziggity with a curated
# working tree + a seeded recent list under /tmp/zdemo - never a real repo), then
# from the repo root:
#   vhs docs/assets/demo.tape
# Output: docs/assets/ziggity-demo.mp4
# Navigation and read-only overlays only; it records against a throwaway clone.

Output docs/assets/ziggity-demo.mp4

Set Shell "bash"
Set FontSize 30
Set Width 2560
Set Height 1440
Set Padding 30
Set Framerate 30
Set TypingSpeed 45ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

# Launch on the curated demo repo, pointing the recent-repos store at the seed,
# and focus the Status panel (key "1") where the about splash with the rotating
# ASCII donut lives. Hide the startup so the video opens straight on the donut.
Hide
Type "Z=$PWD/zig-out/bin/ziggity; export XDG_STATE_HOME=/tmp/zdemo/state; cd /tmp/zdemo/ziggity && $Z"
Enter
Sleep 3s
Type "1"
Sleep 700ms
Show

# Open on the donut spinning.
Sleep 4s

# Into the tour: Files + live diff preview, onto a modified file.
Type "2"
Sleep 1s
Type "j"
Sleep 1.3s

# Stage by hunk and line: open the staging view and dwell on it, then back out.
Enter
Sleep 3s
Escape
Sleep 800ms

# Commits panel with per-commit diff preview (incl. GPG signature status).
Type "4"
Sleep 700ms
Type "j"
Sleep 1.5s

# The real git log --graph, current branch and its upstream; a shows all branches.
Ctrl+L
Sleep 2.5s
Type "a"
Sleep 1.5s
Escape
Sleep 700ms

# Diffing mode: mark a ref, the title tracks the comparison in git's notation.
Type "3"
Sleep 700ms
Type "j"
Sleep 500ms
Type "W"
Sleep 2s
Escape
Sleep 700ms

# Recent-repositories switcher (ctrl+r): jump between repos without restarting.
Ctrl+R
Sleep 2.5s
Escape
Sleep 600ms

# Keybindings overlay, scrolled to the current panel.
Type "?"
Sleep 2s
Escape
Sleep 600ms

# Quit.
Type "q"
Sleep 1.2s
