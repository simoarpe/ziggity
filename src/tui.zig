const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const git_mod = @import("git.zig");
const model = @import("model.zig");

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
};

/// A network op run off the UI loop. Allocations use the page allocator (which
/// is thread-safe and independent of the main gpa), so there is no cross-thread
/// allocator race with the rest of the app.
const async_allocator = std.heap.page_allocator;

const AsyncJob = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    root: []const u8,
    op: app_mod.AsyncOp,
    result: ?git_mod.ExecResult = null,
};

fn asyncWorker(job: *AsyncJob) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(async_allocator);
    argv.append(async_allocator, "git") catch return postDone(job);
    argv.appendSlice(async_allocator, job.op.argv()) catch return postDone(job);

    const result = std.process.run(async_allocator, job.io, .{
        .argv = argv.items,
        .cwd = .{ .path = job.root },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch return postDone(job);

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
    generation: u64,
    result: ?app_mod.WorktreeSnapshot = null,
};

fn worktreeWorker(wr: *WorktreeRun) void {
    wr.result = app_mod.WorktreeSnapshot.load(async_allocator, wr.io, wr.environ, wr.root) catch null;
    _ = wr.loop.tryPostEvent(.worktree_done) catch false;
}

const refresh_interval = std.Io.Duration.fromMilliseconds(1500);
const focus_events_set = "\x1b[?1004h";
const focus_events_reset = "\x1b[?1004l";

const RefreshTicker = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    stop: std.atomic.Value(bool) = .init(false),
};

pub fn run(init: std.process.Init, app: *app_mod.App) !void {
    const io = init.io;
    const allocator = init.gpa;
    ui_theme = app.config.theme;

    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    var refresh_ticker: RefreshTicker = .{ .io = io, .loop = &loop };
    var refresh_future = try io.concurrent(refreshTickerRun, .{&refresh_ticker});
    defer {
        refresh_ticker.stop.store(true, .release);
        _ = loop.tryPostEvent(.refresh_tick) catch false;
        refresh_future.await(io);
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
    defer if (preview_future) |*f| {
        f.await(io);
        if (preview_run.result) |r| async_allocator.free(r);
        preview_run.job.deinit(async_allocator);
    };

    var worktree_run: WorktreeRun = undefined;
    var worktree_future: ?std.Io.Future(void) = null;
    defer if (worktree_future) |*f| {
        f.await(io);
        if (worktree_run.result) |*r| r.deinit(async_allocator);
    };

    var render_ctx = RenderCtx{ .vx = &vx, .writer = writer, .app = app };
    app.render_hook = .{ .ctx = &render_ctx, .func = renderHook };
    defer app.render_hook = null;

    try renderAndFlush(&vx, writer, app);
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
        }

        // Push any queued text to the system clipboard (OSC 52).
        if (app.clipboard_request) |text| {
            vx.copyToSystemClipboard(writer, text, allocator) catch {};
            allocator.free(text);
            app.clipboard_request = null;
        }

        // Start a queued network op once nothing else is in flight.
        if (async_future == null) {
            if (app.async_requested) |op| {
                app.async_requested = null;
                app.async_active = true;
                async_job = .{ .io = io, .loop = &loop, .root = app.git.root, .op = op };
                async_future = io.concurrent(asyncWorker, .{&async_job}) catch blk: {
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
                    .generation = generation,
                    .result = null,
                };
                worktree_future = io.concurrent(worktreeWorker, .{&worktree_run}) catch blk: {
                    app.applyWorktreeSnapshot(null, generation, async_allocator) catch {};
                    break :blk null;
                };
            }
        }

        if (render_needed) try renderAndFlush(&vx, writer, app);
    }
}

fn refreshTickerRun(state: *RefreshTicker) void {
    while (!state.stop.load(.acquire)) {
        std.Io.sleep(state.io, refresh_interval, .awake) catch return;
        if (state.stop.load(.acquire)) return;
        _ = state.loop.tryPostEvent(.refresh_tick) catch false;
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
    var side_w: u16 = @intCast((@as(u32, root.width) * app.config.side_panel_width_percent) / 100);
    side_w = @max(@as(u16, 24), @min(side_w, @min(@as(u16, 60), root.width - 20)));
    const main_w = root.width - side_w;

    var y: u16 = 0;
    const status_h: u16 = 6;
    const remaining = body_h - status_h;
    const base = remaining / 4;
    const extra = remaining % 4;
    const files_h = base + if (extra > 0) @as(u16, 1) else 0;
    const branches_h = base + if (extra > 1) @as(u16, 1) else 0;
    const commits_h = base + if (extra > 2) @as(u16, 1) else 0;
    const stash_h = body_h - status_h - files_h - branches_h - commits_h;

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

    drawStatus(panel(root, 0, y, side_w, status_h, "Status [1]", app.focus == .status), app);
    y += status_h;
    drawFiles(panel(root, 0, y, side_w, files_h, "Files [2]", app.focus == .files), app);
    y += files_h;
    const branches_title = switch (app.branches_tab) {
        .local => "Branches [3]",
        .remotes => "Remotes [3]",
        .tags => "Tags [3]",
        .worktrees => "Worktrees [3]",
        .submodules => "Submodules [3]",
    };
    drawBranches(panel(root, 0, y, side_w, branches_h, branches_title, app.focus == .branches), app);
    y += branches_h;
    var commits_title_buf: [80]u8 = undefined;
    var filter_label_buf: [64]u8 = undefined;
    const commits_title = if (app.commit_files_active)
        (if (app.patchFileCount() > 0)
            (std.fmt.bufPrint(&commits_title_buf, "Commit files [4] (patch: {d})", .{app.patchFileCount()}) catch "Commit files [4]")
        else
            "Commit files [4]  (space: add to patch)")
    else if (app.commits_tab == .reflog)
        "Reflog [4]"
    else if (app.commitFilterLabel(&filter_label_buf)) |label|
        (std.fmt.bufPrint(&commits_title_buf, "Commits [4] ({s})", .{label}) catch "Commits [4] (filtered)")
    else
        "Commits [4]";
    drawCommits(panel(root, 0, y, side_w, commits_h, commits_title, app.focus == .commits), app);
    y += commits_h;
    drawStash(panel(root, 0, y, side_w, stash_h, "Stash [5]", app.focus == .stash), app);

    var title_buf: [64]u8 = undefined;
    const main_title = if (app.staging_active)
        (if (app.staging_staged_view) "Staging - staged" else "Staging - unstaged")
    else if (app.diff_base) |diff_ref|
        (std.fmt.bufPrint(&title_buf, "Diff [base {s}]", .{diff_ref[0..@min(diff_ref.len, 16)]}) catch "Diff [diffing]")
    else
        "Diff";
    const main = panel(root, side_w, 0, main_w, body_h, main_title, app.focus == .main);
    app.main_view_height = main.height;
    drawDiff(main, app);
    drawBottom(root.child(.{ .x_off = 0, .y_off = @intCast(body_h), .width = root.width, .height = bottom_h }), app);

    // Centered popups render on top of everything else.
    switch (app.mode) {
        .status_filter_menu => drawStatusFilterPopup(root, app),
        .menu => drawMenuPopup(root, app),
        .confirmation => drawConfirmPopup(root, app),
        .commit_prompt => drawCommitPopup(root, app),
        .text_prompt => drawTextPromptPopup(root, app),
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
    "  h/l, tab       move between side panels",
    "  j/k, arrows    move selection",
    "  [ / ]          switch panel tabs",
    "  enter / esc    inspect in main panel / go back",
    "  @ / ?          command log / this help",
    "  z              undo the last operation (reflog reset)",
    "  ctrl+o         copy selected hash / branch / tag to the clipboard",
    "  o              open the selected commit / branch on its remote host",
    "  W              diff mode: mark a ref, then select another to compare",
    "  f / p / P      fetch / pull / push (async)",
    "",
    "Files",
    "  space          stage/unstage (whole dir in tree view)",
    "  a              stage/unstage all",
    "  c / A          commit (popup) / amend last commit",
    "  d / D          discard menu / discard all",
    "  s              stash menu (all / +untracked / staged / file)",
    "  / / ctrl+b     filter by path / status filter",
    "  `              toggle directory tree",
    "  enter          open the hunk/line staging view",
    "  m              merge/rebase actions: continue, amend+continue, abort",
    "",
    "Staging view",
    "  j/k            move by line",
    "  v              toggle range selection",
    "  space          stage/unstage line(s); on @@ the whole hunk",
    "  tab            switch unstaged / staged side",
    "",
    "Branches  (tabs: Local / Remotes / Tags / Worktrees / Submodules)",
    "  space          checkout / apply / init-update",
    "  n              new branch (new tag / add remote by tab)",
    "  R              rename branch",
    "  d              delete branch / tag / remote branch / worktree",
    "  M / r / f      merge / rebase / fast-forward",
    "  Remotes tab    e edit URL   x remove remote   u set upstream",
    "",
    "Commits  (tabs: Commits / Reflog)",
    "  enter          view the commit's changed files",
    "  g / t          reset menu / revert",
    "  c / v          copy commit to clipboard / paste (cherry-pick) onto HEAD",
    "  d / s / f      drop / squash-down / fixup-down (interactive rebase)",
    "  e / r          edit (stop here) / reword",
    "  F / S          create fixup! commit / autosquash fixups above",
    "  B              mark base, then rebase a branch to move commits onto it",
    "  W              diff mode: compare against another ref",
    "  /              filter the log by message / author / path (esc clears)",
    "  b              bisect menu (start, then mark good/bad/skip/reset)",
    "  enter, space   open a commit's files; space adds a file to the patch",
    "  ctrl+p         custom patch menu (apply / remove from commit / reset)",
    "  ctrl+j/ctrl+k  move commit down / up",
    "",
    "Stash",
    "  space / g / d  apply / pop / drop",
    "",
    "Operations",
    "  git actions    run synchronously in a dialog showing the command,",
    "                 its output and result; enter dismisses, up/down scroll",
    "  fetch/pull/push run in the background (status in the bottom bar)",
};

fn drawHelpPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const w: u16 = @min(@as(u16, 70), root.width -| 2);
    const h: u16 = @min(@as(u16, help_lines.len + 2), root.height -| 1);
    const win = popup(root, w, h, "Keybindings");

    const max_scroll = if (help_lines.len > win.height) help_lines.len - win.height else 0;
    const start = @min(app.help_scroll, max_scroll);
    var row: u16 = 0;
    for (help_lines[start..]) |line| {
        if (row >= win.height) break;
        // Section headers (no leading indent) are accented.
        const style = if (line.len > 0 and line[0] != ' ') st.bottom_accent else st.normal;
        print(win, row, 0, line, style);
        row += 1;
    }
}

fn drawCommandLogPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const log = app.git.command_log.items;
    const w: u16 = @min(@as(u16, 90), root.width -| 4);
    const h: u16 = @min(@as(u16, 20), root.height -| 2);
    const win = popup(root, w, h, "Command log");
    if (log.len == 0) {
        print(win, 0, 0, "No commands run yet.", st.muted);
        return;
    }
    // Show the most recent commands that fit, oldest at the top.
    const capacity: usize = win.height;
    const start = if (log.len > capacity) log.len - capacity else 0;
    var row: u16 = 0;
    for (log[start..]) |entry| {
        if (row >= win.height) break;
        print(win, row, 0, entry, st.normal);
        row += 1;
    }
}

fn drawOperationPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const w: u16 = @min(@as(u16, 86), root.width -| 4);
    const h: u16 = @min(@as(u16, 20), root.height -| 2);
    const title = if (app.op_running) "Running" else if (app.op_ok) "Done" else "Failed";
    const win = popup(root, w, h, title);

    // The command that is running / ran.
    print(win, 0, 0, app.op_command, st.title);

    if (app.op_running) {
        print(win, 2, 0, "Running...", st.muted);
        return;
    }

    // Outcome summary, colored by success.
    print(win, 2, 0, app.op_summary, if (app.op_ok) st.normal else st.warning);

    // Raw stdout/stderr below the summary, scrollable; last row is the footer.
    const out_top: u16 = 4;
    const footer_row: u16 = win.height -| 1;
    if (app.op_output.len > 0 and out_top < footer_row) {
        var lines = std.mem.splitScalar(u8, app.op_output, '\n');
        var skipped: usize = 0;
        while (skipped < app.op_scroll) : (skipped += 1) {
            if (lines.next() == null) break;
        }
        var row: u16 = out_top;
        while (lines.next()) |line| {
            if (row >= footer_row) break;
            print(win, row, 0, line, st.muted);
            row += 1;
        }
    }

    print(win, footer_row, 0, "enter dismiss   up/down scroll", st.bottom_accent);
}

fn drawTextPromptPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const kind = app.text_prompt_kind orelse return;
    const w: u16 = @min(@as(u16, 64), root.width -| 4);
    const win = popup(root, w, 5, kind.title());
    print(win, 0, 0, app.input_buffer.items, st.normal);
    print(win, 2, 0, "enter confirm   esc cancel", st.bottom_accent);
    const cursor_col: u16 = @min(win.width -| 1, @as(u16, @intCast(app.input_buffer.items.len)));
    win.showCursor(cursor_col, 0);
}

fn drawCommitPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const subject_focused = app.commit_field == .subject;
    const w: u16 = @min(@as(u16, 72), root.width -| 4);
    const title = if (app.commit_action == .reword) "Reword commit" else "Commit message";
    const win = popup(root, w, 12, title);

    // Field labels indicate which has focus.
    print(win, 0, 0, "Summary", if (subject_focused) st.active_title else st.muted);
    print(win, 1, 0, app.commit_buffer.items, st.normal);
    print(win, 3, 0, "Description (optional)", if (subject_focused) st.muted else st.active_title);

    // Body lines start at row 4.
    const body_top: u16 = 4;
    var lines = std.mem.splitScalar(u8, app.commit_body_buffer.items, '\n');
    var row: u16 = body_top;
    var body_rows: u16 = 0;
    var last_line_len: usize = 0;
    while (lines.next()) |line| {
        if (row < win.height -| 1) print(win, row, 0, line, st.normal);
        last_line_len = line.len;
        row += 1;
        body_rows += 1;
    }

    print(win, win.height -| 1, 0, "tab: switch field   enter: commit / newline   esc: cancel", st.bottom_accent);

    if (subject_focused) {
        const col: u16 = @min(win.width -| 1, @as(u16, @intCast(app.commit_buffer.items.len)));
        win.showCursor(col, 1);
    } else {
        const cursor_row: u16 = @min(win.height -| 1, body_top + (body_rows -| 1));
        const col: u16 = @min(win.width -| 1, @as(u16, @intCast(last_line_len)));
        win.showCursor(col, cursor_row);
    }
}

/// Centered, bordered, opaque popup window. Fills its region first so the
/// panels underneath do not bleed through, draws a rounded border and a title,
/// and returns the inner content window.
fn popup(root: vaxis.Window, width: u16, height: u16, title: []const u8) vaxis.Window {
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
    _ = raw.printSegment(.{ .text = title, .style = styles().active_title }, .{
        .row_offset = 0,
        .col_offset = 2,
        .wrap = .none,
    });
    return inner;
}

fn drawStatusFilterPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const options = app_mod.status_filter_options;
    const w: u16 = 38;
    const h: u16 = @intCast(options.len + 2);
    const win = popup(root, w, h, "Status filter");
    for (options, 0..) |option, idx| {
        var buf: [64]u8 = undefined;
        const marker: u8 = if (option == app.file_display_filter) '*' else ' ';
        const line = std.fmt.bufPrint(&buf, "{c} {s}", .{ marker, option.label() }) catch option.label();
        drawSelectable(win, @intCast(idx), line, st.normal, idx == app.status_filter_index);
    }
}

fn drawMenuPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    const menu = app.active_menu orelse return;
    var max_label: usize = menu.title.len;
    for (menu.items) |item| max_label = @max(max_label, item.label.len);
    const w: u16 = @intCast(@min(@as(usize, 72), max_label + 6));
    const h: u16 = @intCast(menu.items.len + 2);
    const win = popup(root, w, h, menu.title);
    for (menu.items, 0..) |item, idx| {
        drawSelectable(win, @intCast(idx), item.label, st.normal, idx == menu.index);
    }
}

fn drawConfirmPopup(root: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();
    var buf: [1024]u8 = undefined;
    const text = app.confirmationText(&buf);
    const title = switch (app.pending_confirmation orelse .discard_all) {
        .discard_all => "Discard all changes",
        .merge_branch => "Merge branch",
        .rebase_branch => "Rebase branch",
        .delete_tag => "Delete tag",
        .delete_remote_branch => "Delete remote branch",
        .remove_worktree => "Remove worktree",
        .remove_remote => "Remove remote",
        .undo => "Undo",
    };
    const w: u16 = @intCast(@min(@as(usize, 72), @max(text.len, 34) + 4));
    const win = popup(root, w, 5, title);
    print(win, 0, 0, text, st.normal);
    print(win, 2, 0, "(y/enter) confirm   (n/esc) cancel", st.bottom_accent);
}

fn panel(root: vaxis.Window, x: u16, y: u16, w: u16, h: u16, title: []const u8, focused: bool) vaxis.Window {
    const raw = root.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w, .height = h });
    if (w < 4 or h < 3) return raw;
    const st = styles();
    const border_style = if (focused) st.active_border else st.inactive_border;
    const inner = raw.child(.{
        .border = .{
            .where = .all,
            .style = border_style,
            .glyphs = .single_rounded,
        },
    });
    _ = raw.printSegment(.{ .text = title, .style = if (focused) st.active_title else st.title }, .{
        .row_offset = 0,
        .col_offset = 2,
        .wrap = .none,
    });
    return inner;
}

fn drawStatus(win: vaxis.Window, app: *const app_mod.App) void {
    const st = styles();

    // Line 0: <repo> → <branch>  <ahead/behind status>   (lazygit-style)
    const repo = std.fs.path.basename(app.git.root);
    var col: u16 = 0;
    col = printSpan(win, 0, col, repo, st.normal);
    col = printSpan(win, 0, col, " ", st.muted);
    col = printGlyph(win, 0, col, glyph_to_branch, st.muted);
    col = printSpan(win, 0, col, " ", st.muted);
    col = printSpan(win, 0, col, app.data.current_branch, st.active_title);
    col = printSpan(win, 0, col, " ", st.muted);
    _ = drawBranchStatus(win, 0, col, st.muted, app.data.upstream != null, app.data.ahead orelse 0, app.data.behind orelse 0);

    // Line 1: a running network op takes priority, then merge/rebase state,
    // then a worktree summary.
    if (app.async_active) {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}...", .{app.async_op.gerund()}) catch "working...";
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
        print(win, 0, 0, "Working tree clean", styles().muted);
        return;
    }
    if (app.tree_view) return drawFileTree(win, app);
    const visible_count = app.visibleFileCount();
    if (visible_count == 0) {
        print(win, 0, 0, "No files match filter", styles().muted);
        return;
    }
    const start = scrollStart(app.selectedFileVisibleOrdinal(), visible_count, win.height);
    var row: u16 = 0;
    var ordinal: usize = 0;
    for (app.data.files, 0..) |file, idx| {
        if (!app.fileMatchesFilter(file)) continue;
        if (ordinal < start) {
            ordinal += 1;
            continue;
        }
        if (row >= win.height) break;
        var buf: [512]u8 = undefined;
        const line = if (file.previous_path) |previous|
            std.fmt.bufPrint(&buf, "{c}{c} {s} -> {s}", .{ file.short_status[0], file.short_status[1], previous, file.path }) catch file.path
        else
            std.fmt.bufPrint(&buf, "{c}{c} {s}", .{ file.short_status[0], file.short_status[1], file.path }) catch file.path;
        const style = if (file.conflict) styles().warning else if (file.has_unstaged) styles().unstaged else if (file.has_staged) styles().staged else styles().normal;
        drawSelectable(win, row, line, style, idx == app.file_index and app.focus == .files);
        ordinal += 1;
        row += 1;
    }
}

fn drawFileTree(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.tree_rows.len == 0) {
        print(win, 0, 0, "No files match filter", styles().muted);
        return;
    }
    const start = scrollStart(app.tree_cursor, app.tree_rows.len, win.height);
    var row: u16 = 0;
    var i = start;
    while (i < app.tree_rows.len and row < win.height) : ({
        i += 1;
        row += 1;
    }) {
        const tr = app.tree_rows[i];
        const selected = i == app.tree_cursor and app.focus == .files;
        var base = styles().normal;
        if (selected) {
            base.bg = selectedBg();
            base.bold = true;
            fillRow(win, row, base);
        }

        const indent: usize = @min(@as(usize, tr.depth) * 2, indent_spaces.len);
        var col = printSpan(win, row, 0, indent_spaces[0..indent], base);
        const name = std.fs.path.basename(tr.path);
        if (tr.is_dir) {
            col = printGlyph(win, row, col, if (tr.collapsed) glyph_collapsed else glyph_expanded, withFg(base, 12));
            col = printSpan(win, row, col, " ", base);
            col = printSpan(win, row, col, name, withFg(base, 12));
            _ = printSpan(win, row, col, "/", withFg(base, 12));
        } else {
            const file = app.data.files[tr.file_index];
            const fg: u8 = if (file.conflict) 11 else if (file.has_unstaged) 9 else 10;
            var prefix: [3]u8 = .{ file.short_status[0], file.short_status[1], ' ' };
            col = printSpan(win, row, col, &prefix, withFg(base, fg));
            _ = printSpan(win, row, col, name, withFg(base, fg));
        }
    }
}

fn drawBranches(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.branches_tab == .tags) return drawTags(win, app);
    if (app.branches_tab == .worktrees) return drawWorktrees(win, app);
    if (app.branches_tab == .submodules) return drawSubmodules(win, app);

    const branches = switch (app.branches_tab) {
        .remotes => app.data.remote_branches,
        else => app.data.branches,
    };
    const selected = switch (app.branches_tab) {
        .remotes => app.remote_index,
        else => app.branch_index,
    };
    if (branches.len == 0) {
        const empty_label = if (app.branches_tab == .remotes) "No remote branches" else "No branches";
        print(win, 0, 0, empty_label, styles().muted);
        return;
    }
    const start = scrollStart(selected, branches.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < branches.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const branch = branches[idx];
        var buf: [512]u8 = undefined;
        const marker: u8 = if (branch.current) '*' else ' ';
        const line = if (branch.upstream) |upstream|
            std.fmt.bufPrint(&buf, "{c} {s} -> {s} ", .{ marker, branch.name, upstream }) catch branch.name
        else
            std.fmt.bufPrint(&buf, "{c} {s} ", .{ marker, branch.name }) catch branch.name;

        const base = blk: {
            var s = if (branch.current) styles().staged else styles().normal;
            if (idx == selected and app.focus == .branches) {
                s.bg = selectedBg();
                s.bold = true;
                fillRow(win, row, s);
            }
            break :blk s;
        };
        const end = printSpan(win, row, 0, line, base);

        // The current branch shows its push/pull status (others lack the data).
        if (branch.current and app.branches_tab == .local) {
            _ = drawBranchStatus(win, row, end, base, app.data.upstream != null, app.data.ahead orelse 0, app.data.behind orelse 0);
        }
    }
}

fn drawTags(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.tags.len == 0) {
        print(win, 0, 0, "No tags", styles().muted);
        return;
    }
    const start = scrollStart(app.tag_index, app.data.tags.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.tags.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const tag = app.data.tags[idx];
        var buf: [512]u8 = undefined;
        const line = if (tag.subject.len > 0)
            std.fmt.bufPrint(&buf, "{s}  {s}", .{ tag.name, tag.subject }) catch tag.name
        else
            tag.name;
        drawSelectable(win, row, line, styles().normal, idx == app.tag_index and app.focus == .branches);
    }
}

fn drawWorktrees(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.worktrees.len == 0) {
        print(win, 0, 0, "No worktrees", styles().muted);
        return;
    }
    const start = scrollStart(app.worktree_index, app.data.worktrees.len, win.height);
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
        drawSelectable(win, row, line, if (wt.is_current) styles().staged else styles().normal, idx == app.worktree_index and app.focus == .branches);
    }
}

fn drawSubmodules(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.submodules.len == 0) {
        print(win, 0, 0, "No submodules", styles().muted);
        return;
    }
    const start = scrollStart(app.submodule_index, app.data.submodules.len, win.height);
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
        drawSelectable(win, row, line, style, idx == app.submodule_index and app.focus == .branches);
    }
}

fn drawCommitFiles(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.commit_files.len == 0) {
        print(win, 0, 0, "No files in this commit", styles().muted);
        return;
    }
    const start = scrollStart(app.commit_file_index, app.commit_files.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.commit_files.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const file = app.commit_files[idx];
        var buf: [512]u8 = undefined;
        // A leading '+' marks files added to the custom patch.
        const in_patch = app.patchHasFile(file.path);
        const marker: u8 = if (in_patch) '+' else ' ';
        const line = std.fmt.bufPrint(&buf, "{c}{c} {s}", .{ marker, file.status, file.path }) catch file.path;
        const style = if (in_patch) styles().staged else switch (file.status) {
            'A' => styles().added,
            'D' => styles().removed,
            else => styles().normal,
        };
        drawSelectable(win, row, line, style, idx == app.commit_file_index and app.focus == .commits);
    }
}

fn drawCommits(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.commit_files_active) return drawCommitFiles(win, app);
    const commits = app.activeCommits();
    if (commits.len == 0) {
        const empty_label = if (app.commits_tab == .reflog) "No reflog entries" else "No commits";
        print(win, 0, 0, empty_label, styles().muted);
        return;
    }
    const selected = app.activeCommitIndex();
    const start = scrollStart(selected, commits.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < commits.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const commit = commits[idx];
        var buf: [512]u8 = undefined;
        // A leading marker flags commits copied to the cherry-pick clipboard;
        // a 'B' flags the commit marked as the base for a rebase --onto.
        const copied = app.isCommitCopied(commit.hash);
        const marked = app.isMarkedBase(commit.hash);
        const marker: u8 = if (marked) 'B' else if (copied) '*' else ' ';
        const line = std.fmt.bufPrint(&buf, "{c}{s} {s}", .{ marker, commit.short_hash, commit.subject }) catch commit.subject;
        const style = if (marked) styles().warning else if (copied) styles().staged else styles().normal;
        drawSelectable(win, row, line, style, idx == selected and app.focus == .commits);
    }
}

fn drawStash(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.stash.len == 0) {
        print(win, 0, 0, "No stash entries", styles().muted);
        return;
    }
    const start = scrollStart(app.stash_index, app.data.stash.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.stash.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const entry = app.data.stash[idx];
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ entry.selector, entry.message }) catch entry.message;
        drawSelectable(win, row, line, styles().normal, idx == app.stash_index and app.focus == .stash);
    }
}

fn drawDiff(win: vaxis.Window, app: *const app_mod.App) void {
    const text = if (app.staging_active) app.staging_diff else app.diff;
    if (app.staging_active and text.len == 0) {
        print(win, 0, 0, "No changes on this side - press tab to switch", styles().muted);
        return;
    }

    // The selected line (or v-range) is highlighted while staging.
    var hl_start: usize = 0;
    var hl_end: usize = 0;
    if (app.staging_active) {
        const anchor = app.staging_anchor orelse app.staging_cursor;
        hl_start = @min(anchor, app.staging_cursor);
        hl_end = @max(anchor, app.staging_cursor) + 1;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var skipped: usize = 0;
    while (skipped < app.main_scroll) : (skipped += 1) {
        if (lines.next() == null) return;
    }

    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        const line = lines.next() orelse break;
        const abs_line = app.main_scroll + row;
        var style = diffStyle(line);
        if (app.staging_active and abs_line >= hl_start and abs_line < hl_end) {
            style.bg = .{ .index = 8 };
            fillRow(win, row, style);
        }
        print(win, row, 0, line, style);
    }
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
        print(win, 0, 8, app.file_filter_buffer.items, st.bottom);
        const cursor_col: u16 = @min(win.width -| 1, @as(u16, @intCast(8 + app.file_filter_buffer.items.len)));
        win.showCursor(cursor_col, 0);
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

    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}  |  {s}", .{ app.message, contextHints(app) }) catch app.message;
    print(win, 0, 0, line, st.bottom);
}

/// Keybinding hints for the focused panel only, lazygit-style. A short global
/// suffix (refresh/quit) is appended since those apply everywhere.
fn contextHints(app: *const app_mod.App) []const u8 {
    const global = "  -  ? help  z undo  R refresh  q quit";
    if (app.staging_active) {
        return "j/k line  v range  space stage/unstage (@@=hunk)  tab side  esc back" ++ global;
    }
    if (app.commit_files_active and app.focus == .commits) {
        return "j/k file  enter diff  esc back" ++ global;
    }
    if (app.data.state != .clean and app.focus == .files) {
        return "space resolve (ours/theirs)  m continue/abort  d discard  esc back" ++ global;
    }
    if (app.focus == .branches) {
        return switch (app.branches_tab) {
            .local => "space checkout  n new  R rename  d delete  M merge  r rebase  f ff  [ ]" ++ global,
            .remotes => "space checkout  n add  e edit  x remove  u upstream  d del-branch  [ ]" ++ global,
            .tags => "space checkout  n new-tag  d delete-tag  [ ] tabs" ++ global,
            .worktrees => "d remove  [ ] tabs" ++ global,
            .submodules => "space init/update  [ ] tabs" ++ global,
        };
    }
    return switch (app.focus) {
        .status => "1-5 panels  enter inspect  f fetch  p pull  P push  @ log" ++ global,
        .files => "space stage  a all  c commit  A amend  d discard  s stash  / filter  ` tree  enter hunks" ++ global,
        .branches => unreachable,
        .commits => "g reset  t revert  c/v copy/paste  d/s/f/e/r rebase  F fixup  S autosquash  B mark-base  W diff  / filter  b bisect  ^j/^k move" ++ global,
        .stash => "space apply  g pop  d drop  enter view" ++ global,
        .main => "j/k scroll  PgUp/PgDn page  esc back" ++ global,
    };
}

fn drawSelectable(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style, selected: bool) void {
    var draw_style = style;
    if (selected) {
        draw_style.bg = selectedBg();
        draw_style.bold = true;
        fillRow(win, row, draw_style);
    }
    print(win, row, 0, text, draw_style);
}

fn print(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    _ = printSpan(win, row, col, text, style);
}

/// Like `print`, but returns the column after the last cell written so spans
/// (including static UTF-8 glyphs via `printGlyph`) can be composed on a row.
fn printSpan(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) u16 {
    if (row >= win.height) return col;
    var out_col = col;
    for (text) |byte| {
        if (out_col >= win.width or byte == '\n' or byte == '\r') break;
        if (byte == '\t') {
            var spaces: u8 = 0;
            while (spaces < 4 and out_col < win.width) : (spaces += 1) {
                win.writeCell(out_col, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = style,
                });
                out_col += 1;
            }
            continue;
        }
        win.writeCell(out_col, row, .{
            .char = .{ .grapheme = glyph(byte), .width = 1 },
            .style = style,
        });
        out_col += 1;
    }
    return out_col;
}

/// Write a single static UTF-8 glyph (e.g. an arrow) as one cell. The grapheme
/// must be a stable slice — vaxis stores it by reference until render.
fn printGlyph(win: vaxis.Window, row: u16, col: u16, grapheme: []const u8, style: vaxis.Style) u16 {
    if (row < win.height and col < win.width) {
        win.writeCell(col, row, .{ .char = .{ .grapheme = grapheme, .width = 1 }, .style = style });
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

fn scrollStart(selected: usize, len: usize, visible: u16) usize {
    if (len == 0 or visible == 0) return 0;
    const vis: usize = visible;
    if (selected < vis) return 0;
    return selected - vis + 1;
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
    bottom: vaxis.Style,
    bottom_accent: vaxis.Style,
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
        .bottom = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
        .bottom_accent = .{ .fg = .{ .index = t.accent }, .bg = .{ .index = 0 }, .bold = true },
    };
}

fn selectedBg() vaxis.Color {
    return .{ .index = ui_theme.selected_bg };
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
const glyph_expanded = "▾"; // U+25BE
const indent_spaces = " " ** 32;

/// Render lazygit-style ahead/behind status: `↓2↑3`, `✓` when in sync, or a
/// note when there is no upstream. Returns the next column.
fn drawBranchStatus(win: vaxis.Window, row: u16, col: u16, base: vaxis.Style, has_upstream: bool, ahead: usize, behind: usize) u16 {
    if (!has_upstream) return printSpan(win, row, col, "?", withFg(base, 8));
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
