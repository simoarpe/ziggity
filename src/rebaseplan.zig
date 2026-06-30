//! The interactive-rebase editor (`i`): compose a git-rebase todo in-app by
//! marking commits pick/drop/squash/fixup/edit and reordering them, then execute
//! it as one rebase. Reword is intentionally not a plan action — ziggity's `r`
//! rewords a single commit through its in-app message editor. Free functions
//! over `*App`; the plan and its state live on App.
const std = @import("std");

const app_mod = @import("app.zig");
const model = @import("model.zig");

const App = app_mod.App;

/// What to do with a commit in the plan. `pick` keeps it; the rest map to the
/// matching git-rebase-todo verbs.
pub const Action = enum {
    pick,
    drop,
    squash,
    fixup,
    edit,

    pub fn word(self: Action) []const u8 {
        return switch (self) {
            .pick => "pick",
            .drop => "drop",
            .squash => "squash",
            .fixup => "fixup",
            .edit => "edit",
        };
    }

    /// Short label shown in the plan list.
    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .pick => "pick  ",
            .drop => "drop  ",
            .squash => "squash",
            .fixup => "fixup ",
            .edit => "edit  ",
        };
    }
};

/// One commit in the plan. Strings are owned (duped from the commit list) so the
/// plan survives a background refresh that replaces `data.commits`.
pub const Entry = struct {
    hash: []u8,
    short_hash: []u8,
    subject: []u8,
    action: Action = .pick,
};

/// `i` on the Commits tab: build a plan for the commits from HEAD down to (and
/// including) the selected one, all initially `pick`, and enter plan mode.
pub fn start(app: *App) !void {
    if (app.commits_tab != .commits) {
        try app.setMessage("interactive rebase applies to the Commits tab", .{});
        return;
    }
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress rebase/merge first (m)", .{});
        return;
    }
    const commits = app.data.commits;
    if (commits.len == 0) {
        try app.setMessage("no commit selected", .{});
        return;
    }
    const i = @min(app.commit_index, commits.len - 1);

    free(app); // drop any stale plan
    var entries = try app.allocator.alloc(Entry, i + 1);
    var built: usize = 0;
    errdefer {
        for (entries[0..built]) |e| freeEntry(app.allocator, e);
        app.allocator.free(entries);
    }
    while (built <= i) : (built += 1) {
        const c = commits[built];
        entries[built] = .{
            .hash = try app.allocator.dupe(u8, c.hash),
            .short_hash = try app.allocator.dupe(u8, c.short_hash),
            .subject = try app.allocator.dupe(u8, c.subject),
        };
    }
    // Base is the parent of the oldest commit in the plan (the last entry).
    app.rebase_plan_base = try app.allocator.dupe(u8, commits[i].hash);
    app.rebase_plan = entries;
    app.rebase_plan_index = 0;
    app.rebase_plan_anchor = null;
    app.mode = .rebase_plan;
    try app.setMessage("interactive rebase: p/d/s/f/e mark, v/shift+arrows select, ^j/^k move, enter run, esc cancel", .{});
}

/// The inclusive [lo, hi] plan rows the action/move applies to: the multi-commit
/// range when one is active, else just the cursor row.
pub fn bounds(app: *const App) struct { lo: usize, hi: usize } {
    const plan = app.rebase_plan orelse return .{ .lo = 0, .hi = 0 };
    const idx = @min(app.rebase_plan_index, plan.len - 1);
    if (app.rebase_plan_anchor) |anc| {
        const a = @min(anc, plan.len - 1);
        return .{ .lo = @min(a, idx), .hi = @max(a, idx) };
    }
    return .{ .lo = idx, .hi = idx };
}

/// True when plan row `i` is inside the active multi-commit selection.
pub fn inRange(app: *const App, i: usize) bool {
    if (app.rebase_plan_anchor == null) return false;
    const b = bounds(app);
    return i >= b.lo and i <= b.hi;
}

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const plan = app.rebase_plan orelse {
        app.mode = .normal;
        return;
    };
    const km = app.config.keymap;

    if (app.isDialogCloseKey(key)) {
        // esc first cancels a range selection, then exits the plan editor.
        if (app.rebase_plan_anchor != null) {
            app.rebase_plan_anchor = null;
            return;
        }
        return cancel(app);
    }
    if (app.isEnterKey(key)) return execute(app);

    // `v` toggles a multi-commit selection anchored at the cursor. The plan
    // editor is a composition surface, so once a selection exists every
    // navigation key keeps it and extends it (anchor fixed, cursor moves) —
    // only `v` or `esc` clears it. shift+arrows additionally *start* one.
    if (matchesChar(key, 'v')) {
        if (app.rebase_plan_anchor != null) {
            app.rebase_plan_anchor = null;
        } else {
            app.rebase_plan_anchor = app.rebase_plan_index;
        }
        return;
    }
    // shift+arrows start a selection if none is active, then move the cursor.
    if (key.matches(vaxis.Key.down, .{ .shift = true })) {
        if (app.rebase_plan_anchor == null) app.rebase_plan_anchor = app.rebase_plan_index;
        if (app.rebase_plan_index + 1 < plan.len) app.rebase_plan_index += 1;
        return;
    }
    if (key.matches(vaxis.Key.up, .{ .shift = true })) {
        if (app.rebase_plan_anchor == null) app.rebase_plan_anchor = app.rebase_plan_index;
        app.rebase_plan_index -|= 1;
        return;
    }
    // Plain arrows move the cursor; an active selection follows it (it does not
    // get cleared), so a user can keep extending without holding shift.
    if (km.up.matches(key) or key.matches(vaxis.Key.up, .{})) {
        app.rebase_plan_index -|= 1;
        return;
    }
    if (km.down.matches(key) or key.matches(vaxis.Key.down, .{})) {
        if (app.rebase_plan_index + 1 < plan.len) app.rebase_plan_index += 1;
        return;
    }
    // Reorder the selected entry/block within the plan (newest-first display).
    if (km.commit_move_up.matches(key)) return moveBlock(app, false);
    if (km.commit_move_down.matches(key)) return moveBlock(app, true);

    // Set the action for the selected entry, or every entry in the selection.
    const action: ?Action = if (km.commit_drop.matches(key))
        .drop
    else if (km.commit_squash.matches(key))
        .squash
    else if (km.commit_create_fixup.matches(key) or matchesChar(key, 'f'))
        .fixup
    else if (km.commit_edit.matches(key))
        .edit
    else if (matchesChar(key, 'p'))
        .pick
    else
        null;
    if (action) |a| {
        const b = bounds(app);
        var i = b.lo;
        while (i <= b.hi) : (i += 1) plan[i].action = a;
    }
}

/// Move the selected entry (or the whole selected block) one row up/down,
/// carrying the cursor and the selection anchor with it.
fn moveBlock(app: *App, down: bool) void {
    const plan = app.rebase_plan orelse return;
    const b = bounds(app);
    if (down) {
        if (b.hi + 1 >= plan.len) return;
        // The neighbour below the block moves above it; the block shifts down.
        const neighbour = plan[b.hi + 1];
        var i = b.hi + 1;
        while (i > b.lo) : (i -= 1) plan[i] = plan[i - 1];
        plan[b.lo] = neighbour;
        app.rebase_plan_index += 1;
        if (app.rebase_plan_anchor) |anc| app.rebase_plan_anchor = anc + 1;
    } else {
        if (b.lo == 0) return;
        // The neighbour above the block moves below it; the block shifts up.
        const neighbour = plan[b.lo - 1];
        var i = b.lo - 1;
        while (i < b.hi) : (i += 1) plan[i] = plan[i + 1];
        plan[b.hi] = neighbour;
        app.rebase_plan_index -= 1;
        if (app.rebase_plan_anchor) |anc| app.rebase_plan_anchor = anc - 1;
    }
}

/// Run the composed plan as one rebase. The git-rebase-todo is oldest-first, so
/// the newest-first plan is emitted in reverse.
fn execute(app: *App) !void {
    const plan = app.rebase_plan orelse return;

    // The oldest commit (last entry) cannot squash/fixup into a predecessor.
    const oldest = plan[plan.len - 1].action;
    if (oldest == .squash or oldest == .fixup) {
        try app.setMessage("the oldest commit cannot be squash/fixup (nothing below it)", .{});
        return;
    }
    if (allDrop(plan)) {
        try app.setMessage("at least one commit must be kept", .{});
        return;
    }

    var aw: std.Io.Writer.Allocating = .init(app.allocator);
    defer aw.deinit();
    var k = plan.len;
    while (k > 0) {
        k -= 1;
        try aw.writer.print("{s} {s}\n", .{ plan[k].action.word(), plan[k].hash });
    }
    const todo = try aw.toOwnedSlice();
    defer app.allocator.free(todo);

    const base_ref = try std.fmt.allocPrint(app.allocator, "{s}^", .{app.rebase_plan_base});
    defer app.allocator.free(base_ref);

    // Exit plan mode before queuing; the mutation owns its own copies.
    free(app);
    app.mode = .normal;
    return app.requestMutation(
        .{ .rebase_todo = .{ .base_ref = base_ref, .todo = todo, .message = null } },
        .{ .gerund = "rebasing", .command = "git rebase -i" },
        "interactive rebase done",
        .{},
    );
}

pub fn cancel(app: *App) void {
    free(app);
    app.mode = .normal;
    app.setMessage("interactive rebase cancelled", .{}) catch {};
}

/// Free the plan and its owned strings. Safe to call when no plan is active.
pub fn free(app: *App) void {
    if (app.rebase_plan) |plan| {
        for (plan) |e| freeEntry(app.allocator, e);
        app.allocator.free(plan);
        app.rebase_plan = null;
    }
    if (app.rebase_plan_base.len > 0) {
        app.allocator.free(app.rebase_plan_base);
        app.rebase_plan_base = &.{};
    }
    app.rebase_plan_index = 0;
    app.rebase_plan_anchor = null;
}

fn freeEntry(allocator: std.mem.Allocator, e: Entry) void {
    allocator.free(e.hash);
    allocator.free(e.short_hash);
    allocator.free(e.subject);
}

fn allDrop(plan: []const Entry) bool {
    for (plan) |e| {
        if (e.action != .drop) return false;
    }
    return true;
}

fn matchesChar(key: vaxis.Key, c: u21) bool {
    return key.matches(c, .{});
}

const vaxis = @import("vaxis");

test "execute builds an oldest-first todo from the newest-first plan" {
    const a = std.testing.allocator;
    var plan = [_]Entry{
        .{ .hash = @constCast("cccc"), .short_hash = @constCast("ccc"), .subject = @constCast("c"), .action = .pick },
        .{ .hash = @constCast("bbbb"), .short_hash = @constCast("bbb"), .subject = @constCast("b"), .action = .fixup },
        .{ .hash = @constCast("aaaa"), .short_hash = @constCast("aaa"), .subject = @constCast("a"), .action = .pick },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var k = plan.len;
    while (k > 0) {
        k -= 1;
        try aw.writer.print("{s} {s}\n", .{ plan[k].action.word(), plan[k].hash });
    }
    try std.testing.expectEqualStrings("pick aaaa\nfixup bbbb\npick cccc\n", aw.written());
}
