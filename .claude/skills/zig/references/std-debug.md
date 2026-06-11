# std.debug

Debugging utilities: panic handling, assertions, stack traces, hex dumps, and value tracing.

## Quick Reference

| Function | Purpose |
|----------|---------|
| `print(fmt, args)` | Printf-style debug output to stderr |
| `panic(fmt, args)` | Format message and abort |
| `assert(bool)` | Crash if false (optimized out in ReleaseFast) |
| `dumpCurrentStackTrace(addr)` | Print stack trace to stderr |
| `dumpHex(bytes)` | Print hexdump to stderr |

## Debug Printing

```zig
const std = @import("std");

// Quick debug output (64-byte buffer, auto-flush)
std.debug.print("value: {}\n", .{x});
std.debug.print("name: {s}, count: {d}\n", .{name, count});

// Print without newline
std.debug.print("loading...", .{});
```

**Note:** `std.debug.print` silently ignores errors. For production logging, use `std.log`.

## Format Specifiers

Format string syntax: `{[arg]:[fill][alignment][width][.precision][specifier]}`

### Type Specifiers

| Specifier | Types | Output |
|-----------|-------|--------|
| `{}` | any | Default formatting |
| `{s}` | `[]const u8`, `[*:0]const u8` | String |
| `{d}` | int, float, enum | Decimal |
| `{b}` | int, enum | Binary |
| `{o}` | int, enum | Octal |
| `{x}` | int, float, `[]u8`, enum | Lowercase hex |
| `{X}` | int, float, `[]u8`, enum | Uppercase hex |
| `{c}` | u8, u21 | ASCII character |
| `{u}` | u21 | Unicode codepoint |
| `{e}` | float | Scientific notation |
| `{*}` | pointer | Address (`Type@0x...`) |
| `{f}` | has `format` method | Custom formatter |
| `{any}` | any | Debug representation with depth limit |

### Examples

```zig
std.debug.print("{d}\n", .{42});           // "42"
std.debug.print("{x}\n", .{255});          // "ff"
std.debug.print("{X}\n", .{255});          // "FF"
std.debug.print("{b}\n", .{5});            // "101"
std.debug.print("{o}\n", .{64});           // "100"
std.debug.print("{s}\n", .{"hello"});      // "hello"
std.debug.print("{c}\n", .{'A'});          // "A"
std.debug.print("{*}\n", .{&value});       // "i32@7fff5fbff8a0"

// Floats
std.debug.print("{d}\n", .{3.14159});      // "3.14159"
std.debug.print("{e}\n", .{1234.5});       // "1.2345e+03"
std.debug.print("{x}\n", .{@as(f32, 1.0)}); // "0x1.0p0"

// Hex dump of bytes
std.debug.print("{x}\n", .{"hello"});      // "68656c6c6f"
```

### Width and Alignment

```zig
std.debug.print("{d:5}\n", .{42});         // "   42" (right-aligned, width 5)
std.debug.print("{d:<5}\n", .{42});        // "42   " (left-aligned)
std.debug.print("{d:^5}\n", .{42});        // " 42  " (center-aligned)
std.debug.print("{d:0>5}\n", .{42});       // "00042" (zero-padded)
std.debug.print("{s:_<10}\n", .{"hi"});    // "hi________" (custom fill)
```

### Precision

```zig
std.debug.print("{d:.2}\n", .{3.14159});   // "3.14"
std.debug.print("{e:.3}\n", .{1234.5});    // "1.234e+03"
std.debug.print("{x:.4}\n", .{@as(f32, 1.0)}); // "0x1.0000p0"
```

### Named and Positional Arguments

```zig
// Positional
std.debug.print("{0} {1} {0}\n", .{"a", "b"});  // "a b a"

// Named (with struct)
std.debug.print("{name}: {value}\n", .{ .name = "x", .value = 42 });

// Runtime width/precision
std.debug.print("{d:[width]}\n", .{ .width = 5, 42 });
std.debug.print("{d:.[precision]}\n", .{ .precision = 2, 3.14159 });
```

### Escape Braces

```zig
std.debug.print("{{literal braces}}\n", .{});  // "{literal braces}"
```

### Custom Format Method

Types can implement a `format` method for `{f}`:

```zig
const Point = struct {
    x: f32,
    y: f32,

    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print("({d:.2}, {d:.2})", .{ self.x, self.y });
    }
};

const p = Point{ .x = 1.5, .y = 2.5 };
std.debug.print("{f}\n", .{p});  // "(1.50, 2.50)"
```

### Any Format (Debug Representation)

```zig
const data = .{ .x = 1, .list = &[_]u8{ 1, 2, 3 } };
std.debug.print("{any}\n", .{data});
// Prints struct with depth-limited recursion
```

## Assertions

```zig
// Runtime assertion (triggers illegal instruction on failure)
std.debug.assert(x > 0);
std.debug.assert(ptr != null);

// Debug/ReleaseSafe: generates check
// ReleaseFast/ReleaseSmall: optimized away (undefined behavior if false)
```

### Specialized Assertions

```zig
// Assert slice is readable (checks memory mapping)
std.debug.assertReadable(slice);

// Assert pointer alignment
std.debug.assertAligned(ptr, .@"16");  // 16-byte alignment
```

## Panic

```zig
// Formatted panic message
std.debug.panic("invalid state: {}", .{state});

// With explicit return address
std.debug.panicExtra(@returnAddress(), "error: {s}", .{msg});
```

Panic prints message + stack trace to stderr, then aborts.

## Stack Traces

### Dump Current Stack

```zig
// Print current stack trace to stderr
std.debug.dumpCurrentStackTrace(null);

// Skip frames until this address
std.debug.dumpCurrentStackTrace(@returnAddress());
```

### Dump to Writer

```zig
var buf: [4096]u8 = undefined;
const stderr = std.fs.File.stderr().writer(&buf);
try std.debug.dumpCurrentStackTraceToWriter(null, &stderr.interface);
```

### Capture Stack Trace

```zig
var addrs: [32]usize = undefined;
var trace: std.builtin.StackTrace = .{
    .instruction_addresses = &addrs,
    .index = 0,
};
std.debug.captureStackTrace(@returnAddress(), &trace);

// Later: print captured trace
std.debug.dumpStackTrace(trace);
```

### StackIterator

Walk the stack manually:

```zig
var it = std.debug.StackIterator.init(@returnAddress(), null);
defer it.deinit();

while (it.next()) |return_address| {
    const addr = return_address -| 1;
    std.debug.print("0x{x}\n", .{addr});
}
```

## Hex Dump

```zig
const data = "Hello, World!\x00\x01\x02";

// Quick dump to stderr
std.debug.dumpHex(data);
// Output:
// 7fff5fbff8a0  48 65 6C 6C 6F 2C 20 57  6F 72 6C 64 21 00 01 02  Hello, World!...

// Dump to writer
var buf: [256]u8 = undefined;
var aw: std.io.Writer.Allocating = .init(allocator);
defer aw.deinit();
try std.debug.dumpHexFallible(&aw.writer, .no_color, data);
```

Output format:
- Address (lowercase hex)
- 16 bytes per line (uppercase hex)
- ASCII representation (`.` for non-printable, special chars for `\n`, `\r`, `\t`)

## Value Tracing

Track where values originate and mutate during debugging:

```zig
const Trace = std.debug.Trace;  // Pre-configured: 2 traces, 4 stack frames

const MyStruct = struct {
    value: u32,
    trace: Trace = .init,

    fn setValue(self: *@This(), v: u32) void {
        self.value = v;
        self.trace.add("setValue called");
    }
};

var s = MyStruct{ .value = 0 };
s.setValue(42);
s.trace.dump();  // Prints stack traces with notes
```

### Configurable Trace

```zig
// Custom configuration: 4 trace slots, 8 stack frames per trace
const MyTrace = std.debug.ConfigurableTrace(4, 8, true);

var trace: MyTrace = .init;
trace.add("first mutation");
trace.addAddr(@returnAddress(), "with explicit address");

// Check if tracing is enabled
if (MyTrace.enabled) {
    trace.dump();
}

// Use in format strings
std.debug.print("trace: {}", .{trace});
```

In release builds (`enabled = false`), all trace operations are no-ops with zero size.

## SafetyLock

Debug helper to detect concurrent access violations:

```zig
const SafetyLock = std.debug.SafetyLock;

var lock: SafetyLock = .{};

fn criticalSection() void {
    lock.lock();
    defer lock.unlock();
    // ... protected code
}

fn checkNotLocked() void {
    lock.assertUnlocked();  // Panics if locked
}
```

- In Debug/ReleaseSafe: actively tracks lock state
- In ReleaseFast/ReleaseSmall: all methods are no-ops

## Source Location

```zig
const SourceLocation = std.debug.SourceLocation;

const loc: SourceLocation = .{
    .line = 42,
    .column = 10,
    .file_name = "src/main.zig",
};

// Invalid/unknown location
const unknown = SourceLocation.invalid;
```

## Symbol Information

```zig
const Symbol = std.debug.Symbol;

// Symbol with resolved source location
const sym: Symbol = .{
    .name = "myFunction",
    .compile_unit_name = "main.zig",
    .source_location = .{ .line = 100, .column = 1, .file_name = "src/main.zig" },
};

// Unknown symbol
const unknown: Symbol = .{};  // name = "???", compile_unit_name = "???"
```

## Segfault Handling

```zig
// Check if platform supports segfault handling
if (std.debug.have_segfault_handling_support) {
    // Attach handler (prints stack trace on SIGSEGV/SIGBUS/etc)
    std.debug.attachSegfaultHandler();

    // Later: reset to default handler
    std.debug.resetSegfaultHandler();
}

// Check if handler is enabled by default
const enabled = std.debug.default_enable_segfault_handler;
```

**Note:** `maybeEnableSegfaultHandler()` is called automatically by the runtime if `std.options.enable_segfault_handler` is true.

## Thread Context

Platform-specific CPU register state for stack unwinding:

```zig
const ThreadContext = std.debug.ThreadContext;

var ctx: ThreadContext = undefined;
if (std.debug.getContext(&ctx)) {
    // ctx now contains register state
    std.debug.dumpStackTraceFromBase(&ctx, stderr);
}

// Copy context (handles internal pointers)
var ctx_copy: ThreadContext = undefined;
std.debug.copyContext(&original_ctx, &ctx_copy);
```

## Valgrind Detection

```zig
if (std.debug.inValgrind()) {
    // Running under Valgrind - may want different behavior
    std.debug.print("Valgrind detected\n", .{});
}
```

## Debug Info Access

```zig
// Get debug info for current executable
const info = try std.debug.getSelfDebugInfo();

// Get symbol at address
const symbol = try info.getSymbolAtAddress(allocator, address);
defer if (symbol.source_location) |sl| allocator.free(sl.file_name);

std.debug.print("{s}:{d}: {s}\n", .{
    symbol.source_location.?.file_name,
    symbol.source_location.?.line,
    symbol.name,
});
```

## Constants

```zig
// Whether runtime safety checks are enabled
std.debug.runtime_safety  // true in Debug/ReleaseSafe

// Whether platform can produce stack traces
std.debug.sys_can_stack_trace  // false on WASM, MIPS, etc.

// Whether platform has ucontext_t
std.debug.have_ucontext
```

## Submodules

| Module | Purpose |
|--------|---------|
| `std.debug.Dwarf` | DWARF debug info parser |
| `std.debug.Pdb` | Windows PDB debug info parser |
| `std.debug.SelfInfo` | Debug info for current executable |
| `std.debug.MemoryAccessor` | Safe memory access for unwinding |
| `std.debug.Coverage` | Code coverage support |

## FullPanic

Create custom panic handler with formatted safety messages:

```zig
pub const panic = std.debug.FullPanic(myPanicFn);

fn myPanicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    // Custom panic handling (log to file, send telemetry, etc.)
    std.posix.abort();
}

// Now safety checks use myPanicFn with descriptive messages:
// - "sentinel mismatch: expected X, found Y"
// - "index out of bounds: index N, len M"
// - "attempt to unwrap error: ErrorName"
// etc.
```

## Locking stderr

For multi-line debug output without interleaving:

```zig
// Lock stderr and clear any progress indicators
std.debug.lockStdErr();
defer std.debug.unlockStdErr();

// Safe to write multiple lines
const stderr = std.io.getStdErr();
try stderr.writeAll("Line 1\n");
try stderr.writeAll("Line 2\n");
```

Or with a writer:

```zig
var buf: [256]u8 = undefined;
const writer = std.debug.lockStderrWriter(&buf);
defer std.debug.unlockStderrWriter();

try writer.print("Complex output: {}\n", .{value});
```
