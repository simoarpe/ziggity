const std = @import("std");
const ziggity = @import("ziggity");

/// A TUI owns the terminal, so `std.log` output must never reach stderr — it
/// lands on the alt-screen and corrupts it. vaxis logs capability detection at
/// `.info` during startup (e.g. "kitty keyboard capability detected"), which is
/// what produced the garbled text on launch. Route all logging to a no-op sink;
/// app errors surface through the UI, and the pre-TUI startup error path in
/// `main` writes to stderr directly (before the alt-screen is entered).
pub const std_options: std.Options = .{
    .logFn = discardLog,
};

fn discardLog(
    comptime _: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime _: []const u8,
    _: anytype,
) void {}

pub fn main(init: std.process.Init) !void {
    // When git runs us as its GIT_ASKPASS/SSH_ASKPASS program, the marker env
    // var is set: echo the requested credential and exit before touching the
    // terminal or requiring a git repository.
    if (init.environ_map.get(ziggity.app.askpass_env_marker) != null) {
        return ziggity.app.runAskpassHelper(init);
    }

    var app = ziggity.app.App.init(init.gpa, init.io, init.environ_map) catch |err| blk: {
        // Not in a repo: offer to create one here and continue; otherwise exit
        // cleanly. Any other startup error is reported and aborts.
        if (err == error.NotGitRepository) {
            if (!offerCreateRepo(init)) std.process.exit(0);
            break :blk ziggity.app.App.init(init.gpa, init.io, init.environ_map) catch |e2| {
                reportStartupError(init, e2);
                std.process.exit(1);
            };
        }
        reportStartupError(init, err);
        std.process.exit(1);
    };
    defer app.deinit();

    try ziggity.tui.run(init, &app);
}

/// Prompt (on the cooked terminal, before the TUI starts) to create a git repo
/// in the current directory. Returns true if one was created and we should
/// continue, false if the user declined. A failed `git init` reports and exits.
fn offerCreateRepo(init: std.process.Init) bool {
    var out_buf: [256]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stderr(), init.io, &out_buf);
    const out = &out_w.interface;
    out.writeAll("Not in a git repository. Create one here? (y/N) ") catch {};
    out.flush() catch {};

    var in_buf: [128]u8 = undefined;
    var in_r: std.Io.File.Reader = .init(.stdin(), init.io, &in_buf);
    // No newline (EOF / non-interactive stdin) counts as "no".
    const line = in_r.interface.takeDelimiterExclusive('\n') catch "";
    const answer = std.mem.trim(u8, line, " \t\r");
    if (!(answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y'))) return false;

    const result = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "git", "init" },
        .environ_map = init.environ_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        out.writeAll("ziggity: failed to run git init\n") catch {};
        out.flush() catch {};
        std.process.exit(1);
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        out.print("ziggity: git init failed: {s}\n", .{result.stderr}) catch {};
        out.flush() catch {};
        std.process.exit(1);
    }
    // Echo git's confirmation (e.g. "Initialized empty Git repository in …").
    out.writeAll(result.stdout) catch {};
    out.flush() catch {};
    init.gpa.free(result.stdout);
    init.gpa.free(result.stderr);
    return true;
}

/// Report a non-repo startup failure on stderr (no error-return trace).
fn reportStartupError(init: std.process.Init, err: anyerror) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), init.io, &buf);
    const writer = &w.interface;
    writer.print("ziggity: startup failed: {s}\n", .{@errorName(err)}) catch {};
    writer.flush() catch {};
}

test {
    std.testing.refAllDecls(@This());
}
