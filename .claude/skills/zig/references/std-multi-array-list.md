# std.MultiArrayList

Struct-of-Arrays container for cache-efficient struct storage. Stores each field in a separate contiguous array, reducing padding overhead and improving cache locality when accessing individual fields.

## When to Use

- Storing many structs where you often access only some fields
- Performance-critical code benefiting from cache-friendly access patterns
- Tagged unions (stores tags and data separately)

## Initialization

```zig
const Item = struct {
    id: u32,
    name: []const u8,
    score: f32,
};

var list: std.MultiArrayList(Item) = .{};
defer list.deinit(allocator);

// Pre-allocate capacity
try list.ensureTotalCapacity(allocator, 100);
```

## Basic Operations

```zig
// Append
try list.append(allocator, .{ .id = 1, .name = "foo", .score = 0.5 });
list.appendAssumeCapacity(.{ .id = 2, .name = "bar", .score = 0.8 });

// Get/set individual elements
const item = list.get(0);          // returns full struct
list.set(0, new_item);             // set full struct

// Access individual field arrays (MAIN BENEFIT)
const ids = list.items(.id);       // []u32 slice
const scores = list.items(.score); // []f32 slice

// Modify field directly
list.items(.score)[0] = 1.0;

// Pop last element
const last = list.pop();  // returns ?Item

// Length
const n = list.len;
```

## Slice API (More Efficient)

When accessing multiple fields, use `slice()` to compute pointers once:

```zig
const slices = list.slice();

// Now access fields without recomputing offsets
for (slices.items(.id), slices.items(.score)) |id, score| {
    // process id and score together
}

// Get/set via slice
const item = slices.get(index);
slices.set(index, new_item);
```

## Removal

```zig
// O(1) but doesn't preserve order
list.swapRemove(index);

// O(n) but preserves order
list.orderedRemove(index);

// Remove multiple indices (must be sorted ascending)
list.orderedRemoveMany(&.{ 1, 5, 7, 9 });
```

## Tagged Union Support

MultiArrayList works with tagged unions, storing tags separately:

```zig
const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
};

var values: std.MultiArrayList(Value) = .{};
try values.append(allocator, .{ .int = 42 });
try values.append(allocator, .{ .float = 3.14 });

// Access tags and data separately
const tags = values.items(.tags);   // []meta.Tag(Value)
const data = values.items(.data);   // []Value.Bare (untagged union)

// Reconstruct full union
const full = values.get(0);  // Value{ .int = 42 }
```

## Sorting

```zig
// Sort with custom comparator (index-based)
list.sort(struct {
    scores: []const f32,

    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        return ctx.scores[a] < ctx.scores[b];
    }
}{ .scores = list.items(.score) });

// Also: sortUnstable, sortSpan, sortSpanUnstable
```

## Capacity Management

```zig
try list.ensureTotalCapacity(allocator, 100);
try list.ensureUnusedCapacity(allocator, 10);
try list.resize(allocator, new_len);  // doesn't initialize
list.shrinkAndFree(allocator, new_len);
list.shrinkRetainingCapacity(new_len);
list.clearRetainingCapacity();
list.clearAndFree(allocator);
```

## Clone and Transfer

```zig
const copy = try list.clone(allocator);
const owned_slice = list.toOwnedSlice();  // empties list, caller owns
```
