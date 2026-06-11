# std.Treap

A self-balancing binary search tree using randomized priorities. Combines BST ordering with heap-based balancing for expected O(log n) operations.

## When to Use

- Need ordered key storage with fast lookup/insert/delete
- Require in-order iteration
- Need min/max access
- Predecessor/successor queries

## Initialization

```zig
const std = @import("std");

// Define treap with key type and comparator
const MyTreap = std.Treap(u64, std.math.order);

var treap: MyTreap = .{};
```

## Node Structure

Nodes are user-managed (intrusive design):

```zig
var nodes: [100]MyTreap.Node = undefined;

// Node fields (managed by treap):
// - key: Key
// - priority: usize (random, for balancing)
// - parent: ?*Node
// - children: [2]?*Node
```

## Insert via Entry API

```zig
// Get entry for a key (like a "slot" in the treap)
var entry = treap.getEntryFor(key);

if (entry.node == null) {
    // Key not present, insert new node
    entry.set(&nodes[i]);  // node content initialized by treap
}
```

## Lookup

```zig
// Find by key
var entry = treap.getEntryFor(key);
if (entry.node) |node| {
    // found, node.key == key
}

// Get entry for existing node (O(1) if you have the node)
var entry = treap.getEntryForExisting(node);
```

## Remove

```zig
var entry = treap.getEntryFor(key);
entry.set(null);  // removes the node

// Or if you have the node:
var entry = treap.getEntryForExisting(node);
entry.set(null);
```

## Replace

```zig
var entry = treap.getEntryForExisting(old_node);
entry.set(&new_node);  // replaces old with new (same key)
```

## Min/Max Access

```zig
// Get smallest key
if (treap.getMin()) |min_node| {
    std.debug.print("min key: {}\n", .{min_node.key});
}

// Get largest key
if (treap.getMax()) |max_node| {
    std.debug.print("max key: {}\n", .{max_node.key});
}
```

## Predecessor/Successor

```zig
// Next larger key
if (node.next()) |successor| {
    // successor.key > node.key
}

// Previous smaller key
if (node.prev()) |predecessor| {
    // predecessor.key < node.key
}
```

## In-Order Iteration

```zig
// Iterate keys in sorted order (smallest to largest)
var iter = treap.inorderIterator();
while (iter.next()) |node| {
    std.debug.print("key: {}\n", .{node.key});
}
```

## Custom Comparator

```zig
fn compareStrings(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

const StringTreap = std.Treap([]const u8, compareStrings);
```

## Complete Example

```zig
const std = @import("std");
const Treap = std.Treap(u64, std.math.order);

pub fn main() !void {
    var treap: Treap = .{};
    var nodes: [10]Treap.Node = undefined;

    // Insert keys 0-9
    for (0..10) |i| {
        var entry = treap.getEntryFor(@intCast(i));
        entry.set(&nodes[i]);
    }

    // Find key 5
    var entry = treap.getEntryFor(5);
    if (entry.node) |node| {
        std.debug.print("found: {}\n", .{node.key});

        // Get neighbors
        if (node.prev()) |p| std.debug.print("prev: {}\n", .{p.key});
        if (node.next()) |n| std.debug.print("next: {}\n", .{n.key});
    }

    // Iterate in order
    var iter = treap.inorderIterator();
    while (iter.next()) |node| {
        std.debug.print("{} ", .{node.key});
    }
    // Output: 0 1 2 3 4 5 6 7 8 9

    // Remove key 5
    entry.set(null);
}
```

## Notes

- No allocator needed (nodes are user-managed)
- Balancing uses randomized priorities (xorshift PRNG)
- `node.priority == 0` indicates node is not in treap
- Entry API allows atomic check-and-modify patterns
