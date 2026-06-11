# Zig Built-in Functions Reference

Built-in functions are compiler intrinsics prefixed with `@`. Parameters marked `comptime` must be compile-time known.

## Table of Contents
- [Type Conversions](#type-conversions)
- [Integer/Float Operations](#integerfloat-operations)
- [Overflow Arithmetic](#overflow-arithmetic)
- [Bit Manipulation](#bit-manipulation)
- [Memory Operations](#memory-operations)
- [Atomics](#atomics)
- [Type Introspection](#type-introspection)
- [Comptime Utilities](#comptime-utilities)
- [SIMD/Vector](#simdvector)
- [C Interop](#c-interop)
- [Debug/Control Flow](#debugcontrol-flow)

## Type Conversions

### @as
```zig
@as(comptime T: type, expr) T
```
Safe type coercion. Preferred over explicit casts when conversion is unambiguous.
```zig
const x = @as(u32, 5);  // comptime_int → u32
```

### @intCast
```zig
@intCast(value: anytype) anytype
```
Convert between integer types. Runtime safety check if value doesn't fit.
```zig
const big: u64 = 100;
const small: u8 = @intCast(big);  // OK if value fits
```

### @floatCast
```zig
@floatCast(value: anytype) anytype
```
Convert between float types. Return type inferred.
```zig
const d: f64 = 3.14;
const f: f32 = @floatCast(d);
```

### @intFromFloat
```zig
@intFromFloat(value: anytype) anytype
```
Float → integer. Truncates fractional part. Return type inferred.
```zig
const i: i32 = @intFromFloat(3.7);  // i = 3
```

### @floatFromInt
```zig
@floatFromInt(value: anytype) anytype
```
Integer → float. Return type inferred.
```zig
const f: f32 = @floatFromInt(42);
```

### @intFromPtr
```zig
@intFromPtr(ptr: anytype) usize
```
Pointer → `usize`. For pointer arithmetic or FFI.
```zig
const addr: usize = @intFromPtr(&x);
```

### @ptrFromInt
```zig
@ptrFromInt(addr: usize) anytype
```
`usize` → pointer. Return type inferred. **Undefined behavior if invalid.**
```zig
const ptr: *u32 = @ptrFromInt(0x1000);
```

### @ptrCast
```zig
@ptrCast(ptr: anytype) anytype
```
Pointer type cast. Return type inferred.
```zig
const bytes: [*]u8 = @ptrCast(some_ptr);
```

### @alignCast
```zig
@alignCast(ptr: anytype) anytype
```
Change pointer alignment. Safety check at runtime.
```zig
const aligned: *align(16) u8 = @alignCast(ptr);
```

### @constCast
```zig
@constCast(ptr: anytype) anytype
```
Remove `const` qualifier from pointer. Return type inferred.
```zig
const mutable_ptr: *u32 = @constCast(const_ptr);
```

### @volatileCast
```zig
@volatileCast(ptr: anytype) anytype
```
Remove `volatile` qualifier from pointer.

### @bitCast
```zig
@bitCast(value: anytype) anytype
```
Reinterpret bits as different type. Sizes must match. Return type inferred.
```zig
const bits: u32 = @bitCast(@as(f32, 1.0));
const f: f32 = @bitCast(@as(u32, 0x3f800000));
```

### @truncate
```zig
@truncate(value: anytype) anytype
```
Truncate integer to smaller type. Discards high bits. Return type inferred.
```zig
const small: u8 = @truncate(@as(u32, 0x12345678));  // 0x78
```

### @intFromBool
```zig
@intFromBool(value: bool) u1
```
`false` → 0, `true` → 1.
```zig
const x: u8 = @intFromBool(true);  // 1
```

### @intFromEnum
```zig
@intFromEnum(value: anytype) anytype
```
Enum → backing integer type.
```zig
const State = enum(u8) { idle = 0, running = 1 };
const n: u8 = @intFromEnum(State.running);  // 1
```

### @enumFromInt
```zig
@enumFromInt(int: anytype) anytype
```
Integer → enum. Return type inferred.
```zig
const state: State = @enumFromInt(1);  // State.running
```

### @errorFromInt
```zig
@errorFromInt(int: anytype) anytype
```
Integer → error. Return type inferred.

### @intFromError
```zig
@intFromError(err: anytype) std.meta.Int(.unsigned, @bitSizeOf(anyerror))
```
Error → integer.

### @errorCast
```zig
@errorCast(err: anytype) anytype
```
Cast between error set types.

### @addrSpaceCast
```zig
@addrSpaceCast(ptr: anytype) anytype
```
Convert pointer between address spaces (GPU/embedded).

## Integer/Float Operations

### @abs
```zig
@abs(value: anytype) anytype
```
Absolute value. Works on integers, floats, vectors.
```zig
const x = @abs(@as(i32, -5));  // 5
```

### @min / @max
```zig
@min(a: T, b: T) T
@max(a: T, b: T) T
```
Return minimum/maximum of two values.
```zig
const m = @max(3, 7);  // 7
```

### @divExact
```zig
@divExact(numerator: T, denominator: T) T
```
Exact division. Asserts no remainder.
```zig
const x = @divExact(10, 2);  // 5
```

### @divFloor
```zig
@divFloor(numerator: T, denominator: T) T
```
Floor division (rounds toward negative infinity).
```zig
const x = @divFloor(-7, 3);  // -3
```

### @divTrunc
```zig
@divTrunc(numerator: T, denominator: T) T
```
Truncating division (rounds toward zero).
```zig
const x = @divTrunc(-7, 3);  // -2
```

### @mod
```zig
@mod(numerator: T, denominator: T) T
```
Floor modulus. Result has same sign as denominator.
```zig
const x = @mod(-5, 3);  // 1
```

### @rem
```zig
@rem(numerator: T, denominator: T) T
```
Remainder. Result has same sign as numerator.
```zig
const x = @rem(-5, 3);  // -2
```

### Math Functions (floats/vectors)
```zig
@sqrt(x)     // Square root
@sin(x)      // Sine
@cos(x)      // Cosine
@tan(x)      // Tangent
@exp(x)      // e^x
@exp2(x)     // 2^x
@log(x)      // Natural log
@log2(x)     // Log base 2
@log10(x)    // Log base 10
@floor(x)    // Round down
@ceil(x)     // Round up
@round(x)    // Round to nearest
@trunc(x)    // Truncate toward zero
@mulAdd(T, a, b, c)  // Fused (a*b)+c
```

## Overflow Arithmetic

Returns tuple: `{ result, overflow_bit }` where overflow_bit is `u1`.

### @addWithOverflow
```zig
@addWithOverflow(a: T, b: T) struct { T, u1 }
```
```zig
const result, const overflow = @addWithOverflow(@as(u8, 250), 10);
if (overflow != 0) { /* handle overflow */ }
```

### @subWithOverflow
```zig
@subWithOverflow(a: T, b: T) struct { T, u1 }
```

### @mulWithOverflow
```zig
@mulWithOverflow(a: T, b: T) struct { T, u1 }
```

### @shlWithOverflow
```zig
@shlWithOverflow(a: T, b: Log2Int) struct { T, u1 }
```

## Bit Manipulation

### @clz
```zig
@clz(value: anytype) anytype
```
Count leading zeros.
```zig
const z = @clz(@as(u8, 0b00001111));  // 4
```

### @ctz
```zig
@ctz(value: anytype) anytype
```
Count trailing zeros.
```zig
const z = @ctz(@as(u8, 0b11110000));  // 4
```

### @popCount
```zig
@popCount(value: anytype) anytype
```
Count set bits (population count).
```zig
const c = @popCount(@as(u8, 0b10101010));  // 4
```

### @byteSwap
```zig
@byteSwap(value: anytype) @TypeOf(value)
```
Reverse byte order (endianness conversion).
```zig
const swapped = @byteSwap(@as(u32, 0x12345678));  // 0x78563412
```

### @bitReverse
```zig
@bitReverse(value: anytype) @TypeOf(value)
```
Reverse all bits.
```zig
const rev = @bitReverse(@as(u8, 0b11000001));  // 0b10000011
```

### @shlExact / @shrExact
```zig
@shlExact(value: T, shift: Log2Int) T
@shrExact(value: T, shift: Log2Int) T
```
Shift with assertion that no bits are lost.

## Memory Operations

### @memcpy
```zig
@memcpy(dest: []T, src: []const T) void
```
Copy memory. Slices must not overlap.
```zig
@memcpy(dest[0..n], src[0..n]);
```

### @memset
```zig
@memset(dest: []T, value: T) void
```
Fill memory with value.
```zig
@memset(buffer[0..n], 0);
```

### @memmove
```zig
@memmove(dest: []T, src: []const T) void
```
Copy memory. Slices may overlap.

### @sizeOf
```zig
@sizeOf(comptime T: type) comptime_int
```
Size of type in bytes (includes padding).
```zig
const size = @sizeOf(u32);  // 4
```

### @bitSizeOf
```zig
@bitSizeOf(comptime T: type) comptime_int
```
Size of type in bits.
```zig
const bits = @bitSizeOf(u24);  // 24
```

### @alignOf
```zig
@alignOf(comptime T: type) comptime_int
```
Alignment requirement of type.
```zig
const align = @alignOf(u64);  // typically 8
```

### @offsetOf
```zig
@offsetOf(comptime T: type, comptime field: []const u8) comptime_int
```
Byte offset of struct field.
```zig
const Point = struct { x: i32, y: i32 };
const off = @offsetOf(Point, "y");  // 4
```

### @bitOffsetOf
```zig
@bitOffsetOf(comptime T: type, comptime field: []const u8) comptime_int
```
Bit offset of field (useful for packed structs).

## Atomics

### @atomicLoad
```zig
@atomicLoad(comptime T: type, ptr: *const T, comptime ordering: AtomicOrder) T
```
Atomic read.
```zig
const val = @atomicLoad(u32, &counter, .acquire);
```

### @atomicStore
```zig
@atomicStore(comptime T: type, ptr: *T, value: T, comptime ordering: AtomicOrder) void
```
Atomic write.
```zig
@atomicStore(u32, &counter, 42, .release);
```

### @atomicRmw
```zig
@atomicRmw(comptime T: type, ptr: *T, comptime op: AtomicRmwOp, operand: T, comptime ordering: AtomicOrder) T
```
Atomic read-modify-write. Returns previous value.
```zig
const old = @atomicRmw(u32, &counter, .Add, 1, .seq_cst);
```
Operations: `.Add`, `.Sub`, `.And`, `.Or`, `.Xor`, `.Nand`, `.Min`, `.Max`, `.Xchg`

### @cmpxchgStrong / @cmpxchgWeak
```zig
@cmpxchgStrong(comptime T: type, ptr: *T, expected: T, new: T, success_order: AtomicOrder, fail_order: AtomicOrder) ?T
@cmpxchgWeak(comptime T: type, ptr: *T, expected: T, new: T, success_order: AtomicOrder, fail_order: AtomicOrder) ?T
```
Compare-and-swap. Returns `null` on success, old value on failure.
```zig
while (@cmpxchgWeak(u32, &counter, expected, new, .seq_cst, .seq_cst)) |actual| {
    expected = actual;
}
```

## Type Introspection

### @TypeOf
```zig
@TypeOf(expr) type
```
Get type of expression at comptime.
```zig
const T = @TypeOf(some_value);
```

### @typeInfo
```zig
@typeInfo(comptime T: type) std.builtin.Type
```
Get detailed type information.
```zig
const info = @typeInfo(MyStruct);
if (info == .@"struct") {
    for (info.@"struct".fields) |field| {
        // field.name, field.type, etc.
    }
}
```

### @Type
```zig
@Type(comptime info: std.builtin.Type) type
```
Create type from type info (inverse of `@typeInfo`).

### @typeName
```zig
@typeName(comptime T: type) [:0]const u8
```
Get string name of type.
```zig
const name = @typeName(u32);  // "u32"
```

### @hasDecl
```zig
@hasDecl(comptime T: type, comptime name: []const u8) bool
```
Check if type has declaration (const, fn, etc.).
```zig
if (@hasDecl(T, "init")) { T.init(); }
```

### @hasField
```zig
@hasField(comptime T: type, comptime name: []const u8) bool
```
Check if struct/union has field.

### @field
```zig
@field(value: anytype, comptime name: []const u8) anytype
```
Access field by comptime string name.
```zig
const x = @field(point, "x");
```

### @FieldType
```zig
@FieldType(comptime T: type, comptime name: []const u8) type
```
Get type of a struct field.

### @fieldParentPtr
```zig
@fieldParentPtr(field_ptr: anytype, comptime field_name: []const u8) anytype
```
Get pointer to containing struct from field pointer (for intrusive data structures).
```zig
const Node = struct { data: u32, hook: Hook };
fn getNode(hook: *Hook) *Node {
    return @fieldParentPtr(hook, "hook");
}
```

### @tagName
```zig
@tagName(value: anytype) [:0]const u8
```
Get string name of enum/union tag.
```zig
const Color = enum { red, green, blue };
const name = @tagName(Color.red);  // "red"
```

### @errorName
```zig
@errorName(err: anyerror) [:0]const u8
```
Get string name of error.
```zig
const name = @errorName(error.OutOfMemory);  // "OutOfMemory"
```

## Comptime Utilities

### @import
```zig
@import(comptime path: []const u8) type
```
Import module. Special: `"std"`, `"builtin"`.
```zig
const std = @import("std");
const builtin = @import("builtin");
const other = @import("other.zig");
```

### @embedFile
```zig
@embedFile(comptime path: []const u8) *const [N:0]u8
```
Embed file contents as compile-time string.
```zig
const data = @embedFile("data.bin");
```

### @compileError
```zig
@compileError(comptime msg: []const u8) noreturn
```
Emit compile error with message.
```zig
if (condition) @compileError("Invalid configuration");
```

### @compileLog
```zig
@compileLog(args: ...) void
```
Print values at compile time for debugging.
```zig
@compileLog("x =", x, "T =", T);
```

### @This
```zig
@This() type
```
Get enclosing struct/union/enum type.
```zig
const Self = @This();
fn method(self: *Self) void { ... }
```

### @src
```zig
@src() std.builtin.SourceLocation
```
Get current source location (file, line, column, fn name).

### @inComptime
```zig
@inComptime() bool
```
Check if currently executing at comptime.
```zig
if (@inComptime()) {
    // comptime path
} else {
    // runtime path
}
```

### @setEvalBranchQuota
```zig
@setEvalBranchQuota(quota: u32) void
```
Increase comptime evaluation limit (default 1000).
```zig
@setEvalBranchQuota(100_000);
```

## SIMD/Vector

### @Vector
```zig
@Vector(len: comptime_int, T: type) type
```
Create SIMD vector type.
```zig
const Vec4f = @Vector(4, f32);
const v: Vec4f = .{ 1.0, 2.0, 3.0, 4.0 };
```

### @splat
```zig
@splat(value: anytype) anytype
```
Create vector with all elements equal to value. Return type inferred.
```zig
const ones: @Vector(4, f32) = @splat(1.0);
```

### @reduce
```zig
@reduce(comptime op: std.builtin.ReduceOp, value: anytype) ElementType
```
Reduce vector to scalar.
```zig
const sum = @reduce(.Add, vec);  // sum all elements
const max = @reduce(.Max, vec);  // find maximum
```
Operations: `.Add`, `.Mul`, `.And`, `.Or`, `.Xor`, `.Min`, `.Max`

### @shuffle
```zig
@shuffle(T: type, a: @Vector(N, T), b: @Vector(N, T), mask: @Vector(M, i32)) @Vector(M, T)
```
Rearrange vector elements using mask.
```zig
const a: @Vector(4, i32) = .{ 1, 2, 3, 4 };
const b: @Vector(4, i32) = .{ 5, 6, 7, 8 };
const result = @shuffle(i32, a, b, .{ 0, 4, 1, 5 });  // {1, 5, 2, 6}
// Positive indices select from a, indices >= len select from b
```

### @select
```zig
@select(T: type, pred: @Vector(N, bool), a: @Vector(N, T), b: @Vector(N, T)) @Vector(N, T)
```
Element-wise select: `pred[i] ? a[i] : b[i]`.

## C Interop

### @cImport
```zig
@cImport(expr) type
```
Import C header files.
```zig
const c = @cImport({
    @cDefine("_GNU_SOURCE", {});
    @cInclude("stdio.h");
});
```

### @cInclude
```zig
@cInclude(comptime path: []const u8) void
```
Include C header (inside `@cImport`).

### @cDefine
```zig
@cDefine(comptime name: []const u8, value) void
```
Define C macro (inside `@cImport`).

### @cUndef
```zig
@cUndef(comptime name: []const u8) void
```
Undefine C macro.

### @extern
```zig
@extern(comptime T: type, options: ExternOptions) T
```
Declare external symbol.

### @export
```zig
@export(target: anytype, options: ExportOptions) void
```
Export symbol. **Takes pointer in 0.14.0+**.
```zig
@export(&my_fn, .{ .name = "exported_name" });
```

### C Varargs
```zig
@cVaStart() std.builtin.VaList    // Start vararg processing
@cVaArg(*VaList, T) T             // Get next vararg
@cVaCopy(*VaList) VaList          // Copy vararg state
@cVaEnd(*VaList) void             // End vararg processing
```

## Debug/Control Flow

### @branchHint
```zig
@branchHint(hint: std.builtin.BranchHint) void
```
Hint branch likelihood. Must be first statement in branch.
```zig
if (unlikely_condition) {
    @branchHint(.cold);
    // rarely executed
}
```
Hints: `.none`, `.likely`, `.unlikely`, `.cold`

### @breakpoint
```zig
@breakpoint() void
```
Insert debugger breakpoint.

### @trap
```zig
@trap() noreturn
```
Crash immediately (illegal instruction).

### @panic
```zig
@panic(msg: []const u8) noreturn
```
Trigger panic with message.

### @setRuntimeSafety
```zig
@setRuntimeSafety(enabled: bool) void
```
Enable/disable safety checks in current scope.
```zig
@setRuntimeSafety(false);
// Unsafe operations here
```

### @setFloatMode
```zig
@setFloatMode(mode: std.builtin.FloatMode) void
```
Set floating-point optimization mode.
```zig
@setFloatMode(.optimized);  // Allow reordering, etc.
```

### @returnAddress
```zig
@returnAddress() usize
```
Get return address of current function.

### @frameAddress
```zig
@frameAddress() usize
```
Get frame pointer of current function.

### @errorReturnTrace
```zig
@errorReturnTrace() ?*std.builtin.StackTrace
```
Get error return trace (if available).

### @call
```zig
@call(modifier: std.builtin.CallModifier, fn: anytype, args: anytype) anytype
```
Call function with modifier.
```zig
const result = @call(.always_inline, my_fn, .{ arg1, arg2 });
```
Modifiers: `.auto`, `.never_inline`, `.always_inline`, `.always_tail`, `.never_tail`, `.compile_time`

### @prefetch
```zig
@prefetch(ptr: anytype, options: PrefetchOptions) void
```
Prefetch memory into cache.
```zig
@prefetch(ptr, .{ .rw = .read, .locality = 3 });
```

## WebAssembly

### @wasmMemorySize
```zig
@wasmMemorySize(index: u32) u32
```
Get WebAssembly memory size in pages.

### @wasmMemoryGrow
```zig
@wasmMemoryGrow(index: u32, delta: u32) u32
```
Grow WebAssembly memory by delta pages.

## GPU/Workgroup

```zig
@workGroupId(dim: u32) u32      // Get workgroup ID
@workGroupSize(dim: u32) u32    // Get workgroup size
@workItemId(dim: u32) u32       // Get work item ID within group
```
