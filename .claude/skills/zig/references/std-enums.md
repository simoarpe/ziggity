# std.enums

Utilities for working with enums: sets, maps, arrays, and iteration backed by bit operations.

## EnumSet

Bit-backed set of enum values. Zero allocation, copyable by value.

```zig
const std = @import("std");

const Color = enum { red, green, blue, yellow };
const ColorSet = std.enums.EnumSet(Color);

// Initialize
var colors = ColorSet.initEmpty();
var all = ColorSet.initFull();

// Struct-style init
var primary = ColorSet.init(.{
    .red = true,
    .green = true,
    .blue = true,
    .yellow = false,
});

// From slice
var some = ColorSet.initMany(&.{ .red, .blue });

// Single element
var just_red = ColorSet.initOne(.red);
```

## EnumSet Operations

```zig
// Insert/remove
colors.insert(.red);
colors.remove(.blue);
colors.toggle(.green);
colors.setPresent(.yellow, true);

// Check
if (colors.contains(.red)) {
    // red is in set
}

const n = colors.count();  // number of elements

// Set operations (in-place)
colors.setUnion(other);        // add all from other
colors.setIntersection(other); // keep only common
colors.toggleSet(other);       // XOR
colors.toggleAll();            // invert all

// Set operations (return new set)
const u = colors.unionWith(other);
const i = colors.intersectWith(other);
const x = colors.xorWith(other);
const d = colors.differenceWith(other);  // colors - other
const c = colors.complement();           // all except colors

// Comparison
if (colors.eql(other)) { }
if (colors.subsetOf(other)) { }
if (colors.supersetOf(other)) { }
```

## EnumSet Iteration

```zig
var it = colors.iterator();
while (it.next()) |color| {
    std.debug.print("{}\n", .{color});
}
```

## EnumMap

Map from enum to value. Fixed-size, zero allocation.

```zig
const Color = enum { red, green, blue };
const ColorMap = std.enums.EnumMap(Color, u32);

// Empty map
var map = ColorMap{};

// Struct-style init (null = not present)
var scores = ColorMap.init(.{
    .red = 100,
    .green = 50,
    .blue = null,  // not in map
});
```

## EnumMap Operations

```zig
// Insert
map.put(.red, 42);

// Get
if (map.get(.red)) |value| {
    std.debug.print("red = {}\n", .{value});
}

// Get with default
const value = map.getOrDefault(.blue, 0);

// Get pointer
if (map.getPtr(.red)) |ptr| {
    ptr.* += 1;  // modify in place
}

// Remove
map.remove(.red);

// Check
if (map.contains(.red)) { }

// Count
const n = map.count();
```

## EnumMap Iteration

```zig
// Iterate entries
var it = map.iterator();
while (it.next()) |entry| {
    std.debug.print("{}: {}\n", .{ entry.key, entry.value.* });
}

// Iterate keys only
var key_it = map.keyIterator();
while (key_it.next()) |key| {
    std.debug.print("{}\n", .{key});
}
```

## EnumArray

Dense array indexed by enum. All values always present.

```zig
const Color = enum { red, green, blue };
const ColorArray = std.enums.EnumArray(Color, u32);

// Initialize all to same value
var arr = ColorArray.initFill(0);

// Struct-style init (all must be present)
var rgb = ColorArray.init(.{
    .red = 255,
    .green = 128,
    .blue = 64,
});

// Access
const r = rgb.get(.red);     // 255
rgb.set(.green, 200);
rgb.getPtr(.blue).* = 100;
```

## EnumArray Iteration

```zig
// By key
for (std.enums.values(Color)) |color| {
    std.debug.print("{}: {}\n", .{ color, rgb.get(color) });
}

// Direct slice access
const slice = rgb.values;  // [3]u32
```

## EnumIndexer

Convert between enum values and dense indices.

```zig
const Indexer = std.enums.EnumIndexer(Color);

const idx = Indexer.indexOf(.green);   // 1
const color = Indexer.keyForIndex(1);  // .green
const count = Indexer.count;           // 3
```

## Utility Functions

```zig
// Get all values as slice
const colors = std.enums.values(Color);  // [3]Color

// Safe tag name (works with non-exhaustive)
const name = std.enums.tagName(Color, .red);  // "red" or null

// Safe int-to-enum
const maybe = std.enums.fromInt(Color, 1);  // ?.green
```

## Direct Enum Array (Sparse Enums)

For enums with gaps in values:

```zig
const Sparse = enum(u8) { a = 1, b = 5, c = 10 };

// Create array indexed by enum int value
const arr = std.enums.directEnumArray(
    Sparse,
    bool,
    8,  // max_unused_slots (gaps allowed)
    .{ .a = true, .b = false, .c = true },
);
// arr is [11]bool, indexed by @intFromEnum
```

## Complete Example: Permission System

```zig
const std = @import("std");

const Permission = enum {
    read,
    write,
    execute,
    admin,
};

const Permissions = std.enums.EnumSet(Permission);

const User = struct {
    name: []const u8,
    perms: Permissions,
};

fn canAccess(user: User, required: Permissions) bool {
    // User must have all required permissions
    return required.subsetOf(user.perms);
}

pub fn main() void {
    const admin = User{
        .name = "admin",
        .perms = Permissions.initFull(),
    };

    const reader = User{
        .name = "reader",
        .perms = Permissions.initOne(.read),
    };

    const write_required = Permissions.initMany(&.{ .read, .write });

    std.debug.print("admin can write: {}\n", .{canAccess(admin, write_required)});   // true
    std.debug.print("reader can write: {}\n", .{canAccess(reader, write_required)}); // false
}
```

## Complete Example: State Machine Transitions

```zig
const std = @import("std");

const State = enum { idle, running, paused, stopped };
const Event = enum { start, pause, resume, stop };

const TransitionMap = std.enums.EnumMap(Event, State);
const StateTransitions = std.enums.EnumArray(State, TransitionMap);

const transitions = StateTransitions.init(.{
    .idle = TransitionMap.init(.{ .start = .running, .stop = .stopped }),
    .running = TransitionMap.init(.{ .pause = .paused, .stop = .stopped }),
    .paused = TransitionMap.init(.{ .resume = .running, .stop = .stopped }),
    .stopped = TransitionMap{},  // no transitions from stopped
});

fn nextState(current: State, event: Event) ?State {
    return transitions.get(current).get(event);
}

pub fn main() void {
    var state = State.idle;
    state = nextState(state, .start) orelse state;  // -> running
    state = nextState(state, .pause) orelse state;  // -> paused
    state = nextState(state, .resume) orelse state; // -> running
    std.debug.print("Final state: {}\n", .{state});
}
```

## Notes

- `EnumSet`: Bit-backed, use for presence tracking
- `EnumMap`: Sparse, only stores present values
- `EnumArray`: Dense, all values always present
- All are fixed-size, zero-allocation, copyable by value
- Use `std.StaticBitSet` for non-enum integer sets
- Works with non-exhaustive enums (explicit fields only)
