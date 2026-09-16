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
    /// Include ziggity's built-in soft style guidance (imperative mood, no
    /// trailing period, follow recent-commit conventions for the subject; don't
    /// restate the subject and explain motivation for the body). From
    /// `ai_commit_style_defaults`. When false, only the hard output contract and
    /// the length/wrap numbers remain ours, and any custom instructions file is
    /// the sole style voice. The contract and 50/72 numbers always apply.
    style_defaults: bool = true,
};

/// Cap on how much of the staged diff we put in a prompt, so a huge staged
/// change doesn't send megabytes to the provider.
const max_diff_bytes: usize = 16 * 1024;

/// Max staged file names listed in the prompt; beyond this the rest are summarized
/// as a count, so a commit that stages thousands of files (e.g. a vendored
/// toolchain) doesn't push a megabyte of paths into the prompt.
const max_staged_files_listed: usize = 1024;

/// Cap a newline-separated file list to the first `max_staged_files_listed`
/// entries, appending an "... and N more files" line. Owned result.
fn capFileList(allocator: std.mem.Allocator, list: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, list, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    var total: usize = 1;
    for (trimmed) |c| {
        if (c == '\n') total += 1;
    }
    if (total <= max_staged_files_listed) return allocator.dupe(u8, trimmed);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    var i: usize = 0;
    while (i < max_staged_files_listed) : (i += 1) {
        const line = it.next() orelse break;
        if (i > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    var nbuf: [80]u8 = undefined;
    const more = std.fmt.bufPrint(&nbuf, "\n... and {d} more files", .{total - max_staged_files_listed}) catch "\n... and more files";
    try out.appendSlice(allocator, more);
    return allocator.dupe(u8, out.items);
}

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
    const files_listed = try capFileList(allocator, files);
    defer allocator.free(files_listed);
    const subjects = try git.recentSubjects(10);
    defer allocator.free(subjects);

    const ctx = Context{
        .staged_diff = diff,
        .staged_files = files_listed,
        .recent_subjects = subjects,
        .current_title = current_title,
    };

    // Optional per-project / global commit-instructions file, scoped to this field.
    const raw_instr = loadInstructions(allocator, git, "commit-instructions.md");
    defer if (raw_instr) |r| allocator.free(r);
    const instr = if (raw_instr) |r| try composeFieldInstructions(allocator, r, field) else try allocator.dupe(u8, "");
    defer allocator.free(instr);

    const prompt = switch (field) {
        .title => try buildTitlePrompt(allocator, ctx, limits.title_max, limits.style_defaults, instr),
        .description => try buildDescPrompt(allocator, ctx, limits.body_wrap, limits.style_defaults, instr),
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

// ---- Custom commit instructions (optional user file) ----------------------

/// A commit-instructions file is a prompt fragment, not data; bound its size.
const max_instructions_bytes: usize = 16 * 1024;

/// Which prompt a section of the instructions file applies to. Text with no
/// heading is `shared` (goes to both title and body).
const Bucket = enum { shared, title, body };

/// The global config directory ziggity looks in, mirroring the state-dir logic
/// in recentrepos: `$XDG_CONFIG_HOME/ziggity`, else on Windows `%APPDATA%\ziggity`,
/// else `$HOME/.config/ziggity`. Caller frees. Null when no home is configured.
fn configDir(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) !?[]u8 {
    if (environ.get("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return try std.fs.path.join(allocator, &.{ x, "ziggity" });
    }
    if (@import("builtin").os.tag == .windows) {
        if (environ.get("APPDATA")) |a| {
            if (a.len > 0) return try std.fs.path.join(allocator, &.{ a, "ziggity" });
        }
    }
    if (environ.get("HOME")) |h| {
        if (h.len > 0) return try std.fs.path.join(allocator, &.{ h, ".config", "ziggity" });
    }
    return null;
}

/// Load a custom instructions file (`filename`, e.g. "commit-instructions.md" or
/// "pr-instructions.md"), if any. Whole-file resolution, first match wins (no
/// merge): the repo file completely overrides the global one.
///   1. <repo>/.ziggity/<filename>
///   2. <config dir>/<filename>   (see `configDir`)
/// Returns owned bytes, or null when neither exists or is readable.
pub fn loadInstructions(allocator: std.mem.Allocator, git: *git_mod.Git, filename: []const u8) ?[]u8 {
    if (std.fs.path.join(allocator, &.{ git.root, ".ziggity", filename })) |repo_path| {
        defer allocator.free(repo_path);
        if (std.Io.Dir.readFileAlloc(.cwd(), git.io, repo_path, allocator, .limited(max_instructions_bytes))) |bytes| {
            return bytes;
        } else |_| {}
    } else |_| {}
    if (configDir(allocator, git.environ) catch null) |dir| {
        defer allocator.free(dir);
        if (std.fs.path.join(allocator, &.{ dir, filename })) |gpath| {
            defer allocator.free(gpath);
            if (std.Io.Dir.readFileAlloc(.cwd(), git.io, gpath, allocator, .limited(max_instructions_bytes))) |bytes| {
                return bytes;
            } else |_| {}
        } else |_| {}
    }
    return null;
}

/// Recognize a section-heading line, or null for ordinary content. Accepts a
/// markdown heading (`# Title`, `## Subject`) or a `Label:` line, case-insensitive:
/// Title/Titles/Subject -> title, Body/Description -> body, Shared/Both -> shared.
fn headingBucket(line: []const u8) ?Bucket {
    var s = std.mem.trim(u8, line, " \t\r");
    if (s.len == 0) return null;
    var had_hash = false;
    while (s.len > 0 and s[0] == '#') : (s = s[1..]) had_hash = true;
    s = std.mem.trimStart(u8, s, " \t");
    var is_label = false;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
        // A "Label:" heading has nothing but spaces after the colon; a prose line
        // like "Explain why: it does X" keeps content there and is not a heading.
        if (std.mem.trim(u8, s[c + 1 ..], " \t").len == 0) {
            s = s[0..c];
            is_label = true;
        }
    }
    if (!had_hash and !is_label) return null;
    s = std.mem.trim(u8, s, " \t");
    if (std.ascii.eqlIgnoreCase(s, "title") or std.ascii.eqlIgnoreCase(s, "titles") or std.ascii.eqlIgnoreCase(s, "subject")) return .title;
    if (std.ascii.eqlIgnoreCase(s, "body") or std.ascii.eqlIgnoreCase(s, "description")) return .body;
    if (std.ascii.eqlIgnoreCase(s, "shared") or std.ascii.eqlIgnoreCase(s, "both")) return .shared;
    return null;
}

/// Build the instruction text for `field` from a raw commit-instructions file:
/// the shared (pre/unheaded) lines plus the lines under the matching Title/Body
/// section, in file order. Owned result, trimmed, possibly empty. Handles repeated
/// or interleaved headings line by line.
pub fn composeFieldInstructions(allocator: std.mem.Allocator, raw: []const u8, field: Field) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var cur: Bucket = .shared;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (headingBucket(line)) |b| {
            cur = b;
            continue; // the heading itself is a marker, not content
        }
        const want = cur == .shared or
            (field == .title and cur == .title) or
            (field == .description and cur == .body);
        if (!want) continue;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    return allocator.dupe(u8, std.mem.trim(u8, out.items, " \t\r\n"));
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

pub fn buildTitlePrompt(allocator: std.mem.Allocator, ctx: Context, title_max: usize, style_defaults: bool, instructions: []const u8) ![]u8 {
    const max = if (title_max == 0) 50 else title_max;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Write a git commit SUBJECT LINE for the staged changes below.\n\nRules:\n");
    // Hard output contract + length: always ours (the parser keeps the first line
    // only, so a preamble would corrupt the title).
    try out.appendSlice(allocator, "- Output ONLY the subject line. No quotes, no markdown, no code fences, no preamble or explanation.\n");
    var nbuf: [96]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&nbuf, "- At most {d} characters when reasonable; never wrap to multiple lines.\n", .{max}) catch "- Keep the subject short; never wrap to multiple lines.\n");
    // Soft style defaults: gated by `ai_commit_style_defaults` so a custom file
    // can be the sole style voice when it is turned off.
    if (style_defaults) {
        try out.appendSlice(allocator,
            \\- Imperative mood, e.g. "Fix wallet layout in landscape" not "Fixed the wallet layout.".
            \\- No trailing period unless the recent subjects clearly use one.
            \\- Follow the conventions visible in the recent subjects (prefixes, casing) when there is a clear pattern.
            \\
        );
    }
    // Project instructions come last (after our defaults) so they win by recency
    // and can override the soft rules above; the hard contract is re-asserted at
    // the tail so it always has the final word.
    try appendInstructions(&out, allocator, instructions);
    try out.appendSlice(allocator, "\nRecent commit subjects (for style):\n");
    try out.appendSlice(allocator, ctx.recent_subjects);
    try out.appendSlice(allocator, "\nStaged files:\n");
    try out.appendSlice(allocator, ctx.staged_files);
    try out.appendSlice(allocator, "\nStaged diff:\n");
    try appendDiff(&out, allocator, ctx.staged_diff);
    try out.appendSlice(allocator, "\n\nOutput only the single subject line, nothing else.\nSubject line:");
    return out.toOwnedSlice(allocator);
}

/// Append the project's custom instructions as a distinct, authoritative section,
/// or nothing when there are none.
fn appendInstructions(out: *std.ArrayList(u8), allocator: std.mem.Allocator, instructions: []const u8) !void {
    if (instructions.len == 0) return;
    try out.appendSlice(allocator, "\nProject commit instructions (follow these; they take precedence over the defaults above):\n");
    try out.appendSlice(allocator, instructions);
    try out.appendSlice(allocator, "\n");
}

pub fn buildDescPrompt(allocator: std.mem.Allocator, ctx: Context, body_wrap: usize, style_defaults: bool, instructions: []const u8) ![]u8 {
    const wrap = if (body_wrap == 0) 72 else body_wrap;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Write a git commit MESSAGE BODY (description) for the staged changes below.\n\nRules:\n");
    // Hard output contract: always ours.
    try out.appendSlice(allocator, "- Output ONLY the body. No subject line, no quotes, no markdown headings, no code fences, no preamble.\n");
    // Soft style defaults: gated by `ai_commit_style_defaults`.
    if (style_defaults) {
        try out.appendSlice(allocator, "- Do not repeat or restate the subject.\n");
        try out.appendSlice(allocator, "- Explain the motivation and the resulting behavior, not a line-by-line restatement of the diff.\n");
    }
    // Wrap width is ours and also code-enforced (normalizeBody), so it stays even
    // when style defaults are off.
    var nbuf: [96]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&nbuf, "- Plain-text git style, wrapped at {d} columns, short paragraphs separated by a blank line.\n", .{wrap}) catch "- Plain-text git style, wrapped at 72 columns, short paragraphs separated by a blank line.\n");
    try appendInstructions(&out, allocator, instructions);
    if (std.mem.trim(u8, ctx.current_title, " \t\r\n").len > 0) {
        try out.appendSlice(allocator, "\nThe commit subject is: ");
        try out.appendSlice(allocator, ctx.current_title);
        try out.appendSlice(allocator, "\nWrite a body that complements it.\n");
    }
    try out.appendSlice(allocator, "\nRecent commit subjects (for style):\n");
    try out.appendSlice(allocator, ctx.recent_subjects);
    try out.appendSlice(allocator, "\nStaged files:\n");
    try out.appendSlice(allocator, ctx.staged_files);
    try out.appendSlice(allocator, "\nStaged diff:\n");
    try appendDiff(&out, allocator, ctx.staged_diff);
    try out.appendSlice(allocator, "\n\nOutput only the body, nothing else.\nBody:");
    return out.toOwnedSlice(allocator);
}

// ---- Pull request document generation -------------------------------------

/// A generated document: a title line plus a markdown body. Owned; free both.
pub const DocResult = struct {
    title: []u8,
    body: []u8,

    pub fn deinit(self: *DocResult, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

/// The git context a PR document is generated from.
pub const DocContext = struct {
    /// What the changes are, for the prompt header (e.g. "branch `feature` against
    /// `origin/main`" or "commit abc1234").
    subject: []const u8,
    /// Commit list (see git.refLog): one "- <subject>" per commit plus bodies.
    commit_log: []const u8,
    /// The diff (see git.refDiff), already bounded; only its first 16 KB is used.
    diff: []const u8,
};

/// Cap on the commit-log block put in the prompt (a long branch can have many).
const max_commit_log_bytes: usize = 8 * 1024;

/// Generate a pull request title + markdown body from `ctx`, honoring an optional
/// `pr-instructions.md` (repo overrides global; `# Title` / `# Body` sections
/// route to the title vs the body). One AI call returns "title\n\n<body>", which
/// is split. Runs off the UI thread. Caller owns the result.
pub fn generatePrDoc(allocator: std.mem.Allocator, git: *git_mod.Git, command: []const u8, ctx: DocContext) !DocResult {
    const raw_instr = loadInstructions(allocator, git, "pr-instructions.md");
    defer if (raw_instr) |r| allocator.free(r);
    const title_instr = if (raw_instr) |r| try composeFieldInstructions(allocator, r, .title) else try allocator.dupe(u8, "");
    defer allocator.free(title_instr);
    const body_instr = if (raw_instr) |r| try composeFieldInstructions(allocator, r, .description) else try allocator.dupe(u8, "");
    defer allocator.free(body_instr);

    const prompt = try buildPrPrompt(allocator, ctx, title_instr, body_instr);
    defer allocator.free(prompt);

    var res = git.runAiCommand(command, "pr", prompt) catch return GenError.AiCommandFailed;
    defer res.deinit(allocator);
    if (!res.ok()) return GenError.AiCommandFailed;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return GenError.EmptyResponse;
    return splitTitleBody(allocator, out);
}

fn buildPrPrompt(allocator: std.mem.Allocator, ctx: DocContext, title_instr: []const u8, body_instr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Write a GitHub pull request TITLE and DESCRIPTION for the changes below.\n\nRules:\n");
    try out.appendSlice(allocator,
        \\- First line: the PR title only — a concise, imperative summary. Plain text, no markdown, no quotes, no "Title:" prefix.
        \\- Then one blank line.
        \\- Then the description in GitHub-flavored markdown: a short summary of what the PR does and why, then the notable changes. Be concise; do not restate the diff line by line.
        \\- Output only the title line, a blank line, and the body. No preamble, no code fences around the whole thing.
        \\
    );
    if (title_instr.len > 0) {
        try out.appendSlice(allocator, "\nTitle guidance (follow it): ");
        try out.appendSlice(allocator, title_instr);
        try out.appendSlice(allocator, "\n");
    }
    if (body_instr.len > 0) {
        try out.appendSlice(allocator, "\nDescription guidance (follow it): ");
        try out.appendSlice(allocator, body_instr);
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "\nThe changes are ");
    try out.appendSlice(allocator, ctx.subject);
    try out.appendSlice(allocator, ".\n\nCommits:\n");
    const log = if (ctx.commit_log.len > max_commit_log_bytes) ctx.commit_log[0..max_commit_log_bytes] else ctx.commit_log;
    try out.appendSlice(allocator, log);
    try out.appendSlice(allocator, "\nDiff:\n");
    try appendDiff(&out, allocator, ctx.diff);
    try out.appendSlice(allocator, "\n\nTitle line, blank line, then the markdown body:\n");
    return out.toOwnedSlice(allocator);
}

/// Split a "title\n\n<body>" response into an owned title + body. The first
/// non-empty line is the title (a leading markdown `#` or `Title:` and wrapping
/// quotes are stripped); everything after it is the body.
fn splitTitleBody(allocator: std.mem.Allocator, out: []const u8) !DocResult {
    const nl = std.mem.indexOfScalar(u8, out, '\n') orelse out.len;
    var title = std.mem.trim(u8, out[0..nl], " \t\r");
    title = stripTitlePrefix(title);
    title = std.mem.trim(u8, stripWrappingQuotes(title), " \t");
    const rest = if (nl < out.len) std.mem.trim(u8, out[nl + 1 ..], " \t\r\n") else "";
    return DocResult{
        .title = try allocator.dupe(u8, title),
        .body = try allocator.dupe(u8, rest),
    };
}

/// Strip a leading markdown heading marker (`#`, `##`, …) or a `Title:` label from
/// a title line the model may have added despite the prompt.
fn stripTitlePrefix(line: []const u8) []const u8 {
    var s = std.mem.trimStart(u8, line, "#");
    s = std.mem.trimStart(u8, s, " \t");
    if (s.len >= 6 and std.ascii.eqlIgnoreCase(s[0..6], "title:")) {
        s = std.mem.trimStart(u8, s[6..], " \t");
    }
    return s;
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

test "composeFieldInstructions routes shared/title/body sections per field" {
    const a = std.testing.allocator;
    const raw =
        \\Use Conventional Commits with a scope.
        \\
        \\# Title
        \\Keep it under 60 characters.
        \\
        \\# Body
        \\Explain why, reference issues at the end.
    ;
    const t = try composeFieldInstructions(a, raw, .title);
    defer a.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "Conventional Commits") != null); // shared
    try std.testing.expect(std.mem.indexOf(u8, t, "under 60 characters") != null); // title section
    try std.testing.expect(std.mem.indexOf(u8, t, "reference issues") == null); // NOT the body section

    const b = try composeFieldInstructions(a, raw, .description);
    defer a.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "Conventional Commits") != null); // shared
    try std.testing.expect(std.mem.indexOf(u8, b, "reference issues") != null); // body section
    try std.testing.expect(std.mem.indexOf(u8, b, "under 60 characters") == null); // NOT the title section
}

test "splitTitleBody separates the title line from the markdown body" {
    const a = std.testing.allocator;
    {
        var r = try splitTitleBody(a, "Add dark mode toggle\n\n## Summary\nAdds a toggle.");
        defer r.deinit(a);
        try std.testing.expectEqualStrings("Add dark mode toggle", r.title);
        try std.testing.expectEqualStrings("## Summary\nAdds a toggle.", r.body);
    }
    { // strips a stray markdown "# " and wrapping quotes from the title
        var r = try splitTitleBody(a, "# \"Fix the crash\"\n\nBody here.");
        defer r.deinit(a);
        try std.testing.expectEqualStrings("Fix the crash", r.title);
        try std.testing.expectEqualStrings("Body here.", r.body);
    }
    { // strips a "Title:" label, tolerates a title-only response (empty body)
        var r = try splitTitleBody(a, "Title: Bump deps");
        defer r.deinit(a);
        try std.testing.expectEqualStrings("Bump deps", r.title);
        try std.testing.expectEqualStrings("", r.body);
    }
}

test "capFileList keeps a short list and summarizes a long one" {
    const a = std.testing.allocator;

    // Under the cap: returned as-is (trimmed of the trailing newline).
    const short = try capFileList(a, "a.zig\nb.zig\n");
    defer a.free(short);
    try std.testing.expectEqualStrings("a.zig\nb.zig", short);

    // 1500 names: keep the first 1024, summarize the remaining 476.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        var nb: [32]u8 = undefined;
        try buf.appendSlice(a, try std.fmt.bufPrint(&nb, "file{d}.txt\n", .{i}));
    }
    const capped = try capFileList(a, buf.items);
    defer a.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "file0.txt") != null); // first kept
    try std.testing.expect(std.mem.indexOf(u8, capped, "file1499.txt") == null); // tail dropped
    try std.testing.expect(std.mem.indexOf(u8, capped, "and 476 more files") != null); // 1500 - 1024
    var newlines: usize = 0;
    for (capped) |c| {
        if (c == '\n') newlines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1024), newlines); // 1024 names, then the summary line
}

test "composeFieldInstructions with no headings: everything is shared" {
    const a = std.testing.allocator;
    const raw = "No emoji. Mention the affected module.";
    const t = try composeFieldInstructions(a, raw, .title);
    defer a.free(t);
    const b = try composeFieldInstructions(a, raw, .description);
    defer a.free(b);
    try std.testing.expectEqualStrings(raw, t);
    try std.testing.expectEqualStrings(raw, b);
}

test "headingBucket recognizes markdown and label forms, ignores prose colons" {
    try std.testing.expectEqual(Bucket.title, headingBucket("# Title").?);
    try std.testing.expectEqual(Bucket.title, headingBucket("## Subject").?);
    try std.testing.expectEqual(Bucket.body, headingBucket("Body:").?);
    try std.testing.expectEqual(Bucket.body, headingBucket("Description:").?);
    try std.testing.expectEqual(Bucket.shared, headingBucket("# Shared").?);
    try std.testing.expect(headingBucket("Explain why: it fixes the crash") == null); // prose colon
    try std.testing.expect(headingBucket("Keep it short.") == null);
    try std.testing.expect(headingBucket("# Notes") == null); // unrecognized heading = content
}

test "buildTitlePrompt gates the style defaults and injects project instructions" {
    const a = std.testing.allocator;
    const ctx = Context{ .staged_diff = "diff", .staged_files = "f.zig", .recent_subjects = "Fix x" };

    // Defaults on, no custom file: our imperative rule is present.
    const p1 = try buildTitlePrompt(a, ctx, 50, true, "");
    defer a.free(p1);
    try std.testing.expect(std.mem.indexOf(u8, p1, "Imperative mood") != null);
    try std.testing.expect(std.mem.indexOf(u8, p1, "Output ONLY the subject line") != null); // hard contract
    try std.testing.expect(std.mem.indexOf(u8, p1, "Project commit instructions") == null);

    // Defaults off: the imperative rule is gone, contract + length stay.
    const p2 = try buildTitlePrompt(a, ctx, 50, false, "");
    defer a.free(p2);
    try std.testing.expect(std.mem.indexOf(u8, p2, "Imperative mood") == null);
    try std.testing.expect(std.mem.indexOf(u8, p2, "Output ONLY the subject line") != null);
    try std.testing.expect(std.mem.indexOf(u8, p2, "At most 50 characters") != null);

    // Custom instructions appear as an authoritative section, and the contract is
    // still re-asserted at the tail.
    const p3 = try buildTitlePrompt(a, ctx, 50, true, "Use Conventional Commits.");
    defer a.free(p3);
    try std.testing.expect(std.mem.indexOf(u8, p3, "Project commit instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, p3, "Use Conventional Commits.") != null);
    try std.testing.expect(std.mem.indexOf(u8, p3, "Output only the single subject line") != null); // tail re-assert
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
