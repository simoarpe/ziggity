# std.hash - Hash Functions

Non-cryptographic hash functions for hash tables, checksums, and data integrity. For cryptographic hashing, use `std.crypto.hash`.

## Quick Reference

| Category | Types |
|----------|-------|
| General Purpose | `Wyhash` (default for HashMap), `XxHash64`, `XxHash32`, `XxHash3` |
| Classic | `Fnv1a_32`, `Fnv1a_64`, `Fnv1a_128`, `Murmur2_32`, `Murmur2_64`, `Murmur3_32` |
| Checksum | `Crc32`, `Adler32`, `crc.*` (100+ CRC variants) |
| City | `CityHash32`, `CityHash64` |
| SipHash | `SipHash64`, `SipHash128` (from `std.crypto.siphash`) |
| Auto-hashing | `autoHash`, `autoHashStrat`, `hash.int` |

## Choosing a Hash Function

```
Need a hash for HashMap?
├─ Yes → Use default (Wyhash via std.hash.autoHash)
└─ No → Need checksum/integrity?
        ├─ Yes → Crc32 or Adler32
        └─ No → Need speed?
               ├─ Yes → XxHash3, XxHash64, or Wyhash
               └─ No → Fnv1a (simple), Murmur (portable)
```

| Hash | Output | Speed | Use Case |
|------|--------|-------|----------|
| `Wyhash` | 64-bit | Very fast | Default for HashMap, general hashing |
| `XxHash3` | 64-bit | Fastest | Large data, streaming |
| `XxHash64` | 64-bit | Fast | General purpose |
| `Fnv1a_64` | 64-bit | Moderate | Simple, small code size |
| `Murmur3_32` | 32-bit | Fast | Portable, well-tested |
| `CityHash64` | 64-bit | Fast | Google's hash, good distribution |
| `Crc32` | 32-bit | Fast | Checksums, error detection |
| `Adler32` | 32-bit | Very fast | Lightweight checksums |

## Basic Usage

### One-Shot Hashing

```zig
const std = @import("std");
const hash = std.hash;

// Wyhash (recommended default)
const h1 = hash.Wyhash.hash(0, "hello world");

// XxHash
const h2 = hash.XxHash64.hash(0, "hello world");
const h3 = hash.XxHash3.hash(0, "hello world");

// FNV-1a
const h4 = hash.Fnv1a_64.hash("hello world");

// Murmur
const h5 = hash.Murmur2_64.hash("hello world");
const h6 = hash.Murmur3_32.hash("hello world");

// CityHash
const h7 = hash.CityHash64.hash("hello world");
```

### Streaming/Incremental Hashing

All hashers support incremental updates for large or streaming data:

```zig
const std = @import("std");

// Initialize hasher
var hasher = std.hash.Wyhash.init(0);  // 0 is the seed

// Update with data incrementally
hasher.update("hello ");
hasher.update("world");

// Get final hash
const result = hasher.final();
```

### With Seed

```zig
// Different seeds produce different hashes
const seed: u64 = 12345;

const h1 = std.hash.Wyhash.hash(seed, "data");
const h2 = std.hash.XxHash64.hash(seed, "data");

// Fnv1a doesn't take a seed in hash(), use init() for streaming
var fnv = std.hash.Fnv1a_64.init();
fnv.update("data");
const h3 = fnv.final();
```

## Auto-Hashing (Generic Types)

`std.hash.autoHash` automatically hashes any Zig type:

```zig
const std = @import("std");

const Point = struct {
    x: i32,
    y: i32,
};

fn hashPoint(p: Point) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, p);
    return hasher.final();
}

// Works with any hashable type
fn hashAny(value: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, value);
    return hasher.final();
}

// Usage
const h1 = hashAny(Point{ .x = 10, .y = 20 });
const h2 = hashAny(@as(u32, 42));
const h3 = hashAny(MyEnum.value);
```

### Hash Strategy for Pointers

`autoHashStrat` controls how pointers are hashed:

```zig
const std = @import("std");
const Strategy = std.hash.Strategy;

var hasher = std.hash.Wyhash.init(0);
const data: []const u8 = "hello";

// Shallow: hash pointer address only (default for autoHash)
std.hash.autoHashStrat(&hasher, data, .Shallow);

// Deep: follow pointer, hash contents (one level)
std.hash.autoHashStrat(&hasher, data, .Deep);

// DeepRecursive: follow all pointers recursively
std.hash.autoHashStrat(&hasher, data, .DeepRecursive);
```

| Strategy | Behavior |
|----------|----------|
| `.Shallow` | Hash pointer address, not contents |
| `.Deep` | Follow pointer one level, hash contents |
| `.DeepRecursive` | Follow all pointers, hash all contents |

## Integer Hashing

`std.hash.int` provides optimized integer-to-integer hashing:

```zig
const std = @import("std");

// Hash integers directly (preserves type)
const h1: u32 = std.hash.int(@as(u32, 12345));
const h2: u64 = std.hash.int(@as(u64, 12345));
const h3: i32 = std.hash.int(@as(i32, -42));

// Useful for hash table probing
fn probe(key: u64, attempt: usize) u64 {
    return std.hash.int(key +% @as(u64, attempt));
}
```

## Checksum Functions

### CRC32

```zig
const std = @import("std");
const Crc32 = std.hash.Crc32;

// One-shot
const checksum = Crc32.hash("data to checksum");

// Streaming
var crc = Crc32.init();
crc.update("data ");
crc.update("to checksum");
const result = crc.final();
```

### CRC Variants

Over 100 CRC variants available:

```zig
const crc = std.hash.crc;

// Common variants
const Crc32IsoHdlc = crc.Crc32IsoHdlc;  // Standard CRC-32 (default)
const Crc32Iscsi = crc.Crc32Iscsi;      // CRC-32C (Castagnoli)
const Crc16Usb = crc.Crc16Usb;
const Crc16Modbus = crc.Crc16Modbus;
const Crc8Bluetooth = crc.Crc8Bluetooth;

// Usage
const checksum = crc.Crc32Iscsi.hash("data");
```

### Custom CRC

```zig
const std = @import("std");
const Crc = std.hash.crc.Crc;

// Define custom CRC
const MyCrc = Crc(u16, .{
    .polynomial = 0x8005,
    .initial = 0xFFFF,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0x0000,
});

const checksum = MyCrc.hash("data");
```

### Adler32

Faster than CRC but weaker error detection:

```zig
const std = @import("std");
const Adler32 = std.hash.Adler32;

const checksum = Adler32.hash("data");

// Streaming
var adler = Adler32.init();
adler.update("data");
const result = adler.final();
```

## Using with HashMap

HashMap uses `std.hash.autoHash` by default:

```zig
const std = @import("std");

// Default string HashMap (uses Wyhash internally)
var map = std.StringHashMap(u32).init(allocator);
defer map.deinit();

try map.put("key", 42);

// Custom key type
const Point = struct {
    x: i32,
    y: i32,
};

// AutoHashMap handles hashing automatically
var point_map = std.AutoHashMap(Point, []const u8).init(allocator);
defer point_map.deinit();

try point_map.put(.{ .x = 1, .y = 2 }, "origin-ish");
```

### Custom Hash Function for HashMap

```zig
const std = @import("std");

const MyKey = struct {
    id: u64,
    name: []const u8,
};

const MyContext = struct {
    pub fn hash(self: @This(), key: MyKey) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.id));
        h.update(key.name);
        return h.final();
    }

    pub fn eql(self: @This(), a: MyKey, b: MyKey) bool {
        _ = self;
        return a.id == b.id and std.mem.eql(u8, a.name, b.name);
    }
};

var map = std.HashMap(MyKey, u32, MyContext, 80).init(allocator);
```

## Hash Function Details

### Wyhash

Default hash for `std.HashMap`. Very fast with excellent distribution.

```zig
const std = @import("std");
const Wyhash = std.hash.Wyhash;

// One-shot (most efficient for single use)
const h = Wyhash.hash(seed, data);

// Streaming
var hasher = Wyhash.init(seed);
hasher.update(chunk1);
hasher.update(chunk2);
const result = hasher.final();  // idempotent, can call multiple times
```

### XxHash Family

High-performance hash functions by Yann Collet:

```zig
const std = @import("std");

// XxHash3 - fastest for large inputs
const h1 = std.hash.XxHash3.hash(0, data);

// XxHash64 - 64-bit output
const h2 = std.hash.XxHash64.hash(0, data);

// XxHash32 - 32-bit output
const h3 = std.hash.XxHash32.hash(0, data);

// Streaming
var hasher = std.hash.XxHash64.init(0);
hasher.update(chunk);
const result = hasher.final();
```

### FNV-1a

Simple, portable hash. Good for small data:

```zig
const std = @import("std");

// One-shot
const h32 = std.hash.Fnv1a_32.hash("data");
const h64 = std.hash.Fnv1a_64.hash("data");
const h128 = std.hash.Fnv1a_128.hash("data");

// Streaming
var hasher = std.hash.Fnv1a_64.init();
hasher.update("hello ");
hasher.update("world");
const result = hasher.final();
```

### Murmur Hash

Well-tested, portable hash functions:

```zig
const std = @import("std");
const murmur = std.hash.murmur;

// Murmur2
const h1 = murmur.Murmur2_32.hash("data");
const h2 = murmur.Murmur2_64.hash("data");

// Murmur3
const h3 = murmur.Murmur3_32.hash("data");

// With seed
const h4 = murmur.Murmur2_32.hashWithSeed("data", 12345);
const h5 = murmur.Murmur2_64.hashWithSeed("data", 12345);

// Direct integer hashing
const h6 = murmur.Murmur2_32.hashUint32(12345);
const h7 = murmur.Murmur2_64.hashUint64(12345);
```

### CityHash

Google's fast hash function:

```zig
const std = @import("std");
const cityhash = std.hash.cityhash;

const h32 = cityhash.CityHash32.hash("data");
const h64 = cityhash.CityHash64.hash("data");

// With seed
const h64_seeded = cityhash.CityHash64.hashWithSeed("data", 12345);
```

### SipHash

Cryptographically strong for hash table protection:

```zig
const std = @import("std");

// Requires 128-bit key
const key: [16]u8 = .{0} ** 16;

const h64 = std.hash.SipHash64(2, 4).hash(&key, "data");
const h128 = std.hash.SipHash128(2, 4).hash(&key, "data");

// Default parameters (2-4 rounds)
const SipHash = std.hash.SipHash64(2, 4);
```

## Common Patterns

### Combine Multiple Values

```zig
fn combineHashes(a: u64, b: u64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&a));
    hasher.update(std.mem.asBytes(&b));
    return hasher.final();
}

// Or use autoHash for any type
fn hashPair(comptime T: type, a: T, b: T) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, a);
    std.hash.autoHash(&hasher, b);
    return hasher.final();
}
```

### File Checksum

```zig
fn checksumFile(path: []const u8) !u32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var crc = std.hash.Crc32.init();
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        crc.update(buf[0..n]);
    }

    return crc.final();
}
```

### Bloom Filter Hash

```zig
fn bloomHashes(data: []const u8, k: usize) []u64 {
    var hashes: [16]u64 = undefined;
    const h1 = std.hash.Wyhash.hash(0, data);
    const h2 = std.hash.Wyhash.hash(h1, data);

    for (0..k) |i| {
        hashes[i] = h1 +% @as(u64, i) *% h2;
    }
    return hashes[0..k];
}
```

### Consistent Hashing

```zig
fn consistentHash(key: []const u8, num_buckets: u32) u32 {
    const hash = std.hash.XxHash64.hash(0, key);
    // Jump consistent hash
    var b: i64 = -1;
    var j: i64 = 0;
    var h = hash;
    while (j < num_buckets) {
        b = j;
        h = h *% 2862933555777941757 +% 1;
        j = @intFromFloat(@as(f64, @floatFromInt(b + 1)) *
            (@as(f64, 1 << 31) / @as(f64, @floatFromInt((h >> 33) + 1))));
    }
    return @intCast(b);
}
```

## Performance Notes

- **Wyhash**: Fastest general-purpose hash, excellent for hash tables
- **XxHash3**: Fastest for large inputs (>256 bytes), uses SIMD when available
- **XxHash64/32**: Good balance of speed and portability
- **Fnv1a**: Simple, small code size, slower for large data
- **Murmur**: Widely compatible, good for cross-platform consistency
- **CityHash**: Fast, optimized for x86
- **Crc32**: Hardware-accelerated on many platforms
- **Adler32**: Fastest checksum, weaker error detection

## Notes

- All hash functions are deterministic (same input = same output)
- Non-cryptographic hashes are NOT suitable for security (use `std.crypto.hash`)
- `autoHash` rejects slices by default to avoid ambiguity; use `autoHashStrat` with explicit strategy
- Streaming APIs (`init`/`update`/`final`) allow hashing data incrementally
- `final()` is idempotent on most hashers (can be called multiple times)
- For HashMap keys, implement custom `hash` and `eql` in a context struct
