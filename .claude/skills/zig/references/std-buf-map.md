# std.BufMap / std.BufSet

String-keyed maps and sets that own their strings. Automatically copy and free string keys/values.

## When to Use

- Environment variable storage
- String-to-string mapping with ownership
- Set of unique strings with automatic memory management
- When you don't want to manage string lifetime manually

## BufMap (String -> String)

```zig
const std = @import("std");

var map = std.BufMap.init(allocator);
defer map.deinit();  // frees all stored strings

// Put (copies both key and value)
try map.put("HOME", "/Users/alice");
try map.put("PATH", "/usr/bin");

// Get
if (map.get("HOME")) |home| {
    std.debug.print("home: {s}\n", .{home});
}

// Get pointer (invalidated on resize)
if (map.getPtr("PATH")) |path_ptr| {
    path_ptr.* = try map.copy("/new/path");  // update in place
}

// Remove (frees both key and value)
map.remove("PATH");

// Count
const n = map.count();
```

## BufMap: Move Ownership

```zig
// putMove takes ownership instead of copying
const key = try allocator.dupe(u8, "MY_KEY");
const value = try allocator.dupe(u8, "my_value");
try map.putMove(key, value);
// Don't free key/value - map owns them now
```

## BufMap: Iteration

```zig
var it = map.iterator();
while (it.next()) |entry| {
    const key = entry.key_ptr.*;
    const value = entry.value_ptr.*;
    std.debug.print("{s}={s}\n", .{ key, value });
}
```

## BufSet (Set of Strings)

```zig
var set = std.BufSet.init(allocator);
defer set.deinit();  // frees all stored strings

// Insert (copies the string)
try set.insert("apple");
try set.insert("banana");
try set.insert("apple");  // no-op, already exists

// Check membership
if (set.contains("apple")) {
    // it's in the set
}

// Remove (frees the string)
set.remove("banana");

// Count
const n = set.count();
```

## BufSet: Iteration

```zig
var it = set.iterator();
while (it.next()) |key| {
    std.debug.print("{s}\n", .{key.*});
}
```

## BufSet: Clone

```zig
// Create independent copy
var copy = try set.clone();
defer copy.deinit();

// Clone with different allocator
var arena_copy = try set.cloneWithAllocator(arena.allocator());
// No need to deinit if using arena
```

## Complete Example: Environment Variables

```zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var env = std.BufMap.init(alloc);
    defer env.deinit();

    // Set some variables
    try env.put("APP_NAME", "MyApp");
    try env.put("APP_VERSION", "1.0.0");
    try env.put("DEBUG", "true");

    // Update a value
    try env.put("DEBUG", "false");  // replaces, frees old value

    // Print all
    var it = env.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // Check and use
    if (env.get("DEBUG")) |debug| {
        if (std.mem.eql(u8, debug, "true")) {
            std.debug.print("Debug mode enabled\n", .{});
        }
    }
}
```

## Complete Example: Unique Words

```zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var words = std.BufSet.init(gpa.allocator());
    defer words.deinit();

    const text = "the quick brown fox jumps over the lazy dog";
    var tokens = std.mem.tokenizeScalar(u8, text, ' ');

    while (tokens.next()) |word| {
        try words.insert(word);  // duplicates automatically ignored
    }

    std.debug.print("Unique words: {}\n", .{words.count()});  // 8

    var it = words.iterator();
    while (it.next()) |word| {
        std.debug.print("  {s}\n", .{word.*});
    }
}
```

## Notes

- All strings are copied on insert/put, freed on remove/deinit
- Use `putMove` to transfer ownership instead of copying
- `get()` returns borrowed slice - don't store long-term
- Iteration order is not insertion order (hash map)
- For non-owning string maps, use `std.StringHashMap`
