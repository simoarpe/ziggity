const std = @import("std");

/// How the local Branches panel is ordered: `date` = most-recent commit first,
/// `recency` = most-recently checked out first (from the reflog),
/// `alphabetical` = by name.
pub const BranchSortOrder = enum { date, recency, alphabetical };

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
    /// navigation. The main panel is reached with
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
    /// The branch tracks a remote branch that has been deleted ("[gone]" from
    /// `%(upstream:track)`), e.g. after the upstream PR was merged and pruned.
    upstream_gone: bool = false,

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

    /// Deep copy into `allocator`. Used to move a summary built off-thread (with
    /// the page allocator) into the gpa-owned `RepoData`.
    pub fn dupe(self: StatusSummary, allocator: std.mem.Allocator) !StatusSummary {
        const branch = try allocator.dupe(u8, self.current_branch);
        errdefer allocator.free(branch);
        const upstream = if (self.upstream) |u| try allocator.dupe(u8, u) else null;
        return .{
            .current_branch = branch,
            .upstream = upstream,
            .ahead = self.ahead,
            .behind = self.behind,
        };
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
    bisecting: bool = false,
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

    pub fn replaceBranches(self: *RepoData, allocator: std.mem.Allocator, branches: []Branch) void {
        for (self.branches) |*b| b.deinit(allocator);
        allocator.free(self.branches);
        self.branches = branches;
    }

    pub fn replaceRemoteBranches(self: *RepoData, allocator: std.mem.Allocator, branches: []Branch) void {
        for (self.remote_branches) |*b| b.deinit(allocator);
        allocator.free(self.remote_branches);
        self.remote_branches = branches;
    }

    pub fn replaceTags(self: *RepoData, allocator: std.mem.Allocator, tags: []Tag) void {
        for (self.tags) |*t| t.deinit(allocator);
        allocator.free(self.tags);
        self.tags = tags;
    }

    pub fn replaceWorktrees(self: *RepoData, allocator: std.mem.Allocator, worktrees: []Worktree) void {
        for (self.worktrees) |*w| w.deinit(allocator);
        allocator.free(self.worktrees);
        self.worktrees = worktrees;
    }

    pub fn replaceSubmodules(self: *RepoData, allocator: std.mem.Allocator, submodules: []Submodule) void {
        for (self.submodules) |*s| s.deinit(allocator);
        allocator.free(self.submodules);
        self.submodules = submodules;
    }

    pub fn replaceCommits(self: *RepoData, allocator: std.mem.Allocator, commits: []Commit) void {
        for (self.commits) |*c| c.deinit(allocator);
        allocator.free(self.commits);
        self.commits = commits;
    }

    pub fn replaceReflog(self: *RepoData, allocator: std.mem.Allocator, reflog: []Commit) void {
        for (self.reflog) |*c| c.deinit(allocator);
        allocator.free(self.reflog);
        self.reflog = reflog;
    }

    pub fn replaceStash(self: *RepoData, allocator: std.mem.Allocator, stash: []StashEntry) void {
        for (self.stash) |*s| s.deinit(allocator);
        allocator.free(self.stash);
        self.stash = stash;
    }

    /// Deep copy into `allocator`. Used to move repo data loaded off-thread
    /// (with the page allocator) into the gpa-owned data the UI thread keeps,
    /// so the incremental refreshes (which free with the gpa) stay valid.
    pub fn dupe(self: RepoData, allocator: std.mem.Allocator) std.mem.Allocator.Error!RepoData {
        var out = RepoData{};
        errdefer out.deinit(allocator);
        out.ahead = self.ahead;
        out.behind = self.behind;
        out.state = self.state;
        out.bisecting = self.bisecting;
        out.current_branch = try allocator.dupe(u8, self.current_branch);
        out.upstream = if (self.upstream) |u| try allocator.dupe(u8, u) else null;
        out.files = try dupeList(FileStatus, allocator, self.files, dupeFile);
        out.branches = try dupeList(Branch, allocator, self.branches, dupeBranch);
        out.remote_branches = try dupeList(Branch, allocator, self.remote_branches, dupeBranch);
        out.tags = try dupeList(Tag, allocator, self.tags, dupeTag);
        out.worktrees = try dupeList(Worktree, allocator, self.worktrees, dupeWorktree);
        out.submodules = try dupeList(Submodule, allocator, self.submodules, dupeSubmodule);
        out.commits = try dupeList(Commit, allocator, self.commits, dupeCommit);
        out.reflog = try dupeList(Commit, allocator, self.reflog, dupeCommit);
        out.stash = try dupeList(StashEntry, allocator, self.stash, dupeStash);
        return out;
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

// Deep-copy helpers for `RepoData.dupe`. Each element type is duped by hand
// (its owned strings copied), and `dupeList` copies a slice with proper
// errdefer cleanup of any elements already duped if a later one fails.

fn dupeList(
    comptime T: type,
    a: std.mem.Allocator,
    src: []const T,
    comptime dupeOne: fn (std.mem.Allocator, T) std.mem.Allocator.Error!T,
) std.mem.Allocator.Error![]T {
    const out = try a.alloc(T, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |*e| e.deinit(a);
        a.free(out);
    }
    for (src) |item| {
        out[n] = try dupeOne(a, item);
        n += 1;
    }
    return out;
}

fn dupeFile(a: std.mem.Allocator, f: FileStatus) std.mem.Allocator.Error!FileStatus {
    const path = try a.dupe(u8, f.path);
    errdefer a.free(path);
    const previous_path = if (f.previous_path) |p| try a.dupe(u8, p) else null;
    return .{
        .path = path,
        .previous_path = previous_path,
        .short_status = f.short_status,
        .has_staged = f.has_staged,
        .has_unstaged = f.has_unstaged,
        .tracked = f.tracked,
        .added = f.added,
        .deleted = f.deleted,
        .conflict = f.conflict,
    };
}

fn dupeBranch(a: std.mem.Allocator, b: Branch) std.mem.Allocator.Error!Branch {
    const name = try a.dupe(u8, b.name);
    errdefer a.free(name);
    const upstream = if (b.upstream) |u| try a.dupe(u8, u) else null;
    return .{ .name = name, .upstream = upstream, .current = b.current, .upstream_gone = b.upstream_gone };
}

fn dupeTag(a: std.mem.Allocator, t: Tag) std.mem.Allocator.Error!Tag {
    const name = try a.dupe(u8, t.name);
    errdefer a.free(name);
    const subject = try a.dupe(u8, t.subject);
    return .{ .name = name, .subject = subject };
}

fn dupeWorktree(a: std.mem.Allocator, w: Worktree) std.mem.Allocator.Error!Worktree {
    const path = try a.dupe(u8, w.path);
    errdefer a.free(path);
    const branch = try a.dupe(u8, w.branch);
    return .{ .path = path, .branch = branch, .is_current = w.is_current };
}

fn dupeSubmodule(a: std.mem.Allocator, s: Submodule) std.mem.Allocator.Error!Submodule {
    const path = try a.dupe(u8, s.path);
    errdefer a.free(path);
    const sha = try a.dupe(u8, s.sha);
    return .{ .path = path, .sha = sha, .status = s.status };
}

fn dupeCommit(a: std.mem.Allocator, c: Commit) std.mem.Allocator.Error!Commit {
    const hash = try a.dupe(u8, c.hash);
    errdefer a.free(hash);
    const short_hash = try a.dupe(u8, c.short_hash);
    errdefer a.free(short_hash);
    const author = try a.dupe(u8, c.author);
    errdefer a.free(author);
    const time = try a.dupe(u8, c.time);
    errdefer a.free(time);
    const refs = try a.dupe(u8, c.refs);
    errdefer a.free(refs);
    const subject = try a.dupe(u8, c.subject);
    return .{ .hash = hash, .short_hash = short_hash, .author = author, .time = time, .refs = refs, .subject = subject };
}

fn dupeStash(a: std.mem.Allocator, s: StashEntry) std.mem.Allocator.Error!StashEntry {
    const selector = try a.dupe(u8, s.selector);
    errdefer a.free(selector);
    const hash = try a.dupe(u8, s.hash);
    errdefer a.free(hash);
    const time = try a.dupe(u8, s.time);
    errdefer a.free(time);
    const message = try a.dupe(u8, s.message);
    return .{ .index = s.index, .selector = selector, .hash = hash, .time = time, .message = message };
}

// Public per-slice deep copies — used to move one view's data, loaded off-thread
// with the page allocator, into the gpa-owned `RepoData` (see scoped refresh).
pub fn dupeFiles(a: std.mem.Allocator, src: []const FileStatus) std.mem.Allocator.Error![]FileStatus {
    return dupeList(FileStatus, a, src, dupeFile);
}
pub fn dupeBranches(a: std.mem.Allocator, src: []const Branch) std.mem.Allocator.Error![]Branch {
    return dupeList(Branch, a, src, dupeBranch);
}
pub fn dupeTags(a: std.mem.Allocator, src: []const Tag) std.mem.Allocator.Error![]Tag {
    return dupeList(Tag, a, src, dupeTag);
}
pub fn dupeWorktrees(a: std.mem.Allocator, src: []const Worktree) std.mem.Allocator.Error![]Worktree {
    return dupeList(Worktree, a, src, dupeWorktree);
}
pub fn dupeSubmodules(a: std.mem.Allocator, src: []const Submodule) std.mem.Allocator.Error![]Submodule {
    return dupeList(Submodule, a, src, dupeSubmodule);
}
pub fn dupeCommits(a: std.mem.Allocator, src: []const Commit) std.mem.Allocator.Error![]Commit {
    return dupeList(Commit, a, src, dupeCommit);
}
pub fn dupeStashes(a: std.mem.Allocator, src: []const StashEntry) std.mem.Allocator.Error![]StashEntry {
    return dupeList(StashEntry, a, src, dupeStash);
}

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

test "RepoData.dupe is an independent deep copy" {
    const a = std.testing.allocator;
    var src = RepoData{};
    src.current_branch = try a.dupe(u8, "main");
    src.files = try a.alloc(FileStatus, 1);
    src.files[0] = .{ .path = try a.dupe(u8, "f.zig"), .short_status = .{ 'M', 'M' }, .has_staged = true, .has_unstaged = true, .tracked = true, .added = false, .deleted = false, .conflict = false };
    src.commits = try a.alloc(Commit, 1);
    src.commits[0] = .{ .hash = try a.dupe(u8, "h"), .short_hash = try a.dupe(u8, "s"), .author = try a.dupe(u8, "au"), .time = try a.dupe(u8, "t"), .refs = try a.dupe(u8, "r"), .subject = try a.dupe(u8, "subj") };
    defer src.deinit(a);

    var copy = try src.dupe(a);
    defer copy.deinit(a);

    try std.testing.expectEqualStrings("main", copy.current_branch);
    try std.testing.expectEqualStrings("f.zig", copy.files[0].path);
    try std.testing.expectEqualStrings("subj", copy.commits[0].subject);
    // Independent allocations — the copy doesn't alias the source.
    try std.testing.expect(copy.current_branch.ptr != src.current_branch.ptr);
    try std.testing.expect(copy.commits[0].subject.ptr != src.commits[0].subject.ptr);
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

test "file display filter follows status filter semantics" {
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
