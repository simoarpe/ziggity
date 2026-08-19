//! AI-assisted commit authoring: builds the title/description prompts, runs the
//! configured `ai_command` (a black box that reads a prompt on stdin and prints
//! a completion on stdout), and normalizes the result to git conventions (a
//! clean single-line subject; a body wrapped at 72 columns).
//!
//! Title and description use separate prompts and separate requests so a field
//! can be generated or regenerated on its own. The provider, key, and transport
//! all live in the external command, never here. Everything except `generate`
//! (which touches git) is pure and unit-tested.

const std = @import("std");
const git_mod = @import("git.zig");

pub const Field = enum { title, description };

/// Length conventions for the generated message. Sourced from the commit-dialog
/// config: `title_max` = `commit_summary_limit`, `body_wrap` = `commit_body_guide`
/// (each falling back to the 50/72 default when the config is 0/unset).
pub const Limits = struct {
    title_max: usize = 50,
    body_wrap: usize = 72,
};

/// Cap on how much of the staged diff we put in a prompt, so a huge staged
/// change doesn't send megabytes to the provider.
const max_diff_bytes: usize = 16 * 1024;

pub const GenError = error{ NothingStaged, AiCommandFailed, EmptyResponse };

pub const Context = struct {
    staged_diff: []const u8,
    staged_files: []const u8,
    recent_subjects: []const u8,
    /// The current title, passed to description generation so the body can
    /// complement it. Empty when unknown or generating a title.
    current_title: []const u8 = "",
};

/// Gather the git context, build the field's prompt, run `command`, and return
/// the normalized result (caller owns it). Runs off the UI thread.
pub fn generate(allocator: std.mem.Allocator, git: *git_mod.Git, command: []const u8, field: Field, current_title: []const u8, limits: Limits) ![]u8 {
    const diff = try git.stagedDiff();
    defer allocator.free(diff);
    if (std.mem.trim(u8, diff, " \t\r\n").len == 0) return GenError.NothingStaged;

    const files = try git.stagedFileNames();
    defer allocator.free(files);
    const subjects = try git.recentSubjects(10);
    defer allocator.free(subjects);

    const ctx = Context{
        .staged_diff = diff,
        .staged_files = files,
        .recent_subjects = subjects,
        .current_title = current_title,
    };
    const prompt = switch (field) {
        .title => try buildTitlePrompt(allocator, ctx, limits.title_max),
        .description => try buildDescPrompt(allocator, ctx, limits.body_wrap),
    };
    defer allocator.free(prompt);

    const slot = switch (field) {
        .title => "title",
        .description => "desc",
    };
    var res = git.runAiCommand(command, slot, prompt) catch return GenError.AiCommandFailed;
    defer res.deinit(allocator);
    if (!res.ok()) return GenError.AiCommandFailed;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return GenError.EmptyResponse;

    return switch (field) {
        .title => try normalizeTitle(allocator, out),
        .description => try normalizeBody(allocator, out, limits.body_wrap),
    };
}

// ---- Prompt construction --------------------------------------------------

fn appendDiff(out: *std.ArrayList(u8), allocator: std.mem.Allocator, diff: []const u8) !void {
    if (diff.len <= max_diff_bytes) {
        try out.appendSlice(allocator, diff);
    } else {
        try out.appendSlice(allocator, diff[0..max_diff_bytes]);
        try out.appendSlice(allocator, "\n… [diff truncated]\n");
    }
}

pub fn buildTitlePrompt(allocator: std.mem.Allocator, ctx: Context, title_max: usize) ![]u8 {
    const max = if (title_max == 0) 50 else title_max;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Write a git commit SUBJECT LINE for the staged changes below.\n\nRules:\n");
    try out.appendSlice(allocator, "- Output ONLY the subject line. No quotes, no markdown, no code fences, no preamble or explanation.\n");
    var nbuf: [96]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&nbuf, "- At most {d} characters when reasonable; never wrap to multiple lines.\n", .{max}) catch "- Keep the subject short; never wrap to multiple lines.\n");
    try out.appendSlice(allocator,
        \\- Imperative mood, e.g. "Fix wallet layout in landscape" not "Fixed the wallet layout.".
        \\- No trailing period unless the recent subjects clearly use one.
        \\- Follow the conventions visible in the recent subjects (prefixes, casing) when there is a clear pattern.
        \\
        \\Recent commit subjects (for style):
        \\
    );
    try out.appendSlice(allocator, ctx.recent_subjects);
    try out.appendSlice(allocator, "\nStaged files:\n");
    try out.appendSlice(allocator, ctx.staged_files);
    try out.appendSlice(allocator, "\nStaged diff:\n");
    try appendDiff(&out, allocator, ctx.staged_diff);
    try out.appendSlice(allocator, "\n\nSubject line:");
    return out.toOwnedSlice(allocator);
}

pub fn buildDescPrompt(allocator: std.mem.Allocator, ctx: Context, body_wrap: usize) ![]u8 {
    const wrap = if (body_wrap == 0) 72 else body_wrap;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Write a git commit MESSAGE BODY (description) for the staged changes below.\n\nRules:\n");
    try out.appendSlice(allocator, "- Output ONLY the body. No subject line, no quotes, no markdown headings, no code fences, no preamble.\n");
    try out.appendSlice(allocator, "- Do not repeat or restate the subject.\n");
    try out.appendSlice(allocator, "- Explain the motivation and the resulting behavior, not a line-by-line restatement of the diff.\n");
    var nbuf: [96]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&nbuf, "- Plain-text git style, wrapped at {d} columns, short paragraphs separated by a blank line.\n", .{wrap}) catch "- Plain-text git style, wrapped at 72 columns, short paragraphs separated by a blank line.\n");
    if (std.mem.trim(u8, ctx.current_title, " \t\r\n").len > 0) {
        try out.appendSlice(allocator, "The commit subject is: ");
        try out.appendSlice(allocator, ctx.current_title);
        try out.appendSlice(allocator, "\nWrite a body that complements it.\n\n");
    }
    try out.appendSlice(allocator, "Recent commit subjects (for style):\n");
    try out.appendSlice(allocator, ctx.recent_subjects);
    try out.appendSlice(allocator, "\nStaged files:\n");
    try out.appendSlice(allocator, ctx.staged_files);
    try out.appendSlice(allocator, "\nStaged diff:\n");
    try appendDiff(&out, allocator, ctx.staged_diff);
    try out.appendSlice(allocator, "\n\nBody:");
    return out.toOwnedSlice(allocator);
}

// ---- Response normalization ----------------------------------------------

fn trimEnd(s: []const u8, chars: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and std.mem.indexOfScalar(u8, chars, s[end - 1]) != null) end -= 1;
    return s[0..end];
}

/// Drop a single pair of wrapping quotes or backticks the model sometimes adds.
fn stripWrappingQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const a = s[0];
        const b = s[s.len - 1];
        if ((a == '"' and b == '"') or (a == '\'' and b == '\'') or (a == '`' and b == '`')) return s[1 .. s.len - 1];
    }
    return s;
}

/// Clean a model title: first line only, no wrapping quotes, trimmed. Never
/// hard-truncated (a short, valid title is the model's job, enforced by prompt).
pub fn normalizeTitle(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = s[0..nl];
    s = std.mem.trim(u8, s, " \t\r");
    s = std.mem.trim(u8, stripWrappingQuotes(s), " \t");
    return allocator.dupe(u8, s);
}

/// Reflow a model body to `width` columns: consecutive prose lines are joined
/// into one paragraph and greedy-wrapped, so the model's own (uneven) line
/// breaks are normalized. Blank lines separate paragraphs and are preserved;
/// list items and indented lines are kept on their own lines (wrapped if long).
/// Words longer than the width are left intact rather than broken.
pub fn normalizeBody(allocator: std.mem.Allocator, raw: []const u8, width: usize) ![]u8 {
    const w = if (width == 0) 72 else width;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var para: std.ArrayList(u8) = .empty;
    defer para.deinit(allocator);

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw_line| {
        const line = trimEnd(raw_line, " \t\r");
        const t = std.mem.trim(u8, line, " \t");
        const blank = t.len == 0;
        const indented = line.len > 0 and (line[0] == ' ' or line[0] == '\t');
        const special = !blank and (isListItem(t) or indented);

        if (blank or special) try flushPara(&out, allocator, &para, w);
        if (blank) {
            try appendOutLine(&out, allocator, "");
        } else if (special) {
            try wrapInto(&out, allocator, line, w);
        } else {
            if (para.items.len > 0) try para.append(allocator, ' ');
            try para.appendSlice(allocator, t);
        }
    }
    try flushPara(&out, allocator, &para, w);
    return out.toOwnedSlice(allocator);
}

fn flushPara(out: *std.ArrayList(u8), allocator: std.mem.Allocator, para: *std.ArrayList(u8), width: usize) !void {
    if (para.items.len == 0) return;
    try wrapInto(out, allocator, para.items, width);
    para.clearRetainingCapacity();
}

/// Append `line` to `out` on its own output row (a newline before it unless
/// `out` is empty), so callers don't track separators.
fn appendOutLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, line);
}

/// Greedy word-wrap `text` at `width`, appending each wrapped row via
/// `appendOutLine`.
fn wrapInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |word| {
        if (row.items.len == 0) {
            try row.appendSlice(allocator, word);
        } else if (row.items.len + 1 + word.len <= width) {
            try row.append(allocator, ' ');
            try row.appendSlice(allocator, word);
        } else {
            try appendOutLine(out, allocator, row.items);
            row.clearRetainingCapacity();
            try row.appendSlice(allocator, word);
        }
    }
    if (row.items.len > 0) try appendOutLine(out, allocator, row.items);
}

fn isListItem(t: []const u8) bool {
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') return true;
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
    return i > 0 and i + 1 < t.len and (t[i] == '.' or t[i] == ')') and t[i + 1] == ' ';
}

test "normalizeTitle strips quotes and takes the first line" {
    const a = std.testing.allocator;
    const t1 = try normalizeTitle(a, "\"Fix wallet layout in landscape\"\nextra");
    defer a.free(t1);
    try std.testing.expectEqualStrings("Fix wallet layout in landscape", t1);

    const t2 = try normalizeTitle(a, "  `Add parser stub`  ");
    defer a.free(t2);
    try std.testing.expectEqualStrings("Add parser stub", t2);
}

test "normalizeBody wraps prose to 72 columns and keeps blank lines" {
    const a = std.testing.allocator;
    const raw = "Update the content insets when the available layout changes so the confirmation screen stays usable in smartphone landscape.\n\nPreserve the existing portrait and tablet behavior.";
    const body = try normalizeBody(a, raw, 72);
    defer a.free(body);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var saw_blank = false;
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= 72);
        if (line.len == 0) saw_blank = true;
    }
    try std.testing.expect(saw_blank); // paragraph break preserved
}

test "normalizeBody reflows the model's uneven line breaks to the width" {
    const a = std.testing.allocator;
    // A paragraph the model broke at ~40 cols should be rejoined and rewrapped.
    const raw = "Update the content insets\nwhen the layout changes\nso the confirmation screen\nstays usable in landscape.";
    const body = try normalizeBody(a, raw, 72);
    defer a.free(body);
    // Reflowed: fewer, fuller lines, none over 72, and the first line should pack
    // more than the model's ~25-char break.
    var lines = std.mem.splitScalar(u8, body, '\n');
    const first = lines.next().?;
    try std.testing.expect(first.len > 40 and first.len <= 72);
}

test "normalizeBody keeps list items on their own lines" {
    const a = std.testing.allocator;
    const raw = "Change things:\n- first item\n- second item";
    const body = try normalizeBody(a, raw, 72);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\n- first item\n") != null);
}
