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

    var app = ziggity.app.App.init(init.gpa, init.io, init.environ_map) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const writer = &stderr_writer.interface;
        switch (err) {
            error.NotGitRepository => try writer.writeAll("ziggity: not inside a git repository\n"),
            else => try writer.print("ziggity: startup failed: {s}\n", .{@errorName(err)}),
        }
        try writer.flush();
        return err;
    };
    defer app.deinit();

    try ziggity.tui.run(init, &app);
}

test {
    std.testing.refAllDecls(@This());
}
