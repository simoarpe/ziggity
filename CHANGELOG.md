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
