const std = @import("std");

/// Strip the remote prefix from a remote-tracking branch name so git's DWIM
/// checkout can create a local tracking branch: "origin/feature" -> "feature".
pub fn localNameForRemote(remote_name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, remote_name, '/')) |slash| {
        return remote_name[slash + 1 ..];
    }
    return remote_name;
}

/// How the live `/` filter matches each term against a name.
/// - `.substring` (the default, as in the referenced client): the term must
///   appear as a contiguous run, so "di" keeps "diff" but not "android".
/// - `.fuzzy`: the term's characters must appear in order but not necessarily
///   adjacent, so "di" also keeps "android" (an interior d...i).
pub const FilterMode = enum { substring, fuzzy };

/// Whether `path` passes `filter` under `mode`: every whitespace-separated term
/// must match (in any order). Both modes are smart case, a term is
/// case-sensitive iff it has an uppercase letter. An empty filter matches
/// everything.
pub fn pathMatchesFilter(path: []const u8, filter: []const u8, mode: FilterMode) bool {
    var terms = std.mem.tokenizeAny(u8, filter, " \t\r\n");
    while (terms.next()) |term| {
        const ok = switch (mode) {
            .substring => smartCaseContains(path, term),
            .fuzzy => fuzzySubsequence(path, term),
        };
        if (!ok) return false;
    }
    return true;
}

/// Whether `needle` occurs in `haystack` as a contiguous substring. Smart-case:
/// case-insensitive unless `needle` has an uppercase letter, then that term is
/// matched case-sensitively. An empty needle matches.
fn smartCaseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const sensitive = containsAsciiUppercase(needle);
    return substringIndex(haystack, needle, sensitive) != null;
}

/// The byte offset of the next occurrence of `needle` in `haystack` at or after
/// `from`, smart-case (case-insensitive unless `needle` has an uppercase
/// letter). Null when there is none or `needle` is empty. Used by the help
/// overlay's find-and-highlight search.
pub fn findSmart(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    const sensitive = containsAsciiUppercase(needle);
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (hasPrefix(haystack[i..], needle, sensitive)) return i;
    }
    return null;
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

test "path filter matches smart-case substrings, each whitespace term" {
    // Contiguous substrings match, with smart case.
    try std.testing.expect(pathMatchesFilter("src/App.zig", "app", .substring));
    try std.testing.expect(pathMatchesFilter("src/App.zig", "App", .substring));
    try std.testing.expect(!pathMatchesFilter("src/App.zig", "APP", .substring));
    try std.testing.expect(pathMatchesFilter("README.md", "read", .substring));
    // Whitespace-separated terms each match independently (any order).
    try std.testing.expect(pathMatchesFilter("integration-testing", "int test", .substring));
    try std.testing.expect(pathMatchesFilter("integration-testing", "test int", .substring));
    try std.testing.expect(!pathMatchesFilter("integration-testing", "int missing", .substring));
    // Only contiguous substrings match: a scattered subsequence does not, so
    // "di" keeps "diff" but not "android-support".
    try std.testing.expect(pathMatchesFilter("diff", "di", .substring));
    try std.testing.expect(!pathMatchesFilter("android-support", "di", .substring));
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "mnzig", .substring));
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "smz", .substring));
    // Empty / whitespace filters match everything.
    try std.testing.expect(pathMatchesFilter("src/main.zig", "", .substring));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "  \t  ", .substring));
}

test "path filter in fuzzy mode matches scattered subsequences" {
    // Fuzzy mode accepts characters in order but not contiguous, so the loose
    // matches the substring mode rejects come back.
    try std.testing.expect(pathMatchesFilter("android-support", "di", .fuzzy));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "mnzig", .fuzzy));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "smz", .fuzzy));
    // Order still matters, and smart case still applies.
    try std.testing.expect(!pathMatchesFilter("src/main.zig", "zigm", .fuzzy));
    try std.testing.expect(!pathMatchesFilter("src/App.zig", "APP", .fuzzy));
    // Each whitespace term matches independently; empty matches everything.
    try std.testing.expect(pathMatchesFilter("integration-testing", "itg tst", .fuzzy));
    try std.testing.expect(pathMatchesFilter("src/main.zig", "", .fuzzy));
}

test "findSmart locates occurrences with smart case" {
    try std.testing.expectEqual(@as(?usize, 0), findSmart("diff", "di", 0));
    try std.testing.expectEqual(@as(?usize, 3), findSmart("android", "ro", 0));
    // Searching from past the first hit finds the next.
    try std.testing.expectEqual(@as(?usize, 4), findSmart("a-b-a", "a", 1));
    try std.testing.expectEqual(@as(?usize, null), findSmart("a-b-a", "a", 5));
    // Smart case: lowercase matches any case; an uppercase letter is strict.
    try std.testing.expectEqual(@as(?usize, 0), findSmart("Push", "push", 0));
    try std.testing.expectEqual(@as(?usize, null), findSmart("push", "Push", 0));
    try std.testing.expectEqual(@as(?usize, null), findSmart("abc", "", 0));
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
