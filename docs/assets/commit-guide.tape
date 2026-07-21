# VHS tape for the commit dialog gif in the README.
# Regenerate with:  vhs docs/assets/commit-guide.tape   (repo root; first run
# the demo repo setup in docs/assets/demo-repos.sh).
# Shows the 50/72 guidance: the live subject counter turning red past 50
# characters, then the body with its wrap guide column at 72.

Output docs/assets/ziggity-commit-guide.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 45ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-commit && $Z"
Enter
Sleep 2.5s
Show

# Open the commit dialog and type a subject that drifts past 50 characters:
# the counter turns red the moment it crosses the limit.
Type "c"
Sleep 1s
Type "Add line and column tracking to the lexer and expose token spans"
Sleep 2s

# Trim the tail back under 50: the counter returns to yellow.
Backspace 23
Sleep 1.5s

# Switch to the body: the soft guide column at 72 marks the wrap width.
Tab
Sleep 800ms
Type "The lexer records the line and column of every token so diagnostics"
Enter
Type "can point at exact source locations."
Sleep 3s
