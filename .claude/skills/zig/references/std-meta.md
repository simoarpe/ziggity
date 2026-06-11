# std.meta

Comptime type introspection and manipulation utilities. Essential for generic programming, serialization, and metaprogramming.

## Quick Reference

| Function | Purpose |
|----------|---------|
| `stringToEnum(T, str)` | Convert string to enum variant |
| `fields(T)` | Get struct/union/enum/error fields |
| `fieldNames(T)` | Get field names as string slice |
| `fieldInfo(T, field)` | Get info for specific field |
| `fieldIndex(T, name)` | Get field index by name |
| `tags(T)` | Get all enum/error set values |
| `Tag(T)` | Get tag type of enum/union |
| `activeTag(u)` | Get active variant of tagged union |
| `eql(a, b)` | Deep equality comparison |
| `Child(T)` | Get child type of pointer/array/optional |
| `Elem(T)` | Get element type of memory span |
| `sentinel(T)` | Get sentinel value if any |
| `FieldEnum(T)` | Generate enum from field names |
| `hasFn(T, name)` | Check if type has function |
| `hasMethod(T, name)` | Check if type has method |

## String to Enum Conversion

```zig
const std = @import("std");

const Color = enum { red, green, blue };

// Convert runtime string to enum
const color = std.meta.stringToEnum(Color, "green");
if (color) |c| {
    // c == Color.green
}

// Returns null for invalid strings
const invalid = std.meta.stringToEnum(Color, "purple");  // null
```

Uses `StaticStringMap` for small enums (≤100 variants), inline iteration for larger ones.

## Field Introspection

### Get All Fields

```zig
const Point = struct {
    x: f32,
    y: f32,
    z: f32 = 0,
};

// Get struct fields
const point_fields = std.meta.fields(Point);
// point_fields.len == 3
// point_fields[0].name == "x"
// point_fields[0].type == f32

// Works for unions
const Result = union { ok: u32, err: []const u8 };
const union_fields = std.meta.fields(Result);

// Works for enums
const Status = enum { pending, done };
const enum_fields = std.meta.fields(Status);

// Works for error sets
const MyError = error{ NotFound, Timeout };
const error_fields = std.meta.fields(MyError);
```

### Get Field Names

```zig
const names = std.meta.fieldNames(Point);
// names.* == .{ "x", "y", "z" }

for (names) |name| {
    std.debug.print("{s}\n", .{name});
}
```

### Get Specific Field

```zig
// By enum literal
const x_info = std.meta.fieldInfo(Point, .x);
// x_info.name == "x"
// x_info.type == f32
// x_info.default_value_ptr == null

const z_info = std.meta.fieldInfo(Point, .z);
// z_info.default_value_ptr != null (has default 0)

// Get field index
const idx = std.meta.fieldIndex(Point, "y");  // 1
const bad = std.meta.fieldIndex(Point, "w");  // null
```

## Enum/Union Tag Operations

### Get Tag Type

```zig
const Status = enum(u8) { active = 1, inactive = 2 };
const TagInt = std.meta.Tag(Status);  // u8

const Tagged = union(enum) { a: u32, b: f32 };
const TagEnum = std.meta.Tag(Tagged);  // enum { a, b }
```

### Get Active Tag

```zig
const Value = union(enum) { int: i32, float: f32 };

var v = Value{ .int = 42 };
const tag = std.meta.activeTag(v);  // Value.int

switch (tag) {
    .int => std.debug.print("integer\n", .{}),
    .float => std.debug.print("float\n", .{}),
}
```

### Get All Tags

```zig
const Color = enum { red, green, blue };
const colors = std.meta.tags(Color);
// colors.* == .{ Color.red, Color.green, Color.blue }

const MyError = error{ A, B };
const errors = std.meta.tags(MyError);
// errors.* == .{ MyError.A, MyError.B }
```

## Type Construction

### FieldEnum - Generate Enum from Fields

```zig
const Point = struct { x: f32, y: f32 };
const PointField = std.meta.FieldEnum(Point);
// Equivalent to: enum { x, y }

// Iterate fields generically
inline for (std.meta.tags(PointField)) |field| {
    const info = std.meta.fieldInfo(Point, field);
    std.debug.print("{s}: {s}\n", .{ info.name, @typeName(info.type) });
}
```

For tagged unions, returns the existing tag type if compatible.

### DeclEnum - Generate Enum from Declarations

```zig
const Api = struct {
    pub fn getUser() void {}
    pub fn deleteUser() void {}
};

const ApiMethod = std.meta.DeclEnum(Api);
// Equivalent to: enum { getUser, deleteUser }
```

### Int/Float Type Construction

```zig
const U24 = std.meta.Int(.unsigned, 24);  // u24
const I7 = std.meta.Int(.signed, 7);      // i7
const F32 = std.meta.Float(32);           // f32
const F16 = std.meta.Float(16);           // f16
```

### Tuple Construction

```zig
// From type array
const T1 = std.meta.Tuple(&.{ u32, f32, bool });
// Equivalent to: struct { u32, f32, bool }

// From function signature
const T2 = std.meta.ArgsTuple(fn (u32, f32) void);
// Equivalent to: struct { u32, f32 }
```

## Child/Element Types

### Child - Direct Child Type

```zig
std.meta.Child(*u8)       // u8
std.meta.Child([]u8)      // u8
std.meta.Child([5]u8)     // u8
std.meta.Child(?u8)       // u8
std.meta.Child(@Vector(4, f32))  // f32
```

### Elem - Element Type of Memory Spans

```zig
std.meta.Elem([5]u8)      // u8
std.meta.Elem([]u8)       // u8
std.meta.Elem([*]u8)      // u8
std.meta.Elem(*[10]u8)    // u8 (through pointer to array)
std.meta.Elem(?[*]u8)     // u8 (through optional)
```

### Sentinel

```zig
std.meta.sentinel([:0]u8)      // @as(u8, 0)
std.meta.sentinel([*:0]u8)     // @as(u8, 0)
std.meta.sentinel([5:0]u8)     // @as(u8, 0)
std.meta.sentinel([]u8)        // null
std.meta.sentinel([5]u8)       // null
```

### Sentinel Type Construction

```zig
// Add sentinel to type
const S1 = std.meta.Sentinel([]u8, 0);   // [:0]u8
const S2 = std.meta.Sentinel([*]u8, 0);  // [*:0]u8
```

## Deep Equality

```zig
const std = @import("std");

const Point = struct { x: i32, y: i32 };

const p1 = Point{ .x = 1, .y = 2 };
const p2 = Point{ .x = 1, .y = 2 };
const p3 = Point{ .x = 1, .y = 3 };

std.meta.eql(p1, p2)  // true
std.meta.eql(p1, p3)  // false

// Works with nested structs, arrays, optionals, error unions
const Complex = struct {
    data: [3]u8,
    opt: ?i32,
};

const a = Complex{ .data = .{ 1, 2, 3 }, .opt = 42 };
const b = Complex{ .data = .{ 1, 2, 3 }, .opt = 42 };
std.meta.eql(a, b)  // true

// Pointers compared by address, not content
std.meta.eql(&p1, &p2)  // false (different addresses)
std.meta.eql(&p1, &p1)  // true
```

**Supported types:** structs, arrays, vectors, optionals, error unions, tagged unions, primitives.

**Not supported:** untagged unions (compile error).

## Type Queries

### Check for Function/Method

```zig
const S = struct {
    value: u32,
    pub fn method(self: *@This()) void { _ = self; }
};

std.meta.hasFn(S, "method")      // true
std.meta.hasFn(S, "value")       // false (field, not fn)
std.meta.hasFn(S, "missing")     // false

std.meta.hasMethod(S, "method")  // true
std.meta.hasMethod(*S, "method") // true (through pointer)
std.meta.hasMethod([]S, "method") // false (slice, not single pointer)
```

### Check Unique Representation

```zig
// True if type has no padding/unused bits
std.meta.hasUniqueRepresentation(u8)   // true
std.meta.hasUniqueRepresentation(u32)  // true
std.meta.hasUniqueRepresentation(i24)  // false (padded to 4 bytes)

// Struct with no padding
const Packed = struct { a: u32, b: u32 };
std.meta.hasUniqueRepresentation(Packed)  // true

// Struct with padding
const Padded = struct { a: u32, b: u16 };
std.meta.hasUniqueRepresentation(Padded)  // false
```

### Container Layout

```zig
const Auto = struct {};
const Packed = packed struct {};
const Extern = extern struct {};

std.meta.containerLayout(Auto)    // .auto
std.meta.containerLayout(Packed)  // .@"packed"
std.meta.containerLayout(Extern)  // .@"extern"
```

### Alignment

```zig
// For pointers, returns the pointed-to alignment (not pointer alignment)
std.meta.alignment(*align(16) u8)  // 16
std.meta.alignment([]align(8) u8)  // 8
std.meta.alignment(u8)             // 1
```

### Declarations

```zig
const S = struct {
    pub const value = 42;
    pub fn method() void {}
};

const decls = std.meta.declarations(S);
// decls[0].name == "method" or "value"
```

## Error Handling

```zig
// Check if value is error (deprecated: use std.enums.fromInt)
const result = std.math.divTrunc(u8, 5, 0);
std.meta.isError(result)  // true

// Enum from int (deprecated: use std.enums.fromInt)
const Color = enum { red, green, blue };
const c = std.meta.intToEnum(Color, 1) catch unreachable;  // Color.green
```

## TrailerFlags

Memory-efficient optional field storage using bit flags:

```zig
const std = @import("std");

const Flags = std.meta.TrailerFlags(struct {
    name: []const u8,
    age: u32,
    email: []const u8,
});

// Initialize with some fields active
var flags = Flags.init(.{
    .name = true,
    .age = true,
    .email = false,
});

// Allocate only needed space
const size = flags.sizeInBytes();
const data = try allocator.alignedAlloc(u8, @alignOf(@TypeOf(flags).Fields), size);
defer allocator.free(data);

// Set values
flags.set(data.ptr, .name, "Alice");
flags.set(data.ptr, .age, 30);

// Get values (returns optional)
const name = flags.get(data.ptr, .name);  // ?"Alice"
const email = flags.get(data.ptr, .email); // null

// Set multiple at once
flags.setMany(data.ptr, .{
    .name = "Bob",
    .age = 25,
});
```

Use case: Allocating objects with many optional components where memory matters.

## Generic Programming Patterns

### Iterate All Fields

```zig
fn printStruct(value: anytype) void {
    const T = @TypeOf(value);
    inline for (std.meta.fields(T)) |field| {
        const v = @field(value, field.name);
        std.debug.print("{s}: {any}\n", .{ field.name, v });
    }
}
```

### Create Default Instance

```zig
fn createDefault(comptime T: type) T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        if (field.default_value_ptr) |ptr| {
            @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
        } else {
            @field(result, field.name) = std.mem.zeroes(field.type);
        }
    }
    return result;
}
```

### Dynamic Field Access

```zig
fn getField(comptime T: type, value: T, comptime name: []const u8) ?std.meta.fieldInfo(T, std.meta.stringToEnum(std.meta.FieldEnum(T), name) orelse return null).type {
    const field = std.meta.stringToEnum(std.meta.FieldEnum(T), name) orelse return null;
    return @field(value, @tagName(field));
}
```

### Serialize to JSON-like

```zig
fn toJson(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try writer.writeAll("{");
            inline for (info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\":", .{field.name});
                try toJson(@field(value, field.name), writer);
            }
            try writer.writeAll("}");
        },
        .int, .float => try writer.print("{}", .{value}),
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) {
            try writer.print("\"{s}\"", .{value});
        },
        else => try writer.writeAll("null"),
    }
}
```
