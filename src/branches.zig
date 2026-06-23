//! Branch-panel management actions, dispatched by tab (Local / Remotes / Tags /
//! Worktrees / Submodules): create, checkout, delete (menu + per-tab targets),
//! fast-forward, set-upstream, and editing/removing remotes. Free functions over
//! `*App`; they route through the shared confirmation/mutation machinery.
const std = @import("std");

const app_mod = @import("app.zig");
const model = @import("model.zig");
const textmatch = @import("textmatch.zig");

const App = app_mod.App;

pub fn startNewForBranchTab(self: *App) !void {
    if (self.branches_tab == .tags) return self.startTextPrompt(.new_tag);
    if (self.branches_tab == .remotes) return self.startTextPrompt(.add_remote_name);
    return self.startTextPrompt(.new_branch);
}

/// The remote name implied by the selected Remotes-tab entry (the prefix of
/// a `remote/branch` ref), stashed into remote_name_buf. Null off-tab/empty.
pub fn selectedRemoteName(self: *App) ?[]const u8 {
    if (self.branches_tab != .remotes) return null;
    const branch = self.selectedRemoteBranch() orelse return null;
    const slash = std.mem.indexOfScalar(u8, branch.name, '/') orelse return null;
    const name = branch.name[0..slash];
    if (name.len == 0 or name.len > self.remote_name_buf.len) return null;
    @memcpy(self.remote_name_buf[0..name.len], name);
    self.remote_name_len = name.len;
    return self.remote_name_buf[0..name.len];
}

pub fn startEditRemote(self: *App) !void {
    if (self.branches_tab != .remotes) {
        try self.setMessage("switch to the Remotes tab to edit a remote", .{});
        return;
    }
    const name = selectedRemoteName(self) orelse {
        try self.setMessage("no remote selected", .{});
        return;
    };
    // Prefill the current URL so the user edits rather than retypes.
    const current = self.git.remoteUrl(name) catch null;
    defer if (current) |c| self.allocator.free(c);
    self.mode = .text_prompt;
    self.text_prompt_kind = .edit_remote_url;
    self.focus = .branches;
    self.input_buffer.clearRetainingCapacity();
    if (current) |c| try self.input_buffer.appendSlice(self.allocator, std.mem.trim(u8, c, " \t\r\n"));
    try self.setMessage("edit URL for {s}", .{name});
}

pub fn startRemoveRemote(self: *App) !void {
    if (self.branches_tab != .remotes) {
        try self.setMessage("switch to the Remotes tab to remove a remote", .{});
        return;
    }
    const name = selectedRemoteName(self) orelse {
        try self.setMessage("no remote selected", .{});
        return;
    };
    return self.requestConfirmation(.remove_remote, "confirm remove remote {s}", .{name});
}

pub fn setUpstreamToSelected(self: *App) !void {
    if (self.branches_tab != .remotes) {
        try self.setMessage("select a remote branch (Remotes tab) to track", .{});
        return;
    }
    const branch = self.selectedRemoteBranch() orelse {
        try self.setMessage("no remote branch selected", .{});
        return;
    };
    try self.beginOpFmt("git branch --set-upstream-to={s}", .{branch.name});
    return self.runMutationScoped(try self.git.setUpstream(branch.name), App.Refresh.upstream, "tracking {s}", .{branch.name});
}

/// `d` in the Branches panel deletes by tab: local branch / tag / remote.
pub fn startDeleteForBranchTab(self: *App) !void {
    switch (self.branches_tab) {
        .local => return startBranchDeleteMenu(self),
        .tags => {
            const tag = self.selectedTag() orelse {
                try self.setMessage("no tag selected", .{});
                return;
            };
            return self.requestConfirmation(.delete_tag, "confirm delete tag {s}", .{tag.name});
        },
        .remotes => {
            const branch = self.selectedRemoteBranch() orelse {
                try self.setMessage("no remote branch selected", .{});
                return;
            };
            return self.requestConfirmation(.delete_remote_branch, "confirm delete remote {s}", .{branch.name});
        },
        .worktrees => {
            const wt = self.selectedWorktree() orelse {
                try self.setMessage("no worktree selected", .{});
                return;
            };
            if (wt.is_current) {
                try self.setMessage("cannot remove the current worktree", .{});
                return;
            }
            return self.requestConfirmation(.remove_worktree, "confirm remove worktree {s}", .{wt.path});
        },
        .submodules => try self.setMessage("no delete action for submodules", .{}),
    }
}

pub fn startBranchDeleteMenu(self: *App) !void {
    const branch = try localBranchForAction(self) orelse return;
    if (branch.current) {
        try self.setMessage("cannot delete the checked-out branch", .{});
        return;
    }
    self.mode = .menu;
    self.active_menu = .{ .title = "Delete branch", .items = &app_mod.branch_delete_menu, .index = 0 };
    try self.setMessage("delete {s}", .{branch.name});
}

pub fn startBranchConfirm(self: *App, kind: app_mod.Confirmation) !void {
    const branch = try localBranchForAction(self) orelse return;
    if (branch.current) {
        try self.setMessage("select a branch other than the current one", .{});
        return;
    }
    return self.requestConfirmation(kind, "confirm action on {s}", .{branch.name});
}

pub fn fastForwardSelectedBranch(self: *App) !void {
    const branch = try localBranchForAction(self) orelse return;
    const upstream = branch.upstream orelse {
        try self.setMessage("{s} has no upstream to fast-forward", .{branch.name});
        return;
    };
    if (branch.current) {
        var cmd_buf: [160]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "git merge --ff-only {s}", .{upstream}) catch "git merge --ff-only";
        return self.requestMutation(.fast_forward_current, .{ .gerund = "fast-forwarding", .command = cmd }, "fast-forwarded {s}", .{branch.name});
    }
    const slash = std.mem.indexOfScalar(u8, upstream, '/') orelse {
        try self.setMessage("cannot parse upstream {s}", .{upstream});
        return;
    };
    const remote = upstream[0..slash];
    const remote_ref = upstream[slash + 1 ..];
    var cmd_buf: [192]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git fetch {s} {s}:{s}", .{ remote, remote_ref, branch.name }) catch "git fetch";
    return self.requestMutation(.{ .fast_forward_branch = .{ .remote = remote, .remote_ref = remote_ref, .local = branch.name } }, .{ .gerund = "fast-forwarding", .command = cmd }, "fast-forwarded {s}", .{branch.name});
}

/// Validate that a branch action can run: the Branches panel must be on the
/// Local tab with a branch selected. Returns the selected branch or null
/// (after setting an explanatory message).
pub fn localBranchForAction(self: *App) !?model.Branch {
    if (self.branches_tab != .local) {
        try self.setMessage("branch actions apply to the Local tab", .{});
        return null;
    }
    return self.selectedBranch() orelse {
        try self.setMessage("no branch selected", .{});
        return null;
    };
}

pub fn checkoutSelectedBranch(self: *App) !void {
    switch (self.branches_tab) {
        .local => {
            const branch = self.selectedBranch() orelse {
                try self.setMessage("no branch selected", .{});
                return;
            };
            if (branch.current) {
                try self.setMessage("already on {s}", .{branch.name});
                return;
            }
            return self.requestMutation(.{ .checkout = branch.name }, .{ .gerund = "checking out", .command = "git checkout", .refresh = App.Refresh.checkout }, "checked out {s}", .{branch.name});
        },
        .remotes => {
            const branch = self.selectedRemoteBranch() orelse {
                try self.setMessage("no remote branch selected", .{});
                return;
            };
            // git's DWIM checkout creates a local tracking branch from
            // "<remote>/<name>" when "<name>" doesn't already exist locally.
            const local_name = textmatch.localNameForRemote(branch.name);
            return self.requestMutation(.{ .checkout = local_name }, .{ .gerund = "checking out", .command = "git checkout", .refresh = App.Refresh.checkout }, "checked out {s}", .{local_name});
        },
        .tags => {
            const tag = self.selectedTag() orelse {
                try self.setMessage("no tag selected", .{});
                return;
            };
            return self.requestMutation(.{ .checkout = tag.name }, .{ .gerund = "checking out", .command = "git checkout", .refresh = App.Refresh.checkout }, "checked out {s} (detached)", .{tag.name});
        },
        .worktrees => {
            // Switching the active worktree would re-root the app; instead
            // tell the user to open ziggity in that directory.
            if (self.selectedWorktree()) |wt| {
                try self.setMessage("open ziggity in {s} to use that worktree", .{wt.path});
            } else {
                try self.setMessage("no worktree selected", .{});
            }
        },
        .submodules => {
            const sm = self.selectedSubmodule() orelse {
                try self.setMessage("no submodule selected", .{});
                return;
            };
            return self.requestMutation(.{ .update_submodule = sm.path }, .{ .gerund = "updating submodule", .command = "git submodule update", .refresh = App.Refresh.submodules }, "updated {s}", .{sm.path});
        },
    }
}
