# std.simd

SIMD (Single Instruction, Multiple Data) utilities for parallel processing of multiple elements at once. Provides convenience functions for vector manipulation, pattern generation, searching, and parallel computation.

## Quick Reference

| Category | Functions |
|----------|-----------|
| Vector Length | `suggestVectorLength`, `suggestVectorLengthForCpu`, `VectorIndex`, `VectorCount` |
| Pattern Generation | `iota`, `repeat`, `join`, `interlace`, `deinterlace` |
| Extraction/Shifting | `extract`, `mergeShift`, `shiftElementsLeft`, `shiftElementsRight` |
| Rotation/Reversal | `rotateElementsLeft`, `rotateElementsRight`, `reverseOrder` |
| Searching | `firstTrue`, `lastTrue`, `countTrues`, `firstIndexOfValue`, `lastIndexOfValue`, `countElementsWithValue` |
| Parallel Scans | `prefixScan`, `prefixScanWithFunc` |

## Core Concepts

### Vector Types

Zig vectors are first-class types declared with `@Vector(len, T)`. Element types can be booleans, integers, floats, or pointers:

```zig
const Vec4 = @Vector(4, f64);      // 4 f64 values
const Vec8i = @Vector(8, i32);     // 8 i32 values
const Vec16b = @Vector(16, bool);  // 16 booleans
const Vec4p = @Vector(4, *u8);     // 4 pointers
```

**Vector length limits:** Zig supports lengths up to 2^32-1, but powers of two from 2-64 are typical. Excessively long vectors (e.g., 2^20) may crash the compiler.

**Compilation behavior:** Vectors shorter than the native SIMD size compile to single instructions. Longer vectors compile to multiple SIMD instructions. Without SIMD support, operations fall back to element-by-element execution.

### Built-in Operations

Vectors support arithmetic, comparisons, and builtins directly (all element-wise):

```zig
const a: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
const b: @Vector(4, f32) = .{ 5.0, 6.0, 7.0, 8.0 };

// Arithmetic (element-wise)
const sum = a + b;      // { 6.0, 8.0, 10.0, 12.0 }
const prod = a * b;     // { 5.0, 12.0, 21.0, 32.0 }

// Comparison (returns bool vector)
const mask = a < b;     // { true, true, true, true }

// Broadcast scalar to all lanes
const twos: @Vector(4, f32) = @splat(2.0);  // { 2.0, 2.0, 2.0, 2.0 }

// Math builtins (hardware-accelerated when available)
const sines = @sin(a);
const sqrts = @sqrt(a);

// Horizontal reduction
const total = @reduce(.Add, a);  // 10.0
const max_val = @reduce(.Max, a);  // 4.0
```

**Important:** `and` and `or` keywords do NOT work on bool vectors (they affect control flow). Use `&` and `|` bitwise operators, or `@select` instead.

### Vector-Compatible Builtins

These builtins work element-wise on vectors:

| Category | Builtins |
|----------|----------|
| Math | `@sqrt`, `@sin`, `@cos`, `@exp`, `@exp2`, `@log`, `@log2`, `@log10` |
| Rounding | `@floor`, `@ceil`, `@trunc`, `@round` |
| Arithmetic | `@abs`, `@min`, `@max`, `@mulAdd`, `@divFloor`, `@divTrunc`, `@mod`, `@rem` |
| Bit ops | `@clz`, `@ctz`, `@popCount`, `@byteSwap`, `@bitReverse` |
| Overflow | `@addWithOverflow`, `@subWithOverflow`, `@mulWithOverflow`, `@shlWithOverflow` |

### Array/Slice Conversion

```zig
// Array to vector (automatic)
const arr: [4]f32 = .{ 1.1, 3.2, 4.5, 5.6 };
const vec: @Vector(4, f32) = arr;

// Vector to array (automatic)
const arr2: [4]f32 = vec;

// Slice with comptime-known length to vector
const vec2: @Vector(2, f32) = arr[1..3].*;

// Runtime offset with comptime length
const slice: []const f32 = &arr;
var offset: usize = 1;
const vec3: @Vector(2, f32) = slice[offset..][0..2].*;
```

### Vector Destructuring

Vectors can be destructured like tuples:

```zig
const vec: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
const a, const b, _, _ = vec;  // a=1.0, b=2.0, ignore rest

// Useful for SIMD unpacking (emulating punpckldq)
pub fn unpack(x: @Vector(4, f32), y: @Vector(4, f32)) @Vector(4, f32) {
    const a, const c, _, _ = x;
    const b, const d, _, _ = y;
    return .{ a, b, c, d };
}
```

### @shuffle - Rearrange Elements

Rearrange elements from one or two vectors using an index mask:

```zig
const a: @Vector(7, u8) = .{ 'o', 'l', 'h', 'e', 'r', 'z', 'w' };
const b: @Vector(4, u8) = .{ 'w', 'd', '!', 'x' };

// Shuffle within single vector (pass undefined as second)
const mask1: @Vector(5, i32) = .{ 2, 3, 1, 1, 0 };
const hello: @Vector(5, u8) = @shuffle(u8, a, undefined, mask1);
// "hello"

// Combine two vectors (negative indices select from b: -1=b[0], -2=b[1], etc.)
const mask2: @Vector(6, i32) = .{ -1, 0, 4, 1, -2, -3 };
const world: @Vector(6, u8) = @shuffle(u8, a, b, mask2);
// "world!"
```

### @select - Conditional Selection

Select elements from two vectors based on a bool mask:

```zig
const a: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
const b: @Vector(4, f32) = .{ 5.0, 6.0, 7.0, 8.0 };
const mask: @Vector(4, bool) = .{ true, false, true, false };

const result = @select(f32, mask, a, b);
// { 1.0, 6.0, 3.0, 8.0 }  (a where true, b where false)
```

### @reduce - Horizontal Reduction

Reduce a vector to a scalar using an operation:

```zig
const vec: @Vector(4, i32) = .{ 1, 2, 3, 4 };

// Arithmetic reductions
const sum = @reduce(.Add, vec);  // 10
const prod = @reduce(.Mul, vec); // 24
const min_val = @reduce(.Min, vec);  // 1
const max_val = @reduce(.Max, vec);  // 4

// Bitwise reductions
const and_val = @reduce(.And, vec);  // 0
const or_val = @reduce(.Or, vec);    // 7
const xor_val = @reduce(.Xor, vec);  // 4

// Boolean reductions (for bool vectors)
const mask: @Vector(4, bool) = .{ true, true, false, true };
const all_true = @reduce(.And, mask);  // false
const any_true = @reduce(.Or, mask);   // true
```

**Available operations by type:**
- **Integers:** All operations (Add, Mul, Min, Max, And, Or, Xor)
- **Floats:** Add, Mul, Min, Max
- **Booleans:** And, Or, Xor

## Optimal Vector Length

### suggestVectorLength

Query the optimal vector length for the current CPU:

```zig
const std = @import("std");

// Get optimal lane count for this type on current hardware
const len = std.simd.suggestVectorLength(f32) orelse 4;

// Use comptime to create vector type
const Vec = @Vector(len, f32);
```

Returns `null` if scalars are recommended (no SIMD benefit).

### suggestVectorLengthForCpu

Query optimal length for a specific CPU target:

```zig
const len = std.simd.suggestVectorLengthForCpu(f64, target_cpu) orelse 2;
```

**Architecture support:**
- **x86**: SSE (128-bit), AVX2 (256-bit), AVX-512 (512-bit)
- **ARM**: NEON (128-bit)
- **AArch64**: NEON (128-bit), SVE (128-bit default)
- **RISC-V**: V extension (32-bit to 65536-bit via zvl* features)
- **WebAssembly**: simd128 (128-bit)
- **PowerPC**: AltiVec (128-bit)

### Vector Index/Count Types

Get the smallest integer type for indexing or counting:

```zig
const Vec8 = @Vector(8, u32);

// Type that can index any element (0-7)
const Idx = std.simd.VectorIndex(Vec8);  // u3

// Type that can hold the count (0-8)
const Cnt = std.simd.VectorCount(Vec8);  // u4
```

## Pattern Generation

### iota - Sequential Values

Generate a vector of sequential values starting from 0:

```zig
const indices = std.simd.iota(i32, 8);
// { 0, 1, 2, 3, 4, 5, 6, 7 }

const floats = std.simd.iota(f32, 4);
// { 0.0, 1.0, 2.0, 3.0 }
```

### repeat - Repeating Pattern

Repeat a smaller vector/array to fill a larger one:

```zig
const pattern = [_]u32{ 1, 2, 3 };
const repeated = std.simd.repeat(8, pattern);
// { 1, 2, 3, 1, 2, 3, 1, 2 }

const vec: @Vector(2, f32) = .{ 10.0, 20.0 };
const tiled = std.simd.repeat(6, vec);
// { 10.0, 20.0, 10.0, 20.0, 10.0, 20.0 }
```

### join - Concatenate Vectors

Concatenate two vectors end-to-end:

```zig
const a: @Vector(4, u32) = .{ 10, 20, 30, 40 };
const b: @Vector(4, u32) = .{ 55, 66, 77, 88 };
const joined = std.simd.join(a, b);
// { 10, 20, 30, 40, 55, 66, 77, 88 }
```

### interlace - Interleave Multiple Vectors

Alternate elements from multiple vectors:

```zig
const a: @Vector(4, u32) = .{ 10, 20, 30, 40 };
const b: @Vector(4, u32) = .{ 55, 66, 77, 88 };
const interleaved = std.simd.interlace(.{ a, b });
// { 10, 55, 20, 66, 30, 77, 40, 88 }

// Works with more than 2 vectors
const v1: @Vector(2, u8) = .{ 0, 1 };
const v2: @Vector(2, u8) = .{ 2, 3 };
const v3: @Vector(2, u8) = .{ 4, 5 };
const result = std.simd.interlace(.{ v1, v2, v3 });
// { 0, 2, 4, 1, 3, 5 }
```

**Note:** Does not work on MIPS (compile error).

### deinterlace - Split Interleaved Data

Reverse of interlace - split into separate vectors:

```zig
const interleaved: @Vector(8, u32) = .{ 10, 55, 20, 66, 30, 77, 40, 88 };
const result = std.simd.deinterlace(2, interleaved);
// result[0] = { 10, 20, 30, 40 }
// result[1] = { 55, 66, 77, 88 }
```

## Element Extraction and Shifting

### extract - Get Subvector

Extract a contiguous slice of elements:

```zig
const vec: @Vector(8, u32) = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
const slice = std.simd.extract(vec, 2, 3);
// { 2, 3, 4 }
```

### shiftElementsLeft / shiftElementsRight

Shift elements, filling with a value:

```zig
const vec: @Vector(4, u32) = .{ 10, 20, 30, 40 };

// Shift left (toward lower indices), fill from right
const left = std.simd.shiftElementsLeft(vec, 2, 999);
// { 30, 40, 999, 999 }

// Shift right (toward higher indices), fill from left
const right = std.simd.shiftElementsRight(vec, 2, 999);
// { 999, 999, 10, 20 }
```

### rotateElementsLeft / rotateElementsRight

Circular rotation (elements wrap around):

```zig
const vec: @Vector(4, u32) = .{ 10, 20, 30, 40 };

const rotl = std.simd.rotateElementsLeft(vec, 1);
// { 20, 30, 40, 10 }

const rotr = std.simd.rotateElementsRight(vec, 1);
// { 40, 10, 20, 30 }
```

### reverseOrder

Reverse element order:

```zig
const vec: @Vector(4, u32) = .{ 10, 20, 30, 40 };
const reversed = std.simd.reverseOrder(vec);
// { 40, 30, 20, 10 }
```

### mergeShift

Combine two vectors and extract a shifted window:

```zig
const a: @Vector(4, u32) = .{ 1, 2, 3, 4 };
const b: @Vector(4, u32) = .{ 5, 6, 7, 8 };
const merged = std.simd.mergeShift(a, b, 2);
// Joins to { 1, 2, 3, 4, 5, 6, 7, 8 }, extracts starting at index 2
// { 3, 4, 5, 6 }
```

## Searching

### firstTrue / lastTrue

Find first/last true element in a boolean vector:

```zig
const mask: @Vector(8, bool) = .{ false, false, true, false, true, false, false, false };

const first = std.simd.firstTrue(mask);  // 2
const last = std.simd.lastTrue(mask);    // 4

// Returns null if no true values
const all_false: @Vector(4, bool) = .{ false, false, false, false };
const none = std.simd.firstTrue(all_false);  // null
```

### countTrues

Count true elements:

```zig
const mask: @Vector(8, bool) = .{ true, false, true, false, true, false, true, false };
const count = std.simd.countTrues(mask);  // 4
```

### firstIndexOfValue / lastIndexOfValue

Find first/last occurrence of a value:

```zig
const vec: @Vector(8, u32) = .{ 6, 4, 7, 4, 4, 2, 3, 7 };

const first_4 = std.simd.firstIndexOfValue(vec, 4);  // 1
const last_4 = std.simd.lastIndexOfValue(vec, 4);    // 4
const not_found = std.simd.lastIndexOfValue(vec, 99); // null
```

### countElementsWithValue

Count occurrences of a value:

```zig
const vec: @Vector(8, u32) = .{ 6, 4, 7, 4, 4, 2, 3, 7 };
const count = std.simd.countElementsWithValue(vec, 4);  // 3
```

## Parallel Prefix Scans

### prefixScan

Compute cumulative operations across vector lanes:

```zig
const vec: @Vector(4, i32) = .{ 11, 23, 9, -21 };

// Running sum
const sums = std.simd.prefixScan(.Add, 1, vec);
// { 11, 34, 43, 22 }

// Running product
const prods = std.simd.prefixScan(.Mul, 1, vec);
// { 11, 253, 2277, -47817 }

// Running min
const mins = std.simd.prefixScan(.Min, 1, vec);
// { 11, 11, 9, -21 }

// Running max
const maxs = std.simd.prefixScan(.Max, 1, vec);
// { 11, 23, 23, 23 }

// Bitwise operations
const ands = std.simd.prefixScan(.And, 1, vec);
const ors = std.simd.prefixScan(.Or, 1, vec);
const xors = std.simd.prefixScan(.Xor, 1, vec);
```

**Hop parameter:** Controls which elements combine. `hop=2` combines every other element.

```zig
const vec: @Vector(4, i32) = .{ 11, 23, 9, -21 };
const skip = std.simd.prefixScan(.Add, 2, vec);
// { 11, 23, 20, 2 }  (11+9=20, 23+(-21)=2)

// Negative hop scans in reverse
const rev = std.simd.prefixScan(.Add, -1, vec);
// { 22, 11, -12, -21 }
```

**Note:** Does not work on MIPS (compile error).

### prefixScanWithFunc

Use a custom associative function:

```zig
fn myMax(a: @Vector(4, f32), b: @Vector(4, f32)) @Vector(4, f32) {
    return @max(a, b);
}

const vec: @Vector(4, f32) = .{ 1.0, 5.0, 2.0, 8.0 };
const result = std.simd.prefixScanWithFunc(1, vec, void, myMax, -std.math.inf(f32));
// { 1.0, 5.0, 5.0, 8.0 }
```

The identity value must satisfy: `func(x, identity) == x`.

## Practical Patterns

### Branchless Selection

Replace `if` statements with vector selection:

```zig
// Scalar (branching)
fn clampScalar(x: f32, lo: f32, hi: f32) f32 {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
}

// Vector (branchless)
fn clampSimd(x: @Vector(4, f32), lo: f32, hi: f32) @Vector(4, f32) {
    const lo_vec: @Vector(4, f32) = @splat(lo);
    const hi_vec: @Vector(4, f32) = @splat(hi);
    return @min(@max(x, lo_vec), hi_vec);
}
```

### Convergence Loops

Process lanes that converge at different rates:

```zig
fn iterateUntilConverged(vec: @Vector(4, f64), tolerance: f64) @Vector(4, f64) {
    const tol_vec: @Vector(4, f64) = @splat(tolerance);
    var current = vec;
    var converged: @Vector(4, bool) = @splat(false);

    while (!@reduce(.And, converged)) {
        const next = computeNext(current);
        const delta = @abs(next - current);
        converged = delta <= tol_vec;
        current = next;
    }
    return current;
}
```

### Time-Batched Processing

Process multiple time points for one object:

```zig
const Vec4 = @Vector(4, f64);

fn propagateV4(state: *const State, times: [4]f64) [4]Result {
    const time_vec: Vec4 = times;
    // Process all 4 times simultaneously
    const positions = computePositions(state, time_vec);
    const velocities = computeVelocities(state, time_vec);
    // ...
}
```

### Object-Batched Processing (Struct of Arrays)

Process multiple objects at the same time point:

```zig
// Struct of Arrays layout for 4 objects
const ObjectsV4 = struct {
    x: @Vector(4, f64),
    y: @Vector(4, f64),
    vx: @Vector(4, f64),
    vy: @Vector(4, f64),
};

fn updatePositions(objs: *ObjectsV4, dt: f64) void {
    const dt_vec: @Vector(4, f64) = @splat(dt);
    objs.x += objs.vx * dt_vec;
    objs.y += objs.vy * dt_vec;
}
```

### Custom atan2 Approximation

LLVM lacks vectorized `atan2`. Implement polynomial approximation:

```zig
fn atan2Simd(y: @Vector(4, f64), x: @Vector(4, f64)) @Vector(4, f64) {
    const abs_x = @abs(x);
    const abs_y = @abs(y);
    const max_xy = @max(abs_x, abs_y);
    const min_xy = @min(abs_x, abs_y);
    const epsilon: @Vector(4, f64) = @splat(1.0e-30);
    const t = min_xy / @max(max_xy, epsilon);

    // Polynomial approximation (Horner's method)
    const t2 = t * t;
    var atan_t = @as(@Vector(4, f64), @splat(0.0028662257));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(-0.0161657367));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(0.0429096138));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(-0.0752896400));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(0.1065626393));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(-0.1420889944));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(0.1999355085));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(-0.3333314528));
    atan_t = atan_t * t2 + @as(@Vector(4, f64), @splat(1.0));
    atan_t = atan_t * t;

    // Quadrant correction
    const half_pi: @Vector(4, f64) = @splat(std.math.pi / 2.0);
    const pi: @Vector(4, f64) = @splat(std.math.pi);
    const swap_mask = abs_y > abs_x;
    atan_t = @select(f64, swap_mask, half_pi - atan_t, atan_t);
    const x_neg = x < @as(@Vector(4, f64), @splat(0.0));
    atan_t = @select(f64, x_neg, pi - atan_t, atan_t);
    const y_neg = y < @as(@Vector(4, f64), @splat(0.0));
    return @select(f64, y_neg, -atan_t, atan_t);
}
```

## Performance Notes

- **Optimal vector size:** Use `suggestVectorLength` for portable code; don't hardcode lane counts. Powers of two (2-64) are most efficient
- **Compilation:** Short vectors → single SIMD instruction; long vectors → multiple instructions; no SIMD → scalar fallback
- **Alignment:** Vectors are automatically aligned; use `@alignCast` when loading from byte pointers
- **Branching:** Replace scalar branches with `@select` for branchless SIMD code. `and`/`or` keywords don't work on bool vectors
- **Reductions:** `@reduce` operations break SIMD parallelism; minimize their use in hot paths
- **Memory layout:** Prefer Struct-of-Arrays over Array-of-Structs for better vectorization
- **Cache tiling:** For large datasets, process in cache-sized chunks (e.g., 64 elements) to maintain data locality
- **Fused operations:** Use `@mulAdd(a, b, c)` for `(a * b) + c` - rounds once, more accurate
- **MIPS limitation:** `interlace` and `prefixScan` don't work on MIPS architecture
