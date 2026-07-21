# VHS tape for the async operations gif in the README.
# Regenerate with:  vhs docs/assets/async-fetch.tape   (repo root; first run
# docs/assets/demo-repos.sh, which clones ziggity into /tmp/zdemo-fetch so the
# fetch hits a real network remote and the spinner is visible).
# NEVER record action tapes against a real working repository: keys mean
# different things per panel (in Commits, f is fixup, a history rewrite).
# Shows a fetch running with the Status panel spinner while list navigation
# stays live. No terminal switch, no "press enter to return".

Output docs/assets/ziggity-async-fetch.gif

Set Shell "bash"
Set FontSize 40
Set Width 3000
Set Height 1600
Set Padding 40
Set Framerate 24
Set Theme { "name": "TokyoNight Moon", "background": "#222436", "foreground": "#c8d3f5", "cursor": "#c8d3f5", "selection": "#2d3f76", "black": "#1b1d2b", "red": "#ff757f", "green": "#c3e88d", "yellow": "#ffc777", "blue": "#82aaff", "magenta": "#c099ff", "cyan": "#86e1fc", "white": "#828bb8", "brightBlack": "#444a73", "brightRed": "#ff757f", "brightGreen": "#c3e88d", "brightYellow": "#ffc777", "brightBlue": "#82aaff", "brightMagenta": "#c099ff", "brightCyan": "#86e1fc", "brightWhite": "#c8d3f5" }

Hide
Type "Z=$PWD/zig-out/bin/ziggity; cd /tmp/zdemo-fetch && $Z"
Enter
Sleep 2.5s
Show

# Fetch from the Files panel (f is fetch here), then move to the commit list
# and keep navigating while the network op runs: the spinner lives in the
# Status panel and the UI never blocks.
Type "f"
Sleep 300ms
Type "4"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 250ms
Type "k"
Sleep 200ms
Type "j"
Sleep 250ms
Type "j"
Sleep 2s
Type "k"
Sleep 200ms
Type "k"
Sleep 2.5s
