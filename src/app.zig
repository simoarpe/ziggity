const std = @import("std");
const vaxis = @import("vaxis");

const actions = @import("actions.zig");
const config_mod = @import("config.zig");
const diff_mod = @import("diff.zig");
const filetree = @import("filetree.zig");
const git_mod = @import("git.zig");
const model = @import("model.zig");

pub const Mode = enum {
    normal,
    commit_prompt,
    file_filter_prompt,
    status_filter_menu,
    menu,
    text_prompt,
    confirmation,
    command_log,
};

/// A reusable single-line text-input popup. Each kind knows its title and what
/// to do with the submitted text.
pub const TextPromptKind = enum {
    new_branch,
    rename_branch,
    new_tag,

    pub fn title(self: TextPromptKind) []const u8 {
        return switch (self) {
            .new_branch => "New branch name",
            .rename_branch => "Rename branch",
            .new_tag => "New tag name",
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

/// Order of entries shown in the status-filter menu popup.
pub const status_filter_options = [_]model.FileDisplayFilter{
    .all,
    .staged,
    .unstaged,
    .tracked,
    .untracked,
    .conflicted,
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
    branches_tab: BranchesTab = .local,
    commits_tab: CommitsTab = .commits,
    main_scroll: usize = 0,
    file_display_filter: model.FileDisplayFilter = .all,
    diff: []u8 = &.{},
    message: []u8 = &.{},
    file_filter: []u8 = &.{},
    commit_buffer: std.ArrayList(u8) = .empty,
    file_filter_buffer: std.ArrayList(u8) = .empty,
    input_buffer: std.ArrayList(u8) = .empty,
    text_prompt_kind: ?TextPromptKind = null,
    mode: Mode = .normal,
    status_filter_index: usize = 0,
    active_menu: ?Menu = null,
    pending_confirmation: ?Confirmation = null,
    terminal_focused: bool = true,
    running: bool = true,
    /// A network op the TUI loop should start; cleared once it spawns the worker.
    async_requested: ?AsyncOp = null,
    /// True while a network op is running off-loop (single in-flight).
    async_active: bool = false,
    async_op: AsyncOp = .fetch,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
    ) !App {
        var git = try git_mod.Git.init(allocator, io);
        errdefer git.deinit();

        const cfg = try config_mod.Config.load(allocator, io, env_map, git.root);
        var app = App{
            .allocator = allocator,
            .git = git,
            .config = cfg,
        };
        app.collapsed_dirs = std.BufSet.init(allocator);
        errdefer app.deinit();

        try app.refresh();
        try app.setMessage("ready", .{});
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
        self.commit_buffer.deinit(self.allocator);
        self.file_filter_buffer.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
        self.git.deinit();
        self.* = undefined;
    }

    pub fn refresh(self: *App) !void {
        const tree_path = try self.captureTreePath();
        defer if (tree_path) |p| self.allocator.free(p);

        const next = try self.git.loadRepoData();
        self.data.deinit(self.allocator);
        self.data = next;
        self.clampSelections();
        if (self.tree_view) try self.rebuildTree(tree_path);
        if (self.commit_files_active) self.reloadCommitFilesAfterRefresh();
        self.updatePreview() catch |err| {
            try self.setMessage("preview failed: {s}", .{@errorName(err)});
        };
    }

    pub fn refreshWorkingTree(self: *App) !void {
        const selected_path = if (self.selectedFile()) |file| try self.allocator.dupe(u8, file.path) else null;
        defer if (selected_path) |path| self.allocator.free(path);
        const tree_path = try self.captureTreePath();
        defer if (tree_path) |p| self.allocator.free(p);

        var status = try self.git.loadStatusSummary();
        errdefer status.deinit(self.allocator);
        var files = try self.git.loadFiles();
        errdefer model.deinitFileStatuses(self.allocator, files);

        self.data.replaceStatus(self.allocator, status);
        status = .{};
        self.data.replaceFiles(self.allocator, files);
        files = &.{};
        self.data.state = self.git.detectState();

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
        if (self.mode == .command_log) {
            // Any key closes the command-log overlay.
            self.mode = .normal;
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
            if (cc.binding.matches(key)) return self.runCustomCommand(cc.command());
        }

        const action = actions.fromNormalKey(key, self.config.keymap, self.focus) orelse return;
        switch (action) {
            .quit => self.running = false,
            .cancel => {
                if (self.fileFilterActive()) {
                    try self.clearFileFilter();
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
            .range_select => if (self.staging_active) self.toggleStagingRange(),
            .focus_left => if (self.staging_active) try self.closeStaging() else try self.focusPrevious(),
            .focus_right => if (self.staging_active) try self.toggleStagingSide() else try self.focusNext(),
            .select => {
                if (self.staging_active) {
                    try self.applyStagingSelection();
                } else switch (self.focus) {
                    .files => try self.toggleSelectedFileStaged(),
                    .branches => try self.checkoutSelectedBranch(),
                    .stash => try self.applySelectedStash(),
                    .status, .commits, .main => {},
                }
            },
            .toggle_tree => try self.toggleTreeView(),
            .command_log => {
                self.mode = .command_log;
                try self.setMessage("command log", .{});
            },
            .conflict_menu => try self.startConflictActionsMenu(),
            .stage_all => try self.toggleAllStaged(),
            .discard_selected => try self.startDiscardMenu(),
            .discard_all => try self.startDiscardAllConfirmation(),
            .start_file_filter => try self.startFileFilterPrompt(),
            .open_status_filter => try self.startStatusFilterMenu(),
            .start_commit => try self.startCommitPrompt(),
            .new_branch => try self.startNewForBranchTab(),
            .delete_branch => try self.startDeleteForBranchTab(),
            .merge_branch => try self.startBranchConfirm(.merge_branch),
            .rebase_branch => try self.startBranchConfirm(.rebase_branch),
            .rename_branch => try self.startTextPrompt(.rename_branch),
            .fast_forward_branch => try self.fastForwardSelectedBranch(),
            .reset_commit => try self.startCommitResetMenu(),
            .revert_commit => try self.revertSelectedCommit(),
            .stash_pop => try self.popSelectedStash(),
            .stash_drop => try self.dropSelectedStash(),
            .confirm, .backspace => {},
        }
    }

    pub fn handleRefreshTick(self: *App) !void {
        if (self.mode != .normal) return;
        if (self.staging_active) return;
        if (!self.terminal_focused) return;
        self.refreshWorkingTree() catch |err| {
            try self.setMessage("auto refresh failed: {s}", .{@errorName(err)});
        };
    }

    pub fn handleFocusIn(self: *App) !void {
        self.terminal_focused = true;
        if (self.mode != .normal) return;
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
            return self.runMutation(try self.git.stagePaths(paths.items), "staged {s}/", .{dir});
        }
        return self.runMutation(try self.git.unstagePaths(paths.items), "unstaged {s}/", .{dir});
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
        if (pathMatchesFilter(file.path, self.file_filter)) return true;
        if (file.previous_path) |previous| {
            return pathMatchesFilter(previous, self.file_filter);
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
        try self.loadStaging();
        try self.setMessage("staging {s}", .{file.path});
    }

    fn loadStaging(self: *App) !void {
        if (self.staging) |*parsed| parsed.deinit(self.allocator);
        self.staging = null;
        self.allocator.free(self.staging_diff);
        self.staging_diff = &.{};

        self.staging_diff = self.git.rawFileDiff(self.staging_path, self.staging_staged_view, self.config.diff_context) catch
            try self.allocator.dupe(u8, "");
        self.staging = try diff_mod.parse(self.allocator, self.staging_diff);
        self.staging_anchor = null;
        self.staging_cursor = self.stagingFirstLine();
        self.scrollToStagingCursor();
    }

    fn toggleStagingSide(self: *App) !void {
        self.staging_staged_view = !self.staging_staged_view;
        try self.loadStaging();
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
            break :blk diff_mod.buildLinePatch(self.allocator, self.staging_diff, parsed, hunk_index, lo, hi) catch |err| switch (err) {
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
        self.refresh() catch {};
        try self.loadStaging();
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
            return self.runMutation(try self.git.stageFile(file.path), "staged {s}", .{file.path});
        }
        if (file.has_staged) {
            return self.runMutation(try self.git.unstageFile(file), "unstaged {s}", .{file.path});
        }
        try self.setMessage("file has no staged or unstaged changes", .{});
    }

    fn toggleAllStaged(self: *App) !void {
        if (self.visibleUnstagedCount() > 0) {
            if (self.anyFileFilterActive()) {
                var paths: std.ArrayList([]const u8) = .empty;
                defer paths.deinit(self.allocator);
                try self.collectVisiblePaths(&paths, .unstaged);
                return self.runMutation(try self.git.stagePaths(paths.items), "staged visible files", .{});
            }
            return self.runMutation(try self.git.stageAll(), "staged all files", .{});
        }
        if (self.visibleStagedCount() > 0) {
            if (self.anyFileFilterActive()) {
                var paths: std.ArrayList([]const u8) = .empty;
                defer paths.deinit(self.allocator);
                try self.collectVisiblePaths(&paths, .staged);
                return self.runMutation(try self.git.unstagePaths(paths.items), "unstaged visible files", .{});
            }
            return self.runMutation(try self.git.unstageAll(), "unstaged all files", .{});
        }
        try self.setMessage("no visible files to stage", .{});
    }

    fn startCommitPrompt(self: *App) !void {
        if (self.data.stagedCount() == 0) {
            try self.setMessage("stage files before committing", .{});
            return;
        }
        self.mode = .commit_prompt;
        self.commit_buffer.clearRetainingCapacity();
        try self.setMessage("enter commit message", .{});
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
        }
    }

    fn startFileFilterPrompt(self: *App) !void {
        self.focus = .files;
        self.main_scroll = 0;
        self.mode = .file_filter_prompt;
        self.file_filter_buffer.clearRetainingCapacity();
        try self.updateFileFilterFromPrompt();
        try self.setMessage("filter files", .{});
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
        self.mode = .menu;
        self.active_menu = .{ .title = self.data.state.label(), .items = &conflict_actions_menu, .index = 0 };
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
                return self.runMutation(try self.git.discardFile(file), "discarded {s}", .{file.path});
            },
            .discard_file_unstaged => {
                const file = self.selectedFile() orelse {
                    try self.setMessage("no file selected", .{});
                    return;
                };
                return self.runMutation(try self.git.discardUnstaged(file), "discarded unstaged changes in {s}", .{file.path});
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
                return self.runMutation(try self.git.resolveConflict(file.path, theirs), "resolved {s}", .{file.path});
            },
            .conflict_continue => switch (self.data.state) {
                .merging => return self.runMutation(try self.git.mergeContinue(), "merge continued", .{}),
                .rebasing => return self.runMutation(try self.git.rebaseContinue(), "rebase continued", .{}),
                .clean => try self.setMessage("nothing to continue", .{}),
            },
            .conflict_abort => switch (self.data.state) {
                .merging => return self.runMutation(try self.git.mergeAbort(), "merge aborted", .{}),
                .rebasing => return self.runMutation(try self.git.rebaseAbort(), "rebase aborted", .{}),
                .clean => try self.setMessage("nothing to abort", .{}),
            },
        }
    }

    fn startDiscardAllConfirmation(self: *App) !void {
        if (self.data.files.len == 0) {
            try self.setMessage("no files to discard", .{});
            return;
        }
        self.mode = .confirmation;
        self.pending_confirmation = .discard_all;
        try self.setMessage("confirm discard all changes", .{});
    }

    /// `n` in the Branches panel creates a branch, or a tag on the Tags tab.
    fn startNewForBranchTab(self: *App) !void {
        if (self.branches_tab == .tags) return self.startTextPrompt(.new_tag);
        return self.startTextPrompt(.new_branch);
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
                self.mode = .confirmation;
                self.pending_confirmation = .delete_tag;
                try self.setMessage("confirm delete tag {s}", .{tag.name});
            },
            .remotes => {
                const branch = self.selectedRemoteBranch() orelse {
                    try self.setMessage("no remote branch selected", .{});
                    return;
                };
                self.mode = .confirmation;
                self.pending_confirmation = .delete_remote_branch;
                try self.setMessage("confirm delete remote {s}", .{branch.name});
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
                self.mode = .confirmation;
                self.pending_confirmation = .remove_worktree;
                try self.setMessage("confirm remove worktree {s}", .{wt.path});
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
        self.mode = .confirmation;
        self.pending_confirmation = kind;
        try self.setMessage("confirm action on {s}", .{branch.name});
    }

    fn fastForwardSelectedBranch(self: *App) !void {
        const branch = try self.localBranchForAction() orelse return;
        const upstream = branch.upstream orelse {
            try self.setMessage("{s} has no upstream to fast-forward", .{branch.name});
            return;
        };
        if (branch.current) {
            return self.runMutation(try self.git.fastForwardCurrent(), "fast-forwarded {s}", .{branch.name});
        }
        const slash = std.mem.indexOfScalar(u8, upstream, '/') orelse {
            try self.setMessage("cannot parse upstream {s}", .{upstream});
            return;
        };
        const remote = upstream[0..slash];
        const remote_ref = upstream[slash + 1 ..];
        return self.runMutation(try self.git.fastForwardBranch(remote, remote_ref, branch.name), "fast-forwarded {s}", .{branch.name});
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
                const local_name = localNameForRemote(branch.name);
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
            try self.setMessage("commit cancelled", .{});
            return;
        }
        if (self.isEnterKey(key)) {
            const message = std.mem.trim(u8, self.commit_buffer.items, " \t\r\n");
            if (message.len == 0) {
                try self.setMessage("commit message cannot be empty", .{});
                return;
            }
            self.mode = .normal;
            const result = try self.git.commit(message);
            self.commit_buffer.clearRetainingCapacity();
            return self.runMutation(result, "commit created", .{});
        }
        if (self.isBackspaceKey(key)) {
            if (self.commit_buffer.items.len > 0) self.commit_buffer.items.len -= 1;
            return;
        }
        if (key.text) |text| {
            if (!key.mods.ctrl and !key.mods.alt and text.len > 0 and text[0] >= 0x20) {
                try self.commit_buffer.appendSlice(self.allocator, text);
            }
        }
    }

    fn handleFileFilterPromptKey(self: *App, key: vaxis.Key) !void {
        if (self.isEscapeKey(key)) {
            try self.clearFileFilter();
            return;
        }
        if (self.isEnterKey(key)) {
            const filter = std.mem.trim(u8, self.file_filter_buffer.items, " \t\r\n");
            try self.applyFileFilter(filter);
            return;
        }
        if (self.isBackspaceKey(key)) {
            if (self.file_filter_buffer.items.len > 0) self.file_filter_buffer.items.len -= 1;
            try self.updateFileFilterFromPrompt();
            return;
        }
        if (key.text) |text| {
            if (!key.mods.ctrl and !key.mods.alt and text.len > 0 and text[0] >= 0x20) {
                try self.file_filter_buffer.appendSlice(self.allocator, text);
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
            .discard_all => return self.runMutation(try self.git.discardAll(), "discarded all changes", .{}),
            .merge_branch => {
                const branch = self.selectedBranch() orelse {
                    try self.setMessage("no branch selected", .{});
                    return;
                };
                return self.runMutation(try self.git.mergeBranch(branch.name), "merged {s}", .{branch.name});
            },
            .rebase_branch => {
                const branch = self.selectedBranch() orelse {
                    try self.setMessage("no branch selected", .{});
                    return;
                };
                return self.runMutation(try self.git.rebaseOnto(branch.name), "rebased onto {s}", .{branch.name});
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
        }
    }

    /// The panel whose selection drives the main-panel content. When the main
    /// panel is focused we keep showing the side panel we descended from.
    fn contentFocus(self: *const App) model.Focus {
        return if (self.focus == .main) self.main_origin else self.focus;
    }

    fn updatePreview(self: *App) !void {
        // While staging, the main panel renders the raw staging diff instead of
        // self.diff, so there is nothing to recompute here.
        if (self.staging_active) return;
        self.allocator.free(self.diff);
        self.diff = switch (self.contentFocus()) {
            .status => try self.statusPreview(),
            .files, .main => blk: {
                if (self.tree_view) {
                    if (self.treeSelectedRow()) |row| {
                        if (row.is_dir) break :blk try std.fmt.allocPrint(self.allocator, "Directory {s}/\n\nSelect a file to view its diff.\n", .{row.path});
                    }
                }
                if (self.selectedFile()) |file| break :blk try self.git.diffForFile(file, self.config.diff_context);
                if (self.anyFileFilterActive() and self.data.files.len > 0) break :blk try self.allocator.dupe(u8, "No files match the active filter.\n");
                break :blk try self.allocator.dupe(u8, "Working tree clean.\n");
            },
            .branches => blk: {
                if (self.branches_tab == .worktrees) {
                    if (self.selectedWorktree()) |wt| {
                        break :blk try std.fmt.allocPrint(self.allocator, "Worktree{s}\nPath:   {s}\nBranch: {s}\n", .{ if (wt.is_current) " (current)" else "", wt.path, wt.branch });
                    }
                    break :blk try self.allocator.dupe(u8, "No worktrees.\n");
                }
                if (self.branches_tab == .submodules) {
                    if (self.selectedSubmodule()) |sm| {
                        break :blk try std.fmt.allocPrint(self.allocator, "Submodule ({s})\nPath: {s}\nSHA:  {s}\n\nspace to init/update.\n", .{ sm.stateLabel(), sm.path, sm.sha });
                    }
                    break :blk try self.allocator.dupe(u8, "No submodules.\n");
                }
                if (self.selectedBranchRefName()) |name| break :blk try self.git.showBranch(name);
                break :blk try self.allocator.dupe(u8, "Nothing to show in this tab.\n");
            },
            .commits => blk: {
                const commit = self.selectedCommit() orelse break :blk try self.allocator.dupe(u8, "No commits found.\n");
                if (self.commit_files_active) {
                    if (self.selectedCommitFile()) |file| break :blk try self.git.diffForCommitFile(commit.hash, file.path, self.config.diff_context);
                    break :blk try self.allocator.dupe(u8, "This commit changed no files.\n");
                }
                break :blk try self.git.showCommit(commit.hash, self.config.diff_context);
            },
            .stash => blk: {
                if (self.selectedStash()) |entry| break :blk try self.git.showStash(entry.index, self.config.diff_context);
                break :blk try self.allocator.dupe(u8, "No stash entries.\n");
            },
        };
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
                try self.setMessage("{s} complete", .{op.label()});
            } else {
                const stderr = std.mem.trim(u8, mutable.stderr, " \t\r\n");
                if (stderr.len > 0) {
                    try self.setMessage("{s}", .{stderr});
                } else {
                    try self.setMessage("{s} failed", .{op.label()});
                }
            }
        } else {
            try self.setMessage("{s} failed to start", .{op.label()});
        }
        self.refresh() catch {};
    }

    fn runMutation(self: *App, result: git_mod.ExecResult, comptime success_fmt: []const u8, args: anytype) !void {
        var mutable = result;
        defer mutable.deinit(self.allocator);
        if (mutable.ok()) {
            try self.setMessage(success_fmt, args);
            self.refresh() catch |err| {
                try self.setMessage("git command succeeded; refresh failed: {s}", .{@errorName(err)});
            };
            return;
        }
        const stderr = std.mem.trim(u8, mutable.stderr, " \t\r\n");
        if (stderr.len > 0) {
            try self.setMessage("{s}", .{stderr});
        } else {
            try self.setMessage("git command failed", .{});
        }
        self.refresh() catch {};
    }

    fn runCustomCommand(self: *App, command: []const u8) !void {
        var result = try self.git.runShell(command);
        defer result.deinit(self.allocator);
        if (result.ok()) {
            try self.setMessage("ran: {s}", .{command});
        } else {
            const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
            if (stderr.len > 0) {
                try self.setMessage("{s}", .{stderr});
            } else {
                try self.setMessage("command failed: {s}", .{command});
            }
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

/// Strip the remote prefix from a remote-tracking branch name so git's DWIM
/// checkout can create a local tracking branch: "origin/feature" -> "feature".
pub fn localNameForRemote(remote_name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, remote_name, '/')) |slash| {
        return remote_name[slash + 1 ..];
    }
    return remote_name;
}

pub fn pathMatchesFilter(path: []const u8, filter: []const u8) bool {
    var terms = std.mem.tokenizeAny(u8, filter, " \t\r\n");
    while (terms.next()) |term| {
        if (!caseAwareContains(path, term)) return false;
    }
    return true;
}

fn caseAwareContains(haystack: []const u8, needle: []const u8) bool {
    if (containsAsciiUppercase(needle)) {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }
    return containsIgnoreCaseAscii(haystack, needle);
}

fn containsAsciiUppercase(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 'A' and byte <= 'Z') return true;
    }
    return false;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

test "action enum is referenced" {
    try std.testing.expect(actions.Action.quit == .quit);
}

test "path filter follows lazygit substring matching" {
    try std.testing.expect(pathMatchesFilter("src/App.zig", "app"));
    try std.testing.expect(pathMatchesFilter("src/App.zig", "App"));
    try std.testing.expect(!pathMatchesFilter("src/App.zig", "APP"));
    try std.testing.expect(pathMatchesFilter("README.md", "read"));
    try std.testing.expect(pathMatchesFilter("integration-testing", "int test"));
    try std.testing.expect(pathMatchesFilter("integration-testing", "test int"));
    try std.testing.expect(!pathMatchesFilter("integration-testing", "int missing"));
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "model"));
    try std.testing.expect(pathMatchesFilter("src/main.zig", ""));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "  \t  "));
}

test "local name for remote strips the remote prefix" {
    try std.testing.expectEqualStrings("feature", localNameForRemote("origin/feature"));
    try std.testing.expectEqualStrings("feat/x", localNameForRemote("origin/feat/x"));
    try std.testing.expectEqualStrings("solo", localNameForRemote("solo"));
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
    app.commit_buffer.deinit(app.allocator);
    app.file_filter_buffer.deinit(app.allocator);
    app.input_buffer.deinit(app.allocator);
    if (app.staging) |*parsed| parsed.deinit(app.allocator);
    app.allocator.free(app.staging_diff);
    app.allocator.free(app.staging_path);
    app.allocator.free(app.tree_rows);
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
