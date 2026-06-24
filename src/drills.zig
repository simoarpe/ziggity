//! The panel "drills": the Commits panel into a commit's file list, and the
//! Branches panel into a branch's sub-commits and then a commit's files. Open/
//! close move between levels; the `*AfterRefresh` reloaders keep a drilled-in
//! view consistent when a background refresh replaces the underlying data.
//! Free functions over `*App`; the drill state lives on `App`.
const std = @import("std");

const app_mod = @import("app.zig");
const model = @import("model.zig");

const App = app_mod.App;

// --- Commits panel: its own commit-files drill (log -> a commit's files) ---

pub fn openCommitFiles(app: *App) !void {
    const commit = app.selectedCommit() orelse {
        try app.setMessage("no commit selected", .{});
        return;
    };
    const files = try app.git.loadCommitFiles(commit.hash);
    model.deinitCommitFiles(app.allocator, app.commit_files);
    app.commit_files = files;
    app.commit_file_index = 0;
    app.commit_files_active = true;
    try app.syncCommitFilesTree();
    app.resetMainView();
    app.resetListHScroll(.commits);
    try app.updatePreview();
    try app.setMessage("{d} files in {s}", .{ files.len, commit.short_hash });
}

pub fn closeCommitFiles(app: *App) !void {
    deactivateCommitFiles(app);
    app.resetMainView();
    app.resetListHScroll(.commits);
    try app.updatePreview();
}

pub fn deactivateCommitFiles(app: *App) void {
    model.deinitCommitFiles(app.allocator, app.commit_files);
    app.commit_files = &.{};
    app.commit_file_index = 0;
    app.commit_files_active = false;
    app.commit_tree.clear(app.allocator);
}

/// Reload the Commits panel's file list after a refresh; drop it if its commit
/// is gone. Independent of the Branches drill.
pub fn reloadCommitFilesAfterRefresh(app: *App) void {
    const list = app.activeCommits();
    if (list.len == 0) return deactivateCommitFiles(app);
    const commit = list[@min(app.activeCommitIndex(), list.len - 1)];
    const files = app.git.loadCommitFiles(commit.hash) catch return deactivateCommitFiles(app);
    model.deinitCommitFiles(app.allocator, app.commit_files);
    app.commit_files = files;
    app.commit_file_index = if (app.commit_files.len == 0) 0 else @min(app.commit_file_index, app.commit_files.len - 1);
    app.syncCommitFilesTree() catch {};
}

// --- Branches panel: its own drill (branch -> sub-commits -> files) ---

/// Drill from a branch/tag in the Branches panel into its commits (the
/// "sub-commits" view): the Branches panel then lists `ref`'s commits.
pub fn openBranchCommits(app: *App, ref: []const u8) !void {
    const commits = try app.git.loadCommits(ref, 100);
    model.deinitCommits(app.allocator, app.branch_commits);
    app.branch_commits = commits;
    app.branch_commit_index = 0;
    app.allocator.free(app.branch_commits_ref);
    app.branch_commits_ref = try app.allocator.dupe(u8, ref);
    app.branch_commits_active = true;
    if (app.listView(.branches)) |lv| {
        lv.scroll = 0;
        lv.hscroll = 0;
    }
    app.resetMainView();
    try app.updatePreview();
    try app.setMessage("{d} commits in {s}", .{ commits.len, ref });
}

/// Exit the sub-commits view, back to the branch list.
pub fn closeBranchCommits(app: *App) !void {
    deactivateBranchCommits(app);
    if (app.listView(.branches)) |lv| {
        lv.scroll = 0;
        lv.hscroll = 0;
    }
    app.resetMainView();
    try app.updatePreview();
}

pub fn deactivateBranchCommits(app: *App) void {
    // Closing the sub-commits list also drops the files level beneath it.
    deactivateBranchFiles(app);
    model.deinitCommits(app.allocator, app.branch_commits);
    app.branch_commits = &.{};
    app.branch_commit_index = 0;
    app.branch_commits_active = false;
}

pub fn openBranchFiles(app: *App) !void {
    const commit = app.selectedCommit() orelse {
        try app.setMessage("no commit selected", .{});
        return;
    };
    const files = try app.git.loadCommitFiles(commit.hash);
    model.deinitCommitFiles(app.allocator, app.branch_files);
    app.branch_files = files;
    app.branch_file_index = 0;
    app.branch_files_active = true;
    try app.syncBranchFilesTree();
    app.resetMainView();
    app.resetListHScroll(.branches);
    try app.updatePreview();
    try app.setMessage("{d} files in {s}", .{ files.len, commit.short_hash });
}

pub fn closeBranchFiles(app: *App) !void {
    deactivateBranchFiles(app);
    app.resetMainView();
    app.resetListHScroll(.branches);
    try app.updatePreview();
}

pub fn deactivateBranchFiles(app: *App) void {
    model.deinitCommitFiles(app.allocator, app.branch_files);
    app.branch_files = &.{};
    app.branch_file_index = 0;
    app.branch_files_active = false;
    app.branch_tree.clear(app.allocator);
}

/// Reload the sub-commits list from its ref after a refresh, keeping the
/// selection position. If the ref is gone (no commits come back), exit the
/// whole Branches drill back to the branch list.
pub fn reloadBranchCommitsAfterRefresh(app: *App) void {
    const commits = app.git.loadCommits(app.branch_commits_ref, 100) catch null;
    if (commits == null or commits.?.len == 0) {
        if (commits) |c| model.deinitCommits(app.allocator, c);
        deactivateBranchCommits(app); // also drops the files level
        return;
    }
    model.deinitCommits(app.allocator, app.branch_commits);
    app.branch_commits = commits.?;
    app.branch_commit_index = @min(app.branch_commit_index, app.branch_commits.len - 1);
}

/// Reload the Branches drill's file list after a refresh; drop it if its
/// sub-commit is gone. Independent of the Commits panel.
pub fn reloadBranchFilesAfterRefresh(app: *App) void {
    if (app.branch_commits.len == 0) return deactivateBranchFiles(app);
    const commit = app.branch_commits[@min(app.branch_commit_index, app.branch_commits.len - 1)];
    const files = app.git.loadCommitFiles(commit.hash) catch return deactivateBranchFiles(app);
    model.deinitCommitFiles(app.allocator, app.branch_files);
    app.branch_files = files;
    app.branch_file_index = if (app.branch_files.len == 0) 0 else @min(app.branch_file_index, app.branch_files.len - 1);
    app.syncBranchFilesTree() catch {};
}
