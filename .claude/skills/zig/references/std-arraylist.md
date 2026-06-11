# std.ArrayList

Dynamic array (vector) that grows as needed.

**Note:** `std.ArrayListUnmanaged` is now deprecated - use `std.ArrayList` (same type, unmanaged is now the default pattern in Zig 0.15.x).

## Initialization

```zig
// CRITICAL: Use .empty, not .{}
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);

// With pre-allocated capacity
var list = try std.ArrayList(u32).initCapacity(allocator, 100);

// From existing slice (takes ownership)
var list = std.ArrayList(u32).fromOwnedSlice(existing_slice);

// Fixed buffer (no allocator needed for operations)
var buffer: [8]i32 = undefined;
var stack = std.ArrayList(i32).initBuffer(&buffer);
```

## Basic Operations

```zig
// Append
try list.append(allocator, 42);
try list.appendSlice(allocator, &[_]u32{1, 2, 3});

// Append without allocation (asserts capacity exists)
list.appendAssumeCapacity(42);
list.appendSliceAssumeCapacity(&[_]u32{1, 2, 3});

// Access items
const items = list.items;  // []T slice
const first = list.items[0];
const last = list.getLast();  // returns ?T
const popped = list.pop();    // returns ?T, removes last

// Insert at index
try list.insert(allocator, 2, value);
try list.insertSlice(allocator, 2, slice);

// Remove
const removed = list.orderedRemove(index);   // O(n), preserves order
const removed = list.swapRemove(index);      // O(1), doesn't preserve order
```

## Capacity Management

```zig
// Ensure space for N more items
try list.ensureUnusedCapacity(allocator, 10);

// Ensure total capacity is at least N
try list.ensureTotalCapacity(allocator, 100);

// Shrink to fit
list.shrinkAndFree(allocator, list.items.len);

// Clear
list.clearRetainingCapacity();  // keeps memory
list.clearAndFree(allocator);   // frees memory
```

## Ownership Transfer

```zig
// Get owned slice (empties list, caller owns memory)
const owned = try list.toOwnedSlice(allocator);
defer allocator.free(owned);

// Get null-terminated slice
const z_str = try list.toOwnedSliceSentinel(allocator, 0);
```

## Iteration

```zig
for (list.items) |item| {
    // read-only
}

for (list.items) |*item| {
    item.* += 1;  // modify in place
}

for (list.items, 0..) |item, i| {
    // with index
}
```

## Common Patterns

```zig
// Collect from iterator
var list: std.ArrayList(u8) = .empty;
for (some_iterator) |item| {
    try list.append(allocator, item);
}

// Build string
var buf: std.ArrayList(u8) = .empty;
try buf.appendSlice(allocator, "Hello ");
try buf.appendSlice(allocator, name);
const result = try buf.toOwnedSlice(allocator);

// Remove while iterating (iterate backwards)
var i: usize = list.items.len;
while (i > 0) {
    i -= 1;
    if (shouldRemove(list.items[i])) {
        _ = list.swapRemove(i);
    }
}
```

## Reserve-First Pattern (Exception Safety)

When inserting into multiple containers or when partial mutation would corrupt state, use **reserve-first**: separate fallible reservation from infallible mutation.

```zig
// BAD - partial failure leaves invalid state
fn addItem(list: *std.ArrayList(u32), map: *std.AutoHashMap(u32, usize), gpa: Allocator, value: u32) !void {
    try list.append(gpa, value);              // Can fail
    try map.put(gpa, value, list.items.len);  // If this fails, list has orphan entry!
}

// GOOD - reserve first, then mutate
fn addItem(list: *std.ArrayList(u32), map: *std.AutoHashMap(u32, usize), gpa: Allocator, value: u32) !void {
    // Phase 1: Reserve (fallible, but no mutation)
    try list.ensureUnusedCapacity(gpa, 1);
    try map.ensureUnusedCapacity(gpa, 1);

    errdefer comptime unreachable;  // Phase 2: No errors after this point

    // Phase 3: Mutate (infallible)
    list.appendAssumeCapacity(value);
    map.getOrPutAssumeCapacity(value).value_ptr.* = list.items.len;
}
```

**Key methods:**
- `ensureUnusedCapacity(gpa, n)` - Reserve space for n more items (can fail, doesn't mutate)
- `appendAssumeCapacity(item)` - Append without allocation (cannot fail, asserts capacity)
- `appendSliceAssumeCapacity(items)` - Append slice without allocation

See **[Reserve-First Exception Safety](patterns.md#reserve-first-exception-safety)** for detailed explanation and real-world examples.

## BoundedArray Replacement

`std.BoundedArray` was REMOVED in 0.15.x. Use `initBuffer` instead:

```zig
// OLD (removed)
var arr = std.BoundedArray(u8, 64){};

// NEW
var buffer: [64]u8 = undefined;
var arr = std.ArrayList(u8).initBuffer(&buffer);
// Note: Operations will panic if capacity exceeded
try arr.appendBounded(value);  // returns error.OutOfMemory if full
```
