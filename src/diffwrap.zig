//! Soft-wrap layout for the diff panels. Given the diff text (git's ANSI preview
//! or the plain staging text) and the panel's content width, `build` produces
//! the visual rows: one source line becomes one or more `Row`s, each a visual-
//! column window `[vis_start, vis_end)` of that line. The renderer draws each
//! Row by walking the whole source line but only emitting cells inside its
//! window (like a per-row horizontal offset), so ANSI colour state and the
//! word-diff character ordinals carry across wrapped rows unchanged.
//!
//! Widths must match the renderer: ANSI escapes are skipped, tabs count as four
//! columns, and each other character's width comes from `widthFn` (the same
//! `gwidth` the renderer uses), with zero-width forced to one. Wrapping is
//! greedy and breaks at the last space that fit, hard-breaking words longer than
//! the width. When wrapping is off, callers use one row per line instead (see
//! `App.mainVisualRows`), and `build` is not called.
const std = @import("std");

/// One visual row: a `[vis_start, vis_end)` column window of source line `line`,
/// whose full bytes are `text[start..end]`.
pub const Row = struct {
    line: u32,
    start: u32,
    end: u32,
    vis_start: u16,
    vis_end: u16,
};

/// Cap a single line's wrapped width so `vis_*` stay within u16 and a pathological
/// minified line can't explode the row count. Beyond this the line's tail is not
/// shown in wrap mode (use horizontal scroll for such lines).
const max_line_vis: u16 = 60000;

pub fn build(
    gpa: std.mem.Allocator,
    text: []const u8,
    content_width: u16,
    widthFn: *const fn (grapheme: []const u8) u16,
) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);
    if (content_width == 0 or text.len == 0) return rows.toOwnedSlice(gpa);

    var line_no: u32 = 0;
    var ls: usize = 0;
    while (true) {
        const le = std.mem.indexOfScalarPos(u8, text, ls, '\n') orelse text.len;
        try wrapLine(gpa, &rows, text, ls, le, line_no, content_width, widthFn);
        line_no += 1;
        if (le == text.len) break;
        ls = le + 1;
        if (ls == text.len) break; // a trailing newline is not a separate row
    }
    return rows.toOwnedSlice(gpa);
}

fn wrapLine(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    text: []const u8,
    ls: usize,
    le: usize,
    line_no: u32,
    width: u16,
    widthFn: *const fn ([]const u8) u16,
) !void {
    const start32: u32 = @intCast(ls);
    const end32: u32 = @intCast(le);
    var seg_start: u16 = 0;
    var vis: u16 = 0;
    var break_vis: u16 = 0; // column just past the last space in this segment
    var have_break = false;

    var i: usize = ls;
    while (i < le) {
        const b = text[i];
        if (b == 0x1b) { // skip a CSI escape (ANSI colour); it draws nothing
            if (i + 1 < le and text[i + 1] == '[') {
                var j = i + 2;
                while (j < le and !(text[j] >= 0x40 and text[j] <= 0x7e)) j += 1;
                i = if (j < le) j + 1 else le;
            } else {
                i += 1;
            }
            continue;
        }
        if (b == '\r') {
            i += 1;
            continue;
        }
        var cw: u16 = 1;
        var clen: usize = 1;
        if (b == '\t') {
            cw = 4;
        } else if (b >= 0x80) {
            clen = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + clen > le) clen = 1;
            const w = widthFn(text[i .. i + clen]);
            cw = if (w == 0) 1 else w;
        }

        // Break before a char that would overrun the segment (but never on an
        // empty segment: a single too-wide char is placed and overflows).
        if (vis > seg_start and vis + cw > seg_start + width) {
            const at = if (have_break and break_vis > seg_start) break_vis else vis;
            try rows.append(gpa, .{ .line = line_no, .start = start32, .end = end32, .vis_start = seg_start, .vis_end = at });
            seg_start = at;
            have_break = false;
        }
        if (vis >= max_line_vis) break; // guard pathological lines

        // Break only on spaces (not tabs), so leading indentation stays attached
        // to its line's content instead of getting a row of its own.
        if (b == ' ') {
            break_vis = vis + 1;
            have_break = true;
        }
        vis += cw;
        i += clen;
    }
    // Final segment (also the sole row for an empty line: vis == seg_start == 0).
    try rows.append(gpa, .{ .line = line_no, .start = start32, .end = end32, .vis_start = seg_start, .vis_end = vis });
}

const testing = std.testing;

/// Test width: ASCII = 1; a leading byte >= 0xF0 (our stand-in for a wide char) = 2.
fn testWidth(g: []const u8) u16 {
    if (g.len > 0 and g[0] >= 0xf0) return 2;
    return 1;
}

test "no wrap when the line fits" {
    const a = testing.allocator;
    const rows = try build(a, "hello world", 40, testWidth);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u16, 0), rows[0].vis_start);
    try testing.expectEqual(@as(u16, 11), rows[0].vis_end);
}

test "wraps at the last space that fits" {
    const a = testing.allocator;
    // width 5: "aa " fits, then "bb cc" fills the next row exactly.
    const rows = try build(a, "aa bb cc", 5, testWidth);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(u16, 0), rows[0].vis_start);
    try testing.expectEqual(@as(u16, 3), rows[0].vis_end); // "aa "
    try testing.expectEqual(@as(u16, 3), rows[1].vis_start);
    try testing.expectEqual(@as(u16, 8), rows[1].vis_end); // "bb cc"
}

test "hard-breaks a word longer than the width" {
    const a = testing.allocator;
    const rows = try build(a, "abcdefghij", 4, testWidth);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(u16, 4), rows[0].vis_end);
    try testing.expectEqual(@as(u16, 8), rows[1].vis_end);
    try testing.expectEqual(@as(u16, 10), rows[2].vis_end);
}

test "multiple source lines keep their indices; empty line is one row" {
    const a = testing.allocator;
    const rows = try build(a, "ab\n\ncd", 10, testWidth);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(u32, 0), rows[0].line);
    try testing.expectEqual(@as(u32, 1), rows[1].line); // empty line
    try testing.expectEqual(@as(u16, 0), rows[1].vis_end);
    try testing.expectEqual(@as(u32, 2), rows[2].line);
}

test "tabs count as four columns" {
    const a = testing.allocator;
    // "\tab" -> visual width 6; at width 5 it wraps after the tab boundary.
    const rows = try build(a, "\tabcd", 5, testWidth);
    defer a.free(rows);
    // tab(4) + "a"(1) = 5 fits; "b" overflows, no space to break on -> hard break.
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(u16, 5), rows[0].vis_end);
}

test "ANSI escapes do not consume visual width" {
    const a = testing.allocator;
    // The colour codes are zero-width; "hi" is 2 columns, fits in one row.
    const rows = try build(a, "\x1b[32mhi\x1b[m", 10, testWidth);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u16, 2), rows[0].vis_end);
}

test "wide characters take two columns" {
    const a = testing.allocator;
    // Two wide chars (2 cols each) = 4 cols; width 3 -> wrap after the first.
    const rows = try build(a, "\xf0\x9f\x9a\x80\xf0\x9f\x8e\x89", 3, testWidth);
    defer a.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(u16, 2), rows[0].vis_end); // first wide char (2 cols)
    try testing.expectEqual(@as(u16, 4), rows[1].vis_end);
}
