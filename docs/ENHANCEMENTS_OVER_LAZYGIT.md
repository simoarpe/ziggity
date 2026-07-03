# Enhancements over lazygit

Ziggity aims to match lazygit's workflow, but in a few places it deliberately
diverges to behave *better* than lazygit. This file records those intentional
enhancements (as opposed to `LAZYGIT_ALIGNMENT.md`, which tracks parity).

> Note: these notes reference lazygit for comparison. That's fine here — the
> "no lazygit in the source" rule applies to `src/` only, not to docs.

## Escalating force-push chain

**What lazygit does:** when a push is rejected for a diverged remote, lazygit's
behavior depends on internal state:

- If the remote-tracking branch is stored locally and the branch is behind, it
  preemptively offers `--force-with-lease`.
- If the push is rejected and the remote-tracking branch *is* stored locally, it
  tells you "updates were rejected" and to pull first — a dead end; it does not
  offer to force from there.
- If the push is rejected and the remote-tracking branch is *not* stored
  locally, it offers a plain `--force`.

So whether you get `--force-with-lease`, a plain `--force`, or just a
"pull first" message depends on whether the remote ref happens to be stored
locally — which isn't obvious to the user.

**What Ziggity does:** a single, predictable, escalating chain. Each rejected
step offers the next, stronger option, and every step is confirmed first:

```
git push
  └─ rejected (diverged remote) ─→ confirm ─→ git push --force-with-lease
                                                  └─ rejected (e.g. stale lease) ─→ confirm ─→ git push --force
                                                                                                  └─ still fails ─→ error (end of chain)
```

- The **safe** force (`--force-with-lease`) is always tried before the blunt one
  (`--force`), so you only overwrite remote work you haven't seen if the safe
  push is itself rejected.
- There is **no dead end**: instead of "you must pull first", you always get an
  explicit, confirmable path forward.
- A failed plain `--force` reports the error and stops — the chain never loops.

Rejections are detected from git's messages (`Updates were rejected`,
`[rejected]`, `non-fast-forward`, `fetch first`); unrelated failures
(authentication, network) skip the force offer and surface as normal errors.

Both confirmation steps can be turned into auto-accept via config (off by
default, so you always confirm):

```ini
skip_confirm.force_push = false        # auto --force-with-lease when a push is rejected
skip_confirm.force_push_plain = false  # auto --force when force-with-lease is rejected
```

Implemented in `src/app.zig` (`AsyncOp.push_force` / `push_force_plain`,
`pushNeedsForce`, `completeAsync`) and `src/git.zig`.

## Mouse text selection in the Diff panel

**What lazygit does:** it has no in-app text selection in the diff view. To copy
diff text you fall back to the terminal's own selection (often Shift-drag), which
is terminal-dependent, spans the whole screen rather than just the diff, and
doesn't auto-copy.

**What Ziggity does:** character-precise text selection built into the Diff panel
itself. Click-drag over the diff to select an exact span; the selection is
highlighted as you drag, and on release the text is copied straight to the system
clipboard (OSC 52) — no extra keypress.

- Works for **whatever the diff panel is showing** — a file diff, the branch
  commit graph, a commit, or a stash — regardless of which left panel is
  selected.
- The copied text is **clean**: git's ANSI color codes are stripped, and tabs are
  preserved so copied code keeps its indentation. Multi-line selections join with
  newlines.
- Dragging **does not steal focus** from the left panel (a plain click still
  focuses the diff, as before), so your navigation context is kept.
- The selection clears automatically when the diff content changes, and the
  feature is disabled in the hunk/line staging view (which has its own keyboard
  selection).

Caveat: copying relies on the terminal honoring OSC 52 (the same mechanism as
Ziggity's other copy actions).

Implemented in `src/app.zig` (`handleMouse` press/drag/release, `diffPointAt`,
`diffSelectionRange`, `copyDiffSelection`, `appendDiffColumns`) and `src/tui.zig`
(`printAnsi` selection highlight in `drawDiff`).

## In-app credential entry for push / pull / fetch

**What lazygit does:** when a network op needs HTTPS credentials, lazygit runs
git inside a pseudo-terminal (PTY), watches the byte stream for git's prompts
(`Username for '…':`, `Password for '…':`, passphrase/PIN/token), and pops a
modal prompt (masked for secrets) whose answer it writes back into the PTY.

**What Ziggity does:** the same user experience — a username prompt then a
masked password/token prompt, in-app, with no external credential helper
required — implemented without a PTY. When a network op fails with an
authentication error, Ziggity opens a two-step credential popup; the entered
values are handed to git through a `GIT_ASKPASS` (and `SSH_ASKPASS`) re-exec of
the Ziggity binary, which echoes the requested secret. Why this design:

- **No terminal corruption.** A PTY-and-fork approach is fragile alongside the
  async I/O runtime and the alt-screen TUI; the askpass re-exec keeps git off the
  controlling terminal entirely (`GIT_TERMINAL_PROMPT=0` stays set as a backstop).
- **No environment races.** The secrets ride on a *clone* of the process
  environment built per credentialed op; the shared environment that the
  background status/preview threads read is never mutated.
- **Plays well with keychains.** Because the values flow through git's normal
  credential machinery, a configured helper (e.g. macOS `osxkeychain`) will
  `store` them on success, so subsequent pushes are silent.
- **Secrets are wiped** from the input buffers once stored and zeroed on exit;
  wrong credentials are discarded and re-prompted rather than retried in a loop.

Press `esc` at either step to cancel (git then fails cleanly). Entered
credentials are reused for the rest of the session across push/pull/fetch.

Implemented in `src/app.zig` (`runAskpassHelper`, `startCredentialPrompt`,
`advanceCredentialPrompt`, `buildCredentialEnv`, `isAuthFailure`,
`clearGitCredentials`, `completeAsync`), `src/main.zig` (askpass short-circuit),
and `src/tui.zig` (`drawCredentialPopup`, credential-bearing `asyncWorker`).

## Mouse text selection in dialogs

**What lazygit does:** its popups (command output, menus, keybinding cheatsheet)
aren't text-selectable from within the app; copying their text falls back to the
terminal's own selection.

**What Ziggity does:** the same character-precise click-drag selection as the
Diff panel, extended to the read-only dialogs — the operation-result popup (git
command output), the help/keybindings popup, and the command-log overlay.
Drag to select; the span is highlighted as you drag, and on release it is copied
to the system clipboard (OSC 52). Selection coordinates index the dialog's
*rendered* rows, so it composes with wrapping; scrolling or closing the dialog
clears it. The mouse wheel also scrolls the operation-result and help popups.

Implemented in `src/app.zig` (`handleMouse` dialog branch, `beginDialogGrid`,
`setDialogRow`, `dialogPointAt`, `dialogRowSelection`, `copyDialogSelection`,
`dialogScroll`) and `src/tui.zig` (`drawDialogRow` in the dialog renderers).

## Three-dot (merge-base) diff in diffing mode

_Addresses lazygit issue [#3767](https://github.com/jesseduffield/lazygit/issues/3767)._

**What lazygit does:** diffing mode marks a ref and diffs the selection against it
with **two-dot** semantics — `git diff A B`, the full difference between the two
snapshots. It offers a *reverse* toggle but no merge-base option. The "diff my
branch against `master` showing only my own changes" request (#3767) is still
open; lazygit's diffing mode carries only `Ref` and `Reverse`.

**What Ziggity does:** the diffing menu (`W`) adds a **"Toggle merge-base diff
(three-dot)"** item. When on, the diff becomes `git diff base...target` — the diff
*from the merge-base* of the two refs, i.e. only the target's own changes since it
diverged. This is the GitHub pull-request view.

- After you merge `master` into your branch, a two-dot `master feature` diff shows
  `master`'s own commits as spurious deletions ("a lot of changes"); the three-dot
  `master...feature` shows **just your branch's work**.
- It's an independent toggle that composes with reverse — you can have neither,
  either, or both.
- The Diff panel title reflects the mode: `[base X]` for two-dot, `[base X ...]`
  for three-dot, so the current semantics are always visible.

Implemented in `src/app.zig` (`diff_three_dot`, `diff_toggle_three_dot`, the
`diff_refs` argv branch, preview cache key), `src/diffmode.zig`
(`clearDiffBase`), and `src/tui.zig` (Diff panel title).

## First-parent navigation in the commit graph

_Addresses lazygit issue [#3974](https://github.com/jesseduffield/lazygit/issues/3974)._

**What lazygit does:** the commit-graph / log view navigates line-by-line
(`j`/`k`, page keys). There is no "jump to this commit's parent"; the parent/child
navigation request (#3974) is open and unimplemented.

**What Ziggity does:** in the `ctrl+l` commit-graph viewer, **`p`** jumps the
cursor to the current commit's **first parent** (the mainline parent for a merge
commit) and re-centers on it.

- The parent lookup uses a scope-matched `git log --format='%h %p'` map that is
  loaded **off the UI thread**, alongside the graph itself — so pressing `p` is a
  pure in-memory lookup and never spawns git on the UI thread.
- Honest edges: a root commit reports "no parent"; a first parent that lies
  outside the loaded window (older than the graph's commit cap, or off-scope) says
  so instead of silently doing nothing.
- The binding is configurable (`graph_first_parent`, default `p`). Go-to-child —
  which is ambiguous (a commit can have many children) — is intentionally left for
  later; the same `%h %p` map already contains what it would need.

Implemented in `src/commitgraph.zig` (`goToFirstParent`, `firstParentOf`,
`rowForHash`, `hashMatch`, the `commit_graph_parents` map), `src/tui.zig`
(second `%h %p` pass in `graphWorker`), and `src/config.zig`
(`graph_first_parent`).

## prepare-commit-msg hook seeding

_Addresses lazygit issue [#4995](https://github.com/jesseduffield/lazygit/issues/4995)._

**What lazygit does:** it commits from the message popup with `git commit -m`, so
the repo's `prepare-commit-msg` hook runs with source `message`. The common
branch-ticket-prefix hooks guard on an *empty* source (they only act for an
interactive editor), so through the popup they effectively do nothing — you never
see the templated message. Issue #4995 requests running the hook; lazygit has an
in-flight PR (#5099), but stock lazygit does not seed the field.

**What Ziggity does:** when the commit dialog opens (and there is no restored
draft), Ziggity runs the repo's `prepare-commit-msg` hook the way an *interactive*
commit would — with **no source argument**, so hooks guarded on an empty `$2`
fire — strips git comment lines, and pre-fills the subject/body. The templated
message (e.g. a `PROJ-123:` prefix derived from the branch) appears in the fields,
editable, before you commit.

- The no-hook case costs a single `access` syscall — no subprocess — so opening
  the commit dialog stays instant on repos without the hook.
- Off by a config switch when unwanted: `prepare_commit_msg_hook` (default on).
- Honest caveat: the final `git commit -m` re-runs the hook with source
  `message`. Source-guarded hooks (the common case) skip that second run cleanly;
  a hook that prepends *unconditionally* would apply twice.

Implemented in `src/git.zig` (`prepareCommitMsg`, `stripCommentLines`),
`src/commits.zig` (seeding in `startCommitPrompt`), and `src/config.zig`
(`prepare_commit_msg_hook`).

## Independent Branches and Commits drill-downs

**What lazygit does:** the Commits panel is a single shared view tied to the
checked-out branch. Inspecting another branch's commits reuses that one panel, so
you can't hold a branch's history and the main log's history side by side.

**What Ziggity does:** the Branches panel can **drill into a branch's commits (and
those commits' files) independently** of the Commits panel — both panels keep
their own selection and their own file list at the same time. Drilling into a
branch to inspect a commit never disturbs where you were in the main log.

- Diffing mode understands the drill: while you're inside a branch's commit list,
  the ref it diffs is the selected **sub-commit**, not the (frozen) branch — so
  marking a base or picking a target from the drill behaves as expected.

Implemented in `src/app.zig` (`branch_commits_active`, `branch_commits`,
`branch_commit_index`, `inBranchCommitContext`, `selectedCommit`) and
`src/diffmode.zig` (`selectedRefForDiff` drill handling).

## Skip the remote prompt when there is only one

**What lazygit does:** tag push routes through a remote selection step even in the
common single-remote repo.

**What Ziggity does:** when the repo has exactly one remote, tag push (`P`) goes
**straight to that remote** with no prompt; the prompt only appears when there is a
genuine choice to make (and is then prefilled with the suggested remote). One less
keystroke for the overwhelmingly common case, with no loss of control when it
actually matters.

Implemented in `src/app.zig` (`pushSelectedTag`, `suggestedRemote`).
