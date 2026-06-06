const std = @import("std");
const vaxis = @import("vaxis");

const actions = @import("actions.zig");
const config_mod = @import("config.zig");
const git_mod = @import("git.zig");
const model = @import("model.zig");

pub const Mode = enum {
    normal,
    commit_prompt,
    confirmation,
};

pub const Confirmation = enum {
    discard_file,
    discard_all,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    git: git_mod.Git,
    config: config_mod.Config,
    data: model.RepoData = .{},
    focus: model.Focus = .files,
    file_index: usize = 0,
    branch_index: usize = 0,
    commit_index: usize = 0,
    stash_index: usize = 0,
    main_scroll: usize = 0,
    diff: []u8 = &.{},
    message: []u8 = &.{},
    commit_buffer: std.ArrayList(u8) = .empty,
    mode: Mode = .normal,
    pending_confirmation: ?Confirmation = null,
    running: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
    ) !App {
        var git = try git_mod.Git.init(allocator, io);
        errdefer git.deinit();

        const cfg = try config_mod.Config.load(allocator, io, env_map, git.root);
        var app = App{
            .allocator = allocator,
            .git = git,
            .config = cfg,
        };
        errdefer app.deinit();

        try app.refresh();
        try app.setMessage("ready", .{});
        return app;
    }

    pub fn deinit(self: *App) void {
        self.data.deinit(self.allocator);
        self.allocator.free(self.diff);
        self.allocator.free(self.message);
        self.commit_buffer.deinit(self.allocator);
        self.git.deinit();
        self.* = undefined;
    }

    pub fn refresh(self: *App) !void {
        const next = try self.git.loadRepoData();
        self.data.deinit(self.allocator);
        self.data = next;
        self.clampSelections();
        self.updatePreview() catch |err| {
            try self.setMessage("preview failed: {s}", .{@errorName(err)});
        };
    }

    pub fn handleKey(self: *App, key: vaxis.Key) !void {
        if (self.mode == .commit_prompt) {
            try self.handleCommitPromptKey(key);
            return;
        }
        if (self.mode == .confirmation) {
            try self.handleConfirmationKey(key);
            return;
        }

        if (key.matches(vaxis.Key.page_up, .{})) return self.scrollMain(-10);
        if (key.matches(vaxis.Key.page_down, .{})) return self.scrollMain(10);

        const action = actions.fromNormalKey(key, self.config.keymap, self.focus) orelse return;
        switch (action) {
            .quit => self.running = false,
            .cancel => {
                if (self.focus == .main) {
                    self.focus = .files;
                    try self.updatePreview();
                } else {
                    self.running = false;
                }
            },
            .focus_files => try self.setFocus(.files),
            .focus_branches => try self.setFocus(.branches),
            .focus_commits => try self.setFocus(.commits),
            .focus_stash => try self.setFocus(.stash),
            .focus_main => try self.setFocus(.main),
            .refresh => {
                try self.refresh();
                try self.setMessage("refreshed", .{});
            },
            .fetch => try self.runMutation(try self.git.fetch(), "fetch complete", .{}),
            .pull => try self.runMutation(try self.git.pull(), "pull complete", .{}),
            .push => try self.runMutation(try self.git.push(), "push complete", .{}),
            .move_up => try self.moveUp(),
            .move_down => try self.moveDown(),
            .focus_left => try self.focusPrevious(),
            .focus_right => try self.focusNext(),
            .select => switch (self.focus) {
                .files => try self.toggleFileStaged(),
                .branches => try self.checkoutSelectedBranch(),
                .stash => try self.applySelectedStash(),
                .commits, .main => {},
            },
            .stage_all => try self.toggleAllStaged(),
            .discard_selected => try self.startDiscardSelectedConfirmation(),
            .discard_all => try self.startDiscardAllConfirmation(),
            .start_commit => try self.startCommitPrompt(),
            .stash_pop => try self.popSelectedStash(),
            .stash_drop => try self.dropSelectedStash(),
            .confirm, .backspace => {},
        }
    }

    pub fn selectedFile(self: *const App) ?model.FileStatus {
        if (self.data.files.len == 0) return null;
        return self.data.files[@min(self.file_index, self.data.files.len - 1)];
    }

    pub fn selectedBranch(self: *const App) ?model.Branch {
        if (self.data.branches.len == 0) return null;
        return self.data.branches[@min(self.branch_index, self.data.branches.len - 1)];
    }

    pub fn selectedCommit(self: *const App) ?model.Commit {
        if (self.data.commits.len == 0) return null;
        return self.data.commits[@min(self.commit_index, self.data.commits.len - 1)];
    }

    pub fn selectedStash(self: *const App) ?model.StashEntry {
        if (self.data.stash.len == 0) return null;
        return self.data.stash[@min(self.stash_index, self.data.stash.len - 1)];
    }

    pub fn confirmationText(self: *const App, buf: []u8) []const u8 {
        return switch (self.pending_confirmation orelse return "No pending action.") {
            .discard_file => blk: {
                if (self.selectedFile()) |file| {
                    break :blk std.fmt.bufPrint(buf, "Discard all changes to {s}? y/enter confirm, n/esc cancel", .{file.path}) catch "Discard selected file? y/enter confirm, n/esc cancel";
                }
                break :blk "Discard selected file? y/enter confirm, n/esc cancel";
            },
            .discard_all => "Discard all working tree changes? y/enter confirm, n/esc cancel",
        };
    }

    fn setFocus(self: *App, focus: model.Focus) !void {
        self.focus = focus;
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn focusNext(self: *App) !void {
        self.focus = switch (self.focus) {
            .files => .branches,
            .branches => .commits,
            .commits => .stash,
            .stash => .main,
            .main => .files,
        };
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn focusPrevious(self: *App) !void {
        self.focus = switch (self.focus) {
            .files => .main,
            .branches => .files,
            .commits => .branches,
            .stash => .commits,
            .main => .stash,
        };
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn moveUp(self: *App) !void {
        switch (self.focus) {
            .files => self.file_index -|= 1,
            .branches => self.branch_index -|= 1,
            .commits => self.commit_index -|= 1,
            .stash => self.stash_index -|= 1,
            .main => return self.scrollMain(-1),
        }
        try self.updatePreview();
    }

    fn moveDown(self: *App) !void {
        switch (self.focus) {
            .files => {
                if (self.file_index + 1 < self.data.files.len) self.file_index += 1;
            },
            .branches => {
                if (self.branch_index + 1 < self.data.branches.len) self.branch_index += 1;
            },
            .commits => {
                if (self.commit_index + 1 < self.data.commits.len) self.commit_index += 1;
            },
            .stash => {
                if (self.stash_index + 1 < self.data.stash.len) self.stash_index += 1;
            },
            .main => return self.scrollMain(1),
        }
        try self.updatePreview();
    }

    fn scrollMain(self: *App, amount: isize) !void {
        if (amount < 0) {
            self.main_scroll -|= @intCast(-amount);
        } else {
            self.main_scroll += @intCast(amount);
        }
    }

    fn toggleFileStaged(self: *App) !void {
        const file = self.selectedFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        if (file.has_unstaged) {
            return self.runMutation(try self.git.stageFile(file.path), "staged {s}", .{file.path});
        }
        if (file.has_staged) {
            return self.runMutation(try self.git.unstageFile(file), "unstaged {s}", .{file.path});
        }
        try self.setMessage("file has no staged or unstaged changes", .{});
    }

    fn toggleAllStaged(self: *App) !void {
        if (self.data.unstagedCount() > 0) {
            return self.runMutation(try self.git.stageAll(), "staged all files", .{});
        }
        if (self.data.stagedCount() > 0) {
            return self.runMutation(try self.git.unstageAll(), "unstaged all files", .{});
        }
        try self.setMessage("no files to stage", .{});
    }

    fn startCommitPrompt(self: *App) !void {
        if (self.data.stagedCount() == 0) {
            try self.setMessage("stage files before committing", .{});
            return;
        }
        self.mode = .commit_prompt;
        self.commit_buffer.clearRetainingCapacity();
        try self.setMessage("enter commit message", .{});
    }

    fn startDiscardSelectedConfirmation(self: *App) !void {
        _ = self.selectedFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        self.mode = .confirmation;
        self.pending_confirmation = .discard_file;
        try self.setMessage("confirm discard selected file", .{});
    }

    fn startDiscardAllConfirmation(self: *App) !void {
        if (self.data.files.len == 0) {
            try self.setMessage("no files to discard", .{});
            return;
        }
        self.mode = .confirmation;
        self.pending_confirmation = .discard_all;
        try self.setMessage("confirm discard all changes", .{});
    }

    fn checkoutSelectedBranch(self: *App) !void {
        const branch = self.selectedBranch() orelse {
            try self.setMessage("no branch selected", .{});
            return;
        };
        if (branch.current) {
            try self.setMessage("already on {s}", .{branch.name});
            return;
        }
        return self.runMutation(try self.git.checkout(branch.name), "checked out {s}", .{branch.name});
    }

    fn applySelectedStash(self: *App) !void {
        const entry = self.selectedStash() orelse {
            try self.setMessage("no stash entry selected", .{});
            return;
        };
        return self.runMutation(try self.git.stashApply(entry.index), "applied {s}", .{entry.selector});
    }

    fn popSelectedStash(self: *App) !void {
        const entry = self.selectedStash() orelse {
            try self.setMessage("no stash entry selected", .{});
            return;
        };
        return self.runMutation(try self.git.stashPop(entry.index), "popped {s}", .{entry.selector});
    }

    fn dropSelectedStash(self: *App) !void {
        const entry = self.selectedStash() orelse {
            try self.setMessage("no stash entry selected", .{});
            return;
        };
        return self.runMutation(try self.git.stashDrop(entry.index), "dropped {s}", .{entry.selector});
    }

    fn handleCommitPromptKey(self: *App, key: vaxis.Key) !void {
        const km = self.config.keymap;
        if (km.escape.matches(key)) {
            self.mode = .normal;
            self.commit_buffer.clearRetainingCapacity();
            try self.setMessage("commit cancelled", .{});
            return;
        }
        if (km.enter.matches(key)) {
            const message = std.mem.trim(u8, self.commit_buffer.items, " \t\r\n");
            if (message.len == 0) {
                try self.setMessage("commit message cannot be empty", .{});
                return;
            }
            self.mode = .normal;
            const result = try self.git.commit(message);
            self.commit_buffer.clearRetainingCapacity();
            return self.runMutation(result, "commit created", .{});
        }
        if (km.backspace.matches(key)) {
            if (self.commit_buffer.items.len > 0) self.commit_buffer.items.len -= 1;
            return;
        }
        if (key.text) |text| {
            if (!key.mods.ctrl and !key.mods.alt and text.len > 0 and text[0] >= 0x20) {
                try self.commit_buffer.appendSlice(self.allocator, text);
            }
        }
    }

    fn handleConfirmationKey(self: *App, key: vaxis.Key) !void {
        const km = self.config.keymap;
        if (km.enter.matches(key) or key.matches('y', .{})) {
            try self.confirmPendingAction();
            return;
        }
        if (km.escape.matches(key) or key.matches('n', .{})) {
            self.mode = .normal;
            self.pending_confirmation = null;
            try self.setMessage("cancelled", .{});
            return;
        }
    }

    fn confirmPendingAction(self: *App) !void {
        const pending = self.pending_confirmation orelse {
            self.mode = .normal;
            return;
        };
        self.mode = .normal;
        self.pending_confirmation = null;
        switch (pending) {
            .discard_file => {
                const file = self.selectedFile() orelse {
                    try self.setMessage("no file selected", .{});
                    return;
                };
                return self.runMutation(try self.git.discardFile(file), "discarded {s}", .{file.path});
            },
            .discard_all => return self.runMutation(try self.git.discardAll(), "discarded all changes", .{}),
        }
    }

    fn updatePreview(self: *App) !void {
        self.allocator.free(self.diff);
        self.diff = switch (self.focus) {
            .files, .main => blk: {
                if (self.selectedFile()) |file| break :blk try self.git.diffForFile(file, self.config.diff_context);
                break :blk try self.allocator.dupe(u8, "Working tree clean.\n");
            },
            .branches => blk: {
                if (self.selectedBranch()) |branch| break :blk try self.git.showBranch(branch.name);
                break :blk try self.allocator.dupe(u8, "No branches found.\n");
            },
            .commits => blk: {
                if (self.selectedCommit()) |commit| break :blk try self.git.showCommit(commit.hash, self.config.diff_context);
                break :blk try self.allocator.dupe(u8, "No commits found.\n");
            },
            .stash => blk: {
                if (self.selectedStash()) |entry| break :blk try self.git.showStash(entry.index, self.config.diff_context);
                break :blk try self.allocator.dupe(u8, "No stash entries.\n");
            },
        };
    }

    fn runMutation(self: *App, result: git_mod.ExecResult, comptime success_fmt: []const u8, args: anytype) !void {
        var mutable = result;
        defer mutable.deinit(self.allocator);
        if (mutable.ok()) {
            try self.setMessage(success_fmt, args);
            self.refresh() catch |err| {
                try self.setMessage("git command succeeded; refresh failed: {s}", .{@errorName(err)});
            };
            return;
        }
        const stderr = std.mem.trim(u8, mutable.stderr, " \t\r\n");
        if (stderr.len > 0) {
            try self.setMessage("{s}", .{stderr});
        } else {
            try self.setMessage("git command failed", .{});
        }
        self.refresh() catch {};
    }

    fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) !void {
        self.allocator.free(self.message);
        self.message = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    fn clampSelections(self: *App) void {
        if (self.data.files.len == 0) self.file_index = 0 else self.file_index = @min(self.file_index, self.data.files.len - 1);
        if (self.data.branches.len == 0) self.branch_index = 0 else self.branch_index = @min(self.branch_index, self.data.branches.len - 1);
        if (self.data.commits.len == 0) self.commit_index = 0 else self.commit_index = @min(self.commit_index, self.data.commits.len - 1);
        if (self.data.stash.len == 0) self.stash_index = 0 else self.stash_index = @min(self.stash_index, self.data.stash.len - 1);
    }
};

test "action enum is referenced" {
    try std.testing.expect(actions.Action.quit == .quit);
}
