# Enhancements over lazygit

Ziggity follows lazygit's workflow, and in a number of places it deliberately
diverges to behave better. The full write up, with measurements and animated
demos, now lives in the README under
[Why Ziggity](../README.md#why-ziggity). This page stays as the short form
index of those intentional differences.

> Note: these notes reference lazygit for comparison. That is fine here; the
> "no lazygit in the source" rule applies to `src/` only, not to docs.

## The list, in short

- **Small and fast.** A 1.8 MB static binary against 17.6 MB, about 3 ms of
  process startup against about 19 ms, roughly 3 MB resident against 18 MB,
  26 git subprocesses to load a repo against 38, and about a third of the
  CPU over the same window, measured on the same machine and repository.
  Eleven panel loaders fan out in parallel, the log loads incrementally,
  previews are cached, and startup never touches the network.
  [Details](../README.md#small-and-fast)

- **Nothing blocks, ever.** Fetch, pull, push and slow multistep actions run
  off the interface thread with a spinner while navigation stays live.
  Success is silent, only failures open a dialog, and you are never dropped
  back to the raw terminal with a "press enter to return" screen.
  [Details](../README.md#nothing-blocks-ever)

- **Credential entry in the app.** On an HTTPS auth failure Ziggity prompts
  for username and token in a popup and feeds git through an askpass reexec
  of its own binary. No PTY tricks, no terminal corruption, no environment
  races; keychain helpers still cache the result, entered credentials are
  authoritative over stale cached ones, secrets are wiped after use, and a
  host that wants a token instead of a password gets said out loud.
  [Details](../README.md#nothing-blocks-ever)

- **Mouse text selection with automatic copy.** Character precise click and
  drag selection in the Diff panel and in the read only dialogs (command
  output, help overlay, command log). On release the text is on the
  clipboard via OSC 52, color codes stripped, indentation preserved.
  lazygit has no in-app selection; you fall back to the terminal's own,
  which grabs panel borders too.
  [Details](../README.md#copy-text-straight-from-the-screen)

- **The mouse works everywhere.** Click to focus a panel, click to select a
  row, click a line in the staging view to land the cursor on it, click a
  completion in the checkout prompt, wheel scroll every list, dialog and the
  graph.
  [Details](../README.md#the-mouse-works-everywhere)

- **At home in any terminal.** Standard ANSI plus a curated 256 color set,
  emphasis through dim and bold, OSC 52 copy that survives SSH, focus
  events, bracketed paste, and the kitty keyboard protocol where available.
  [Details](../README.md#at-home-in-any-terminal)

- **Checkout by name that lands on a real branch.** In the `c` prompt a
  remote branch name checks out with `--track`: a local tracking branch, in
  one step, never a detached HEAD and no extra menu. An existing local name
  switches, a tag or commit detaches because that is the only correct
  meaning.
  [Details](../README.md#checkout-by-name-that-lands-on-a-real-branch)

- **A commit editor that nudges the 50/72 rule.** A live subject counter
  that turns red past 50 and a soft guide column at 72 in the body, both
  configurable.
  [Details](../README.md#a-commit-editor-that-nudges-the-5072-rule)

- **prepare-commit-msg hook seeding.** The dialog runs the hook the way an
  interactive commit would (empty source argument), so branch ticket prefix
  hooks finally fire from a TUI. Addresses lazygit issue
  [#4995](https://github.com/jesseduffield/lazygit/issues/4995).
  [Details](../README.md#a-commit-editor-that-nudges-the-5072-rule)

- **An escalating force push chain with no dead ends.** Rejected push, then
  confirmed `--force-with-lease`, then confirmed `--force`, then stop. The
  safe force always comes first and the path never depends on whether the
  remote tracking ref happens to be stored locally.
  [Details](../README.md#a-force-push-that-never-dead-ends)

- **A diffing mode you can read off the screen.** One `W` marks the selected
  ref as the base (no menu detour), a note explains the mode, the marked row
  keeps a colored diamond, and the Diff title tracks every selection in
  git's own notation with the real ref names (`main...feature/login`): order
  is direction, dot count is mode. lazygit's diffing opens a menu first and
  shows no marker and no comparison state.
  [Details](../README.md#diffs-the-way-review-tools-show-them)

- **Merge base (three dot) diffing, on by default for branches.** Diffing
  mode can show `git diff base...target`, only the target's own changes
  since divergence, the pull request view; it is the default whenever the
  marked base is a branch, while commits and tags default to the plain two
  dot comparison. Composes with the invert toggle. Addresses lazygit issue
  [#3767](https://github.com/jesseduffield/lazygit/issues/3767), still open
  there.
  [Details](../README.md#diffs-the-way-review-tools-show-them)

- **First parent navigation in the commit graph.** `p` jumps to the current
  commit's first parent via a preloaded parent map, so walking the mainline
  of a merge heavy history is instant. Addresses lazygit issue
  [#3974](https://github.com/jesseduffield/lazygit/issues/3974).
  [Details](../README.md#history-navigation-with-intent)

- **A Divergence tab and push state everywhere.** The current branch versus
  its upstream, outgoing above incoming, with history editing keys disabled
  there; commit hashes are tinted red until they reach the remote. The
  commit graph shows the upstream by default so incoming commits are visible
  without asking.
  [Details](../README.md#history-navigation-with-intent)

- **Independent Branches and Commits drill downs.** Both panels keep their
  own selection and file lists at the same time, so inspecting another
  branch never loses your place in the main log, and diffing mode targets
  the drilled commit you are actually on.
  [Details](../README.md#two-histories-side-by-side)

- **Stash without losing your working tree.** Snapshot everything into a
  stash, untracked files included, while the tree stays untouched. Git's own
  `stash create` silently ignores untracked files; ziggity stashes with
  `--include-untracked` and reapplies with `--index`, so the entry is
  complete and the staged and unstaged split survives byte for byte.
  [Details](../README.md#stash-without-losing-your-working-tree)

- **Small courtesies.** One remote skips the remote prompt on tag push. Any
  stash exports to a `git apply` ready patch. A commit with thousands of
  binary files previews instantly instead of freezing the panel. `ctrl+z`
  undoes the last operation through the reflog.
  [Details](../README.md#small-courtesies)
