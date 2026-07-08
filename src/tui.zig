const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const credentials_mod = @import("credentials.zig");
const git_mod = @import("git.zig");
const filetree = @import("filetree.zig");
const model = @import("model.zig");
const patch_mod = @import("patch.zig");
const conflicts_mod = @import("conflicts.zig");
const donut_mod = @import("donut.zig");
const rebaseplan_mod = @import("rebaseplan.zig");
const staging_mod = @import("staging.zig");
const commitgraph_mod = @import("commitgraph.zig");

/// Active theme, set from config at startup and read by `styles()`.
var ui_theme: config_mod.Theme = .{};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    refresh_tick,
    anim_tick,
    fetch_tick,
    bg_fetch_done,
    command_done,
    preview_done,
    worktree_done,
    mutation_done,
    repo_load_done,
    scoped_load_done,
    graph_done,
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
    git_dir: []const u8,
    environ: *std.process.Environ.Map,
    untracked: git_mod.Git.UntrackedFiles = .all,
    generation: u64,
    result: ?app_mod.WorktreeSnapshot = null,
};

fn worktreeWorker(wr: *WorktreeRun) void {
    wr.result = app_mod.WorktreeSnapshot.load(async_allocator, wr.io, wr.environ, wr.root, wr.git_dir, wr.untracked) catch null;
    _ = wr.loop.tryPostEvent(.worktree_done) catch false;
}

/// The commit-graph viewer's `git log --graph` load, run off the UI loop so a
/// big repo's graph doesn't block navigation. Posts `.graph_done`.
const GraphRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []const u8,
    environ: *std.process.Environ.Map,
    all: bool,
    generation: u64,
    result: ?[]u8 = null,
    parents: ?[]u8 = null,
};

fn graphWorker(gr: *GraphRun) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(async_allocator);
    // Rich one-line-per-commit format: hash, decorations, author, relative date,
    // then subject — colourised by git so printAnsi renders it directly.
    // Branch/tag names (%d) get a fixed bold magenta so they stand out rather
    // than relying on git's theme-dependent auto decoration colours.
    const base = [_][]const u8{ "git", "--no-optional-locks", "log", "--graph", "--color=always", "--decorate", "-n", "5000", "--format=format:%C(yellow)%h%C(bold magenta)%d%C(reset) %C(blue)%an%C(reset) %C(green)%ar%C(reset)  %s" };
    argv.appendSlice(async_allocator, &base) catch return postGraph(gr);
    if (gr.all) argv.append(async_allocator, "--all") catch return postGraph(gr);
    const r = git_mod.runWithLockRetry(async_allocator, gr.io, .{
        .argv = argv.items,
        .cwd = .{ .path = gr.root },
        .environ_map = gr.environ,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1 * 1024 * 1024),
    }) catch return postGraph(gr);
    gr.result = r.stdout; // owned by async_allocator; freed in completeGraph
    async_allocator.free(r.stderr);

    // Second, scope-matched pass: one `%h %p` line per commit (no graph, no
    // colour) so the viewer can resolve first-parents. Best-effort — if it
    // fails, parent-jump is simply unavailable this load.
    var pargv: std.ArrayList([]const u8) = .empty;
    defer pargv.deinit(async_allocator);
    const pbase = [_][]const u8{ "git", "--no-optional-locks", "log", "-n", "5000", "--format=%h %p" };
    pargv.appendSlice(async_allocator, &pbase) catch return postGraph(gr);
    if (gr.all) pargv.append(async_allocator, "--all") catch return postGraph(gr);
    if (git_mod.runWithLockRetry(async_allocator, gr.io, .{
        .argv = pargv.items,
        .cwd = .{ .path = gr.root },
        .environ_map = gr.environ,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1 * 1024 * 1024),
    })) |pr| {
        gr.parents = pr.stdout; // owned by async_allocator; freed in completeGraph
        async_allocator.free(pr.stderr);
    } else |_| {}

    postGraph(gr);
}

fn postGraph(gr: *GraphRun) void {
    _ = gr.loop.tryPostEvent(.graph_done) catch false;
}

/// A quiet periodic `git fetch` run off the UI loop (config `fetch_interval_secs`), so
/// the behind/ahead counts reflect new remote commits. The shared environment
/// has `GIT_TERMINAL_PROMPT=0` and no askpass, so it fails silently rather than
/// prompting when the remote needs credentials. Output is discarded; posts
/// `.bg_fetch_done` so the loop can refresh the branch/status views.
const BgFetchRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []const u8,
    environ: *std.process.Environ.Map,
};

fn bgFetchWorker(fr: *BgFetchRun) void {
    const argv = [_][]const u8{ "git", "--no-optional-locks", "fetch", "--all", "--no-write-fetch-head" };
    if (git_mod.runWithLockRetry(async_allocator, fr.io, .{
        .argv = &argv,
        .cwd = .{ .path = fr.root },
        .environ_map = fr.environ,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    })) |r| {
        async_allocator.free(r.stdout);
        async_allocator.free(r.stderr);
    } else |_| {}
    _ = fr.loop.tryPostEvent(.bg_fetch_done) catch false;
}

/// A slow git mutation (merge/rebase/bisect/…) run off the UI loop on a
/// page-allocator Git. Posts `.mutation_done` so the loop can surface the
/// result and refresh on the UI thread.
const MutationRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []u8,
    git_dir: []const u8,
    environ: *std.process.Environ.Map,
    mutation: app_mod.Mutation,
    result: ?git_mod.ExecResult = null,
};

fn mutationWorker(mr: *MutationRun) void {
    mr.result = mr.mutation.run(async_allocator, mr.io, mr.environ, mr.root, mr.git_dir) catch null;
    _ = mr.loop.tryPostEvent(.mutation_done) catch false;
}

/// The one-shot initial repo load (async startup). Loads the full
/// repo off the UI loop on a page-allocator Git and posts `.repo_load_done` so
/// the loop can deep-copy it into the gpa and paint the populated panels.
const RepoLoadRun = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []u8,
    git_dir: []const u8,
    environ: *std.process.Environ.Map,
    branch_sort: model.BranchSortOrder = .date,
    untracked: git_mod.Git.UntrackedFiles = .all,
    commit_limit: usize = app_mod.commit_load_batch,
    result: ?model.RepoData = null,
};

fn repoLoadWorker(rl: *RepoLoadRun) void {
    rl.result = app_mod.loadRepoDataAsync(async_allocator, rl.io, rl.environ, rl.root, rl.git_dir, rl.branch_sort, rl.untracked, rl.commit_limit);
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
    git_dir: []const u8,
    environ: *std.process.Environ.Map,
    scopes: app_mod.ScopeSet,
    grep: ?[]u8 = null,
    author: ?[]u8 = null,
    path: ?[]u8 = null,
    branch_sort: model.BranchSortOrder = .date,
    untracked: git_mod.Git.UntrackedFiles = .all,
    commit_limit: usize = app_mod.commit_load_batch,
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
    sr.result = app_mod.loadScopesAsync(async_allocator, sr.io, sr.environ, sr.root, sr.git_dir, sr.scopes, .{
        .grep = sr.grep,
        .author = sr.author,
        .path = sr.path,
    }, sr.branch_sort, sr.untracked, sr.commit_limit);
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
    // Bracketed paste: the terminal wraps pasted text in markers so a pasted
    // newline arrives as content, not as an Enter that would submit a dialog.
    try vx.setBracketedPaste(writer, true);
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

    var graph_run: GraphRun = undefined;
    var graph_future: ?std.Io.Future(void) = null;
    defer if (graph_future) |*f| {
        f.cancel(io);
        if (graph_run.result) |r| async_allocator.free(r);
    };

    var bg_fetch_run: BgFetchRun = undefined;
    var bg_fetch_future: ?std.Io.Future(void) = null;
    defer if (bg_fetch_future) |*f| f.cancel(io);

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
    var repo_load_run: RepoLoadRun = .{ .io = io, .loop = &loop, .root = app.git.root, .git_dir = app.git.git_dir, .environ = app.git.environ, .branch_sort = app.git.branch_sort, .untracked = app.git.untracked_files, .commit_limit = app.commit_limit };
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
            .anim_tick => app.anim_frame +%= 1,
            .fetch_tick => app.bg_fetch_requested = true,
            .bg_fetch_done => {
                if (bg_fetch_future) |*f| {
                    f.await(io);
                    bg_fetch_future = null;
                    // New remote-tracking refs: refresh the status summary
                    // (ahead/behind) and the branch list (its arrows).
                    app.refreshViews(app_mod.ScopeSet.init(.{ .files = true, .branches = true }));
                }
            },
            .focus_in => try app.handleFocusIn(),
            .focus_out => app.handleFocusOut(),
            // Bracketed paste: while pasting, key events are literal text, not
            // commands — so a pasted newline can't submit a dialog.
            .paste_start => app.pasting = true,
            .paste_end => app.pasting = false,
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
            .graph_done => {
                if (graph_future) |*f| {
                    f.await(io);
                    graph_future = null;
                    commitgraph_mod.complete(app, graph_run.result, graph_run.parents, graph_run.generation, async_allocator);
                    graph_run.result = null;
                    graph_run.parents = null;
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
            if (bg_fetch_future) |*f| {
                f.await(io);
                bg_fetch_future = null;
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
                repo_load_run = .{ .io = io, .loop = &loop, .root = app.git.root, .git_dir = app.git.git_dir, .environ = app.git.environ, .branch_sort = app.git.branch_sort, .untracked = app.git.untracked_files, .commit_limit = app.commit_limit };
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
                    .git_dir = app.git.git_dir,
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

        // Start a queued commit-graph load (ctrl+l) off the loop.
        if (graph_future == null) {
            if (commitgraph_mod.takeLoad(app)) |req| {
                graph_run = .{
                    .io = io,
                    .loop = &loop,
                    .root = app.git.root,
                    .environ = app.git.environ,
                    .all = req.all,
                    .generation = req.generation,
                    .result = null,
                };
                graph_future = io.concurrent(graphWorker, .{&graph_run}) catch blk: {
                    commitgraph_mod.complete(app, null, null, req.generation, async_allocator);
                    break :blk null;
                };
                render_needed = true;
            }
        }

        // Start a queued background auto-fetch off the loop — but never while a
        // user's own network op is in flight (they'd contend / double-prompt).
        if (bg_fetch_future == null and app.bg_fetch_requested and !app.async_active) {
            app.bg_fetch_requested = false;
            bg_fetch_run = .{ .io = io, .loop = &loop, .root = app.git.root, .environ = app.git.environ };
            bg_fetch_future = io.concurrent(bgFetchWorker, .{&bg_fetch_run}) catch null;
        }

        // Flush any pending stage/unstage toggles into a coalesced off-thread
        // batch (queued as a mutation below) so rapid space-staging never blocks
        // the UI thread on a synchronous `git add`.
        staging_mod.tryFlushStaging(app);

        // Start the queued slow mutation off the loop. Single in-flight; the
        // input gate keeps another mutation from being requested meanwhile.
        if (mutation_future == null) {
            if (app.takeMutation()) |mutation| {
                mutation_run = .{ .io = io, .loop = &loop, .root = app.git.root, .git_dir = app.git.git_dir, .environ = app.git.environ, .mutation = mutation, .result = null };
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
                    .git_dir = app.git.git_dir,
                    .environ = app.git.environ,
                    .scopes = scopes,
                    .grep = if (filters.grep) |g| async_allocator.dupe(u8, g) catch null else null,
                    .author = if (filters.author) |x| async_allocator.dupe(u8, x) catch null else null,
                    .path = if (filters.path) |p| async_allocator.dupe(u8, p) catch null else null,
                    .branch_sort = app.git.branch_sort,
                    .untracked = app.git.untracked_files,
                    .commit_limit = app.commit_limit,
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
        // Reflect whether the about-splash animation wants continuous ticks.
        app.animate_flag.store(app.wantsAnimation(), .release);

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
    vx.setBracketedPaste(writer, true) catch {}; // exitAltScreen reset it
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
    // Background auto-fetch cadence (config `fetch_interval_secs`, 0 = off). Seed
    // the accumulator so the first fetch fires a few seconds after startup rather
    // than a full interval later.
    const fetch_interval_ms: u64 = @as(u64, state.app.config.fetch_interval_secs) * 1000;
    var fetch_ms: u64 = if (fetch_interval_ms > 3000) fetch_interval_ms - 3000 else 0;
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
        } else {
            // The about-splash animation runs on every fast tick (independent of
            // the background refresh, and without triggering a git status).
            if (state.app.animate_flag.load(.acquire)) {
                _ = state.loop.tryPostEvent(.anim_tick) catch false;
            }
            // Idle: fire the periodic working-tree refresh only at the slower
            // cadence (built up from the fast ticks), not every tick.
            if (interval_ms > 0) {
                idle_ms += spinner_tick_ms;
                if (idle_ms >= interval_ms) {
                    idle_ms = 0;
                    _ = state.loop.tryPostEvent(.refresh_tick) catch false;
                }
            }
            // The background auto-fetch runs on its own (slower) cadence. A
            // focus-triggered fetch restarts the countdown so the next timed one
            // is a full interval away.
            if (fetch_interval_ms > 0) {
                if (state.app.fetch_timer_reset.swap(false, .acquire)) fetch_ms = 0;
                fetch_ms += spinner_tick_ms;
                if (fetch_ms >= fetch_interval_ms) {
                    fetch_ms = 0;
                    _ = state.loop.tryPostEvent(.fetch_tick) catch false;
                }
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
    // Start a fresh grapheme arena for this frame: multibyte cells written below
    // reference it, and it must stay valid until vaxis flushes (which copies the
    // bytes into its own storage). See `grapheme_arena`.
    resetGraphemeArena();
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
    // Full-screen mode hides the side column so the Diff/main panel fills the
    // terminal (side_w = 0 → the main panel is drawn at x=0, full width).
    const side_w = if (app.diff_fullscreen) 0 else sidePanelWidth(root.width, app.config.side_panel_width_percent);
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

    if (!app.diff_fullscreen) {
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
            const w = if (app.mode == .rebase_plan) blk: {
                break :blk panel(root, 0, y, side_w, commits_h, "[4] Interactive rebase (enter run, esc cancel)", app.focus == .commits, listScrollInfo(app, .commits));
            } else if (app.commitsFilesActive()) blk: {
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
    }

    const main_title = if (app.staging_patch_mode)
        "Building patch (esc back)"
    else if (app.staging_active)
        (if (app.staging_staged_view) "Staging - staged" else "Staging - unstaged")
    else if (app.diff_base) |diff_ref|
        // The " ..." suffix marks three-dot (merge-base) mode.
        (std.fmt.bufPrint(&app.main_title_buf, "Diff [base {s}{s}]", .{ diff_ref[0..@min(diff_ref.len, 16)], if (app.diff_three_dot) " ..." else "" }) catch "Diff [diffing]")
    else if (app.contentFocus() == .branches and app.selectedBranchRefName() != null)
        // A selected branch/tag shows its commit graph, titled "Log".
        "Log"
    else if (app.focus == .main and app.contentFocus() == .files and app.files_tab == .files and app.selectedFile() != null)
        // Tabbed into a working-tree file's diff: advertise that <enter> opens
        // the stage/unstage view (the behaviour isn't otherwise discoverable).
        "Diff (enter to stage)"
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
        if (app.showAboutSplash()) drawAbout(main, app) else drawDiff(main, app);
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
        .commit_graph => drawCommitGraphPopup(root, app),
        .conflict_resolve => drawConflicts(root, app),
        else => {},
    }
}

fn drawCommitGraphPopup(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const w: u16 = root.width -| 4;
    const h: u16 = root.height -| 2;
    var title_buf: [96]u8 = undefined;
    const title = if (app.commit_graph_all)
        "Commit graph - all branches"
    else if (app.data.current_branch.len > 0)
        (std.fmt.bufPrint(&title_buf, "Commit graph - {s} (current branch)", .{app.data.current_branch}) catch "Commit graph - current branch")
    else
        "Commit graph - current branch (detached)";
    const win = popup(root, w, h, title, null);

    const footer_row: u16 = win.height -| 1;
    print(win, footer_row, 0, "j/k move  p parent  H/L pan  a all/current  ^o copy hash  enter go-to  esc close", st.bottom_accent);

    if (app.commit_graph_loading or app.commit_graph == null) {
        var sbuf: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&sbuf, "{s} loading graph...", .{spinnerGlyph(app.spinner_frame)}) catch "loading graph...";
        print(win, win.height / 2, 1, msg, st.muted);
        return;
    }

    const graph = app.commit_graph.?;
    const plain = app.commit_graph_plain orelse graph;
    const avail: usize = footer_row; // content rows above the footer
    if (avail == 0) return;

    app.commit_graph_view_h = @intCast(avail);
    const max_scroll = app.commit_graph_lines -| avail;
    // On open / scope toggle, center the cursor row once. Otherwise leave the
    // scroll where the user (keyboard or wheel) put it.
    if (app.commit_graph_recenter) {
        app.commit_graph_scroll = if (app.commit_graph_sel > avail / 2) app.commit_graph_sel - avail / 2 else 0;
        app.commit_graph_recenter = false;
    }
    if (app.commit_graph_scroll > max_scroll) app.commit_graph_scroll = max_scroll;

    // Clamp the horizontal pan to the widest line.
    const content_w: usize = win.width;
    const max_hscroll: u16 = @intCast(app.commit_graph_max_width -| content_w);
    if (app.commit_graph_hscroll > max_hscroll) app.commit_graph_hscroll = max_hscroll;
    const h_off = app.commit_graph_hscroll;

    // Register the visible rows (ANSI-stripped) for mouse selection/copy.
    const px0: u16 = (root.width - w) / 2;
    const py0: u16 = (root.height - h) / 2;
    app.beginDialogGrid(px0 + 1, py0 + 1, footer_row);

    var it = std.mem.splitScalar(u8, graph, '\n');
    var pit = std.mem.splitScalar(u8, plain, '\n');
    var idx: usize = 0;
    var row: u16 = 0;
    while (it.next()) |line| : (idx += 1) {
        const pline = pit.next() orelse "";
        if (idx < app.commit_graph_scroll) continue;
        if (row >= footer_row) break;
        const selected = idx == app.commit_graph_sel;
        var base = st.normal;
        if (selected) {
            applySel(&base, .active);
            fillRow(win, row, base);
        }
        app.setDialogRow(row, pline);
        const sel = app.dialogRowSelection(row);
        const lo: u16 = if (sel) |s| s.lo else 0;
        const hi: u16 = if (sel) |s| s.hi else 0;
        // The graph carries git's own ANSI colours; printAnsi renders them over
        // the (possibly selected) background, with the drag-selection span lit
        // and the horizontal pan applied.
        printAnsi(win, row, line, base, lo, hi, h_off);
        row += 1;
    }
    drawScrollbarRange(root, px0 + w - 1, py0 + 1, avail, app.commit_graph_lines, app.commit_graph_scroll, true);
}

fn drawConflicts(root: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    const w: u16 = root.width -| 4;
    const h: u16 = root.height -| 2;
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Resolve conflicts - {s}  ({d}/{d})", .{
        app.conflict_path,
        @min(app.conflict_index + 1, app.conflicts.len),
        app.conflicts.len,
    }) catch "Resolve conflicts";
    const win = popup(root, w, h, title, null);

    const footer_row: u16 = win.height -| 1;
    print(win, footer_row, 0, "j/k conflict  o ours  t theirs  b both  u undo  esc back", st.bottom_accent);

    const avail: usize = footer_row; // content rows above the footer
    if (avail == 0 or app.conflicts.len == 0) return;

    const content = app.conflict_content;
    const idx = @min(app.conflict_index, app.conflicts.len - 1);
    const cur = app.conflicts[idx];

    // Total line count, matching conflicts.zig's line addressing (a trailing
    // newline does not create an extra empty line).
    var total: usize = 0;
    {
        var p: usize = 0;
        while (p < content.len) : (total += 1) {
            const nl = std.mem.indexOfScalarPos(u8, content, p, '\n');
            p = if (nl) |n| n + 1 else content.len;
        }
    }
    if (total == 0) return;

    // Centre the viewport on the current conflict block.
    const block_h = cur.end - cur.start + 1;
    const center = cur.start + block_h / 2;
    var scroll: usize = if (center > avail / 2) center - avail / 2 else 0;
    const max_scroll = total -| avail;
    if (scroll > max_scroll) scroll = max_scroll;

    // Line-number gutter sized to the largest line number.
    var gutter: u16 = 2;
    {
        var v = total;
        var digits: u16 = 0;
        while (v > 0) : (v /= 10) digits += 1;
        gutter = @max(digits, 1) + 1; // number + one padding space
    }

    const ours_end = cur.ancestor orelse cur.target;
    var line_no: usize = 0;
    var p: usize = 0;
    var row: u16 = 0;
    while (p < content.len and row < footer_row) : (line_no += 1) {
        const nl = std.mem.indexOfScalarPos(u8, content, p, '\n');
        const line_end = if (nl) |n| n else content.len;
        const next = if (nl) |n| n + 1 else content.len;
        defer p = next;
        if (line_no < scroll) continue;
        var text = content[p..line_end];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];

        const in_block = line_no >= cur.start and line_no <= cur.end;
        const is_marker = conflicts_mod.isMarkerLine(text);

        var base = st.normal;
        if (in_block) {
            applySel(&base, .active);
            fillRow(win, row, base);
        }

        // Right-aligned 1-based line number in the gutter — accent + bold for the
        // active conflict's lines (over its highlight background), muted elsewhere.
        var num_buf: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{line_no + 1}) catch "";
        const num_col: u16 = gutter -| 1 -| @as(u16, @intCast(num.len));
        var gutter_style = if (in_block) base else st.muted;
        if (in_block) {
            gutter_style.fg = st.bottom_accent.fg;
            gutter_style.bold = true;
        }
        print(win, row, num_col, num, gutter_style);

        var line_style = base;
        if (is_marker) {
            line_style.fg = st.warning.fg;
            line_style.bold = true;
        } else if (in_block) {
            // Tint ours green and theirs red within the active block; the diff3
            // base region keeps the default colour.
            if (line_no > cur.start and line_no < ours_end) {
                line_style.fg = st.added.fg;
            } else if (line_no > cur.target and line_no < cur.end) {
                line_style.fg = st.removed.fg;
            }
        }
        print(win, row, gutter, text, line_style);
        row += 1;
    }

    drawScrollbarRange(root, (root.width - w) / 2 + w - 1, (root.height - h) / 2 + 1, avail, total, scroll, true);
}

const help_lines = [_][]const u8{
    "Global",
    "  q, ctrl+c      quit",
    "  R              refresh",
    "  1-5            jump to a panel (Status, Files, Branches, Commits, Stash)",
    "  h, left        focus the panel on the left",
    "  l, right       focus the panel on the right",
    "  j, down        move the selection down",
    "  k, up          move the selection up",
    "  tab            focus the Diff panel (tab again returns)",
    "  H              scroll the focused panel left (long rows)",
    "  L              scroll the focused panel right (long rows)",
    "  [              previous tab (or staging side)",
    "  ]              next tab (or staging side)",
    "  enter          inspect the selection in the main panel",
    "  esc            go back or cancel",
    "  z              maximize the Diff panel to full screen (z or esc exits)",
    "  @              command log",
    "  ?              this help",
    "  ctrl+z         undo the last operation (reflog reset)",
    "  ctrl+o         copy the selected hash, branch or tag to the clipboard",
    "  o              open the selected commit or branch on its remote host",
    "  W              diffing menu (mark a base ref, then compare another; the",
    "                 menu reverses direction and toggles a three-dot merge-base",
    "                 diff — only the target's own changes, GitHub-PR style)",
    "  f              fetch (async)",
    "  p              pull (async)",
    "  P              push (async)",
    "  mouse drag     select text in the Diff panel (auto-copies on release)",
    "",
    "Range select  (multi-selection in list panels)",
    "  v              toggle a sticky range anchored at the cursor",
    "  shift+up       extend the range up",
    "  shift+down     extend the range down",
    "  *              in Commits, select every commit unique to the branch",
    "  esc            cancel the range",
    "                 The action key then acts on every selected row: stage,",
    "                 discard or edit files; drop, squash, fixup, edit, move,",
    "                 revert or copy commits; delete branches or tags; drop",
    "                 stashes; toggle commit files into the patch.",
    "",
    "Files  (tabs: Files, Worktrees, Submodules — [ and ] switch)",
    "  space          stage or unstage (whole dir in tree view)",
    "  a              stage or unstage all",
    "  c              commit",
    "  w              commit with --no-verify (skip hooks)",
    "  A              amend the last commit",
    "  e              open the file in your editor",
    "  i              add the file to .gitignore",
    "  y              copy the file path to the clipboard",
    "  ctrl+f         make a fixup! for the staged change's base commit",
    "  d              discard menu",
    "  D              discard all",
    "  s              stash menu (all, +untracked, staged, file)",
    "  /              filter by path",
    "  ctrl+b         status filter",
    "  `              toggle the directory tree",
    "  enter          open the hunk/line staging view (a conflicted file opens",
    "                 the per-conflict resolver: j/k between conflicts, o/t/b",
    "                 pick ours/theirs/both, u undo)",
    "  m              merge/rebase actions: continue, amend+continue, abort",
    "",
    "Worktrees tab",
    "  space, enter   switch into the worktree",
    "  n              new worktree",
    "  o              open it in your editor",
    "  d              remove the worktree",
    "",
    "Submodules tab",
    "  enter          enter the submodule",
    "  space          update it",
    "  n              add a submodule",
    "  e              edit its URL",
    "  d              remove it",
    "  b              bulk actions",
    "                 (inside a worktree or submodule, esc walks back out to",
    "                 the parent repo)",
    "",
    "Staging view",
    "  j, k           move by line",
    "  v              toggle range selection",
    "  space          stage/unstage the line(s); on a @@ header the whole hunk",
    "  [              switch to the unstaged side",
    "  ]              switch to the staged side",
    "  \\              toggle split view (unstaged | staged)",
    "  c              commit the staged changes",
    "  A              amend the staged changes",
    "  e              open the file in your editor",
    "",
    "Branches  (tabs: Local, Remotes, Tags)",
    "  space          checkout the selected branch",
    "  c              checkout by name (type a branch/ref; \"-\" = previous)",
    "  n              new branch (new tag on the Tags tab)",
    "  R              rename the branch",
    "  w              create a worktree at the selected ref",
    "  d              delete the branch or tag",
    "  M              merge into the current branch",
    "  r              rebase onto the selected branch",
    "  f              fast-forward the selected branch",
    "  g              reset the current branch to the selected one",
    "  F              force-checkout (discards changes)",
    "  T              tag the branch",
    "  N              move commits onto a new branch",
    "  G              open the pull request page",
    "  s              branch sort menu",
    "",
    "Remotes tab — the remotes list",
    "  enter, space   view the remote's branches",
    "  n              add a remote",
    "  e              edit it (rename and URL)",
    "  d              remove the remote",
    "  f              fetch this remote",
    "",
    "Remotes tab — inside a remote's branches",
    "  space          checkout",
    "  n              new local branch from it",
    "  M              merge",
    "  r              rebase",
    "  g              reset",
    "  u              set upstream",
    "  d              delete the remote branch",
    "  esc            back to the remotes list",
    "",
    "Tags tab",
    "  space          checkout the tag (detached HEAD)",
    "  n              new tag (empty message = lightweight, a message =",
    "                 annotated; overwriting prompts to force)",
    "  P              push the tag to a remote",
    "  g              reset menu (soft, mixed, hard) onto the tag",
    "  d              delete menu (local, remote, both)",
    "",
    "Commits  (tabs: Commits, Reflog)",
    "  enter          view the commit's changed files",
    "  space          checkout the commit (detached HEAD)",
    "  n              new branch at the commit",
    "  N              move the branch's commits onto a new branch (needs upstream)",
    "  a              change the commit's author (reset to you, or set one)",
    "  T              create a tag at the commit (name, then message)",
    "  g              reset menu",
    "  t              revert the commit",
    "  x              verify the commit's GPG signature (result in a dialog)",
    "  c              copy the commit (for cherry-pick)",
    "  V              paste — cherry-pick the copied commit onto HEAD",
    "  ctrl+r         clear the cherry-pick copy selection",
    "  y              copy menu: commit hash, subject or author",
    "  d              drop the commit (interactive rebase)",
    "  s              squash down (interactive rebase)",
    "  f              fixup down (interactive rebase)",
    "  e              edit — stop the rebase at this commit",
    "  r              reword the commit message",
    "  F              create a fixup! commit",
    "  S              autosquash the fixups above",
    "  B              mark a base, then rebase a branch onto it",
    "  G              open the new pull/merge request page",
    "  W              diffing menu (compare the selection against a marked base)",
    "  /              filter the log by message, author or path (esc clears)",
    "  b              bisect menu (start, then mark good/bad/skip/reset)",
    "  ctrl+p         custom patch menu (apply, remove from commit, reset)",
    "  ctrl+j         move the commit down",
    "  ctrl+k         move the commit up",
    "  ctrl+l         commit graph viewer (its own keys show in its footer)",
    "  i              interactive rebase — a plan editor for the commits down",
    "                 to the selected one. p/d/s/f/e mark pick/drop/squash/",
    "                 fixup/edit; v or shift+arrows select a range; ctrl+j and",
    "                 ctrl+k reorder; enter runs it, esc cancels.",
    "                 In a commit's file list: space toggles a whole file into",
    "                 the patch, enter opens the file to pick lines, e opens",
    "                 the editor, d discards the file's changes from the commit.",
    "                 Reflog tab — recovery view of where HEAD has been: space",
    "                 checkout (detached), g reset HEAD to it, n new branch,",
    "                 c/V copy and paste, o browser, W diff. History-rewriting",
    "                 keys do not apply to reflog entries.",
    "",
    "Stash",
    "  space          apply the stash",
    "  g              pop the stash",
    "  d              drop the stash",
    "  r              rename the selected stash",
    "",
    "Operations",
    "  git actions    succeed silently (summary in the bottom bar); only",
    "                 failures pop a dialog (enter dismisses, up/down scroll).",
    "                 Config: result_dialog = on_error | always | never",
    "  slow actions   merge, rebase, bisect, fast-forward and patch run in the",
    "                 background (spinner in Status); navigation stays live",
    "                 while they run, but other actions wait until they finish",
    "  network        fetch, pull and push run in the background (status shows",
    "                 in the bottom bar)",
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
    var wrapped: [512]HelpLine = undefined;
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
    // The key column of each command line is redrawn in this colour so the keys
    // stand out from their descriptions.
    const key_style: vaxis.Style = .{ .fg = .{ .index = ui_theme.footer_key }, .bold = true };
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
            // Recolour just the key token (leave headers, notes and any active
            // text selection untouched).
            if (!wl.header and app.dialogRowSelection(row) == null) {
                if (helpKeyEnd(wl.text)) |end| print(win, row, 2, wl.text[2..end], key_style);
            }
        }
        row += 1;
    }
}

/// For a command line (`"  <key>  <description>"`), the byte index just past the
/// key token, so `text[2..end]` is the key. Returns null for section notes and
/// continuation lines (deep indent, or no early two-space gap).
fn helpKeyEnd(text: []const u8) ?usize {
    if (text.len < 4) return null;
    if (!(text[0] == ' ' and text[1] == ' ' and text[2] != ' ')) return null;
    var i: usize = 2;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == ' ' and text[i + 1] == ' ') {
            // A gap far past the key column means this is prose, not a key line.
            return if (i - 2 <= 16) i else null;
        }
    }
    return null;
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
    // Wide enough to show the 72-column body-wrap guide (see below) with a small
    // margin, but never wider than the terminal.
    const w: u16 = @min(@as(u16, 80), root.width -| 4);
    const title = if (app.commit_action == .reword) "Reword commit" else "Commit message";
    const win = popup(root, w, 12, title, null);

    // The description's soft body-wrap guide column (config; 0 disables it).
    const body_guide_col: usize = app.config.commit_body_guide;

    // Field labels indicate which has focus.
    print(win, 0, 0, "Summary", if (subject_focused) st.active_title else st.muted);
    print(win, 3, 0, "Description (optional)", if (subject_focused) st.muted else st.active_title);

    // Character counter for the summary, right-aligned on its label row. It
    // shows in the warning colour and turns to the removed colour once it goes
    // over `commit_summary_limit` (default 50, the git subject convention); a
    // limit of 0 disables the red threshold (it stays the warning colour).
    const subj_len = std.unicode.utf8CountCodepoints(app.commit_buffer.items) catch app.commit_buffer.items.len;
    var count_buf: [16]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{subj_len}) catch "";
    const limit = app.config.commit_summary_limit;
    const count_style = if (limit > 0 and subj_len > limit) st.removed else st.warning;
    const count_col = win.width -| @as(u16, @intCast(count_text.len));
    // Keep it clear of the "Summary" label (7 cols) on a very narrow popup.
    if (count_col > 8) print(win, 0, count_col, count_text, count_style);

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

    // A soft vertical guide at the configured body-wrap column, drawn *under*
    // the description text: where a line reaches it the text renders over it,
    // shorter and empty rows keep the marker. Disabled when the column is 0,
    // and auto-hidden when the popup is too narrow to show it; tracks
    // horizontal scroll.
    if (body_guide_col > 0 and body_guide_col >= scx.origin) {
        const guide_screen_col = body_guide_col - scx.origin;
        if (guide_screen_col < win.width) {
            const gx: u16 = @intCast(guide_screen_col);
            var gr: u16 = body_top;
            while (gr < footer_row) : (gr += 1) {
                win.writeCell(gx, gr, .{ .char = .{ .grapheme = "\u{2502}", .width = 1 }, .style = st.muted });
            }
        }
    }

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
        .force_checkout => "Force checkout",
        .checkout_ref => "Checkout",
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
        const line = std.fmt.bufPrint(&buf, "{s} - m: menu (continue, abort)", .{app.data.state.label()}) catch app.data.state.label();
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
        // Cursor is tracked by data index (file_index); the range is in visible-
        // ordinal space (what activeListSelected uses), so range-check `ordinal`.
        const sel = rowSel(app, .files, ordinal, idx == app.file_index, app.focus == .files);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);
        // The two short-status columns are colored independently:
        // the index/staged column green, the worktree/unstaged column red — so a
        // half-staged "MM" shows one green M and one red M.
        var col = printSpan(win, row, 0, file.short_status[0..1], statusCharStyle(file.short_status[0], true, file.conflict, base));
        col = printSpan(win, row, col, file.short_status[1..2], statusCharStyle(file.short_status[1], false, file.conflict, base));
        col = printSpan(win, row, col, " ", base);
        // On the focused selection the unstaged red is illegible against the
        // blue highlight, so draw that filename in the legible `selected_fg`
        // instead; every other case keeps its status colour. The red status
        // letter in the column above still marks the file as unstaged.
        const path_style = if (file.conflict)
            withFg(base, ui_theme.warning)
        else if (file.has_unstaged)
            withFg(base, if (sel == .active) ui_theme.selected_fg else ui_theme.unstaged)
        else if (file.has_staged)
            withFg(base, ui_theme.staged)
        else
            base;
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
        const sel = rowSel(app, .files, i, i == app.files_tree.cursor, app.focus == .files);
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
            const sel = rowSel(app, .branches, idx, idx == selected, app.focus == .branches);
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
        const sel = rowSel(app, .branches, idx, idx == app.remotes_index, app.focus == .branches);
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
        const sel = rowSel(app, .branches, idx, idx == app.tag_index, app.focus == .branches);
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
        drawSelectable(win, row, line, if (wt.is_current) styles().staged else styles().normal, rowSel(app, .files, idx, idx == app.worktree_index, app.focus == .files));
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
        drawSelectable(win, row, line, style, rowSel(app, .files, idx, idx == app.submodule_index, app.focus == .files));
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
        drawSelectable(win, row, line, style, rowSel(app, panel_focus, idx, idx == selected, focused));
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
        const sel = rowSel(app, panel_focus, i, i == tree.cursor, focused);
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

/// A stable truecolor for an author name: an HSL colour seeded by the md5 of
/// the name (hue from the name, medium saturation and lightness) so each author
/// always renders in the same distinct colour.
fn authorColor(name: []const u8) vaxis.Color {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(name, &digest, .{});
    const h = authorHashFloat(digest[0..4]) * 360.0;
    const s = 0.6 + 0.4 * authorHashFloat(digest[4..8]);
    const l = 0.4 + authorHashFloat(digest[8..12]) * 0.2;
    return .{ .rgb = hslToRgb(h, s, l) };
}

/// Map a 4-byte hash slice → [0,1): a running `(sum + byte) % 100`, then /100.
fn authorHashFloat(bytes: []const u8) f64 {
    var sum: usize = 0;
    for (bytes) |b| sum = (sum + b) % 100;
    return @as(f64, @floatFromInt(sum)) / 100.0;
}

fn hslToRgb(h: f64, s: f64, l: f64) [3]u8 {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (hp < 1.0) {
        r = c;
        g = x;
    } else if (hp < 2.0) {
        r = x;
        g = c;
    } else if (hp < 3.0) {
        g = c;
        b = x;
    } else if (hp < 4.0) {
        g = x;
        b = c;
    } else if (hp < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = l - c / 2.0;
    return .{
        @intFromFloat(@round((r + m) * 255.0)),
        @intFromFloat(@round((g + m) * 255.0)),
        @intFromFloat(@round((b + m) * 255.0)),
    };
}

/// The compact author tag: two words → one leading char each; one word → its
/// first two chars (codepoint-aware). Written into `buf`; empty for a blank name.
fn authorInitials(name: []const u8, buf: *[8]u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0) return "";
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const first = it.next() orelse return "";
    const a = firstCodepoint(first);
    @memcpy(buf[0..a.len], a);
    var n = a.len;
    const rest = if (it.next()) |second| second else first[a.len..];
    const b = firstCodepoint(rest);
    @memcpy(buf[n .. n + b.len], b);
    n += b.len;
    return buf[0..n];
}

/// The first UTF-8 codepoint of `s` as a byte slice (or `s` if it is short /
/// malformed).
fn firstCodepoint(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return s[0..@min(len, s.len)];
}

/// The byte ranges of a leading Conventional-Commits prefix `type(scope)!: ` in
/// `s`, or null when it doesn't match. `scope` spans `[type_end, scope_end)`
/// (empty when absent); the breaking `!` (when present) sits at `scope_end`; the
/// `: ` separator spans `[colon_start, colon_end)`; the description follows.
fn conventionalPrefix(s: []const u8) ?struct { type_end: usize, scope_end: usize, bang: bool, colon_start: usize, colon_end: usize } {
    var i: usize = 0;
    while (i < s.len and std.ascii.isAlphabetic(s[i])) : (i += 1) {}
    if (i == 0) return null; // no type
    const type_end = i;
    var scope_end = i;
    if (i < s.len and s[i] == '(') {
        const close = std.mem.indexOfScalarPos(u8, s, i + 1, ')') orelse return null;
        scope_end = close + 1; // include the parentheses
        i = scope_end;
    }
    var bang = false;
    if (i < s.len and s[i] == '!') {
        bang = true;
        i += 1;
    }
    // Conventional Commits requires the ": " separator.
    if (i + 1 >= s.len or s[i] != ':' or s[i + 1] != ' ') return null;
    return .{ .type_end = type_end, .scope_end = scope_end, .bang = bang, .colon_start = i, .colon_end = i + 2 };
}

/// Draw a commit subject, colouring a leading Conventional-Commits prefix when
/// enabled: type in accent, scope muted, breaking `!` red, the description in
/// the base colour. Plain draw otherwise (including non-conventional subjects).
fn printCommitSubject(win: vaxis.Window, row: u16, col: u16, subject: []const u8, base: vaxis.Style, highlight: bool) void {
    const p = if (highlight) conventionalPrefix(subject) else null;
    const cc = p orelse {
        _ = printSpan(win, row, col, subject, base);
        return;
    };
    var c = printSpan(win, row, col, subject[0..cc.type_end], withFg(base, ui_theme.accent));
    if (cc.scope_end > cc.type_end) c = printSpan(win, row, c, subject[cc.type_end..cc.scope_end], withFg(base, ui_theme.muted));
    if (cc.bang) c = printSpan(win, row, c, "!", withFg(base, ui_theme.removed));
    c = printSpan(win, row, c, subject[cc.colon_start..cc.colon_end], withFg(base, ui_theme.muted));
    _ = printSpan(win, row, c, subject[cc.colon_end..], base);
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
        const sel = rowSel(app, panel_focus, idx, idx == selected, focused);
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);

        const hash_fg = if (marked) ui_theme.warning else if (copied) ui_theme.staged else ui_theme.hash;
        var buf: [80]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "{c}{s} ", .{ marker, commit.short_hash }) catch "";
        var col = printSpan(win, row, 0, head, withFg(base, hash_fg));

        // The author's initials in a stable per-author colour, padded to a
        // two-cell column so the subjects still line up.
        var ini_buf: [8]u8 = undefined;
        const initials = authorInitials(commit.author, &ini_buf);
        if (initials.len > 0) {
            var author_style = base;
            author_style.fg = authorColor(commit.author);
            const author_start = col;
            // `printSpan` (static glyph table) — not `printGlyph` with a slice
            // into the stack `ini_buf`, whose grapheme would dangle by flush.
            col = printSpan(win, row, col, initials, author_style);
            while (col < author_start + 2) col = printSpan(win, row, col, " ", base);
            col = printSpan(win, row, col, " ", base);
        }
        printCommitSubject(win, row, col, commit.subject, base, app.config.highlight_conventional_commits);
    }
}

fn drawRebasePlan(win: vaxis.Window, app: *const app_mod.App) void {
    const plan = app.rebase_plan orelse return;
    const start = app.listScroll(.commits);
    var row: u16 = 0;
    var idx = start;
    while (idx < plan.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const e = plan[idx];
        var base = styles().normal;
        const sel: Sel = if (idx == app.rebase_plan_index)
            selOf(true, app.focus == .commits)
        else if (rebaseplan_mod.inRange(app, idx))
            .inactive
        else
            .none;
        applySel(&base, sel);
        if (sel != .none) fillRow(win, row, base);
        // The action label is coloured by kind: drop dim, squash/fixup warning,
        // edit accent, pick normal. The hash stays the log yellow.
        const act = e.action;
        const act_fg: u8 = switch (act) {
            .pick => ui_theme.added,
            .drop => ui_theme.removed,
            .squash, .fixup => ui_theme.warning,
            .edit => ui_theme.accent,
        };
        var buf: [16]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "{s} ", .{act.label()}) catch "";
        var col = printSpan(win, row, 0, head, withFg(base, act_fg));
        col = printSpan(win, row, col, e.short_hash, withFg(base, ui_theme.hash));
        col = printSpan(win, row, col, " ", base);
        _ = printSpan(win, row, col, e.subject, base);
    }
}

fn drawCommits(win: vaxis.Window, app: *const app_mod.App) void {
    // The interactive-rebase editor takes over the Commits panel while active.
    if (app.mode == .rebase_plan) return drawRebasePlan(win, app);
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
        drawSelectable(win, row, line, styles().normal, rowSel(app, .stash, idx, idx == app.stash_index, app.focus == .stash));
    }
}

// --- Status-panel "about" splash (banner + repo info + a rotating donut) ---

/// The app version, mirrored from `build.zig.zon`.
const app_version = "0.1.0";

/// 5-row block-font glyphs (each 5 columns, `#` = filled) for the banner word.
fn bannerGlyph(c: u8) [5][]const u8 {
    return switch (c) {
        'Z' => .{ "#####", "   ##", "  ## ", " ##  ", "#####" },
        'I' => .{ " ### ", "  #  ", "  #  ", "  #  ", " ### " },
        'G' => .{ " ####", "#    ", "#  ##", "#   #", " ####" },
        'T' => .{ "#####", "  #  ", "  #  ", "  #  ", "  #  " },
        'Y' => .{ "#   #", " # # ", "  #  ", "  #  ", "  #  " },
        else => .{ "     ", "     ", "     ", "     ", "     " },
    };
}

const banner_word = "ZIGGITY";
const banner_rows = 5;
const banner_width = banner_word.len * 5 + (banner_word.len - 1); // glyphs + gaps

/// Build one banner row into `buf`, translating `#` to a full block. Returns the
/// UTF-8 slice; its display width is always `banner_width` columns.
fn buildBannerRow(buf: []u8, r: usize) []const u8 {
    var n: usize = 0;
    for (banner_word, 0..) |letter, li| {
        if (li > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        for (bannerGlyph(letter)[r]) |ch| {
            if (ch == '#') {
                if (n + 3 <= buf.len) {
                    @memcpy(buf[n .. n + 3], "\u{2588}"); // full block
                    n += 3;
                }
            } else if (n < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
        }
    }
    return buf[0..n];
}

fn centerCol(width: u16, content: u16) u16 {
    return if (content >= width) 0 else (width - content) / 2;
}

/// Draw a centred, *selectable* splash text line on `row` and advance `row`.
/// The text is left-padded to its centred column into an App-owned buffer and
/// drawn via `drawDialogRow`, which registers it in the dialog-selection grid so
/// a mouse drag can copy it (banner rows and the donut are left unregistered, so
/// only these lines are selectable). Padding keeps the grid's column mapping
/// aligned with what's on screen.
fn aboutLine(win: vaxis.Window, app: *app_mod.App, row: *u16, slot: *usize, text: []const u8, style: vaxis.Style) void {
    defer row.* += 1;
    if (row.* >= win.height or slot.* >= app.about_bufs.len) return;
    const buf = &app.about_bufs[slot.*];
    slot.* += 1;
    const pad: usize = if (text.len >= win.width) 0 else (@as(usize, win.width) - text.len) / 2;
    var n: usize = 0;
    while (n < pad and n < buf.len) : (n += 1) buf[n] = ' ';
    const take = @min(text.len, buf.len - n);
    @memcpy(buf[n .. n + take], text[0..take]);
    n += take;
    drawDialogRow(win, app, row.*, buf[0..n], style);
}

/// Like `aboutLine`, but the text is also emitted as an OSC 8 hyperlink so
/// terminals that support it make `uri` clickable, while still being selectable
/// (registered in the dialog grid) for drag-to-copy. `uri` must be a stable
/// (static / App-owned) slice — vaxis keeps the link by reference until flush.
fn aboutUrlLine(win: vaxis.Window, app: *app_mod.App, row: *u16, slot: *usize, uri: []const u8, style: vaxis.Style) void {
    defer row.* += 1;
    if (row.* >= win.height or slot.* >= app.about_bufs.len) return;
    const buf = &app.about_bufs[slot.*];
    slot.* += 1;
    const pad: usize = if (uri.len >= win.width) 0 else (@as(usize, win.width) - uri.len) / 2;
    var n: usize = 0;
    while (n < pad and n < buf.len) : (n += 1) buf[n] = ' ';
    const take = @min(uri.len, buf.len - n);
    @memcpy(buf[n .. n + take], uri[0..take]);
    n += take;
    app.setDialogRow(row.*, buf[0..n]); // register for selection/copy
    // Record the clickable region so a plain click opens the browser directly.
    app.about_url = uri;
    app.about_url_row = row.*;
    app.about_url_lo = pad;
    app.about_url_hi = n;
    const hover = app.hoveringAboutUrl();
    app.about_url_hovered = hover;

    // Draw the cells ourselves so the URL columns carry the hyperlink (and an
    // underline on hover); the padding columns are plain. Honour any live drag
    // selection's highlight.
    const sel = app.dialogRowSelection(row.*);
    var col: u16 = 0;
    while (col < n and col < win.width) : (col += 1) {
        const is_url = col >= pad;
        var cs = style;
        if (sel) |s| {
            if (col >= s.lo and col < s.hi) cs.bg = .{ .index = ui_theme.selected_bg };
        }
        if (is_url and hover) cs.ul_style = .single;
        win.writeCell(col, row.*, .{
            .char = .{ .grapheme = ascii_table[buf[col]][0..1], .width = 1 },
            .style = cs,
            .link = if (is_url) .{ .uri = uri } else .{},
        });
    }
}

/// The calendar year for `now_unix` (falls back to 2026 before the clock is set).
fn currentYear(now_unix: i64) u16 {
    if (now_unix <= 0) return 2026;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now_unix) };
    return es.getEpochDay().calculateYearDay().year;
}

fn drawAbout(win: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    if (win.width == 0 or win.height == 0) return;
    // Register this frame's selection grid over the panel; rows left unset stay
    // empty (non-selectable), so only the text lines below can be copied.
    app.beginDialogGrid(@intCast(@max(win.x_off, 0)), @intCast(@max(win.y_off, 0)), win.height);
    var row: u16 = 1;
    var slot: usize = 0;

    // Banner (only when there's vertical room for it plus the text below). Drawn
    // with `print`, not registered — the block art isn't worth selecting.
    if (win.height > banner_rows + 8 and win.width >= banner_width) {
        var buf: [256]u8 = undefined;
        var r: usize = 0;
        while (r < banner_rows) : (r += 1) {
            const line = buildBannerRow(&buf, r);
            print(win, row, centerCol(win.width, banner_width), line, withFg(styles().normal, ui_theme.accent));
            row += 1;
        }
        row += 1;
    }

    // Copyright / repository / version. Show a single year until the current
    // year moves past the start year, then a "start-end" range.
    const start_year = 2026;
    const year = currentYear(app.now_unix);
    var cbuf: [96]u8 = undefined;
    const copyright = if (year <= start_year)
        std.fmt.bufPrint(&cbuf, "Copyright {d} Simone Arpe", .{start_year}) catch "Copyright Simone Arpe"
    else
        std.fmt.bufPrint(&cbuf, "Copyright {d}-{d} Simone Arpe", .{ start_year, year }) catch "Copyright Simone Arpe";
    aboutLine(win, app, &row, &slot, copyright, st.normal);
    aboutUrlLine(win, app, &row, &slot, "https://github.com/simoarpe/ziggity", withFg(st.normal, ui_theme.accent));
    var vbuf: [48]u8 = undefined;
    aboutLine(win, app, &row, &slot, std.fmt.bufPrint(&vbuf, "version {s}", .{app_version}) catch "version", st.normal);
    row += 1;

    // The repo status the user likes (from the loaded data, not the git preview).
    var sbuf: [128]u8 = undefined;
    aboutLine(win, app, &row, &slot, std.fmt.bufPrint(&sbuf, "On branch {s}", .{app.data.current_branch}) catch "", st.normal);
    if (app.data.upstream) |upstream| {
        const ahead = app.data.ahead orelse 0;
        const behind = app.data.behind orelse 0;
        if (ahead == 0 and behind == 0) {
            aboutLine(win, app, &row, &slot, std.fmt.bufPrint(&sbuf, "Up to date with {s}", .{upstream}) catch "", st.normal);
        } else {
            aboutLine(win, app, &row, &slot, std.fmt.bufPrint(&sbuf, "{s}: {d} ahead, {d} behind", .{ upstream, ahead, behind }) catch "", st.normal);
        }
    } else {
        aboutLine(win, app, &row, &slot, "No upstream configured", st.normal);
    }
    aboutLine(win, app, &row, &slot, std.fmt.bufPrint(&sbuf, "{d} changed  ({d} staged, {d} unstaged)", .{ app.data.files.len, app.data.stagedCount(), app.data.unstagedCount() }) catch "", st.normal);
    aboutLine(win, app, &row, &slot, std.fmt.bufPrint(&sbuf, "{d} branches  {d} stashes", .{ app.data.branches.len, app.data.stash.len }) catch "", st.normal);

    // The donut fills whatever vertical space is left (unregistered rows).
    const donut_top = row + 1;
    if (win.height > donut_top + 6) {
        drawDonut(win, donut_top, win.width, win.height - donut_top, app.anim_frame);
    }
}

const donut_max_w = 200;
const donut_max_h = 80;
// Frame-local scratch for donut_mod.render (UI thread only): shade level per
// cell (0 = empty) and the z-buffer. Sized generously; larger panels clamp.
var donut_cell: [donut_max_w * donut_max_h]u8 = undefined;
var donut_depth: [donut_max_w * donut_max_h]f32 = undefined;

fn shadeColor(level: usize) u8 {
    // A dim-blue -> cyan -> white ramp, all basic ANSI (palette-safe).
    return if (level < 3) 4 else if (level < 6) 6 else if (level < 9) 14 else 15;
}

/// Compute one donut frame (via `donut_mod`) and blit it into the panel at
/// `(0, y0)` sized `w x h` (panel-relative columns/rows). The shade math lives in
/// `donut.zig`; here we only map levels to a glyph + colour and write cells.
fn drawDonut(win: vaxis.Window, y0: u16, w: u16, h: u16, frame: usize) void {
    const cw: usize = @min(@as(usize, w), donut_max_w);
    const ch: usize = @min(@as(usize, h), donut_max_h);
    if (cw < 8 or ch < 6) return;
    const cells = cw * ch;
    donut_mod.render(frame, cw, ch, donut_depth[0..cells], donut_cell[0..cells]);

    // ASCII shades map through the static table so the grapheme reference is
    // stable for vaxis (which stores it by reference until the flush).
    var yy: usize = 0;
    while (yy < ch) : (yy += 1) {
        var xx: usize = 0;
        while (xx < cw) : (xx += 1) {
            const level = donut_cell[yy * cw + xx];
            if (level == 0) continue;
            const col: u16 = @intCast(xx);
            const rr: u16 = y0 + @as(u16, @intCast(yy));
            if (rr >= win.height or col >= win.width) continue;
            win.writeCell(col, rr, .{
                .char = .{ .grapheme = ascii_table[donut_mod.shades[level - 1]][0..1], .width = 1 },
                .style = .{ .fg = .{ .index = shadeColor(level - 1) }, .bold = true },
            });
        }
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
    /// The interactive-rebase plan editor is open.
    rebase_plan: bool = false,
    /// Branches panel drilled into a branch's commit list.
    branch_commits: bool = false,
    /// Within the Branches drill, showing a commit's file list (vs the commits).
    branch_files: bool = false,
    /// A merge/rebase/conflict is in progress (data.state != .clean).
    conflict: bool = false,
    /// The Diff panel is showing a working-tree file (so `e` can edit it).
    main_file: bool = false,
    /// The Diff/main panel is maximised to full screen.
    fullscreen: bool = false,
};

/// Keybinding hints for the current stage. A global suffix is appended since
/// those keys apply everywhere — except in the Branches list, where `R` renames
/// rather than refreshes, so that footer uses a suffix without "R refresh".
fn footerHints(c: FooterCtx) []const u8 {
    const global = "  @ log  ? help  ^z undo  R refresh  q quit";
    const global_branches = "  @ log  ? help  ^z undo  q quit";
    if (c.rebase_plan) {
        return "j/k move  p pick  d drop  s squash  f fixup  e edit  ^j/^k reorder  enter run  esc cancel";
    }
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
        return "space resolve (ours/theirs)  m menu (continue/abort)  d discard" ++ global;
    }
    if (c.focus == .branches) {
        return switch (c.branches_tab) {
            .local => "space checkout  c by-name  n new  R rename  d delete  M merge  r rebase  g reset  f ff  F force-co  T tag  N move  G pr  s sort  w worktree  W diff  [/] tabs" ++ global_branches,
            .remotes => if (c.remote_drill)
                "space checkout  n new-local  M merge  r rebase  g reset  u upstream  d delete  w worktree  W diff  enter commits  esc back" ++ global_branches
            else
                "enter/space branches  n add  e edit  d remove  f fetch  [/] tabs" ++ global_branches,
            .tags => "space checkout  n new-tag  d delete  P push  g reset  w worktree  W diff  [/] tabs" ++ global_branches,
        };
    }
    if (c.focus == .files) {
        return switch (c.files_tab) {
            .files => "space stage  a all  c/w commit/no-verify  A amend  e edit  d discard  i ignore  y copy  ^f fixup-base  s stash  / filter  ` tree  enter hunks  [/] tabs" ++ global,
            .worktrees => "space/enter switch  n new  o editor  d remove  [/] tabs" ++ global,
            .submodules => "enter enter  space update  n add  e edit-url  d remove  b bulk  [/] tabs" ++ global,
        };
    }
    return switch (c.focus) {
        .status => "1-5 panels  enter inspect  f fetch  p pull  P push" ++ global,
        .files => unreachable,
        .branches => unreachable,
        .commits => if (c.reflog)
            "space checkout  g reset  n new-branch  c/v/^r copy/paste/clear  y copy  o browser  W diff  [/] tabs" ++ global
        else
            "enter files  space checkout  n/N branch/move  T tag  g reset  t revert  x verify-sig  c/v/^r copy/paste/clear  d/s/f/e/r rebase  F fixup  S autosquash  B mark-base  G pr  ^l graph  W diff  / filter  b bisect  ^j/^k move" ++ global,
        .stash => "space apply  g pop  d drop  r rename  enter view" ++ global,
        .main => if (c.fullscreen)
            (if (c.main_file)
                "enter stage  j/k scroll  H/L pan  e edit  PgUp/PgDn page  drag select  ^o copy all  z exit full  esc back" ++ global
            else
                "j/k scroll  H/L pan  PgUp/PgDn page  drag select  ^o copy all  z exit full  esc back" ++ global)
        else if (c.main_file)
            "enter stage  j/k scroll  H/L pan  e edit  PgUp/PgDn page  drag select  ^o copy all  z full  esc back" ++ global
        else
            "j/k scroll  H/L pan  PgUp/PgDn page  drag select  ^o copy all  z full  esc back" ++ global,
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
        .rebase_plan = app.mode == .rebase_plan,
        .branch_commits = app.branch_commits_active,
        .branch_files = app.branchFilesActive(),
        .conflict = app.data.state != .clean,
        // `e` edits the file when the Diff panel shows a working-tree file.
        .main_file = app.focus == .main and !app.staging_active and
            app.contentFocus() == .files and app.selectedFile() != null,
        .fullscreen = app.diff_fullscreen,
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

/// Selection style for a list row that may be inside a multi-range: the cursor
/// row keeps the full highlight; other in-range rows get the dimmer one.
/// `ord` is the row's index in the panel's range space (= its cursor index).
fn rowSel(app: *const app_mod.App, render_focus: model.Focus, ord: usize, is_cursor: bool, focused: bool) Sel {
    if (is_cursor) return selOf(true, focused);
    if (app.rowInRange(render_focus, ord)) return .inactive;
    return .none;
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
fn emitRowCell(win: vaxis.Window, abs_col: u16, row: u16, grapheme: []const u8, width: u16, style: vaxis.Style) void {
    if (abs_col >= row_h_off) {
        const sc = abs_col - row_h_off;
        if (sc < win.width) win.writeCell(sc, row, .{ .char = .{ .grapheme = grapheme, .width = @intCast(width) }, .style = style });
    }
    if (abs_col + width > row_max_col) row_max_col = abs_col + width;
}

/// Like `print`, but returns the column after the last cell written so spans
/// (including static UTF-8 glyphs via `printGlyph`) can be composed on a row.
/// Columns are absolute (pre-`row_h_off`), so composition is unaffected by
/// horizontal scrolling; the full row is walked (even past the right edge) so
/// `row_max_col` reflects the true content width.
fn printSpan(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) u16 {
    if (row >= win.height) return col;
    var out_col = col;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte == '\n' or byte == '\r') break;
        if (byte == '\t') {
            var spaces: u8 = 0;
            while (spaces < 4) : (spaces += 1) {
                emitRowCell(win, out_col, row, " ", 1, style);
                out_col += 1;
            }
            i += 1;
            continue;
        }
        const dc = decodeCell(win, text, i);
        emitRowCell(win, out_col, row, dc.grapheme, dc.width, style);
        out_col += dc.width;
        i += dc.len;
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
        fn f(w: vaxis.Window, vc: u16, h: u16, r: u16, g: []const u8, width: u16, s: vaxis.Style, lo: u16, hi: u16) void {
            if (vc < h) return;
            const c = vc - h;
            if (c >= w.width) return;
            var cell_style = s;
            if (c >= lo and c < hi) cell_style.bg = .{ .index = ui_theme.selected_bg };
            w.writeCell(c, r, .{ .char = .{ .grapheme = g, .width = @intCast(width) }, .style = cell_style });
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
                emit(win, vis_col, h_off, row, " ", 1, style, sel_lo, sel_hi);
                vis_col += 1;
            }
            i += 1;
            continue;
        }
        const dc = decodeCell(win, line, i);
        emit(win, vis_col, h_off, row, dc.grapheme, dc.width, style, sel_lo, sel_hi);
        vis_col += dc.width;
        i += dc.len;
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
        emitRowCell(win, col, row, grapheme, 1, style);
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

// A frame-scoped arena for multibyte grapheme bytes. vaxis stores a cell's
// grapheme slice by reference and only reads it during the flush (where it
// copies the bytes into its own screen_last storage), so these bytes just need
// to outlive the current frame's render+flush. Reset at the top of `render`.
// ASCII goes through the static `ascii_table` and never touches this.
var grapheme_arena: [64 * 1024]u8 = undefined;
var grapheme_used: usize = 0;

fn resetGraphemeArena() void {
    grapheme_used = 0;
}

/// Copy `bytes` into the frame arena, returning a stable slice, or null when the
/// arena is full (the caller then falls back to '?').
fn stashGrapheme(bytes: []const u8) ?[]const u8 {
    if (grapheme_used + bytes.len > grapheme_arena.len) return null;
    const dst = grapheme_arena[grapheme_used .. grapheme_used + bytes.len];
    @memcpy(dst, bytes);
    grapheme_used += bytes.len;
    return dst;
}

/// One display cell decoded from `text` at byte `i`. An ASCII printable maps to
/// the static table; a well-formed UTF-8 sequence is copied into the frame arena
/// and measured with `gwidth`; anything else (a control byte, invalid UTF-8, or a
/// full arena) becomes '?'. `len` is the bytes consumed, `width` the columns.
const DecodedCell = struct { grapheme: []const u8, len: usize, width: u16 };

fn decodeCell(win: vaxis.Window, text: []const u8, i: usize) DecodedCell {
    const b = text[i];
    if (b < 0x80) {
        // ASCII printables use the static table (no arena, no lifetime worry);
        // control bytes render as '?'.
        if (b >= 32 and b < 127) return .{ .grapheme = ascii_table[b][0..1], .len = 1, .width = 1 };
        return .{ .grapheme = "?", .len = 1, .width = 1 };
    }
    const seq_len = utf8CellLen(text, i) orelse return .{ .grapheme = "?", .len = 1, .width = 1 };
    const stored = stashGrapheme(text[i .. i + seq_len]) orelse return .{ .grapheme = "?", .len = seq_len, .width = 1 };
    const w = win.gwidth(stored);
    return .{ .grapheme = stored, .len = seq_len, .width = if (w == 0) 1 else w };
}

/// The length of the valid UTF-8 sequence starting at `text[i]`, or null when the
/// lead byte is invalid or the sequence is truncated / ill-formed (the caller
/// then emits a single '?' and advances one byte).
fn utf8CellLen(text: []const u8, i: usize) ?usize {
    const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
    if (i + seq_len > text.len) return null;
    _ = std.unicode.utf8Decode(text[i .. i + seq_len]) catch return null;
    return seq_len;
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

    // The Diff panel advertises the fullscreen toggle, reflecting its state.
    try std.testing.expect(has(footerHints(.{ .focus = .main }), "z full"));
    try std.testing.expect(has(footerHints(.{ .focus = .main, .fullscreen = true }), "z exit full"));

    // Over a working-tree file, the Diff panel advertises `enter` → staging;
    // a plain commit/branch diff does not (enter does nothing there).
    try std.testing.expect(has(footerHints(.{ .focus = .main, .main_file = true }), "enter stage"));
    try std.testing.expect(!has(footerHints(.{ .focus = .main }), "enter stage"));

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

test "author initials: two words -> initials, one word -> first two chars" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("AL", authorInitials("Ada Lovelace", &buf));
    try std.testing.expectEqualStrings("AT", authorInitials("Alan Turing", &buf));
    try std.testing.expectEqualStrings("gr", authorInitials("grace", &buf));
    try std.testing.expectEqualStrings("x", authorInitials("x", &buf));
    try std.testing.expectEqualStrings("", authorInitials("", &buf));
    try std.testing.expectEqualStrings("", authorInitials("   ", &buf));
}

test "author colour is a stable per-author truecolor" {
    const a1 = authorColor("Ada Lovelace");
    const a2 = authorColor("Ada Lovelace");
    const b = authorColor("Alan Turing");
    // Always an RGB (truecolor) value.
    try std.testing.expect(std.meta.activeTag(a1) == .rgb);
    // Deterministic: the same author yields the same colour.
    try std.testing.expectEqual(a1.rgb, a2.rgb);
    // Different authors (almost always) differ — these two do.
    try std.testing.expect(!std.mem.eql(u8, &a1.rgb, &b.rgb));
}

test "hslToRgb hits the primary corners" {
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, hslToRgb(0.0, 1.0, 0.5)); // red
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, hslToRgb(120.0, 1.0, 0.5)); // green
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, hslToRgb(240.0, 1.0, 0.5)); // blue
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, hslToRgb(0.0, 0.0, 0.0)); // black
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, hslToRgb(0.0, 0.0, 1.0)); // white
}

test "conventionalPrefix parses type/scope/breaking and rejects non-conventional" {
    // type + scope + breaking + ": "
    const a = conventionalPrefix("feat(auth)!: add SSO").?;
    try std.testing.expectEqual(@as(usize, 4), a.type_end); // "feat"
    try std.testing.expectEqual(@as(usize, 10), a.scope_end); // "(auth)"
    try std.testing.expect(a.bang);
    try std.testing.expectEqual(@as(usize, 11), a.colon_start); // ':'
    try std.testing.expectEqual(@as(usize, 13), a.colon_end); // after ": "

    // type + ": " only
    const b = conventionalPrefix("fix: a bug").?;
    try std.testing.expectEqual(@as(usize, 3), b.type_end);
    try std.testing.expectEqual(@as(usize, 3), b.scope_end); // no scope
    try std.testing.expect(!b.bang);

    // scope, no breaking
    const c = conventionalPrefix("docs(readme): tweak").?;
    try std.testing.expectEqual(@as(usize, 4), c.type_end);
    try std.testing.expectEqual(@as(usize, 12), c.scope_end);
    try std.testing.expect(!c.bang);

    // Non-conventional subjects return null.
    try std.testing.expect(conventionalPrefix("just a normal message") == null);
    try std.testing.expect(conventionalPrefix("Merge branch 'x'") == null);
    try std.testing.expect(conventionalPrefix("fix the thing") == null); // no ": "
    try std.testing.expect(conventionalPrefix("feat(unclosed: x") == null); // scope not closed
    try std.testing.expect(conventionalPrefix(": no type") == null);
    try std.testing.expect(conventionalPrefix("") == null);
}

test "buildBannerRow is banner_width columns wide on every row" {
    var buf: [256]u8 = undefined;
    var r: usize = 0;
    while (r < banner_rows) : (r += 1) {
        const row = buildBannerRow(&buf, r);
        // Each codepoint (space or full block) occupies exactly one column.
        try std.testing.expectEqual(@as(usize, banner_width), std.unicode.utf8CountCodepoints(row) catch 0);
    }
}

test "currentYear converts epoch seconds to the calendar year" {
    try std.testing.expectEqual(@as(u16, 2026), currentYear(0)); // fallback
    try std.testing.expectEqual(@as(u16, 2024), currentYear(1_704_067_200)); // 2024-01-01Z
    try std.testing.expectEqual(@as(u16, 2026), currentYear(1_767_225_600)); // 2026-01-01Z
}

test "utf8CellLen consumes whole sequences and rejects bad bytes" {
    // ASCII: one byte.
    try std.testing.expectEqual(@as(?usize, 1), utf8CellLen("a", 0));
    // 2-byte (é = C3 A9), 3-byte (em-dash — = E2 80 94), 4-byte (😀 = F0 9F 98 80).
    try std.testing.expectEqual(@as(?usize, 2), utf8CellLen("é", 0));
    try std.testing.expectEqual(@as(?usize, 3), utf8CellLen("—", 0));
    try std.testing.expectEqual(@as(?usize, 4), utf8CellLen("😀", 0));
    // The em-dash must be read as one unit, not three '?'s.
    try std.testing.expectEqual(@as(?usize, 3), utf8CellLen("a—b", 1));

    // A lone continuation byte and a truncated sequence are rejected (the caller
    // emits one '?' and advances a byte).
    try std.testing.expectEqual(@as(?usize, null), utf8CellLen(&.{0x94}, 0)); // stray continuation
    try std.testing.expectEqual(@as(?usize, null), utf8CellLen(&.{ 0xE2, 0x80 }, 0)); // truncated
}

test "helpKeyEnd isolates the key column of a command line" {
    const keyOf = struct {
        fn f(line: []const u8) ?[]const u8 {
            const end = helpKeyEnd(line) orelse return null;
            return line[2..end];
        }
    }.f;

    // Single keys, synonyms, and chords.
    try std.testing.expectEqualStrings("q, ctrl+c", keyOf("  q, ctrl+c      quit").?);
    try std.testing.expectEqualStrings("ctrl+l", keyOf("  ctrl+l         commit graph viewer").?);
    try std.testing.expectEqualStrings("\\", keyOf("  \\              toggle split view").?);
    try std.testing.expectEqualStrings("space, enter", keyOf("  space, enter   switch into the worktree").?);

    // Headers, continuation lines, and prose notes have no key column.
    try std.testing.expect(keyOf("Global") == null); // header (col 0)
    try std.testing.expect(keyOf("                 continued description here") == null); // deep indent
    try std.testing.expect(keyOf("  a note with only single spaces between words") == null);

    // Every real command line in the table yields a key; every non-empty,
    // non-header line either yields a key or is an indented continuation.
    for (help_lines) |line| {
        if (line.len == 0) continue;
        if (line[0] != ' ') continue; // header
        if (std.mem.startsWith(u8, line, "  ")) {
            // A "  <key>" command line must expose a non-empty key.
            if (helpKeyEnd(line)) |end| try std.testing.expect(end > 2);
        }
    }
}
