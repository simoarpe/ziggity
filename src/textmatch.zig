const std = @import("std");

/// Strip the remote prefix from a remote-tracking branch name so git's DWIM
/// checkout can create a local tracking branch: "origin/feature" -> "feature".
pub fn localNameForRemote(remote_name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, remote_name, '/')) |slash| {
        return remote_name[slash + 1 ..];
    }
    return remote_name;
}

/// lazygit-style file filtering: whitespace-separated terms must all match as
/// substrings, with smart case (a term is case-sensitive iff it has an
/// uppercase letter).
pub fn pathMatchesFilter(path: []const u8, filter: []const u8) bool {
    var terms = std.mem.tokenizeAny(u8, filter, " \t\r\n");
    while (terms.next()) |term| {
        if (!caseAwareContains(path, term)) return false;
    }
    return true;
}

fn caseAwareContains(haystack: []const u8, needle: []const u8) bool {
    if (containsAsciiUppercase(needle)) {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }
    return containsIgnoreCaseAscii(haystack, needle);
}

fn containsAsciiUppercase(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 'A' and byte <= 'Z') return true;
    }
    return false;
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

test "path filter follows lazygit substring matching" {
    try std.testing.expect(pathMatchesFilter("src/App.zig", "app"));
    try std.testing.expect(pathMatchesFilter("src/App.zig", "App"));
    try std.testing.expect(!pathMatchesFilter("src/App.zig", "APP"));
    try std.testing.expect(pathMatchesFilter("README.md", "read"));
    try std.testing.expect(pathMatchesFilter("integration-testing", "int test"));
    try std.testing.expect(pathMatchesFilter("integration-testing", "test int"));
    try std.testing.expect(!pathMatchesFilter("integration-testing", "int missing"));
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "model"));
    try std.testing.expect(pathMatchesFilter("src/main.zig", ""));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "  \t  "));
}

test "local name for remote strips the remote prefix" {
    try std.testing.expectEqualStrings("feature", localNameForRemote("origin/feature"));
    try std.testing.expectEqualStrings("feat/x", localNameForRemote("origin/feat/x"));
    try std.testing.expectEqualStrings("solo", localNameForRemote("solo"));
}
