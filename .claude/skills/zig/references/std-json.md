# std.json - JSON Parsing and Serialization

JSON RFC 8259 compliant parsing and stringification in Zig 0.15.x.

## Table of Contents
- [Parsing JSON](#parsing-json)
- [Serializing to JSON](#serializing-to-json)
- [Dynamic Values](#dynamic-values)
- [Custom Serialization](#custom-serialization)
- [Streaming API](#streaming-api)
- [Common Patterns](#common-patterns)

## Parsing JSON

### Parse into Struct

```zig
const Config = struct {
    name: []const u8,
    port: u16,
    enabled: bool = true,  // default value for missing fields
};

const json_str =
    \\{"name": "server", "port": 8080}
;

const parsed = try std.json.parseFromSlice(Config, allocator, json_str, .{});
defer parsed.deinit();

const config = parsed.value;
// config.name == "server"
// config.port == 8080
// config.enabled == true (default)
```

### ParseOptions

```zig
const parsed = try std.json.parseFromSlice(T, allocator, json_str, .{
    // What to do with duplicate fields
    .duplicate_field_behavior = .@"error",  // .use_first, .use_last, .@"error" (default)

    // Allow unknown fields (default: error)
    .ignore_unknown_fields = true,

    // Max string/number length (default: input length for slices)
    .max_value_len = 4096,

    // Parse numbers vs keep as strings
    .parse_numbers = true,  // default: true
});
```

### Supported Types

| Zig Type | JSON |
|----------|------|
| `bool` | `true`, `false` |
| `i32`, `u64`, etc. | number or string |
| `f32`, `f64` | number or string |
| `?T` | value or `null` |
| `[]const u8` | string |
| `[N]u8` | string (fixed length) |
| `[]T`, `[N]T` | array |
| `struct` | object |
| `union(enum)` | object with single field |
| `enum` | string |
| `std.json.Value` | any JSON value |

### Parse into Dynamic Value

Use `std.json.Value` when structure is unknown at compile time:

```zig
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
defer parsed.deinit();

const value = parsed.value;
switch (value) {
    .object => |obj| {
        if (obj.get("name")) |name| {
            std.debug.print("name: {s}\n", .{name.string});
        }
    },
    .array => |arr| {
        for (arr.items) |item| { ... }
    },
    .string => |s| { ... },
    .integer => |i| { ... },
    .float => |f| { ... },
    .bool => |b| { ... },
    .null => { ... },
    .number_string => |s| { ... },  // unparsed number
}
```

### Leaky Parsing (Arena Allocator)

When using an arena, skip the `Parsed` wrapper:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const config = try std.json.parseFromSliceLeaky(
    Config,
    arena.allocator(),
    json_str,
    .{},
);
// No deinit needed - arena handles cleanup
```

## Serializing to JSON

### Simple Serialization

```zig
const config = Config{ .name = "app", .port = 3000 };

// To allocated string
const json = try std.json.Stringify.valueAlloc(allocator, config, .{});
defer allocator.free(json);
// json == {"name":"app","port":3000}

// To writer
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
try std.json.Stringify.value(config, .{}, &writer.interface);
try writer.interface.flush();
```

### Stringify Options

```zig
try std.json.Stringify.value(data, .{
    // Whitespace formatting
    .whitespace = .minified,     // default: no whitespace
    // .whitespace = .indent_2,  // 2-space indent
    // .whitespace = .indent_4,  // 4-space indent
    // .whitespace = .indent_tab,

    // Include null optional fields? (default: true)
    .emit_null_optional_fields = false,

    // Emit []u8 as array of numbers instead of string
    .emit_strings_as_arrays = false,

    // Escape non-ASCII unicode as \uXXXX
    .escape_unicode = false,

    // Large integers as strings for JS compatibility
    .emit_nonportable_numbers_as_strings = false,
}, writer);
```

### Supported Types for Serialization

- `bool` → `true`/`false`
- `?T` → value or `null`
- integers → number (or string if > 2^53 with option)
- floats → number (or string if not precisely representable as f64)
- `[]const u8` → string (or array with option)
- `[]T`, `[N]T` → array
- tuples → array
- `struct` → object (fields in declaration order)
- `union(enum)` → object with one field
- `enum` → string
- `*T` → serialization of `T`
- `error` → string

## Dynamic Values

### Value Type

```zig
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    number_string: []const u8,  // unparsed number
    string: []const u8,
    array: Array,               // std.ArrayList(Value)
    object: ObjectMap,          // StringArrayHashMap(Value)
};
```

### Building Values Manually

```zig
var obj = std.json.ObjectMap.init(allocator);
try obj.put("name", .{ .string = "test" });
try obj.put("count", .{ .integer = 42 });

var arr = std.json.Array.init(allocator);
try arr.append(.{ .integer = 1 });
try arr.append(.{ .integer = 2 });
try obj.put("items", .{ .array = arr });

const value = std.json.Value{ .object = obj };
```

### Accessing Values

```zig
// Object access
if (value.object.get("key")) |v| {
    switch (v) {
        .string => |s| std.debug.print("{s}\n", .{s}),
        else => {},
    }
}

// Array iteration
for (value.array.items) |item| {
    if (item == .integer) {
        std.debug.print("{d}\n", .{item.integer});
    }
}
```

## Custom Serialization

### Custom jsonParse

Define `jsonParse` for custom deserialization:

```zig
const Point = struct {
    x: i32,
    y: i32,

    // Parse from "x,y" string format
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !@This() {
        _ = allocator;
        _ = options;
        const token = try source.next();
        const str = switch (token) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        var it = std.mem.splitScalar(u8, str, ',');
        return .{
            .x = try std.fmt.parseInt(i32, it.next() orelse return error.UnexpectedToken, 10),
            .y = try std.fmt.parseInt(i32, it.next() orelse return error.UnexpectedToken, 10),
        };
    }
};

// Parses: "10,20" → Point{ .x = 10, .y = 20 }
```

### Custom jsonStringify

Define `jsonStringify` for custom serialization:

```zig
const Point = struct {
    x: i32,
    y: i32,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        // Serialize as "x,y" string
        try jw.print("\"{d},{d}\"", .{ self.x, self.y });
    }
};

// Serializes: Point{ .x = 10, .y = 20 } → "10,20"
```

## Streaming API

### Stringify (Write Stream)

Build JSON incrementally:

```zig
var out: std.io.Writer.Allocating = .init(allocator);
defer out.deinit();

var jw: std.json.Stringify = .{
    .writer = &out.writer,
    .options = .{ .whitespace = .indent_2 },
};

try jw.beginObject();
try jw.objectField("users");
try jw.beginArray();

for (users) |user| {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(user.name);
    try jw.objectField("age");
    try jw.write(user.age);
    try jw.endObject();
}

try jw.endArray();
try jw.endObject();

const json = out.written();
```

### Scanner (Low-Level Parsing)

Token-based parsing for streaming:

```zig
var scanner = std.json.Scanner.initCompleteInput(allocator, json_str);
defer scanner.deinit();

while (true) {
    const token = try scanner.next();
    switch (token) {
        .object_begin => { ... },
        .object_end => { ... },
        .array_begin => { ... },
        .array_end => { ... },
        .string => |s| { ... },
        .number => |n| { ... },
        .true, .false, .null => { ... },
        .end_of_document => break,
        else => {},
    }
}
```

## Common Patterns

### Config File Loading

```zig
const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    debug: bool = false,
};

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Config{},  // defaults
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Copy strings to owned memory since parsed will be freed
    return Config{
        .host = try allocator.dupe(u8, parsed.value.host),
        .port = parsed.value.port,
        .debug = parsed.value.debug,
    };
}
```

### API Response Handling

```zig
const ApiResponse = struct {
    success: bool,
    data: ?Data = null,
    @"error": ?[]const u8 = null,  // use @"error" for reserved words

    const Data = struct {
        id: u64,
        name: []const u8,
    };
};

fn handleResponse(json: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(ApiResponse, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!parsed.value.success) {
        std.debug.print("Error: {s}\n", .{parsed.value.@"error" orelse "unknown"});
        return error.ApiError;
    }

    if (parsed.value.data) |data| {
        std.debug.print("Got: {s} (id={})\n", .{ data.name, data.id });
    }
}
```

### Pretty Print JSON

```zig
fn prettyPrint(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
    });
}
```

### Serialize with Filtering

```zig
fn serializePublicFields(allocator: std.mem.Allocator, user: User) ![]u8 {
    // Create anonymous struct with only public fields
    const public = .{
        .id = user.id,
        .name = user.name,
        // Exclude: .password, .internal_state
    };
    return std.json.Stringify.valueAlloc(allocator, public, .{});
}
```
