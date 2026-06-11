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

Commit workflows: reset (`g`, soft/mixed/hard menu) and revert (`t`) are done.
Still open: a navigable commit **file list** on `<enter>` (currently the main
panel shows the commit's stat+patch, not a selectable file list).

Next, resume feature breadth:

1. Commit file-list view; branch rename + fast-forward.
2. Merge/rebase conflict handling.
3. Add file tree grouping.
4. Add patch/hunk/line staging in the diff view.
5. Re-run `zig fmt`, `zig build`, and `zig build test` after each step.
