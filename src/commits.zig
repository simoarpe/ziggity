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
    app.resetCommitAiState(); // fresh dialog instance: bump generation, clear state
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
    app.commit_body_last_caret = std.math.maxInt(usize); // force the caret into view on open
    app.commit_sel_anchor = null;
    app.commit_mouse_selecting = false;
    if (restored) {
        try app.setMessage("enter commit message (restored draft)", .{});
    } else if (seeded) {
        try app.setMessage("enter commit message (prefilled by prepare-commit-msg)", .{});
    } else {
        try app.setMessage("enter commit message", .{});
    }
    // Automatic AI generation on open, when configured. Only for empty fields, so
    // a restored draft or hook seed is never clobbered. Title and description
    // requests start independently (concurrently), neither waiting on the other.
    if (app.config.aiConfigured()) {
        const subj_empty = std.mem.trim(u8, app.commit_buffer.items, " \t\r\n").len == 0;
        const body_empty = std.mem.trim(u8, app.commit_body_buffer.items, " \t\r\n").len == 0;
        if (app.config.auto_generate_commit_title and subj_empty) try app.requestAiGeneration(.title);
        if (app.config.auto_generate_commit_description and body_empty) try app.requestAiGeneration(.description);
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
    app.resetCommitAiState();
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
    app.commit_body_last_caret = std.math.maxInt(usize); // force the caret into view on open
    app.commit_sel_anchor = null;
    app.commit_mouse_selecting = false;
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
    // Confirm first (amend rewrites HEAD and is awkward to undo); the accept
    // path runs the actual `git commit --amend`. `skip_confirm.amend` bypasses
    // the prompt for anyone who wants the old instant behaviour back.
    return app.requestConfirmation(.amend, "confirm amend last commit", .{});
}

pub fn handleCommitPromptKey(app: *App, key: vaxis.Key) !void {
    // Mid-paste, esc is part of the pasted content, not a cancel.
    if (app.isEscapeKey(key) and !app.pasting) {
        app.mode = .normal;
        // Keep an unfinalized "create" message so reopening restores it; a
        // reword's text is tied to its commit, so it is not preserved.
        if (app.commit_action == .create) try savePreservedCommitMessage(app);
        app.commit_buffer.clearRetainingCapacity();
        app.commit_body_buffer.clearRetainingCapacity();
        app.commit_sel_anchor = null;
        app.commit_mouse_selecting = false;
        app.resetCommitAiState(); // ignore any in-flight AI result for this dialog
        try app.setMessage("commit cancelled", .{});
        return;
    }
    // ctrl+g: generate/regenerate the focused field with AI (when configured).
    // Only for `create` — AI describes the staged diff, which is meaningless for
    // a reword of an existing commit.
    if (key.matches('g', .{ .ctrl = true })) {
        if (app.commit_action == .create and app.config.aiConfigured()) {
            const field: @import("aiauthor.zig").Field = if (app.commit_field == .subject) .title else .description;
            try app.requestAiGeneration(field);
        }
        return;
    }
    // Tab switches between the subject and body fields (dropping any selection,
    // which is scoped to one field).
    if (key.matches(vaxis.Key.tab, .{})) {
        app.commit_field = if (app.commit_field == .subject) .body else .subject;
        app.commit_sel_anchor = null;
        return;
    }
    // Enter submits from the subject; in the body it inserts a newline (replacing
    // any selection). While pasting, a newline never submits: in the subject it
    // moves to the body (so the first pasted line is the subject and the rest
    // becomes the body), and in the body it inserts a literal line break.
    if (app.isEnterKey(key)) {
        if (app.commit_field == .body) {
            _ = app.deleteCommitSelection();
            try app.commit_body_buffer.insertSlice(app.allocator, app.commit_body_cursor, "\n");
            app.commit_body_cursor += 1;
            app.commit_sel_anchor = null;
            app.bumpCommitFieldRevision(.body); // a real edit — invalidates a stale AI body
            return;
        }
        if (app.pasting) {
            app.commit_field = .body;
            return;
        }
        return submitCommit(app);
    }

    const is_body = app.commit_field == .body;
    const buffer = if (is_body) &app.commit_body_buffer else &app.commit_buffer;
    const cursor = if (is_body) &app.commit_body_cursor else &app.commit_cursor;

    // ctrl+c copies the current selection (no-op if there is none).
    if (key.matches('c', .{ .ctrl = true })) {
        try app.copyCommitSelection();
        return;
    }

    // Shift + a caret move grows the selection from a fixed anchor.
    if (key.mods.shift) {
        if (App.caretTarget(buffer.items, cursor.*, key, is_body)) |target| {
            if (app.commit_sel_anchor == null) app.commit_sel_anchor = cursor.*;
            cursor.* = target;
            if (app.commit_sel_anchor.? == cursor.*) app.commit_sel_anchor = null; // collapsed onto the anchor
            return;
        }
    } else {
        // A plain caret move (arrows, word moves, home/end) collapses any
        // selection and repositions the caret — never bumps the field revision.
        if (App.caretTarget(buffer.items, cursor.*, key, is_body)) |target| {
            app.commit_sel_anchor = null;
            cursor.* = target;
            return;
        }
    }

    // From here it is editing. A live selection is replaced or removed first.
    if (app.commitSelRange() != null) {
        // Backspace / delete simply remove the selection.
        if (app.isBackspaceKey(key) or key.matches(vaxis.Key.delete, .{})) {
            _ = app.deleteCommitSelection();
            app.bumpCommitFieldRevision(app.commit_field);
            return;
        }
        // A typed character replaces the selection: drop it, then insert below.
        if (isTextInsertion(key)) _ = app.deleteCommitSelection();
    }

    // A content edit bumps the field revision so an AI result from before the
    // edit is discarded; a cursor-only move must not. Either way an edit or move
    // collapses the selection.
    switch (try app.editLine(buffer, cursor, key)) {
        .changed => {
            app.commit_sel_anchor = null;
            app.bumpCommitFieldRevision(app.commit_field);
        },
        .moved => app.commit_sel_anchor = null,
        .ignored => {},
    }
}

/// Whether a key event is a printable character insertion (matching the rule in
/// `editLine`), so a live selection can be replaced before the character lands.
fn isTextInsertion(key: vaxis.Key) bool {
    if (key.text) |t| return !key.mods.ctrl and !key.mods.alt and t.len > 0 and t[0] >= 0x20;
    return false;
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
    app.resetCommitAiState(); // dialog closing: ignore any in-flight AI result
    // Preserve the draft across the async commit so a failure (a rejecting
    // pre-commit hook, a signing error, nothing staged…) keeps the message
    // instead of discarding it — `completeMutation` drops it once the commit
    // actually lands. A reword's text is tied to its commit, so it isn't kept.
    if (action == .create) try savePreservedCommitMessage(app) else clearPreservedCommitMessage(app);
    app.commit_buffer.clearRetainingCapacity();
    app.commit_body_buffer.clearRetainingCapacity();
    app.commit_sel_anchor = null;
    app.commit_mouse_selecting = false;

    switch (action) {
        // Run the commit off-thread (close the panel first, then commit via a
        // waiting status): the dialog disappears at once and pre-commit hooks /
        // signing / a slow `git status` no longer block it. The refresh is
        // scoped to the views a commit changes.
        .create => return app.requestMutation(.{ .commit = .{ .message = message, .no_verify = app.commit_no_verify } }, .{ .gerund = "committing", .command = if (app.commit_no_verify) "git commit --no-verify" else "git commit", .refresh = App.Refresh.commit }, "commit created", .{}),
        .reword => return commitops_mod.runRebase(app, .reword, reword_index, message),
    }
}
