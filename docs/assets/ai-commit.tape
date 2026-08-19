# VHS tape for the AI commit authoring gif in the README.
# Regenerate with:  vhs docs/assets/ai-commit.tape   (repo root; first run
# the demo repo setup in docs/assets/demo-repos.sh).
# Records offline against a stub ai_command (see demo-repos.sh) that prints a
# canned subject and body after a short pause, so the per-field spinner shows.

Output docs/assets/ziggity-ai-commit.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 45ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-commit-ai && $Z"
Enter
Sleep 2.5s
Show

# A change to the lexer is staged. Open the commit dialog.
Type "c"
Sleep 1.2s

# Generate the subject from the staged diff: the field shows a spinner, then
# the AI's subject line lands (ctrl+g).
Ctrl+G
Sleep 2.4s

# Move to the description and generate a body that complements the subject.
Tab
Sleep 700ms
Ctrl+G
Sleep 2.8s

# Let the finished message sit for a beat.
Sleep 1.8s
