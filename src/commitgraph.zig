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

/// Toggle between the current branch and all branches, reloading.
pub fn toggleScope(app: *App) void {
    app.commit_graph_all = !app.commit_graph_all;
    requestLoad(app);
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
pub fn complete(app: *App, text: ?[]u8, generation: u64, gpa: std.mem.Allocator) void {
    if (generation != app.commit_graph_generation or app.mode != .commit_graph) {
        if (text) |t| gpa.free(t);
        return;
    }
    app.commit_graph_loading = false;
    if (text) |t| {
        defer gpa.free(t);
        freeGraph(app);
        app.commit_graph = app.allocator.dupe(u8, t) catch null;
        app.commit_graph_lines = countLines(app.commit_graph orelse "");
        // Highlight the row for the commit that was selected on open.
        app.commit_graph_sel = findTargetRow(app);
        app.commit_graph_scroll = 0;
    }
}

pub fn handleKey(app: *App, key: anytype) !void {
    if (app.isEscapeKey(key)) return close(app);

    const km = app.config.keymap;
    const lines = app.commit_graph_lines;
    if (km.up.matches(key) or key.matches(up_key, .{})) {
        app.commit_graph_sel -|= 1;
        return;
    }
    if (km.down.matches(key) or key.matches(down_key, .{})) {
        if (lines > 0 and app.commit_graph_sel + 1 < lines) app.commit_graph_sel += 1;
        return;
    }
    if (key.matches(pgup_key, .{})) {
        app.commit_graph_sel -|= 10;
        return;
    }
    if (key.matches(pgdn_key, .{})) {
        if (lines > 0) app.commit_graph_sel = @min(app.commit_graph_sel + 10, lines - 1);
        return;
    }
    // `a` toggles the all-branches / current-branch scope.
    if (km.stage_all.matches(key)) return toggleScope(app);
    // enter jumps the Commits-panel selection to the row under the cursor.
    if (app.isEnterKey(key)) return jumpToSelected(app);
}

/// enter: resolve the commit on the cursor row and select it in the Commits panel.
fn jumpToSelected(app: *App) !void {
    const graph = app.commit_graph orelse return close(app);
    const line = nthLine(graph, app.commit_graph_sel) orelse return close(app);
    var buf: [64]u8 = undefined;
    const hash = firstHash(line, &buf) orelse {
        try app.setMessage("no commit on that row", .{});
        return;
    };
    for (app.data.commits, 0..) |c, i| {
        if (std.mem.startsWith(u8, c.short_hash, hash) or std.mem.startsWith(u8, c.hash, hash)) {
            app.commit_index = i;
            app.focus = .commits;
            close(app);
            try app.updatePreview();
            return;
        }
    }
    // Not in the loaded window; just close on the commit.
    close(app);
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
    app.commit_graph_lines = 0;
}

/// Free everything (called from App.deinit / resetRepoState).
pub fn deinit(app: *App) void {
    freeGraph(app);
    app.allocator.free(app.commit_graph_target);
    app.commit_graph_target = &.{};
}

fn findTargetRow(app: *App) usize {
    const graph = app.commit_graph orelse return 0;
    const target = app.commit_graph_target;
    if (target.len == 0) return 0;
    var it = std.mem.splitScalar(u8, graph, '\n');
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (it.next()) |line| : (i += 1) {
        if (firstHash(line, &buf)) |h| {
            if (std.mem.startsWith(u8, target, h) or std.mem.startsWith(u8, h, target)) return i;
        }
    }
    return 0;
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

test "countLines counts rows with and without a trailing newline" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb"));
}
