# Zig Patterns Reference

Comprehensive patterns for writing idiomatic Zig code. This reference contains best practices extracted from the Zig standard library (0.15.x) and established community idioms.

## Table of Contents

### Quick Patterns
- [Memory and Allocators](#memory-and-allocators)
- [File I/O (0.15.x)](#file-io-015x)
- [HTTP Client (0.15.x)](#http-client-015x)
- [JSON](#json)
- [Testing](#testing)
- [Build System Patterns](#build-system-patterns)

### Idiomatic Code Patterns
- [I. Syntax Patterns](#i-syntax-patterns)
  - [Closure Pattern](#closure-pattern)
  - [Context Pattern](#context-pattern)
  - [Pointer Size Type Selection](#pointer-size-type-selection)
  - [Default Arguments via Options Struct](#default-arguments-via-options-struct)
  - [Side Computation Block](#side-computation-block)
  - [Destructuring Assignment](#destructuring-assignment)
  - [Hashed Mappings Storage](#hashed-mappings-storage)
  - [Module-wide Overridable Options](#module-wide-overridable-options)
  - [Self-referential Type Alias](#self-referential-type-alias)
  - [Variable Struct Initialization](#variable-struct-initialization)
  - [Return Value Struct Initialization](#return-value-struct-initialization)
- [II. Polymorphism Patterns](#ii-polymorphism-patterns)
  - [Duck Typing](#duck-typing)
  - [Generic Type](#generic-type)
  - [Generic Function](#generic-function)
  - [Basic Type Formatting](#basic-type-formatting)
  - [Custom Type Formatting](#custom-type-formatting)
  - [Custom Type JSON](#custom-type-json)
  - [Compile-time Implementation Switching](#compile-time-implementation-switching)
  - [Dynamic Dispatch (Fat Pointer)](#dynamic-dispatch-fat-pointer)
  - [Static Dispatch (Tagged Union)](#static-dispatch-tagged-union-with-inline-switch)
- [III. Safety Patterns](#iii-safety-patterns)
  - [Diagnostics](#diagnostics)
  - [Index-Based Data Structures](#index-based-data-structures)
  - [Error Payloads](#error-payloads)
  - [Compile-time Assertion](#compile-time-assertion)
  - [Granular Error Handling](#granular-error-handling)
  - [Deallocated Memory Poisoning](#deallocated-memory-poisoning)
  - [Deferred Resource Deinitialization](#deferred-resource-deinitialization)
  - [Error-deferred Resource Deinitialization](#error-deferred-resource-deinitialization)
  - [Compile-time Unreachable Switch Prong](#compile-time-unreachable-switch-prong)
  - [Compile-time Error Absence Guarantee](#compile-time-error-absence-guarantee)
  - [Reserve-First Exception Safety](#reserve-first-exception-safety)
- [IV. Performance Patterns](#iv-performance-patterns)
  - [Big Struct Constant Pointer Passing](#big-struct-constant-pointer-passing)
  - [Big Struct Constant Pointer Capturing](#big-struct-constant-pointer-capturing)
- [V. Workarounds](#v-workarounds)
  - [Inlined Loop with Runtime Logic](#inlined-loop-with-runtime-logic)

---

## Quick Patterns

### Memory and Allocators

> **Naming convention:** Name allocators by their memory contract (`gpa`, `arena`, `scratch`) not generically as `allocator`. See [Allocator Naming Conventions](std-allocators.md#allocator-naming-conventions) for details.

#### Allocator Setup
```zig
// Debug allocator (development - detects leaks, use-after-free)
// Note: GeneralPurposeAllocator is now an alias for DebugAllocator
var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Arena (batch operations - free all at once)
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

// Fixed buffer (no heap, stack allocation)
var buffer: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
const allocator = fba.allocator();
```

#### Allocation Patterns
```zig
// Single item
const ptr = try allocator.create(T);
defer allocator.destroy(ptr);

// Slice
const slice = try allocator.alloc(u8, 100);
defer allocator.free(slice);

// Duplicate
const copy = try allocator.dupe(u8, source);
defer allocator.free(copy);
```

### File I/O (0.15.x)

#### Reading Files
```zig
const file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var reader = file.reader(&buf);
const r = &reader.interface;

// Line by line (takeDelimiter returns null at EOF)
while (try r.takeDelimiter('\n')) |line| {
    // process line (doesn't include '\n')
}
```

#### Writing Files
```zig
const file = try std.fs.cwd().createFile("out.txt", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var writer = file.writer(&buf);
const w = &writer.interface;

try w.print("Hello {s}\n", .{"world"});
try w.flush();
```

#### Stdout/Stderr
```zig
var stdout_buf: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
const stdout = &stdout_writer.interface;

try stdout.print("Output\n", .{});
try stdout.flush();
```

### HTTP Client (0.15.x)

See [std-http.md](std-http.md) for full documentation including server, WebSocket, and compression.

```zig
// Quick fetch (simple requests)
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

var body_buf: [65536]u8 = undefined;
var body_writer: std.Io.Writer = .fixed(&body_buf);

const result = try client.fetch(.{
    .location = .{ .url = "https://api.example.com/data" },
    .response_writer = &body_writer,
});

const body = body_writer.buffered();
```

```zig
// Full control (for headers, streaming, redirects)
var req = try client.request(.GET, try std.Uri.parse(url), .{
    .extra_headers = &.{
        .{ .name = "Authorization", .value = "Bearer token" },
    },
});
defer req.deinit();

try req.sendBodiless();

var redirect_buf: [8192]u8 = undefined;
var response = try req.receiveHead(&redirect_buf);

var reader_buf: [4096]u8 = undefined;
const body_reader = response.reader(&reader_buf);
// read body...
```

### JSON

#### Parsing
```zig
const Config = struct {
    name: []const u8,
    count: u32,
};

const parsed = try std.json.parseFromSlice(Config, allocator, json_bytes, .{});
defer parsed.deinit();
const config = parsed.value;
```

#### Stringifying
```zig
const json = try std.json.stringifyAlloc(allocator, config, .{});
defer allocator.free(json);
```

### Testing

```zig
const std = @import("std");
const testing = std.testing;

test "example" {
    try testing.expectEqual(4, 2 + 2);
    try testing.expectEqualStrings("hello", "hello");
    try testing.expect(condition);
}

test "with allocator" {
    var list: std.ArrayListUnmanaged(u32) = .empty;
    defer list.deinit(testing.allocator);
    try list.append(testing.allocator, 42);
}
```

### Build System Patterns

#### Basic Executable
```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the app").dependOn(&run.step);
}
```

#### Adding Dependencies
```zig
const dep = b.dependency("pkg_name", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pkg_name", dep.module("module_name"));
```

#### Library + Executable
```zig
const lib_mod = b.createModule(.{
    .root_source_file = b.path("src/lib.zig"),
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mylib", .module = lib_mod }},
    }),
});
```

#### Tests
```zig
const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const run_tests = b.addRunArtifact(tests);
b.step("test", "Run tests").dependOn(&run_tests.step);
```

---

## Idiomatic Code Patterns

These patterns are extracted from the Zig standard library (0.15.x) and represent established idioms for writing clean, efficient Zig code.

### I. Syntax Patterns

#### Closure Pattern
Use a local struct with `@fieldParentPtr` to capture context when you need a function pointer with associated state.

```zig
pub fn spawnWg(pool: *Pool, wait_group: *WaitGroup, comptime func: anytype, args: anytype) void {
    wait_group.start();

    const Args = @TypeOf(args);
    const Closure = struct {
        arguments: Args,
        pool: *Pool,
        runnable: Runnable = .{ .runFn = runFn },
        wait_group: *WaitGroup,

        fn runFn(runnable: *Runnable, _: ?usize) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
            @call(.auto, func, closure.arguments);
            closure.wait_group.finish();
            closure.pool.allocator.destroy(closure);
        }
    };

    const closure = pool.allocator.create(Closure) catch return;
    closure.* = .{
        .arguments = args,
        .pool = pool,
        .wait_group = wait_group,
    };
    pool.run_queue.prepend(&closure.runnable.node);
}
```

**When to use:** Thread pools, callbacks, event handlers—anywhere you need a function pointer but also need captured state.

#### Context Pattern
Parameterize a generic type with *behavior*, not just data types. A context struct bundles related operations that the generic type calls at runtime, allowing callers to customize how the type operates.

**The principle:** When a generic type needs to perform operations that depend on how the caller wants to use it (comparison, hashing, ordering, formatting), accept a `Context` type parameter. The context provides methods the generic calls internally.

```zig
// DEFINING a generic type that accepts a context:
pub fn SortedSet(comptime T: type, comptime Context: type) type {
    return struct {
        items: std.ArrayList(T),
        ctx: Context,  // Store the context instance

        pub fn contains(self: *@This(), value: T) bool {
            for (self.items.items) |item| {
                // Call the context's comparison method
                if (self.ctx.eql(item, value)) return true;
            }
            return false;
        }

        pub fn insert(self: *@This(), value: T) !void {
            if (!self.contains(value)) {
                // Use context's lessThan for sorted insertion
                const pos = for (self.items.items, 0..) |item, i| {
                    if (self.ctx.lessThan(value, item)) break i;
                } else self.items.items.len;
                try self.items.insert(pos, value);
            }
        }
    };
}
```

**Stateless context** - when behavior doesn't need configuration, `self` is unused:
```zig
// Case-sensitive string comparison (no state needed)
const CaseSensitive = struct {
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
    pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

var set: SortedSet([]const u8, CaseSensitive) = .{
    .items = .empty,
    .ctx = .{},  // No state to initialize
};
```

**Stateful context** - when behavior needs configuration:
```zig
// Floating-point comparison with configurable tolerance
const ApproxEql = struct {
    tolerance: f64,

    pub fn eql(self: @This(), a: f64, b: f64) bool {
        return @abs(a - b) <= self.tolerance;
    }
    pub fn lessThan(self: @This(), a: f64, b: f64) bool {
        return a < b - self.tolerance;
    }
};

var precise: SortedSet(f64, ApproxEql) = .{
    .items = .empty,
    .ctx = .{ .tolerance = 0.0001 },
};
var loose: SortedSet(f64, ApproxEql) = .{
    .items = .empty,
    .ctx = .{ .tolerance = 1.0 },
};
```

**Standard library example** - HashMap requires `hash` and `eql`:
```zig
// Case-insensitive string keys
const CaseInsensitive = struct {
    pub fn hash(_: @This(), key: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        for (key) |c| h.update(&.{std.ascii.toLower(c)});
        return h.final();
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

const Headers = std.HashMap([]const u8, []const u8, CaseInsensitive, 80);
```

**When to use:**
- Your generic type needs customizable comparison, hashing, ordering, or formatting
- Different use cases need different behavior for the same data type
- You want compile-time polymorphism without runtime vtable overhead

**Design guidelines:**
- Document which methods the context must provide
- Use `_: @This()` for stateless contexts (optimizer eliminates the parameter)
- Store `ctx: Context` as a field when the generic needs to call methods later
- Consider providing a default context type for common cases

#### Pointer Size Type Selection
Use `switch (@sizeOf(usize))` to select platform-appropriate types at compile time.

```zig
pub const Auxv = switch (@sizeOf(usize)) {
    4 => Elf32_auxv_t,
    8 => Elf64_auxv_t,
    else => @compileError("expected pointer size of 32 or 64"),
};

pub const Ehdr = switch (@sizeOf(usize)) {
    4 => Elf32_Ehdr,
    8 => Elf64_Ehdr,
    else => @compileError("expected pointer size of 32 or 64"),
};
```

**When to use:** FFI with C libraries, ELF parsing, or any code that needs different types for 32-bit vs 64-bit platforms.

#### Default Arguments via Options Struct
Use a struct with default field values to simulate optional/default function arguments.

```zig
pub const Options = struct {
    /// The alignment of the memory pool items. Use `null` for natural alignment.
    alignment: ?Alignment = null,
    /// If `true`, the memory pool can allocate additional items after initial setup.
    growable: bool = true,
};

pub fn MemoryPoolExtra(comptime Item: type, comptime pool_options: Options) type {
    return struct {
        // Implementation uses pool_options.alignment, pool_options.growable
    };
}

// Usage:
const Pool1 = MemoryPoolExtra(u32, .{});  // All defaults
const Pool2 = MemoryPoolExtra(u32, .{ .growable = false });  // Override one
```

**When to use:** Functions with many optional parameters, builder patterns, configuration structs.

#### Side Computation Block
Use labeled blocks to perform intermediate calculations with a clear scope boundary.

```zig
// Calculate length needed for resulting joined path buffer.
const total_len = blk: {
    var sum: usize = paths[first_path_index].len;
    var prev_path = paths[first_path_index];
    var i: usize = first_path_index + 1;
    while (i < paths.len) : (i += 1) {
        const this_path = paths[i];
        if (this_path.len == 0) continue;
        sum += this_path.len;
        prev_path = this_path;
    }
    if (zero) sum += 1;
    break :blk sum;
};
```

**When to use:** Complex expressions that need temporary variables, when you want to limit variable scope.

#### Destructuring Assignment
Unpack tuples, arrays, and vectors into individual variables.

```zig
// From function returning tuple
fn divmod(n: u32, d: u32) struct { u32, u32 } {
    return .{ n / d, n % d };
}
const div, const mod = divmod(10, 3);

// Array destructuring with swizzle
fn swizzleRgbaToBgra(rgba: [4]u8) [4]u8 {
    const r, const g, const b, const a = rgba;
    return .{ b, g, r, a };
}

// Ignore elements with _
const first, _, const third, _ = some_array;

// Works with comptime
comptime const x, const y = .{ 1, 2 };
```

**When to use:** Multiple return values, array element extraction, SIMD vector unpacking.

#### Hashed Mappings Storage
Use multiple `AutoArrayHashMapUnmanaged` fields when storing complex interned data.

```zig
// From llvm/Builder.zig - demonstrating the pattern of parallel maps for interned data
string_map: std.AutoArrayHashMapUnmanaged(void, void),
string_indices: std.ArrayListUnmanaged(u32),
string_bytes: std.ArrayListUnmanaged(u8),

types: std.AutoArrayHashMapUnmanaged(String, Type),
type_map: std.AutoArrayHashMapUnmanaged(void, void),
type_items: std.ArrayListUnmanaged(Type.Item),
type_extra: std.ArrayListUnmanaged(u32),

attributes: std.AutoArrayHashMapUnmanaged(Attribute.Storage, void),
attributes_map: std.AutoArrayHashMapUnmanaged(void, void),
attributes_indices: std.ArrayListUnmanaged(u32),
```

**When to use:** Interning strings/symbols, IR builders, AST storage, deduplication with stable indices.

#### Module-wide Overridable Options
Use `@import("root")` to allow users to customize library behavior.

```zig
const root = @import("root");

/// Stdlib-wide options that can be overridden by the root file.
pub const options: Options = if (@hasDecl(root, "std_options")) root.std_options else .{};

pub const Options = struct {
    enable_segfault_handler: bool = debug.default_enable_segfault_handler,
    log_level: log.Level = log.default_level,
    // ...
};

// In user's main.zig:
pub const std_options: std.Options = .{
    .log_level = .debug,
};
```

**When to use:** Library configuration, logging levels, feature flags that users can customize.

#### Self-referential Type Alias
Use `const Self = @This();` inside a struct for self-reference.

```zig
// GOOD: Simple alias at top of struct
pub fn EnumSet(comptime E: type) type {
    return struct {
        const Self = @This();

        pub const Indexer = EnumIndexer(E);
        pub const Key = Indexer.Key;

        bits: BitSet,

        pub fn contains(self: Self, key: Key) bool {
            return self.bits.isSet(Indexer.indexOf(key));
        }
    };
}

// ANTI-PATTERN: Unnecessary Self usage when @This() would be clearer
pub const PaxIterator = struct {
    size: usize,
    reader: *std.Io.Reader,

    const Self = @This();  // Unnecessary - only used once

    // Better: just use @This() inline or the actual type name
};
```

**When to use:** Generic types where `Self` is used multiple times. Avoid in non-generic structs where it adds no value.

#### Variable Struct Initialization
Use `pub const init: T = .{...};` for default/initial values.

```zig
// GOOD: Named constant with explicit type
pub const Recursive = struct {
    mutex: Mutex,
    thread_id: std.Thread.Id,
    lock_count: usize,

    pub const init: Recursive = .{
        .mutex = .{},
        .thread_id = invalid_thread_id,
        .lock_count = 0,
    };
};

// Usage:
var rec: Recursive = Recursive.init;

// ANTI-PATTERN: Using T{} syntax (older style)
var mutex = Mutex{};  // Works but .{} is preferred
```

**When to use:** Types with meaningful default states, especially when zero-initialization isn't appropriate.

#### Return Value Struct Initialization
Return `.{...}` directly instead of creating named locals.

```zig
// GOOD: Direct return
pub fn initContext(allocator: Allocator, ctx: Context) Self {
    return .{
        .unmanaged = .empty,
        .allocator = allocator,
        .ctx = ctx,
    };
}

// ANTI-PATTERN: Unnecessary named local
pub fn getEntryAdapted(self: Self, key: anytype, ctx: anytype) ?Entry {
    const index = self.getIndexAdapted(key, ctx) orelse return null;
    const slice = self.entries.slice();
    return Entry{  // Could just be: return .{
        .key_ptr = &slice.items(.key)[index],
        .value_ptr = &slice.items(.value)[index],
    };
}
```

**When to use:** Simple struct construction in return statements. Use named locals only when the struct is complex or needs multiple statements to build.

### II. Polymorphism Patterns

#### Duck Typing
Use `anytype` parameters with compile-time interface checking.

```zig
pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,  // Duck typed: must have lessThan behavior
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    std.sort.block(T, items, context, lessThanFn);
}

// Works with any type that can be passed to lessThanFn
sort(i32, &items, {}, struct {
    fn lt(_: void, a: i32, b: i32) bool { return a < b; }
}.lt);
```

**When to use:** Callbacks, comparators, iterators—when the exact type doesn't matter, only its capabilities.

#### Generic Type
Return a parameterized struct from a function.

```zig
pub fn HashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u64,
) type {
    return struct {
        unmanaged: Unmanaged,
        allocator: Allocator,
        ctx: Context,

        pub const Unmanaged = HashMapUnmanaged(K, V, Context, max_load_percentage);
        pub const Entry = Unmanaged.Entry;
        // ...
    };
}

const MyMap = HashMap([]const u8, u32, std.hash_map.StringContext, 80);
```

**When to use:** Data structures, containers, any reusable component parameterized by types.

#### Generic Function
Use `comptime T: type` for functions operating on any type.

```zig
pub fn allEqual(comptime T: type, slice: []const T, scalar: T) bool {
    for (slice) |item| {
        if (item != scalar) return false;
    }
    return true;
}

// Usage:
const all_zero = std.mem.allEqual(u8, buffer, 0);
const all_space = std.mem.allEqual(u8, text, ' ');
```

**When to use:** Utility functions, algorithms that work on any type with certain properties.

#### Basic Type Formatting
Built-in format specifiers for `std.fmt.print`.

```zig
// x/X: hexadecimal
try w.print("{x}", .{255});       // "ff"
try w.print("{X}", .{255});       // "FF"

// s: strings and slices
try w.print("{s}", .{"hello"});   // "hello"

// t: tag names for enums/unions/errors
try w.print("{t}", .{MyEnum.foo}); // "foo"

// d: decimal, b: binary, o: octal
try w.print("{d} {b} {o}", .{10, 10, 10}); // "10 1010 12"

// e: scientific notation
try w.print("{e}", .{1234.5});    // "1.2345e+03"

// c: ASCII character, u: UTF-8 codepoint
try w.print("{c} {u}", .{65, 0x1F600}); // "A 😀"

// D: duration (nanoseconds)
try w.print("{D}", .{3_661_001_000_000}); // "1h1m1.001s"

// B/Bi: bytes in SI/IEC units
try w.print("{B} {Bi}", .{1536, 1536}); // "1.536kB 1.5KiB"
```

#### Custom Type Formatting
Implement `format` method for custom types (0.15.x signature).

```zig
const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: ?[]const u8 = null,
    build: ?[]const u8 = null,

    // 0.15.x signature: takes *std.io.Writer, returns Writer.Error!void
    pub fn format(self: Version, w: *std.io.Writer) std.io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.pre) |pre| try w.print("-{s}", .{pre});
        if (self.build) |build| try w.print("+{s}", .{build});
    }
};

// Usage with {f} specifier (required in 0.15.x)
try stdout.print("{f}", .{version});
```

**When to use:** Any type that needs custom string representation.

#### Custom Type JSON
Implement `jsonParse`, `jsonParseFromValue`, and `jsonStringify` for JSON support.

```zig
pub fn ArrayHashMap(comptime T: type) type {
    return struct {
        map: std.StringArrayHashMapUnmanaged(T) = .empty,

        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: ParseOptions,
        ) !@This() {
            var map: std.StringArrayHashMapUnmanaged(T) = .empty;
            errdefer map.deinit(allocator);

            if (.object_begin != try source.next()) return error.UnexpectedToken;
            while (true) {
                const token = try source.nextAlloc(allocator, options.allocate.?);
                switch (token) {
                    inline .string, .allocated_string => |k| {
                        const gop = try map.getOrPut(allocator, k);
                        gop.value_ptr.* = try innerParse(T, allocator, source, options);
                    },
                    .object_end => break,
                    else => unreachable,
                }
            }
            return .{ .map = map };
        }

        pub fn jsonStringify(self: @This(), w: anytype) !void {
            // ... serialize to JSON
        }
    };
}
```

**When to use:** Types with non-trivial JSON representation, maps with dynamic keys.

#### Compile-time Implementation Switching
Select platform-specific implementations at compile time.

```zig
const native_os = builtin.os.tag;
const use_libc = builtin.link_libc;

/// A libc-compatible API layer.
pub const system = if (use_libc)
    std.c
else switch (native_os) {
    .linux => linux,
    .plan9 => std.os.plan9,
    else => struct {
        pub const ucontext_t = void;
        pub const pid_t = void;
        pub const fd_t = void;
    },
};

pub const AF = system.AF;
pub const pid_t = system.pid_t;
```

**When to use:** Cross-platform code, OS-specific syscall wrappers, CPU architecture selection.

#### Dynamic Dispatch (Fat Pointer)
Use `ptr: *anyopaque` with `vtable: *const VTable` for runtime polymorphism.

```zig
const Allocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        alloc: *const fn (*anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8,
        resize: *const fn (*anyopaque, []u8, Alignment, new_len: usize, ret_addr: usize) bool,
        free: *const fn (*anyopaque, []u8, Alignment, ret_addr: usize) void,
    };

    pub fn alloc(self: Allocator, len: usize, alignment: Alignment) ?[*]u8 {
        return self.vtable.alloc(self.ptr, len, alignment, @returnAddress());
    }
};
```

**When to use:** Allocators, I/O interfaces, plugin systems—when you need runtime polymorphism and can't use comptime generics.

#### Static Dispatch (Tagged Union with inline switch)
Use tagged unions with `inline else` for compile-time generated dispatch.

```zig
const U = union(enum) {
    a: u32,
    b: f32,
};

fn getNum(u: U) u32 {
    switch (u) {
        // Generates separate code paths at compile time
        inline else => |num, tag| {
            if (tag == .b) {
                return @intFromFloat(num);
            }
            return num;
        },
    }
}

// More common: uniform operations on all variants
const AnySlice = union(enum) {
    a: []const u8,
    b: []const u16,
    c: []const u32,
};

fn len(any: AnySlice) usize {
    return switch (any) {
        inline else => |slice| slice.len,
    };
}
```

**When to use:** Variants with similar operations, type-safe enums, when you want compiler-generated dispatch instead of vtables.

### III. Safety Patterns

#### Diagnostics
Use an optional diagnostics struct to provide detailed error information.

```zig
pub const ParseOptions = struct {
    string: ?[]const u8 = null,
    dynamic_linker: ?[]const u8 = null,

    /// If provided, the function will populate information about parsing failures.
    diagnostics: ?*Diagnostics = null,

    pub const Diagnostics = struct {
        arch: ?Target.Cpu.Arch = null,
        os_name: ?[]const u8 = null,
        os_tag: ?Target.Os.Tag = null,
        abi: ?Target.Abi = null,
        cpu_name: ?[]const u8 = null,
        unknown_feature_name: ?[]const u8 = null,
    };
};

pub fn parse(args: ParseOptions) !Query {
    var dummy_diags: ParseOptions.Diagnostics = undefined;
    const diags = args.diagnostics orelse &dummy_diags;

    // On error, populate diags before returning
    diags.arch = detected_arch;
    return error.UnknownArchitecture;
}
```

**When to use:** Parser functions, validators, anywhere you want to report multiple issues or provide context with errors.

#### Index-Based Data Structures

Zig enums are strongly-typed integer constants. By default, the compiler chooses a minimal backing type, but you can specify one explicitly with `enum(u32)`. Adding a trailing `_` field makes the enum *non-exhaustive*: any value of the backing type becomes valid, not just named members. This means `enum(u32) { _ }` is effectively "u32, but a distinct type"—the compiler won't implicitly convert between different enum types even if they share the same backing integer.

Use this to create distinct index types that the type system can distinguish. This pattern prevents bugs from accidentally mixing up indices into different arrays or confusing semantically different integers.

```zig
/// Index into `sections` array.
const SectionIndex = enum(u32) {
    _,
};

/// Index into `functions` array.
const FunctionIndex = enum(u32) {
    _,
};

/// Index into `symbols` array.
const SymbolIndex = enum(u32) {
    _,
};
```

These types are incompatible with each other, even though they share the same backing integer:

```zig
fn getSection(index: SectionIndex) *Section { ... }
fn getFunction(index: FunctionIndex) *Function { ... }

// COMPILE ERROR: type mismatch
const section = getSection(func_index);  // func_index is FunctionIndex, not SectionIndex

// CORRECT: types match
const section = getSection(section_index);
```

**Converting to/from the underlying integer:**
```zig
const index: SectionIndex = @enumFromInt(42);
const raw: u32 = @intFromEnum(index);
```

**Optional variants** - use a sentinel value for null representation:
```zig
/// Index into `functions`, or null.
const OptionalFunctionIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(self: OptionalFunctionIndex) ?FunctionIndex {
        if (self == .none) return null;
        return @enumFromInt(@intFromEnum(self));
    }
};

/// Non-optional index with conversion helper.
const FunctionIndex = enum(u32) {
    _,

    pub fn toOptional(self: FunctionIndex) OptionalFunctionIndex {
        const result: OptionalFunctionIndex = @enumFromInt(@intFromEnum(self));
        std.debug.assert(result != .none);
        return result;
    }
};
```

**With sentinel states** - multiple special values:
```zig
const Parent = enum(u8) {
    /// Unallocated storage.
    unused = std.math.maxInt(u8) - 1,
    /// Indicates root node.
    none = std.math.maxInt(u8),
    /// Index into `node_storage`.
    _,

    fn unwrap(self: @This()) ?NodeIndex {
        return switch (self) {
            .unused, .none => null,
            _ => @enumFromInt(@intFromEnum(self)),
        };
    }
};
```

**When to use:**
- Any index into an array/slice where you have multiple arrays
- Handles, IDs, or tokens that should not be interchangeable
- Any integer with semantic meaning that could be confused with other integers
- Linkers, compilers, parsers, and any code managing multiple parallel data structures

**Benefits:**
- Compile-time detection of index mix-ups (otherwise painful runtime debugging)
- Self-documenting code - the type name explains what the integer represents
- Zero runtime cost - same representation as the underlying integer

**Why Indices Over Pointers**

Index-based data structures offer significant advantages over pointer-based ones:

- **Memory efficiency**: 4 bytes (u32) vs 8 bytes (pointer) per reference—50% savings
- **Cache locality**: Contiguous array storage means better cache utilization
- **Fewer allocations**: Append to array vs individual `create()` calls
- **Instant bulk frees**: One `deinit()` vs recursive traversal
- **Natural serialization**: Indices are relocatable; can `@memcpy` entire arrays

**Tree and Graph Modeling**

Use the "collective noun first" idiom: define the container (`Tree`) before the index type (`Node`). The index is just an integer—actual data lives in the container.

```zig
/// A tree structure using index-based nodes.
pub const Tree = struct {
    /// Node storage - the actual data lives here.
    nodes: std.MultiArrayList(Node.Data),
    /// Root is always index 0.
    root: Node = .root,

    pub const Node = enum(u32) {
        root = 0,
        _,

        /// Data stored for each node.
        pub const Data = struct {
            tag: Tag,
            parent: OptionalNode,
            children: Children,
            // ... other fields
        };

        pub const Tag = enum { leaf, branch };

        pub const Children = struct {
            start: Node,
            len: u32,
        };
    };

    pub const OptionalNode = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(self: OptionalNode) ?Node {
            if (self == .none) return null;
            return @enumFromInt(@intFromEnum(self));
        }
    };

    /// Access node data by index.
    pub fn get(self: *const Tree, node: Node) Node.Data {
        return self.nodes.get(@intFromEnum(node));
    }

    /// Get mutable pointer to node data.
    pub fn getPtr(self: *Tree, node: Node) *Node.Data {
        const slice = self.nodes.slice();
        return &slice.items(.tag)[@intFromEnum(node)];
    }
};
```

This pattern mirrors `std.zig.Ast` from the Zig standard library:
- `Ast.Node.Index` is `enum(u32) { _, }` (lines 3020-3035 in Ast.zig)
- Node data accessed via `ast.nodes.get(index)`
- Optional indices use `maxInt` sentinel: `Ast.Node.OptionalIndex`

**Index Ranges**

For variable-length children, use the `Index.Range` pattern from `Zoir.zig`:

```zig
pub const Node = enum(u32) {
    _,

    /// A range of contiguous node indices.
    pub const Range = struct {
        start: Node,
        len: u32,

        /// Get the node at offset `i` within this range.
        pub fn at(r: Range, i: u32) Node {
            std.debug.assert(i < r.len);
            return @enumFromInt(@intFromEnum(r.start) + i);
        }

        /// Iterate over all nodes in range.
        pub fn slice(r: Range) []const Node {
            // Note: requires nodes stored contiguously
            return @ptrCast(@as([*]const u32, @ptrFromInt(@intFromEnum(r.start)))[0..r.len]);
        }
    };
};

// Usage in tree traversal:
fn visitChildren(tree: *const Tree, node: Tree.Node) void {
    const data = tree.get(node);
    var i: u32 = 0;
    while (i < data.children.len) : (i += 1) {
        const child = data.children.at(i);
        visit(tree, child);
    }
}
```

**Freelist for Deletion**

When individual node deletion is needed, maintain a freelist stack:

```zig
pub const NodePool = struct {
    nodes: std.ArrayListUnmanaged(Node.Data),
    /// Head of freelist, or none if no free slots.
    free_head: OptionalNode = .none,

    pub fn alloc(self: *NodePool) !Node {
        if (self.free_head.unwrap()) |free| {
            // Reuse freed slot
            self.free_head = self.nodes.items[@intFromEnum(free)].next_free;
            return free;
        }
        // Allocate new slot
        const index: Node = @enumFromInt(self.nodes.items.len);
        try self.nodes.append(undefined);
        return index;
    }

    pub fn free(self: *NodePool, node: Node) void {
        // Push onto freelist
        self.nodes.items[@intFromEnum(node)].next_free = self.free_head;
        self.free_head = node.toOptional();
    }
};
```

**Stdlib examples of these patterns:**
| Pattern | File | Description |
|---------|------|-------------|
| `Node.Index` | `Ast.zig:3020-3035` | Basic index type |
| `Node.OptionalIndex` | `Ast.zig:3038-3050` | Optional with maxInt sentinel |
| `Index.Range` | `Zoir.zig:151-159` | Contiguous index ranges |
| Multiple sentinels | `Progress.zig:157-171` | `unused`, `none` states |
| Accessor pattern | `Ast.zig:88-106` | `ast.nodes.get(index)` |

#### Error Payloads
Use a tagged union to attach context to errors.

```zig
pub const Diagnostics = struct {
    errors: std.ArrayListUnmanaged(Error) = .empty,
    entries: usize = 0,

    pub const Error = union(enum) {
        unable_to_create_sym_link: struct {
            code: anyerror,
            file_name: []const u8,
            link_name: []const u8,
        },
        unable_to_create_file: struct {
            code: anyerror,
            file_name: []const u8,
        },
        unsupported_file_type: struct {
            file_name: []const u8,
            file_type: Header.Kind,
        },
    };
};

// Usage: collect errors instead of failing immediately
fn extract(d: *Diagnostics, ...) !void {
    file.create(...) catch |err| {
        try d.errors.append(allocator, .{
            .unable_to_create_file = .{ .code = err, .file_name = name },
        });
        return;
    };
}
```

**When to use:** Batch processing with multiple possible failures, when you need more context than error codes provide.

#### Compile-time Assertion
Use `comptime { assert(...); }` for compile-time invariant checking.

```zig
const upper_bound_msg_len = 1 + node_storage_buffer_len * @sizeOf(Node.Storage) +
    node_storage_buffer_len * @sizeOf(Node.OptionalIndex);
comptime assert(upper_bound_msg_len <= 4096);

// Also works with @compileError for custom messages
comptime {
    if (@sizeOf(MyStruct) > 64) {
        @compileError("MyStruct too large for cache line");
    }
}
```

**When to use:** Size constraints, alignment requirements, invariants that must hold at compile time.

#### Granular Error Handling
Use exhaustive switch on specific error values for precise handling.

```zig
fn oom(err: anytype) noreturn {
    switch (err) {
        error.OutOfMemory => @panic("out of memory"),
    }
}

// Or handle different errors differently:
file.open() catch |err| switch (err) {
    error.FileNotFound => return createDefault(),
    error.AccessDenied => return error.PermissionDenied,
    error.IsDir => return error.InvalidPath,
    else => return err,
};
```

**When to use:** When different errors need different handling, converting between error sets.

#### Deallocated Memory Poisoning
Set `self.* = undefined;` after deallocation to catch use-after-free.

```zig
pub fn deinit(self: *Self, gpa: Allocator) void {
    gpa.free(self.allocatedSlice());
    self.* = undefined;  // Poison the memory
}
```

**When to use:** In `deinit` functions to help catch use-after-free bugs in debug builds. Zig writes `0xaa` bytes to undefined memory in debug mode.

#### Deferred Resource Deinitialization
Use `defer` for unconditional cleanup.

```zig
fn doWork(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();  // Always runs, even on error

    // ... work with locked resource
}
```

**When to use:** Mutexes, file handles, any resource that must be released regardless of control flow.

#### Error-deferred Resource Deinitialization
Use `errdefer` for cleanup only on error paths.

```zig
pub fn put(self: *BufMap, key: []const u8, value: []const u8) !void {
    const value_copy = try self.copy(value);
    errdefer self.free(value_copy);  // Only runs if we return an error

    const get_or_put = try self.hash_map.getOrPut(key);
    // ... if this succeeds, value_copy ownership is transferred
}
```

**When to use:** Partial initialization, multi-step construction where early steps need rollback on later failures.

#### Compile-time Unreachable Switch Prong
Use `else => comptime unreachable` for exhaustive compile-time switches.

```zig
fn shl(a: anytype, shift_amt: anytype) @TypeOf(a) {
    const casted_shift_amt = switch (@typeInfo(@TypeOf(shift_amt))) {
        .int => @as(Log2Int(@TypeOf(a)), @intCast(shift_amt)),
        .comptime_int => @as(Log2Int(@TypeOf(a)), shift_amt),
        else => comptime unreachable,  // Only int types allowed
    };
    return a << casted_shift_amt;
}
```

**When to use:** Generic functions where only certain type categories are valid.

#### Compile-time Error Absence Guarantee
Use `errdefer comptime unreachable;` to assert no errors can occur after a point.

```zig
fn spawnChild(self: *Child) !void {
    const pid_result = posix.fork();
    if (pid_result == 0) {
        // Child process
        posix.execvpeZ(...);
        forkChildErrReport(err_pipe[1], err);
    }

    // Parent process - after fork, we must not error
    errdefer comptime unreachable;  // Compile error if any code below can error

    posix.close(err_pipe[1]);
    self.err_pipe = err_pipe[0];
    // ... all operations here must be infallible
}
```

**When to use:** After point-of-no-return operations like fork(), to ensure subsequent code is truly infallible.

#### Reserve-First Exception Safety
When mutating data structures that can fail (e.g., growing arrays or hash maps), separate the fallible reservation phase from the infallible mutation phase. This ensures strong exception safety: if an error occurs, the object remains unchanged.

**The pattern:**
1. **Reserve** - Call `ensureUnusedCapacity` for all containers that will grow. These calls can fail but don't mutate data.
2. **Mark boundary** - Use `errdefer comptime unreachable;` to assert no errors can occur after this point.
3. **Mutate** - Use `*AssumeCapacity` methods which cannot fail.

```zig
// WRONG - exception safety bug
pub fn internString(state: *State, gpa: Allocator, bytes: []const u8) !String {
    // BUG: getOrPut inserts a slot, then ensureUnusedCapacity can fail,
    // leaving an uninitialized entry in the hash table
    const gop = try state.string_table.getOrPut(gpa, bytes);
    if (gop.found_existing) return gop.key_ptr.*;

    try state.string_bytes.ensureUnusedCapacity(gpa, bytes.len + 1);  // Can fail!
    // ... rest of function
}

// CORRECT - reserve first, then mutate
pub fn internString(state: *State, gpa: Allocator, bytes: []const u8) !String {
    // Phase 1: Reserve capacity (all fallible operations)
    try state.string_table.ensureUnusedCapacityContext(gpa, 1, .{
        .bytes = state.string_bytes.items,
    });
    try state.string_bytes.ensureUnusedCapacity(gpa, bytes.len + 1);

    errdefer comptime unreachable;  // Phase 2: No errors after this point

    // Phase 3: Mutate using AssumeCapacity methods (infallible)
    const gop = state.string_table.getOrPutAssumeCapacityAdapted(bytes, .{
        .bytes = state.string_bytes.items,
    });
    if (gop.found_existing) return gop.key_ptr.*;

    const new_off: String = @enumFromInt(state.string_bytes.items.len);
    state.string_bytes.appendSliceAssumeCapacity(bytes);
    state.string_bytes.appendAssumeCapacity(0);
    gop.key_ptr.* = new_off;

    return new_off;
}
```

**Real-world example from HashMap.grow:**
```zig
fn grow(self: *Self, allocator: Allocator, new_capacity: Size, ctx: Context) Allocator.Error!void {
    var map: Self = .{};
    try map.allocate(allocator, new_cap);    // Can fail
    errdefer comptime unreachable;           // No errors after this point

    map.initMetadatas();                     // Infallible
    map.available = @truncate((new_cap * max_load_percentage) / 100);

    // Copy all entries using putAssumeCapacityNoClobberContext (infallible)
    if (self.size != 0) {
        for (self.metadata.?[0..old_capacity], self.keys()[0..old_capacity], self.values()[0..old_capacity]) |m, k, v| {
            if (!m.isUsed()) continue;
            map.putAssumeCapacityNoClobberContext(k, v, ctx);  // Infallible
        }
    }
    // ... swap and cleanup
}
```

**Exception safety levels:**
- **Strong** (reserve-first): Object unchanged if error occurs
- **Basic**: Object left in valid but different state
- **None**: Object may be corrupted

**When to use:**
- Any function that must insert into multiple containers
- Growing data structures where partial mutation would corrupt state
- String/symbol interning (hash table + byte array)
- Any operation where failure after partial mutation leaves invalid state

**Key insight:** `ensureUnusedCapacity` is magic—it contains all the failure modes but changes nothing. Reservation failures are safe to retry; partial mutations are not.

### IV. Performance Patterns

#### Big Struct Constant Pointer Passing
Pass large structs by `*const` to avoid copies.

```zig
// GOOD: Pass by const pointer for large structs
pub fn format(uri: *const Uri, writer: *Writer) Writer.Error!void {
    return writeToStream(uri, writer, .all);
}

pub fn writeToStream(uri: *const Uri, writer: *Writer, flags: Format.Flags) Writer.Error!void {
    if (flags.scheme) {
        try writer.print("{s}:", .{uri.scheme});
    }
    // ...
}
```

**When to use:** Structs larger than ~2 pointers that are read-only. The calling convention may copy small structs in registers anyway.

#### Big Struct Constant Pointer Capturing
Use `*const` in closures to avoid copying large captured values.

```zig
if (m.resolved_target) |*target| {  // *target is a pointer, not a copy
    if (!target.query.isNative()) {
        try zig_args.appendSlice(&.{
            "-target", try target.query.zigTriple(b.allocator),
            "-mcpu",   try target.query.serializeCpuAlloc(b.allocator),
        });
    }
}
```

**When to use:** When capturing large structs in closures or iterating with payload capture on large items.

### V. Workarounds

#### Inlined Loop with Runtime Logic
When `inline for` doesn't work (e.g., modifying slice during iteration), use `comptime var` with `inline while`.

```zig
fn deinterlace(interlaced: anytype, comptime vec_count: usize) [vec_count]@Vector(...) {
    const vec_len = vectorLength(@TypeOf(interlaced)) / vec_count;
    const Child = std.meta.Child(@TypeOf(interlaced));

    var out: [vec_count]@Vector(vec_len, Child) = undefined;

    // inline for doesn't work here due to runtime slice mutation
    comptime var i: usize = 0;
    inline while (i < out.len) : (i += 1) {
        const indices = comptime iota(i32, vec_len) *
            @as(@Vector(vec_len, i32), @splat(@intCast(vec_count))) +
            @as(@Vector(vec_len, i32), @splat(@intCast(i)));
        out[i] = @shuffle(Child, interlaced, undefined, indices);
    }

    return out;
}
```

**When to use:** When you need compile-time loop unrolling but `inline for` fails due to control flow or mutation requirements.
