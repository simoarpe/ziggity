# Zig Language Basics Reference

Core language features, control flow, and type system fundamentals.

## Table of Contents
- [Types](#types)
- [Control Flow](#control-flow)
- [Error Handling](#error-handling)
- [Optionals](#optionals)
- [Structs](#structs)
- [Enums](#enums)
- [Unions](#unions)
- [Pointers and Slices](#pointers-and-slices)
- [Comptime](#comptime)
- [Functions](#functions)

## Types

### Primitive Types
```zig
// Integers (signed and unsigned, any bit width 1-65535)
i8, i16, i32, i64, i128, isize   // signed
u8, u16, u32, u64, u128, usize   // unsigned
i7, u24, i53                      // arbitrary widths

// Floats
f16, f32, f64, f80, f128

// Other
bool                // true or false
void                // zero-size type
noreturn            // function never returns
type                // type of types (comptime only)
anyopaque           // type-erased pointer target
comptime_int        // arbitrary precision integer (comptime only)
comptime_float      // arbitrary precision float (comptime only)

// C interop types
c_char, c_short, c_int, c_long, c_longlong
c_ushort, c_uint, c_ulong, c_ulonglong
c_longdouble
```

### Type Coercion
```zig
// Implicit coercions (safe, automatic)
const a: u16 = 42;      // comptime_int → u16
const b: i32 = a;       // u16 → i32 (widening)
const c: f64 = 3.14;    // comptime_float → f64
const d: []const u8 = "hello";  // *const [5:0]u8 → []const u8
const e: ?i32 = 5;      // i32 → ?i32

// @as for explicit safe coercion
const x = @as(u32, 100);

// Casts for unsafe/reinterpret conversions
const y: u8 = @intCast(big_value);   // may panic if value doesn't fit
const z: u32 = @bitCast(float_val);  // reinterpret bits
```

### Arrays
```zig
// Fixed-size arrays
const arr: [5]u8 = .{ 1, 2, 3, 4, 5 };
const arr2 = [_]u8{ 1, 2, 3 };         // infer length
const zeros = [_]u8{0} ** 100;         // repeat pattern

// Sentinel-terminated arrays
const str: [5:0]u8 = "hello".*;        // null-terminated
const arr: [3:255]u8 = .{ 1, 2, 3 };   // 255-terminated

// Access
const elem = arr[2];
const len = arr.len;

// Iteration
for (arr) |elem| { ... }
for (arr, 0..) |elem, i| { ... }    // with index
for (&arr) |*elem| { elem.* = 0; }  // mutable
```

### Tuples
```zig
const tuple = .{ 42, "hello", true };
const first = tuple[0];       // 42
const len = tuple.len;        // 3

// Destructuring
const a, const b, const c = tuple;
```

## Control Flow

### if
```zig
// Basic
if (condition) {
    // ...
} else if (other) {
    // ...
} else {
    // ...
}

// Expression form
const value = if (condition) x else y;

// With optionals
if (optional_value) |unwrapped| {
    // unwrapped is non-null
} else {
    // was null
}

// With error unions
if (error_union) |value| {
    // success
} else |err| {
    // handle err
}
```

### switch
```zig
const result = switch (value) {
    1 => "one",
    2, 3 => "two or three",
    4...10 => "four to ten",
    else => "other",
};

// Capture
switch (tagged_union) {
    .variant => |payload| { ... },
    .other => |*ptr| { ptr.* = new_value; },  // mutable capture
}

// Comptime switch on types
switch (@typeInfo(T)) {
    .int => |info| { ... },
    .float => { ... },
    else => @compileError("unsupported type"),
}
```

### Labeled switch (0.14.0+) - State Machines
```zig
state: switch (initial_state) {
    .idle => {
        continue :state .running;  // transition
    },
    .running => {
        if (done) break :state result;  // exit with value
        continue :state .running;       // loop
    },
    .error => return error.Failed,
}
```

### Non-exhaustive enum switch (0.15.x)
```zig
switch (non_exhaustive_enum) {
    .known_a => {},
    .known_b => {},
    else => {},  // other named tags
    _ => {},     // unnamed integer values
}
```

### while
```zig
// Basic
while (condition) { ... }

// With else (runs if condition was never true or on break)
while (condition) { ... } else { ... }

// With continue expression
var i: usize = 0;
while (i < 10) : (i += 1) { ... }

// With optional
while (iterator.next()) |item| { ... }

// With error union
while (reader.readByte()) |byte| {
    ...
} else |err| {
    if (err != error.EndOfStream) return err;
}

// Infinite loop
while (true) { ... }
```

### for
```zig
// Iterate slice/array
for (items) |item| { ... }

// With index
for (items, 0..) |item, i| { ... }

// Multiple sequences (must have same length)
for (a, b, c) |x, y, z| { ... }

// Mutable iteration
for (&items) |*item| { item.* = new_value; }

// Range (comptime only for runtime, but works in comptime blocks)
inline for (0..10) |i| { ... }
```

### Labels and Control
```zig
// Labeled blocks
const result = blk: {
    if (condition) break :blk value;
    break :blk other_value;
};

// Labeled loops
outer: for (rows) |row| {
    for (row) |cell| {
        if (cell == target) break :outer;
    }
}

// continue with label
outer: for (items) |item| {
    for (sub_items) |sub| {
        if (skip) continue :outer;
    }
}
```

### defer / errdefer
```zig
// Always runs when scope exits
fn example() void {
    const resource = acquire();
    defer release(resource);  // runs on return
    // use resource...
}

// Only runs on error return
fn example() !void {
    const ptr = try allocate();
    errdefer free(ptr);  // runs only if function returns error
    try doSomething(ptr);
    return ptr;  // errdefer does NOT run
}

// errdefer with capture
fn example() !void {
    errdefer |err| {
        log.err("Failed with: {}", .{err});
    };
    try riskyOperation();
}
```

## Error Handling

### Error Sets
```zig
// Define error set
const FileError = error{
    NotFound,
    AccessDenied,
    OutOfMemory,
};

// Inferred error set (use sparingly)
fn foo() !void { ... }  // error set inferred from body

// Merge error sets
const AllErrors = FileError || NetworkError;

// anyerror - global error set (avoid when possible)
fn bar() anyerror!void { ... }
```

### Error Unions
```zig
// Error union type: ErrorSet!PayloadType
fn parse(s: []const u8) ParseError!u32 { ... }
fn read() ![]u8 { ... }  // inferred error set

// Return errors
return error.InvalidInput;

// Return success
return value;
```

### Handling Errors
```zig
// try - propagate error, unwrap on success
const value = try mayFail();

// catch - provide default on error
const value = mayFail() catch 0;
const value = mayFail() catch |err| {
    log.err("failed: {}", .{err});
    return default;
};

// catch unreachable - assert no error (crashes if error)
const value = mayFail() catch unreachable;

// if with error union
if (mayFail()) |value| {
    // success
} else |err| {
    // handle error
}

// switch on specific errors
mayFail() catch |err| switch (err) {
    error.NotFound => return null,
    error.AccessDenied => return error.PermissionDenied,
    else => return err,
};
```

## Optionals

### Optional Types
```zig
// Optional type: ?T
var maybe: ?i32 = null;
maybe = 42;

// Check for null
if (maybe != null) { ... }
if (maybe == null) { ... }
```

### Unwrapping
```zig
// orelse - default value
const value = maybe orelse 0;
const value = maybe orelse return error.Missing;
const value = maybe orelse unreachable;  // assert non-null

// .? - assert and unwrap (crashes on null)
const value = maybe.?;

// if unwrap
if (maybe) |value| {
    // value is non-null
} else {
    // was null
}

// while unwrap
while (iterator.next()) |item| { ... }
```

### Optional Pointers
```zig
// ?*T has null representation as 0 (same size as *T)
var ptr: ?*Node = null;
ptr = &node;

if (ptr) |p| {
    p.*.data = 42;
}
```

## Structs

### Basic Structs
```zig
const Point = struct {
    x: f32,
    y: f32,

    // Methods
    pub fn distance(self: Point, other: Point) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }

    // Static method
    pub fn origin() Point {
        return .{ .x = 0, .y = 0 };
    }
};

// Usage
const p = Point{ .x = 1.0, .y = 2.0 };
const p2: Point = .{ .x = 3.0, .y = 4.0 };  // type inferred
const dist = p.distance(p2);
```

### Default Values
```zig
const Config = struct {
    name: []const u8,
    port: u16 = 8080,       // default value
    debug: bool = false,
};

const cfg: Config = .{ .name = "server" };  // uses defaults
```

### @This() for Self-Reference
```zig
const Node = struct {
    const Self = @This();
    next: ?*Self = null,
    data: i32,

    pub fn append(self: *Self, node: *Self) void {
        self.next = node;
    }
};
```

### Packed Structs
```zig
const Flags = packed struct {
    enabled: bool,      // 1 bit
    mode: u2,          // 2 bits
    _reserved: u5,     // 5 bits
};  // Total: 1 byte

const flags: Flags = @bitCast(@as(u8, 0b10100001));
```

### Extern Structs (C ABI)
```zig
const CStruct = extern struct {
    x: c_int,
    y: c_int,
};
```

## Enums

### Basic Enums
```zig
const Color = enum {
    red,
    green,
    blue,
};

const c: Color = .red;

// Switch (must be exhaustive)
switch (c) {
    .red => {},
    .green => {},
    .blue => {},
}
```

### Enums with Values
```zig
const HttpStatus = enum(u16) {
    ok = 200,
    not_found = 404,
    internal_error = 500,
    _,  // non-exhaustive marker
};

const code: u16 = @intFromEnum(HttpStatus.ok);  // 200
const status: HttpStatus = @enumFromInt(404);    // .not_found
```

### Enum Methods
```zig
const Direction = enum {
    north,
    south,
    east,
    west,

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .north => .south,
            .south => .north,
            .east => .west,
            .west => .east,
        };
    }
};
```

## Unions

### Tagged Unions
```zig
const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    none,  // void payload

    pub fn isNumeric(self: Value) bool {
        return switch (self) {
            .int, .float => true,
            else => false,
        };
    }
};

const v: Value = .{ .int = 42 };

switch (v) {
    .int => |n| std.debug.print("{}", .{n}),
    .float => |f| std.debug.print("{}", .{f}),
    .string => |s| std.debug.print("{s}", .{s}),
    .none => {},
}
```

### Bare Unions (no tag)
```zig
const Bare = union {
    int: i32,
    float: f32,
};
// Must track active field manually - unsafe
```

### Extern Unions (C ABI)
```zig
const CUnion = extern union {
    as_int: c_int,
    as_float: f32,
};
```

## Pointers and Slices

### Pointer Types
```zig
*T          // single-item pointer
*const T    // pointer to const
[*]T        // many-item pointer (unknown length)
[*:0]T      // null-terminated many-item pointer
?*T         // optional pointer

// Alignment
*align(16) T    // pointer with explicit alignment
```

### Slices
```zig
[]T         // slice (pointer + length)
[]const T   // slice to const data
[:0]T       // null-terminated slice

// Create slice from array
const arr = [_]u8{ 1, 2, 3, 4, 5 };
const slice: []const u8 = &arr;
const sub: []const u8 = arr[1..4];  // {2, 3, 4}

// Slice operations
const len = slice.len;
const ptr = slice.ptr;  // [*]const u8
const elem = slice[2];
```

### Pointer Arithmetic
```zig
// Many-item pointers support arithmetic
const ptr: [*]u8 = buffer.ptr;
const next = ptr + 1;
const offset = ptr + n;

// Single-item pointers do NOT support arithmetic
// Use slicing instead:
const slice = ptr[0..n];
```

### Sentinel-Terminated
```zig
// Null-terminated string
const str: [:0]const u8 = "hello";
const c_str: [*:0]const u8 = str.ptr;

// Custom sentinel
const arr: [3:255]u8 = .{ 1, 2, 3 };  // followed by 255
```

## Comptime

### Comptime Variables
```zig
comptime var count: u32 = 0;

// Comptime block
comptime {
    count += 1;
}

// Comptime parameter
fn repeat(comptime n: usize, value: u8) [n]u8 {
    return [_]u8{value} ** n;
}
```

### Comptime Functions
```zig
fn factorial(comptime n: u32) u32 {
    if (n == 0) return 1;
    return n * factorial(n - 1);
}

const result = factorial(5);  // computed at compile time
```

### Type as First-Class Value
```zig
fn Container(comptime T: type) type {
    return struct {
        items: []T,

        pub fn get(self: @This(), i: usize) T {
            return self.items[i];
        }
    };
}

const IntContainer = Container(i32);
```

### @typeInfo
```zig
fn isInteger(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn fieldNames(comptime T: type) []const []const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("expected struct");

    var names: [info.@"struct".fields.len][]const u8 = undefined;
    for (info.@"struct".fields, 0..) |field, i| {
        names[i] = field.name;
    }
    return &names;
}
```

### inline for/while
```zig
// Unroll loop at compile time
inline for (0..4) |i| {
    array[i] = computeValue(i);
}

// Generate code for each field
inline for (std.meta.fields(T)) |field| {
    @field(value, field.name) = default;
}
```

## Functions

### Function Basics
```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

// With error
fn parse(s: []const u8) !i32 { ... }

// Void return
fn log(msg: []const u8) void { ... }

// Noreturn
fn abort() noreturn {
    @panic("aborted");
}
```

### Generic Functions
```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

// Using anytype
fn print(value: anytype) void {
    const T = @TypeOf(value);
    // ...
}
```

### Function Pointers
```zig
const BinaryOp = *const fn (i32, i32) i32;

fn apply(op: BinaryOp, a: i32, b: i32) i32 {
    return op(a, b);
}
```

### Calling Conventions
```zig
fn cFunc() callconv(.c) void { ... }
fn nakedFunc() callconv(.naked) noreturn { ... }
fn inlineFunc() callconv(.@"inline") i32 { ... }
```

### Export/Extern
```zig
// Export to C
export fn my_function() void { ... }

// Import from C
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

// Link with library
extern "SDL2" fn SDL_Init(flags: u32) c_int;
```

### Inline Functions
```zig
inline fn fastAdd(a: i32, b: i32) i32 {
    return a + b;
}
// Forces inlining - compile error if impossible
```
