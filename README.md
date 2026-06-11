# ziggity

`ziggity` is a small Zig terminal UI Git client inspired by
[lazygit](https://github.com/jesseduffield/lazygit). It is not a line-by-line
port. The goal is to keep lazygit's core workflow shape while using idiomatic
Zig, explicit ownership, simple subprocess-based Git integration, and
[libvaxis](https://github.com/rockorager/libvaxis) for the terminal UI.

## Implemented

- Repository status summary with current branch, upstream, ahead/behind counts,
  and staged/unstaged file counts.
- Files panel from `git status --porcelain -z`.
- Branches panel from `git branch --format`.
- Recent commits panel from `git log`.
- Stash panel from `git stash list`.
- Diff preview for selected files, commits, branches, and stash entries.
- Keyboard navigation across side panels and the diff panel.
- Files-panel live path filtering using lazygit-style substring matching.
- Files-panel status filtering for staged, unstaged, tracked, and untracked files.
- Scoped periodic auto-refresh for external working tree changes.
- Full refresh when the terminal reports focus regain.
- Stage/unstage selected file.
- Stage/unstage all files.
- Discard selected file with confirmation.
- Discard all working tree changes with confirmation.
- Commit staged changes with an in-app one-line commit prompt.
- Checkout selected branch.
- Fetch, pull, and push.
- Basic repo-local and environment-selected config file support.

## Missing

This is an MVP. Large lazygit workflows are intentionally not implemented yet:

- Patch/hunk/line staging.
- Interactive rebase, squash/fixup flows, cherry-pick flows, and undo/redo.
- Merge conflict helpers.
- Custom commands and custom command menus.
- Remote branch, tag, worktree, and submodule panels.
- Mouse handling.
- Nonblocking async command execution.
- Full lazygit config compatibility.
- File tree grouping, fuzzy filtering, and filter history.

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
- `/`: filter files by path live; enter accepts; esc clears
- `ctrl+b`: open files status filter menu
- `j`/`k` or arrows: move selection
- `h`/`l`, `tab`/`shift+tab`, or arrows: cycle focus between side panels
- `1`/`2`/`3`/`4`/`5`: focus status, files, branches, commits, stash
- `enter`: inspect the selected item in the main panel; `esc`/`h` returns
- `space`: stage/unstage file, checkout branch, or apply stash depending on focus
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

key.quit = q
key.refresh = R
key.file_filter = /
key.open_status_filter = ctrl+b
key.discard = d
key.discard_all = D
key.commit = c
key.push = P
key.select = space
```

Key values may be a single character or one of `space`, `enter`, `tab`, `esc`,
`backspace`, `ctrl+x`, or `alt+x`.

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
