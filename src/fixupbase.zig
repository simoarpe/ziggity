//! `ctrl+f` find-base-commit-for-fixup: figure out which existing commit the
//! current staged (or unstaged) change belongs to, by blaming the lines it
//! touches, then create a `fixup!` commit for that base. Mirrors the reference's
//! FindBaseCommitForFixup. Free functions over `*App`.
const std = @import("std");

const app_mod = @import("app.zig");
const model = @import("model.zig");

const App = app_mod.App;

/// An old-line (HEAD-side) range to blame, inclusive, 1-based.
pub const Range = struct { start: usize, end: usize };

pub const FileRanges = struct {
    path: []u8,
    ranges: []Range,

    pub fn deinit(self: *FileRanges, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.ranges);
    }
};

/// Parse a unified diff into, per file, the old-line ranges whose origin commit
/// identifies the fixup base: the exact deleted lines, or — for a pure-addition
/// hunk — the surrounding context lines. Owned by `allocator`.
pub fn parseDiffRanges(allocator: std.mem.Allocator, diff: []const u8) ![]FileRanges {
    var files: std.ArrayList(FileRanges) = .empty;
    errdefer {
        for (files.items) |*f| f.deinit(allocator);
        files.deinit(allocator);
    }

    var path: ?[]const u8 = null;
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);

    // Per-hunk state.
    var old_line: usize = 0;
    var old_start: usize = 0;
    var old_count: usize = 0;
    var hunk_has_del = false;
    var hunk_has_add = false;
    var del_start: usize = 0; // 0 = no open deleted run

    const flushHunk = struct {
        fn call(a: std.mem.Allocator, rs: *std.ArrayList(Range), os: usize, oc: usize, has_del: bool, has_add: bool, dstart: *usize, oline: usize) !void {
            if (dstart.* != 0) {
                try rs.append(a, .{ .start = dstart.*, .end = oline - 1 });
                dstart.* = 0;
            }
            // Pure addition: blame the hunk's old context window instead.
            if (!has_del and has_add and oc > 0) {
                try rs.append(a, .{ .start = @max(os, 1), .end = os + oc - 1 });
            }
        }
    }.call;

    const flushFile = struct {
        fn call(a: std.mem.Allocator, fs: *std.ArrayList(FileRanges), p: *?[]const u8, rs: *std.ArrayList(Range)) !void {
            if (p.*) |pp| {
                if (rs.items.len > 0) {
                    try fs.append(a, .{ .path = try a.dupe(u8, pp), .ranges = try rs.toOwnedSlice(a) });
                } else {
                    rs.clearRetainingCapacity();
                }
            }
            p.* = null;
        }
    }.call;

    var it = std.mem.splitScalar(u8, diff, '\n');
    var in_hunk = false;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ")) {
            if (in_hunk) {
                try flushHunk(allocator, &ranges, old_start, old_count, hunk_has_del, hunk_has_add, &del_start, old_line);
                in_hunk = false;
            }
            try flushFile(allocator, &files, &path, &ranges);
            // "+++ b/path" (or "+++ /dev/null" for deletions — skip those).
            const rest = line[4..];
            if (std.mem.eql(u8, rest, "/dev/null")) {
                path = null;
            } else {
                path = if (std.mem.startsWith(u8, rest, "b/")) rest[2..] else rest;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "diff --git") or std.mem.startsWith(u8, line, "--- ")) {
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            if (in_hunk) try flushHunk(allocator, &ranges, old_start, old_count, hunk_has_del, hunk_has_add, &del_start, old_line);
            parseHunkHeader(line, &old_start, &old_count);
            old_line = old_start;
            hunk_has_del = false;
            hunk_has_add = false;
            del_start = 0;
            in_hunk = true;
            continue;
        }
        if (!in_hunk or path == null) continue;
        const c: u8 = if (line.len > 0) line[0] else ' ';
        switch (c) {
            '-' => {
                hunk_has_del = true;
                if (del_start == 0) del_start = old_line;
                old_line += 1;
            },
            '+' => hunk_has_add = true,
            '\\' => {}, // "\ No newline at end of file"
            else => { // context
                if (del_start != 0) {
                    try ranges.append(allocator, .{ .start = del_start, .end = old_line - 1 });
                    del_start = 0;
                }
                old_line += 1;
            },
        }
    }
    if (in_hunk) try flushHunk(allocator, &ranges, old_start, old_count, hunk_has_del, hunk_has_add, &del_start, old_line);
    try flushFile(allocator, &files, &path, &ranges);

    return files.toOwnedSlice(allocator);
}

/// Parse `@@ -old_start,old_count +new... @@`. A missing count means 1.
fn parseHunkHeader(line: []const u8, old_start: *usize, old_count: *usize) void {
    old_start.* = 1;
    old_count.* = 1;
    const minus = std.mem.indexOfScalar(u8, line, '-') orelse return;
    const seg = line[minus + 1 ..];
    const end = std.mem.indexOfAny(u8, seg, " +") orelse seg.len;
    const spec = seg[0..end];
    if (std.mem.indexOfScalar(u8, spec, ',')) |comma| {
        old_start.* = std.fmt.parseInt(usize, spec[0..comma], 10) catch 1;
        old_count.* = std.fmt.parseInt(usize, spec[comma + 1 ..], 10) catch 1;
    } else {
        old_start.* = std.fmt.parseInt(usize, spec, 10) catch 1;
        old_count.* = 1;
    }
}

/// `ctrl+f`: find the base commit for the current change and create a fixup!.
pub fn findBaseAndFixup(app: *App) !void {
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress rebase/merge first (m)", .{});
        return;
    }
    const staged = app.data.stagedCount() > 0;
    const diff = app.git.diffForFixup(staged) catch {
        try app.setMessage("could not read the diff", .{});
        return;
    };
    defer app.allocator.free(diff);
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) {
        try app.setMessage("no changes to find a fixup base for", .{});
        return;
    }

    const files = try parseDiffRanges(app.allocator, diff);
    defer {
        for (files) |*f| f.deinit(app.allocator);
        app.allocator.free(files);
    }

    // Blame every range, collecting distinct candidate commit hashes.
    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |h| app.allocator.free(h);
        candidates.deinit(app.allocator);
    }
    for (files) |f| {
        for (f.ranges) |r| {
            var res = app.git.blameRange(f.path, r.start, r.end) catch continue;
            defer res.deinit(app.allocator);
            if (!res.ok()) continue;
            try collectBlameHashes(app.allocator, res.stdout, &candidates);
        }
    }
    if (candidates.items.len == 0) {
        try app.setMessage("could not find a base commit for these changes", .{});
        return;
    }

    // Pick the newest candidate (smallest index in the newest-first log).
    const base = newestCandidate(candidates.items, app.data.commits);
    const distinct = candidates.items.len;
    if (distinct > 1) {
        try app.setMessage("multiple base commits; fixing up the newest ({s})", .{shortOf(base)});
    }
    return app.requestMutation(
        .{ .create_fixup = base },
        .{ .gerund = "creating fixup", .command = "git commit --fixup", .refresh = App.Refresh.commit },
        "created fixup! for {s}",
        .{shortOf(base)},
    );
}

/// Append each distinct, non-zero originating commit hash from porcelain blame
/// output to `out` (each line group starts with `<40-hex> ...`).
fn collectBlameHashes(allocator: std.mem.Allocator, blame: []const u8, out: *std.ArrayList([]u8)) !void {
    var it = std.mem.splitScalar(u8, blame, '\n');
    while (it.next()) |line| {
        if (line.len < 41 or line[40] != ' ') continue;
        const hash = line[0..40];
        if (!isHex(hash) or isAllZero(hash)) continue;
        var seen = false;
        for (out.items) |h| {
            if (std.mem.eql(u8, h, hash)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(allocator, try allocator.dupe(u8, hash));
    }
}

/// The candidate that is newest in `commits` (newest-first); falls back to the
/// first candidate when none are in the loaded log.
fn newestCandidate(candidates: []const []u8, commits: []const model.Commit) []const u8 {
    var best: []const u8 = candidates[0];
    var best_idx: usize = std.math.maxInt(usize);
    for (candidates) |h| {
        for (commits, 0..) |c, i| {
            if (std.mem.eql(u8, c.hash, h)) {
                if (i < best_idx) {
                    best_idx = i;
                    best = h;
                }
                break;
            }
        }
    }
    return best;
}

fn shortOf(hash: []const u8) []const u8 {
    return hash[0..@min(7, hash.len)];
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isAllZero(s: []const u8) bool {
    for (s) |c| {
        if (c != '0') return false;
    }
    return true;
}

test "parseDiffRanges: deleted lines yield their exact old-line range" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -10,3 +10,2 @@\n" ++
        " context\n" ++
        "-removed one\n" ++
        "-removed two\n" ++
        " context2\n";
    const files = try parseDiffRanges(a, diff);
    defer {
        for (files) |*f| f.deinit(a);
        a.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("f.txt", files[0].path);
    try std.testing.expectEqual(@as(usize, 1), files[0].ranges.len);
    // line 10 = context, 11/12 = the two removed old lines.
    try std.testing.expectEqual(@as(usize, 11), files[0].ranges[0].start);
    try std.testing.expectEqual(@as(usize, 12), files[0].ranges[0].end);
}

test "parseDiffRanges: pure addition blames the surrounding context window" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -5,2 +5,3 @@\n" ++
        " ctx a\n" ++
        "+added line\n" ++
        " ctx b\n";
    const files = try parseDiffRanges(a, diff);
    defer {
        for (files) |*f| f.deinit(a);
        a.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files[0].ranges.len);
    try std.testing.expectEqual(@as(usize, 5), files[0].ranges[0].start);
    try std.testing.expectEqual(@as(usize, 6), files[0].ranges[0].end);
}

test "collectBlameHashes dedups and skips the all-zero boundary hash" {
    const a = std.testing.allocator;
    const blame =
        "1111111111111111111111111111111111111111 1 1 1\n" ++
        "\tcode line\n" ++
        "1111111111111111111111111111111111111111 2 2\n" ++
        "\tcode line 2\n" ++
        "0000000000000000000000000000000000000000 3 3 1\n" ++
        "\tuncommitted\n";
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |h| a.free(h);
        out.deinit(a);
    }
    try collectBlameHashes(a, blame, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", out.items[0]);
}
