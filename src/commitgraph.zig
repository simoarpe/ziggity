//! The commit-graph viewer (`ctrl+l` on the Commits panel): a large overlay that
//! renders `git log --graph` (the real ASCII DAG, in git's own colours), scoped
//! to the current branch or all branches. The graph loads off the UI thread with
//! a cancellable spinner; the commit selected in the Commits panel is highlighted
//! on open, and `enter` jumps the panel selection to the row under the cursor.
//! Free functions over `*App`; the graph and its state live on App.
const std = @import("std");

const app_mod = @import("app.zig");
const model = @import("model.zig");

const App = app_mod.App;

/// What the TUI loop needs to load a graph off-thread.
pub const LoadReq = struct { all: bool, generation: u64 };

/// `ctrl+l`: open the viewer, scoped to the current branch, and request a load.
pub fn open(app: *App) !void {
    if (app.commits_tab != .commits) {
        try app.setMessage("the commit graph is on the Commits tab", .{});
        return;
    }
    // Remember which commit to highlight once the graph arrives.
    app.allocator.free(app.commit_graph_target);
    app.commit_graph_target = if (app.selectedCommit()) |c|
        try app.allocator.dupe(u8, c.short_hash)
    else
        try app.allocator.dupe(u8, "");

    app.commit_graph_all = false;
    app.mode = .commit_graph;
    app.commit_graph_sel = 0;
    app.commit_graph_scroll = 0;
    requestLoad(app);
    try app.setMessage("loading commit graph...", .{});
}

/// Toggle between the current branch and all branches, reloading. The commit
/// currently under the cursor stays selected across the reload.
pub fn toggleScope(app: *App) void {
    captureCursorTarget(app);
    app.commit_graph_all = !app.commit_graph_all;
    requestLoad(app);
}

/// Remember the commit on the cursor row so the next load re-highlights it.
fn captureCursorTarget(app: *App) void {
    const graph = app.commit_graph orelse return;
    const line = nthLine(graph, app.commit_graph_sel) orelse return;
    var buf: [64]u8 = undefined;
    if (firstHash(line, &buf)) |h| {
        if (app.allocator.dupe(u8, h)) |dup| {
            app.allocator.free(app.commit_graph_target);
            app.commit_graph_target = dup;
        } else |_| {}
    }
}

fn requestLoad(app: *App) void {
    freeGraph(app);
    app.commit_graph_loading = true;
    app.commit_graph_generation +%= 1;
    app.commit_graph_wanted = true;
    app.spinner_frame = 0;
}

/// TUI loop hook: claim a pending graph load, if any.
pub fn takeLoad(app: *App) ?LoadReq {
    if (!app.commit_graph_wanted) return null;
    app.commit_graph_wanted = false;
    return .{ .all = app.commit_graph_all, .generation = app.commit_graph_generation };
}

/// TUI loop hook: a graph load finished. `text` is owned by `gpa`. Stale results
/// (a newer load was requested, or the viewer was closed) are discarded.
pub fn complete(app: *App, text: ?[]u8, parents: ?[]u8, generation: u64, gpa: std.mem.Allocator) void {
    if (generation != app.commit_graph_generation or app.mode != .commit_graph) {
        if (text) |t| gpa.free(t);
        if (parents) |p| gpa.free(p);
        return;
    }
    app.commit_graph_loading = false;
    if (text) |t| {
        defer gpa.free(t);
        defer if (parents) |p| gpa.free(p);
        freeGraph(app); // clears the old graph and its parent map
        app.commit_graph = app.allocator.dupe(u8, t) catch null;
        app.commit_graph_plain = stripAnsi(app.allocator, t) catch null;
        if (parents) |p| app.commit_graph_parents = app.allocator.dupe(u8, p) catch &.{};
        app.commit_graph_lines = countLines(app.commit_graph orelse "");
        app.commit_graph_max_width = widestLine(app.commit_graph_plain orelse "");
        app.commit_graph_hscroll = 0;
        // Highlight the row for the commit that was selected (on open, or kept
        // across a scope toggle), and ask the renderer to center it once.
        app.commit_graph_sel = findTargetRow(app);
        app.commit_graph_scroll = 0;
        app.commit_graph_recenter = true;
    } else if (parents) |p| {
        gpa.free(p); // no graph stored, so drop the parent map too
    }
}

pub fn handleKey(app: *App, key: anytype) !void {
    if (app.isDialogCloseKey(key)) return close(app);

    const km = app.config.keymap;
    const lines = app.commit_graph_lines;
    if (km.up.matches(key) or key.matches(up_key, .{})) {
        app.commit_graph_sel -|= 1;
        return ensureCursorVisible(app);
    }
    if (km.down.matches(key) or key.matches(down_key, .{})) {
        if (lines > 0 and app.commit_graph_sel + 1 < lines) app.commit_graph_sel += 1;
        return ensureCursorVisible(app);
    }
    if (key.matches(pgup_key, .{})) {
        app.commit_graph_sel -|= 10;
        return ensureCursorVisible(app);
    }
    if (key.matches(pgdn_key, .{})) {
        if (lines > 0) app.commit_graph_sel = @min(app.commit_graph_sel + 10, lines - 1);
        return ensureCursorVisible(app);
    }
    // H / L pan the graph horizontally when it's wider than the dialog (the
    // renderer clamps the pan to the content width).
    if (km.scroll_left.matches(key)) {
        app.commit_graph_hscroll -|= app_mod.horizontal_scroll_step;
        return;
    }
    if (km.scroll_right.matches(key)) {
        app.commit_graph_hscroll +|= app_mod.horizontal_scroll_step;
        return;
    }
    // `a` toggles the all-branches / current-branch scope.
    if (km.stage_all.matches(key)) return toggleScope(app);
    // ctrl+o copies the cursor row's commit hash to the clipboard.
    if (km.copy_clipboard.matches(key)) return copyCursorHash(app);
    // `p` jumps the cursor to the current commit's first parent.
    if (km.graph_first_parent.matches(key)) return goToFirstParent(app);
    // enter jumps the Commits-panel selection to the row under the cursor.
    if (app.isEnterKey(key)) return jumpToSelected(app);
}

/// ctrl+o: copy the full hash of the commit on the cursor row.
fn copyCursorHash(app: *App) !void {
    const short = cursorHash(app) orelse {
        try app.setMessage("no commit on that row", .{});
        return;
    };
    // Resolve the abbreviated hash to the full one from the loaded log.
    const full = for (app.data.commits) |c| {
        if (std.mem.startsWith(u8, c.short_hash, short) or std.mem.startsWith(u8, c.hash, short)) break c.hash;
    } else short;
    if (app.clipboard_request) |old| app.allocator.free(old);
    app.clipboard_request = try app.allocator.dupe(u8, full);
    try app.setMessage("copied to clipboard: {s}", .{full});
}

/// The abbreviated hash on the cursor row (into a static-lifetime view of the
/// owned graph), or null on a connector row. The returned slice points into a
/// caller-independent scratch; callers must use it before re-entrancy.
fn cursorHash(app: *App) ?[]const u8 {
    const graph = app.commit_graph orelse return null;
    const line = nthLine(graph, app.commit_graph_sel) orelse return null;
    return firstHash(line, &app.commit_graph_hash_buf);
}

/// Mouse: move the cursor to an absolute line index (clamped).
pub fn selectRow(app: *App, line_index: usize) void {
    if (app.commit_graph_lines == 0) return;
    app.commit_graph_sel = @min(line_index, app.commit_graph_lines - 1);
}

/// After keyboard navigation, scroll the view just enough to keep the cursor
/// visible. The mouse wheel does NOT call this — wheel scrolls the view freely
/// and the cursor stays put.
fn ensureCursorVisible(app: *App) void {
    const h = app.commit_graph_view_h;
    if (h == 0) return;
    if (app.commit_graph_sel < app.commit_graph_scroll) {
        app.commit_graph_scroll = app.commit_graph_sel;
    } else if (app.commit_graph_sel >= app.commit_graph_scroll + h) {
        app.commit_graph_scroll = app.commit_graph_sel - h + 1;
    }
}

/// Strip ANSI escape sequences from `s`, preserving visible characters and
/// newlines so the result is line-aligned with the coloured graph.
fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, s.len);
    var n: usize = 0;
    var in_esc = false;
    for (s) |c| {
        if (in_esc) {
            if (c == 'm') in_esc = false;
            continue;
        }
        if (c == 0x1b) {
            in_esc = true;
            continue;
        }
        out[n] = c;
        n += 1;
    }
    return allocator.realloc(out, n);
}

/// enter on a commit:
///   - on the current branch  -> move the Commits-panel selection to it (no
///     side effect);
///   - on another branch       -> confirm a checkout of that branch (if the
///     commit is a branch tip) or a detached checkout of the commit.
fn jumpToSelected(app: *App) !void {
    const graph = app.commit_graph orelse return close(app);
    const plain = app.commit_graph_plain orelse graph;
    const line = nthLine(plain, app.commit_graph_sel) orelse return close(app);
    var buf: [64]u8 = undefined;
    const hash = firstHash(line, &buf) orelse {
        try app.setMessage("no commit on that row", .{});
        return;
    };
    // A commit in the current branch's log: pure navigation, no prompt.
    for (app.data.commits, 0..) |c, i| {
        if (std.mem.startsWith(u8, c.short_hash, hash) or std.mem.startsWith(u8, c.hash, hash)) {
            app.commit_index = i;
            app.focus = .commits;
            close(app);
            try app.updatePreview();
            return;
        }
    }
    // Off-branch: confirm a checkout. Prefer a local branch the commit tips.
    const is_branch = firstLocalBranch(line) != null;
    const ref = firstLocalBranch(line) orelse hash;
    app.allocator.free(app.graph_checkout_ref);
    app.graph_checkout_ref = try app.allocator.dupe(u8, ref);
    app.graph_checkout_is_branch = is_branch;
    close(app); // leave the viewer before showing the confirmation
    if (is_branch) {
        return app.requestConfirmation(.checkout_ref, "check out branch {s}?", .{ref});
    }
    return app.requestConfirmation(.checkout_ref, "check out {s}? (detaches HEAD)", .{ref});
}

/// The first local branch name in a graph row's `(decoration)`, or null. Skips
/// `HEAD`, `tag:` entries, and remote-tracking refs (those containing `/`).
fn firstLocalBranch(line: []const u8) ?[]const u8 {
    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_paren = std.mem.indexOfScalarPos(u8, line, open_paren, ')') orelse return null;
    var it = std.mem.splitScalar(u8, line[open_paren + 1 .. close_paren], ',');
    while (it.next()) |raw| {
        const ref = std.mem.trim(u8, raw, " \t");
        if (ref.len == 0) continue;
        if (std.mem.startsWith(u8, ref, "tag:")) continue;
        if (std.mem.startsWith(u8, ref, "HEAD")) continue;
        if (std.mem.indexOfScalar(u8, ref, '/') != null) continue; // remote-tracking
        return ref;
    }
    return null;
}

pub fn close(app: *App) void {
    freeGraph(app);
    app.commit_graph_loading = false;
    app.commit_graph_wanted = false;
    app.commit_graph_generation +%= 1; // discard any in-flight load
    app.mode = .normal;
}

pub fn freeGraph(app: *App) void {
    if (app.commit_graph) |g| {
        app.allocator.free(g);
        app.commit_graph = null;
    }
    if (app.commit_graph_plain) |p| {
        app.allocator.free(p);
        app.commit_graph_plain = null;
    }
    if (app.commit_graph_parents.len > 0) {
        app.allocator.free(app.commit_graph_parents);
        app.commit_graph_parents = &.{};
    }
    app.commit_graph_lines = 0;
}

/// Free everything (called from App.deinit / resetRepoState).
pub fn deinit(app: *App) void {
    freeGraph(app);
    app.allocator.free(app.commit_graph_target);
    app.commit_graph_target = &.{};
    app.allocator.free(app.graph_checkout_ref);
    app.graph_checkout_ref = &.{};
}

fn findTargetRow(app: *App) usize {
    if (app.commit_graph_target.len == 0) return 0;
    return rowForHash(app, app.commit_graph_target) orelse 0;
}

/// True when two abbreviated hashes name the same commit (one is a prefix of the
/// other) — git may abbreviate to different lengths in different places.
fn hashMatch(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b) or std.mem.startsWith(u8, b, a);
}

/// The graph row index whose commit hash matches `hash`, or null if no visible
/// row shows it (e.g. the commit is outside the loaded window).
fn rowForHash(app: *App, hash: []const u8) ?usize {
    const graph = app.commit_graph orelse return null;
    var it = std.mem.splitScalar(u8, graph, '\n');
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (it.next()) |line| : (i += 1) {
        if (firstHash(line, &buf)) |h| {
            if (hashMatch(h, hash)) return i;
        }
    }
    return null;
}

/// The first-parent hash of `hash` from the loaded `%h %p` map, or null when the
/// commit is a root (no parents) or isn't in the map. Copies into `buf`.
fn firstParentOf(parents: []const u8, hash: []const u8, buf: []u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, parents, '\n');
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeScalar(u8, line, ' ');
        const h = toks.next() orelse continue;
        if (!hashMatch(h, hash)) continue;
        const parent = toks.next() orelse return null; // root commit: no parents
        const n = @min(parent.len, buf.len);
        @memcpy(buf[0..n], parent[0..n]);
        return buf[0..n];
    }
    return null;
}

/// `p`: move the cursor to the current commit's first parent, centering it.
fn goToFirstParent(app: *App) !void {
    // Copy the cursor hash out of the shared scratch buffer before the helpers
    // below reuse it.
    var cur_buf: [64]u8 = undefined;
    const cur = if (cursorHash(app)) |h| blk: {
        const n = @min(h.len, cur_buf.len);
        @memcpy(cur_buf[0..n], h[0..n]);
        break :blk cur_buf[0..n];
    } else {
        try app.setMessage("no commit on that row", .{});
        return;
    };
    var parent_buf: [64]u8 = undefined;
    const parent = firstParentOf(app.commit_graph_parents, cur, &parent_buf) orelse {
        try app.setMessage("no parent (root commit, or parents not loaded)", .{});
        return;
    };
    const row = rowForHash(app, parent) orelse {
        try app.setMessage("first parent {s} is outside the loaded graph", .{parent});
        return;
    };
    app.commit_graph_sel = row;
    ensureCursorVisible(app);
    try app.setMessage("jumped to first parent {s}", .{parent});
}

fn widestLine(s: []const u8) usize {
    var max: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| max = @max(max, line.len);
    return max;
}

fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    // A trailing newline shouldn't count as an extra empty row.
    return if (s[s.len - 1] == '\n') n else n + 1;
}

fn nthLine(s: []const u8, n: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == n) return line;
    }
    return null;
}

/// The first abbreviated commit hash on a graph line (after stripping ANSI and
/// the graph glyphs), copied into `buf`. Null if the row has no commit.
fn firstHash(line: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var in_esc = false;
    var run_start: ?usize = null; // start in buf of the current hex run
    var prev_graph = true; // true at line start / after graph glyphs+space
    for (line) |c| {
        if (in_esc) {
            if (c == 'm') in_esc = false;
            continue;
        }
        if (c == 0x1b) {
            in_esc = true;
            continue;
        }
        // Graph glyphs and separators that precede the hash.
        if (c == '*' or c == '|' or c == '/' or c == '\\' or c == '_' or c == ' ') {
            // Close a hex run that turned out to be a hash candidate.
            if (run_start) |rs| {
                const len = n - rs;
                if (len >= 7) return buf[rs..n];
            }
            run_start = null;
            prev_graph = true;
            continue;
        }
        if (std.ascii.isHex(c) and prev_graph) {
            if (run_start == null) run_start = n;
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            }
            continue;
        }
        // A non-hex, non-graph char: the token isn't a hash (it's the subject).
        if (run_start) |rs| {
            const len = n - rs;
            if (len >= 7) return buf[rs..n];
        }
        run_start = null;
        prev_graph = false;
    }
    if (run_start) |rs| {
        const len = n - rs;
        if (len >= 7) return buf[rs..n];
    }
    return null;
}

const vaxis = @import("vaxis");
const up_key = vaxis.Key.up;
const down_key = vaxis.Key.down;
const pgup_key = vaxis.Key.page_up;
const pgdn_key = vaxis.Key.page_down;

test "firstHash extracts the abbreviated hash past the graph glyphs" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc1234", firstHash("* abc1234 some subject", &buf).?);
    try std.testing.expectEqualStrings("deadbee", firstHash("| | * deadbee merge: x", &buf).?);
    try std.testing.expect(firstHash("|\\", &buf) == null); // connector row, no commit
    try std.testing.expect(firstHash("| |", &buf) == null);
}

test "firstHash ignores ANSI colour codes" {
    var buf: [64]u8 = undefined;
    const line = "\x1b[31m*\x1b[m \x1b[33mfeedface\x1b[m subject";
    try std.testing.expectEqualStrings("feedface", firstHash(line, &buf).?);
}

test "firstLocalBranch picks a checkoutable local branch from the decoration" {
    try std.testing.expectEqualStrings("feature", firstLocalBranch("* abc1234 (feature) subject").?);
    // Skips HEAD, tags and remote-tracking refs.
    try std.testing.expectEqualStrings("dev", firstLocalBranch("* abc1234 (HEAD -> main, origin/main, tag: v1, dev) subj").?);
    try std.testing.expect(firstLocalBranch("* abc1234 (origin/main, tag: v1) subj") == null);
    try std.testing.expect(firstLocalBranch("* abc1234 plain subject, no parens") == null);
}

test "countLines counts rows with and without a trailing newline" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb"));
}

test "firstParentOf reads the first parent from a %h %p map" {
    // Merge (f93eef1) then linear history down to a root (43b4136, no parents).
    const map =
        "f93eef1 1183dd8 44f8e7d\n" ++
        "1183dd8 5281457\n" ++
        "44f8e7d 1183dd8\n" ++
        "5281457 43b4136\n" ++
        "43b4136\n";
    var buf: [64]u8 = undefined;

    // A merge commit's first parent is the mainline one.
    try std.testing.expectEqualStrings("1183dd8", firstParentOf(map, "f93eef1", &buf).?);
    // A regular commit.
    try std.testing.expectEqualStrings("43b4136", firstParentOf(map, "5281457", &buf).?);
    // The root commit has no parents.
    try std.testing.expect(firstParentOf(map, "43b4136", &buf) == null);
    // An unknown hash isn't in the map.
    try std.testing.expect(firstParentOf(map, "deadbee", &buf) == null);
}

test "hashMatch treats a prefix as the same commit" {
    try std.testing.expect(hashMatch("1183dd8", "1183dd8"));
    try std.testing.expect(hashMatch("1183dd8", "1183dd8abcd")); // longer disambiguation
    try std.testing.expect(!hashMatch("1183dd8", "44f8e7d"));
}
