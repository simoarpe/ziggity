//! The hunk/line staging view: opening a file into it, loading the per-side
//! diff, moving the line cursor, the single/split layout toggle, and applying a
//! line/hunk/range selection to the index via `git apply`. Free functions over
//! `*App`; the staging state (`staging`, `staging_diff`, cursor, …) lives on App.
const std = @import("std");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const diff_mod = @import("diff.zig");
const patch_mod = @import("patch.zig");

const App = app_mod.App;

pub fn openStaging(app: *App) !void {
    const file = app.selectedFile() orelse {
        try app.setMessage("no file selected", .{});
        return;
    };
    if (!file.tracked and !file.has_staged) {
        try app.setMessage("stage untracked files with space in the Files panel", .{});
        return;
    }
    const path = try app.allocator.dupe(u8, file.path);
    clearStaging(app);
    app.staging_path = path;
    app.staging_staged_view = false;
    app.main_origin = .files;
    app.focus = .main;
    app.staging_active = true;
    // Decide the layout for this file (recomputed only on (re)open):
    //   off/on -> the remembered preference; auto -> split for a file with both
    //   staged and unstaged changes, else the remembered preference.
    app.staging_opened_mixed = file.has_staged and file.has_unstaged;
    app.staging_split = stagingLayoutForOpen(app.config.staging_split, app.staging_split_pref, app.staging_opened_mixed);
    try loadStaging(app, false);
    try app.setMessage("staging {s}", .{file.path});
}

/// Reload the staging diff for the current side. `keep_cursor` preserves the
/// cursor position (clamped) instead of resetting to the first change — used
/// after staging/unstaging a line so the cursor stays put and repeated space
/// keeps applying the lines that shift up into it.
pub fn loadStaging(app: *App, keep_cursor: bool) !void {
    if (app.staging) |*parsed| parsed.deinit(app.allocator);
    app.staging = null;
    app.allocator.free(app.staging_diff);
    app.staging_diff = &.{};

    app.staging_diff = app.git.rawFileDiff(app.staging_path, app.staging_staged_view, app.config.diff_context) catch
        try app.allocator.dupe(u8, "");

    // If the active side has no diff but the other side does, switch to it — e.g.
    // opening a fully-staged file shows the staged changes rather than a blank
    // unstaged pane (and after staging the last change, flip to staged).
    if (app.staging_diff.len == 0) {
        const other = app.git.rawFileDiff(app.staging_path, !app.staging_staged_view, app.config.diff_context) catch
            try app.allocator.dupe(u8, "");
        if (other.len > 0) {
            app.allocator.free(app.staging_diff);
            app.staging_diff = other;
            app.staging_staged_view = !app.staging_staged_view;
        } else {
            app.allocator.free(other);
        }
    }

    app.staging = try diff_mod.parse(app.allocator, app.staging_diff);

    // In split view, also load the other side's diff for the read-only pane.
    app.allocator.free(app.staging_other_diff);
    app.staging_other_diff = &.{};
    if (app.staging_split) {
        app.staging_other_diff = app.git.rawFileDiff(app.staging_path, !app.staging_staged_view, app.config.diff_context) catch
            try app.allocator.dupe(u8, "");
    }

    app.staging_anchor = null;
    if (keep_cursor) {
        app.staging_cursor = @min(@max(app.staging_cursor, stagingFirstLine(app)), stagingLastLine(app));
    } else {
        app.staging_cursor = stagingFirstLine(app);
    }
    scrollToStagingCursor(app);
}

pub fn toggleStagingSide(app: *App) !void {
    app.staging_staged_view = !app.staging_staged_view;
    try loadStaging(app, false);
    try app.setMessage("{s} changes", .{if (app.staging_staged_view) "staged" else "unstaged"});
}

/// The staging layout to use when a file opens, per the config mode, the
/// remembered `\` preference, and whether the file has both staged and unstaged
/// changes ("mixed").
pub fn stagingLayoutForOpen(mode: config_mod.StagingSplitMode, pref: bool, mixed: bool) bool {
    return switch (mode) {
        .off, .on => pref,
        .auto => if (mixed) true else pref,
    };
}

/// Whether toggling `\` should be remembered for the next file. In `auto`, a
/// mixed file always reopens split, so its toggle is transient.
pub fn stagingTogglePersists(mode: config_mod.StagingSplitMode, mixed: bool) bool {
    return !(mode == .auto and mixed);
}

pub fn toggleStagingSplit(app: *App) !void {
    app.staging_split = !app.staging_split;
    if (stagingTogglePersists(app.config.staging_split, app.staging_opened_mixed)) {
        app.staging_split_pref = app.staging_split;
    }
    try loadStaging(app, true); // (re)load or drop the other side's diff
    try app.setMessage("{s} staging view", .{if (app.staging_split) "split" else "single"});
}

pub fn toggleStagingRange(app: *App) void {
    app.staging_anchor = if (app.staging_anchor == null) app.staging_cursor else null;
}

/// Line index of the first selectable line (the first hunk's `@@` line).
pub fn stagingFirstLine(app: *const App) usize {
    const parsed = app.staging orelse return 0;
    if (parsed.hunks.len == 0) return 0;
    return parsed.hunks[0].start_line;
}

pub fn stagingLastLine(app: *const App) usize {
    const lines = std.mem.count(u8, app.staging_diff, "\n");
    if (lines == 0) return stagingFirstLine(app);
    return lines - 1;
}

pub fn moveStagingCursor(app: *App, delta: i8) void {
    const first = stagingFirstLine(app);
    const last = stagingLastLine(app);
    if (delta < 0) {
        if (app.staging_cursor > first) app.staging_cursor -= 1;
    } else if (app.staging_cursor < last) {
        app.staging_cursor += 1;
    }
    scrollToStagingCursor(app);
}

pub fn scrollToStagingCursor(app: *App) void {
    const height: usize = if (app.main_view_height == 0) 20 else app.main_view_height;
    if (app.staging_cursor < app.main_scroll) {
        app.main_scroll = app.staging_cursor;
    } else if (app.staging_cursor >= app.main_scroll + height) {
        app.main_scroll = app.staging_cursor + 1 - height;
    }
}

/// The hunk index whose body or header line contains `abs`, or null.
pub fn stagingHunkAt(app: *const App, abs: usize) ?usize {
    const parsed = app.staging orelse return null;
    for (parsed.hunks, 0..) |hunk, idx| {
        if (abs >= hunk.start_line and abs < hunk.end_line) return idx;
    }
    return null;
}

pub fn applyStagingSelection(app: *App) !void {
    const parsed = app.staging orelse return;
    if (parsed.hunks.len == 0) {
        try app.setMessage("no changes to stage", .{});
        return;
    }
    const hunk_index = stagingHunkAt(app, app.staging_cursor) orelse {
        try app.setMessage("move the cursor onto a change", .{});
        return;
    };
    const hunk = parsed.hunks[hunk_index];

    // On the `@@` header line, stage the whole hunk; otherwise the lines.
    const patch = if (app.staging_cursor == hunk.start_line)
        try diff_mod.buildHunkPatch(app.allocator, app.staging_diff, parsed, hunk_index)
    else blk: {
        const lo_abs = @min(app.staging_anchor orelse app.staging_cursor, app.staging_cursor);
        const hi_abs = @max(app.staging_anchor orelse app.staging_cursor, app.staging_cursor);
        const body_first = hunk.start_line + 1;
        const lo = (@max(lo_abs, body_first)) - body_first;
        const hi = (@min(hi_abs, hunk.end_line - 1)) - body_first;
        break :blk diff_mod.buildLinePatch(app.allocator, app.staging_diff, parsed, hunk_index, lo, hi, app.staging_staged_view) catch |err| switch (err) {
            error.EmptySelection => {
                try app.setMessage("selection contains no change", .{});
                return;
            },
            error.NoNewlineHunk => {
                try app.setMessage("stage the whole hunk for no-newline changes (enter on @@)", .{});
                return;
            },
            error.InvalidHunk => {
                try app.setMessage("could not build patch for this hunk", .{});
                return;
            },
            else => return err,
        };
    };
    defer app.allocator.free(patch);

    var result = try app.git.applyPatch(patch, app.staging_staged_view);
    defer result.deinit(app.allocator);
    if (!result.ok()) {
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        try app.setMessage("apply failed: {s}", .{if (stderr.len > 0) stderr else "git apply error"});
        return;
    }
    const verb = if (app.staging_staged_view) "unstaged" else "staged";
    const scope = if (app.staging_cursor == hunk.start_line) "hunk" else "selection";
    try app.setMessage("{s} {s}", .{ verb, scope });
    app.staging_anchor = null;
    // Staging a line only touches the index — scoped (fast) reload. Keep the
    // cursor where it is so repeated space keeps staging the lines that shift up
    // into its position.
    app.refreshFiles() catch {};
    try loadStaging(app, true);
}

pub fn closeStaging(app: *App) !void {
    if (app.staging_patch_mode) return patch_mod.closePatchLineView(app);
    clearStaging(app);
    app.focus = .files;
    app.resetMainView();
    try app.updatePreview();
}

pub fn clearStaging(app: *App) void {
    app.staging_patch_mode = false;
    if (app.staging) |*parsed| parsed.deinit(app.allocator);
    app.staging = null;
    app.allocator.free(app.staging_diff);
    app.staging_diff = &.{};
    app.allocator.free(app.staging_other_diff);
    app.staging_other_diff = &.{};
    app.allocator.free(app.staging_path);
    app.staging_path = &.{};
    app.staging_active = false;
    app.staging_staged_view = false;
    app.staging_cursor = 0;
    app.staging_anchor = null;
}
