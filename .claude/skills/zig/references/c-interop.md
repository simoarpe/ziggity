# C Interoperability Reference

Zig can export C-compatible APIs for use from any language that supports the C ABI: Swift, Objective-C, Python, Ruby, Rust, etc. This enables architectures like Ghostty (93% Zig business logic + 4% platform-native GUI).

## Table of Contents
- [Quick Start](#quick-start)
- [Exporting Functions](#exporting-functions)
- [C-Compatible Types](#c-compatible-types)
- [Building C Libraries](#building-c-libraries)
- [Creating Header Files](#creating-header-files)
- [macOS Integration](#macos-integration)
- [Swift Integration](#swift-integration)
- [Common Patterns](#common-patterns)

## Quick Start

Minimal C-compatible library:

**src/lib.zig:**
```zig
const std = @import("std");

// Global state (opaque to C consumers)
var context: ?*Context = null;

const Context = struct {
    allocator: std.mem.Allocator,
    value: i32,
};

/// Initialize the library. Returns 0 on success, -1 on failure.
export fn mylib_init() c_int {
    const gpa = std.heap.c_allocator;
    context = gpa.create(Context) catch return -1;
    context.?.* = .{ .allocator = gpa, .value = 0 };
    return 0;
}

/// Clean up resources.
export fn mylib_deinit() void {
    if (context) |ctx| {
        ctx.allocator.destroy(ctx);
        context = null;
    }
}

/// Get the current value.
export fn mylib_get_value() c_int {
    return if (context) |ctx| ctx.value else 0;
}

/// Set the value.
export fn mylib_set_value(v: c_int) void {
    if (context) |ctx| ctx.value = v;
}
```

**build.zig:**
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "mylib",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libc if using std.heap.c_allocator
    lib.linkLibC();

    b.installArtifact(lib);

    // Install header alongside library
    b.installFile("include/mylib.h", "include/mylib.h");
}
```

**include/mylib.h:**
```c
#ifndef MYLIB_H
#define MYLIB_H

#ifdef __cplusplus
extern "C" {
#endif

int mylib_init(void);
void mylib_deinit(void);
int mylib_get_value(void);
void mylib_set_value(int v);

#ifdef __cplusplus
}
#endif

#endif /* MYLIB_H */
```

## Exporting Functions

### `export` Keyword

The `export` keyword creates a function with C ABI linkage:

```zig
// Creates symbol "add" with C calling convention
export fn add(a: c_int, b: c_int) c_int {
    return a + b;
}
```

Equivalent to:
```zig
fn add(a: c_int, b: c_int) callconv(.c) c_int {
    return a + b;
}
comptime {
    @export(&add, .{ .name = "add" });
}
```

### Custom Symbol Names

Use `@export` for custom symbol names:

```zig
fn zigAdd(a: c_int, b: c_int) callconv(.c) c_int {
    return a + b;
}

comptime {
    @export(&zigAdd, .{ .name = "mylib_add" });  // Symbol: mylib_add
}
```

### Calling Convention

For internal C-callable functions (not exported):

```zig
// C calling convention, but not exported as symbol
fn internalCallback(data: ?*anyopaque) callconv(.c) void {
    // Called by C code via function pointer
}
```

### Restrictions on Exported Functions

Exported function signatures are limited to C-compatible constructs:

**Allowed:**
- C integer types: `c_int`, `c_uint`, `c_long`, `c_ulong`, `c_char`, etc.
- Fixed-width integers matching C: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`
- Floating point: `f32` (`float`), `f64` (`double`)
- Pointers: `*T`, `[*]T`, `[*c]T`, `?*T`
- `bool` (maps to C `_Bool`)
- `void`
- `usize`, `isize` (map to `size_t`, `ptrdiff_t`)

**Not allowed in signatures:**
- Comptime parameters
- Generic types (`anytype`)
- Zig error unions (`!T`)
- Zig optionals (except optional pointers `?*T`)
- Slices (`[]T`) - use pointer + length instead
- Non-extern structs/unions/enums
- Arbitrary bit-width integers (`u3`, `i47`)

**Inside the function body**, all Zig features work:

```zig
export fn process(data: [*]const u8, len: usize) c_int {
    // Inside: full Zig features
    const slice = data[0..len];

    for (slice) |byte| {
        if (byte == 0) return -1;
    }

    return @intCast(slice.len);
}
```

## C-Compatible Types

### Integer Type Mapping

| Zig Type | C Type | Notes |
|----------|--------|-------|
| `c_char` | `char` | Signed or unsigned (platform-dependent) |
| `c_short` | `short` | |
| `c_int` | `int` | |
| `c_long` | `long` | 32-bit on Windows, 64-bit elsewhere |
| `c_longlong` | `long long` | |
| `c_uchar` | `unsigned char` | |
| `c_ushort` | `unsigned short` | |
| `c_uint` | `unsigned int` | |
| `c_ulong` | `unsigned long` | |
| `c_ulonglong` | `unsigned long long` | |
| `usize` | `size_t` | |
| `isize` | `ptrdiff_t` | |
| `i8`/`u8` | `int8_t`/`uint8_t` | |
| `i16`/`u16` | `int16_t`/`uint16_t` | |
| `i32`/`u32` | `int32_t`/`uint32_t` | |
| `i64`/`u64` | `int64_t`/`uint64_t` | |

### Pointer Type Mapping

| Zig Type | C Equivalent | Notes |
|----------|--------------|-------|
| `*T` | `T*` | Non-null pointer |
| `?*T` | `T*` | Nullable pointer |
| `[*]T` | `T*` | Many-item pointer |
| `[*c]T` | `T*` | C pointer (nullable, arithmetic allowed) |
| `*const T` | `const T*` | Const pointer |

### Extern Structs

For structs passed across FFI boundary:

```zig
// Extern struct: C-compatible layout
pub const Point = extern struct {
    x: f64,
    y: f64,
};

// Can be passed by value or pointer
export fn distance(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}
```

### Extern Unions

```zig
pub const Value = extern union {
    i: c_int,
    f: f32,
    p: ?*anyopaque,
};
```

### Extern Enums

```zig
// Specify backing type for C compatibility
pub const Status = enum(c_int) {
    ok = 0,
    err_invalid = -1,
    err_nomem = -2,
};

export fn get_status() Status {
    return .ok;
}
```

## Building C Libraries

### Static Library

```zig
const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .static,  // Creates libmylib.a
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

lib.linkLibC();  // If using c_allocator or libc functions
b.installArtifact(lib);
```

### Dynamic/Shared Library

```zig
const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .dynamic,  // Creates libmylib.so / libmylib.dylib / mylib.dll
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
    .version = .{ .major = 1, .minor = 0, .patch = 0 },
});

lib.linkLibC();
b.installArtifact(lib);
```

### Cross-Compilation

Build for specific targets:

```zig
// Build for Apple Silicon Mac
const mac_arm = b.resolveTargetQuery(.{
    .cpu_arch = .aarch64,
    .os_tag = .macos,
});

const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .static,
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = mac_arm,
        .optimize = .ReleaseFast,
    }),
});
```

### Multi-Target Build

```zig
const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
};

for (targets) |t| {
    const resolved = b.resolveTargetQuery(t);
    const lib = b.addLibrary(.{
        .name = b.fmt("mylib-{s}-{s}", .{
            @tagName(t.cpu_arch.?),
            @tagName(t.os_tag.?),
        }),
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(lib);
}
```

## Creating Header Files

Zig does not auto-generate C headers. Write them manually to match exported symbols.

### Header Template

```c
#ifndef MYLIB_H
#define MYLIB_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle type */
typedef struct mylib_context mylib_context_t;

/* Lifecycle */
mylib_context_t* mylib_create(void);
void mylib_destroy(mylib_context_t* ctx);

/* Operations */
int mylib_process(mylib_context_t* ctx, const uint8_t* data, size_t len);
const char* mylib_get_error(mylib_context_t* ctx);

/* Callback type */
typedef void (*mylib_callback_t)(void* user_data, int result);
void mylib_set_callback(mylib_context_t* ctx, mylib_callback_t cb, void* user_data);

#ifdef __cplusplus
}
#endif

#endif /* MYLIB_H */
```

### Matching Zig Implementation

```zig
const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    error_msg: ?[]const u8 = null,
    callback: ?Callback = null,

    const Callback = struct {
        func: *const fn (?*anyopaque, c_int) callconv(.c) void,
        user_data: ?*anyopaque,
    };
};

export fn mylib_create() ?*Context {
    const allocator = std.heap.c_allocator;
    return allocator.create(Context) catch null;
}

export fn mylib_destroy(ctx: ?*Context) void {
    if (ctx) |c| {
        c.allocator.destroy(c);
    }
}

export fn mylib_process(ctx: ?*Context, data: [*]const u8, len: usize) c_int {
    const c = ctx orelse return -1;
    const slice = data[0..len];

    // Process data...
    _ = slice;

    if (c.callback) |cb| {
        cb.func(cb.user_data, 0);
    }

    return 0;
}

export fn mylib_get_error(ctx: ?*Context) [*:0]const u8 {
    const c = ctx orelse return "null context";
    return if (c.error_msg) |msg|
        msg.ptr
    else
        "no error";
}

export fn mylib_set_callback(
    ctx: ?*Context,
    cb: ?*const fn (?*anyopaque, c_int) callconv(.c) void,
    user_data: ?*anyopaque,
) void {
    if (ctx) |c| {
        c.callback = if (cb) |f| .{ .func = f, .user_data = user_data } else null;
    }
}
```

## macOS Integration

### Universal Binaries (Fat Binaries)

Build for both architectures and combine with `lipo`:

**build.zig:**
```zig
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Build for both architectures
    const arm64 = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const x86_64 = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });

    const lib_arm64 = b.addLibrary(.{
        .name = "mylib",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = arm64,
            .optimize = optimize,
        }),
    });

    const lib_x86_64 = b.addLibrary(.{
        .name = "mylib",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = x86_64,
            .optimize = optimize,
        }),
    });

    // Use lipo to create universal binary
    const lipo = b.addSystemCommand(&.{
        "lipo", "-create", "-output",
    });
    const universal_lib = lipo.addOutputFileArg("libmylib.a");
    lipo.addFileArg(lib_arm64.getEmittedBin());
    lipo.addFileArg(lib_x86_64.getEmittedBin());

    // Install universal binary
    const install = b.addInstallFile(universal_lib, "lib/libmylib.a");

    const universal_step = b.step("universal", "Build universal binary");
    universal_step.dependOn(&install.step);
}
```

**Manual lipo usage:**
```bash
# Build each architecture
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
mv zig-out/lib/libmylib.a libmylib-arm64.a

zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
mv zig-out/lib/libmylib.a libmylib-x86_64.a

# Combine into universal binary
lipo -create -output libmylib.a libmylib-arm64.a libmylib-x86_64.a

# Verify architectures
lipo -info libmylib.a
```

### XCFramework Creation

XCFrameworks are the modern way to distribute libraries for Apple platforms:

```bash
# 1. Build universal library (see above)

# 2. Create directory structure
mkdir -p MyLib.xcframework/macos-arm64_x86_64/Headers

# 3. Copy library and headers
cp libmylib.a MyLib.xcframework/macos-arm64_x86_64/
cp include/mylib.h MyLib.xcframework/macos-arm64_x86_64/Headers/

# 4. Create module map
cat > MyLib.xcframework/macos-arm64_x86_64/Headers/module.modulemap << 'EOF'
module MyLib {
    umbrella header "mylib.h"
    export *
}
EOF

# 5. Create Info.plist
cat > MyLib.xcframework/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>macos-arm64_x86_64</string>
            <key>LibraryPath</key>
            <string>libmylib.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF
```

**Using xcodebuild (simpler):**
```bash
xcodebuild -create-xcframework \
    -library libmylib.a \
    -headers include/ \
    -output MyLib.xcframework
```

## Swift Integration

### Module Map

Create `module.modulemap` alongside your header:

```c
module MyLib {
    umbrella header "mylib.h"
    export *
}
```

### Using from Swift

```swift
import MyLib

// Use C functions directly
let result = mylib_init()
if result == 0 {
    mylib_set_value(42)
    print("Value: \(mylib_get_value())")
    mylib_deinit()
}
```

### Swift-Friendly Wrapper

```swift
import MyLib

class MyLibWrapper {
    private var initialized = false

    init?() {
        guard mylib_init() == 0 else { return nil }
        initialized = true
    }

    deinit {
        if initialized {
            mylib_deinit()
        }
    }

    var value: Int32 {
        get { mylib_get_value() }
        set { mylib_set_value(newValue) }
    }
}
```

### Xcode Project Integration

1. Drag `MyLib.xcframework` into Xcode project
2. Ensure "Embed & Sign" or "Do Not Embed" (for static libs)
3. Import module: `import MyLib`

For static libraries without XCFramework:
1. Add library to "Link Binary With Libraries"
2. Add header path to "Header Search Paths"
3. Create bridging header if not using module map

### Improving Swift Interop (Advanced)

For better Swift projection, use API notes (`.apinotes` files):

**MyLib.apinotes:**
```yaml
Name: MyLib
Functions:
  - Name: mylib_create
    SwiftName: "MyLibContext.create()"
    NullabilityOfRet: N  # Non-null (returns Optional in Swift)
  - Name: mylib_destroy
    SwiftName: "MyLibContext.destroy(self:)"
  - Name: mylib_get_error
    NullabilityOfRet: N
    ResultType: "const char * _Nonnull"
```

See [Swift.org: Improving the Usability of C APIs](https://www.swift.org/documentation/cxx-interop/) for more.

## Common Patterns

### Opaque Pointers

Hide implementation details from C consumers:

```zig
const std = @import("std");

const InternalState = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
    // Complex internal state...
};

// C sees: typedef struct handle handle_t;
// (opaque, can't access fields)

export fn handle_create() ?*InternalState {
    const allocator = std.heap.c_allocator;
    const state = allocator.create(InternalState) catch return null;
    state.* = .{
        .allocator = allocator,
        .data = std.ArrayList(u8).init(allocator),
    };
    return state;
}

export fn handle_destroy(h: ?*InternalState) void {
    if (h) |state| {
        state.data.deinit();
        state.allocator.destroy(state);
    }
}
```

### Error Handling Across FFI

Zig errors can't cross FFI boundary. Use return codes or out parameters:

```zig
pub const ErrorCode = enum(c_int) {
    ok = 0,
    invalid_argument = -1,
    out_of_memory = -2,
    io_error = -3,
    unknown = -99,
};

export fn process_data(
    data: [*]const u8,
    len: usize,
    out_result: *c_int,
) ErrorCode {
    const slice = data[0..len];

    // Internal Zig code can use errors
    const result = processInternal(slice) catch |err| {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidData => .invalid_argument,
            else => .unknown,
        };
    };

    out_result.* = result;
    return .ok;
}

fn processInternal(data: []const u8) !c_int {
    // Full Zig error handling here
    if (data.len == 0) return error.InvalidData;
    return @intCast(data.len);
}
```

### Callbacks

C callbacks with user data:

```zig
const CallbackFn = *const fn (
    user_data: ?*anyopaque,
    event_type: c_int,
    event_data: ?*const anyopaque,
) callconv(.c) void;

var stored_callback: ?CallbackFn = null;
var stored_user_data: ?*anyopaque = null;

export fn register_callback(cb: ?CallbackFn, user_data: ?*anyopaque) void {
    stored_callback = cb;
    stored_user_data = user_data;
}

export fn trigger_event(event_type: c_int) void {
    if (stored_callback) |cb| {
        cb(stored_user_data, event_type, null);
    }
}
```

### String Handling

Zig slices vs C strings:

```zig
const std = @import("std");

// Accept C string, return length
export fn string_length(s: [*:0]const u8) usize {
    return std.mem.len(s);
}

// Accept pointer + length (more efficient)
export fn process_string(s: [*]const u8, len: usize) c_int {
    const slice = s[0..len];
    // Process slice...
    _ = slice;
    return 0;
}

// Return C string (must be static or allocated)
const greeting: [:0]const u8 = "Hello from Zig!";

export fn get_greeting() [*:0]const u8 {
    return greeting.ptr;
}

// Allocate string for caller to free
export fn alloc_string(len: usize) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const buf = allocator.allocSentinel(u8, len, 0) catch return null;
    return buf.ptr;
}

export fn free_string(s: ?[*:0]u8) void {
    if (s) |ptr| {
        const allocator = std.heap.c_allocator;
        // Need to know length to free - typically tracked separately
        // or use c_allocator which can query allocation size
        _ = allocator;
        _ = ptr;
    }
}
```

### Thread Safety

For thread-safe libraries, use atomics or mutexes:

```zig
const std = @import("std");

var global_mutex: std.Thread.Mutex = .{};
var shared_value: c_int = 0;

export fn thread_safe_increment() c_int {
    global_mutex.lock();
    defer global_mutex.unlock();

    shared_value += 1;
    return shared_value;
}

// Or use atomics for simple cases
var atomic_counter: std.atomic.Value(c_int) = .init(0);

export fn atomic_increment() c_int {
    return atomic_counter.fetchAdd(1, .seq_cst) + 1;
}
```

### Versioning

Export version info for runtime checking:

```zig
pub const version_major: c_int = 1;
pub const version_minor: c_int = 2;
pub const version_patch: c_int = 3;

comptime {
    @export(&version_major, .{ .name = "mylib_version_major" });
    @export(&version_minor, .{ .name = "mylib_version_minor" });
    @export(&version_patch, .{ .name = "mylib_version_patch" });
}

export fn mylib_version_string() [*:0]const u8 {
    return "1.2.3";
}
```

**Header:**
```c
extern const int mylib_version_major;
extern const int mylib_version_minor;
extern const int mylib_version_patch;
const char* mylib_version_string(void);
```
