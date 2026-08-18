//! Inline commit-graph lanes for the Commits panel: a `git log --graph`-style
//! DAG rendered one row per commit, computed from each commit's parent hashes.
//!
//! Ported from jesseduffield's TUI git client (`pkg/gui/presentation/graph`):
//! the pipe-set topology algorithm (`getNextPipes`), the pipe→cell renderer
//! (`renderPipeSet`), and the box-drawing table (`getBoxDrawingChars`).
//!
//! Two phases:
//!   1. `build` computes the pipe set for every commit once (topology + the
//!      per-pipe colour, taken from the author of the commit that started it).
//!   2. `renderRow` turns one commit's pipe set into terminal cells on demand —
//!      cheap enough to run per visible row each frame, and it applies the
//!      moving selected-commit highlight there rather than in the cached data.

const std = @import("std");
const model = @import("model.zig");

/// The most lanes we render. A busy repo can spike wide; beyond this the narrow
/// Commits panel is unusable anyway, so we clamp instead of unbounded growth.
pub const max_lanes: usize = 48;

pub const PipeKind = enum(u2) { terminates, starts, continues };

pub const Pipe = struct {
    from_pos: i16,
    to_pos: i16,
    /// Hash of the commit the pipe originates from (used to match the selection).
    from_hash: []const u8,
    /// Hash of the target parent (matched against commit hashes to terminate).
    to_hash: []const u8,
    kind: PipeKind,
    /// 256-colour palette index — the author colour of the commit that started
    /// this lane, inherited as the lane continues down.
    fg: u8,

    fn left(self: Pipe) i16 {
        return @min(self.from_pos, self.to_pos);
    }
    fn right(self: Pipe) i16 {
        return @max(self.from_pos, self.to_pos);
    }
};

/// A sentinel that never equals a real commit hash (the seed pipe's source, and
/// a root commit's "parent").
const no_hash = "\x01";

fn eqHash(a: []const u8, b: []const u8) bool {
    return a.len > 0 and std.mem.eql(u8, a, b);
}

/// The cached graph: one pipe slice per commit, in the same order as the commit
/// list it was built from.
pub const Graph = struct {
    sets: [][]Pipe,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Graph) void {
        for (self.sets) |s| self.allocator.free(s);
        self.allocator.free(self.sets);
        self.* = undefined;
    }
};

/// Build the pipe sets for `commits` (newest first, as `git log` returns them).
pub fn build(allocator: std.mem.Allocator, commits: []const model.Commit) !Graph {
    if (commits.len == 0) return .{ .sets = &.{}, .allocator = allocator };

    const sets = try allocator.alloc([]Pipe, commits.len);
    var built: usize = 0;
    errdefer {
        for (sets[0..built]) |s| allocator.free(s);
        allocator.free(sets);
    }

    // Seed: a single STARTS pipe feeding the newest commit, coloured like it so
    // HEAD's node takes its own author colour.
    var seed = [_]Pipe{.{
        .from_pos = 0,
        .to_pos = 0,
        .from_hash = no_hash,
        .to_hash = commits[0].hash,
        .kind = .starts,
        .fg = model.authorColorIndex(commits[0].author),
    }};
    var prev: []const Pipe = seed[0..];

    for (commits, 0..) |commit, i| {
        const next = try getNextPipes(allocator, prev, commit);
        sets[i] = next;
        built = i + 1;
        prev = next;
    }

    return .{ .sets = sets, .allocator = allocator };
}

const PosSet = std.AutoHashMapUnmanaged(i16, void);

fn getNextPipes(allocator: std.mem.Allocator, prev: []const Pipe, commit: model.Commit) ![]Pipe {
    var max_pos: i16 = 0;
    for (prev) |pipe| {
        if (pipe.to_pos > max_pos) max_pos = pipe.to_pos;
    }

    var pipes: std.ArrayList(Pipe) = .empty;
    errdefer pipes.deinit(allocator);

    const fg = model.authorColorIndex(commit.author);

    // The commit's node position: reuse the first pipe ending on it, else a new
    // far-right lane (only happens under `--all`, which we don't use, but keep).
    var pos: i16 = max_pos + 1;
    for (prev) |pipe| {
        if (pipe.kind == .terminates) continue;
        if (eqHash(pipe.to_hash, commit.hash)) {
            pos = pipe.to_pos;
            break;
        }
    }

    var taken: PosSet = .empty;
    defer taken.deinit(allocator);
    var traversed: PosSet = .empty;
    defer traversed.deinit(allocator);
    var traversed_cont: PosSet = .empty; // spots continuing (non-terminating) pipes occupy
    defer traversed_cont.deinit(allocator);
    for (prev) |pipe| {
        if (pipe.kind == .terminates) continue;
        if (!eqHash(pipe.to_hash, commit.hash)) try traversed_cont.put(allocator, pipe.to_pos, {});
    }

    // The commit's main pipe, heading to its first parent (or nowhere for a root).
    const first_parent: []const u8 = if (commit.parents.len == 0) no_hash else commit.parents[0];
    try pipes.append(allocator, .{
        .from_pos = pos,
        .to_pos = pos,
        .from_hash = commit.hash,
        .to_hash = first_parent,
        .kind = .starts,
        .fg = fg,
    });

    // Terminating pipes (ending on this commit) and continuing pipes to the left
    // of the node.
    for (prev) |pipe| {
        if (pipe.kind == .terminates) continue;
        if (eqHash(pipe.to_hash, commit.hash)) {
            try pipes.append(allocator, .{
                .from_pos = pipe.to_pos,
                .to_pos = pos,
                .from_hash = pipe.from_hash,
                .to_hash = pipe.to_hash,
                .kind = .terminates,
                .fg = pipe.fg,
            });
            try traverse(allocator, &traversed, &taken, pipe.to_pos, pos);
        } else if (pipe.to_pos < pos) {
            const avail = nextAvailContinuing(&traversed);
            try pipes.append(allocator, .{
                .from_pos = pipe.to_pos,
                .to_pos = avail,
                .from_hash = pipe.from_hash,
                .to_hash = pipe.to_hash,
                .kind = .continues,
                .fg = pipe.fg,
            });
            try traverse(allocator, &traversed, &taken, pipe.to_pos, avail);
        }
    }

    // Merge parents each start a new lane.
    if (commit.parents.len > 1) {
        for (commit.parents[1..]) |parent| {
            const avail = nextAvailNew(&taken, &traversed_cont);
            try pipes.append(allocator, .{
                .from_pos = pos,
                .to_pos = avail,
                .from_hash = commit.hash,
                .to_hash = parent,
                .kind = .starts,
                .fg = fg,
            });
            try taken.put(allocator, avail, {});
        }
    }

    // Remaining continuing pipes to the right of the node, shifting left to fill
    // any freed lanes.
    for (prev) |pipe| {
        if (pipe.kind == .terminates) continue;
        if (!eqHash(pipe.to_hash, commit.hash) and pipe.to_pos > pos) {
            var last = pipe.to_pos;
            var i = pipe.to_pos;
            while (i > pos) : (i -= 1) {
                if (taken.contains(i) or traversed.contains(i)) break;
                last = i;
            }
            try pipes.append(allocator, .{
                .from_pos = pipe.to_pos,
                .to_pos = last,
                .from_hash = pipe.from_hash,
                .to_hash = pipe.to_hash,
                .kind = .continues,
                .fg = pipe.fg,
            });
            try traverse(allocator, &traversed, &taken, pipe.to_pos, last);
        }
    }

    const result = try pipes.toOwnedSlice(allocator);
    std.mem.sort(Pipe, result, {}, pipeLess);
    return result;
}

fn traverse(allocator: std.mem.Allocator, traversed: *PosSet, taken: *PosSet, from: i16, to: i16) !void {
    var lo = from;
    var hi = to;
    if (lo > hi) {
        lo = to;
        hi = from;
    }
    var i = lo;
    while (i <= hi) : (i += 1) try traversed.put(allocator, i, {});
    try taken.put(allocator, to, {});
}

fn nextAvailContinuing(traversed: *const PosSet) i16 {
    var i: i16 = 0;
    while (traversed.contains(i)) : (i += 1) {}
    return i;
}

fn nextAvailNew(taken: *const PosSet, traversed_cont: *const PosSet) i16 {
    var i: i16 = 0;
    while (taken.contains(i) or traversed_cont.contains(i)) : (i += 1) {}
    return i;
}

fn pipeLess(_: void, a: Pipe, b: Pipe) bool {
    if (a.to_pos == b.to_pos) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.to_pos < b.to_pos;
}

// ---- Rendering ------------------------------------------------------------

const Style = struct { fg: u8, bold: bool };
const default_style = Style{ .fg = 7, .bold = false };
/// The selected commit's lanes: bright white + bold, overriding lane colours.
const highlight_style = Style{ .fg = 15, .bold = true };

// Filled nodes (a solid coloured spot), rather than the hollow outlines the
// reference renderer uses — a merge keeps a ring so it still stands out.
pub const commit_symbol: u21 = '●';
pub const merge_symbol: u21 = '◉';

/// One rendered graph column pair (each graph "cell" is two terminal columns:
/// a glyph and its horizontal connector).
pub const RenderCell = struct {
    a: u21,
    a_fg: u8,
    a_bold: bool,
    b: u21,
    b_fg: u8,
    b_bold: bool,
};

const CellType = enum { connection, commit, merge };

const Cell = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    ctype: CellType = .connection,
    style: Style = default_style,
    right_style: ?Style = null,

    fn setUp(self: *Cell, st: Style) void {
        self.up = true;
        self.style = st;
    }
    fn setDown(self: *Cell, st: Style) void {
        self.down = true;
        self.style = st;
    }
    fn setLeft(self: *Cell, st: Style) void {
        self.left = true;
        if (!self.up and !self.down) self.style = st; // vertical trumps left
    }
    fn setRight(self: *Cell, st: Style, override: bool) void {
        self.right = true;
        if (self.right_style == null or override) self.right_style = st;
    }

    fn toRender(self: Cell) RenderCell {
        const bd = boxChars(self.up, self.down, self.left, self.right);
        const first: u21 = switch (self.ctype) {
            .connection => bd.first,
            .commit => commit_symbol,
            .merge => merge_symbol,
        };
        const rstyle = self.right_style orelse self.style;
        return .{
            .a = first,
            .a_fg = self.style.fg,
            .a_bold = self.style.bold,
            .b = bd.second,
            .b_fg = rstyle.fg,
            .b_bold = rstyle.bold,
        };
    }
};

/// Render one commit's pipe set into `out`. Returns the number of cells written
/// (each = two terminal columns). `selected_hash`/`prev_hash` drive the moving
/// selection highlight; pass an empty slice for "none".
pub fn renderRow(pipes: []const Pipe, selected_hash: []const u8, prev_hash: []const u8, out: []RenderCell) usize {
    var max_pos: i16 = 0;
    var commit_pos: i16 = 0;
    var start_count: usize = 0;
    for (pipes) |pipe| {
        if (pipe.kind == .starts) {
            start_count += 1;
            commit_pos = pipe.from_pos;
        } else if (pipe.kind == .terminates) {
            commit_pos = pipe.to_pos;
        }
        if (pipe.right() > max_pos) max_pos = pipe.right();
    }
    const is_merge = start_count > 1;

    const count = @min(@as(usize, @intCast(max_pos + 1)), @min(max_lanes, out.len));
    var cells: [max_lanes]Cell = undefined;
    for (0..count) |i| cells[i] = .{};
    const view = cells[0..count];

    // Only highlight the selected commit's lanes when there's a visible pipe
    // involved (avoid double-highlighting two contiguous selected rows).
    var highlight = true;
    if (prev_hash.len > 0 and eqHash(prev_hash, selected_hash)) {
        highlight = false;
        for (pipes) |pipe| {
            if (eqHash(pipe.from_hash, selected_hash) and (pipe.kind != .terminates or pipe.from_pos != pipe.to_pos)) highlight = true;
        }
    }

    // Non-selected STARTS first, then the other non-selected pipes.
    for (pipes) |pipe| {
        if (highlight and eqHash(pipe.from_hash, selected_hash)) continue;
        if (pipe.kind == .starts) renderPipe(view, pipe, .{ .fg = pipe.fg, .bold = false }, true);
    }
    for (pipes) |pipe| {
        if (highlight and eqHash(pipe.from_hash, selected_hash)) continue;
        const trivial_terminate = pipe.kind == .terminates and pipe.from_pos == commit_pos and pipe.to_pos == commit_pos;
        if (pipe.kind != .starts and !trivial_terminate) renderPipe(view, pipe, .{ .fg = pipe.fg, .bold = false }, false);
    }

    // Selected pipes last so they override: clear their cells, then redraw bold.
    for (pipes) |pipe| {
        if (!(highlight and eqHash(pipe.from_hash, selected_hash))) continue;
        var i = pipe.left();
        while (i <= pipe.right()) : (i += 1) {
            const u: usize = @intCast(i);
            if (u < count) view[u] = .{};
        }
    }
    for (pipes) |pipe| {
        if (!(highlight and eqHash(pipe.from_hash, selected_hash))) continue;
        renderPipe(view, pipe, highlight_style, true);
        const u: usize = @intCast(pipe.to_pos);
        if (pipe.to_pos == commit_pos and u < count) view[u].style = highlight_style;
    }

    const cu: usize = @intCast(commit_pos);
    if (cu < count) view[cu].ctype = if (is_merge) .merge else .commit;

    for (0..count) |i| out[i] = view[i].toRender();
    return count;
}

fn renderPipe(cells: []Cell, pipe: Pipe, st: Style, override_right: bool) void {
    const l = pipe.left();
    const r = pipe.right();
    if (l != r) {
        var i = l + 1;
        while (i < r) : (i += 1) {
            const u: usize = @intCast(i);
            if (u < cells.len) {
                cells[u].setLeft(st);
                cells[u].setRight(st, override_right);
            }
        }
        const lu: usize = @intCast(l);
        if (lu < cells.len) cells[lu].setRight(st, override_right);
        const ru: usize = @intCast(r);
        if (ru < cells.len) cells[ru].setLeft(st);
    }
    if (pipe.kind == .starts or pipe.kind == .continues) {
        const u: usize = @intCast(pipe.to_pos);
        if (u < cells.len) cells[u].setDown(st);
    }
    if (pipe.kind == .terminates or pipe.kind == .continues) {
        const u: usize = @intCast(pipe.from_pos);
        if (u < cells.len) cells[u].setUp(st);
    }
}

const BoxChars = struct { first: u21, second: u21 };

/// The box-drawing glyph pair for a cell's up/down/left/right connections — a
/// direct port of the reference truth table. `first` is the junction glyph,
/// `second` the horizontal connector (or space).
fn boxChars(up: bool, down: bool, left: bool, right: bool) BoxChars {
    if (up and down and left and right) return .{ .first = '│', .second = '─' };
    if (up and down and left and !right) return .{ .first = '│', .second = ' ' };
    if (up and down and !left and right) return .{ .first = '│', .second = '─' };
    if (up and down and !left and !right) return .{ .first = '│', .second = ' ' };
    if (up and !down and left and right) return .{ .first = '┴', .second = '─' };
    if (up and !down and left and !right) return .{ .first = '╯', .second = ' ' };
    if (up and !down and !left and right) return .{ .first = '╰', .second = '─' };
    if (up and !down and !left and !right) return .{ .first = '╵', .second = ' ' };
    if (!up and down and left and right) return .{ .first = '┬', .second = '─' };
    if (!up and down and left and !right) return .{ .first = '╮', .second = ' ' };
    if (!up and down and !left and right) return .{ .first = '╭', .second = '─' };
    if (!up and down and !left and !right) return .{ .first = '╷', .second = ' ' };
    if (!up and !down and left and right) return .{ .first = '─', .second = '─' };
    if (!up and !down and left and !right) return .{ .first = '─', .second = ' ' };
    if (!up and !down and !left and right) return .{ .first = '╶', .second = '─' };
    return .{ .first = ' ', .second = ' ' };
}

test "linear history: one lane, one node per row" {
    const a = std.testing.allocator;
    // c0 <- c1 <- c2 (newest first, each parent the next).
    var commits = [_]model.Commit{
        .{ .hash = @constCast("c0"), .short_hash = @constCast("c0"), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast("s"), .parents = @constCast(&[_][]u8{@constCast("c1")}) },
        .{ .hash = @constCast("c1"), .short_hash = @constCast("c1"), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast("s"), .parents = @constCast(&[_][]u8{@constCast("c2")}) },
        .{ .hash = @constCast("c2"), .short_hash = @constCast("c2"), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast("s"), .parents = @constCast(&[_][]u8{}) },
    };
    var g = try build(a, &commits);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.sets.len);

    var out: [max_lanes]RenderCell = undefined;
    for (commits, 0..) |_, i| {
        const n = renderRow(g.sets[i], "", "", &out);
        try std.testing.expectEqual(@as(usize, 1), n); // single lane
        try std.testing.expectEqual(commit_symbol, out[0].a); // ○ node
    }
}

test "a merge commit marks a merge node and opens a second lane" {
    const a = std.testing.allocator;
    // m is a merge of p1 and p2; p1 is its first parent.
    var commits = [_]model.Commit{
        .{ .hash = @constCast("m"), .short_hash = @constCast("m"), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast("merge"), .parents = @constCast(&[_][]u8{ @constCast("p1"), @constCast("p2") }) },
        .{ .hash = @constCast("p1"), .short_hash = @constCast("p1"), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast("s"), .parents = @constCast(&[_][]u8{@constCast("p2")}) },
        .{ .hash = @constCast("p2"), .short_hash = @constCast("p2"), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast("s"), .parents = @constCast(&[_][]u8{}) },
    };
    var g = try build(a, &commits);
    defer g.deinit();

    var out: [max_lanes]RenderCell = undefined;
    const n = renderRow(g.sets[0], "", "", &out);
    try std.testing.expectEqual(merge_symbol, out[0].a); // ◎ merge node
    try std.testing.expect(n >= 2); // a second lane opened for the merge parent
}

test "golden: matches the reference renderer on a merge-with-left-shift history" {
    const a = std.testing.allocator;
    // Ported verbatim from the reference implementation's graph test
    // ("with a path that has room to move to the left"). Newest first.
    const P = struct {
        fn c(hash: []const u8, parents: []const []u8) model.Commit {
            return .{ .hash = @constCast(hash), .short_hash = @constCast(hash), .author = @constCast("A"), .time = @constCast(""), .refs = @constCast(""), .subject = @constCast(""), .parents = @constCast(parents) };
        }
    };
    var commits = [_]model.Commit{
        P.c("1", &.{@constCast("2")}),
        P.c("2", &.{ @constCast("3"), @constCast("4") }),
        P.c("4", &.{ @constCast("3"), @constCast("5") }),
        P.c("3", &.{@constCast("5")}),
        P.c("5", &.{@constCast("6")}),
        P.c("6", &.{@constCast("7")}),
    };
    // Same topology as the reference renderer; only the node glyph differs
    // (filled ●/◉ instead of the reference's hollow ○/◎).
    const expected = [_][]const u8{
        "1 ●",
        "2 ◉─╮",
        "4 │ ◉─╮",
        "3 ●─╯ │",
        "5 ●───╯",
        "6 ●",
    };

    var g = try build(a, &commits);
    defer g.deinit();

    var out: [max_lanes]RenderCell = undefined;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);

    for (commits, 0..) |commit, i| {
        line.clearRetainingCapacity();
        try line.appendSlice(a, commit.hash);
        try line.append(a, ' ');
        const prev_hash: []const u8 = if (i > 0) commits[i - 1].hash else "";
        const n = renderRow(g.sets[i], "blah", prev_hash, &out); // "blah" never matches → no highlight
        for (out[0..n]) |cell| {
            var buf: [4]u8 = undefined;
            try line.appendSlice(a, buf[0 .. std.unicode.utf8Encode(cell.a, &buf) catch 0]);
            try line.appendSlice(a, buf[0 .. std.unicode.utf8Encode(cell.b, &buf) catch 0]);
        }
        const trimmed = std.mem.trim(u8, line.items, " ");
        try std.testing.expectEqualStrings(expected[i], trimmed);
    }
}
