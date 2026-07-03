//! The commit editor: the create/reword message prompt (its key handling and
//! submit), amend, and preservation of an unfinalized "create" message in
//! memory and on disk (`.git/ZIGGITY_PENDING_COMMIT`) so it survives across
//! reopens and restarts. Free functions over `*App`; the editor buffers and
//! preserved-draft fields live on App.
const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const commitops_mod = @import("commitops.zig");

const App = app_mod.App;

pub fn startCommitPrompt(app: *App, no_verify: bool) !void {
    if (app.data.stagedCount() == 0) {
        try app.setMessage("stage files before committing", .{});
        return;
    }
    app.mode = .commit_prompt;
    app.commit_action = .create;
    app.commit_no_verify = no_verify;
    app.commit_field = .subject;
    app.commit_buffer.clearRetainingCapacity();
    app.commit_body_buffer.clearRetainingCapacity();
    // The first time the dialog opens this session, pick up a draft left on disk
    // by a previous run (if nothing is preserved in memory already).
    if (!app.commit_draft_loaded) {
        app.commit_draft_loaded = true;
        if (app.commit_preserved_subject.len == 0 and app.commit_preserved_body.len == 0) loadCommitDraftFile(app);
    }
    // Restore an unfinalized message from a previous (cancelled) attempt.
    const restored = app.commit_preserved_subject.len > 0 or app.commit_preserved_body.len > 0;
    if (restored) {
        try app.commit_buffer.appendSlice(app.allocator, app.commit_preserved_subject);
        try app.commit_body_buffer.appendSlice(app.allocator, app.commit_preserved_body);
    }
    // With no draft to restore, let the repo's prepare-commit-msg hook seed the
    // fields (e.g. a branch-derived ticket prefix) as an interactive commit
    // would — see git.prepareCommitMsg. Skipped when the message is preserved so
    // the hook never clobbers text the user was in the middle of writing.
    var seeded = false;
    if (!restored and app.config.prepare_commit_msg_hook and app.git.git_dir.len > 0) {
        if (app.git.prepareCommitMsg() catch null) |seed| {
            defer app.allocator.free(seed);
            if (seed.len > 0) {
                const nl = std.mem.indexOfScalar(u8, seed, '\n');
                const subject = if (nl) |i| seed[0..i] else seed;
                const body = if (nl) |i| std.mem.trimStart(u8, seed[i + 1 ..], "\n") else "";
                try app.commit_buffer.appendSlice(app.allocator, subject);
                try app.commit_body_buffer.appendSlice(app.allocator, body);
                seeded = subject.len > 0 or body.len > 0;
            }
        }
    }
    app.commit_cursor = app.commit_buffer.items.len;
    app.commit_body_cursor = app.commit_body_buffer.items.len;
    app.commit_scroll = 0;
    app.commit_body_scroll_x = 0;
    app.commit_body_scroll_y = 0;
    if (restored) {
        try app.setMessage("enter commit message (restored draft)", .{});
    } else if (seeded) {
        try app.setMessage("enter commit message (prefilled by prepare-commit-msg)", .{});
    } else {
        try app.setMessage("enter commit message", .{});
    }
}

/// Preserve the live editor's content as the unfinalized create-commit message,
/// or drop any prior draft if the editor is now empty.
pub fn savePreservedCommitMessage(app: *App) !void {
    const subj_empty = std.mem.trim(u8, app.commit_buffer.items, " \t\r\n").len == 0;
    const body_empty = std.mem.trim(u8, app.commit_body_buffer.items, " \t\r\n").len == 0;
    if (subj_empty and body_empty) return clearPreservedCommitMessage(app);
    const subj = try app.allocator.dupe(u8, app.commit_buffer.items);
    errdefer app.allocator.free(subj);
    const body = try app.allocator.dupe(u8, app.commit_body_buffer.items);
    app.allocator.free(app.commit_preserved_subject);
    app.allocator.free(app.commit_preserved_body);
    app.commit_preserved_subject = subj;
    app.commit_preserved_body = body;
    writeCommitDraftFile(app);
}

pub fn clearPreservedCommitMessage(app: *App) void {
    app.allocator.free(app.commit_preserved_subject);
    app.allocator.free(app.commit_preserved_body);
    app.commit_preserved_subject = &.{};
    app.commit_preserved_body = &.{};
    if (app.commit_draft_path) |path| std.Io.Dir.deleteFile(.cwd(), app.git.io, path) catch {};
}

/// Persist the in-memory draft to `.git/ZIGGITY_PENDING_COMMIT` so it survives
/// quitting (best-effort; stored as "subject\n<body>").
pub fn writeCommitDraftFile(app: *App) void {
    const path = app.commit_draft_path orelse return;
    const bytes = std.fmt.allocPrint(app.allocator, "{s}\n{s}", .{ app.commit_preserved_subject, app.commit_preserved_body }) catch return;
    defer app.allocator.free(bytes);
    std.Io.Dir.writeFile(.cwd(), app.git.io, .{ .sub_path = path, .data = bytes }) catch {};
}

/// Load a draft persisted by a previous run into the in-memory fields. The
/// stored format splits subject from body at the first newline.
pub fn loadCommitDraftFile(app: *App) void {
    const path = app.commit_draft_path orelse return;
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), app.git.io, path, app.allocator, .limited(1 << 20)) catch return;
    defer app.allocator.free(bytes);
    const nl = std.mem.indexOfScalar(u8, bytes, '\n');
    const subject = if (nl) |i| bytes[0..i] else bytes;
    const body = if (nl) |i| bytes[i + 1 ..] else "";
    if (subject.len == 0 and body.len == 0) return;
    const subj = app.allocator.dupe(u8, subject) catch return;
    const bod = app.allocator.dupe(u8, body) catch {
        app.allocator.free(subj);
        return;
    };
    app.allocator.free(app.commit_preserved_subject);
    app.allocator.free(app.commit_preserved_body);
    app.commit_preserved_subject = subj;
    app.commit_preserved_body = bod;
}

/// Open the commit editor pre-filled with a commit's subject/body to reword it
/// (runs an interactive rebase on submit).
pub fn startReword(app: *App) !void {
    if (app.commits_tab != .commits) {
        try app.setMessage("reword applies to the Commits tab", .{});
        return;
    }
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress operation first (m)", .{});
        return;
    }
    if (app.data.commits.len == 0) {
        try app.setMessage("no commit selected", .{});
        return;
    }
    const i = @min(app.commit_index, app.data.commits.len - 1);
    const commit = app.data.commits[i];
    const body = app.git.commitBody(commit.hash) catch try app.allocator.alloc(u8, 0);
    defer app.allocator.free(body);

    app.mode = .commit_prompt;
    app.commit_action = .reword;
    app.commit_reword_index = i;
    app.commit_field = .subject;
    app.commit_buffer.clearRetainingCapacity();
    try app.commit_buffer.appendSlice(app.allocator, commit.subject);
    app.commit_body_buffer.clearRetainingCapacity();
    try app.commit_body_buffer.appendSlice(app.allocator, body);
    app.commit_cursor = app.commit_buffer.items.len;
    app.commit_body_cursor = app.commit_body_buffer.items.len;
    app.commit_scroll = 0;
    app.commit_body_scroll_x = 0;
    app.commit_body_scroll_y = 0;
    try app.setMessage("reword commit", .{});
}

pub fn amendLastCommit(app: *App) !void {
    if (app.data.state != .clean) {
        try app.setMessage("finish the in-progress operation first (m)", .{});
        return;
    }
    if (app.data.stagedCount() == 0) {
        try app.setMessage("stage changes to amend into the last commit", .{});
        return;
    }
    return app.requestMutation(.amend, .{ .gerund = "amending", .command = "git commit --amend", .refresh = App.Refresh.commit }, "amended last commit", .{});
}

pub fn handleCommitPromptKey(app: *App, key: vaxis.Key) !void {
    if (app.isEscapeKey(key)) {
        app.mode = .normal;
        // Keep an unfinalized "create" message so reopening restores it; a
        // reword's text is tied to its commit, so it is not preserved.
        if (app.commit_action == .create) try savePreservedCommitMessage(app);
        app.commit_buffer.clearRetainingCapacity();
        app.commit_body_buffer.clearRetainingCapacity();
        try app.setMessage("commit cancelled", .{});
        return;
    }
    // Tab switches between the subject and body fields.
    if (key.matches(vaxis.Key.tab, .{})) {
        app.commit_field = if (app.commit_field == .subject) .body else .subject;
        return;
    }
    // Enter submits from the subject; in the body it inserts a newline.
    if (app.isEnterKey(key)) {
        if (app.commit_field == .body) {
            try app.commit_body_buffer.insertSlice(app.allocator, app.commit_body_cursor, "\n");
            app.commit_body_cursor += 1;
            return;
        }
        return submitCommit(app);
    }
    const buffer = if (app.commit_field == .subject) &app.commit_buffer else &app.commit_body_buffer;
    const cursor = if (app.commit_field == .subject) &app.commit_cursor else &app.commit_body_cursor;
    _ = try app.editLine(buffer, cursor, key);
}

pub fn submitCommit(app: *App) !void {
    const subject = std.mem.trim(u8, app.commit_buffer.items, " \t\r\n");
    if (subject.len == 0) {
        try app.setMessage("commit message cannot be empty", .{});
        return;
    }
    const body = std.mem.trim(u8, app.commit_body_buffer.items, " \t\r\n");
    const message = if (body.len > 0)
        try std.fmt.allocPrint(app.allocator, "{s}\n\n{s}", .{ subject, body })
    else
        try app.allocator.dupe(u8, subject);
    defer app.allocator.free(message);

    const action = app.commit_action;
    const reword_index = app.commit_reword_index;
    app.mode = .normal;
    app.commit_buffer.clearRetainingCapacity();
    app.commit_body_buffer.clearRetainingCapacity();
    // The message is being committed: drop any preserved draft.
    clearPreservedCommitMessage(app);

    switch (action) {
        // Run the commit off-thread (close the panel first, then commit via a
        // waiting status): the dialog disappears at once and pre-commit hooks /
        // signing / a slow `git status` no longer block it. The refresh is
        // scoped to the views a commit changes.
        .create => return app.requestMutation(.{ .commit = .{ .message = message, .no_verify = app.commit_no_verify } }, .{ .gerund = "committing", .command = if (app.commit_no_verify) "git commit --no-verify" else "git commit", .refresh = App.Refresh.commit }, "commit created", .{}),
        .reword => return commitops_mod.runRebase(app, .reword, reword_index, message),
    }
}
