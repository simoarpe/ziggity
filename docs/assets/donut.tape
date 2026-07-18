# VHS tape for the animated donut preview in the README.
# Regenerate with:  vhs docs/assets/donut.tape   (run from the repo root)
# Produces docs/assets/ziggity-donut.gif — Ziggity's Status panel "about"
# splash with the rotating ASCII donut.

Output docs/assets/ziggity-donut.gif

Set Shell "bash"
Set FontSize 18
Set Width 1000
Set Height 760
Set Padding 18
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

# Launch Ziggity and focus the Status panel (key "1"), where the about splash
# with the donut lives. Hide the startup so the GIF is just the spinning donut.
Hide
Type "./zig-out/bin/ziggity"
Enter
Sleep 2.5s
Type "1"
Sleep 1s
Show

# Record the donut spinning.
Sleep 8s
