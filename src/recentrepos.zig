//! Persistent "recently opened repositories" list backing the ctrl+r switcher.
//!
//! Stored as plain text, one absolute repository path per line, most-recent
//! first, under the XDG state directory (`$XDG_STATE_HOME/ziggity/recent`, else
//! `$HOME/.local/state/ziggity/recent`; on Windows `%LOCALAPPDATA%\ziggity`).
//! The file is small, human-readable, and safe to edit or delete by hand.
//!
//! Every write is best-effort: a failure to persist never breaks the app, it
//! just means the list does not update this time. Callers own everything
//! `load` and `currentBranch` return and free it with `freeList` / the
//! allocator.
const std = @import("std");
const builtin = @import("builtin");

const Environ = std.process.Environ.Map;

/// Cap on remembered repositories. Old entries fall off the end.
const max_entries = 50;
/// The state file never grows large; this bounds a corrupt/huge file read.
const read_limit = 256 * 1024;

const empty: [][]u8 = &.{};

/// The directory that holds the `recent` file (caller frees). Null when no
/// suitable home/state location is configured in the environment.
fn stateDir(allocator: std.mem.Allocator, environ: *Environ) !?[]u8 {
    if (environ.get("XDG_STATE_HOME")) |x| {
        if (x.len > 0) return try std.fs.path.join(allocator, &.{ x, "ziggity" });
    }
    if (builtin.os.tag == .windows) {
        if (environ.get("LOCALAPPDATA")) |la| {
            if (la.len > 0) return try std.fs.path.join(allocator, &.{ la, "ziggity" });
        }
    }
    if (environ.get("HOME")) |h| {
        if (h.len > 0) return try std.fs.path.join(allocator, &.{ h, ".local", "state", "ziggity" });
    }
    return null;
}

/// The `recent` file path (caller frees). Null when no state dir is available.
fn filePath(allocator: std.mem.Allocator, environ: *Environ) !?[]u8 {
    const dir = (try stateDir(allocator, environ)) orelse return null;
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "recent" });
}

/// Free a list returned by `load`.
pub fn freeList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |p| allocator.free(p);
    if (list.len > 0) allocator.free(list);
}

/// Load the remembered paths, most-recent first. Best-effort: a missing or
/// unreadable file yields an empty list. Caller owns the result (`freeList`).
pub fn load(allocator: std.mem.Allocator, io: std.Io, environ: *Environ) [][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    defer list.deinit(allocator);

    const fp = (filePath(allocator, environ) catch null) orelse return empty;
    defer allocator.free(fp);

    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, fp, allocator, .limited(read_limit)) catch return empty;
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const dup = allocator.dupe(u8, trimmed) catch continue;
        list.append(allocator, dup) catch {
            allocator.free(dup);
            continue;
        };
    }
    return list.toOwnedSlice(allocator) catch empty;
}

/// Read `repo`'s current branch straight from its `HEAD` (no `git` subprocess),
/// following the pointer when `.git` is a file (worktree/submodule). Returns the
/// branch name, a short hash when detached, or null when it cannot be read.
/// Caller frees.
pub fn currentBranch(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) ?[]u8 {
    const dotgit = std.fs.path.join(allocator, &.{ repo, ".git" }) catch return null;
    defer allocator.free(dotgit);

    // `.git` is a regular file ("gitdir: <path>") for linked worktrees and
    // submodules; otherwise it is the git directory itself.
    if (std.Io.Dir.readFileAlloc(.cwd(), io, dotgit, allocator, .limited(read_limit))) |raw| {
        defer allocator.free(raw);
        const marker = "gitdir:";
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (!std.mem.startsWith(u8, t, marker)) return null;
        const rel = std.mem.trim(u8, t[marker.len..], " \t\r\n");
        const gitdir = if (std.fs.path.isAbsolute(rel))
            allocator.dupe(u8, rel) catch return null
        else
            std.fs.path.join(allocator, &.{ repo, rel }) catch return null;
        defer allocator.free(gitdir);
        return headBranch(allocator, io, gitdir);
    } else |_| {
        // Reading `.git` failed because it is a directory: read `.git/HEAD`.
        return headBranch(allocator, io, dotgit);
    }
}

fn headBranch(allocator: std.mem.Allocator, io: std.Io, gitdir: []const u8) ?[]u8 {
    const head_path = std.fs.path.join(allocator, &.{ gitdir, "HEAD" }) catch return null;
    defer allocator.free(head_path);
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, head_path, allocator, .limited(read_limit)) catch return null;
    defer allocator.free(bytes);
    const ref = parseHeadRef(bytes) orelse return null;
    return allocator.dupe(u8, ref) catch null;
}

/// The display ref from `HEAD` contents: the branch name for a symbolic ref, a
/// short object id when detached, or null when unusable. Returns a slice into
/// `bytes`.
fn parseHeadRef(bytes: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, bytes, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, t, prefix)) {
        const name = t[prefix.len..];
        return if (name.len == 0) null else name;
    }
    // Detached HEAD: a raw object id. Show it short, as git does.
    if (t.len >= 7) return t[0..7];
    return null;
}

/// Record `repo` as the most-recent entry: move it to the front, drop any
/// duplicate, and cap the list. Best-effort; failures are silently ignored.
pub fn record(allocator: std.mem.Allocator, io: std.Io, environ: *Environ, repo: []const u8) void {
    if (repo.len == 0) return;
    const list = load(allocator, io, environ);
    defer freeList(allocator, list);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    recordOrder(allocator, list, repo, &out);
    writeList(allocator, io, environ, out.items);
}

/// The list order after recording `repo`: it moves to the front, any duplicate
/// is dropped, and the result is capped at `max_entries`. Appends borrowed
/// slices (from `repo`/`existing`) into `out`.
fn recordOrder(allocator: std.mem.Allocator, existing: []const []const u8, repo: []const u8, out: *std.ArrayList([]const u8)) void {
    out.append(allocator, repo) catch return;
    for (existing) |p| {
        if (std.mem.eql(u8, p, repo)) continue;
        if (out.items.len >= max_entries) break;
        out.append(allocator, p) catch break;
    }
}

/// Drop `repo` from the list if present. Best-effort.
pub fn remove(allocator: std.mem.Allocator, io: std.Io, environ: *Environ, repo: []const u8) void {
    const list = load(allocator, io, environ);
    defer freeList(allocator, list);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    for (list) |p| {
        if (std.mem.eql(u8, p, repo)) continue;
        out.append(allocator, p) catch return;
    }
    writeList(allocator, io, environ, out.items);
}

fn writeList(allocator: std.mem.Allocator, io: std.Io, environ: *Environ, items: []const []const u8) void {
    const dir = (stateDir(allocator, environ) catch null) orelse return;
    defer allocator.free(dir);
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch return;

    const fp = std.fs.path.join(allocator, &.{ dir, "recent" }) catch return;
    defer allocator.free(fp);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (items) |p| {
        buf.appendSlice(allocator, p) catch return;
        buf.append(allocator, '\n') catch return;
    }
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = fp, .data = buf.items }) catch return;
}

const testing = std.testing;

test "parseHeadRef reads a branch, short-hashes a detached HEAD, rejects junk" {
    try testing.expectEqualStrings("main", parseHeadRef("ref: refs/heads/main\n").?);
    try testing.expectEqualStrings("feature/x", parseHeadRef("ref: refs/heads/feature/x").?);
    // Detached HEAD is a raw object id, shown short like git does.
    try testing.expectEqualStrings("0123456", parseHeadRef("0123456789abcdef0123456789abcdef01234567\n").?);
    try testing.expect(parseHeadRef("ref: refs/heads/") == null);
    try testing.expect(parseHeadRef("   \n") == null);
}

test "recordOrder moves to front, dedups, and caps the list" {
    const a = testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);

    // A repo already present is moved to the front, not duplicated.
    const existing = [_][]const u8{ "/a", "/b", "/c" };
    recordOrder(a, &existing, "/b", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("/b", out.items[0]);
    try testing.expectEqualStrings("/a", out.items[1]);
    try testing.expectEqualStrings("/c", out.items[2]);

    // The cap holds: recording onto a full list keeps exactly max_entries.
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(a);
    var bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (bufs.items) |b| a.free(b);
        bufs.deinit(a);
    }
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        const s = try std.fmt.allocPrint(a, "/repo{d}", .{i});
        try bufs.append(a, s);
        try full.append(a, s);
    }
    var capped: std.ArrayList([]const u8) = .empty;
    defer capped.deinit(a);
    recordOrder(a, full.items, "/fresh", &capped);
    try testing.expectEqual(max_entries, capped.items.len);
    try testing.expectEqualStrings("/fresh", capped.items[0]);
}
