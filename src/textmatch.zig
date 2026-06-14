const std = @import("std");

/// Strip the remote prefix from a remote-tracking branch name so git's DWIM
/// checkout can create a local tracking branch: "origin/feature" -> "feature".
pub fn localNameForRemote(remote_name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, remote_name, '/')) |slash| {
        return remote_name[slash + 1 ..];
    }
    return remote_name;
}

/// lazygit-style file filtering, made fuzzy: each whitespace-separated term
/// must appear in the path as a smart-case subsequence (its characters in
/// order, not necessarily contiguous). A term is case-sensitive iff it has an
/// uppercase letter.
pub fn pathMatchesFilter(path: []const u8, filter: []const u8) bool {
    var terms = std.mem.tokenizeAny(u8, filter, " \t\r\n");
    while (terms.next()) |term| {
        if (!fuzzySubsequence(path, term)) return false;
    }
    return true;
}

fn fuzzySubsequence(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const sensitive = containsAsciiUppercase(needle);
    var h: usize = 0;
    for (needle) |target| {
        var found = false;
        while (h < haystack.len) {
            const c = haystack[h];
            h += 1;
            const eq = if (sensitive) c == target else std.ascii.toLower(c) == std.ascii.toLower(target);
            if (eq) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn containsAsciiUppercase(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 'A' and byte <= 'Z') return true;
    }
    return false;
}

test "path filter matches fuzzy subsequences with smart case" {
    // Contiguous substrings still match.
    try std.testing.expect(pathMatchesFilter("src/App.zig", "app"));
    try std.testing.expect(pathMatchesFilter("src/App.zig", "App"));
    try std.testing.expect(!pathMatchesFilter("src/App.zig", "APP"));
    try std.testing.expect(pathMatchesFilter("README.md", "read"));
    // Whitespace-separated terms each match independently (any order).
    try std.testing.expect(pathMatchesFilter("integration-testing", "int test"));
    try std.testing.expect(pathMatchesFilter("integration-testing", "test int"));
    try std.testing.expect(!pathMatchesFilter("integration-testing", "int missing"));
    // Non-contiguous subsequences now match (the fuzzy part).
    try std.testing.expect(pathMatchesFilter("src/main.zig", "mnzig"));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "smz"));
    // Characters must still appear in order.
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "zigm"));
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "model"));
    // Empty / whitespace filters match everything.
    try std.testing.expect(pathMatchesFilter("src/main.zig", ""));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "  \t  "));
}

test "local name for remote strips the remote prefix" {
    try std.testing.expectEqualStrings("feature", localNameForRemote("origin/feature"));
    try std.testing.expectEqualStrings("feat/x", localNameForRemote("origin/feat/x"));
    try std.testing.expectEqualStrings("solo", localNameForRemote("solo"));
}
