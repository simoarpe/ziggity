# std.heap - Allocators

Zig has no default allocator. Functions that need heap memory accept an `Allocator` parameter.

## Quick Reference

| Allocator | Use Case | Thread-Safe |
|-----------|----------|-------------|
| `std.testing.allocator` | Unit tests (leak detection) | No |
| `std.heap.FixedBufferAllocator` | Stack-based, bounded size known | Optional |
| `std.heap.ArenaAllocator` | Batch free, CLI apps, request handlers | No |
| `std.heap.page_allocator` | Backing for other allocators | Yes |
| `std.heap.c_allocator` | Linking libc, interop | Yes |
| `std.heap.raw_c_allocator` | Libc arena backing (no alignment overhead) | Yes |
| `std.heap.DebugAllocator` | Debug builds, leak/corruption detection | Configurable |
| `std.heap.smp_allocator` | ReleaseFast production multithreaded | Yes |
| `std.heap.MemoryPool` | High-frequency same-type allocations | No |
| `std.heap.ThreadSafeAllocator` | Wrap non-thread-safe allocator | Yes |
| `std.heap.StackFallbackAllocator` | Stack buffer with heap fallback | Depends |
| `std.heap.wasm_allocator` | WebAssembly targets | Yes |

## Allocator Naming Conventions

Using a generic `allocator` name hides memory ownership contracts. Name allocators by their **memory contract** to make code self-documenting:

| Name | Contract | Can Return Data? |
|------|----------|------------------|
| `gpa` | Caller **must** free with `defer gpa.free()` | Yes |
| `arena` | Bulk-deallocated at system boundary | Yes |
| `scratch` | Function-private temporary space | **Never** |

### The Problem

```zig
// BAD - "allocator" says nothing about ownership
fn process(allocator: Allocator) ![]u8 {
    const temp = try allocator.alloc(u8, 100);  // Who frees this?
    const result = try allocator.dupe(u8, temp); // Who owns this?
    allocator.free(temp);  // Is this correct?
    return result;  // Can caller free with same allocator?
}
```

### The Solution

Name allocators by their contract:

```zig
// GOOD - names communicate ownership contracts
fn process(
    gpa: Allocator,      // General-purpose: caller must free returned data
    scratch: Allocator,  // Temporary: never return data allocated here
) ![]u8 {
    // scratch is for intermediate computation only
    const temp = try scratch.alloc(u8, 100);
    defer scratch.free(temp);

    // gpa for data that outlives this function
    return try gpa.dupe(u8, computeResult(temp));
}
```

### Full Example with All Three

```zig
fn handleRequest(
    request: *Request,
    arena: Allocator,   // Response lifetime - bulk freed after response sent
    gpa: Allocator,     // Long-lived data - cache, shared state
    scratch: Allocator, // This function only - intermediate computation
) !Response {
    // Scratch: temporary parsing buffers (never escapes this function)
    const parsed = try parseBody(request.body, scratch);

    // GPA: update shared cache (outlives request)
    try updateCache(gpa, parsed.cache_key, parsed.value);

    // Arena: response data (freed when response completes)
    const response_body = try formatResponse(arena, parsed);

    return Response{ .body = response_body };
}
```

### Common Patterns

**CLI applications** - arena for everything, freed at exit:
```zig
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    try run(arena.allocator());  // Name as "arena" - bulk freed at end
}
```

**Request handlers** - arena per request, gpa for shared state:
```zig
fn handleRequest(gpa: Allocator, request: Request) !Response {
    var request_arena = std.heap.ArenaAllocator.init(gpa);
    defer request_arena.deinit();
    const arena = request_arena.allocator();

    // arena: request-scoped data
    // gpa: data that outlives the request (caches, connections)
}
```

**Functions with temporary allocations** - scratch parameter:
```zig
/// Computes result using scratch for intermediate work.
/// Caller owns returned slice (allocated from gpa).
fn compute(gpa: Allocator, scratch: Allocator, input: []const u8) ![]u8 {
    const temp = try scratch.alloc(u8, input.len * 2);
    defer scratch.free(temp);
    // ... use temp for intermediate computation ...
    return try gpa.dupe(u8, result);
}
```

## Allocator Interface

```zig
const Allocator = std.mem.Allocator;

// Single items: create/destroy
const ptr: *T = try allocator.create(T);
defer allocator.destroy(ptr);

// Slices: alloc/free
const slice: []T = try allocator.alloc(T, count);
defer allocator.free(slice);

// Duplicate existing slice
const copy = try allocator.dupe(u8, source);
defer allocator.free(copy);

// Resize (returns bool - true if resized in place)
if (allocator.resize(slice, new_len)) {
    // slice is now new_len (pointer unchanged)
}

// Reallocate (may move, returns new slice)
slice = try allocator.realloc(slice, new_len);
```

## Choosing an Allocator

**Decision flow:**

1. **Library code?** Accept `Allocator` parameter - let caller decide
2. **Unit test?** Use `std.testing.allocator` (has leak detection)
3. **Size known at comptime?** Use `FixedBufferAllocator` with stack buffer
4. **Stack with heap fallback?** Use `stackFallback(N, backing_allocator)`
5. **CLI app / one-shot?** Use `ArenaAllocator` wrapping `page_allocator`
6. **Request loop (web/game)?** Use `ArenaAllocator`, reset per iteration
7. **Many same-type objects?** Use `MemoryPool(T)` for fast create/destroy
8. **Debug build?** Use `DebugAllocator` for leak/corruption detection
9. **ReleaseFast production?** Use `std.heap.smp_allocator`
10. **Linking libc?** Use `c_allocator` or `raw_c_allocator` (as arena backing)

## Common Allocators

### Testing Allocator

```zig
test "example" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);  // Leak detected if missing!
}
```

### FixedBufferAllocator

No heap allocations - allocates into a fixed buffer. Useful for kernels, embedded, or performance-critical code. Returns `OutOfMemory` when buffer exhausted:

```zig
var buffer: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
const allocator = fba.allocator();

const data = try allocator.alloc(u8, 100);
// Free/resize only works for most recent allocation
allocator.free(data);

// Reset to reuse buffer
fba.reset();
```

**Thread-safe variant** (allocate only - no resize/free):
```zig
const ts_allocator = fba.threadSafeAllocator();
```

**Ownership checks:**
```zig
if (fba.ownsPtr(ptr)) { ... }    // Check if pointer is within buffer
if (fba.ownsSlice(slice)) { ... } // Check if slice is within buffer
```

### ArenaAllocator

Wraps a child allocator. Allocate many times, free all at once with `.deinit()`. Individual `free()` only works for most recent allocation:

```zig
// CLI app pattern - allocate freely, free all at end
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try allocator.alloc(u8, 1000);
    const more = try allocator.alloc(u8, 2000);
    // No need to free individual allocations
}

// Request loop pattern - reset per iteration
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

while (running) {
    _ = arena.reset(.retain_capacity);  // Keep memory, reset state
    const allocator = arena.allocator();
    try handleRequest(allocator);
}
```

**Reset modes:**

- `.free_all` - Release all memory to backing allocator
- `.retain_capacity` - Keep allocated pages for reuse (faster)
- `.{ .retain_with_limit = N }` - Retain up to N bytes

**Query current usage:**
```zig
const bytes_used = arena.queryCapacity();  // Excludes internal overhead
```

**State optimization** - store just the state to save memory:
```zig
const State = std.heap.ArenaAllocator.State;
var state: State = .{};

// Promote to full allocator when needed
var arena = state.promote(std.heap.page_allocator);
defer arena.deinit();
```

### DebugAllocator

Detects leaks, double-free, use-after-free. Designed for safety over performance, but still faster than `page_allocator`. Safety checks and thread safety configurable:

```zig
var gpa: std.heap.DebugAllocator(.{}) = .init;
defer {
    const check = gpa.deinit();
    if (check == .leak) {
        std.debug.print("Memory leak detected!\n", .{});
    }
}
const allocator = gpa.allocator();
```

**Configuration options:**

```zig
var gpa: std.heap.DebugAllocator(.{
    .stack_trace_frames = 10,     // Capture more frames
    .enable_memory_limit = true,  // Track total bytes
    .safety = true,               // Enable safety checks
    .thread_safe = true,          // Multi-thread support
    .never_unmap = true,          // Debug use-after-free
    .retain_metadata = true,      // Better double-free detection
}) = .init;
```

### SmpAllocator

Maximum performance for multithreaded ReleaseFast builds. Few safety features:

```zig
const allocator = std.heap.smp_allocator;
const data = try allocator.alloc(u8, 1000);
allocator.free(data);
```

### C Allocator

Alternative when `smp_allocator` is not available. Requires linking libc (`-lc`):

```zig
const allocator = std.heap.c_allocator;
```

### Page Allocator

Requests entire pages from OS via syscall. A 1-byte allocation reserves multiple kibibytes - inefficient for small allocations. Use as backing allocator for `ArenaAllocator` or `DebugAllocator`:

```zig
const allocator = std.heap.page_allocator;
```

### MemoryPool

Fast allocator for many objects of the same type. Outperforms general-purpose allocators when allocating/freeing objects in rapid succession:

```zig
var pool = std.heap.MemoryPool(MyStruct).init(std.heap.page_allocator);
defer pool.deinit();

// Allocate objects (very fast)
const obj1 = try pool.create();
const obj2 = try pool.create();

// Free returns to pool for reuse (not to backing allocator)
pool.destroy(obj1);

// Reuses freed slot
const obj3 = try pool.create();  // likely same address as obj1

// Reset all - batch destroy without individual frees
_ = pool.reset(.retain_capacity);
```

**Options:**
```zig
// Pre-allocate slots
var pool = try std.heap.MemoryPool(T).initPreheated(allocator, 100);

// Custom alignment
var pool = std.heap.MemoryPoolAligned(T, .@"64").init(allocator);

// Non-growable (fixed capacity)
var pool = try std.heap.MemoryPoolExtra(T, .{ .growable = false }).initPreheated(allocator, 50);
```

### ThreadSafeAllocator

Wraps any allocator with mutex for thread safety:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

var ts = std.heap.ThreadSafeAllocator{
    .child_allocator = arena.allocator(),
};
const allocator = ts.allocator();  // Safe to use from multiple threads
```

### StackFallbackAllocator

Allocates from stack buffer first, falls back to another allocator when exhausted:

```zig
var fallback = std.heap.stackFallback(4096, std.heap.page_allocator);
const allocator = fallback.get();

// First 4KB comes from stack (no heap allocation)
const small = try allocator.alloc(u8, 100);

// Falls back to page_allocator if stack buffer exhausted
const large = try allocator.alloc(u8, 10000);
```

### raw_c_allocator

Direct malloc/free without alignment overhead. Use as `ArenaAllocator` backing when linking libc:

```zig
// More efficient than c_allocator when wrapping with ArenaAllocator
var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
defer arena.deinit();
```

Requires linking libc. Does not support custom alignment - asserts alignment <= `@alignOf(std.c.max_align_t)`.

### Wasm Allocator

Optimized for WebAssembly. Uses `@wasmMemoryGrow`:

```zig
const allocator = std.heap.wasm_allocator;  // Only on wasm32/wasm64
```

## Page Size Constants

```zig
std.heap.page_size_min  // Comptime minimum page size for target
std.heap.page_size_max  // Comptime maximum page size for target
std.heap.pageSize()     // Runtime page size (may be comptime if min == max)
```

## Passing Allocators

**In libraries - accept allocator parameter:**

```zig
pub fn MyContainer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        data: []T,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator, .data = &.{} };
        }

        pub fn deinit(self: *@This()) void {
            if (self.data.len > 0) {
                self.allocator.free(self.data);
            }
        }

        pub fn add(self: *@This(), item: T) !void {
            // Use self.allocator for internal allocations
        }
    };
}
```

**Functions returning allocated memory - document ownership:**

```zig
/// Caller owns returned memory.
pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    // ...
    return try allocator.dupe(u8, content);
}

// Caller must free:
const content = try readFile(allocator, "file.txt");
defer allocator.free(content);
```

## Common Patterns

### Wrapping Allocators (Sub-Allocators)

```zig
// Arena on top of debug allocator
var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();

var arena = std.heap.ArenaAllocator.init(gpa.allocator());
defer arena.deinit();

const allocator = arena.allocator();
```

### Temporary Allocations in Loops

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

for (items) |item| {
    // Reset arena each iteration for automatic cleanup
    _ = arena.reset(.retain_capacity);
    const temp = try arena.allocator().alloc(u8, item.size);
    // temp is automatically "freed" on next reset
}
```

### Sentinel-Terminated Allocations

```zig
// Allocate with null terminator
const str = try allocator.allocSentinel(u8, len, 0);
defer allocator.free(str);

// Duplicate with sentinel
const c_str = try allocator.dupeZ(u8, "hello");  // [:0]u8
defer allocator.free(c_str);
```

## Error Handling

Always handle `error.OutOfMemory`:

```zig
// Option 1: Propagate
fn process(allocator: Allocator) !void {
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
}

// Option 2: Handle gracefully
fn process(allocator: Allocator) void {
    const data = allocator.alloc(u8, size) catch {
        log.err("Out of memory", .{});
        return;
    };
    defer allocator.free(data);
}
```

## Initialization (0.15.x)

Use `.init` not `.{}`:

```zig
// WRONG - deprecated
var gpa: std.heap.DebugAllocator(.{}) = .{};

// CORRECT
var gpa: std.heap.DebugAllocator(.{}) = .init;
```

## Debugging Memory Issues

### Leak Detection

```zig
test "check for leaks" {
    // std.testing.allocator automatically reports leaks
    var list: std.ArrayList(u32) = .empty;
    try list.append(std.testing.allocator, 42);
    // Missing: list.deinit(std.testing.allocator);
    // Test will FAIL with leak report
}
```

### DebugAllocator in Main

```zig
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = gpa.deinit();
        if (check == .leak) @panic("memory leak");
    }
    try run(gpa.allocator());
}
```

## Implementing Custom Allocators

Allocators implement `std.mem.Allocator.VTable`:

```zig
const MyAllocator = struct {
    // State fields here

    pub fn allocator(self: *MyAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *MyAllocator = @ptrCast(@alignCast(ctx));
        _ = ra;  // return address for stack traces
        // Return aligned pointer or null
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        // Return true if resize succeeded in-place
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        // Return new pointer (may move) or null if can't remap
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        // Free memory
    }
};
```

**Validation wrapper** - for testing allocators:
```zig
var my_alloc = MyAllocator.init();
var validated = std.mem.validationWrap(my_alloc.allocator());
const allocator = validated.allocator();  // Adds safety checks
```
