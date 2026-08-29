const std = @import("std");

/// How the local Branches panel is ordered: `date` = most-recent commit first,
/// `recency` = most-recently checked out first (from the reflog),
/// `alphabetical` = by name.
pub const BranchSortOrder = enum { date, recency, alphabetical };

/// How the working-tree Files panel is ordered: `name` = by path (stable, so a
/// file keeps its place as its git status changes), `status` = grouped by state
/// (staged, then unstaged, then untracked) and then by path.
pub const FileSortOrder = enum { name, status };

/// Whether the inline commit graph is drawn in the Commits panel: `off` never,
/// `focused` only while the Commits panel is focused, `on` always.
pub const CommitGraphMode = enum { off, focused, on };

/// Which refs the `ctrl+l` commit-graph viewer shows when it opens: `current`
/// (the current branch and its upstream) or `all` (every branch). `a` toggles it
/// live; this is only the initial scope.
pub const CommitGraphScope = enum { current, all };

/// How `pull` (`p`) behaves: `git` (the default) runs `git pull`, honouring
/// git's own `pull.rebase` config; `menu` opens a menu to choose merge / rebase
/// / fast-forward-only for each pull.
pub const PullMode = enum { git, menu };

/// Ordering of the HEAD commit log: `date` (the default — reverse-chronological
/// by commit time, git's native order: fastest, no flag), `topo` (keeps a
/// branch's commits contiguous for a readable graph), or `author_date`
/// (reverse-chronological by the author timestamp).
pub const LogOrder = enum { date, topo, author_date };

/// The `git log` order flag for a `LogOrder`, or null to use git's native
/// default (reverse-chronological) — the fast path, no whole-DAG walk.
pub fn logOrderFlag(order: LogOrder) ?[]const u8 {
    return switch (order) {
        .date => null,
        .topo => "--topo-order",
        .author_date => "--author-date-order",
    };
}

/// How many rows the footer hint bar may occupy when its hints do not fit one
/// line. `off` keeps the classic single (truncated) line; `.rows` caps the wrap
/// at N rows; `full` wraps onto as many rows as the hints need. Configured by
/// `footer_hint_rows` (a number, `0` for off, or `full`).
pub const FooterHintWrap = union(enum) {
    off,
    rows: u16,
    full,

    /// The maximum footer rows this setting allows, before any terminal-height
    /// clamp. `off` is a single row; `full` is effectively unbounded.
    pub fn cap(self: FooterHintWrap) u16 {
        return switch (self) {
            .off => 1,
            .rows => |n| @max(1, n),
            .full => std.math.maxInt(u16),
        };
    }
};

/// The `git log --graph` order flag for a `LogOrder`. Unlike `logOrderFlag`,
/// `.date` must be spelled out as `--date-order`: `--graph` implies
/// `--topo-order`, so omitting a flag would order the graph topologically and
/// disagree with the (date-ordered) Commits panel.
pub fn graphOrderFlag(order: LogOrder) []const u8 {
    return switch (order) {
        .date => "--date-order",
        .topo => "--topo-order",
        .author_date => "--author-date-order",
    };
}

/// Palette of 256-colour indices authors are hashed into. Shared by the Commits
/// panel initials, the `ctrl+l` graph viewer, and the inline commit graph so an
/// author always shows in the same colour everywhere.
pub const author_palette = [_]u8{
    33,  39,  43,  80,  78,  113, 149, 186,
    178, 208, 209, 203, 168, 170, 141, 111,
};

/// A stable palette index for an author name (MD5 of the name, mod palette size),
/// so each author always maps to the same colour.
pub fn authorColorIndex(name: []const u8) u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(name, &digest, .{});
    const slot = std.mem.readInt(u32, digest[0..4], .little) % author_palette.len;
    return author_palette[slot];
}

/// Sort `files` in place per `order`. `name` gives a stable path order so
/// staging a file never moves it; `status` groups by state first, then path.
pub fn sortFiles(files: []FileStatus, order: FileSortOrder) void {
    switch (order) {
        .name => std.mem.sort(FileStatus, files, {}, fileLessByPath),
        .status => std.mem.sort(FileStatus, files, {}, fileLessByStatus),
    }
}

fn fileLessByPath(_: void, a: FileStatus, b: FileStatus) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Status group for the `status` order: staged first, then tracked unstaged
/// changes, then untracked.
fn fileStatusRank(f: FileStatus) u8 {
    if (f.has_staged) return 0;
    if (f.tracked) return 1;
    return 2;
}

fn fileLessByStatus(_: void, a: FileStatus, b: FileStatus) bool {
    const ra = fileStatusRank(a);
    const rb = fileStatusRank(b);
    if (ra != rb) return ra < rb;
    return std.mem.lessThan(u8, a.path, b.path);
}

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
    /// Commits this branch is ahead of / behind its upstream (from
    /// `%(upstream:track)`); both 0 when in sync or with no upstream.
    ahead: usize = 0,
    behind: usize = 0,
    /// Unix timestamp of the branch tip's commit (`%(committerdate:unix)`),
    /// used for the "time ago" recency column. 0 when unknown.
    commit_time: i64 = 0,

    pub fn deinit(self: *Branch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.upstream) |upstream| allocator.free(upstream);
        self.* = undefined;
    }
};

/// A configured remote (`git remote -v`): its name and primary fetch URL.
pub const Remote = struct {
    name: []u8,
    url: []u8 = &.{},

    pub fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
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

pub fn deinitCommits(allocator: std.mem.Allocator, commits: []Commit) void {
    for (commits) |*commit| commit.deinit(allocator);
    allocator.free(commits);
}

/// A commit's position relative to its branch's upstream, for the hash colour
/// in the Commits panel: `unpushed` (ahead of the remote), `pushed` (already on
/// the remote), or `none` (no upstream / not computed).
pub const CommitStatus = enum { none, unpushed, pushed };

/// Which side of a left-right divergence log a commit is on: `ahead` (local,
/// ↑) or `behind` (upstream-only / incoming, ↓). `none` outside that view.
pub const Divergence = enum { none, ahead, behind };

pub const Commit = struct {
    hash: []u8,
    short_hash: []u8,
    author: []u8,
    time: []u8,
    refs: []u8,
    subject: []u8,
    /// Full parent hashes (from `%P`): `parents[0]` is the first parent;
    /// `len > 1` marks a merge; `len == 0` a root commit. Owned. Used by the
    /// inline commit graph.
    parents: [][]u8 = &.{},
    status: CommitStatus = .none,
    divergence: Divergence = .none,

    pub fn isMerge(self: Commit) bool {
        return self.parents.len > 1;
    }

    pub fn deinit(self: *Commit, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.time);
        allocator.free(self.refs);
        allocator.free(self.subject);
        for (self.parents) |p| allocator.free(p);
        allocator.free(self.parents);
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
    /// The current branch's upstream was deleted on the remote ("[gone]").
    upstream_gone: bool = false,
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
            .upstream_gone = self.upstream_gone,
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
    /// The current branch's upstream was deleted on the remote ("[gone]").
    upstream_gone: bool = false,
    ahead: ?usize = null,
    behind: ?usize = null,
    state: RepoState = .clean,
    bisecting: bool = false,
    files: []FileStatus = &.{},
    branches: []Branch = &.{},
    remote_branches: []Branch = &.{},
    /// Configured remotes (`git remote -v`: name + fetch URL), independent of
    /// whether any of their branches have been fetched.
    remotes: []Remote = &.{},
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
        for (self.remotes) |*remote| remote.deinit(allocator);
        allocator.free(self.remotes);
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
        self.upstream_gone = status.upstream_gone;
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

    pub fn replaceRemotes(self: *RepoData, allocator: std.mem.Allocator, remotes: []Remote) void {
        for (self.remotes) |*r| r.deinit(allocator);
        allocator.free(self.remotes);
        self.remotes = remotes;
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
        out.upstream_gone = self.upstream_gone;
        out.files = try dupeList(FileStatus, allocator, self.files, dupeFile);
        out.branches = try dupeList(Branch, allocator, self.branches, dupeBranch);
        out.remote_branches = try dupeList(Branch, allocator, self.remote_branches, dupeBranch);
        out.remotes = try dupeList(Remote, allocator, self.remotes, dupeRemote);
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
    return .{ .name = name, .upstream = upstream, .current = b.current, .upstream_gone = b.upstream_gone, .ahead = b.ahead, .behind = b.behind, .commit_time = b.commit_time };
}

fn dupeRemote(a: std.mem.Allocator, r: Remote) std.mem.Allocator.Error!Remote {
    const name = try a.dupe(u8, r.name);
    errdefer a.free(name);
    const url = try a.dupe(u8, r.url);
    return .{ .name = name, .url = url };
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
    errdefer a.free(subject);
    const parents = try a.alloc([]u8, c.parents.len);
    var filled: usize = 0;
    errdefer {
        for (parents[0..filled]) |p| a.free(p);
        a.free(parents);
    }
    for (c.parents, 0..) |p, i| {
        parents[i] = try a.dupe(u8, p);
        filled = i + 1;
    }
    return .{ .hash = hash, .short_hash = short_hash, .author = author, .time = time, .refs = refs, .subject = subject, .parents = parents, .status = c.status, .divergence = c.divergence };
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

pub fn dupeRemotes(a: std.mem.Allocator, src: []const Remote) std.mem.Allocator.Error![]Remote {
    return dupeList(Remote, a, src, dupeRemote);
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

/// Overwrite a file's porcelain status code and re-derive its staged/unstaged
/// flags from it. Used both when parsing real `git status` output and for the
/// optimistic staging update.
pub fn setStatusFields(file: *FileStatus, short_status: [2]u8) void {
    const d = deriveStatusFields(short_status);
    file.short_status = short_status;
    file.has_staged = d.has_staged;
    file.has_unstaged = d.has_unstaged;
    file.tracked = d.tracked;
    file.added = d.added;
    file.deleted = d.deleted;
    file.conflict = d.conflict;
}

const StatusRemap = struct { from: [2]u8, to: [2]u8 };

// The instant status-code transitions for staging / unstaging, used to update
// the file list optimistically (before the real `git status` lands). Statuses
// with no entry have no well-defined instant transition and are left for the
// refresh to settle.
const stage_remap = [_]StatusRemap{
    .{ .from = .{ '?', '?' }, .to = .{ 'A', ' ' } }, // untracked -> added
    .{ .from = .{ ' ', 'M' }, .to = .{ 'M', ' ' } }, // unstaged modified -> staged
    .{ .from = .{ 'M', 'M' }, .to = .{ 'M', ' ' } }, // both -> staged only
    .{ .from = .{ ' ', 'D' }, .to = .{ 'D', ' ' } }, // unstaged delete -> staged
    .{ .from = .{ ' ', 'A' }, .to = .{ 'A', ' ' } },
    .{ .from = .{ 'A', 'M' }, .to = .{ 'A', ' ' } }, // added w/ later mods -> added
    .{ .from = .{ 'M', 'D' }, .to = .{ 'D', ' ' } }, // modified then deleted -> staged delete
};

const unstage_remap = [_]StatusRemap{
    .{ .from = .{ 'A', ' ' }, .to = .{ '?', '?' } }, // staged add -> untracked
    .{ .from = .{ 'M', ' ' }, .to = .{ ' ', 'M' } }, // staged modified -> unstaged
    .{ .from = .{ 'D', ' ' }, .to = .{ ' ', 'D' } }, // staged delete -> unstaged
    .{ .from = .{ 'M', 'M' }, .to = .{ ' ', 'M' } },
};

/// The new status code when `short_status` is staged, or null if there's no
/// well-defined instant transition (leave it for the real refresh).
pub fn optimisticStage(short_status: [2]u8) ?[2]u8 {
    for (stage_remap) |m| {
        if (m.from[0] == short_status[0] and m.from[1] == short_status[1]) return m.to;
    }
    return null;
}

/// The new status code when `short_status` is unstaged, or null (see above).
pub fn optimisticUnstage(short_status: [2]u8) ?[2]u8 {
    for (unstage_remap) |m| {
        if (m.from[0] == short_status[0] and m.from[1] == short_status[1]) return m.to;
    }
    return null;
}

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

test "graphOrderFlag spells out date order that --graph would otherwise topo-sort" {
    // The flat log lets date fall through to git's default (null); the graph must
    // request it explicitly, since `--graph` implies --topo-order.
    try std.testing.expectEqual(@as(?[]const u8, null), logOrderFlag(.date));
    try std.testing.expectEqualStrings("--date-order", graphOrderFlag(.date));
    try std.testing.expectEqualStrings("--topo-order", graphOrderFlag(.topo));
    try std.testing.expectEqualStrings("--author-date-order", graphOrderFlag(.author_date));
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

test "optimistic stage/unstage status remaps" {
    // Stage transitions (porcelain XY -> XY).
    try std.testing.expectEqual([2]u8{ 'A', ' ' }, optimisticStage(.{ '?', '?' }).?);
    try std.testing.expectEqual([2]u8{ 'M', ' ' }, optimisticStage(.{ ' ', 'M' }).?);
    try std.testing.expectEqual([2]u8{ 'M', ' ' }, optimisticStage(.{ 'M', 'M' }).?);
    try std.testing.expectEqual([2]u8{ 'D', ' ' }, optimisticStage(.{ ' ', 'D' }).?);
    // Already fully staged / unmapped code: no instant transition.
    try std.testing.expect(optimisticStage(.{ 'A', ' ' }) == null);

    // Unstage transitions (the reverse).
    try std.testing.expectEqual([2]u8{ '?', '?' }, optimisticUnstage(.{ 'A', ' ' }).?);
    try std.testing.expectEqual([2]u8{ ' ', 'M' }, optimisticUnstage(.{ 'M', ' ' }).?);
    try std.testing.expectEqual([2]u8{ ' ', 'D' }, optimisticUnstage(.{ 'D', ' ' }).?);
    try std.testing.expect(optimisticUnstage(.{ ' ', 'M' }) == null);

    // setStatusFields rewrites the code and re-derives the flags.
    var f = FileStatus{ .path = @constCast("x"), .short_status = .{ ' ', 'M' }, .has_staged = false, .has_unstaged = true, .tracked = true, .added = false, .deleted = false, .conflict = false };
    setStatusFields(&f, .{ 'M', ' ' });
    try std.testing.expectEqual([2]u8{ 'M', ' ' }, f.short_status);
    try std.testing.expect(f.has_staged and !f.has_unstaged);
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

test "sortFiles orders by name, and by status group then name" {
    var files = [_]FileStatus{
        .{ .path = @constCast("z_untracked.txt"), .short_status = .{ '?', '?' }, .has_staged = false, .has_unstaged = true, .tracked = false, .added = false, .deleted = false, .conflict = false },
        .{ .path = @constCast("a_staged.txt"), .short_status = .{ 'A', ' ' }, .has_staged = true, .has_unstaged = false, .tracked = true, .added = true, .deleted = false, .conflict = false },
        .{ .path = @constCast("m_unstaged.txt"), .short_status = .{ ' ', 'M' }, .has_staged = false, .has_unstaged = true, .tracked = true, .added = false, .deleted = false, .conflict = false },
        .{ .path = @constCast("b_untracked.txt"), .short_status = .{ '?', '?' }, .has_staged = false, .has_unstaged = true, .tracked = false, .added = false, .deleted = false, .conflict = false },
    };

    // `.name`: pure path order, regardless of git status.
    sortFiles(&files, .name);
    try std.testing.expectEqualStrings("a_staged.txt", files[0].path);
    try std.testing.expectEqualStrings("b_untracked.txt", files[1].path);
    try std.testing.expectEqualStrings("m_unstaged.txt", files[2].path);
    try std.testing.expectEqualStrings("z_untracked.txt", files[3].path);

    // `.status`: staged, then tracked-unstaged, then untracked; path within group.
    sortFiles(&files, .status);
    try std.testing.expectEqualStrings("a_staged.txt", files[0].path); // staged
    try std.testing.expectEqualStrings("m_unstaged.txt", files[1].path); // tracked unstaged
    try std.testing.expectEqualStrings("b_untracked.txt", files[2].path); // untracked (b < z)
    try std.testing.expectEqualStrings("z_untracked.txt", files[3].path); // untracked
}
