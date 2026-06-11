const std = @import("std");

/// A single hunk within a unified diff, located by byte offsets and line
/// indices into the original diff text (no copies are made).
pub const Hunk = struct {
    /// Byte range of the hunk body, starting at its `@@` line.
    start: usize,
    end: usize,
    /// Line indices (0-based) of the hunk's first and one-past-last lines.
    start_line: usize,
    end_line: usize,
};

/// A unified diff split into its file header (everything before the first
/// `@@` line) and its hunks. Hunks reference the source `diff` slice.
pub const ParsedDiff = struct {
    /// The header occupies `diff[0..header_end)`.
    header_end: usize,
    hunks: []Hunk,

    pub fn deinit(self: *ParsedDiff, allocator: std.mem.Allocator) void {
        allocator.free(self.hunks);
        self.* = undefined;
    }
};

/// Parse a unified diff (as produced by `git diff`) into its header and hunks.
pub fn parse(allocator: std.mem.Allocator, diff: []const u8) !ParsedDiff {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(allocator);

    var header_end: ?usize = null;
    var line_start: usize = 0;
    var line_index: usize = 0;
    var open_start: ?usize = null;
    var open_line: usize = 0;

    var i: usize = 0;
    while (i <= diff.len) : (i += 1) {
        const at_eol = i == diff.len or diff[i] == '\n';
        if (!at_eol) continue;

        const line = diff[line_start..i];
        if (std.mem.startsWith(u8, line, "@@")) {
            if (header_end == null) header_end = line_start;
            if (open_start) |start| {
                try hunks.append(allocator, .{
                    .start = start,
                    .end = line_start,
                    .start_line = open_line,
                    .end_line = line_index,
                });
            }
            open_start = line_start;
            open_line = line_index;
        }

        line_start = i + 1;
        line_index += 1;
    }

    if (open_start) |start| {
        try hunks.append(allocator, .{
            .start = start,
            .end = diff.len,
            .start_line = open_line,
            .end_line = if (diff.len > 0 and diff[diff.len - 1] == '\n') line_index - 1 else line_index,
        });
    }

    return .{
        .header_end = header_end orelse diff.len,
        .hunks = try hunks.toOwnedSlice(allocator),
    };
}

/// Build a single-hunk patch (file header + one hunk) suitable for
/// `git apply --cached`. Caller owns the returned slice.
pub fn buildHunkPatch(allocator: std.mem.Allocator, diff: []const u8, parsed: ParsedDiff, hunk_index: usize) ![]u8 {
    if (hunk_index >= parsed.hunks.len) return error.InvalidHunk;
    const hunk = parsed.hunks[hunk_index];
    const header = diff[0..parsed.header_end];
    const body = diff[hunk.start..hunk.end];
    const patch = try allocator.alloc(u8, header.len + body.len);
    @memcpy(patch[0..header.len], header);
    @memcpy(patch[header.len..], body);
    return patch;
}

test "parse splits header and hunks" {
    const diff =
        "diff --git a/f b/f\n" ++
        "index 111..222 100644\n" ++
        "--- a/f\n" ++
        "+++ b/f\n" ++
        "@@ -1,2 +1,3 @@\n" ++
        " a\n" ++
        "+b\n" ++
        " c\n" ++
        "@@ -10,2 +11,2 @@\n" ++
        "-x\n" ++
        "+y\n";
    var parsed = try parse(std.testing.allocator, diff);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.hunks.len);
    try std.testing.expect(std.mem.startsWith(u8, diff[0..parsed.header_end], "diff --git"));
    try std.testing.expect(std.mem.startsWith(u8, diff[parsed.hunks[0].start..], "@@ -1,2 +1,3 @@"));
    try std.testing.expect(std.mem.startsWith(u8, diff[parsed.hunks[1].start..], "@@ -10,2 +11,2 @@"));
    try std.testing.expectEqual(@as(usize, 4), parsed.hunks[0].start_line);
    try std.testing.expectEqual(@as(usize, 8), parsed.hunks[1].start_line);
}

test "parse handles a diff with no hunks" {
    var parsed = try parse(std.testing.allocator, "");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), parsed.hunks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.header_end);
}

test "buildHunkPatch joins header with a single hunk" {
    const diff =
        "diff --git a/f b/f\n" ++
        "--- a/f\n" ++
        "+++ b/f\n" ++
        "@@ -1 +1,2 @@\n" ++
        " a\n" ++
        "+b\n" ++
        "@@ -5 +6,2 @@\n" ++
        " c\n" ++
        "+d\n";
    var parsed = try parse(std.testing.allocator, diff);
    defer parsed.deinit(std.testing.allocator);

    const patch = try buildHunkPatch(std.testing.allocator, diff, parsed, 1);
    defer std.testing.allocator.free(patch);

    try std.testing.expect(std.mem.startsWith(u8, patch, "diff --git a/f b/f\n"));
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -5 +6,2 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -1 +1,2 @@") == null);
}
