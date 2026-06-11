const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const model = @import("model.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    refresh_tick,
};

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
    try writer.writeAll(focus_events_set);
    try writer.flush();
    defer {
        writer.writeAll(focus_events_reset) catch {};
        writer.flush() catch {};
    }
    try vx.queryTerminal(writer, .fromSeconds(1));

    try renderAndFlush(&vx, writer, app);
    while (app.running) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try app.handleKey(key),
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            .refresh_tick => try app.handleRefreshTick(),
            .focus_in => try app.handleFocusIn(),
            .focus_out => app.handleFocusOut(),
        }
        try renderAndFlush(&vx, writer, app);
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

    drawStatus(panel(root, 0, y, side_w, status_h, "Status [1]", app.focus == .status), app);
    y += status_h;
    drawFiles(panel(root, 0, y, side_w, files_h, "Files [2]", app.focus == .files), app);
    y += files_h;
    drawBranches(panel(root, 0, y, side_w, branches_h, "Branches [3]", app.focus == .branches), app);
    y += branches_h;
    drawCommits(panel(root, 0, y, side_w, commits_h, "Commits [4]", app.focus == .commits), app);
    y += commits_h;
    drawStash(panel(root, 0, y, side_w, stash_h, "Stash [5]", app.focus == .stash), app);

    const main = panel(root, side_w, 0, main_w, body_h, "Diff", app.focus == .main);
    drawDiff(main, app);
    drawBottom(root.child(.{ .x_off = 0, .y_off = @intCast(body_h), .width = root.width, .height = bottom_h }), app);
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
    var row: u16 = 0;
    var buf: [256]u8 = undefined;
    const branch = std.fmt.bufPrint(&buf, "branch {s}", .{app.data.current_branch}) catch return;
    print(win, row, 0, branch, st.normal);
    row += 1;

    var counts_buf: [256]u8 = undefined;
    const counts = std.fmt.bufPrint(&counts_buf, "files {d} staged {d} unstaged {d}", .{
        app.data.files.len,
        app.data.stagedCount(),
        app.data.unstagedCount(),
    }) catch return;
    print(win, row, 0, counts, st.muted);
    row += 1;

    if (app.data.upstream) |upstream| {
        var upstream_buf: [256]u8 = undefined;
        const ahead = app.data.ahead orelse 0;
        const behind = app.data.behind orelse 0;
        const line = std.fmt.bufPrint(&upstream_buf, "{s} +{d} -{d}", .{ upstream, ahead, behind }) catch return;
        print(win, row, 0, line, st.muted);
        row += 1;
    }

    if (app.anyFileFilterActive()) {
        var filter_buf: [256]u8 = undefined;
        const line = if (app.fileDisplayFilterActive() and app.fileFilterActive())
            std.fmt.bufPrint(&filter_buf, "filter {s} {d}/{d} {s}", .{ app.file_display_filter.label(), app.visibleFileCount(), app.data.files.len, app.file_filter }) catch return
        else if (app.fileDisplayFilterActive())
            std.fmt.bufPrint(&filter_buf, "filter {s} {d}/{d}", .{ app.file_display_filter.label(), app.visibleFileCount(), app.data.files.len }) catch return
        else
            std.fmt.bufPrint(&filter_buf, "filter {d}/{d} {s}", .{ app.visibleFileCount(), app.data.files.len, app.file_filter }) catch return;
        print(win, row, 0, line, st.muted);
    }
}

fn drawFiles(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.files.len == 0) {
        print(win, 0, 0, "Working tree clean", styles().muted);
        return;
    }
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

fn drawBranches(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.branches.len == 0) {
        print(win, 0, 0, "No branches", styles().muted);
        return;
    }
    const start = scrollStart(app.branch_index, app.data.branches.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.branches.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const branch = app.data.branches[idx];
        var buf: [512]u8 = undefined;
        const marker: u8 = if (branch.current) '*' else ' ';
        const line = if (branch.upstream) |upstream|
            std.fmt.bufPrint(&buf, "{c} {s} -> {s}", .{ marker, branch.name, upstream }) catch branch.name
        else
            std.fmt.bufPrint(&buf, "{c} {s}", .{ marker, branch.name }) catch branch.name;
        drawSelectable(win, row, line, if (branch.current) styles().staged else styles().normal, idx == app.branch_index and app.focus == .branches);
    }
}

fn drawCommits(win: vaxis.Window, app: *const app_mod.App) void {
    if (app.data.commits.len == 0) {
        print(win, 0, 0, "No commits", styles().muted);
        return;
    }
    const start = scrollStart(app.commit_index, app.data.commits.len, win.height);
    var row: u16 = 0;
    var idx = start;
    while (idx < app.data.commits.len and row < win.height) : ({
        idx += 1;
        row += 1;
    }) {
        const commit = app.data.commits[idx];
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ commit.short_hash, commit.subject }) catch commit.subject;
        drawSelectable(win, row, line, styles().normal, idx == app.commit_index and app.focus == .commits);
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
    var lines = std.mem.splitScalar(u8, app.diff, '\n');
    var skipped: usize = 0;
    while (skipped < app.main_scroll) : (skipped += 1) {
        if (lines.next() == null) return;
    }

    var row: u16 = 0;
    while (row < win.height) : (row += 1) {
        const line = lines.next() orelse break;
        const style = diffStyle(line);
        print(win, row, 0, line, style);
    }
}

fn drawBottom(win: vaxis.Window, app: *app_mod.App) void {
    const st = styles();
    fillRow(win, 0, st.bottom);
    if (app.mode == .commit_prompt) {
        print(win, 0, 0, "commit: ", st.bottom_accent);
        print(win, 0, 8, app.commit_buffer.items, st.bottom);
        const cursor_col: u16 = @min(win.width -| 1, @as(u16, @intCast(8 + app.commit_buffer.items.len)));
        win.showCursor(cursor_col, 0);
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
        var menu_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&menu_buf, "status filter ({s}): s staged u unstaged t tracked T untracked r all esc cancel", .{app.file_display_filter.label()}) catch "status filter";
        print(win, 0, 0, line, st.bottom_accent);
        return;
    }
    if (app.mode == .confirmation) {
        var confirm_buf: [1024]u8 = undefined;
        print(win, 0, 0, app.confirmationText(&confirm_buf), st.bottom_accent);
        return;
    }

    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} | q quit R refresh / filter ^b status h/l panels j/k move space action d discard D discard-all c commit f fetch p pull P push", .{app.message}) catch app.message;
    print(win, 0, 0, line, st.bottom);
}

fn drawSelectable(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style, selected: bool) void {
    var draw_style = style;
    if (selected) {
        draw_style.bg = .{ .index = 4 };
        draw_style.bold = true;
        fillRow(win, row, draw_style);
    }
    print(win, row, 0, text, draw_style);
}

fn print(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height or col >= win.width) return;
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
    return .{
        .normal = .{ .fg = .default },
        .muted = .{ .fg = .{ .index = 8 } },
        .title = .{ .fg = .{ .index = 7 } },
        .active_title = .{ .fg = .{ .index = 10 }, .bold = true },
        .active_border = .{ .fg = .{ .index = 10 }, .bold = true },
        .inactive_border = .{ .fg = .{ .index = 8 } },
        .staged = .{ .fg = .{ .index = 10 } },
        .unstaged = .{ .fg = .{ .index = 9 } },
        .warning = .{ .fg = .{ .index = 11 }, .bold = true },
        .added = .{ .fg = .{ .index = 10 } },
        .removed = .{ .fg = .{ .index = 9 } },
        .hunk = .{ .fg = .{ .index = 14 } },
        .header = .{ .fg = .{ .index = 13 }, .bold = true },
        .bottom = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
        .bottom_accent = .{ .fg = .{ .index = 14 }, .bg = .{ .index = 0 }, .bold = true },
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
