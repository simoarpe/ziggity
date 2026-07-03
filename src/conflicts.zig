//! Per-conflict merge resolution: parse a conflicted working-tree file into its
//! `<<<<<<< / ||||||| / ======= / >>>>>>>` blocks, navigate between them, and
//! pick ours / theirs / both for each — rewriting the file in place. A per-file
//! undo stack lets each pick be reverted. Free functions over `*App`; the state
//! (parsed conflicts, content, undo stack) lives on App.
const std = @import("std");

const app_mod = @import("app.zig");
const vaxis = @import("vaxis");

const App = app_mod.App;

/// One conflict block, addressed by 0-based line index. `ancestor` is the
/// `|||||||` base line (diff3 mode) or null.
pub const Conflict = struct {
    start: usize, // `<<<<<<<`
    ancestor: ?usize, // `|||||||` (diff3) or null
    target: usize, // `=======`
    end: usize, // `>>>>>>>`
};

/// Which side(s) of a conflict to keep. `both` keeps ours then theirs (dropping
/// the diff3 base and all markers).
pub const Choice = enum { ours, theirs, both };

fn isStart(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "<<<<<<<");
}
fn isAncestor(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "|||||||");
}
fn isTarget(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "=======");
}
fn isEnd(l: []const u8) bool {
    return std.mem.startsWith(u8, l, ">>>>>>>");
}

/// True for any of the four conflict marker lines — used by the renderer to
/// colour them.
pub fn isMarkerLine(l: []const u8) bool {
    return isStart(l) or isAncestor(l) or isTarget(l) or isEnd(l);
}

/// Byte range [start, end) of each line — `end` is *after* the trailing `\n`,
/// so concatenating kept ranges reproduces the file byte-for-byte.
const LineRange = struct { start: usize, end: usize };

fn lineRanges(allocator: std.mem.Allocator, content: []const u8) ![]LineRange {
    var ranges: std.ArrayList(LineRange) = .empty;
    errdefer ranges.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n');
        const end = if (nl) |n| n + 1 else content.len;
        try ranges.append(allocator, .{ .start = i, .end = end });
        i = end;
    }
    return ranges.toOwnedSlice(allocator);
}

/// The text of line `r` with its trailing newline (and CR) stripped, for marker
/// detection.
fn lineText(content: []const u8, r: LineRange) []const u8 {
    var e = r.end;
    if (e > r.start and content[e - 1] == '\n') e -= 1;
    if (e > r.start and content[e - 1] == '\r') e -= 1;
    return content[r.start..e];
}

/// Parse every conflict block in `content`. Malformed/nested blocks are skipped.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]Conflict {
    const ranges = try lineRanges(allocator, content);
    defer allocator.free(ranges);

    var conflicts: std.ArrayList(Conflict) = .empty;
    errdefer conflicts.deinit(allocator);

    var i: usize = 0;
    while (i < ranges.len) : (i += 1) {
        if (!isStart(lineText(content, ranges[i]))) continue;
        const start = i;
        var ancestor: ?usize = null;
        var target: ?usize = null;
        var end: ?usize = null;
        var j = start + 1;
        while (j < ranges.len) : (j += 1) {
            const t = lineText(content, ranges[j]);
            if (isStart(t)) break; // another start before we closed — malformed
            if (target == null and ancestor == null and isAncestor(t)) {
                ancestor = j;
            } else if (target == null and isTarget(t)) {
                target = j;
            } else if (target != null and isEnd(t)) {
                end = j;
                break;
            }
        }
        if (target != null and end != null) {
            try conflicts.append(allocator, .{ .start = start, .ancestor = ancestor, .target = target.?, .end = end.? });
            i = end.?; // resume after this conflict
        }
    }
    return conflicts.toOwnedSlice(allocator);
}

/// True if line `idx` survives resolving conflict `c` with `choice`.
fn keepLine(c: Conflict, choice: Choice, idx: usize) bool {
    if (idx < c.start or idx > c.end) return true; // outside the conflict: keep
    // Marker lines are always dropped.
    if (idx == c.start or idx == c.target or idx == c.end) return false;
    if (c.ancestor) |a| if (idx == a) return false;

    const ours_end = c.ancestor orelse c.target; // ours = (start, ancestor|target)
    const in_ours = idx > c.start and idx < ours_end;
    const in_theirs = idx > c.target and idx < c.end;
    return switch (choice) {
        .ours => in_ours,
        .theirs => in_theirs,
        .both => in_ours or in_theirs, // ours then theirs, base dropped
    };
}

/// New file content after resolving conflict `c` with `choice` (owned). Other
/// conflicts are left untouched.
pub fn resolveContent(allocator: std.mem.Allocator, content: []const u8, c: Conflict, choice: Choice) ![]u8 {
    const ranges = try lineRanges(allocator, content);
    defer allocator.free(ranges);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (ranges, 0..) |r, idx| {
        if (keepLine(c, choice, idx)) try out.appendSlice(allocator, content[r.start..r.end]);
    }
    return out.toOwnedSlice(allocator);
}

// --- App-facing interactive layer ---

/// `enter` on a conflicted file: read it, parse its conflicts, and open the
/// resolution view. Falls back with a message if it has no inline markers.
pub fn open(app: *App, path: []const u8) !void {
    const content = app.git.readWorkingFile(path) catch {
        try app.setMessage("could not read {s}", .{path});
        return;
    };
    const parsed = parse(app.allocator, content) catch {
        app.allocator.free(content);
        try app.setMessage("could not parse conflicts", .{});
        return;
    };
    if (parsed.len == 0) {
        app.allocator.free(content);
        app.allocator.free(parsed);
        try app.setMessage("no conflict markers in {s} — resolve via m", .{path});
        return;
    }
    close(app); // clear any previous session
    app.conflict_path = try app.allocator.dupe(u8, path);
    app.conflict_content = content;
    app.conflicts = parsed;
    app.conflict_index = 0;
    app.mode = .conflict_resolve;
    try app.setMessage("resolving {s}: o ours / t theirs / b both / u undo / esc back", .{path});
}

/// Free the conflict session state (safe when none is active).
pub fn close(app: *App) void {
    app.allocator.free(app.conflict_path);
    app.conflict_path = &.{};
    app.allocator.free(app.conflict_content);
    app.conflict_content = &.{};
    app.allocator.free(app.conflicts);
    app.conflicts = &.{};
    for (app.conflict_undo.items) |c| app.allocator.free(c);
    app.conflict_undo.clearRetainingCapacity();
    app.conflict_index = 0;
}

pub fn cancel(app: *App) !void {
    close(app);
    app.mode = .normal;
    try app.updatePreview();
}

/// Move the current-conflict cursor between conflicts.
pub fn move(app: *App, down: bool) void {
    if (app.conflicts.len == 0) return;
    if (down) {
        if (app.conflict_index + 1 < app.conflicts.len) app.conflict_index += 1;
    } else {
        app.conflict_index -|= 1;
    }
}

/// Resolve the current conflict with `choice`: rewrite the file, push the old
/// content for undo, and re-parse. When the last conflict is resolved, stage
/// the file and return to the Files panel.
pub fn pick(app: *App, choice: Choice) !void {
    if (app.conflicts.len == 0) return;
    const idx = @min(app.conflict_index, app.conflicts.len - 1);
    const new_content = try resolveContent(app.allocator, app.conflict_content, app.conflicts[idx], choice);
    errdefer app.allocator.free(new_content);
    app.git.writeWorkingFile(app.conflict_path, new_content) catch {
        app.allocator.free(new_content);
        try app.setMessage("could not write {s}", .{app.conflict_path});
        return;
    };
    try app.conflict_undo.append(app.allocator, app.conflict_content); // old content owns the stack slot
    app.conflict_content = new_content;
    try reparse(app);
    if (app.conflicts.len == 0) return finish(app);
    try app.setMessage("{d} conflict(s) left in {s}", .{ app.conflicts.len, app.conflict_path });
}

/// Undo the last pick: restore the previous content and re-parse.
pub fn undo(app: *App) !void {
    if (app.conflict_undo.items.len == 0) {
        try app.setMessage("nothing to undo", .{});
        return;
    }
    const prev = app.conflict_undo.pop().?;
    app.allocator.free(app.conflict_content);
    app.conflict_content = prev;
    app.git.writeWorkingFile(app.conflict_path, prev) catch {};
    try reparse(app);
    try app.setMessage("undid pick — {d} conflict(s) left", .{app.conflicts.len});
}

fn reparse(app: *App) !void {
    const parsed = try parse(app.allocator, app.conflict_content);
    app.allocator.free(app.conflicts);
    app.conflicts = parsed;
    if (app.conflicts.len > 0 and app.conflict_index >= app.conflicts.len) {
        app.conflict_index = app.conflicts.len - 1;
    } else if (app.conflicts.len == 0) {
        app.conflict_index = 0;
    }
}

/// All conflicts resolved: stage the file and leave the view.
fn finish(app: *App) !void {
    const path = try app.allocator.dupe(u8, app.conflict_path);
    defer app.allocator.free(path);
    close(app);
    app.mode = .normal;
    return app.runMutationFiles(try app.git.stagePaths(&.{path}), "resolved {s}", .{path});
}

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const km = app.config.keymap;
    if (app.isDialogCloseKey(key)) return cancel(app);
    if (km.up.matches(key) or key.matches(vaxis.Key.up, .{})) return move(app, false);
    if (km.down.matches(key) or key.matches(vaxis.Key.down, .{})) return move(app, true);
    if (matchesChar(key, 'o')) return pick(app, .ours);
    if (matchesChar(key, 't')) return pick(app, .theirs);
    if (matchesChar(key, 'b')) return pick(app, .both);
    if (matchesChar(key, 'u')) return undo(app);
}

fn matchesChar(key: vaxis.Key, c: u21) bool {
    return key.matches(c, .{});
}

const testing = std.testing;

const sample_2way =
    "line 1\n" ++
    "<<<<<<< HEAD\n" ++
    "ours a\n" ++
    "ours b\n" ++
    "=======\n" ++
    "theirs a\n" ++
    ">>>>>>> branch\n" ++
    "line 8\n";

test "parse finds a single 2-way conflict" {
    const c = try parse(testing.allocator, sample_2way);
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(@as(usize, 1), c[0].start);
    try testing.expectEqual(@as(?usize, null), c[0].ancestor);
    try testing.expectEqual(@as(usize, 4), c[0].target);
    try testing.expectEqual(@as(usize, 6), c[0].end);
}

test "resolveContent ours/theirs/both" {
    const c = try parse(testing.allocator, sample_2way);
    defer testing.allocator.free(c);

    const ours = try resolveContent(testing.allocator, sample_2way, c[0], .ours);
    defer testing.allocator.free(ours);
    try testing.expectEqualStrings("line 1\nours a\nours b\nline 8\n", ours);

    const theirs = try resolveContent(testing.allocator, sample_2way, c[0], .theirs);
    defer testing.allocator.free(theirs);
    try testing.expectEqualStrings("line 1\ntheirs a\nline 8\n", theirs);

    const both = try resolveContent(testing.allocator, sample_2way, c[0], .both);
    defer testing.allocator.free(both);
    try testing.expectEqualStrings("line 1\nours a\nours b\ntheirs a\nline 8\n", both);
}

test "parse handles diff3 ancestor and multiple conflicts" {
    const src =
        "<<<<<<< HEAD\n" ++
        "ours\n" ++
        "||||||| base\n" ++
        "orig\n" ++
        "=======\n" ++
        "theirs\n" ++
        ">>>>>>> b\n" ++
        "mid\n" ++
        "<<<<<<< HEAD\n" ++
        "x\n" ++
        "=======\n" ++
        "y\n" ++
        ">>>>>>> b\n";
    const c = try parse(testing.allocator, src);
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqual(@as(?usize, 2), c[0].ancestor);
    // ours drops the diff3 base region.
    const ours = try resolveContent(testing.allocator, src, c[0], .ours);
    defer testing.allocator.free(ours);
    try testing.expectEqualStrings("ours\nmid\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n", ours);
}

test "parse ignores content without markers" {
    const c = try parse(testing.allocator, "just\nplain\ntext\n");
    defer testing.allocator.free(c);
    try testing.expectEqual(@as(usize, 0), c.len);
}
