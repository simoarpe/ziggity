<p align="center">
  <img src="docs/assets/ziggity-icon.svg" alt="Ziggity icon" width="128" height="128">
</p>

<h1 align="center">ziggity</h1>

<p align="center">
  A fast terminal UI for Git, written in Zig.
</p>

<p align="center">
  <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16.0-f7a41d">
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey">
</p>

Ziggity puts your whole Git workflow in one terminal window: stage single
lines, commit, branch, rebase interactively, and read history without ever
reaching for the mouse. Every list has a live diff preview, every action is a
keystroke, and nothing ever blocks the interface.

It follows the workflow that [lazygit](https://github.com/jesseduffield/lazygit)
made popular, and it owes that project a lot. It is not a port, though. Ziggity
is written from scratch in Zig, drives plain `git` subprocesses (no libgit2),
and in the places where the two tools differ, the difference is deliberate.
[docs/comparison.md](docs/comparison.md) explains exactly where and why.

<p align="center">
  <img src="docs/screenshots/01-overview.png" alt="Ziggity, the main view" width="900">
</p>

<p align="center"><i>Status, Files, Branches, Commits and Stash panels with a live diff preview and a footer that follows context.</i></p>

**Documentation:** [Features](docs/features.md) ·
[Keybindings](docs/keybindings.md) · [Configuration](docs/configuration.md) ·
[Comparison with lazygit](docs/comparison.md)

## Installation

Ziggity needs the `git` command on your `PATH` at runtime, since it drives
git as a subprocess. Install via Homebrew, grab a prebuilt binary, or build
from source.

### Homebrew (macOS / Linux)

```sh
brew install simoarpe/ziggity/ziggity
```

That taps [`simoarpe/homebrew-ziggity`](https://github.com/simoarpe/homebrew-ziggity)
and installs the binary, the short form of:

```sh
brew tap simoarpe/ziggity
brew install ziggity
```

Upgrade with `brew upgrade ziggity`. Unlike a downloaded binary, a Homebrew
install is not quarantined, so it runs on macOS without a Gatekeeper prompt.

### Manual Installation

Every [release](https://github.com/simoarpe/ziggity/releases) ships static
binaries for macOS, Linux, and Windows. No Zig toolchain required.

#### macOS / Linux

Grab the archive for your platform from the releases page: `aarch64-macos` or
`x86_64-macos` for macOS, `x86_64-linux-musl`, `aarch64-linux-musl` or
`riscv64-linux-musl` for Linux (the musl builds are fully static and run on
any distro), then:

```sh
# set VERSION to the latest release and pick your OS/arch (see the releases page)
VERSION=v0.13.0
curl -LO https://github.com/simoarpe/ziggity/releases/download/$VERSION/ziggity-$VERSION-aarch64-macos.tar.gz
tar -xzf ziggity-$VERSION-aarch64-macos.tar.gz
sudo mv ziggity /usr/local/bin/      # or any directory on your PATH
command -v ziggity                   # confirm it is on your PATH
```

On macOS the binary is not notarized, so Gatekeeper may block it on first
run. Clear the quarantine flag once:

```sh
xattr -d com.apple.quarantine /usr/local/bin/ziggity
```

#### Windows

Download `ziggity-v0.13.0-x86_64-windows-gnu.zip`, unzip it, and put
`ziggity.exe` in a folder on your `PATH`. Requires
[Git for Windows](https://git-scm.com/download/win).

> **Note:** Windows builds are cross compiled and not yet smoke tested on
> Windows. Treat them as experimental for now.

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
`PATH`** so you can run `ziggity` from anywhere. Either copy it into a
directory already on your `PATH`:

```sh
sudo cp zig-out/bin/ziggity /usr/local/bin/
```

or add `zig-out/bin` to your `PATH` (e.g. in `~/.zshrc` or `~/.bashrc`):

```sh
export PATH="$PWD/zig-out/bin:$PATH"
```

## Quick Start

Run `ziggity` inside any Git repository. Press `?` for the keybindings
overlay (it opens scrolled to the panel you are on), and `q` to quit.

## Why Ziggity

If lazygit already works for you, great: it is an excellent tool. Ziggity
exists because a few everyday interactions could be quicker, more efficient,
or more predictable, and because Zig makes it possible to deliver that in a
tiny native binary.

Ziggity compiles to a single static binary with no runtime, no garbage
collector, and no library dependencies beyond the `git` you already have.
Measured on an Apple Silicon laptop against lazygit 0.62.2, same repository,
same terminal:

| | ziggity 0.3.0 | lazygit 0.62.2 |
|---|---|---|
| Binary size | **1.8 MB** | 17.6 MB |
| Process startup, median of 30 runs | **2.9 ms** | 19.2 ms |
| Resident memory after opening a repo | **3 MB** | 18 MB |
| Git subprocesses to load the repo | **26** | 38 |
| Peak git processes running in parallel | **11** | 9 |
| CPU time to open the repo and idle 10 s | **50 ms** | 140 ms |
| Network fetch at startup | none | `git fetch --all` |

Run the same checks yourself; numbers will vary by machine, the gap will not.
[docs/comparison.md](docs/comparison.md) has the methodology behind every row,
the subprocess log, and the honest case point by point, with demos:

| | |
|---|---|
| [Small and Fast](docs/comparison.md#small-and-fast) | [Diffs the Way Review Tools Show Them](docs/comparison.md#diffs-the-way-review-tools-show-them) |
| [Nothing Blocks, Ever](docs/comparison.md#nothing-blocks-ever) | [Word-Level Diff Highlighting](docs/comparison.md#word-level-diff-highlighting) |
| [Copy Text Straight from the Screen](docs/comparison.md#copy-text-straight-from-the-screen) | [Wrap Long Lines On Demand](docs/comparison.md#wrap-long-lines-on-demand) |
| [The Mouse Works Everywhere](docs/comparison.md#the-mouse-works-everywhere) | [History Navigation with Intent](docs/comparison.md#history-navigation-with-intent) |
| [At Home in Any Terminal](docs/comparison.md#at-home-in-any-terminal) | [Two Histories Side by Side](docs/comparison.md#two-histories-side-by-side) |
| [Checkout by Name That Lands on a Real Branch](docs/comparison.md#checkout-by-name-that-lands-on-a-real-branch) | [Jump Between Repositories](docs/comparison.md#jump-between-repositories) |
| [A Commit Editor That Nudges the 50/72 Rule](docs/comparison.md#a-commit-editor-that-nudges-the-5072-rule) | [Stash Without Losing Your Working Tree](docs/comparison.md#stash-without-losing-your-working-tree) |
| [A Force Push That Never Dead Ends](docs/comparison.md#a-force-push-that-never-dead-ends) | [Small Courtesies](docs/comparison.md#small-courtesies) |

## Features

- **The whole workflow**: status, files, branches, commits, and stash panels
  with diff previews and a footer that follows context.
- **Staging down to the line**: `enter` a file to stage single lines or
  hunks, or `d` to discard them, with an optional split view showing unstaged
  and staged side by side.
- **Full interactive rebase**: drop, squash, fixup, edit, reword and move per
  commit, a plan editor (`i`), cherry picking, custom patch building,
  autosquash, and `rebase --onto` from a marked base.
- **History and inspection**: the real `git log --graph` DAG (`ctrl+l`) with
  first parent jumps, ref against ref diffing (`W`) with reverse and merge
  base modes, GPG signature verification (`x`), and log filtering (`/`).
- **Multi selection**: `v` or `shift+arrows` select a range in any list to
  act on many files, commits, branches, or stashes at once; `*` selects a
  branch's own commits.
- **Stays in sync**: a quiet background `git fetch` keeps the incoming
  commit count current on its own; slow and network operations run off the
  interface thread while navigation stays live.
- **Thoughtful touches**: `prepare-commit-msg` prefill, stash naming, a keep
  everything snapshot, per stash patch export, and bracketed paste so a
  pasted multiline message never submits early.
- **Lightweight and explicit**: one small binary, plain `git` subprocesses,
  no libgit2, fully remappable keys, themeable colors, custom commands.

<p align="center">
  <img src="docs/screenshots/02-staging.png" alt="Line level staging view" width="900">
</p>

<p align="center"><i>Stage or unstage single lines or whole hunks with <code>space</code>; <code>d</code> discards them instead.</i></p>

<p align="center">
  <img src="docs/screenshots/08-commit-dialog.png" alt="Commit message dialog" width="900">
</p>

<p align="center"><i><code>c</code> opens the commit dialog: a summary line plus an optional multiline body, and a live character count nudging the 50/72 rule.</i></p>

<p align="center">
  <img src="docs/screenshots/04-commit-graph.png" alt="Commit graph viewer" width="900">
</p>

<p align="center"><i><code>ctrl+l</code> opens the real <code>git log --graph</code> DAG in git's own colors, showing the current branch and its upstream.</i></p>

[docs/features.md](docs/features.md) has the full per panel breakdown and the
rest of the screenshots.

## Keybindings

Press **`?`** in the app for the full, always current overlay. The
essentials:

| Key | Action |
|---|---|
| `1`–`5` | Focus Status / Files / Branches / Commits / Stash (press again to cycle that panel's tabs) |
| `h` `l` / arrows | Move focus between side panels |
| `j` `k` / arrows | Move selection |
| `tab` | Focus the Diff panel (and back) |
| `z` | Maximize the Diff panel to full screen (`z` or `esc` to exit) |
| `[` `]` | Switch the focused panel's tabs (or staging side) |
| `enter` / `esc` | Inspect in the main panel / step back |
| `space` | Stage file · checkout branch · apply stash (by focus) |
| `c` · `a` · `d` · `D` | Commit · stage all · discard menu · discard all |
| `v` · `shift+arrows` · `*` | Start range · extend range · select branch commits |
| `i` · `ctrl+p` · `ctrl+l` | Rebase plan · custom patch · commit graph |
| `f` · `p` · `P` | Fetch · pull · push |
| `z` · `@` · `?` · `q` | Undo · command log · help · quit |

Every key, including the panel key tab cycling, is in
[docs/keybindings.md](docs/keybindings.md).

## Configuration

Ziggity loads its defaults, then reads (each overriding the previous):

1. the path in `ZIGGITY_CONFIG`
2. `<repo>/.ziggity.ini`

There is **no** auto loaded global file (no `~/.config/ziggity/`, no XDG
path). To apply settings everywhere, point `ZIGGITY_CONFIG` at a file from
your shell profile, e.g.
`export ZIGGITY_CONFIG="$HOME/.config/ziggity/config.ini"`, and a repo's
`.ziggity.ini` overrides those per repo. Without any file, settings fall back
to per repo auto detection (notably the editor).

[docs/configuration.md](docs/configuration.md) is the annotated `.ini` with
every setting, key and color, plus the staging layout and editor rules.

## Status & Roadmap

The feature parity roadmap against lazygit is **complete**. Known smaller
gaps:

- **Redo**: undo (`ctrl+z`) is implemented; redoing an undo is not.
- **Move a custom patch to a *different* commit**: only apply and remove
  from commit are implemented.
- **Editing the live rebase todo mid rebase**: ziggity composes the whole
  plan up front in its `i` editor (with range select), so there is no paused
  rebase todo view to edit.
- **Reword in your external `$EDITOR`**: ziggity rewords in its own editor
  (`r`), which serves the same purpose.
- **Full lazygit config compatibility** and **score based fuzzy ranking**
  (the current fuzzy filter matches but preserves order).

See [docs/comparison.md](docs/comparison.md) for where ziggity deliberately
diverges, or
[`docs/ENHANCEMENTS_OVER_LAZYGIT.md`](docs/ENHANCEMENTS_OVER_LAZYGIT.md) for
the same list in short form.

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
| `src/config.zig` | Defaults and the keybinding and INI parser |
| `src/actions.zig` | Action names shared by the app and key layers |

Supporting modules split cohesive areas out of `app.zig`: `staging.zig`,
`patch.zig`, `commitops.zig`, `rebaseplan.zig`, `drills.zig`,
`diffmode.zig`, `stash.zig`, `branches.zig`, `commits.zig`, `filetree.zig`,
`commitgraph.zig`, `editor.zig`, `diff.zig`, `credentials.zig`. All Git data
is loaded through `git` commands rather than reimplementing Git internals.

The gif tapes under `docs/assets/` regenerate with
[vhs](https://github.com/charmbracelet/vhs); run
`bash docs/assets/demo-repos.sh` first to set up the scratch repositories
they record against.

### libvaxis Gotcha: Cells Store Graphemes by Reference

libvaxis stores each screen cell's grapheme as a **slice into the source
text** (`Window.print` does `.grapheme = grapheme.bytes(segment.text)`; it
does not copy the bytes), and the frame is flushed **after** `render()`
returns. So any text drawn via vaxis `printSegment` or `print` must be backed
by memory that outlives `render()`: a string literal or an App owned buffer,
**never a stack local buffer** (which dangles and renders as garbage or
`U+FFFD`, intermittently).

In `src/tui.zig`:

- The local `print`, `printSpan` and `printAnsi` helpers are **safe** with
  any buffer lifetime (they map bytes through a static glyph table), so
  formatting into a stack buffer is fine for list rows, popups, the footer,
  and so on.
- Only vaxis `printSegment` is by reference, and it is used only for panel
  and popup titles; dynamic titles must live in an App owned buffer
  (`app.*_title_buf`).

## Sponsor

Ziggity is free and open source, built in spare time. If it saves you some
of yours, you can support its development on Ko-fi. No pressure, no paywalled
features, just a tip jar that helps keep the work going.

<p align="center">
  <a href="https://ko-fi.com/simoarpe">
    <img src="https://img.shields.io/badge/Support%20on-Ko--fi-ff5e5b?logo=ko-fi&logoColor=white" alt="Support Ziggity on Ko-fi">
  </a>
</p>

<p align="center"><a href="https://ko-fi.com/simoarpe">ko-fi.com/simoarpe</a></p>

You can also help for free: star the repo, report bugs, and tell a friend. 💛

## License

[MIT](LICENSE) © 2026 Simone Arpe.
