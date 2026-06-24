const std = @import("std");

/// One visible row of the file tree: either a directory (collapsible) or a
/// file. `path` is the directory path for dirs (e.g. "src/sub") or the file
/// path for files. `file_index` indexes the caller's file list for file rows.
pub const Row = struct {
    is_dir: bool,
    depth: u16,
    path: []const u8,
    file_index: usize = 0,
    collapsed: bool = false,
};

/// A file to place in the tree, paired with its index in the owning list.
pub const Entry = struct {
    path: []const u8,
    index: usize,
};

/// Build the flattened, currently-visible rows of a directory tree from a
/// path-sorted list of files. Directories listed in `collapsed` are shown but
/// their descendants are hidden. Rows reference the input paths (no copies).
///
/// When `show_root` is set, a synthetic root directory row (the empty path "",
/// covering every file) is placed first and everything else is indented one
/// level beneath it; collapsing the root hides the whole tree.
pub fn build(allocator: std.mem.Allocator, entries: []const Entry, collapsed: *const std.BufSet, show_root: bool) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);

    const base: u16 = if (show_root) 1 else 0;
    if (show_root) {
        const root_collapsed = collapsed.contains("");
        try rows.append(allocator, .{ .is_dir = true, .depth = 0, .path = "", .collapsed = root_collapsed });
        if (root_collapsed) return rows.toOwnedSlice(allocator);
    }

    var prev_dir: []const u8 = "";
    var i: usize = 0;
    while (i < entries.len) {
        const entry = entries[i];
        const dir = dirOf(entry.path);
        const segs = segCount(dir);
        const common = commonSegs(prev_dir, dir);

        var skipped = false;
        var d: usize = common;
        while (d < segs) : (d += 1) {
            const dir_path = dir[0..prefixLen(dir, d + 1)];
            const is_collapsed = collapsed.contains(dir_path);
            try rows.append(allocator, .{
                .is_dir = true,
                .depth = depthCast(d) + base,
                .path = dir_path,
                .collapsed = is_collapsed,
            });
            if (is_collapsed) {
                // Hide every entry under this directory (they are contiguous
                // because the input is path-sorted).
                var j = i;
                while (j < entries.len and underDir(entries[j].path, dir_path)) : (j += 1) {}
                i = j;
                prev_dir = dir_path;
                skipped = true;
                break;
            }
        }
        if (skipped) continue;

        try rows.append(allocator, .{
            .is_dir = false,
            .depth = depthCast(segs) + base,
            .path = entry.path,
            .file_index = entry.index,
        });
        prev_dir = dir;
        i += 1;
    }

    return rows.toOwnedSlice(allocator);
}

/// Saturating narrow of a path-depth to the Row.depth width (only ever used for
/// indentation, so clamping absurdly deep paths is harmless).
fn depthCast(depth: usize) u16 {
    return @intCast(@min(depth, std.math.maxInt(u16)));
}

/// The directory portion of a path ("src/a/b.zig" -> "src/a", "x" -> "").
pub fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}

fn segCount(dir: []const u8) usize {
    if (dir.len == 0) return 0;
    return std.mem.count(u8, dir, "/") + 1;
}

/// Byte length of the first `n` segments of `dir` (no trailing slash).
fn prefixLen(dir: []const u8, n: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        if (dir[i] == '/') {
            seen += 1;
            if (seen == n) return i;
        }
    }
    return dir.len;
}

fn segAt(dir: []const u8, k: usize) ?[]const u8 {
    if (dir.len == 0) return null;
    var seg: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            if (seg == k) return dir[start..i];
            seg += 1;
            start = i + 1;
        }
    }
    return null;
}

fn commonSegs(a: []const u8, b: []const u8) usize {
    var k: usize = 0;
    while (true) : (k += 1) {
        const sa = segAt(a, k) orelse return k;
        const sb = segAt(b, k) orelse return k;
        if (!std.mem.eql(u8, sa, sb)) return k;
    }
}

/// True if `path` lives directly or indirectly under directory `dir`.
pub fn underDir(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

fn expectRow(row: Row, is_dir: bool, depth: u16, path: []const u8) !void {
    try std.testing.expectEqual(is_dir, row.is_dir);
    try std.testing.expectEqual(depth, row.depth);
    try std.testing.expectEqualStrings(path, row.path);
}

test "build groups files under nested directories" {
    var collapsed = std.BufSet.init(std.testing.allocator);
    defer collapsed.deinit();

    const entries = [_]Entry{
        .{ .path = "README.md", .index = 0 },
        .{ .path = "src/app.zig", .index = 1 },
        .{ .path = "src/sub/a.zig", .index = 2 },
        .{ .path = "src/sub/b.zig", .index = 3 },
    };
    const rows = try build(std.testing.allocator, &entries, &collapsed, false);
    defer std.testing.allocator.free(rows);

    try std.testing.expectEqual(@as(usize, 6), rows.len);
    try expectRow(rows[0], false, 0, "README.md");
    try expectRow(rows[1], true, 0, "src");
    try expectRow(rows[2], false, 1, "src/app.zig");
    try expectRow(rows[3], true, 1, "src/sub");
    try expectRow(rows[4], false, 2, "src/sub/a.zig");
    try expectRow(rows[5], false, 2, "src/sub/b.zig");
    try std.testing.expectEqual(@as(usize, 2), rows[4].file_index);
}

test "build hides descendants of a collapsed directory" {
    var collapsed = std.BufSet.init(std.testing.allocator);
    defer collapsed.deinit();
    try collapsed.insert("src/sub");

    const entries = [_]Entry{
        .{ .path = "src/app.zig", .index = 0 },
        .{ .path = "src/sub/a.zig", .index = 1 },
        .{ .path = "src/sub/b.zig", .index = 2 },
        .{ .path = "src/zed.zig", .index = 3 },
    };
    const rows = try build(std.testing.allocator, &entries, &collapsed, false);
    defer std.testing.allocator.free(rows);

    // src, src/app.zig, src/sub (collapsed, no children), src/zed.zig
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try expectRow(rows[0], true, 0, "src");
    try expectRow(rows[1], false, 1, "src/app.zig");
    try expectRow(rows[2], true, 1, "src/sub");
    try std.testing.expect(rows[2].collapsed);
    try expectRow(rows[3], false, 1, "src/zed.zig");
}

test "build with a root node nests everything under the empty path" {
    var collapsed = std.BufSet.init(std.testing.allocator);
    defer collapsed.deinit();

    const entries = [_]Entry{
        .{ .path = "README.md", .index = 0 },
        .{ .path = "src/app.zig", .index = 1 },
    };
    const rows = try build(std.testing.allocator, &entries, &collapsed, true);
    defer std.testing.allocator.free(rows);

    // Root row first, then everything indented one level beneath it.
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try expectRow(rows[0], true, 0, "");
    try expectRow(rows[1], false, 1, "README.md");
    try expectRow(rows[2], true, 1, "src");
    try expectRow(rows[3], false, 2, "src/app.zig");

    // Collapsing the root hides the whole tree, leaving only the root row.
    try collapsed.insert("");
    const collapsed_rows = try build(std.testing.allocator, &entries, &collapsed, true);
    defer std.testing.allocator.free(collapsed_rows);
    try std.testing.expectEqual(@as(usize, 1), collapsed_rows.len);
    try std.testing.expect(collapsed_rows[0].collapsed);
}

test "underDir and dirOf" {
    try std.testing.expect(underDir("src/a.zig", "src"));
    try std.testing.expect(underDir("src/sub/a.zig", "src"));
    try std.testing.expect(!underDir("srcx/a.zig", "src"));
    try std.testing.expect(!underDir("README.md", "src"));
    try std.testing.expectEqualStrings("src/sub", dirOf("src/sub/a.zig"));
    try std.testing.expectEqualStrings("", dirOf("README.md"));
}
