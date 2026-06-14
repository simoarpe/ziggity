# ziggity Implementation Plan

This plan tracks the next stages for turning the current MVP into a more
complete lazygit-inspired Zig TUI Git client. Work should proceed in order so
the core remains testable before larger workflows are added.

## Feature Workflow Rule

Before adding any new user-facing feature, inspect how lazygit implements the
same or closest workflow. Record the relevant lazygit files/functions in the
working notes or final summary, then implement the ziggity version pragmatically
rather than as a line-by-line port.

## 1. Stabilize The MVP

- Add focused tests for Git parsers:
  - `git status --porcelain -z`
  - `git branch --format`
  - `git log --pretty`
  - `git stash list --format`
- Add lightweight app/action tests where behavior can be validated without a
  real terminal.
- Improve command failure messages and make parser failures local to the panel
  where possible.
- Keep validation commands passing:
  - `zig fmt`
  - `zig build`
  - `zig build test`

## 2. Strengthen The Files Workflow

- Add confirmation prompts.
- Implement discard selected file.
- Implement discard all changes.
- Add file filtering/search. Implemented: lazygit-style live files-panel path
  filtering with `/`, whitespace-separated substring terms, and smart case.
- Add fuzzy filter mode and filter history.
- Add staged/unstaged/tracked/untracked file status filters. Implemented:
  compact lazygit-style status filter menu with `<ctrl+b>` and `s/u/t/T/r`.
- Add file tree grouping.
- Add patch/hunk/line staging in the diff view.

## 3. Improve Commit Workflows

- Add amend last commit.
- Add multiline commit description prompt.
- Add commit-with-editor support.
- Add reset selected commit:
  - soft
  - mixed
  - hard
- Add revert selected commit.
- Add selected commit file list mode.

## 4. Expand Branch And Remote Workflows

- Create branch.
- Rename branch.
- Delete branch.
- Merge selected branch into current branch.
- Rebase current branch onto selected branch.
- Add remote branches panel.
- Add upstream management.
- Add push upstream setup prompt.

## 5. Add Async Execution

- Keep the current scoped timer refresh for files/status.
- Keep the current full refresh on terminal focus regain.
- Move long-running Git commands off the UI loop.
- Add loading state for in-flight commands.
- Add command log panel.
- Add background fetch timers.
- Make all panel refreshes granular so one failed loader does not break the
  whole app.

## 6. Add Secondary Panels

- Tags.
- Remotes.
- Worktrees.
- Submodules.
- Reflog.

## 7. Expand Configuration

- Replace `.ziggity.ini` with a richer config format.
- Support global and repo-local config merging.
- Add theme config.
- Add broader keybinding remapping.
- Add custom commands.

## Current Priority

A dedicated lazygit TUI/UX fidelity pass is complete — see
`docs/LAZYGIT_ALIGNMENT.md` and git history (panel numbering/navigation,
context-sensitive bottom bar, centered popups for menus/confirmations/commit,
and the discard menu).

Panel tabs (`[`/`]`) are now implemented for both the Branches panel
(Local/Remotes/Tags) and the Commits panel (Commits/Reflog).

Branch workflows are largely done: new (`n`), delete (`d` menu), merge (`M`),
rebase (`r`), and remote/tag checkout. Still open: rename and fast-forward
(both need a non-conflicting key decision), and a merge/rebase **conflict
resolution** flow (conflicts currently surface as an error message + `U` file
statuses, with no in-app resolver).

Commit workflows: reset (`g`, soft/mixed/hard menu), revert (`t`), and a
navigable commit **file list** on `<enter>` (drill into a commit, pick a file
with `j`/`k`, scroll its diff, `esc` to go back) are done.

Branch rename (`R`) and hunk- + line-level staging (`<enter>` on a file →
stage/unstage individual lines with `v` for a range, or whole hunks on a `@@`
header, `tab` to switch unstaged/staged sides; via `src/diff.zig` line-patch
construction + `git apply --cached [--reverse]`) are done.

Branch fast-forward (`f` in the Branches panel: `git pull --ff-only` for the
current branch, `git fetch <remote> <ref>:<local>` for others) is done.

File-tree grouping in the Files panel (toggle with `` ` ``; collapsible
directories via `src/filetree.zig`; `enter` collapses/expands, `space` stages a
whole directory) is done.

Also done since: merge/rebase **conflict resolution** (take ours/theirs,
continue/abort, MERGING/REBASING in the status panel), **tag** create/delete and
**remote-branch** delete (tab-aware `n`/`d`), a **command-log** overlay (`@`),
configurable **theme colors** + fully remappable keys, and user-defined
**custom commands** (`command.<key>` in config).

Remaining (large/architectural — scope before implementing):

1. **Async / non-blocking command execution.** Today every git call runs
   synchronously on the UI event loop. Making it non-blocking needs a job
   system (worker spawn, completion events, in-flight/loading UI, cancellation)
   touching the event loop and every mutation — a substantial rewrite.
2. **Worktrees and submodules panels.** The layout is a fixed five-panel column;
   adding these needs either a sixth panel (layout rework) or a new tabbed host,
   plus new git loaders/actions.
3. Re-run `zig fmt`, `zig build`, and `zig build test` after each step.
