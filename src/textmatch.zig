const std = @import("std");

/// Strip the remote prefix from a remote-tracking branch name so git's DWIM
/// checkout can create a local tracking branch: "origin/feature" -> "feature".
pub fn localNameForRemote(remote_name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, remote_name, '/')) |slash| {
        return remote_name[slash + 1 ..];
    }
    return remote_name;
}

/// Fuzzy file filtering: each whitespace-separated term
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

/// Rank a completion candidate (a ref name) against what the user has typed so
/// far, for the checkout-by-name suggestion list. Smart-case: case-insensitive
/// unless `needle` contains an uppercase letter. Returns null when it doesn't
/// match; otherwise a score where LOWER sorts first: a prefix match beats an
/// interior substring, which beats a scattered subsequence, with ties broken so
/// shorter (closer) names come first.
pub fn suggestionRank(candidate: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    const sensitive = containsAsciiUppercase(needle);
    if (hasPrefix(candidate, needle, sensitive)) return candidate.len;
    if (substringIndex(candidate, needle, sensitive)) |off|
        return 1_000_000 + off * 4096 + candidate.len;
    if (fuzzySubsequence(candidate, needle)) return 2_000_000_000 + candidate.len;
    return null;
}

fn eqSmart(a: u8, b: u8, sensitive: bool) bool {
    return if (sensitive) a == b else std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn hasPrefix(candidate: []const u8, needle: []const u8, sensitive: bool) bool {
    if (needle.len > candidate.len) return false;
    for (needle, 0..) |c, i| {
        if (!eqSmart(candidate[i], c, sensitive)) return false;
    }
    return true;
}

fn substringIndex(candidate: []const u8, needle: []const u8, sensitive: bool) ?usize {
    if (needle.len > candidate.len) return null;
    var i: usize = 0;
    while (i + needle.len <= candidate.len) : (i += 1) {
        if (hasPrefix(candidate[i..], needle, sensitive)) return i;
    }
    return null;
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

test "suggestion rank orders prefix before substring before subsequence" {
    // A prefix match ranks ahead of an interior substring of the same needle.
    const pfx = suggestionRank("feature/login", "feat").?;
    const sub = suggestionRank("new-feature", "feat").?;
    const seq = suggestionRank("fast-elevator-atlas-time", "feat").?;
    try std.testing.expect(pfx < sub);
    try std.testing.expect(sub < seq);
    // Smart case: a lowercase needle matches any case; an uppercase letter makes
    // it case-sensitive.
    try std.testing.expect(suggestionRank("Origin/Main", "main") != null);
    try std.testing.expect(suggestionRank("origin/main", "Main") == null);
    // Non-matches return null; an empty needle offers no suggestions.
    try std.testing.expect(suggestionRank("develop", "xyz") == null);
    try std.testing.expect(suggestionRank("develop", "") == null);
    // Shorter candidates win ties (both prefix matches of "ma").
    const short = suggestionRank("main", "ma").?;
    const long = suggestionRank("master-of-none", "ma").?;
    try std.testing.expect(short < long);
}

test "local name for remote strips the remote prefix" {
    try std.testing.expectEqualStrings("feature", localNameForRemote("origin/feature"));
    try std.testing.expectEqualStrings("feat/x", localNameForRemote("origin/feat/x"));
    try std.testing.expectEqualStrings("solo", localNameForRemote("solo"));
}
