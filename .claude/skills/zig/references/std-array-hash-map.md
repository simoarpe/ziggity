# std.ArrayHashMap

A hash map that preserves insertion order and stores keys/values in contiguous arrays. Combines hash table lookup with array-like iteration.

## When to Use

- Need deterministic iteration order (insertion order)
- Need array-style access to keys/values
- JSON object preservation
- When iteration performance matters more than removal performance

## Variants

| Type | Description |
|------|-------------|
| `AutoArrayHashMap(K, V)` | Auto-hashing for common key types |
| `ArrayHashMap(K, V, Ctx, store_hash)` | Custom hash/equal context |
| `StringArrayHashMap(V)` | String keys |
| `ArrayHashMapUnmanaged(...)` | No stored allocator |

## Basic Usage

```zig
const std = @import("std");

var map = std.AutoArrayHashMap(u32, []const u8).init(allocator);
defer map.deinit();

// Insert
try map.put(1, "one");
try map.put(2, "two");
try map.put(3, "three");

// Lookup
if (map.get(2)) |value| {
    std.debug.print("2 = {s}\n", .{value});
}

// Check existence
if (map.contains(1)) {
    // key exists
}
```

## Insertion Order Preserved

```zig
try map.put(10, "ten");
try map.put(5, "five");
try map.put(15, "fifteen");

// Iteration is in insertion order: 10, 5, 15
var it = map.iterator();
while (it.next()) |entry| {
    std.debug.print("{}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
}
```

## Array Access

```zig
// Direct access to underlying arrays
const keys = map.keys();     // []K slice of all keys
const values = map.values(); // []V slice of all values

// Access by index
for (keys, values) |k, v| {
    std.debug.print("{}: {s}\n", .{ k, v });
}
```

## Removal (Two Options)

```zig
// O(1) removal - swaps with last element, changes order
_ = map.swapRemove(key);

// O(n) removal - shifts elements, preserves order
_ = map.orderedRemove(key);

// Fetch and remove
if (map.fetchSwapRemove(key)) |kv| {
    std.debug.print("removed {}: {s}\n", .{ kv.key, kv.value });
}
```

## Get or Put

```zig
// Get existing or insert new
const result = try map.getOrPut(key);
if (!result.found_existing) {
    result.value_ptr.* = "new_value";
}

// Get or put with default value
const result2 = try map.getOrPutValue(key, "default");
```

## Index-Based Operations

```zig
// Get index of key
if (map.getIndex(key)) |idx| {
    // Remove by index
    map.swapRemoveAt(idx);
    // or
    map.orderedRemoveAt(idx);
}
```

## Capacity Management

```zig
try map.ensureTotalCapacity(100);
try map.ensureUnusedCapacity(10);

const cap = map.capacity();
const len = map.count();

map.clearRetainingCapacity();
map.clearAndFree();
```

## String Keys

```zig
var map = std.StringArrayHashMap(i32).init(allocator);
defer map.deinit();

try map.put("apple", 1);
try map.put("banana", 2);

// Keys are stored by reference, not copied
// Make sure string lifetime exceeds map usage
```

## Custom Context

```zig
const CaseInsensitiveContext = struct {
    pub fn hash(_: @This(), key: []const u8) u32 {
        var h: u32 = 0;
        for (key) |c| {
            h = h *% 31 +% std.ascii.toLower(c);
        }
        return h;
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

var map = std.ArrayHashMap(
    []const u8,
    i32,
    CaseInsensitiveContext,
    true,  // store_hash for better performance
).initContext(allocator, .{});
defer map.deinit();

try map.put("Hello", 1);
_ = map.get("HELLO");  // finds it!
```

## Complete Example: Word Counter

```zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counts = std.StringArrayHashMap(u32).init(gpa.allocator());
    defer counts.deinit();

    const words = [_][]const u8{ "apple", "banana", "apple", "cherry", "banana", "apple" };

    for (words) |word| {
        const result = try counts.getOrPut(word);
        if (result.found_existing) {
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
    }

    // Print in insertion order
    var it = counts.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}: {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    // Output (insertion order):
    // apple: 3
    // banana: 2
    // cherry: 1
}
```

## Comparison with HashMap

| Feature | HashMap | ArrayHashMap |
|---------|---------|--------------|
| Lookup | O(1) | O(1) |
| Insert | O(1) amortized | O(1) amortized |
| swapRemove | O(1) | O(1) |
| orderedRemove | N/A | O(n) |
| Iteration order | Undefined | Insertion order |
| Key/value arrays | No | Yes |
| Memory layout | Scattered | Contiguous |

## Notes

- Iteration order equals insertion order
- `swapRemove` is O(1) but changes order
- `orderedRemove` preserves order but is O(n)
- Use `store_hash=true` when `eql` is expensive
- Keys/values are stored in `MultiArrayList` (cache-friendly)
- Pointer stability only guaranteed with pre-allocated capacity
