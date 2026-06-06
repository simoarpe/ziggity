const std = @import("std");

pub const Focus = enum {
    files,
    branches,
    commits,
    stash,
    main,

    pub fn title(self: Focus) []const u8 {
        return switch (self) {
            .files => "Files",
            .branches => "Branches",
            .commits => "Commits",
            .stash => "Stash",
            .main => "Diff",
        };
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
    files: []FileStatus = &.{},
    branches: []Branch = &.{},
    commits: []Commit = &.{},
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
        for (self.commits) |*commit| commit.deinit(allocator);
        allocator.free(self.commits);
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
