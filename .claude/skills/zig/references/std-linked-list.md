# std.DoublyLinkedList / std.SinglyLinkedList

Intrusive linked lists for O(1) insertion/removal. Nodes are embedded in user structs via `@fieldParentPtr`.

## When to Use

- O(1) insertion/removal anywhere in list
- Elements that need to be in multiple lists
- Preallocated/arena-allocated nodes
- No allocation on insert (nodes already exist)

## DoublyLinkedList

Bidirectional traversal, O(1) removal of any node.

```zig
const std = @import("std");

const Item = struct {
    data: u32,
    node: std.DoublyLinkedList.Node = .{},  // embed node
};

var list: std.DoublyLinkedList = .{};

// Create items (you manage memory)
var a: Item = .{ .data = 1 };
var b: Item = .{ .data = 2 };
var c: Item = .{ .data = 3 };

// Insert
list.append(&a.node);         // add to end
list.prepend(&b.node);        // add to start
list.insertAfter(&a.node, &c.node);   // insert c after a
list.insertBefore(&a.node, &c.node);  // insert c before a

// Remove
list.remove(&a.node);         // O(1) remove specific node
const last = list.pop();      // remove and return last
const first = list.popFirst(); // remove and return first

// Get data from node
if (list.first) |node| {
    const item: *Item = @fieldParentPtr("node", node);
    std.debug.print("data: {}\n", .{item.data});
}

// Traverse forward
var it = list.first;
while (it) |node| : (it = node.next) {
    const item: *Item = @fieldParentPtr("node", node);
    // use item.data
}

// Traverse backward
var it = list.last;
while (it) |node| : (it = node.prev) {
    const item: *Item = @fieldParentPtr("node", node);
    // use item.data
}

// Concatenate (moves all from list2 to end of list1)
list1.concatByMoving(&list2);

// Length (O(n) - consider tracking separately)
const n = list.len();
```

## SinglyLinkedList

Forward-only, minimal memory (one pointer per node).

```zig
const Item = struct {
    data: u32,
    node: std.SinglyLinkedList.Node = .{},
};

var list: std.SinglyLinkedList = .{};

var a: Item = .{ .data = 1 };
var b: Item = .{ .data = 2 };

// Insert (only at front or after existing node)
list.prepend(&a.node);         // add to front
a.node.insertAfter(&b.node);   // insert b after a

// Remove
const first = list.popFirst(); // remove and return first
_ = a.node.removeNext();       // remove node after a
list.remove(&b.node);          // O(n) - must find predecessor

// Traverse (forward only)
var it = list.first;
while (it) |node| : (it = node.next) {
    const item: *Item = @fieldParentPtr("node", node);
    // use item.data
}

// Find last (O(n))
if (list.first) |first| {
    const last = first.findLast();
}

// Reverse in place
std.SinglyLinkedList.Node.reverse(&list.first);

// Length (O(n))
const n = list.len();
```

## Node Methods

```zig
// DoublyLinkedList.Node
node.prev  // ?*Node
node.next  // ?*Node

// SinglyLinkedList.Node
node.next           // ?*Node
node.insertAfter(new_node)
node.removeNext()   // ?*Node - removes and returns next
node.findLast()     // *Node
node.countChildren() // usize
node.reverse(&optional_ptr)
```

## Common Pattern: LRU Cache

```zig
const Entry = struct {
    key: []const u8,
    value: Value,
    node: std.DoublyLinkedList.Node = .{},
};

var lru_list: std.DoublyLinkedList = .{};
var entries: std.StringHashMap(*Entry) = .init(allocator);

fn access(key: []const u8) ?*Entry {
    const entry = entries.get(key) orelse return null;
    // Move to front (most recently used)
    lru_list.remove(&entry.node);
    lru_list.prepend(&entry.node);
    return entry;
}

fn evictOldest() void {
    if (lru_list.pop()) |node| {
        const entry: *Entry = @fieldParentPtr("node", node);
        _ = entries.remove(entry.key);
        // free entry
    }
}
```
