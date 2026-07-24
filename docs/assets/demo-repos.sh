#!/usr/bin/env bash
# Scratch repositories for the README gif tapes (commit-guide.tape and
# checkout-track.tape). Run this once, then run the tapes from the repo root:
#
#   bash docs/assets/demo-repos.sh
#   vhs docs/assets/commit-guide.tape
#   vhs docs/assets/checkout-track.tape
#
# Everything lands under /tmp and can be deleted afterwards.
set -euo pipefail

# --- /tmp/zdemo-commit: a small project with a staged change to commit -------
rm -rf /tmp/zdemo-commit
mkdir -p /tmp/zdemo-commit/src
cd /tmp/zdemo-commit
git init -q -b main
git config user.email demo@ziggity.dev
git config user.name "Demo"
printf 'const std = @import("std");\n\npub fn main() !void {\n    try run();\n}\n' > src/main.zig
printf 'pub fn tokenize(src: []const u8) Lexer {\n    return .{ .src = src, .pos = 0 };\n}\n' > src/lexer.zig
printf '# aurora\nA tiny expression evaluator.\n' > README.md
git add .
git commit -q -m "Initial project skeleton"
printf 'pub fn parse(tokens: []Token) !Ast {\n    // TODO\n}\n' > src/parser.zig
git add .
git commit -q -m "Add parser stub"
printf 'pub fn tokenize(src: []const u8) Lexer {\n    return .{ .src = src, .pos = 0, .line = 1 };\n}\n\npub fn next(l: *Lexer) ?Token {\n    return l.scan();\n}\n' > src/lexer.zig
git add src/lexer.zig

# --- /tmp/zdemo-co: an origin with a feature branch not present locally ------
rm -rf /tmp/zdemo-co
mkdir -p /tmp/zdemo-co/origin.git
cd /tmp/zdemo-co/origin.git
git init -q --bare -b main
cd /tmp/zdemo-co
git clone -q origin.git clone
cd clone
git config user.email demo@ziggity.dev
git config user.name "Demo"
printf '# demo\n' > README.md
git add .
git commit -q -m "Initial commit"
git push -q origin main
git checkout -q -b feature/login-form
printf 'form\n' > form.txt
git add .
git commit -q -m "Start the login form"
git push -q origin feature/login-form
git checkout -q main
git branch -q -D feature/login-form
git fetch -q --prune

# --- /tmp/zdemo-fetch: a throwaway clone with a real network remote ---------
# Used by async-fetch.tape so the recorded fetch has visible latency. Never
# record action tapes against a real working repository.
rm -rf /tmp/zdemo-fetch
git clone -q https://github.com/simoarpe/ziggity /tmp/zdemo-fetch

# --- /tmp/zhero/ziggity: a pristine clone for the donut hero gif ------------
# A clean tree named "ziggity" makes a tidier hero shot than the working repo.
rm -rf /tmp/zhero
mkdir -p /tmp/zhero
git clone -q /tmp/zdemo-fetch /tmp/zhero/ziggity

# --- /tmp/zdemo-auth: a remote that always answers 401 ----------------------
# Used by credentials.tape: fetching from it deterministically opens the in
# app credential prompt. Start the server before recording and kill it after:
#   python3 /tmp/auth401.py &
cat > /tmp/auth401.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _r(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="demo"')
        self.end_headers()
    do_GET = do_POST = _r
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 8401), H).serve_forever()
PYEOF
rm -rf /tmp/zdemo-auth
mkdir /tmp/zdemo-auth
cd /tmp/zdemo-auth
git init -q -b main
git config user.email demo@ziggity.dev
git config user.name "Demo"
printf '# app\n' > README.md
git add .
git commit -q -m "Initial commit"
git remote add origin http://127.0.0.1:8401/team/app.git

# --- /tmp/zdemo-graph: a history with real merge lanes ----------------------
# Used by graph-complex.tape for the commit graph screenshot.
if [ ! -d /tmp/zdemo-graph/.git ]; then
  git clone -q --depth 400 https://github.com/git/git /tmp/zdemo-graph
fi

# --- /tmp/zdemo-push: a diverged clone pair for force-push.tape -------------
# "ours" and the origin moved apart, so a push from "ours" is rejected and
# ziggity offers the lease force confirmation.
rm -rf /tmp/zdemo-push
mkdir -p /tmp/zdemo-push/origin.git
cd /tmp/zdemo-push/origin.git
git init -q --bare -b main
cd /tmp/zdemo-push
git clone -q origin.git ours
cd ours
git config user.email simon.arpe@gmail.com
git config user.name "Simone Arpe"
printf '# service\n' > README.md
git add .
git commit -q -m "Initial commit"
printf 'retry with backoff\n' > worker.txt
git add .
git commit -q -m "Add retry with backoff"
git push -qu origin main
cd /tmp/zdemo-push
git clone -q origin.git theirs
cd theirs
git config user.email colleague@example.com
git config user.name "Colleague"
printf 'metrics\n' > metrics.txt
git add .
git commit -q -m "Emit queue metrics"
git push -q origin main
cd /tmp/zdemo-push/ours
printf 'jitter\n' >> worker.txt
git add .
git commit -q -m "Add jitter to the retry delay"
git fetch -q

# --- /tmp/zshot/ziggity: the curated state for screenshots.tape -------------
# A ziggity clone with a staged file, an unstaged file, an untracked file,
# two named stashes and a local branch, so every panel has something real to
# show. Rebuild this before each screenshots.tape run: the tape types a
# commit message whose draft persists in the repo.
rm -rf /tmp/zshot
mkdir /tmp/zshot
git clone -q /tmp/zdemo-fetch /tmp/zshot/ziggity
cd /tmp/zshot/ziggity
git config user.email simon.arpe@gmail.com
git config user.name "Simone Arpe"
printf '\n// scratch: experiment with a wider gutter\n' >> src/tui.zig
git stash push -q -m "experiment: wider diff gutter"
printf '\n// scratch: try a different palette\n' >> src/config.zig
git stash push -q -m "try an alternate palette"
git branch feature/preview-cache HEAD~3
printf '\n// TODO: cache rendered previews across refreshes\n' >> src/app.zig
git add src/app.zig
printf '\n// TODO: measure cell width once per frame\n' >> src/tui.zig
printf '# Release notes draft\n\n- faster previews\n- calmer refreshes\n' > docs/notes.md

# --- /tmp/zrecent: the recent-repositories switcher demo (recent-repos.tape) -
# A handful of realistically named repos on different branches, plus a seeded
# recent list, so ctrl+r shows a full, tidy switcher. Everything (repos and the
# recent list) lives under a private XDG state dir, so the shot never depends on
# or touches your real recent list. recent-repos.tape points XDG_STATE_HOME here
# and opens the "aurora" repo, which ziggity prepends on launch (and the
# switcher then hides as the current repo), leaving the five seeded rows.
rm -rf /tmp/zrecent
mkdir -p /tmp/zrecent/state/ziggity
zrecent_repo() { # <path> <branch>
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  git -C "$1" config user.email demo@ziggity.dev
  git -C "$1" config user.name "Demo"
  printf '# %s\n' "$(basename "$1")" > "$1/README.md"
  git -C "$1" add .
  git -C "$1" commit -q -m "Initial commit"
}
zrecent_repo /tmp/zrecent/projects/aurora main
zrecent_repo /tmp/zrecent/work/api-gateway release/2.1
zrecent_repo /tmp/zrecent/projects/lexer main
zrecent_repo /tmp/zrecent/work/billing-service feature/invoices
zrecent_repo /tmp/zrecent/projects/dotfiles main
zrecent_repo /tmp/zrecent/sandbox/raytracer-zig experiment/bvh
cat > /tmp/zrecent/state/ziggity/recent <<'REOF'
/tmp/zrecent/work/api-gateway
/tmp/zrecent/projects/lexer
/tmp/zrecent/work/billing-service
/tmp/zrecent/projects/dotfiles
/tmp/zrecent/sandbox/raytracer-zig
REOF

# --- /tmp/zword: the word-level diff demo (word-diff.tape) ------------------
# A small file with a few intra-line edits (a number, an enum tag, one word in
# a string) so the diff shows changed *words* highlighted within otherwise
# unchanged lines, not whole-line repaints.
rm -rf /tmp/zword
mkdir /tmp/zword
cd /tmp/zword
git init -q -b main
git config user.email demo@ziggity.dev
git config user.name "Demo"
cat > config.zig <<'ZEOF'
const timeout_seconds = 30;
const max_retries = 3;
pub fn connect(host: []const u8) !Conn {
    return dial(host, timeout_seconds, .tcp);
}
pub fn shutdown() void {
    log.info("closing all connections gracefully", .{});
}
ZEOF
git add .
git commit -q -m "Add connection config"
cat > config.zig <<'ZEOF'
const timeout_seconds = 45;
const max_retries = 3;
pub fn connect(host: []const u8) !Conn {
    return dial(host, timeout_seconds, .quic);
}
pub fn shutdown() void {
    log.info("closing all sockets gracefully", .{});
}
ZEOF

# --- /tmp/zwrap: the line-wrapping demo (wrap.tape) -------------------------
# A markdown file with long prose paragraphs and a one-word edit deep inside
# one of them, so the diff has long -/+ lines that run off the right edge when
# truncating and reflow into the view when wrapping (ctrl+w).
rm -rf /tmp/zwrap
mkdir /tmp/zwrap
cd /tmp/zwrap
git init -q -b main
git config user.email demo@ziggity.dev
git config user.name "Demo"
cat > notes.md <<'ZEOF'
# Release notes

Ziggity is a fast terminal user interface for Git written in Zig that follows the workflow lazygit made popular while fixing a number of everyday interactions so they are quicker, more efficient, and more predictable, all delivered in one tiny native binary with no runtime and no libgit2.

Long paragraphs of prose like this one, common in markdown and documentation diffs, run off the right edge when lines are truncated, so the part that actually changed can sit off screen and stay invisible until you scroll sideways to hunt for it.
ZEOF
git add .
git commit -q -m "Add release notes"
sed -i.bak 's/while fixing a number/while improving a number/' notes.md && rm -f notes.md.bak

echo "demo repos ready: /tmp/zdemo-commit, /tmp/zdemo-co/clone, /tmp/zdemo-fetch, /tmp/zhero/ziggity, /tmp/zdemo-auth, /tmp/zdemo-graph, /tmp/zrecent, /tmp/zword, /tmp/zwrap"
echo "for credentials.tape, also start:  python3 /tmp/auth401.py &"
