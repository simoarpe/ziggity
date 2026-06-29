const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const credentials_mod = @import("credentials.zig");
const git_mod = @import("git.zig");
const filetree = @import("filetree.zig");
const model = @import("model.zig");
const patch_mod = @import("patch.zig");
const staging_mod = @import("staging.zig");

/// Active theme, set from config at startup and read by `styles()`.
var ui_theme: config_mod.Theme = .{};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    refresh_tick,
    command_done,
    preview_done,
    worktree_done,
    mutation_done,
    repo_load_done,
    scoped_load_done,
};

/// A network op run off the UI loop. Allocations use the page allocator (which
/// is thread-safe and independent of the main gpa), so there is no cross-thread
/// allocator race with the rest of the app.
const async_allocator = std.heap.page_allocator;

const AsyncJob = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []const u8,
    environ: *std.process.Environ.Map,
    /// When credentials have been entered, an owned clone of `environ` carrying
    /// the askpass wiring + secrets. Used in place of `environ` for this op and
    /// freed when the op finishes; null otherwise.
    cred_environ: ?std.process.Environ.Map = null,
    op: app_mod.AsyncOp,
    /// For `push_set_upstream`: the remote and branch appended after the op's
    /// args (`push --set-upstream <remote> <branch>`). Borrowed from the app.
    upstream_remote: ?[]const u8 = null,
    upstream_branch: ?[]const u8 = null,
    result: ?git_mod.ExecResult = null,
};

fn asyncWorker(job: *AsyncJob) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(async_allocator);
    argv.append(async_allocator, "git") catch return postDone(job);
    argv.appendSlice(async_allocator, job.op.argv()) catch return postDone(job);
    // A first push of an upstream-less branch appends "<remote> <branch>".
    if (job.upstream_remote) |r| argv.append(async_allocator, r) catch return postDone(job);
    if (job.upstream_branch) |b| argv.append(async_allocator, b) catch return postDone(job);

    // Use the credential-bearing clone when present, else the shared environment
    // (which sets GIT_TERMINAL_PROMPT=0 so git never blocks on a terminal
    // prompt). The credential clone points GIT_ASKPASS back at this binary, so
    // git fetches the entered username/password from us instead.
    const env = if (job.cred_environ) |*e| e else job.environ;
    const result = git_mod.runWithLockRetry(async_allocator, job.io, .{
        .argv = argv.items,
        .cwd = .{ .path = job.root },
        .environ_map = env,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch {
        if (job.cred_environ) |*e| {
            e.deinit();
            job.cred_environ = null;
        }
        return postDone(job);
    };

    if (job.cred_environ) |*e| {
        e.deinit();
        job.cred_environ = null;
    }
    job.result = .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
    postDone(job);
}

fn postDone(job: *AsyncJob) void {
    _ = job.loop.tryPostEvent(.command_done) catch false;
}

/// A preview diff generated off the UI loop. Runs the queued `PreviewJob`'s git
/// commands with the page allocator (thread-safe, independent of the gpa) and
/// posts `.preview_done` so the loop can hand the result back to the app.
const PreviewRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []const u8,
    job: app_mod.PreviewJob,
    result: ?[]u8 = null,
};

fn previewWorker(pr: *PreviewRun) void {
    pr.result = pr.job.run(async_allocator, pr.io, pr.root) catch null;
    _ = pr.loop.tryPostEvent(.preview_done) catch false;
}

/// The background working-tree refresh (the 1.5s tick). Gathers `git status`
/// and friends off the UI loop with the page allocator and posts
/// `.worktree_done` so the loop can apply the snapshot on the UI thread.
const WorktreeRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []u8,
    environ: *std.process.Environ.Map,
    untracked: git_mod.Git.UntrackedFiles = .all,
    generation: u64,
    result: ?app_mod.WorktreeSnapshot = null,
};

fn worktreeWorker(wr: *WorktreeRun) void {
    wr.result = app_mod.WorktreeSnapshot.load(async_allocator, wr.io, wr.environ, wr.root, wr.untracked) catch null;
    _ = wr.loop.tryPostEvent(.worktree_done) catch false;
}

/// A slow git mutation (merge/rebase/bisect/…) run off the UI loop on a
/// page-allocator Git. Posts `.mutation_done` so the loop can surface the
/// result and refresh on the UI thread.
const MutationRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []u8,
    environ: *std.process.Environ.Map,
    mutation: app_mod.Mutation,
    result: ?git_mod.ExecResult = null,
};

fn mutationWorker(mr: *MutationRun) void {
    mr.result = mr.mutation.run(async_allocator, mr.io, mr.environ, mr.root) catch null;
    _ = mr.loop.tryPostEvent(.mutation_done) catch false;
}

/// The one-shot initial repo load (async startup). Loads the full
/// repo off the UI loop on a page-allocator Git and posts `.repo_load_done` so
/// the loop can deep-copy it into the gpa and paint the populated panels.
const RepoLoadRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []u8,
    environ: *std.process.Environ.Map,
    branch_sort: model.BranchSortOrder = .date,
    untracked: git_mod.Git.UntrackedFiles = .all,
    result: ?model.RepoData = null,
};

fn repoLoadWorker(rl: *RepoLoadRun) void {
    rl.result = app_mod.loadRepoDataAsync(async_allocator, rl.io, rl.environ, rl.root, rl.branch_sort, rl.untracked);
    _ = rl.loop.tryPostEvent(.repo_load_done) catch false;
}

/// A per-view scoped refresh: loads just the requested slow
/// views (branches/commits/tags/…) off the UI loop and posts `.scoped_load_done`
/// so the loop can apply each into its view. `grep`/`author`/`path` are
/// page-allocated copies of the active Commits filter, freed when done.
const ScopedLoadRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []u8,
    environ: *std.process.Environ.Map,
    scopes: app_mod.ScopeSet,
    grep: ?[]u8 = null,
    author: ?[]u8 = null,
    path: ?[]u8 = null,
    branch_sort: model.BranchSortOrder = .date,
    untracked: git_mod.Git.UntrackedFiles = .all,
    result: ?app_mod.ScopedData = null,

    fn freeFilters(self: *ScopedLoadRun) void {
        if (self.grep) |g| async_allocator.free(g);
        if (self.author) |a| async_allocator.free(a);
        if (self.path) |p| async_allocator.free(p);
        self.grep = null;
        self.author = null;
        self.path = null;
    }
};

fn scopedLoadWorker(sr: *ScopedLoadRun) void {
    sr.result = app_mod.loadScopesAsync(async_allocator, sr.io, sr.environ, sr.root, sr.scopes, .{
        .grep = sr.grep,
        .author = sr.author,
        .path = sr.path,
    }, sr.branch_sort, sr.untracked);
    _ = sr.loop.tryPostEvent(.scoped_load_done) catch false;
}

// The ticker always wakes at this fast cadence so the spinner animates smoothly
// and a newly-started op begins spinning within one tick — instead of staying
// stuck on the first frame until a long idle sleep finishes.
const spinner_tick_ms: u64 = 80;
const spinner_tick = std.Io.Duration.fromMilliseconds(spinner_tick_ms);
// The idle background working-tree refresh cadence is configurable
// (`refresh_interval_secs`); see `refreshTickerRun`.
const focus_events_set = "\x1b[?1004h";
const focus_events_reset = "\x1b[?1004l";

const RefreshTicker = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    app: *app_mod.App,
    stop: std.atomic.Value(bool) = .init(false),
};

pub fn run(init: std.process.Init, app: *app_mod.App) !void {
    const io = init.io;
    const allocator = init.gpa;
    ui_theme = app.config.theme;

    var tty_buffer: [1024]u8 = undefined;
    // Opening /dev/tty (+ switching it to raw mode) fails when there's no
    // controlling terminal — stdin/stdout redirected, a pipe, cron/CI, etc.
    // Surface that as a typed error so `main` can print a clear message.
    var tty = vaxis.Tty.init(io, &tty_buffer) catch return error.NoTerminal;
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    var refresh_ticker: RefreshTicker = .{ .io = io, .loop = &loop, .app = app };
    var refresh_future = try io.concurrent(refreshTickerRun, .{&refresh_ticker});
    defer {
        // Cancel the ticker's in-progress sleep so quitting returns immediately
        // instead of blocking until it next wakes (up to the idle interval).
        refresh_ticker.stop.store(true, .release);
        refresh_future.cancel(io);
    }

    const writer = tty.writer();
    try vx.enterAltScreen(writer);
    try vx.setMouseMode(writer, true);
    try writer.writeAll(focus_events_set);
    try writer.flush();
    defer {
        writer.writeAll(focus_events_reset) catch {};
        writer.flush() catch {};
    }
    try vx.queryTerminal(writer, .fromSeconds(1));

    var async_job: AsyncJob = undefined;
    var async_future: ?std.Io.Future(void) = null;
    defer if (async_future) |*f| {
        f.await(io);
        if (async_job.result) |*r| r.deinit(async_allocator);
    };

    var preview_run: PreviewRun = undefined;
    var preview_future: ?std.Io.Future(void) = null;
    // Preview and worktree workers are read-only (git diff/show/status), so on
    // quit we cancel them — interrupting their git call so a large-diff preview
    // or status read doesn't delay shutdown. (cancel still awaits the worker's
    // return, so freeing its run struct stays safe.)
    defer if (preview_future) |*f| {
        f.cancel(io);
        if (preview_run.result) |r| async_allocator.free(r);
        preview_run.job.deinit(async_allocator);
    };

    var worktree_run: WorktreeRun = undefined;
    var worktree_future: ?std.Io.Future(void) = null;
    defer if (worktree_future) |*f| {
        f.cancel(io);
        if (worktree_run.result) |*r| r.deinit(async_allocator);
    };

    var mutation_run: MutationRun = undefined;
    var mutation_future: ?std.Io.Future(void) = null;
    defer if (mutation_future) |*f| {
        f.await(io);
        if (mutation_run.result) |*r| r.deinit(async_allocator);
        mutation_run.mutation.deinit(async_allocator);
    };

    var render_ctx = RenderCtx{ .vx = &vx, .writer = writer, .app = app };
    app.render_hook = .{ .ctx = &render_ctx, .func = renderHook };
    defer app.render_hook = null;

    // Load the repo off-thread: the loop's initial winsize event
    // paints the skeleton with "Loading…" placeholders right away, and the
    // panels fill in when `repo_load_done` lands — no startup freeze, no flash.
    var repo_load_run: RepoLoadRun = .{ .io = io, .loop = &loop, .root = app.git.root, .environ = app.git.environ, .branch_sort = app.git.branch_sort, .untracked = app.git.untracked_files };
    var repo_load_future: ?std.Io.Future(void) = null;
    defer if (repo_load_future) |*f| {
        f.cancel(io);
        if (repo_load_run.result) |*r| r.deinit(async_allocator);
    };
    app.beginInitialLoad();
    repo_load_future = io.concurrent(repoLoadWorker, .{&repo_load_run}) catch blk: {
        app.applyRepoLoad(null, async_allocator);
        break :blk null;
    };

    var scoped_load_run: ScopedLoadRun = undefined;
    var scoped_load_future: ?std.Io.Future(void) = null;
    defer if (scoped_load_future) |*f| {
        f.cancel(io); // read-only views, safe to interrupt on quit
        if (scoped_load_run.result) |*r| r.deinit(async_allocator);
        scoped_load_run.freeFilters();
    };

    // Size the screen up front so the first in-loop render is correctly sized
    // regardless of whether the initial winsize or the load-done event is
    // processed first (a tiny repo can finish loading before the winsize).
    if (tty.getWinsize()) |ws| {
        vx.resize(allocator, writer, ws) catch {};
    } else |_| {}

    while (app.running) {
        const event = try loop.nextEvent();
        // Motion mouse events flood with any-motion tracking; skip re-rendering
        // when nothing changed.
        var render_needed = true;
        switch (event) {
            .key_press => |key| try app.handleKey(key),
            .mouse => |m| render_needed = try app.handleMouse(m),
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .refresh_tick => try app.handleRefreshTick(),
            .focus_in => try app.handleFocusIn(),
            .focus_out => app.handleFocusOut(),
            .command_done => {
                if (async_future) |*f| {
                    f.await(io);
                    async_future = null;
                    try app.completeAsync(async_job.op, async_job.result, async_allocator);
                    async_job.result = null;
                }
            },
            .preview_done => {
                if (preview_future) |*f| {
                    f.await(io);
                    preview_future = null;
                    app.completePreview(preview_run.job, preview_run.result, async_allocator);
                    preview_run.result = null;
                }
            },
            .worktree_done => {
                if (worktree_future) |*f| {
                    f.await(io);
                    worktree_future = null;
                    // A failed background refresh is non-critical; the next tick
                    // retries. applyWorktreeSnapshot frees the snapshot either way.
                    app.applyWorktreeSnapshot(worktree_run.result, worktree_run.generation, async_allocator) catch {};
                    worktree_run.result = null;
                }
            },
            .mutation_done => {
                if (mutation_future) |*f| {
                    f.await(io);
                    mutation_future = null;
                    try app.completeMutation(mutation_run.mutation, mutation_run.result, async_allocator);
                    mutation_run.result = null;
                }
            },
            .repo_load_done => {
                if (repo_load_future) |*f| {
                    f.await(io);
                    repo_load_future = null;
                    app.applyRepoLoad(repo_load_run.result, async_allocator);
                    repo_load_run.result = null;
                }
            },
            .scoped_load_done => {
                if (scoped_load_future) |*f| {
                    f.await(io);
                    scoped_load_future = null;
                    app.applyScopedLoad(scoped_load_run.result, async_allocator);
                    scoped_load_run.result = null;
                    scoped_load_run.freeFilters();
                }
            },
        }

        // Push any queued text to the system clipboard (OSC 52).
        if (app.clipboard_request) |text| {
            vx.copyToSystemClipboard(writer, text, allocator) catch {};
            allocator.free(text);
            app.clipboard_request = null;
        }

        // Open the selected file in the editor. A terminal editor needs the
        // terminal, so suspend the TUI and resume on exit; a GUI editor just
        // launches. This must happen on the UI thread (it drives the tty).
        if (app.editor_request) |req| {
            app.editor_request = null;
            runEditor(&loop, &vx, &tty, writer, io, app, req);
            app.allocator.free(req.command);
            render_needed = true;
        }

        // A queued in-process re-root (entering/leaving a worktree or submodule):
        // drain the read-only background workers — they borrow the old `root` —
        // switch repositories, then start a fresh load against the new root.
        // Mutations/network ops are gated by `foregroundBusy` in the request, so
        // only these read-only futures can be in flight here.
        if (app.reroot_request) |new_root| {
            if (preview_future) |*f| {
                f.await(io);
                preview_future = null;
                if (preview_run.result) |r| async_allocator.free(r);
                preview_run.result = null;
            }
            if (worktree_future) |*f| {
                f.await(io);
                worktree_future = null;
                if (worktree_run.result) |*r| r.deinit(async_allocator);
                worktree_run.result = null;
            }
            if (scoped_load_future) |*f| {
                f.await(io);
                scoped_load_future = null;
                if (scoped_load_run.result) |*r| r.deinit(async_allocator);
                scoped_load_run.result = null;
                scoped_load_run.freeFilters();
            }
            if (repo_load_future) |*f| {
                f.await(io);
                repo_load_future = null;
                if (repo_load_run.result) |*r| r.deinit(async_allocator);
                repo_load_run.result = null;
            }

            app.reroot_request = null;
            const push = app.reroot_push;
            app.reRootTo(new_root, push) catch {};
            app.allocator.free(new_root);

            // On a successful switch the app marks an initial load pending; start
            // it against the new root. (A failed switch leaves the app unchanged.)
            if (app.initial_load_pending) {
                repo_load_run = .{ .io = io, .loop = &loop, .root = app.git.root, .environ = app.git.environ, .branch_sort = app.git.branch_sort, .untracked = app.git.untracked_files };
                repo_load_future = io.concurrent(repoLoadWorker, .{&repo_load_run}) catch blk: {
                    app.applyRepoLoad(null, async_allocator);
                    break :blk null;
                };
            }
            render_needed = true;
        }

        // Start a queued network op once nothing else is in flight.
        if (async_future == null) {
            if (app.async_requested) |op| {
                app.async_requested = null;
                app.async_active = true;
                async_job = .{ .io = io, .loop = &loop, .root = app.git.root, .environ = app.git.environ, .op = op };
                // A first push of an upstream-less branch carries the target.
                if (op == .push_set_upstream or op == .push_tag) {
                    async_job.upstream_remote = app.push_upstream_remote;
                    async_job.upstream_branch = app.push_upstream_branch;
                }
                // A per-remote fetch carries the remote name (appended after "fetch").
                if (op == .fetch_remote) async_job.upstream_remote = app.fetch_remote_name;
                // Attach entered credentials (a cloned, askpass-wired env) when
                // available; on clone failure fall back to the bare env.
                if (credentials_mod.gitCredentialsSet(app)) {
                    async_job.cred_environ = credentials_mod.buildCredentialEnv(app, async_allocator) catch null;
                }
                async_future = io.concurrent(asyncWorker, .{&async_job}) catch blk: {
                    if (async_job.cred_environ) |*e| {
                        e.deinit();
                        async_job.cred_environ = null;
                    }
                    app.async_active = false;
                    try app.completeAsync(op, null, async_allocator);
                    break :blk null;
                };
                render_needed = true;
            }
        }

        // Start the next queued preview once no preview worker is in flight.
        // Rapid selection moves coalesce: only the latest wanted job is kept,
        // so intermediate items are skipped rather than each spawning git.
        if (preview_future == null) {
            if (app.takePreviewJob()) |job| {
                preview_run = .{ .io = io, .loop = &loop, .root = app.git.root, .job = job };
                preview_future = io.concurrent(previewWorker, .{&preview_run}) catch blk: {
                    app.completePreview(job, null, async_allocator);
                    break :blk null;
                };
                render_needed = true;
            }
        }

        // Start the queued background working-tree refresh (the 1.5s tick) off
        // the loop, so the periodic git status never blocks navigation.
        if (worktree_future == null) {
            if (app.takeWorktreeRefresh()) |generation| {
                worktree_run = .{
                    .io = io,
                    .loop = &loop,
                    .root = app.git.root,
                    .environ = app.git.environ,
                    .untracked = app.git.untracked_files,
                    .generation = generation,
                    .result = null,
                };
                worktree_future = io.concurrent(worktreeWorker, .{&worktree_run}) catch blk: {
                    app.applyWorktreeSnapshot(null, generation, async_allocator) catch {};
                    break :blk null;
                };
            }
        }

        // Flush any pending stage/unstage toggles into a coalesced off-thread
        // batch (queued as a mutation below) so rapid space-staging never blocks
        // the UI thread on a synchronous `git add`.
        staging_mod.tryFlushStaging(app);

        // Start the queued slow mutation off the loop. Single in-flight; the
        // input gate keeps another mutation from being requested meanwhile.
        if (mutation_future == null) {
            if (app.takeMutation()) |mutation| {
                mutation_run = .{ .io = io, .loop = &loop, .root = app.git.root, .environ = app.git.environ, .mutation = mutation, .result = null };
                mutation_future = io.concurrent(mutationWorker, .{&mutation_run}) catch blk: {
                    try app.completeMutation(mutation, null, async_allocator);
                    break :blk null;
                };
                render_needed = true;
            }
        }

        // Start a queued per-view scoped refresh off the loop. Single in-flight;
        // further requests accumulate and run after this one. The active Commits
        // filter is copied for the worker so a filtered list stays filtered.
        if (scoped_load_future == null) {
            if (app.takeScopes()) |scopes| {
                const filters = app.logFilters();
                scoped_load_run = .{
                    .io = io,
                    .loop = &loop,
                    .root = app.git.root,
                    .environ = app.git.environ,
                    .scopes = scopes,
                    .grep = if (filters.grep) |g| async_allocator.dupe(u8, g) catch null else null,
                    .author = if (filters.author) |x| async_allocator.dupe(u8, x) catch null else null,
                    .path = if (filters.path) |p| async_allocator.dupe(u8, p) catch null else null,
                    .branch_sort = app.git.branch_sort,
                    .untracked = app.git.untracked_files,
                    .result = null,
                };
                scoped_load_future = io.concurrent(scopedLoadWorker, .{&scoped_load_run}) catch blk: {
                    app.applyScopedLoad(null, async_allocator);
                    scoped_load_run.freeFilters();
                    break :blk null;
                };
                render_needed = true;
            }
        }

        // Reflect foreground-busy state for the ticker (spinner animation speed).
        app.busy_flag.store(app.foregroundBusy(), .release);

        // Wall-clock time for the branches "time ago" column (unix seconds).
        app.now_unix = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));

        if (render_needed) try renderAndFlush(&vx, writer, app);
    }
}

/// Launch the requested editor on the file. A GUI editor (`suspend_tui` false)
/// is spawned with its stdio sent to /dev/null so it can't scribble on the alt
/// screen, and reaped. A terminal editor needs the terminal: stop the input
/// loop, leave the alt screen and restore cooked mode, run it to completion,
/// then re-enter raw + alt screen, restart the loop, and force a full repaint.
fn runEditor(
    loop: *vaxis.Loop(Event),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    writer: *std.Io.Writer,
    io: std.Io,
    app: *app_mod.App,
    req: app_mod.EditorRequest,
) void {
    const argv = [_][]const u8{ "sh", "-c", req.command };

    if (!req.suspend_tui) {
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .cwd = .{ .path = app.git.root },
            .environ_map = app.git.environ,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(io) catch {};
        return;
    }

    // Hand the terminal to a terminal editor. `tty.fd`/`tty.termios` exist only
    // on the real (posix) Tty, not the test stub — gate the raw/cooked switch.
    const has_termios = @hasField(vaxis.Tty, "fd") and @hasField(vaxis.Tty, "termios");
    loop.stop();
    vx.exitAltScreen(writer) catch {};
    vx.setMouseMode(writer, false) catch {};
    writer.writeAll(focus_events_reset) catch {};
    writer.flush() catch {};
    if (has_termios) std.posix.tcsetattr(tty.fd.handle, .FLUSH, tty.termios) catch {}; // cooked mode

    if (std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .path = app.git.root },
        .environ_map = app.git.environ,
    })) |child| {
        var c = child;
        _ = c.wait(io) catch {};
    } else |_| {}

    // Reclaim the terminal.
    if (has_termios) {
        _ = vaxis.Tty.makeRaw(tty.fd.handle) catch {};
    }
    vx.enterAltScreen(writer) catch {};
    vx.setMouseMode(writer, true) catch {};
    writer.writeAll(focus_events_set) catch {};
    writer.flush() catch {};
    vx.queryTerminal(writer, .fromSeconds(1)) catch {};
    loop.start() catch {};
    vx.queueRefresh(); // editor scribbled over the screen: repaint everything
}

/// ASCII spinner frame for `frame` (the renderer maps non-ASCII bytes to '?',
/// so the spinner stays ASCII).
fn spinnerGlyph(frame: usize) []const u8 {
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    return frames[frame % frames.len];
}

fn refreshTickerRun(state: *RefreshTicker) void {
    // Idle working-tree refresh cadence (configurable, default 10s). A tighter
    // interval makes `git status` thrash a large repo; 0 disables the periodic
    // refresh entirely (it still refreshes after ops and on focus).
    const interval_ms: u64 = @as(u64, state.app.config.refresh_interval_secs) * 1000;
    var idle_ms: u64 = 0;
    while (!state.stop.load(.acquire)) {
        // Always sleep the short spinner tick so the ticker re-checks the
        // busy state promptly; a freshly-started op then animates within one
        // tick instead of waiting out a long idle sleep.
        std.Io.sleep(state.io, spinner_tick, .awake) catch return;
        if (state.stop.load(.acquire)) return;
        if (state.app.busy_flag.load(.acquire)) {
            // Busy: animate the spinner on every fast tick.
            idle_ms = 0;
            _ = state.loop.tryPostEvent(.refresh_tick) catch false;
        } else if (interval_ms > 0) {
            // Idle: fire the periodic working-tree refresh only at the slower
            // cadence (built up from the fast ticks), not every tick.
            idle_ms += spinner_tick_ms;
            if (idle_ms >= interval_ms) {
                idle_ms = 0;
                _ = state.loop.tryPostEvent(.refresh_tick) catch false;
            }
        }
    }
}

fn renderAndFlush(vx: *vaxis.Vaxis, writer: anytype, app: *app_mod.App) !void {
    render(vx, app);
    try vx.render(writer);
    try writer.flush();
}

/// Backing context for `app.render_hook`, letting App repaint mid-handler so a
/// synchronous operation's "running" frame is visible before it blocks.
const RenderCtx = struct {
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    app: *app_mod.App,
};

fn renderHook(ctx: *anyopaque) void {
    const rc: *RenderCtx = @ptrCast(@alignCast(ctx));
    renderAndFlush(rc.vx, rc.writer, rc.app) catch {};
}

/// Side-panel column width: `percent` of the total terminal width, scaling
/// proportionally with it. A small floor keeps the panel usable on narrow
/// terminals, and at least 20 columns are reserved for the main panel. There is
/// deliberately no fixed upper cap, so the side panels keep growing on wide
/// terminals instead of stalling at a maximum width.
fn sidePanelWidth(total: u16, percent: u8) u16 {
    const raw: u16 = @intCast((@as(u32, total) * percent) / 100);
    const main_floor: u16 = if (total > 20) total - 20 else total;
    return @max(@as(u16, 20), @min(raw, main_floor));
}

const SidePanelHeights = struct { status: u16, files: u16, branches: u16, commits: u16, stash: u16 };

/// Side-panel sizing: the status panel is a fixed height; files,
/// branches and commits share the remaining space by weight (1 each); and the
/// stash panel is a small fixed height *unless it is focused*, in which case it
/// joins the weighted group. With the accordion (`expand_focused_side_panel`),
/// the focused list panel gets `expanded_weight` instead of 1, growing at the
/// others' expense. The returned heights always sum to `body_h`.
fn sidePanelHeights(body_h: u16, focused: model.Focus, accordion: bool, expanded_weight: u16) SidePanelHeights {
    const status_h: u16 = @min(body_h, 5);
    const stash_fixed: u16 = @min(body_h -| status_h, 3);
    const stash_focused = focused == .stash;

    // Weights for files, branches, commits, stash. Stash stays fixed (weight 0)
    // unless it is the focused panel.
    var weights = [4]u16{ 1, 1, 1, if (stash_focused) @as(u16, 1) else 0 };
    if (accordion) {
        const ew: u16 = @max(1, expanded_weight);
        switch (focused) {
            .files => weights[0] = ew,
            .branches => weights[1] = ew,
            .commits => weights[2] = ew,
            .stash => weights[3] = ew,
            else => {},
        }
    }

    const reserved = status_h + (if (stash_focused) @as(u16, 0) else stash_fixed);
    const dynamic = body_h -| reserved;
    const total = weights[0] + weights[1] + weights[2] + weights[3];
    const unit = if (total > 0) dynamic / total else 0;
    var rem = if (total > 0) dynamic % total else 0;

    var h = [4]u16{ unit * weights[0], unit * weights[1], unit * weights[2], unit * weights[3] };
    // Hand out the integer-division remainder one row at a time across the
    // weighted panels so the column fills `body_h` exactly.
    var i: usize = 0;
    while (rem > 0) : (i = (i + 1) % 4) {
        if (weights[i] > 0) {
            h[i] += 1;
            rem -= 1;
        }
    }

    return .{
        .status = status_h,
        .files = h[0],
        .branches = h[1],
        .commits = h[2],
        .stash = if (stash_focused) h[3] else stash_fixed,
    };
}

fn render(vx: *vaxis.Vaxis, app: *app_mod.App) void {
    const root = vx.window();
    root.clear();
    root.hideCursor();

    if (root.width < 50 or root.height < 15) {
        _ = root.printSegment(.{ .text = "ziggity needs at least 50x15", .style = styles().warning }, .{
            .row_offset = 0,
            .col_offset = 0,
            .wrap = .none,
        });
        return;
    }

    const bottom_h: u16 = 1;
    const body_h = root.height - bottom_h;
    const side_w = sidePanelWidth(root.width, app.config.side_panel_width_percent);
    const main_w = root.width - side_w;

    var y: u16 = 0;
    const heights = sidePanelHeights(
        body_h,
        app.contentFocus(),
        app.config.expand_focused_side_panel,
        app.config.expanded_side_panel_weight,
    );
    const status_h = heights.status;
    const files_h = heights.files;
    const branches_h = heights.branches;
    const commits_h = heights.commits;
    const stash_h = heights.stash;

    // Sync each list panel's view scroll to its visible height (inner = panel
    // height minus the border) before drawing: re-anchors to the selection if it
    // moved, leaves a wheel-scrolled view alone, and clamps to the content.
    app.syncListView(.files, files_h -| 2);
    app.syncListView(.branches, branches_h -| 2);
    app.syncListView(.commits, commits_h -| 2);
    app.syncListView(.stash, stash_h -| 2);

    // Capture panel hit-boxes for mouse handling.
    app.panel_rects = .{
        .{ .focus = .status, .x = 0, .y = 0, .w = side_w, .h = status_h },
        .{ .focus = .files, .x = 0, .y = status_h, .w = side_w, .h = files_h },
        .{ .focus = .branches, .x = 0, .y = status_h + files_h, .w = side_w, .h = branches_h },
        .{ .focus = .commits, .x = 0, .y = status_h + files_h + branches_h, .w = side_w, .h = commits_h },
        .{ .focus = .stash, .x = 0, .y = status_h + files_h + branches_h + commits_h, .w = side_w, .h = stash_h },
        .{ .focus = .main, .x = side_w, .y = 0, .w = main_w, .h = body_h },
    };
    app.panel_rect_count = 6;

    drawStatus(panel(root, 0, y, side_w, status_h, "[1] Status", app.focus == .status, null), app);
    y += status_h;
    {
        const files_tabs = [_][]const u8{ "Files", "Worktrees", "Submodules" };
        const w = tabbedPanel(root, 0, y, side_w, files_h, 2, &files_tabs, @intFromEnum(app.files_tab), "", app.focus == .files, listScrollInfo(app, .files));
        beginListPan(app, .files);
        switch (app.files_tab) {
            .files => drawFiles(w, app),
            .worktrees => drawWorktrees(w, app),
            .submodules => drawSubmodules(w, app),
        }
        endListPan(app, .files, w.width);
    }
    y += files_h;
    {
        // Drilled into a branch's sub-commits / files: a plain descriptive title.
        // Otherwise the title is the tab strip (Local / Remotes / Tags / …).
        const branches_tabs = [_][]const u8{ "Local", "Remotes", "Tags" };
        const w = if (app.branch_commits_active) blk: {
            const t = if (app.branchFilesActive())
                (if (patch_mod.branchFilesPatchCount(app) > 0)
                    (std.fmt.bufPrint(&app.branches_title_buf, "[3] Commit files (patch: {d}) (esc back)", .{patch_mod.branchFilesPatchCount(app)}) catch "[3] Commit files (esc back)")
                else
                    "[3] Commit files  (space: add to patch) (esc back)")
            else
                (std.fmt.bufPrint(&app.branches_title_buf, "[3] Commits ({s}) (esc back)", .{app.branch_commits_ref}) catch "[3] Commits (esc back)");
            break :blk panel(root, 0, y, side_w, branches_h, t, app.focus == .branches, listScrollInfo(app, .branches));
        } else if (app.remoteDrillActive()) blk: {
            // Drilled into a remote's branches.
            const t = std.fmt.bufPrint(&app.branches_title_buf, "[3] {s} (esc back)", .{app.remote_drill.?}) catch "[3] Remote (esc back)";
            break :blk panel(root, 0, y, side_w, branches_h, t, app.focus == .branches, listScrollInfo(app, .branches));
        } else tabbedPanel(root, 0, y, side_w, branches_h, 3, &branches_tabs, @intFromEnum(app.branches_tab), "", app.focus == .branches, listScrollInfo(app, .branches));
        beginListPan(app, .branches);
        drawBranches(w, app);
        endListPan(app, .branches, w.width);
    }
    y += branches_h;
    {
        const commits_tabs = [_][]const u8{ "Commits", "Reflog" };
        const w = if (app.commitsFilesActive()) blk: {
            const t = if (patch_mod.commitFilesPatchCount(app) > 0)
                (std.fmt.bufPrint(&app.commits_title_buf, "[4] Commit files (patch: {d}) (esc back)", .{patch_mod.commitFilesPatchCount(app)}) catch "[4] Commit files (esc back)")
            else
                "[4] Commit files  (space: add to patch) (esc back)";
            break :blk panel(root, 0, y, side_w, commits_h, t, app.focus == .commits, listScrollInfo(app, .commits));
        } else blk: {
            // Show an active commit-log filter (Commits tab only) after the tabs.
            var sbuf: [128]u8 = undefined;
            const suffix = if (app.commits_tab == .commits)
                (if (app.commitFilterLabel(&app.commit_filter_label_buf)) |label| (std.fmt.bufPrint(&sbuf, "({s})", .{label}) catch label) else "")
            else
                "";
            break :blk tabbedPanel(root, 0, y, side_w, commits_h, 4, &commits_tabs, @intFromEnum(app.commits_tab), suffix, app.focus == .commits, listScrollInfo(app, .commits));
        };
        beginListPan(app, .commits);
        drawCommits(w, app);
        endListPan(app, .commits, w.width);
    }
    y += commits_h;
    {
        const w = panel(root, 0, y, side_w, stash_h, "[5] Stash", app.focus == .stash, listScrollInfo(app, .stash));
        beginListPan(app, .stash);
        drawStash(w, app);
        endListPan(app, .stash, w.width);
    }

    const main_title = if (app.staging_patch_mode)
        "Building patch (esc back)"
    else if (app.staging_active)
        (if (app.staging_staged_view) "Staging - staged" else "Staging - unstaged")
    else if (app.diff_base) |diff_ref|
        (std.fmt.bufPrint(&app.main_title_buf, "Diff [base {s}]", .{diff_ref[0..@min(diff_ref.len, 16)]}) catch "Diff [diffing]")
    else if (app.contentFocus() == .branches and app.selectedBranchRefName() != null)
        // A selected branch/tag shows its commit graph, titled "Log".
        "Log"
    else
        "Diff";
    // Clamp the main panel's scroll to the current content (using the previous
    // frame's measured size) before drawing. Selecting a different item replaces
    // the preview without touching the scroll, so a scroll left over from a
    // longer/wider diff could otherwise skip past all of a shorter one and render
    // the panel blank.
    app.main_scroll = @min(app.main_scroll, app.maxMainScroll());
    app.main_hscroll = @min(app.main_hscroll, app.maxMainHScroll());
    if (app.staging_active and app.staging_split and !app.staging_patch_mode) {
        // Split staging view: two panes (Unstaged | Staged) fill the main area.
        drawStagingSplit(root, app, side_w, 0, main_w, body_h);
    } else {
        const scroll: ScrollInfo = .{ .len = app.mainContentLines(), .pos = app.main_scroll };
        // In the single-pane staging view, `[`/`]` switch the unstaged/staged
        // side, so show them as a highlighted tab strip.
        const main = if (app.staging_active and !app.staging_patch_mode) blk: {
            const staging_tabs = [_][]const u8{ "Unstaged", "Staged" };
            break :blk tabbedPanel(root, side_w, 0, main_w, body_h, null, &staging_tabs, @as(usize, if (app.staging_staged_view) 1 else 0), "", app.focus == .main, scroll);
        } else panel(root, side_w, 0, main_w, body_h, main_title, app.focus == .main, scroll);
        app.main_view_height = main.height;
        app.main_view_width = main.width;
        drawDiff(main, app);
    }
    // Indent the footer by one column so it lines up with the panel content
    // (just inside the left `│` border) and clears the terminal's rounded
    // bottom-left corner, which would otherwise clip the first character.
    drawBottom(root.child(.{ .x_off = 1, .y_off = @intCast(body_h), .width = root.width -| 1, .height = bottom_h }), app);

    // Centered popups render on top of everything else.
    switch (app.mode) {
        .status_filter_menu => drawStatusFilterPopup(root, app),
        .menu => drawMenuPopup(root, app),
        .confirmation => drawConfirmPopup(root, app),
        .commit_prompt => drawCommitPopup(root, app),
        .text_prompt => drawTextPromptPopup(root, app),
        .credential_prompt => drawCredentialPopup(root, app),
        .command_log => drawCommandLogPopup(root, app),
        .help => drawHelpPopup(root, app),
        .operation => drawOperationPopup(root, app),
        else => {},
    }
}

const help_lines = [_][]const u8{
    "Global",
    "  q / ctrl+c     quit",
    "  R              refresh",
    "  1-5            focus Status/Files/Branches/Commits/Stash",
    "  h/l, arrows    move between side panels",
    "  tab            focus the Diff panel (tab again returns)",
    "  j/k, arrows    move selection",
    "  H / L          scroll the focused panel left / right (long rows)",
    "  [ / ]          switch panel tabs / staging side",
    "  enter / esc    inspect in main panel / go back",
    "  @ / ?          command log / this help",
    "  z              undo the last operation (reflog reset)",
    "  ctrl+o         copy selected hash / branch / tag to the clipboard",
    "  o              open the selected commit / branch on its remote host",
    "  W              open the diffing menu (compare/reverse against a ref)",
    "  f / p / P      fetch / pull / push (async)",
    "  mouse drag     select text in the Diff panel (auto-copies on release)",
    "",
    "Files  (tabs: Files / Worktrees / Submodules - [ / ] to switch)",
    "  space          stage/unstage (whole dir in tree view)",
    "  a              stage/unstage all",
    "  c / A          commit (popup) / amend last commit",
    "  e              open the file in your editor (also from the staging,",
    "                 patch, and diff views; configurable, see README)",
    "  d / D          discard menu / discard all",
    "  s              stash menu (all / +untracked / staged / file)",
    "  / / ctrl+b     filter by path / status filter",
    "  `              toggle directory tree",
    "  enter          open the hunk/line staging view",
    "  m              merge/rebase actions: continue, amend+continue, abort",
    "  Worktrees tab  space/enter switch into it   n new   o open in editor   d remove",
    "  Submodules tab enter enter it   space update   n add   e edit URL   d remove   b bulk",
    "  (inside a worktree/submodule, esc walks back out to the parent repo)",
    "",
    "Staging view",
    "  j/k            move by line",
    "  v              toggle range selection",
    "  space          stage/unstage line(s); on @@ the whole hunk",
    "  [ / ]          switch unstaged / staged side",
    "  \\              toggle split view (unstaged | staged)",
    "  c / A          commit / amend the staged changes",
    "  e              open the file in your editor",
    "",
    "Branches  (tabs: Local / Remotes / Tags)",
    "  space          checkout the selected branch",
    "  c              checkout by name (type a branch/ref; \"-\" = previous)",
    "  n              new branch (new tag on the Tags tab)",
    "  R              rename branch",
    "  w              create a worktree checked out at the selected ref",
    "  d              delete branch / tag",
    "  M / r / f      merge / rebase / fast-forward",
    "",
    "Remotes tab  (two levels: the remotes list, then a remote's branches)",
    "  remotes list   enter/space view branches   n add   e edit (rename+URL)",
    "                 d remove   f fetch this remote",
    "  a remote's br. space checkout   n new local branch   M merge   r rebase",
    "                 g reset   u set upstream   d delete remote branch   esc back",
    "",
    "Tags tab",
    "  space          checkout the tag (detached HEAD)",
    "  n              new tag (then an optional message: empty = lightweight,",
    "                 a message makes it annotated; overwrite prompts to force)",
    "  P              push the tag to a remote",
    "  g              reset menu (soft / mixed / hard) onto the tag",
    "  d              delete menu (local / remote / both)",
    "",
    "Commits  (tabs: Commits / Reflog)",
    "  enter          view the commit's changed files",
    "  space / n      checkout the commit (detached) / new branch at it",
    "  g / t          reset menu / revert",
    "  c / v          copy commit to clipboard / paste (cherry-pick) onto HEAD",
    "  ctrl+r         clear the cherry-pick copy selection",
    "  d / s / f      drop / squash-down / fixup-down (interactive rebase)",
    "  e / r          edit (stop here) / reword",
    "  F / S          create fixup! commit / autosquash fixups above",
    "  B              mark base, then rebase a branch to move commits onto it",
    "  W              diff mode: compare against another ref",
    "  /              filter the log by message / author / path (esc clears)",
    "  b              bisect menu (start, then mark good/bad/skip/reset)",
    "  in a commit's files: space toggles a whole file into the patch,",
    "                 enter opens that file to pick individual lines,",
    "                 e opens the file in your editor",
    "  ctrl+p         custom patch menu (apply / remove from commit / reset)",
    "  ctrl+j/ctrl+k  move commit down / up",
    "  Reflog tab     a recovery view of where HEAD has been:",
    "                 space checkout the entry (detached), g reset HEAD to it,",
    "                 n new branch at it, c/v copy/paste, o browser, W diff.",
    "                 The history-rewriting keys (revert/rebase/fixup/…) do not",
    "                 apply to reflog entries.",
    "",
    "Stash",
    "  space / g / d  apply / pop / drop",
    "",
    "Operations",
    "  git actions    succeed silently (summary in the bottom bar); only",
    "                 failures pop a dialog (enter dismisses, up/down scroll)",
    "                 config: result_dialog = on_error | always | never",
    "  slow actions   merge/rebase/bisect/fast-forward/patch run in the",
    "                 background (spinner in Status); navigation stays live",
    "                 while they run, but other actions wait until they finish",
    "  fetch/pull/push run in the background (status in the bottom bar)",
};

fn drawHelpPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    // Size the popup to the longest line so nothing is cut on a wide terminal;
    // cap at the screen width and wrap any still-too-long line as a fallback.
    var longest: usize = 0;
    for (help_lines) |line| longest = @max(longest, line.len);
    const w: u16 = @intCast(@min(@as(usize, root.width -| 2), longest + 4));
    const content_w: u16 = w -| 2;

    const HelpLine = struct { text: []const u8, header: bool, focus: bool };
    var wrapped: [320]HelpLine = undefined;
    var total: usize = 0;
    // The first wrapped-line index of the section matching the current context,
    // so the dialog can open scrolled to it.
    var focus_start: ?usize = null;
    const want = app.help_focus_header;
    for (help_lines) |line| {
        // Section headers have no leading indent; their wrapped parts keep the style.
        const header = line.len > 0 and line[0] != ' ';
        if (line.len == 0) {
            if (total < wrapped.len) {
                wrapped[total] = .{ .text = "", .header = false, .focus = false };
                total += 1;
            }
            continue;
        }
        // Mark the (first) header that matches the wanted section as focused.
        const is_focus = header and focus_start == null and
            want != null and std.mem.startsWith(u8, line, want.?);
        var segs: [8][]const u8 = undefined;
        const n = wrapText(line, content_w, &segs);
        for (segs[0..n]) |s| {
            if (total >= wrapped.len) break;
            if (is_focus and focus_start == null) focus_start = total;
            wrapped[total] = .{ .text = s, .header = header, .focus = is_focus };
            total += 1;
        }
    }

    const h: u16 = @intCast(@min(@as(usize, root.height -| 1), total + 2));
    // The inner content height is `h` minus the top and bottom border rows; the
    // max scroll follows from it. Computed before `popup()` so the one-shot
    // jump below is reflected in the scrollbar it draws (no first-frame mismatch).
    const win_height: u16 = h -| 2;
    const max_scroll = if (total > win_height) total - win_height else 0;
    app.help_max_scroll = max_scroll; // so key handlers can clamp scrolling

    // One-shot on open: jump so the matched section header sits at the top
    // (clamped). Cleared here so subsequent up/down scrolling is left alone.
    if (app.help_scroll_to_focus) {
        if (focus_start) |fs| app.help_scroll = @min(fs, max_scroll);
        app.help_scroll_to_focus = false;
    }

    const win = popup(root, w, h, "Keybindings", .{ .len = total, .pos = app.help_scroll });

    const px0: u16 = (root.width - w) / 2;
    const py0: u16 = (root.height - h) / 2;
    app.beginDialogGrid(px0 + 1, py0 + 1, win.height);

    // The matched header is drawn as a full-width highlighted bar (an arrow
    // marker plus a selected-row background) so it stands out from the other,
    // plain-accent section headers.
    const focus_style: vaxis.Style = .{
        .fg = .{ .index = ui_theme.accent },
        .bg = .{ .index = ui_theme.selected_bg },
        .bold = true,
    };
    const start = @min(app.help_scroll, max_scroll);
    var row: u16 = 0;
    for (wrapped[start..total]) |wl| {
        if (row >= win.height) break;
        if (wl.focus) {
            fillRow(win, row, focus_style);
            drawDialogRow(win, app, row, wl.text, focus_style);
            // A right-edge "◀" pointer reinforces the highlight (drawn as a
            // static glyph so it survives the post-render flush).
            _ = printGlyph(win, row, win.width -| 2, glyph_focus_pointer, focus_style);
        } else {
            drawDialogRow(win, app, row, wl.text, if (wl.header) st.bottom_accent else st.normal);
        }
        row += 1;
    }
}

fn drawCommandLogPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const log = app.git.command_log.items;
    const w: u16 = @min(@as(u16, 90), root.width -| 4);
    const h: u16 = @min(@as(u16, 20), root.height -| 2);
    const win = popup(root, w, h, "Command log", null);
    const px0: u16 = (root.width - w) / 2;
    const py0: u16 = (root.height - h) / 2;
    app.beginDialogGrid(px0 + 1, py0 + 1, win.height);
    const footer_row: u16 = win.height -| 1;
    if (log.len == 0) {
        // Reset the scroll so the "open at bottom" sentinel (maxInt) can't
        // linger and overflow the next scroll keypress.
        app.command_log_max_scroll = 0;
        app.command_log_scroll = 0;
        print(win, 0, 0, "No commands run yet.", st.muted);
        print(win, footer_row, 0, "enter/esc close", st.bottom_accent);
        return;
    }
    // Wrap every command into visual lines (long ones wrap, not cut), then show
    // a scrolled window of them with the newest at the bottom.
    const cw = win.width;
    var vis: [512][]const u8 = undefined;
    var total: usize = 0;
    for (log) |entry| {
        var segs: [16][]const u8 = undefined;
        const n = wrapText(entry, cw, &segs);
        for (segs[0..n]) |s| {
            if (total >= vis.len) break;
            vis[total] = s;
            total += 1;
        }
    }
    const avail: usize = footer_row; // content rows above the footer
    app.command_log_max_scroll = total -| avail;
    app.command_log_scroll = @min(app.command_log_scroll, app.command_log_max_scroll);
    var idx: usize = app.command_log_scroll;
    var row: u16 = 0;
    while (idx < total and row < footer_row) : (idx += 1) {
        drawDialogRow(win, app, row, vis[idx], st.normal);
        row += 1;
    }
    drawScrollbarRange(root, px0 + w - 1, py0 + 1, avail, total, app.command_log_scroll, true);
    print(win, footer_row, 0, "up/down scroll   enter/esc close", st.bottom_accent);
}

fn drawOperationPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const w: u16 = @min(@as(u16, 86), root.width -| 4);
    const h: u16 = @min(@as(u16, 20), root.height -| 2);
    const title = if (app.op_running) "Running" else if (app.op_ok) "Done" else "Failed";
    const win = popup(root, w, h, title, null);
    const cw = win.width; // content width to wrap long lines into

    // Capture this render's content rows so the text can be mouse-selected.
    const px0: u16 = (root.width - w) / 2;
    const py0: u16 = (root.height - h) / 2;
    app.beginDialogGrid(px0 + 1, py0 + 1, win.height);

    // The command that is running / ran (wrapped).
    var cmd_lines: [3][]const u8 = undefined;
    const cmd_n = wrapText(app.op_command, cw, &cmd_lines);
    var row: u16 = 0;
    for (cmd_lines[0..cmd_n]) |ln| {
        drawDialogRow(win, app, row, ln, st.title);
        row += 1;
    }

    if (app.op_running) {
        print(win, row + 1, 0, "Running...", st.muted);
        return;
    }

    // Outcome summary, colored by success (wrapped).
    row += 1;
    var sum_lines: [4][]const u8 = undefined;
    const sum_n = wrapText(app.op_summary, cw, &sum_lines);
    for (sum_lines[0..sum_n]) |ln| {
        drawDialogRow(win, app, row, ln, if (app.op_ok) st.normal else st.warning);
        row += 1;
    }

    // Raw stdout/stderr below the summary, wrapped and scrollable by visual line.
    const footer_row: u16 = win.height -| 1;
    row += 1;
    const output_top = row;
    if (app.op_output.len > 0 and output_top < footer_row) {
        var vis: [256][]const u8 = undefined;
        const vis_n = wrapText(app.op_output, cw, &vis);
        const avail: usize = footer_row - output_top;
        app.op_max_scroll = vis_n -| avail; // clamp target for the key handler
        var idx: usize = @min(app.op_scroll, app.op_max_scroll);
        while (idx < vis_n and row < footer_row) : (idx += 1) {
            drawDialogRow(win, app, row, vis[idx], st.muted);
            row += 1;
        }
        // Scrollbar over just the output region, on the popup's right border
        // (same centering as popup(), mapped back to root coordinates).
        drawScrollbarRange(root, px0 + w - 1, py0 + 1 + output_top, avail, vis_n, app.op_scroll, true);
    } else {
        app.op_max_scroll = 0;
    }

    print(win, footer_row, 0, "enter dismiss   up/down scroll", st.bottom_accent);
}

fn drawTextPromptPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const kind = app.text_prompt_kind orelse return;
    const w: u16 = @min(@as(u16, 64), root.width -| 4);
    const win = popup(root, w, 5, kind.title(), null);
    // Horizontally scroll so the caret stays inside the box:
    // render the buffer starting at the scroll origin instead of clipping it.
    const caret = @min(app.prompt_cursor, app.input_buffer.items.len);
    const sc = app_mod.viewScroll(app.prompt_scroll, win.width, caret);
    app.prompt_scroll = sc.origin;
    print(win, 0, 0, app.input_buffer.items[sc.origin..], st.normal);
    print(win, 2, 0, "enter confirm   esc cancel", st.bottom_accent);
    win.showCursor(@intCast(sc.view), 0);
}

fn drawCredentialPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const w: u16 = @min(@as(u16, 56), root.width -| 4);
    const win = popup(root, w, 5, credentials_mod.credentialTitle(app), null);
    // Scroll horizontally so the caret stays inside the box.
    const caret = @min(app.prompt_cursor, app.input_buffer.items.len);
    const sc = app_mod.viewScroll(app.prompt_scroll, win.width, caret);
    app.prompt_scroll = sc.origin;
    const visible = app.input_buffer.items[sc.origin..];
    if (credentials_mod.credentialMask(app)) {
        // Mask the secret with bullets, one per byte (credentials are ASCII, so
        // a byte maps to a column). A bullet is used instead of `*` because a
        // run of identical asterisks can be reshaped by the terminal font's
        // ligature/contextual rules, making earlier glyphs visibly shift as more
        // are typed; the dedicated bullet mask is not subject to that.
        const n = @min(visible.len, @as(usize, win.width));
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            win.writeCell(i, 0, .{ .char = .{ .grapheme = "\u{2022}", .width = 1 }, .style = st.normal });
        }
    } else {
        print(win, 0, 0, visible, st.normal);
    }
    print(win, 2, 0, "enter confirm   esc cancel", st.bottom_accent);
    win.showCursor(@intCast(sc.view), 0);
}

fn drawCommitPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const subject_focused = app.commit_field == .subject;
    const w: u16 = @min(@as(u16, 72), root.width -| 4);
    const title = if (app.commit_action == .reword) "Reword commit" else "Commit message";
    const win = popup(root, w, 12, title, null);

    // Field labels indicate which has focus.
    print(win, 0, 0, "Summary", if (subject_focused) st.active_title else st.muted);
    print(win, 3, 0, "Description (optional)", if (subject_focused) st.muted else st.active_title);

    // Summary: single line at row 1, scrolled horizontally to keep the caret in.
    const subj = app.commit_buffer.items;
    const subj_caret = @min(app.commit_cursor, subj.len);
    const subj_sc = app_mod.viewScroll(app.commit_scroll, win.width, subj_caret);
    app.commit_scroll = subj_sc.origin;
    print(win, 1, 0, subj[subj_sc.origin..], st.normal);

    // Body: multi-line area from row 4 down to the footer, scrolled in both axes.
    const body_top: u16 = 4;
    const footer_row: u16 = win.height -| 1;
    const body_h: usize = if (footer_row > body_top) footer_row - body_top else 0;
    const body = app.commit_body_buffer.items;
    const b_caret = @min(app.commit_body_cursor, body.len);
    var caret_line: usize = 0;
    var caret_col: usize = 0;
    for (body[0..b_caret]) |b| {
        if (b == '\n') {
            caret_line += 1;
            caret_col = 0;
        } else caret_col += 1;
    }
    const scy = app_mod.viewScroll(app.commit_body_scroll_y, body_h, caret_line);
    const scx = app_mod.viewScroll(app.commit_body_scroll_x, win.width, caret_col);
    app.commit_body_scroll_y = scy.origin;
    app.commit_body_scroll_x = scx.origin;

    var lines = std.mem.splitScalar(u8, body, '\n');
    var idx: usize = 0;
    var drawn: usize = 0;
    while (lines.next()) |line| : (idx += 1) {
        if (idx < scy.origin) continue;
        if (drawn >= body_h) break;
        const row: u16 = body_top + @as(u16, @intCast(drawn));
        if (scx.origin < line.len) print(win, row, 0, line[scx.origin..], st.normal);
        drawn += 1;
    }

    // Scrollbar over the multi-line description when it overflows, on the right
    // border (same centering as popup(); the popup height is the fixed 12).
    const body_lines = std.mem.count(u8, body, "\n") + 1;
    const px: u16 = (root.width - w) / 2;
    const py: u16 = (root.height - 12) / 2;
    drawScrollbarRange(root, px + w - 1, py + 1 + body_top, body_h, body_lines, scy.origin, !subject_focused);

    print(win, footer_row, 0, "tab: switch field   enter: commit / newline   esc: cancel", st.bottom_accent);

    if (subject_focused) {
        win.showCursor(@intCast(subj_sc.view), 1);
    } else {
        const cursor_row: u16 = body_top + @as(u16, @intCast(caret_line - scy.origin));
        win.showCursor(@intCast(scx.view), cursor_row);
    }
}

/// Centered, bordered, opaque popup window. Fills its region first so the
/// panels underneath do not bleed through, draws a rounded border and a title,
/// and returns the inner content window.
/// One popup is visible at a time, so a single module-owned buffer backs its
/// title (see the note in `popup`).
var popup_title_buf: [256]u8 = undefined;

fn popup(root: vaxis.Window, width: u16, height: u16, title: []const u8, scroll: ?ScrollInfo) vaxis.Window {
    const w = @min(@max(width, 8), root.width);
    const h = @min(@max(height, 3), root.height);
    const x: u16 = (root.width - w) / 2;
    const y: u16 = (root.height - h) / 2;
    const raw = root.child(.{ .x_off = x, .y_off = y, .width = w, .height = h });
    var row: u16 = 0;
    while (row < h) : (row += 1) fillRow(raw, row, styles().normal);
    const inner = raw.child(.{
        .border = .{
            .where = .all,
            .style = styles().active_border,
            .glyphs = .single_rounded,
        },
    });
    // vaxis stores a cell's grapheme by reference and the frame is flushed after
    // render() returns, so a title passed via `printSegment` must outlive this
    // call. Copy it into the module buffer so callers may pass a stack-built
    // string safely. (The local `print*` helpers map bytes through static glyphs,
    // so list/body text drawn with them needs no such care.)
    const n = @min(title.len, popup_title_buf.len);
    @memcpy(popup_title_buf[0..n], title[0..n]);
    _ = raw.printSegment(.{ .text = popup_title_buf[0..n], .style = styles().active_title }, .{
        .row_offset = 0,
        .col_offset = 2,
        .wrap = .none,
    });
    if (scroll) |s| drawScrollbar(raw, s.len, s.pos, true);
    return inner;
}

fn drawStatusFilterPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const options = app_mod.status_filter_options;
    const w: u16 = 38;
    const h: u16 = @intCast(options.len + 2);
    const win = popup(root, w, h, "Status filter", null);
    for (options, 0..) |option, idx| {
        var buf: [64]u8 = undefined;
        const marker: u8 = if (option == app.file_display_filter) '*' else ' ';
        const line = std.fmt.bufPrint(&buf, "{c} {s}", .{ marker, option.label() }) catch option.label();
        drawSelectable(win, @intCast(idx), line, st.normal, selOf(idx == app.status_filter_index, true));
    }
}

fn drawMenuPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const menu = app.active_menu orelse return;
    var max_label: usize = menu.title.len;
    for (menu.items) |item| max_label = @max(max_label, item.label.len);
    const w: u16 = @intCast(@min(@as(usize, 72), max_label + 6));
    const h: u16 = @intCast(menu.items.len + 2);
    const win = popup(root, w, h, menu.title, null);
    for (menu.items, 0..) |item, idx| {
        drawSelectable(win, @intCast(idx), item.label, st.normal, selOf(idx == menu.index, true));
    }
}

fn drawConfirmPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    // Use the App-owned buffer (not a stack one) so the rows recorded for mouse
    // selection below stay valid when the selection is copied between frames.
    const text = app.confirmationText(&app.confirm_text_buf);
    const title = switch (app.pending_confirmation orelse .discard_all) {
        .discard_all => "Discard all changes",
        .merge_branch => "Merge branch",
        .rebase_branch => "Rebase branch",
        .delete_tag => "Delete tag",
        .force_tag => "Overwrite tag",
        .delete_remote_branch => "Delete remote branch",
        .remove_worktree => "Remove worktree",
        .remove_submodule => "Remove submodule",
        .remove_remote => "Remove remote",
        .merge_remote => "Merge remote branch",
        .rebase_remote => "Rebase onto remote branch",
        .undo => "Undo",
        .force_push, .force_push_plain => "Force push",
        .delete_index_lock => "Git locked",
        .reset_patch => "Discard patch",
    };
    // Wrap the message so a long prompt (e.g. a worktree path) stays readable
    // inside the box instead of being clipped, growing the popup's height.
    const content_w: u16 = @min(@as(u16, 64), root.width -| 6);
    var lines: [24][]const u8 = undefined;
    const n = wrapText(text, content_w, &lines);
    var longest: usize = 34; // keep room for the footer hint (its full width)
    for (lines[0..n]) |ln| longest = @max(longest, ln.len);
    const w: u16 = @intCast(@min(@as(usize, root.width -| 2), longest + 4));
    // Inner height needs n text rows + a blank + the footer row; +2 more for the
    // border, so the popup is n + 4 tall (clamped to the screen).
    const h: u16 = @intCast(@min(@as(usize, root.height -| 2), n + 4));
    const win = popup(root, w, h, title, null);
    const px0: u16 = (root.width - w) / 2;
    const py0: u16 = (root.height - h) / 2;
    app.beginDialogGrid(px0 + 1, py0 + 1, win.height);
    const shown = @min(n, @as(usize, win.height -| 1)); // keep the footer row clear
    // drawDialogRow records each row so the message can be selected and copied
    // with the mouse (drag to select, release to copy), like the other popups.
    for (lines[0..shown], 0..) |ln, idx| drawDialogRow(win, app, @intCast(idx), ln, st.normal);
    print(win, win.height -| 1, 0, "(y/enter) confirm   (n/esc) cancel", st.bottom_accent);
}

/// Content size and scroll position for a panel's scrollbar. `len` is the total
/// number of lines/items, `pos` the index of the first visible one.
const ScrollInfo = struct { len: usize, pos: usize };

const scrollbar_glyph = "▐"; // U+2590, drawn on the right border

/// Scrollbar info for a list panel: total items and the current view offset.
fn listScrollInfo(app: *const app_mod.App, focus: model.Focus) ScrollInfo {
    return .{ .len = app.activeListLen(focus), .pos = app.listScroll(focus) };
}

/// `title` is drawn via `printSegment`, which keeps a reference to the bytes
/// until the post-render flush — so it must be a string literal or App-owned
/// memory (e.g. `app.*_title_buf`), never a stack buffer local to `render`.
/// Draw a panel's rounded border + scrollbar and return the outer (`raw`, for
/// the title row) and inner (content) windows. `raw == inner` when too small.
const PanelFrame = struct { raw: vaxis.Window, inner: vaxis.Window };
fn panelBorder(root: vaxis.Window, x: u16, y: u16, w: u16, h: u16, focused: bool, scroll: ?ScrollInfo) PanelFrame {
    const raw = root.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w, .height = h });
    if (w < 4 or h < 3) return .{ .raw = raw, .inner = raw };
    const st = styles();
    const border_style = if (focused) st.active_border else st.inactive_border;
    const inner = raw.child(.{
        .border = .{
            .where = .all,
            .style = border_style,
            .glyphs = .single_rounded,
        },
    });
    if (scroll) |s| drawScrollbar(raw, s.len, s.pos, focused);
    return .{ .raw = raw, .inner = inner };
}

fn panel(root: vaxis.Window, x: u16, y: u16, w: u16, h: u16, title: []const u8, focused: bool, scroll: ?ScrollInfo) vaxis.Window {
    const frame = panelBorder(root, x, y, w, h, focused, scroll);
    if (w < 4 or h < 3) return frame.inner;
    const st = styles();
    _ = frame.raw.printSegment(.{ .text = title, .style = if (focused) st.active_title else st.title }, .{
        .row_offset = 0,
        .col_offset = 2,
        .wrap = .none,
    });
    return frame.inner;
}

/// Write `text` on the title row at column `col` (clipped to leave the last
/// column for the border), returning the column after it. Uses `printSpan`,
/// which copies each byte into its cell via the glyph table — unlike vaxis
/// `printSegment`, which stores the grapheme *by reference* and would render
/// garbage when the title is backed by a stack buffer (the `[N]` / filter text).
fn drawTitleSpan(raw: vaxis.Window, w: u16, col: u16, text: []const u8, style: vaxis.Style) u16 {
    const limit = w -| 1;
    if (col >= limit) return col;
    const avail = limit - col;
    const shown = if (text.len > avail) text[0..avail] else text;
    return printSpan(raw, 0, col, shown, style);
}

/// A panel whose title is the strip of views that `[`/`]` switches between (the
/// active one highlighted, the rest dimmed), joined by " - ". `number` is the
/// optional `[N]` focus-key hint; `suffix` is trailing text (e.g. a filter).
fn tabbedPanel(root: vaxis.Window, x: u16, y: u16, w: u16, h: u16, number: ?u8, tabs: []const []const u8, active: usize, suffix: []const u8, focused: bool, scroll: ?ScrollInfo) vaxis.Window {
    const frame = panelBorder(root, x, y, w, h, focused, scroll);
    if (w < 4 or h < 3) return frame.inner;
    const st = styles();
    const active_style = if (focused) st.active_title else st.title;

    var col: u16 = 2;
    if (number) |n| {
        var nbuf: [8]u8 = undefined;
        col = drawTitleSpan(frame.raw, w, col, std.fmt.bufPrint(&nbuf, "[{d}] ", .{n}) catch "", st.title);
    }
    for (tabs, 0..) |tab, i| {
        if (i > 0) col = drawTitleSpan(frame.raw, w, col, " - ", st.muted);
        col = drawTitleSpan(frame.raw, w, col, tab, if (i == active) active_style else st.muted);
    }
    if (suffix.len > 0) {
        col = drawTitleSpan(frame.raw, w, col, " ", st.muted);
        _ = drawTitleSpan(frame.raw, w, col, suffix, st.muted);
    }
    return frame.inner;
}

/// Draw a proportional scrollbar thumb on a panel's right border when its
/// content is taller than the visible area (otherwise nothing). The thumb size
/// reflects the visible fraction and its position the scroll offset.
const Thumb = struct { start: usize, size: usize };

/// Thumb position/size for a `track`-row scrollbar over `len` items scrolled to
/// `pos`. Null when the content fits (no scrollbar needed).
fn scrollbarThumb(track: usize, len: usize, pos: usize) ?Thumb {
    if (track < 1 or len <= track) return null;
    const max_scroll = len - track;
    var size = (track * track) / len; // proportional to the visible fraction
    if (size < 1) size = 1;
    if (size > track) size = track;
    const span = track - size; // travel range
    const p = @min(pos, max_scroll);
    const start = if (max_scroll == 0) 0 else (p * span) / max_scroll;
    return .{ .start = start, .size = size };
}

/// Draw a scrollbar thumb in `win` at column `col`, over a `track`-row region
/// starting at `top`, for `len` items scrolled to `pos`. Nothing if it fits.
fn drawScrollbarRange(win: vaxis.Window, col: u16, top: u16, track: usize, len: usize, pos: usize, focused: bool) void {
    const t = scrollbarThumb(track, len, pos) orelse return;
    const st = styles();
    const style = if (focused) st.active_border else st.inactive_border;
    var i: usize = 0;
    while (i < t.size) : (i += 1) {
        win.writeCell(col, @intCast(top + t.start + i), .{ .char = .{ .grapheme = scrollbar_glyph, .width = 1 }, .style = style });
    }
}

/// Scrollbar on a bordered window's right edge, spanning its inner height.
fn drawScrollbar(raw: vaxis.Window, len: usize, pos: usize, focused: bool) void {
    drawScrollbarRange(raw, raw.width - 1, 1, raw.height -| 2, len, pos, focused);
}

fn drawStatus(win: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();

    // Line 0: [<parent> / ...] <repo> → <branch>  <ahead/behind status>
    const repo = std.fs.path.basename(app.git.root);
    var col: u16 = 0;
    // Breadcrumb of parent repos when drilled into a worktree/submodule (esc
    // walks back out one level at a time).
    for (app.repo_stack.items) |parent| {
        col = printSpan(win, 0, col, std.fs.path.basename(parent), st.muted);
        col = printSpan(win, 0, col, " / ", st.muted);
    }
    col = printSpan(win, 0, col, repo, st.normal);
    col = printSpan(win, 0, col, " ", st.muted);
    col = printGlyph(win, 0, col, glyph_to_branch, st.muted);
    col = printSpan(win, 0, col, " ", st.muted);
    col = printSpan(win, 0, col, app.data.current_branch, st.active_title);
    col = printSpan(win, 0, col, " ", st.muted);
    if (app.data.upstream_gone) {
        // The upstream was deleted on the remote — flag it (red), matching the
        // branches panel, instead of a misleading "in sync" tick.
        _ = printSpan(win, 0, col, "(upstream gone)", withFg(st.muted, ui_theme.unstaged));
    } else {
        _ = drawBranchStatus(win, 0, col, st.muted, app.data.upstream != null, app.data.ahead orelse 0, app.data.behind orelse 0);
    }

    // Line 1: a running foreground op (network or slow mutation) takes
    // priority with an animated spinner, then merge/rebase state, then a
    // worktree summary.
    if (app.foregroundBusy()) {
        const gerund = if (app.initial_load_pending)
            "loading"
        else if (app.mutation_active or app.mutation_requested != null)
            app.mutation_gerund
        else
            app.async_op.gerund();
        var buf: [80]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}...", .{ spinnerGlyph(app.spinner_frame), gerund }) catch "working...";
        print(win, 1, 0, line, st.bottom_accent);
    } else if (app.data.state != .clean) {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} - m: continue / abort", .{app.data.state.label()}) catch app.data.state.label();
        print(win, 1, 0, line, st.warning);
    } else if (app.data.bisecting) {
        print(win, 1, 0, "BISECTING - b: mark good/bad/skip/reset", st.warning);
    } else if (app.data.files.len == 0) {
        print(win, 1, 0, "working tree clean", st.muted);
    } else {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d} staged, {d} unstaged", .{ app.data.stagedCount(), app.data.unstagedCount() }) catch "";
        print(win, 1, 0, line, st.muted);
    }

    // Line 2: active filter, if any.
    if (app.anyFileFilterActive()) {
        var filter_buf: [256]u8 = undefined;
        const line = if (app.fileDisplayFilterActive() and app.fileFilterActive())
            std.fmt.bufPrint(&filter_buf, "filter {s} {d}/{d} {s}", .{ app.file_display_filter.label(), app.visibleFileCount(), app.data.files.len, app.file_filter }) catch return
        else if (app.fileDisplayFilterActive())
            std.fmt.bufPrint(&filter_buf, "filter {s} {d}/{d}", .{ app.file_display_filter.label(), app.visibleFileCount(), app.data.files.len }) catch return
        else
            std.fmt.bufPrint(&filter_buf, "filter {d}/{d} {s}", .{ app.visibleFileCount(), app.data.files.len, app.file_filter }) catch return;
        print(win, 2, 0, line, st.muted);
    }
}

fn drawFiles(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.files.len == 0) {
        print(win, 0, 0, if (app.initial_load_pending) "Loading..." else "Working tree clean", styles().muted);
        return;
    }
    if (app.tree_view) return drawFileTree(win, app);
    const visible_count = app.visibleFileCount();
    if (visible_count == 0) {
        print(win, 0, 0, "No files match filter", styles().muted);
        return;
    }
    const start = app.listScroll(.files);
    var row: u16 = 0;
    var ordinal: usize = 0;
    for (app.data.files, 0..) |file, idx| {
        if (!app.fileMatchesFilter(file)) continue;
        if (ordinal < start) {
            ordinal += 1;
            continue;
        }
        if (row >= win.height) break;
        var base = styles().normal;
        const sel = selOf(idx == app.file_index, app.focus == .files);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);
        // The two short-status columns are colored independently:
        // the index/staged column green, the worktree/unstaged column red — so a
        // half-staged "MM" shows one green M and one red M.
        var col = printSpan(win, row, 0, file.short_status[0..1], statusCharStyle(file.short_status[0], true, file.conflict, base));
        col = printSpan(win, row, col, file.short_status[1..2], statusCharStyle(file.short_status[1], false, file.conflict, base));
        col = printSpan(win, row, col, " ", base);
        const path_style = if (file.conflict) withFg(base, ui_theme.warning) else if (file.has_unstaged) withFg(base, ui_theme.unstaged) else if (file.has_staged) withFg(base, ui_theme.staged) else base;
        if (file.previous_path) |previous| {
            col = printSpan(win, row, col, previous, path_style);
            col = printSpan(win, row, col, " -> ", base);
            _ = printSpan(win, row, col, file.path, path_style);
        } else {
            _ = printSpan(win, row, col, file.path, path_style);
        }
        ordinal += 1;
        row += 1;
    }
}

/// Style for one of the two `git status` short-status columns. The index
/// (staged) column is green, the worktree (unstaged) column red; untracked '?'
/// is red, a blank is muted, and a conflicted file is the warning color.
/// Preserves `base`'s background/bold so selection highlighting is kept.
fn statusCharStyle(c: u8, is_index: bool, conflict: bool, base: vaxis.Style) vaxis.Style {
    if (conflict) return withFg(base, ui_theme.warning);
    if (c == ' ') return withFg(base, ui_theme.muted);
    if (c == '?') return withFg(base, ui_theme.unstaged);
    return withFg(base, if (is_index) ui_theme.staged else ui_theme.unstaged);
}

/// Draw a tree row's indentation and — for a directory — its collapse glyph and
/// name (the synthetic root, an empty path, shows as "/"). Returns the column a
/// file row should continue from (directory rows are fully drawn here).
fn drawTreeRowPrefix(win: vaxis.Window, row: u16, base: vaxis.Style, tr: filetree.Row) u16 {
    const indent: usize = @min(@as(usize, tr.depth) * 2, indent_spaces.len);
    var col = printSpan(win, row, 0, indent_spaces[0..indent], base);
    if (tr.is_dir) {
        col = printGlyph(win, row, col, if (tr.collapsed) glyph_collapsed else glyph_expanded, withFg(base, 12));
        col = printSpan(win, row, col, " ", base);
        if (tr.path.len == 0) {
            _ = printSpan(win, row, col, "/", withFg(base, 12));
        } else {
            // Display the segment(s) below the parent — for a compressed chain
            // this is the whole "a/b/c", otherwise just the directory name.
            col = printSpan(win, row, col, tr.path[tr.name_off..], withFg(base, 12));
            _ = printSpan(win, row, col, "/", withFg(base, 12));
        }
    }
    return col;
}

fn drawFileTree(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.files_tree.rows.len == 0) {
        print(win, 0, 0, "No files match filter", styles().muted);
        return;
    }
    const start = app.listScroll(.files);
    var row: u16 = 0;
    var i = start;
    while (i < app.files_tree.rows.len and row < win.height) : ({
        i += 1;
        row += 1;
    }) {
        const tr = app.files_tree.rows[i];
        var base = styles().normal;
        const sel = selOf(i == app.files_tree.cursor, app.focus == .files);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);

        var col = drawTreeRowPrefix(win, row, base, tr);
        if (tr.is_dir) continue;

        const file = app.data.files[tr.file_index];
        // Two status columns colored independently, like the flat list.
        col = printSpan(win, row, col, file.short_status[0..1], statusCharStyle(file.short_status[0], true, file.conflict, base));
        col = printSpan(win, row, col, file.short_status[1..2], statusCharStyle(file.short_status[1], false, file.conflict, base));
        col = printSpan(win, row, col, " ", base);
        const name_fg: u8 = if (file.conflict) ui_theme.warning else if (file.has_unstaged) ui_theme.unstaged else ui_theme.staged;
        _ = printSpan(win, row, col, std.fs.path.basename(tr.path), withFg(base, name_fg));
    }
}

fn drawBranches(win: vaxis.Window, app: *const app_mod.App) void {
    // Sub-commits drill: the Branches panel shows the ref's commits, or (one
    // level deeper) the selected commit's files.
    if (app.branch_commits_active) {
        if (app.branchFilesActive()) {
            const patch_active = patch_mod.branchFilesPatchCount(app) > 0;
            if (app.tree_view) return drawCommitFileTree(win, app, app.branch_files, &app.branch_tree, .branches, patch_active);
            return drawCommitFiles(win, app, app.branch_files, app.branch_file_index, .branches, patch_active);
        }
        if (app.branch_commits.len == 0) {
            print(win, 0, 0, "No commits", styles().muted);
            return;
        }
        return drawCommitRows(win, app, app.branch_commits, app.branch_commit_index, .branches);
    }
    if (app.branches_tab == .tags) return drawTags(win, app);
    // Remotes tab, level 0: the list of remotes (drills into branches on enter).
    if (app.remotesListActive()) return drawRemotesList(win, app);

    var branches: []const model.Branch = app.data.branches;
    var selected: usize = app.branch_index;
    if (app.remoteDrillActive()) {
        const r = app.drilledRemoteRange() orelse {
            print(win, 0, 0, if (app.initial_load_pending) "Loading..." else "No remote branches", styles().muted);
            return;
        };
        branches = app.data.remote_branches[r.start..r.end];
        selected = app.remote_index - r.start;
    }
    if (branches.len == 0) {
        const empty_label = if (app.initial_load_pending) "Loading..." else "No branches";
        print(win, 0, 0, empty_label, styles().muted);
        return;
    }
    const start = app.listScroll(.branches);
    const now = app.now_unix;
    var row: u16 = 0;
    var idx = start;
    while (idx < branches.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const branch = branches[idx];
        const marker: u8 = if (branch.current) '*' else ' ';

        const base = blk: {
            var s = if (branch.current) styles().staged else styles().normal;
            const sel = selOf(idx == selected, app.focus == .branches);
            applySel(&s, sel);
            if (sel != .none) fillRow(win, row, s);
            break :blk s;
        };

        var end: u16 = 0;
        // Local branches lead with a compact "time ago" recency column (green
        // for the current branch, cyan otherwise).
        if (app.branches_tab == .local) {
            var rbuf: [8]u8 = undefined;
            const rec = recencyStr(&rbuf, branch.commit_time, now);
            const pad: usize = if (rec.len < 3) 3 - rec.len else 0;
            end = printSpan(win, row, end, indent_spaces[0..pad], base);
            end = printSpan(win, row, end, rec, withFg(base, if (branch.current) ui_theme.staged else ui_theme.accent));
            end = printSpan(win, row, end, " ", base);
        }

        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{c} {s}", .{ marker, branch.name }) catch branch.name;
        end = printSpan(win, row, end, line, base);

        // The Remotes tab shows just the ref name. Local branches show their
        // tracking status: ahead/behind (per-branch), in-sync (✓), or gone — and
        // the upstream ref only when it isn't the obvious origin/<same-name>.
        if (app.branches_tab == .local) {
            if (branch.upstream_gone) {
                end = printSpan(win, row, end, " ", base);
                _ = printSpan(win, row, end, "(gone)", withFg(base, ui_theme.unstaged));
            } else if (branch.upstream) |upstream| {
                if (!upstreamIsDefault(branch.name, upstream)) {
                    end = printSpan(win, row, end, " ", base);
                    end = printGlyph(win, row, end, glyph_to_branch, withFg(base, ui_theme.muted));
                    end = printSpan(win, row, end, " ", base);
                    end = printSpan(win, row, end, upstream, withFg(base, ui_theme.muted));
                }
                end = printSpan(win, row, end, " ", base);
                _ = drawBranchStatus(win, row, end, base, true, branch.ahead, branch.behind);
            }
        }
    }
}

/// Compact "time ago" for a commit unix timestamp `ts` relative to `now`, into
/// `buf` (e.g. "5s", "3m", "2h", "4d", "6w", "2M", "1y"). Empty when `ts` is
/// unknown. Mirrors git's `--date=relative` rounding (rounds to the nearest
/// unit, switching units at 90s/90m/36h/14d/70d/365d) rather than truncating —
/// so e.g. a ~2-year-old commit reads "2y", not "1y". Capital M is months,
/// lowercase m is minutes.
fn recencyStr(buf: []u8, ts: i64, now: i64) []const u8 {
    if (ts <= 0) return "";
    const p = struct {
        fn f(b: []u8, n: i64, unit: []const u8) []const u8 {
            return std.fmt.bufPrint(b, "{d}{s}", .{ n, unit }) catch "";
        }
    }.f;
    var d: i64 = if (now > ts) now - ts else 0;
    if (d < 90) return p(buf, d, "s");
    d = @divFloor(d + 30, 60); // minutes (rounded)
    if (d < 90) return p(buf, d, "m");
    d = @divFloor(d + 30, 60); // hours
    if (d < 36) return p(buf, d, "h");
    d = @divFloor(d + 12, 24); // days
    if (d < 14) return p(buf, d, "d");
    if (d < 70) return p(buf, @divFloor(d + 3, 7), "w");
    if (d < 365) return p(buf, @divFloor(d + 15, 30), "M");
    // Years from total months, accounting for 365.25 days/year (git's formula).
    const total_months = @divFloor(d * 12 * 100 + 91500, 36525);
    return p(buf, @divFloor(total_months, 12), "y");
}

/// Whether `upstream` is the obvious default for `name` — `origin/<same-name>` —
/// so its display can be elided. A differently-named ref or a non-origin remote
/// is still shown (it's information the bare status can't convey).
fn upstreamIsDefault(name: []const u8, upstream: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, upstream, '/') orelse return false;
    return std.mem.eql(u8, upstream[0..slash], "origin") and std.mem.eql(u8, upstream[slash + 1 ..], name);
}

/// Remotes tab, level 0: the list of remotes with their branch counts. <enter>
/// drills into the selected remote's branches.
fn drawRemotesList(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.remotes.len == 0) {
        print(win, 0, 0, if (app.initial_load_pending) "Loading..." else "No remotes", styles().muted);
        return;
    }
    const start = app.listScroll(.branches);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.remotes.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const remote = app.data.remotes[idx];
        var base = styles().normal;
        const sel = selOf(idx == app.remotes_index, app.focus == .branches);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);
        const col = printSpan(win, row, 0, remote.name, base);
        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, " ({d})", .{app.remoteBranchCount(remote.name)}) catch "";
        _ = printSpan(win, row, col, count, withFg(base, ui_theme.accent));
    }
}

fn drawTags(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.tags.len == 0) {
        print(win, 0, 0, "No tags", styles().muted);
        return;
    }
    // Align every subject into one column at the widest tag name (+2 gap), so
    // the annotations line up instead of starting at a ragged edge. Tag names
    // are git refs (ASCII, no spaces), so byte length is their display width.
    var name_w: usize = 0;
    for (app.data.tags) |t| name_w = @max(name_w, t.name.len);
    const subj_col: u16 = @intCast(@min(name_w + 2, @as(usize, win.width)));
    const start = app.listScroll(.branches);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.tags.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const tag = app.data.tags[idx];
        // Tag name in the default colour, its annotation/subject dimmed so the
        // name stands out (the row's selection background still spans both).
        var base = styles().normal;
        const sel = selOf(idx == app.tag_index, app.focus == .branches);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);
        _ = printSpan(win, row, 0, tag.name, base);
        if (tag.subject.len > 0) {
            _ = printSpan(win, row, subj_col, tag.subject, withFg(base, ui_theme.tag));
        }
    }
}

fn drawWorktrees(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.worktrees.len == 0) {
        print(win, 0, 0, "No worktrees", styles().muted);
        return;
    }
    const start = app.listScroll(.branches);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.worktrees.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const wt = app.data.worktrees[idx];
        var buf: [512]u8 = undefined;
        const marker: u8 = if (wt.is_current) '*' else ' ';
        const name = std.fs.path.basename(wt.path);
        const line = std.fmt.bufPrint(&buf, "{c} {s} [{s}]", .{ marker, name, wt.branch }) catch wt.path;
        drawSelectable(win, row, line, if (wt.is_current) styles().staged else styles().normal, selOf(idx == app.worktree_index, app.focus == .files));
    }
}

fn drawSubmodules(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.submodules.len == 0) {
        print(win, 0, 0, "No submodules", styles().muted);
        return;
    }
    const start = app.listScroll(.branches);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.submodules.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const sm = app.data.submodules[idx];
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{c} {s}", .{ sm.status, sm.path }) catch sm.path;
        const style = switch (sm.status) {
            '-' => styles().muted,
            '+', 'U' => styles().warning,
            else => styles().normal,
        };
        drawSelectable(win, row, line, style, selOf(idx == app.submodule_index, app.focus == .files));
    }
}

/// Render a commit-files list (drilled into a commit) in `panel_focus` — either
/// the Commits panel or the Branches drill, each with its own `files`/`selected`.
/// `patch_active` is true when the in-progress patch belongs to this view's
/// commit, so the '+' markers reflect this commit rather than another's.
fn drawCommitFiles(win: vaxis.Window, app: *const app_mod.App, files: []const model.CommitFile, selected: usize, panel_focus: model.Focus, patch_active: bool) void {
    if (files.len == 0) {
        print(win, 0, 0, "No files in this commit", styles().muted);
        return;
    }
    const start = app.listScroll(panel_focus);
    const focused = app.focus == panel_focus;
    var row: u16 = 0;
    var idx = start;
    while (idx < files.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const file = files[idx];
        var buf: [512]u8 = undefined;
        // A leading '+' marks files added to this commit's custom patch.
        const in_patch = patch_active and patch_mod.patchHasFile(app, file.path);
        const marker: u8 = if (in_patch) '+' else ' ';
        const line = std.fmt.bufPrint(&buf, "{c}{c} {s}", .{ marker, file.status, file.path }) catch file.path;
        const style = if (in_patch) styles().staged else switch (file.status) {
            'A' => styles().added,
            'M', 'R' => styles().hash,
            'D' => styles().removed,
            else => styles().normal,
        };
        drawSelectable(win, row, line, style, selOf(idx == selected, focused));
    }
}

/// Foreground colour index for a commit-file row by its status letter, or null
/// to keep the default text colour.
fn commitFileFg(status: u8) ?u8 {
    return switch (status) {
        'A' => ui_theme.added,
        'M', 'R' => ui_theme.hash,
        'D' => ui_theme.removed,
        else => null,
    };
}

/// Tree-view rendering of a commit/branch drill's files (mirrors `drawFileTree`
/// but over `model.CommitFile`, whose single status letter colours the row).
fn drawCommitFileTree(win: vaxis.Window, app: *const app_mod.App, files: []const model.CommitFile, tree: *const app_mod.TreeState, panel_focus: model.Focus, patch_active: bool) void {
    if (tree.rows.len == 0) {
        print(win, 0, 0, "No files in this commit", styles().muted);
        return;
    }
    const start = app.listScroll(panel_focus);
    const focused = app.focus == panel_focus;
    var row: u16 = 0;
    var i = start;
    while (i < tree.rows.len and row < win.height) : ({
        i += 1;
        row += 1;
    }) {
        const tr = tree.rows[i];
        var base = styles().normal;
        const sel = selOf(i == tree.cursor, focused);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);

        var col = drawTreeRowPrefix(win, row, base, tr);
        if (tr.is_dir) continue;

        const file = files[tr.file_index];
        // A leading '+' marks files added to this commit's custom patch.
        const in_patch = patch_active and patch_mod.patchHasFile(app, file.path);
        const fg = if (in_patch) withFg(base, ui_theme.staged) else if (commitFileFg(file.status)) |c| withFg(base, c) else base;
        if (in_patch) col = printSpan(win, row, col, "+", withFg(base, ui_theme.staged));
        col = printSpan(win, row, col, &[_]u8{file.status}, fg);
        col = printSpan(win, row, col, " ", base);
        _ = printSpan(win, row, col, std.fs.path.basename(tr.path), fg);
    }
}

/// Render a commit list (`commits`, `selected` index) into `panel` — shared by
/// the Commits panel and the Branches-panel sub-commits drill.
fn drawCommitRows(win: vaxis.Window, app: *const app_mod.App, commits: []const model.Commit, selected: usize, panel_focus: model.Focus) void {
    const start = app.listScroll(panel_focus);
    const focused = app.focus == panel_focus;
    var row: u16 = 0;
    var idx = start;
    while (idx < commits.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const commit = commits[idx];
        // A leading marker flags commits copied to the cherry-pick clipboard;
        // a 'B' flags the commit marked as the base for a rebase --onto.
        const copied = app.isCommitCopied(commit.hash);
        const marked = app.isMarkedBase(commit.hash);
        const marker: u8 = if (marked) 'B' else if (copied) '*' else ' ';

        // The selection background/bold spans the whole row; the short hash is
        // coloured on its own (yellow, or the marker's colour) while the subject
        // keeps the default text colour — the familiar `git log --oneline` look.
        var base = styles().normal;
        const sel = selOf(idx == selected, focused);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);

        const hash_fg = if (marked) ui_theme.warning else if (copied) ui_theme.staged else ui_theme.hash;
        var buf: [80]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "{c}{s} ", .{ marker, commit.short_hash }) catch "";
        const col = printSpan(win, row, 0, head, withFg(base, hash_fg));
        _ = printSpan(win, row, col, commit.subject, base);
    }
}

fn drawCommits(win: vaxis.Window, app: *const app_mod.App) void {
    // The Commits panel's own commit-files drill (not the Branches one).
    if (app.commitsFilesActive()) {
        const patch_active = patch_mod.commitFilesPatchCount(app) > 0;
        if (app.tree_view) return drawCommitFileTree(win, app, app.commit_files, &app.commit_tree, .commits, patch_active);
        return drawCommitFiles(win, app, app.commit_files, app.commit_file_index, .commits, patch_active);
    }
    const commits = app.activeCommits();
    if (commits.len == 0) {
        const empty_label = if (app.initial_load_pending) "Loading..." else if (app.commits_tab == .reflog) "No reflog entries" else "No commits";
        print(win, 0, 0, empty_label, styles().muted);
        return;
    }
    drawCommitRows(win, app, commits, app.activeCommitIndex(), .commits);
}

fn drawStash(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.stash.len == 0) {
        print(win, 0, 0, if (app.initial_load_pending) "Loading..." else "No stash entries", styles().muted);
        return;
    }
    const start = app.listScroll(.stash);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.stash.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const entry = app.data.stash[idx];
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ entry.selector, entry.message }) catch entry.message;
        drawSelectable(win, row, line, styles().normal, selOf(idx == app.stash_index, app.focus == .stash));
    }
}

fn drawDiff(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.staging_active) {
        return drawStagingPane(win, app, app.staging_diff, true, "No changes on this side - press [ or ] to switch", .main);
    }

    const text = app.diff;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var skipped: usize = 0;
    while (skipped < app.main_scroll) : (skipped += 1) {
        if (lines.next() == null) return;
    }

    const sel = app.diffSelectionRangeFor(.main);
    const h_off = app.main_hscroll;

    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        const line = lines.next() orelse break;
        const abs_line = app.main_scroll + row;
        // Preview text carries git's own ANSI colors (--color=always). The mouse
        // text selection (if any) highlights columns on this line; selection
        // columns are text columns, shifted into screen space by `h_off`.
        var sel_lo: u16 = 0;
        var sel_hi: u16 = 0;
        if (sel) |s| {
            if (abs_line >= s.sl and abs_line <= s.el) {
                sel_lo = if (abs_line == s.sl) selScreenCol(s.sc, h_off, win.width) else 0;
                sel_hi = if (abs_line == s.el) selScreenCol(s.ec, h_off, win.width) else win.width;
            }
        }
        printAnsi(win, row, line, styles().normal, sel_lo, sel_hi, h_off);
    }
}

/// Map a text column to an on-screen column for the selection highlight: shift
/// left by the horizontal offset (saturating) and clamp to the panel width.
fn selScreenCol(text_col: usize, h_off: u16, width: u16) u16 {
    const shifted = text_col -| h_off;
    return @intCast(@min(shifted, width));
}

/// Render one side of the staging diff. The plain (--no-color) text is colorized
/// per line; the `active` pane shows the line/range highlight and scrolls with
/// `main_scroll`, while an inactive pane (the read-only side in split view)
/// renders from the top with no highlight.
fn drawStagingPane(win: vaxis.Window, app: *const app_mod.App, text: []const u8, active: bool, empty_msg: []const u8, pane: app_mod.SelPane) void {
    if (text.len == 0) {
        print(win, 0, 0, empty_msg, styles().muted);
        return;
    }
    var hl_start: usize = 0;
    var hl_end: usize = 0;
    if (active) {
        const anchor = app.staging_anchor orelse app.staging_cursor;
        hl_start = @min(anchor, app.staging_cursor);
        hl_end = @max(anchor, app.staging_cursor) + 1;
    }
    const scroll: usize = if (active) app.main_scroll else 0;
    // Only the active pane scrolls horizontally; the read-only side stays at the
    // left so both halves of a split stay legible.
    const h_off: u16 = if (active) app.main_hscroll else 0;
    // Mouse text selection in this pane (if any), highlighted per column.
    const sel = app.diffSelectionRangeFor(pane);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var skipped: usize = 0;
    while (skipped < scroll) : (skipped += 1) {
        if (lines.next() == null) return;
    }
    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        const line = lines.next() orelse break;
        const abs_line = scroll + row;
        var style = diffStyle(line);
        // Patch builder: add/remove lines included in the patch get a green
        // background so the selection is visible at a glance.
        if (app.staging_patch_mode and abs_line < app.patch_work_included.len and
            app.patch_work_included[abs_line] and line.len > 0 and (line[0] == '+' or line[0] == '-'))
        {
            style.bg = .{ .index = 22 };
            fillRow(win, row, style);
        }
        if (active and abs_line >= hl_start and abs_line < hl_end) {
            style.bg = .{ .index = 8 };
            fillRow(win, row, style);
        }
        var sel_lo: u16 = 0;
        var sel_hi: u16 = 0;
        if (sel) |s| {
            if (abs_line >= s.sl and abs_line <= s.el) {
                sel_lo = if (abs_line == s.sl) selScreenCol(s.sc, h_off, win.width) else 0;
                sel_hi = if (abs_line == s.el) selScreenCol(s.ec, h_off, win.width) else win.width;
            }
        }
        // The staging diff is plain (--no-color) text; printAnsi renders it with
        // `style` as the base and the selected column span highlighted.
        printAnsi(win, row, line, style, sel_lo, sel_hi, h_off);
    }
}

/// Split staging view: Unstaged on the left, Staged on the right, with the
/// active side bordered as focused. The active side is `app.staging_diff`; the
/// other is the read-only `app.staging_other_diff`.
fn drawStagingSplit(root: vaxis.Window, app: *app_mod.App, x: u16, y: u16, w: u16, h: u16) void {
    const left_w = w / 2;
    const unstaged_active = !app.staging_staged_view;
    const unstaged_text = if (unstaged_active) app.staging_diff else app.staging_other_diff;
    const staged_text = if (unstaged_active) app.staging_other_diff else app.staging_diff;
    const focused = app.focus == .main;
    // The active pane scrolls with main_scroll; the read-only one shows the top.
    const unstaged_pos: usize = if (unstaged_active) app.main_scroll else 0;
    const staged_pos: usize = if (unstaged_active) 0 else app.main_scroll;
    const left = panel(root, x, y, left_w, h, "Unstaged", focused and unstaged_active, .{ .len = app_mod.diffLineCount(unstaged_text), .pos = unstaged_pos });
    const right = panel(root, x + left_w, y, w - left_w, h, "Staged", focused and !unstaged_active, .{ .len = app_mod.diffLineCount(staged_text), .pos = staged_pos });
    app.main_view_height = if (unstaged_active) left.height else right.height;
    app.main_view_width = if (unstaged_active) left.width else right.width;
    // The active side (`staging_diff`) is the `.main` selection pane; the
    // read-only side is `.other` — matching `App.paneRectFor`.
    const left_pane: app_mod.SelPane = if (unstaged_active) .main else .other;
    const right_pane: app_mod.SelPane = if (unstaged_active) .other else .main;
    drawStagingPane(left, app, unstaged_text, unstaged_active, "No unstaged changes", left_pane);
    drawStagingPane(right, app, staged_text, !unstaged_active, "No staged changes", right_pane);
}

fn drawBottom(win: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    fillRow(win, 0, st.bottom);
    if (app.mode == .commit_prompt) {
        print(win, 0, 0, "tab switch field  -  enter commit/newline  -  esc cancel", st.bottom_accent);
        return;
    }
    if (app.mode == .file_filter_prompt) {
        print(win, 0, 0, "filter: ", st.bottom_accent);
        // The field starts at column 8; scroll within the remaining width.
        const field_w: usize = if (win.width > 8) win.width - 8 else 0;
        const caret = @min(app.file_filter_cursor, app.file_filter_buffer.items.len);
        const sc = app_mod.viewScroll(app.file_filter_scroll, field_w, caret);
        app.file_filter_scroll = sc.origin;
        print(win, 0, 8, app.file_filter_buffer.items[sc.origin..], st.bottom);
        win.showCursor(@intCast(8 + sc.view), 0);
        return;
    }
    if (app.mode == .status_filter_menu) {
        print(win, 0, 0, "status filter  -  j/k move  enter apply  esc cancel", st.bottom_accent);
        return;
    }
    if (app.mode == .menu) {
        print(win, 0, 0, "j/k move  -  enter select  -  esc cancel", st.bottom_accent);
        return;
    }
    if (app.mode == .text_prompt) {
        print(win, 0, 0, "enter confirm  -  esc cancel", st.bottom_accent);
        return;
    }
    if (app.mode == .credential_prompt) {
        print(win, 0, 0, "credentials  -  enter next/confirm  -  esc cancel", st.bottom_accent);
        return;
    }
    if (app.mode == .confirmation) {
        print(win, 0, 0, "y/enter confirm  -  n/esc cancel", st.bottom_accent);
        return;
    }
    if (app.mode == .command_log) {
        print(win, 0, 0, "command log  -  press any key to close", st.bottom_accent);
        return;
    }
    if (app.mode == .help) {
        print(win, 0, 0, "help  -  j/k scroll  -  any other key closes", st.bottom_accent);
        return;
    }

    var col: u16 = 0;
    if (app.message.len > 0) {
        col = printSpan(win, 0, 0, app.message, st.bottom);
        col = printSpan(win, 0, col, "  |  ", st.bottom);
    }
    _ = drawHints(win, 0, col, contextHints(app), st.hint_key, st.hint_desc);
}

/// Render keybinding hints: each "<key> <description>" group
/// (groups separated by two spaces) draws the leading key token highlighted and
/// the rest in the footer color. Returns the next column.
fn drawHints(win: vaxis.Window, row: u16, start_col: u16, hints: []const u8, key_st: vaxis.Style, desc_st: vaxis.Style) u16 {
    var col = start_col;
    var first = true;
    var it = std.mem.splitSequence(u8, hints, "  ");
    while (it.next()) |raw| {
        const group = std.mem.trim(u8, raw, " ");
        if (group.len == 0) continue;
        if (!first) col = printSpan(win, row, col, "  ", desc_st);
        first = false;
        if (std.mem.indexOfScalar(u8, group, ' ')) |sp| {
            col = printSpan(win, row, col, group[0..sp], key_st); // key token
            col = printSpan(win, row, col, group[sp..], desc_st); // " description"
        } else {
            col = printSpan(win, row, col, group, key_st); // key-only group
        }
        if (col >= win.width) break;
    }
    return col;
}

/// The view state that selects a footer hint line. A small value type so the
/// footer copy can be unit-tested without constructing a whole `App`.
const FooterCtx = struct {
    focus: model.Focus = .status,
    branches_tab: app_mod.BranchesTab = .local,
    files_tab: app_mod.FilesTab = .files,
    /// Remotes tab: drilled into a remote's branches (vs the remotes list).
    remote_drill: bool = false,
    /// Building a patch line-by-line (the per-line selection view).
    staging_patch: bool = false,
    /// The hunk/line staging view is open.
    staging: bool = false,
    /// Commits panel drilled into a commit's file list.
    commits_files: bool = false,
    /// Commits panel showing the Reflog tab (vs the commit log).
    reflog: bool = false,
    /// Branches panel drilled into a branch's commit list.
    branch_commits: bool = false,
    /// Within the Branches drill, showing a commit's file list (vs the commits).
    branch_files: bool = false,
    /// A merge/rebase/conflict is in progress (data.state != .clean).
    conflict: bool = false,
    /// The Diff panel is showing a working-tree file (so `e` can edit it).
    main_file: bool = false,
};

/// Keybinding hints for the current stage. A global suffix is appended since
/// those keys apply everywhere — except in the Branches list, where `R` renames
/// rather than refreshes, so that footer uses a suffix without "R refresh".
fn footerHints(c: FooterCtx) []const u8 {
    const global = "  @ log  ? help  z undo  R refresh  q quit";
    const global_branches = "  @ log  ? help  z undo  q quit";
    if (c.staging_patch) {
        return "j/k line  v range  space add/remove line (@@=hunk)  ^p patch  e edit  esc back" ++ global;
    }
    if (c.staging) {
        return "j/k line  v range  space stage/unstage (@@=hunk)  [/] staged/unstaged  \\ split  c/A commit/amend  e edit  esc back" ++ global;
    }
    // A commit's file list, building a custom patch: `space` toggles the whole
    // file, `enter` opens per-line selection, `^p` opens the patch menu, `e`
    // edits the file. Shared by the Commits and Branches sub-commits drills.
    const commit_files_hint = "j/k file  space toggle file  enter pick lines  ^p patch  e edit  esc back";
    if (c.commits_files and c.focus == .commits) {
        return commit_files_hint ++ global;
    }
    // Branches-panel sub-commits drill: commit list, or the selected commit's
    // file list — branch-management keys don't apply here.
    if (c.branch_commits and c.focus == .branches) {
        return if (c.branch_files)
            commit_files_hint ++ global
        else
            "j/k commit  enter files  esc back" ++ global;
    }
    if (c.conflict and c.focus == .files) {
        // No "esc back" here: the Files panel is at the top level during a
        // conflict, so esc has nothing to back out to (only `q` quits).
        return "space resolve (ours/theirs)  m continue/abort  d discard" ++ global;
    }
    if (c.focus == .branches) {
        return switch (c.branches_tab) {
            .local => "space checkout  c by-name  n new  R rename  d delete  M merge  r rebase  f ff  w worktree  W diff  [/] tabs" ++ global_branches,
            .remotes => if (c.remote_drill)
                "space checkout  n new-local  M merge  r rebase  g reset  u upstream  d delete  w worktree  W diff  enter commits  esc back" ++ global_branches
            else
                "enter/space branches  n add  e edit  d remove  f fetch  [/] tabs" ++ global_branches,
            .tags => "space checkout  n new-tag  d delete  P push  g reset  w worktree  W diff  [/] tabs" ++ global_branches,
        };
    }
    if (c.focus == .files) {
        return switch (c.files_tab) {
            .files => "space stage  a all  c commit  A amend  e edit  d discard  s stash  / filter  ` tree  enter hunks  [/] tabs" ++ global,
            .worktrees => "space/enter switch  n new  o editor  d remove  [/] tabs" ++ global,
            .submodules => "enter enter  space update  n add  e edit-url  d remove  b bulk  [/] tabs" ++ global,
        };
    }
    return switch (c.focus) {
        .status => "1-5 panels  enter inspect  f fetch  p pull  P push" ++ global,
        .files => unreachable,
        .branches => unreachable,
        .commits => if (c.reflog)
            "space checkout  g reset  n new-branch  c/v/^r copy/paste/clear  o browser  W diff  [/] tabs" ++ global
        else
            "enter files  space checkout  n branch  g reset  t revert  c/v/^r copy/paste/clear  d/s/f/e/r rebase  F fixup  S autosquash  B mark-base  W diff  / filter  b bisect  ^j/^k move" ++ global,
        .stash => "space apply  g pop  d drop  enter view" ++ global,
        .main => if (c.main_file)
            "j/k scroll  H/L pan  e edit  PgUp/PgDn page  drag select  ^o copy all  esc back" ++ global
        else
            "j/k scroll  H/L pan  PgUp/PgDn page  drag select  ^o copy all  esc back" ++ global,
    };
}

/// Footer hints for the live app — projects `App` state onto `FooterCtx`.
fn contextHints(app: *const app_mod.App) []const u8 {
    return footerHints(.{
        .focus = app.focus,
        .branches_tab = app.branches_tab,
        .files_tab = app.files_tab,
        .remote_drill = app.remoteDrillActive(),
        .staging_patch = app.staging_patch_mode,
        .staging = app.staging_active,
        .commits_files = app.commitsFilesActive(),
        .reflog = app.commits_tab == .reflog,
        .branch_commits = app.branch_commits_active,
        .branch_files = app.branchFilesActive(),
        .conflict = app.data.state != .clean,
        // `e` edits the file when the Diff panel shows a working-tree file.
        .main_file = app.focus == .main and !app.staging_active and
            app.contentFocus() == .files and app.selectedFile() != null,
    });
}

/// How a row's selection is drawn: not selected, selected in an unfocused panel
/// (dim highlight so it stays visible), or selected in the
/// focused panel (full highlight).
const Sel = enum { none, inactive, active };

/// The selection state for a row given whether it's the selected index and
/// whether its panel has focus.
fn selOf(selected: bool, focused: bool) Sel {
    if (!selected) return .none;
    return if (focused) .active else .inactive;
}

/// Apply the selection highlight (background, and bold when focused) to `base`.
fn applySel(base: *vaxis.Style, sel: Sel) void {
    switch (sel) {
        .none => {},
        .active => {
            base.bg = .{ .index = ui_theme.selected_bg };
            base.bold = true;
        },
        .inactive => base.bg = .{ .index = ui_theme.inactive_selected_bg },
    }
}

fn drawSelectable(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style, sel: Sel) void {
    var draw_style = style;
    applySel(&draw_style, sel);
    if (sel != .none) fillRow(win, row, draw_style);
    print(win, row, 0, text, draw_style);
}

fn print(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    _ = printSpan(win, row, col, text, style);
}

/// Horizontal scroll offset (cells) applied by `printSpan`/`printGlyph` to the
/// current row: the first `row_h_off` columns are skipped and the rest shift
/// left, so list rows pan with H/L. A panel's draw sets it (and resets to 0 via
/// `endListPan`); it is 0 everywhere else — the footer, popups, borders, titles.
var row_h_off: u16 = 0;
/// Widest absolute column reached since the last reset, so a panel can learn its
/// content width from the render pass (to bound horizontal scrolling).
var row_max_col: u16 = 0;

/// Begin horizontal panning for a list panel: load its offset into the row
/// primitives and reset the content-width tracker. Pair with `endListPan`.
fn beginListPan(app: *app_mod.App, focus: model.Focus) void {
    row_max_col = 0;
    row_h_off = if (app.listView(focus)) |lv| lv.hscroll else 0;
}

/// End panning: record the measured content width and inner width (so H/L can
/// bound the offset), then clear `row_h_off` so later drawing never pans.
fn endListPan(app: *app_mod.App, focus: model.Focus, inner_w: u16) void {
    if (app.listView(focus)) |lv| {
        lv.content_width = row_max_col;
        lv.view_w = inner_w;
    }
    row_h_off = 0;
}

/// Write one cell of absolute column `abs_col`, shifted left by `row_h_off`;
/// skipped when it falls off the left or right edge. Tracks the widest column.
fn emitRowCell(win: vaxis.Window, abs_col: u16, row: u16, grapheme: []const u8, style: vaxis.Style) void {
    if (abs_col >= row_h_off) {
        const sc = abs_col - row_h_off;
        if (sc < win.width) win.writeCell(sc, row, .{ .char = .{ .grapheme = grapheme, .width = 1 }, .style = style });
    }
    if (abs_col + 1 > row_max_col) row_max_col = abs_col + 1;
}

/// Like `print`, but returns the column after the last cell written so spans
/// (including static UTF-8 glyphs via `printGlyph`) can be composed on a row.
/// Columns are absolute (pre-`row_h_off`), so composition is unaffected by
/// horizontal scrolling; the full row is walked (even past the right edge) so
/// `row_max_col` reflects the true content width.
fn printSpan(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) u16 {
    if (row >= win.height) return col;
    var out_col = col;
    for (text) |byte| {
        if (byte == '\n' or byte == '\r') break;
        if (byte == '\t') {
            var spaces: u8 = 0;
            while (spaces < 4) : (spaces += 1) {
                emitRowCell(win, out_col, row, " ", style);
                out_col += 1;
            }
            continue;
        }
        emitRowCell(win, out_col, row, glyph(byte), style);
        out_col += 1;
    }
    return out_col;
}

fn clampU8(v: u32) u8 {
    return @intCast(@min(v, 255));
}

/// Update `style` from one ANSI SGR escape's parameters (the bytes between
/// `ESC[` and the final `m`), resetting to `base` on code 0 / empty. Supports
/// the attributes git emits: bold/dim/italic/underline/reverse, the 8 basic and
/// 8 bright colors, and the 256-color (`38;5;n`) and truecolor (`38;2;r;g;b`)
/// extended forms for both foreground and background.
fn applySgr(style: *vaxis.Style, base: vaxis.Style, params: []const u8) void {
    var codes: [24]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |tok| {
        if (n >= codes.len) break;
        codes[n] = if (tok.len == 0) 0 else (std.fmt.parseInt(u32, tok, 10) catch 0);
        n += 1;
    }
    if (n == 0) {
        style.* = base; // a bare ESC[m is a reset
        return;
    }
    var k: usize = 0;
    while (k < n) : (k += 1) {
        switch (codes[k]) {
            0 => style.* = base,
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.ul_style = .single,
            5, 6 => style.blink = true,
            7 => style.reverse = true,
            8 => style.invisible = true,
            9 => style.strikethrough = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.ul_style = .off,
            25 => style.blink = false,
            27 => style.reverse = false,
            28 => style.invisible = false,
            29 => style.strikethrough = false,
            30...37 => style.fg = .{ .index = clampU8(codes[k] - 30) },
            38 => {
                if (k + 2 < n and codes[k + 1] == 5) {
                    style.fg = .{ .index = clampU8(codes[k + 2]) };
                    k += 2;
                } else if (k + 4 < n and codes[k + 1] == 2) {
                    style.fg = .{ .rgb = .{ clampU8(codes[k + 2]), clampU8(codes[k + 3]), clampU8(codes[k + 4]) } };
                    k += 4;
                }
            },
            39 => style.fg = .default,
            40...47 => style.bg = .{ .index = clampU8(codes[k] - 40) },
            48 => {
                if (k + 2 < n and codes[k + 1] == 5) {
                    style.bg = .{ .index = clampU8(codes[k + 2]) };
                    k += 2;
                } else if (k + 4 < n and codes[k + 1] == 2) {
                    style.bg = .{ .rgb = .{ clampU8(codes[k + 2]), clampU8(codes[k + 3]), clampU8(codes[k + 4]) } };
                    k += 4;
                }
            },
            49 => style.bg = .default,
            90...97 => style.fg = .{ .index = clampU8(codes[k] - 90 + 8) },
            100...107 => style.bg = .{ .index = clampU8(codes[k] - 100 + 8) },
            else => {},
        }
    }
}

/// Draw one selectable content row of a read-only dialog: record its text (so
/// the mouse handler can map clicks to it and copy the span) and render it with
/// any active selection highlight. Dialog text is plain, so `printAnsi` just
/// draws it verbatim while shading the selected `[lo, hi)` columns.
fn drawDialogRow(win: vaxis.Window, app: *app_mod.App, win_row: u16, text: []const u8, base: vaxis.Style) void {
    app.setDialogRow(win_row, text);
    var lo: u16 = 0;
    var hi: u16 = 0;
    if (app.dialogRowSelection(win_row)) |s| {
        lo = s.lo;
        hi = s.hi;
    }
    printAnsi(win, win_row, text, base, lo, hi, 0);
}

/// Render one line into `win` at `row`, interpreting ANSI SGR escape sequences
/// (git's `--color=always` output) as styles instead of printing them as raw
/// bytes. Non-SGR CSI sequences are skipped. `base` is the default/reset style.
/// Like `printSpan`, one cell is written per byte (ASCII-oriented). `h_off` is
/// the horizontal scroll offset: the first `h_off` visible columns are skipped
/// (their SGR state is still tracked), and the rest shift left by `h_off`. Cells
/// whose on-screen column falls in `[sel_lo, sel_hi)` get the selection
/// background (mouse text selection); pass an empty range (0,0) for none.
fn printAnsi(win: vaxis.Window, row: u16, line: []const u8, base: vaxis.Style, sel_lo: u16, sel_hi: u16, h_off: u16) void {
    if (row >= win.height) return;
    var style = base;
    var vis_col: u16 = 0; // column in the unscrolled line
    var i: usize = 0;
    // Emit one cell of unscrolled column `vc`, shifted left by `h`; skip it if
    // it falls off the left (vc < h) or right edge.
    const emit = struct {
        fn f(w: vaxis.Window, vc: u16, h: u16, r: u16, g: []const u8, s: vaxis.Style, lo: u16, hi: u16) void {
            if (vc < h) return;
            const c = vc - h;
            if (c >= w.width) return;
            var cell_style = s;
            if (c >= lo and c < hi) cell_style.bg = .{ .index = ui_theme.selected_bg };
            w.writeCell(c, r, .{ .char = .{ .grapheme = g, .width = 1 }, .style = cell_style });
        }
    }.f;
    const last_col: usize = @as(usize, h_off) + win.width;
    while (i < line.len and vis_col < last_col) {
        const byte = line[i];
        if (byte == 0x1b) {
            // CSI: ESC [ params... final(0x40-0x7e). Other escapes: drop ESC.
            if (i + 1 < line.len and line[i + 1] == '[') {
                var j = i + 2;
                while (j < line.len and !(line[j] >= 0x40 and line[j] <= 0x7e)) j += 1;
                if (j >= line.len) break; // truncated sequence
                if (line[j] == 'm') applySgr(&style, base, line[i + 2 .. j]);
                i = j + 1;
            } else {
                i += 1;
            }
            continue;
        }
        if (byte == '\r') {
            i += 1;
            continue;
        }
        if (byte == '\t') {
            var spaces: u8 = 0;
            while (spaces < 4 and vis_col < last_col) : (spaces += 1) {
                emit(win, vis_col, h_off, row, " ", style, sel_lo, sel_hi);
                vis_col += 1;
            }
            i += 1;
            continue;
        }
        emit(win, vis_col, h_off, row, glyph(byte), style, sel_lo, sel_hi);
        vis_col += 1;
        i += 1;
    }
}

/// Word-wrap `text` to `width` cells, writing each resulting line (a substring
/// of `text`) into `out` and returning the count. Breaks on existing newlines,
/// prefers to break at spaces, and hard-breaks words longer than `width`, so
/// confirmation/message popups stay readable instead of being clipped at the boundary.
fn wrapText(text: []const u8, width: u16, out: [][]const u8) usize {
    if (out.len == 0) return 0;
    if (text.len == 0) {
        out[0] = text;
        return 1;
    }
    if (width == 0) {
        out[0] = text;
        return 1;
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        const line_start = i;
        var last_space: ?usize = null;
        var j = i;
        var line_end: usize = undefined;
        var next: usize = undefined;
        while (true) {
            if (j >= text.len) {
                line_end = text.len;
                next = text.len;
                break;
            }
            if (text[j] == '\n') {
                line_end = j;
                next = j + 1; // consume the newline
                break;
            }
            if (j - line_start >= width) {
                if (text[j] == ' ') {
                    line_end = j; // a word ended exactly at the boundary
                    next = j + 1;
                } else if (last_space) |sp| {
                    line_end = sp; // break at the last space that fit
                    next = sp + 1;
                } else {
                    line_end = j; // hard break inside a long word
                    next = j;
                }
                break;
            }
            if (text[j] == ' ') last_space = j;
            j += 1;
        }
        out[n] = text[line_start..line_end];
        n += 1;
        i = next;
    }
    return n;
}

/// Write a single static UTF-8 glyph (e.g. an arrow) as one cell. The grapheme
/// must be a stable slice — vaxis stores it by reference until render. Honors
/// `row_h_off` so glyphs in list rows pan with the rest of the row.
fn printGlyph(win: vaxis.Window, row: u16, col: u16, grapheme: []const u8, style: vaxis.Style) u16 {
    if (row < win.height) {
        emitRowCell(win, col, row, grapheme, style);
        return col + 1;
    }
    return col;
}

fn fillRow(win: vaxis.Window, row: u16, style: vaxis.Style) void {
    if (row >= win.height) return;
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        win.writeCell(col, row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        });
    }
}

fn diffStyle(line: []const u8) vaxis.Style {
    const st = styles();
    if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) return st.added;
    if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) return st.removed;
    if (std.mem.startsWith(u8, line, "@@")) return st.hunk;
    if (std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "commit ")) return st.header;
    return st.normal;
}

const StyleSet = struct {
    normal: vaxis.Style,
    muted: vaxis.Style,
    title: vaxis.Style,
    active_title: vaxis.Style,
    active_border: vaxis.Style,
    inactive_border: vaxis.Style,
    staged: vaxis.Style,
    unstaged: vaxis.Style,
    warning: vaxis.Style,
    added: vaxis.Style,
    removed: vaxis.Style,
    hunk: vaxis.Style,
    header: vaxis.Style,
    hash: vaxis.Style,
    bottom: vaxis.Style,
    bottom_accent: vaxis.Style,
    hint_key: vaxis.Style,
    hint_desc: vaxis.Style,
};

fn styles() StyleSet {
    const t = ui_theme;
    return .{
        .normal = .{ .fg = .default },
        .muted = .{ .fg = .{ .index = t.muted } },
        .title = .{ .fg = .{ .index = t.title } },
        .active_title = .{ .fg = .{ .index = t.active }, .bold = true },
        .active_border = .{ .fg = .{ .index = t.active }, .bold = true },
        .inactive_border = .{ .fg = .{ .index = t.inactive_border } },
        .staged = .{ .fg = .{ .index = t.staged } },
        .unstaged = .{ .fg = .{ .index = t.unstaged } },
        .warning = .{ .fg = .{ .index = t.warning }, .bold = true },
        .added = .{ .fg = .{ .index = t.added } },
        .removed = .{ .fg = .{ .index = t.removed } },
        .hunk = .{ .fg = .{ .index = t.hunk } },
        .header = .{ .fg = .{ .index = t.header }, .bold = true },
        .hash = .{ .fg = .{ .index = t.hash } },
        .bottom = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
        .bottom_accent = .{ .fg = .{ .index = t.accent }, .bg = .{ .index = 0 }, .bold = true },
        .hint_key = .{ .fg = .{ .index = t.footer_key }, .bg = .{ .index = 0 }, .bold = true },
        .hint_desc = .{ .fg = .{ .index = t.footer }, .bg = .{ .index = 0 } },
    };
}

const ascii_table: [128][1]u8 = initAsciiTable();

fn initAsciiTable() [128][1]u8 {
    var table: [128][1]u8 = undefined;
    for (0..128) |i| {
        table[i][0] = @intCast(i);
    }
    return table;
}

fn glyph(byte: u8) []const u8 {
    if (byte >= 32 and byte < 127) return ascii_table[byte][0..1];
    return "?";
}

// Static UTF-8 glyphs (stable storage for vaxis grapheme references).
const glyph_to_branch = "→"; // U+2192
const glyph_ahead = "↑"; // U+2191 (commits to push)
const glyph_behind = "↓"; // U+2193 (commits to pull)
const glyph_uptodate = "✓"; // U+2713
const glyph_collapsed = "▸"; // U+25B8
const glyph_focus_pointer = "◀"; // U+25C0 (marks the help section for the current context)
const glyph_expanded = "▾"; // U+25BE
const indent_spaces = " " ** 32;

/// Render ahead/behind status: `↓2↑3`, `✓` when in sync, or `(unpushed)`
/// when the branch has no upstream (never pushed). Returns the next column.
fn drawBranchStatus(win: vaxis.Window, row: u16, col: u16, base: vaxis.Style, has_upstream: bool, ahead: usize, behind: usize) u16 {
    if (!has_upstream) return printSpan(win, row, col, "(unpushed)", withFg(base, ui_theme.muted));
    if (ahead == 0 and behind == 0) return printGlyph(win, row, col, glyph_uptodate, withFg(base, 10));

    var c = col;
    var buf: [16]u8 = undefined;
    if (behind > 0) {
        c = printGlyph(win, row, c, glyph_behind, withFg(base, 9));
        c = printSpan(win, row, c, std.fmt.bufPrint(&buf, "{d}", .{behind}) catch "", withFg(base, 9));
    }
    if (ahead > 0) {
        c = printGlyph(win, row, c, glyph_ahead, withFg(base, 10));
        c = printSpan(win, row, c, std.fmt.bufPrint(&buf, "{d}", .{ahead}) catch "", withFg(base, 10));
    }
    return c;
}

/// Copy a style with a different foreground colour index, preserving bg/bold
/// (so highlighted rows keep their background).
fn withFg(base: vaxis.Style, index: u8) vaxis.Style {
    var s = base;
    s.fg = .{ .index = index };
    return s;
}

test "recencyStr rounds like git --date=relative" {
    const now: i64 = 2_000_000_000;
    var buf: [8]u8 = undefined;
    const day: i64 = 86400;
    try std.testing.expectEqualStrings("", recencyStr(&buf, 0, now)); // unknown
    try std.testing.expectEqualStrings("0s", recencyStr(&buf, now, now));
    try std.testing.expectEqualStrings("30s", recencyStr(&buf, now - 30, now));
    try std.testing.expectEqualStrings("2m", recencyStr(&buf, now - 90, now)); // 90s -> 2 minutes
    try std.testing.expectEqualStrings("2h", recencyStr(&buf, now - 7200, now));
    try std.testing.expectEqualStrings("3d", recencyStr(&buf, now - 3 * day, now));
    try std.testing.expectEqualStrings("3w", recencyStr(&buf, now - 20 * day, now));
    try std.testing.expectEqualStrings("2M", recencyStr(&buf, now - 70 * day, now));
    try std.testing.expectEqualStrings("1y", recencyStr(&buf, now - 365 * day, now));
    // The case that floor got wrong: ~2 years reads "2y", not "1y".
    try std.testing.expectEqualStrings("2y", recencyStr(&buf, now - 730 * day, now));
}

test "every help-section keyword matches a real help header" {
    const isHeader = struct {
        fn f(line: []const u8) bool {
            return line.len > 0 and line[0] != ' ';
        }
    }.f;
    // Every (focus, staging) the app can be in must map to a keyword that is a
    // prefix of an actual help section header — otherwise the auto-scroll/
    // highlight would silently find nothing.
    const cases = [_]struct { focus: model.Focus, staging: bool }{
        .{ .focus = .status, .staging = false },
        .{ .focus = .files, .staging = false },
        .{ .focus = .files, .staging = true },
        .{ .focus = .branches, .staging = false },
        .{ .focus = .commits, .staging = false },
        .{ .focus = .stash, .staging = false },
        .{ .focus = .main, .staging = false },
    };
    for (cases) |c| {
        const kw = app_mod.helpSectionKeyword(c.focus, c.staging) orelse continue;
        var found = false;
        for (help_lines) |line| {
            if (isHeader(line) and std.mem.startsWith(u8, line, kw)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "footer hints have no key contradictions per stage" {
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;

    // Branches list: `R` renames here, so the footer must advertise rename and
    // must NOT also claim "R refresh" (the global key is shadowed).
    inline for ([_]app_mod.BranchesTab{ .local, .remotes, .tags }) |tab| {
        const s = footerHints(.{ .focus = .branches, .branches_tab = tab });
        try std.testing.expect(!has(s, "R refresh"));
    }
    // Only the local tab renames with `R`; the others leave it unbound rather
    // than claiming refresh.
    try std.testing.expect(has(footerHints(.{ .focus = .branches, .branches_tab = .local }), "R rename"));
    // Local tab advertises checkout-by-name (`c`).
    try std.testing.expect(has(footerHints(.{ .focus = .branches, .branches_tab = .local }), "by-name"));

    // Everywhere `R` actually refreshes, the global suffix advertises it.
    inline for ([_]model.Focus{ .status, .files, .commits, .stash, .main }) |f| {
        try std.testing.expect(has(footerHints(.{ .focus = f }), "R refresh"));
    }
    // The Branches drill re-binds `R` to refresh, so its footer keeps the hint.
    try std.testing.expect(has(footerHints(.{ .focus = .branches, .branch_commits = true }), "R refresh"));

    // Status: `@ log` lives in the global suffix only — not duplicated.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, footerHints(.{ .focus = .status }), "@ log"));

    // Commits: drilling into a commit's files is the headline action.
    try std.testing.expect(has(footerHints(.{ .focus = .commits }), "enter files"));

    // Commit-files (patch building): both the Commits and Branches drills show
    // the same accurate hints — toggle file, pick lines, patch menu — and never
    // the stale "enter diff".
    const cf_commits = footerHints(.{ .focus = .commits, .commits_files = true });
    const cf_branches = footerHints(.{ .focus = .branches, .branch_commits = true, .branch_files = true });
    inline for ([_][]const u8{ cf_commits, cf_branches }) |s| {
        try std.testing.expect(has(s, "toggle file"));
        try std.testing.expect(has(s, "pick lines"));
        try std.testing.expect(has(s, "^p patch"));
        try std.testing.expect(!has(s, "enter diff"));
    }

    // Patch line view advertises the patch menu to apply/reset the selection.
    try std.testing.expect(has(footerHints(.{ .staging_patch = true }), "^p patch"));

    // The Diff panel advertises horizontal scrolling (H/L) for long lines.
    try std.testing.expect(has(footerHints(.{ .focus = .main }), "H/L"));

    // `e edit` is advertised wherever editing the file works: Files, the
    // staging and patch views, a commit's file list, and the Diff panel of a
    // working-tree file — but NOT the plain Diff panel (a commit/branch diff).
    try std.testing.expect(has(footerHints(.{ .focus = .files }), "e edit"));
    try std.testing.expect(has(footerHints(.{ .staging = true, .focus = .main }), "e edit"));
    try std.testing.expect(has(footerHints(.{ .staging_patch = true, .focus = .main }), "e edit"));
    try std.testing.expect(has(footerHints(.{ .focus = .commits, .commits_files = true }), "e edit"));
    try std.testing.expect(has(footerHints(.{ .focus = .main, .main_file = true }), "e edit"));
    try std.testing.expect(!has(footerHints(.{ .focus = .main }), "e edit"));

    // Conflict state (Files panel): advertises the resolve/continue keys, and
    // must NOT promise "esc back" — the panel is top-level during a conflict,
    // so esc has nothing to back out to.
    const conflict = footerHints(.{ .focus = .files, .conflict = true });
    try std.testing.expect(has(conflict, "resolve"));
    try std.testing.expect(has(conflict, "continue/abort"));
    try std.testing.expect(!has(conflict, "esc back"));

    // "esc back" must appear only where esc actually backs out of a sub-view
    // (drills, staging, the main diff) — never at a top-level panel where esc
    // is inert.
    const top_level = [_]FooterCtx{
        .{ .focus = .status },
        .{ .focus = .files },
        .{ .focus = .files, .conflict = true },
        .{ .focus = .commits },
        .{ .focus = .stash },
        .{ .focus = .branches, .branches_tab = .local },
        .{ .focus = .branches, .branches_tab = .remotes },
        .{ .focus = .branches, .branches_tab = .tags },
        .{ .focus = .files, .files_tab = .worktrees },
        .{ .focus = .files, .files_tab = .submodules },
    };
    for (top_level) |c| try std.testing.expect(!has(footerHints(c), "esc back"));
    const sub_view = [_]FooterCtx{
        .{ .focus = .main },
        .{ .staging = true, .focus = .main },
        .{ .staging_patch = true, .focus = .main },
        .{ .focus = .commits, .commits_files = true },
        .{ .focus = .branches, .branch_commits = true },
        .{ .focus = .branches, .branch_commits = true, .branch_files = true },
    };
    for (sub_view) |c| try std.testing.expect(has(footerHints(c), "esc back"));

    // Every reachable stage yields a non-empty footer (the `.branches`
    // arm of the final switch is `unreachable` — exercised only via the
    // dedicated branches block above).
    try std.testing.expect(footerHints(.{ .focus = .main }).len > 0);
}

test "scrollbar thumb sizes and positions to the content" {
    // Content fits the track → no scrollbar.
    try std.testing.expect(scrollbarThumb(10, 5, 0) == null);
    try std.testing.expect(scrollbarThumb(10, 10, 0) == null);

    // 10 of 100 visible → a 1-row thumb that travels the full track.
    {
        const top = scrollbarThumb(10, 100, 0).?;
        try std.testing.expectEqual(@as(usize, 0), top.start);
        try std.testing.expectEqual(@as(usize, 1), top.size);
        const bot = scrollbarThumb(10, 100, 90).?; // max scroll
        try std.testing.expectEqual(@as(usize, 9), bot.start); // sits at the bottom
        try std.testing.expectEqual(@as(usize, 1), bot.size);
    }

    // Half visible → a thumb half the track tall.
    {
        const t = scrollbarThumb(10, 20, 0).?;
        try std.testing.expectEqual(@as(usize, 5), t.size);
        try std.testing.expectEqual(@as(usize, 0), t.start);
        const b = scrollbarThumb(10, 20, 10).?; // max scroll
        try std.testing.expectEqual(@as(usize, 5), b.start); // start+size == track
    }

    // Over-scrolled position is clamped to the bottom.
    try std.testing.expectEqual(@as(usize, 9), scrollbarThumb(10, 100, 9999).?.start);
}

test "side panel heights match the weighting" {
    const body_h: u16 = 30;

    // Default (no accordion): status fixed, stash a small fixed size when not
    // focused, files/branches/commits share the rest equally. Fills body_h.
    const h = sidePanelHeights(body_h, .files, false, 2);
    try std.testing.expectEqual(@as(u16, 5), h.status);
    try std.testing.expectEqual(@as(u16, 3), h.stash);
    try std.testing.expectEqual(body_h, h.status + h.files + h.branches + h.commits + h.stash);
    const lists_spread = @max(h.files, @max(h.branches, h.commits)) - @min(h.files, @min(h.branches, h.commits));
    try std.testing.expect(lists_spread <= 1);

    // Stash focused: it joins the weighted group and grows past the fixed 3.
    const hs = sidePanelHeights(body_h, .stash, false, 2);
    try std.testing.expect(hs.stash > 3);
    try std.testing.expectEqual(body_h, hs.status + hs.files + hs.branches + hs.commits + hs.stash);

    // Accordion: the focused list panel is larger than the others.
    const ha = sidePanelHeights(body_h, .commits, true, 2);
    try std.testing.expect(ha.commits > ha.files);
    try std.testing.expectEqual(body_h, ha.status + ha.files + ha.branches + ha.commits + ha.stash);
}

test "side panel width scales with the terminal, no fixed cap" {
    // Stays proportional (~1/3 at 33%) at any width — no stalling at 60 columns.
    try std.testing.expectEqual(@as(u16, 39), sidePanelWidth(120, 33));
    try std.testing.expectEqual(@as(u16, 66), sidePanelWidth(200, 33)); // would have been capped at 60 before
    try std.testing.expectEqual(@as(u16, 79), sidePanelWidth(240, 33));
    // The main panel always keeps at least 20 columns.
    try std.testing.expect(120 - sidePanelWidth(120, 90) >= 20);
    // A small floor keeps the panel usable on a narrow terminal.
    try std.testing.expectEqual(@as(u16, 20), sidePanelWidth(50, 33));
}

test "wrapText wraps at word and line boundaries" {
    var lines: [8][]const u8 = undefined;

    // A word ending exactly at the boundary is not broken early.
    try std.testing.expectEqual(@as(usize, 2), wrapText("hello world foo", 11, &lines));
    try std.testing.expectEqualStrings("hello world", lines[0]);
    try std.testing.expectEqualStrings("foo", lines[1]);

    // Existing newlines start a new line (and blank lines are kept).
    try std.testing.expectEqual(@as(usize, 3), wrapText("a\n\nb", 20, &lines));
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("", lines[1]);
    try std.testing.expectEqualStrings("b", lines[2]);

    // A word longer than the width is hard-broken.
    try std.testing.expectEqual(@as(usize, 2), wrapText("abcdefghij", 5, &lines));
    try std.testing.expectEqualStrings("abcde", lines[0]);
    try std.testing.expectEqualStrings("fghij", lines[1]);

    // Text that fits is a single line.
    try std.testing.expectEqual(@as(usize, 1), wrapText("short", 20, &lines));
    try std.testing.expectEqualStrings("short", lines[0]);
}

test "applySgr parses ANSI color codes" {
    const base: vaxis.Style = .{};
    var s = base;

    // Basic foreground color (green).
    applySgr(&s, base, "32");
    try std.testing.expectEqual(@as(u8, 2), s.fg.index);

    // Bold + basic color in one sequence.
    s = base;
    applySgr(&s, base, "1;31");
    try std.testing.expect(s.bold);
    try std.testing.expectEqual(@as(u8, 1), s.fg.index);

    // Code 0 and an empty sequence both reset to the base style.
    s = .{ .bold = true, .fg = .{ .index = 5 } };
    applySgr(&s, base, "0");
    try std.testing.expect(!s.bold);
    try std.testing.expect(std.meta.activeTag(s.fg) == .default);
    s = .{ .italic = true };
    applySgr(&s, base, "");
    try std.testing.expect(!s.italic);

    // 256-color and truecolor extended forms.
    s = base;
    applySgr(&s, base, "38;5;208");
    try std.testing.expectEqual(@as(u8, 208), s.fg.index);
    s = base;
    applySgr(&s, base, "48;2;10;20;30");
    try std.testing.expectEqual([3]u8{ 10, 20, 30 }, s.bg.rgb);

    // Bright foreground maps into the 8-15 palette range.
    s = base;
    applySgr(&s, base, "92");
    try std.testing.expectEqual(@as(u8, 10), s.fg.index);
}
