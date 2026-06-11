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
    select,
    stage_all,
    discard_selected,
    discard_all,
    start_file_filter,
    open_status_filter,
    start_commit,
    new_branch,
    delete_branch,
    merge_branch,
    rebase_branch,
    reset_commit,
    revert_commit,
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

pub fn fromNormalKey(key: vaxis.Key, keymap: config_mod.KeyMap, focus: model.Focus) ?Action {
    if (keymap.quit.matches(key) or keymap.quit_ctrl.matches(key)) return .quit;
    if (keymap.escape.matches(key)) return .cancel;

    if (keymap.status_panel.matches(key)) return .focus_status;
    if (keymap.files_panel.matches(key)) return .focus_files;
    if (keymap.branches_panel.matches(key)) return .focus_branches;
    if (keymap.commits_panel.matches(key)) return .focus_commits;
    if (keymap.stash_panel.matches(key)) return .focus_stash;

    // <enter> on a side panel descends into the main panel (lazygit: inspect
    // the selected item). The main panel is left with <esc>/<h>.
    if (focus.isSidePanel() and keymap.enter.matches(key)) return .focus_main;

    if (keymap.prev_tab.matches(key)) return .prev_tab;
    if (keymap.next_tab.matches(key)) return .next_tab;

    if (keymap.refresh.matches(key)) return .refresh;
    if (keymap.file_filter.matches(key)) return .start_file_filter;
    if (keymap.fetch.matches(key)) return .fetch;
    if (keymap.pull.matches(key)) return .pull;
    if (keymap.push.matches(key)) return .push;

    if (keymap.up.matches(key) or key.matches(vaxis.Key.up, .{})) return .move_up;
    if (keymap.down.matches(key) or key.matches(vaxis.Key.down, .{})) return .move_down;
    if (key.matches(vaxis.Key.tab, .{ .shift = true })) return .focus_left;
    if (keymap.left.matches(key) or key.matches(vaxis.Key.left, .{})) return .focus_left;
    if (keymap.right.matches(key) or key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.tab, .{})) return .focus_right;

    switch (focus) {
        .files => {
            if (keymap.select.matches(key)) return .select;
            if (keymap.stage_all.matches(key)) return .stage_all;
            if (keymap.open_status_filter.matches(key)) return .open_status_filter;
            if (keymap.discard.matches(key)) return .discard_selected;
            if (keymap.discard_all.matches(key)) return .discard_all;
            if (keymap.commit.matches(key)) return .start_commit;
        },
        .branches => {
            if (keymap.select.matches(key)) return .select;
            if (keymap.new_branch.matches(key)) return .new_branch;
            if (keymap.discard.matches(key)) return .delete_branch;
            if (keymap.merge.matches(key)) return .merge_branch;
            if (keymap.rebase.matches(key)) return .rebase_branch;
        },
        .commits => {
            if (keymap.reset.matches(key)) return .reset_commit;
            if (keymap.revert.matches(key)) return .revert_commit;
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
    try std.testing.expectEqual(Action.stash_pop, fromNormalKey(testKey('g'), keymap, .stash).?);
    try std.testing.expect(fromNormalKey(testKey('g'), keymap, .files) == null);

    // <enter> descends into the main panel from any side panel, but does
    // nothing once the main panel already has focus.
    const enter = testKey(0x0d);
    try std.testing.expectEqual(Action.focus_main, fromNormalKey(enter, keymap, .files).?);
    try std.testing.expectEqual(Action.focus_main, fromNormalKey(enter, keymap, .commits).?);
    try std.testing.expect(fromNormalKey(enter, keymap, .main) == null);

    // <space> on branches/stash is the primary action, not enter.
    try std.testing.expectEqual(Action.select, fromNormalKey(testKey(' '), keymap, .branches).?);
}
