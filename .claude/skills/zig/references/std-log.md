# std.log

Standardized logging interface with configurable scopes, levels, and output.

## Quick Reference

| Function | Purpose |
|----------|---------|
| `log.err(fmt, args)` | Log error (something went wrong) |
| `log.warn(fmt, args)` | Log warning (uncertain if wrong) |
| `log.info(fmt, args)` | Log info (general state) |
| `log.debug(fmt, args)` | Log debug (debugging only) |
| `log.scoped(.name)` | Create scoped logger |

## Basic Usage

```zig
const std = @import("std");
const log = std.log;

pub fn main() void {
    log.info("Starting application", .{});
    log.debug("Debug value: {}", .{x});  // Hidden in release builds
    log.warn("Config missing, using defaults", .{});
    log.err("Failed to connect: {s}", .{@errorName(e)});
}
```

## Log Levels

| Level | Build Mode Default | Purpose |
|-------|-------------------|---------|
| `.err` | Always shown | Something went wrong |
| `.warn` | Always shown | Uncertain if wrong, worth investigating |
| `.info` | Debug + Release | General program state |
| `.debug` | Debug only | Messages only useful for debugging |

Default level by build mode:
- **Debug**: `.debug` (all messages)
- **ReleaseSafe/Fast/Small**: `.info` (no debug messages)

## Scoped Logging

Create loggers with custom scopes for filtering:

```zig
const std = @import("std");

// Library logger with custom scope
const log = std.log.scoped(.my_library);

pub fn doWork() void {
    log.info("Processing...", .{});   // Prefixed with (my_library)
    log.debug("Details: {}", .{x});
}
```

Multiple scopes in one file:

```zig
const network_log = std.log.scoped(.network);
const db_log = std.log.scoped(.database);

fn fetchData() void {
    network_log.info("Connecting...", .{});
    db_log.debug("Query: {s}", .{sql});
}
```

## Configuration via std_options

Configure logging in your root file:

```zig
const std = @import("std");

pub const std_options: std.Options = .{
    // Global log level
    .log_level = .warn,  // Only show warn and err

    // Per-scope levels (override global)
    .log_scope_levels = &.{
        .{ .scope = .my_library, .level = .debug },  // Full debug for this scope
        .{ .scope = .noisy_lib, .level = .err },     // Errors only
    },

    // Custom log function
    .logFn = myLogFn,
};
```

## Custom Log Function

Replace the default log output:

```zig
const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = myLogFn,
};

fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Filter: only errors from unknown scopes
    const scope_prefix = switch (scope) {
        .my_app, .default => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,  // Skip non-error from other scopes
    };

    const level_txt = comptime level.asText();
    const prefix = "[" ++ level_txt ++ "] (" ++ scope_prefix ++ "): ";

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    var buf: [64]u8 = undefined;
    const stderr = std.fs.File.stderr().writer(&buf);
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
    try stderr.flush();
}
```

## Check if Logging Enabled

Avoid expensive computations when logging is disabled:

```zig
const log = std.log.scoped(.my_scope);

fn process() void {
    // Check before expensive operation
    if (std.log.logEnabled(.debug, .my_scope)) {
        const debug_info = computeExpensiveDebugInfo();
        log.debug("Info: {}", .{debug_info});
    }

    // For default scope
    if (std.log.defaultLogEnabled(.debug)) {
        std.log.debug("Debug message", .{});
    }
}
```

## Level Methods

```zig
const level: std.log.Level = .warn;

// Get text representation
const text = level.asText();  // "warning"

// Compare levels (lower = more severe)
const is_error_or_worse = @intFromEnum(level) <= @intFromEnum(std.log.Level.err);
```

## Default Log Function

Forward to the standard implementation:

```zig
fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Add timestamp, then forward to default
    std.debug.print("[{d}] ", .{std.time.timestamp()});
    std.log.defaultLog(level, scope, format, args);
}
```

## Output Format

Default output format:
```
level: message                     # default scope
level(scope): message              # named scope
```

Examples:
```
info: Server started on port 8080
warning(database): Connection pool exhausted
error(network): Failed to resolve hostname
debug: Variable x = 42
```

## Common Patterns

### Conditional Debug Logging

```zig
fn processItem(item: Item) void {
    if (comptime std.log.logEnabled(.debug, .default)) {
        log.debug("Processing: {}", .{item});
    }
    // ... process
}
```

### Error Context Logging

```zig
fn loadConfig(path: []const u8) !Config {
    return std.fs.cwd().openFile(path, .{}) catch |err| {
        log.err("Failed to open config '{s}': {s}", .{path, @errorName(err)});
        return err;
    };
}
```

### Library Logging Pattern

```zig
// In library code
pub const log = std.log.scoped(.my_lib);

// Users can filter with:
// .log_scope_levels = &.{ .{ .scope = .my_lib, .level = .warn } }
```

## Log to File

```zig
fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const file = std.fs.cwd().openFile("app.log", .{ .mode = .write_only }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;

    var buf: [256]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;

    const level_txt = comptime level.asText();
    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

    w.print("[{s}]{s} " ++ format ++ "\n", .{level_txt, scope_txt} ++ args) catch return;
    w.flush() catch return;
}
```
