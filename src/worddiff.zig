//! Word-level (intra-line) diff refinement, delta/GitHub style: within a changed
//! `-`/`+` line pair, find the words that actually differ so the renderer can
//! emphasize just those instead of painting the whole line.
//!
//! `build` takes a full unified diff (git's ANSI-coloured preview text or the
//! plain `--no-color` staging text), pairs each block of removed lines with the
//! added lines that follow, and returns, per diff line, the spans to emphasize.
//!
//! Spans are in CHARACTER ORDINALS, not visual columns: one unit per rendered
//! codepoint, matching how `tui.printAnsiEmph` draws (one cell per codepoint via
//! `decodeCell`). Counting characters rather than widths keeps the emphasis
//! aligned through wide characters (CJK, emoji = 2 columns), combining marks and
//! zero-width codepoints, since both sides step character by character whatever
//! each one's on-screen width. ANSI is stripped, tabs expand to four, and the
//! leading `+`/`-` marker is ordinal 0 (so content starts at ordinal 1).
//! Everything is best-effort: on any allocation failure or a pair too dissimilar
//! to refine usefully, the line simply gets no spans and renders as before.
const std = @import("std");

/// A half-open character-ordinal range `[start, end)` to emphasize on one line.
pub const Span = struct { start: u16, end: u16 };

/// Per-line emphasis: which changed-word column spans to highlight, and whether
/// this is an added (green) or removed (red) line so the renderer picks the
/// matching background. `spans` empty means no word-level highlight for the line.
pub const Emph = struct {
    added: bool = false,
    spans: []Span = &.{},
};

const Kind = enum { removed, added, other };

const tab_width = 4; // must match tui.printAnsi's fixed tab expansion
/// Skip refinement past these bounds — a full DP over huge lines/blocks is not
/// worth it, and a near-total rewrite reads better as plain line-level colour.
const max_line_cols = 4096;
const max_tokens = 128;
/// Minimum fraction of shared content for a pair to be worth refining; below
/// this the two lines are basically unrelated and highlighting is just noise.
const min_similarity = 0.25;

/// Per-line emphasis for a whole diff, indexed by line number. Owned by the
/// caller; free with `free`.
pub fn build(gpa: std.mem.Allocator, text: []const u8) ![]Emph {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    const out = try gpa.alloc(Emph, lines.items.len);
    for (out) |*e| e.* = .{};
    errdefer free(gpa, out);

    // Plain (ANSI-stripped, tab-expanded, marker-dropped) content per line, plus
    // its polarity. Built once so pairing and refinement share it.
    const plains = try gpa.alloc([]u8, lines.items.len);
    const kinds = try gpa.alloc(Kind, lines.items.len);
    defer {
        for (plains) |p| gpa.free(p);
        gpa.free(plains);
        gpa.free(kinds);
    }
    for (lines.items, 0..) |line, i| {
        const stripped = try stripAnsi(gpa, line);
        defer gpa.free(stripped);
        kinds[i] = classify(stripped);
        // Drop the leading marker for -/+ lines; keep the rest for context.
        const body = if (kinds[i] == .other) stripped else stripped[1..];
        plains[i] = try expandTabs(gpa, body);
    }

    // Pair each run of removed lines with the run of added lines that follows,
    // by position, and refine the overlap.
    var i: usize = 0;
    while (i < lines.items.len) {
        if (kinds[i] != .removed) {
            i += 1;
            continue;
        }
        const rs = i;
        while (i < lines.items.len and kinds[i] == .removed) i += 1;
        const as = i;
        while (i < lines.items.len and kinds[i] == .added) i += 1;
        const r = as - rs;
        const a = i - as;
        var k: usize = 0;
        while (k < r and k < a) : (k += 1) {
            out[rs + k].added = false;
            out[as + k].added = true;
            refinePair(gpa, plains[rs + k], plains[as + k], &out[rs + k].spans, &out[as + k].spans);
        }
    }
    return out;
}

pub fn free(gpa: std.mem.Allocator, lines: []Emph) void {
    for (lines) |e| if (e.spans.len > 0) gpa.free(e.spans);
    if (lines.len > 0) gpa.free(lines);
}

/// Refine one removed/added content pair, writing marker-offset (+1) spans into
/// `out_old`/`out_new`. Best-effort: leaves them empty on any failure.
fn refinePair(gpa: std.mem.Allocator, old: []const u8, new: []const u8, out_old: *[]Span, out_new: *[]Span) void {
    if (old.len > max_line_cols or new.len > max_line_cols) return;
    if (std.mem.eql(u8, old, new)) return;

    const a_toks = tokenize(gpa, old) catch return;
    defer gpa.free(a_toks);
    const b_toks = tokenize(gpa, new) catch return;
    defer gpa.free(b_toks);
    if (a_toks.len == 0 or b_toks.len == 0) return;
    if (a_toks.len > max_tokens or b_toks.len > max_tokens) return;

    const a_changed = gpa.alloc(bool, a_toks.len) catch return;
    defer gpa.free(a_changed);
    const b_changed = gpa.alloc(bool, b_toks.len) catch return;
    defer gpa.free(b_changed);
    const shared = lcsChanged(gpa, old, new, a_toks, b_toks, a_changed, b_changed) catch return;

    // Similarity guard: skip near-unrelated pairs.
    const denom: f32 = @floatFromInt(@max(old.len, new.len));
    if (denom == 0 or (@as(f32, @floatFromInt(shared)) / denom) < min_similarity) return;

    out_old.* = spansFromChanged(gpa, a_toks, a_changed) catch return;
    out_new.* = spansFromChanged(gpa, b_toks, b_changed) catch {
        gpa.free(out_old.*);
        out_old.* = &.{};
        return;
    };
}

/// A token: `byte_start..byte_end` locates its text in the content (for equality
/// comparison); `col_start..col_end` is its span in visual columns. The two
/// differ whenever the content holds multibyte UTF-8 (e.g. an em dash), which
/// takes several bytes but one screen column, so spans must track columns to
/// line up with the renderer.
const Tok = struct { col_start: u16, col_end: u16, byte_start: u32, byte_end: u32 };

/// Split content into tokens: runs of word chars ([A-Za-z0-9_]), runs of
/// whitespace, and every other codepoint on its own. Content is tab-expanded and
/// ANSI-free; columns advance one per codepoint to match the renderer, which
/// draws one cell per character.
fn tokenize(gpa: std.mem.Allocator, s: []const u8) ![]Tok {
    var toks: std.ArrayList(Tok) = .empty;
    errdefer toks.deinit(gpa);
    var i: usize = 0; // byte index
    var col: u16 = 0; // visual column
    while (i < s.len) {
        const byte_start = i;
        const col_start = col;
        const class = charClass(s[i]);
        if (class == .word or class == .space) {
            // A run of ASCII word/space (a multibyte lead byte is >= 0x80, so it
            // classifies as punct and ends the run here).
            while (i < s.len and charClass(s[i]) == class) {
                i += 1;
                col += 1;
            }
        } else {
            // One codepoint (ASCII punctuation or a whole multibyte char) is one
            // token and one column.
            const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            i += @min(@as(usize, l), s.len - i);
            col += 1;
        }
        try toks.append(gpa, .{
            .col_start = col_start,
            .col_end = col,
            .byte_start = @intCast(byte_start),
            .byte_end = @intCast(i),
        });
    }
    return toks.toOwnedSlice(gpa);
}

const CharClass = enum { word, space, punct };
fn charClass(c: u8) CharClass {
    if (c == ' ' or c == '\t') return .space;
    if (c == '_' or std.ascii.isAlphanumeric(c)) return .word;
    return .punct;
}

/// Mark each token changed/common via a longest-common-subsequence backtrace,
/// returning the number of shared content bytes (for the similarity guard).
fn lcsChanged(gpa: std.mem.Allocator, a_src: []const u8, b_src: []const u8, a: []const Tok, b: []const Tok, a_changed: []bool, b_changed: []bool) !usize {
    const n = a.len;
    const m = b.len;
    @memset(a_changed, true);
    @memset(b_changed, true);
    // dp[(n+1) x (m+1)] filled from the bottom-right; dp[i*(m+1)+j] = LCS length
    // of a[i..], b[j..].
    const dp = try gpa.alloc(u16, (n + 1) * (m + 1));
    defer gpa.free(dp);
    const w = m + 1;
    @memset(dp[n * w ..], 0);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        dp[i * w + m] = 0;
        var j: usize = m;
        while (j > 0) {
            j -= 1;
            if (tokEql(a_src, b_src, a[i], b[j])) {
                dp[i * w + j] = dp[(i + 1) * w + (j + 1)] + 1;
            } else {
                dp[i * w + j] = @max(dp[(i + 1) * w + j], dp[i * w + (j + 1)]);
            }
        }
    }
    var shared: usize = 0;
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (tokEql(a_src, b_src, a[i], b[j])) {
            a_changed[i] = false;
            b_changed[j] = false;
            shared += a[i].col_end - a[i].col_start;
            i += 1;
            j += 1;
        } else if (dp[(i + 1) * w + j] >= dp[i * w + (j + 1)]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return shared;
}

fn tokEql(a_src: []const u8, b_src: []const u8, a: Tok, b: Tok) bool {
    return std.mem.eql(u8, a_src[a.byte_start..a.byte_end], b_src[b.byte_start..b.byte_end]);
}

/// Merge consecutive changed tokens into marker-offset (+1) visual-column spans.
fn spansFromChanged(gpa: std.mem.Allocator, toks: []const Tok, changed: []const bool) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    var k: usize = 0;
    while (k < toks.len) {
        if (!changed[k]) {
            k += 1;
            continue;
        }
        const start = toks[k].col_start;
        var end = toks[k].col_end;
        k += 1;
        while (k < toks.len and changed[k]) : (k += 1) end = toks[k].col_end;
        try spans.append(gpa, .{ .start = start + 1, .end = end + 1 }); // +1: leading marker
    }
    return spans.toOwnedSlice(gpa);
}

/// Remove ANSI escape sequences (git colours) and carriage returns.
fn stripAnsi(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, line.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == 0x1b) {
            if (i + 1 < line.len and line[i + 1] == '[') {
                var j = i + 2;
                while (j < line.len and !(line[j] >= 0x40 and line[j] <= 0x7e)) j += 1;
                i = if (j < line.len) j + 1 else line.len;
            } else {
                i += 1;
            }
            continue;
        }
        if (c == '\r') {
            i += 1;
            continue;
        }
        out[n] = c;
        n += 1;
        i += 1;
    }
    return gpa.realloc(out, n);
}

/// Expand each tab to `tab_width` spaces, matching printAnsi, so column offsets
/// line up with the rendered cells.
fn expandTabs(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const tabs = std.mem.count(u8, s, "\t");
    if (tabs == 0) return gpa.dupe(u8, s);
    var out = try gpa.alloc(u8, s.len + tabs * (tab_width - 1));
    var n: usize = 0;
    for (s) |c| {
        if (c == '\t') {
            @memset(out[n .. n + tab_width], ' ');
            n += tab_width;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

fn classify(stripped: []const u8) Kind {
    if (std.mem.startsWith(u8, stripped, "-") and !std.mem.startsWith(u8, stripped, "---")) return .removed;
    if (std.mem.startsWith(u8, stripped, "+") and !std.mem.startsWith(u8, stripped, "+++")) return .added;
    return .other;
}

const testing = std.testing;

test "refinePair highlights only the changed token" {
    const a = testing.allocator;
    var old: []Span = &.{};
    var new: []Span = &.{};
    defer if (old.len > 0) a.free(old);
    defer if (new.len > 0) a.free(new);
    // content (marker already dropped): "const x = 30;" vs "const x = 45;"
    refinePair(a, "const x = 30;", "const x = 45;", &old, &new);
    // "30" and "45" differ; each is one span, offset by the +1 marker column.
    try testing.expectEqual(@as(usize, 1), old.len);
    try testing.expectEqual(@as(usize, 1), new.len);
    // "30" starts at content col 10 -> visual col 11.
    try testing.expectEqual(@as(u16, 11), old[0].start);
    try testing.expectEqual(@as(u16, 13), old[0].end);
    try testing.expectEqual(@as(u16, 11), new[0].start);
    try testing.expectEqual(@as(u16, 13), new[0].end);
}

test "refinePair finds two separate changed words" {
    const a = testing.allocator;
    var old: []Span = &.{};
    var new: []Span = &.{};
    defer if (old.len > 0) a.free(old);
    defer if (new.len > 0) a.free(new);
    refinePair(a, "dial(host, .tcp, 30)", "dial(host, .quic, 45)", &old, &new);
    // "tcp"->"quic" and "30"->"45": two spans on each side.
    try testing.expectEqual(@as(usize, 2), old.len);
    try testing.expectEqual(@as(usize, 2), new.len);
}

test "refinePair skips near-unrelated lines (similarity guard)" {
    const a = testing.allocator;
    var old: []Span = &.{};
    var new: []Span = &.{};
    defer if (old.len > 0) a.free(old);
    defer if (new.len > 0) a.free(new);
    refinePair(a, "completely different old line here", "xyz 123 !@# totally other", &old, &new);
    try testing.expectEqual(@as(usize, 0), old.len);
    try testing.expectEqual(@as(usize, 0), new.len);
}

test "refinePair leaves identical content unmarked" {
    const a = testing.allocator;
    var old: []Span = &.{};
    var new: []Span = &.{};
    defer if (old.len > 0) a.free(old);
    defer if (new.len > 0) a.free(new);
    refinePair(a, "same line", "same line", &old, &new);
    try testing.expectEqual(@as(usize, 0), old.len);
    try testing.expectEqual(@as(usize, 0), new.len);
}

test "build pairs a -/+ block and offsets spans by the marker" {
    const a = testing.allocator;
    const diff =
        "@@ -1,1 +1,1 @@\n" ++
        "-const timeout = 30;\n" ++
        "+const timeout = 45;\n";
    const lines = try build(a, diff);
    defer free(a, lines);
    try testing.expectEqual(@as(usize, 4), lines.len); // 3 lines + trailing empty
    try testing.expectEqual(@as(usize, 0), lines[0].spans.len); // hunk header
    try testing.expectEqual(@as(usize, 1), lines[1].spans.len); // removed line
    try testing.expectEqual(@as(usize, 1), lines[2].spans.len); // added line
    try testing.expect(!lines[1].added); // removed -> red
    try testing.expect(lines[2].added); // added -> green
    // "30" is at content col 16 -> visual col 17 (after the '-' marker).
    try testing.expectEqual(@as(u16, 17), lines[1].spans[0].start);
    try testing.expectEqual(@as(u16, 19), lines[1].spans[0].end);
}

test "refinePair counts a multibyte char as one column, not its bytes" {
    const a = testing.allocator;
    var old: []Span = &.{};
    var new: []Span = &.{};
    defer if (old.len > 0) a.free(old);
    defer if (new.len > 0) a.free(new);
    // An em dash (U+2014, 3 bytes, 1 column) precedes the inserted words. The
    // insertion "new " sits at visual columns 2..6 -> spans 3..7 after the '+'
    // marker; a byte-offset bug would push it right by the em dash's extra bytes.
    refinePair(a, "# \u{2014} tail", "# \u{2014} new tail", &old, &new);
    try testing.expectEqual(@as(usize, 0), old.len); // pure insertion: nothing removed
    try testing.expectEqual(@as(usize, 1), new.len);
    try testing.expectEqual(@as(u16, 5), new[0].start); // content col 4 (+1 marker)
    try testing.expectEqual(@as(u16, 9), new[0].end); // "new " -> 4 cols
}

test "refinePair counts a wide (CJK) char as one ordinal, not two columns" {
    const a = testing.allocator;
    var old: []Span = &.{};
    var new: []Span = &.{};
    defer if (old.len > 0) a.free(old);
    defer if (new.len > 0) a.free(new);
    // A wide CJK char (U+4F60, renders 2 columns but is one character) precedes
    // the change, counted as a single ordinal. Content ordinals: "你"=0, " "=1,
    // "v1"=2..4 (one word token). "v1"->"v2" is the change, so the span is
    // ordinals 2..4, +1 for the marker => 3..5, regardless of the CJK width.
    refinePair(a, "\u{4F60} v1", "\u{4F60} v2", &old, &new);
    try testing.expectEqual(@as(usize, 1), old.len);
    try testing.expectEqual(@as(usize, 1), new.len);
    try testing.expectEqual(@as(u16, 3), new[0].start);
    try testing.expectEqual(@as(u16, 5), new[0].end);
}

test "build expands tabs so spans line up with the renderer" {
    const a = testing.allocator;
    // A tab of indentation (4 cols) then a one-token change.
    const diff = "-\tx = 30\n+\tx = 45\n";
    const lines = try build(a, diff);
    defer free(a, lines);
    // content after marker: "\tx = 30" -> "    x = 30"; "30" at cols 8..10,
    // visual cols 9..11 after the marker.
    try testing.expectEqual(@as(usize, 1), lines[0].spans.len);
    try testing.expectEqual(@as(u16, 9), lines[0].spans[0].start);
    try testing.expectEqual(@as(u16, 11), lines[0].spans[0].end);
}
