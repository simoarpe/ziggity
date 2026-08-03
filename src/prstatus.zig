//! Pull/merge request status for local branches. The status is fetched via the
//! host's own CLI — `gh` for GitHub, `glab` for GitLab — which already handle
//! auth, then matched to local branches by head/source branch name. This module
//! is pure: the types plus the JSON parsers for each CLI's list output. The
//! fetch (git.zig), background wiring (app/tui), and rendering live elsewhere.
const std = @import("std");

pub const PrState = enum { open, draft, merged, closed };

/// Which host CLI (if any) can serve PR status for a remote URL: `gh` for
/// GitHub, `glab` for GitLab. Everything else (Gitea, Codeberg, Bitbucket, …)
/// has no supported CLI here, so it reports no status.
pub const Host = enum { github, gitlab, unsupported };

pub fn hostFromUrl(url: []const u8) Host {
    if (std.mem.indexOf(u8, url, "github") != null) return .github;
    if (std.mem.indexOf(u8, url, "gitlab") != null) return .gitlab;
    return .unsupported;
}

/// A branch's pull/merge request: its number and current state. No owned
/// memory, so it is a plain value in the per-branch status map.
pub const PrInfo = struct {
    number: u32,
    state: PrState,
};

/// One parsed list entry: the head/source branch the PR targets, plus its info.
/// `head` is owned by the caller's allocator.
pub const PrEntry = struct {
    head: []u8,
    info: PrInfo,
};

pub fn deinitEntries(allocator: std.mem.Allocator, entries: []PrEntry) void {
    for (entries) |e| allocator.free(e.head);
    allocator.free(entries);
}

/// When several PRs share one head branch, an active (open/draft) one wins over
/// a merged one, which wins over a closed one — the branch shows its liveliest PR.
fn priority(s: PrState) u8 {
    return switch (s) {
        .open, .draft => 3,
        .merged => 2,
        .closed => 1,
    };
}

/// Insert `entry` into `list`, keeping just the highest-priority PR per head
/// branch (see `priority`). Takes ownership of `entry.head` and frees it if a
/// same-head entry already wins.
fn upsert(allocator: std.mem.Allocator, list: *std.ArrayList(PrEntry), entry: PrEntry) !void {
    for (list.items) |*existing| {
        if (std.mem.eql(u8, existing.head, entry.head)) {
            if (priority(entry.info.state) > priority(existing.info.state)) existing.info = entry.info;
            allocator.free(entry.head);
            return;
        }
    }
    try list.append(allocator, entry);
}

const GitHubPr = struct {
    number: u32,
    headRefName: []const u8,
    state: []const u8, // OPEN | CLOSED | MERGED
    isDraft: bool = false,
    // A PR from a fork: its head branch lives in another repo, so its name must
    // not be matched to a local branch (e.g. a fork's "main" is not our "main").
    isCrossRepository: bool = false,
};

/// Parse `gh pr list --json number,headRefName,state,isDraft,isCrossRepository`
/// output. Cross-repository (fork) PRs are skipped — their head branch belongs
/// to another repo and would false-match a local branch of the same name.
pub fn parseGitHub(allocator: std.mem.Allocator, json: []const u8) ![]PrEntry {
    const parsed = std.json.parseFromSlice([]GitHubPr, allocator, json, .{ .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();

    var list: std.ArrayList(PrEntry) = .empty;
    errdefer {
        for (list.items) |e| allocator.free(e.head);
        list.deinit(allocator);
    }
    for (parsed.value) |pr| {
        if (pr.headRefName.len == 0 or pr.isCrossRepository) continue;
        const state: PrState = if (std.mem.eql(u8, pr.state, "MERGED"))
            .merged
        else if (std.mem.eql(u8, pr.state, "CLOSED"))
            .closed
        else if (pr.isDraft)
            .draft
        else
            .open;
        const head = try allocator.dupe(u8, pr.headRefName);
        try upsert(allocator, &list, .{ .head = head, .info = .{ .number = pr.number, .state = state } });
    }
    return list.toOwnedSlice(allocator);
}

const GitLabMr = struct {
    iid: u32,
    source_branch: []const u8,
    state: []const u8, // opened | closed | merged | locked
    draft: bool = false,
    // `project_id` is the target project; `source_branch` lives in
    // `source_project_id`. When they differ the MR comes from a fork, so its
    // branch name must not be matched to a local branch. Both default 0 (absent).
    project_id: u64 = 0,
    source_project_id: u64 = 0,
};

/// Parse `glab mr list -F json` output (raw GitLab merge-request objects).
/// Fork MRs (source project != target project) are skipped, same as GitHub's
/// cross-repository PRs.
pub fn parseGitLab(allocator: std.mem.Allocator, json: []const u8) ![]PrEntry {
    const parsed = std.json.parseFromSlice([]GitLabMr, allocator, json, .{ .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();

    var list: std.ArrayList(PrEntry) = .empty;
    errdefer {
        for (list.items) |e| allocator.free(e.head);
        list.deinit(allocator);
    }
    for (parsed.value) |mr| {
        if (mr.source_branch.len == 0) continue;
        // Skip fork MRs: both ids present and different means the source branch
        // is in another project.
        if (mr.project_id != 0 and mr.source_project_id != 0 and mr.project_id != mr.source_project_id) continue;
        const state: PrState = if (std.mem.eql(u8, mr.state, "merged"))
            .merged
        else if (std.mem.eql(u8, mr.state, "closed") or std.mem.eql(u8, mr.state, "locked"))
            .closed
        else if (mr.draft)
            .draft
        else
            .open;
        const head = try allocator.dupe(u8, mr.source_branch);
        try upsert(allocator, &list, .{ .head = head, .info = .{ .number = mr.iid, .state = state } });
    }
    return list.toOwnedSlice(allocator);
}

test "parseGitHub maps states and dedupes to the liveliest PR" {
    const a = std.testing.allocator;
    const json =
        \\[{"headRefName":"feature-a","isDraft":false,"number":10,"state":"OPEN","url":"x"},
        \\ {"headRefName":"feature-b","isDraft":true,"number":11,"state":"OPEN"},
        \\ {"headRefName":"old","isDraft":false,"number":7,"state":"MERGED"},
        \\ {"headRefName":"main","isDraft":false,"number":6,"state":"MERGED","isCrossRepository":true},
        \\ {"headRefName":"feature-a","isDraft":false,"number":3,"state":"CLOSED"}]
    ;
    const entries = try parseGitHub(a, json);
    defer deinitEntries(a, entries);
    // The fork PR (#6, head "main") is skipped, so no false match on a local main.
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |e| try std.testing.expect(!std.mem.eql(u8, e.head, "main"));
    // feature-a keeps the OPEN (#10), not the older CLOSED (#3).
    for (entries) |e| {
        if (std.mem.eql(u8, e.head, "feature-a")) {
            try std.testing.expectEqual(@as(u32, 10), e.info.number);
            try std.testing.expectEqual(PrState.open, e.info.state);
        } else if (std.mem.eql(u8, e.head, "feature-b")) {
            try std.testing.expectEqual(PrState.draft, e.info.state);
        } else if (std.mem.eql(u8, e.head, "old")) {
            try std.testing.expectEqual(PrState.merged, e.info.state);
        } else return error.UnexpectedHead;
    }
}

test "parseGitLab maps opened/merged/draft and source_branch" {
    const a = std.testing.allocator;
    const json =
        \\[{"iid":42,"source_branch":"wip","state":"opened","draft":true,"web_url":"x","project_id":1,"source_project_id":1},
        \\ {"iid":40,"source_branch":"done","state":"merged","draft":false},
        \\ {"iid":39,"source_branch":"live","state":"opened","draft":false},
        \\ {"iid":38,"source_branch":"main","state":"merged","draft":false,"project_id":1,"source_project_id":2}]
    ;
    const entries = try parseGitLab(a, json);
    defer deinitEntries(a, entries);
    // The fork MR (#38, source project 2 != target 1) is skipped.
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |e| try std.testing.expect(!std.mem.eql(u8, e.head, "main"));
    for (entries) |e| {
        if (std.mem.eql(u8, e.head, "wip")) {
            try std.testing.expectEqual(@as(u32, 42), e.info.number);
            try std.testing.expectEqual(PrState.draft, e.info.state);
        } else if (std.mem.eql(u8, e.head, "done")) {
            try std.testing.expectEqual(PrState.merged, e.info.state);
        } else if (std.mem.eql(u8, e.head, "live")) {
            try std.testing.expectEqual(PrState.open, e.info.state);
        } else return error.UnexpectedHead;
    }
}

test "parsers tolerate an empty list" {
    const a = std.testing.allocator;
    const gh = try parseGitHub(a, "[]");
    defer deinitEntries(a, gh);
    try std.testing.expectEqual(@as(usize, 0), gh.len);
    const gl = try parseGitLab(a, "[]");
    defer deinitEntries(a, gl);
    try std.testing.expectEqual(@as(usize, 0), gl.len);
}
