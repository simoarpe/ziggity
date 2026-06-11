# std.process - Process Management API Reference

Process spawning, environment variables, argument parsing, and system utilities in Zig 0.15.x.

## Table of Contents
- [Module Structure](#module-structure)
- [Spawning Child Processes](#spawning-child-processes)
- [Environment Variables](#environment-variables)
- [Command Line Arguments](#command-line-arguments)
- [Process Utilities](#process-utilities)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.process.Child         // Child process management (spawn, wait, kill)
std.process.EnvMap        // Environment variable hash map
std.process.ArgIterator   // Cross-platform argument iterator
std.process.exit          // Exit process immediately
std.process.abort         // Abort with core dump
std.process.getCwd        // Get current working directory
std.process.getEnvMap     // Snapshot all environment variables
std.process.getEnvVarOwned // Get single environment variable
```

## Spawning Child Processes

### Basic Spawn and Wait

```zig
var child = std.process.Child.init(&.{ "ls", "-la" }, allocator);
child.cwd = "/tmp";  // optional working directory

try child.spawn();
const term = try child.wait();

switch (term) {
    .Exited => |code| std.debug.print("Exited with {d}\n", .{code}),
    .Signal => |sig| std.debug.print("Killed by signal {d}\n", .{sig}),
    .Stopped => |sig| std.debug.print("Stopped by signal {d}\n", .{sig}),
    .Unknown => |status| std.debug.print("Unknown status {d}\n", .{status}),
}
```

### Capture Output

```zig
const result = try std.process.Child.run(.{
    .allocator = allocator,
    .argv = &.{ "git", "status", "--short" },
    .cwd = project_dir,               // optional
    .max_output_bytes = 50 * 1024,    // default
});
defer allocator.free(result.stdout);
defer allocator.free(result.stderr);

if (result.term == .Exited and result.term.Exited == 0) {
    std.debug.print("Output: {s}\n", .{result.stdout});
} else {
    std.debug.print("Error: {s}\n", .{result.stderr});
}
```

### Pipe to/from Child

```zig
var child = std.process.Child.init(&.{ "cat" }, allocator);
child.stdin_behavior = .Pipe;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;

try child.spawn();

// Write to child's stdin
var buf: [4096]u8 = undefined;
var writer = child.stdin.?.writer(&buf);
try writer.interface.writeAll("Hello from parent\n");
try writer.interface.flush();
child.stdin.?.close();
child.stdin = null;

// Read child's stdout
var stdout: std.ArrayList(u8) = .empty;
defer stdout.deinit(allocator);
var stderr: std.ArrayList(u8) = .empty;
defer stderr.deinit(allocator);

try child.collectOutput(allocator, &stdout, &stderr, 50 * 1024);
const term = try child.wait();
```

### StdIo Behaviors

```zig
child.stdin_behavior = .Inherit;  // share parent's stdin (default)
child.stdin_behavior = .Pipe;     // create pipe for communication
child.stdin_behavior = .Ignore;   // /dev/null
child.stdin_behavior = .Close;    // no stdin

// Same options for stdout_behavior and stderr_behavior
```

### Spawn with Custom Environment

```zig
var env = std.process.EnvMap.init(allocator);
defer env.deinit();
try env.put("PATH", "/usr/bin:/bin");
try env.put("MY_VAR", "value");

var child = std.process.Child.init(&.{ "my_program" }, allocator);
child.env_map = &env;
try child.spawn();
```

### Set Working Directory

```zig
var child = std.process.Child.init(&.{ "make" }, allocator);

// Option 1: path string
child.cwd = "/path/to/project";

// Option 2: directory handle (not yet on Windows)
var dir = try std.fs.cwd().openDir("project", .{});
defer dir.close();
child.cwd_dir = dir;

try child.spawn();
```

### Kill Child Process

```zig
var child = std.process.Child.init(&.{ "sleep", "100" }, allocator);
try child.spawn();

// ... later
const term = try child.kill();  // sends SIGTERM on POSIX
```

### Resource Usage Statistics

```zig
var child = std.process.Child.init(&.{ "heavy_computation" }, allocator);
child.request_resource_usage_statistics = true;

try child.spawn();
_ = try child.wait();

if (child.resource_usage_statistics.getMaxRss()) |rss| {
    std.debug.print("Peak memory: {d} bytes\n", .{rss});
}
```

### POSIX-only: Change User/Group

```zig
var child = std.process.Child.init(&.{ "daemon" }, allocator);

// By name
try child.setUserName("nobody");

// Or directly
child.uid = 65534;
child.gid = 65534;
child.pgid = 0;  // create new process group

try child.spawn();
```

### Windows-only Options

```zig
var child = std.process.Child.init(&.{ "app.exe" }, allocator);
child.create_no_window = true;   // hide console window
child.start_suspended = true;    // start paused
try child.spawn();
```

### Darwin-only: Disable ASLR

```zig
var child = std.process.Child.init(&.{ "debugee" }, allocator);
child.disable_aslr = true;
try child.spawn();
```

## Environment Variables

### Get Single Variable

```zig
// With allocation (caller owns memory)
const home = try std.process.getEnvVarOwned(allocator, "HOME");
defer allocator.free(home);

// Check existence without allocation
if (std.process.hasEnvVarConstant("DEBUG")) {
    // DEBUG is set
}

// Check with dynamic key
const has_it = try std.process.hasEnvVar(allocator, key);

// Check non-empty
if (std.process.hasNonEmptyEnvVarConstant("PATH")) {
    // PATH is set and not empty
}

// Parse as integer
const port = std.process.parseEnvVarInt("PORT", u16, 10) catch 8080;
```

### Get All Variables

```zig
var env = try std.process.getEnvMap(allocator);
defer env.deinit();

// Iterate
var it = env.iterator();
while (it.next()) |entry| {
    std.debug.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
}

// Lookup
if (env.get("PATH")) |path| {
    std.debug.print("PATH={s}\n", .{path});
}
```

### EnvMap Operations

```zig
var env = std.process.EnvMap.init(allocator);
defer env.deinit();

// Add/update (copies key and value)
try env.put("KEY", "value");

// Add/update (takes ownership, avoids copy)
const key = try allocator.dupe(u8, "KEY");
const val = try allocator.dupe(u8, "value");
try env.putMove(key, val);  // env now owns key and val

// Lookup
const value = env.get("KEY");       // ?[]const u8
const ptr = env.getPtr("KEY");      // ?*[]const u8

// Remove
env.remove("KEY");

// Count
const n = env.count();
```

**Note**: On Windows, environment variable names are case-insensitive. EnvMap handles this automatically.

## Command Line Arguments

### Cross-platform Iterator

```zig
// With allocator (required on Windows/WASI)
var args = try std.process.argsWithAllocator(allocator);
defer args.deinit();

// Skip program name
_ = args.skip();

while (args.next()) |arg| {
    std.debug.print("arg: {s}\n", .{arg});
}
```

### Get All Arguments as Slice

```zig
const argv = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, argv);

const program = argv[0];
for (argv[1..]) |arg| {
    // process arg
}
```

### POSIX-only (no allocation)

```zig
var args = std.process.ArgIterator.init();
while (args.next()) |arg| {
    std.debug.print("{s}\n", .{arg});
}
```

### Parse Response Files (shell-style)

```zig
const ArgParser = std.process.ArgIteratorGeneral(.{
    .comments = true,       // skip # comments
    .single_quotes = true,  // support 'quoted args'
});

var parser = try ArgParser.init(allocator, response_file_content);
defer parser.deinit();

while (parser.next()) |arg| {
    // process arg
}
```

## Process Utilities

### Current Working Directory

```zig
// Into provided buffer
var buf: [std.fs.max_path_bytes]u8 = undefined;
const cwd = try std.process.getCwd(&buf);

// With allocation
const cwd = try std.process.getCwdAlloc(allocator);
defer allocator.free(cwd);
```

### Exit Process

```zig
// Clean exit (in release: immediate exit; in debug: returns to allow cleanup testing)
std.process.cleanExit();

// Immediate exit with code
std.process.exit(0);   // success
std.process.exit(1);   // failure

// Abort (generates core dump on POSIX)
std.process.abort();
```

### Replace Current Process (POSIX only)

```zig
// Replace with new program (never returns on success)
std.process.execv(allocator, &.{ "/bin/sh", "-c", "echo hello" }) catch |err| {
    std.debug.print("exec failed: {}\n", .{err});
    std.process.exit(1);
};

// With custom environment
var env = std.process.EnvMap.init(allocator);
try env.put("PATH", "/bin");
std.process.execve(allocator, &.{ "my_program" }, &env) catch |err| {
    // handle error
};
```

### System Memory

```zig
const mem = try std.process.totalSystemMemory();
std.debug.print("Total RAM: {d} bytes\n", .{mem});
```

### User Information (POSIX only)

```zig
const info = try std.process.getUserInfo("nobody");
std.debug.print("uid={d} gid={d}\n", .{ info.uid, info.gid });
```

### Raise File Descriptor Limit

```zig
// Attempt to raise NOFILE limit (no-op on unsupported platforms)
std.process.raiseFileDescriptorLimit();
```

### Check Spawning Support

```zig
if (std.process.can_spawn) {
    // Can use Child.spawn()
}

if (std.process.can_execv) {
    // Can use execv/execve
}
```

## Common Patterns

### Run Command and Check Success

```zig
fn runCommand(allocator: Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("Command failed:\n{s}\n", .{result.stderr});
        return error.CommandFailed;
    }
}
```

### Pipe Between Processes

```zig
fn pipeCommands(allocator: Allocator) ![]u8 {
    // First command: generate output
    var producer = std.process.Child.init(&.{ "echo", "hello world" }, allocator);
    producer.stdout_behavior = .Pipe;
    try producer.spawn();

    // Second command: process output
    var consumer = std.process.Child.init(&.{ "tr", "a-z", "A-Z" }, allocator);
    consumer.stdin_behavior = .Pipe;
    consumer.stdout_behavior = .Pipe;
    try consumer.spawn();

    // Connect them (copy producer stdout to consumer stdin)
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try producer.stdout.?.read(&buf);
        if (n == 0) break;
        try consumer.stdin.?.writeAll(buf[0..n]);
    }
    consumer.stdin.?.close();
    consumer.stdin = null;

    // Collect result
    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try consumer.collectOutput(allocator, &stdout, &stderr, 50 * 1024);

    _ = try producer.wait();
    _ = try consumer.wait();

    return stdout.toOwnedSlice(allocator);
}
```

### Environment Variable Fallback Chain

```zig
fn getConfigPath(allocator: Allocator) ![]const u8 {
    // Try specific var first
    if (std.process.getEnvVarOwned(allocator, "MY_APP_CONFIG")) |path| {
        return path;
    } else |_| {}

    // Fall back to XDG
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "myapp", "config.json" });
    } else |_| {}

    // Fall back to HOME
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "myapp", "config.json" });
}
```

### Process Pool / Parallel Execution

```zig
fn runParallel(allocator: Allocator, commands: []const []const []const u8) !void {
    var children: std.ArrayList(std.process.Child) = .empty;
    defer children.deinit(allocator);

    // Start all processes
    for (commands) |argv| {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        try children.append(allocator, child);
    }

    // Wait for all
    for (children.items) |*child| {
        const term = try child.wait();
        if (term != .Exited or term.Exited != 0) {
            return error.ChildFailed;
        }
    }
}
```

### Argument Parsing with Flags

```zig
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip program name

    var verbose = false;
    var output: ?[]const u8 = null;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            output = args.next() orelse return error.MissingOutputArg;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            try positional.append(allocator, arg);
        }
    }

    // Use parsed arguments...
}
```

### Spawn with Timeout

```zig
fn runWithTimeout(allocator: Allocator, argv: []const []const u8, timeout_ns: u64) !std.process.Child.Term {
    var child = std.process.Child.init(argv, allocator);
    try child.spawn();

    const start = std.time.nanoTimestamp();
    while (true) {
        // Non-blocking wait check
        if (child.term) |term| {
            return term;
        }

        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (elapsed > timeout_ns) {
            return child.kill();
        }

        std.time.sleep(10 * std.time.ns_per_ms);  // poll every 10ms
    }
}
```
