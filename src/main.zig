const std = @import("std");
const ziggity = @import("ziggity");

pub fn main(init: std.process.Init) !void {
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
