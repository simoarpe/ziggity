const std = @import("std");
const vaxis = @import("vaxis");

const config_mod = @import("config.zig");
const model = @import("model.zig");

pub const Action = enum {
    quit,
    refresh,
    move_up,
    move_down,
    focus_left,
    focus_right,
    scroll_left,
    scroll_right,
    toggle_main,
    toggle_staging_split,
    select,
    stage_all,
    edit_file,
    discard_selected,
    discard_all,
    stash_menu,
    start_file_filter,
    start_commit_filter,
    open_status_filter,
    start_commit,
    amend_commit,
    cherry_pick,
    reset_cherry_pick,
    tag_commit,
    open_pull_request,
    move_to_new_branch,
    conflict_menu,
    command_log,
    help,
    undo,
    copy_to_clipboard,
    open_browser,
    diff_mark,
    patch_menu,
    toggle_tree,
    new_branch,
    checkout_by_name,
    delete_branch,
    merge_branch,
    rebase_branch,
    rename_branch,
    fast_forward_branch,
    edit_remote,
    remove_remote,
    set_upstream,
    reset_commit,
    revert_commit,
    rebase_drop,
    rebase_squash,
    rebase_fixup,
    rebase_edit,
    rebase_reword,
    rebase_move_down,
    rebase_move_up,
    rebase_create_fixup,
    rebase_autosquash,
    mark_base,
    bisect_menu,
    range_select,
    fetch,
    pull,
    push,
    focus_status,
    focus_files,
    focus_branches,
    focus_commits,
    focus_stash,
    focus_main,
    prev_tab,
    next_tab,
    cancel,
    confirm,
    backspace,
    stash_pop,
    stash_drop,
};

/// Whether an action starts or could lead to a git mutation. While a
/// foreground op is in flight these are ignored (navigation stays live). Errs
/// toward gating: menu-openers (which lead to mutations) and clipboard/cherry
/// toggles count, since allowing them mid-op would be confusing. The allowed
/// set is pure navigation/inspection/quit.
/// Branch-management actions: they act on the selected branch. While the
/// Branches panel is drilled into a branch's sub-commits, the selection is a
/// commit, not a branch, so these don't apply and are suppressed.
pub fn isBranchManagement(self: Action) bool {
    return switch (self) {
        .new_branch,
        .delete_branch,
        .merge_branch,
        .rebase_branch,
        .rename_branch,
        .fast_forward_branch,
        .edit_remote,
        .remove_remote,
        .set_upstream,
        => true,
        else => false,
    };
}

/// Commit-list actions: they act on the selected commit in the Commits panel's
/// log. While that panel is drilled into a commit's files, the panel shows
/// files rather than the log, so these don't apply and are suppressed.
pub fn isCommitListAction(self: Action) bool {
    return switch (self) {
        .reset_commit,
        .revert_commit,
        .rebase_drop,
        .rebase_squash,
        .rebase_edit,
        .rebase_reword,
        .rebase_move_down,
        .rebase_move_up,
        .rebase_create_fixup,
        .rebase_autosquash,
        .rebase_fixup,
        .mark_base,
        .bisect_menu,
        .cherry_pick,
        => true,
        else => false,
    };
}

/// Working-tree file actions that only make sense on the Files panel's Files
/// tab — suppressed on its Worktrees / Submodules tabs (which list refs, not a
/// working-tree file set). `select`/`discard_selected`/`focus_main` are handled
/// separately (repurposed per tab), so they are not listed here.
pub fn isFilesContentAction(self: Action) bool {
    return switch (self) {
        .stage_all,
        .edit_file,
        .discard_all,
        .stash_menu,
        .start_commit,
        .amend_commit,
        .conflict_menu,
        .open_status_filter,
        .start_file_filter,
        .toggle_tree,
        => true,
        else => false,
    };
}

pub fn isMutating(self: Action) bool {
    return switch (self) {
        // Navigation, inspection, and global view toggles — always allowed.
        .quit,
        .cancel,
        .refresh,
        .move_up,
        .move_down,
        .focus_left,
        .focus_right,
        .scroll_left,
        .scroll_right,
        .toggle_main,
        .toggle_staging_split,
        .focus_status,
        .focus_files,
        .focus_branches,
        .focus_commits,
        .focus_stash,
        .focus_main,
        .prev_tab,
        .next_tab,
        .command_log,
        .help,
        .copy_to_clipboard,
        .open_browser,
        .edit_file,
        .diff_mark,
        .toggle_tree,
        .start_file_filter,
        .start_commit_filter,
        .open_status_filter,
        .confirm,
        .backspace,
        => false,
        // Everything else either mutates or opens a menu/prompt that does.
        else => true,
    };
}

pub fn fromNormalKey(key: vaxis.Key, keymap: config_mod.KeyMap, focus: model.Focus) ?Action {
    if (keymap.quit.matches(key) or keymap.quit_ctrl.matches(key)) return .quit;
    if (keymap.escape.matches(key)) return .cancel;

    if (keymap.status_panel.matches(key)) return .focus_status;
    if (keymap.files_panel.matches(key)) return .focus_files;
    if (keymap.branches_panel.matches(key)) return .focus_branches;
    if (keymap.commits_panel.matches(key)) return .focus_commits;
    if (keymap.stash_panel.matches(key)) return .focus_stash;

    // <enter> on a side panel descends into the main panel to inspect
    // the selected item. The main panel is left with <esc>/<h>.
    if (focus.isSidePanel() and keymap.enter.matches(key)) return .focus_main;

    if (keymap.prev_tab.matches(key)) return .prev_tab;
    if (keymap.next_tab.matches(key)) return .next_tab;

    // Context keybindings inside the Branches panel, shadowing
    // the global refresh/fetch there: R renames, f fast-forwards.
    if (focus == .branches and keymap.rename.matches(key)) return .rename_branch;
    if (focus == .branches and keymap.fast_forward.matches(key)) return .fast_forward_branch;
    // In the Commits panel, f is fixup (shadows the global fetch there).
    if (focus == .commits and keymap.commit_fixup.matches(key)) return .rebase_fixup;

    if (keymap.range_select.matches(key)) return .range_select;

    // In the Commits panel, `/` filters the log instead of the file list.
    if (focus == .commits and keymap.file_filter.matches(key)) return .start_commit_filter;

    if (keymap.command_log.matches(key)) return .command_log;
    if (keymap.help.matches(key)) return .help;
    if (keymap.undo.matches(key)) return .undo;
    if (keymap.copy_clipboard.matches(key)) return .copy_to_clipboard;
    if (keymap.open_browser.matches(key)) return .open_browser;
    if (keymap.diff_mark.matches(key)) return .diff_mark;
    if (keymap.patch_menu.matches(key)) return .patch_menu;
    if (keymap.refresh.matches(key)) return .refresh;
    if (keymap.file_filter.matches(key)) return .start_file_filter;
    if (keymap.fetch.matches(key)) return .fetch;
    if (keymap.pull.matches(key)) return .pull;
    if (keymap.push.matches(key)) return .push;

    if (keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) return .move_up;
    if (keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) return .move_down;
    // Tab toggles focus into the Diff (main) panel and back; the h/l/arrow keys
    // cycle the side panels.
    if (key.matches(vaxis.Key.tab, .{})) return .toggle_main;
    if (keymap.left.matches(key) or key.matches(vaxis.Key.left, .{})) return .focus_left;
    if (keymap.right.matches(key) or key.matches(vaxis.Key.right, .{})) return .focus_right;

    // Horizontal scrolling (H/L) of the focused panel for rows wider than it.
    if (keymap.scroll_left.matches(key)) return .scroll_left;
    if (keymap.scroll_right.matches(key)) return .scroll_right;

    // Toggle the staging view's single/split layout (only acts in that view).
    if (keymap.staging_split.matches(key)) return .toggle_staging_split;

    // `select` (space) is valid in every focus — the handler branches by focus
    // and staging state (stage a file, checkout a branch, apply a stash, stage
    // a line in the staging view, toggle a commit file into the patch). Match it
    // globally so it works in the main/staging and commits focuses too, not just
    // the side panels.
    if (keymap.select.matches(key)) return .select;

    switch (focus) {
        .files => {
            if (keymap.stage_all.matches(key)) return .stage_all;
            if (keymap.edit_file.matches(key)) return .edit_file;
            if (keymap.toggle_tree.matches(key)) return .toggle_tree;
            if (keymap.open_status_filter.matches(key)) return .open_status_filter;
            if (keymap.discard.matches(key)) return .discard_selected;
            if (keymap.discard_all.matches(key)) return .discard_all;
            if (keymap.stash_create.matches(key)) return .stash_menu;
            if (keymap.commit.matches(key)) return .start_commit;
            if (keymap.amend.matches(key)) return .amend_commit;
            if (keymap.conflict_menu.matches(key)) return .conflict_menu;
        },
        .branches => {
            if (keymap.new_branch.matches(key)) return .new_branch;
            if (keymap.checkout_by_name.matches(key)) return .checkout_by_name;
            if (keymap.discard.matches(key)) return .delete_branch;
            if (keymap.merge.matches(key)) return .merge_branch;
            if (keymap.rebase.matches(key)) return .rebase_branch;
            if (keymap.edit_remote.matches(key)) return .edit_remote;
            if (keymap.remove_remote.matches(key)) return .remove_remote;
            if (keymap.set_upstream.matches(key)) return .set_upstream;
        },
        .commits => {
            if (keymap.reset.matches(key)) return .reset_commit;
            if (keymap.revert.matches(key)) return .revert_commit;
            if (keymap.commit_drop.matches(key)) return .rebase_drop;
            if (keymap.commit_squash.matches(key)) return .rebase_squash;
            if (keymap.commit_edit.matches(key)) return .rebase_edit;
            if (keymap.commit_reword.matches(key)) return .rebase_reword;
            if (keymap.commit_move_down.matches(key)) return .rebase_move_down;
            if (keymap.commit_move_up.matches(key)) return .rebase_move_up;
            if (keymap.commit_create_fixup.matches(key)) return .rebase_create_fixup;
            if (keymap.commit_autosquash.matches(key)) return .rebase_autosquash;
            if (keymap.commit_mark_base.matches(key)) return .mark_base;
            if (keymap.bisect.matches(key)) return .bisect_menu;
            if (keymap.cherry_pick.matches(key)) return .cherry_pick;
            if (keymap.reset_cherry_pick.matches(key)) return .reset_cherry_pick;
            if (keymap.tag_commit.matches(key)) return .tag_commit;
            if (keymap.open_pull_request.matches(key)) return .open_pull_request;
            if (keymap.move_to_new_branch.matches(key)) return .move_to_new_branch;
        },
        .stash => {
            if (keymap.stash_apply.matches(key)) return .select;
            if (keymap.stash_pop.matches(key)) return .stash_pop;
            if (keymap.stash_drop.matches(key)) return .stash_drop;
        },
        .status, .main => {},
    }

    return null;
}

fn testKey(codepoint: u21) vaxis.Key {
    return .{ .codepoint = codepoint };
}

fn ctrlTestKey(codepoint: u21) vaxis.Key {
    return .{ .codepoint = codepoint, .mods = .{ .ctrl = true } };
}

test "normal key mapping handles global and focused actions" {
    const keymap: config_mod.KeyMap = .{};

    try std.testing.expectEqual(Action.quit, fromNormalKey(testKey('q'), keymap, .files).?);
    try std.testing.expectEqual(Action.refresh, fromNormalKey(testKey('R'), keymap, .files).?);
    try std.testing.expectEqual(Action.focus_status, fromNormalKey(testKey('1'), keymap, .files).?);
    try std.testing.expectEqual(Action.focus_files, fromNormalKey(testKey('2'), keymap, .files).?);
    try std.testing.expectEqual(Action.focus_branches, fromNormalKey(testKey('3'), keymap, .files).?);
    try std.testing.expectEqual(Action.focus_commits, fromNormalKey(testKey('4'), keymap, .files).?);
    try std.testing.expectEqual(Action.focus_stash, fromNormalKey(testKey('5'), keymap, .files).?);
    try std.testing.expectEqual(Action.stage_all, fromNormalKey(testKey('a'), keymap, .files).?);
    try std.testing.expectEqual(Action.discard_selected, fromNormalKey(testKey('d'), keymap, .files).?);
    try std.testing.expectEqual(Action.discard_all, fromNormalKey(testKey('D'), keymap, .files).?);
    try std.testing.expectEqual(Action.start_file_filter, fromNormalKey(testKey('/'), keymap, .files).?);
    try std.testing.expectEqual(Action.open_status_filter, fromNormalKey(ctrlTestKey('b'), keymap, .files).?);
    try std.testing.expectEqual(Action.start_commit, fromNormalKey(testKey('c'), keymap, .files).?);
    // `c` is not a generic main-panel binding (commit there is gated to the
    // staging view, handled in handleKey).
    try std.testing.expect(fromNormalKey(testKey('c'), keymap, .main) == null);
    try std.testing.expectEqual(Action.stash_pop, fromNormalKey(testKey('g'), keymap, .stash).?);
    try std.testing.expect(fromNormalKey(testKey('g'), keymap, .files) == null);

    // `c` is context-dependent: commit in Files, cherry-pick in Commits, and
    // checkout-by-name in Branches.
    try std.testing.expectEqual(Action.start_commit, fromNormalKey(testKey('c'), keymap, .files).?);
    try std.testing.expectEqual(Action.cherry_pick, fromNormalKey(testKey('c'), keymap, .commits).?);
    try std.testing.expectEqual(Action.checkout_by_name, fromNormalKey(testKey('c'), keymap, .branches).?);

    // H/L scroll the focused panel horizontally; lowercase h/l move between panels.
    try std.testing.expectEqual(Action.scroll_left, fromNormalKey(testKey('H'), keymap, .main).?);
    try std.testing.expectEqual(Action.scroll_right, fromNormalKey(testKey('L'), keymap, .main).?);
    try std.testing.expectEqual(Action.focus_left, fromNormalKey(testKey('h'), keymap, .files).?);
    try std.testing.expectEqual(Action.focus_right, fromNormalKey(testKey('l'), keymap, .files).?);

    // <enter> descends into the main panel from any side panel, but does
    // nothing once the main panel already has focus.
    const enter = testKey(0x0d);
    try std.testing.expectEqual(Action.focus_main, fromNormalKey(enter, keymap, .files).?);
    try std.testing.expectEqual(Action.focus_main, fromNormalKey(enter, keymap, .commits).?);
    try std.testing.expect(fromNormalKey(enter, keymap, .main) == null);

    // <space> is the primary action (select) in every focus — including the
    // main/staging focus (stage a line) and commits (toggle a patch file),
    // which previously fell through to null and made line-staging do nothing.
    const space = testKey(' ');
    try std.testing.expectEqual(Action.select, fromNormalKey(space, keymap, .files).?);
    try std.testing.expectEqual(Action.select, fromNormalKey(space, keymap, .branches).?);
    try std.testing.expectEqual(Action.select, fromNormalKey(space, keymap, .stash).?);
    try std.testing.expectEqual(Action.select, fromNormalKey(space, keymap, .commits).?);
    try std.testing.expectEqual(Action.select, fromNormalKey(space, keymap, .main).?);
}

test "list-level bindings are classified, and resolve to globals at neutral focus" {
    const keymap: config_mod.KeyMap = .{};

    // In the Branches panel, R/f are branch-list bindings; a panel drilled into
    // sub-commits re-resolves them at a neutral focus to their global meaning.
    try std.testing.expect(isBranchManagement(fromNormalKey(testKey('R'), keymap, .branches).?));
    try std.testing.expect(isBranchManagement(fromNormalKey(testKey('f'), keymap, .branches).?));
    try std.testing.expectEqual(Action.refresh, fromNormalKey(testKey('R'), keymap, .status).?);
    try std.testing.expectEqual(Action.fetch, fromNormalKey(testKey('f'), keymap, .status).?);

    // In the Commits panel, f is fixup and g/t are reset/revert — all commit-list
    // bindings the commit-files view suppresses; f then falls through to fetch.
    try std.testing.expect(isCommitListAction(fromNormalKey(testKey('f'), keymap, .commits).?));
    try std.testing.expect(isCommitListAction(fromNormalKey(testKey('g'), keymap, .commits).?));
    try std.testing.expect(isCommitListAction(fromNormalKey(testKey('t'), keymap, .commits).?));
    // A neutral focus has no binding for g/t, so they become no-ops in the view.
    try std.testing.expect(fromNormalKey(testKey('g'), keymap, .status) == null);
}
