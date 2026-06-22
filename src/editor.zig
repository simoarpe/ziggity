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
    suspend_tui: bool,
};

/// Built-in presets. Terminal editors suspend the TUI; GUI editors don't.
const presets = [_]Preset{
    .{ .name = "vi", .template = "vi -- {{filename}}", .suspend_tui = true },
    .{ .name = "vim", .template = "vim -- {{filename}}", .suspend_tui = true },
    .{ .name = "nvim", .template = "nvim -- {{filename}}", .suspend_tui = true },
    .{ .name = "lvim", .template = "lvim -- {{filename}}", .suspend_tui = true },
    .{ .name = "nano", .template = "nano -- {{filename}}", .suspend_tui = true },
    .{ .name = "emacs", .template = "emacs -- {{filename}}", .suspend_tui = true },
    .{ .name = "micro", .template = "micro {{filename}}", .suspend_tui = true },
    .{ .name = "helix", .template = "hx -- {{filename}}", .suspend_tui = true },
    .{ .name = "kakoune", .template = "kak {{filename}}", .suspend_tui = true },
    .{ .name = "vscode", .template = "code --reuse-window -- {{filename}}", .suspend_tui = false },
    .{ .name = "sublime", .template = "subl -- {{filename}}", .suspend_tui = false },
    .{ .name = "zed", .template = "zed -- {{filename}}", .suspend_tui = false },
    .{ .name = "bbedit", .template = "bbedit -- {{filename}}", .suspend_tui = false },
    .{ .name = "xcode", .template = "xed -- {{filename}}", .suspend_tui = false },
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
pub fn resolve(
    alloc: std.mem.Allocator,
    explicit_cmd: []const u8,
    preset_name: []const u8,
    detected: []const u8,
    suspend_override: ?bool,
    filename: []const u8,
) !Resolved {
    var template: []const u8 = undefined;
    var suspend_tui: bool = true;

    if (explicit_cmd.len > 0) {
        // A user-provided command: assume it needs the terminal unless told
        // otherwise (most hand-set editors are terminal ones).
        template = explicit_cmd;
        suspend_tui = true;
    } else if (preset_name.len > 0 and (findPreset(presetNameFor(preset_name) orelse preset_name) != null)) {
        const p = findPreset(presetNameFor(preset_name) orelse preset_name).?;
        template = p.template;
        suspend_tui = p.suspend_tui;
    } else if (detected.len > 0) {
        if (presetNameFor(detected)) |pname| {
            const p = findPreset(pname).?;
            template = p.template;
            suspend_tui = p.suspend_tui;
        } else {
            // Unknown but detected: run it as a terminal editor.
            template = detected; // placeholder appended below
            suspend_tui = true;
        }
    } else {
        const p = findPreset("vim").?;
        template = p.template;
        suspend_tui = p.suspend_tui;
    }

    if (suspend_override) |s| suspend_tui = s;

    const command = try substituteFilename(alloc, template, filename);
    return .{ .command = command, .suspend_tui = suspend_tui };
}

/// Replace every `{{filename}}` in `template` with a shell-quoted `filename`.
/// If the template has no placeholder, the quoted name is appended (so a bare
/// `vim` or a detected editor name still receives the file).
fn substituteFilename(alloc: std.mem.Allocator, template: []const u8, filename: []const u8) ![]u8 {
    const quoted = try shellQuote(alloc, filename);
    defer alloc.free(quoted);

    const placeholder = "{{filename}}";
    if (std.mem.indexOf(u8, template, placeholder) == null) {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ template, quoted });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = template;
    while (std.mem.indexOf(u8, rest, placeholder)) |i| {
        try out.appendSlice(alloc, rest[0..i]);
        try out.appendSlice(alloc, quoted);
        rest = rest[i + placeholder.len ..];
    }
    try out.appendSlice(alloc, rest);
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
    const r = try resolve(a, "myed {{filename}}", "vscode", "code", null, "a b.txt");
    defer a.free(r.command);
    try std.testing.expectEqualStrings("myed 'a b.txt'", r.command);
    try std.testing.expect(r.suspend_tui);
}

test "resolve: preset selects template + suspend flag" {
    const a = std.testing.allocator;
    const vsc = try resolve(a, "", "vscode", "", null, "f.zig");
    defer a.free(vsc.command);
    try std.testing.expectEqualStrings("code --reuse-window -- 'f.zig'", vsc.command);
    try std.testing.expect(!vsc.suspend_tui); // GUI

    const vimr = try resolve(a, "", "vim", "", null, "f.zig");
    defer a.free(vimr.command);
    try std.testing.expect(vimr.suspend_tui); // terminal
}

test "resolve: auto-detect maps aliases, falls back to vim" {
    const a = std.testing.allocator;
    // `code` (a $EDITOR value) maps to the vscode preset.
    const d = try resolve(a, "", "", "code", null, "x");
    defer a.free(d.command);
    try std.testing.expectEqualStrings("code --reuse-window -- 'x'", d.command);
    try std.testing.expect(!d.suspend_tui);

    // An unknown detected editor is run as a terminal editor.
    const u = try resolve(a, "", "", "myeditor", null, "x");
    defer a.free(u.command);
    try std.testing.expectEqualStrings("myeditor 'x'", u.command);
    try std.testing.expect(u.suspend_tui);

    // Nothing configured or detected -> vim.
    const f = try resolve(a, "", "", "", null, "x");
    defer a.free(f.command);
    try std.testing.expectEqualStrings("vim -- 'x'", f.command);
}

test "resolve: editor_in_terminal override wins" {
    const a = std.testing.allocator;
    const r = try resolve(a, "", "vscode", "", true, "x"); // force suspend for a GUI preset
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
