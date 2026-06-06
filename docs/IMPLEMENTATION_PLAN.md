# ziggity Implementation Plan

This plan tracks the next stages for turning the current MVP into a more
complete lazygit-inspired Zig TUI Git client. Work should proceed in order so
the core remains testable before larger workflows are added.

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
- Add file filtering/search.
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

- Move long-running Git commands off the UI loop.
- Add loading state for in-flight commands.
- Add command log panel.
- Add background refresh.
- Add background fetch timers.
- Make refresh granular so one failed loader does not break the whole app.

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

Start with section 1:

1. Extract pure parser functions where parsing is currently embedded in Git
   command methods.
2. Add parser tests.
3. Add a small action/key mapping layer and tests.
4. Re-run build and tests before moving to discard confirmations.
