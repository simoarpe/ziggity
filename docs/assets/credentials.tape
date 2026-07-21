# VHS tape for the in-app credential prompt screenshot in the README.
# Regenerate: start the always-401 server and demo repo first (see
# docs/assets/demo-repos.sh, auth section), then run from the repo root:
#   vhs docs/assets/credentials.tape
# A fetch against the 401 remote fails with an auth error, which opens the
# two step credential popup: username, then a masked token field.

# Scrap gif (deleted after the run); the real outputs are the screenshots.
Output docs/assets/scrap-credentials.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set TypingSpeed 60ms
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-auth && $Z"
Enter
Sleep 2.5s
Show

# Fetch (Files panel). The 401 answer opens the username prompt.
Type "f"
Sleep 2s
Screenshot docs/screenshots/15-credential-user.png
Type "simoarpe"
Sleep 800ms
Enter
Sleep 800ms

# The token step: input is masked as it is typed.
Type "ghp_demo_token_1234"
Sleep 1s
Screenshot docs/screenshots/15-credential-token.png
Sleep 500ms
Escape
Sleep 500ms
