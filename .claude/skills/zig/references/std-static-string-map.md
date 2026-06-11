# std.StaticStringMap

Compile-time optimized string lookup. Perfect hash for small, fixed sets of string keys.

## When to Use

- Keywords/reserved words lookup
- Command/option parsing
- Static configuration keys
- When string set is known at compile time
- Very fast O(1) lookups by string length

## Basic Usage

```zig
const std = @import("std");

const keywords = std.StaticStringMap(enum { @"if", @"else", @"while", @"for" }).initComptime(.{
    .{ "if", .@"if" },
    .{ "else", .@"else" },
    .{ "while", .@"while" },
    .{ "for", .@"for" },
});

// Lookup
if (keywords.get("while")) |kw| {
    switch (kw) {
        .@"while" => std.debug.print("found while\n", .{}),
        else => {},
    }
}

// Check existence
if (keywords.has("if")) {
    // it's a keyword
}
```

## Void Value (Set)

```zig
// When you only need presence check, use void
const reserved = std.StaticStringMap(void).initComptime(.{
    .{"break"},
    .{"continue"},
    .{"return"},
    .{"defer"},
});

if (reserved.has("break")) {
    std.debug.print("'break' is reserved\n", .{});
}
```

## Case-Insensitive Lookup

```zig
const commands = std.StaticStringMapWithEql(
    i32,
    std.static_string_map.eqlAsciiIgnoreCase,
).initComptime(.{
    .{ "help", 1 },
    .{ "quit", 2 },
    .{ "list", 3 },
});

// All find the same entry
_ = commands.get("HELP");   // 1
_ = commands.get("Help");   // 1
_ = commands.get("help");   // 1
```

## Runtime Initialization

```zig
// When data isn't known at comptime
const pairs = [_]struct { []const u8, i32 }{
    .{ "one", 1 },
    .{ "two", 2 },
    .{ "three", 3 },
};

const map = try std.StaticStringMap(i32).init(&pairs, allocator);
defer map.deinit(allocator);

_ = map.get("two");  // 2
```

## Get Index

```zig
// Get the index in the internal array
if (keywords.getIndex("if")) |idx| {
    // idx is position in sorted-by-length array
}
```

## Longest Prefix Match

```zig
const prefixes = std.StaticStringMap(u32).initComptime(.{
    .{ "/api", 1 },
    .{ "/api/v1", 2 },
    .{ "/api/v2", 3 },
});

// Find longest matching prefix
if (prefixes.getLongestPrefix("/api/v2/users")) |kv| {
    std.debug.print("matched: {s} -> {}\n", .{ kv.key, kv.value });
    // matched: /api/v2 -> 3
}
```

## Access All Keys/Values

```zig
const all_keys = keywords.keys();     // []const []const u8
const all_values = keywords.values(); // []const EnumType
```

## Complete Example: HTTP Method Parser

```zig
const std = @import("std");

const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

const methods = std.StaticStringMap(Method).initComptime(.{
    .{ "GET", .GET },
    .{ "POST", .POST },
    .{ "PUT", .PUT },
    .{ "DELETE", .DELETE },
    .{ "PATCH", .PATCH },
    .{ "HEAD", .HEAD },
    .{ "OPTIONS", .OPTIONS },
});

fn parseMethod(s: []const u8) ?Method {
    return methods.get(s);
}

pub fn main() void {
    if (parseMethod("POST")) |m| {
        std.debug.print("Method: {}\n", .{m});  // Method: POST
    }

    if (parseMethod("INVALID")) |_| {
        unreachable;
    } else {
        std.debug.print("Invalid method\n", .{});
    }
}
```

## Complete Example: Config Parser

```zig
const std = @import("std");

const ConfigKey = enum {
    host,
    port,
    debug,
    timeout,
};

const config_keys = std.StaticStringMapWithEql(
    ConfigKey,
    std.static_string_map.eqlAsciiIgnoreCase,
).initComptime(.{
    .{ "host", .host },
    .{ "port", .port },
    .{ "debug", .debug },
    .{ "timeout", .timeout },
});

fn parseConfig(line: []const u8) ?struct { key: ConfigKey, value: []const u8 } {
    const eq_idx = std.mem.indexOf(u8, line, "=") orelse return null;
    const key_str = std.mem.trim(u8, line[0..eq_idx], " ");
    const value = std.mem.trim(u8, line[eq_idx + 1 ..], " ");

    const key = config_keys.get(key_str) orelse return null;
    return .{ .key = key, .value = value };
}

pub fn main() void {
    const lines = [_][]const u8{
        "HOST = localhost",
        "PORT = 8080",
        "Debug = true",
    };

    for (lines) |line| {
        if (parseConfig(line)) |cfg| {
            std.debug.print("{}: {s}\n", .{ cfg.key, cfg.value });
        }
    }
}
```

## How It Works

1. Strings are sorted by length at compile time
2. Lookup first checks length to narrow candidates
3. Only strings of matching length are compared
4. Very efficient for disparate key lengths

## Notes

- Comptime version has zero runtime allocation
- Keys are grouped by length for fast rejection
- Use `eqlAsciiIgnoreCase` for case-insensitive matching
- Runtime `init()` requires `deinit()` to free memory
- Best for small to medium-sized static string sets
- Not suitable for dynamic key sets (use HashMap instead)
