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
