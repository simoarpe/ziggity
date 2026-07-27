//! Stash-panel actions: opening the Stash menu (save variants) and the
//! apply/pop/drop operations on the selected stash entry. Free functions over
//! `*App`; mutating actions route through the shared background mutation queue.
const std = @import("std");
const app_mod = @import("app.zig");

const App = app_mod.App;

pub fn startStashMenu(self: *App) !void {
    if (self.data.files.len == 0) {
        try self.setMessage("nothing to stash", .{});
        return;
    }
    // git cannot stash while intent-to-add (`git add -N`) files are present,
    // except that `stash --staged` can still work when there is a real staged
    // change too. If staged-only cannot do useful work, explain up front;
    // otherwise let the menu open and the async failure path explains any
    // unsupported variant the user chooses.
    if (self.hasIntentToAddFiles() and !self.hasStagedFiles()) return self.explainIntentToAddStash();
    self.focus = .files;
    self.mode = .menu;
    self.active_menu = .{ .title = "Stash", .items = &app_mod.stash_menu, .index = 0 };
    if (self.hasIntentToAddFiles()) {
        try self.setMessage("intent-to-add present; staged-only stash can still work", .{});
    } else {
        try self.setMessage("stash changes", .{});
    }
}

pub fn applySelectedStash(self: *App) !void {
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.requestMutation(.{ .stash_apply = entry.index }, .{ .gerund = "applying stash", .command = "git stash apply", .refresh = App.Refresh.stash }, "applied {s}", .{entry.selector});
}

pub fn popSelectedStash(self: *App) !void {
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.requestMutation(.{ .stash_pop = entry.index }, .{ .gerund = "popping stash", .command = "git stash pop", .refresh = App.Refresh.stash }, "popped {s}", .{entry.selector});
}

/// Write the selected stash's diff to `stash-<index>.patch` in the repo root,
/// so it can be shared or `git apply`d later. Includes untracked files.
pub fn createPatchFromSelectedStash(self: *App) !void {
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    var res = try self.git.stashShowPatch(entry.selector);
    defer res.deinit(self.allocator);
    if (!res.ok()) {
        try self.setMessage("could not read the stash's diff", .{});
        return;
    }
    if (res.stdout.len == 0) {
        try self.setMessage("stash has no changes to patch", .{});
        return;
    }
    const filename = try std.fmt.allocPrint(self.allocator, "stash-{d}.patch", .{entry.index});
    defer self.allocator.free(filename);
    self.git.writeWorkingFile(filename, res.stdout) catch {
        try self.setMessage("could not write {s}", .{filename});
        return;
    };
    // The new .patch is an untracked file — refresh so it shows in Files.
    self.refreshViews(App.Refresh.files);
    try self.setMessage("wrote patch to {s}", .{filename});
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
                self.clearRange();
                return self.requestMutation(.{ .stash_drop_many = indices.items }, .{ .gerund = "dropping stash", .command = "git stash drop", .refresh = App.Refresh.stash }, "dropped {d} stash entries", .{n});
            }
        }
    }
    const entry = self.selectedStash() orelse {
        try self.setMessage("no stash entry selected", .{});
        return;
    };
    return self.requestMutation(.{ .stash_drop = entry.index }, .{ .gerund = "dropping stash", .command = "git stash drop", .refresh = App.Refresh.stash }, "dropped {s}", .{entry.selector});
}
