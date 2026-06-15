const std = @import("std");
const vaxis = @import("vaxis");

const actions = @import("actions.zig");
const config_mod = @import("config.zig");
const diff_mod = @import("diff.zig");
const filetree = @import("filetree.zig");
const git_mod = @import("git.zig");
const model = @import("model.zig");
const textmatch = @import("textmatch.zig");

pub const Mode = enum {
    normal,
    commit_prompt,
    file_filter_prompt,
    status_filter_menu,
    menu,
    text_prompt,
    confirmation,
    command_log,
    help,
    operation,
};

/// Lets App repaint the screen mid-handler. Synchronous git operations block
/// the event loop while they run, so the operation dialog paints its "running"
/// frame through this hook before the blocking call, then the loop paints the
/// result once the handler returns. Installed by the TUI; null in tests.
pub const RenderHook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,

    pub fn call(self: RenderHook) void {
        self.func(self.ctx);
    }
};

/// Which field of the two-field commit editor has focus.
pub const CommitField = enum { subject, body };

/// Whether the commit editor creates a new commit or rewords an existing one.
pub const CommitAction = enum { create, reword };

/// A reusable single-line text-input popup. Each kind knows its title and what
/// to do with the submitted text.
pub const TextPromptKind = enum {
    new_branch,
    rename_branch,
    new_tag,
    add_remote_name,
    add_remote_url,
    edit_remote_url,
    commit_grep,
    commit_author,
    commit_path,

    pub fn title(self: TextPromptKind) []const u8 {
        return switch (self) {
            .new_branch => "New branch name",
            .rename_branch => "Rename branch",
            .new_tag => "New tag name",
            .add_remote_name => "New remote name",
            .add_remote_url => "New remote URL",
            .edit_remote_url => "Remote URL",
            .commit_grep => "Filter commits by message",
            .commit_author => "Filter commits by author",
            .commit_path => "Filter commits by path",
        };
    }
};

pub const Confirmation = enum {
    discard_all,
    merge_branch,
    rebase_branch,
    delete_tag,
    delete_remote_branch,
    remove_worktree,
    remove_remote,
    undo,
};

/// Network operations that run off the UI loop so they don't freeze it.
pub const AsyncOp = enum {
    fetch,
    pull,
    push,

    pub fn label(self: AsyncOp) []const u8 {
        return switch (self) {
            .fetch => "fetch",
            .pull => "pull",
            .push => "push",
        };
    }

    pub fn gerund(self: AsyncOp) []const u8 {
        return switch (self) {
            .fetch => "fetching",
            .pull => "pulling",
            .push => "pushing",
        };
    }

    /// Git args (without the leading "git") run for this operation.
    pub fn argv(self: AsyncOp) []const []const u8 {
        return switch (self) {
            .fetch => &.{ "fetch", "--all", "--no-write-fetch-head" },
            .pull => &.{ "pull", "--no-edit" },
            .push => &.{"push"},
        };
    }
};

/// A panel's screen rectangle, captured during render for mouse hit-testing.
pub const PanelRect = struct {
    focus: model.Focus,
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(self: PanelRect, col: u16, row: u16) bool {
        return col >= self.x and col < self.x + self.w and row >= self.y and row < self.y + self.h;
    }
};

/// An interactive-rebase action applied to the selected commit.
pub const RebaseAction = enum {
    drop,
    squash,
    fixup,
    edit,
    reword,
    move_up,
    move_down,

    /// The git-rebase-todo verb for this action.
    pub fn word(self: RebaseAction) []const u8 {
        return switch (self) {
            .drop => "drop",
            .squash => "squash",
            .fixup => "fixup",
            .edit => "edit",
            .reword => "reword",
            .move_up, .move_down => "pick",
        };
    }

    pub fn label(self: RebaseAction) []const u8 {
        return switch (self) {
            .drop => "dropped commit",
            .squash => "squashed commit",
            .fixup => "fixed up commit",
            .edit => "stopped to edit commit",
            .reword => "reworded commit",
            .move_up => "moved commit up",
            .move_down => "moved commit down",
        };
    }
};

/// Tabs within the Branches panel, switched with [ and ] (lazygit).
pub const BranchesTab = enum {
    local,
    remotes,
    tags,
    worktrees,
    submodules,

    pub fn label(self: BranchesTab) []const u8 {
        return switch (self) {
            .local => "Branches",
            .remotes => "Remotes",
            .tags => "Tags",
            .worktrees => "Worktrees",
            .submodules => "Submodules",
        };
    }
};

/// Tabs within the Commits panel, switched with [ and ] (lazygit).
pub const CommitsTab = enum {
    commits,
    reflog,

    pub fn label(self: CommitsTab) []const u8 {
        return switch (self) {
            .commits => "Commits",
            .reflog => "Reflog",
        };
    }
};

/// Actions a generic menu popup can dispatch when its selected item is chosen.
pub const MenuAction = enum {
    discard_file_all,
    discard_file_unstaged,
    delete_branch,
    force_delete_branch,
    reset_soft,
    reset_mixed,
    reset_hard,
    take_ours,
    take_theirs,
    conflict_continue,
    conflict_abort,
    rebase_amend_continue,
    stash_all,
    stash_untracked,
    stash_staged,
    stash_file,
    filter_commits_message,
    filter_commits_author,
    filter_commits_path,
    clear_commit_filter,
    bisect_start_bad,
    bisect_start_good,
    bisect_good_current,
    bisect_bad_current,
    bisect_skip,
    bisect_good_selected,
    bisect_bad_selected,
    bisect_reset,
    patch_apply,
    patch_apply_reverse,
    patch_remove_from_commit,
    patch_reset,
};

pub const MenuItem = struct {
    label: []const u8,
    action: MenuAction,
};

/// A lazygit-style action menu: a titled list of choices navigated with j/k
/// and confirmed with enter. Items point at static arrays, so no ownership.
pub const Menu = struct {
    title: []const u8,
    items: []const MenuItem,
    index: usize = 0,
};

const discard_menu_staged_and_unstaged = [_]MenuItem{
    .{ .label = "Discard all changes", .action = .discard_file_all },
    .{ .label = "Discard unstaged changes", .action = .discard_file_unstaged },
};

const discard_menu_all_only = [_]MenuItem{
    .{ .label = "Discard all changes", .action = .discard_file_all },
};

const branch_delete_menu = [_]MenuItem{
    .{ .label = "Delete branch", .action = .delete_branch },
    .{ .label = "Force delete branch", .action = .force_delete_branch },
};

const commit_reset_menu = [_]MenuItem{
    .{ .label = "Soft reset (keep staged changes)", .action = .reset_soft },
    .{ .label = "Mixed reset (keep working tree)", .action = .reset_mixed },
    .{ .label = "Hard reset (discard changes)", .action = .reset_hard },
};

const conflict_resolve_menu = [_]MenuItem{
    .{ .label = "Take ours (keep current branch's version)", .action = .take_ours },
    .{ .label = "Take theirs (keep incoming version)", .action = .take_theirs },
};

const conflict_actions_menu = [_]MenuItem{
    .{ .label = "Continue", .action = .conflict_continue },
    .{ .label = "Abort", .action = .conflict_abort },
};

/// Shown for an in-progress rebase: an `edit` stop additionally offers
/// amending the stopped commit with the staged changes before continuing.
const rebase_actions_menu = [_]MenuItem{
    .{ .label = "Continue", .action = .conflict_continue },
    .{ .label = "Amend this commit, then continue", .action = .rebase_amend_continue },
    .{ .label = "Abort", .action = .conflict_abort },
};

const stash_menu = [_]MenuItem{
    .{ .label = "Stash all changes", .action = .stash_all },
    .{ .label = "Stash including untracked files", .action = .stash_untracked },
    .{ .label = "Stash staged changes only", .action = .stash_staged },
    .{ .label = "Stash the selected file", .action = .stash_file },
};

const commit_filter_menu = [_]MenuItem{
    .{ .label = "Filter by message (grep)", .action = .filter_commits_message },
    .{ .label = "Filter by author", .action = .filter_commits_author },
    .{ .label = "Filter by path", .action = .filter_commits_path },
    .{ .label = "Clear filter", .action = .clear_commit_filter },
};

const bisect_start_menu = [_]MenuItem{
    .{ .label = "Mark selected commit bad, start bisecting", .action = .bisect_start_bad },
    .{ .label = "Mark selected commit good, start bisecting", .action = .bisect_start_good },
};

const bisect_actions_menu = [_]MenuItem{
    .{ .label = "Mark current commit good", .action = .bisect_good_current },
    .{ .label = "Mark current commit bad", .action = .bisect_bad_current },
    .{ .label = "Skip current commit", .action = .bisect_skip },
    .{ .label = "Mark selected commit good", .action = .bisect_good_selected },
    .{ .label = "Mark selected commit bad", .action = .bisect_bad_selected },
    .{ .label = "Reset bisect", .action = .bisect_reset },
};

const patch_menu_items = [_]MenuItem{
    .{ .label = "Apply patch to working tree", .action = .patch_apply },
    .{ .label = "Apply patch in reverse", .action = .patch_apply_reverse },
    .{ .label = "Remove patch from its commit", .action = .patch_remove_from_commit },
    .{ .label = "Reset patch", .action = .patch_reset },
};

/// Order of entries shown in the status-filter menu popup.
pub const status_filter_options = [_]model.FileDisplayFilter{
    .all,
    .staged,
    .unstaged,
    .tracked,
    .untracked,
    .conflicted,
};

/// Allocations shared with worker threads (preview, worktree, mutation jobs)
/// use the page allocator, which is thread-safe and independent of the main gpa
/// (mirrors the network async path in tui.zig). Job specs and results live here.
const page_alloc = std.heap.page_allocator;

/// One `git` invocation contributing a labeled section to a preview. `argv` is
/// the argument vector after "git" (the worker prepends it). Every string is
/// page-allocated so the job is self-contained across the thread boundary and
/// survives repo refreshes. `keep_on_error` is for `diff --no-index` on
/// untracked files, which exits non-zero yet still prints a usable diff.
pub const PreviewSection = struct {
    argv: []const []const u8,
    label: []const u8 = "",
    keep_on_error: bool = false,
};

/// A git-backed preview to render off the UI thread. Built on the UI thread
/// from the current selection (see `buildPreviewJob`), run by the TUI loop's
/// preview worker, and the result stashed in `PreviewCache`. Owned by the page
/// allocator; freed via `deinit` once consumed.
pub const PreviewJob = struct {
    key: []const u8,
    sections: []const PreviewSection,
    /// Static fallback text shown when every section comes back empty.
    empty_msg: []const u8,

    /// Worker-thread entry point: run each section's git command and stitch the
    /// non-empty outputs together with their labels. Allocates with `gpa` (the
    /// page allocator); the returned slice is owned by the caller.
    pub fn run(self: PreviewJob, gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.sections) |sec| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.append(gpa, "git");
            try argv.appendSlice(gpa, sec.argv);
            const res = std.process.run(gpa, io, .{
                .argv = argv.items,
                .cwd = .{ .path = root },
                .stdout_limit = .limited(16 * 1024 * 1024),
                .stderr_limit = .limited(4 * 1024 * 1024),
            }) catch continue;
            defer gpa.free(res.stdout);
            defer gpa.free(res.stderr);
            const ok = switch (res.term) {
                .exited => |code| code == 0,
                else => false,
            };
            const usable = if (sec.keep_on_error) res.stdout.len > 0 else (ok and res.stdout.len > 0);
            if (!usable) continue;
            if (out.items.len > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, sec.label);
            try out.appendSlice(gpa, res.stdout);
        }
        if (out.items.len == 0) return gpa.dupe(u8, self.empty_msg);
        return out.toOwnedSlice(gpa);
    }

    pub fn deinit(self: PreviewJob, gpa: std.mem.Allocator) void {
        for (self.sections) |sec| {
            for (sec.argv) |arg| gpa.free(arg);
            gpa.free(sec.argv);
        }
        gpa.free(self.sections);
        gpa.free(self.key);
    }
};

/// Copy an argument vector into the page allocator so a `PreviewSection` owns
/// every string and can outlive the borrowed selection slices it was built from.
fn dupArgv(parts: []const []const u8) ![]const []const u8 {
    const out = try page_alloc.alloc([]const u8, parts.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |a| page_alloc.free(a);
        page_alloc.free(out);
    }
    for (parts) |p| {
        out[filled] = try page_alloc.dupe(u8, p);
        filled += 1;
    }
    return out;
}

/// The first non-blank line of `text`, trimmed, or "" if there is none. Used to
/// surface a one-line summary (e.g. bisect progress, an error's first line) in
/// the bottom bar.
fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

/// Describes the preview the current selection wants, independent of how it is
/// fetched. Translated into a `PreviewJob` and a cache key on the UI thread.
const PreviewKind = union(enum) {
    file: model.FileStatus,
    branch: []const u8,
    commit: []const u8,
    commit_file: struct { hash: []const u8, path: []const u8 },
    stash: usize,
    diff_refs: struct { base: []const u8, target: []const u8 },
};

/// Bounded, insertion-ordered cache of rendered preview text keyed by a
/// content-addressed string (e.g. "c:3:<hash>", "f:3:U_T:<path>"). Lets
/// revisiting an item render instantly and lets the async worker stash results
/// it produced even after the selection moved on. Keys and values are gpa-owned.
const PreviewCache = struct {
    const max_entries = 256;
    const max_bytes = 32 * 1024 * 1024;

    map: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    bytes: usize = 0,

    fn deinit(self: *PreviewCache, gpa: std.mem.Allocator) void {
        for (self.map.keys()) |k| gpa.free(k);
        for (self.map.values()) |v| gpa.free(v);
        self.map.deinit(gpa);
    }

    fn get(self: *PreviewCache, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// Insert a copy of `value` under `key`. Content is immutable for a given
    /// key, so an existing entry is kept. Evicts oldest entries past the caps.
    fn put(self: *PreviewCache, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (self.map.contains(key)) return;
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        const k = try gpa.dupe(u8, key);
        errdefer gpa.free(k);
        try self.map.put(gpa, k, v);
        self.bytes += v.len;
        while ((self.map.count() > max_entries or self.bytes > max_bytes) and self.map.count() > 1) {
            const old_k = self.map.keys()[0];
            const old_v = self.map.values()[0];
            self.bytes -= old_v.len;
            self.map.orderedRemoveAt(0);
            gpa.free(old_k);
            gpa.free(old_v);
        }
    }

    fn clearAll(self: *PreviewCache, gpa: std.mem.Allocator) void {
        for (self.map.keys()) |k| gpa.free(k);
        for (self.map.values()) |v| gpa.free(v);
        self.map.clearRetainingCapacity();
        self.bytes = 0;
    }

    /// Drop entries whose key starts with `prefix` (e.g. "f:" when the working
    /// tree changed but commit/branch diffs remain valid).
    fn invalidatePrefix(self: *PreviewCache, gpa: std.mem.Allocator, prefix: []const u8) void {
        var i: usize = 0;
        while (i < self.map.count()) {
            const k = self.map.keys()[i];
            if (std.mem.startsWith(u8, k, prefix)) {
                const v = self.map.values()[i];
                self.bytes -= v.len;
                self.map.orderedRemoveAt(i);
                gpa.free(k);
                gpa.free(v);
            } else {
                i += 1;
            }
        }
    }
};

/// Working-tree state gathered off the UI thread for the background auto-refresh
/// (the 1.5s tick). The slow part — spawning `git status` and friends — runs in
/// `load` on a worker with the page allocator; the UI thread then converts the
/// payload into gpa-owned `RepoData` (see `App.applyWorktreeSnapshot`). Keeping
/// the git calls off the loop means the periodic refresh no longer hitches
/// navigation on large repos.
pub const WorktreeSnapshot = struct {
    status: model.StatusSummary,
    porcelain: []u8,
    state: model.RepoState,

    /// Worker-thread entry point. `gpa` is the page allocator; everything
    /// returned is owned by it. Borrows `root`/`environ` read-only from the
    /// app's Git (never mutated by these read-only commands).
    pub fn load(gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, root: []u8) !WorktreeSnapshot {
        // A throwaway Git bound to the page allocator. The commands it runs
        // (branch/rev-parse/rev-list/status) are all read-only, so its command
        // log stays empty and `root` is only ever read — no deinit needed.
        var wgit = git_mod.Git{
            .allocator = gpa,
            .io = io,
            .environ = environ,
            .root = root,
        };
        var status = try wgit.loadStatusSummary();
        errdefer status.deinit(gpa);
        const porcelain = try wgit.statusPorcelain();
        return .{ .status = status, .porcelain = porcelain, .state = wgit.detectState() };
    }

    pub fn deinit(self: *WorktreeSnapshot, gpa: std.mem.Allocator) void {
        self.status.deinit(gpa);
        gpa.free(self.porcelain);
        self.* = undefined;
    }
};

/// Worker-thread full repo load (lazygit-style async startup). Runs
/// `git.loadRepoData` on a throwaway page-allocator `Git`; the result is
/// page-owned and the UI thread deep-copies it into the gpa (see
/// `App.applyRepoLoad`). Returns null on failure. `root`/`environ` are borrowed
/// read-only. The throwaway Git's command log stays empty (loadRepoData is all
/// read-only commands) but is freed defensively.
pub fn loadRepoDataAsync(gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, root: []u8) ?model.RepoData {
    var wgit = git_mod.Git{ .allocator = gpa, .io = io, .environ = environ, .root = root };
    defer {
        for (wgit.command_log.items) |e| gpa.free(e);
        wgit.command_log.deinit(gpa);
    }
    return wgit.loadRepoData() catch null;
}

/// A slow / multi-step git mutation to run off the UI thread (merge, rebase,
/// bisect, custom-patch, …). The worker runs it on a page-allocator `Git`,
/// which reuses the real `Git` methods verbatim — so temp files, env vars and
/// multi-step sequences all work. Fast/instant mutations (stage, checkout, …)
/// stay synchronous so rapid input is never gated. Params are page-allocated
/// copies so the job is self-contained across the thread boundary.
pub const Mutation = union(enum) {
    merge: []const u8,
    rebase: []const u8,
    rebase_onto_marked: struct { newbase: []const u8, marked_base: []const u8 },
    autosquash: []const u8,
    fast_forward_current,
    fast_forward_branch: struct { remote: []const u8, remote_ref: []const u8, local: []const u8 },
    bisect_start_mark: struct { good: bool, rev: []const u8 },
    bisect_mark: struct { good: bool, rev: ?[]const u8 },
    bisect_skip,
    bisect_reset,
    amend_continue_rebase,
    apply_custom_patch: struct { patch: []const u8, reverse: bool },
    remove_patch_from_commit: struct { base_ref: []const u8, todo: []const u8, patch: []const u8 },
    rebase_todo: struct { base_ref: []const u8, todo: []const u8, message: ?[]const u8 },

    /// Worker-thread entry point: run the mutation on a throwaway page-allocator
    /// `Git`. The wgit's command log (mutations are recorded) is page-allocated
    /// and freed here since the real app log is updated separately on request.
    pub fn run(self: Mutation, gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, root: []u8) !git_mod.ExecResult {
        var wgit = git_mod.Git{ .allocator = gpa, .io = io, .environ = environ, .root = root };
        defer {
            for (wgit.command_log.items) |e| gpa.free(e);
            wgit.command_log.deinit(gpa);
        }
        return switch (self) {
            .merge => |b| wgit.mergeBranch(b),
            .rebase => |b| wgit.rebaseOnto(b),
            .rebase_onto_marked => |x| wgit.rebaseOntoMarked(x.newbase, x.marked_base),
            .autosquash => |base| wgit.autosquashRebase(base),
            .fast_forward_current => wgit.fastForwardCurrent(),
            .fast_forward_branch => |x| wgit.fastForwardBranch(x.remote, x.remote_ref, x.local),
            .bisect_start_mark => |x| wgit.bisectStartMark(x.good, x.rev),
            .bisect_mark => |x| wgit.bisectMark(x.good, x.rev),
            .bisect_skip => wgit.bisectSkip(),
            .bisect_reset => wgit.bisectReset(),
            .amend_continue_rebase => wgit.amendAndContinueRebase(),
            .apply_custom_patch => |x| wgit.applyCustomPatch(x.patch, x.reverse),
            .remove_patch_from_commit => |x| wgit.removePatchFromCommit(x.base_ref, x.todo, x.patch),
            .rebase_todo => |x| wgit.rebaseTodo(x.base_ref, x.todo, x.message),
        };
    }

    /// Deep copy into `gpa` (the page allocator) so the job outlives the
    /// borrowed selection slices it was built from.
    pub fn dupe(self: Mutation, gpa: std.mem.Allocator) !Mutation {
        return switch (self) {
            .merge => |b| .{ .merge = try gpa.dupe(u8, b) },
            .rebase => |b| .{ .rebase = try gpa.dupe(u8, b) },
            .rebase_onto_marked => |x| .{ .rebase_onto_marked = .{ .newbase = try gpa.dupe(u8, x.newbase), .marked_base = try gpa.dupe(u8, x.marked_base) } },
            .autosquash => |base| .{ .autosquash = try gpa.dupe(u8, base) },
            .fast_forward_current => .fast_forward_current,
            .fast_forward_branch => |x| .{ .fast_forward_branch = .{ .remote = try gpa.dupe(u8, x.remote), .remote_ref = try gpa.dupe(u8, x.remote_ref), .local = try gpa.dupe(u8, x.local) } },
            .bisect_start_mark => |x| .{ .bisect_start_mark = .{ .good = x.good, .rev = try gpa.dupe(u8, x.rev) } },
            .bisect_mark => |x| .{ .bisect_mark = .{ .good = x.good, .rev = if (x.rev) |r| try gpa.dupe(u8, r) else null } },
            .bisect_skip => .bisect_skip,
            .bisect_reset => .bisect_reset,
            .amend_continue_rebase => .amend_continue_rebase,
            .apply_custom_patch => |x| .{ .apply_custom_patch = .{ .patch = try gpa.dupe(u8, x.patch), .reverse = x.reverse } },
            .remove_patch_from_commit => |x| .{ .remove_patch_from_commit = .{ .base_ref = try gpa.dupe(u8, x.base_ref), .todo = try gpa.dupe(u8, x.todo), .patch = try gpa.dupe(u8, x.patch) } },
            .rebase_todo => |x| .{ .rebase_todo = .{ .base_ref = try gpa.dupe(u8, x.base_ref), .todo = try gpa.dupe(u8, x.todo), .message = if (x.message) |m| try gpa.dupe(u8, m) else null } },
        };
    }

    pub fn deinit(self: Mutation, gpa: std.mem.Allocator) void {
        switch (self) {
            .merge, .rebase, .autosquash => |s| gpa.free(s),
            .rebase_onto_marked => |x| {
                gpa.free(x.newbase);
                gpa.free(x.marked_base);
            },
            .fast_forward_branch => |x| {
                gpa.free(x.remote);
                gpa.free(x.remote_ref);
                gpa.free(x.local);
            },
            .bisect_start_mark => |x| gpa.free(x.rev),
            .bisect_mark => |x| if (x.rev) |r| gpa.free(r),
            .apply_custom_patch => |x| gpa.free(x.patch),
            .remove_patch_from_commit => |x| {
                gpa.free(x.base_ref);
                gpa.free(x.todo);
                gpa.free(x.patch);
            },
            .rebase_todo => |x| {
                gpa.free(x.base_ref);
                gpa.free(x.todo);
                if (x.message) |m| gpa.free(m);
            },
            .fast_forward_current, .bisect_skip, .bisect_reset, .amend_continue_rebase => {},
        }
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    git: git_mod.Git,
    config: config_mod.Config,
    data: model.RepoData = .{},
    focus: model.Focus = .files,
    main_origin: model.Focus = .files,
    file_index: usize = 0,
    tree_view: bool = false,
    tree_rows: []filetree.Row = &.{},
    tree_cursor: usize = 0,
    collapsed_dirs: std.BufSet = undefined,
    branch_index: usize = 0,
    remote_index: usize = 0,
    tag_index: usize = 0,
    worktree_index: usize = 0,
    submodule_index: usize = 0,
    commit_index: usize = 0,
    reflog_index: usize = 0,
    stash_index: usize = 0,
    /// Cherry-pick clipboard: full SHAs of copied commits, applied on paste.
    copied_commits: std.ArrayList([]u8) = .empty,
    /// A commit marked as the base for a `rebase --onto` (full SHA), or null.
    marked_base: ?[]u8 = null,
    commit_files: []model.CommitFile = &.{},
    commit_file_index: usize = 0,
    commit_files_active: bool = false,
    staging_active: bool = false,
    staging_staged_view: bool = false,
    staging_path: []u8 = &.{},
    staging_diff: []u8 = &.{},
    staging: ?diff_mod.ParsedDiff = null,
    staging_cursor: usize = 0,
    staging_anchor: ?usize = null,
    main_view_height: u16 = 0,
    /// Panel hit-boxes captured by the renderer for mouse handling.
    panel_rects: [6]PanelRect = undefined,
    panel_rect_count: usize = 0,
    branches_tab: BranchesTab = .local,
    commits_tab: CommitsTab = .commits,
    main_scroll: usize = 0,
    file_display_filter: model.FileDisplayFilter = .all,
    commit_body_buffer: std.ArrayList(u8) = .empty,
    commit_field: CommitField = .subject,
    commit_action: CommitAction = .create,
    commit_reword_index: usize = 0,
    diff: []u8 = &.{},
    message: []u8 = &.{},
    file_filter: []u8 = &.{},
    // Operation dialog: the modal that shows a synchronous git op running and
    // its result. `op_command` is the command line, `op_summary` a one-line
    // outcome, `op_output` the raw stdout/stderr. `op_running` is true only
    // while the pre-exec "running" frame is up.
    op_command: []u8 = &.{},
    op_summary: []u8 = &.{},
    op_output: []u8 = &.{},
    op_ok: bool = true,
    op_running: bool = false,
    op_scroll: usize = 0,
    render_hook: ?RenderHook = null,
    // Text the TUI loop should copy to the system clipboard (OSC 52), owned;
    // set by a copy action, consumed and freed by the loop.
    clipboard_request: ?[]u8 = null,
    // Diffing mode: the ref (commit hash or branch) marked as the diff base.
    // When set, the main panel shows `git diff <base> <selected ref>`.
    diff_base: ?[]u8 = null,
    // Custom patch: paths added from a single source commit. The patch bytes
    // are rebuilt on demand from `patch_source` and these paths.
    patch_source: ?[]u8 = null,
    patch_paths: std.ArrayList([]u8) = .empty,
    commit_buffer: std.ArrayList(u8) = .empty,
    file_filter_buffer: std.ArrayList(u8) = .empty,
    filter_history: std.ArrayList([]u8) = .empty,
    filter_history_index: ?usize = null,
    input_buffer: std.ArrayList(u8) = .empty,
    text_prompt_kind: ?TextPromptKind = null,
    // Holds the remote name between the two-step add-remote prompt (name → URL)
    // and the remote acted on by edit/remove. No allocation needed.
    remote_name_buf: [128]u8 = undefined,
    remote_name_len: usize = 0,
    mode: Mode = .normal,
    status_filter_index: usize = 0,
    help_scroll: usize = 0,
    undo_label_buf: [160]u8 = undefined,
    undo_label_len: usize = 0,
    active_menu: ?Menu = null,
    pending_confirmation: ?Confirmation = null,
    terminal_focused: bool = true,
    running: bool = true,
    /// A network op the TUI loop should start; cleared once it spawns the worker.
    async_requested: ?AsyncOp = null,
    /// True while a network op is running off-loop (single in-flight).
    async_active: bool = false,
    async_op: AsyncOp = .fetch,

    // Async preview pipeline. Switching panels / moving the selection only
    // computes a cache key and renders cached text (instant); the matching git
    // command runs off the UI loop. `preview_desired_key` is what the current
    // selection wants shown; `preview_wanted` is a built job the loop should
    // start; `preview_inflight_key` is the job currently running off-thread.
    preview_cache: PreviewCache = .{},
    preview_desired_key: []const u8 = &.{},
    preview_wanted: ?PreviewJob = null,
    preview_inflight_key: []const u8 = &.{},
    preview_loading: bool = false,

    // Background working-tree refresh (the 1.5s tick). `..._requested` is set by
    // the tick for the TUI loop to start a worker; `..._active` guards against
    // overlapping workers. `refresh_generation` bumps on every full refresh so a
    // worktree snapshot that started before it can be discarded as stale.
    worktree_refresh_requested: bool = false,
    worktree_refresh_active: bool = false,
    refresh_generation: u64 = 0,
    /// True from startup until the first (async) repo load lands; panels show a
    /// "Loading…" state and mutating input is gated meanwhile.
    initial_load_pending: bool = false,

    // Async slow mutations (merge/rebase/bisect/…) run off the UI loop like the
    // network ops: `mutation_requested` is a built job the loop starts (page-
    // allocated), `mutation_active` is the in-flight guard. `mutation_msg` is
    // the success summary (page-allocated), `mutation_echo` uses git's stdout
    // first line instead (bisect), `mutation_gerund` labels the spinner. While
    // any foreground op runs, mutating keys are ignored but navigation stays
    // live. `busy_flag` lets the ticker speed up to animate the spinner.
    mutation_requested: ?Mutation = null,
    mutation_active: bool = false,
    mutation_msg: []u8 = &.{},
    mutation_echo: bool = false,
    mutation_post: PostMutation = .none,
    mutation_gerund: []const u8 = "working",
    busy_flag: std.atomic.Value(bool) = .init(false),
    spinner_frame: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
    ) !App {
        var git = try git_mod.Git.init(allocator, io, env_map);
        errdefer git.deinit();

        const cfg = try config_mod.Config.load(allocator, io, env_map, git.root);
        var app = App{
            .allocator = allocator,
            .git = git,
            .config = cfg,
        };
        app.collapsed_dirs = std.BufSet.init(allocator);
        errdefer app.deinit();

        // The initial repo load runs off-thread, started by the TUI loop (see
        // `beginInitialLoad`/`applyRepoLoad`), so the UI paints a "Loading…"
        // skeleton immediately instead of blocking on a large-repo load.
        try app.setMessage("loading...", .{});
        return app;
    }

    pub fn deinit(self: *App) void {
        self.data.deinit(self.allocator);
        model.deinitCommitFiles(self.allocator, self.commit_files);
        self.allocator.free(self.tree_rows);
        self.collapsed_dirs.deinit();
        if (self.staging) |*parsed| parsed.deinit(self.allocator);
        self.allocator.free(self.staging_diff);
        self.allocator.free(self.staging_path);
        self.allocator.free(self.diff);
        self.allocator.free(self.message);
        self.allocator.free(self.file_filter);
        self.allocator.free(self.op_command);
        self.allocator.free(self.op_summary);
        self.allocator.free(self.op_output);
        self.commit_buffer.deinit(self.allocator);
        self.commit_body_buffer.deinit(self.allocator);
        self.file_filter_buffer.deinit(self.allocator);
        for (self.filter_history.items) |entry| self.allocator.free(entry);
        self.filter_history.deinit(self.allocator);
        for (self.copied_commits.items) |entry| self.allocator.free(entry);
        self.copied_commits.deinit(self.allocator);
        if (self.marked_base) |b| self.allocator.free(b);
        if (self.clipboard_request) |c| self.allocator.free(c);
        if (self.diff_base) |b| self.allocator.free(b);
        if (self.patch_source) |s| self.allocator.free(s);
        for (self.patch_paths.items) |p| self.allocator.free(p);
        self.patch_paths.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
        self.preview_cache.deinit(self.allocator);
        self.allocator.free(self.preview_desired_key);
        self.allocator.free(self.preview_inflight_key);
        if (self.preview_wanted) |job| job.deinit(page_alloc);
        if (self.mutation_requested) |job| job.deinit(page_alloc);
        page_alloc.free(self.mutation_msg);
        self.git.deinit();
        self.* = undefined;
    }

    /// Mark the initial repo load as in progress. The TUI loop spawns the load
    /// worker and paints the skeleton (panels show "Loading…") immediately;
    /// `applyRepoLoad` lands the data when the worker finishes.
    pub fn beginInitialLoad(self: *App) void {
        self.initial_load_pending = true;
        self.setMessage("loading repository...", .{}) catch {};
    }

    /// TUI loop hook: apply the finished async repo load. `page_data` (owned by
    /// `gpa`, the page allocator) is null on failure. Deep-copies into the
    /// gpa-owned `data` and frees the page version.
    pub fn applyRepoLoad(self: *App, page_data_opt: ?model.RepoData, gpa: std.mem.Allocator) void {
        self.initial_load_pending = false;
        var page_data = page_data_opt orelse {
            self.setMessage("repository load failed", .{}) catch {};
            return;
        };
        defer page_data.deinit(gpa);
        const gpa_data = page_data.dupe(self.allocator) catch {
            self.setMessage("repository load failed (out of memory)", .{}) catch {};
            return;
        };
        self.data.deinit(self.allocator);
        self.data = gpa_data;
        self.refresh_generation +%= 1;
        self.preview_cache.clearAll(self.allocator);
        self.clampSelections();
        if (self.tree_view) self.rebuildTree(null) catch {};
        self.updatePreview() catch {};
        self.setMessage("ready", .{}) catch {};
    }

    pub fn refresh(self: *App) !void {
        const tree_path = try self.captureTreePath();
        defer if (tree_path) |p| self.allocator.free(p);

        // Invalidate any in-flight background worktree snapshot: this full
        // reload is newer, so a snapshot that started earlier must not clobber it.
        // A queued (not-yet-started) request is now redundant — drop it.
        self.refresh_generation +%= 1;
        self.worktree_refresh_requested = false;

        const next = try self.git.loadRepoData();
        self.data.deinit(self.allocator);
        self.data = next;
        // A full reload can move branches, rewrite history and shift stash
        // indices, so every cached preview is potentially stale.
        self.preview_cache.clearAll(self.allocator);
        self.clampSelections();
        if (self.tree_view) try self.rebuildTree(tree_path);
        if (self.commit_files_active) self.reloadCommitFilesAfterRefresh();
        self.updatePreview() catch |err| {
            try self.setMessage("preview failed: {s}", .{@errorName(err)});
        };
    }

    /// Fast, scoped reload of just the working tree (status + file list), the
    /// lazygit "FILES scope" refresh. Used after stage/unstage/discard/resolve,
    /// which change only the working tree — reloading the whole repo (branches,
    /// 100 commits, reflog, tags, …) on every such keypress is what made staging
    /// slow and clunky. Keeps the cursor on the same file.
    pub fn refreshFiles(self: *App) !void {
        const selected_path = if (self.selectedFile()) |file| try self.allocator.dupe(u8, file.path) else null;
        defer if (selected_path) |p| self.allocator.free(p);
        const tree_path = try self.captureTreePath();
        defer if (tree_path) |p| self.allocator.free(p);

        var files = try self.git.loadFiles();
        errdefer model.deinitFileStatuses(self.allocator, files);
        self.data.replaceFiles(self.allocator, files);
        files = &.{};
        self.data.state = self.git.detectState();
        // Only working-tree file diffs can have changed.
        self.preview_cache.invalidatePrefix(self.allocator, "f:");

        self.restoreFileSelection(selected_path);
        self.clampSelections();
        if (self.tree_view) try self.rebuildTree(tree_path);
        const content = self.contentFocus();
        if (content == .files or content == .status) {
            self.updatePreview() catch |err| {
                try self.setMessage("preview failed: {s}", .{@errorName(err)});
            };
        }
    }

    /// True while a foreground git operation is in progress, during which the
    /// periodic background working-tree refresh is held off (lazygit's
    /// `pauseBackgroundRefreshes`). A network op (fetch/pull/push) runs on its
    /// own worker while the loop stays live, so without this its `git status`
    /// read could overlap a write; the op finishes with its own full refresh
    /// anyway. Synchronous mutations block the loop and keep `mode` non-normal,
    /// so the tick guard already covers them — this mainly catches network ops.
    fn backgroundRefreshPaused(self: *const App) bool {
        return self.foregroundBusy();
    }

    /// Queue a background working-tree refresh (status + file list) for the TUI
    /// loop to run off-thread. Single in-flight; ignored if one is already
    /// running or queued, or while an operation is in progress. The slow git
    /// calls happen on a worker so the periodic auto-refresh never blocks
    /// navigation (see `WorktreeSnapshot`).
    pub fn requestWorktreeRefresh(self: *App) void {
        if (self.worktree_refresh_active or self.worktree_refresh_requested) return;
        if (self.backgroundRefreshPaused()) return;
        self.worktree_refresh_requested = true;
    }

    /// TUI loop hook: claim a queued worktree refresh, returning the refresh
    /// generation to stamp the worker with (so a full refresh that lands while
    /// it runs invalidates its result). Null when nothing is queued or while an
    /// operation is in progress (the request is held until it clears).
    pub fn takeWorktreeRefresh(self: *App) ?u64 {
        if (!self.worktree_refresh_requested) return null;
        if (self.backgroundRefreshPaused()) return null;
        self.worktree_refresh_requested = false;
        self.worktree_refresh_active = true;
        return self.refresh_generation;
    }

    /// TUI loop hook: apply a finished background worktree snapshot on the UI
    /// thread. `snap_opt` (owned by `gpa`, the page allocator) is null if the
    /// worker could not run. Stale snapshots — ones started before a full
    /// refresh — are dropped. The payload is freed here.
    pub fn applyWorktreeSnapshot(self: *App, snap_opt: ?WorktreeSnapshot, generation: u64, gpa: std.mem.Allocator) !void {
        self.worktree_refresh_active = false;
        var snap = snap_opt orelse return;
        defer snap.deinit(gpa);
        // A full refresh happened while we were loading: its data is newer.
        if (generation != self.refresh_generation) return;

        // Convert the page-allocated payload into gpa-owned data before touching
        // app.data, so everything stored there is freed with the right allocator.
        var status = try snap.status.dupe(self.allocator);
        errdefer status.deinit(self.allocator);
        var files = try git_mod.parseStatus(self.allocator, snap.porcelain);
        errdefer model.deinitFileStatuses(self.allocator, files);

        const selected_path = if (self.selectedFile()) |file| try self.allocator.dupe(u8, file.path) else null;
        defer if (selected_path) |path| self.allocator.free(path);
        const tree_path = try self.captureTreePath();
        defer if (tree_path) |p| self.allocator.free(p);

        self.data.replaceStatus(self.allocator, status);
        status = .{};
        self.data.replaceFiles(self.allocator, files);
        files = &.{};
        self.data.state = snap.state;
        // Only working-tree file diffs can have changed; commit/branch/stash
        // previews stay valid, so drop just the "f:" entries.
        self.preview_cache.invalidatePrefix(self.allocator, "f:");

        self.restoreFileSelection(selected_path);
        self.clampSelections();
        if (self.tree_view) try self.rebuildTree(tree_path);
        const content = self.contentFocus();
        if (content == .files or content == .status) {
            self.updatePreview() catch |err| {
                try self.setMessage("preview failed: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleKey(self: *App, key: vaxis.Key) !void {
        if (self.mode == .commit_prompt) {
            try self.handleCommitPromptKey(key);
            return;
        }
        if (self.mode == .file_filter_prompt) {
            try self.handleFileFilterPromptKey(key);
            return;
        }
        if (self.mode == .status_filter_menu) {
            try self.handleStatusFilterMenuKey(key);
            return;
        }
        if (self.mode == .menu) {
            try self.handleMenuKey(key);
            return;
        }
        if (self.mode == .text_prompt) {
            try self.handleTextPromptKey(key);
            return;
        }
        if (self.mode == .confirmation) {
            try self.handleConfirmationKey(key);
            return;
        }
        if (self.mode == .operation) {
            // The result stays up until dismissed; arrows scroll long output.
            if (self.config.keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) {
                self.op_scroll += 1;
            } else if (self.config.keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) {
                self.op_scroll -|= 1;
            } else if (self.isEnterKey(key) or self.isEscapeKey(key)) {
                self.mode = .normal;
            }
            return;
        }
        if (self.mode == .command_log) {
            // Any key closes the command-log overlay.
            self.mode = .normal;
            return;
        }
        if (self.mode == .help) {
            if (self.config.keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) {
                self.help_scroll += 1;
            } else if (self.config.keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) {
                self.help_scroll -|= 1;
            } else {
                self.mode = .normal;
            }
            return;
        }

        if (key.matches(vaxis.Key.page_up, .{})) return self.scrollMain(-10);
        if (key.matches(vaxis.Key.page_down, .{})) return self.scrollMain(10);
        if (self.isEscapeKey(key) and self.fileFilterActive()) {
            try self.clearFileFilter();
            return;
        }

        // User-defined custom commands take precedence over built-in bindings.
        for (self.config.custom_commands[0..self.config.custom_count]) |*cc| {
            if (cc.binding.matches(key)) {
                if (self.foregroundBusy()) return self.setMessage("operation in progress...", .{});
                return self.runCustomCommand(cc.command());
            }
        }

        const action = actions.fromNormalKey(key, self.config.keymap, self.focus) orelse return;
        // While a slow op runs, navigation/inspection stay live but mutating
        // keys are ignored so a second git command can't race the first.
        if (self.foregroundBusy() and actions.isMutating(action)) {
            return self.setMessage("operation in progress...", .{});
        }
        switch (action) {
            .quit => self.running = false,
            .cancel => {
                if (self.diff_base != null) {
                    self.clearDiffBase();
                    try self.setMessage("exited diffing mode", .{});
                    try self.updatePreview();
                    return;
                }
                if (self.fileFilterActive()) {
                    try self.clearFileFilter();
                    return;
                }
                if (self.focus == .commits and self.git.hasLogFilter()) {
                    try self.clearCommitFilter();
                    return;
                }
                if (self.staging_active) {
                    try self.closeStaging();
                } else if (self.focus == .main) {
                    try self.leaveMain();
                } else if (self.commit_files_active) {
                    try self.closeCommitFiles();
                } else {
                    self.running = false;
                }
            },
            .focus_status => try self.setFocus(.status),
            .focus_files => try self.setFocus(.files),
            .focus_branches => try self.setFocus(.branches),
            .focus_commits => try self.setFocus(.commits),
            .focus_stash => try self.setFocus(.stash),
            .focus_main => try self.descendOrOpenCommitFiles(),
            .prev_tab => try self.cycleTab(.prev),
            .next_tab => try self.cycleTab(.next),
            .refresh => {
                try self.refresh();
                try self.setMessage("refreshed", .{});
            },
            .fetch => try self.requestAsync(.fetch),
            .pull => try self.requestAsync(.pull),
            .push => try self.requestAsync(.push),
            .move_up => if (self.staging_active) self.moveStagingCursor(-1) else try self.moveUp(),
            .move_down => if (self.staging_active) self.moveStagingCursor(1) else try self.moveDown(),
            .range_select => {
                if (self.staging_active) {
                    self.toggleStagingRange();
                } else if (self.focus == .commits) {
                    try self.pasteCopiedCommits();
                }
            },
            .focus_left => if (self.staging_active) try self.closeStaging() else try self.focusPrevious(),
            .focus_right => if (self.staging_active) try self.toggleStagingSide() else try self.focusNext(),
            .select => {
                if (self.staging_active) {
                    try self.applyStagingSelection();
                } else switch (self.focus) {
                    .files => try self.toggleSelectedFileStaged(),
                    .branches => try self.checkoutSelectedBranch(),
                    .stash => try self.applySelectedStash(),
                    // In a commit's file list, space toggles the file into the
                    // custom patch.
                    .commits => if (self.commit_files_active) try self.toggleFileInPatch(),
                    .status, .main => {},
                }
            },
            .toggle_tree => try self.toggleTreeView(),
            .command_log => {
                self.mode = .command_log;
                try self.setMessage("command log", .{});
            },
            .help => {
                self.mode = .help;
                self.help_scroll = 0;
                try self.setMessage("help", .{});
            },
            .undo => try self.startUndoConfirm(),
            .copy_to_clipboard => try self.requestClipboardCopy(),
            .open_browser => try self.openSelectionInBrowser(),
            .diff_mark => try self.toggleDiffMark(),
            .patch_menu => try self.startPatchMenu(),
            .conflict_menu => try self.startConflictActionsMenu(),
            .stage_all => try self.toggleAllStaged(),
            .discard_selected => try self.startDiscardMenu(),
            .discard_all => try self.startDiscardAllConfirmation(),
            .stash_menu => try self.startStashMenu(),
            .start_file_filter => try self.startFileFilterPrompt(),
            .start_commit_filter => try self.startCommitFilterMenu(),
            .open_status_filter => try self.startStatusFilterMenu(),
            .start_commit => try self.startCommitPrompt(),
            .amend_commit => try self.amendLastCommit(),
            .cherry_pick => try self.toggleCommitCopy(),
            .new_branch => try self.startNewForBranchTab(),
            .delete_branch => try self.startDeleteForBranchTab(),
            .merge_branch => try self.startBranchConfirm(.merge_branch),
            .rebase_branch => try self.startBranchConfirm(.rebase_branch),
            .rename_branch => try self.startTextPrompt(.rename_branch),
            .fast_forward_branch => try self.fastForwardSelectedBranch(),
            .edit_remote => try self.startEditRemote(),
            .remove_remote => try self.startRemoveRemote(),
            .set_upstream => try self.setUpstreamToSelected(),
            .reset_commit => try self.startCommitResetMenu(),
            .revert_commit => try self.revertSelectedCommit(),
            .rebase_drop => try self.rebaseSelectedCommit(.drop),
            .rebase_squash => try self.rebaseSelectedCommit(.squash),
            .rebase_fixup => try self.rebaseSelectedCommit(.fixup),
            .rebase_edit => try self.rebaseSelectedCommit(.edit),
            .rebase_reword => try self.startReword(),
            .rebase_move_down => try self.rebaseSelectedCommit(.move_down),
            .rebase_move_up => try self.rebaseSelectedCommit(.move_up),
            .rebase_create_fixup => try self.createFixupCommit(),
            .rebase_autosquash => try self.autosquashFixups(),
            .mark_base => try self.toggleMarkBase(),
            .bisect_menu => try self.startBisectMenu(),
            .stash_pop => try self.popSelectedStash(),
            .stash_drop => try self.dropSelectedStash(),
            .confirm, .backspace => {},
        }
    }

    /// Returns true if the event changed state and a re-render is warranted.
    /// Motion/drag events (which flood with any-motion tracking) return false.
    pub fn handleMouse(self: *App, mouse: vaxis.Mouse) !bool {
        if (mouse.type != .press) return false;
        if (self.mode != .normal) return false;
        if (mouse.col < 0 or mouse.row < 0) return false;
        const rect = self.panelAt(@intCast(mouse.col), @intCast(mouse.row)) orelse return false;
        switch (mouse.button) {
            .left => {
                try self.focusPanel(rect.focus);
                try self.clickSelectInPanel(rect, @intCast(mouse.row));
            },
            .wheel_up => {
                try self.focusPanel(rect.focus);
                if (rect.focus == .main) try self.scrollMain(-1) else try self.moveUp();
            },
            .wheel_down => {
                try self.focusPanel(rect.focus);
                if (rect.focus == .main) try self.scrollMain(1) else try self.moveDown();
            },
            else => return false,
        }
        return true;
    }

    fn panelAt(self: *const App, col: u16, row: u16) ?PanelRect {
        for (self.panel_rects[0..self.panel_rect_count]) |rect| {
            if (rect.contains(col, row)) return rect;
        }
        return null;
    }

    fn focusPanel(self: *App, focus: model.Focus) !void {
        if (focus == .main) {
            if (self.focus != .main) try self.enterMain();
        } else {
            try self.setFocus(focus);
        }
    }

    /// Scroll offset a list panel uses for a given selection (mirrors the
    /// renderer's scrollStart) — used to map a clicked row back to an item.
    fn listScrollStart(selected: usize, len: usize, visible: usize) usize {
        if (len == 0 or visible == 0) return 0;
        if (selected < visible) return 0;
        return selected - visible + 1;
    }

    /// Resolve a clicked content row to an item index in a flat list.
    fn rowToIndex(current: usize, len: usize, visible: usize, rel: usize) usize {
        if (len == 0) return 0;
        const start = listScrollStart(@min(current, len - 1), len, visible);
        return @min(start + rel, len - 1);
    }

    /// Select the item under a left-click in a list panel.
    fn clickSelectInPanel(self: *App, rect: PanelRect, row: u16) !void {
        if (rect.h < 3) return; // border-only, no content
        const content_top = rect.y + 1;
        if (row < content_top) return;
        const rel: usize = row - content_top;
        const visible: usize = rect.h - 2;
        if (rel >= visible) return;

        switch (rect.focus) {
            .files => {
                if (self.tree_view) {
                    self.tree_cursor = rowToIndex(self.tree_cursor, self.tree_rows.len, visible, rel);
                } else {
                    const vis = self.visibleFileCount();
                    if (vis == 0) return;
                    const start = listScrollStart(@min(self.selectedFileVisibleOrdinal(), vis - 1), vis, visible);
                    if (self.fileIndexAtVisibleOrdinal(@min(start + rel, vis - 1))) |idx| self.file_index = idx;
                }
            },
            .branches => switch (self.branches_tab) {
                .local => self.branch_index = rowToIndex(self.branch_index, self.data.branches.len, visible, rel),
                .remotes => self.remote_index = rowToIndex(self.remote_index, self.data.remote_branches.len, visible, rel),
                .tags => self.tag_index = rowToIndex(self.tag_index, self.data.tags.len, visible, rel),
                .worktrees => self.worktree_index = rowToIndex(self.worktree_index, self.data.worktrees.len, visible, rel),
                .submodules => self.submodule_index = rowToIndex(self.submodule_index, self.data.submodules.len, visible, rel),
            },
            .commits => {
                if (self.commit_files_active) {
                    self.commit_file_index = rowToIndex(self.commit_file_index, self.commit_files.len, visible, rel);
                } else switch (self.commits_tab) {
                    .commits => self.commit_index = rowToIndex(self.commit_index, self.data.commits.len, visible, rel),
                    .reflog => self.reflog_index = rowToIndex(self.reflog_index, self.data.reflog.len, visible, rel),
                }
            },
            .stash => self.stash_index = rowToIndex(self.stash_index, self.data.stash.len, visible, rel),
            .status, .main => return,
        }
        try self.updatePreview();
    }

    /// The file index shown at a given visible (filtered) ordinal, or null.
    fn fileIndexAtVisibleOrdinal(self: *const App, ordinal: usize) ?usize {
        var count: usize = 0;
        for (self.data.files, 0..) |file, idx| {
            if (!self.fileMatchesFilter(file)) continue;
            if (count == ordinal) return idx;
            count += 1;
        }
        return null;
    }

    pub fn handleRefreshTick(self: *App) !void {
        // While a foreground op runs the ticker fires fast to animate the
        // spinner; advance it and skip the (paused) background refresh.
        if (self.foregroundBusy()) {
            self.spinner_frame +%= 1;
            return;
        }
        if (self.mode != .normal) return;
        if (self.staging_active) return;
        if (!self.terminal_focused) return;
        // The actual git work runs off the loop; this only queues it.
        self.requestWorktreeRefresh();
    }

    pub fn handleFocusIn(self: *App) !void {
        self.terminal_focused = true;
        if (self.mode != .normal) return;
        // Don't run a heavy reload alongside an in-flight op; it refreshes on
        // completion anyway.
        if (self.foregroundBusy()) return;
        self.refresh() catch |err| {
            try self.setMessage("focus refresh failed: {s}", .{@errorName(err)});
        };
    }

    pub fn handleFocusOut(self: *App) void {
        self.terminal_focused = false;
    }

    pub fn selectedFile(self: *const App) ?model.FileStatus {
        if (self.data.files.len == 0) return null;
        if (self.tree_view) {
            const row = self.treeSelectedRow() orelse return null;
            if (row.is_dir) return null;
            return self.data.files[row.file_index];
        }
        const idx = @min(self.file_index, self.data.files.len - 1);
        if (self.fileMatchesFilter(self.data.files[idx])) return self.data.files[idx];
        if (self.firstMatchingFileIndex()) |first| return self.data.files[first];
        return null;
    }

    pub fn treeSelectedRow(self: *const App) ?filetree.Row {
        if (self.tree_rows.len == 0) return null;
        return self.tree_rows[@min(self.tree_cursor, self.tree_rows.len - 1)];
    }

    /// Capture the currently-selected tree row's path (owned) so the cursor can
    /// be restored after a rebuild that replaces the underlying file data.
    fn captureTreePath(self: *App) !?[]u8 {
        if (!self.tree_view) return null;
        const row = self.treeSelectedRow() orelse return null;
        return try self.allocator.dupe(u8, row.path);
    }

    fn treeEntryLessThan(_: void, a: filetree.Entry, b: filetree.Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }

    /// Rebuild the flattened tree rows from the filtered file list, restoring
    /// the cursor onto `restore_path` when possible.
    fn rebuildTree(self: *App, restore_path: ?[]const u8) !void {
        self.allocator.free(self.tree_rows);
        self.tree_rows = &.{};

        var entries: std.ArrayList(filetree.Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (self.data.files, 0..) |file, idx| {
            if (self.fileMatchesFilter(file)) try entries.append(self.allocator, .{ .path = file.path, .index = idx });
        }
        std.mem.sort(filetree.Entry, entries.items, {}, treeEntryLessThan);
        self.tree_rows = try filetree.build(self.allocator, entries.items, &self.collapsed_dirs);

        self.tree_cursor = 0;
        if (restore_path) |path| {
            for (self.tree_rows, 0..) |row, i| {
                if (std.mem.eql(u8, row.path, path)) {
                    self.tree_cursor = i;
                    break;
                }
            }
        }
        if (self.tree_rows.len > 0) self.tree_cursor = @min(self.tree_cursor, self.tree_rows.len - 1);
    }

    fn toggleTreeView(self: *App) !void {
        self.tree_view = !self.tree_view;
        if (self.tree_view) {
            const path = if (self.selectedFile()) |file| try self.allocator.dupe(u8, file.path) else null;
            defer if (path) |p| self.allocator.free(p);
            try self.rebuildTree(path);
            try self.setMessage("file tree", .{});
        } else {
            // Keep the flat selection on whatever file the tree cursor showed.
            if (self.treeSelectedRow()) |row| {
                if (!row.is_dir) self.file_index = row.file_index;
            }
            self.allocator.free(self.tree_rows);
            self.tree_rows = &.{};
            try self.setMessage("file list", .{});
        }
        self.main_scroll = 0;
        try self.updatePreview();
    }

    /// Toggle the collapsed state of the directory under the tree cursor.
    fn toggleTreeCollapse(self: *App) !void {
        const row = self.treeSelectedRow() orelse return;
        if (!row.is_dir) return;
        if (self.collapsed_dirs.contains(row.path)) {
            self.collapsed_dirs.remove(row.path);
        } else {
            try self.collapsed_dirs.insert(row.path);
        }
        const path = try self.allocator.dupe(u8, row.path);
        defer self.allocator.free(path);
        try self.rebuildTree(path);
        try self.updatePreview();
    }

    /// Stage (or unstage) every file under the directory at the tree cursor,
    /// mirroring the whole-panel stage/unstage decision.
    fn toggleDirStaged(self: *App, dir: []const u8) !void {
        var any_unstaged = false;
        var any_staged = false;
        for (self.data.files) |file| {
            if (!self.fileMatchesFilter(file)) continue;
            if (!filetree.underDir(file.path, dir)) continue;
            if (file.conflict) continue; // resolve conflicts individually
            if (file.has_unstaged) any_unstaged = true;
            if (file.has_staged) any_staged = true;
        }
        if (!any_unstaged and !any_staged) {
            try self.setMessage("no changes under {s}/", .{dir});
            return;
        }

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        const want_staged = any_unstaged; // stage if anything is unstaged, else unstage
        for (self.data.files) |file| {
            if (!self.fileMatchesFilter(file)) continue;
            if (!filetree.underDir(file.path, dir)) continue;
            if (file.conflict) continue;
            const include = if (want_staged) file.has_unstaged else file.has_staged;
            if (include) try paths.append(self.allocator, file.path);
        }
        if (want_staged) {
            return self.runMutationFiles(try self.git.stagePaths(paths.items), "staged {s}/", .{dir});
        }
        return self.runMutationFiles(try self.git.unstagePaths(paths.items), "unstaged {s}/", .{dir});
    }

    pub fn fileFilterActive(self: *const App) bool {
        return self.file_filter.len > 0;
    }

    pub fn fileDisplayFilterActive(self: *const App) bool {
        return self.file_display_filter != .all;
    }

    pub fn anyFileFilterActive(self: *const App) bool {
        return self.fileFilterActive() or self.fileDisplayFilterActive();
    }

    pub fn fileMatchesFilter(self: *const App, file: model.FileStatus) bool {
        if (!self.file_display_filter.matches(file)) return false;
        if (self.file_filter.len == 0) return true;
        if (textmatch.pathMatchesFilter(file.path, self.file_filter)) return true;
        if (file.previous_path) |previous| {
            return textmatch.pathMatchesFilter(previous, self.file_filter);
        }
        return false;
    }

    pub fn visibleFileCount(self: *const App) usize {
        var count: usize = 0;
        for (self.data.files) |file| {
            if (self.fileMatchesFilter(file)) count += 1;
        }
        return count;
    }

    pub fn selectedFileVisibleOrdinal(self: *const App) usize {
        if (self.data.files.len == 0) return 0;
        var ordinal: usize = 0;
        const selected_idx = @min(self.file_index, self.data.files.len - 1);
        for (self.data.files, 0..) |file, idx| {
            if (!self.fileMatchesFilter(file)) continue;
            if (idx == selected_idx) return ordinal;
            ordinal += 1;
        }
        return 0;
    }

    pub fn selectedBranch(self: *const App) ?model.Branch {
        if (self.data.branches.len == 0) return null;
        return self.data.branches[@min(self.branch_index, self.data.branches.len - 1)];
    }

    pub fn selectedRemoteBranch(self: *const App) ?model.Branch {
        if (self.data.remote_branches.len == 0) return null;
        return self.data.remote_branches[@min(self.remote_index, self.data.remote_branches.len - 1)];
    }

    pub fn selectedTag(self: *const App) ?model.Tag {
        if (self.data.tags.len == 0) return null;
        return self.data.tags[@min(self.tag_index, self.data.tags.len - 1)];
    }

    pub fn selectedWorktree(self: *const App) ?model.Worktree {
        if (self.data.worktrees.len == 0) return null;
        return self.data.worktrees[@min(self.worktree_index, self.data.worktrees.len - 1)];
    }

    pub fn selectedSubmodule(self: *const App) ?model.Submodule {
        if (self.data.submodules.len == 0) return null;
        return self.data.submodules[@min(self.submodule_index, self.data.submodules.len - 1)];
    }

    /// The ref name selected in the Branches panel, whichever tab is active.
    /// Used to drive the main-panel preview. Null for the Worktrees tab, which
    /// has no ref to show.
    pub fn selectedBranchRefName(self: *const App) ?[]const u8 {
        return switch (self.branches_tab) {
            .local => if (self.selectedBranch()) |branch| branch.name else null,
            .remotes => if (self.selectedRemoteBranch()) |branch| branch.name else null,
            .tags => if (self.selectedTag()) |tag| tag.name else null,
            .worktrees, .submodules => null,
        };
    }

    /// A short label for the active Commits-list filter, into `buf`, or null
    /// when no filter is set. Drives the Commits panel title.
    pub fn commitFilterLabel(self: *const App, buf: []u8) ?[]const u8 {
        if (self.git.log_author) |a| return std.fmt.bufPrint(buf, "author:{s}", .{a}) catch "filtered";
        if (self.git.log_grep) |g| return std.fmt.bufPrint(buf, "/{s}", .{g}) catch "filtered";
        if (self.git.log_path) |p| return std.fmt.bufPrint(buf, "path:{s}", .{p}) catch "filtered";
        return null;
    }

    /// The commit list backing the Commits panel for the active tab.
    pub fn activeCommits(self: *const App) []model.Commit {
        return switch (self.commits_tab) {
            .commits => self.data.commits,
            .reflog => self.data.reflog,
        };
    }

    pub fn activeCommitIndex(self: *const App) usize {
        return switch (self.commits_tab) {
            .commits => self.commit_index,
            .reflog => self.reflog_index,
        };
    }

    pub fn selectedCommit(self: *const App) ?model.Commit {
        const list = self.activeCommits();
        if (list.len == 0) return null;
        return list[@min(self.activeCommitIndex(), list.len - 1)];
    }

    pub fn selectedCommitFile(self: *const App) ?model.CommitFile {
        if (self.commit_files.len == 0) return null;
        return self.commit_files[@min(self.commit_file_index, self.commit_files.len - 1)];
    }

    pub fn patchHasFile(self: *const App, path: []const u8) bool {
        for (self.patch_paths.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    pub fn patchFileCount(self: *const App) usize {
        return self.patch_paths.items.len;
    }

    fn clearPatch(self: *App) void {
        if (self.patch_source) |s| self.allocator.free(s);
        self.patch_source = null;
        for (self.patch_paths.items) |p| self.allocator.free(p);
        self.patch_paths.clearRetainingCapacity();
    }

    /// Toggle the selected commit file into the custom patch. A patch is tied
    /// to one source commit; adding a file from a different commit is refused
    /// until the patch is reset.
    fn toggleFileInPatch(self: *App) !void {
        if (!self.commit_files_active) {
            try self.setMessage("open a commit's files (enter) to build a patch", .{});
            return;
        }
        const commit = self.selectedCommit() orelse return;
        const file = self.selectedCommitFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        if (self.patch_source) |source| {
            if (!std.mem.eql(u8, source, commit.hash)) {
                try self.setMessage("patch is from another commit - reset it first (ctrl+p)", .{});
                return;
            }
        } else {
            self.patch_source = try self.allocator.dupe(u8, commit.hash);
        }
        for (self.patch_paths.items, 0..) |p, idx| {
            if (std.mem.eql(u8, p, file.path)) {
                self.allocator.free(self.patch_paths.orderedRemove(idx));
                if (self.patch_paths.items.len == 0) self.clearPatch();
                try self.setMessage("removed {s} from patch ({d} files)", .{ file.path, self.patch_paths.items.len });
                return;
            }
        }
        try self.patch_paths.append(self.allocator, try self.allocator.dupe(u8, file.path));
        try self.setMessage("added {s} to patch ({d} files)", .{ file.path, self.patch_paths.items.len });
    }

    /// Concatenate the source commit's per-file diffs into one applyable patch.
    fn buildPatchBytes(self: *App) ![]u8 {
        const source = self.patch_source orelse return error.NoPatch;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (self.patch_paths.items) |path| {
            const diff = try self.git.diffForCommitFile(source, path, self.config.diff_context);
            defer self.allocator.free(diff);
            try out.appendSlice(self.allocator, diff);
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// <enter> behaviour per panel: on the Commits tab it drills into the
    /// commit's file list; on the Files panel it opens the hunk-staging view;
    /// elsewhere it descends into the main panel to scroll.
    fn descendOrOpenCommitFiles(self: *App) !void {
        if (self.focus == .commits and self.commits_tab == .commits and !self.commit_files_active) {
            return self.openCommitFiles();
        }
        if (self.focus == .files) {
            // In tree view, <enter> on a directory collapses/expands it.
            if (self.tree_view) {
                if (self.treeSelectedRow()) |row| {
                    if (row.is_dir) return self.toggleTreeCollapse();
                }
            }
            return self.openStaging();
        }
        return self.enterMain();
    }

    fn openStaging(self: *App) !void {
        const file = self.selectedFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        if (!file.tracked and !file.has_staged) {
            try self.setMessage("stage untracked files with space in the Files panel", .{});
            return;
        }
        const path = try self.allocator.dupe(u8, file.path);
        self.clearStaging();
        self.staging_path = path;
        self.staging_staged_view = false;
        self.main_origin = .files;
        self.focus = .main;
        self.staging_active = true;
        try self.loadStaging(false);
        try self.setMessage("staging {s}", .{file.path});
    }

    /// Reload the staging diff for the current side. `keep_cursor` preserves the
    /// cursor position (clamped) instead of resetting to the first change — used
    /// after staging/unstaging a line so the cursor stays put and repeated space
    /// keeps applying the lines that shift up into it.
    fn loadStaging(self: *App, keep_cursor: bool) !void {
        if (self.staging) |*parsed| parsed.deinit(self.allocator);
        self.staging = null;
        self.allocator.free(self.staging_diff);
        self.staging_diff = &.{};

        self.staging_diff = self.git.rawFileDiff(self.staging_path, self.staging_staged_view, self.config.diff_context) catch
            try self.allocator.dupe(u8, "");
        self.staging = try diff_mod.parse(self.allocator, self.staging_diff);
        self.staging_anchor = null;
        if (keep_cursor) {
            self.staging_cursor = @min(@max(self.staging_cursor, self.stagingFirstLine()), self.stagingLastLine());
        } else {
            self.staging_cursor = self.stagingFirstLine();
        }
        self.scrollToStagingCursor();
    }

    fn toggleStagingSide(self: *App) !void {
        self.staging_staged_view = !self.staging_staged_view;
        try self.loadStaging(false);
        try self.setMessage("{s} changes", .{if (self.staging_staged_view) "staged" else "unstaged"});
    }

    fn toggleStagingRange(self: *App) void {
        self.staging_anchor = if (self.staging_anchor == null) self.staging_cursor else null;
    }

    /// Line index of the first selectable line (the first hunk's `@@` line).
    fn stagingFirstLine(self: *const App) usize {
        const parsed = self.staging orelse return 0;
        if (parsed.hunks.len == 0) return 0;
        return parsed.hunks[0].start_line;
    }

    fn stagingLastLine(self: *const App) usize {
        const lines = std.mem.count(u8, self.staging_diff, "\n");
        if (lines == 0) return self.stagingFirstLine();
        return lines - 1;
    }

    fn moveStagingCursor(self: *App, delta: i8) void {
        const first = self.stagingFirstLine();
        const last = self.stagingLastLine();
        if (delta < 0) {
            if (self.staging_cursor > first) self.staging_cursor -= 1;
        } else if (self.staging_cursor < last) {
            self.staging_cursor += 1;
        }
        self.scrollToStagingCursor();
    }

    fn scrollToStagingCursor(self: *App) void {
        const height: usize = if (self.main_view_height == 0) 20 else self.main_view_height;
        if (self.staging_cursor < self.main_scroll) {
            self.main_scroll = self.staging_cursor;
        } else if (self.staging_cursor >= self.main_scroll + height) {
            self.main_scroll = self.staging_cursor + 1 - height;
        }
    }

    /// The hunk index whose body or header line contains `abs`, or null.
    fn stagingHunkAt(self: *const App, abs: usize) ?usize {
        const parsed = self.staging orelse return null;
        for (parsed.hunks, 0..) |hunk, idx| {
            if (abs >= hunk.start_line and abs < hunk.end_line) return idx;
        }
        return null;
    }

    fn applyStagingSelection(self: *App) !void {
        const parsed = self.staging orelse return;
        if (parsed.hunks.len == 0) {
            try self.setMessage("no changes to stage", .{});
            return;
        }
        const hunk_index = self.stagingHunkAt(self.staging_cursor) orelse {
            try self.setMessage("move the cursor onto a change", .{});
            return;
        };
        const hunk = parsed.hunks[hunk_index];

        // On the `@@` header line, stage the whole hunk; otherwise the lines.
        const patch = if (self.staging_cursor == hunk.start_line)
            try diff_mod.buildHunkPatch(self.allocator, self.staging_diff, parsed, hunk_index)
        else blk: {
            const lo_abs = @min(self.staging_anchor orelse self.staging_cursor, self.staging_cursor);
            const hi_abs = @max(self.staging_anchor orelse self.staging_cursor, self.staging_cursor);
            const body_first = hunk.start_line + 1;
            const lo = (@max(lo_abs, body_first)) - body_first;
            const hi = (@min(hi_abs, hunk.end_line - 1)) - body_first;
            break :blk diff_mod.buildLinePatch(self.allocator, self.staging_diff, parsed, hunk_index, lo, hi, self.staging_staged_view) catch |err| switch (err) {
                error.EmptySelection => {
                    try self.setMessage("selection contains no change", .{});
                    return;
                },
                error.NoNewlineHunk => {
                    try self.setMessage("stage the whole hunk for no-newline changes (enter on @@)", .{});
                    return;
                },
                error.InvalidHunk => {
                    try self.setMessage("could not build patch for this hunk", .{});
                    return;
                },
                else => return err,
            };
        };
        defer self.allocator.free(patch);

        var result = try self.git.applyPatch(patch, self.staging_staged_view);
        defer result.deinit(self.allocator);
        if (!result.ok()) {
            const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
            try self.setMessage("apply failed: {s}", .{if (stderr.len > 0) stderr else "git apply error"});
            return;
        }
        const verb = if (self.staging_staged_view) "unstaged" else "staged";
        const scope = if (self.staging_cursor == hunk.start_line) "hunk" else "selection";
        try self.setMessage("{s} {s}", .{ verb, scope });
        self.staging_anchor = null;
        // Staging a line only touches the index — scoped (fast) reload. Keep
        // the cursor where it is so repeated space keeps staging the lines that
        // shift up into its position.
        self.refreshScope(.files);
        try self.loadStaging(true);
    }

    fn closeStaging(self: *App) !void {
        self.clearStaging();
        self.focus = .files;
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn clearStaging(self: *App) void {
        if (self.staging) |*parsed| parsed.deinit(self.allocator);
        self.staging = null;
        self.allocator.free(self.staging_diff);
        self.staging_diff = &.{};
        self.allocator.free(self.staging_path);
        self.staging_path = &.{};
        self.staging_active = false;
        self.staging_staged_view = false;
        self.staging_cursor = 0;
        self.staging_anchor = null;
    }

    fn openCommitFiles(self: *App) !void {
        const commit = self.selectedCommit() orelse {
            try self.setMessage("no commit selected", .{});
            return;
        };
        const files = try self.git.loadCommitFiles(commit.hash);
        model.deinitCommitFiles(self.allocator, self.commit_files);
        self.commit_files = files;
        self.commit_file_index = 0;
        self.commit_files_active = true;
        self.main_scroll = 0;
        try self.updatePreview();
        try self.setMessage("{d} files in {s}", .{ files.len, commit.short_hash });
    }

    fn closeCommitFiles(self: *App) !void {
        self.deactivateCommitFiles();
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn deactivateCommitFiles(self: *App) void {
        model.deinitCommitFiles(self.allocator, self.commit_files);
        self.commit_files = &.{};
        self.commit_file_index = 0;
        self.commit_files_active = false;
    }

    /// Keep the drilled-in commit file list consistent after a full refresh
    /// (e.g. focus regain or a mutation); drop out if the commit is gone.
    fn reloadCommitFilesAfterRefresh(self: *App) void {
        const commit = self.selectedCommit() orelse return self.deactivateCommitFiles();
        const files = self.git.loadCommitFiles(commit.hash) catch return self.deactivateCommitFiles();
        model.deinitCommitFiles(self.allocator, self.commit_files);
        self.commit_files = files;
        if (self.commit_files.len == 0) {
            self.commit_file_index = 0;
        } else {
            self.commit_file_index = @min(self.commit_file_index, self.commit_files.len - 1);
        }
    }

    const TabDirection = enum { prev, next };

    fn cycleTab(self: *App, direction: TabDirection) !void {
        switch (self.focus) {
            .branches => {
                self.branches_tab = switch (direction) {
                    .next => switch (self.branches_tab) {
                        .local => .remotes,
                        .remotes => .tags,
                        .tags => .worktrees,
                        .worktrees => .submodules,
                        .submodules => .local,
                    },
                    .prev => switch (self.branches_tab) {
                        .local => .submodules,
                        .remotes => .local,
                        .tags => .remotes,
                        .worktrees => .tags,
                        .submodules => .worktrees,
                    },
                };
                self.main_scroll = 0;
                try self.updatePreview();
                try self.setMessage("{s}", .{self.branches_tab.label()});
            },
            .commits => {
                if (self.commit_files_active) self.deactivateCommitFiles();
                // Only two tabs, so prev and next are equivalent here.
                self.commits_tab = switch (self.commits_tab) {
                    .commits => .reflog,
                    .reflog => .commits,
                };
                self.main_scroll = 0;
                try self.updatePreview();
                try self.setMessage("{s}", .{self.commits_tab.label()});
            },
            else => {},
        }
    }

    pub fn selectedStash(self: *const App) ?model.StashEntry {
        if (self.data.stash.len == 0) return null;
        return self.data.stash[@min(self.stash_index, self.data.stash.len - 1)];
    }

    pub fn confirmationText(self: *const App, buf: []u8) []const u8 {
        return switch (self.pending_confirmation orelse return "No pending action.") {
            .discard_all => "Discard all working tree changes? This cannot be undone.",
            .merge_branch => blk: {
                if (self.selectedBranch()) |branch| {
                    break :blk std.fmt.bufPrint(buf, "Merge {s} into {s}?", .{ branch.name, self.data.current_branch }) catch "Merge the selected branch into the current one?";
                }
                break :blk "Merge the selected branch into the current one?";
            },
            .rebase_branch => blk: {
                if (self.selectedBranch()) |branch| {
                    break :blk std.fmt.bufPrint(buf, "Rebase {s} onto {s}?", .{ self.data.current_branch, branch.name }) catch "Rebase the current branch onto the selected one?";
                }
                break :blk "Rebase the current branch onto the selected one?";
            },
            .delete_tag => blk: {
                if (self.selectedTag()) |tag| {
                    break :blk std.fmt.bufPrint(buf, "Delete tag {s}?", .{tag.name}) catch "Delete the selected tag?";
                }
                break :blk "Delete the selected tag?";
            },
            .delete_remote_branch => blk: {
                if (self.selectedRemoteBranch()) |branch| {
                    break :blk std.fmt.bufPrint(buf, "Delete remote branch {s}? This pushes a deletion.", .{branch.name}) catch "Delete the selected remote branch?";
                }
                break :blk "Delete the selected remote branch?";
            },
            .remove_worktree => blk: {
                if (self.selectedWorktree()) |wt| {
                    break :blk std.fmt.bufPrint(buf, "Remove worktree {s}?", .{wt.path}) catch "Remove the selected worktree?";
                }
                break :blk "Remove the selected worktree?";
            },
            .remove_remote => blk: {
                if (self.remote_name_len > 0) {
                    break :blk std.fmt.bufPrint(buf, "Remove remote {s}? Local tracking refs are deleted.", .{self.remote_name_buf[0..self.remote_name_len]}) catch "Remove the selected remote?";
                }
                break :blk "Remove the selected remote?";
            },
            .undo => blk: {
                if (self.undo_label_len > 0) {
                    break :blk std.fmt.bufPrint(buf, "Undo \"{s}\"? Resets HEAD to before it.", .{self.undo_label_buf[0..self.undo_label_len]}) catch "Undo the last operation?";
                }
                break :blk "Undo the last operation? Resets HEAD.";
            },
        };
    }

    fn setFocus(self: *App, focus: model.Focus) !void {
        if (self.commit_files_active) self.deactivateCommitFiles();
        if (self.staging_active) self.clearStaging();
        self.focus = focus;
        self.main_scroll = 0;
        try self.updatePreview();
    }

    /// Descend into the main panel to inspect the selected item, remembering
    /// the side panel we came from so <esc>/<h> can return there.
    fn enterMain(self: *App) !void {
        if (self.focus.isSidePanel()) self.main_origin = self.focus;
        self.focus = .main;
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn leaveMain(self: *App) !void {
        self.focus = self.main_origin;
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn focusNext(self: *App) !void {
        if (self.focus == .main) return self.leaveMain();
        if (self.commit_files_active) self.deactivateCommitFiles();
        self.focus = switch (self.focus) {
            .status => .files,
            .files => .branches,
            .branches => .commits,
            .commits => .stash,
            .stash => .status,
            .main => unreachable,
        };
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn focusPrevious(self: *App) !void {
        if (self.focus == .main) return self.leaveMain();
        if (self.commit_files_active) self.deactivateCommitFiles();
        self.focus = switch (self.focus) {
            .status => .stash,
            .files => .status,
            .branches => .files,
            .commits => .branches,
            .stash => .commits,
            .main => unreachable,
        };
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn moveUp(self: *App) !void {
        switch (self.focus) {
            .status => return,
            .files => if (self.tree_view) self.moveTreeCursor(-1) else self.moveFileUp(),
            .branches => switch (self.branches_tab) {
                .local => self.branch_index -|= 1,
                .remotes => self.remote_index -|= 1,
                .tags => self.tag_index -|= 1,
                .worktrees => self.worktree_index -|= 1,
                .submodules => self.submodule_index -|= 1,
            },
            .commits => {
                if (self.commit_files_active) {
                    self.commit_file_index -|= 1;
                } else switch (self.commits_tab) {
                    .commits => self.commit_index -|= 1,
                    .reflog => self.reflog_index -|= 1,
                }
            },
            .stash => self.stash_index -|= 1,
            .main => return self.scrollMain(-1),
        }
        try self.updatePreview();
    }

    fn moveDown(self: *App) !void {
        switch (self.focus) {
            .status => return,
            .files => if (self.tree_view) self.moveTreeCursor(1) else self.moveFileDown(),
            .branches => switch (self.branches_tab) {
                .local => if (self.branch_index + 1 < self.data.branches.len) {
                    self.branch_index += 1;
                },
                .remotes => if (self.remote_index + 1 < self.data.remote_branches.len) {
                    self.remote_index += 1;
                },
                .tags => if (self.tag_index + 1 < self.data.tags.len) {
                    self.tag_index += 1;
                },
                .worktrees => if (self.worktree_index + 1 < self.data.worktrees.len) {
                    self.worktree_index += 1;
                },
                .submodules => if (self.submodule_index + 1 < self.data.submodules.len) {
                    self.submodule_index += 1;
                },
            },
            .commits => {
                if (self.commit_files_active) {
                    if (self.commit_file_index + 1 < self.commit_files.len) self.commit_file_index += 1;
                } else switch (self.commits_tab) {
                    .commits => if (self.commit_index + 1 < self.data.commits.len) {
                        self.commit_index += 1;
                    },
                    .reflog => if (self.reflog_index + 1 < self.data.reflog.len) {
                        self.reflog_index += 1;
                    },
                }
            },
            .stash => {
                if (self.stash_index + 1 < self.data.stash.len) self.stash_index += 1;
            },
            .main => return self.scrollMain(1),
        }
        try self.updatePreview();
    }

    fn scrollMain(self: *App, amount: isize) !void {
        if (amount < 0) {
            self.main_scroll -|= @intCast(-amount);
        } else {
            self.main_scroll += @intCast(amount);
        }
    }

    /// Space in the Files panel: stage/unstage a whole directory in tree view
    /// when the cursor is on one, otherwise the selected file.
    fn toggleSelectedFileStaged(self: *App) !void {
        if (self.tree_view) {
            if (self.treeSelectedRow()) |row| {
                if (row.is_dir) return self.toggleDirStaged(row.path);
            }
        }
        return self.toggleFileStaged();
    }

    fn toggleFileStaged(self: *App) !void {
        const file = self.selectedFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        if (file.conflict) return self.startConflictResolveMenu();
        if (file.has_unstaged) {
            return self.runMutationFiles(try self.git.stageFile(file.path), "staged {s}", .{file.path});
        }
        if (file.has_staged) {
            return self.runMutationFiles(try self.git.unstageFile(file), "unstaged {s}", .{file.path});
        }
        try self.setMessage("file has no staged or unstaged changes", .{});
    }

    fn toggleAllStaged(self: *App) !void {
        if (self.visibleUnstagedCount() > 0) {
            if (self.anyFileFilterActive()) {
                var paths: std.ArrayList([]const u8) = .empty;
                defer paths.deinit(self.allocator);
                try self.collectVisiblePaths(&paths, .unstaged);
                return self.runMutationFiles(try self.git.stagePaths(paths.items), "staged visible files", .{});
            }
            return self.runMutationFiles(try self.git.stageAll(), "staged all files", .{});
        }
        if (self.visibleStagedCount() > 0) {
            if (self.anyFileFilterActive()) {
                var paths: std.ArrayList([]const u8) = .empty;
                defer paths.deinit(self.allocator);
                try self.collectVisiblePaths(&paths, .staged);
                return self.runMutationFiles(try self.git.unstagePaths(paths.items), "unstaged visible files", .{});
            }
            return self.runMutationFiles(try self.git.unstageAll(), "unstaged all files", .{});
        }
        try self.setMessage("no visible files to stage", .{});
    }

    fn startCommitPrompt(self: *App) !void {
        if (self.data.stagedCount() == 0) {
            try self.setMessage("stage files before committing", .{});
            return;
        }
        self.mode = .commit_prompt;
        self.commit_action = .create;
        self.commit_field = .subject;
        self.commit_buffer.clearRetainingCapacity();
        self.commit_body_buffer.clearRetainingCapacity();
        try self.setMessage("enter commit message", .{});
    }

    /// Open the commit editor pre-filled with a commit's subject/body to reword
    /// it (runs an interactive rebase on submit).
    fn startReword(self: *App) !void {
        if (self.commits_tab != .commits) {
            try self.setMessage("reword applies to the Commits tab", .{});
            return;
        }
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }
        if (self.data.commits.len == 0) {
            try self.setMessage("no commit selected", .{});
            return;
        }
        const i = @min(self.commit_index, self.data.commits.len - 1);
        const commit = self.data.commits[i];
        const body = self.git.commitBody(commit.hash) catch try self.allocator.alloc(u8, 0);
        defer self.allocator.free(body);

        self.mode = .commit_prompt;
        self.commit_action = .reword;
        self.commit_reword_index = i;
        self.commit_field = .subject;
        self.commit_buffer.clearRetainingCapacity();
        try self.commit_buffer.appendSlice(self.allocator, commit.subject);
        self.commit_body_buffer.clearRetainingCapacity();
        try self.commit_body_buffer.appendSlice(self.allocator, body);
        try self.setMessage("reword commit", .{});
    }

    fn amendLastCommit(self: *App) !void {
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }
        if (self.data.stagedCount() == 0) {
            try self.setMessage("stage changes to amend into the last commit", .{});
            return;
        }
        return self.runMutation(try self.git.amendCommit(), "amended last commit", .{});
    }

    pub fn isCommitCopied(self: *const App, hash: []const u8) bool {
        for (self.copied_commits.items) |h| {
            if (std.mem.eql(u8, h, hash)) return true;
        }
        return false;
    }

    /// Queue the focused item's identifier for the system clipboard: a commit
    /// hash, branch/tag/remote ref, or stash selector, depending on the panel.
    /// The TUI loop performs the OSC 52 copy.
    fn requestClipboardCopy(self: *App) !void {
        const text: []const u8 = switch (self.focus) {
            .commits => if (self.selectedCommit()) |commit| commit.hash else "",
            .branches => self.selectedBranchRefName() orelse "",
            .stash => if (self.selectedStash()) |entry| entry.selector else "",
            .status, .files, .main => "",
        };
        if (text.len == 0) {
            try self.setMessage("nothing to copy here", .{});
            return;
        }
        if (self.clipboard_request) |old| self.allocator.free(old);
        self.clipboard_request = try self.allocator.dupe(u8, text);
        try self.setMessage("copied to clipboard: {s}", .{text});
    }

    /// The ref the focused panel contributes to a diff: a commit hash in the
    /// Commits panel or a branch/tag ref in the Branches panel; null otherwise.
    fn selectedRefForDiff(self: *const App) ?[]const u8 {
        return switch (self.contentFocus()) {
            .commits => if (self.selectedCommit()) |commit| commit.hash else null,
            .branches => self.selectedBranchRefName(),
            .status, .files, .stash, .main => null,
        };
    }

    fn clearDiffBase(self: *App) void {
        if (self.diff_base) |b| self.allocator.free(b);
        self.diff_base = null;
    }

    /// Mark the focused ref as the diff base (entering diffing mode); pressing
    /// it again on that same ref exits. While active, the main panel shows the
    /// diff from the base to whatever ref is selected. Esc also exits.
    fn toggleDiffMark(self: *App) !void {
        const ref = self.selectedRefForDiff() orelse {
            try self.setMessage("select a commit or branch to diff", .{});
            return;
        };
        if (self.diff_base) |base| {
            if (std.mem.eql(u8, base, ref)) {
                self.clearDiffBase();
                try self.setMessage("exited diffing mode", .{});
                try self.updatePreview();
                return;
            }
        }
        self.clearDiffBase();
        self.diff_base = try self.allocator.dupe(u8, ref);
        try self.setMessage("diffing from {s} - select another ref (esc to exit)", .{ref});
        try self.updatePreview();
    }

    /// Open the focused commit or branch on its remote's web host. Derives an
    /// https URL from the remote's fetch URL and launches the OS browser.
    fn openSelectionInBrowser(self: *App) !void {
        const remote = self.currentRemoteName();
        const raw = self.git.remoteUrl(remote) catch {
            try self.setMessage("no '{s}' remote to open", .{remote});
            return;
        };
        defer self.allocator.free(raw);
        const base = (try webUrlFromRemote(self.allocator, std.mem.trim(u8, raw, " \t\r\n"))) orelse {
            try self.setMessage("cannot derive a web URL from {s}", .{std.mem.trim(u8, raw, " \t\r\n")});
            return;
        };
        defer self.allocator.free(base);

        const url = try self.selectionWebUrl(base);
        defer self.allocator.free(url);
        self.git.openUrl(url) catch {
            try self.setMessage("failed to launch the browser", .{});
            return;
        };
        try self.setMessage("opening {s}", .{url});
    }

    /// The remote whose web host we open: the current branch's upstream remote,
    /// falling back to "origin".
    fn currentRemoteName(self: *const App) []const u8 {
        if (self.data.upstream) |upstream| {
            if (std.mem.indexOfScalar(u8, upstream, '/')) |slash| return upstream[0..slash];
        }
        return "origin";
    }

    /// Append the path for the focused item to a repo web `base` URL.
    fn selectionWebUrl(self: *const App, base: []const u8) ![]u8 {
        switch (self.focus) {
            .commits => if (self.selectedCommit()) |commit| {
                return std.fmt.allocPrint(self.allocator, "{s}/commit/{s}", .{ base, commit.hash });
            },
            .branches => switch (self.branches_tab) {
                .local => if (self.selectedBranch()) |branch| {
                    return std.fmt.allocPrint(self.allocator, "{s}/tree/{s}", .{ base, branch.name });
                },
                .remotes => if (self.selectedRemoteBranch()) |branch| {
                    // Strip the "<remote>/" prefix so the tree path is the branch.
                    const name = if (std.mem.indexOfScalar(u8, branch.name, '/')) |slash|
                        branch.name[slash + 1 ..]
                    else
                        branch.name;
                    return std.fmt.allocPrint(self.allocator, "{s}/tree/{s}", .{ base, name });
                },
                .tags => if (self.selectedTag()) |tag| {
                    return std.fmt.allocPrint(self.allocator, "{s}/tree/{s}", .{ base, tag.name });
                },
                .worktrees, .submodules => {},
            },
            .status, .files, .stash, .main => {},
        }
        return self.allocator.dupe(u8, base);
    }

    /// Toggle the selected commit in the cherry-pick clipboard.
    fn toggleCommitCopy(self: *App) !void {
        const commit = self.selectedCommit() orelse {
            try self.setMessage("no commit selected", .{});
            return;
        };
        for (self.copied_commits.items, 0..) |h, idx| {
            if (std.mem.eql(u8, h, commit.hash)) {
                self.allocator.free(self.copied_commits.orderedRemove(idx));
                try self.setMessage("uncopied {s} ({d} copied)", .{ commit.short_hash, self.copied_commits.items.len });
                return;
            }
        }
        try self.copied_commits.append(self.allocator, try self.allocator.dupe(u8, commit.hash));
        try self.setMessage("copied {s} ({d} copied)", .{ commit.short_hash, self.copied_commits.items.len });
    }

    fn clearCopiedCommits(self: *App) void {
        for (self.copied_commits.items) |h| self.allocator.free(h);
        self.copied_commits.clearRetainingCapacity();
    }

    pub fn isMarkedBase(self: *const App, hash: []const u8) bool {
        const base = self.marked_base orelse return false;
        return std.mem.eql(u8, base, hash);
    }

    fn clearMarkedBase(self: *App) void {
        if (self.marked_base) |b| self.allocator.free(b);
        self.marked_base = null;
    }

    /// Toggle the selected commit as the base for a `rebase --onto`. With a base
    /// marked, rebasing onto a branch replays the marked commit (inclusive)
    /// through HEAD onto that branch — see `Git.rebaseOntoMarked`.
    fn toggleMarkBase(self: *App) !void {
        const commit = self.selectedCommit() orelse {
            try self.setMessage("no commit selected", .{});
            return;
        };
        if (self.isMarkedBase(commit.hash)) {
            self.clearMarkedBase();
            try self.setMessage("unmarked base {s}", .{commit.short_hash});
            return;
        }
        self.clearMarkedBase();
        self.marked_base = try self.allocator.dupe(u8, commit.hash);
        try self.setMessage("marked base {s} (rebase a branch to move commits)", .{commit.short_hash});
    }

    /// Cherry-pick all copied commits onto HEAD, oldest-first, then clear.
    fn pasteCopiedCommits(self: *App) !void {
        if (self.copied_commits.items.len == 0) {
            try self.setMessage("no commits copied (c to copy)", .{});
            return;
        }
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }

        // Order oldest-first: walk the commit list from the bottom, then append
        // any copied commits not present in it (e.g. reflog-only) in copy order.
        var ordered: std.ArrayList([]const u8) = .empty;
        defer ordered.deinit(self.allocator);
        var i = self.data.commits.len;
        while (i > 0) {
            i -= 1;
            const hash = self.data.commits[i].hash;
            if (self.isCommitCopied(hash)) try ordered.append(self.allocator, hash);
        }
        for (self.copied_commits.items) |h| {
            var present = false;
            for (ordered.items) |o| {
                if (std.mem.eql(u8, o, h)) {
                    present = true;
                    break;
                }
            }
            if (!present) try ordered.append(self.allocator, h);
        }

        const count = ordered.items.len;
        var run_buf: [48]u8 = undefined;
        const shown = std.fmt.bufPrint(&run_buf, "git cherry-pick ({d} commit(s))", .{count}) catch "git cherry-pick";
        try self.beginOp(shown);

        var result = try self.git.cherryPickMany(ordered.items);
        defer result.deinit(self.allocator);
        if (result.ok()) {
            self.clearCopiedCommits();
            const summary = try std.fmt.allocPrint(self.allocator, "cherry-picked {d} commit(s)", .{count});
            defer self.allocator.free(summary);
            try self.finishOp(true, summary, result.stdout);
        } else {
            try self.finishOp(false, "cherry-pick failed", if (result.stderr.len > 0) result.stderr else result.stdout);
        }
        self.refresh() catch {};
    }

    fn startTextPrompt(self: *App, kind: TextPromptKind) !void {
        var prefill: []const u8 = "";
        switch (kind) {
            .new_branch => {
                if (self.branches_tab != .local) self.branches_tab = .local;
                self.focus = .branches;
            },
            .rename_branch => {
                const branch = try self.localBranchForAction() orelse return;
                self.focus = .branches;
                prefill = branch.name;
            },
            .new_tag => {
                if (self.branches_tab != .tags) self.branches_tab = .tags;
                self.focus = .branches;
            },
            .add_remote_name, .add_remote_url, .edit_remote_url => {
                if (self.branches_tab != .remotes) self.branches_tab = .remotes;
                self.focus = .branches;
            },
            .commit_grep, .commit_author, .commit_path => self.focus = .commits,
        }
        self.mode = .text_prompt;
        self.text_prompt_kind = kind;
        self.input_buffer.clearRetainingCapacity();
        if (prefill.len > 0) try self.input_buffer.appendSlice(self.allocator, prefill);
        try self.setMessage("{s}", .{kind.title()});
    }

    fn handleTextPromptKey(self: *App, key: vaxis.Key) !void {
        if (self.isEscapeKey(key)) {
            self.cancelTextPrompt("cancelled");
            return;
        }
        if (self.isEnterKey(key)) {
            try self.submitTextPrompt();
            return;
        }
        if (self.isBackspaceKey(key)) {
            if (self.input_buffer.items.len > 0) self.input_buffer.items.len -= 1;
            return;
        }
        if (key.text) |text| {
            if (!key.mods.ctrl and !key.mods.alt and text.len > 0 and text[0] >= 0x20) {
                try self.input_buffer.appendSlice(self.allocator, text);
            }
        }
    }

    fn cancelTextPrompt(self: *App, comptime reason: []const u8) void {
        self.mode = .normal;
        self.text_prompt_kind = null;
        self.input_buffer.clearRetainingCapacity();
        self.setMessage(reason, .{}) catch {};
    }

    fn submitTextPrompt(self: *App) !void {
        const kind = self.text_prompt_kind orelse {
            self.mode = .normal;
            return;
        };
        const value = std.mem.trim(u8, self.input_buffer.items, " \t\r\n");

        // Commit filters accept an empty value (which clears that filter), so
        // they are handled before the non-empty guard below.
        switch (kind) {
            .commit_grep, .commit_author, .commit_path => {
                const which: git_mod.Git.LogFilter = switch (kind) {
                    .commit_grep => .grep,
                    .commit_author => .author,
                    .commit_path => .path,
                    else => unreachable,
                };
                self.mode = .normal;
                self.text_prompt_kind = null;
                self.input_buffer.clearRetainingCapacity();
                return self.applyCommitFilter(which, value);
            },
            else => {},
        }

        if (value.len == 0) {
            try self.setMessage("{s} cannot be empty", .{kind.title()});
            return;
        }
        switch (kind) {
            .new_branch => {
                const result = try self.git.createBranch(value);
                self.mode = .normal;
                self.text_prompt_kind = null;
                self.input_buffer.clearRetainingCapacity();
                return self.runMutation(result, "created branch {s}", .{value});
            },
            .rename_branch => {
                const branch = self.selectedBranch() orelse {
                    self.cancelTextPrompt("no branch selected");
                    return;
                };
                if (std.mem.eql(u8, branch.name, value)) {
                    self.cancelTextPrompt("branch name unchanged");
                    return;
                }
                const result = try self.git.renameBranch(branch.name, value);
                self.mode = .normal;
                self.text_prompt_kind = null;
                self.input_buffer.clearRetainingCapacity();
                return self.runMutation(result, "renamed to {s}", .{value});
            },
            .new_tag => {
                const result = try self.git.createTag(value);
                self.mode = .normal;
                self.text_prompt_kind = null;
                self.input_buffer.clearRetainingCapacity();
                return self.runMutation(result, "created tag {s}", .{value});
            },
            .add_remote_name => {
                // Stash the name and ask for the URL in a second prompt.
                const n = @min(value.len, self.remote_name_buf.len);
                @memcpy(self.remote_name_buf[0..n], value[0..n]);
                self.remote_name_len = n;
                self.text_prompt_kind = .add_remote_url;
                self.input_buffer.clearRetainingCapacity();
                try self.setMessage("URL for remote {s}", .{self.remote_name_buf[0..n]});
                return;
            },
            .add_remote_url => {
                const name = self.remote_name_buf[0..self.remote_name_len];
                const result = try self.git.addRemote(name, value);
                self.mode = .normal;
                self.text_prompt_kind = null;
                self.input_buffer.clearRetainingCapacity();
                return self.runMutation(result, "added remote {s}", .{name});
            },
            .edit_remote_url => {
                const name = self.remote_name_buf[0..self.remote_name_len];
                const result = try self.git.setRemoteUrl(name, value);
                self.mode = .normal;
                self.text_prompt_kind = null;
                self.input_buffer.clearRetainingCapacity();
                return self.runMutation(result, "set URL for {s}", .{name});
            },
            // Handled before the non-empty guard above.
            .commit_grep, .commit_author, .commit_path => unreachable,
        }
    }

    fn startFileFilterPrompt(self: *App) !void {
        self.focus = .files;
        self.main_scroll = 0;
        self.mode = .file_filter_prompt;
        self.file_filter_buffer.clearRetainingCapacity();
        self.filter_history_index = null;
        try self.updateFileFilterFromPrompt();
        try self.setMessage("filter files (up/down for history)", .{});
    }

    /// Replace the filter prompt buffer with a value (used for history recall).
    fn setFilterPromptBuffer(self: *App, value: []const u8) !void {
        self.file_filter_buffer.clearRetainingCapacity();
        try self.file_filter_buffer.appendSlice(self.allocator, value);
        try self.updateFileFilterFromPrompt();
    }

    /// Recall an older (-1) or newer (+1) entry from the filter history.
    fn recallFilterHistory(self: *App, direction: i8) !void {
        const history = self.filter_history.items;
        if (history.len == 0) return;
        if (direction < 0) {
            const next = if (self.filter_history_index) |idx|
                (if (idx == 0) 0 else idx - 1)
            else
                history.len - 1;
            self.filter_history_index = next;
            try self.setFilterPromptBuffer(history[next]);
        } else {
            if (self.filter_history_index) |idx| {
                if (idx + 1 < history.len) {
                    self.filter_history_index = idx + 1;
                    try self.setFilterPromptBuffer(history[idx + 1]);
                } else {
                    self.filter_history_index = null;
                    try self.setFilterPromptBuffer("");
                }
            }
        }
    }

    fn pushFilterHistory(self: *App, filter: []const u8) !void {
        if (filter.len == 0) return;
        if (self.filter_history.items.len > 0) {
            const last = self.filter_history.items[self.filter_history.items.len - 1];
            if (std.mem.eql(u8, last, filter)) return;
        }
        const entry = try self.allocator.dupe(u8, filter);
        if (self.filter_history.items.len >= 20) {
            self.allocator.free(self.filter_history.orderedRemove(0));
        }
        self.filter_history.append(self.allocator, entry) catch self.allocator.free(entry);
    }

    fn startStatusFilterMenu(self: *App) !void {
        self.focus = .files;
        self.mode = .status_filter_menu;
        self.status_filter_index = 0;
        for (status_filter_options, 0..) |option, idx| {
            if (option == self.file_display_filter) self.status_filter_index = idx;
        }
        try self.setMessage("status filter", .{});
    }

    fn startDiscardMenu(self: *App) !void {
        const file = self.selectedFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        const items: []const MenuItem = if (file.has_staged and file.has_unstaged)
            &discard_menu_staged_and_unstaged
        else
            &discard_menu_all_only;
        self.mode = .menu;
        self.active_menu = .{ .title = "Discard changes", .items = items, .index = 0 };
        try self.setMessage("discard changes", .{});
    }

    fn startStashMenu(self: *App) !void {
        if (self.data.files.len == 0) {
            try self.setMessage("nothing to stash", .{});
            return;
        }
        self.focus = .files;
        self.mode = .menu;
        self.active_menu = .{ .title = "Stash", .items = &stash_menu, .index = 0 };
        try self.setMessage("stash changes", .{});
    }

    fn startPatchMenu(self: *App) !void {
        if (self.patchFileCount() == 0) {
            try self.setMessage("no patch - open a commit (enter), then space to add files", .{});
            return;
        }
        self.mode = .menu;
        self.active_menu = .{ .title = "Custom patch", .items = &patch_menu_items, .index = 0 };
        try self.setMessage("custom patch ({d} files)", .{self.patchFileCount()});
    }

    fn startBisectMenu(self: *App) !void {
        self.focus = .commits;
        self.commits_tab = .commits;
        const items: []const MenuItem = if (self.data.bisecting)
            &bisect_actions_menu
        else
            &bisect_start_menu;
        const title = if (self.data.bisecting) "Bisect in progress" else "Start bisect";
        self.mode = .menu;
        self.active_menu = .{ .title = title, .items = items, .index = 0 };
        try self.setMessage("bisect", .{});
    }

    fn startCommitFilterMenu(self: *App) !void {
        self.focus = .commits;
        self.commits_tab = .commits;
        self.mode = .menu;
        self.active_menu = .{ .title = "Filter commits", .items = &commit_filter_menu, .index = 0 };
        try self.setMessage("filter commits", .{});
    }

    /// Apply a Commits-list filter and reload. An empty value clears just that
    /// filter. Selection resets to the top since the list changes.
    fn applyCommitFilter(self: *App, which: git_mod.Git.LogFilter, value: []const u8) !void {
        try self.git.setLogFilter(which, value);
        self.commit_index = 0;
        try self.refresh();
        if (value.len == 0) {
            try self.setMessage("commit filter cleared", .{});
        } else {
            try self.setMessage("filtered commits ({d} shown)", .{self.data.commits.len});
        }
    }

    fn clearCommitFilter(self: *App) !void {
        self.git.clearLogFilters();
        self.commit_index = 0;
        try self.refresh();
        try self.setMessage("commit filter cleared", .{});
    }

    fn startConflictResolveMenu(self: *App) !void {
        const file = self.selectedFile() orelse {
            try self.setMessage("no file selected", .{});
            return;
        };
        if (!file.conflict) {
            try self.setMessage("{s} is not conflicted", .{file.path});
            return;
        }
        self.mode = .menu;
        self.active_menu = .{ .title = "Resolve conflict", .items = &conflict_resolve_menu, .index = 0 };
        try self.setMessage("resolve {s}", .{file.path});
    }

    fn startConflictActionsMenu(self: *App) !void {
        if (self.data.state == .clean) {
            try self.setMessage("no merge or rebase in progress", .{});
            return;
        }
        const items: []const MenuItem = if (self.data.state == .rebasing)
            &rebase_actions_menu
        else
            &conflict_actions_menu;
        self.mode = .menu;
        self.active_menu = .{ .title = self.data.state.label(), .items = items, .index = 0 };
        try self.setMessage("{s} in progress", .{self.data.state.label()});
    }

    fn handleMenuKey(self: *App, key: vaxis.Key) !void {
        const menu = &(self.active_menu orelse {
            self.mode = .normal;
            return;
        });
        if (self.isEscapeKey(key)) {
            self.closeMenu();
            try self.setMessage("cancelled", .{});
            return;
        }
        if (self.config.keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) {
            menu.index -|= 1;
            return;
        }
        if (self.config.keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) {
            if (menu.index + 1 < menu.items.len) menu.index += 1;
            return;
        }
        if (self.isEnterKey(key) or self.config.keymap.select.matches(key)) {
            const action = menu.items[menu.index].action;
            self.closeMenu();
            try self.runMenuAction(action);
            return;
        }
    }

    fn closeMenu(self: *App) void {
        self.mode = .normal;
        self.active_menu = null;
    }

    fn runMenuAction(self: *App, action: MenuAction) !void {
        switch (action) {
            .discard_file_all => {
                const file = self.selectedFile() orelse {
                    try self.setMessage("no file selected", .{});
                    return;
                };
                return self.runMutationFiles(try self.git.discardFile(file), "discarded {s}", .{file.path});
            },
            .discard_file_unstaged => {
                const file = self.selectedFile() orelse {
                    try self.setMessage("no file selected", .{});
                    return;
                };
                return self.runMutationFiles(try self.git.discardUnstaged(file), "discarded unstaged changes in {s}", .{file.path});
            },
            .delete_branch, .force_delete_branch => {
                const branch = self.selectedBranch() orelse {
                    try self.setMessage("no branch selected", .{});
                    return;
                };
                const force = action == .force_delete_branch;
                return self.runMutation(try self.git.deleteBranch(branch.name, force), "deleted {s}", .{branch.name});
            },
            .reset_soft, .reset_mixed, .reset_hard => {
                const commit = self.selectedCommit() orelse {
                    try self.setMessage("no commit selected", .{});
                    return;
                };
                const mode: git_mod.Git.ResetMode = switch (action) {
                    .reset_soft => .soft,
                    .reset_mixed => .mixed,
                    .reset_hard => .hard,
                    else => unreachable,
                };
                return self.runMutation(try self.git.resetTo(commit.hash, mode), "reset to {s}", .{commit.short_hash});
            },
            .take_ours, .take_theirs => {
                const file = self.selectedFile() orelse {
                    try self.setMessage("no file selected", .{});
                    return;
                };
                const theirs = action == .take_theirs;
                return self.runMutationFiles(try self.git.resolveConflict(file.path, theirs), "resolved {s}", .{file.path});
            },
            .conflict_continue => switch (self.data.state) {
                .merging => return self.runMutation(try self.git.mergeContinue(), "merge continued", .{}),
                .rebasing => return self.runMutation(try self.git.rebaseContinue(), "rebase continued", .{}),
                .cherry_picking => return self.runMutation(try self.git.cherryPickContinue(), "cherry-pick continued", .{}),
                .clean => try self.setMessage("nothing to continue", .{}),
            },
            .conflict_abort => switch (self.data.state) {
                .merging => return self.runMutation(try self.git.mergeAbort(), "merge aborted", .{}),
                .rebasing => return self.runMutation(try self.git.rebaseAbort(), "rebase aborted", .{}),
                .cherry_picking => return self.runMutation(try self.git.cherryPickAbort(), "cherry-pick aborted", .{}),
                .clean => try self.setMessage("nothing to abort", .{}),
            },
            .rebase_amend_continue => {
                if (self.data.state != .rebasing) {
                    try self.setMessage("no rebase in progress to amend", .{});
                    return;
                }
                return self.requestMutation(.amend_continue_rebase, .{ .gerund = "rebasing", .command = "git commit --amend --no-edit && git rebase --continue" }, "amended and continued", .{});
            },
            .stash_all => return self.runMutation(try self.git.stashAll(), "stashed all changes", .{}),
            .stash_untracked => return self.runMutation(try self.git.stashIncludingUntracked(), "stashed (incl. untracked)", .{}),
            .stash_staged => return self.runMutation(try self.git.stashStaged(), "stashed staged changes", .{}),
            .stash_file => {
                const file = self.selectedFile() orelse {
                    try self.setMessage("no file selected", .{});
                    return;
                };
                return self.runMutation(try self.git.stashFile(file.path), "stashed {s}", .{file.path});
            },
            .filter_commits_message => return self.startCommitFilterPrompt(.commit_grep),
            .filter_commits_author => return self.startCommitFilterPrompt(.commit_author),
            .filter_commits_path => return self.startCommitFilterPrompt(.commit_path),
            .clear_commit_filter => return self.clearCommitFilter(),
            .bisect_start_bad, .bisect_start_good => {
                const commit = self.selectedCommit() orelse {
                    try self.setMessage("no commit selected", .{});
                    return;
                };
                const good = action == .bisect_start_good;
                var cmd_buf: [128]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "git bisect start && git bisect {s} {s}", .{ if (good) "good" else "bad", commit.short_hash }) catch "git bisect start";
                return self.requestMutation(.{ .bisect_start_mark = .{ .good = good, .rev = commit.hash } }, .{ .gerund = "bisecting", .command = cmd, .echo = true }, "bisect started", .{});
            },
            .bisect_good_current, .bisect_bad_current => {
                const good = action == .bisect_good_current;
                var cmd_buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "git bisect {s}", .{if (good) "good" else "bad"}) catch "git bisect";
                return self.requestMutation(.{ .bisect_mark = .{ .good = good, .rev = null } }, .{ .gerund = "bisecting", .command = cmd, .echo = true }, "bisect marked", .{});
            },
            .bisect_skip => {
                return self.requestMutation(.bisect_skip, .{ .gerund = "bisecting", .command = "git bisect skip", .echo = true }, "bisect skipped", .{});
            },
            .bisect_good_selected, .bisect_bad_selected => {
                const commit = self.selectedCommit() orelse {
                    try self.setMessage("no commit selected", .{});
                    return;
                };
                const good = action == .bisect_good_selected;
                var cmd_buf: [96]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "git bisect {s} {s}", .{ if (good) "good" else "bad", commit.short_hash }) catch "git bisect";
                return self.requestMutation(.{ .bisect_mark = .{ .good = good, .rev = commit.hash } }, .{ .gerund = "bisecting", .command = cmd, .echo = true }, "bisect marked", .{});
            },
            .bisect_reset => {
                return self.requestMutation(.bisect_reset, .{ .gerund = "resetting bisect", .command = "git bisect reset", .echo = true }, "bisect reset", .{});
            },
            .patch_apply, .patch_apply_reverse => {
                const reverse = action == .patch_apply_reverse;
                const patch = self.buildPatchBytes() catch {
                    try self.setMessage("no patch to apply", .{});
                    return;
                };
                defer self.allocator.free(patch);
                const cmd = if (reverse) "git apply --reverse" else "git apply";
                const summary = if (reverse) "applied patch in reverse" else "applied patch to working tree";
                return self.requestMutation(.{ .apply_custom_patch = .{ .patch = patch, .reverse = reverse } }, .{ .gerund = "applying patch", .command = cmd }, "{s}", .{summary});
            },
            .patch_remove_from_commit => return self.removePatchFromSourceCommit(),
            .patch_reset => {
                self.clearPatch();
                try self.setMessage("patch reset", .{});
            },
        }
    }

    /// Drop the built patch's changes from its source commit via an interactive
    /// rebase. Refused while another operation is in progress or if the source
    /// is the root commit (it has no parent to rebase onto).
    fn removePatchFromSourceCommit(self: *App) !void {
        const source = self.patch_source orelse {
            try self.setMessage("no patch built", .{});
            return;
        };
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }
        const commits = self.data.commits;
        const i = blk: {
            for (commits, 0..) |commit, idx| {
                if (std.mem.eql(u8, commit.hash, source)) break :blk idx;
            }
            try self.setMessage("source commit is not in the loaded history", .{});
            return;
        };
        if (i + 1 >= commits.len) {
            try self.setMessage("cannot remove a patch from the root commit", .{});
            return;
        }

        const patch = self.buildPatchBytes() catch {
            try self.setMessage("could not build the patch", .{});
            return;
        };
        defer self.allocator.free(patch);

        const base_ref = try std.fmt.allocPrint(self.allocator, "{s}^", .{commits[i].hash});
        defer self.allocator.free(base_ref);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try writeRebaseTodo(&aw.writer, commits, i, .edit);
        const todo = try aw.toOwnedSlice();
        defer self.allocator.free(todo);

        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "git rebase -i {s} (remove patch, amend)", .{base_ref}) catch "git rebase -i";
        return self.requestMutation(
            .{ .remove_patch_from_commit = .{ .base_ref = base_ref, .todo = todo, .patch = patch } },
            .{ .gerund = "removing patch", .command = cmd, .post = .clear_patch },
            "removed patch from commit",
            .{},
        );
    }

    /// Open the text prompt for a commit filter, prefilling the existing value
    /// (or, for a path filter, the selected file's path).
    fn startCommitFilterPrompt(self: *App, kind: TextPromptKind) !void {
        var prefill: []const u8 = switch (kind) {
            .commit_grep => self.git.log_grep orelse "",
            .commit_author => self.git.log_author orelse "",
            .commit_path => self.git.log_path orelse "",
            else => "",
        };
        if (kind == .commit_path and prefill.len == 0) {
            if (self.selectedFile()) |file| prefill = file.path;
        }
        self.focus = .commits;
        self.mode = .text_prompt;
        self.text_prompt_kind = kind;
        self.input_buffer.clearRetainingCapacity();
        if (prefill.len > 0) try self.input_buffer.appendSlice(self.allocator, prefill);
        try self.setMessage("{s} (empty to clear)", .{kind.title()});
    }

    fn startDiscardAllConfirmation(self: *App) !void {
        if (self.data.files.len == 0) {
            try self.setMessage("no files to discard", .{});
            return;
        }
        return self.requestConfirmation(.discard_all, "confirm discard all changes", .{});
    }

    /// Undo the last history operation by resetting HEAD to its prior reflog
    /// position. Refused while an operation is in progress or when there are
    /// tracked changes (which a hard reset would discard).
    fn startUndoConfirm(self: *App) !void {
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }
        if (self.data.stagedCount() + self.data.unstagedCount() > 0) {
            try self.setMessage("commit or discard changes before undo", .{});
            return;
        }
        const subject = self.git.reflogSubject() catch try self.allocator.alloc(u8, 0);
        defer self.allocator.free(subject);
        const n = @min(subject.len, self.undo_label_buf.len);
        @memcpy(self.undo_label_buf[0..n], subject[0..n]);
        self.undo_label_len = n;

        return self.requestConfirmation(.undo, "confirm undo", .{});
    }

    /// `n` in the Branches panel creates a branch, or a tag on the Tags tab.
    fn startNewForBranchTab(self: *App) !void {
        if (self.branches_tab == .tags) return self.startTextPrompt(.new_tag);
        if (self.branches_tab == .remotes) return self.startTextPrompt(.add_remote_name);
        return self.startTextPrompt(.new_branch);
    }

    /// The remote name implied by the selected Remotes-tab entry (the prefix of
    /// a `remote/branch` ref), stashed into remote_name_buf. Null off-tab/empty.
    fn selectedRemoteName(self: *App) ?[]const u8 {
        if (self.branches_tab != .remotes) return null;
        const branch = self.selectedRemoteBranch() orelse return null;
        const slash = std.mem.indexOfScalar(u8, branch.name, '/') orelse return null;
        const name = branch.name[0..slash];
        if (name.len == 0 or name.len > self.remote_name_buf.len) return null;
        @memcpy(self.remote_name_buf[0..name.len], name);
        self.remote_name_len = name.len;
        return self.remote_name_buf[0..name.len];
    }

    fn startEditRemote(self: *App) !void {
        if (self.branches_tab != .remotes) {
            try self.setMessage("switch to the Remotes tab to edit a remote", .{});
            return;
        }
        const name = self.selectedRemoteName() orelse {
            try self.setMessage("no remote selected", .{});
            return;
        };
        // Prefill the current URL so the user edits rather than retypes.
        const current = self.git.remoteUrl(name) catch null;
        defer if (current) |c| self.allocator.free(c);
        self.mode = .text_prompt;
        self.text_prompt_kind = .edit_remote_url;
        self.focus = .branches;
        self.input_buffer.clearRetainingCapacity();
        if (current) |c| try self.input_buffer.appendSlice(self.allocator, std.mem.trim(u8, c, " \t\r\n"));
        try self.setMessage("edit URL for {s}", .{name});
    }

    fn startRemoveRemote(self: *App) !void {
        if (self.branches_tab != .remotes) {
            try self.setMessage("switch to the Remotes tab to remove a remote", .{});
            return;
        }
        const name = self.selectedRemoteName() orelse {
            try self.setMessage("no remote selected", .{});
            return;
        };
        return self.requestConfirmation(.remove_remote, "confirm remove remote {s}", .{name});
    }

    fn setUpstreamToSelected(self: *App) !void {
        if (self.branches_tab != .remotes) {
            try self.setMessage("select a remote branch (Remotes tab) to track", .{});
            return;
        }
        const branch = self.selectedRemoteBranch() orelse {
            try self.setMessage("no remote branch selected", .{});
            return;
        };
        try self.beginOpFmt("git branch --set-upstream-to={s}", .{branch.name});
        return self.runMutation(try self.git.setUpstream(branch.name), "tracking {s}", .{branch.name});
    }

    /// `d` in the Branches panel deletes by tab: local branch / tag / remote.
    fn startDeleteForBranchTab(self: *App) !void {
        switch (self.branches_tab) {
            .local => return self.startBranchDeleteMenu(),
            .tags => {
                const tag = self.selectedTag() orelse {
                    try self.setMessage("no tag selected", .{});
                    return;
                };
                return self.requestConfirmation(.delete_tag, "confirm delete tag {s}", .{tag.name});
            },
            .remotes => {
                const branch = self.selectedRemoteBranch() orelse {
                    try self.setMessage("no remote branch selected", .{});
                    return;
                };
                return self.requestConfirmation(.delete_remote_branch, "confirm delete remote {s}", .{branch.name});
            },
            .worktrees => {
                const wt = self.selectedWorktree() orelse {
                    try self.setMessage("no worktree selected", .{});
                    return;
                };
                if (wt.is_current) {
                    try self.setMessage("cannot remove the current worktree", .{});
                    return;
                }
                return self.requestConfirmation(.remove_worktree, "confirm remove worktree {s}", .{wt.path});
            },
            .submodules => try self.setMessage("no delete action for submodules", .{}),
        }
    }

    fn startBranchDeleteMenu(self: *App) !void {
        const branch = try self.localBranchForAction() orelse return;
        if (branch.current) {
            try self.setMessage("cannot delete the checked-out branch", .{});
            return;
        }
        self.mode = .menu;
        self.active_menu = .{ .title = "Delete branch", .items = &branch_delete_menu, .index = 0 };
        try self.setMessage("delete {s}", .{branch.name});
    }

    fn startBranchConfirm(self: *App, kind: Confirmation) !void {
        const branch = try self.localBranchForAction() orelse return;
        if (branch.current) {
            try self.setMessage("select a branch other than the current one", .{});
            return;
        }
        return self.requestConfirmation(kind, "confirm action on {s}", .{branch.name});
    }

    fn fastForwardSelectedBranch(self: *App) !void {
        const branch = try self.localBranchForAction() orelse return;
        const upstream = branch.upstream orelse {
            try self.setMessage("{s} has no upstream to fast-forward", .{branch.name});
            return;
        };
        if (branch.current) {
            var cmd_buf: [160]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "git merge --ff-only {s}", .{upstream}) catch "git merge --ff-only";
            return self.requestMutation(.fast_forward_current, .{ .gerund = "fast-forwarding", .command = cmd }, "fast-forwarded {s}", .{branch.name});
        }
        const slash = std.mem.indexOfScalar(u8, upstream, '/') orelse {
            try self.setMessage("cannot parse upstream {s}", .{upstream});
            return;
        };
        const remote = upstream[0..slash];
        const remote_ref = upstream[slash + 1 ..];
        var cmd_buf: [192]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "git fetch {s} {s}:{s}", .{ remote, remote_ref, branch.name }) catch "git fetch";
        return self.requestMutation(.{ .fast_forward_branch = .{ .remote = remote, .remote_ref = remote_ref, .local = branch.name } }, .{ .gerund = "fast-forwarding", .command = cmd }, "fast-forwarded {s}", .{branch.name});
    }

    /// Validate that a branch action can run: the Branches panel must be on the
    /// Local tab with a branch selected. Returns the selected branch or null
    /// (after setting an explanatory message).
    fn localBranchForAction(self: *App) !?model.Branch {
        if (self.branches_tab != .local) {
            try self.setMessage("branch actions apply to the Local tab", .{});
            return null;
        }
        return self.selectedBranch() orelse {
            try self.setMessage("no branch selected", .{});
            return null;
        };
    }

    fn startCommitResetMenu(self: *App) !void {
        const commit = try self.commitForAction() orelse return;
        self.mode = .menu;
        self.active_menu = .{ .title = "Reset to commit", .items = &commit_reset_menu, .index = 0 };
        try self.setMessage("reset to {s}", .{commit.short_hash});
    }

    fn revertSelectedCommit(self: *App) !void {
        const commit = try self.commitForAction() orelse return;
        return self.runMutation(try self.git.revertCommit(commit.hash), "reverted {s}", .{commit.short_hash});
    }

    fn rebaseSelectedCommit(self: *App, action: RebaseAction) !void {
        if (self.commits_tab != .commits) {
            try self.setMessage("rebase actions apply to the Commits tab", .{});
            return;
        }
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress rebase/merge first (m)", .{});
            return;
        }
        if (self.data.commits.len == 0) {
            try self.setMessage("no commit selected", .{});
            return;
        }
        const i = @min(self.commit_index, self.data.commits.len - 1);
        return self.runRebase(action, i, null);
    }

    /// Build the rebase todo + base ref for `action` on commit index `i`
    /// (in the newest-first commit list), run it, and report.
    fn runRebase(self: *App, action: RebaseAction, i: usize, message: ?[]const u8) !void {
        const commits = self.data.commits;
        const base_index: usize = switch (action) {
            .drop, .edit, .reword, .move_up => i,
            .squash, .fixup, .move_down => i + 1,
        };
        switch (action) {
            .squash, .fixup, .move_down => if (i + 1 >= commits.len) {
                try self.setMessage("no commit below to combine with", .{});
                return;
            },
            .move_up => if (i == 0) {
                try self.setMessage("commit is already at the top", .{});
                return;
            },
            else => {},
        }

        const base_ref = try std.fmt.allocPrint(self.allocator, "{s}^", .{commits[base_index].hash});
        defer self.allocator.free(base_ref);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try writeRebaseTodo(&aw.writer, commits, i, action);
        const todo = try aw.toOwnedSlice();
        defer self.allocator.free(todo);

        var run_buf: [96]u8 = undefined;
        const shown = std.fmt.bufPrint(&run_buf, "git rebase -i {s}", .{base_ref}) catch "git rebase -i";
        return self.requestMutation(
            .{ .rebase_todo = .{ .base_ref = base_ref, .todo = todo, .message = message } },
            .{ .gerund = "rebasing", .command = shown },
            "{s}",
            .{action.label()},
        );
    }

    /// Emit a git-rebase-todo (oldest-first) for `action` on commit index `i`.
    fn writeRebaseTodo(w: *std.Io.Writer, commits: []const model.Commit, i: usize, action: RebaseAction) !void {
        switch (action) {
            .drop, .edit, .reword => {
                var k = i;
                while (true) : (k -= 1) {
                    const word = if (k == i) action.word() else "pick";
                    try w.print("{s} {s}\n", .{ word, commits[k].hash });
                    if (k == 0) break;
                }
            },
            .squash, .fixup => {
                var k = i + 1;
                while (true) : (k -= 1) {
                    const word = if (k == i) action.word() else "pick";
                    try w.print("{s} {s}\n", .{ word, commits[k].hash });
                    if (k == 0) break;
                }
            },
            .move_down => {
                // Swap i with i+1 (move the commit one step older).
                try w.print("pick {s}\n", .{commits[i].hash});
                try w.print("pick {s}\n", .{commits[i + 1].hash});
                if (i > 0) {
                    var k = i - 1;
                    while (true) : (k -= 1) {
                        try w.print("pick {s}\n", .{commits[k].hash});
                        if (k == 0) break;
                    }
                }
            },
            .move_up => {
                // Swap i with i-1 (move the commit one step newer).
                try w.print("pick {s}\n", .{commits[i - 1].hash});
                try w.print("pick {s}\n", .{commits[i].hash});
                if (i >= 2) {
                    var k = i - 2;
                    while (true) : (k -= 1) {
                        try w.print("pick {s}\n", .{commits[k].hash});
                        if (k == 0) break;
                    }
                }
            },
        }
    }

    /// Validate that a commit action can run: the Commits panel must be on the
    /// Commits tab (not Reflog) with a commit selected.
    fn commitForAction(self: *App) !?model.Commit {
        if (self.commits_tab != .commits) {
            try self.setMessage("commit actions apply to the Commits tab", .{});
            return null;
        }
        return self.selectedCommit() orelse {
            try self.setMessage("no commit selected", .{});
            return null;
        };
    }

    /// Commit the staged changes as a `fixup!` of the selected commit.
    fn createFixupCommit(self: *App) !void {
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }
        const commit = try self.commitForAction() orelse return;
        if (self.data.stagedCount() == 0) {
            try self.setMessage("stage changes to create a fixup commit", .{});
            return;
        }
        return self.runMutation(try self.git.createFixup(commit.hash), "created fixup! for {s}", .{commit.short_hash});
    }

    /// Autosquash fixup!/squash! commits above (and including) the selected one.
    fn autosquashFixups(self: *App) !void {
        if (self.data.state != .clean) {
            try self.setMessage("finish the in-progress operation first (m)", .{});
            return;
        }
        const commit = try self.commitForAction() orelse return;
        const base = try std.fmt.allocPrint(self.allocator, "{s}^", .{commit.hash});
        defer self.allocator.free(base);
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "git rebase -i --autosquash {s}", .{base}) catch "git rebase -i --autosquash";
        return self.requestMutation(.{ .autosquash = base }, .{ .gerund = "autosquashing", .command = cmd }, "autosquashed fixups", .{});
    }

    fn checkoutSelectedBranch(self: *App) !void {
        switch (self.branches_tab) {
            .local => {
                const branch = self.selectedBranch() orelse {
                    try self.setMessage("no branch selected", .{});
                    return;
                };
                if (branch.current) {
                    try self.setMessage("already on {s}", .{branch.name});
                    return;
                }
                return self.runMutation(try self.git.checkout(branch.name), "checked out {s}", .{branch.name});
            },
            .remotes => {
                const branch = self.selectedRemoteBranch() orelse {
                    try self.setMessage("no remote branch selected", .{});
                    return;
                };
                // git's DWIM checkout creates a local tracking branch from
                // "<remote>/<name>" when "<name>" doesn't already exist locally.
                const local_name = textmatch.localNameForRemote(branch.name);
                return self.runMutation(try self.git.checkout(local_name), "checked out {s}", .{local_name});
            },
            .tags => {
                const tag = self.selectedTag() orelse {
                    try self.setMessage("no tag selected", .{});
                    return;
                };
                return self.runMutation(try self.git.checkout(tag.name), "checked out {s} (detached)", .{tag.name});
            },
            .worktrees => {
                // Switching the active worktree would re-root the app; instead
                // tell the user to open ziggity in that directory.
                if (self.selectedWorktree()) |wt| {
                    try self.setMessage("open ziggity in {s} to use that worktree", .{wt.path});
                } else {
                    try self.setMessage("no worktree selected", .{});
                }
            },
            .submodules => {
                const sm = self.selectedSubmodule() orelse {
                    try self.setMessage("no submodule selected", .{});
                    return;
                };
                return self.runMutation(try self.git.updateSubmodule(sm.path), "updated {s}", .{sm.path});
            },
        }
    }

    fn applySelectedStash(self: *App) !void {
        const entry = self.selectedStash() orelse {
            try self.setMessage("no stash entry selected", .{});
            return;
        };
        return self.runMutation(try self.git.stashApply(entry.index), "applied {s}", .{entry.selector});
    }

    fn popSelectedStash(self: *App) !void {
        const entry = self.selectedStash() orelse {
            try self.setMessage("no stash entry selected", .{});
            return;
        };
        return self.runMutation(try self.git.stashPop(entry.index), "popped {s}", .{entry.selector});
    }

    fn dropSelectedStash(self: *App) !void {
        const entry = self.selectedStash() orelse {
            try self.setMessage("no stash entry selected", .{});
            return;
        };
        return self.runMutation(try self.git.stashDrop(entry.index), "dropped {s}", .{entry.selector});
    }

    fn handleCommitPromptKey(self: *App, key: vaxis.Key) !void {
        if (self.isEscapeKey(key)) {
            self.mode = .normal;
            self.commit_buffer.clearRetainingCapacity();
            self.commit_body_buffer.clearRetainingCapacity();
            try self.setMessage("commit cancelled", .{});
            return;
        }
        // Tab switches between the subject and body fields.
        if (key.matches(vaxis.Key.tab, .{})) {
            self.commit_field = if (self.commit_field == .subject) .body else .subject;
            return;
        }
        // Enter submits from the subject; in the body it inserts a newline.
        if (self.isEnterKey(key)) {
            if (self.commit_field == .body) {
                try self.commit_body_buffer.append(self.allocator, '\n');
                return;
            }
            return self.submitCommit();
        }
        const buffer = if (self.commit_field == .subject) &self.commit_buffer else &self.commit_body_buffer;
        if (self.isBackspaceKey(key)) {
            if (buffer.items.len > 0) buffer.items.len -= 1;
            return;
        }
        if (key.text) |text| {
            if (!key.mods.ctrl and !key.mods.alt and text.len > 0 and text[0] >= 0x20) {
                try buffer.appendSlice(self.allocator, text);
            }
        }
    }

    fn submitCommit(self: *App) !void {
        const subject = std.mem.trim(u8, self.commit_buffer.items, " \t\r\n");
        if (subject.len == 0) {
            try self.setMessage("commit message cannot be empty", .{});
            return;
        }
        const body = std.mem.trim(u8, self.commit_body_buffer.items, " \t\r\n");
        const message = if (body.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ subject, body })
        else
            try self.allocator.dupe(u8, subject);
        defer self.allocator.free(message);

        const action = self.commit_action;
        const reword_index = self.commit_reword_index;
        self.mode = .normal;
        self.commit_buffer.clearRetainingCapacity();
        self.commit_body_buffer.clearRetainingCapacity();

        switch (action) {
            .create => return self.runMutation(try self.git.commit(message), "commit created", .{}),
            .reword => return self.runRebase(.reword, reword_index, message),
        }
    }

    fn handleFileFilterPromptKey(self: *App, key: vaxis.Key) !void {
        if (self.isEscapeKey(key)) {
            try self.clearFileFilter();
            return;
        }
        if (self.config.keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) {
            try self.recallFilterHistory(-1);
            return;
        }
        if (self.config.keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) {
            try self.recallFilterHistory(1);
            return;
        }
        if (self.isEnterKey(key)) {
            const filter = std.mem.trim(u8, self.file_filter_buffer.items, " \t\r\n");
            try self.applyFileFilter(filter);
            return;
        }
        if (self.isBackspaceKey(key)) {
            if (self.file_filter_buffer.items.len > 0) self.file_filter_buffer.items.len -= 1;
            self.filter_history_index = null;
            try self.updateFileFilterFromPrompt();
            return;
        }
        if (key.text) |text| {
            if (!key.mods.ctrl and !key.mods.alt and text.len > 0 and text[0] >= 0x20) {
                try self.file_filter_buffer.appendSlice(self.allocator, text);
                self.filter_history_index = null;
                try self.updateFileFilterFromPrompt();
            }
        }
    }

    fn handleStatusFilterMenuKey(self: *App, key: vaxis.Key) !void {
        if (self.isEscapeKey(key)) {
            self.mode = .normal;
            try self.setMessage("status filter cancelled", .{});
            return;
        }
        if (self.config.keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) {
            self.status_filter_index -|= 1;
            return;
        }
        if (self.config.keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) {
            if (self.status_filter_index + 1 < status_filter_options.len) self.status_filter_index += 1;
            return;
        }
        if (self.isEnterKey(key) or self.config.keymap.select.matches(key)) {
            return self.setFileDisplayFilter(status_filter_options[self.status_filter_index]);
        }
        // Letter shortcuts mirror lazygit's quick filters.
        if (key.matches('r', .{})) return self.setFileDisplayFilter(.all);
        if (key.matches('s', .{})) return self.setFileDisplayFilter(.staged);
        if (key.matches('u', .{})) return self.setFileDisplayFilter(.unstaged);
        if (key.matches('t', .{})) return self.setFileDisplayFilter(.tracked);
        if (key.matches('T', .{})) return self.setFileDisplayFilter(.untracked);
        if (key.matches('c', .{})) return self.setFileDisplayFilter(.conflicted);
    }

    fn handleConfirmationKey(self: *App, key: vaxis.Key) !void {
        if (self.isEnterKey(key) or key.matches('y', .{})) {
            try self.confirmPendingAction();
            return;
        }
        if (self.isEscapeKey(key) or key.matches('n', .{})) {
            self.mode = .normal;
            self.pending_confirmation = null;
            try self.setMessage("cancelled", .{});
            return;
        }
    }

    fn confirmPendingAction(self: *App) !void {
        const pending = self.pending_confirmation orelse {
            self.mode = .normal;
            return;
        };
        self.mode = .normal;
        self.pending_confirmation = null;
        switch (pending) {
            .discard_all => return self.runMutationFiles(try self.git.discardAll(), "discarded all changes", .{}),
            .merge_branch => {
                const branch = self.selectedBranch() orelse {
                    try self.setMessage("no branch selected", .{});
                    return;
                };
                var cmd_buf: [160]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "git merge --no-edit {s}", .{branch.name}) catch "git merge --no-edit";
                return self.requestMutation(.{ .merge = branch.name }, .{ .gerund = "merging", .command = cmd }, "merged {s}", .{branch.name});
            },
            .rebase_branch => {
                const branch = self.selectedBranch() orelse {
                    try self.setMessage("no branch selected", .{});
                    return;
                };
                if (self.marked_base) |base| {
                    var cmd_buf: [192]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "git rebase --onto {s} {s}^", .{ branch.name, base }) catch "git rebase --onto";
                    // requestMutation dupes the marked base before we clear it.
                    try self.requestMutation(.{ .rebase_onto_marked = .{ .newbase = branch.name, .marked_base = base } }, .{ .gerund = "rebasing", .command = cmd }, "rebased marked commits onto {s}", .{branch.name});
                    self.clearMarkedBase();
                    return;
                }
                var cmd_buf: [160]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "git rebase {s}", .{branch.name}) catch "git rebase";
                return self.requestMutation(.{ .rebase = branch.name }, .{ .gerund = "rebasing", .command = cmd }, "rebased onto {s}", .{branch.name});
            },
            .delete_tag => {
                const tag = self.selectedTag() orelse {
                    try self.setMessage("no tag selected", .{});
                    return;
                };
                return self.runMutation(try self.git.deleteTag(tag.name), "deleted tag {s}", .{tag.name});
            },
            .delete_remote_branch => {
                const branch = self.selectedRemoteBranch() orelse {
                    try self.setMessage("no remote branch selected", .{});
                    return;
                };
                const slash = std.mem.indexOfScalar(u8, branch.name, '/') orelse {
                    try self.setMessage("cannot parse remote {s}", .{branch.name});
                    return;
                };
                const remote = branch.name[0..slash];
                const remote_branch = branch.name[slash + 1 ..];
                return self.runMutation(try self.git.deleteRemoteBranch(remote, remote_branch), "deleted remote {s}", .{branch.name});
            },
            .remove_worktree => {
                const wt = self.selectedWorktree() orelse {
                    try self.setMessage("no worktree selected", .{});
                    return;
                };
                return self.runMutation(try self.git.removeWorktree(wt.path), "removed worktree {s}", .{wt.path});
            },
            .remove_remote => {
                const name = self.remote_name_buf[0..self.remote_name_len];
                if (name.len == 0) {
                    try self.setMessage("no remote selected", .{});
                    return;
                }
                return self.runMutation(try self.git.removeRemote(name), "removed remote {s}", .{name});
            },
            .undo => return self.runMutation(try self.git.undoLastOperation(), "undone", .{}),
        }
    }

    /// Whether the confirm-before prompt for `kind` is disabled in config. Field
    /// names in `ConfirmSkips` match the `Confirmation` tags, so the lookup is a
    /// direct comptime `@field`.
    fn shouldSkipConfirm(self: *const App, kind: Confirmation) bool {
        return switch (kind) {
            inline else => |k| @field(self.config.skip_confirm, @tagName(k)),
        };
    }

    /// Begin a confirm-before-destructive action. If its skip flag is set the
    /// action runs immediately (no prompt); otherwise the confirmation prompt is
    /// shown with `prompt_fmt`/`prompt_args` in the bottom bar. The prompt text
    /// is irrelevant when skipping, since the action sets its own message.
    fn requestConfirmation(self: *App, kind: Confirmation, comptime prompt_fmt: []const u8, prompt_args: anytype) !void {
        self.pending_confirmation = kind;
        if (self.shouldSkipConfirm(kind)) return self.confirmPendingAction();
        self.mode = .confirmation;
        try self.setMessage(prompt_fmt, prompt_args);
    }

    /// The panel whose selection drives the main-panel content. When the main
    /// panel is focused we keep showing the side panel we descended from.
    fn contentFocus(self: *const App) model.Focus {
        return if (self.focus == .main) self.main_origin else self.focus;
    }

    /// Refresh the main-panel preview for the current selection. Cheap previews
    /// (status, placeholders) render immediately; diffs that require a git
    /// command render from `preview_cache` when warm, otherwise the command is
    /// queued for the TUI loop to run off-thread (see `requestGitPreview`). This
    /// never spawns git on the UI thread, so panel/selection moves stay instant.
    fn updatePreview(self: *App) !void {
        // While staging, the main panel renders the raw staging diff instead of
        // self.diff, so there is nothing to recompute here.
        if (self.staging_active) return;

        // Diffing mode overrides the normal preview with a ref-to-ref diff.
        if (self.diff_base) |base| {
            const target = self.selectedRefForDiff();
            if (target == null)
                return self.setCheapPreview(try std.fmt.allocPrint(self.allocator, "Diffing from {s}.\n\nSelect a commit or branch to compare against.\n", .{base}));
            if (std.mem.eql(u8, base, target.?))
                return self.setCheapPreview(try std.fmt.allocPrint(self.allocator, "Diffing from {s}.\n\nThat is the base itself - move to another ref.\n", .{base}));
            return self.requestGitPreview(.{ .diff_refs = .{ .base = base, .target = target.? } });
        }

        switch (self.contentFocus()) {
            .status => return self.setCheapPreview(try self.statusPreview()),
            .files, .main => {
                if (self.tree_view) {
                    if (self.treeSelectedRow()) |row| {
                        if (row.is_dir) return self.setCheapPreview(try std.fmt.allocPrint(self.allocator, "Directory {s}/\n\nSelect a file to view its diff.\n", .{row.path}));
                    }
                }
                if (self.selectedFile()) |file| return self.requestGitPreview(.{ .file = file });
                if (self.anyFileFilterActive() and self.data.files.len > 0) return self.setCheapPreview(try self.allocator.dupe(u8, "No files match the active filter.\n"));
                return self.setCheapPreview(try self.allocator.dupe(u8, "Working tree clean.\n"));
            },
            .branches => {
                if (self.branches_tab == .worktrees) {
                    if (self.selectedWorktree()) |wt|
                        return self.setCheapPreview(try std.fmt.allocPrint(self.allocator, "Worktree{s}\nPath:   {s}\nBranch: {s}\n", .{ if (wt.is_current) " (current)" else "", wt.path, wt.branch }));
                    return self.setCheapPreview(try self.allocator.dupe(u8, "No worktrees.\n"));
                }
                if (self.branches_tab == .submodules) {
                    if (self.selectedSubmodule()) |sm|
                        return self.setCheapPreview(try std.fmt.allocPrint(self.allocator, "Submodule ({s})\nPath: {s}\nSHA:  {s}\n\nspace to init/update.\n", .{ sm.stateLabel(), sm.path, sm.sha }));
                    return self.setCheapPreview(try self.allocator.dupe(u8, "No submodules.\n"));
                }
                if (self.selectedBranchRefName()) |name| return self.requestGitPreview(.{ .branch = name });
                return self.setCheapPreview(try self.allocator.dupe(u8, "Nothing to show in this tab.\n"));
            },
            .commits => {
                const commit = self.selectedCommit() orelse return self.setCheapPreview(try self.allocator.dupe(u8, "No commits found.\n"));
                if (self.commit_files_active) {
                    if (self.selectedCommitFile()) |file| return self.requestGitPreview(.{ .commit_file = .{ .hash = commit.hash, .path = file.path } });
                    return self.setCheapPreview(try self.allocator.dupe(u8, "This commit changed no files.\n"));
                }
                return self.requestGitPreview(.{ .commit = commit.hash });
            },
            .stash => {
                if (self.selectedStash()) |entry| return self.requestGitPreview(.{ .stash = entry.index });
                return self.setCheapPreview(try self.allocator.dupe(u8, "No stash entries.\n"));
            },
        }
    }

    /// Show `text` (gpa-owned; ownership transferred) right away. Used for
    /// previews that need no git command; also cancels any queued async fetch
    /// since a cheap preview means we are no longer waiting on git.
    fn setCheapPreview(self: *App, text: []u8) void {
        self.allocator.free(self.diff);
        self.diff = text;
        self.preview_loading = false;
        self.setDesiredKey("");
    }

    /// Render the preview for `kind`: instantly from cache when warm, otherwise
    /// leave the current text on screen and queue the git command for the TUI
    /// loop to run off the UI thread. Never blocks on git.
    fn requestGitPreview(self: *App, kind: PreviewKind) !void {
        const key = try self.previewKey(self.allocator, kind);
        defer self.allocator.free(key);
        self.setDesiredKey(key);

        if (self.preview_cache.get(key)) |cached| {
            const dup = try self.allocator.dupe(u8, cached);
            self.allocator.free(self.diff);
            self.diff = dup;
            self.preview_loading = false;
            return;
        }

        // Already running, or already queued, for this exact key: just wait.
        if (std.mem.eql(u8, key, self.preview_inflight_key)) {
            self.preview_loading = true;
            return;
        }
        if (self.preview_wanted) |w| {
            if (std.mem.eql(u8, key, w.key)) {
                self.preview_loading = true;
                return;
            }
        }

        const job = try self.buildPreviewJob(kind, key);
        if (self.preview_wanted) |w| w.deinit(page_alloc);
        self.preview_wanted = job;
        self.preview_loading = true;
        // Avoid a blank panel on the very first preview; thereafter we keep the
        // previous diff on screen until the worker fills it in.
        if (self.diff.len == 0) self.diff = try self.allocator.dupe(u8, "Loading...\n");
    }

    /// Content-addressed cache key for `kind`. The diff-context is folded in
    /// because it changes the rendered output. The "f:" prefix marks
    /// working-tree file diffs so they can be invalidated on a working-tree
    /// refresh without dropping immutable commit/branch/stash previews.
    fn previewKey(self: *App, gpa: std.mem.Allocator, kind: PreviewKind) ![]u8 {
        const ctx = self.config.diff_context;
        return switch (kind) {
            .file => |f| std.fmt.allocPrint(gpa, "f:{d}:{c}{c}{c}:{s}", .{
                ctx,
                @as(u8, if (f.tracked) 'T' else 'u'),
                @as(u8, if (f.has_staged) 'S' else '_'),
                @as(u8, if (f.has_unstaged) 'U' else '_'),
                f.path,
            }),
            .branch => |name| std.fmt.allocPrint(gpa, "b:{s}", .{name}),
            .commit => |hash| std.fmt.allocPrint(gpa, "c:{d}:{s}", .{ ctx, hash }),
            .commit_file => |cf| std.fmt.allocPrint(gpa, "cf:{d}:{s}:{s}", .{ ctx, cf.hash, cf.path }),
            .stash => |idx| std.fmt.allocPrint(gpa, "s:{d}:{d}", .{ ctx, idx }),
            .diff_refs => |dr| std.fmt.allocPrint(gpa, "dr:{d}:{s}:{s}", .{ ctx, dr.base, dr.target }),
        };
    }

    /// Record `key` as the preview the selection currently wants, and drop any
    /// queued job that no longer matches it (the selection moved on before it
    /// started). Pass "" when the current preview needs no git command.
    fn setDesiredKey(self: *App, key: []const u8) void {
        if (!std.mem.eql(u8, key, self.preview_desired_key)) {
            if (self.allocator.dupe(u8, key)) |dup| {
                self.allocator.free(self.preview_desired_key);
                self.preview_desired_key = dup;
            } else |_| {}
        }
        if (self.preview_wanted) |w| {
            if (!std.mem.eql(u8, w.key, key)) {
                w.deinit(page_alloc);
                self.preview_wanted = null;
            }
        }
    }

    /// Translate a `PreviewKind` into a page-allocated `PreviewJob` (git commands
    /// mirroring git.zig's preview helpers) the worker can run thread-safely.
    fn buildPreviewJob(self: *App, kind: PreviewKind, key: []const u8) !PreviewJob {
        var ctx_buf: [24]u8 = undefined;
        const ctx_arg = try std.fmt.bufPrint(&ctx_buf, "--unified={d}", .{self.config.diff_context});

        var sections: std.ArrayList(PreviewSection) = .empty;
        errdefer {
            for (sections.items) |sec| {
                for (sec.argv) |a| page_alloc.free(a);
                page_alloc.free(sec.argv);
            }
            sections.deinit(page_alloc);
        }
        var empty_msg: []const u8 = "No preview available.\n";

        switch (kind) {
            .file => |f| {
                empty_msg = "No diff for selected file.\n";
                if (f.has_unstaged) {
                    if (!f.tracked and !f.has_staged) {
                        try sections.append(page_alloc, .{
                            .argv = try dupArgv(&.{ "diff", "--no-index", "--no-color", "--", "/dev/null", f.path }),
                            .label = "Untracked\n\n",
                            .keep_on_error = true,
                        });
                    } else {
                        try sections.append(page_alloc, .{
                            .argv = try dupArgv(&.{ "diff", "--no-ext-diff", "--no-color", ctx_arg, "--", f.path }),
                            .label = "Unstaged\n\n",
                        });
                    }
                }
                if (f.has_staged) {
                    try sections.append(page_alloc, .{
                        .argv = try dupArgv(&.{ "diff", "--staged", "--no-ext-diff", "--no-color", ctx_arg, "--", f.path }),
                        .label = "Staged\n\n",
                    });
                }
            },
            .branch => |name| {
                empty_msg = "No commits.\n";
                try sections.append(page_alloc, .{
                    .argv = try dupArgv(&.{ "log", "--oneline", "--decorate", "-30", name }),
                });
            },
            .commit => |hash| {
                empty_msg = "Could not load commit.\n";
                try sections.append(page_alloc, .{
                    .argv = try dupArgv(&.{ "show", "--no-ext-diff", "--no-color", "--stat", "--patch", ctx_arg, hash }),
                });
            },
            .commit_file => |cf| {
                empty_msg = "No changes for this file.\n";
                try sections.append(page_alloc, .{
                    .argv = try dupArgv(&.{ "show", cf.hash, "--no-ext-diff", "--no-color", ctx_arg, "--format=", "--", cf.path }),
                });
            },
            .stash => |idx| {
                empty_msg = "No changes in stash.\n";
                var sel_buf: [32]u8 = undefined;
                const selector = try std.fmt.bufPrint(&sel_buf, "stash@{{{d}}}", .{idx});
                try sections.append(page_alloc, .{
                    .argv = try dupArgv(&.{ "stash", "show", "-p", "--stat", "-u", "--no-ext-diff", "--no-color", ctx_arg, selector }),
                });
            },
            .diff_refs => |dr| {
                empty_msg = "No differences.\n";
                try sections.append(page_alloc, .{
                    .argv = try dupArgv(&.{ "diff", "--no-ext-diff", "--no-color", "--stat", "--patch", ctx_arg, dr.base, dr.target }),
                });
            },
        }

        const key_copy = try page_alloc.dupe(u8, key);
        errdefer page_alloc.free(key_copy);
        const sec_slice = try sections.toOwnedSlice(page_alloc);
        return .{ .key = key_copy, .sections = sec_slice, .empty_msg = empty_msg };
    }

    /// Claim the queued preview job (if any) for the TUI loop to run, recording
    /// its key as in-flight so a repeated selection of the same item does not
    /// re-queue it. Returns null when nothing is pending.
    pub fn takePreviewJob(self: *App) ?PreviewJob {
        const job = self.preview_wanted orelse return null;
        self.preview_wanted = null;
        const dup = self.allocator.dupe(u8, job.key) catch "";
        self.allocator.free(self.preview_inflight_key);
        self.preview_inflight_key = dup;
        return job;
    }

    /// Called on the UI thread when a preview worker finishes. `text` (owned by
    /// `gpa`, the page allocator) is the rendered preview, or null if the worker
    /// could not start. Caches the result and shows it if the selection still
    /// wants it; otherwise it stays cached for when we return to that item.
    pub fn completePreview(self: *App, job: PreviewJob, text: ?[]u8, gpa: std.mem.Allocator) void {
        self.allocator.free(self.preview_inflight_key);
        self.preview_inflight_key = "";
        const is_desired = std.mem.eql(u8, job.key, self.preview_desired_key);
        if (text) |t| {
            self.preview_cache.put(self.allocator, job.key, t) catch {};
            if (is_desired) {
                if (self.allocator.dupe(u8, t)) |dup| {
                    self.allocator.free(self.diff);
                    self.diff = dup;
                    self.preview_loading = false;
                } else |_| {}
            }
            gpa.free(t);
        } else if (is_desired) {
            self.preview_loading = false;
        }
        job.deinit(gpa);
    }

    fn statusPreview(self: *App) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;
        try writer.print("On branch {s}\n", .{self.data.current_branch});
        if (self.data.upstream) |upstream| {
            const ahead = self.data.ahead orelse 0;
            const behind = self.data.behind orelse 0;
            try writer.print("Tracking {s}\n", .{upstream});
            if (ahead == 0 and behind == 0) {
                try writer.writeAll("Up to date with upstream.\n");
            } else {
                if (ahead > 0) try writer.print("{d} commit(s) to push (ahead).\n", .{ahead});
                if (behind > 0) try writer.print("{d} commit(s) to pull (behind).\n", .{behind});
            }
        } else {
            try writer.writeAll("No upstream configured.\n");
        }
        try writer.print("\n{d} changed files: {d} staged, {d} unstaged\n", .{
            self.data.files.len,
            self.data.stagedCount(),
            self.data.unstagedCount(),
        });
        try writer.print("{d} local branches, {d} stash entries\n", .{
            self.data.branches.len,
            self.data.stash.len,
        });
        return aw.toOwnedSlice();
    }

    /// Queue a network op for the TUI loop to run off-thread. Single in-flight.
    fn requestAsync(self: *App, op: AsyncOp) !void {
        if (self.async_active or self.async_requested != null) {
            try self.setMessage("a network operation is already running", .{});
            return;
        }
        self.git.recordExternal(op.argv());
        self.async_requested = op;
        self.async_op = op;
        try self.setMessage("{s}...", .{op.gerund()});
    }

    /// Called on the UI thread when an async op finishes. `result` is owned by
    /// `result_allocator` (the async path's allocator); null means the command
    /// failed to even start.
    pub fn completeAsync(self: *App, op: AsyncOp, result_opt: ?git_mod.ExecResult, result_allocator: std.mem.Allocator) !void {
        self.async_active = false;
        if (result_opt) |result| {
            var mutable = result;
            defer mutable.deinit(result_allocator);
            if (mutable.ok()) {
                // Network success stays silent (bottom bar), like lazygit.
                try self.setMessage("{s} complete", .{op.label()});
            } else {
                // Failures follow result_dialog so a rejected push/pull is seen.
                var label_buf: [64]u8 = undefined;
                const summary = std.fmt.bufPrint(&label_buf, "{s} failed", .{op.label()}) catch "command failed";
                const stderr = std.mem.trim(u8, mutable.stderr, " \t\r\n");
                try self.reportFailure(summary, if (stderr.len > 0) mutable.stderr else mutable.stdout);
            }
        } else {
            try self.setMessage("{s} failed to start", .{op.label()});
        }
        self.refresh() catch {};
    }

    /// Paint the operation dialog's "running" frame for a slow op before it
    /// blocks the loop. `command` is shown verbatim (e.g. "git rebase main").
    /// Fast ops skip this; their command is recovered from the log on finish.
    fn beginOp(self: *App, command: []const u8) !void {
        self.allocator.free(self.op_command);
        self.op_command = try self.allocator.dupe(u8, command);
        self.op_running = true;
        self.op_scroll = 0;
        self.mode = .operation;
        // Paint the "Running…" frame so it is visible while the (blocking) git
        // call runs; it lasts only as long as the op. Only when a hook is
        // installed (the real TUI) — tests have none and stay instant.
        if (self.render_hook) |hook| hook.call();
    }

    fn beginOpFmt(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const command = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(command);
        try self.beginOp(command);
    }

    /// Populate and show the operation result dialog. `summary` is a one-line
    /// outcome; `raw` is the command's stdout/stderr (trimmed for display).
    /// Used for failures (always) and for successes only when
    /// `result_dialog = always`.
    fn finishOp(self: *App, ok: bool, summary: []const u8, raw: []const u8) !void {
        // A slow op set op_command via beginOp; a fast op recovers the command
        // it just ran from the log so the dialog shows what executed.
        if (!self.op_running) {
            self.allocator.free(self.op_command);
            const log = self.git.command_log.items;
            self.op_command = try self.allocator.dupe(u8, if (log.len > 0) log[log.len - 1] else "");
        }
        self.allocator.free(self.op_summary);
        self.op_summary = try self.allocator.dupe(u8, summary);
        self.allocator.free(self.op_output);
        self.op_output = try self.allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        self.op_ok = ok;
        self.op_running = false;
        self.op_scroll = 0;
        self.mode = .operation;
        // Mirror the outcome in the bottom bar for a glance after dismissal.
        self.allocator.free(self.message);
        self.message = try std.fmt.allocPrint(self.allocator, "{s}", .{summary});
    }

    /// Tear down a pending "Running…" frame (from beginOp) without showing a
    /// result dialog, returning to the normal view.
    fn dismissOpFrame(self: *App) void {
        self.op_running = false;
        if (self.mode == .operation) self.mode = .normal;
    }

    /// Surface a successful op (lazygit-style). Under `result_dialog = always`
    /// the legacy result dialog is shown; otherwise it is silent — a one-line
    /// bottom-bar summary, tearing down any "Running…" frame. `raw` is the
    /// command's stdout, shown only in the dialog.
    fn reportSuccess(self: *App, summary: []const u8, raw: []const u8) !void {
        if (self.config.result_dialog == .always) {
            try self.finishOp(true, summary, raw);
            return;
        }
        self.dismissOpFrame();
        try self.setMessage("{s}", .{summary});
    }

    /// Surface a failed op. Under `result_dialog = never` the error stays in the
    /// bottom bar (its first line); otherwise the error dialog pops so the
    /// failure is not missed.
    fn reportFailure(self: *App, summary: []const u8, raw: []const u8) !void {
        if (self.config.result_dialog == .never) {
            self.dismissOpFrame();
            const line = firstLine(raw);
            try self.setMessage("{s}", .{if (line.len > 0) line else summary});
            return;
        }
        try self.finishOp(false, summary, raw);
    }

    /// How much to reload after a mutation. `.files` is the fast working-tree
    /// scope (lazygit's FILES scope); `.full` reloads the whole repo.
    const RefreshScope = enum { files, full };

    fn refreshScope(self: *App, scope: RefreshScope) void {
        switch (scope) {
            .files => self.refreshFiles() catch self.refresh() catch {},
            .full => self.refresh() catch {},
        }
    }

    /// Run a mutation that touched only the working tree (stage/unstage/discard/
    /// resolve) — refreshes just the file list, so it stays snappy on big repos.
    fn runMutationFiles(self: *App, result: git_mod.ExecResult, comptime success_fmt: []const u8, args: anytype) !void {
        return self.runMutationScoped(result, .files, success_fmt, args);
    }

    fn runMutation(self: *App, result: git_mod.ExecResult, comptime success_fmt: []const u8, args: anytype) !void {
        return self.runMutationScoped(result, .full, success_fmt, args);
    }

    fn runMutationScoped(self: *App, result: git_mod.ExecResult, scope: RefreshScope, comptime success_fmt: []const u8, args: anytype) !void {
        var mutable = result;
        defer mutable.deinit(self.allocator);
        if (mutable.ok()) {
            const summary = try std.fmt.allocPrint(self.allocator, success_fmt, args);
            defer self.allocator.free(summary);
            try self.reportSuccess(summary, mutable.stdout);
            self.refreshScope(scope);
            return;
        }
        const stderr = std.mem.trim(u8, mutable.stderr, " \t\r\n");
        try self.reportFailure("command failed", if (stderr.len > 0) mutable.stderr else mutable.stdout);
        self.refreshScope(scope);
    }

    /// True while a foreground git op (the initial load, a network op, or a slow
    /// mutation) is queued or running. Used to gate mutating keybindings, pause
    /// the background refresh, and animate the spinner.
    pub fn foregroundBusy(self: *const App) bool {
        return self.initial_load_pending or
            self.async_active or self.async_requested != null or
            self.mutation_active or self.mutation_requested != null;
    }

    /// UI-thread side effect to run when a mutation succeeds.
    const PostMutation = enum { none, clear_patch };

    const MutationMeta = struct {
        gerund: []const u8 = "working",
        command: []const u8 = "",
        echo: bool = false,
        post: PostMutation = .none,
    };

    /// Queue a slow mutation for the TUI loop to run off-thread. Refused if a
    /// foreground op is already in flight. `command` (if any) is recorded in the
    /// command log now, since the worker's log is discarded. On completion the
    /// result is surfaced via reportSuccess/reportFailure + refresh.
    fn requestMutation(self: *App, mutation: Mutation, meta: MutationMeta, comptime success_fmt: []const u8, args: anytype) !void {
        if (self.foregroundBusy()) {
            try self.setMessage("operation in progress...", .{});
            return;
        }
        const job = try mutation.dupe(page_alloc);
        errdefer job.deinit(page_alloc);
        const msg = try std.fmt.allocPrint(page_alloc, success_fmt, args);
        errdefer page_alloc.free(msg);
        if (meta.command.len > 0) self.git.recordRaw(meta.command);

        if (self.mutation_requested) |old| old.deinit(page_alloc);
        page_alloc.free(self.mutation_msg);
        self.mutation_requested = job;
        self.mutation_msg = msg;
        self.mutation_echo = meta.echo;
        self.mutation_post = meta.post;
        self.mutation_gerund = meta.gerund;
        self.spinner_frame = 0;
        try self.setMessage("{s}...", .{meta.gerund});
    }

    /// TUI loop hook: claim the queued mutation to run off-thread.
    pub fn takeMutation(self: *App) ?Mutation {
        const job = self.mutation_requested orelse return null;
        self.mutation_requested = null;
        self.mutation_active = true;
        return job;
    }

    /// TUI loop hook: a mutation worker finished. `result_opt` (owned by `gpa`,
    /// the page allocator) is null if it could not run. Surfaces success/failure
    /// like the synchronous path, then refreshes. Frees the job and result.
    pub fn completeMutation(self: *App, job: Mutation, result_opt: ?git_mod.ExecResult, gpa: std.mem.Allocator) !void {
        self.mutation_active = false;
        defer job.deinit(gpa);
        if (result_opt) |result| {
            var mutable = result;
            defer mutable.deinit(gpa);
            if (mutable.ok()) {
                switch (self.mutation_post) {
                    .none => {},
                    .clear_patch => self.clearPatch(),
                }
                const line = if (self.mutation_echo) firstLine(mutable.stdout) else "";
                try self.reportSuccess(if (line.len > 0) line else self.mutation_msg, mutable.stdout);
            } else {
                const stderr = std.mem.trim(u8, mutable.stderr, " \t\r\n");
                try self.reportFailure("command failed", if (stderr.len > 0) mutable.stderr else mutable.stdout);
            }
        } else {
            try self.reportFailure("command failed to start", "");
        }
        self.refresh() catch {};
    }

    fn runCustomCommand(self: *App, command: []const u8) !void {
        var run_buf: [256]u8 = undefined;
        const shown = std.fmt.bufPrint(&run_buf, "$ {s}", .{command}) catch command;
        try self.beginOp(shown);
        var result = try self.git.runShell(command);
        defer result.deinit(self.allocator);
        // Custom commands are usually run to read output, so by default show it
        // in the dialog; `command_output = silent` makes them follow the same
        // result_dialog policy as git actions.
        if (self.config.command_output == .show) {
            if (result.ok()) {
                const summary = try std.fmt.allocPrint(self.allocator, "ran: {s}", .{command});
                defer self.allocator.free(summary);
                try self.finishOp(true, summary, result.stdout);
            } else {
                try self.finishOp(false, "command failed", if (result.stderr.len > 0) result.stderr else result.stdout);
            }
        } else if (result.ok()) {
            const summary = try std.fmt.allocPrint(self.allocator, "ran: {s}", .{command});
            defer self.allocator.free(summary);
            try self.reportSuccess(summary, result.stdout);
        } else {
            try self.reportFailure("command failed", if (result.stderr.len > 0) result.stderr else result.stdout);
        }
        self.refresh() catch {};
    }

    fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) !void {
        self.allocator.free(self.message);
        self.message = try std.fmt.allocPrint(self.allocator, fmt, args);
    }

    fn clampSelections(self: *App) void {
        if (self.data.files.len == 0) self.file_index = 0 else self.file_index = @min(self.file_index, self.data.files.len - 1);
        self.normalizeFileSelectionForFilter();
        if (self.data.branches.len == 0) self.branch_index = 0 else self.branch_index = @min(self.branch_index, self.data.branches.len - 1);
        if (self.data.remote_branches.len == 0) self.remote_index = 0 else self.remote_index = @min(self.remote_index, self.data.remote_branches.len - 1);
        if (self.data.tags.len == 0) self.tag_index = 0 else self.tag_index = @min(self.tag_index, self.data.tags.len - 1);
        if (self.data.worktrees.len == 0) self.worktree_index = 0 else self.worktree_index = @min(self.worktree_index, self.data.worktrees.len - 1);
        if (self.data.submodules.len == 0) self.submodule_index = 0 else self.submodule_index = @min(self.submodule_index, self.data.submodules.len - 1);
        if (self.data.commits.len == 0) self.commit_index = 0 else self.commit_index = @min(self.commit_index, self.data.commits.len - 1);
        if (self.data.reflog.len == 0) self.reflog_index = 0 else self.reflog_index = @min(self.reflog_index, self.data.reflog.len - 1);
        if (self.data.stash.len == 0) self.stash_index = 0 else self.stash_index = @min(self.stash_index, self.data.stash.len - 1);
    }

    fn restoreFileSelection(self: *App, selected_path: ?[]const u8) void {
        const path = selected_path orelse return;
        for (self.data.files, 0..) |file, idx| {
            if (std.mem.eql(u8, file.path, path)) {
                self.file_index = idx;
                return;
            }
        }
    }

    fn applyFileFilter(self: *App, filter: []const u8) !void {
        self.mode = .normal;
        try self.pushFilterHistory(filter);
        self.filter_history_index = null;
        try self.setFileFilter(filter);
        self.file_filter_buffer.clearRetainingCapacity();
        if (self.file_filter.len == 0) {
            try self.setMessage("file filter cleared", .{});
        } else {
            try self.setMessage("filter \"{s}\" ({d}/{d})", .{ self.file_filter, self.visibleFileCount(), self.data.files.len });
        }
    }

    fn clearFileFilter(self: *App) !void {
        self.mode = .normal;
        self.file_filter_buffer.clearRetainingCapacity();
        try self.applyFileFilter("");
    }

    fn updateFileFilterFromPrompt(self: *App) !void {
        const filter = std.mem.trim(u8, self.file_filter_buffer.items, " \t\r\n");
        try self.setFileFilter(filter);
        if (self.file_filter.len == 0) {
            try self.setMessage("filter files", .{});
        } else {
            try self.setMessage("filter \"{s}\" ({d}/{d})", .{ self.file_filter, self.visibleFileCount(), self.data.files.len });
        }
    }

    fn setFileFilter(self: *App, filter: []const u8) !void {
        const next_filter = try self.allocator.dupe(u8, filter);
        self.allocator.free(self.file_filter);
        self.file_filter = next_filter;
        self.file_index = self.firstMatchingFileIndex() orelse 0;
        if (self.tree_view) try self.rebuildTree(null);
        self.main_scroll = 0;
        try self.updatePreview();
    }

    fn setFileDisplayFilter(self: *App, filter: model.FileDisplayFilter) !void {
        self.mode = .normal;
        self.file_display_filter = filter;
        self.file_index = self.firstMatchingFileIndex() orelse 0;
        if (self.tree_view) try self.rebuildTree(null);
        self.main_scroll = 0;
        try self.updatePreview();
        if (filter == .all) {
            try self.setMessage("file status filter cleared", .{});
        } else {
            try self.setMessage("showing {s} files ({d}/{d})", .{ filter.label(), self.visibleFileCount(), self.data.files.len });
        }
    }

    fn moveTreeCursor(self: *App, delta: i8) void {
        if (self.tree_rows.len == 0) {
            self.tree_cursor = 0;
            return;
        }
        if (delta < 0) {
            if (self.tree_cursor > 0) self.tree_cursor -= 1;
        } else if (self.tree_cursor + 1 < self.tree_rows.len) {
            self.tree_cursor += 1;
        }
    }

    fn moveFileUp(self: *App) void {
        if (self.data.files.len == 0) return;
        self.normalizeFileSelectionForFilter();
        var idx = @min(self.file_index, self.data.files.len - 1);
        while (idx > 0) {
            idx -= 1;
            if (self.fileMatchesFilter(self.data.files[idx])) {
                self.file_index = idx;
                return;
            }
        }
    }

    fn moveFileDown(self: *App) void {
        if (self.data.files.len == 0) return;
        self.normalizeFileSelectionForFilter();
        var idx = @min(self.file_index, self.data.files.len - 1) + 1;
        while (idx < self.data.files.len) : (idx += 1) {
            if (self.fileMatchesFilter(self.data.files[idx])) {
                self.file_index = idx;
                return;
            }
        }
    }

    fn normalizeFileSelectionForFilter(self: *App) void {
        if (self.data.files.len == 0) {
            self.file_index = 0;
            return;
        }
        self.file_index = @min(self.file_index, self.data.files.len - 1);
        if (self.fileMatchesFilter(self.data.files[self.file_index])) return;
        self.file_index = self.firstMatchingFileIndex() orelse 0;
    }

    fn firstMatchingFileIndex(self: *const App) ?usize {
        for (self.data.files, 0..) |file, idx| {
            if (self.fileMatchesFilter(file)) return idx;
        }
        return null;
    }

    fn visibleUnstagedCount(self: *const App) usize {
        var count: usize = 0;
        for (self.data.files) |file| {
            if (self.fileMatchesFilter(file) and file.has_unstaged) count += 1;
        }
        return count;
    }

    fn visibleStagedCount(self: *const App) usize {
        var count: usize = 0;
        for (self.data.files) |file| {
            if (self.fileMatchesFilter(file) and file.has_staged) count += 1;
        }
        return count;
    }

    const VisiblePathKind = enum {
        staged,
        unstaged,
    };

    fn collectVisiblePaths(self: *const App, paths: *std.ArrayList([]const u8), kind: VisiblePathKind) !void {
        for (self.data.files) |file| {
            if (!self.fileMatchesFilter(file)) continue;
            const include = switch (kind) {
                .staged => file.has_staged,
                .unstaged => file.has_unstaged,
            };
            if (include) try paths.append(self.allocator, file.path);
        }
    }

    fn isEscapeKey(self: *const App, key: vaxis.Key) bool {
        return self.config.keymap.escape.matches(key) or key.matches(vaxis.Key.escape, .{});
    }

    fn isEnterKey(self: *const App, key: vaxis.Key) bool {
        return self.config.keymap.enter.matches(key) or key.matches(vaxis.Key.enter, .{});
    }

    fn isBackspaceKey(self: *const App, key: vaxis.Key) bool {
        return self.config.keymap.backspace.matches(key) or key.matches(vaxis.Key.backspace, .{});
    }
};

test "action enum is referenced" {
    try std.testing.expect(actions.Action.quit == .quit);
}

test "cherry-pick clipboard toggles copied commits" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{
        .{ .hash = @constCast("aaaaaaa"), .short_hash = @constCast("aaa"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("first") },
        .{ .hash = @constCast("bbbbbbb"), .short_hash = @constCast("bbb"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("second") },
    };
    app.data.commits = &commits;

    app.commit_index = 0;
    try app.toggleCommitCopy();
    try std.testing.expect(app.isCommitCopied("aaaaaaa"));
    try std.testing.expectEqual(@as(usize, 1), app.copied_commits.items.len);

    app.commit_index = 1;
    try app.toggleCommitCopy();
    try std.testing.expectEqual(@as(usize, 2), app.copied_commits.items.len);

    app.commit_index = 0;
    try app.toggleCommitCopy(); // uncopy aaa
    try std.testing.expect(!app.isCommitCopied("aaaaaaa"));
    try std.testing.expect(app.isCommitCopied("bbbbbbb"));
    try std.testing.expectEqual(@as(usize, 1), app.copied_commits.items.len);
}

test "add-remote prompt stashes the name and asks for the URL" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    app.mode = .text_prompt;
    app.text_prompt_kind = .add_remote_name;
    try app.input_buffer.appendSlice(allocator, "upstream");
    try app.submitTextPrompt();

    // Transitions to the URL step with the name stashed and input cleared.
    try std.testing.expectEqual(TextPromptKind.add_remote_url, app.text_prompt_kind.?);
    try std.testing.expectEqualStrings("upstream", app.remote_name_buf[0..app.remote_name_len]);
    try std.testing.expectEqual(@as(usize, 0), app.input_buffer.items.len);
}

test "selectedRemoteName extracts the remote from the selected ref" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var remotes = [_]model.Branch{.{ .name = @constCast("origin/main") }};
    app.data.remote_branches = &remotes;
    app.branches_tab = .remotes;
    app.remote_index = 0;

    try std.testing.expectEqualStrings("origin", app.selectedRemoteName().?);
    app.branches_tab = .local;
    try std.testing.expect(app.selectedRemoteName() == null);
}

test "webUrlFromRemote normalizes the common remote URL forms" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "git@github.com:owner/repo.git", .want = "https://github.com/owner/repo" },
        .{ .in = "https://github.com/owner/repo.git", .want = "https://github.com/owner/repo" },
        .{ .in = "ssh://git@gitlab.com:22/group/sub/repo.git", .want = "https://gitlab.com/group/sub/repo" },
        .{ .in = "https://github.com/owner/repo", .want = "https://github.com/owner/repo" },
    };
    for (cases) |c| {
        const got = (try webUrlFromRemote(allocator, c.in)).?;
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
    try std.testing.expect((try webUrlFromRemote(allocator, "not-a-url")) == null);
}

test "custom patch toggles commit files and is tied to one commit" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{
        .{ .hash = @constCast("aaaaaaa"), .short_hash = @constCast("aaa"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("first") },
        .{ .hash = @constCast("bbbbbbb"), .short_hash = @constCast("bbb"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("second") },
    };
    app.data.commits = &commits;
    var cfiles = [_]model.CommitFile{
        .{ .status = 'M', .path = @constCast("f.txt") },
        .{ .status = 'M', .path = @constCast("g.txt") },
    };
    app.commit_files = &cfiles;
    app.focus = .commits;
    app.commit_files_active = true;
    app.commit_index = 0;

    app.commit_file_index = 0;
    try app.toggleFileInPatch();
    try std.testing.expect(app.patchHasFile("f.txt"));
    app.commit_file_index = 1;
    try app.toggleFileInPatch();
    try std.testing.expectEqual(@as(usize, 2), app.patchFileCount());

    // Toggling a file off removes it.
    app.commit_file_index = 0;
    try app.toggleFileInPatch();
    try std.testing.expect(!app.patchHasFile("f.txt"));
    try std.testing.expectEqual(@as(usize, 1), app.patchFileCount());

    // A file from a different commit is refused while a patch exists.
    app.commit_index = 1;
    try app.toggleFileInPatch();
    try std.testing.expectEqualStrings("patch is from another commit - reset it first (ctrl+p)", app.message);
    try std.testing.expectEqual(@as(usize, 1), app.patchFileCount());
}

test "bisect menu reflects whether a bisect is in progress" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    app.data.bisecting = false;
    try app.startBisectMenu();
    try std.testing.expectEqual(@as(usize, bisect_start_menu.len), app.active_menu.?.items.len);

    app.data.bisecting = true;
    try app.startBisectMenu();
    try std.testing.expectEqual(@as(usize, bisect_actions_menu.len), app.active_menu.?.items.len);
}

test "diffing mode marks a ref base and clears cleanly" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    // A panel without a ref refuses to start diffing.
    app.focus = .status;
    try app.toggleDiffMark();
    try std.testing.expect(app.diff_base == null);
    try std.testing.expectEqualStrings("select a commit or branch to diff", app.message);

    // The Commits panel exposes the selected hash as the diff ref.
    var commits = [_]model.Commit{
        .{ .hash = @constCast("aaaaaaa"), .short_hash = @constCast("aaa"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("first") },
    };
    app.data.commits = &commits;
    app.focus = .commits;
    app.commit_index = 0;
    try std.testing.expectEqualStrings("aaaaaaa", app.selectedRefForDiff().?);

    app.diff_base = try allocator.dupe(u8, "aaaaaaa");
    app.clearDiffBase();
    try std.testing.expect(app.diff_base == null);
}

test "preview pipeline queues a git job, caches it, and serves repeats instantly" {
    const allocator = std.testing.allocator;
    const page = std.heap.page_allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{
        .{ .hash = @constCast("aaaaaaa"), .short_hash = @constCast("aaa"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("first") },
        .{ .hash = @constCast("bbbbbbb"), .short_hash = @constCast("bbb"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("second") },
    };
    app.data.commits = &commits;
    app.focus = .commits;

    // Selecting a commit does not run git inline: it queues a job and shows a
    // placeholder rather than blocking.
    app.commit_index = 0;
    try app.updatePreview();
    try std.testing.expect(app.preview_wanted != null);
    try std.testing.expect(app.preview_loading);
    try std.testing.expectEqualStrings("Loading...\n", app.diff);

    // The TUI loop would claim the job and run it off-thread; simulate that and
    // hand back the rendered diff.
    const job = app.takePreviewJob().?;
    try std.testing.expect(app.preview_wanted == null);
    app.completePreview(job, try page.dupe(u8, "DIFF FOR a\n"), page);
    try std.testing.expectEqualStrings("DIFF FOR a\n", app.diff);
    try std.testing.expect(!app.preview_loading);

    // Move to another commit, then back: the first one is cache-warm and renders
    // synchronously with no new job queued.
    app.commit_index = 1;
    try app.updatePreview();
    try std.testing.expect(app.preview_wanted != null); // commit b not cached yet
    const job_b = app.takePreviewJob().?;
    job_b.deinit(page_alloc);
    app.allocator.free(app.preview_inflight_key);
    app.preview_inflight_key = "";

    app.commit_index = 0;
    try app.updatePreview();
    try std.testing.expect(app.preview_wanted == null); // served from cache
    try std.testing.expectEqualStrings("DIFF FOR a\n", app.diff);

    // A full refresh would invalidate everything; here just confirm the cache
    // clears cleanly.
    app.preview_cache.clearAll(app.allocator);
    app.commit_index = 0;
    try app.updatePreview();
    try std.testing.expect(app.preview_wanted != null); // cache cold again
}

test "background worktree refresh is paused while an operation runs" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    // A network op in flight pauses the periodic refresh: nothing is queued.
    app.async_active = true;
    app.requestWorktreeRefresh();
    try std.testing.expect(!app.worktree_refresh_requested);

    // Even an already-queued request is held back while paused.
    app.async_active = false;
    app.requestWorktreeRefresh();
    try std.testing.expect(app.worktree_refresh_requested);
    app.async_active = true;
    try std.testing.expect(app.takeWorktreeRefresh() == null);
    try std.testing.expect(app.worktree_refresh_requested); // still pending

    // Once the op clears, the held request is claimed.
    app.async_active = false;
    try std.testing.expect(app.takeWorktreeRefresh() != null);
    try std.testing.expect(app.worktree_refresh_active);
}

test "background worktree snapshot applies on the UI thread and honors generation" {
    const allocator = std.testing.allocator;
    const page = std.heap.page_allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer {
        app.data.deinit(allocator);
        deinitTestApp(&app);
    }
    app.data.current_branch = try allocator.dupe(u8, "old");

    // A snapshot for the current generation is applied: status and file list
    // update from the page-allocated payload (which is freed by the apply).
    const snap = WorktreeSnapshot{
        .status = .{ .current_branch = try page.dupe(u8, "main"), .upstream = null },
        .porcelain = try page.dupe(u8, " M hello.txt\x00"),
        .state = .clean,
    };
    try app.applyWorktreeSnapshot(snap, app.refresh_generation, page);
    try std.testing.expectEqualStrings("main", app.data.current_branch);
    try std.testing.expectEqual(@as(usize, 1), app.data.files.len);
    try std.testing.expectEqualStrings("hello.txt", app.data.files[0].path);

    // A snapshot stamped with an older generation (a full refresh landed while
    // it was loading) is discarded rather than clobbering the newer data.
    app.refresh_generation +%= 1;
    const stale = WorktreeSnapshot{
        .status = .{ .current_branch = try page.dupe(u8, "feature"), .upstream = null },
        .porcelain = try page.dupe(u8, ""),
        .state = .clean,
    };
    try app.applyWorktreeSnapshot(stale, app.refresh_generation - 1, page);
    try std.testing.expectEqualStrings("main", app.data.current_branch);
    try std.testing.expectEqual(@as(usize, 1), app.data.files.len);
}

test "clipboard copy picks the focused panel's identifier" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{
        .{ .hash = @constCast("aaaaaaa"), .short_hash = @constCast("aaa"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("first") },
    };
    app.data.commits = &commits;

    // Commits panel copies the full hash.
    app.focus = .commits;
    app.commit_index = 0;
    try app.requestClipboardCopy();
    try std.testing.expectEqualStrings("aaaaaaa", app.clipboard_request.?);

    // Status panel has nothing to copy and leaves the request untouched.
    app.focus = .status;
    try app.requestClipboardCopy();
    try std.testing.expectEqualStrings("aaaaaaa", app.clipboard_request.?);
    try std.testing.expectEqualStrings("nothing to copy here", app.message);
}

test "mark base toggles the rebase-onto base commit" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{
        .{ .hash = @constCast("aaaaaaa"), .short_hash = @constCast("aaa"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("first") },
        .{ .hash = @constCast("bbbbbbb"), .short_hash = @constCast("bbb"), .author = @constCast("s"), .time = @constCast("now"), .refs = @constCast(""), .subject = @constCast("second") },
    };
    app.data.commits = &commits;

    app.commit_index = 0;
    try app.toggleMarkBase();
    try std.testing.expect(app.isMarkedBase("aaaaaaa"));

    // Marking a different commit replaces the previous base (only one at a time).
    app.commit_index = 1;
    try app.toggleMarkBase();
    try std.testing.expect(!app.isMarkedBase("aaaaaaa"));
    try std.testing.expect(app.isMarkedBase("bbbbbbb"));

    // Toggling the marked commit again clears it.
    try app.toggleMarkBase();
    try std.testing.expect(app.marked_base == null);
}

test "filter history dedups consecutive entries and ignores empties" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    try app.pushFilterHistory("app");
    try app.pushFilterHistory("app"); // dedup of the most recent
    try app.pushFilterHistory(""); // ignored
    try app.pushFilterHistory("zig");

    try std.testing.expectEqual(@as(usize, 2), app.filter_history.items.len);
    try std.testing.expectEqualStrings("app", app.filter_history.items[0]);
    try std.testing.expectEqualStrings("zig", app.filter_history.items[1]);
}

test "click row maps to the list item under the cursor" {
    // No scroll: row N selects item N.
    try std.testing.expectEqual(@as(usize, 2), App.rowToIndex(0, 5, 3, 2));
    // Selection at the bottom scrolls the window; row 0 is item 2 of 5.
    try std.testing.expectEqual(@as(usize, 2), App.rowToIndex(4, 5, 3, 0));
    try std.testing.expectEqual(@as(usize, 4), App.rowToIndex(4, 5, 3, 2));
    // Clamps to the last item and handles empty lists.
    try std.testing.expectEqual(@as(usize, 4), App.rowToIndex(0, 5, 10, 9));
    try std.testing.expectEqual(@as(usize, 0), App.rowToIndex(0, 0, 3, 1));
}

test "escape clears active file filter before quitting" {
    const allocator = std.testing.allocator;
    var app = App{
        .allocator = allocator,
        .git = undefined,
        .config = .{},
        .diff = try allocator.dupe(u8, "old preview"),
        .message = try allocator.dupe(u8, "old message"),
        .file_filter = try allocator.dupe(u8, "app"),
    };
    defer allocator.free(app.diff);
    defer allocator.free(app.message);
    defer allocator.free(app.file_filter);

    try app.handleKey(.{ .codepoint = vaxis.Key.escape });

    try std.testing.expect(app.running);
    try std.testing.expectEqual(@as(usize, 0), app.file_filter.len);
    try std.testing.expectEqualStrings("file filter cleared", app.message);
}

test "result feedback: success is silent by default, failure pops a dialog" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);
    // default result_dialog == .on_error

    // Success: no dialog, just a bottom-bar summary.
    try app.reportSuccess("staged main.zig", "");
    try std.testing.expectEqual(Mode.normal, app.mode);
    try std.testing.expectEqualStrings("staged main.zig", app.message);

    // A slow op's "Running…" frame is torn down on silent success.
    app.op_running = true;
    app.mode = .operation;
    try app.reportSuccess("merged feature", "Merge made.\n");
    try std.testing.expectEqual(Mode.normal, app.mode);
    try std.testing.expect(!app.op_running);

    // Failure pops the error dialog (op_running set so finishOp skips the log).
    app.op_running = true;
    app.mode = .operation;
    try app.reportFailure("command failed", "fatal: boom\n");
    try std.testing.expectEqual(Mode.operation, app.mode);
    try std.testing.expect(!app.op_ok);
    try std.testing.expectEqualStrings("fatal: boom", app.op_output);
}

test "result feedback: always shows on success, never suppresses error dialogs" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    // always: success enters the dialog (op_running set so finishOp skips log).
    app.config.result_dialog = .always;
    app.op_running = true;
    try app.reportSuccess("did a thing", "some output\n");
    try std.testing.expectEqual(Mode.operation, app.mode);
    try std.testing.expect(app.op_ok);

    // never: failure stays in the bottom bar (first line), no dialog.
    app.config.result_dialog = .never;
    app.mode = .normal;
    try app.reportFailure("command failed", "first error line\nsecond\n");
    try std.testing.expectEqual(Mode.normal, app.mode);
    try std.testing.expectEqualStrings("first error line", app.message);
}

test "firstLine returns the first non-blank trimmed line" {
    try std.testing.expectEqualStrings("hello", firstLine("\n  \n  hello \nworld"));
    try std.testing.expectEqualStrings("", firstLine("   \n\t\n"));
    try std.testing.expectEqualStrings("Bisecting: 3 left", firstLine("Bisecting: 3 left\n[abc] x"));
}

test "skip-confirm flag controls whether the confirm prompt is shown" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    try std.testing.expect(!app.shouldSkipConfirm(.delete_tag));
    app.config.skip_confirm.delete_tag = true;
    try std.testing.expect(app.shouldSkipConfirm(.delete_tag));
    try std.testing.expect(!app.shouldSkipConfirm(.discard_all)); // independent

    // With the flag off, the prompt is shown (no git touched on this path).
    try app.requestConfirmation(.discard_all, "confirm discard", .{});
    try std.testing.expectEqual(Mode.confirmation, app.mode);
    try std.testing.expectEqual(Confirmation.discard_all, app.pending_confirmation.?);
}

test "async initial load deep-copies into gpa and clears the loading state" {
    const allocator = std.testing.allocator;
    const page = std.heap.page_allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer {
        app.data.deinit(allocator); // applyRepoLoad makes data gpa-owned
        deinitTestApp(&app);
    }
    app.initial_load_pending = true;
    try std.testing.expect(app.foregroundBusy()); // gated while loading

    // A page-allocated RepoData as the worker would produce.
    var page_data = model.RepoData{};
    page_data.current_branch = try page.dupe(u8, "main");
    page_data.commits = try page.alloc(model.Commit, 1);
    page_data.commits[0] = .{ .hash = try page.dupe(u8, "abc"), .short_hash = try page.dupe(u8, "abc"), .author = try page.dupe(u8, "s"), .time = try page.dupe(u8, "now"), .refs = try page.dupe(u8, ""), .subject = try page.dupe(u8, "first") };

    app.applyRepoLoad(page_data, page);
    try std.testing.expect(!app.initial_load_pending);
    try std.testing.expect(!app.foregroundBusy());
    try std.testing.expectEqualStrings("main", app.data.current_branch);
    try std.testing.expectEqual(@as(usize, 1), app.data.commits.len);
    try std.testing.expectEqualStrings("first", app.data.commits[0].subject);
    try std.testing.expectEqualStrings("ready", app.message);
}

test "slow mutation queues off-thread, marks busy, and refuses a second op" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    try std.testing.expect(!app.foregroundBusy());
    // command = "" so we don't touch git (undefined in tests).
    try app.requestMutation(.bisect_skip, .{ .gerund = "bisecting", .echo = true }, "bisect skipped", .{});
    try std.testing.expect(app.foregroundBusy());
    try std.testing.expect(app.mutation_requested != null);
    try std.testing.expect(!app.mutation_active);
    try std.testing.expect(app.mutation_echo);
    try std.testing.expectEqualStrings("bisecting", app.mutation_gerund);
    try std.testing.expectEqualStrings("bisect skipped", app.mutation_msg);
    try std.testing.expectEqualStrings("bisecting...", app.message);

    // The loop claims the job to run it.
    const job = app.takeMutation().?;
    defer job.deinit(page_alloc);
    try std.testing.expect(app.mutation_requested == null);
    try std.testing.expect(app.mutation_active);

    // A second request is refused while one is in flight.
    try app.requestMutation(.bisect_reset, .{ .gerund = "x" }, "y", .{});
    try std.testing.expect(app.mutation_requested == null);
    try std.testing.expectEqualStrings("operation in progress...", app.message);

    app.mutation_active = false;
}

test "input gate ignores mutating keys while a foreground op runs" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    app.mutation_active = true; // simulate an op in flight
    try app.handleKey(.{ .codepoint = 'a' }); // stage_all — mutating, must be ignored
    try std.testing.expectEqualStrings("operation in progress...", app.message);
    app.mutation_active = false;
}

test "isMutating classifies actions for the input gate" {
    try std.testing.expect(actions.isMutating(.stage_all));
    try std.testing.expect(actions.isMutating(.merge_branch));
    try std.testing.expect(actions.isMutating(.fetch));
    try std.testing.expect(actions.isMutating(.select));
    try std.testing.expect(!actions.isMutating(.move_down));
    try std.testing.expect(!actions.isMutating(.focus_files));
    try std.testing.expect(!actions.isMutating(.quit));
    try std.testing.expect(!actions.isMutating(.refresh));
}

test "operation dialog shows a running frame then its result" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    // A slow op paints its running frame first (no render hook in tests).
    try app.beginOp("git rebase main");
    try std.testing.expectEqual(Mode.operation, app.mode);
    try std.testing.expect(app.op_running);
    try std.testing.expectEqualStrings("git rebase main", app.op_command);

    // Finishing flips to the result, preserving the running op's command.
    try app.finishOp(true, "rebased onto main", "Successfully rebased.\n");
    try std.testing.expect(!app.op_running);
    try std.testing.expect(app.op_ok);
    try std.testing.expectEqualStrings("git rebase main", app.op_command);
    try std.testing.expectEqualStrings("rebased onto main", app.op_summary);
    try std.testing.expectEqualStrings("Successfully rebased.", app.op_output);
    try std.testing.expectEqualStrings("rebased onto main", app.message);

    // Enter dismisses the dialog.
    try app.handleKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqual(Mode.normal, app.mode);
}

/// Derive an https web URL (no scheme variants, no trailing `.git`) from a git
/// remote URL. Handles scp-like (`git@host:owner/repo`), `https://…`, and
/// `ssh://[user@]host[:port]/path` forms. Returns null if it cannot parse.
fn webUrlFromRemote(allocator: std.mem.Allocator, remote: []const u8) !?[]u8 {
    var url = std.mem.trim(u8, remote, " \t\r\n");
    if (std.mem.endsWith(u8, url, ".git")) url = url[0 .. url.len - 4];
    url = std.mem.trimEnd(u8, url, "/");
    if (url.len == 0) return null;

    var host: []const u8 = "";
    var path: []const u8 = "";

    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        // scheme://[user@]host[:port]/path
        var after = url[scheme_end + 3 ..];
        if (std.mem.indexOfScalar(u8, after, '@')) |at| after = after[at + 1 ..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        var hostport = after[0..slash];
        if (std.mem.indexOfScalar(u8, hostport, ':')) |colon| hostport = hostport[0..colon];
        host = hostport;
        path = after[slash + 1 ..];
    } else if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        // scp-like [user@]host:path
        var hostpart = url[0..colon];
        if (std.mem.indexOfScalar(u8, hostpart, '@')) |at| hostpart = hostpart[at + 1 ..];
        host = hostpart;
        path = url[colon + 1 ..];
    } else return null;

    path = std.mem.trim(u8, path, "/");
    if (host.len == 0 or path.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "https://{s}/{s}", .{ host, path });
}

fn testApp(allocator: std.mem.Allocator, files: []model.FileStatus) !App {
    return App{
        .allocator = allocator,
        .git = undefined,
        .config = .{},
        .diff = try allocator.dupe(u8, ""),
        .message = try allocator.dupe(u8, ""),
        .file_filter = try allocator.dupe(u8, ""),
        .data = .{ .files = files },
        .collapsed_dirs = std.BufSet.init(allocator),
    };
}

fn deinitTestApp(app: *App) void {
    app.allocator.free(app.diff);
    app.allocator.free(app.message);
    app.allocator.free(app.file_filter);
    app.allocator.free(app.op_command);
    app.allocator.free(app.op_summary);
    app.allocator.free(app.op_output);
    if (app.clipboard_request) |c| app.allocator.free(c);
    if (app.diff_base) |b| app.allocator.free(b);
    if (app.patch_source) |s| app.allocator.free(s);
    for (app.patch_paths.items) |p| app.allocator.free(p);
    app.patch_paths.deinit(app.allocator);
    app.commit_buffer.deinit(app.allocator);
    app.commit_body_buffer.deinit(app.allocator);
    app.file_filter_buffer.deinit(app.allocator);
    for (app.filter_history.items) |entry| app.allocator.free(entry);
    app.filter_history.deinit(app.allocator);
    for (app.copied_commits.items) |entry| app.allocator.free(entry);
    app.copied_commits.deinit(app.allocator);
    if (app.marked_base) |b| app.allocator.free(b);
    app.input_buffer.deinit(app.allocator);
    if (app.staging) |*parsed| parsed.deinit(app.allocator);
    app.allocator.free(app.staging_diff);
    app.allocator.free(app.staging_path);
    app.allocator.free(app.tree_rows);
    app.preview_cache.deinit(app.allocator);
    app.allocator.free(app.preview_desired_key);
    app.allocator.free(app.preview_inflight_key);
    if (app.preview_wanted) |job| job.deinit(page_alloc);
    if (app.mutation_requested) |job| job.deinit(page_alloc);
    page_alloc.free(app.mutation_msg);
    app.collapsed_dirs.deinit();
}

test "discard menu offers the unstaged option only when a file has both" {
    const allocator = std.testing.allocator;

    var both = [_]model.FileStatus{.{
        .path = @constCast("src/main.zig"),
        .short_status = .{ 'M', 'M' },
        .has_staged = true,
        .has_unstaged = true,
        .tracked = true,
        .added = false,
        .deleted = false,
        .conflict = false,
    }};
    var app = try testApp(allocator, &both);
    defer deinitTestApp(&app);

    try app.startDiscardMenu();
    try std.testing.expectEqual(Mode.menu, app.mode);
    try std.testing.expectEqual(@as(usize, 2), app.active_menu.?.items.len);
    try std.testing.expectEqual(MenuAction.discard_file_unstaged, app.active_menu.?.items[1].action);

    var unstaged_only = [_]model.FileStatus{.{
        .path = @constCast("src/main.zig"),
        .short_status = .{ ' ', 'M' },
        .has_staged = false,
        .has_unstaged = true,
        .tracked = true,
        .added = false,
        .deleted = false,
        .conflict = false,
    }};
    var app2 = try testApp(allocator, &unstaged_only);
    defer deinitTestApp(&app2);

    try app2.startDiscardMenu();
    try std.testing.expectEqual(@as(usize, 1), app2.active_menu.?.items.len);
    try std.testing.expectEqual(MenuAction.discard_file_all, app2.active_menu.?.items[0].action);
}

test "commits panel tab selects between the commits and reflog lists" {
    const allocator = std.testing.allocator;

    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{.{
        .hash = @constCast("1111111111111111111111111111111111111111"),
        .short_hash = @constCast("1111111"),
        .author = @constCast("Sam"),
        .time = @constCast("now"),
        .refs = @constCast(""),
        .subject = @constCast("a real commit"),
    }};
    var reflog = [_]model.Commit{.{
        .hash = @constCast("2222222222222222222222222222222222222222"),
        .short_hash = @constCast("2222222"),
        .author = @constCast("Sam"),
        .time = @constCast("now"),
        .refs = @constCast("HEAD@{0}"),
        .subject = @constCast("commit: a reflog entry"),
    }};
    app.data.commits = &commits;
    app.data.reflog = &reflog;

    try std.testing.expectEqual(CommitsTab.commits, app.commits_tab);
    try std.testing.expectEqualStrings("1111111", app.selectedCommit().?.short_hash);

    app.commits_tab = .reflog;
    try std.testing.expectEqualStrings("2222222", app.selectedCommit().?.short_hash);
    try std.testing.expectEqualStrings("HEAD@{0}", app.selectedCommit().?.refs);
}

test "commit file drill-down tracks selection and deactivates cleanly" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var files = try allocator.alloc(model.CommitFile, 2);
    files[0] = .{ .status = 'M', .path = try allocator.dupe(u8, "src/a.zig") };
    files[1] = .{ .status = 'A', .path = try allocator.dupe(u8, "src/b.zig") };
    app.commit_files = files;
    app.commit_files_active = true;
    app.commit_file_index = 1;

    try std.testing.expectEqualStrings("src/b.zig", app.selectedCommitFile().?.path);

    app.deactivateCommitFiles();
    try std.testing.expect(!app.commit_files_active);
    try std.testing.expectEqual(@as(usize, 0), app.commit_files.len);
    try std.testing.expect(app.selectedCommitFile() == null);
}

test "commit reset menu opens on the commits tab and refuses reflog" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var commits = [_]model.Commit{.{
        .hash = @constCast("1111111111111111111111111111111111111111"),
        .short_hash = @constCast("1111111"),
        .author = @constCast("Sam"),
        .time = @constCast("now"),
        .refs = @constCast(""),
        .subject = @constCast("a real commit"),
    }};
    app.data.commits = &commits;

    try app.startCommitResetMenu();
    try std.testing.expectEqual(Mode.menu, app.mode);
    try std.testing.expectEqual(@as(usize, 3), app.active_menu.?.items.len);
    try std.testing.expectEqual(MenuAction.reset_hard, app.active_menu.?.items[2].action);

    app.closeMenu();
    app.commits_tab = .reflog;
    try app.startCommitResetMenu();
    try std.testing.expectEqual(Mode.normal, app.mode);
}

test "rebase todo ordering for drop, squash, and move" {
    const allocator = std.testing.allocator;
    const mk = struct {
        fn c(hash: []const u8) model.Commit {
            return .{
                .hash = @constCast(hash),
                .short_hash = @constCast(hash[0..3]),
                .author = @constCast("Sam"),
                .time = @constCast("now"),
                .refs = @constCast(""),
                .subject = @constCast("s"),
            };
        }
    }.c;
    // Newest-first: A(0), B(1), C(2).
    var commits = [_]model.Commit{ mk("aaa"), mk("bbb"), mk("ccc") };

    const Case = struct { i: usize, action: RebaseAction, want: []const u8 };
    const cases = [_]Case{
        .{ .i = 1, .action = .drop, .want = "drop bbb\npick aaa\n" },
        .{ .i = 0, .action = .squash, .want = "pick bbb\nsquash aaa\n" },
        .{ .i = 0, .action = .fixup, .want = "pick bbb\nfixup aaa\n" },
        .{ .i = 0, .action = .move_down, .want = "pick aaa\npick bbb\n" },
        .{ .i = 1, .action = .move_up, .want = "pick aaa\npick bbb\n" },
        .{ .i = 1, .action = .reword, .want = "reword bbb\npick aaa\n" },
    };
    for (cases) |case| {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        try App.writeRebaseTodo(&aw.writer, &commits, case.i, case.action);
        const got = try aw.toOwnedSlice();
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "branch delete menu refuses the current branch and non-local tabs" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var branches = [_]model.Branch{
        .{ .name = @constCast("main"), .current = true },
        .{ .name = @constCast("feature"), .current = false },
    };
    app.data.branches = &branches;

    // The checked-out branch cannot be deleted.
    app.branch_index = 0;
    try app.startBranchDeleteMenu();
    try std.testing.expectEqual(Mode.normal, app.mode);

    // A non-current local branch opens the delete menu with both options.
    app.branch_index = 1;
    try app.startBranchDeleteMenu();
    try std.testing.expectEqual(Mode.menu, app.mode);
    try std.testing.expectEqual(@as(usize, 2), app.active_menu.?.items.len);
    try std.testing.expectEqual(MenuAction.force_delete_branch, app.active_menu.?.items[1].action);

    // Branch actions are unavailable on the Remotes/Tags tabs.
    app.closeMenu();
    app.branches_tab = .remotes;
    try app.startBranchDeleteMenu();
    try std.testing.expectEqual(Mode.normal, app.mode);
}

test "staging cursor navigation clamps, ranges, and tears down cleanly" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    // Header lines 0-3, "@@" at line 4, body lines 5-8.
    const diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,4 +1,5 @@\n a\n+X\n b\n c\n";
    app.staging_diff = try allocator.dupe(u8, diff);
    app.staging = try diff_mod.parse(allocator, app.staging_diff);
    app.staging_path = try allocator.dupe(u8, "f");
    app.staging_active = true;
    app.staging_cursor = app.stagingFirstLine();

    // Cursor starts on the @@ line (line 3) and cannot move above it.
    try std.testing.expectEqual(@as(usize, 3), app.staging_cursor);
    app.moveStagingCursor(-1);
    try std.testing.expectEqual(@as(usize, 3), app.staging_cursor);

    // The cursor's hunk is found for body lines.
    app.moveStagingCursor(1);
    try std.testing.expectEqual(@as(usize, 4), app.staging_cursor);
    try std.testing.expectEqual(@as(?usize, 0), app.stagingHunkAt(app.staging_cursor));

    // Range toggle anchors and clears.
    app.toggleStagingRange();
    try std.testing.expectEqual(@as(?usize, 4), app.staging_anchor);
    app.toggleStagingRange();
    try std.testing.expect(app.staging_anchor == null);

    app.clearStaging();
    try std.testing.expect(!app.staging_active);
    try std.testing.expect(app.staging == null);
    try std.testing.expectEqual(@as(usize, 0), app.staging_diff.len);
}

test "file tree builds rows, selects files, and collapses directories" {
    const allocator = std.testing.allocator;

    const mk = struct {
        fn f(path: []const u8) model.FileStatus {
            return .{
                .path = @constCast(path),
                .short_status = .{ ' ', 'M' },
                .has_staged = false,
                .has_unstaged = true,
                .tracked = true,
                .added = false,
                .deleted = false,
                .conflict = false,
            };
        }
    }.f;
    var files = [_]model.FileStatus{ mk("README.md"), mk("src/app.zig"), mk("src/sub/a.zig") };
    var app = try testApp(allocator, &files);
    defer deinitTestApp(&app);

    app.tree_view = true;
    try app.rebuildTree(null);
    // README.md, src/, src/app.zig, src/sub/, src/sub/a.zig
    try std.testing.expectEqual(@as(usize, 5), app.tree_rows.len);

    app.tree_cursor = 1; // the "src" directory row
    try std.testing.expect(app.treeSelectedRow().?.is_dir);
    try std.testing.expect(app.selectedFile() == null);

    app.tree_cursor = 2; // src/app.zig
    try std.testing.expectEqualStrings("src/app.zig", app.selectedFile().?.path);

    try app.collapsed_dirs.insert("src");
    try app.rebuildTree(null);
    try std.testing.expectEqual(@as(usize, 2), app.tree_rows.len); // README.md, src/ (collapsed)
    try std.testing.expect(app.tree_rows[1].collapsed);

    app.tree_cursor = 0;
    app.moveTreeCursor(-1);
    try std.testing.expectEqual(@as(usize, 0), app.tree_cursor);
    app.moveTreeCursor(1);
    try std.testing.expectEqual(@as(usize, 1), app.tree_cursor);
    app.moveTreeCursor(1); // clamps at the last row
    try std.testing.expectEqual(@as(usize, 1), app.tree_cursor);
}

test "rename prompt prefills the selected branch name" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    var branches = [_]model.Branch{
        .{ .name = @constCast("main"), .current = true },
        .{ .name = @constCast("feature"), .current = false },
    };
    app.data.branches = &branches;
    app.focus = .branches;
    app.branch_index = 1;

    try app.startTextPrompt(.rename_branch);
    try std.testing.expectEqual(Mode.text_prompt, app.mode);
    try std.testing.expectEqual(TextPromptKind.rename_branch, app.text_prompt_kind.?);
    try std.testing.expectEqualStrings("feature", app.input_buffer.items);

    // Rename is unavailable on the Remotes/Tags tabs.
    app.cancelTextPrompt("x");
    app.branches_tab = .tags;
    try app.startTextPrompt(.rename_branch);
    try std.testing.expectEqual(Mode.normal, app.mode);
}

test "new branch prompt opens on the local branches tab" {
    const allocator = std.testing.allocator;
    var no_files = [_]model.FileStatus{};
    var app = try testApp(allocator, &no_files);
    defer deinitTestApp(&app);

    app.branches_tab = .tags;
    try app.startTextPrompt(.new_branch);

    try std.testing.expectEqual(Mode.text_prompt, app.mode);
    try std.testing.expectEqual(TextPromptKind.new_branch, app.text_prompt_kind.?);
    try std.testing.expectEqual(model.Focus.branches, app.focus);
    try std.testing.expectEqual(BranchesTab.local, app.branches_tab);
}
