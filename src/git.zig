const std = @import("std");
const model = @import("model.zig");

pub const GitError = error{
    NotGitRepository,
    CommandFailed,
    UnexpectedOutput,
};

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    pub fn ok(self: ExecResult) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub const Git = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Git {
        var argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
        const result = try std.process.run(allocator, io, .{
            .argv = &argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);

        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return GitError.NotGitRepository;

        const root = try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
        };
    }

    pub fn deinit(self: *Git) void {
        self.allocator.free(self.root);
        self.* = undefined;
    }

    pub fn exec(self: *Git, args: []const []const u8) !ExecResult {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, "git");
        try argv.appendSlice(self.allocator, args);

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.root },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .term = result.term,
        };
    }

    fn output(self: *Git, args: []const []const u8) ![]u8 {
        var result = try self.exec(args);
        errdefer result.deinit(self.allocator);
        if (!result.ok()) return GitError.CommandFailed;
        self.allocator.free(result.stderr);
        return result.stdout;
    }

    pub fn loadRepoData(self: *Git) !model.RepoData {
        var data = model.RepoData.empty();
        errdefer data.deinit(self.allocator);

        const status = try self.loadStatusSummary();
        data.current_branch = status.current_branch;
        data.upstream = status.upstream;
        data.ahead = status.ahead;
        data.behind = status.behind;
        data.files = try self.loadFiles();
        data.branches = try self.loadBranches();
        data.remote_branches = try self.loadRemoteBranches();
        data.tags = try self.loadTags();
        data.commits = try self.loadCommits("HEAD", 100);
        data.reflog = try self.loadReflog(100);
        data.stash = try self.loadStash();

        return data;
    }

    pub fn loadStatusSummary(self: *Git) !model.StatusSummary {
        var status = model.StatusSummary{
            .current_branch = try self.currentBranch(),
        };
        errdefer status.deinit(self.allocator);

        status.upstream = try self.upstreamBranch();
        if (status.upstream != null) {
            const counts = self.aheadBehind() catch null;
            if (counts) |value| {
                status.behind = value.behind;
                status.ahead = value.ahead;
            }
        }

        return status;
    }

    pub fn currentBranch(self: *Git) ![]u8 {
        var result = try self.exec(&.{ "branch", "--show-current" });
        defer result.deinit(self.allocator);
        if (result.ok()) {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (trimmed.len > 0) return self.allocator.dupe(u8, trimmed);
        }

        var detached = try self.exec(&.{ "rev-parse", "--short", "HEAD" });
        defer detached.deinit(self.allocator);
        if (!detached.ok()) return GitError.CommandFailed;
        const trimmed = std.mem.trim(u8, detached.stdout, " \t\r\n");
        return std.fmt.allocPrint(self.allocator, "detached@{s}", .{trimmed});
    }

    pub fn upstreamBranch(self: *Git) !?[]u8 {
        var result = try self.exec(&.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return null;
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try self.allocator.dupe(u8, trimmed);
    }

    const AheadBehind = struct {
        ahead: usize,
        behind: usize,
    };

    fn aheadBehind(self: *Git) !?AheadBehind {
        var result = try self.exec(&.{ "rev-list", "--left-right", "--count", "@{u}...HEAD" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return null;

        var fields = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
        const behind_raw = fields.next() orelse return null;
        const ahead_raw = fields.next() orelse return null;
        return .{
            .behind = std.fmt.parseInt(usize, behind_raw, 10) catch 0,
            .ahead = std.fmt.parseInt(usize, ahead_raw, 10) catch 0,
        };
    }

    pub fn loadFiles(self: *Git) ![]model.FileStatus {
        const output_bytes = try self.output(&.{ "status", "--porcelain", "-z", "--untracked-files=all", "--find-renames=50%" });
        defer self.allocator.free(output_bytes);
        return parseStatus(self.allocator, output_bytes);
    }

    pub fn loadBranches(self: *Git) ![]model.Branch {
        const bytes = try self.output(&.{ "branch", "--format=%(HEAD)%00%(refname:short)%00%(upstream:short)" });
        defer self.allocator.free(bytes);
        return parseBranches(self.allocator, bytes);
    }

    pub fn loadRemoteBranches(self: *Git) ![]model.Branch {
        // Skip the `<remote>/HEAD -> ...` symbolic entry git lists for remotes.
        var result = try self.exec(&.{ "branch", "--remotes", "--format=%00%(refname:short)%00", "--list" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Branch, 0);
        const all = try parseBranches(self.allocator, result.stdout);
        defer self.allocator.free(all);

        var kept: std.ArrayList(model.Branch) = .empty;
        errdefer {
            for (kept.items) |*branch| branch.deinit(self.allocator);
            kept.deinit(self.allocator);
        }
        for (all) |*branch| {
            // The symbolic `<remote>/HEAD` entry shortens to just the remote
            // name (no slash); real remote branches are always `remote/branch`.
            if (std.mem.indexOfScalar(u8, branch.name, '/') == null) {
                branch.deinit(self.allocator);
                continue;
            }
            try kept.append(self.allocator, branch.*);
        }
        return kept.toOwnedSlice(self.allocator);
    }

    pub fn loadTags(self: *Git) ![]model.Tag {
        var result = try self.exec(&.{ "tag", "--sort=-creatordate", "--format=%(refname:short)%00%(contents:subject)" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Tag, 0);
        return parseTags(self.allocator, result.stdout);
    }

    pub fn loadCommits(self: *Git, ref_name: []const u8, limit: usize) ![]model.Commit {
        const limit_arg = try std.fmt.allocPrint(self.allocator, "-{d}", .{limit});
        defer self.allocator.free(limit_arg);
        const bytes = try self.output(&.{
            "log",
            ref_name,
            "--date=relative",
            "--pretty=format:%H%x00%h%x00%an%x00%cr%x00%D%x00%s",
            "--no-show-signature",
            limit_arg,
        });
        defer self.allocator.free(bytes);

        return parseCommits(self.allocator, bytes);
    }

    pub fn loadReflog(self: *Git, limit: usize) ![]model.Commit {
        const limit_arg = try std.fmt.allocPrint(self.allocator, "-{d}", .{limit});
        defer self.allocator.free(limit_arg);
        // %gd is the reflog selector (HEAD@{n}); %gs the reflog subject. They
        // map onto the Commit model's refs/subject fields for reuse.
        var result = try self.exec(&.{
            "log",
            "-g",
            "--date=relative",
            "--pretty=format:%H%x00%h%x00%an%x00%cr%x00%gd%x00%gs",
            "--no-show-signature",
            limit_arg,
        });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Commit, 0);
        return parseCommits(self.allocator, result.stdout);
    }

    pub fn loadStash(self: *Git) ![]model.StashEntry {
        var result = try self.exec(&.{ "stash", "list", "--format=%gd%x00%H%x00%cr%x00%gs" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.StashEntry, 0);
        return parseStash(self.allocator, result.stdout);
    }

    pub fn diffForFile(self: *Git, file: model.FileStatus, diff_context: u8) ![]u8 {
        var output_buf: std.ArrayList(u8) = .empty;
        errdefer output_buf.deinit(self.allocator);

        const context_arg = try std.fmt.allocPrint(self.allocator, "--unified={d}", .{diff_context});
        defer self.allocator.free(context_arg);

        if (file.has_unstaged) {
            if (!file.tracked and !file.has_staged) {
                var result = try self.exec(&.{ "diff", "--no-index", "--no-color", "--", "/dev/null", file.path });
                defer result.deinit(self.allocator);
                if (result.stdout.len > 0) {
                    try output_buf.appendSlice(self.allocator, "Untracked\n\n");
                    try output_buf.appendSlice(self.allocator, result.stdout);
                }
            } else {
                var result = try self.exec(&.{ "diff", "--no-ext-diff", "--no-color", context_arg, "--", file.path });
                defer result.deinit(self.allocator);
                if (result.ok() and result.stdout.len > 0) {
                    try output_buf.appendSlice(self.allocator, "Unstaged\n\n");
                    try output_buf.appendSlice(self.allocator, result.stdout);
                }
            }
        }

        if (file.has_staged) {
            var result = try self.exec(&.{ "diff", "--staged", "--no-ext-diff", "--no-color", context_arg, "--", file.path });
            defer result.deinit(self.allocator);
            if (result.ok() and result.stdout.len > 0) {
                if (output_buf.items.len > 0) try output_buf.appendSlice(self.allocator, "\n");
                try output_buf.appendSlice(self.allocator, "Staged\n\n");
                try output_buf.appendSlice(self.allocator, result.stdout);
            }
        }

        if (output_buf.items.len == 0) {
            try output_buf.appendSlice(self.allocator, "No diff for selected file.\n");
        }
        return output_buf.toOwnedSlice(self.allocator);
    }

    pub fn showCommit(self: *Git, hash: []const u8, diff_context: u8) ![]u8 {
        const context_arg = try std.fmt.allocPrint(self.allocator, "--unified={d}", .{diff_context});
        defer self.allocator.free(context_arg);
        var result = try self.exec(&.{ "show", "--no-ext-diff", "--no-color", "--stat", "--patch", context_arg, hash });
        errdefer result.deinit(self.allocator);
        if (!result.ok()) return GitError.CommandFailed;
        self.allocator.free(result.stderr);
        return result.stdout;
    }

    pub fn showBranch(self: *Git, name: []const u8) ![]u8 {
        var result = try self.exec(&.{ "log", "--oneline", "--decorate", "-30", name });
        errdefer result.deinit(self.allocator);
        if (!result.ok()) return GitError.CommandFailed;
        self.allocator.free(result.stderr);
        return result.stdout;
    }

    pub fn showStash(self: *Git, index: usize, diff_context: u8) ![]u8 {
        const selector = try std.fmt.allocPrint(self.allocator, "stash@{{{d}}}", .{index});
        defer self.allocator.free(selector);
        const context_arg = try std.fmt.allocPrint(self.allocator, "--unified={d}", .{diff_context});
        defer self.allocator.free(context_arg);
        var result = try self.exec(&.{ "stash", "show", "-p", "--stat", "-u", "--no-ext-diff", "--no-color", context_arg, selector });
        errdefer result.deinit(self.allocator);
        if (!result.ok()) return GitError.CommandFailed;
        self.allocator.free(result.stderr);
        return result.stdout;
    }

    pub fn stageFile(self: *Git, path: []const u8) !ExecResult {
        return self.stagePaths(&.{path});
    }

    pub fn stagePaths(self: *Git, paths: []const []const u8) !ExecResult {
        if (paths.len == 0) return self.successResult();
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "add", "--" });
        try args.appendSlice(self.allocator, paths);
        return self.exec(args.items);
    }

    pub fn unstageFile(self: *Git, file: model.FileStatus) !ExecResult {
        if (file.tracked) return self.exec(&.{ "reset", "HEAD", "--", file.path });
        return self.exec(&.{ "rm", "--cached", "--force", "--", file.path });
    }

    pub fn unstagePaths(self: *Git, paths: []const []const u8) !ExecResult {
        if (paths.len == 0) return self.successResult();
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "reset", "HEAD", "--" });
        try args.appendSlice(self.allocator, paths);
        return self.exec(args.items);
    }

    pub fn stageAll(self: *Git) !ExecResult {
        return self.exec(&.{ "add", "-A" });
    }

    pub fn unstageAll(self: *Git) !ExecResult {
        return self.exec(&.{"reset"});
    }

    pub fn discardFile(self: *Git, file: model.FileStatus) !ExecResult {
        if (file.isRename()) {
            if (try self.resetFilePaths(file)) |failure| return failure;
            if (file.previous_path) |previous| {
                if (try self.runStep(&.{ "checkout", "HEAD", "--", previous })) |failure| return failure;
            }
            if (try self.runStep(&.{ "clean", "-fd", "--", file.path })) |failure| return failure;
            return self.successResult();
        }

        if (!file.tracked or file.added) {
            if (file.has_staged) {
                if (try self.resetFilePaths(file)) |failure| return failure;
            }
            if (try self.runStep(&.{ "clean", "-fd", "--", file.path })) |failure| return failure;
            return self.successResult();
        }

        if (try self.runStep(&.{ "checkout", "HEAD", "--", file.path })) |failure| return failure;
        return self.successResult();
    }

    /// Discard only the unstaged (working-tree) changes for a file, keeping any
    /// staged changes intact by restoring the working tree from the index.
    pub fn discardUnstaged(self: *Git, file: model.FileStatus) !ExecResult {
        return self.exec(&.{ "checkout", "--", file.path });
    }

    pub fn discardAll(self: *Git) !ExecResult {
        if (try self.runStep(&.{ "reset", "--hard", "HEAD" })) |failure| return failure;
        if (try self.runStep(&.{ "clean", "-fd" })) |failure| return failure;
        return self.successResult();
    }

    pub fn commit(self: *Git, message: []const u8) !ExecResult {
        return self.exec(&.{ "commit", "-m", message });
    }

    pub fn checkout(self: *Git, branch_name: []const u8) !ExecResult {
        return self.exec(&.{ "checkout", branch_name });
    }

    /// Create a new branch from HEAD and switch to it (lazygit's new-branch).
    pub fn createBranch(self: *Git, name: []const u8) !ExecResult {
        return self.exec(&.{ "checkout", "-b", name });
    }

    pub fn fetch(self: *Git) !ExecResult {
        return self.exec(&.{ "fetch", "--all", "--no-write-fetch-head" });
    }

    pub fn pull(self: *Git) !ExecResult {
        return self.exec(&.{ "pull", "--no-edit" });
    }

    pub fn push(self: *Git) !ExecResult {
        return self.exec(&.{"push"});
    }

    pub fn stashApply(self: *Git, index: usize) !ExecResult {
        const selector = try std.fmt.allocPrint(self.allocator, "stash@{{{d}}}", .{index});
        defer self.allocator.free(selector);
        return self.exec(&.{ "stash", "apply", selector });
    }

    pub fn stashPop(self: *Git, index: usize) !ExecResult {
        const selector = try std.fmt.allocPrint(self.allocator, "stash@{{{d}}}", .{index});
        defer self.allocator.free(selector);
        return self.exec(&.{ "stash", "pop", selector });
    }

    pub fn stashDrop(self: *Git, index: usize) !ExecResult {
        const selector = try std.fmt.allocPrint(self.allocator, "stash@{{{d}}}", .{index});
        defer self.allocator.free(selector);
        return self.exec(&.{ "stash", "drop", selector });
    }

    fn resetFilePaths(self: *Git, file: model.FileStatus) !?ExecResult {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "reset", "HEAD", "--", file.path });
        if (file.previous_path) |previous| try args.append(self.allocator, previous);
        return self.runStep(args.items);
    }

    fn runStep(self: *Git, args: []const []const u8) !?ExecResult {
        var result = try self.exec(args);
        if (!result.ok()) return result;
        result.deinit(self.allocator);
        return null;
    }

    fn successResult(self: *Git) !ExecResult {
        return .{
            .stdout = try self.allocator.alloc(u8, 0),
            .stderr = try self.allocator.alloc(u8, 0),
            .term = .{ .exited = 0 },
        };
    }
};

pub fn parseStatus(allocator: std.mem.Allocator, bytes: []const u8) ![]model.FileStatus {
    var files: std.ArrayList(model.FileStatus) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, bytes, 0);
    while (parts.next()) |entry| {
        if (entry.len < 3) continue;
        const short_status: [2]u8 = .{ entry[0], entry[1] };
        const path = entry[3..];
        const fields = model.deriveStatusFields(short_status);
        var file = model.FileStatus{
            .path = try allocator.dupe(u8, path),
            .short_status = short_status,
            .has_staged = fields.has_staged,
            .has_unstaged = fields.has_unstaged,
            .tracked = fields.tracked,
            .added = fields.added,
            .deleted = fields.deleted,
            .conflict = fields.conflict,
        };
        errdefer file.deinit(allocator);

        if (short_status[0] == 'R' or short_status[0] == 'C') {
            if (parts.next()) |previous| {
                file.previous_path = try allocator.dupe(u8, previous);
            }
        }

        try files.append(allocator, file);
    }

    return files.toOwnedSlice(allocator);
}

pub fn parseBranches(allocator: std.mem.Allocator, bytes: []const u8) ![]model.Branch {
    var branches: std.ArrayList(model.Branch) = .empty;
    errdefer {
        for (branches.items) |*branch| branch.deinit(allocator);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0);
        const head = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const upstream = fields.next() orelse "";
        var branch = model.Branch{
            .name = try allocator.dupe(u8, name),
            .current = head.len > 0 and head[0] == '*',
        };
        errdefer branch.deinit(allocator);
        if (upstream.len > 0) branch.upstream = try allocator.dupe(u8, upstream);
        try branches.append(allocator, branch);
    }

    return branches.toOwnedSlice(allocator);
}

pub fn parseTags(allocator: std.mem.Allocator, bytes: []const u8) ![]model.Tag {
    var tags: std.ArrayList(model.Tag) = .empty;
    errdefer {
        for (tags.items) |*tag| tag.deinit(allocator);
        tags.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0);
        const name = fields.next() orelse continue;
        if (name.len == 0) continue;
        const subject = fields.next() orelse "";
        var tag = model.Tag{
            .name = try allocator.dupe(u8, name),
            .subject = try allocator.dupe(u8, subject),
        };
        errdefer tag.deinit(allocator);
        try tags.append(allocator, tag);
    }

    return tags.toOwnedSlice(allocator);
}

pub fn parseCommits(allocator: std.mem.Allocator, bytes: []const u8) ![]model.Commit {
    var commits: std.ArrayList(model.Commit) = .empty;
    errdefer {
        for (commits.items) |*item| item.deinit(allocator);
        commits.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0);
        const hash = fields.next() orelse continue;
        const short_hash = fields.next() orelse continue;
        const author = fields.next() orelse "";
        const time = fields.next() orelse "";
        const refs = fields.next() orelse "";
        const subject = fields.next() orelse "";
        var item = model.Commit{
            .hash = try allocator.dupe(u8, hash),
            .short_hash = try allocator.dupe(u8, short_hash),
            .author = try allocator.dupe(u8, author),
            .time = try allocator.dupe(u8, time),
            .refs = try allocator.dupe(u8, refs),
            .subject = try allocator.dupe(u8, subject),
        };
        errdefer item.deinit(allocator);
        try commits.append(allocator, item);
    }

    return commits.toOwnedSlice(allocator);
}

pub fn parseStash(allocator: std.mem.Allocator, bytes: []const u8) ![]model.StashEntry {
    var entries: std.ArrayList(model.StashEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0);
        const selector = fields.next() orelse continue;
        const hash = fields.next() orelse "";
        const time = fields.next() orelse "";
        const message = fields.next() orelse "";
        var entry = model.StashEntry{
            .index = parseStashIndex(selector) orelse entries.items.len,
            .selector = try allocator.dupe(u8, selector),
            .hash = try allocator.dupe(u8, hash),
            .time = try allocator.dupe(u8, time),
            .message = try allocator.dupe(u8, message),
        };
        errdefer entry.deinit(allocator);
        try entries.append(allocator, entry);
    }

    return entries.toOwnedSlice(allocator);
}

fn parseStashIndex(selector: []const u8) ?usize {
    const start = std.mem.indexOfScalar(u8, selector, '{') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, selector, start, '}') orelse return null;
    return std.fmt.parseInt(usize, selector[start + 1 .. end], 10) catch null;
}

test "parse porcelain status including rename" {
    const input = " M src/main.zig\x00R  new.txt\x00old.txt\x00?? scratch.txt\x00";
    const files = try parseStatus(std.testing.allocator, input);
    defer {
        for (files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualSlices(u8, "src/main.zig", files[0].path);
    try std.testing.expect(files[0].has_unstaged);
    try std.testing.expect(files[1].isRename());
    try std.testing.expectEqualSlices(u8, "old.txt", files[1].previous_path.?);
    try std.testing.expect(!files[2].tracked);
}

test "parse branches captures current marker and upstream" {
    const input =
        "*\x00main\x00origin/main\n" ++
        " \x00feature/demo\x00origin/feature/demo\n" ++
        " \x00local-only\x00\n";
    const branches = try parseBranches(std.testing.allocator, input);
    defer {
        for (branches) |*branch| branch.deinit(std.testing.allocator);
        std.testing.allocator.free(branches);
    }

    try std.testing.expectEqual(@as(usize, 3), branches.len);
    try std.testing.expect(branches[0].current);
    try std.testing.expectEqualSlices(u8, "main", branches[0].name);
    try std.testing.expectEqualSlices(u8, "origin/main", branches[0].upstream.?);
    try std.testing.expect(!branches[1].current);
    try std.testing.expectEqualSlices(u8, "feature/demo", branches[1].name);
    try std.testing.expect(branches[2].upstream == null);
}

test "parse tags captures name and optional subject" {
    const input =
        "v1.2.0\x00Release 1.2.0\n" ++
        "v1.1.0\x00\n" ++
        "v1.0.0\x00First stable\n";
    const tags = try parseTags(std.testing.allocator, input);
    defer {
        for (tags) |*tag| tag.deinit(std.testing.allocator);
        std.testing.allocator.free(tags);
    }

    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualSlices(u8, "v1.2.0", tags[0].name);
    try std.testing.expectEqualSlices(u8, "Release 1.2.0", tags[0].subject);
    try std.testing.expectEqualSlices(u8, "v1.1.0", tags[1].name);
    try std.testing.expectEqual(@as(usize, 0), tags[1].subject.len);
}

test "parse commits handles optional refs and subjects" {
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x00aaaaaaa\x00Sam\x002 hours ago\x00HEAD -> main, origin/main\x00Initial commit\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x00bbbbbbb\x00Lee\x00yesterday\x00\x00Follow up\n";
    const commits = try parseCommits(std.testing.allocator, input);
    defer {
        for (commits) |*commit| commit.deinit(std.testing.allocator);
        std.testing.allocator.free(commits);
    }

    try std.testing.expectEqual(@as(usize, 2), commits.len);
    try std.testing.expectEqualSlices(u8, "aaaaaaa", commits[0].short_hash);
    try std.testing.expectEqualSlices(u8, "Sam", commits[0].author);
    try std.testing.expectEqualSlices(u8, "HEAD -> main, origin/main", commits[0].refs);
    try std.testing.expectEqualSlices(u8, "Initial commit", commits[0].subject);
    try std.testing.expectEqualSlices(u8, "", commits[1].refs);
    try std.testing.expectEqualSlices(u8, "Follow up", commits[1].subject);
}

test "parse stash entries extracts selector index" {
    const input =
        "stash@{0}\x001111111111111111111111111111111111111111\x005 minutes ago\x00WIP on main\n" ++
        "stash@{12}\x002222222222222222222222222222222222222222\x003 days ago\x00Saved work\n";
    const entries = try parseStash(std.testing.allocator, input);
    defer {
        for (entries) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 0), entries[0].index);
    try std.testing.expectEqualSlices(u8, "stash@{0}", entries[0].selector);
    try std.testing.expectEqualSlices(u8, "WIP on main", entries[0].message);
    try std.testing.expectEqual(@as(usize, 12), entries[1].index);
    try std.testing.expectEqualSlices(u8, "Saved work", entries[1].message);
}
