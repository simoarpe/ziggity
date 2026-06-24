const std = @import("std");

/// One visible row of the file tree: either a directory (collapsible) or a
/// file. `path` is the directory path for dirs (e.g. "src/sub") or the file
/// path for files. `file_index` indexes the caller's file list for file rows.
pub const Row = struct {
    is_dir: bool,
    depth: u16,
    path: []const u8,
    /// Byte offset into `path` where this row's display name begins (the part
    /// after its parent's prefix). A compressed chain like "a/b/c" displays the
    /// whole "a/b/c"; "src/sub" under "src" displays just "sub". Files render by
    /// basename, so this only matters for directory rows.
    name_off: usize = 0,
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
/// A directory whose only child is another directory is compressed into a single
/// row ("a/b/c"), matching the familiar collapsed-chain look. When `show_root`
/// is set, a synthetic root row (the empty path "", covering every file) is
/// placed first and everything else is indented one level beneath it; collapsing
/// the root hides the whole tree.
pub fn build(allocator: std.mem.Allocator, entries: []const Entry, collapsed: *const std.BufSet, show_root: bool) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);

    const base_depth: u16 = if (show_root) 1 else 0;
    if (show_root) {
        const root_collapsed = collapsed.contains("");
        try rows.append(allocator, .{ .is_dir = true, .depth = 0, .path = "", .collapsed = root_collapsed });
        if (root_collapsed) return rows.toOwnedSlice(allocator);
    }
    try buildLevel(allocator, &rows, entries, 0, base_depth, collapsed);
    return rows.toOwnedSlice(allocator);
}

/// Emit rows for `entries`, all of which live under one parent directory whose
/// path occupies the first `base` bytes of each entry path (0 at the root).
/// Entries are grouped by their next path segment; a directory with a single
/// sub-directory child is compressed into the same row.
fn buildLevel(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), entries: []const Entry, base: usize, depth: u16, collapsed: *const std.BufSet) !void {
    var i: usize = 0;
    while (i < entries.len) {
        const path = entries[i].path;
        const slash = std.mem.indexOfScalarPos(u8, path, base, '/') orelse {
            // A file sitting directly in this directory.
            try rows.append(allocator, .{ .is_dir = false, .depth = depth, .path = path, .name_off = base, .file_index = entries[i].index });
            i += 1;
            continue;
        };
        // A sub-directory: gather every entry beneath it (contiguous, sorted).
        var dir_path = path[0..slash];
        var j = i;
        while (j < entries.len and underDir(entries[j].path, dir_path)) : (j += 1) {}

        // Compress a chain of single sub-directory children into one row: extend
        // `dir_path` while the whole group still shares one deeper directory.
        var child_base = slash + 1;
        while (true) {
            const first = entries[i].path;
            const last = entries[j - 1].path;
            const fs = std.mem.indexOfScalarPos(u8, first, child_base, '/') orelse break;
            const ls = std.mem.indexOfScalarPos(u8, last, child_base, '/') orelse break;
            if (!std.mem.eql(u8, first[child_base..fs], last[child_base..ls])) break;
            dir_path = first[0..fs];
            child_base = fs + 1;
        }

        const is_collapsed = collapsed.contains(dir_path);
        try rows.append(allocator, .{ .is_dir = true, .depth = depth, .path = dir_path, .name_off = base, .collapsed = is_collapsed });
        if (!is_collapsed) try buildLevel(allocator, rows, entries[i..j], child_base, depth + 1, collapsed);
        i = j;
    }
}

/// The directory portion of a path ("src/a/b.zig" -> "src/a", "x" -> "").
pub fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
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

test "build compresses single-child directory chains into one row" {
    var collapsed = std.BufSet.init(std.testing.allocator);
    defer collapsed.deinit();

    const entries = [_]Entry{
        .{ .path = "a/b/c/x.zig", .index = 0 },
        .{ .path = "a/b/c/y.zig", .index = 1 },
        .{ .path = "top.zig", .index = 2 },
    };
    const rows = try build(std.testing.allocator, &entries, &collapsed, false);
    defer std.testing.allocator.free(rows);

    // "a/b/c" collapses to one directory row; its name spans the whole chain.
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try expectRow(rows[0], true, 0, "a/b/c");
    try std.testing.expectEqualStrings("a/b/c", rows[0].path[rows[0].name_off..]);
    try expectRow(rows[1], false, 1, "a/b/c/x.zig");
    try expectRow(rows[2], false, 1, "a/b/c/y.zig");
    try expectRow(rows[3], false, 0, "top.zig");
}

test "build stops compressing when a directory has a file child" {
    var collapsed = std.BufSet.init(std.testing.allocator);
    defer collapsed.deinit();

    // "a" has a single child "b", but "b" holds both a file and a subdirectory,
    // so compression merges "a/b" and stops there.
    const entries = [_]Entry{
        .{ .path = "a/b/c/deep.zig", .index = 0 },
        .{ .path = "a/b/file.zig", .index = 1 },
    };
    const rows = try build(std.testing.allocator, &entries, &collapsed, false);
    defer std.testing.allocator.free(rows);

    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try expectRow(rows[0], true, 0, "a/b"); // a -> b compressed
    try std.testing.expectEqualStrings("a/b", rows[0].path[rows[0].name_off..]);
    try expectRow(rows[1], true, 1, "a/b/c");
    try std.testing.expectEqualStrings("c", rows[1].path[rows[1].name_off..]);
    try expectRow(rows[2], false, 2, "a/b/c/deep.zig");
    try expectRow(rows[3], false, 1, "a/b/file.zig");
}

test "underDir and dirOf" {
    try std.testing.expect(underDir("src/a.zig", "src"));
    try std.testing.expect(underDir("src/sub/a.zig", "src"));
    try std.testing.expect(!underDir("srcx/a.zig", "src"));
    try std.testing.expect(!underDir("README.md", "src"));
    try std.testing.expectEqualStrings("src/sub", dirOf("src/sub/a.zig"));
    try std.testing.expectEqualStrings("", dirOf("README.md"));
}
