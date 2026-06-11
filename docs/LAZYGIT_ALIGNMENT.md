# Lazygit Alignment Plan

Goal: make ziggity's TUI — navigation, panels, commands, and presentation —
follow lazygit's conventions closely, using idiomatic Zig. Decisions confirmed
with the maintainer:

1. **Priority: TUI/UX fidelity first** (before new feature breadth).
2. **Match lazygit keybindings/numbering exactly.**
3. **Adopt lazygit-style centered bordered popups** for menus, confirmations,
   and the commit-message editor.

For each feature, inspect lazygit's corresponding workflow first, note the
relevant lazygit files/keys, then implement pragmatically in Zig.

## Status

Iterations 1–5 (the TUI/UX fidelity pass) are **done** — see git history. The
app builds, all tests pass, and the binary launches (TTY required). Remaining
work is the feature backlog below.

## Iterations

Each iteration ends with `zig fmt`, `zig build`, `zig build test`, and a commit.

### 1. Panel numbering & navigation alignment  — DONE
- Make **Status** a focusable bordered panel.
- Number side panels lazygit-style: `1`=Status `2`=Files `3`=Branches
  `4`=Commits `5`=Stash.
- `h`/`l`/`←`/`→`/`<tab>`/`<backtab>` cycle the **side** panels only.
- `<enter>` on a side-panel item focuses the **main** panel (scroll/inspect);
  `<esc>`/`h` returns to the originating side panel.
- Branches/stash: `<space>` performs the primary action (checkout/apply),
  `<enter>` inspects — matching lazygit (`space` vs `enter`).
- Update config defaults, README key list, `.ziggity.ini` docs, and tests.

### 2. Context-sensitive bottom bar  — DONE
- Replace the fixed full-keybinding dump with a lazygit-style **options line**
  that shows only keys valid for the focused panel.
- Keep the transient status message; add an info segment on the right.

### 3. Popup / menu widget layer  — DONE
- Add a small reusable centered-popup renderer (bordered, title, body lines).
- Add a generic selectable **menu** popup (items + `j/k` + `<enter>`/`<esc>`).
- Convert discard confirmation to a centered confirmation popup.
- Convert the status-filter menu to a centered menu popup.

### 4. Discard menu (lazygit `d`)  — DONE
- `d` opens a menu: "discard all changes" / "discard unstaged changes" for
  files that have both staged and unstaged changes; direct discard otherwise.
- Keep `D` = reset/discard-all menu.

### 5. Commit-message popup editor  — DONE
- Replace the bottom-line commit prompt with a centered bordered editor popup.
- Single line first; leave multi-line description as a later enhancement.

## Backlog (after fidelity pass) — tracked in IMPLEMENTATION_PLAN.md
- Panel tabs (`[`/`]`): Branches→Local/Remotes/Tags, Commits→Commits/Reflog.
- New/delete/rename branch; merge/rebase.
- Commit amend/reword/reset/revert; view commit/branch/stash file lists.
- Hunk/line staging.
- Command log panel; async command execution.

## Lazygit references (default keybindings)
- Universal: `q` quit, `<esc>` back, `<tab>`/`<backtab>` next/prev block,
  `h`/`l`/`←`/`→` prev/next block, `1`-`5` jump to block, `[`/`]` prev/next tab,
  `,`/`.` page up/down, `<`/`>` top/bottom, `/` search.
- Files: `<space>` toggle stage, `a` stage/unstage all, `c` commit,
  `d` discard menu, `<enter>` focus staging/main.
- Branches: `<space>` checkout, `<enter>` view commits, `n` new, `d` delete.
- Commits: `<enter>` view files, `g` reset, `t` revert.
- Stash: `<space>` apply, `g` pop, `d` drop, `<enter>` view files.
</content>
</invoke>
