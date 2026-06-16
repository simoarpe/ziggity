const std = @import("std");

pub const Binding = struct {
    codepoint: u21,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn matches(self: Binding, key: anytype) bool {
        return key.matches(self.codepoint, .{
            .ctrl = self.ctrl,
            .alt = self.alt,
            .shift = self.shift,
        });
    }
};

pub const KeyMap = struct {
    quit: Binding = .{ .codepoint = 'q' },
    quit_ctrl: Binding = .{ .codepoint = 'c', .ctrl = true },
    refresh: Binding = .{ .codepoint = 'R' },
    command_log: Binding = .{ .codepoint = '@' },
    help: Binding = .{ .codepoint = '?' },
    undo: Binding = .{ .codepoint = 'z' },
    copy_clipboard: Binding = .{ .codepoint = 'o', .ctrl = true },
    open_browser: Binding = .{ .codepoint = 'o' },
    diff_mark: Binding = .{ .codepoint = 'W' },
    patch_menu: Binding = .{ .codepoint = 'p', .ctrl = true },
    up: Binding = .{ .codepoint = 'k' },
    down: Binding = .{ .codepoint = 'j' },
    left: Binding = .{ .codepoint = 'h' },
    right: Binding = .{ .codepoint = 'l' },
    select: Binding = .{ .codepoint = ' ' },
    enter: Binding = .{ .codepoint = 0x0d },
    escape: Binding = .{ .codepoint = 0x1b },
    backspace: Binding = .{ .codepoint = 0x7f },
    stage_all: Binding = .{ .codepoint = 'a' },
    file_filter: Binding = .{ .codepoint = '/' },
    toggle_tree: Binding = .{ .codepoint = '`' },
    open_status_filter: Binding = .{ .codepoint = 'b', .ctrl = true },
    discard: Binding = .{ .codepoint = 'd' },
    discard_all: Binding = .{ .codepoint = 'D' },
    commit: Binding = .{ .codepoint = 'c' },
    amend: Binding = .{ .codepoint = 'A' },
    cherry_pick: Binding = .{ .codepoint = 'c' },
    conflict_menu: Binding = .{ .codepoint = 'm' },
    stash_create: Binding = .{ .codepoint = 's' },
    new_branch: Binding = .{ .codepoint = 'n' },
    merge: Binding = .{ .codepoint = 'M' },
    rebase: Binding = .{ .codepoint = 'r' },
    rename: Binding = .{ .codepoint = 'R' },
    fast_forward: Binding = .{ .codepoint = 'f' },
    edit_remote: Binding = .{ .codepoint = 'e' },
    remove_remote: Binding = .{ .codepoint = 'x' },
    set_upstream: Binding = .{ .codepoint = 'u' },
    reset: Binding = .{ .codepoint = 'g' },
    revert: Binding = .{ .codepoint = 't' },
    range_select: Binding = .{ .codepoint = 'v' },
    commit_drop: Binding = .{ .codepoint = 'd' },
    commit_squash: Binding = .{ .codepoint = 's' },
    commit_fixup: Binding = .{ .codepoint = 'f' },
    commit_edit: Binding = .{ .codepoint = 'e' },
    commit_reword: Binding = .{ .codepoint = 'r' },
    commit_move_down: Binding = .{ .codepoint = 'j', .ctrl = true },
    commit_move_up: Binding = .{ .codepoint = 'k', .ctrl = true },
    commit_create_fixup: Binding = .{ .codepoint = 'F' },
    commit_autosquash: Binding = .{ .codepoint = 'S' },
    commit_mark_base: Binding = .{ .codepoint = 'B' },
    bisect: Binding = .{ .codepoint = 'b' },
    fetch: Binding = .{ .codepoint = 'f' },
    pull: Binding = .{ .codepoint = 'p' },
    push: Binding = .{ .codepoint = 'P' },
    stash_apply: Binding = .{ .codepoint = ' ' },
    stash_pop: Binding = .{ .codepoint = 'g' },
    stash_drop: Binding = .{ .codepoint = 'd' },
    status_panel: Binding = .{ .codepoint = '1' },
    files_panel: Binding = .{ .codepoint = '2' },
    branches_panel: Binding = .{ .codepoint = '3' },
    commits_panel: Binding = .{ .codepoint = '4' },
    stash_panel: Binding = .{ .codepoint = '5' },
    prev_tab: Binding = .{ .codepoint = '[' },
    next_tab: Binding = .{ .codepoint = ']' },
};

/// Terminal color indices (0-255) for UI elements, set via `color.<name>` in
/// the config. Defaults match the built-in palette.
pub const Theme = struct {
    selected_bg: u8 = 4,
    active: u8 = 10,
    inactive_border: u8 = 8,
    muted: u8 = 8,
    title: u8 = 7,
    accent: u8 = 14,
    staged: u8 = 10,
    unstaged: u8 = 9,
    warning: u8 = 11,
    added: u8 = 10,
    removed: u8 = 9,
    hunk: u8 = 14,
    header: u8 = 13,
};

/// A user-defined shell command bound to a key (`command.<key>` in config).
/// Stored in a fixed buffer so Config needs no allocation or teardown.
pub const CustomCommand = struct {
    binding: Binding,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn command(self: *const CustomCommand) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const max_custom_commands = 16;

/// When the operation result dialog appears after a git action.
/// `on_error` (default) mirrors lazygit: silent on success, dialog on failure.
pub const ResultDialog = enum { on_error, always, never };

/// Whether a custom shell command's output pops a dialog (`show`, the default,
/// since custom commands are usually run to read output) or follows
/// `result_dialog` like any other action (`silent`).
pub const CommandOutput = enum { show, silent };

/// Per-action toggles to skip the confirm-before prompt for destructive
/// actions. Field names match the `Confirmation` enum tags in app.zig so the
/// lookup is a direct `@field`. All default to false (confirmations stay on).
/// Set via `skip_confirm.<name> = true` in the config.
pub const ConfirmSkips = struct {
    discard_all: bool = false,
    merge_branch: bool = false,
    rebase_branch: bool = false,
    delete_tag: bool = false,
    delete_remote_branch: bool = false,
    remove_worktree: bool = false,
    remove_remote: bool = false,
    undo: bool = false,
};

pub const Config = struct {
    side_panel_width_percent: u8 = 34,
    diff_context: u8 = 3,
    /// lazygit's accordion mode: when true, the focused side-panel list grows to
    /// `expanded_side_panel_weight` while the others shrink. Default off.
    expand_focused_side_panel: bool = false,
    expanded_side_panel_weight: u8 = 2,
    result_dialog: ResultDialog = .on_error,
    command_output: CommandOutput = .show,
    skip_confirm: ConfirmSkips = .{},
    keymap: KeyMap = .{},
    theme: Theme = .{},
    custom_commands: [max_custom_commands]CustomCommand = undefined,
    custom_count: usize = 0,

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *std.process.Environ.Map,
        repo_root: []const u8,
    ) !Config {
        var cfg: Config = .{};

        if (env_map.get("ZIGGITY_CONFIG")) |path| {
            try cfg.applyFile(allocator, io, path);
        }

        const repo_config = try std.fmt.allocPrint(allocator, "{s}/.ziggity.ini", .{repo_root});
        defer allocator.free(repo_config);
        try cfg.applyFile(allocator, io, repo_config);

        return cfg;
    }

    fn applyFile(self: *Config, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer allocator.free(bytes);
        self.applyBytes(bytes);
    }

    pub fn applyBytes(self: *Config, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const no_cr = std.mem.trim(u8, raw_line, "\r");
            const without_comment = if (std.mem.indexOfScalar(u8, no_cr, '#')) |idx| no_cr[0..idx] else no_cr;
            const line = std.mem.trim(u8, without_comment, " \t");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            self.applyEntry(key, value);
        }
    }

    fn applyEntry(self: *Config, key: []const u8, value: []const u8) void {
        if (std.mem.eql(u8, key, "side_panel_width_percent")) {
            const parsed = std.fmt.parseInt(u8, value, 10) catch return;
            self.side_panel_width_percent = @min(70, @max(20, parsed));
            return;
        }
        if (std.mem.eql(u8, key, "diff_context")) {
            self.diff_context = std.fmt.parseInt(u8, value, 10) catch self.diff_context;
            return;
        }
        if (std.mem.eql(u8, key, "expand_focused_side_panel")) {
            if (parseBool(value)) |on| self.expand_focused_side_panel = on;
            return;
        }
        if (std.mem.eql(u8, key, "expanded_side_panel_weight")) {
            self.expanded_side_panel_weight = @max(1, std.fmt.parseInt(u8, value, 10) catch self.expanded_side_panel_weight);
            return;
        }
        if (std.mem.eql(u8, key, "result_dialog")) {
            if (std.meta.stringToEnum(ResultDialog, value)) |v| self.result_dialog = v;
            return;
        }
        if (std.mem.eql(u8, key, "command_output")) {
            if (std.meta.stringToEnum(CommandOutput, value)) |v| self.command_output = v;
            return;
        }
        if (std.mem.startsWith(u8, key, "skip_confirm.")) {
            const name = key["skip_confirm.".len..];
            const on = parseBool(value) orelse return;
            inline for (std.meta.fields(ConfirmSkips)) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    @field(self.skip_confirm, field.name) = on;
                    return;
                }
            }
            return;
        }

        if (std.mem.startsWith(u8, key, "command.")) {
            if (self.custom_count >= max_custom_commands) return;
            if (value.len == 0 or value.len > 256) return;
            const binding = parseBinding(key["command.".len..]) orelse return;
            var cc = CustomCommand{ .binding = binding, .len = value.len };
            @memcpy(cc.buf[0..value.len], value);
            self.custom_commands[self.custom_count] = cc;
            self.custom_count += 1;
            return;
        }

        if (std.mem.startsWith(u8, key, "color.")) {
            const color_name = key["color.".len..];
            const parsed = std.fmt.parseInt(u8, value, 10) catch return;
            inline for (std.meta.fields(Theme)) |field| {
                if (std.mem.eql(u8, color_name, field.name)) {
                    @field(self.theme, field.name) = parsed;
                    return;
                }
            }
            return;
        }

        const key_name = if (std.mem.startsWith(u8, key, "key.")) key["key.".len..] else return;
        const binding = parseBinding(value) orelse return;
        inline for (std.meta.fields(KeyMap)) |field| {
            if (std.mem.eql(u8, key_name, field.name)) {
                @field(self.keymap, field.name) = binding;
                return;
            }
        }
    }
};

pub fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off")) return false;
    return null;
}

pub fn parseBinding(raw: []const u8) ?Binding {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;
    if (std.mem.startsWith(u8, value, "ctrl+")) {
        const rest = value["ctrl+".len..];
        if (rest.len != 1) return null;
        return .{ .codepoint = rest[0], .ctrl = true };
    }
    if (std.mem.startsWith(u8, value, "alt+")) {
        const rest = value["alt+".len..];
        if (rest.len != 1) return null;
        return .{ .codepoint = rest[0], .alt = true };
    }
    if (std.mem.eql(u8, value, "space")) return .{ .codepoint = ' ' };
    if (std.mem.eql(u8, value, "enter")) return .{ .codepoint = 0x0d };
    if (std.mem.eql(u8, value, "tab")) return .{ .codepoint = 0x09 };
    if (std.mem.eql(u8, value, "esc")) return .{ .codepoint = 0x1b };
    if (std.mem.eql(u8, value, "backspace")) return .{ .codepoint = 0x7f };
    if (value.len == 1) return .{ .codepoint = value[0] };
    return null;
}

test "config parser applies key overrides and bounded layout" {
    var cfg: Config = .{};
    cfg.applyBytes(
        \\side_panel_width_percent = 80
        \\key.quit = x
        \\key.push = ctrl+p
    );
    try std.testing.expectEqual(@as(u8, 70), cfg.side_panel_width_percent);
    try std.testing.expectEqual(@as(u21, 'x'), cfg.keymap.quit.codepoint);
    try std.testing.expectEqual(@as(u21, 'p'), cfg.keymap.push.codepoint);
    try std.testing.expect(cfg.keymap.push.ctrl);
}

test "config parser applies theme colors and newer keybindings" {
    var cfg: Config = .{};
    cfg.applyBytes(
        \\color.selected_bg = 5
        \\color.added = 2
        \\key.fast_forward = F
        \\key.command_log = L
    );
    try std.testing.expectEqual(@as(u8, 5), cfg.theme.selected_bg);
    try std.testing.expectEqual(@as(u8, 2), cfg.theme.added);
    try std.testing.expectEqual(@as(u8, 11), cfg.theme.warning); // default preserved
    try std.testing.expectEqual(@as(u21, 'F'), cfg.keymap.fast_forward.codepoint);
    try std.testing.expectEqual(@as(u21, 'L'), cfg.keymap.command_log.codepoint);
}

test "config parser applies result-dialog, command-output, and skip-confirm flags" {
    var cfg: Config = .{};
    // Defaults match lazygit: dialog only on error, custom output shown,
    // confirmations on.
    try std.testing.expectEqual(ResultDialog.on_error, cfg.result_dialog);
    try std.testing.expectEqual(CommandOutput.show, cfg.command_output);
    try std.testing.expect(!cfg.skip_confirm.discard_all);

    cfg.applyBytes(
        \\result_dialog = always
        \\command_output = silent
        \\skip_confirm.discard_all = true
        \\skip_confirm.undo = yes
        \\skip_confirm.bogus = true
        \\result_dialog = nonsense
        \\expand_focused_side_panel = true
        \\expanded_side_panel_weight = 3
    );
    try std.testing.expectEqual(ResultDialog.always, cfg.result_dialog); // valid set; bad value ignored
    try std.testing.expectEqual(CommandOutput.silent, cfg.command_output);
    try std.testing.expect(cfg.skip_confirm.discard_all);
    try std.testing.expect(cfg.skip_confirm.undo);
    try std.testing.expect(!cfg.skip_confirm.merge_branch); // untouched
    try std.testing.expect(cfg.expand_focused_side_panel);
    try std.testing.expectEqual(@as(u8, 3), cfg.expanded_side_panel_weight);
}

test "config parser stores custom commands bound to keys" {
    var cfg: Config = .{};
    cfg.applyBytes(
        \\command.C = git commit --amend --no-edit
        \\command.ctrl+t = ctags -R .
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.custom_count);
    try std.testing.expectEqual(@as(u21, 'C'), cfg.custom_commands[0].binding.codepoint);
    try std.testing.expectEqualStrings("git commit --amend --no-edit", cfg.custom_commands[0].command());
    try std.testing.expect(cfg.custom_commands[1].binding.ctrl);
    try std.testing.expectEqualStrings("ctags -R .", cfg.custom_commands[1].command());
}
