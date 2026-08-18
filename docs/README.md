<p align="center">
  <img src="assets/ziggity-icon.svg" alt="Ziggity icon" width="96" height="96">
</p>

<h1 align="center">Ziggity Documentation</h1>

<p align="center">
  A fast terminal UI for Git, written in Zig.
</p>

<p align="center">
  <a href="https://ziggity.dev">ziggity.dev</a> ·
  <a href="../README.md">Project README</a> ·
  <a href="https://github.com/simoarpe/ziggity/releases">Releases</a>
</p>

---

Welcome. This folder holds everything you need to learn, configure, and get the
most out of Ziggity. New here? The [project README](../README.md) covers
installation and a quick tour. The pages below go deeper.

## Guides

| Page | What it covers |
| --- | --- |
| [Features](features.md) | A tour of the whole workflow: staging by line and hunk, the inline commit graph, interactive rebase, worktrees, stashes, bisect, and the live diff preview. |
| [Keybindings](keybindings.md) | The complete key reference for every panel and mode. |
| [Configuration](configuration.md) | Every setting, key remap, and color. The `.ziggity.ini` format, custom commands, and editor setup. |

## How it compares

Ziggity is inspired by [lazygit](https://github.com/jesseduffield/lazygit) but
written from scratch in Zig, and it makes different choices where they improve
the experience.

| Page | What it covers |
| --- | --- |
| [Why Ziggity](comparison.md) | A detailed comparison with lazygit: what is the same, what is different, and the reasoning behind each choice. |
| [Enhancements over lazygit](ENHANCEMENTS_OVER_LAZYGIT.md) | The specific places Ziggity goes a step further. |

## A look at it

<p align="center">
  <img src="screenshots/01-overview.png" alt="Ziggity main view" width="820">
</p>

<p align="center"><i>Status, Files, Branches, Commits, and Stash panels with a live diff preview.</i></p>

<p align="center">
  <img src="screenshots/04-commit-graph.png" alt="Ziggity commit graph" width="820">
</p>

<p align="center"><i>The commit graph, drawn inline in the Commits panel.</i></p>

There are more in the [screenshots](screenshots/) folder.

## Benchmarks

The "small and fast" numbers in the README come out of one command, so you can
reproduce them yourself rather than take them on trust. See
[bench/](bench/) for the script and the raw results.

## Project internals

Notes kept for contributors and for tracking direction:
[Implementation plan](IMPLEMENTATION_PLAN.md) and
[lazygit alignment plan](LAZYGIT_ALIGNMENT.md).

---

<p align="center">
  Questions or ideas? Open an
  <a href="https://github.com/simoarpe/ziggity/issues">issue</a>.
</p>
