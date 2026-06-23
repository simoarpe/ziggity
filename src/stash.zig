//! Stash-panel actions: opening the Stash menu (save variants) and the
//! apply/pop/drop operations on the selected stash entry. Free functions over
//! `*App`; they route through the shared scoped-mutation machinery.
const app_mod = @import("app.zig");

const App = app_mod.App;

pub fn startStashMenu(self: *App) !void {
    if (self.data.files.len == 0) {
        try self.setMessage("nothing to stash", .{});
        return;
    }
    self.focus = .files;
    self.mode = .menu;
    self.active_menu = .{ .title = "Stash", .items = &app_mod.stash_menu, .index = 0 };
    try self.setMessage("stash changes", .{});
}

pub fn applySelectedStash(self: *App) !void {
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.runMutationScoped(try self.git.stashApply(entry.index), App.Refresh.stash_apply, "applied {s}", .{entry.selector});
}

pub fn popSelectedStash(self: *App) !void {
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.runMutationScoped(try self.git.stashPop(entry.index), App.Refresh.stash, "popped {s}", .{entry.selector});
}

pub fn dropSelectedStash(self: *App) !void {
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.runMutationScoped(try self.git.stashDrop(entry.index), App.Refresh.stash, "dropped {s}", .{entry.selector});
}
