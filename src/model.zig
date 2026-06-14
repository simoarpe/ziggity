const std = @import("std");

/// Whether an interrupted merge or rebase is in progress (conflicts pending).
pub const RepoState = enum {
    clean,
    merging,
    rebasing,
    cherry_picking,

    pub fn label(self: RepoState) []const u8 {
        return switch (self) {
            .clean => "",
            .merging => "MERGING",
            .rebasing => "REBASING",
            .cherry_picking => "CHERRY-PICK",
        };
    }
};

pub const Focus = enum {
    status,
    files,
    branches,
    commits,
    stash,
    main,

    pub fn title(self: Focus) []const u8 {
        return switch (self) {
            .status => "Status",
            .files => "Files",
            .branches => "Branches",
            .commits => "Commits",
            .stash => "Stash",
            .main => "Diff",
        };
    }

    /// True for the left-column list panels that participate in block
    /// navigation (lazygit's "blocks"). The main panel is reached with
    /// <enter> and left with <esc>, so it is excluded here.
    pub fn isSidePanel(self: Focus) bool {
        return self != .main;
    }
};

pub const FileStatus = struct {
    path: []u8,
    previous_path: ?[]u8 = null,
    short_status: [2]u8,
    has_staged: bool,
    has_unstaged: bool,
    tracked: bool,
    added: bool,
    deleted: bool,
    conflict: bool,

    pub fn deinit(self: *FileStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.previous_path) |previous| allocator.free(previous);
        self.* = undefined;
    }

    pub fn isRename(self: FileStatus) bool {
        return self.previous_path != null;
    }
};

pub const FileDisplayFilter = enum {
    all,
    staged,
    unstaged,
    tracked,
    untracked,
    conflicted,

    pub fn label(self: FileDisplayFilter) []const u8 {
        return switch (self) {
            .all => "all",
            .staged => "staged",
            .unstaged => "unstaged",
            .tracked => "tracked",
            .untracked => "untracked",
            .conflicted => "conflicted",
        };
    }

    pub fn matches(self: FileDisplayFilter, file: FileStatus) bool {
        return switch (self) {
            .all => true,
            .staged => file.has_staged,
            .unstaged => file.has_unstaged,
            .tracked => file.tracked or file.has_staged,
            .untracked => !(file.tracked or file.has_staged),
            .conflicted => file.conflict,
        };
    }
};

pub const Branch = struct {
    name: []u8,
    upstream: ?[]u8 = null,
    current: bool = false,

    pub fn deinit(self: *Branch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.upstream) |upstream| allocator.free(upstream);
        self.* = undefined;
    }
};

pub const Tag = struct {
    name: []u8,
    subject: []u8 = &.{},

    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.subject);
        self.* = undefined;
    }
};

pub const Worktree = struct {
    path: []u8,
    branch: []u8, // short branch name, or "(detached)" / "(bare)"
    is_current: bool = false,

    pub fn deinit(self: *Worktree, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.branch);
        self.* = undefined;
    }
};

pub const Submodule = struct {
    path: []u8,
    sha: []u8,
    /// Leading char from `git submodule status`: ' ' ok, '+' out of date,
    /// '-' uninitialized, 'U' conflicts.
    status: u8,

    pub fn deinit(self: *Submodule, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.sha);
        self.* = undefined;
    }

    pub fn stateLabel(self: Submodule) []const u8 {
        return switch (self.status) {
            '-' => "uninitialized",
            '+' => "out of date",
            'U' => "conflicts",
            else => "ok",
        };
    }
};

/// A file changed by a single commit, from `git diff-tree --name-status`.
pub const CommitFile = struct {
    status: u8,
    path: []u8,

    pub fn deinit(self: *CommitFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn deinitCommitFiles(allocator: std.mem.Allocator, files: []CommitFile) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

pub const Commit = struct {
    hash: []u8,
    short_hash: []u8,
    author: []u8,
    time: []u8,
    refs: []u8,
    subject: []u8,

    pub fn deinit(self: *Commit, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.time);
        allocator.free(self.refs);
        allocator.free(self.subject);
        self.* = undefined;
    }
};

pub const StashEntry = struct {
    index: usize,
    selector: []u8,
    hash: []u8,
    time: []u8,
    message: []u8,

    pub fn deinit(self: *StashEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.selector);
        allocator.free(self.hash);
        allocator.free(self.time);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const StatusSummary = struct {
    current_branch: []u8 = &.{},
    upstream: ?[]u8 = null,
    ahead: ?usize = null,
    behind: ?usize = null,

    pub fn deinit(self: *StatusSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.current_branch);
        if (self.upstream) |upstream| allocator.free(upstream);
        self.* = .{};
    }
};

pub fn deinitFileStatuses(allocator: std.mem.Allocator, files: []FileStatus) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

pub const RepoData = struct {
    current_branch: []u8 = &.{},
    upstream: ?[]u8 = null,
    ahead: ?usize = null,
    behind: ?usize = null,
    state: RepoState = .clean,
    files: []FileStatus = &.{},
    branches: []Branch = &.{},
    remote_branches: []Branch = &.{},
    tags: []Tag = &.{},
    worktrees: []Worktree = &.{},
    submodules: []Submodule = &.{},
    commits: []Commit = &.{},
    reflog: []Commit = &.{},
    stash: []StashEntry = &.{},

    pub fn empty() RepoData {
        return .{};
    }

    pub fn deinit(self: *RepoData, allocator: std.mem.Allocator) void {
        allocator.free(self.current_branch);
        if (self.upstream) |upstream| allocator.free(upstream);
        deinitFileStatuses(allocator, self.files);
        for (self.branches) |*branch| branch.deinit(allocator);
        allocator.free(self.branches);
        for (self.remote_branches) |*branch| branch.deinit(allocator);
        allocator.free(self.remote_branches);
        for (self.tags) |*tag| tag.deinit(allocator);
        allocator.free(self.tags);
        for (self.worktrees) |*wt| wt.deinit(allocator);
        allocator.free(self.worktrees);
        for (self.submodules) |*sm| sm.deinit(allocator);
        allocator.free(self.submodules);
        for (self.commits) |*commit| commit.deinit(allocator);
        allocator.free(self.commits);
        for (self.reflog) |*entry| entry.deinit(allocator);
        allocator.free(self.reflog);
        for (self.stash) |*entry| entry.deinit(allocator);
        allocator.free(self.stash);
        self.* = empty();
    }

    pub fn replaceStatus(self: *RepoData, allocator: std.mem.Allocator, status: StatusSummary) void {
        allocator.free(self.current_branch);
        if (self.upstream) |upstream| allocator.free(upstream);
        self.current_branch = status.current_branch;
        self.upstream = status.upstream;
        self.ahead = status.ahead;
        self.behind = status.behind;
    }

    pub fn replaceFiles(self: *RepoData, allocator: std.mem.Allocator, files: []FileStatus) void {
        deinitFileStatuses(allocator, self.files);
        self.files = files;
    }

    pub fn stagedCount(self: RepoData) usize {
        var count: usize = 0;
        for (self.files) |file| {
            if (file.has_staged) count += 1;
        }
        return count;
    }

    pub fn unstagedCount(self: RepoData) usize {
        var count: usize = 0;
        for (self.files) |file| {
            if (file.has_unstaged) count += 1;
        }
        return count;
    }
};

pub const StatusFields = struct {
    has_staged: bool,
    has_unstaged: bool,
    tracked: bool,
    added: bool,
    deleted: bool,
    conflict: bool,
};

pub fn deriveStatusFields(short_status: [2]u8) StatusFields {
    const staged = short_status[0];
    const unstaged = short_status[1];
    const tracked = !(short_status[0] == '?' and short_status[1] == '?') and
        !(short_status[0] == 'A' and short_status[1] == ' ') and
        !(short_status[0] == 'A' and short_status[1] == 'M');
    const has_staged = staged != ' ' and staged != 'U' and staged != '?';
    const has_unstaged = unstaged != ' ';
    const conflict = (short_status[0] == 'U' or short_status[1] == 'U') or
        std.mem.eql(u8, &short_status, "AA") or
        std.mem.eql(u8, &short_status, "DD");

    return .{
        .has_staged = has_staged,
        .has_unstaged = has_unstaged,
        .tracked = tracked,
        .added = staged == 'A' or unstaged == 'A' or !tracked,
        .deleted = staged == 'D' or unstaged == 'D',
        .conflict = conflict,
    };
}

test "derive status fields follows porcelain status columns" {
    const modified = deriveStatusFields(.{ ' ', 'M' });
    try std.testing.expect(!modified.has_staged);
    try std.testing.expect(modified.has_unstaged);
    try std.testing.expect(modified.tracked);

    const added = deriveStatusFields(.{ 'A', ' ' });
    try std.testing.expect(added.has_staged);
    try std.testing.expect(!added.tracked);

    const untracked = deriveStatusFields(.{ '?', '?' });
    try std.testing.expect(untracked.has_unstaged);
    try std.testing.expect(!untracked.tracked);

    const conflict = deriveStatusFields(.{ 'U', 'U' });
    try std.testing.expect(conflict.conflict);
}

test "file display filter follows lazygit status filter semantics" {
    const unstaged: FileStatus = .{
        .path = @constCast("src/main.zig"),
        .short_status = .{ ' ', 'M' },
        .has_staged = false,
        .has_unstaged = true,
        .tracked = true,
        .added = false,
        .deleted = false,
        .conflict = false,
    };
    const staged_untracked: FileStatus = .{
        .path = @constCast("new.zig"),
        .short_status = .{ 'A', ' ' },
        .has_staged = true,
        .has_unstaged = false,
        .tracked = false,
        .added = true,
        .deleted = false,
        .conflict = false,
    };
    const untracked: FileStatus = .{
        .path = @constCast("scratch.txt"),
        .short_status = .{ '?', '?' },
        .has_staged = false,
        .has_unstaged = true,
        .tracked = false,
        .added = true,
        .deleted = false,
        .conflict = false,
    };

    try std.testing.expect(FileDisplayFilter.unstaged.matches(unstaged));
    try std.testing.expect(!FileDisplayFilter.staged.matches(unstaged));
    try std.testing.expect(FileDisplayFilter.tracked.matches(staged_untracked));
    try std.testing.expect(!FileDisplayFilter.untracked.matches(staged_untracked));
    try std.testing.expect(FileDisplayFilter.untracked.matches(untracked));
}
