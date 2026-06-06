const std = @import("std");

pub const Logger = struct {
    enabled: bool = false,

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;
        std.log.debug(fmt, args);
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;
        std.log.info(fmt, args);
    }
};
