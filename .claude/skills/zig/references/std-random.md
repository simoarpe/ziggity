# std.Random - Random Number Generation

Pseudo-random number generators (PRNGs), cryptographically secure random number generators (CSPRNGs), and utilities for generating random values of various types.

## Quick Reference

| Category | Types/Functions |
|----------|-----------------|
| Default PRNGs | `DefaultPrng` (Xoshiro256), `DefaultCsprng` (ChaCha) |
| Fast PRNGs | `Xoshiro256`, `Xoroshiro128`, `Pcg`, `Sfc64`, `RomuTrio`, `Isaac64` |
| CSPRNGs | `ChaCha`, `Ascon` |
| Utilities | `SplitMix64` (seeding helper) |
| Integer | `int`, `uintLessThan`, `uintAtMost`, `intRangeLessThan`, `intRangeAtMost` |
| Float | `float`, `floatNorm`, `floatExp` |
| Collections | `boolean`, `enumValue`, `shuffle`, `weightedIndex` |
| Bytes | `bytes` |

## Choosing a PRNG

```
Need crypto security?
├─ Yes → ChaCha (DefaultCsprng) or Ascon
└─ No → Need speed?
       ├─ Yes → Xoshiro256 (DefaultPrng), Sfc64, or RomuTrio
       └─ No → Pcg (smaller state), Xoroshiro128
```

| PRNG | State | Output | Use Case |
|------|-------|--------|----------|
| `Xoshiro256` | 256-bit | 64-bit | Default, fast, good quality |
| `Xoroshiro128` | 128-bit | 64-bit | Smaller state than Xoshiro256 |
| `Pcg` | 128-bit | 32-bit | Compact, statistically excellent |
| `Sfc64` | 256-bit | 64-bit | Very fast |
| `RomuTrio` | 192-bit | 64-bit | Fast, small code size |
| `Isaac64` | 8KB | 64-bit | Cryptographic-ish (prefer ChaCha) |
| `ChaCha` | 512-bit | stream | CSPRNG, forward secure |
| `Ascon` | 320-bit | stream | CSPRNG, lightweight |

## Basic Usage

### Quick Start with DefaultPrng

```zig
const std = @import("std");

pub fn main() void {
    // Initialize with a seed
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Generate random values
    const n = random.int(u32);           // 0 to maxInt(u32)
    const dice = random.intRangeLessThan(u8, 1, 7);  // 1-6
    const coin = random.boolean();
    const prob = random.float(f32);      // [0, 1)
}
```

### Cryptographically Secure Random

```zig
const std = @import("std");

pub fn main() void {
    // Use std.crypto.random for system entropy
    const secure = std.crypto.random;

    var key: [32]u8 = undefined;
    secure.bytes(&key);  // fill with cryptographically secure random bytes

    const token = secure.int(u64);
}
```

### Seeding from System Entropy

```zig
var seed: u64 = undefined;
std.crypto.random.bytes(std.mem.asBytes(&seed));
var prng = std.Random.DefaultPrng.init(seed);
```

## PRNG Initialization

### Xoshiro256 (Default)

```zig
var prng = std.Random.Xoshiro256.init(seed);
const random = prng.random();

// Jump ahead 2^128 steps (for parallel streams)
prng.jump();
```

### ChaCha (CSPRNG)

```zig
// Requires 32-byte secret seed
var secret_seed: [std.Random.ChaCha.secret_seed_length]u8 = undefined;
std.crypto.random.bytes(&secret_seed);

var csprng = std.Random.ChaCha.init(secret_seed);
const random = csprng.random();

// Add entropy to refresh internal state
csprng.addEntropy(&additional_entropy);
```

### Pcg

```zig
var prng = std.Random.Pcg.init(seed);
const random = prng.random();
```

### Other PRNGs

```zig
// All follow the same pattern
var xoro = std.Random.Xoroshiro128.init(seed);
var sfc = std.Random.Sfc64.init(seed);
var romu = std.Random.RomuTrio.init(seed);
var isaac = std.Random.Isaac64.init(seed);
var ascon = std.Random.Ascon.init(secret_seed);
```

## Generating Random Values

### Integers

```zig
const random = prng.random();

// Full range of type
const u8_val = random.int(u8);     // 0 to 255
const i32_val = random.int(i32);   // minInt to maxInt

// Less than upper bound: [0, less_than)
const index = random.uintLessThan(usize, array.len);
const digit = random.uintLessThan(u8, 10);  // 0-9

// At most (inclusive): [0, at_most]
const die = random.uintAtMost(u8, 5);  // 0-5

// Range (exclusive upper): [at_least, less_than)
const temp = random.intRangeLessThan(i16, -40, 50);

// Range (inclusive): [at_least, at_most]
const year = random.intRangeAtMost(u16, 2000, 2024);
```

### Biased Variants (Constant Time)

For timing-sensitive code where bias is acceptable:

```zig
// Slightly biased but constant-time
const n = random.uintLessThanBiased(u32, 100);
const m = random.uintAtMostBiased(u32, 99);
const r = random.intRangeLessThanBiased(i32, -50, 50);
const s = random.intRangeAtMostBiased(i32, -50, 50);
```

### Floating Point

```zig
// Uniform in [0, 1)
const uniform: f32 = random.float(f32);
const uniform64: f64 = random.float(f64);

// Scale to range [a, b)
const scaled = a + (b - a) * random.float(f64);

// Normal distribution (mean=0, stddev=1)
const normal: f64 = random.floatNorm(f64);
// Custom mean/stddev: value * stddev + mean
const custom_normal = random.floatNorm(f64) * 10.0 + 50.0;

// Exponential distribution (rate=1)
const exponential: f64 = random.floatExp(f64);
// Custom rate: value / rate
const custom_exp = random.floatExp(f64) / 0.5;
```

### Boolean

```zig
const coin_flip = random.boolean();

if (random.boolean()) {
    // 50% chance
}
```

### Enum Values

```zig
const Direction = enum { north, south, east, west };

// Random enum value (evenly distributed)
const dir = random.enumValue(Direction);

// With explicit index type for cross-platform consistency
const dir2 = random.enumValueWithIndex(Direction, u32);
```

### Bytes

```zig
var buffer: [32]u8 = undefined;
random.bytes(&buffer);

// Generate a random string
var id: [16]u8 = undefined;
random.bytes(&id);
const hex = std.fmt.fmtSliceHexLower(&id);
```

## Collections

### Shuffle

```zig
var items = [_]u32{ 1, 2, 3, 4, 5 };
random.shuffle(u32, &items);

// With explicit index type for reproducibility
random.shuffleWithIndex(u32, &items, u32);
```

### Weighted Selection

```zig
const weights = [_]f32{ 0.5, 0.3, 0.2 };  // 50%, 30%, 20%
const choice = random.weightedIndex(f32, &weights);

// With integer weights
const int_weights = [_]u32{ 5, 3, 2 };
const int_choice = random.weightedIndex(u32, &int_weights);
```

### Random Element from Slice

```zig
fn randomElement(comptime T: type, random: std.Random, slice: []const T) T {
    const index = random.uintLessThan(usize, slice.len);
    return slice[index];
}

const colors = [_][]const u8{ "red", "green", "blue" };
const color = randomElement([]const u8, random, &colors);
```

### Random Sample (Without Replacement)

```zig
fn sample(comptime T: type, random: std.Random, source: []const T, dest: []T) void {
    // Fisher-Yates partial shuffle
    var indices: [source.len]usize = undefined;
    for (&indices, 0..) |*idx, i| idx.* = i;

    for (dest, 0..) |*d, i| {
        const j = random.intRangeLessThan(usize, i, source.len);
        std.mem.swap(usize, &indices[i], &indices[j]);
        d.* = source[indices[i]];
    }
}
```

## Common Patterns

### Reproducible Sequences

```zig
// Same seed = same sequence
const seed: u64 = 42;

var prng1 = std.Random.DefaultPrng.init(seed);
var prng2 = std.Random.DefaultPrng.init(seed);

std.debug.assert(prng1.random().int(u64) == prng2.random().int(u64));
```

### Thread-Local PRNGs

```zig
threadlocal var tls_prng: ?std.Random.DefaultPrng = null;

fn getThreadRandom() std.Random {
    if (tls_prng == null) {
        var seed: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        tls_prng = std.Random.DefaultPrng.init(seed);
    }
    return tls_prng.?.random();
}
```

### Parallel Streams with Jump

```zig
fn createParallelStreams(base_seed: u64, n: usize, allocator: std.mem.Allocator) ![]std.Random.Xoshiro256 {
    const prngs = try allocator.alloc(std.Random.Xoshiro256, n);

    prngs[0] = std.Random.Xoshiro256.init(base_seed);
    for (prngs[1..], 1..) |*prng, i| {
        prng.* = prngs[i - 1];
        prng.jump();  // advance 2^128 steps
    }

    return prngs;
}
```

### Monte Carlo Simulation

```zig
fn estimatePi(random: std.Random, samples: usize) f64 {
    var inside: usize = 0;
    for (0..samples) |_| {
        const x = random.float(f64);
        const y = random.float(f64);
        if (x * x + y * y <= 1.0) inside += 1;
    }
    return 4.0 * @as(f64, @floatFromInt(inside)) / @as(f64, @floatFromInt(samples));
}
```

### Random Password Generator

```zig
const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*";

fn generatePassword(random: std.Random, buf: []u8) void {
    for (buf) |*c| {
        c.* = charset[random.uintLessThan(usize, charset.len)];
    }
}

// Usage
var password: [16]u8 = undefined;
generatePassword(std.crypto.random, &password);
```

### Gaussian Random with Box-Muller

The built-in `floatNorm` uses ziggurat algorithm. For explicit Box-Muller:

```zig
fn boxMullerPair(random: std.Random) struct { f64, f64 } {
    const u1 = 1.0 - random.float(f64);  // (0, 1]
    const u2 = random.float(f64);         // [0, 1)

    const r = @sqrt(-2.0 * @log(u1));
    const theta = 2.0 * std.math.pi * u2;

    return .{ r * @cos(theta), r * @sin(theta) };
}
```

## Custom PRNG Implementation

Implement a custom PRNG by providing a `fill` function:

```zig
const MyPrng = struct {
    state: u64,

    pub fn init(seed: u64) MyPrng {
        return .{ .state = seed };
    }

    pub fn random(self: *MyPrng) std.Random {
        return std.Random.init(self, fill);
    }

    fn fill(self: *MyPrng, buf: []u8) void {
        for (buf) |*b| {
            // Simple LCG (not for production!)
            self.state = self.state *% 6364136223846793005 +% 1;
            b.* = @truncate(self.state >> 56);
        }
    }
};
```

## Notes

- `DefaultPrng` is `Xoshiro256` - fast, high quality, not cryptographic
- `DefaultCsprng` is `ChaCha` - cryptographically secure with forward secrecy
- For crypto: use `std.crypto.random` which provides system entropy
- `uintLessThan`/`intRangeLessThan` may reject values (not constant-time)
- Use biased variants (`*Biased`) for timing-sensitive applications
- `jump()` on Xoshiro256 advances 2^128 steps for parallel streams
- `float()` returns values in [0, 1) covering all representable values
- `floatNorm()` and `floatExp()` use efficient ziggurat algorithm
