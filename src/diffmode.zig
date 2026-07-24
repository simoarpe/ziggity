//! Diffing mode (W) and opening the selection on its remote host (o). Diffing
//! mode marks a ref as the base and then shows `git diff <base> <selected>` in
//! the main panel; the browser path derives a web URL for the focused commit or
//! branch and launches it. Free functions over `*App`; `diff_base` lives on App.
const std = @import("std");

const app_mod = @import("app.zig");

const App = app_mod.App;

pub fn selectedRefForDiff(app: *const App) ?[]const u8 {
    // While drilled into a branch's commits the cursor is on a sub-commit, not a
    // branch (`branch_index` stays frozen on the drilled branch), so the ref to
    // diff is that commit's hash — `selectedCommit` already resolves the drill.
    if (app.branch_commits_active and app.contentFocus() == .branches) {
        return if (app.selectedCommit()) |commit| commit.hash else null;
    }
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
    app.diff_three_dot = false;
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
    // Smart default for the dot mode: a branch base almost always wants the
    // three-dot "what did this branch do" view (the pull-request semantics),
    // while commits and tags compare snapshots, where two-dot is the honest
    // answer. For two commits on one line of history the outputs are identical
    // anyway, so the two-dot default costs nothing. The title always shows the
    // active dots, so the default is never hidden state.
    const is_branch = !(app.branch_commits_active and app.contentFocus() == .branches) and
        app.contentFocus() == .branches and
        (app.branches_tab == .local or app.branches_tab == .remotes);
    clearDiffBase(app);
    app.diff_base = try app.allocator.dupe(u8, ref);
    app.diff_three_dot = is_branch;
    try app.setMessage("comparing using {s} as base - select another ref (W options, esc exits)", .{ref});
    try openDiffingDialog(app);
    try app.updatePreview();
}

/// Set the diff base to an arbitrary, typed ref name.
pub fn diffAgainstRef(app: *App, ref: []const u8) !void {
    // The ref is interpolated into `git diff <base> <target>` positionally, so a
    // value beginning with `-` would be parsed by git as an option (e.g.
    // `--output=FILE` could clobber a file). Reject it — no valid ref starts
    // with a dash.
    if (ref.len == 0 or ref[0] == '-') {
        try app.setMessage("invalid ref (cannot start with '-')", .{});
        return;
    }
    const owned = try app.allocator.dupe(u8, ref);
    clearDiffBase(app);
    app.diff_base = owned;
    // A typed ref that names a known branch gets the branch default (three-dot).
    app.diff_three_dot = app.localBranchExists(owned) or app.isRemoteBranchName(owned);
    try app.setMessage("comparing using {s} as base - select another ref (W options, esc exits)", .{owned});
    try openDiffingDialog(app);
    try app.updatePreview();
}

/// The explicit "you are now in diffing mode" note, shown as a dialog when a
/// base is marked: names the base, spells out the two-dot/three-dot semantics
/// and the invert option, and says how to leave. Enter/esc dismisses it; the
/// compact hint stays in the bottom bar afterwards.
fn openDiffingDialog(app: *App) !void {
    const base = app.diff_base.?;
    const dots: []const u8 = if (app.diff_three_dot) "..." else "..";
    const active: []const u8 = if (app.diff_three_dot)
        "only the selected side's own changes since the refs\n    diverged (the view a pull request shows)"
    else
        "the full difference between the two refs";
    const other: []const u8 = if (app.diff_three_dot)
        "switch to .. (the full difference between the two refs)"
    else
        "switch to ... (only the selected side's changes since\n               diverging - the view a pull request shows)";
    app.allocator.free(app.op_command);
    app.op_command = try std.fmt.allocPrint(app.allocator, "git diff {s}{s}<selected>", .{ base, dots });
    app.allocator.free(app.op_summary);
    app.op_summary = try app.allocator.dupe(u8, "Diffing mode");
    app.allocator.free(app.op_output);
    app.op_output = try std.fmt.allocPrint(app.allocator,
        "Base marked: {s} (its row shows a \u{25C6})\n\n" ++
        "Select any other commit, branch or tag; the Diff panel follows,\n" ++
        "showing:\n\n" ++
        "    git diff {s}{s}selected\n    {s}\n\n" ++
        "Press W again for options:\n\n" ++
        "    invert     swap the two sides (selected{s}{s})\n" ++
        "    dots       {s}\n\n" ++
        "Branches default to three dots, commits and tags to two.\n" ++
        "Enter or esc closes this note; esc again exits diffing mode.", .{ base, base, dots, active, dots, base, other });
    app.op_ok = true;
    app.op_running = false;
    app.op_scroll = 0;
    app.mode = .operation;
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

/// `G` on the Commits tab: open a pull request for the current branch.
pub fn openPullRequest(app: *App) !void {
    return openPrForBranch(app, app.data.current_branch);
}

/// `G` on the local Branches tab: open a pull request for the selected branch.
pub fn openPullRequestForBranch(app: *App) !void {
    const branch = app.selectedBranch() orelse {
        try app.setMessage("no branch selected", .{});
        return;
    };
    return openPrForBranch(app, branch.name);
}

/// Open the host's "create pull/merge request" page for `branch` in the browser.
/// No forge API is needed — it's a plain compare URL.
fn openPrForBranch(app: *App, branch: []const u8) !void {
    if (branch.len == 0) {
        try app.setMessage("no branch to open a pull request for", .{});
        return;
    }
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

    const url = try pullRequestUrl(app.allocator, base, branch);
    defer app.allocator.free(url);
    app.git.openUrl(url) catch {
        try app.setMessage("failed to launch the browser", .{});
        return;
    };
    try app.setMessage("opening {s}", .{url});
}

/// Build the host's new-pull-request URL for `branch`. GitLab and Bitbucket use
/// their own paths; everything else (GitHub, Gitea, …) uses the GitHub-style
/// compare URL, matching the rest of the web-URL handling.
fn pullRequestUrl(allocator: std.mem.Allocator, base: []const u8, branch: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, base, "gitlab") != null) {
        return std.fmt.allocPrint(allocator, "{s}/-/merge_requests/new?merge_request%5Bsource_branch%5D={s}", .{ base, branch });
    }
    if (std.mem.indexOf(u8, base, "bitbucket") != null) {
        return std.fmt.allocPrint(allocator, "{s}/pull-requests/new?source={s}", .{ base, branch });
    }
    return std.fmt.allocPrint(allocator, "{s}/compare/{s}?expand=1", .{ base, branch });
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
/// The forge family behind a web base URL, which decides the commit/branch/tag
/// URL shapes. Detected from the host; anything unrecognised is treated as
/// GitHub-style (also correct for Gitea's commit page, Bitbucket, etc.).
const Forge = enum { github, gitlab, gitea };

fn forgeOf(base: []const u8) Forge {
    if (std.mem.indexOf(u8, base, "gitlab") != null) return .gitlab;
    if (std.mem.indexOf(u8, base, "codeberg") != null or std.mem.indexOf(u8, base, "gitea") != null) return .gitea;
    return .github;
}

/// The forge's web page for a commit. GitLab nests everything under `/-/`;
/// GitHub and Gitea/Codeberg both use a plain `/commit/<hash>`.
fn commitWebUrl(allocator: std.mem.Allocator, base: []const u8, hash: []const u8) ![]u8 {
    const path = if (forgeOf(base) == .gitlab) "/-/commit/" else "/commit/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base, path, hash });
}

/// The forge's web page for a branch or tag ref. GitHub uses `/tree/<ref>`,
/// GitLab `/-/tree/<ref>`, and Gitea/Codeberg `/src/branch/<ref>` or
/// `/src/tag/<ref>`.
fn refWebUrl(allocator: std.mem.Allocator, base: []const u8, name: []const u8, is_tag: bool) ![]u8 {
    return switch (forgeOf(base)) {
        .github => std.fmt.allocPrint(allocator, "{s}/tree/{s}", .{ base, name }),
        .gitlab => std.fmt.allocPrint(allocator, "{s}/-/tree/{s}", .{ base, name }),
        .gitea => std.fmt.allocPrint(allocator, "{s}/src/{s}/{s}", .{ base, if (is_tag) "tag" else "branch", name }),
    };
}

pub fn selectionWebUrl(app: *const App, base: []const u8) ![]u8 {
    switch (app.focus) {
        .commits => if (app.selectedCommit()) |commit| {
            return commitWebUrl(app.allocator, base, commit.hash);
        },
        .branches => switch (app.branches_tab) {
            .local => if (app.selectedBranch()) |branch| {
                return refWebUrl(app.allocator, base, branch.name, false);
            },
            .remotes => if (app.selectedRemoteBranch()) |branch| {
                // Strip the "<remote>/" prefix so the tree path is the branch.
                const name = if (std.mem.indexOfScalar(u8, branch.name, '/')) |slash|
                    branch.name[slash + 1 ..]
                else
                    branch.name;
                return refWebUrl(app.allocator, base, name, false);
            },
            .tags => if (app.selectedTag()) |tag| {
                return refWebUrl(app.allocator, base, tag.name, true);
            },
        },
        .status, .files, .stash, .main => {},
    }
    return app.allocator.dupe(u8, base);
}

test "pullRequestUrl picks the host's new-request path" {
    const a = std.testing.allocator;
    const gh = try pullRequestUrl(a, "https://github.com/o/r", "feature/x");
    defer a.free(gh);
    try std.testing.expectEqualStrings("https://github.com/o/r/compare/feature/x?expand=1", gh);

    const gl = try pullRequestUrl(a, "https://gitlab.com/o/r", "wip");
    defer a.free(gl);
    try std.testing.expectEqualStrings("https://gitlab.com/o/r/-/merge_requests/new?merge_request%5Bsource_branch%5D=wip", gl);

    const bb = try pullRequestUrl(a, "https://bitbucket.org/o/r", "wip");
    defer a.free(bb);
    try std.testing.expectEqualStrings("https://bitbucket.org/o/r/pull-requests/new?source=wip", bb);
}

test "commitWebUrl uses each forge's commit path" {
    const a = std.testing.allocator;
    const cases = [_]struct { base: []const u8, want: []const u8 }{
        .{ .base = "https://github.com/o/r", .want = "https://github.com/o/r/commit/abc123" },
        .{ .base = "https://gitlab.com/o/r", .want = "https://gitlab.com/o/r/-/commit/abc123" },
        .{ .base = "https://codeberg.org/o/r", .want = "https://codeberg.org/o/r/commit/abc123" },
        // Self-hosted GitLab is detected by the host substring.
        .{ .base = "https://gitlab.example.com/o/r", .want = "https://gitlab.example.com/o/r/-/commit/abc123" },
    };
    for (cases) |c| {
        const got = try commitWebUrl(a, c.base, "abc123");
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "refWebUrl uses each forge's branch/tag path" {
    const a = std.testing.allocator;
    const branch = [_]struct { base: []const u8, want: []const u8 }{
        .{ .base = "https://github.com/o/r", .want = "https://github.com/o/r/tree/main" },
        .{ .base = "https://gitlab.com/o/r", .want = "https://gitlab.com/o/r/-/tree/main" },
        .{ .base = "https://codeberg.org/o/r", .want = "https://codeberg.org/o/r/src/branch/main" },
    };
    for (branch) |c| {
        const got = try refWebUrl(a, c.base, "main", false);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
    const tag = [_]struct { base: []const u8, want: []const u8 }{
        .{ .base = "https://github.com/o/r", .want = "https://github.com/o/r/tree/v1.0" },
        .{ .base = "https://gitlab.com/o/r", .want = "https://gitlab.com/o/r/-/tree/v1.0" },
        .{ .base = "https://codeberg.org/o/r", .want = "https://codeberg.org/o/r/src/tag/v1.0" },
    };
    for (tag) |c| {
        const got = try refWebUrl(a, c.base, "v1.0", true);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
