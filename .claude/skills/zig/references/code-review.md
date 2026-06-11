# Zig Code Review Reference (0.15.x)

Systematic code review checklist organized by detection confidence level. Work through sections in order: ALWAYS FLAG → FLAG WITH CONTEXT → SUGGEST.

## Quick Reference Card

### Scan Order

1. **ALWAYS FLAG** - Mechanical checks, objectively wrong
2. **FLAG WITH CONTEXT** - Requires understanding function semantics
3. **SUGGEST** - Style suggestions for review feedback

### Most Common Issues

| Detect | Issue | Risk | Fix |
|--------|-------|------|-----|
| `writer(&buf)` without `.flush()` | Missing flush | Data loss | Add `try w.flush()` |
| `.{}` on container type | Wrong init | Compile error | Use `.empty` or `.init` |
| `root_source_file` in build.zig | Old build API | Compile error | Use `root_module = b.createModule(...)` |
| `"{}"` with custom format method | Old format spec | Compile error | Use `"{f}"` (see [1.4](#14-api-signature-changes)) |
| `getOrPut` then `ensure*` | Exception safety | Orphan entries | Reserve first, mutate with `*AssumeCapacity` |

### Guaranteed Bug Patterns

| Detect | Risk | Verify |
|--------|------|--------|
| `@intCast(val)` without bounds check | Runtime panic | No `std.math.cast` or prior validation |
| `.?` unwrap | Runtime panic | Not guarded by `if` or `orelse` |
| `catch unreachable` on alloc/create | Runtime panic | Allocation can fail |
| `return &local_var` | Dangling pointer | Returns address of stack variable |
| `&packed_struct.field` | Undefined behavior | Pointer to packed struct field |
| `DebugAllocator` without `defer.*deinit()` | No leak detection | Missing cleanup |
| build.zig without `standardTargetOptions` | No cross-compile | Missing standard options |

### Context-Dependent Checks

| Detect | When to Flag | Section |
|--------|--------------|---------|
| `anyerror` return type | Library public API | [2.7](#27-error-handling-selection) |
| Loop allocations with non-freeing allocator | Arena without reset | [2.8](#28-loop-resource-management) |
| `[*]T` pointer type | Pure Zig code (not FFI) | [2.10](#210-pointer-type-selection) |
| Regular `for` on `@typeInfo` fields | Need comptime iteration | [2.11](#211-comptime-propagation) |
| `ArenaAllocator` without `.reset()` | Long-running service | [2.9](#29-allocator-misuse-patterns) |
| Multi-step alloc without errdefer | Partial construction | [2.12](#212-missing-errdefer-for-partial-construction) |
| Alloc without `defer free` + error returns | Resource leak | [2.13](#213-missing-defer-for-allocation-cleanup) |

### Style Quick Checks

| Detect | Suggestion | Section |
|--------|------------|---------|
| Imports not grouped | std → third-party → local | [3.8](#38-import-organization) |
| Global allocator variable | Accept as parameter | [3.9](#39-allocator-design) |
| `allocPrint` for bounded strings | Use `bufPrint` with stack buffer | [3.10](#310-stack-vs-heap-allocation) |
| Runtime constant lookup | Comptime lookup table | [3.11](#311-comptime-optimization) |
| `expectEqual` with strings/slices | Use `expectEqualStrings`/`expectEqualSlices` | [3.14](#314-testing-best-practices) |
| `len`, `pos`, `n` for numeric vars | Use `_count`/`_index`/`_size`/`_offset` suffixes | [3.17](#317-numeric-variable-naming-indexcountoffsetsize) |

---

## Review Workflow

1. **Run `zig fmt`** — catches whitespace, trailing commas, basic style
2. **Scan for ALWAYS FLAG patterns** — removed features, old APIs, guaranteed bugs
3. **Check safety** — defer/errdefer usage, reserve-first pattern, memory poisoning
4. **Check context-dependent issues** — allocator naming, error handling, loop resources
5. **Review style** — naming conventions, struct init, imports, documentation
6. **Verify build.zig** — `standardTargetOptions`, `standardOptimizeOption`, `root_module`

---

## Table of Contents

- [1. ALWAYS FLAG (100% Confidence)](#1-always-flag-100-confidence)
- [2. FLAG WITH CONTEXT (High Confidence)](#2-flag-with-context-high-confidence)
- [3. SUGGEST (Advisory)](#3-suggest-advisory) (incl. [3.17 Numeric Naming](#317-numeric-variable-naming-indexcountoffsetsize))

---

## 1. ALWAYS FLAG (100% Confidence)

Objective errors that cause compilation failures or guaranteed runtime bugs.

### 1.1 Removed Language Features

| Detect | Replacement | Risk |
|--------|-------------|------|
| `usingnamespace` | Explicit re-exports | Compile error |
| `async`/`await` keywords | Removed entirely | Compile error |
| `@fence()` | Stronger atomic orderings or RMW operations | Compile error |
| `@setCold(true/false)` | `@branchHint(.cold)` | Compile error |
| `@setAlignStack()` | `callconv(.withStackAlign(...))` | Compile error |
| `std.BoundedArray` | `ArrayList.initBuffer()` | Compile error |

**Wrong:**
```zig
pub usingnamespace @import("other.zig");
```

**Right:**
```zig
const other = @import("other.zig");
pub const foo = other.foo;
```

**Wrong:**
```zig
fn coldPath() void {
    @setCold(true);
}
```

**Right:**
```zig
fn coldPath() void {
    @branchHint(.cold);  // Must be first statement
}
```

**Wrong:**
```zig
var stack = try std.BoundedArray(i32, 8).fromSlice(initial);
```

**Right:**
```zig
var buffer: [8]i32 = undefined;
var stack = std.ArrayList(i32).initBuffer(&buffer);
try stack.appendSliceBounded(initial);
```

### 1.2 Changed Syntax (0.14+)

| Detect | New | Risk |
|--------|-----|------|
| `@export(foo, opts)` | `@export(&foo, opts)` | Compile error |
| `.Int`, `.Struct` in @typeInfo | `.int`, `.@"struct"` | Compile error |
| `.One`, `.Slice`, `.Many` | `.one`, `.slice`, `.many` | Compile error |
| `sentinel = &val` | `sentinel_ptr = &val` | Compile error |
| Inline asm clobbers `"rcx"` | `.{ .rcx = true }` | Compile error |
| `callconv(.C)` | `callconv(.c)` | Compile error |
| `callconv(.Stdcall)` | `callconv(.x86_stdcall)` | Compile error |

**Wrong:**
```zig
@export(foo, .{ .name = "bar" });
```

**Right:**
```zig
@export(&foo, .{ .name = "bar" });
```

**Wrong:**
```zig
switch (@typeInfo(T)) {
    .Int => {},
    .Struct => {},
    .Pointer => |p| if (p.size == .One) {},
}
```

**Right:**
```zig
switch (@typeInfo(T)) {
    .int => {},
    .@"struct" => {},
    .pointer => |p| if (p.size == .one) {},
}
```

**Wrong:**
```zig
asm volatile ("syscall"
    : [ret] "={rax}" (-> usize),
    : [number] "{rax}" (number),
    : "rcx", "r11"
);
```

**Right:**
```zig
asm volatile ("syscall"
    : [ret] "={rax}" (-> usize),
    : [number] "{rax}" (number),
    : .{ .rcx = true, .r11 = true }
);
```

**Wrong:**
```zig
export fn foo() callconv(.C) void {}
```

**Right:**
```zig
export fn foo() callconv(.c) void {}
```

### 1.3 Removed/Renamed APIs

| Detect | New | Risk |
|--------|-----|------|
| `root_source_file` | `root_module = b.createModule(...)` | Compile error |
| `exe.addModule(...)` | `exe.root_module.addImport(...)` | Compile error |
| `GeneralPurposeAllocator` | `DebugAllocator` | Alias works |
| `std.mem.page_size` | `std.heap.pageSize()` | Compile error |
| `BufferedWriter` | Buffer provided to `.writer(&buf)` | Compile error |
| `CountingWriter` | `std.Io.Writer.Discarding` | Compile error |
| `GenericWriter/Reader` | `std.Io.Writer/Reader` | Deprecated |
| `std.ArrayList` (managed) | `std.array_list.Managed` | Eventually removed |
| `std.ArrayListUnmanaged` | `std.ArrayList` | Unmanaged is now the default |
| `std.fifo.LinearFifo` | `std.Io.Reader`/`Writer` patterns | Removed |
| `std.RingBuffer` | `std.Io.Reader`/`Writer` patterns | Removed |
| `std.ChildProcess` | `std.process.Child` | Compile error |
| `*std.build.Builder` | `*std.Build` | Compile error |
| `.{ .path = "..." }` | `b.path("...")` | Compile error |

**Wrong:**
```zig
b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

**Right:**
```zig
b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**Wrong:**
```zig
exe.addModule("helper", helper_mod);
```

**Right:**
```zig
exe.root_module.addImport("helper", helper_mod);
```

### 1.4 API Signature Changes

*Note: For `"{}"` → `"{f}"`, this is a migration check. For new code forgetting `.flush()`, see also [2.2](#22-missing-flush-after-io-write).*

| Detect | New | Risk |
|--------|-----|------|
| `stdout.print(fmt, args)` without flush | Must call `stdout.flush()` | Data loss |
| `format(self, fmt, opts, writer)` | `format(self, *std.Io.Writer)` | Compile error |
| `"{}"` for format methods | `"{f}"` | Compile error |
| `child.collectOutput(&stdout, ...)` | `child.collectOutput(allocator, &stdout, ...)` | Compile error |

**Wrong:**
```zig
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello\n", .{});
```

**Right:**
```zig
var buf: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&buf);
const stdout = &stdout_writer.interface;
try stdout.print("Hello\n", .{});
try stdout.flush();  // Required
```

**Wrong:**
```zig
pub fn format(
    self: @This(),
    comptime fmt: []const u8,
    opts: std.fmt.FormatOptions,
    writer: anytype,
) !void { ... }
```

**Right:**
```zig
pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void { ... }
```

**Wrong:**
```zig
std.debug.print("{}", .{myFormattableType});
```

**Right:**
```zig
std.debug.print("{f}", .{myFormattableType});
```

### 1.5 Container Initialization

| Detect | Right | Risk |
|--------|-------|------|
| `var list: ArrayList(T) = .{}` | `.empty` | Deprecated |
| `var gpa: DebugAllocator(.{}) = .{}` | `.init` | Deprecated |
| `var map: HashMapUnmanaged(...) = .{}` | `.empty` | Deprecated |
| `list.append(42)` (old managed API) | `try list.append(allocator, 42)` | Compile error |

**Wrong:**
```zig
var list: std.ArrayList(u32) = .{};
var gpa: std.heap.DebugAllocator(.{}) = .{};
```

**Right:**
```zig
var list: std.ArrayList(u32) = .empty;
var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
var gpa: std.heap.DebugAllocator(.{}) = .init;
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
```

**ArrayList is now unmanaged by default** — allocator is passed per method call, not stored:

**Wrong (old managed API):**
```zig
var list = std.ArrayList(u32).init(allocator);
list.append(42);
```

**Right (unmanaged, allocator per call):**
```zig
var list: std.ArrayList(u32) = .empty;
try list.append(allocator, 42);
try list.appendSlice(allocator, &.{ 1, 2, 3 });
defer list.deinit(allocator);
```

### 1.6 Guaranteed Runtime Bugs

#### 1.6.1 Unchecked @intCast

| Detect | `@intCast` without prior bounds check or `std.math.cast` |
|--------|----------------------------------------------------------|
| Risk | Runtime panic on overflow |

**Wrong:**
```zig
fn convert(big: u64) u8 {
    return @intCast(big);  // Panics if big > 255
}
```

**Right:**
```zig
fn convert(big: u64) ?u8 {
    return std.math.cast(u8, big);
}
```

**Verify:** Search for `@intCast` calls, check for prior validation.

#### 1.6.2 Unguarded Optional Unwrap

| Detect | `.?` not preceded by `if` check or `orelse` |
|--------|---------------------------------------------|
| Risk | Runtime panic if null |

**Wrong:**
```zig
fn getName(user: ?*User) []const u8 {
    return user.?.name;
}
```

**Right:**
```zig
fn getName(user: ?*User) []const u8 {
    return if (user) |u| u.name else "anonymous";
}
```

**Verify:** Search for `.?` usage, confirm null case is handled.

#### 1.6.3 Catch Unreachable on Allocation

| Detect | `catch unreachable` after `alloc`/`create` calls |
|--------|--------------------------------------------------|
| Risk | Runtime panic on OOM |

**Wrong:**
```zig
fn createBuffer(allocator: Allocator) *Buffer {
    return allocator.create(Buffer) catch unreachable;
}
```

**Right:**
```zig
fn createBuffer(allocator: Allocator) !*Buffer {
    return try allocator.create(Buffer);
}
```

**Verify:** Search for `catch unreachable`, check if operation can fail.

#### 1.6.4 Returning Stack Pointer

| Detect | `return &` of local variable |
|--------|------------------------------|
| Risk | Dangling pointer |

**Wrong:**
```zig
fn getBuffer() *[256]u8 {
    var buf: [256]u8 = undefined;
    return &buf;
}
```

**Right:**
```zig
fn fillBuffer(buf: *[256]u8) void { ... }

// OR return by value if small
fn getBuffer() [256]u8 {
    var buf: [256]u8 = undefined;
    return buf;
}
```

**Verify:** Search for `return &`, check if variable is local.

#### 1.6.5 Self-Referential Struct Copy

| Detect | Struct with self-pointer field returned by value |
|--------|--------------------------------------------------|
| Risk | Dangling internal pointer |

**Wrong:**
```zig
const Node = struct {
    self_ptr: *Node,

    fn init() Node {
        var node: Node = undefined;
        node.self_ptr = &node;
        return node;  // self_ptr now dangling
    }
};
```

**Right:**
```zig
fn init(allocator: Allocator) !*Node {
    const node = try allocator.create(Node);
    node.self_ptr = node;
    return node;
}
```

**Verify:** Check structs with pointer fields pointing to self.

#### 1.6.6 Division by Runtime Variable

| Detect | `/` or `%` with non-constant divisor |
|--------|--------------------------------------|
| Risk | Runtime panic if zero |

**Wrong:**
```zig
fn average(sum: u32, count: u32) u32 {
    return sum / count;
}
```

**Right:**
```zig
fn average(sum: u32, count: u32) ?u32 {
    if (count == 0) return null;
    return sum / count;
}
```

**Verify:** Search for division, check if divisor is validated.

#### 1.6.7 Inactive Union Field Access

| Detect | Direct union field access without tag check |
|--------|---------------------------------------------|
| Risk | Undefined behavior |

**Wrong:**
```zig
fn getInt(v: Value) i64 {
    return v.int;  // UB if v is not .int
}
```

**Right:**
```zig
fn getInt(v: Value) ?i64 {
    return switch (v) {
        .int => |i| i,
        else => null,
    };
}
```

**Verify:** Check union field access, ensure tag is verified first.

#### 1.6.8 Unchecked @enumFromInt

| Detect | `@enumFromInt` without range validation |
|--------|----------------------------------------|
| Risk | Runtime panic if invalid |

**Wrong:**
```zig
fn parseColor(byte: u8) Color {
    return @enumFromInt(byte);
}
```

**Right:**
```zig
fn parseColor(byte: u8) ?Color {
    return std.meta.intToEnum(Color, byte) catch null;
}
```

**Verify:** Search for `@enumFromInt`, check for validation.

### 1.7 Memory Safety Violations

#### 1.7.1 Missing DebugAllocator Deinit

| Detect | `DebugAllocator` without `defer.*deinit()` |
|--------|-------------------------------------------|
| Risk | No leak detection in debug builds |

**Wrong:**
```zig
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    // Missing gpa.deinit()
}
```

**Right:**
```zig
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
}
```

**Verify:** Search for `DebugAllocator`, check for `defer.*deinit()`.

#### 1.7.2 @ptrCast Size Mismatch

| Detect | `@ptrCast` between types of different sizes |
|--------|---------------------------------------------|
| Risk | Memory corruption |

**Wrong:**
```zig
fn dangerous(ptr: *u32) *u64 {
    return @ptrCast(ptr);  // Reading u64 from u32 space
}
```

**Right:**
```zig
fn reinterpret(ptr: *u32) *[4]u8 {
    return @ptrCast(ptr);  // Same size
}
```

**Verify:** Check `@ptrCast` source and target sizes match.

#### 1.7.3 Packed Struct Field Pointer

| Detect | `&packed_struct.field` |
|--------|------------------------|
| Risk | Unaligned access UB |

**Wrong:**
```zig
const Packet = packed struct { flags: u4, len: u12, data: u16 };

fn getLen(pkt: *Packet) *u12 {
    return &pkt.len;  // Unaligned pointer
}
```

**Right:**
```zig
fn getLen(pkt: *const Packet) u12 {
    return pkt.len;  // Copy value
}
```

**Verify:** Search for `&` on packed struct field access.

#### 1.7.4 Disabled Runtime Safety

| Detect | `@setRuntimeSafety(false)` |
|--------|---------------------------|
| Risk | All safety checks removed |

**Wrong:**
```zig
fn fastPath(data: []u8) void {
    @setRuntimeSafety(false);
}
```

**Right:**
```zig
fn fastPath(data: []u8) void {
    // Use ReleaseFast build mode for controlled optimization
}
```

**Verify:** Search for `@setRuntimeSafety(false)`.

### 1.8 Build System Anti-patterns

| Detect | Problem | Risk |
|--------|---------|------|
| Missing `b.standardTargetOptions()` | No cross-compilation | Build inflexibility |
| Missing `b.standardOptimizeOption()` | No release builds | Build inflexibility |

**Wrong:**
```zig
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            // Missing target and optimize
        }),
    });
}
```

**Right:**
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
}
```

**Verify:** Check build.zig for `standardTargetOptions` and `standardOptimizeOption`.

---

## 2. FLAG WITH CONTEXT (High Confidence)

Genuine issues when preconditions are satisfied.

### 2.1 Exception Safety Bugs

| Detect | `getOrPut` followed by `ensureCapacity` in same function |
|--------|----------------------------------------------------------|
| Risk | Orphan entries on allocation failure |

**Preconditions:**
- [ ] Function inserts into multiple growable containers
- [ ] Mutation precedes reservation

**If met:** Reorder to reserve-first pattern.

**Wrong:**
```zig
const gop = try state.table.getOrPut(gpa, key);
try state.bytes.ensureUnusedCapacity(gpa, len);  // Failure leaves orphan
```

**Right:**
```zig
try state.table.ensureUnusedCapacityContext(gpa, 1, ctx);
try state.bytes.ensureUnusedCapacity(gpa, len);

errdefer comptime unreachable;  // Assert no errors after this

const gop = state.table.getOrPutAssumeCapacity(key);
state.bytes.appendSliceAssumeCapacity(data);
```

**Verify:** Search for `getOrPut` followed by `ensure` in same scope.

### 2.2 Missing flush() After I/O Write

*Note: For migrating old `stdout.print()` calls, see also [1.4](#14-api-signature-changes). This section covers new code that forgets `.flush()`.*

| Detect | `writer(&buf)` or `.writer(&` without subsequent `.flush()` |
|--------|-------------------------------------------------------------|
| Risk | Data loss (buffered data not written) |

**Preconditions:**
- [ ] Code uses 0.15.x `std.Io.Writer` API
- [ ] Writer scope ends without flush

**If met:** Add `try writer.interface.flush()` before scope exit.

**Wrong:**
```zig
var buf: [4096]u8 = undefined;
var writer = file.writer(&buf);
try writer.interface.print("data", .{});
// Missing flush
```

**Right:**
```zig
var buf: [4096]u8 = undefined;
var writer = file.writer(&buf);
try writer.interface.print("data", .{});
try writer.interface.flush();
```

**Verify:** Check for `writer(&` without corresponding `.flush()`.

### 2.3 Allocator Pointer Comparison

| Detect | `alloc1.ptr == alloc2.ptr` or similar |
|--------|---------------------------------------|
| Risk | Undefined for stateless allocators |

**Preconditions:**
- [ ] Code compares `Allocator` or `Random` interface `ptr` fields

**If met:** Remove comparison; `ptr` is undefined for `page_allocator`, `c_allocator`.

### 2.4 Generic Allocator Naming

| Detect | Allocator parameter named just `allocator` |
|--------|-------------------------------------------|
| Risk | Hidden memory ownership contract |

**Preconditions:**
- [ ] Function has allocator parameter
- [ ] Ownership semantics unclear from name

**If met:** Rename by memory contract:

| Name | Contract | Return Data? | Who Frees? |
|------|----------|--------------|------------|
| `gpa` | Long-lived | Yes | Caller |
| `arena` | Request-scoped | Yes | Arena owner |
| `scratch` | Function-private | Never | Function |

**Wrong:**
```zig
fn process(allocator: Allocator) ![]u8 {
    const temp = try allocator.alloc(u8, 100);
    const result = try allocator.dupe(u8, temp);
    allocator.free(temp);
    return result;
}
```

**Right:**
```zig
fn handleRequest(
    arena: Allocator,   // Response lifetime
    gpa: Allocator,     // Long-lived cache
    scratch: Allocator, // Function temporaries
) !Response { ... }
```

### 2.5 Use-After-Free Potential

| Detect | `deinit` method without `self.* = undefined;` |
|--------|-----------------------------------------------|
| Risk | Use-after-free not caught in debug |

**Preconditions:**
- [ ] Type has `deinit` method that frees memory
- [ ] No memory poisoning after deallocation

**If met:** Add `self.* = undefined;` at end of deinit.

**Wrong:**
```zig
pub fn deinit(self: *Self, gpa: Allocator) void {
    gpa.free(self.allocatedSlice());
}
```

**Right:**
```zig
pub fn deinit(self: *Self, gpa: Allocator) void {
    gpa.free(self.allocatedSlice());
    self.* = undefined;
}
```

**Verify:** Check `deinit` methods for memory poisoning.

### 2.6 Type-Unsafe Index Usage

| Detect | Multiple `u32`/`usize` indices for different arrays |
|--------|-----------------------------------------------------|
| Risk | Index type confusion |

**Preconditions:**
- [ ] Code manages parallel arrays
- [ ] Same integer type used for different index spaces

**If met:** Use distinct enum types for indices.

**Wrong:**
```zig
fn getSection(index: u32) *Section { ... }
fn getSymbol(index: u32) *Symbol { ... }
```

**Right:**
```zig
const SectionIndex = enum(u32) { _ };
const SymbolIndex = enum(u32) { _ };

fn getSection(index: SectionIndex) *Section { ... }
fn getSymbol(index: SymbolIndex) *Symbol { ... }
```

See also [3.17](#317-numeric-variable-naming-indexcountoffsetsize) for naming conventions that complement type safety.

### 2.7 Error Handling Selection

| Detect | `anyerror` return in public API, or blind `try` propagation |
|--------|-------------------------------------------------------------|
| Risk | Callers cannot handle errors specifically |

**Preconditions:**
- [ ] Library public function returns `anyerror`
- [ ] OR: Function uses `try` where specific handling needed

**If met:** Define specific error set; use `catch` with `switch` for meaningful errors.

**Wrong:**
```zig
pub fn parse(input: []const u8) anyerror!Ast { ... }
```

**Right:**
```zig
pub const ParseError = error{ UnexpectedToken, InvalidSyntax, OutOfMemory };
pub fn parse(input: []const u8) ParseError!Ast { ... }
```

### 2.8 Loop Resource Management

| Detect | Allocations inside loop body |
|--------|------------------------------|
| Risk | Memory accumulation or premature free |

**Preconditions:**
- [ ] Loop body allocates memory
- [ ] Allocator does not actually free (e.g., `ArenaAllocator`)
- [ ] OR: Results accumulate across iterations where `defer` would free too early

**If met:** Use arena with per-iteration reset, or manage lifetime explicitly.

Zig's `defer` is **block-scoped** — it runs at the end of each loop iteration, not at function exit. This means `defer free` inside a loop works correctly for per-iteration cleanup. The real risks are:

**Risk 1: Non-freeing allocator makes `defer free` a no-op:**

**Wrong:**
```zig
// ArenaAllocator.free() is a no-op — memory accumulates
for (items) |item| {
    const data = try arena.alloc(u8, item.size);
    defer arena.free(data);  // Does nothing!
    try process(data);
}
```

**Right:**
```zig
// Use a scratch arena with per-iteration reset
var scratch = std.heap.ArenaAllocator.init(backing_allocator);
defer scratch.deinit();

for (items) |item| {
    defer _ = scratch.reset(.retain_capacity);
    const data = try scratch.allocator().alloc(u8, item.size);
    try process(data);
}
```

**Risk 2: Accumulating results across iterations where `defer` would free too early:**

**Wrong:**
```zig
var results: std.ArrayList([]u8) = .empty;
for (items) |item| {
    const data = try allocator.dupe(u8, item.name);
    defer allocator.free(data);  // Frees before we're done with it!
    try results.append(allocator, data);
}
```

**Right:**
```zig
var results: std.ArrayList([]u8) = .empty;
for (items) |item| {
    const data = try allocator.dupe(u8, item.name);
    errdefer allocator.free(data);  // Only free on error
    try results.append(allocator, data);
}
```

### 2.9 Allocator Misuse Patterns

#### FixedBufferAllocator Non-LIFO Free

| Detect | Free in non-LIFO order with FixedBufferAllocator |
|--------|--------------------------------------------------|
| Risk | Unexpected allocation failures |

**Preconditions:**
- [ ] Using `FixedBufferAllocator`
- [ ] Freeing allocations out of order

**If met:** Use LIFO order or switch to ArenaAllocator.

#### ArenaAllocator Without Reset

| Detect | `ArenaAllocator` in loop without `.reset()` |
|--------|---------------------------------------------|
| Risk | Unbounded memory growth |

**Preconditions:**
- [ ] Long-running service/loop
- [ ] Arena never reset

**If met:** Add `defer _ = arena.reset(.retain_capacity);` in loop.

**Wrong:**
```zig
while (true) {
    const request = try readRequest(arena.allocator());
    try processRequest(request);
    // Missing reset
}
```

**Right:**
```zig
while (true) {
    defer _ = arena.reset(.retain_capacity);
    const request = try readRequest(arena.allocator());
    try processRequest(request);
}
```

### 2.10 Pointer Type Selection

| Detect | `[*]T` in pure Zig code (not C FFI) |
|--------|-------------------------------------|
| Risk | No bounds checking |

**Preconditions:**
- [ ] Code uses `[*]T` pointer
- [ ] Not at C FFI boundary

**If met:** Use slice `[]T` instead.

**Wrong:**
```zig
fn process(data: [*]u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        data[i] = transform(data[i]);
    }
}
```

**Right:**
```zig
fn process(data: []u8) void {
    for (data) |*byte| {
        byte.* = transform(byte.*);
    }
}
```

### 2.11 Comptime Propagation

| Detect | Regular `for` iterating `@typeInfo` fields |
|--------|-------------------------------------------|
| Risk | Comptime values lost at runtime boundary |

**Preconditions:**
- [ ] Iterating comptime-known collection
- [ ] Using field names or other comptime data

**If met:** Use `inline for` or mark function `inline`.

**Wrong:**
```zig
fn printFields(comptime T: type) void {
    for (@typeInfo(T).@"struct".fields) |field| {
        std.debug.print("{s}\n", .{field.name});  // Error
    }
}
```

**Right:**
```zig
fn printFields(comptime T: type) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        std.debug.print("{s}\n", .{field.name});
    }
}
```

### 2.12 Missing errdefer for Partial Construction

| Detect | Multi-step allocation without errdefer cleanup |
|--------|------------------------------------------------|
| Risk | Resource leak on failure |

**Preconditions:**
- [ ] Function performs multiple fallible allocations
- [ ] Earlier allocations not cleaned up if later ones fail

**If met:** Add `errdefer` after each allocation that must be cleaned up on failure.

**Wrong:**
```zig
pub fn init(gpa: Allocator) !Self {
    const data = try gpa.alloc(u8, 100);
    const more = try gpa.alloc(u8, 200);  // data leaks if this fails
    return .{ .data = data, .more = more };
}
```

**Right:**
```zig
pub fn init(gpa: Allocator) !Self {
    const data = try gpa.alloc(u8, 100);
    errdefer gpa.free(data);
    const more = try gpa.alloc(u8, 200);
    return .{ .data = data, .more = more };
}
```

**Verify:** Search for functions with multiple `try allocator.alloc`/`create` calls. Check that each allocation (except the last) has a corresponding `errdefer`.

### 2.13 Missing defer for Allocation Cleanup

| Detect | Allocation without corresponding `defer free` in function with error/early-return paths |
|--------|----------------------------------------------------------------------------------------|
| Risk | Memory leak on non-error paths |

**Preconditions:**
- [ ] Function allocates memory for internal use (not returned to caller)
- [ ] Function has `try`, `return`, or other early-exit paths after allocation
- [ ] No `defer` to free the allocation

**If met:** Add `defer allocator.free(...)` immediately after allocation.

This is distinct from `errdefer` ([2.12](#212-missing-errdefer-for-partial-construction)) — `errdefer` only fires on error. This covers unconditional cleanup of internally-used allocations.

**Wrong:**
```zig
fn process(gpa: Allocator, input: []const u8) !Result {
    const temp = try gpa.alloc(u8, input.len);
    const parsed = try parse(input);  // temp leaks if this fails
    // ... use temp ...
    gpa.free(temp);
    return parsed;
}
```

**Right:**
```zig
fn process(gpa: Allocator, input: []const u8) !Result {
    const temp = try gpa.alloc(u8, input.len);
    defer gpa.free(temp);
    const parsed = try parse(input);  // temp freed by defer
    // ... use temp ...
    return parsed;
}
```

**Verify:** Search for `alloc(` not followed by `defer.*free` in functions with `try` or early returns.

---

## 3. SUGGEST (Advisory)

Style and idiom suggestions.

### 3.1 Unnecessary Self Alias

| Detect | `const Self = @This();` used only once |
|--------|----------------------------------------|
| Risk | None (style) |

**Wrong:**
```zig
pub const Iterator = struct {
    const Self = @This();  // Used once
    pub fn next(self: *Self) ?Entry { ... }
};
```

**Right:**
```zig
pub const Iterator = struct {
    pub fn next(self: *@This()) ?Entry { ... }
};
```

### 3.2 Unnecessary Named Return Variable

| Detect | Variable assigned then immediately returned |
|--------|---------------------------------------------|
| Risk | None (style) |

**Wrong:**
```zig
const result = Entry{ .key = k, .value = v };
return result;
```

**Right:**
```zig
return .{ .key = k, .value = v };
```

### 3.3 Old Struct Init Syntax

| Detect | `TypeName{}` instead of `.{}` with type annotation |
|--------|---------------------------------------------------|
| Risk | None (style) |

**Wrong:**
```zig
var mutex = Mutex{};
```

**Right:**
```zig
var mutex: Mutex = .{};
```

### 3.4 Redundant Naming

| Detect | Names like `JsonValue`, `DataManager`, `miscUtils` |
|--------|---------------------------------------------------|
| Risk | None (style) |

**Wrong:**
```zig
const JsonValue = struct { ... };
const JsonParser = struct { ... };
```

**Right:**
```zig
const json = struct {
    const Value = struct { ... };
    const Parser = struct { ... };
};
```

### 3.5 Large Struct Passed by Value

| Detect | Struct >16 bytes passed as `self: T` (read-only) |
|--------|--------------------------------------------------|
| Risk | Unnecessary copy |

**Wrong:**
```zig
pub fn format(uri: Uri, writer: *Writer) Writer.Error!void { ... }
```

**Right:**
```zig
pub fn format(uri: *const Uri, writer: *Writer) Writer.Error!void { ... }
```

Also applies to payload captures:
```zig
// Wrong: if (m.target) |target| { ... }
// Right: if (m.target) |*target| { ... }
```

### 3.6 errdefer Error Capture for Debugging

| Detect | Complex init/setup function without `errdefer` diagnostics |
|--------|-----------------------------------------------------------|
| Risk | Hard to diagnose failures |

In complex initialization functions, use `errdefer |err|` to capture and log the error for debugging context:

**Basic:**
```zig
pub fn init(gpa: Allocator, path: []const u8) !Self {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| return err;
    // No context if later steps fail
    ...
}
```

**Better:**
```zig
pub fn init(gpa: Allocator, path: []const u8) !Self {
    errdefer |err| {
        std.log.err("init failed for '{s}': {}", .{ path, err });
    }
    const file = try std.fs.cwd().openFile(path, .{});
    errdefer file.close();
    ...
}
```

### 3.7 Style Guide Violations (not caught by zig fmt)

| Element | Convention | Example |
|---------|-----------|---------|
| Types | `TitleCase` | `XmlParser`, `HashMap` |
| Namespace structs | `snake_case` | `std.json`, `std.mem` |
| Functions | `camelCase` | `readU32Be`, `parseJson` |
| Type-returning functions | `TitleCase` | `ArrayList`, `HashMap` |
| Variables/constants | `snake_case` | `const_name`, `file_path` |

**Acronyms:** Treat as regular words (`XmlParser` not `XMLParser`).

**File naming:**
- Type file: `TitleCase.zig` (e.g., `ArrayList.zig`)
- Namespace file: `snake_case.zig` (e.g., `mem.zig`)

### 3.8 Import Organization

| Detect | Imports not grouped or inconsistently ordered |
|--------|-----------------------------------------------|
| Risk | None (style) |

**Right:**
```zig
const std = @import("std");
const builtin = @import("builtin");

const json = @import("json");  // Third-party

const MyModule = @import("my_module.zig");  // Local
```

### 3.9 Allocator Design

| Detect | Global allocator variable |
|--------|--------------------------|
| Risk | Untestable code |

**Wrong:**
```zig
var global_allocator: Allocator = undefined;
pub fn process() ![]u8 {
    return global_allocator.alloc(u8, 100);
}
```

**Right:**
```zig
pub fn process(allocator: Allocator) ![]u8 {
    return allocator.alloc(u8, 100);
}
```

### 3.10 Stack vs Heap Allocation

| Detect | Heap allocation for comptime-known bounded size |
|--------|------------------------------------------------|
| Risk | Unnecessary allocation |

**Wrong:**
```zig
fn formatVersion(allocator: Allocator, major: u32, minor: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}.{d}", .{ major, minor });
}
```

**Right (caller provides buffer):**
```zig
fn formatVersion(buf: []u8, major: u32, minor: u32) []u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor }) catch unreachable;
}

// Call site — buffer outlives the returned slice
var buf: [32]u8 = undefined;
const version = formatVersion(&buf, 1, 2);
```

### 3.11 Comptime Optimization

| Detect | Runtime loop for constant lookup |
|--------|----------------------------------|
| Risk | Suboptimal performance |

**Wrong:**
```zig
fn isVowel(c: u8) bool {
    for ("aeiouAEIOU") |v| {
        if (c == v) return true;
    }
    return false;
}
```

**Right:**
```zig
fn isVowel(c: u8) bool {
    const table = comptime blk: {
        var t: [256]bool = .{false} ** 256;
        for ("aeiouAEIOU") |v| t[v] = true;
        break :blk t;
    };
    return table[c];
}
```

### 3.12 SIMD Opportunities

| Detect | Scalar loop on arrays where SIMD helps |
|--------|----------------------------------------|
| Risk | Suboptimal performance |

**Scalar:**
```zig
fn addArrays(a: []const f32, b: []const f32, result: []f32) void {
    for (a, b, result) |av, bv, *rv| {
        rv.* = av + bv;
    }
}
```

**SIMD:**
```zig
fn addArrays(a: []const f32, b: []const f32, result: []f32) void {
    const Vec = @Vector(8, f32);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        const va: Vec = a[i..][0..8].*;
        const vb: Vec = b[i..][0..8].*;
        result[i..][0..8].* = va + vb;
    }
    while (i < a.len) : (i += 1) {
        result[i] = a[i] + b[i];
    }
}
```

Only suggest for hot loops with measurable impact.

### 3.13 Struct Layout

| Detect | `packed` for non-binary data, or poor extern field ordering |
|--------|-------------------------------------------------------------|
| Risk | Slower access or wasted padding |

**Use:**
- Regular `struct` for normal use
- `packed struct` for binary protocols/hardware
- `extern struct` for C ABI

**Extern field order:** Order by size descending to minimize padding.

### 3.14 Testing Best Practices

| Detect | Production allocator in tests, or wrong assertion type |
|--------|--------------------------------------------------------|
| Risk | Missed leaks, false passes |

**Allocator:**
```zig
// Wrong: var gpa: std.heap.DebugAllocator(.{}) = .init;
// Right: use std.testing.allocator
```

**Assertions:**
```zig
// Strings: use expectEqualStrings (not expectEqual)
// Slices: use expectEqualSlices (not expectEqual)
```

### 3.15 Documentation

| Detect | Public API without doc comments |
|--------|--------------------------------|
| Risk | Poor discoverability |

Focus on: what it does, error conditions, ownership, usage example.

### 3.16 Stateless Context Pattern

| Detect | `self` parameter that's never used |
|--------|-----------------------------------|
| Risk | None (style) |

**Wrong:**
```zig
pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
    _ = self;
    return std.mem.eql(u8, a, b);
}
```

**Right:**
```zig
pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
```

### 3.17 Numeric Variable Naming (index/count/offset/size)

| Detect | Mixed use of `length`, `size`, `count`, `index` without consistent distinction |
|--------|-------------------------------------------------------------------------------|
| Risk | Off-by-one errors, index space confusion |

Use consistent suffixes to distinguish numeric quantities (from [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)):

| Suffix | Meaning | Domain | Invariant |
|--------|---------|--------|-----------|
| `_count` | Number of items | Items | — |
| `_index` | Position of one item | Items | `index < count` |
| `_size` | Number of bytes | Bytes | `size = @sizeOf(T) * count` |
| `_offset` | Byte position | Bytes | `offset < size` |

Avoid `length`/`len` for new code — it's ambiguous (Rust `str::len` = byte size; Python `len(str)` = codepoint count). Note: Zig's stdlib uses `.len` on slices, which is fine — this convention applies to your own variable names.

**Wrong:**
```zig
fn process(data: []const u8, len: usize) void {
    var pos: usize = 0;
    var n: usize = 0;
    while (pos < len) {
        // Are pos and len in the same domain? Hard to tell.
        n += 1;
        pos += record_len;  // Is this bytes or items?
    }
}
```

**Right:**
```zig
fn process(data: []const u8, data_size: usize) void {
    var record_index: usize = 0;
    var data_offset: usize = 0;
    while (data_offset < data_size) {
        // Clear: offset < size (both bytes), index counts items
        record_index += 1;
        data_offset += record_size;  // size = bytes, obviously
    }
}
```

Converting between index and offset spaces should be explicit:

```zig
const node_offset = @intFromPtr(node) - @intFromPtr(pool.buffer.ptr);
const node_index = @divExact(node_offset, node_size);
// Correctness is mechanical: offset / size = index ✓
```

**Naming tips:**
- Use "big-endian" naming — qualifiers as suffixes: `source_index`, `target_index` (not `idx_source`)
- Choose dual names of equal length for visual alignment: `source`/`target` (not `src`/`destination`)

Aligned names make bugs pop out during review:

```zig
source_index += marker.literal_word_count;
target_index += marker.literal_word_count;
```

See also [2.6](#26-type-unsafe-index-usage) for enforcing index safety with distinct enum types.

---

## File References

- [SKILL.md](../SKILL.md) - Breaking changes overview
- [patterns.md](patterns.md) - Best practices patterns
- [std-io.md](std-io.md) - New I/O API
- [std-allocators.md](std-allocators.md) - Allocator naming conventions
- [style-guide.md](style-guide.md) - Style conventions
