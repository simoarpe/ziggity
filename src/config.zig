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
    open_status_filter: Binding = .{ .codepoint = 'b', .ctrl = true },
    discard: Binding = .{ .codepoint = 'd' },
    discard_all: Binding = .{ .codepoint = 'D' },
    commit: Binding = .{ .codepoint = 'c' },
    new_branch: Binding = .{ .codepoint = 'n' },
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

pub const Config = struct {
    side_panel_width_percent: u8 = 34,
    diff_context: u8 = 3,
    keymap: KeyMap = .{},

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
