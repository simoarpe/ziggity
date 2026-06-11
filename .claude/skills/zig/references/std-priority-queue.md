# std.PriorityQueue

A binary heap-based priority queue. Efficiently retrieves elements by priority order.

## When to Use

- Need to repeatedly extract min or max element
- Task scheduling by priority
- Dijkstra's algorithm, A* pathfinding
- Event-driven simulation (process earliest event first)

## Initialization

```zig
const std = @import("std");

// Min-heap comparator (smallest first)
fn lessThan(context: void, a: u32, b: u32) std.math.Order {
    _ = context;
    return std.math.order(a, b);
}

const PQ = std.PriorityQueue(u32, void, lessThan);

var queue = PQ.init(allocator, {});
defer queue.deinit();
```

## Max-Heap

```zig
fn greaterThan(context: void, a: u32, b: u32) std.math.Order {
    _ = context;
    return std.math.order(a, b).invert();
}

const MaxPQ = std.PriorityQueue(u32, void, greaterThan);
```

## Basic Operations

```zig
// Add elements
try queue.add(54);
try queue.add(12);
try queue.add(7);

// Add multiple
try queue.addSlice(&[_]u32{ 1, 2, 3 });

// Peek at highest priority (doesn't remove)
if (queue.peek()) |top| {
    std.debug.print("top: {}\n", .{top});  // 7 for min-heap
}

// Remove highest priority
const top = queue.remove();       // asserts non-empty
const maybe = queue.removeOrNull(); // returns ?T

// Size
const n = queue.count();
const cap = queue.capacity();
```

## From Existing Slice

```zig
// Take ownership of slice, heapify in place
var items = try allocator.dupe(u32, &[_]u32{ 5, 3, 8, 1, 2 });
var queue = PQ.fromOwnedSlice(allocator, items, {});
defer queue.deinit();
// Now queue is a valid heap
```

## Update Priority

```zig
// Change priority of existing element
try queue.update(old_value, new_value);
// Error if old_value not found
```

## Remove by Index

```zig
// Remove element at specific position (not priority order)
const removed = queue.removeIndex(index);
```

## Iteration (Non-Priority Order)

```zig
// Iterate without removing (order is NOT priority order!)
var it = queue.iterator();
while (it.next()) |elem| {
    // process elem
}
it.reset();  // restart iteration
```

## Capacity Management

```zig
try queue.ensureTotalCapacity(100);
try queue.ensureUnusedCapacity(10);
queue.shrinkAndFree(new_capacity);
queue.clearRetainingCapacity();
queue.clearAndFree();
```

## Context-Based Comparator

For comparing by external data (e.g., indices into an array):

```zig
fn compareByScore(scores: []const u32, a: usize, b: usize) std.math.Order {
    return std.math.order(scores[a], scores[b]);
}

const IndexPQ = std.PriorityQueue(usize, []const u32, compareByScore);

const scores = [_]u32{ 50, 30, 80, 20 };
var queue = IndexPQ.init(allocator, &scores);
defer queue.deinit();

try queue.add(0);  // score 50
try queue.add(1);  // score 30
try queue.add(2);  // score 80
try queue.add(3);  // score 20

// Removes index 3 (score 20 is smallest)
const best = queue.remove();  // 3
```

## Complete Example: Task Scheduler

```zig
const std = @import("std");

const Task = struct {
    name: []const u8,
    priority: u32,  // lower = more urgent
};

fn taskCompare(_: void, a: Task, b: Task) std.math.Order {
    return std.math.order(a.priority, b.priority);
}

const TaskQueue = std.PriorityQueue(Task, void, taskCompare);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var tasks = TaskQueue.init(gpa.allocator(), {});
    defer tasks.deinit();

    try tasks.add(.{ .name = "low priority", .priority = 100 });
    try tasks.add(.{ .name = "urgent", .priority = 1 });
    try tasks.add(.{ .name = "medium", .priority = 50 });

    while (tasks.removeOrNull()) |task| {
        std.debug.print("Processing: {s}\n", .{task.name});
    }
    // Output:
    // Processing: urgent
    // Processing: medium
    // Processing: low priority
}
```

## Notes

- Heap property: parent has higher priority than children
- `remove()` is O(log n), `peek()` is O(1)
- Iterator order is NOT priority order (it's heap array order)
- Use `removeOrNull()` for safe extraction from potentially empty queue
