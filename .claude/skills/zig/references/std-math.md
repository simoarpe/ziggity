# std.math

Mathematical functions, constants, and utilities. Provides floating-point operations, trigonometry, integer arithmetic with overflow checking, and arbitrary-precision integers.

## Quick Reference

| Category | Functions |
|----------|-----------|
| Constants | `e`, `pi`, `phi`, `tau`, `sqrt2`, `ln2`, `ln10` |
| Trig | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2` |
| Hyperbolic | `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` |
| Exponential | `exp`, `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p` |
| Powers/Roots | `pow`, `powi`, `sqrt`, `cbrt`, `hypot` |
| Rounding | `floor`, `ceil`, `round`, `trunc` |
| Float Tests | `isNan`, `isInf`, `isFinite`, `isNormal`, `signbit` |
| Integer Ops | `add`, `sub`, `mul`, `divTrunc`, `divFloor`, `divCeil` |
| Bit Ops | `shl`, `shr`, `rotl`, `rotr`, `log2_int`, `isPowerOfTwo` |
| Comparison | `order`, `compare`, `clamp`, `sign` |

## Mathematical Constants

```zig
const std = @import("std");
const math = std.math;

// Fundamental constants
const euler = math.e;              // 2.71828...
const pi_val = math.pi;            // 3.14159...
const golden = math.phi;           // 1.61803... (golden ratio)
const tau_val = math.tau;          // 2 * pi

// Logarithmic constants
const log2_e = math.log2e;         // log2(e)
const log10_e = math.log10e;       // log10(e)
const ln_2 = math.ln2;             // ln(2)
const ln_10 = math.ln10;           // ln(10)

// Square root constants
const sqrt_2 = math.sqrt2;         // sqrt(2)
const inv_sqrt2 = math.sqrt1_2;    // 1/sqrt(2)

// Angle conversion
const rad_deg = math.rad_per_deg;  // pi/180
const deg_rad = math.deg_per_rad;  // 180/pi
```

## Angle Conversion

```zig
// Convert between radians and degrees
const radians = std.math.degreesToRadians(@as(f32, 90.0));  // pi/2
const degrees = std.math.radiansToDegrees(@as(f32, std.math.pi));  // 180.0

// Works with vectors
const angles: @Vector(3, f32) = .{ 90.0, 180.0, 270.0 };
const rads = std.math.degreesToRadians(angles);
```

## Trigonometric Functions

```zig
const x: f32 = std.math.pi / 4.0;

// Basic trig (use hardware instructions when available)
const sine = std.math.sin(x);       // 0.7071...
const cosine = std.math.cos(x);     // 0.7071...
const tangent = std.math.tan(x);    // 1.0

// Inverse trig
const asin_val = std.math.asin(@as(f32, 0.5));  // pi/6
const acos_val = std.math.acos(@as(f32, 0.5));  // pi/3
const atan_val = std.math.atan(@as(f32, 1.0));  // pi/4
const atan2_val = std.math.atan2(@as(f32, 1.0), @as(f32, 1.0));  // pi/4

// Hyperbolic functions
const sinh_val = std.math.sinh(x);
const cosh_val = std.math.cosh(x);
const tanh_val = std.math.tanh(x);
const asinh_val = std.math.asinh(x);
const acosh_val = std.math.acosh(@as(f32, 2.0));
const atanh_val = std.math.atanh(@as(f32, 0.5));
```

## Exponential and Logarithmic Functions

```zig
const x: f64 = 2.0;

// Exponential
const exp_val = std.math.exp(x);      // e^x
const exp2_val = std.math.exp2(x);    // 2^x
const expm1_val = std.math.expm1(x);  // e^x - 1 (more precise near 0)

// Logarithms
const log_val = std.math.log(f64, std.math.e, x);  // natural log
const log2_val = std.math.log2(x);     // log base 2
const log10_val = std.math.log10(x);   // log base 10
const log1p_val = std.math.log1p(x);   // ln(1 + x) (more precise near 0)

// Integer logarithms (for integer types)
const log2_int_val = std.math.log2_int(u32, 8);   // 3 (floor)
const log2_ceil = std.math.log2_int_ceil(u32, 9); // 4 (ceil)
const log10_int_val = std.math.log10_int(1000);   // 3
```

## Power and Root Functions

```zig
// Powers
const pow_val = std.math.pow(f64, 2.0, 3.0);  // 2^3 = 8.0
const powi_val = std.math.powi(f64, 2.0, 3);  // 2^3 (integer exponent)

// Roots
const sqrt_val = std.math.sqrt(@as(f64, 16.0));  // 4.0
const cbrt_val = std.math.cbrt(@as(f64, 27.0));  // 3.0

// Hypotenuse (sqrt(x^2 + y^2), avoids overflow)
const hyp = std.math.hypot(@as(f64, 3.0), @as(f64, 4.0));  // 5.0
```

## Rounding Functions

```zig
const x: f32 = 2.7;

const floor_val = std.math.floor(x);  // 2.0 (toward -inf)
const ceil_val = std.math.ceil(x);    // 3.0 (toward +inf)
const trunc_val = std.math.trunc(x);  // 2.0 (toward zero)
const round_val = std.math.round(x);  // 3.0 (nearest, ties away from zero)
```

## Floating-Point Classification

```zig
const x: f32 = 1.0;
const inf_val = std.math.inf(f32);
const nan_val = std.math.nan(f32);

// Classification tests
const is_nan = std.math.isNan(nan_val);           // true
const is_inf = std.math.isInf(inf_val);           // true
const is_pos_inf = std.math.isPositiveInf(inf_val);  // true
const is_neg_inf = std.math.isNegativeInf(-inf_val); // true
const is_finite = std.math.isFinite(x);           // true
const is_normal = std.math.isNormal(x);           // true

// Sign operations
const has_neg_sign = std.math.signbit(-1.0);      // true
const copied = std.math.copysign(@as(f32, 5.0), @as(f32, -1.0));  // -5.0
```

## Float Properties

```zig
// Get float type properties
const mantissa_bits = std.math.floatMantissaBits(f32);  // 23
const exponent_bits = std.math.floatExponentBits(f32);  // 8
const eps = std.math.floatEps(f32);              // ~1.19e-7
const min_val = std.math.floatMin(f32);          // smallest positive normal
const max_val = std.math.floatMax(f32);          // largest finite
const true_min = std.math.floatTrueMin(f32);     // smallest positive (including subnormal)

// Special values
const inf_val = std.math.inf(f32);               // positive infinity
const nan_val = std.math.nan(f32);               // quiet NaN
const snan_val = std.math.snan(f32);             // signaling NaN
```

## Approximate Equality

```zig
const x: f32 = 1.0;
const y: f32 = 1.0 + std.math.floatEps(f32);

// Absolute tolerance (good for values near zero)
const abs_eq = std.math.approxEqAbs(f32, x, y, 1e-6);

// Relative tolerance (good for larger values)
const rel_eq = std.math.approxEqRel(f32, x, y, std.math.sqrt(std.math.floatEps(f32)));
```

## Integer Arithmetic with Overflow Checking

```zig
// These return errors on overflow instead of wrapping
const sum = std.math.add(i32, 2147483647, 1) catch |err| {
    // err is error.Overflow
    return err;
};

const product = std.math.mul(i32, 1000000, 1000000) catch |err| {
    return err;  // Overflow for i32
};

const diff = std.math.sub(u32, 5, 10) catch |err| {
    return err;  // Overflow (underflow) for unsigned
};

// Negation with potential overflow
const negated = std.math.negate(@as(i8, -128)) catch |err| {
    return err;  // Can't represent 128 in i8
};

// Shift with overflow check
const shifted = std.math.shlExact(u8, 1, 8) catch |err| {
    return err;  // Overflow: 1 << 8 doesn't fit in u8
};
```

## Division Functions

```zig
// Division toward zero
const trunc_div = try std.math.divTrunc(i32, -7, 3);  // -2

// Division toward negative infinity
const floor_div = try std.math.divFloor(i32, -7, 3);  // -3

// Division toward positive infinity
const ceil_div = try std.math.divCeil(i32, 7, 3);     // 3

// Exact division (error if remainder)
const exact = try std.math.divExact(i32, 10, 5);      // 2
// std.math.divExact(i32, 10, 3) returns error.UnexpectedRemainder

// Modulo (always non-negative result)
const mod_val = try std.math.mod(i32, -5, 3);  // 1

// Remainder (can be negative)
const rem_val = try std.math.rem(i32, -5, 3);  // -2
```

## Bit Operations

```zig
// Shift with truncation (no overflow, large shifts -> 0)
const shl_val = std.math.shl(u8, 0b11111111, 3);   // 0b11111000
const shr_val = std.math.shr(u8, 0b11111111, 3);   // 0b00011111

// Negative shift amounts reverse direction
const neg_shift = std.math.shl(u8, 0b11111111, -2);  // 0b00111111

// Rotation (unsigned integers only)
const rotl_val = std.math.rotl(u8, 0b00000001, 4);  // 0b00010000
const rotr_val = std.math.rotr(u8, 0b00010000, 4);  // 0b00000001

// Power of two checks
const is_pow2 = std.math.isPowerOfTwo(@as(u32, 8));   // true
const floor_pow2 = std.math.floorPowerOfTwo(u32, 65); // 64
const ceil_pow2 = try std.math.ceilPowerOfTwo(u32, 65); // 128
```

## Integer Type Utilities

```zig
// Get min/max values of integer type
const max_i32 = std.math.maxInt(i32);  // 2147483647
const min_i32 = std.math.minInt(i32);  // -2147483648

// Log2Int: type for bit indices
const Log2U32 = std.math.Log2Int(u32);  // u5 (can hold 0-31)

// Smallest type fitting a range
const T = std.math.IntFittingRange(0, 100);  // u7
const S = std.math.IntFittingRange(-50, 50); // i7

// Byte-aligned integer type
const ByteAligned = std.math.ByteAlignedInt(u5);  // u8
```

## Comparison and Ordering

```zig
// Get ordering between values
const ord = std.math.order(@as(i32, 5), @as(i32, 3));  // .gt
// ord is std.math.Order: .lt, .eq, or .gt

// Runtime comparison operator
const result = std.math.compare(@as(i32, 5), .gte, @as(i32, 3));  // true

// Clamp to range
const clamped = std.math.clamp(@as(i32, 15), @as(i32, 0), @as(i32, 10));  // 10

// Wrap to half-open interval [-r, r)
const wrapped = std.math.wrap(@as(i32, 270), @as(i32, 180));  // -90
```

## Sign and Interpolation

```zig
// Get sign (-1, 0, or 1)
const s = std.math.sign(@as(i32, -42));  // -1

// Linear interpolation
const lerped = std.math.lerp(@as(f32, 0.0), @as(f32, 100.0), @as(f32, 0.25));  // 25.0
```

## Type Casting

```zig
// Safe cast (returns null if doesn't fit)
const maybe: ?u8 = std.math.cast(u8, @as(i32, 300));  // null

// Lossy cast (clamps to representable range)
const clamped = std.math.lossyCast(u8, @as(i32, 300));   // 255
const from_float = std.math.lossyCast(i16, @as(f32, 70000.0)); // 32767

// Negate and cast to signed
const negated = try std.math.negateCast(@as(u32, 100));  // -100 as i32
```

## Wide Multiplication

```zig
// Multiply without overflow (result is double width)
const wide = std.math.mulWide(u8, 200, 200);  // 40000 as u16
```

## Complex Numbers

```zig
const Complex = std.math.Complex;

const z1 = Complex(f32).init(3.0, 4.0);  // 3 + 4i
const z2 = Complex(f32).init(1.0, 2.0);  // 1 + 2i

// Arithmetic
const sum = z1.add(z2);         // 4 + 6i
const diff = z1.sub(z2);        // 2 + 2i
const prod = z1.mul(z2);        // -5 + 10i
const quot = z1.div(z2);

// Operations
const conj = z1.conjugate();    // 3 - 4i
const neg = z1.neg();           // -3 - 4i
const recip = z1.reciprocal();
const mag = z1.magnitude();     // 5.0 (|z|)

// Multiply by i
const times_i = z1.mulbyi();    // -4 + 3i

// Complex math functions
const z_exp = std.math.complex.exp(z1);
const z_log = std.math.complex.log(z1);
const z_sin = std.math.complex.sin(z1);
const z_sqrt = std.math.complex.sqrt(z1);
```

## Big Integers (Arbitrary Precision)

```zig
const big = std.math.big;
const Managed = big.int.Managed;

// Create big integers (requires allocator)
var a = try Managed.initSet(allocator, 12345678901234567890);
defer a.deinit();

var b = try Managed.initSet(allocator, 98765432109876543210);
defer b.deinit();

// Arithmetic
try a.add(&a, &b);
try a.mul(&a, &b);
try a.div(&q, &r, &a, &b);  // quotient and remainder

// Comparison
const ord = a.order(b);  // .lt, .eq, or .gt

// Convert to primitive (if fits)
const val = a.to(i128) catch |err| {
    // Value doesn't fit in i128
    return err;
};

// Convert from string
var c = try Managed.init(allocator);
defer c.deinit();
try c.setString(10, "123456789012345678901234567890");
```

## GCD and LCM

```zig
// Greatest common divisor
const gcd_val = std.math.gcd(@as(u32, 48), @as(u32, 18));  // 6

// Least common multiple
const lcm_val = try std.math.lcm(@as(u32, 4), @as(u32, 6));  // 12
// Returns error.Overflow if result doesn't fit
```

## Gamma Functions

```zig
// Gamma function
const g = std.math.gamma(f64, 5.0);  // 24.0 (= 4!)

// Log gamma (more numerically stable for large values)
const lg = std.math.lgamma(f64, 100.0);
```

## Notes

- Most functions work with `f16`, `f32`, `f64`, `f80`, `f128` and `comptime_float`
- Many functions support SIMD vectors: `sin(@Vector(4, f32){...})`
- Integer overflow-checking functions return `error.Overflow` or `error.DivisionByZero`
- Hardware instructions used when available (`@sin`, `@cos`, `@sqrt`, etc.)
- `approxEqAbs` for values near zero, `approxEqRel` for larger values
- Complex number operations available in `std.math.complex`
- Big integers require allocator and are in `std.math.big.int`
