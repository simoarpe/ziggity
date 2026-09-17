# VHS tape for the AI PR-description gif in the README.
# Regenerate with:  vhs docs/assets/pr-generation.tape   (repo root; first run
# the demo repo setup in docs/assets/demo-repos.sh).
# Records offline against a stub ai_command (see demo-repos.sh) that prints a
# canned PR title and markdown body after a short pause, so the spinner shows.

Output docs/assets/ziggity-pr-generation.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 45ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-pr && $Z"
Enter
Sleep 2.5s
Show

# Focus the Branches panel; the feature branch is checked out and selected.
Type "3"
Sleep 1.2s

# Open the AI-generate menu and choose "Generate PR description".
Ctrl+G
Sleep 1.4s
Enter
Sleep 1.2s

# Accept the base ref (prefilled with the default branch, main).
Enter
Sleep 3s

# The generated title and markdown body, in a preview you can copy from.
Sleep 3s
