# std.PriorityDequeue

A min-max heap that efficiently supports both min and max extraction. Unlike `PriorityQueue`, you can pop from either end.

## When to Use

- Need both min and max extraction
- Double-ended priority queue
- Sliding window min/max
- Median maintenance (with two heaps)

## Initialization

```zig
const std = @import("std");

fn compare(context: void, a: u32, b: u32) std.math.Order {
    _ = context;
    return std.math.order(a, b);
}

const PDQ = std.PriorityDequeue(u32, void, compare);

var dequeue = PDQ.init(allocator, {});
defer dequeue.deinit();
```

## Basic Operations

```zig
// Add elements
try dequeue.add(54);
try dequeue.add(12);
try dequeue.add(7);

// Add multiple
try dequeue.addSlice(&[_]u32{ 1, 2, 3 });

// Peek at min/max (doesn't remove)
if (dequeue.peekMin()) |min| {
    std.debug.print("min: {}\n", .{min});
}
if (dequeue.peekMax()) |max| {
    std.debug.print("max: {}\n", .{max});
}

// Remove min/max
const min = dequeue.removeMin();        // asserts non-empty
const max = dequeue.removeMax();        // asserts non-empty

// Safe removal (returns null if empty)
const maybe_min = dequeue.removeMinOrNull();
const maybe_max = dequeue.removeMaxOrNull();

// Size
const n = dequeue.count();
const cap = dequeue.capacity();
```

## From Existing Slice

```zig
// Take ownership of slice, heapify in place
var items = try allocator.dupe(u32, &[_]u32{ 5, 3, 8, 1, 2 });
var dequeue = PDQ.fromOwnedSlice(allocator, items, {});
defer dequeue.deinit();
```

## Update Priority

```zig
try dequeue.update(old_value, new_value);
// Error if old_value not found
```

## Remove by Index

```zig
const removed = dequeue.removeIndex(index);
```

## Iteration

```zig
// Iterate (order is NOT priority order)
var it = dequeue.iterator();
while (it.next()) |elem| {
    // process elem
}
it.reset();
```

## Capacity Management

```zig
try dequeue.ensureTotalCapacity(100);
try dequeue.ensureUnusedCapacity(10);
dequeue.shrinkAndFree(new_capacity);
```

## Context-Based Comparator

```zig
fn compareByScore(scores: []const u32, a: usize, b: usize) std.math.Order {
    return std.math.order(scores[a], scores[b]);
}

const IndexPDQ = std.PriorityDequeue(usize, []const u32, compareByScore);

const scores = [_]u32{ 50, 30, 80, 20 };
var dequeue = IndexPDQ.init(allocator, &scores);
```

## Complete Example: Bounded Range Tracker

```zig
const std = @import("std");

fn order(_: void, a: i32, b: i32) std.math.Order {
    return std.math.order(a, b);
}

const RangePDQ = std.PriorityDequeue(i32, void, order);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var tracker = RangePDQ.init(gpa.allocator(), {});
    defer tracker.deinit();

    // Add values
    try tracker.add(10);
    try tracker.add(5);
    try tracker.add(20);
    try tracker.add(3);
    try tracker.add(15);

    // Get range without removing
    const min = tracker.peekMin().?;  // 3
    const max = tracker.peekMax().?;  // 20
    const range = max - min;           // 17

    std.debug.print("Range: {} to {} = {}\n", .{ min, max, range });

    // Pop from both ends
    _ = tracker.removeMin();  // removes 3
    _ = tracker.removeMax();  // removes 20

    // New range is 5 to 15
}
```

## Difference from PriorityQueue

| Feature | PriorityQueue | PriorityDequeue |
|---------|--------------|-----------------|
| Pop min | Yes | Yes |
| Pop max | No (unless you reverse comparator) | Yes |
| Peek min | Yes | Yes |
| Peek max | No | Yes |
| Structure | Binary heap | Min-max heap |

## Notes

- Both `removeMin()` and `removeMax()` are O(log n)
- `peekMin()` is O(1), `peekMax()` is O(1) after first 2 elements
- Iterator order is heap array order, not priority order
- Use when you need efficient access to both extremes
