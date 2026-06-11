# std.HashMap / std.AutoHashMap

Hash maps for key-value storage. Use `AutoHashMap` for simple keys, `StringHashMap` for string keys.

## Types Overview

```zig
// AutoHashMap - automatic hash/eql for simple types
std.AutoHashMap(KeyType, ValueType)
std.AutoHashMapUnmanaged(KeyType, ValueType)  // no stored allocator

// StringHashMap - optimized for string keys
std.StringHashMap(ValueType)
std.StringHashMapUnmanaged(ValueType)

// ArrayHashMap - preserves insertion order, fast iteration
std.ArrayHashMap(K, V, Context, store_hash)
std.StringArrayHashMap(V)
```

## AutoHashMap Usage

```zig
// Initialization
var map = std.AutoHashMap(u32, []const u8).init(allocator);
defer map.deinit();

// Insert
try map.put(42, "answer");

// Get
if (map.get(42)) |value| {
    // value is []const u8
}

// Get pointer (for modification)
if (map.getPtr(42)) |ptr| {
    ptr.* = "new value";
}

// Remove
if (map.fetchRemove(42)) |kv| {
    // kv.key, kv.value - removed entry
}
_ = map.remove(42);  // returns bool

// Check existence
const exists = map.contains(42);

// Count
const n = map.count();
```

## Unmanaged Variant

```zig
// No stored allocator - pass to each method
var map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
defer map.deinit(allocator);

try map.put(allocator, 42, "answer");
const val = map.get(42);
```

## StringHashMap

```zig
var map = std.StringHashMap(i32).init(allocator);
defer map.deinit();

try map.put("foo", 123);
const val = map.get("foo");  // ?i32
```

## getOrPut Pattern

Efficient insert-or-update without double lookup:

```zig
const gop = try map.getOrPut(key);
if (gop.found_existing) {
    // Update existing
    gop.value_ptr.* += 1;
} else {
    // Initialize new entry
    gop.value_ptr.* = 1;
}
```

## Iteration

```zig
// Iterate entries
var iter = map.iterator();
while (iter.next()) |entry| {
    const key = entry.key_ptr.*;
    const value = entry.value_ptr.*;
}

// Keys only
for (map.keys()) |key| { }

// Values only
for (map.values()) |value| { }
```

## Capacity

```zig
try map.ensureTotalCapacity(100);
map.clearRetainingCapacity();
map.clearAndFree();
```

## Custom Context

For custom hash/equality functions:

```zig
const Context = struct {
    pub fn hash(self: @This(), key: MyKey) u64 {
        _ = self;
        // compute hash
    }
    pub fn eql(self: @This(), a: MyKey, b: MyKey) bool {
        _ = self;
        // compare
    }
};

var map = std.HashMap(MyKey, Value, Context, 80).init(allocator);
// Or with context instance:
var map = std.HashMap(MyKey, Value, Context, 80).initContext(allocator, context);
```

## ArrayHashMap (Ordered)

Preserves insertion order, supports indexed access:

```zig
var map = std.StringArrayHashMap(i32).init(allocator);
defer map.deinit();

try map.put("b", 2);
try map.put("a", 1);

// Iterate in insertion order: "b", "a"
for (map.keys(), map.values()) |k, v| { }

// Index access
const key = map.keys()[0];  // "b"
const val = map.values()[0]; // 2

// Swap remove (O(1) but changes order)
map.swapRemove("b");

// Ordered remove (O(n) but preserves order)
map.orderedRemove("a");
```

## Common Patterns

```zig
// Word frequency counter
var counts = std.StringHashMap(usize).init(allocator);
for (words) |word| {
    const gop = try counts.getOrPut(word);
    if (gop.found_existing) {
        gop.value_ptr.* += 1;
    } else {
        gop.value_ptr.* = 1;
    }
}

// Cache with owned keys
var cache = std.StringHashMap(Data).init(allocator);
// When inserting, dupe the key if needed:
const key_copy = try allocator.dupe(u8, external_key);
errdefer allocator.free(key_copy);
try cache.put(key_copy, data);
```
