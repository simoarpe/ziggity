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

/// The old-side start line from a hunk's `@@ -A,B +C,D @@` header.
fn parseOldStart(at_line: []const u8) ?usize {
    const dash = std.mem.indexOfScalar(u8, at_line, '-') orelse return null;
    var i = dash + 1;
    var value: usize = 0;
    var any = false;
    while (i < at_line.len and at_line[i] >= '0' and at_line[i] <= '9') : (i += 1) {
        value = value * 10 + (at_line[i] - '0');
        any = true;
    }
    return if (any) value else null;
}

/// Build a patch that stages/unstages only the selected lines within one hunk.
/// `sel_first`/`sel_last` are inclusive 0-based indices over the hunk's body
/// lines (excluding the `@@` header). Unselected additions are dropped and
/// unselected deletions become context, then the header counts are recomputed.
/// Returns error.EmptySelection if the selection contains no +/- change.
pub fn buildLinePatch(
    allocator: std.mem.Allocator,
    diff: []const u8,
    parsed: ParsedDiff,
    hunk_index: usize,
    sel_first: usize,
    sel_last: usize,
) ![]u8 {
    if (hunk_index >= parsed.hunks.len) return error.InvalidHunk;
    const hunk = parsed.hunks[hunk_index];
    const header = diff[0..parsed.header_end];
    const hunk_text = diff[hunk.start..hunk.end];
    const nl = std.mem.indexOfScalar(u8, hunk_text, '\n') orelse return error.InvalidHunk;
    const old_start = parseOldStart(hunk_text[0..nl]) orelse return error.InvalidHunk;

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const w = &body.writer;

    var old_count: usize = 0;
    var new_count: usize = 0;
    var changed = false;
    var kept_prev = true;

    var lines = std.mem.splitScalar(u8, hunk_text[nl + 1 ..], '\n');
    var j: usize = 0;
    while (lines.next()) |line| : (j += 1) {
        if (line.len == 0) break; // trailing element after the final newline
        const selected = j >= sel_first and j <= sel_last;
        switch (line[0]) {
            ' ' => {
                try w.print("{s}\n", .{line});
                old_count += 1;
                new_count += 1;
                kept_prev = true;
            },
            '-' => {
                if (selected) {
                    try w.print("{s}\n", .{line});
                    old_count += 1;
                    changed = true;
                } else {
                    try w.print(" {s}\n", .{line[1..]});
                    old_count += 1;
                    new_count += 1;
                }
                kept_prev = true;
            },
            '+' => {
                if (selected) {
                    try w.print("{s}\n", .{line});
                    new_count += 1;
                    changed = true;
                    kept_prev = true;
                } else {
                    kept_prev = false;
                }
            },
            '\\' => if (kept_prev) try w.print("{s}\n", .{line}),
            else => try w.print("{s}\n", .{line}),
        }
    }

    if (!changed) return error.EmptySelection;

    const body_bytes = try body.toOwnedSlice();
    defer allocator.free(body_bytes);

    var patch: std.Io.Writer.Allocating = .init(allocator);
    errdefer patch.deinit();
    try patch.writer.writeAll(header);
    try patch.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, old_start, new_count });
    try patch.writer.writeAll(body_bytes);
    return patch.toOwnedSlice();
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

test "buildLinePatch keeps a selected addition and drops the rest" {
    // Matches the algorithm validated end-to-end against git apply: selecting
    // only the first added line drops the second and recomputes the counts.
    const diff =
        "diff --git a/f.txt b/f.txt\n" ++
        "index d68dd40..e5cc6e6 100644\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -1,4 +1,6 @@\n" ++
        " a\n" ++
        "+X\n" ++
        "+Y\n" ++
        " b\n" ++
        " c\n" ++
        " d\n";
    var parsed = try parse(std.testing.allocator, diff);
    defer parsed.deinit(std.testing.allocator);

    // Body line 1 is "+X" (0-based: " a"=0, "+X"=1, "+Y"=2, ...). Select only it.
    const patch = try buildLinePatch(std.testing.allocator, diff, parsed, 0, 1, 1);
    defer std.testing.allocator.free(patch);

    const expected =
        "diff --git a/f.txt b/f.txt\n" ++
        "index d68dd40..e5cc6e6 100644\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -1,4 +1,5 @@\n" ++
        " a\n" ++
        "+X\n" ++
        " b\n" ++
        " c\n" ++
        " d\n";
    try std.testing.expectEqualStrings(expected, patch);
}

test "buildLinePatch turns an unselected deletion into context" {
    const diff =
        "diff --git a/f b/f\n" ++
        "--- a/f\n" ++
        "+++ b/f\n" ++
        "@@ -1,3 +1,1 @@\n" ++
        "-a\n" ++
        "-b\n" ++
        " c\n";
    var parsed = try parse(std.testing.allocator, diff);
    defer parsed.deinit(std.testing.allocator);

    // Select only "-a" (body index 0); "-b" must become context " b".
    const patch = try buildLinePatch(std.testing.allocator, diff, parsed, 0, 0, 0);
    defer std.testing.allocator.free(patch);

    const expected =
        "diff --git a/f b/f\n" ++
        "--- a/f\n" ++
        "+++ b/f\n" ++
        "@@ -1,3 +1,2 @@\n" ++
        "-a\n" ++
        " b\n" ++
        " c\n";
    try std.testing.expectEqualStrings(expected, patch);
}

test "buildLinePatch rejects a selection with no change" {
    const diff =
        "diff --git a/f b/f\n" ++
        "--- a/f\n" ++
        "+++ b/f\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        " a\n" ++
        "+b\n";
    var parsed = try parse(std.testing.allocator, diff);
    defer parsed.deinit(std.testing.allocator);
    // Body index 0 is the context " a"; selecting only it yields no change.
    try std.testing.expectError(error.EmptySelection, buildLinePatch(std.testing.allocator, diff, parsed, 0, 0, 0));
}
