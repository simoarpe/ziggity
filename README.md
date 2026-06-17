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
- Files-panel live fuzzy path filtering (smart-case subsequence matching) with
  recall of recent filters (`up`/`down` in the filter prompt).
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
  cherry-pick copy/paste (`c` copies commits to a clipboard, `v` pastes them
  onto HEAD), a navigable changed-file list per commit, and interactive rebase
  actions (drop `d`, squash `s`, fixup `f`, edit `e`, reword `r`,
  move `ctrl+j`/`ctrl+k`, create `fixup!` commit `F`, autosquash `S`).
- Rebase onto a marked base (`B` marks a commit; rebasing a branch then replays
  the marked commit through HEAD onto it via `git rebase --onto`).
- Mid-rebase amend: when a rebase stops at an `edit` step, the `m` actions menu
  can amend the stopped commit with the staged changes and continue.
- Safe undo of the last operation (`z`, reflog hard-reset after confirmation).
- Diffing mode (`W`): mark a commit/branch, then select another to view
  `git diff` between the two refs in the main panel.
- Commit log filtering (`/` in the Commits panel): filter by message (`--grep`),
  author, or path; the filter persists across refreshes and is shown in the
  panel title (`esc` clears it).
- Git bisect (`b` in the Commits panel): start by marking the selected commit
  good/bad, then mark the current checkout good/bad/skip until the first bad
  commit is found; reset when done.
- Custom patch building (`ctrl+p`): in a commit's file list, `space` toggles
  files into a patch; then apply it to the working tree (forward/reverse),
  remove it from its source commit (rebase + amend), or reset it.
- Copy the selected commit hash / branch / tag to the system clipboard
  (`ctrl+o`, via OSC 52) and open the selected commit or branch on its remote
  host in a browser (`o`).
- Remote management (Branches panel, Remotes tab): add (`n`), edit URL (`e`),
  remove (`x`), and set the current branch's upstream (`u`).
- Stash menu (`s` in the Files panel): stash all, including untracked,
  staged-only, or just the selected file — plus apply/pop/drop on the Stash panel.
- lazygit-style action feedback: fast actions (stage, checkout, commit, reset,
  stash apply/pop/drop, …) succeed silently with a one-line summary in the
  bottom bar; only failures pop a dialog. Slow / multi-step actions (merge,
  rebase, autosquash, interactive-rebase edits, custom-patch apply, fast-forward,
  bisect) run off the UI loop with a spinner in the Status panel — navigation
  stays live while they run, and other actions wait until they finish. Network
  ops (fetch/pull/push) likewise run off the loop. See `result_dialog` /
  `command_output` under Config to tune dialog behavior.
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

The lazygit-parity feature roadmap is complete. Smaller gaps that remain:

- Redo (undo is implemented; redo of an undo is not).
- Moving a custom patch to a *different* commit (only apply / remove-from-commit
  are implemented).
- Full lazygit config compatibility.
- Score-based fuzzy ranking (current fuzzy filter matches but preserves order).

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
- `z`: undo the last operation (reflog reset, after confirmation)
- `@`: show the command log (recent git commands ziggity ran)
- `ctrl+o`: copy the selected hash / branch / tag to the system clipboard
- `o`: open the selected commit or branch on its remote host
- `W`: diffing mode — mark a ref, then select another to diff (esc exits)
- mouse: click a panel to focus it; scroll wheel to navigate/scroll
- `/`: filter files by path live; enter accepts; esc clears
- `` ` ``: toggle the files directory-tree view (collapse dirs with `enter`,
  stage a whole dir with `space`)
- `ctrl+b`: open files status filter menu
- `j`/`k` or arrows: move selection
- `h`/`l` or arrows: cycle focus between side panels
- `tab`: focus the Diff panel (press `tab` again to return to the side panel)
- `1`/`2`/`3`/`4`/`5`: focus status, files, branches, commits, stash
- `[`/`]`: switch panel tabs (branches: Local/Remotes/Tags; commits: Commits/Reflog) or the staging view's unstaged/staged side
- `enter`: inspect the selected item in the main panel; `esc`/`h` returns
- `enter` on a commit: drill into its changed-file list (`j`/`k` to pick a file,
  `enter` to scroll its diff, `esc` to go back)
- `enter` on a file: open the staging view (`j`/`k` move by line, `v` toggles a
  range, `space` stages/unstages the line(s) — or the whole hunk on a `@@`
  header, `[`/`]` switch unstaged/staged side, `\` toggles a split view showing
  unstaged and staged side by side, `c`/`A` commit/amend the staged changes,
  `esc` goes back)
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
- `B`: mark the selected commit as the base for a `rebase --onto`
- `W`: diff the selected commit/branch against another marked ref
- `/` (Commits panel): filter the log by message / author / path
- `b` (Commits panel): bisect menu (start, then mark good/bad/skip/reset)
- `ctrl+p`: custom patch menu (apply / remove from commit / reset); in a
  commit's file list, `space` adds the selected file to the patch
- `a`: stage all if there are unstaged files, otherwise unstage all
- `s` (Files panel): stash menu (all / +untracked / staged / selected file)
- `d`: open the discard menu for the selected file (all changes, or unstaged only)
- `D`: discard all working tree changes after confirmation
- `c`: commit staged changes
- `e`/`x`/`u` (Remotes tab): edit remote URL / remove remote / set upstream
- `m`: merge/rebase actions (continue, amend+continue, abort) while in progress
- `f`: fetch
- `p`: pull
- `P`: push
- `esc`: step back one level — deselect diff text, clear an active filter, exit
  diffing mode, cancel a prompt, leave the staging/diff panel. It never quits
  (only `q` does); at the top level it does nothing.

## Config

`ziggity` loads defaults, then optionally reads:

1. The path in `ZIGGITY_CONFIG`
2. `<repo>/.ziggity.ini`

Supported settings:

```ini
side_panel_width_percent = 34
diff_context = 3

# Side-panel layout (lazygit-style): the Status panel is a fixed height, the
# Files/Branches/Commits lists share the rest equally, and Stash stays small
# unless it's focused. Enable the "accordion" to grow the focused list panel.
expand_focused_side_panel = false  # focused list panel expands, others shrink
expanded_side_panel_weight = 2     # how much bigger the focused panel gets
staging_split = false              # default staging layout: false=single, true=split (\ toggles)

# Action feedback (lazygit-style). Default: actions succeed silently with a
# one-line summary in the bottom bar, and only failures pop a dialog.
result_dialog = on_error    # on_error (default) | always | never
command_output = show       # show (default) custom-command output in a dialog,
                            # or `silent` to follow result_dialog instead

# Skip the confirm-before prompt for individual destructive actions (all
# default false, i.e. confirmations stay on). Names match the action:
skip_confirm.discard_all = false
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
key.toggle_tree = `
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
```

Key values may be a single character or one of `space`, `enter`, `tab`, `esc`,
`backspace`, `ctrl+x`, or `alt+x`. Every binding in the keymap is remappable
via `key.<name>`, and every theme color via `color.<name>`.

Custom commands bind a key to a shell command run in the repo root (output
shown in a dialog by default, or in the message line when `command_output =
silent`; the view refreshes afterward):

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
