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
    // Reset is allowed on both the Commits tab and the Reflog tab: resetting
    // HEAD to a reflog entry is the reflog's primary recovery use. The reset
    // menu's action targets `selectedCommit()`, which is the reflog entry when
    // the Reflog tab is active.
    const commit = app.selectedCommit() orelse {
        try app.setMessage("no commit selected", .{});
        return;
    };
    app.mode = .menu;
    app.active_menu = .{ .title = "Reset to commit", .items = &app_mod.commit_reset_menu, .index = 0 };
    try app.setMessage("reset to {s}", .{commit.short_hash});
}

pub fn revertSelectedCommit(app: *App) !void {
    if (app.commits_tab != .commits) {
        try app.setMessage("commit actions apply to the Commits tab", .{});
        return;
    }
    // A contiguous range reverts every selected commit in one git revert,
    // newest-first (matching git revert's argument order).
    if (app.rangeActive() and !app.commitsFilesActive()) {
        if (app.rangeBounds()) |b| {
            if (b.lo != b.hi and b.hi < app.data.commits.len) {
                var hashes: std.ArrayList([]const u8) = .empty;
                defer hashes.deinit(app.allocator);
                var k = b.lo;
                while (k <= b.hi) : (k += 1) try hashes.append(app.allocator, app.data.commits[k].hash);
                const count = b.hi - b.lo + 1;
                app.clearRange();
                return app.requestMutation(.{ .revert_many = hashes.items }, .{ .gerund = "reverting", .command = "git revert", .refresh = App.Refresh.commits_files }, "reverted {d} commits", .{count});
            }
        }
    }
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
    // A contiguous multi-selection applies the action to the whole range.
    // Reword is single-commit only (each commit needs its own message), so it
    // always falls through to the cursor commit.
    if (action != .reword and app.rangeActive() and !app.commitsFilesActive()) {
        if (app.rangeBounds()) |b| {
            if (b.lo != b.hi) return runRebaseRange(app, action, b.lo, b.hi);
        }
    }
    const i = @min(app.commit_index, app.data.commits.len - 1);
    return runRebase(app, action, i, null);
}

/// Build and run the rebase todo for `action` applied to the contiguous commit
/// range [lo, hi] (newest-first indices, lo ≤ hi; lo is nearest HEAD). Every
/// selected commit gets the verb, and for squash/fixup the commit just below
/// the range is the pick anchor.
pub fn runRebaseRange(app: *App, action: RebaseAction, lo: usize, hi: usize) !void {
    const commits = app.data.commits;
    if (hi >= commits.len) return;
    switch (action) {
        .squash, .fixup, .move_down => if (hi + 1 >= commits.len) {
            try app.setMessage("no commit below the selection to combine with", .{});
            return;
        },
        .move_up => if (lo == 0) {
            try app.setMessage("selection is already at the top", .{});
            return;
        },
        else => {},
    }

    const base_index: usize = switch (action) {
        .drop, .edit, .reword, .move_up => hi,
        .squash, .fixup, .move_down => hi + 1,
    };
    const base_ref = try std.fmt.allocPrint(app.allocator, "{s}^", .{commits[base_index].hash});
    defer app.allocator.free(base_ref);

    var aw: std.Io.Writer.Allocating = .init(app.allocator);
    defer aw.deinit();
    try writeRebaseTodoRange(&aw.writer, commits, lo, hi, action);
    const todo = try aw.toOwnedSlice();
    defer app.allocator.free(todo);

    app.clearRange();
    // Keep the cursor on the same commit after the block shifts one row (the
    // cursor sits at an end of the range, so it moves with the block). Applied
    // only on success; the guards above ensured the neighbour exists.
    switch (action) {
        .move_up => app.select_commit_pending = app.commit_index -| 1,
        .move_down => app.select_commit_pending = app.commit_index + 1,
        else => {},
    }
    const count = hi - lo + 1;
    var run_buf: [96]u8 = undefined;
    const shown = std.fmt.bufPrint(&run_buf, "git rebase -i {s}", .{base_ref}) catch "git rebase -i";
    return app.requestMutation(
        .{ .rebase_todo = .{ .base_ref = base_ref, .todo = todo, .message = null } },
        .{ .gerund = "rebasing", .command = shown },
        "{s} ({d} commits)",
        .{ action.label(), count },
    );
}

/// Emit a git-rebase-todo (oldest-first) for `action` over the contiguous
/// newest-first range [lo, hi].
pub fn writeRebaseTodoRange(w: *std.Io.Writer, commits: []const model.Commit, lo: usize, hi: usize, action: RebaseAction) !void {
    switch (action) {
        .drop, .edit, .reword => {
            var k = hi;
            while (true) : (k -= 1) {
                const word = if (k >= lo and k <= hi) action.word() else "pick";
                try w.print("{s} {s}\n", .{ word, commits[k].hash });
                if (k == 0) break;
            }
        },
        .squash, .fixup => {
            // The commit just below the range (commits[hi+1]) stays "pick" and
            // is the anchor every selected commit melds into.
            var k = hi + 1;
            while (true) : (k -= 1) {
                const word = if (k >= lo and k <= hi) action.word() else "pick";
                try w.print("{s} {s}\n", .{ word, commits[k].hash });
                if (k == 0) break;
            }
        },
        .move_up => {
            // The block [lo, hi] moves one step newer, swapping with commits[lo-1].
            // Oldest-first: commits[lo-1], the block (hi..lo), then commits[lo-2..0].
            try w.print("pick {s}\n", .{commits[lo - 1].hash});
            var k = hi;
            while (k >= lo) : (k -= 1) {
                try w.print("pick {s}\n", .{commits[k].hash});
                if (k == lo) break;
            }
            if (lo >= 2) {
                k = lo - 2;
                while (true) : (k -= 1) {
                    try w.print("pick {s}\n", .{commits[k].hash});
                    if (k == 0) break;
                }
            }
        },
        .move_down => {
            // The block [lo, hi] moves one step older, swapping with commits[hi+1].
            // Oldest-first: the block (hi..lo), commits[hi+1], then commits[lo-1..0].
            var k = hi;
            while (k >= lo) : (k -= 1) {
                try w.print("pick {s}\n", .{commits[k].hash});
                if (k == lo) break;
            }
            try w.print("pick {s}\n", .{commits[hi + 1].hash});
            if (lo > 0) {
                k = lo - 1;
                while (true) : (k -= 1) {
                    try w.print("pick {s}\n", .{commits[k].hash});
                    if (k == 0) break;
                }
            }
        },
    }
}

/// `a`: change the selected commit's author. With `author` null, reset it to the
/// configured git user; otherwise set it to the given "Name <email>". Runs a
/// non-interactive rebase whose todo `exec`s `git commit --amend` at the target,
/// so it works for any commit, not just HEAD. Commits tab only.
pub fn amendCommitAuthor(app: *App, author: ?[]const u8) !void {
    if (app.commits_tab != .commits) {
        try app.setMessage("author edits apply to the Commits tab", .{});
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

    // The amend command run by the rebase's `exec` line (sh -c).
    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(app.allocator);
    try cmd_buf.appendSlice(app.allocator, "git commit --amend --no-edit");
    if (author) |a| {
        try cmd_buf.appendSlice(app.allocator, " --author=");
        try shellQuote(&cmd_buf, app.allocator, a);
    } else {
        try cmd_buf.appendSlice(app.allocator, " --reset-author");
    }

    const base_ref = try std.fmt.allocPrint(app.allocator, "{s}^", .{commits[i].hash});
    defer app.allocator.free(base_ref);

    // Oldest-first todo: pick the target, exec the amend, then pick newer commits.
    var aw: std.Io.Writer.Allocating = .init(app.allocator);
    defer aw.deinit();
    var k = i;
    while (true) : (k -= 1) {
        try aw.writer.print("pick {s}\n", .{commits[k].hash});
        if (k == i) try aw.writer.print("exec {s}\n", .{cmd_buf.items});
        if (k == 0) break;
    }
    const todo = try aw.toOwnedSlice();
    defer app.allocator.free(todo);

    return app.requestMutation(
        .{ .rebase_todo = .{ .base_ref = base_ref, .todo = todo, .message = null } },
        .{ .gerund = "editing author", .command = "git rebase -i" },
        "updated author of {s}",
        .{commits[i].short_hash},
    );
}

/// `d` in a commit's file list: drop the selected file(s)' changes from that
/// commit, rewriting history. Runs a non-interactive rebase whose `exec` line
/// (after picking the target) restores each file to its parent version — or
/// removes it if the commit introduced it — then `git commit --amend`s the
/// target. Commits-panel drill only (the file list must belong to a commit on
/// the current branch's history).
pub fn discardFilesFromCommit(app: *App) !void {
    if (!app.commitsFilesActive() or app.commits_tab != .commits) {
        try app.setMessage("discard-from-commit works in a commit's file list", .{});
        return;
    }
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress operation first (m)", .{});
        return;
    }
    const commits = app.data.commits;
    if (commits.len == 0) {
        try app.setMessage("no commit selected", .{});
        return;
    }
    const i = @min(app.commit_index, commits.len - 1);

    // Collect the target file paths: a multi-file range, else the cursor file.
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(app.allocator);
    if (app.rangeActive() and !app.tree_view) {
        if (app.rangeBounds()) |b| {
            if (b.lo != b.hi) {
                var k = b.lo;
                while (k <= b.hi and k < app.commit_files.len) : (k += 1) {
                    try paths.append(app.allocator, app.commit_files[k].path);
                }
            }
        }
    }
    if (paths.items.len == 0) {
        const cf = app.selectedCommitFile() orelse {
            try app.setMessage("no file selected", .{});
            return;
        };
        try paths.append(app.allocator, cf.path);
    }

    // The amend command the rebase's `exec` line runs (sh -c). For each file:
    // restore the parent's version if it existed there, otherwise remove it.
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(app.allocator);
    for (paths.items) |p| {
        const spec = try std.fmt.allocPrint(app.allocator, "HEAD^:{s}", .{p});
        defer app.allocator.free(spec);
        try cmd.appendSlice(app.allocator, "if git cat-file -e ");
        try shellQuote(&cmd, app.allocator, spec);
        try cmd.appendSlice(app.allocator, " 2>/dev/null; then git checkout HEAD^ -- ");
        try shellQuote(&cmd, app.allocator, p);
        try cmd.appendSlice(app.allocator, "; else git rm -f -- ");
        try shellQuote(&cmd, app.allocator, p);
        try cmd.appendSlice(app.allocator, "; fi; ");
    }
    try cmd.appendSlice(app.allocator, "git commit --amend --no-edit");

    const base_ref = try std.fmt.allocPrint(app.allocator, "{s}^", .{commits[i].hash});
    defer app.allocator.free(base_ref);

    // Oldest-first todo: pick the target, exec the discard+amend, then pick newer.
    var aw: std.Io.Writer.Allocating = .init(app.allocator);
    defer aw.deinit();
    var k = i;
    while (true) : (k -= 1) {
        try aw.writer.print("pick {s}\n", .{commits[k].hash});
        if (k == i) try aw.writer.print("exec {s}\n", .{cmd.items});
        if (k == 0) break;
    }
    const todo = try aw.toOwnedSlice();
    defer app.allocator.free(todo);

    const count = paths.items.len;
    app.clearRange();
    return app.requestMutation(
        .{ .rebase_todo = .{ .base_ref = base_ref, .todo = todo, .message = null } },
        .{ .gerund = "discarding from commit", .command = "git rebase -i", .refresh = App.Refresh.commits_files },
        "discarded {d} file(s) from {s}",
        .{ count, commits[i].short_hash },
    );
}

/// POSIX single-quote `s` into `out` for safe inclusion in an `sh -c` line.
fn shellQuote(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
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
    // Keep the moved commit under the cursor: after the reorder lands, move_up
    // puts it one row newer (smaller index), move_down one row older. Applied
    // only on success (a conflicting rebase clears it), so a failed move leaves
    // the cursor put. Guards above already ensured the neighbour exists.
    switch (action) {
        .move_up => app.select_commit_pending = i - 1,
        .move_down => app.select_commit_pending = i + 1,
        else => {},
    }
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
