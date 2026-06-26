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

/// `e` on the remotes list: rename the remote (enter to keep) then edit its URL.
pub fn startEditRemote(self: *App) !void {
    const remote = self.selectedRemote() orelse {
        try self.setMessage("no remote selected", .{});
        return;
    };
    const n = @min(remote.name.len, self.remote_name_buf.len);
    @memcpy(self.remote_name_buf[0..n], remote.name[0..n]);
    self.remote_name_len = n;
    self.mode = .text_prompt;
    self.text_prompt_kind = .rename_remote;
    self.focus = .branches;
    self.input_buffer.clearRetainingCapacity();
    try self.input_buffer.appendSlice(self.allocator, remote.name);
    self.prompt_cursor = self.input_buffer.items.len;
    self.prompt_scroll = 0;
    try self.setMessage("rename remote {s} (enter to keep)", .{remote.name});
}

pub fn startRemoveRemote(self: *App) !void {
    const remote = self.selectedRemote() orelse {
        try self.setMessage("no remote selected", .{});
        return;
    };
    const n = @min(remote.name.len, self.remote_name_buf.len);
    @memcpy(self.remote_name_buf[0..n], remote.name[0..n]);
    self.remote_name_len = n;
    return self.requestConfirmation(.remove_remote, "confirm remove remote {s}", .{remote.name});
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
    }
}
