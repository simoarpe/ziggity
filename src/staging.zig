//! The hunk/line staging view: opening a file into it, loading the per-side
//! diff, moving the line cursor, the single/split layout toggle, and applying a
//! line/hunk/range selection to the index via `git apply`. Free functions over
//! `*App`; the staging state (`staging`, `staging_diff`, cursor, …) lives on App.
const std = @import("std");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const diff_mod = @import("diff.zig");
const model = @import("model.zig");
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
    // The layout is fully decided by the config each time a file opens; `\`
    // overrides it for the current file only (not remembered across files).
    app.staging_split = stagingLayoutForOpen(app.config.staging_split, file.has_staged and file.has_unstaged);
    try loadStaging(app, false);
    try app.setMessage("staging {s}", .{file.path});
}

/// Reload the staging diff for the current side. `keep_cursor` preserves the
/// cursor position (clamped) instead of resetting to the first change — used
/// after staging/unstaging a line so the cursor stays put and repeated space
/// keeps applying the lines that shift up into it.
pub fn loadStaging(app: *App, keep_cursor: bool) !void {
    return loadStagingSide(app, keep_cursor, true);
}

/// Reload the staging diff. `allow_flip` auto-switches to the other side when
/// the active one is empty — wanted on open / after staging (so a fully-staged
/// file shows the staged side rather than a blank pane), but NOT when the user
/// deliberately switches with `[`/`]`, where they should be able to land on an
/// empty side and see the "no changes" message.
pub fn loadStagingSide(app: *App, keep_cursor: bool, allow_flip: bool) !void {
    if (app.staging) |*parsed| parsed.deinit(app.allocator);
    app.staging = null;
    app.allocator.free(app.staging_diff);
    app.staging_diff = &.{};

    app.staging_diff = app.git.rawFileDiff(app.staging_path, app.staging_staged_view, app.config.diff_context) catch
        try app.allocator.dupe(u8, "");

    // If the active side has no diff but the other side does, switch to it — e.g.
    // opening a fully-staged file shows the staged changes rather than a blank
    // unstaged pane (and after staging the last change, flip to staged).
    if (allow_flip and app.staging_diff.len == 0) {
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
    // Don't auto-flip back: an explicit switch may land on an empty side, which
    // then shows the "no changes on this side" message.
    try loadStagingSide(app, false, false);
    try app.setMessage("{s} changes", .{if (app.staging_staged_view) "staged" else "unstaged"});
}

/// The staging layout a file opens with, decided entirely by the config mode
/// and whether the file has both staged and unstaged changes ("mixed"):
/// `off` always single, `on` always split, `auto` splits a mixed file only.
/// `\` overrides the result for the current file (see `toggleStagingSplit`).
pub fn stagingLayoutForOpen(mode: config_mod.StagingSplitMode, mixed: bool) bool {
    return switch (mode) {
        .off => false,
        .on => true,
        .auto => mixed,
    };
}

pub fn toggleStagingSplit(app: *App) !void {
    app.staging_split = !app.staging_split;
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

// --- File-list staging: optimistic toggles flushed to git off the UI thread ---

/// Space in the Files panel: stage/unstage a whole directory in tree view when
/// the cursor is on one, otherwise the selected file.
pub fn toggleSelectedFileStaged(app: *App) !void {
    // A multi-range (flat list) stages/unstages every selected file at once.
    if (app.rangeActive() and !app.tree_view) return toggleRangeStaged(app);
    if (app.tree_view) {
        if (app.treeSelectedRow()) |row| {
            if (row.is_dir) return app.toggleDirStaged(row.path);
        }
    }
    return toggleFileStaged(app);
}

/// Stage/unstage every file in the active range. If any is unstaged the whole
/// range is staged; otherwise it's unstaged (mirrors the single-file toggle).
fn toggleRangeStaged(app: *App) !void {
    const b = app.rangeBounds() orelse return toggleFileStaged(app);
    // Collect the range's paths up front (staging mutates the model, which would
    // otherwise shift the visible ordinals mid-loop). queueStageOp dupes paths.
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(app.allocator);
    var any_unstaged = false;
    var ord: usize = 0;
    for (app.data.files) |file| {
        if (!app.fileMatchesFilter(file)) continue;
        defer ord += 1;
        if (ord >= b.lo and ord <= b.hi and !file.conflict) {
            try paths.append(app.allocator, file.path);
            if (file.has_unstaged) any_unstaged = true;
        }
    }
    for (paths.items) |p| try queueStageOp(app, p, any_unstaged);
    app.clearRange();
}

/// Optimistically flip the staged/unstaged state of the matching files in the
/// in-memory model so the list reflects the change the instant the key is
/// pressed; the async `git status` refresh that follows reconciles it with
/// reality (a full replace — no merge). `paths == null` means every file
/// (stage/unstage all with no filter active). Statuses with no well-defined
/// instant transition are left untouched. Files are mutated in place — never
/// reordered or removed — so selection holds.
pub fn applyOptimisticStage(app: *App, stage: bool, paths: ?[]const []const u8) void {
    for (app.data.files) |*file| {
        if (paths) |ps| {
            var match = false;
            for (ps) |p| {
                if (std.mem.eql(u8, file.path, p)) {
                    match = true;
                    break;
                }
            }
            if (!match) continue;
        }
        const new_status = if (stage)
            model.optimisticStage(file.short_status)
        else
            model.optimisticUnstage(file.short_status);
        if (new_status) |ns| model.setStatusFields(file, ns);
    }
    // A display filter (e.g. "unstaged only") may now hide a just-staged file;
    // keep the selection index in range until the refresh re-anchors by path.
    app.clampSelections();
}

pub fn toggleFileStaged(app: *App) !void {
    const file = app.selectedFile() orelse {
        try app.setMessage("no file selected", .{});
        return;
    };
    if (file.conflict) return app.startConflictResolveMenu();
    if (file.has_unstaged) return queueStageOp(app, file.path, true);
    if (file.has_staged) return queueStageOp(app, file.path, false);
    try app.setMessage("file has no staged or unstaged changes", .{});
}

/// Record a stage (`true`) or unstage (`false`) of `path`: update the model
/// optimistically for instant feedback and remember the desired state. The
/// actual `git add`/`git reset` is flushed off the UI thread by the loop (see
/// `tryFlushStaging`), coalesced with any other rapid toggles, so input never
/// blocks on git. Re-toggling a path just overwrites its desired state.
pub fn queueStageOp(app: *App, path: []const u8, stage: bool) !void {
    applyOptimisticStage(app, stage, &[_][]const u8{path});
    const gop = try app.stage_pending.getOrPut(app.allocator, path);
    if (!gop.found_existing) gop.key_ptr.* = try app.allocator.dupe(u8, path);
    gop.value_ptr.* = stage;
    // Drop any background worktree snapshot started before this change so it
    // can't clobber the optimistic state with the pre-toggle index.
    app.refresh_generation +%= 1;
}

/// TUI-loop hook: if any stage toggles are pending and the mutation worker is
/// free, drain them into one `git add`/`git reset` batch and queue it. Called
/// every loop iteration; a no-op when nothing is pending or a mutation is
/// already in flight (then it runs after that finishes).
pub fn tryFlushStaging(app: *App) void {
    if (app.stage_pending.count() == 0 and app.stage_all_pending == null) return;
    if (app.foregroundBusy()) return;
    var add: std.ArrayList([]const u8) = .empty;
    defer add.deinit(app.allocator);
    var reset: std.ArrayList([]const u8) = .empty;
    defer reset.deinit(app.allocator);
    var it = app.stage_pending.iterator();
    while (it.next()) |e| {
        (if (e.value_ptr.*) &add else &reset).append(app.allocator, e.key_ptr.*) catch return;
    }
    // requestMutation deep-copies the lists, so the pending keys can be freed.
    app.requestMutation(.{ .stage_batch = .{ .all = app.stage_all_pending, .add = add.items, .reset = reset.items } }, .{ .gerund = "staging", .refresh = App.Refresh.files }, "staged", .{}) catch return;
    clearStagePending(app);
    app.stage_all_pending = null;
}

pub fn clearStagePending(app: *App) void {
    var it = app.stage_pending.iterator();
    while (it.next()) |e| app.allocator.free(e.key_ptr.*);
    app.stage_pending.clearRetainingCapacity();
}

/// Record a stage/unstage-all (`a`): update the model optimistically and set the
/// pending all-op, which the loop flushes off-thread. Supersedes any per-path
/// pending (the all-op is the new baseline for every file).
pub fn queueStageAll(app: *App, stage: bool) void {
    applyOptimisticStage(app, stage, null);
    clearStagePending(app);
    app.stage_all_pending = stage;
    app.refresh_generation +%= 1;
}

pub fn toggleAllStaged(app: *App) !void {
    // Like the per-file toggle, this only updates the model optimistically and
    // queues the work; the loop flushes it off the UI thread so `a` is
    // non-blocking too. A filter narrows it to the visible paths (a per-path
    // batch); unfiltered, it uses the efficient `git add -A` / `git reset`.
    if (app.visibleUnstagedCount() > 0) {
        if (app.anyFileFilterActive()) {
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(app.allocator);
            try app.collectVisiblePaths(&paths, .unstaged);
            for (paths.items) |p| try queueStageOp(app, p, true);
            return;
        }
        queueStageAll(app, true);
        return;
    }
    if (app.visibleStagedCount() > 0) {
        if (app.anyFileFilterActive()) {
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(app.allocator);
            try app.collectVisiblePaths(&paths, .staged);
            for (paths.items) |p| try queueStageOp(app, p, false);
            return;
        }
        queueStageAll(app, false);
        return;
    }
    try app.setMessage("no visible files to stage", .{});
}
