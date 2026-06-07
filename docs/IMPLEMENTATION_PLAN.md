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
- Add staged/unstaged/tracked/untracked file status filters.
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

Continue with section 2:

1. Add file tree grouping.
2. Add patch/hunk/line staging in the diff view.
3. Re-run build and tests after each step.
