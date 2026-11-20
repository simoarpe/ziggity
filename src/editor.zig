//! Resolving which editor command to run to open a file: an explicit configured
//! template wins; otherwise a named preset; otherwise the editor auto-detected
//! from git `core.editor` / `$GIT_EDITOR` / `$VISUAL` / `$EDITOR`; otherwise
//! `vim`. Each choice carries a `suspend_tui` flag — terminal editors (vim,
//! nano, …) need the TUI to hand over the terminal and resume on exit, while
//! GUI editors (VS Code, …) just launch.
const std = @import("std");

pub const Resolved = struct {
    /// A shell command line (`{{filename}}` already substituted and quoted),
    /// run via `sh -c`. Owned by the allocator passed to `resolve`.
    command: []u8,
    /// Whether the TUI must suspend (give up the terminal) while it runs.
    suspend_tui: bool,
};

const Preset = struct {
    name: []const u8,
    /// Edit template containing `{{filename}}`.
    template: []const u8,
    /// Edit-at-line template containing `{{filename}}` and `{{line}}`.
    at_line: []const u8,
    suspend_tui: bool,
};

/// Built-in presets. Terminal editors suspend the TUI; GUI editors don't.
const presets = [_]Preset{
    .{ .name = "vi", .template = "vi -- {{filename}}", .at_line = "vi +{{line}} -- {{filename}}", .suspend_tui = true },
    .{ .name = "vim", .template = "vim -- {{filename}}", .at_line = "vim +{{line}} -- {{filename}}", .suspend_tui = true },
    .{ .name = "nvim", .template = "nvim -- {{filename}}", .at_line = "nvim +{{line}} -- {{filename}}", .suspend_tui = true },
    .{ .name = "lvim", .template = "lvim -- {{filename}}", .at_line = "lvim +{{line}} -- {{filename}}", .suspend_tui = true },
    .{ .name = "nano", .template = "nano -- {{filename}}", .at_line = "nano +{{line}} -- {{filename}}", .suspend_tui = true },
    .{ .name = "emacs", .template = "emacs -- {{filename}}", .at_line = "emacs +{{line}} -- {{filename}}", .suspend_tui = true },
    .{ .name = "micro", .template = "micro {{filename}}", .at_line = "micro +{{line}} {{filename}}", .suspend_tui = true },
    .{ .name = "helix", .template = "hx -- {{filename}}", .at_line = "hx -- {{filename}}:{{line}}", .suspend_tui = true },
    .{ .name = "kakoune", .template = "kak {{filename}}", .at_line = "kak +{{line}} {{filename}}", .suspend_tui = true },
    .{ .name = "vscode", .template = "code --reuse-window -- {{filename}}", .at_line = "code --reuse-window --goto -- {{filename}}:{{line}}", .suspend_tui = false },
    .{ .name = "sublime", .template = "subl -- {{filename}}", .at_line = "subl -- {{filename}}:{{line}}", .suspend_tui = false },
    .{ .name = "zed", .template = "zed -- {{filename}}", .at_line = "zed -- {{filename}}:{{line}}", .suspend_tui = false },
    .{ .name = "bbedit", .template = "bbedit -- {{filename}}", .at_line = "bbedit +{{line}} -- {{filename}}", .suspend_tui = false },
    .{ .name = "xcode", .template = "xed -- {{filename}}", .at_line = "xed --line {{line}} -- {{filename}}", .suspend_tui = false },
};

/// Map a detected editor binary (or a preset alias) to a preset name.
fn presetNameFor(editor: []const u8) ?[]const u8 {
    const aliases = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "code", .to = "vscode" },
        .{ .from = "code-insiders", .to = "vscode" },
        .{ .from = "subl", .to = "sublime" },
        .{ .from = "hx", .to = "helix" },
        .{ .from = "kak", .to = "kakoune" },
        .{ .from = "xed", .to = "xcode" },
    };
    for (aliases) |a| {
        if (std.mem.eql(u8, editor, a.from)) return a.to;
    }
    for (presets) |p| {
        if (std.mem.eql(u8, editor, p.name)) return p.name;
    }
    return null;
}

fn findPreset(name: []const u8) ?Preset {
    for (presets) |p| {
        if (std.mem.eql(u8, name, p.name)) return p;
    }
    return null;
}

/// Build the editor command for `filename`.
/// - `explicit_cmd`: configured template override (`editor_command`), or "".
/// - `preset_name`: configured preset (`editor_preset`), or "".
/// - `detected`: first word of core.editor/$GIT_EDITOR/$VISUAL/$EDITOR, or "".
/// - `suspend_override`: configured `editor_in_terminal`, or null.
/// - `line`: 1-based line to open the file at, or null for no jump. Honored by
///   the presets and by an `editor_command` containing `{{line}}`.
pub fn resolve(
    alloc: std.mem.Allocator,
    explicit_cmd: []const u8,
    preset_name: []const u8,
    detected: []const u8,
    suspend_override: ?bool,
    filename: []const u8,
    line: ?usize,
) !Resolved {
    return resolveMany(alloc, explicit_cmd, preset_name, detected, suspend_override, &.{filename}, line);
}

/// Like `resolve`, but opens several files in one editor invocation. The
/// `{{filename}}` placeholder is replaced with the space-joined, individually
/// shell-quoted list (or the list is appended when the template has none).
/// `line` only makes sense for a single file.
pub fn resolveMany(
    alloc: std.mem.Allocator,
    explicit_cmd: []const u8,
    preset_name: []const u8,
    detected: []const u8,
    suspend_override: ?bool,
    filenames: []const []const u8,
    line: ?usize,
) !Resolved {
    const at_line: ?usize = if (filenames.len == 1) line else null;
    const picked = pickTemplate(explicit_cmd, preset_name, detected, suspend_override, at_line != null);
    const command = try substitute(alloc, picked.template, filenames, at_line);
    return .{ .command = command, .suspend_tui = picked.suspend_tui };
}

fn pickTemplate(
    explicit_cmd: []const u8,
    preset_name: []const u8,
    detected: []const u8,
    suspend_override: ?bool,
    want_line: bool,
) struct { template: []const u8, suspend_tui: bool } {
    var template: []const u8 = undefined;
    var suspend_tui: bool = true;

    if (explicit_cmd.len > 0) {
        // A user-provided command: assume it needs the terminal unless told
        // otherwise (most hand-set editors are terminal ones).
        template = explicit_cmd;
        suspend_tui = true;
    } else if (preset_name.len > 0 and (findPreset(presetNameFor(preset_name) orelse preset_name) != null)) {
        const p = findPreset(presetNameFor(preset_name) orelse preset_name).?;
        template = if (want_line) p.at_line else p.template;
        suspend_tui = p.suspend_tui;
    } else if (detected.len > 0) {
        if (presetNameFor(detected)) |pname| {
            const p = findPreset(pname).?;
            template = if (want_line) p.at_line else p.template;
            suspend_tui = p.suspend_tui;
        } else {
            // Unknown but detected: run it as a terminal editor. Its
            // line-jump syntax is unknown, so the file just opens.
            template = detected; // filename appended by `substitute`
            suspend_tui = true;
        }
    } else {
        const p = findPreset("vim").?;
        template = if (want_line) p.at_line else p.template;
        suspend_tui = p.suspend_tui;
    }

    if (suspend_override) |s| suspend_tui = s;
    return .{ .template = template, .suspend_tui = suspend_tui };
}

/// Fill in a template: every `{{line}}` becomes the line number (1 when there
/// is none to jump to), and every `{{filename}}` becomes the space-joined,
/// individually shell-quoted `filenames`. If the template has no
/// `{{filename}}`, the names are appended (so a bare `vim` or a detected
/// editor name still receives the file).
fn substitute(alloc: std.mem.Allocator, template: []const u8, filenames: []const []const u8, line: ?usize) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (filenames, 0..) |f, idx| {
        if (idx > 0) try joined.append(alloc, ' ');
        const q = try shellQuote(alloc, f);
        defer alloc.free(q);
        try joined.appendSlice(alloc, q);
    }
    var line_buf: [24]u8 = undefined;
    const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{line orelse 1}) catch unreachable;

    const file_ph = "{{filename}}";
    const line_ph = "{{line}}";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var has_file = false;
    var rest = template;
    // Single pass over the template, so a path that itself contains a
    // placeholder is never re-expanded.
    while (std.mem.indexOf(u8, rest, "{{")) |i| {
        try out.appendSlice(alloc, rest[0..i]);
        rest = rest[i..];
        if (std.mem.startsWith(u8, rest, file_ph)) {
            try out.appendSlice(alloc, joined.items);
            rest = rest[file_ph.len..];
            has_file = true;
        } else if (std.mem.startsWith(u8, rest, line_ph)) {
            try out.appendSlice(alloc, line_str);
            rest = rest[line_ph.len..];
        } else {
            try out.appendSlice(alloc, rest[0..2]);
            rest = rest[2..];
        }
    }
    try out.appendSlice(alloc, rest);
    if (!has_file) {
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, joined.items);
    }
    return out.toOwnedSlice(alloc);
}

/// POSIX single-quote a string: wrap in `'…'`, turning any embedded `'` into
/// `'\''`. Safe to drop into a `sh -c` command line.
fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

/// The first whitespace-delimited word of `s` (an `$EDITOR` value may be e.g.
/// "code -w" or "vim -u rc"; only the binary name selects a preset).
pub fn firstWord(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return trimmed;
    return trimmed[0..end];
}

test "resolve: explicit command overrides everything, suspends by default" {
    const a = std.testing.allocator;
    const r = try resolve(a, "myed {{filename}}", "vscode", "code", null, "a b.txt", null);
    defer a.free(r.command);
    try std.testing.expectEqualStrings("myed 'a b.txt'", r.command);
    try std.testing.expect(r.suspend_tui);
}

test "resolveMany: each file is quoted and joined into one command" {
    const a = std.testing.allocator;
    const r = try resolveMany(a, "myed {{filename}}", "", "", null, &.{ "a b.txt", "c.zig" }, null);
    defer a.free(r.command);
    try std.testing.expectEqualStrings("myed 'a b.txt' 'c.zig'", r.command);

    // A single-element list behaves exactly like resolve().
    const one = try resolveMany(a, "myed {{filename}}", "", "", null, &.{"only.txt"}, null);
    defer a.free(one.command);
    try std.testing.expectEqualStrings("myed 'only.txt'", one.command);
}

test "resolve: preset selects template + suspend flag" {
    const a = std.testing.allocator;
    const vsc = try resolve(a, "", "vscode", "", null, "f.zig", null);
    defer a.free(vsc.command);
    try std.testing.expectEqualStrings("code --reuse-window -- 'f.zig'", vsc.command);
    try std.testing.expect(!vsc.suspend_tui); // GUI

    const vimr = try resolve(a, "", "vim", "", null, "f.zig", null);
    defer a.free(vimr.command);
    try std.testing.expect(vimr.suspend_tui); // terminal
}

test "resolve: auto-detect maps aliases, falls back to vim" {
    const a = std.testing.allocator;
    // `code` (a $EDITOR value) maps to the vscode preset.
    const d = try resolve(a, "", "", "code", null, "x", null);
    defer a.free(d.command);
    try std.testing.expectEqualStrings("code --reuse-window -- 'x'", d.command);
    try std.testing.expect(!d.suspend_tui);

    // An unknown detected editor is run as a terminal editor.
    const u = try resolve(a, "", "", "myeditor", null, "x", null);
    defer a.free(u.command);
    try std.testing.expectEqualStrings("myeditor 'x'", u.command);
    try std.testing.expect(u.suspend_tui);

    // Nothing configured or detected -> vim.
    const f = try resolve(a, "", "", "", null, "x", null);
    defer a.free(f.command);
    try std.testing.expectEqualStrings("vim -- 'x'", f.command);
}

test "resolve: editor_in_terminal override wins" {
    const a = std.testing.allocator;
    const r = try resolve(a, "", "vscode", "", true, "x", null); // force suspend for a GUI preset
    defer a.free(r.command);
    try std.testing.expect(r.suspend_tui);
}

test "shellQuote escapes single quotes" {
    const a = std.testing.allocator;
    const q = try shellQuote(a, "it's a file.txt");
    defer a.free(q);
    try std.testing.expectEqualStrings("'it'\\''s a file.txt'", q);
}

test "firstWord takes the binary name" {
    try std.testing.expectEqualStrings("code", firstWord("code -w"));
    try std.testing.expectEqualStrings("vim", firstWord("  vim  "));
    try std.testing.expectEqualStrings("", firstWord(""));
}

test "resolve: a line jumps via the preset's at-line template" {
    const a = std.testing.allocator;
    const nv = try resolve(a, "", "", "nvim", null, "a b.zig", 42);
    defer a.free(nv.command);
    try std.testing.expectEqualStrings("nvim +42 -- 'a b.zig'", nv.command);

    const vsc = try resolve(a, "", "vscode", "", null, "f.zig", 7);
    defer a.free(vsc.command);
    try std.testing.expectEqualStrings("code --reuse-window --goto -- 'f.zig':7", vsc.command);

    // Nothing configured or detected -> vim, still at the line.
    const f = try resolve(a, "", "", "", null, "x", 3);
    defer a.free(f.command);
    try std.testing.expectEqualStrings("vim +3 -- 'x'", f.command);

    // An unknown detected editor has no known line syntax: just the file.
    const u = try resolve(a, "", "", "myeditor", null, "x", 3);
    defer a.free(u.command);
    try std.testing.expectEqualStrings("myeditor 'x'", u.command);
}

test "resolve: editor_command {{line}} placeholder" {
    const a = std.testing.allocator;
    const r = try resolve(a, "myed +{{line}} {{filename}}", "", "", null, "x", 12);
    defer a.free(r.command);
    try std.testing.expectEqualStrings("myed +12 'x'", r.command);

    // No line to jump to: the placeholder falls back to line 1.
    const n = try resolve(a, "myed +{{line}} {{filename}}", "", "", null, "x", null);
    defer a.free(n.command);
    try std.testing.expectEqualStrings("myed +1 'x'", n.command);

    // A command without the placeholder ignores the line.
    const p = try resolve(a, "myed {{filename}}", "", "", null, "x", 12);
    defer a.free(p.command);
    try std.testing.expectEqualStrings("myed 'x'", p.command);

    // Several files never jump, and a placeholder inside a path stays literal.
    const m = try resolveMany(a, "", "vim", "", null, &.{ "a", "{{line}}" }, 9);
    defer a.free(m.command);
    try std.testing.expectEqualStrings("vim -- 'a' '{{line}}'", m.command);
}
