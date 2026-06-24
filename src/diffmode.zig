//! Diffing mode (W) and opening the selection on its remote host (o). Diffing
//! mode marks a ref as the base and then shows `git diff <base> <selected>` in
//! the main panel; the browser path derives a web URL for the focused commit or
//! branch and launches it. Free functions over `*App`; `diff_base` lives on App.
const std = @import("std");

const app_mod = @import("app.zig");

const App = app_mod.App;

pub fn selectedRefForDiff(app: *const App) ?[]const u8 {
    return switch (app.contentFocus()) {
        .commits => if (app.selectedCommit()) |commit| commit.hash else null,
        .branches => app.selectedBranchRefName(),
        .status, .files, .stash, .main => null,
    };
}

pub fn clearDiffBase(app: *App) void {
    if (app.diff_base) |b| app.allocator.free(b);
    app.diff_base = null;
    app.diff_reverse = false;
}

/// The Diffing menu (W): diff against the selected ref, enter an arbitrary ref,
/// and (while active) reverse the direction or exit.
pub fn startDiffingMenu(app: *App) !void {
    const items: []const app_mod.MenuItem = if (app.diff_base != null) &app_mod.diffing_menu_active else &app_mod.diffing_menu_inactive;
    app.mode = .menu;
    app.active_menu = .{ .title = "Diffing", .items = items, .index = 0 };
    try app.setMessage("diffing", .{});
}

/// Mark the selected commit/branch/tag as the diff base. While active, the main
/// panel shows the diff from the base to whatever ref is selected.
pub fn diffAgainstSelected(app: *App) !void {
    const ref = selectedRefForDiff(app) orelse {
        try app.setMessage("select a commit or branch to diff", .{});
        return;
    };
    clearDiffBase(app);
    app.diff_base = try app.allocator.dupe(u8, ref);
    try app.setMessage("diffing from {s} - select another ref (esc to exit)", .{ref});
    try app.updatePreview();
}

/// Set the diff base to an arbitrary, typed ref name.
pub fn diffAgainstRef(app: *App, ref: []const u8) !void {
    const owned = try app.allocator.dupe(u8, ref);
    clearDiffBase(app);
    app.diff_base = owned;
    try app.setMessage("diffing from {s} - select another ref (esc to exit)", .{owned});
    try app.updatePreview();
}

/// Open the focused commit or branch on its remote's web host. Derives an https
/// URL from the remote's fetch URL and launches the OS browser.
pub fn openSelectionInBrowser(app: *App) !void {
    const remote = currentRemoteName(app);
    const raw = app.git.remoteUrl(remote) catch {
        try app.setMessage("no '{s}' remote to open", .{remote});
        return;
    };
    defer app.allocator.free(raw);
    const base = (try app_mod.webUrlFromRemote(app.allocator, std.mem.trim(u8, raw, " \t\r\n"))) orelse {
        try app.setMessage("cannot derive a web URL from {s}", .{std.mem.trim(u8, raw, " \t\r\n")});
        return;
    };
    defer app.allocator.free(base);

    const url = try selectionWebUrl(app, base);
    defer app.allocator.free(url);
    app.git.openUrl(url) catch {
        try app.setMessage("failed to launch the browser", .{});
        return;
    };
    try app.setMessage("opening {s}", .{url});
}

/// The remote whose web host we open: the current branch's upstream remote,
/// falling back to "origin".
pub fn currentRemoteName(app: *const App) []const u8 {
    if (app.data.upstream) |upstream| {
        if (std.mem.indexOfScalar(u8, upstream, '/')) |slash| return upstream[0..slash];
    }
    return "origin";
}

/// Append the path for the focused item to a repo web `base` URL.
pub fn selectionWebUrl(app: *const App, base: []const u8) ![]u8 {
    switch (app.focus) {
        .commits => if (app.selectedCommit()) |commit| {
            return std.fmt.allocPrint(app.allocator, "{s}/commit/{s}", .{ base, commit.hash });
        },
        .branches => switch (app.branches_tab) {
            .local => if (app.selectedBranch()) |branch| {
                return std.fmt.allocPrint(app.allocator, "{s}/tree/{s}", .{ base, branch.name });
            },
            .remotes => if (app.selectedRemoteBranch()) |branch| {
                // Strip the "<remote>/" prefix so the tree path is the branch.
                const name = if (std.mem.indexOfScalar(u8, branch.name, '/')) |slash|
                    branch.name[slash + 1 ..]
                else
                    branch.name;
                return std.fmt.allocPrint(app.allocator, "{s}/tree/{s}", .{ base, name });
            },
            .tags => if (app.selectedTag()) |tag| {
                return std.fmt.allocPrint(app.allocator, "{s}/tree/{s}", .{ base, tag.name });
            },
        },
        .status, .files, .stash, .main => {},
    }
    return app.allocator.dupe(u8, base);
}
