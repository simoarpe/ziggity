//! Commit history operations driven from the Commits panel: reset (menu),
//! revert, the interactive-rebase actions (drop/squash/fixup/edit/reword/move)
//! and their todo generation, create-fixup, and autosquash. Free functions over
//! `*App`; they run through the shared async mutation worker.
const std = @import("std");

const app_mod = @import("app.zig");
const model = @import("model.zig");

const App = app_mod.App;
const RebaseAction = app_mod.RebaseAction;

pub fn startCommitResetMenu(app: *App) !void {
    const commit = try commitForAction(app) orelse return;
    app.mode = .menu;
    app.active_menu = .{ .title = "Reset to commit", .items = &app_mod.commit_reset_menu, .index = 0 };
    try app.setMessage("reset to {s}", .{commit.short_hash});
}

pub fn revertSelectedCommit(app: *App) !void {
    const commit = try commitForAction(app) orelse return;
    return app.requestMutation(.{ .revert = commit.hash }, .{ .gerund = "reverting", .command = "git revert", .refresh = App.Refresh.commits_files }, "reverted {s}", .{commit.short_hash});
}

pub fn rebaseSelectedCommit(app: *App, action: RebaseAction) !void {
    if (app.commits_tab != .commits) {
        try app.setMessage("rebase actions apply to the Commits tab", .{});
        return;
    }
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress rebase/merge first (m)", .{});
        return;
    }
    if (app.data.commits.len == 0) {
        try app.setMessage("no commit selected", .{});
        return;
    }
    const i = @min(app.commit_index, app.data.commits.len - 1);
    return runRebase(app, action, i, null);
}

/// Build the rebase todo + base ref for `action` on commit index `i` (in the
/// newest-first commit list), run it, and report.
pub fn runRebase(app: *App, action: RebaseAction, i: usize, message: ?[]const u8) !void {
    const commits = app.data.commits;
    const base_index: usize = switch (action) {
        .drop, .edit, .reword, .move_up => i,
        .squash, .fixup, .move_down => i + 1,
    };
    switch (action) {
        .squash, .fixup, .move_down => if (i + 1 >= commits.len) {
            try app.setMessage("no commit below to combine with", .{});
            return;
        },
        .move_up => if (i == 0) {
            try app.setMessage("commit is already at the top", .{});
            return;
        },
        else => {},
    }

    const base_ref = try std.fmt.allocPrint(app.allocator, "{s}^", .{commits[base_index].hash});
    defer app.allocator.free(base_ref);

    var aw: std.Io.Writer.Allocating = .init(app.allocator);
    defer aw.deinit();
    try writeRebaseTodo(&aw.writer, commits, i, action);
    const todo = try aw.toOwnedSlice();
    defer app.allocator.free(todo);

    var run_buf: [96]u8 = undefined;
    const shown = std.fmt.bufPrint(&run_buf, "git rebase -i {s}", .{base_ref}) catch "git rebase -i";
    return app.requestMutation(
        .{ .rebase_todo = .{ .base_ref = base_ref, .todo = todo, .message = message } },
        .{ .gerund = "rebasing", .command = shown },
        "{s}",
        .{action.label()},
    );
}

/// Emit a git-rebase-todo (oldest-first) for `action` on commit index `i`.
pub fn writeRebaseTodo(w: *std.Io.Writer, commits: []const model.Commit, i: usize, action: RebaseAction) !void {
    switch (action) {
        .drop, .edit, .reword => {
            var k = i;
            while (true) : (k -= 1) {
                const word = if (k == i) action.word() else "pick";
                try w.print("{s} {s}\n", .{ word, commits[k].hash });
                if (k == 0) break;
            }
        },
        .squash, .fixup => {
            var k = i + 1;
            while (true) : (k -= 1) {
                const word = if (k == i) action.word() else "pick";
                try w.print("{s} {s}\n", .{ word, commits[k].hash });
                if (k == 0) break;
            }
        },
        .move_down => {
            // Swap i with i+1 (move the commit one step older).
            try w.print("pick {s}\n", .{commits[i].hash});
            try w.print("pick {s}\n", .{commits[i + 1].hash});
            if (i > 0) {
                var k = i - 1;
                while (true) : (k -= 1) {
                    try w.print("pick {s}\n", .{commits[k].hash});
                    if (k == 0) break;
                }
            }
        },
        .move_up => {
            // Swap i with i-1 (move the commit one step newer).
            try w.print("pick {s}\n", .{commits[i - 1].hash});
            try w.print("pick {s}\n", .{commits[i].hash});
            if (i >= 2) {
                var k = i - 2;
                while (true) : (k -= 1) {
                    try w.print("pick {s}\n", .{commits[k].hash});
                    if (k == 0) break;
                }
            }
        },
    }
}

/// Validate that a commit action can run: the Commits panel must be on the
/// Commits tab (not Reflog) with a commit selected.
pub fn commitForAction(app: *App) !?model.Commit {
    if (app.commits_tab != .commits) {
        try app.setMessage("commit actions apply to the Commits tab", .{});
        return null;
    }
    return app.selectedCommit() orelse {
        try app.setMessage("no commit selected", .{});
        return null;
    };
}

/// Commit the staged changes as a `fixup!` of the selected commit.
pub fn createFixupCommit(app: *App) !void {
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress operation first (m)", .{});
        return;
    }
    const commit = try commitForAction(app) orelse return;
    if (app.data.stagedCount() == 0) {
        try app.setMessage("stage changes to create a fixup commit", .{});
        return;
    }
    return app.requestMutation(.{ .create_fixup = commit.hash }, .{ .gerund = "creating fixup", .command = "git commit --fixup", .refresh = App.Refresh.commits_files }, "created fixup! for {s}", .{commit.short_hash});
}

/// Autosquash fixup!/squash! commits above (and including) the selected one.
pub fn autosquashFixups(app: *App) !void {
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress operation first (m)", .{});
        return;
    }
    const commit = try commitForAction(app) orelse return;
    const base = try std.fmt.allocPrint(app.allocator, "{s}^", .{commit.hash});
    defer app.allocator.free(base);
    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git rebase -i --autosquash {s}", .{base}) catch "git rebase -i --autosquash";
    return app.requestMutation(.{ .autosquash = base }, .{ .gerund = "autosquashing", .command = cmd }, "autosquashed fixups", .{});
}
