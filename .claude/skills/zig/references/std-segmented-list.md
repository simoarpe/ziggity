# std.SegmentedList

A dynamic list where element pointers remain stable across growth. Unlike ArrayList, appending never invalidates existing pointers. Elements are stored in exponentially-sized segments.

## When to Use

- Need stable pointers to elements (pointers survive append)
- Arena allocator backing (avoids wasted memory on reallocation)
- Non-copyable element types
- Stack-like access patterns (append/pop)

## Trade-offs

- Elements not contiguous (most are, but not guaranteed)
- O(log n) random access (vs O(1) for ArrayList)
- Higher per-element overhead

## Initialization

```zig
// Without preallocation
var list = std.SegmentedList(i32, 0){};
defer list.deinit(allocator);

// With preallocation (must be power of 2)
// First N elements stored inline, no allocation needed
var list = std.SegmentedList(i32, 16){};
defer list.deinit(allocator);
```

## Basic Operations

```zig
// Append (pointer remains valid forever)
try list.append(allocator, 42);
try list.appendSlice(allocator, &[_]i32{ 1, 2, 3 });

// Get pointer to element (STABLE across appends)
const ptr = list.at(0);  // *i32
ptr.* = 100;             // modify in place

// Add and get pointer in one operation
const new_ptr = try list.addOne(allocator);
new_ptr.* = 42;

// Pop
const last = list.pop();  // ?i32

// Length
const n = list.count();
// Or: list.len
```

## Iteration

```zig
// Forward iteration with mutable access
var it = list.iterator(0);  // start at index 0
while (it.next()) |ptr| {
    ptr.* += 1;  // modify in place
}

// Const iteration
var it = list.constIterator(0);
while (it.next()) |ptr| {
    std.debug.print("{}\n", .{ptr.*});
}

// Bidirectional
while (it.prev()) |ptr| {
    // ...
}

// Peek without advancing
if (it.peek()) |ptr| {
    // ...
}

// Jump to index
it.set(50);
```

## Capacity Management

```zig
// Grow capacity
try list.growCapacity(allocator, 100);
try list.setCapacity(allocator, 100);  // grow or shrink

// Shrink
list.shrinkCapacity(allocator, 50);  // may fail silently
list.shrinkRetainingCapacity(new_len);

// Clear
list.clearRetainingCapacity();
list.clearAndFree(allocator);
```

## Copy to Contiguous Slice

```zig
var dest: [100]i32 = undefined;
list.writeToSlice(&dest, 0);  // copy from index 0

// Copy subset
list.writeToSlice(dest[50..], 50);  // copy starting at index 50
```

## Memory Layout

Segments grow exponentially:
```
prealloc=0:  shelf 0: 1 element
             shelf 1: 2 elements
             shelf 2: 4 elements
             ...

prealloc=4:  prealloc: 4 elements (inline)
             shelf 0: 8 elements
             shelf 1: 16 elements
             ...
```

## Common Pattern: Object Pool with Stable References

```zig
const Object = struct {
    data: [1024]u8,
    next: ?*Object,
};

var pool = std.SegmentedList(Object, 64){};

// Create objects - pointers remain valid
const obj1 = try pool.addOne(allocator);
const obj2 = try pool.addOne(allocator);
obj1.next = obj2;  // safe: obj2 pointer won't change
```
