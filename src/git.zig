const std = @import("std");
const builtin = @import("builtin");
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

/// On a transient lock error, retry up to `lock_retry_count` times with an
/// exponential backoff: the wait starts at `lock_retry_base_ms` and doubles each
/// attempt, capped at `lock_retry_cap_ms`. A big repo's index write can hold the
/// lock for a few hundred ms, so the old flat 5×50ms (250ms) budget ran out and
/// surfaced the error; this gives ~1.1s total, which absorbs realistic
/// contention while still failing on a genuinely stuck lock.
const lock_retry_count = 8;
const lock_retry_base_ms: i64 = 25;
const lock_retry_cap_ms: i64 = 250;

/// True when git's output indicates a transient lock error worth retrying —
/// another git process (a background refresh, or one the user ran elsewhere)
/// briefly held `.git/index.lock` or a ref lock.
pub fn isRetryableLockError(text: []const u8) bool {
    // `index.lock` (rather than `.git/index.lock`) so linked-worktree paths
    // (`.git/worktrees/<name>/index.lock`) and the bare message both match.
    return std.mem.indexOf(u8, text, "index.lock") != null or
        std.mem.indexOf(u8, text, "cannot lock ref") != null;
}

/// Run a process like `std.process.run`, but retry briefly on a transient git
/// lock error instead of surfacing it. Returns the last result either way; the
/// returned stdout/stderr are owned by `allocator`. Used for every git command
/// so a momentary lock never reaches the user as a hard failure.
pub fn runWithLockRetry(allocator: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    var attempt: usize = 1;
    var wait_ms: i64 = lock_retry_base_ms;
    while (true) : (attempt += 1) {
        const result = try std.process.run(allocator, io, options);
        const failed = switch (result.term) {
            .exited => |code| code != 0,
            else => true,
        };
        if (!failed or attempt >= lock_retry_count or
            !(isRetryableLockError(result.stderr) or isRetryableLockError(result.stdout)))
        {
            return result;
        }
        // Transient lock: discard this attempt's output, wait, and retry with an
        // exponential backoff (capped) so a slower competing write is waited out.
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(wait_ms), .awake) catch {};
        wait_ms = @min(wait_ms * 2, lock_retry_cap_ms);
    }
}

pub const Git = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    root: []u8,
    /// Absolute path to the git directory (`.git`), for storing side files like
    /// the pending-commit draft. Empty on throwaway worker `Git`s that don't need it.
    git_dir: []u8 = &.{},
    /// Ring of recently-run mutating commands, for the command-log view.
    command_log: std.ArrayList([]u8) = .empty,
    // Active filters for the Commits list, applied on every load. Owned.
    log_grep: ?[]u8 = null,
    log_author: ?[]u8 = null,
    log_path: ?[]u8 = null,
    /// How `loadBranches` orders the local branch list.
    branch_sort: model.BranchSortOrder = .date,
    /// Which untracked files `git status` lists. Mirrors git's own
    /// `status.showUntrackedFiles` config (resolved in `init`); `all` is git's —
    /// and our — default, but a large repo can set `normal`/`no` to make status
    /// far cheaper.
    untracked_files: UntrackedFiles = .all,

    pub const LogFilter = enum { grep, author, path };

    pub const UntrackedFiles = enum {
        all,
        normal,
        no,

        pub fn flag(self: UntrackedFiles) []const u8 {
            return switch (self) {
                .all => "--untracked-files=all",
                .normal => "--untracked-files=normal",
                .no => "--untracked-files=no",
            };
        }
    };

    const command_log_cap = 200;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) !Git {
        return initAt(allocator, io, environ, ".");
    }

    /// Like `init`, but discovers the repository containing `cwd` (used to
    /// re-root the app onto a worktree or submodule directory).
    pub fn initAt(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, cwd: []const u8) !Git {
        // One call yields both the worktree root and the absolute `.git` dir.
        var argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel", "--absolute-git-dir" };
        const result = try std.process.run(allocator, io, .{
            .argv = &argv,
            .cwd = .{ .path = cwd },
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

        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), '\n');
        const root = try allocator.dupe(u8, std.mem.trim(u8, lines.next() orelse "", " \t\r\n"));
        errdefer allocator.free(root);
        const git_dir = try allocator.dupe(u8, std.mem.trim(u8, lines.next() orelse "", " \t\r\n"));
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .root = root,
            .git_dir = git_dir,
            .untracked_files = resolveUntrackedFiles(allocator, io, environ, root),
        };
    }

    /// Read git's `status.showUntrackedFiles` config so `git status` matches what
    /// the user configured (and so a big repo can opt into the cheaper `normal`).
    /// Unset, unrecognized, or any error falls back to `all` — git's default.
    fn resolveUntrackedFiles(allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map, root: []const u8) UntrackedFiles {
        var argv = [_][]const u8{ "git", "config", "--get", "status.showUntrackedFiles" };
        const result = std.process.run(allocator, io, .{
            .argv = &argv,
            .cwd = .{ .path = root },
            .environ_map = environ,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch return .all;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const value = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (std.mem.eql(u8, value, "no")) return .no;
        if (std.mem.eql(u8, value, "normal")) return .normal;
        // "all", "yes" (git's alias for the default), unset, or anything else.
        return .all;
    }

    pub fn deinit(self: *Git) void {
        self.allocator.free(self.root);
        self.allocator.free(self.git_dir);
        for (self.command_log.items) |entry| self.allocator.free(entry);
        self.command_log.deinit(self.allocator);
        self.clearLogFilters();
        self.* = undefined;
    }

    fn logFilterSlot(self: *Git, which: LogFilter) *?[]u8 {
        return switch (which) {
            .grep => &self.log_grep,
            .author => &self.log_author,
            .path => &self.log_path,
        };
    }

    /// Set one Commits-list filter (replacing any prior value for it). The next
    /// load applies it. An empty value clears that filter.
    pub fn setLogFilter(self: *Git, which: LogFilter, value: []const u8) !void {
        const slot = self.logFilterSlot(which);
        if (slot.*) |old| self.allocator.free(old);
        slot.* = if (value.len == 0) null else try self.allocator.dupe(u8, value);
    }

    pub fn clearLogFilters(self: *Git) void {
        inline for (.{ &self.log_grep, &self.log_author, &self.log_path }) |slot| {
            if (slot.*) |old| self.allocator.free(old);
            slot.* = null;
        }
    }

    pub fn hasLogFilter(self: *const Git) bool {
        return self.log_grep != null or self.log_author != null or self.log_path != null;
    }

    /// Read-only invocations ziggity issues during loads/refreshes; these are
    /// kept out of the command log so the auto-refresh does not flood it.
    fn isReadOnly(args: []const []const u8) bool {
        if (args.len == 0) return true;
        const reads = [_][]const u8{ "status", "diff", "diff-tree", "log", "show", "rev-parse", "rev-list", "for-each-ref", "ls-files", "reflog", "cat-file" };
        for (reads) |r| if (std.mem.eql(u8, args[0], r)) return true;
        if (args.len >= 2) {
            const second = args[1];
            const long_flag = std.mem.startsWith(u8, second, "--") and second.len > 2;
            if (std.mem.eql(u8, args[0], "branch") and long_flag) return true;
            if (std.mem.eql(u8, args[0], "tag") and long_flag) return true;
            if (std.mem.eql(u8, args[0], "stash") and std.mem.eql(u8, second, "list")) return true;
        }
        return false;
    }

    /// Record a command run outside `exec` (e.g. an async network op) in the log.
    pub fn recordExternal(self: *Git, args: []const []const u8) void {
        self.recordCommand(args);
    }

    /// Append a verbatim command line to the log (e.g. a slow mutation run on a
    /// worker, whose own Git's log is discarded). Cap-aware, best-effort.
    pub fn recordRaw(self: *Git, line: []const u8) void {
        const entry = self.allocator.dupe(u8, line) catch return;
        if (self.command_log.items.len >= command_log_cap) {
            self.allocator.free(self.command_log.orderedRemove(0));
        }
        self.command_log.append(self.allocator, entry) catch self.allocator.free(entry);
    }

    fn recordCommand(self: *Git, args: []const []const u8) void {
        if (isReadOnly(args)) return;
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        buf.writer.writeAll("git") catch return;
        for (args) |arg| {
            buf.writer.writeByte(' ') catch return;
            buf.writer.writeAll(arg) catch return;
        }
        const entry = buf.toOwnedSlice() catch return;
        if (self.command_log.items.len >= command_log_cap) {
            self.allocator.free(self.command_log.orderedRemove(0));
        }
        self.command_log.append(self.allocator, entry) catch self.allocator.free(entry);
    }

    /// Run an arbitrary shell command in the repository root (for user-defined
    /// custom commands). Recorded in the command log.
    pub fn runShell(self: *Git, command: []const u8) !ExecResult {
        const entry = std.fmt.allocPrint(self.allocator, "$ {s}", .{command}) catch null;
        if (entry) |e| {
            if (self.command_log.items.len >= command_log_cap) {
                self.allocator.free(self.command_log.orderedRemove(0));
            }
            self.command_log.append(self.allocator, e) catch self.allocator.free(e);
        }
        const result = try runWithLockRetry(self.allocator, self.io, .{
            .argv = &.{ "sh", "-c", command },
            .cwd = .{ .path = self.root },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
    }

    pub fn exec(self: *Git, args: []const []const u8) !ExecResult {
        self.recordCommand(args);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, "git");
        // `--no-optional-locks` as an explicit global flag (belt-and-suspenders
        // with GIT_OPTIONAL_LOCKS=0 in the env): the frequent read-only commands,
        // above all the background `git status`, must never take `.git/index.lock`
        // to refresh the on-disk index/untracked-cache/fsmonitor extension —
        // otherwise they collide with a concurrent `git add` and surface a
        // spurious "unable to create '.git/index.lock': File exists". The flag is
        // honored even when the env var isn't (e.g. an fsmonitor daemon). It's a
        // no-op for write commands, which take the required index lock regardless.
        // Recorded command log keeps the logical args only (see `recordCommand`).
        try argv.append(self.allocator, "--no-optional-locks");
        try argv.appendSlice(self.allocator, args);

        const result = try runWithLockRetry(self.allocator, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.root },
            // Also keep the env (GIT_TERMINAL_PROMPT=0, GIT_OPTIONAL_LOCKS=0).
            .environ_map = self.environ,
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

    /// The plain unified diff for one file's unstaged (working tree vs index)
    /// or staged (index vs HEAD) changes, with no decoration — suitable for
    /// hunk parsing and re-application.
    pub fn rawFileDiff(self: *Git, path: []const u8, staged: bool, diff_context: u8) ![]u8 {
        const context_arg = try std.fmt.allocPrint(self.allocator, "--unified={d}", .{diff_context});
        defer self.allocator.free(context_arg);
        if (staged) {
            return self.output(&.{ "diff", "--staged", "--no-ext-diff", "--no-color", context_arg, "--", path });
        }
        return self.output(&.{ "diff", "--no-ext-diff", "--no-color", context_arg, "--", path });
    }

    /// The whole staged (or unstaged) diff with 3 lines of context — used to
    /// find which commit a change should be fixed up into.
    pub fn diffForFixup(self: *Git, staged: bool) ![]u8 {
        if (staged) {
            return self.output(&.{ "diff", "--staged", "--no-ext-diff", "--no-color", "--unified=3", "--" });
        }
        return self.output(&.{ "diff", "--no-ext-diff", "--no-color", "--unified=3", "--" });
    }

    /// `git blame` the old (HEAD) lines `start..end` of `file`, in porcelain form
    /// so each line's originating commit hash can be parsed.
    pub fn blameRange(self: *Git, file: []const u8, start: usize, end: usize) !ExecResult {
        const range = try std.fmt.allocPrint(self.allocator, "{d},{d}", .{ start, end });
        defer self.allocator.free(range);
        return self.exec(&.{ "blame", "-L", range, "--porcelain", "HEAD", "--", file });
    }

    /// Build `<git-dir>/<rel>` (owned). Uses the resolved git directory when
    /// known — correct inside a linked worktree, where `<root>/.git` is a
    /// gitlink *file* and the real git dir lives elsewhere — and otherwise
    /// falls back to `<root>/.git/<rel>`.
    fn gitDirPath(self: *Git, rel: []const u8) ![]u8 {
        if (self.git_dir.len > 0)
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, rel });
        return std.fmt.allocPrint(self.allocator, "{s}/.git/{s}", .{ self.root, rel });
    }

    /// Apply a patch to the index. `reverse` unstages (used on the staged
    /// side). The patch is written to a temp file under the git dir since
    /// `std.process.run` cannot feed stdin.
    pub fn applyPatch(self: *Git, patch: []const u8, reverse: bool) !ExecResult {
        const patch_path = try self.gitDirPath("ziggity-stage.patch");
        defer self.allocator.free(patch_path);
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = patch_path, .data = patch });
        defer std.Io.Dir.deleteFile(.cwd(), self.io, patch_path) catch {};
        if (reverse) {
            return self.exec(&.{ "apply", "--cached", "--reverse", "--whitespace=nowarn", "--", patch_path });
        }
        return self.exec(&.{ "apply", "--cached", "--whitespace=nowarn", "--", patch_path });
    }

    /// Write `patch` to a temp file under the git dir and return its path; the
    /// caller must delete the file and free the path.
    fn writeTempPatch(self: *Git, patch: []const u8) ![]u8 {
        const p = try self.gitDirPath("ziggity-custom.patch");
        errdefer self.allocator.free(p);
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = p, .data = patch });
        return p;
    }

    /// Apply a custom patch to the working tree (not the index). `reverse`
    /// un-applies it. Used by the custom-patch "apply to working tree" actions.
    pub fn applyCustomPatch(self: *Git, patch: []const u8, reverse: bool) !ExecResult {
        const p = try self.writeTempPatch(patch);
        defer {
            std.Io.Dir.deleteFile(.cwd(), self.io, p) catch {};
            self.allocator.free(p);
        }
        if (reverse) {
            return self.exec(&.{ "apply", "--reverse", "--whitespace=nowarn", "--", p });
        }
        return self.exec(&.{ "apply", "--whitespace=nowarn", "--", p });
    }

    /// Remove a built patch's changes from its source commit: rebase with the
    /// caller's `edit` todo to stop at the source, reverse-apply the patch to
    /// the index and tree, amend, then continue. If the patch fails to apply
    /// the rebase is aborted; a conflict on continue is left for the user.
    pub fn removePatchFromCommit(self: *Git, base_ref: []const u8, todo: []const u8, patch: []const u8) !ExecResult {
        var r1 = try self.rebaseTodo(base_ref, todo, null);
        if (!r1.ok()) return r1;
        r1.deinit(self.allocator);

        const p = try self.writeTempPatch(patch);
        defer {
            std.Io.Dir.deleteFile(.cwd(), self.io, p) catch {};
            self.allocator.free(p);
        }

        var ap = try self.exec(&.{ "apply", "--reverse", "--index", "--whitespace=nowarn", "--", p });
        if (!ap.ok()) {
            var abort = self.rebaseAbort() catch return ap;
            abort.deinit(self.allocator);
            return ap;
        }
        ap.deinit(self.allocator);

        var amend = try self.exec(&.{ "commit", "--amend", "--no-edit" });
        if (!amend.ok()) {
            var abort = self.rebaseAbort() catch return amend;
            abort.deinit(self.allocator);
            return amend;
        }
        amend.deinit(self.allocator);

        return self.rebaseContinue();
    }

    /// Run a non-interactive `git rebase -i <base_ref>` with a caller-supplied
    /// todo. The todo is written to a temp file and installed via a
    /// `sequence.editor` that copies it over git's generated todo; messages are
    /// accepted as-is (`core.editor=true`) unless `message` is given, in which
    /// case it replaces the message git would have opened (used for reword).
    pub fn rebaseTodo(self: *Git, base_ref: []const u8, todo: []const u8, message: ?[]const u8) !ExecResult {
        const todo_path = try self.gitDirPath("ziggity-rebase-todo");
        defer self.allocator.free(todo_path);
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = todo_path, .data = todo });
        defer std.Io.Dir.deleteFile(.cwd(), self.io, todo_path) catch {};

        // The sequence editor copies our todo over git's; the commit-message
        // editor accepts the default (true) or, for reword, supplies our
        // message. These must be set via env vars: `-c core.editor` does not
        // reach the reword/squash message subprocess.
        const seq_editor = try std.fmt.allocPrint(self.allocator, "cp '{s}'", .{todo_path});
        defer self.allocator.free(seq_editor);

        var msg_path: ?[]u8 = null;
        defer if (msg_path) |p| {
            std.Io.Dir.deleteFile(.cwd(), self.io, p) catch {};
            self.allocator.free(p);
        };
        const msg_editor = if (message) |msg| blk: {
            const mp = try self.gitDirPath("ziggity-rebase-msg");
            errdefer self.allocator.free(mp);
            try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = mp, .data = msg });
            // Build the editor command first; only then hand `mp` to the outer
            // `defer` by setting `msg_path`. Doing it the other way round would
            // let both this `errdefer` and the outer `defer` free `mp` if the
            // allocPrint below failed (double-free).
            const editor = try std.fmt.allocPrint(self.allocator, "cp '{s}'", .{mp});
            msg_path = mp;
            break :blk editor;
        } else try self.allocator.dupe(u8, "true");
        defer self.allocator.free(msg_editor);

        var env = try self.environ.clone(self.allocator);
        defer env.deinit();
        try env.put("GIT_SEQUENCE_EDITOR", seq_editor);
        try env.put("GIT_EDITOR", msg_editor);

        const argv = [_][]const u8{ "git", "rebase", "-i", "--autostash", base_ref };
        self.recordCommand(argv[1..]);
        const result = try runWithLockRetry(self.allocator, self.io, .{
            .argv = &argv,
            .cwd = .{ .path = self.root },
            .environ_map = &env,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
    }

    fn gitPathExists(self: *Git, rel: []const u8) bool {
        const path = self.gitDirPath(rel) catch return false;
        defer self.allocator.free(path);
        std.Io.Dir.access(.cwd(), self.io, path, .{}) catch return false;
        return true;
    }

    pub fn detectState(self: *Git) model.RepoState {
        if (self.gitPathExists("rebase-merge") or self.gitPathExists("rebase-apply")) return .rebasing;
        if (self.gitPathExists("CHERRY_PICK_HEAD")) return .cherry_picking;
        if (self.gitPathExists("MERGE_HEAD")) return .merging;
        return .clean;
    }

    pub fn isBisecting(self: *Git) bool {
        return self.gitPathExists("BISECT_LOG");
    }

    /// Resolve a conflicted file by keeping our side (or theirs), then stage it.
    pub fn resolveConflict(self: *Git, path: []const u8, take_theirs: bool) !ExecResult {
        const side = if (take_theirs) "--theirs" else "--ours";
        if (try self.runStep(&.{ "checkout", side, "--", path })) |failure| return failure;
        if (try self.runStep(&.{ "add", "--", path })) |failure| return failure;
        return self.successResult();
    }

    pub fn mergeContinue(self: *Git) !ExecResult {
        return self.exec(&.{ "commit", "--no-edit" });
    }

    pub fn mergeAbort(self: *Git) !ExecResult {
        return self.exec(&.{ "merge", "--abort" });
    }

    pub fn rebaseContinue(self: *Git) !ExecResult {
        // core.editor=true accepts the existing message without opening an editor.
        return self.exec(&.{ "-c", "core.editor=true", "rebase", "--continue" });
    }

    pub fn rebaseAbort(self: *Git) !ExecResult {
        return self.exec(&.{ "rebase", "--abort" });
    }

    /// Begin a bisect and mark `rev` as the first good/bad endpoint.
    pub fn bisectStartMark(self: *Git, good: bool, rev: []const u8) !ExecResult {
        var start = try self.exec(&.{ "bisect", "start" });
        if (!start.ok()) return start;
        start.deinit(self.allocator);
        return self.bisectMark(good, rev);
    }

    /// Mark a commit good/bad during a bisect. With no `rev` the current
    /// checkout (HEAD) is marked, which is how the search narrows.
    pub fn bisectMark(self: *Git, good: bool, rev: ?[]const u8) !ExecResult {
        const word = if (good) "good" else "bad";
        if (rev) |r| return self.exec(&.{ "bisect", word, r });
        return self.exec(&.{ "bisect", word });
    }

    pub fn bisectSkip(self: *Git) !ExecResult {
        return self.exec(&.{ "bisect", "skip" });
    }

    pub fn bisectReset(self: *Git) !ExecResult {
        return self.exec(&.{ "bisect", "reset" });
    }

    /// Amend the commit a rebase has stopped at (the `edit` step) with whatever
    /// is currently staged, keeping its message, then resume the rebase.
    pub fn amendAndContinueRebase(self: *Git) !ExecResult {
        var amend = try self.exec(&.{ "commit", "--amend", "--no-edit" });
        if (!amend.ok()) return amend;
        amend.deinit(self.allocator);
        return self.rebaseContinue();
    }

    pub fn loadStatusSummary(self: *Git) !model.StatusSummary {
        var status = model.StatusSummary{
            .current_branch = try self.currentBranch(),
        };
        errdefer status.deinit(self.allocator);

        // Resolve the upstream and whether it's gone from the branch's config
        // (`%(upstream:*)`), which is reliable even when the remote ref was
        // deleted — unlike `@{u}`, which stops resolving once the ref is gone.
        if (status.current_branch.len > 0) {
            if (self.upstreamTrack(status.current_branch)) |track| {
                status.upstream = track.upstream;
                status.upstream_gone = track.gone;
            } else |_| {}
        }
        if (status.upstream != null and !status.upstream_gone) {
            const counts = self.aheadBehind() catch null;
            if (counts) |value| {
                status.behind = value.behind;
                status.ahead = value.ahead;
            }
        }

        return status;
    }

    const UpstreamTrack = struct { upstream: ?[]u8, gone: bool };

    /// The configured upstream of `branch` and whether it's "[gone]" (deleted on
    /// the remote), read via `for-each-ref` so it works from config regardless of
    /// whether the remote-tracking ref still exists. `upstream` is owned.
    fn upstreamTrack(self: *Git, branch: []const u8) !UpstreamTrack {
        const ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(ref);
        var result = try self.exec(&.{ "for-each-ref", "--format=%(upstream:short)%00%(upstream:track)", ref });
        defer result.deinit(self.allocator);
        if (!result.ok()) return .{ .upstream = null, .gone = false };
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), 0);
        const up = it.next() orelse "";
        const track = it.next() orelse "";
        return .{
            .upstream = if (up.len > 0) try self.allocator.dupe(u8, up) else null,
            .gone = std.mem.indexOf(u8, track, "[gone]") != null,
        };
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

    /// Raw `git status --porcelain -z` bytes. Split out from `loadFiles` so a
    /// background worker can capture the (slow) git output off the UI thread and
    /// let the UI thread do the cheap parsing with its own allocator.
    pub fn statusPorcelain(self: *Git) ![]u8 {
        return self.output(&.{ "status", "--porcelain", "-z", self.untracked_files.flag(), "--find-renames=50%" });
    }

    pub fn loadFiles(self: *Git) ![]model.FileStatus {
        const output_bytes = try self.statusPorcelain();
        defer self.allocator.free(output_bytes);
        return parseStatus(self.allocator, output_bytes);
    }

    pub fn loadBranches(self: *Git) ![]model.Branch {
        // `alphabetical` sorts by ref name; `date`/`recency` start from
        // most-recent commit first. `recency` is then reordered by the reflog.
        const sort_flag: []const u8 = switch (self.branch_sort) {
            .alphabetical => "--sort=refname",
            .date, .recency => "--sort=-committerdate",
        };
        const bytes = try self.output(&.{ "branch", sort_flag, "--format=%(HEAD)%00%(refname:short)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)" });
        defer self.allocator.free(bytes);
        const list = try parseBranches(self.allocator, bytes);
        errdefer {
            for (list) |*branch| branch.deinit(self.allocator);
            self.allocator.free(list);
        }
        if (self.branch_sort == .recency) {
            if (self.loadBranchRecency()) |recency| {
                defer {
                    for (recency) |name| self.allocator.free(name);
                    self.allocator.free(recency);
                }
                applyRecencyOrder(list, recency);
            } else |_| {}
        }
        // The current branch is always listed first.
        moveCurrentBranchToFront(list);
        return list;
    }

    /// Branch names in most-recently-checked-out order, parsed from HEAD's
    /// reflog `checkout: moving from X to Y` subjects (for the `recency` order).
    pub fn loadBranchRecency(self: *Git) ![][]u8 {
        var result = try self.exec(&.{ "reflog", "-200", "--format=%gs" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc([]u8, 0);
        return parseBranchRecency(self.allocator, result.stdout);
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

    /// The configured remote names (`git remote`), one per line, independent of
    /// whether any of their branches have been fetched.
    pub fn loadRemotes(self: *Git) ![]model.Remote {
        var result = try self.exec(&.{ "remote", "-v" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Remote, 0);
        return parseRemotes(self.allocator, result.stdout);
    }

    pub fn loadTags(self: *Git) ![]model.Tag {
        var result = try self.exec(&.{ "tag", "--sort=-creatordate", "--format=%(refname:short)%00%(contents:subject)" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Tag, 0);
        return parseTags(self.allocator, result.stdout);
    }

    pub fn loadWorktrees(self: *Git) ![]model.Worktree {
        var result = try self.exec(&.{ "worktree", "list", "--porcelain" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Worktree, 0);
        return parseWorktrees(self.allocator, result.stdout, self.root);
    }

    pub fn removeWorktree(self: *Git, path: []const u8) !ExecResult {
        return self.exec(&.{ "worktree", "remove", "--", path });
    }

    /// Create a worktree at `path`. With an empty `base`, git makes a new branch
    /// (named after the path) from HEAD; otherwise it checks out `base` there.
    pub fn addWorktree(self: *Git, path: []const u8, base: []const u8) !ExecResult {
        if (base.len == 0) return self.exec(&.{ "worktree", "add", path });
        return self.exec(&.{ "worktree", "add", path, base });
    }

    pub fn loadSubmodules(self: *Git) ![]model.Submodule {
        var result = try self.exec(&.{ "submodule", "status" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Submodule, 0);
        return parseSubmodules(self.allocator, result.stdout);
    }

    pub fn updateSubmodule(self: *Git, path: []const u8) !ExecResult {
        return self.exec(&.{ "submodule", "update", "--init", "--", path });
    }

    pub fn addSubmodule(self: *Git, url: []const u8, path: []const u8) !ExecResult {
        return self.exec(&.{ "submodule", "add", "--", url, path });
    }

    /// Point the submodule at a new URL (in `.gitmodules`) and sync it into the
    /// active config.
    pub fn setSubmoduleUrl(self: *Git, path: []const u8, url: []const u8) !ExecResult {
        var r = try self.exec(&.{ "submodule", "set-url", "--", path, url });
        if (!r.ok()) return r;
        r.deinit(self.allocator);
        return self.exec(&.{ "submodule", "sync", "--", path });
    }

    /// Remove a submodule: deinit it, then `git rm` (which also drops its
    /// `.gitmodules` entry from the index).
    pub fn removeSubmodule(self: *Git, path: []const u8) !ExecResult {
        var r = try self.exec(&.{ "submodule", "deinit", "-f", "--", path });
        if (!r.ok()) return r;
        r.deinit(self.allocator);
        return self.exec(&.{ "rm", "-f", "--", path });
    }

    pub const SubmoduleBulk = enum { init_all, update_all, update_recursive, deinit_all };

    pub fn bulkSubmodule(self: *Git, op: SubmoduleBulk) !ExecResult {
        return switch (op) {
            .init_all => self.exec(&.{ "submodule", "init" }),
            .update_all => self.exec(&.{ "submodule", "update" }),
            .update_recursive => self.exec(&.{ "submodule", "update", "--init", "--recursive" }),
            .deinit_all => self.exec(&.{ "submodule", "deinit", "--all", "-f" }),
        };
    }

    pub fn loadCommits(self: *Git, ref_name: []const u8, limit: usize) ![]model.Commit {
        const limit_arg = try std.fmt.allocPrint(self.allocator, "-{d}", .{limit});
        defer self.allocator.free(limit_arg);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            "log",
            ref_name,
            "--date=relative",
            "--pretty=format:%H%x00%h%x00%an%x00%cr%x00%D%x00%s",
            "--no-show-signature",
            limit_arg,
        });

        // Optional Commits-list filters. The --grep/--author args own their
        // formatted strings until the command runs.
        var grep_arg: ?[]u8 = null;
        defer if (grep_arg) |a| self.allocator.free(a);
        if (self.log_grep) |g| {
            grep_arg = try std.fmt.allocPrint(self.allocator, "--grep={s}", .{g});
            try argv.appendSlice(self.allocator, &.{ "--regexp-ignore-case", grep_arg.? });
        }
        var author_arg: ?[]u8 = null;
        defer if (author_arg) |a| self.allocator.free(a);
        if (self.log_author) |a| {
            author_arg = try std.fmt.allocPrint(self.allocator, "--author={s}", .{a});
            try argv.append(self.allocator, author_arg.?);
        }
        // A pathspec must come last, after a `--` separator.
        if (self.log_path) |p| try argv.appendSlice(self.allocator, &.{ "--", p });

        // `git log` fails on an unborn branch (no commits yet) and on an
        // unmatched/invalid filter; treat that as an empty list rather than
        // failing the whole repo load (matches the other list loaders).
        var result = try self.exec(argv.items);
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.Commit, 0);
        return parseCommits(self.allocator, result.stdout);
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

    /// Files changed by a single commit (vs its parent, or all files for the
    /// root commit thanks to --root).
    pub fn loadCommitFiles(self: *Git, hash: []const u8) ![]model.CommitFile {
        var result = try self.exec(&.{ "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", hash });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(model.CommitFile, 0);
        return parseCommitFiles(self.allocator, result.stdout);
    }

    /// The diff a single commit introduced for one path.
    pub fn diffForCommitFile(self: *Git, hash: []const u8, path: []const u8, diff_context: u8) ![]u8 {
        const context_arg = try std.fmt.allocPrint(self.allocator, "--unified={d}", .{diff_context});
        defer self.allocator.free(context_arg);
        var result = try self.exec(&.{ "show", hash, "--no-ext-diff", "--no-color", context_arg, "--format=", "--", path });
        errdefer result.deinit(self.allocator);
        if (!result.ok()) return GitError.CommandFailed;
        self.allocator.free(result.stderr);
        return result.stdout;
    }

    /// The configured `core.editor` (or null if unset), allocated by the Git's
    /// allocator — caller frees. Used to auto-detect the file editor.
    pub fn coreEditor(self: *Git) ?[]u8 {
        var res = self.exec(&.{ "config", "--get", "core.editor" }) catch return null;
        defer res.deinit(self.allocator);
        if (!res.ok()) return null;
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        return self.allocator.dupe(u8, trimmed) catch null;
    }

    pub fn stagePaths(self: *Git, paths: []const []const u8) !ExecResult {
        if (paths.len == 0) return self.successResult();
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "add", "--" });
        try args.appendSlice(self.allocator, paths);
        return self.exec(args.items);
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

    pub fn commit(self: *Git, message: []const u8, no_verify: bool) !ExecResult {
        if (no_verify) return self.exec(&.{ "commit", "--no-verify", "-m", message });
        return self.exec(&.{ "commit", "-m", message });
    }

    /// Append `path` to the repo's `.gitignore`, creating it if absent.
    pub fn ignoreFile(self: *Git, path: []const u8) !ExecResult {
        const gi = try std.fmt.allocPrint(self.allocator, "{s}/.gitignore", .{self.root});
        defer self.allocator.free(gi);
        const existing = std.Io.Dir.readFileAlloc(.cwd(), self.io, gi, self.allocator, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => try self.allocator.dupe(u8, ""),
            else => return err,
        };
        defer self.allocator.free(existing);
        // Avoid duplicating an entry that's already there (line-exact match).
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |line| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), path)) return self.successResult();
        }
        const needs_nl = existing.len > 0 and existing[existing.len - 1] != '\n';
        const updated = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}\n", .{ existing, if (needs_nl) "\n" else "", path });
        defer self.allocator.free(updated);
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = gi, .data = updated });
        return self.successResult();
    }

    pub fn checkout(self: *Git, branch_name: []const u8) !ExecResult {
        return self.exec(&.{ "checkout", branch_name });
    }

    /// Force-checkout a branch, discarding uncommitted changes (`checkout -f`).
    pub fn forceCheckout(self: *Git, branch_name: []const u8) !ExecResult {
        return self.exec(&.{ "checkout", "-f", branch_name });
    }

    /// How many commits HEAD is ahead of the nearest main branch (main/master)
    /// — the current branch's own, not-yet-on-main commits. 0 when none / no
    /// main branch exists (e.g. you're on main itself).
    pub fn branchCommitsCount(self: *Git) !usize {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "rev-list", "--count", "HEAD", "--not" });
        var any = false;
        for ([_][]const u8{ "main", "master" }) |m| {
            var r = self.exec(&.{ "rev-parse", "--verify", "--quiet", m }) catch continue;
            const exists = r.ok();
            r.deinit(self.allocator);
            if (exists) {
                try args.append(self.allocator, m);
                any = true;
            }
        }
        if (!any) return 0;
        var res = try self.exec(args.items);
        defer res.deinit(self.allocator);
        if (!res.ok()) return 0;
        return std.fmt.parseInt(usize, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch 0;
    }

    /// Create a new branch from HEAD and switch to it.
    pub fn createBranch(self: *Git, name: []const u8) !ExecResult {
        return self.exec(&.{ "checkout", "-b", name });
    }

    pub fn deleteBranch(self: *Git, name: []const u8, force: bool) !ExecResult {
        const flag = if (force) "-D" else "-d";
        return self.exec(&.{ "branch", flag, "--", name });
    }

    /// Delete several local branches in one `git branch -d/-D -- <names...>`.
    pub fn deleteBranches(self: *Git, names: []const []const u8, force: bool) !ExecResult {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "branch", if (force) "-D" else "-d", "--" });
        try args.appendSlice(self.allocator, names);
        return self.exec(args.items);
    }

    pub fn renameBranch(self: *Git, old_name: []const u8, new_name: []const u8) !ExecResult {
        return self.exec(&.{ "branch", "-m", old_name, new_name });
    }

    /// Create a tag. A non-empty `message` makes it annotated (`-a -m`); empty
    /// makes it lightweight. `force` (`-f`) overwrites an existing tag. A
    /// non-empty `target` (a commit-ish) tags that commit; empty tags HEAD.
    pub fn createTag(self: *Git, name: []const u8, message: []const u8, force: bool, target: []const u8) !ExecResult {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "tag");
        if (force) try args.append(self.allocator, "-f");
        if (message.len > 0) try args.appendSlice(self.allocator, &.{ "-a", "-m", message });
        try args.appendSlice(self.allocator, &.{ "--", name });
        if (target.len > 0) try args.append(self.allocator, target);
        return self.exec(args.items);
    }

    pub fn deleteTag(self: *Git, name: []const u8) !ExecResult {
        return self.exec(&.{ "tag", "-d", "--", name });
    }

    /// Delete a tag on a remote: `git push <remote> --delete refs/tags/<tag>`.
    /// The `refs/tags/` prefix disambiguates from a same-named branch.
    pub fn deleteRemoteTag(self: *Git, remote: []const u8, name: []const u8) !ExecResult {
        const ref = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{name});
        defer self.allocator.free(ref);
        return self.exec(&.{ "push", remote, "--delete", ref });
    }

    pub fn deleteRemoteBranch(self: *Git, remote: []const u8, branch: []const u8) !ExecResult {
        return self.exec(&.{ "push", remote, "--delete", branch });
    }

    /// Delete several branches on one `remote` in a single push.
    pub fn deleteRemoteBranches(self: *Git, remote: []const u8, refs: []const []const u8) !ExecResult {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "push", remote, "--delete" });
        try args.appendSlice(self.allocator, refs);
        return self.exec(args.items);
    }

    /// The configured fetch URL of `remote` (e.g. `git@github.com:owner/repo`).
    pub fn remoteUrl(self: *Git, remote: []const u8) ![]u8 {
        return self.output(&.{ "remote", "get-url", remote });
    }

    pub fn addRemote(self: *Git, name: []const u8, url: []const u8) !ExecResult {
        return self.exec(&.{ "remote", "add", name, url });
    }

    pub fn renameRemote(self: *Git, old: []const u8, new: []const u8) !ExecResult {
        return self.exec(&.{ "remote", "rename", old, new });
    }

    /// Create (and check out) a new local branch `name` starting at `start`
    /// (a remote ref like "origin/main" becomes a tracking branch).
    pub fn newBranchFrom(self: *Git, name: []const u8, start: []const u8) !ExecResult {
        return self.exec(&.{ "checkout", "-b", name, start });
    }

    /// Move `original`'s commits onto a new branch `name`: create+switch to the
    /// new branch at HEAD (carrying the commits), then reset `original` back to
    /// its upstream. The caller guarantees `original` has an upstream.
    pub fn moveCommitsToNewBranch(self: *Git, name: []const u8, original: []const u8) !ExecResult {
        var r = try self.exec(&.{ "checkout", "-b", name });
        if (!r.ok()) return r;
        r.deinit(self.allocator);
        const upstream = try std.fmt.allocPrint(self.allocator, "{s}@{{u}}", .{original});
        defer self.allocator.free(upstream);
        return self.exec(&.{ "branch", "-f", original, upstream });
    }

    pub fn setRemoteUrl(self: *Git, name: []const u8, url: []const u8) !ExecResult {
        return self.exec(&.{ "remote", "set-url", name, url });
    }

    pub fn removeRemote(self: *Git, name: []const u8) !ExecResult {
        return self.exec(&.{ "remote", "remove", name });
    }

    /// Set the current branch's upstream tracking ref (e.g. `origin/main`).
    pub fn setUpstream(self: *Git, ref: []const u8) !ExecResult {
        const arg = try std.fmt.allocPrint(self.allocator, "--set-upstream-to={s}", .{ref});
        defer self.allocator.free(arg);
        return self.exec(&.{ "branch", arg });
    }

    /// Open `url` in the user's default browser via the platform opener. Returns
    /// quickly; the browser launch is fire-and-forget.
    pub fn openUrl(self: *Git, url: []const u8) !void {
        const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ opener, url },
            .cwd = .{ .path = self.root },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    /// Fast-forward the checked-out branch to its upstream.
    pub fn fastForwardCurrent(self: *Git) !ExecResult {
        return self.exec(&.{ "pull", "--ff-only" });
    }

    /// Fast-forward a non-checked-out local branch to its remote tracking ref
    /// without checking it out, via a fetch refspec `<remote_ref>:<local>`.
    pub fn fastForwardBranch(self: *Git, remote: []const u8, remote_ref: []const u8, local: []const u8) !ExecResult {
        const refspec = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ remote_ref, local });
        defer self.allocator.free(refspec);
        return self.exec(&.{ "fetch", remote, refspec });
    }

    pub fn mergeBranch(self: *Git, name: []const u8) !ExecResult {
        return self.exec(&.{ "merge", "--no-edit", name });
    }

    pub fn rebaseOnto(self: *Git, name: []const u8) !ExecResult {
        return self.exec(&.{ "rebase", name });
    }

    /// Replay commits from `marked_base` (inclusive) through HEAD onto `newbase`,
    /// dropping any commits before the marked base. Runs `git rebase --onto <newbase> <marked_base>^`.
    pub fn rebaseOntoMarked(self: *Git, newbase: []const u8, marked_base: []const u8) !ExecResult {
        var buf: [80]u8 = undefined;
        const upstream = try std.fmt.bufPrint(&buf, "{s}^", .{marked_base});
        return self.exec(&.{ "rebase", "--onto", newbase, upstream });
    }

    pub const ResetMode = enum {
        soft,
        mixed,
        hard,

        fn flag(self: ResetMode) []const u8 {
            return switch (self) {
                .soft => "--soft",
                .mixed => "--mixed",
                .hard => "--hard",
            };
        }
    };

    pub fn resetTo(self: *Git, hash: []const u8, mode: ResetMode) !ExecResult {
        return self.exec(&.{ "reset", mode.flag(), hash });
    }

    pub fn revertCommit(self: *Git, hash: []const u8) !ExecResult {
        return self.exec(&.{ "revert", "--no-edit", hash });
    }

    /// Read a working-tree file (relative to the repo root) into an owned slice.
    pub fn readWorkingFile(self: *Git, path: []const u8) ![]u8 {
        const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, path });
        defer self.allocator.free(full);
        return std.Io.Dir.readFileAlloc(.cwd(), self.io, full, self.allocator, .limited(64 * 1024 * 1024));
    }

    /// Overwrite a working-tree file (relative to the repo root) with `data`.
    pub fn writeWorkingFile(self: *Git, path: []const u8, data: []const u8) !void {
        const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, path });
        defer self.allocator.free(full);
        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = full, .data = data });
    }

    /// Verify a commit's GPG signature. gpg writes its human-readable result
    /// (Good/Bad signature, key, signer) to stderr; exit is non-zero for a bad
    /// or missing signature. The caller shows the output in a dialog.
    pub fn verifyCommit(self: *Git, hash: []const u8) !ExecResult {
        return self.exec(&.{ "verify-commit", "-v", hash });
    }

    /// Revert several commits in one `git revert --no-edit <hashes...>`. The
    /// hashes are applied in the order given (newest-first).
    pub fn revertCommits(self: *Git, hashes: []const []const u8) !ExecResult {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "revert", "--no-edit" });
        try args.appendSlice(self.allocator, hashes);
        return self.exec(args.items);
    }

    /// Amend the last commit with the currently-staged changes, keeping its
    /// message.
    pub fn amendCommit(self: *Git) !ExecResult {
        return self.exec(&.{ "commit", "--amend", "--no-edit" });
    }

    /// Commit the staged changes as a `fixup! <subject of hash>` commit.
    pub fn createFixup(self: *Git, hash: []const u8) !ExecResult {
        const arg = try std.fmt.allocPrint(self.allocator, "--fixup={s}", .{hash});
        defer self.allocator.free(arg);
        return self.exec(&.{ "commit", arg });
    }

    /// Autosquash fixup!/squash! commits in the range above `base`, accepting
    /// git's reordered todo (both editors are no-ops via env vars).
    pub fn autosquashRebase(self: *Git, base: []const u8) !ExecResult {
        var env = try self.environ.clone(self.allocator);
        defer env.deinit();
        try env.put("GIT_SEQUENCE_EDITOR", "true");
        try env.put("GIT_EDITOR", "true");
        const argv = [_][]const u8{ "git", "rebase", "-i", "--autosquash", "--autostash", base };
        self.recordCommand(argv[1..]);
        const result = try runWithLockRetry(self.allocator, self.io, .{
            .argv = &argv,
            .cwd = .{ .path = self.root },
            .environ_map = &env,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
    }

    /// Cherry-pick several commits in one go (apply in the given order).
    pub fn cherryPickMany(self: *Git, hashes: []const []const u8) !ExecResult {
        if (hashes.len == 0) return self.successResult();
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, "cherry-pick");
        try args.appendSlice(self.allocator, hashes);
        return self.exec(args.items);
    }

    pub fn cherryPickContinue(self: *Git) !ExecResult {
        return self.exec(&.{ "-c", "core.editor=true", "cherry-pick", "--continue" });
    }

    pub fn cherryPickAbort(self: *Git) !ExecResult {
        return self.exec(&.{ "cherry-pick", "--abort" });
    }

    /// The subject of the most recent reflog entry (describes the last op).
    pub fn reflogSubject(self: *Git) ![]u8 {
        var result = try self.exec(&.{ "reflog", "-1", "--format=%gs" });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(u8, 0);
        return self.allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    /// Undo the last history operation by resetting HEAD to its prior position.
    pub fn undoLastOperation(self: *Git) !ExecResult {
        return self.exec(&.{ "reset", "--hard", "HEAD@{1}" });
    }

    /// The body (message minus subject line) of a commit, trimmed. Empty if the
    /// commit has only a subject. Caller owns the returned slice.
    pub fn commitBody(self: *Git, hash: []const u8) ![]u8 {
        var result = try self.exec(&.{ "log", "-1", "--format=%b", hash });
        defer result.deinit(self.allocator);
        if (!result.ok()) return self.allocator.alloc(u8, 0);
        return self.allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
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

    /// Drop several stash entries. Entries are dropped highest-index-first so the
    /// lower indices stay valid as the list shifts.
    pub fn stashDropMany(self: *Git, indices: []const usize) !ExecResult {
        const sorted = try self.allocator.dupe(usize, indices);
        defer self.allocator.free(sorted);
        std.mem.sort(usize, sorted, {}, std.sort.desc(usize));
        for (sorted) |idx| {
            var r = try self.stashDrop(idx);
            if (!r.ok()) return r;
            r.deinit(self.allocator);
        }
        return self.successResult();
    }

    /// Rename a stash: drop the entry and re-store its commit `hash` under the new
    /// `message` (git has no in-place rename). The renamed stash returns to the
    /// top of the list.
    pub fn renameStash(self: *Git, index: usize, hash: []const u8, message: []const u8) !ExecResult {
        const selector = try std.fmt.allocPrint(self.allocator, "stash@{{{d}}}", .{index});
        defer self.allocator.free(selector);
        var r = try self.exec(&.{ "stash", "drop", selector });
        if (!r.ok()) return r;
        r.deinit(self.allocator);
        return self.exec(&.{ "stash", "store", "-m", message, hash });
    }

    pub fn stashAll(self: *Git) !ExecResult {
        return self.exec(&.{ "stash", "push" });
    }

    /// Stash tracked changes plus untracked files (`-u`).
    pub fn stashIncludingUntracked(self: *Git) !ExecResult {
        return self.exec(&.{ "stash", "push", "--include-untracked" });
    }

    /// Stash only what is staged (`--staged`), leaving the working tree.
    pub fn stashStaged(self: *Git) !ExecResult {
        return self.exec(&.{ "stash", "push", "--staged" });
    }

    pub fn stashFile(self: *Git, path: []const u8) !ExecResult {
        return self.exec(&.{ "stash", "push", "--", path });
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

    pub fn discardFiles(self: *Git, files: []const model.FileStatus) !ExecResult {
        for (files) |file| {
            var r = try self.discardFile(file);
            if (!r.ok()) return r;
            r.deinit(self.allocator);
        }
        return self.successResult();
    }

    pub fn discardUnstagedFiles(self: *Git, files: []const model.FileStatus) !ExecResult {
        for (files) |file| {
            var r = try self.discardUnstaged(file);
            if (!r.ok()) return r;
            r.deinit(self.allocator);
        }
        return self.successResult();
    }

    pub fn successResult(self: *Git) !ExecResult {
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
        // `%(upstream:track)` is "[gone]" when the tracked remote branch was
        // deleted, or "[ahead N, behind M]" / "[ahead N]" / "[behind M]" / ""
        // otherwise.
        const track = fields.next() orelse "";
        const date = std.mem.trim(u8, fields.next() orelse "", " \t\r\n");
        var branch = model.Branch{
            .name = try allocator.dupe(u8, name),
            .current = head.len > 0 and head[0] == '*',
            .upstream_gone = std.mem.eql(u8, track, "[gone]"),
            .ahead = trackCount(track, "ahead "),
            .behind = trackCount(track, "behind "),
            .commit_time = std.fmt.parseInt(i64, date, 10) catch 0,
        };
        errdefer branch.deinit(allocator);
        if (upstream.len > 0) branch.upstream = try allocator.dupe(u8, upstream);
        try branches.append(allocator, branch);
    }

    return branches.toOwnedSlice(allocator);
}

test "parseBranches reads ahead/behind from upstream:track" {
    const bytes = " \x00feature\x00origin/feature\x00[ahead 2]\x001700000000\n" ++
        " \x00topic\x00origin/topic\x00[ahead 3, behind 1]\x001699999999\n" ++
        "*\x00main\x00origin/main\x00\x001700000123\n";
    const branches = try parseBranches(std.testing.allocator, bytes);
    defer {
        for (branches) |*b| b.deinit(std.testing.allocator);
        std.testing.allocator.free(branches);
    }
    try std.testing.expectEqual(@as(usize, 3), branches.len);
    try std.testing.expectEqual(@as(usize, 2), branches[0].ahead);
    try std.testing.expectEqual(@as(usize, 0), branches[0].behind);
    try std.testing.expectEqual(@as(i64, 1700000000), branches[0].commit_time);
    try std.testing.expectEqual(@as(usize, 3), branches[1].ahead);
    try std.testing.expectEqual(@as(usize, 1), branches[1].behind);
    try std.testing.expectEqual(@as(usize, 0), branches[2].ahead);
    try std.testing.expect(branches[2].current);
    try std.testing.expectEqual(@as(i64, 1700000123), branches[2].commit_time);
}

/// The number following `label` ("ahead "/"behind ") in a `%(upstream:track)`
/// string like "[ahead 2, behind 1]", or 0 if absent.
fn trackCount(track: []const u8, label: []const u8) usize {
    const at = std.mem.indexOf(u8, track, label) orelse return 0;
    var i = at + label.len;
    var n: usize = 0;
    while (i < track.len and track[i] >= '0' and track[i] <= '9') : (i += 1) {
        n = n * 10 + (track[i] - '0');
    }
    return n;
}

/// Parse `git remote -v` into one `Remote` per name, keeping the fetch URL.
pub fn parseRemotes(allocator: std.mem.Allocator, bytes: []const u8) ![]model.Remote {
    var remotes: std.ArrayList(model.Remote) = .empty;
    errdefer {
        for (remotes.items) |*r| r.deinit(allocator);
        remotes.deinit(allocator);
    }
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const name = toks.next() orelse continue;
        const url = toks.next() orelse "";
        const kind = toks.next() orelse "";
        if (!std.mem.eql(u8, kind, "(fetch)")) continue; // one row per remote
        var seen = false;
        for (remotes.items) |r| {
            if (std.mem.eql(u8, r.name, name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const n = try allocator.dupe(u8, name);
        errdefer allocator.free(n);
        const u = try allocator.dupe(u8, url);
        try remotes.append(allocator, .{ .name = n, .url = u });
    }
    return remotes.toOwnedSlice(allocator);
}

test "parseRemotes keeps one fetch URL per remote" {
    const bytes =
        "origin\thttps://example.com/x.git (fetch)\n" ++
        "origin\thttps://example.com/x.git (push)\n" ++
        "upstream\tgit@github.com:y/z.git (fetch)\n" ++
        "upstream\tgit@github.com:y/z.git (push)\n";
    const remotes = try parseRemotes(std.testing.allocator, bytes);
    defer {
        for (remotes) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(remotes);
    }
    try std.testing.expectEqual(@as(usize, 2), remotes.len);
    try std.testing.expectEqualStrings("origin", remotes[0].name);
    try std.testing.expectEqualStrings("https://example.com/x.git", remotes[0].url);
    try std.testing.expectEqualStrings("upstream", remotes[1].name);
    try std.testing.expectEqualStrings("git@github.com:y/z.git", remotes[1].url);
}

/// Move the current (checked-out) branch to index 0, preserving the relative
/// order of the rest — the current branch is always listed first. A no-op
/// for remote-branch lists (none is marked current).
pub fn moveCurrentBranchToFront(branches: []model.Branch) void {
    for (branches, 0..) |branch, i| {
        if (!branch.current) continue;
        if (i == 0) return;
        const cur = branches[i];
        var j = i;
        while (j > 0) : (j -= 1) branches[j] = branches[j - 1];
        branches[0] = cur;
        return;
    }
}

/// Parse the ordered, de-duplicated branch names from reflog `%gs` subjects.
/// Each `checkout: moving from X to Y` contributes X then Y; the first time a
/// name is seen fixes its position, so the result is in most-recent-first order.
pub fn parseBranchRecency(allocator: std.mem.Allocator, bytes: []const u8) ![][]u8 {
    const prefix = "checkout: moving from ";
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const to_at = std.mem.indexOf(u8, rest, " to ") orelse continue;
        const from = rest[0..to_at];
        const to = rest[to_at + " to ".len ..];
        for ([_][]const u8{ from, to }) |name| {
            if (name.len == 0) continue;
            var seen = false;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, name)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            try names.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return names.toOwnedSlice(allocator);
}

/// Reorder `branches` in place for the `recency` sort: branches present in
/// `recency` (in that order, skipping the current branch) come first, then the
/// rest sorted alphabetically. The current branch is positioned separately.
fn applyRecencyOrder(branches: []model.Branch, recency: []const []const u8) void {
    var front: usize = 0; // next slot for a recency-ordered branch
    for (recency) |name| {
        var k = front;
        while (k < branches.len) : (k += 1) {
            if (branches[k].current) continue;
            if (!std.ascii.eqlIgnoreCase(branches[k].name, name)) continue;
            const hit = branches[k];
            var j = k;
            while (j > front) : (j -= 1) branches[j] = branches[j - 1];
            branches[front] = hit;
            front += 1;
            break;
        }
    }
    // Remaining branches (not in the reflog) keep deterministic alphabetical order.
    std.mem.sort(model.Branch, branches[front..], {}, struct {
        fn lt(_: void, a: model.Branch, b: model.Branch) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
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

pub fn parseWorktrees(allocator: std.mem.Allocator, bytes: []const u8, current_root: []const u8) ![]model.Worktree {
    var worktrees: std.ArrayList(model.Worktree) = .empty;
    errdefer {
        for (worktrees.items) |*wt| wt.deinit(allocator);
        worktrees.deinit(allocator);
    }

    // `--porcelain` emits one blank-line-separated block per worktree.
    var blocks = std.mem.splitSequence(u8, bytes, "\n\n");
    while (blocks.next()) |block| {
        var path: ?[]const u8 = null;
        var branch: []const u8 = "(detached)";
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "worktree ")) {
                path = line["worktree ".len..];
            } else if (std.mem.eql(u8, line, "bare")) {
                branch = "(bare)";
            } else if (std.mem.eql(u8, line, "detached")) {
                branch = "(detached)";
            } else if (std.mem.startsWith(u8, line, "branch ")) {
                const ref = line["branch ".len..];
                branch = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else ref;
            }
        }
        const wt_path = path orelse continue;
        if (wt_path.len == 0) continue;
        var wt = model.Worktree{
            .path = try allocator.dupe(u8, wt_path),
            .branch = try allocator.dupe(u8, branch),
            .is_current = std.mem.eql(u8, wt_path, current_root),
        };
        errdefer wt.deinit(allocator);
        try worktrees.append(allocator, wt);
    }

    return worktrees.toOwnedSlice(allocator);
}

pub fn parseSubmodules(allocator: std.mem.Allocator, bytes: []const u8) ![]model.Submodule {
    var submodules: std.ArrayList(model.Submodule) = .empty;
    errdefer {
        for (submodules.items) |*sm| sm.deinit(allocator);
        submodules.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        // Format: "<status><sha> <path> [(describe)]"; the status char (which
        // may be a space) is attached to the SHA, so read it before tokenizing.
        const status = line[0];
        var fields = std.mem.tokenizeScalar(u8, line[1..], ' ');
        const sha = fields.next() orelse continue;
        const path = fields.next() orelse continue;
        var sm = model.Submodule{
            .path = try allocator.dupe(u8, path),
            .sha = try allocator.dupe(u8, sha),
            .status = status,
        };
        errdefer sm.deinit(allocator);
        try submodules.append(allocator, sm);
    }

    return submodules.toOwnedSlice(allocator);
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

pub fn parseCommitFiles(allocator: std.mem.Allocator, bytes: []const u8) ![]model.CommitFile {
    var files: std.ArrayList(model.CommitFile) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    // -z output is a flat NUL-separated stream: STATUS, PATH, STATUS, PATH...
    // Renames/copies (R/C) carry two paths (source then destination).
    var parts = std.mem.splitScalar(u8, bytes, 0);
    while (parts.next()) |status_token| {
        if (status_token.len == 0) continue;
        const status = status_token[0];
        const path = if (status == 'R' or status == 'C') blk: {
            _ = parts.next() orelse break; // source path, unused
            break :blk parts.next() orelse break; // destination path
        } else parts.next() orelse break;
        if (path.len == 0) continue;
        var file = model.CommitFile{
            .status = status,
            .path = try allocator.dupe(u8, path),
        };
        errdefer file.deinit(allocator);
        try files.append(allocator, file);
    }

    return files.toOwnedSlice(allocator);
}

fn parseStashIndex(selector: []const u8) ?usize {
    const start = std.mem.indexOfScalar(u8, selector, '{') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, selector, start, '}') orelse return null;
    return std.fmt.parseInt(usize, selector[start + 1 .. end], 10) catch null;
}

test "log filters set, report and clear" {
    const allocator = std.testing.allocator;
    var git = Git{ .allocator = allocator, .io = undefined, .environ = undefined, .root = undefined };

    try std.testing.expect(!git.hasLogFilter());

    try git.setLogFilter(.author, "alice");
    try git.setLogFilter(.path, "src/app.zig");
    try std.testing.expect(git.hasLogFilter());
    try std.testing.expectEqualStrings("alice", git.log_author.?);
    try std.testing.expectEqualStrings("src/app.zig", git.log_path.?);

    // An empty value clears just that filter.
    try git.setLogFilter(.author, "");
    try std.testing.expect(git.log_author == null);
    try std.testing.expect(git.hasLogFilter());

    git.clearLogFilters();
    try std.testing.expect(!git.hasLogFilter());
}

test "UntrackedFiles maps to git's status flag" {
    try std.testing.expectEqualStrings("--untracked-files=all", Git.UntrackedFiles.all.flag());
    try std.testing.expectEqualStrings("--untracked-files=normal", Git.UntrackedFiles.normal.flag());
    try std.testing.expectEqualStrings("--untracked-files=no", Git.UntrackedFiles.no.flag());
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

test "parse porcelain status handles merge/rebase conflict codes" {
    // The codes `git status` emits during a merge/rebase/cherry-pick conflict.
    const input = "UU both.txt\x00AA addadd.txt\x00DD deldel.txt\x00UA us-added.txt\x00 M plain.txt\x00";
    const files = try parseStatus(std.testing.allocator, input);
    defer {
        for (files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 5), files.len);
    try std.testing.expect(files[0].conflict and files[0].has_unstaged); // UU
    try std.testing.expectEqualSlices(u8, "both.txt", files[0].path);
    try std.testing.expect(files[1].conflict); // AA
    try std.testing.expect(files[2].conflict); // DD
    try std.testing.expect(files[3].conflict); // UA
    try std.testing.expect(!files[4].conflict); // plain modification
}

test "parse branches handles rebase/detached pseudo-entry as current" {
    // `branch --format` lists a pseudo-entry for the detached HEAD during a
    // rebase or detached checkout; it must parse without panicking and be the
    // current branch.
    const input = "*\x00(no branch, rebasing topic)\x00\x00\n" ++
        " \x00main\x00\x00\n" ++
        " \x00topic\x00\x00\n";
    const branches = try parseBranches(std.testing.allocator, input);
    defer {
        for (branches) |*b| b.deinit(std.testing.allocator);
        std.testing.allocator.free(branches);
    }
    try std.testing.expectEqual(@as(usize, 3), branches.len);
    try std.testing.expect(branches[0].current);
    try std.testing.expectEqualSlices(u8, "(no branch, rebasing topic)", branches[0].name);
    try std.testing.expect(!branches[1].current);
    try std.testing.expectEqualSlices(u8, "main", branches[1].name);
}

test "parse commits handles empty (unborn branch) output" {
    const commits = try parseCommits(std.testing.allocator, "");
    defer std.testing.allocator.free(commits);
    try std.testing.expectEqual(@as(usize, 0), commits.len);
}

test "parse branches captures current marker, upstream, and gone upstream" {
    // Fields per line: HEAD, refname:short, upstream:short, upstream:track.
    const input =
        "*\x00main\x00origin/main\x00[ahead 1]\n" ++
        " \x00feature/demo\x00origin/feature/demo\x00\n" ++
        " \x00merged\x00origin/merged\x00[gone]\n" ++
        " \x00local-only\x00\x00\n";
    const branches = try parseBranches(std.testing.allocator, input);
    defer {
        for (branches) |*branch| branch.deinit(std.testing.allocator);
        std.testing.allocator.free(branches);
    }

    try std.testing.expectEqual(@as(usize, 4), branches.len);
    try std.testing.expect(branches[0].current);
    try std.testing.expectEqualSlices(u8, "main", branches[0].name);
    try std.testing.expectEqualSlices(u8, "origin/main", branches[0].upstream.?);
    try std.testing.expect(!branches[0].upstream_gone);
    try std.testing.expect(!branches[1].current);
    try std.testing.expectEqualSlices(u8, "feature/demo", branches[1].name);
    try std.testing.expect(!branches[1].upstream_gone);
    // The "[gone]" track marks the upstream as deleted.
    try std.testing.expectEqualSlices(u8, "merged", branches[2].name);
    try std.testing.expectEqualSlices(u8, "origin/merged", branches[2].upstream.?);
    try std.testing.expect(branches[2].upstream_gone);
    try std.testing.expect(branches[3].upstream == null);
    try std.testing.expect(!branches[3].upstream_gone);
}

test "moveCurrentBranchToFront lists the current branch first" {
    // git sorts by -committerdate; the current branch may be anywhere.
    var b = [_]model.Branch{
        .{ .name = @constCast(@as([]const u8, "feat-a")) },
        .{ .name = @constCast(@as([]const u8, "main")), .current = true },
        .{ .name = @constCast(@as([]const u8, "feat-b")) },
    };
    moveCurrentBranchToFront(&b);
    try std.testing.expectEqualStrings("main", b[0].name); // moved to top
    try std.testing.expectEqualStrings("feat-a", b[1].name); // others keep order
    try std.testing.expectEqualStrings("feat-b", b[2].name);

    // No current branch (remote list / detached HEAD): order is unchanged.
    var r = [_]model.Branch{
        .{ .name = @constCast(@as([]const u8, "origin/x")) },
        .{ .name = @constCast(@as([]const u8, "origin/y")) },
    };
    moveCurrentBranchToFront(&r);
    try std.testing.expectEqualStrings("origin/x", r[0].name);
    try std.testing.expectEqualStrings("origin/y", r[1].name);
}

test "parseBranchRecency extracts checkout order, de-duplicated" {
    const input =
        "checkout: moving from main to feature\n" ++
        "commit: some work\n" ++
        "checkout: moving from feature to main\n" ++
        "checkout: moving from main to old-thing\n";
    const names = try parseBranchRecency(std.testing.allocator, input);
    defer {
        for (names) |n| std.testing.allocator.free(n);
        std.testing.allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("main", names[0]);
    try std.testing.expectEqualStrings("feature", names[1]);
    try std.testing.expectEqualStrings("old-thing", names[2]);
}

test "applyRecencyOrder orders by reflog then alphabetical, skipping current" {
    // committerdate order from git; `main` is the current branch.
    var b = [_]model.Branch{
        .{ .name = @constCast(@as([]const u8, "feature")) },
        .{ .name = @constCast(@as([]const u8, "main")), .current = true },
        .{ .name = @constCast(@as([]const u8, "old")) },
        .{ .name = @constCast(@as([]const u8, "zeta")) },
    };
    const recency = [_][]const u8{ "main", "feature", "old" };
    applyRecencyOrder(&b, &recency);
    // `main` is current so it's skipped here; feature/old lead in reflog order,
    // then the rest (main, zeta) sorted alphabetically.
    try std.testing.expectEqualStrings("feature", b[0].name);
    try std.testing.expectEqualStrings("old", b[1].name);
    try std.testing.expectEqualStrings("main", b[2].name);
    try std.testing.expectEqualStrings("zeta", b[3].name);
}

test "command log filters read-only invocations" {
    // Read-only loads/refreshes are not logged.
    try std.testing.expect(Git.isReadOnly(&.{ "status", "--porcelain" }));
    try std.testing.expect(Git.isReadOnly(&.{ "diff", "--staged" }));
    try std.testing.expect(Git.isReadOnly(&.{ "branch", "--format=%x00" }));
    try std.testing.expect(Git.isReadOnly(&.{ "tag", "--sort=-creatordate" }));
    try std.testing.expect(Git.isReadOnly(&.{ "stash", "list" }));
    // Mutations are logged.
    try std.testing.expect(!Git.isReadOnly(&.{ "commit", "-m", "x" }));
    try std.testing.expect(!Git.isReadOnly(&.{ "branch", "-d", "--", "feat" }));
    try std.testing.expect(!Git.isReadOnly(&.{ "tag", "--", "v1" }));
    try std.testing.expect(!Git.isReadOnly(&.{ "stash", "pop" }));
    try std.testing.expect(!Git.isReadOnly(&.{"push"}));
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

test "parse worktrees marks the current one and shortens branches" {
    const bytes =
        "worktree /repo\nHEAD aaaa\nbranch refs/heads/main\n\n" ++
        "worktree /repo-wt\nHEAD bbbb\nbranch refs/heads/feature\n\n" ++
        "worktree /repo-detached\nHEAD cccc\ndetached\n";
    const worktrees = try parseWorktrees(std.testing.allocator, bytes, "/repo");
    defer {
        for (worktrees) |*wt| wt.deinit(std.testing.allocator);
        std.testing.allocator.free(worktrees);
    }

    try std.testing.expectEqual(@as(usize, 3), worktrees.len);
    try std.testing.expectEqualStrings("/repo", worktrees[0].path);
    try std.testing.expectEqualStrings("main", worktrees[0].branch);
    try std.testing.expect(worktrees[0].is_current);
    try std.testing.expectEqualStrings("feature", worktrees[1].branch);
    try std.testing.expect(!worktrees[1].is_current);
    try std.testing.expectEqualStrings("(detached)", worktrees[2].branch);
}

test "parse submodules reads the status char, sha and path" {
    const bytes =
        " cd8600b5b4b075bae86b0e3b66a133c687d65716 libs/sub (heads/main)\n" ++
        "-aaaa000000000000000000000000000000000000 vendor/x\n" ++
        "+bbbb000000000000000000000000000000000000 vendor/y (v1.2-3-gabc)\n";
    const subs = try parseSubmodules(std.testing.allocator, bytes);
    defer {
        for (subs) |*sm| sm.deinit(std.testing.allocator);
        std.testing.allocator.free(subs);
    }

    try std.testing.expectEqual(@as(usize, 3), subs.len);
    try std.testing.expectEqual(@as(u8, ' '), subs[0].status);
    try std.testing.expectEqualStrings("libs/sub", subs[0].path);
    try std.testing.expectEqualStrings("ok", subs[0].stateLabel());
    try std.testing.expectEqual(@as(u8, '-'), subs[1].status);
    try std.testing.expectEqualStrings("vendor/x", subs[1].path);
    try std.testing.expectEqualStrings("uninitialized", subs[1].stateLabel());
    try std.testing.expectEqual(@as(u8, '+'), subs[2].status);
    try std.testing.expectEqualStrings("vendor/y", subs[2].path);
}

test "parse commit files handles modifications and renames" {
    const input = "M\x00src/main.zig\x00A\x00new.zig\x00R100\x00old.zig\x00renamed.zig\x00D\x00gone.zig\x00";
    const files = try parseCommitFiles(std.testing.allocator, input);
    defer model.deinitCommitFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 4), files.len);
    try std.testing.expectEqual(@as(u8, 'M'), files[0].status);
    try std.testing.expectEqualSlices(u8, "src/main.zig", files[0].path);
    try std.testing.expectEqual(@as(u8, 'A'), files[1].status);
    try std.testing.expectEqual(@as(u8, 'R'), files[2].status);
    try std.testing.expectEqualSlices(u8, "renamed.zig", files[2].path);
    try std.testing.expectEqual(@as(u8, 'D'), files[3].status);
    try std.testing.expectEqualSlices(u8, "gone.zig", files[3].path);
}

test "retryable lock errors are detected, other errors are not" {
    try std.testing.expect(isRetryableLockError("fatal: Unable to create '/repo/.git/index.lock': File exists."));
    try std.testing.expect(isRetryableLockError("error: cannot lock ref 'refs/heads/main': is at ... but expected ..."));
    try std.testing.expect(!isRetryableLockError("error: pathspec 'x' did not match any file(s)"));
    try std.testing.expect(!isRetryableLockError("Everything up-to-date"));
    try std.testing.expect(!isRetryableLockError(""));
}
