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
# HEAD log ordering. `topo` (default) keeps a branch's commits contiguous so the
# graph lanes stay clean (matching lazygit). It relies on git's commit-graph
# cache to stay fast on huge repos, which ziggity refreshes in the background on
# startup. `date` is git's native reverse-chronological order; `author_date`
# orders by author date.
log_order = topo                   # topo (default) | date | author_date

# Editor for `e`. With nothing set, auto detected from git core.editor, then
# $GIT_EDITOR, $VISUAL, $EDITOR, falling back to vim. See "Editor" below.
editor_preset =                    # vim | nvim | nano | emacs | micro | helix | vscode | sublime | zed | ...
editor_command =                   # explicit template, e.g. "code --reuse-window -- {{filename}}"
editor_in_terminal =               # true = suspend the TUI (terminal editors); false = just launch (GUI)

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

`e` opens the file under view in an editor. The command is chosen in order:

1. **`editor_command`**: your explicit template. Use `{{filename}}` for the
   path (quoted for you); if omitted, the path is appended.
2. **`editor_preset`**: a named built in: `vi`, `vim`, `nvim`, `lvim`,
   `nano`, `emacs`, `micro`, `helix`, `kakoune`, `vscode`, `sublime`, `zed`,
   `bbedit`, `xcode`.
3. **Auto detection**: the first of git `core.editor`, `$GIT_EDITOR`,
   `$VISUAL`, `$EDITOR` (matched to a preset, or run as a terminal editor).
4. **Fallback**: `vim`.

Terminal editors (vim, nano, emacs, micro, helix, kakoune, and friends)
**suspend** ziggity and resume when you quit them; GUI editors (VS Code,
Sublime, Zed, and friends) just **launch**. `editor_in_terminal = true|false`
forces which behavior to use.
