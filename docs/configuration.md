# Configuration

Every setting, key and color. The [README](../README.md) carries the summary.

Ziggity loads its defaults, then reads (each overriding the previous):

1. the path in `ZIGGITY_CONFIG`
2. `<repo>/.ziggity.ini`

There is **no** auto loaded global file (no `~/.config/ziggity/`, no XDG
path). To apply settings everywhere, point `ZIGGITY_CONFIG` at a file from
your shell profile, e.g.
`export ZIGGITY_CONFIG="$HOME/.config/ziggity/config.ini"`, and a repo's
`.ziggity.ini` overrides those per repo. Without any file, settings fall back
to per repo auto detection (notably the editor).

## All settings (annotated `.ini`)

```ini
side_panel_width_percent = 34
diff_context = 3

# The commit summary character count (shown in the commit and reword dialog)
# turns red once it goes over this many characters; below it, it stays
# yellow. Default 50 (the git subject length convention). Set to 0 to disable
# the red threshold so the count always stays yellow.
commit_summary_limit = 50

# Column of the soft vertical guide drawn in the commit and reword message
# body, marking the git body wrap width. Default 72. Set to 0 to disable it.
commit_body_guide = 72

# Color the Conventional Commits prefix (`type(scope)!:`) in the commit
# list: type in accent, scope muted, breaking `!` in red. Default on.
highlight_conventional_commits = true

# Run the repo's prepare-commit-msg hook when the commit dialog opens and
# prefill the message from its output (e.g. a ticket prefix derived from the
# branch), matching an interactive commit. Default on; false skips the hook.
prepare_commit_msg_hook = true

# AI-assisted commit authoring. `ai_command` is a shell command that reads a
# prompt on stdin and prints a completion on stdout — ziggity treats it as a
# black box, so the provider, model, key, or subscription all live in that tool,
# never in ziggity. AI features (the ctrl+g shortcut in the commit dialog, and
# the two flags below) appear only when this is set. Examples:
#   ai_command = pi -p                     # earendil pi; ChatGPT Plus/Claude Pro/Copilot via `pi-ai login`
#   ai_command = llm                       # Simon Willison's llm (API keys / local)
#   ai_command = ollama run qwen2.5-coder  # local, free
ai_command =
# Start generating automatically when the commit dialog opens (only affects
# automatic start; ctrl+g manual generation is always available when configured).
auto_generate_commit_title = false
auto_generate_commit_description = false

# Seconds between idle background working tree refreshes (git status, run
# off the interface thread). On a big repo a tight interval makes git status
# thrash; default 10. Set to 0 to disable the periodic refresh (it still
# refreshes after operations and when the terminal regains focus).
refresh_interval_secs = 10

# Seconds between quiet background `git fetch`es so the incoming commit
# count (the inbound arrow) updates on its own. Ahead and behind are
# measured against the remote tracking ref, which only advances on a fetch.
# It never prompts: if the remote needs credentials (and no helper has them
# cached) it fails silently. Set to 0 to disable. Default 60.
fetch_interval_secs = 60

# Side panel layout: the Status panel is a fixed height, the Files, Branches
# and Commits lists share the rest equally, and Stash stays small unless it
# is focused. Enable the accordion to grow the focused list panel.
expand_focused_side_panel = false  # focused list panel expands, others shrink
expanded_side_panel_weight = 2     # how much bigger the focused panel gets
staging_split = auto               # staging layout: off | on | auto (default)

# Open the file lists (the Files panel and a commit's or branch's changed
# files) in directory-tree mode instead of a flat list, so you don't have to
# press ` on every launch. Default off; ` still toggles it at runtime.
show_file_tree = false

# Show each local branch's pull/merge request status in the Branches panel as a
# state coloured #<number>, fetched in the background via the host CLI (gh for
# GitHub, glab for GitLab, which already hold your auth). On by default: it
# activates when the tool is installed and authenticated and the remote is
# GitHub or GitLab, and stays silent otherwise. Set false to disable it.
pr_status = true
# Local Branches panel ordering: date (default) | recency | alphabetical
branch_sort_order = date
# Files panel ordering. `name` (default) sorts by path, so a file keeps its
# place as its git status changes and staging a long list never scrambles the
# cursor. `status` groups by state instead: staged, then unstaged, then
# untracked, and by path within each group.
file_sort_order = name             # name (default) | status

# Inline commit graph in the Commits panel: a `git log --graph`-style DAG drawn
# one row per commit, in each author's colour, so merges and branch topology
# read at a glance without opening the ctrl+l overlay. `on` (default) always
# draws it, `focused` only while the Commits panel is the active panel (handy on
# a narrow side panel), `off` never.
commit_graph = on                  # on (default) | focused | off
# Initial scope of the ctrl+l commit-graph overlay: `current` (default) shows the
# current branch and its upstream; `all` shows every branch (where the hollow
# HEAD node stands out among the other refs). `a` toggles it live inside the
# overlay; this just sets which scope it opens with.
commit_graph_scope = current       # current (default) | all
# How `f` (fetch) behaves. `git` (default) runs `git fetch`, which follows your own
# git `fetch.prune` config (set `git config fetch.prune true` to fetch with prune).
# `on` forces fetch with prune (using `fetch --prune`).
# `off` forces fetch without prune (using `-c fetch.prune=false fetch`).
fetch_prune_mode = git             # git (default: follow git's fetch.prune) | on | off
# How `p` (pull) behaves. `git` (default) runs `git pull`, which follows your own
# git `pull.rebase` config (set `git config pull.rebase true` for rebase pulls).
# `menu` opens a menu to pick merge, rebase, or fast-forward-only — but only when
# the branch has local commits to integrate, since a pull with none can only
# fast-forward and there is nothing to choose.
pull_mode = git                    # git (default: follow git's pull.rebase) | menu
# HEAD log ordering. `date` (default) is git's native reverse-chronological
# order, newest commit first. `topo` keeps a branch's commits contiguous so the
# graph lanes stay clean, at the cost of a commit's row no longer following its
# timestamp; it relies on git's commit-graph cache (refreshed in the background
# on startup) to stay fast on huge repos. `author_date` orders by the author
# timestamp instead of the commit timestamp. This applies to the Commits panel,
# the inline graph, and the ctrl+l graph overlay alike, so every view agrees on
# chronology.
log_order = date                   # date (default) | topo | author_date

# Bottom hint bar wrapping. When the quick key hints do not fit the terminal
# width, ziggity can continue them on the next line (and the next) instead of
# truncating. This is the maximum number of rows the hint bar may use. `1`
# (default) keeps the classic single line, truncating hints that overflow (press
# `?` for the full list). Set `2` to allow one extra line, a larger number for
# more, or `full` to wrap onto as many rows as the hints need. `0` turns the bar
# off entirely and hands the row back to the panels; it still appears for prompts
# that need it (commit, filter, confirmations). When wrapping is on, the bar's
# height is stable across navigation: it is sized to the busiest panel, not the
# focused one, so moving between panels never shifts the layout. Its height
# changes only with the terminal width, or when a long status message pushes the
# hints to reflow onto another row. The bar never takes more than half the screen.
footer_hint_rows = 1               # 1 (default, single line) | any number | 0 (off) | full

# Editor for `e`. Resolved in order, first one set wins: editor_command,
# editor_preset, then git core.editor / $GIT_EDITOR / $VISUAL / $EDITOR, then
# vim. Full details under "Editor" below.
editor_preset =                    # vi | vim | nvim | lvim | nano | emacs | micro | helix | kakoune | vscode | sublime | zed | bbedit | xcode
editor_command =                   # explicit command, e.g. "code --reuse-window -- {{filename}}"; overrides editor_preset. A GUI editor also needs editor_in_terminal = false (a bare command otherwise suspends the TUI)
editor_in_terminal =               # empty = use the editor's own default | true = force suspend the TUI | false = force just launch

# Action feedback. Default: silent success plus a bottom bar summary, and
# dialogs only on failure.
result_dialog = on_error    # on_error (default) | always | never
command_output = show       # show (default) custom command output in a dialog,
                            # or `silent` to follow result_dialog instead

# Skip the confirm prompt for individual destructive actions (all default
# false, i.e. confirmations stay on). Names match the action:
skip_confirm.discard_all = false
skip_confirm.amend = false             # confirm before `A` amends the last commit
skip_confirm.drop_commit = false       # confirm before `d` drops a commit
skip_confirm.squash_commit = false     # confirm before `s` squashes a commit down
skip_confirm.merge_branch = false
skip_confirm.rebase_branch = false
skip_confirm.delete_tag = false
skip_confirm.delete_remote_branch = false
skip_confirm.remove_worktree = false
skip_confirm.remove_remote = false
skip_confirm.undo = false
skip_confirm.force_push = false        # auto --force-with-lease when a push is rejected
skip_confirm.force_push_plain = false  # auto --force when force-with-lease is rejected

# Any keymap field can be remapped with key.<name>:
key.quit = q
key.refresh = R
key.file_filter = /
key.open_status_filter = ctrl+b
key.discard = d
key.commit = c
key.push = P
key.select = space
key.rename = R
key.fast_forward = f
key.reset = g
key.revert = t
key.range_select = v
key.paste_commits = V
key.select_branch_commits = *
key.toggle_tree = `
key.toggle_fullscreen = z
key.conflict_menu = m
key.command_log = @

# Theme colors are terminal palette indices (0-255):
color.selected_bg = 4
color.inactive_selected_bg = 8   # selected row in an unfocused panel (dimmer)
color.active = 10
color.added = 10
color.removed = 9
color.staged = 10
color.unstaged = 9
color.warning = 11
color.hunk = 14
color.header = 13
color.accent = 14
color.muted = 8
color.hash = 3                   # commit short hashes in the log
color.tag = 3                    # a tag's annotation and subject in the Tags list
```

The AI helpers referenced by `ai_command` above:
[pi](https://github.com/earendil-works/pi) (the recommended one, covers
everything), [llm](https://github.com/simonw/llm) (any provider via an API key),
and [ollama](https://github.com/ollama/ollama) (local models).

Key values may be a single character or one of `space`, `enter`, `tab`,
`esc`, `backspace`, `ctrl+x`, or `alt+x`. Every binding is remappable via
`key.<name>`, every color via `color.<name>`.

## Custom commands

**Custom commands** bind a key to a shell command run in the repo root
(output in a dialog by default, or the message line with
`command_output = silent`; the view refreshes afterward):

```ini
command.E = git commit --amend --no-edit
command.ctrl+t = ctags -R .
```

Custom commands take precedence over built in bindings and only run when you
press their key, so a repo local `.ziggity.ini` cannot run anything on its
own.

## Staging Layout (`staging_split`)

The staging view (`enter` or `tab` on a file) shows one pane (the active
side) or two side by side (Unstaged | Staged). `staging_split` decides how
each file opens:

| `staging_split` | File with one side | File with staged **and** unstaged |
|---|---|---|
| `off` | single | single |
| `on` | split | split |
| **`auto`** *(default)* | single | **split** |

`\` toggles split or single for the **current file only**. It is not
remembered, so the next file always opens with the layout above. The layout
is chosen when a file opens and not redecided mid edit.

## Editor (`e`)

`e` opens the selected file (in the Files panel, or a commit's file) in an
editor. Two things matter: which command to run, and whether ziggity should
suspend for it. A terminal editor like vim takes over the screen, so ziggity
suspends and resumes when you quit it; a GUI editor like VS Code is just launched
in the background. The three settings below decide both. They are tried in this
order, and the first one that is set wins:

1. **`editor_command`**: an explicit command you write. Put `{{filename}}` where
   the path should go (it is shell quoted for you; if you leave it out, the path
   is appended). ziggity cannot tell whether your command is a terminal or a GUI
   editor, so with `editor_in_terminal` left empty it assumes terminal and
   suspends for it. If your command is a GUI editor, add
   `editor_in_terminal = false`.

2. **`editor_preset`**: a named editor ziggity already knows, which fills in both
   the command and the suspend/launch behavior for you:
   - Terminal (ziggity suspends): `vi`, `vim`, `nvim`, `lvim`, `nano`, `emacs`,
     `micro`, `helix`, `kakoune`
   - GUI (ziggity just launches): `vscode`, `sublime`, `zed`, `bbedit`, `xcode`

   Common binary names work as aliases too: `code` and `code-insiders` mean
   `vscode`, `subl` means `sublime`, `hx` means `helix`, `kak` means `kakoune`,
   `xed` means `xcode`. An unknown name here is ignored and ziggity moves to the
   next step.

3. **Auto detection**: git `core.editor`, then `$GIT_EDITOR`, `$VISUAL`,
   `$EDITOR`. If the value is one of the presets or aliases above, that preset is
   used; otherwise the command runs as a terminal editor.

4. **Fallback**: `vim`.

`editor_in_terminal` is an optional override for that suspend or launch choice:
`true` forces suspend and resume, `false` forces just launch. Left empty it does
not override anything, so the behavior is whatever the chosen editor implies (a
preset's own default, or suspend for a bare `editor_command`). It is never a
third mode; at runtime the editor always either suspends or launches.

That means `editor_preset = vscode` is simply shorthand for
`editor_command = code --reuse-window -- {{filename}}` plus
`editor_in_terminal = false`. The preset just fills in the command and the "do
not suspend" behavior so you do not have to.
