//! Stash-panel actions: opening the Stash menu (save variants) and the
//! apply/pop/drop operations on the selected stash entry. Free functions over
//! `*App`; they route through the shared scoped-mutation machinery.
const std = @import("std");
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
    if (self.rangeActive() and self.focus == .stash) {
        if (self.rangeBounds()) |bnd| {
            var indices: std.ArrayList(usize) = .empty;
            defer indices.deinit(self.allocator);
            var i = bnd.lo;
            while (i <= bnd.hi and i < self.data.stash.len) : (i += 1) {
                try indices.append(self.allocator, self.data.stash[i].index);
            }
            if (indices.items.len > 0) {
                const n = indices.items.len;
                const res = try self.git.stashDropMany(indices.items);
                self.clearRange();
                return self.runMutationScoped(res, App.Refresh.stash, "dropped {d} stash entries", .{n});
            }
        }
    }
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.runMutationScoped(try self.git.stashDrop(entry.index), App.Refresh.stash, "dropped {s}", .{entry.selector});
}
