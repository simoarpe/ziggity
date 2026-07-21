# VHS tape for the checkout by name gif in the README.
# Regenerate with:  vhs docs/assets/checkout-track.tape   (repo root; first run
# the demo repo setup in docs/assets/demo-repos.sh).
# Shows `c`: typing a remote branch name with live suggestions, then landing on
# a real local tracking branch. One step, no menu, no detached head.

Output docs/assets/ziggity-checkout-track.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 55ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-co/clone && $Z"
Enter
Sleep 2.5s
Type "3"
Sleep 800ms
Show

# Checkout by name: suggestions appear as you type the remote branch.
Type "c"
Sleep 1s
Type "origin/feature/login-form"
Sleep 1.5s
Enter

# Land on a local tracking branch, upstream set. Never a detached head.
Sleep 3.5s
