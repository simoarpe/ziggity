<p align="center">
  <img src="docs/assets/ziggity-icon.svg" alt="Ziggity icon" width="128" height="128">
</p>

<h1 align="center">ziggity</h1>

<p align="center">
  A fast, keyboard-driven terminal UI for Git — a <a href="https://github.com/jesseduffield/lazygit">lazygit</a>-style workflow, written in Zig.
</p>

<p align="center">
  <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16.0-f7a41d">
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey">
</p>

`ziggity` brings the core lazygit workflow — stage, commit, branch, rebase, and
inspect history without leaving the terminal — to a small, dependency-light Zig
binary. It is **not** a line-by-line port: it keeps lazygit's feel while leaning
on idiomatic Zig, explicit memory ownership, plain `git` subprocesses (no
libgit2), and [libvaxis](https://github.com/rockorager/libvaxis) for the UI.

<p align="center">
  <img src="docs/screenshots/01-overview.png" alt="Ziggity - the main view" width="900">
</p>

<p align="center"><i>Status, Files, Branches, Commits and Stash panels with a live diff preview and a context-sensitive footer.</i></p>

---

## Contents

- [Installation](#installation)
- [Highlights](#highlights)
- [Screenshots](#screenshots)
- [Features](#features)
- [Keybindings](#keybindings)
- [Configuration](#configuration)
- [Status & Roadmap](#status--roadmap)
- [Development](#development)
- [License](#license)

## Installation

Ziggity needs the `git` command on your `PATH` at runtime — it drives git as a
subprocess. Install a prebuilt binary (below), or build from source.

### Manual Installation

Every [release](https://github.com/simoarpe/ziggity/releases) ships static
binaries for macOS, Linux, and Windows — no Zig toolchain required.

#### macOS / Linux

Grab the archive for your platform from the releases page — `aarch64-macos` or
`x86_64-macos` for macOS, `x86_64-linux-musl` or `aarch64-linux-musl` for Linux
(the musl builds are fully static and run on any distro) — then:

```sh
# set VERSION to the latest release and pick your OS/arch — see the releases page
VERSION=v0.1.0
curl -LO https://github.com/simoarpe/ziggity/releases/download/$VERSION/ziggity-$VERSION-aarch64-macos.tar.gz
tar -xzf ziggity-$VERSION-aarch64-macos.tar.gz
sudo mv ziggity /usr/local/bin/      # or any directory on your PATH
command -v ziggity                   # confirm it's on your PATH
```

On macOS the binary isn't notarized, so Gatekeeper may block it on first run.
Clear the quarantine flag once:

```sh
xattr -d com.apple.quarantine /usr/local/bin/ziggity
```

#### Windows

Download `ziggity-<version>-x86_64-windows-gnu.zip`, unzip it, and put
`ziggity.exe` in a folder on your `PATH`. Requires
[Git for Windows](https://git-scm.com/download/win).

> **Note:** Windows builds are cross-compiled and not yet smoke-tested on
> Windows — treat them as experimental for now.

#### Verify the Download (Optional)

Each release includes a `checksums.txt`:

```sh
sha256sum --ignore-missing -c checksums.txt   # macOS: shasum -a 256 --ignore-missing -c checksums.txt
```

### Compile from Source

**Requirements:** [Zig `0.16.0`](https://ziglang.org/download/) and `git` on your `PATH`.

```sh
git clone https://github.com/simoarpe/ziggity
cd ziggity
zig build -Doptimize=ReleaseSafe     # binary at ./zig-out/bin/ziggity
zig build test                       # (optional) run the test suite
```

The build leaves the binary at `./zig-out/bin/ziggity`. **Add it to your
`PATH`** so you can run `ziggity` from anywhere — either copy it into a
directory already on your `PATH`:

```sh
sudo cp zig-out/bin/ziggity /usr/local/bin/
```

or add `zig-out/bin` to your `PATH` (e.g. in `~/.zshrc` or `~/.bashrc`):

```sh
export PATH="$PWD/zig-out/bin:$PATH"
```

Once installed, run `ziggity` inside any Git repository. Press `?` for the
in-app keybindings overlay (it opens scrolled to the panel you're on), and `q`
to quit.

## Highlights

- **Whole lazygit workflow** — status, files, branches, commits, and stash
  panels with diff previews and a context-sensitive footer.
- **Hunk and line-level staging** — `enter` a file to stage individual lines or
  hunks, with an optional side-by-side unstaged/staged split.
- **Full interactive rebase** — drop/squash/fixup/edit/reword/move per commit, a
  plan editor (`i`), cherry-pick, custom patch building, autosquash, and
  `rebase --onto` from a marked base.
- **History & inspection** — the real `git log --graph` DAG (`ctrl+l`) with
  first-parent jumps, ref-to-ref diffing (`W`) with reverse and three-dot
  (merge-base) modes, GPG signature verification (`x`), and log filtering (`/`).
- **Multi-selection** — `v` / `shift+arrows` select a range in any list to act on
  many files, commits, branches, or stashes at once; `*` selects a branch's own
  commits.
- **Stays in sync** — a quiet background `git fetch` keeps the inbound "commits to
  pull" arrow current on its own; slow and network operations run off the UI
  thread with a spinner while navigation stays live.
- **Thoughtful touches** — `prepare-commit-msg` hook prefill, stash naming and a
  keep-the-working-tree snapshot, per-stash patch export, and bracketed paste so a
  pasted multi-line message never submits early.
- **Lightweight & explicit** — one small binary, plain `git` subprocesses, no
  libgit2, fully remappable keys, themeable colours, and custom commands.

## Screenshots

A visual tour of the main features, captured from a real terminal session (see
[`docs/screenshots`](docs/screenshots)).

### Hunk and Line-Level Staging

`enter` a file to open the staging view — stage or unstage individual lines or
whole hunks (`space`), with an optional side-by-side unstaged/staged split.

![Line-level staging view](docs/screenshots/02-staging.png)

### Commits & History

The Commits panel previews each commit's diff, including its GPG signature status;
`enter` opens the commit's changed files.

![Commits panel with diff preview](docs/screenshots/03-commits.png)

`ctrl+l` opens the real `git log --graph` DAG in git's own colours. By default
it shows the current branch **and its upstream**, so the commits you're behind
by (the remote's lane) are visible right away; `a` toggles all branches. Jump to
the current commit (HEAD) with `@`, or to a commit's first parent with `p`.

![Commit graph viewer](docs/screenshots/04-commit-graph.png)

Full interactive rebase: press `i` on a commit to open a plan editor — mark
`pick` / `drop` / `squash` / `fixup` / `edit`, reorder with `ctrl+j`/`ctrl+k`,
then run it.

![Interactive rebase plan editor](docs/screenshots/10-rebase-plan.png)

### Committing

`c` opens the commit dialog: a summary line plus an optional multi-line body, a
live character count nudging the 50/72 rule, and (optionally) a
`prepare-commit-msg` hook prefill.

![Commit message dialog](docs/screenshots/08-commit-dialog.png)

### Branches & Tags

The Branches panel shows ahead/behind arrows, upstream tracking and per-ref
actions (merge, rebase, reset, checkout…); the Tags tab lists tags with their
messages.

![Branches panel](docs/screenshots/05-branches.png)

![Tags tab](docs/screenshots/06-tags.png)

### Stash

A Stash panel with a diff preview. The stash menu (`s`) offers all / +untracked /
staged-only / a single file / keep-changes, each with an optional message — and
`w` writes any stash to a `git apply`-able patch file.

![Stash panel](docs/screenshots/07-stash.png)

![Stash menu](docs/screenshots/12-stash-menu.png)

### Diffing & Menus

Mark any ref and diff another against it (`W`), with reverse and three-dot
(merge-base) options. Destructive actions route through clear, explicit menus.

![Diffing menu](docs/screenshots/14-diffing-menu.png)

![Reset menu](docs/screenshots/13-reset-menu.png)

### Help & the About Screen

`?` opens the keybindings overlay, scrolled to the panel you're on. Selecting the
Status panel shows an about screen with a live animation.

![Keybindings help overlay](docs/screenshots/09-help.png)

![About screen](docs/screenshots/11-about-splash.png)

## Features

<details open>
<summary><b>Working tree &amp; staging</b></summary>

- Files panel from `git status --porcelain -z`; stage/unstage a file (`space`)
  or everything (`a`).
- Hunk and line-level staging: `enter` opens a staging view to stage/unstage
  individual lines (`v` for a range) or whole hunks (`tab` switches the
  unstaged/staged side; `\` toggles a side-by-side split — see
  [Staging layout](#staging-layout-staging_split)).
- Directory-tree view (`` ` ``) for working-tree files **and** a commit's /
  branch's file list: a `/` root, collapsible folders (`enter`), single-child
  chains compressed to `a/b/c`. Selecting a folder shows the combined diff
  beneath it; in the Files panel `space` stages the whole folder.
- Live fuzzy path filtering (smart-case subsequence) with recent-filter recall,
  plus a status filter (staged / unstaged / tracked / untracked).
- Discard a file — or a whole folder in tree view (`d` on a directory) — via a
  menu (all / unstaged only), or discard everything (`D`, confirmed). Add to
  `.gitignore` (`i`), copy a path (`y`).
- Scoped periodic auto-refresh for external changes, plus a full refresh when
  the terminal regains focus.

</details>

<details>
<summary><b>Branches, tags &amp; remotes</b></summary>

- Branches panel from `git branch --format`: a "time ago" column, per-branch
  tracking status (`✓` in sync, `↑`/`↓` ahead/behind, `(gone)`), and the
  upstream ref shown only when it isn't the obvious `origin/<same-name>`.
- Branch actions (Local tab): new (`n`), rename (`R`), delete (`d`), merge (`M`),
  rebase (`r`), fast-forward (`f`), checkout-by-name (`c`), reset (`g`),
  force-checkout (`F`), tag (`T`), move commits to a new branch (`N`), open the
  pull-request page (`G`), sort menu (`s`).
- Tags tab: checkout (`space`, detached), create (`n`, lightweight or annotated;
  overwrite prompts for `--force`), push to a remote (`P`), reset onto it (`g`),
  delete (`d`, local / remote / both). One remote skips the remote prompt.
- Remotes tab: list remotes, drill into a remote's branches, add (`n`), edit URL
  (`e`), remove (`x`), set the current branch's upstream (`u`), delete a remote
  branch (`d`).
- Worktrees & Submodules tabs (Files panel): list, create/add, open, update,
  remove, a submodule bulk menu (`b`), and **switching repos in place** —
  `space`/`enter` on a worktree (or `enter` on a submodule) re-roots the app onto
  it, with a `parent / current` breadcrumb and `esc` to walk back out.

</details>

<details>
<summary><b>Commits &amp; history</b></summary>

- Recent commits from `git log` (loaded incrementally — the log grows as you
  scroll toward the end, so it's never capped), each row showing the author's
  initials in a stable per-author colour and a highlighted
  [Conventional Commits](https://www.conventionalcommits.org/) prefix (type in
  accent, scope muted, breaking `!` in red; `highlight_conventional_commits`).
  The short hash is tinted by push state — **red** for commits not yet on the
  remote, the usual yellow once pushed.
- Three tabs (`[` / `]` to switch): **Commits**, a **Reflog** recovery view
  (checkout `space`, reset HEAD `g`, branch `n`), and a **Divergence** view of
  the current branch versus its upstream — `↑` ahead (your local commits to
  push) grouped above `↓` behind (incoming commits to pull). The Divergence tab
  is read-only: checkout, branch-off, copy/paste and diff work; history-editing
  keys are disabled.
- Commit (`c`), commit `--no-verify` (`w`), amend (`A`) in a centered editor with
  a summary line and optional multi-line body (`tab` switches fields). The editor
  nudges you toward the [50/72 rule](https://dev.to/noelworden/improving-your-commit-message-with-the-50-72-rule-3g79):
  the summary shows a live character count (yellow, turning red once it exceeds
  `commit_summary_limit` — default 50), and the description shows a soft vertical
  guide at the body-wrap column (`commit_body_guide` — default 72, `0` off). When
  the editor opens, the repo's `prepare-commit-msg` hook runs (as it would for an
  interactive commit) and pre-fills the fields — e.g. a branch-derived ticket
  prefix — editable before you commit (`prepare_commit_msg_hook = true`, disable
  to skip it).
- Per-commit: reset (`g`, soft/mixed/hard), revert (`t`), checkout (`space`,
  detached), branch from it (`n`), move commits to a new branch (`N`), tag (`T`),
  change author (`a`), and a copy-attribute menu (`y`: hash/subject/author).
- GPG signatures: a signed commit's diff shows git's verification block
  (`--show-signature`), and `x` verifies the selected commit's signature on
  demand (result in a dialog) — no per-row cost.
- A navigable changed-file list per commit (`enter`); `d` there discards a file's
  changes from that commit (rebase + amend).
- Commit graph viewer (`ctrl+l`): the real `git log --graph` DAG in git's colours,
  loaded off-thread. The default view shows the current branch and its upstream
  (so incoming commits to pull are visible); `a` toggles all branches. `@` jumps
  to the current commit (HEAD), `p` to the first parent, `enter` jumps the
  selection; mouse scroll/drag/click supported.
- Log filtering (`/`): by message (`--grep`), author, or path; persists across
  refreshes and shows in the panel title.
- Bisect (`b`): mark the selected commit good/bad, then mark good/bad/skip until
  the first bad commit is found.

</details>

<details>
<summary><b>Interactive rebase &amp; patches</b></summary>

- Per-commit interactive rebase: drop (`d`), squash (`s`), fixup (`f`), edit (`e`),
  reword (`r`), move (`ctrl+j`/`ctrl+k`), create `fixup!` (`F`), autosquash (`S`).
- Rebase plan editor (`i`): compose a plan for the commits down to the selected
  one, mark each action (with range-select to mark/reorder many at once), then run
  it as one rebase.
- Cherry-pick: copy commits to a clipboard (`c`), paste onto HEAD (`V`), clear
  (`ctrl+r`).
- Custom patch building (`ctrl+p`): toggle files into a patch (`space` in a
  commit's file list), then apply it to the working tree (forward/reverse),
  remove it from its source commit, or reset it.
- `rebase --onto` from a marked base (`B`), and mid-rebase amend (`m`'s menu can
  amend the stopped `edit` commit and continue).
- Conflict resolution: `enter` on a conflicted file opens a per-conflict
  resolver with line numbers — `j`/`k` walk between conflicts, `o`/`t`/`b` keep
  ours/theirs/both for the current one, `u` undoes the last pick, and the file is
  staged automatically once the last conflict is resolved. `m` still offers the
  whole-op continue/abort actions; `MERGING`/`REBASING` shown in the Status panel.

</details>

<details>
<summary><b>Multi-selection, diffing &amp; stash</b></summary>

- **Range select** in any list: `v` toggles a sticky range, `shift+arrows` extend
  one, `*` (Commits) selects every commit unique to the branch. The action key
  then applies to the whole range — stage/discard/edit files,
  drop/squash/fixup/edit/move/revert or copy commits, delete branches/tags, drop
  stashes, toggle commit files into a patch, or discard files from a commit.
- Diffing mode (`W`): mark a commit/branch, select another, see `git diff` between
  the two refs in the main panel. Re-open the menu to reverse the direction (swap
  which ref is the diff's "from"), toggle a three-dot merge-base diff
  (`base...target` — only the target's own changes since it diverged, the
  GitHub-PR view; the title shows `[base X ...]`), or exit.
- Stash menu (`s`): stash all / +untracked / staged-only / just the selected file /
  keep-changes (snapshot into a stash but leave the working tree untouched). Each
  asks for an optional message (empty = git's default `WIP on …` name). Apply /
  pop / drop / rename (`r`) / write to a patch file (`w` → `stash-<n>.patch`,
  including untracked, `git apply`-able) on the Stash panel.

</details>

<details>
<summary><b>UX &amp; quality-of-life</b></summary>

- **Action feedback (lazygit-style):** fast actions succeed silently with a
  one-line summary; only failures pop a dialog. Slow / multi-step actions (merge,
  rebase, autosquash, patch apply, fast-forward, bisect) and network ops
  (fetch/pull/push) run off the UI loop with a spinner — navigation stays live.
  Tunable via `result_dialog` / `command_output`.
- **Non-blocking fetch/pull/push** (`f`/`p`/`P`) with an in-status indicator.
- **In-app credential entry:** on an HTTPS auth failure, a username + masked
  password/token prompt feeds git for the session (no external helper needed).
- Safe undo of the last operation (`ctrl+z`, reflog hard-reset after confirmation).
- Find the fixup base for a staged change and make a `fixup!` (`ctrl+f`, via
  blame).
- Copy a hash/branch/tag to the clipboard (`ctrl+o`, OSC 52); open a commit/branch
  on its remote host (`o`).
- Command-log overlay (`@`), themeable colours, fully remappable keys, and
  user-defined custom commands.

</details>

## Keybindings

Press **`?`** in the app for the full, always-current overlay. The essentials:

| Key | Action |
|---|---|
| `1`–`5` | Focus Status / Files / Branches / Commits / Stash |
| `h` `l` / arrows | Move focus between side panels |
| `j` `k` / arrows | Move selection |
| `tab` | Focus the Diff panel (and back) |
| `z` | Maximize the Diff panel to full screen (`z`/`esc` to exit) |
| `[` `]` | Switch the focused panel's tabs (or staging side) |
| `enter` / `esc` | Inspect in the main panel / step back |
| `space` | Stage file · checkout branch · apply stash (by focus) |
| `c` · `a` · `d` · `D` | Commit · stage-all · discard menu · discard all |
| `v` · `shift+arrows` · `*` | Start range · extend range · select branch commits |
| `i` · `ctrl+p` · `ctrl+l` | Rebase plan · custom patch · commit graph |
| `f` · `p` · `P` | Fetch · pull · push |
| `z` · `@` · `?` · `q` | Undo · command log · help · quit |

<details>
<summary><b>Full keybinding reference</b></summary>

- `q` / `ctrl+c`: quit
- `R`: refresh
- `?`: keybindings help overlay (`j`/`k` to scroll), opened to the section for the
  current panel
- `ctrl+z`: undo the last operation (reflog reset, after confirmation)
- `@`: command log (recent git commands ziggity ran)
- `ctrl+o`: copy the selected hash / branch / tag to the system clipboard
- `o`: open the selected commit or branch on its remote host
- `W`: diffing mode — mark a ref, then select another to diff; re-open the menu to
  reverse the direction, toggle a three-dot merge-base diff, or exit (esc also exits)
- mouse: click a panel to focus; wheel to navigate/scroll
- `/`: filter files by path live; enter accepts; esc clears
- `` ` ``: toggle the directory-tree view — Files panel **and** a commit's /
  branch's file list. `enter` collapses/expands the folder under the cursor;
  `space` stages a whole directory (Files) or adds it to the custom patch (commit
  files); the `/` root nests everything and diffs all changes when selected
- `ctrl+b`: files status filter menu
- `j`/`k` or arrows: move selection · `h`/`l` or arrows: cycle side panels
- `H`/`L`: scroll the focused panel left/right (diff, or a list wider than the panel)
- `tab`: focus the Diff panel from any side panel (press again to return). Over a
  working-tree file, `enter` there opens its stage/unstage view (the panel title
  and footer show the hint)
- `z`: maximize the Diff panel to full screen — the side panels hide and the diff
  fills the terminal; press `z` again or `esc` to restore the normal layout
- `1`–`5`: focus status / files / branches / commits / stash
- `[`/`]`: switch panel tabs (Files/Worktrees/Submodules · Local/Remotes/Tags ·
  Commits/Reflog) or the staging unstaged/staged side
- `enter`: inspect in the main panel; on a commit, drill into its changed files;
  on a file, open the staging view
- `enter` on a file → staging view: `j`/`k` by line, `v` range, `space` stage
  line(s)/hunk, `[`/`]` switch side, `\` split view, `c`/`A` commit/amend, `esc` back
- `space`: stage/unstage file · checkout branch · apply stash (by focus)
- `e`: open the file under view in your editor (Files, a commit's files, the
  staging/patch view, or a working-tree file's diff — see [Editor](#editor-e))
- `n`: new branch from HEAD (Branches, Local)
- `c`: checkout a branch/ref by name (resolves local, DWIM-tracks remote, detaches
  onto a tag/commit, or `-` for previous)
- `R`: rename the selected local branch (refresh elsewhere)
- `f`: fast-forward the selected local branch (fetch elsewhere)
- `d`: delete the selected local branch (menu: delete / force delete)
- `M` / `r`: merge the selected branch / rebase the current branch onto it
- `g` / `F` (Branches Local): reset to the branch / force-checkout
- `T` / `N` (Branches Local): tag the branch / move its commits to a new branch
- `G` / `s` (Branches Local): open the PR page / branch sort menu
- `space` (Remotes/Tags): check out the remote branch or tag
- `n`/`P`/`g`/`d` (Tags): new tag / push to a remote / reset onto it / delete
- `g` / `t` (Commits): reset menu / revert
- `x` (Commits): verify the selected commit's GPG signature (result in a dialog)
- `space`/`n`/`N` (Commits/Reflog): checkout (detached) / branch from it / move
  commits to a new branch
- `T` / `a` (Commits): tag the commit / change its author
- `y` / `ctrl+r`: copy-attribute menu / clear the cherry-pick selection
- `i` (Commits): interactive rebase plan editor
- `ctrl+l` (Commits): commit graph viewer (`j`/`k` move, `@` current commit,
  `p` first-parent, `H`/`L` pan, `a` toggle all-branches, `ctrl+o` copy,
  `enter` jump, `esc` close; mouse scroll/drag/click)
- `G` (Commits): open the PR page · `B`: mark a `rebase --onto` base
- `W`: diff the selected commit/branch against another marked ref
- `/` (Commits): filter the log · `b` (Commits): bisect menu
- `ctrl+p`: custom patch menu; `space` in a commit's files adds it to the patch
- `a`: stage all (or unstage all) · `s` (Files): stash menu
- `d` / `D`: discard menu for the file / discard all (confirmed)
- `c` · `w` (Files): commit · commit `--no-verify`
- `i` / `y` / `ctrl+f` (Files): add to `.gitignore` / copy path / make a `fixup!`
- `r` (Stash): rename the selected stash
- `e` / `x` / `u` (Remotes): edit URL / remove remote / set upstream
- `m`: merge/rebase actions (continue, amend+continue, abort) while in progress —
  available from any panel, so you never have to switch to Files to continue/abort
- `f` / `p` / `P`: fetch / pull / push
- `esc`: step back one level (deselect, clear filter, exit diffing, cancel a
  prompt, leave a panel); never quits — only `q` does

</details>

## Configuration

`ziggity` loads its defaults, then reads (each overriding the previous):

1. the path in `ZIGGITY_CONFIG`
2. `<repo>/.ziggity.ini`

There is **no** auto-loaded global file (no `~/.config/ziggity/`, no XDG path). To
apply settings everywhere, point `ZIGGITY_CONFIG` at a file from your shell
profile — e.g. `export ZIGGITY_CONFIG="$HOME/.config/ziggity/config.ini"` — and a
repo's `.ziggity.ini` overrides those per-repo. Without any file, settings fall
back to per-repo auto-detection (notably the editor).

<details>
<summary><b>All settings (annotated <code>.ini</code>)</b></summary>

```ini
side_panel_width_percent = 34
diff_context = 3

# The commit-summary character count (shown in the commit/reword dialog) turns
# red once it goes over this many characters; below it, it stays yellow. Default
# 50 (the git subject-length convention). Set to 0 to disable the red threshold
# so the count always stays yellow.
commit_summary_limit = 50

# Column of the soft vertical guide drawn in the commit/reword message body,
# marking the git body-wrap width. Default 72. Set to 0 to disable the guide.
commit_body_guide = 72

# Colour the Conventional-Commits prefix (`type(scope)!:`) in the commit list:
# type in accent, scope muted, breaking `!` in red. Default on.
highlight_conventional_commits = true

# Run the repo's prepare-commit-msg hook when the commit dialog opens and pre-fill
# the message from its output (e.g. a branch-derived ticket prefix), matching an
# interactive commit. Default on; set false to skip the hook at open time.
prepare_commit_msg_hook = true

# Seconds between idle background working-tree refreshes (git status, run off the
# UI thread). On a big repo a tight interval makes git status thrash; default 10.
# Set to 0 to disable the periodic refresh (it still refreshes after operations
# and when the terminal regains focus).
refresh_interval_secs = 10

# Seconds between quiet background `git fetch`es so "commits to pull" (the
# inbound arrow / behind count) updates on its own — ahead/behind is measured
# against the remote-tracking ref, which only advances on a fetch. It never
# prompts: if the remote needs credentials (and no helper has them cached) it
# fails silently. Set to 0 to disable the background fetch. Default 60.
fetch_interval_secs = 60

# Side-panel layout (lazygit-style): the Status panel is a fixed height, the
# Files/Branches/Commits lists share the rest equally, and Stash stays small
# unless it's focused. Enable the "accordion" to grow the focused list panel.
expand_focused_side_panel = false  # focused list panel expands, others shrink
expanded_side_panel_weight = 2     # how much bigger the focused panel gets
staging_split = auto               # staging layout: off | on | auto (default)

# Editor for `e`. With nothing set, auto-detected from git core.editor, then
# $GIT_EDITOR / $VISUAL / $EDITOR, falling back to vim. See "Editor" below.
editor_preset =                    # vim | nvim | nano | emacs | micro | helix | vscode | sublime | zed | ...
editor_command =                   # explicit template, e.g. "code --reuse-window -- {{filename}}"
editor_in_terminal =               # true = suspend the TUI (terminal editors); false = just launch (GUI)

# Action feedback (lazygit-style). Default: silent success + bottom-bar summary,
# dialogs only on failure.
result_dialog = on_error    # on_error (default) | always | never
command_output = show       # show (default) custom-command output in a dialog,
                            # or `silent` to follow result_dialog instead

# Skip the confirm-before prompt for individual destructive actions (all default
# false, i.e. confirmations stay on). Names match the action:
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
key.paste_commits = V
key.select_branch_commits = *
key.toggle_tree = `
key.toggle_fullscreen = z
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
color.hash = 3                   # commit short hashes in the log
color.tag = 3                    # a tag's annotation/subject in the Tags list
```

Key values may be a single character or one of `space`, `enter`, `tab`, `esc`,
`backspace`, `ctrl+x`, or `alt+x`. Every binding is remappable via `key.<name>`,
every color via `color.<name>`.

**Custom commands** bind a key to a shell command run in the repo root (output in
a dialog by default, or the message line with `command_output = silent`; the view
refreshes afterward):

```ini
command.C = git commit --amend --no-edit
command.ctrl+t = ctags -R .
```

Custom commands take precedence over built-in bindings and only run when you
press their key, so a repo-local `.ziggity.ini` cannot run anything on its own.

</details>

### Staging Layout (`staging_split`)

The staging view (`enter`/`tab` on a file) shows one pane (the active side) or two
side by side (Unstaged | Staged). `staging_split` decides how each file opens:

| `staging_split` | One-sided file | Mixed file (staged **and** unstaged) |
|---|---|---|
| `off` | single | single |
| `on` | split | split |
| **`auto`** *(default)* | single | **split** |

`\` toggles split/single for the **current file only** — it isn't remembered, so
the next file always opens with the layout above. The layout is chosen when a
file opens and isn't re-decided mid-edit.

### Editor (`e`)

`e` opens the file under view in an editor. The command is chosen in order:

1. **`editor_command`** — your explicit template. Use `{{filename}}` for the path
   (quoted for you); if omitted, the path is appended.
2. **`editor_preset`** — a named built-in: `vi`, `vim`, `nvim`, `lvim`, `nano`,
   `emacs`, `micro`, `helix`, `kakoune`, `vscode`, `sublime`, `zed`, `bbedit`,
   `xcode`.
3. **Auto-detection** — the first of git `core.editor`, `$GIT_EDITOR`, `$VISUAL`,
   `$EDITOR` (matched to a preset, or run as a terminal editor).
4. **Fallback** — `vim`.

Terminal editors (vim, nano, emacs, micro, helix, kakoune, …) **suspend** ziggity
and resume when you quit them; GUI editors (VS Code, Sublime, Zed, …) just
**launch**. `editor_in_terminal = true|false` forces which behaviour to use.

## Status & Roadmap

The lazygit-parity feature roadmap is **complete**. Known smaller gaps:

- **Redo** — undo (`ctrl+z`) is implemented; redoing an undo is not.
- **Move a custom patch to a *different* commit** — only apply / remove-from-commit
  are implemented.
- **Editing the live rebase todo *mid-rebase*** — ziggity composes the whole plan
  up front in its `i` editor (with range-select), so there's no paused-rebase todo
  view to edit.
- **Reword in your external `$EDITOR`** — ziggity rewords in its own in-app editor
  (`r`), which serves the same purpose.
- **Full lazygit config compatibility** and **score-based fuzzy ranking** (the
  current fuzzy filter matches but preserves order).

See [`docs/ENHANCEMENTS_OVER_LAZYGIT.md`](docs/ENHANCEMENTS_OVER_LAZYGIT.md) for
where ziggity deliberately diverges.

## Development

```sh
zig build                                  # debug build
zig build test --summary all               # run all tests
zig build -Doptimize=ReleaseFast           # optimized build
```

### Source Layout

| File | Responsibility |
|---|---|
| `src/main.zig` | Process entry point and startup error reporting |
| `src/app.zig` | App state, focus, selections, actions, refreshes |
| `src/git.zig` | Git subprocess wrapper and parsers |
| `src/tui.zig` | libvaxis event loop, layout, and rendering |
| `src/model.zig` | Owned domain models and status derivation |
| `src/config.zig` | Defaults and the keybinding/INI parser |
| `src/actions.zig` | Action names shared by the app and key layers |

Supporting modules split cohesive areas out of `app.zig`: `staging.zig`,
`patch.zig`, `commitops.zig`, `rebaseplan.zig`, `drills.zig`, `diffmode.zig`,
`stash.zig`, `branches.zig`, `commits.zig`, `filetree.zig`, `commitgraph.zig`,
`editor.zig`, `diff.zig`, `credentials.zig`. All Git data is loaded through `git`
commands rather than reimplementing Git internals.

### libvaxis Gotcha: Cells Store Graphemes by Reference

libvaxis stores each screen cell's grapheme as a **slice into the source text**
(`Window.print` does `.grapheme = grapheme.bytes(segment.text)` — it does not copy
the bytes), and the frame is flushed **after** `render()` returns. So any text
drawn via vaxis' `printSegment`/`print` must be backed by memory that outlives
`render()` — a string literal or App-owned buffer, **never a stack-local buffer**
(which dangles and renders as garbage / `U+FFFD`, intermittently).

In `src/tui.zig`:

- The local `print` / `printSpan` / `printAnsi` helpers are **safe** with any
  buffer lifetime (they map bytes through a static glyph table), so formatting
  into a stack buffer is fine for list rows, popups, the footer, etc.
- Only vaxis `printSegment` is by-reference, and it's used only for panel/popup
  titles — dynamic titles must live in an App-owned buffer (`app.*_title_buf`).

## License

[MIT](LICENSE) © 2026 Simone Arpe.
