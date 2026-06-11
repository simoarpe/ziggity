# std.sort

Sorting algorithms and binary search utilities. All sorts are in-place and require no allocator.

## Quick Reference

| Function | Stable | Complexity | When to Use |
|----------|--------|------------|-------------|
| `block` | Yes | O(n log n) | Default choice when stability matters |
| `pdq` | No | O(n log n) | Default choice when stability doesn't matter |
| `insertion` | Yes | O(n²) | Small arrays (<20), nearly sorted data |
| `heap` | No | O(n log n) | Guaranteed worst-case, no recursion |

## Comparator Functions

All sort functions take a `lessThan` comparator:

```zig
const std = @import("std");

// Simple comparator (ascending)
fn lessThan(_: void, a: i32, b: i32) bool {
    return a < b;
}

// Use built-in generators for common cases
const asc_i32 = std.sort.asc(i32);   // ascending
const desc_i32 = std.sort.desc(i32); // descending
```

## Basic Sorting

```zig
var items = [_]i32{ 5, 2, 8, 1, 9 };

// Unstable sort (fastest general-purpose)
std.sort.pdq(i32, &items, {}, std.sort.asc(i32));
// items = [1, 2, 5, 8, 9]

// Stable sort (preserves order of equal elements)
std.sort.block(i32, &items, {}, std.sort.asc(i32));

// Descending order
std.sort.pdq(i32, &items, {}, std.sort.desc(i32));
// items = [9, 8, 5, 2, 1]
```

## Sorting with Context

Pass external data to the comparator:

```zig
const scores = [_]u32{ 50, 30, 80, 20 };
var indices = [_]usize{ 0, 1, 2, 3 };

fn compareByScore(scores_ctx: []const u32, a: usize, b: usize) bool {
    return scores_ctx[a] < scores_ctx[b];
}

std.sort.pdq(usize, &indices, &scores, compareByScore);
// indices = [3, 1, 0, 2] (sorted by score: 20, 30, 50, 80)
```

## Sorting Structs

```zig
const Person = struct {
    name: []const u8,
    age: u32,
};

fn byAge(_: void, a: Person, b: Person) bool {
    return a.age < b.age;
}

var people = [_]Person{
    .{ .name = "Alice", .age = 30 },
    .{ .name = "Bob", .age = 25 },
    .{ .name = "Carol", .age = 35 },
};

std.sort.pdq(Person, &people, {}, byAge);
// Sorted: Bob (25), Alice (30), Carol (35)
```

## Check if Sorted

```zig
const items = [_]i32{ 1, 2, 3, 4, 5 };
const sorted = std.sort.isSorted(i32, &items, {}, std.sort.asc(i32));
// true
```

## Binary Search

Find element in sorted array. Comparator returns `Order` (.lt, .eq, .gt):

```zig
fn order(target: i32, item: i32) std.math.Order {
    return std.math.order(target, item);
}

const items = [_]i32{ 1, 3, 5, 7, 9 };

// Find exact match
const idx = std.sort.binarySearch(i32, &items, @as(i32, 5), order);
// ?usize = 2

// Not found
const missing = std.sort.binarySearch(i32, &items, @as(i32, 4), order);
// null
```

## Lower/Upper Bound

Find insertion points for sorted arrays:

```zig
fn order(target: i32, item: i32) std.math.Order {
    return std.math.order(target, item);
}

const items = [_]i32{ 1, 3, 5, 5, 5, 7, 9 };

// First position where target could be inserted (first >= target)
const lower = std.sort.lowerBound(i32, &items, @as(i32, 5), order);
// 2 (first 5)

// First position after all equal elements (first > target)
const upper = std.sort.upperBound(i32, &items, @as(i32, 5), order);
// 5 (after last 5)

// Both bounds at once
const range = std.sort.equalRange(i32, &items, @as(i32, 5), order);
// .{ 2, 5 } (indices of all 5s)
```

## Partition Point

Find where predicate changes from true to false:

```zig
fn lessThan5(_: void, item: i32) bool {
    return item < 5;
}

const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7 };
const point = std.sort.partitionPoint(i32, &items, {}, lessThan5);
// 4 (first index where predicate is false)
```

## Min/Max

```zig
const items = [_]i32{ 5, 2, 8, 1, 9 };

// Get min/max value
const minimum = std.sort.min(i32, &items, {}, std.sort.asc(i32));  // ?i32 = 1
const maximum = std.sort.max(i32, &items, {}, std.sort.asc(i32));  // ?i32 = 9

// Get index of min/max
const min_idx = std.sort.argMin(i32, &items, {}, std.sort.asc(i32));  // ?usize = 3
const max_idx = std.sort.argMax(i32, &items, {}, std.sort.asc(i32));  // ?usize = 4

// Empty slice returns null
const empty: []const i32 = &.{};
const none = std.sort.min(i32, empty, {}, std.sort.asc(i32));  // null
```

## Context-Based Sorting (Advanced)

For sorting indices into external data using index-based context:

```zig
const Context = struct {
    items: []i32,

    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        return ctx.items[a] < ctx.items[b];
    }

    pub fn swap(ctx: @This(), a: usize, b: usize) void {
        std.mem.swap(i32, &ctx.items[a], &ctx.items[b]);
    }
};

var items = [_]i32{ 5, 2, 8, 1 };
const ctx = Context{ .items = &items };

// Sort a subrange using indices
std.sort.pdqContext(1, 4, ctx);  // sort indices 1..4
// items = [5, 1, 2, 8]
```

## Stable Sort Example

When sorting by one field but preserving order of equal elements:

```zig
const Item = struct {
    id: usize,
    priority: u32,
};

fn byPriority(_: void, a: Item, b: Item) bool {
    return a.priority < b.priority;
}

var items = [_]Item{
    .{ .id = 0, .priority = 1 },
    .{ .id = 1, .priority = 1 },  // same priority as id=0
    .{ .id = 2, .priority = 0 },
};

// Stable sort preserves id order for equal priorities
std.sort.block(Item, &items, {}, byPriority);
// Result: {id=2, p=0}, {id=0, p=1}, {id=1, p=1}
//         id=0 still comes before id=1
```

## Algorithm Selection

- **`pdq`** (Pattern-Defeating Quicksort): Best general-purpose unstable sort. Adapts to input patterns, falls back to heapsort for worst cases.
- **`block`**: Best general-purpose stable sort. Preserves relative order of equal elements.
- **`insertion`**: O(n) on nearly sorted data. Use for small arrays or as final pass.
- **`heap`**: Guaranteed O(n log n) with O(1) memory. No recursion, predictable performance.

## Notes

- All sorts are **in-place** with O(1) or O(log n) auxiliary memory
- Comparators must define strict weak ordering (if `a < b` then not `b < a`)
- `asc`/`desc` helpers work with any type supporting `<` operator
- Binary search functions require the array to already be sorted
- `equalRange` is more efficient than calling `lowerBound` + `upperBound` separately
