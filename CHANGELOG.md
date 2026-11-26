# Changelog

All notable changes to ziggity are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and ziggity aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

How it works: add a bullet under `## [Unreleased]` as you land a user-facing
change, grouped under `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, or
`Security`. When `release.sh` cuts a release it stamps the Unreleased section
with the version and date, so whatever you wrote there becomes the published
GitHub release notes (and the release Atom feed entry). Keep entries short and
written for someone using ziggity, not reading the diff.

Releases before 0.55.0 are listed on the
[GitHub releases page](https://github.com/simoarpe/ziggity/releases).

## [Unreleased]

### Added
- Small and mobile terminals are now supported. ziggity renders down to a 10x9
  terminal, squashing unfocused side panels to their title bars when the window
  is short. On a narrow, tall terminal (a phone, for example) it switches to a
  stacked "portrait" layout: the side panels sit above the main panel instead of
  beside it. A new `portrait_mode` setting (`auto` default, or `always` /
  `never`) controls this; `auto` stacks when the width is 84 or less and the
  height is 46 or more. In the stacked layout `side_panel_width_percent` sets the
  side section's share of the height.

## [0.66.0] - 2026-11-21

### Changed
- AI settings are now grouped under an `ai.*` namespace (`ai.command`,
  `ai.commit.auto_title`, `ai.commit.auto_description`, `ai.commit.style_defaults`,
  plus the new `ai.commit.instructions` and `ai.pr.instructions` path settings).
  The old flat keys still work as aliases. The commit and PR instruction files
  are now opt-in and located by the config path: with the setting unset nothing
  is loaded (no implicit default location). A relative path resolves against the
  directory of the config file that set it (so `./commit-instructions.md` sits
  next to your `.ziggity.ini`, or next to a global `ZIGGITY_CONFIG`); an absolute
  path is used as-is. The previous automatic loading of
  `.ziggity/commit-instructions.md` / `.ziggity/pr-instructions.md` and the
  `~/.config/ziggity/` fallback are removed: set `ai.commit.instructions` /
  `ai.pr.instructions` to the file's path to use one.
- The `/` filter (Files, branches, commits, remotes, tags) now matches by
  substring by default, instead of a scattered subsequence. Each
  whitespace-separated term must appear as a run of characters, so typing `di`
  keeps `diff` but no longer `android-support`. Matching stays smart case:
  lowercase matches any case, and an uppercase letter makes that term
  case-sensitive. A new `filter_mode` setting (`substring` default, or `fuzzy`)
  restores the old scattered-subsequence matching.

### Added
- The Status panel's about screen now shows a support link
  (`https://ko-fi.com/simoarpe`) above the animation. It is clickable, as is the
  repository link next to it.
- The keybindings help overlay (`?`) now has a `/` search that highlights
  matches in place instead of hiding the rest. A footer shows the `/` prompt;
  type at least two characters to highlight every occurrence and jump to the
  first; `enter` or `n` jump to the next match and `N` to the previous (the
  current match is highlighted distinctly and briefly pops when you land on it);
  esc clears the search, and a second esc closes the overlay.
- `e` now opens your editor at the line you are looking at: the cursor line in
  the staging or patch view, or the top line of a focused Diff panel. All editor
  presets support it, and a custom `editor_command` can use a new `{{line}}`
  placeholder.
- The `/` name filter now works on the Tags tab and inside a remote's branches,
  not just on the Local tab. Press `/` and type to narrow the Tags list, or drill
  into a remote with `enter` and `/` to narrow its branches; enter accepts and
  esc clears, the same as for local branches. On the remotes list itself `/`
  reminds you to pick a remote first.

## [0.65.0] - 2026-11-20

### Fixed
- Clicking the Status panel no longer traps the mouse on it. Focusing the Status
  panel shows the about splash, and while it was up a click anywhere was
  swallowed, so you could select panel 1 with the mouse but never click to
  another panel. Clicks outside the Status panel now focus the panel they land
  on, as before.

## [0.64.0] - 2026-11-20

### Added
- Nix flake: `nix run github:simoarpe/ziggity` runs Ziggity without installing
  it, and `nix develop` gives contributors a shell with the pinned Zig version.
- Terminals that support the Program Status Protocol (OSC 7501), such as Rex,
  now show what Ziggity is doing on an unfocused tab: busy during a fetch, pull,
  push, rebase or AI generation, waiting when it needs credentials or a
  force-push confirmation, and failed while an error dialog is open.

## [0.63.0] - 2026-11-19

### Fixed
- The side-by-side and unified diffing view (`W`) now refreshes when its base
  branch moves. Comparing against a branch such as `master` and then pulling (or
  committing, or resetting) so that branch advances used to leave the view
  showing the diff against the old commit, because the cached diff was keyed by
  the branch name and the name had not changed. It now recomputes against where
  the base points now, so the comparison matches the current branches.

## [0.62.0] - 2026-11-15

### Fixed
- The text cursor now lands on the right column in the commit message editor (and
  the other input fields) when the text contains wide characters such as CJK. The
  caret, the horizontal scroll, and click-to-position are measured in display
  cells instead of bytes, so composing a message in Chinese, Japanese, or Korean
  no longer drifts the cursor off the text.
- Discarding a hunk with `d` in the side-by-side review of a working-tree file no
  longer closes the review. It stays open on the next change, matching how discard
  already worked from the staging view, and closes only when the file has no more
  changes.

## [0.61.0] - 2026-11-10

### Changed
- Build against Zig 0.17.1, up from 0.16.0. Building from source now needs Zig
  0.17.1 on your `PATH`.

## [0.60.0] - 2026-11-10

### Added
- A side-by-side review of the current diff: press `|` to open it full screen,
  the old file on the left and the new on the right with lines aligned, file line
  numbers down each side, and the changed words emphasized. `j`/`k`, the wheel,
  `PageUp`/`PageDown` and `Home`/`End` scroll, `J`/`K` (or `shift+↑`/`shift+↓`)
  jump to the next and previous change, landing its header at the top, and
  `space` recentres on the selected hunk; the current change is framed in a rounded panel
  titled with its hunk header, and that header stays pinned to the top while you
  scroll through the hunk. Clicking a line (or the frame) selects its hunk, and
  dragging over one column selects its text (the old file on the left, the new on
  the right, never both) and copies it to the clipboard on release, leaving out
  the line numbers and hunk headers.
  `d` discards the whole current hunk (offered only for changes that are not yet
  committed, so a working-tree file or the staging view, never a commit or a `W`
  comparison), `=` fills in the rest of the file around a single file's changes
  (every unchanged line shown, each change still its own boxed, navigable hunk),
  `^w` soft-wraps both columns kept line for line,
  `H`/`L` pan, and `esc` returns. A terminal too narrow for two columns falls
  back to the unified view. From the staging view, `|` reviews the active side
  and opens on the hunk the staging cursor is on, and `d` discards from that side.

### Fixed
- Emoji and other characters made of several code points (a base plus a
  variation selector, a zero-width-joiner sequence, a skin-tone modifier, or a
  flag) now render as one glyph in the diff panels and lists, instead of
  splitting apart and shifting the rest of the line.

## [0.59.0] - 2026-11-06

### Fixed
- A fetch or pull that fails because the remote replaced a branch with one
  nested under its old name (for example `topic` became `topic/part-1`, so git
  reports `cannot lock ref ... exists; cannot create ...`) no longer offers to
  delete a lock file that does not exist. Nothing is locked in that case: a
  stale remote-tracking ref is in the way. Ziggity now explains that and offers
  to run `git remote prune <remote>`, then re-runs the fetch or pull. It also
  skips the automatic lock retries for this error, since they could never
  succeed.

## [0.58.0] - 2026-11-05

### Fixed
- The Files panel no longer snaps the selection off a file you picked when the
  same path is listed twice. After `git rm`-ing a tracked file and recreating it,
  `git status` reports both a staged deletion and an untracked file at that path;
  selecting the untracked one and waiting for a background refresh used to jump
  the cursor onto the staged-deletion row, because the selection was restored by
  path alone. It now also matches the file's status, so it stays put.
- Selecting a very large file no longer makes the interface churn. While its
  (large) diff preview was loading, the background working-tree refresh fired on
  every fast spinner tick instead of the normal interval, so `git status` ran
  back to back and the file list was re-read and re-sorted constantly, which
  could make the selection feel jumpy and navigation laggy. The refresh now runs
  at its configured cadence whether or not a preview is loading, while the
  spinner still animates smoothly.

## [0.57.0] - 2026-11-04

### Fixed
- Scrolling a long diff (for example a single generated file with tens of
  thousands of lines) stays smooth instead of becoming clunky. The Diff panel
  used to rescan the whole diff every frame, both to find the first visible line
  and to measure the widest line for the horizontal-scroll clamp. Both are now
  cached by content, so a frame costs the same at the bottom of a huge diff as at
  the top, and a flood of scroll events no longer saturates the event loop (which
  was also stalling the file-list refresh). Measured on a 1.7 MB diff, draining a
  burst of scroll events dropped from about 1.6 s to about 0.5 s. The same cached
  index speeds up scrolling in the staging view and the commit-graph viewer.
- The Diff panel keeps its scroll position when you focus it to read and then
  move back to the list. It used to snap to the top every time focus crossed in
  or out of the panel, even though the same diff was still shown; it now resets
  only when the shown content actually changes (a different file, commit, or
  branch).
- Leaving the `W` diffing view no longer drops the Diff panel at a stale scroll
  position. After scrolling a long ref diff, exiting (or entering) diffing now
  resets the panel to the top, instead of opening the next preview clamped to a
  seemingly random offset.
- A slow or very large diff preview no longer freezes the file list. The
  background working-tree refresh used to pause while any preview was loading, so
  a heavy preview (for example diffing a branch against another ref in a large
  repository) could stall it and stop the Files panel from picking up changes.
  The refresh now runs independently of previews. The branch, commit-range, and
  directory diffs also load a bounded summary first and skip the full patch when
  it is enormous, the guard the single-commit preview already used.

## [0.56.0] - 2026-11-04

### Added
- A `collapse_status` setting shrinks the Status panel to a single title bar,
  like the other side panels, giving its rows to the Files, Branches, and
  Commits lists. The collapsed bar still shows repo, branch, and ahead/behind,
  and the panel expands back on its own during an operation, a merge, rebase, or
  bisect, an active diffing base, or while it is focused. Default off.
- The Branches and Commits panels now pick up history that moved outside
  ziggity (a commit, checkout, branch update, or fetch in another terminal)
  within a couple of seconds, instead of waiting for the slower working tree
  refresh. A new `external_change_interval_secs` setting tunes the cadence
  (default 2 seconds; set it to 0 to disable the check).

### Fixed
- The staging view now picks up edits made to the open file from outside
  ziggity. The diff used to stay frozen until you left and reopened the view;
  it now refreshes on the next background update and when the terminal regains
  focus, without moving your hunk cursor on a quiet refresh.

## [0.55.0] - 2026-10-30

### Added
- AI commit-message generation (`ctrl+g`) now works when rewording, amending, or
  editing a cherry-picked message, not only for a brand-new commit. It reads the
  relevant commit's own diff, so the generated subject and body describe the
  right changes.
- GitHub releases now carry curated notes from this changelog, so the releases
  page and the release Atom feed (`/releases.atom`) describe what changed in each
  version instead of showing only a compare link.
