//! Turns a unified diff into aligned side-by-side rows: the old file on the
//! left, the new file on the right, lines paired up so a change shows its
//! before and after next to each other.
//!
//! This module is pure layout. It does not render anything and makes no copies:
//! every cell points back into the original diff text by byte offset, so the
//! caller keeps the diff buffer alive for as long as it uses the rows. The row
//! list it returns is meant to be cached alongside the diff and freed with
//! `free` when the diff changes.
//!
//! Pairing rule, per hunk: context lines sit on both sides at the same row. A
//! run of removed lines is paired with the run of added lines that follows it,
//! one row each by position; when the runs differ in length the shorter side
//! gets blank padding rows. A pure addition therefore has a blank left cell, a
//! pure deletion a blank right cell. This is the straightforward positional
//! pairing; it does not try to match moved or similar lines across the gap.

const std = @import("std");
const diff_mod = @import("diff.zig");

/// What a single cell holds. `blank` is padding on the short side of an uneven
/// change; it has no text.
pub const CellKind = enum { blank, context, del, add };

/// One side of a row. `off`/`len` slice the diff text to the line's content,
/// with the leading `+`/`-`/space marker already stripped. `no_newline` marks a
/// line that the diff flagged with `\ No newline at end of file`.
pub const Cell = struct {
    kind: CellKind = .blank,
    off: usize = 0,
    len: usize = 0,
    /// The cell's line index within the whole diff (0-based), matching
    /// `worddiff.build`'s per-line output so the renderer can emphasize the
    /// changed words. Unused for a blank cell.
    line: usize = 0,
    /// The line's number in the old file (set on `del` and `context` cells) and
    /// in the new file (set on `add` and `context` cells); 0 where it does not
    /// apply. The renderer shows `old_no` in the left gutter, `new_no` in the
    /// right, so a shared context cell numbers both sides correctly.
    old_no: usize = 0,
    new_no: usize = 0,
    no_newline: bool = false,

    /// The cell's text, sliced from the diff the rows were built from.
    pub fn text(self: Cell, diff: []const u8) []const u8 {
        return diff[self.off .. self.off + self.len];
    }
};

/// A `header` row carries a hunk's `@@ ... @@` line (in `left`) and spans the
/// full width when drawn. A `pair` row carries a left and a right cell. A
/// `spacer` is a blank row the view layer places after each hunk to separate
/// them (and to carry the selection box's bottom edge); `build` never emits one.
pub const RowKind = enum { header, pair, spacer };

pub const Row = struct {
    kind: RowKind,
    left: Cell = .{},
    right: Cell = .{},
};

/// Build the side-by-side rows for a parsed unified diff. Caller owns the
/// returned slice and frees it with `free`. The rows borrow `diff`, so it must
/// outlive them.
pub fn build(gpa: std.mem.Allocator, diff: []const u8, parsed: diff_mod.ParsedDiff) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);
    for (parsed.hunks) |h| try appendHunk(gpa, &rows, diff, h);
    return rows.toOwnedSlice(gpa);
}

pub fn free(gpa: std.mem.Allocator, rows: []Row) void {
    gpa.free(rows);
}

/// Append one hunk's rows: its `@@` header, then its body paired up.
fn appendHunk(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), diff: []const u8, h: diff_mod.Hunk) !void {
    // Pending removed/added runs, flushed (paired) when a context line or the
    // end of the hunk closes the run.
    var dels: std.ArrayList(Cell) = .empty;
    defer dels.deinit(gpa);
    var adds: std.ArrayList(Cell) = .empty;
    defer adds.deinit(gpa);

    var first = true;
    var last: u8 = ' '; // kind of the previous body line, for the `\` marker
    var line_no = h.start_line; // index of the current line in the whole diff
    // Running file line numbers, seeded from the hunk's `@@ -old,+new @@` header.
    const starts = parseHunkStarts(diff[h.start..h.end]);
    var old_no = starts.old;
    var new_no = starts.new;
    var ls = h.start;
    while (ls < h.end) : (line_no += 1) {
        var le = ls;
        while (le < h.end and diff[le] != '\n') : (le += 1) {}
        const line = diff[ls..le];

        if (first) {
            // The hunk's `@@` header line, drawn across both columns.
            try rows.append(gpa, .{ .kind = .header, .left = .{ .kind = .context, .off = ls, .len = le - ls, .line = line_no } });
            first = false;
            ls = le + 1;
            continue;
        }

        const c: u8 = if (line.len > 0) line[0] else ' ';
        switch (c) {
            '-' => {
                try dels.append(gpa, .{ .kind = .del, .off = ls + 1, .len = line.len - 1, .line = line_no, .old_no = old_no });
                old_no += 1;
            },
            '+' => {
                try adds.append(gpa, .{ .kind = .add, .off = ls + 1, .len = line.len - 1, .line = line_no, .new_no = new_no });
                new_no += 1;
            },
            // `\ No newline at end of file` refers to the line just above it, so
            // flag that pending (or just-emitted context) cell instead of making
            // a row of its own. This keeps the run pairing intact.
            '\\' => markNoNewline(last, &dels, &adds, rows),
            // Anything else is a context line (it leads with a space, or is the
            // rare empty line). Close any open run, then emit it on both sides.
            else => {
                try flushPairs(gpa, rows, &dels, &adds);
                const off = if (line.len > 0) ls + 1 else ls;
                const len = if (line.len > 0) line.len - 1 else 0;
                const cell: Cell = .{ .kind = .context, .off = off, .len = len, .line = line_no, .old_no = old_no, .new_no = new_no };
                try rows.append(gpa, .{ .kind = .pair, .left = cell, .right = cell });
                old_no += 1;
                new_no += 1;
            },
        }
        last = c;
        ls = le + 1;
    }
    try flushPairs(gpa, rows, &dels, &adds);
}

/// The old and new starting line numbers from a hunk's `@@ -old[,n] +new[,n] @@`
/// header. Defaults to 1 for either side the header does not carry, so numbering
/// never starts at 0 for a side that actually has lines.
fn parseHunkStarts(hunk: []const u8) struct { old: usize, new: usize } {
    var nl: usize = 0;
    while (nl < hunk.len and hunk[nl] != '\n') : (nl += 1) {}
    const header = hunk[0..nl];
    return .{
        .old = numberAfter(header, "-") orelse 1,
        .new = numberAfter(header, "+") orelse 1,
    };
}

/// The decimal number immediately after the first `mark` (`"-"` or `"+"`) in a
/// hunk header. Null when the mark or a digit after it is missing.
fn numberAfter(header: []const u8, mark: []const u8) ?usize {
    const at = std.mem.indexOf(u8, header, mark) orelse return null;
    var i = at + mark.len;
    if (i >= header.len or header[i] < '0' or header[i] > '9') return null;
    var n: usize = 0;
    while (i < header.len and header[i] >= '0' and header[i] <= '9') : (i += 1) {
        n = n * 10 + (header[i] - '0');
    }
    return n;
}

/// Pair the pending removed and added runs into rows, padding the shorter side
/// with blank cells, then clear both runs.
fn flushPairs(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), dels: *std.ArrayList(Cell), adds: *std.ArrayList(Cell)) !void {
    const n = @max(dels.items.len, adds.items.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const l: Cell = if (i < dels.items.len) dels.items[i] else .{};
        const r: Cell = if (i < adds.items.len) adds.items[i] else .{};
        try rows.append(gpa, .{ .kind = .pair, .left = l, .right = r });
    }
    dels.clearRetainingCapacity();
    adds.clearRetainingCapacity();
}

/// Set the no-newline flag on the cell the `\` marker refers to: the last line
/// above it. For a removed/added line that run is still pending; for a context
/// line the row is already emitted, so flag both of its sides.
fn markNoNewline(last: u8, dels: *std.ArrayList(Cell), adds: *std.ArrayList(Cell), rows: *std.ArrayList(Row)) void {
    switch (last) {
        '-' => if (dels.items.len > 0) {
            dels.items[dels.items.len - 1].no_newline = true;
        },
        '+' => if (adds.items.len > 0) {
            adds.items[adds.items.len - 1].no_newline = true;
        },
        else => if (rows.items.len > 0 and rows.items[rows.items.len - 1].kind == .pair) {
            rows.items[rows.items.len - 1].left.no_newline = true;
            rows.items[rows.items.len - 1].right.no_newline = true;
        },
    }
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

/// Parse `diff` and build its rows, for the tests below. Caller frees the rows
/// with `free` and must keep `diff` alive while using them.
fn rowsOf(gpa: std.mem.Allocator, diff: []const u8) ![]Row {
    var parsed = try diff_mod.parse(gpa, diff);
    defer parsed.deinit(gpa);
    return build(gpa, diff, parsed);
}

test "pure addition: every row has a blank left and the added text on the right" {
    const gpa = testing.allocator;
    const diff = "@@ -0,0 +1,2 @@\n+alpha\n+beta\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(RowKind.header, rows[0].kind);
    try testing.expectEqualStrings("@@ -0,0 +1,2 @@", rows[0].left.text(diff));

    try testing.expectEqual(CellKind.blank, rows[1].left.kind);
    try testing.expectEqual(CellKind.add, rows[1].right.kind);
    try testing.expectEqualStrings("alpha", rows[1].right.text(diff));
    try testing.expectEqualStrings("beta", rows[2].right.text(diff));
}

test "pure deletion: the removed text is on the left and the right is blank" {
    const gpa = testing.allocator;
    const diff = "@@ -1,2 +0,0 @@\n-alpha\n-beta\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(CellKind.del, rows[1].left.kind);
    try testing.expectEqualStrings("alpha", rows[1].left.text(diff));
    try testing.expectEqual(CellKind.blank, rows[1].right.kind);
    try testing.expectEqualStrings("beta", rows[2].left.text(diff));
}

test "context lines appear on both sides and a change pairs old with new" {
    const gpa = testing.allocator;
    const diff = "@@ -1,3 +1,3 @@\n ctx1\n-old\n+new\n ctx2\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // header, ctx1 (both), old|new, ctx2 (both)
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual(CellKind.context, rows[1].left.kind);
    try testing.expectEqualStrings("ctx1", rows[1].left.text(diff));
    try testing.expectEqualStrings("ctx1", rows[1].right.text(diff));

    try testing.expectEqualStrings("old", rows[2].left.text(diff));
    try testing.expectEqualStrings("new", rows[2].right.text(diff));

    try testing.expectEqualStrings("ctx2", rows[3].left.text(diff));
    try testing.expectEqualStrings("ctx2", rows[3].right.text(diff));
}

test "uneven run: two removed against one added pads the right side" {
    const gpa = testing.allocator;
    const diff = "@@ -1,2 +1,1 @@\n-a\n-b\n+c\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // header, a|c, b|<blank>
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("a", rows[1].left.text(diff));
    try testing.expectEqualStrings("c", rows[1].right.text(diff));
    try testing.expectEqualStrings("b", rows[2].left.text(diff));
    try testing.expectEqual(CellKind.blank, rows[2].right.kind);
}

test "uneven run: one removed against two added pads the left side" {
    const gpa = testing.allocator;
    const diff = "@@ -1,1 +1,2 @@\n-a\n+c\n+d\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // header, a|c, <blank>|d
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("a", rows[1].left.text(diff));
    try testing.expectEqualStrings("c", rows[1].right.text(diff));
    try testing.expectEqual(CellKind.blank, rows[2].left.kind);
    try testing.expectEqualStrings("d", rows[2].right.text(diff));
}

test "two hunks each contribute their own header row" {
    const gpa = testing.allocator;
    const diff =
        "@@ -1,1 +1,1 @@\n-a\n+b\n" ++
        "@@ -10,1 +10,1 @@\n-c\n+d\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // header, a|b, header, c|d
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual(RowKind.header, rows[0].kind);
    try testing.expectEqualStrings("@@ -1,1 +1,1 @@", rows[0].left.text(diff));
    try testing.expectEqual(RowKind.header, rows[2].kind);
    try testing.expectEqualStrings("@@ -10,1 +10,1 @@", rows[2].left.text(diff));
    try testing.expectEqualStrings("c", rows[3].left.text(diff));
    try testing.expectEqualStrings("d", rows[3].right.text(diff));
}

test "no-newline markers flag the paired cells, not a row of their own" {
    const gpa = testing.allocator;
    const diff =
        "@@ -1,1 +1,1 @@\n" ++
        "-a\n" ++
        "\\ No newline at end of file\n" ++
        "+b\n" ++
        "\\ No newline at end of file\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // header, a|b — the two `\` lines only set flags.
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("a", rows[1].left.text(diff));
    try testing.expectEqualStrings("b", rows[1].right.text(diff));
    try testing.expect(rows[1].left.no_newline);
    try testing.expect(rows[1].right.no_newline);
}

test "file line numbers: old on the left, new on the right, counting from the header" {
    const gpa = testing.allocator;
    // Old lines 4..6, new lines 4..6: a context, a change, a context.
    const diff = "@@ -4,3 +4,3 @@\n ctx\n-old\n+new\n ctx2\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // rows: header, ctx (4|4), old|new (5|5), ctx2 (6|6)
    try testing.expectEqual(@as(usize, 4), rows[1].left.old_no);
    try testing.expectEqual(@as(usize, 4), rows[1].right.new_no);
    try testing.expectEqual(@as(usize, 5), rows[2].left.old_no); // the removed line
    try testing.expectEqual(@as(usize, 0), rows[2].left.new_no);
    try testing.expectEqual(@as(usize, 5), rows[2].right.new_no); // the added line
    try testing.expectEqual(@as(usize, 0), rows[2].right.old_no);
    try testing.expectEqual(@as(usize, 6), rows[3].left.old_no);
    try testing.expectEqual(@as(usize, 6), rows[3].right.new_no);
}

test "uneven runs keep each side's own numbering" {
    const gpa = testing.allocator;
    // Two removed (old 2,3) against one added (new 2); old side continues at 4.
    const diff = "@@ -1,3 +1,2 @@\n a\n-b\n-c\n+d\n e\n";
    const rows = try rowsOf(gpa, diff);
    defer free(gpa, rows);

    // header, a(1|1), b|d (2|2), c|blank (3|0), e (4|3)
    try testing.expectEqual(@as(usize, 2), rows[2].left.old_no);
    try testing.expectEqual(@as(usize, 2), rows[2].right.new_no);
    try testing.expectEqual(@as(usize, 3), rows[3].left.old_no);
    try testing.expectEqual(CellKind.blank, rows[3].right.kind);
    try testing.expectEqual(@as(usize, 4), rows[4].left.old_no);
    try testing.expectEqual(@as(usize, 3), rows[4].right.new_no);
}

test "an empty diff yields no rows" {
    const gpa = testing.allocator;
    const rows = try rowsOf(gpa, "");
    defer free(gpa, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}
