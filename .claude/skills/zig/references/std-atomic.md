# std.atomic - Atomic Operations Reference

Lock-free atomic operations for concurrent programming. Wraps Zig's atomic builtins with a type-safe interface.

## Table of Contents
- [Module Structure](#module-structure)
- [Atomic Value Wrapper](#atomic-value-wrapper)
- [Atomic Operations](#atomic-operations)
- [Atomic Ordering](#atomic-ordering)
- [Spin Loop Hint](#spin-loop-hint)
- [Cache Line Size](#cache-line-size)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.atomic.Value(T)        // Atomic wrapper for T (integers, enums, floats, bools, pointers)
std.atomic.spinLoopHint()  // CPU hint for spin-wait loops
std.atomic.cache_line      // CPU cache line size (comptime constant)
```

## Atomic Value Wrapper

`std.atomic.Value(T)` wraps a value to enable atomic operations. Supported types: integers, enums, floats, bools, optional pointers.

### Creation

```zig
const std = @import("std");

// Initialize with value
var counter = std.atomic.Value(u64).init(0);

// Initialize in struct
const State = struct {
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

// Direct access (careful - not atomic!)
var x = std.atomic.Value(u32).init(10);
x.raw = 20;  // Non-atomic write - use only when no concurrent access
```

### Basic Operations

```zig
var x = std.atomic.Value(u32).init(5);

// Load (atomic read)
const val = x.load(.acquire);

// Store (atomic write)
x.store(10, .release);

// Swap (exchange, returns old value)
const old = x.swap(20, .seq_cst);  // old = 10, x = 20
```

## Atomic Operations

### Fetch-and-Modify Operations

All return the **previous** value before modification:

```zig
var x = std.atomic.Value(i32).init(10);

// Arithmetic
_ = x.fetchAdd(5, .seq_cst);   // x = 15, returns 10
_ = x.fetchSub(3, .seq_cst);   // x = 12, returns 15
_ = x.fetchMin(8, .seq_cst);   // x = 8,  returns 12
_ = x.fetchMax(20, .seq_cst);  // x = 20, returns 8

// Bitwise
var bits = std.atomic.Value(u8).init(0b1100);
_ = bits.fetchAnd(0b1010, .seq_cst);  // 0b1000
_ = bits.fetchOr(0b0011, .seq_cst);   // 0b1011
_ = bits.fetchXor(0b1111, .seq_cst);  // 0b0100
_ = bits.fetchNand(0b1100, .seq_cst); // ~(0b0100 & 0b1100) = ~0b0100

// Generic RMW (any AtomicRmwOp)
_ = x.rmw(.Add, 1, .seq_cst);
```

### Compare-and-Swap (CAS)

```zig
var x = std.atomic.Value(u32).init(100);

// Strong CAS - guaranteed to succeed if values match
const result = x.cmpxchgStrong(100, 200, .seq_cst, .seq_cst);
// result = null (success, x is now 200)
// result = 100 (failure, current value if mismatch)

// Weak CAS - may spuriously fail, use in loops
var current: u32 = x.load(.acquire);
while (x.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
    current = actual;  // Retry with actual value
}
```

**When to use which:**
- `cmpxchgStrong`: Single attempt, no retry loop
- `cmpxchgWeak`: In retry loops (more efficient on some architectures)

### Bit Operations

Individual bit manipulation, returning previous bit state:

```zig
var flags = std.atomic.Value(u32).init(0);

// Set bit (returns previous bit value: 0 or 1)
const was_set = flags.bitSet(3, .seq_cst);   // Set bit 3

// Reset bit
const was_reset = flags.bitReset(3, .seq_cst);  // Clear bit 3

// Toggle bit
const prev = flags.bitToggle(5, .seq_cst);  // Flip bit 5
```

## Atomic Ordering

Memory orderings control synchronization guarantees. From `std.builtin.AtomicOrder`:

| Order | Guarantees | Use Case |
|-------|------------|----------|
| `.unordered` | No ordering, loads/stores only (no RMW) | Preventing torn reads/writes only (e.g., data inside SeqLock) |
| `.monotonic` | Coherent on same variable, reorderable with other atomics | Simple counters, progress indicators |
| `.acquire` | Subsequent reads/writes won't move before this | Loading shared data after flag check |
| `.release` | Prior reads/writes won't move after this | Publishing data before setting flag |
| `.acq_rel` | Both acquire and release | Read-modify-write on shared data |
| `.seq_cst` | Total order among all seq_cst operations | When multiple atomics must be globally ordered |

### Ordering Guidelines

```zig
// Producer-consumer pattern
var data: Data = undefined;
var ready = std.atomic.Value(bool).init(false);

// Producer thread
fn produce() void {
    data = computeData();       // Write data first
    ready.store(true, .release); // Then publish (release ensures order)
}

// Consumer thread
fn consume() void {
    while (!ready.load(.acquire)) {  // Acquire synchronizes with release
        std.atomic.spinLoopHint();
    }
    useData(data);  // Safe to read after acquire
}
```

**Rules of thumb:**
- `.monotonic` for counters that don't guard other data (can still reorder with other atomics)
- `.release` when publishing/storing data that others will read
- `.acquire` when consuming/loading data others published
- `.acq_rel` for RMW operations that both read and write shared state
- `.seq_cst` when multiple atomics must have a single global order visible to all threads (only orders with other seq_cst ops)

## Spin Loop Hint

`spinLoopHint()` tells the CPU it's in a spin-wait loop, improving power efficiency and SMT performance:

```zig
fn spinWait(flag: *std.atomic.Value(bool)) void {
    while (!flag.load(.acquire)) {
        std.atomic.spinLoopHint();  // Reduce power, yield to sibling threads
    }
}
```

Architecture-specific behavior:
- **x86/x86_64**: `pause` instruction
- **AArch64**: `isb` instruction
- **ARM**: `yield` instruction (v6k+)
- **RISC-V**: `pause` (Zihintpause extension)
- **Others**: No-op

## Cache Line Size

`cache_line` is the CPU cache line size, used to prevent false sharing:

```zig
const cache_line = std.atomic.cache_line;  // 64, 128, etc.

// Pad struct to avoid false sharing between threads
const PaddedCounter = struct {
    value: std.atomic.Value(u64) align(cache_line) = std.atomic.Value(u64).init(0),
    _padding: [cache_line - @sizeOf(std.atomic.Value(u64))]u8 = undefined,
};

// Per-thread counters without false sharing
const ThreadCounters = struct {
    counters: [MAX_THREADS]PaddedCounter = [_]PaddedCounter{.{}} ** MAX_THREADS,
};
```

Typical values by architecture:
- x86_64, AArch64: 128 bytes (big cores)
- ARM, MIPS: 32 bytes
- Most others: 64 bytes

## Common Patterns

### Thread-Safe Counter

```zig
const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn increment(self: *@This()) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn decrement(self: *@This()) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn get(self: *const @This()) u64 {
        return self.value.load(.monotonic);
    }
};
```

### Reference Counting

```zig
const RefCounted = struct {
    ref_count: std.atomic.Value(usize),
    data: *Data,

    pub fn retain(self: *@This()) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *@This()) void {
        // Release ensures writes before release are visible to thread that sees 1
        if (self.ref_count.fetchSub(1, .release) == 1) {
            // Acquire synchronizes with all previous releases
            _ = self.ref_count.load(.acquire);
            self.destroy();
        }
    }
};
```

### Lock-Free Stack (Treiber Stack)

**Note:** This simplified implementation only supports single-consumer (one thread calling `pop()` at a time). Multiple concurrent poppers require ABA protection (hazard pointers, epoch-based reclamation, or tagged pointers) to safely read `node.next` without use-after-free.

```zig
fn Stack(comptime T: type) type {
    return struct {
        const Node = struct {
            value: T,
            next: ?*Node,
        };

        head: std.atomic.Value(?*Node) = std.atomic.Value(?*Node).init(null),

        pub fn push(self: *@This(), node: *Node) void {
            var current_head = self.head.load(.acquire);
            while (true) {
                node.next = current_head;
                if (self.head.cmpxchgWeak(current_head, node, .release, .acquire)) |actual| {
                    current_head = actual;
                } else {
                    break;  // Success
                }
            }
        }

        // Single-consumer only! See note above.
        pub fn pop(self: *@This()) ?*Node {
            var current_head = self.head.load(.acquire);
            while (current_head) |node| {
                if (self.head.cmpxchgWeak(current_head, node.next, .acq_rel, .acquire)) |actual| {
                    current_head = actual;
                } else {
                    return node;  // Success
                }
            }
            return null;  // Empty
        }
    };
}
```

### Once Initialization (Double-Checked Locking)

```zig
var initialized = std.atomic.Value(bool).init(false);
var init_mutex: std.Thread.Mutex = .{};
var global_resource: ?*Resource = null;

fn getResource() *Resource {
    // Fast path: already initialized
    if (initialized.load(.acquire)) {
        return global_resource.?;
    }

    // Slow path: initialize with lock
    init_mutex.lock();
    defer init_mutex.unlock();

    if (!initialized.load(.acquire)) {
        global_resource = initializeResource();
        initialized.store(true, .release);
    }

    return global_resource.?;
}
```

### Spin Lock

```zig
const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *@This()) void {
        while (self.locked.swap(true, .acquire)) {
            while (self.locked.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *@This()) void {
        self.locked.store(false, .release);
    }

    pub fn tryLock(self: *@This()) bool {
        return !self.locked.swap(true, .acquire);
    }
};
```

### Progress Flag (SeqLock)

**Note:** `Data` must be a type that supports atomic load/store (integers, bools, enums, floats, pointers). For larger structs, use a pointer or different synchronization.

```zig
const SeqLock = struct {
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    data: Data = .{},

    // Single-writer only!
    pub fn write(self: *@This(), new_data: Data) void {
        // Odd sequence = write in progress
        _ = self.seq.fetchAdd(1, .release);
        @atomicStore(Data, &self.data, new_data, .unordered);
        _ = self.seq.fetchAdd(1, .release);
    }

    pub fn read(self: *@This()) Data {
        while (true) {
            const seq1 = self.seq.load(.acquire);
            if (seq1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;  // Write in progress
            }
            const data = @atomicLoad(Data, &self.data, .unordered);
            const seq2 = self.seq.load(.acquire);
            if (seq1 == seq2) return data;
            std.atomic.spinLoopHint();
        }
    }
};
```

### Barrier Synchronization

```zig
const Barrier = struct {
    counter: std.atomic.Value(usize),
    generation: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    total: usize,

    pub fn init(count: usize) @This() {
        return .{
            .counter = std.atomic.Value(usize).init(count),
            .total = count,
        };
    }

    pub fn wait(self: *@This()) void {
        const gen = self.generation.load(.acquire);
        if (self.counter.fetchSub(1, .acq_rel) == 1) {
            // Last thread to arrive
            self.counter.store(self.total, .release);
            _ = self.generation.fetchAdd(1, .release);
        } else {
            // Wait for generation to change
            while (self.generation.load(.acquire) == gen) {
                std.atomic.spinLoopHint();
            }
        }
    }
};
```

## See Also

- **[std.Thread](std-thread.md)** - Higher-level synchronization (Mutex, RwLock, Condition, Semaphore)
- **[std.Thread.Futex](std-thread.md)** - OS-level blocking primitives
