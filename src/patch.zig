//! Custom-patch building (the `ctrl+p` workflow): selecting whole files or
//! individual lines from a commit's diff into an applyable patch. The patch
//! state lives on `App` (`patch_source`/`patch_paths`/`patch_line_sel` and the
//! `patch_work_included` line-view scratch); these are free functions that
//! operate on it, kept out of `app.zig` so that file stays navigable.
const std = @import("std");

const app_mod = @import("app.zig");
const diff_mod = @import("diff.zig");
const staging_mod = @import("staging.zig");

const App = app_mod.App;

pub fn patchHasFile(app: *const App, path: []const u8) bool {
    for (app.patch_paths.items) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

pub fn patchFileCount(app: *const App) usize {
    return app.patch_paths.items.len;
}

/// Files in the in-progress patch if it belongs to `hash`, else 0. A patch is
/// tied to one commit, so a commit-files view only advertises its own.
fn patchCountForCommit(app: *const App, hash: []const u8) usize {
    const src = app.patch_source orelse return 0;
    return if (std.mem.eql(u8, src, hash)) app.patch_paths.items.len else 0;
}

/// Patch file count for the commit the Commits panel is showing files for.
pub fn commitFilesPatchCount(app: *const App) usize {
    if (!app.commit_files_active) return 0;
    const list = app.activeCommits();
    if (list.len == 0) return 0;
    return patchCountForCommit(app, list[@min(app.activeCommitIndex(), list.len - 1)].hash);
}

/// Patch file count for the sub-commit the Branches panel is showing files for.
pub fn branchFilesPatchCount(app: *const App) usize {
    if (!app.branch_files_active or app.branch_commits.len == 0) return 0;
    return patchCountForCommit(app, app.branch_commits[@min(app.branch_commit_index, app.branch_commits.len - 1)].hash);
}

pub fn clearPatch(app: *App) void {
    if (app.patch_source) |s| app.allocator.free(s);
    app.patch_source = null;
    for (app.patch_paths.items) |p| app.allocator.free(p);
    app.patch_paths.clearRetainingCapacity();
    for (app.patch_line_sel.items) |sel| if (sel) |s| app.allocator.free(s);
    app.patch_line_sel.clearRetainingCapacity();
}

/// The line inclusion for a path in the patch: null if the file isn't in the
/// patch or is included whole; otherwise its per-line bool array.
fn patchLineSelFor(app: *const App, path: []const u8) ?[]bool {
    for (app.patch_paths.items, 0..) |p, idx| {
        if (std.mem.eql(u8, p, path)) return app.patch_line_sel.items[idx];
    }
    return null;
}

/// Toggle the selected commit file into the custom patch. A patch is tied to one
/// source commit; selecting a file from a different commit prompts to discard
/// the current patch first (confirming re-runs via `applyPatchToggle`).
pub fn toggleFileInPatch(app: *App) !void {
    const commit = app.selectedCommit() orelse {
        try app.setMessage("open a commit's files (enter) to build a patch", .{});
        return;
    };
    if (app.selectedCommitFile() == null) {
        try app.setMessage("open a commit's files (enter) to build a patch", .{});
        return;
    }
    if (app.patch_source) |source| {
        if (!std.mem.eql(u8, source, commit.hash)) {
            app.patch_reset_resume = .toggle_file;
            return app.requestConfirmation(.reset_patch, "confirm discard patch", .{});
        }
    }
    return applyPatchToggle(app);
}

/// Add/remove the selected file in the custom patch, starting a fresh patch (tied
/// to the selected commit) if none is in progress. The caller has already ensured
/// the selection belongs to the patch's commit.
pub fn applyPatchToggle(app: *App) !void {
    const commit = app.selectedCommit() orelse return;
    const file = app.selectedCommitFile() orelse {
        try app.setMessage("no file selected", .{});
        return;
    };
    if (app.patch_source == null) app.patch_source = try app.allocator.dupe(u8, commit.hash);
    for (app.patch_paths.items, 0..) |p, idx| {
        if (std.mem.eql(u8, p, file.path)) {
            app.allocator.free(app.patch_paths.orderedRemove(idx));
            if (app.patch_line_sel.orderedRemove(idx)) |sel| app.allocator.free(sel);
            if (app.patch_paths.items.len == 0) clearPatch(app);
            try app.setMessage("removed {s} from patch ({d} files)", .{ file.path, app.patch_paths.items.len });
            return;
        }
    }
    try app.patch_paths.append(app.allocator, try app.allocator.dupe(u8, file.path));
    try app.patch_line_sel.append(app.allocator, null); // whole file
    try app.setMessage("added {s} to patch ({d} files)", .{ file.path, app.patch_paths.items.len });
}

/// Concatenate the source commit's per-file diffs into one applyable patch. A
/// file with a line selection contributes only its included lines.
pub fn buildPatchBytes(app: *App) ![]u8 {
    const source = app.patch_source orelse return error.NoPatch;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(app.allocator);
    for (app.patch_paths.items, 0..) |path, idx| {
        const diff = try app.git.diffForCommitFile(source, path, app.config.diff_context);
        defer app.allocator.free(diff);
        if (app.patch_line_sel.items[idx]) |sel| {
            var parsed = diff_mod.parse(app.allocator, diff) catch {
                try out.appendSlice(app.allocator, diff);
                continue;
            };
            defer parsed.deinit(app.allocator);
            const part = diff_mod.buildPartialFilePatch(app.allocator, diff, parsed, sel) catch |err| switch (err) {
                error.EmptySelection => continue, // nothing selected from this file
                else => {
                    try out.appendSlice(app.allocator, diff); // e.g. no-newline hunk
                    continue;
                },
            };
            defer app.allocator.free(part);
            try out.appendSlice(app.allocator, part);
        } else {
            try out.appendSlice(app.allocator, diff);
        }
    }
    return out.toOwnedSlice(app.allocator);
}

/// Number of `\n`-separated lines in `text` (for sizing inclusion arrays).
fn diffLineCount2(text: []const u8) usize {
    if (text.len == 0) return 0;
    return std.mem.count(u8, text, "\n") + 1;
}

/// First byte of the `abs`-th line of `text`, or 0 if out of range / empty.
fn diffLineFirstByte(text: []const u8, abs: usize) u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        if (i == abs) return if (line.len > 0) line[0] else 0;
    }
    return 0;
}

/// True if the `abs`-th line of the patch-view diff is an add/remove line.
fn patchLineIsChange(app: *const App, abs: usize) bool {
    const c = diffLineFirstByte(app.staging_diff, abs);
    return c == '+' or c == '-';
}

/// Open the line-selection view for the selected commit file. If a patch from a
/// different commit is in progress, confirm discarding it first; on confirm the
/// view re-opens here (the original action resumes, not a whole-file add).
pub fn openPatchLineView(app: *App) !void {
    const commit = app.selectedCommit() orelse return app.enterMain();
    if (app.selectedCommitFile() == null) return app.enterMain();
    if (app.patch_source) |src| {
        if (!std.mem.eql(u8, src, commit.hash)) {
            app.patch_reset_resume = .line_view;
            return app.requestConfirmation(.reset_patch, "confirm discard patch", .{});
        }
    }
    return doOpenPatchLineView(app);
}

/// Actually open the patch line view (no patch-conflict check — the caller has
/// cleared any conflicting patch). Kept separate so the confirm handler can
/// resume here without an inferred-error-set cycle.
pub fn doOpenPatchLineView(app: *App) !void {
    const commit = app.selectedCommit() orelse return app.enterMain();
    const file = app.selectedCommitFile() orelse return app.enterMain();
    const diff = app.git.diffForCommitFile(commit.hash, file.path, app.config.diff_context) catch {
        try app.setMessage("could not load the file's diff", .{});
        return;
    };
    staging_mod.clearStaging(app);
    app.staging_path = try app.allocator.dupe(u8, file.path);
    app.staging_diff = diff;
    app.staging = try diff_mod.parse(app.allocator, app.staging_diff);
    app.staging_active = true;
    app.staging_patch_mode = true;
    app.main_origin = app.contentFocus();
    app.focus = .main;

    // Seed the working inclusion from the file's current patch state.
    const n = diffLineCount2(app.staging_diff);
    app.allocator.free(app.patch_work_included);
    app.patch_work_included = try app.allocator.alloc(bool, n);
    const existing = patchLineSelFor(app, file.path);
    const in_patch = patchHasFile(app, file.path);
    for (app.patch_work_included, 0..) |*b, i| {
        b.* = if (existing) |sel| (i < sel.len and sel[i]) else in_patch; // whole-file => all on
    }

    app.staging_anchor = null;
    app.staging_cursor = staging_mod.stagingFirstLine(app);
    app.resetMainView();
    staging_mod.scrollToStagingCursor(app);
    try app.setMessage("space: toggle line/hunk into patch, esc: back", .{});
}

/// Toggle the line(s)/hunk under the cursor in/out of the working patch
/// selection. On the `@@` header line the whole hunk's changes toggle.
pub fn togglePatchInclusion(app: *App) !void {
    const parsed = app.staging orelse return;
    if (parsed.hunks.len == 0) {
        try app.setMessage("no changes in this file", .{});
        return;
    }
    const hunk_index = staging_mod.stagingHunkAt(app, app.staging_cursor) orelse {
        try app.setMessage("move the cursor onto a change", .{});
        return;
    };
    const hunk = parsed.hunks[hunk_index];
    var lo: usize = undefined;
    var hi: usize = undefined;
    if (app.staging_cursor == hunk.start_line) {
        lo = hunk.start_line + 1;
        hi = hunk.end_line -| 1;
    } else {
        lo = @max(@min(app.staging_anchor orelse app.staging_cursor, app.staging_cursor), hunk.start_line + 1);
        hi = @min(@max(app.staging_anchor orelse app.staging_cursor, app.staging_cursor), hunk.end_line -| 1);
    }
    // Toggle: if every change line in the range is already included, remove;
    // otherwise add. Context lines are ignored.
    var all_on = true;
    var any = false;
    var i = lo;
    while (i <= hi and i < app.patch_work_included.len) : (i += 1) {
        if (patchLineIsChange(app, i)) {
            any = true;
            if (!app.patch_work_included[i]) all_on = false;
        }
    }
    if (!any) {
        try app.setMessage("no +/- change in the selection", .{});
        return;
    }
    const target = !all_on;
    i = lo;
    while (i <= hi and i < app.patch_work_included.len) : (i += 1) {
        if (patchLineIsChange(app, i)) app.patch_work_included[i] = target;
    }
    app.staging_anchor = null;
    if (target) {
        try app.setMessage("added to patch", .{});
    } else {
        try app.setMessage("removed from patch", .{});
    }
}

/// Persist the line view's working inclusion into the patch (adding/updating or
/// removing the file), then close the view back to the commit-files list.
pub fn closePatchLineView(app: *App) !void {
    const path = app.staging_path;
    var any = false;
    for (app.patch_work_included, 0..) |inc, i| {
        if (inc and patchLineIsChange(app, i)) {
            any = true;
            break;
        }
    }
    const commit_hash = if (app.selectedCommit()) |c| c.hash else null;

    if (any) {
        if (app.patch_source == null) {
            if (commit_hash) |h| app.patch_source = try app.allocator.dupe(u8, h);
        }
        // Whole-file if every change line is included, else a line selection.
        var whole = true;
        for (app.patch_work_included, 0..) |inc, i| {
            if (patchLineIsChange(app, i) and !inc) {
                whole = false;
                break;
            }
        }
        const sel: ?[]bool = if (whole) null else try app.allocator.dupe(bool, app.patch_work_included);
        errdefer if (sel) |s| app.allocator.free(s);
        try setPatchFileSelection(app, path, sel);
    } else {
        removePatchFile(app, path);
    }

    staging_mod.clearStaging(app);
    app.focus = app.main_origin;
    app.resetMainView();
    try app.updatePreview();
    try app.setMessage("patch: {d} files", .{patchFileCount(app)});
}

/// Set (or add) a file's line selection in the patch. `sel` ownership moves in.
fn setPatchFileSelection(app: *App, path: []const u8, sel: ?[]bool) !void {
    for (app.patch_paths.items, 0..) |p, idx| {
        if (std.mem.eql(u8, p, path)) {
            if (app.patch_line_sel.items[idx]) |old| app.allocator.free(old);
            app.patch_line_sel.items[idx] = sel;
            return;
        }
    }
    try app.patch_paths.append(app.allocator, try app.allocator.dupe(u8, path));
    try app.patch_line_sel.append(app.allocator, sel);
}

fn removePatchFile(app: *App, path: []const u8) void {
    for (app.patch_paths.items, 0..) |p, idx| {
        if (std.mem.eql(u8, p, path)) {
            app.allocator.free(app.patch_paths.orderedRemove(idx));
            if (app.patch_line_sel.orderedRemove(idx)) |s| app.allocator.free(s);
            if (app.patch_paths.items.len == 0) clearPatch(app);
            return;
        }
    }
}
