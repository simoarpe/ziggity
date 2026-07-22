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
    // git cannot stash while intent-to-add (`git add -N`) files are present —
    // every menu option but "staged only" would fail with a cryptic error — so
    // explain it up front instead of opening a menu that mostly cannot work.
    if (self.hasIntentToAddFiles()) return self.explainIntentToAddStash();
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
