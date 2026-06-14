# ziggity

`ziggity` is a small Zig terminal UI Git client inspired by
[lazygit](https://github.com/jesseduffield/lazygit). It is not a line-by-line
port. The goal is to keep lazygit's core workflow shape while using idiomatic
Zig, explicit ownership, simple subprocess-based Git integration, and
[libvaxis](https://github.com/rockorager/libvaxis) for the terminal UI.

## Implemented

- Lazygit-style status panel: `<repo> → <branch>` with push/pull status
  (`↑ahead`/`↓behind`, `✓` in sync, `?` no upstream) and a working-tree summary.
  The current branch shows the same push/pull status in the Branches panel.
- Files panel from `git status --porcelain -z`.
- Branches panel from `git branch --format`.
- Recent commits panel from `git log`.
- Stash panel from `git stash list`.
- Diff preview for selected files, commits, branches, and stash entries.
- Keyboard navigation across side panels and the diff panel.
- Files-panel directory-tree view (toggle with `` ` ``): collapsible directories
  (`enter`), stage/unstage a whole directory (`space`).
- Files-panel live path filtering using lazygit-style substring matching.
- Files-panel status filtering for staged, unstaged, tracked, and untracked files.
- Scoped periodic auto-refresh for external working tree changes.
- Full refresh when the terminal reports focus regain.
- Stage/unstage selected file.
- Stage/unstage all files.
- Hunk- and line-level staging: `enter` on a file opens a staging view to
  stage/unstage individual lines (`v` for a range) or whole hunks (`tab`
  switches between the unstaged and staged sides).
- Branches panel tabs (Local/Remotes/Tags/Worktrees/Submodules) and Commits
  panel tabs (Commits/Reflog), switched with `[`/`]`.
- Worktrees tab: list worktrees (current marked) and remove one (`d`, confirmed).
- Submodules tab: list submodules with state and init/update one (`space`).
- Branch workflows: new, rename, delete, merge, rebase, fast-forward,
  remote/tag checkout.
- Tag actions (Tags tab): create (`n`), delete (`d`). Remote-branch delete
  (`d` on the Remotes tab).
- Merge/rebase conflict resolution: take ours/theirs on conflicted files and
  continue/abort (`m`); MERGING/REBASING shown in the status panel.
- Commit workflows: commit, amend (`A`), reset (soft/mixed/hard), revert,
  cherry-pick (`c`), a navigable changed-file list per commit, and interactive
  rebase actions (drop `d`, squash `s`, fixup `f`, edit `e`, reword `r`,
  move `ctrl+j`/`ctrl+k`).
- Discard selected file via a lazygit-style menu (all changes / unstaged only).
- Discard all working tree changes with a confirmation popup.
- Commit staged changes in a centered editor with a summary line and an optional
  multi-line description (`tab` switches fields). Reword reuses the same editor,
  prefilled from the commit.
- Lazygit-style panel numbering (`1`-`5`), `enter`/`esc` to inspect the main
  panel, a context-sensitive bottom bar, and centered popups for menus and
  confirmations.
- Checkout selected branch.
- Non-blocking fetch, pull, and push: they run off the UI loop (the status
  panel shows a "fetching…/pulling…/pushing…" indicator) so the UI stays
  responsive.
- Command-log overlay (`@`), configurable theme colors, fully remappable keys,
  and user-defined custom commands.
- Repo-local and environment-selected config file support.

## Missing

Large lazygit workflows still not implemented:

- Cherry-pick of ranges / clipboard-style copy-paste; undo/redo.
- Click-to-select individual list items (mouse currently focuses panels +
  scrolls).
- Async for all mutations (currently only network ops run off-loop).
- Full lazygit config compatibility.
- Fuzzy filtering and filter history.

## Build

Requires Zig `0.16.0`.

```sh
zig build
zig build test
```

The binary is written to:

```sh
./zig-out/bin/ziggity
```

## Run

Run inside a Git repository:

```sh
./zig-out/bin/ziggity
```

Useful keys:

- `q` or `ctrl+c`: quit
- `R`: refresh
- `?`: keybindings help overlay (`j`/`k` to scroll)
- `@`: show the command log (recent git commands ziggity ran)
- mouse: click a panel to focus it; scroll wheel to navigate/scroll
- `/`: filter files by path live; enter accepts; esc clears
- `` ` ``: toggle the files directory-tree view (collapse dirs with `enter`,
  stage a whole dir with `space`)
- `ctrl+b`: open files status filter menu
- `j`/`k` or arrows: move selection
- `h`/`l`, `tab`/`shift+tab`, or arrows: cycle focus between side panels
- `1`/`2`/`3`/`4`/`5`: focus status, files, branches, commits, stash
- `[`/`]`: switch panel tabs (branches: Local/Remotes/Tags; commits: Commits/Reflog)
- `enter`: inspect the selected item in the main panel; `esc`/`h` returns
- `enter` on a commit: drill into its changed-file list (`j`/`k` to pick a file,
  `enter` to scroll its diff, `esc` to go back)
- `enter` on a file: open the staging view (`j`/`k` move by line, `v` toggles a
  range, `space` stages/unstages the line(s) — or the whole hunk on a `@@`
  header, `tab` switches unstaged/staged side, `esc` goes back)
- `space`: stage/unstage file, checkout branch, or apply stash depending on focus
- `n`: create a new branch from HEAD (branches panel, Local tab)
- `R`: rename the selected local branch (branches panel; refresh elsewhere)
- `f`: fast-forward the selected local branch to its upstream (branches panel;
  fetch elsewhere)
- `d`: delete the selected local branch (menu: delete / force delete)
- `M`: merge the selected branch into the current branch (after confirmation)
- `r`: rebase the current branch onto the selected branch (after confirmation)
- `space` on the Remotes/Tags tab: check out the remote branch or tag
- `g`: reset to the selected commit (menu: soft / mixed / hard)
- `t`: revert the selected commit
- `a`: stage all if there are unstaged files, otherwise unstage all
- `d`: open the discard menu for the selected file (all changes, or unstaged only)
- `D`: discard all working tree changes after confirmation
- `c`: commit staged changes
- `f`: fetch
- `p`: pull
- `P`: push
- `esc`: clear active file filter, cancel prompts, or leave the diff panel

## Config

`ziggity` loads defaults, then optionally reads:

1. The path in `ZIGGITY_CONFIG`
2. `<repo>/.ziggity.ini`

Supported settings:

```ini
side_panel_width_percent = 34
diff_context = 3

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
key.toggle_tree = `
key.conflict_menu = m
key.command_log = @

# Theme colors are terminal palette indices (0-255):
color.selected_bg = 4
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
```

Key values may be a single character or one of `space`, `enter`, `tab`, `esc`,
`backspace`, `ctrl+x`, or `alt+x`. Every binding in the keymap is remappable
via `key.<name>`, and every theme color via `color.<name>`.

Custom commands bind a key to a shell command run in the repo root (output and
status surfaced in the message line; the view refreshes afterward):

```ini
command.C = git commit --amend --no-edit
command.ctrl+t = ctags -R .
```

Custom commands take precedence over built-in bindings and only run when you
press their key, so a repo-local `.ziggity.ini` cannot run anything on its own.

## libvaxis Usage

The TUI layer uses libvaxis' low-level API:

- `vaxis.Tty` for terminal raw mode and writing.
- `vaxis.Loop(Event)` for keyboard, resize, focus, and refresh tick events.
- `vaxis.Window.child` for panel layout and borders.
- `Window.printSegment` and cell styles for text rendering.
- Alternate screen rendering with explicit redraws after each event.

## Architecture

- `src/main.zig`: process entry point and startup error reporting.
- `src/app.zig`: application state, focus, selections, actions, full/scoped
  refreshes, and commit prompt handling.
- `src/git.zig`: Git subprocess wrapper and parsers.
- `src/tui.zig`: libvaxis event loop, layout, and rendering.
- `src/model.zig`: owned domain models and status derivation.
- `src/config.zig`: default config and simple keybinding parser.
- `src/actions.zig`: action names used by the app layer.
- `src/log.zig`: placeholder logger hook for future diagnostics.

All Git data is loaded through `git` commands rather than reimplementing Git
internals.
