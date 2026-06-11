# std.fmt - String Formatting and Parsing

String formatting and parsing utilities: format strings, integer/float parsing, hex encoding/decoding, and custom formatters.

## Table of Contents
- [Format String Syntax](#format-string-syntax)
- [Format Specifiers](#format-specifiers)
- [Integer Parsing](#integer-parsing)
- [Float Parsing](#float-parsing)
- [Hex Encoding/Decoding](#hex-encodingdecoding)
- [Buffer Printing](#buffer-printing)
- [Allocating Print](#allocating-print)
- [Comptime Print](#comptime-print)
- [Custom Formatters](#custom-formatters)
- [Format String Parser](#format-string-parser)

## Format String Syntax

Full syntax: `{[arg]:[fill][alignment][width][.precision][specifier]}`

### Components

| Component | Description | Example |
|-----------|-------------|---------|
| `arg` | Argument index or name | `{0}`, `{name}` |
| `fill` | Padding character | `{:0>5}` uses `0` |
| `alignment` | `<` left, `^` center, `>` right | `{:<10}` |
| `width` | Minimum field width | `{:10}` |
| `precision` | Decimal places for floats | `{:.2}` |
| `specifier` | Output format | `{d}`, `{x}`, `{s}` |

### Examples

```zig
std.debug.print("{d:0>8}\n", .{42});        // "00000042"
std.debug.print("{s:_^10}\n", .{"hi"});     // "____hi____"
std.debug.print("{d:.2}\n", .{3.14159});    // "3.14"
std.debug.print("{0} {1} {0}\n", .{"a", "b"}); // "a b a"
```

### Named Arguments

```zig
std.debug.print("{name}: {value}\n", .{ .name = "x", .value = 42 });
```

### Runtime Width/Precision

```zig
std.debug.print("{d:[width]}\n", .{ .width = @as(usize, 8), 42 });
std.debug.print("{d:.[prec]}\n", .{ .prec = @as(usize, 2), 3.14159 });
```

### Escape Braces

```zig
std.debug.print("{{literal}}\n", .{});  // "{literal}"
```

## Format Specifiers

### Type Specifiers

| Specifier | Types | Output |
|-----------|-------|--------|
| `{}` | any | Default formatting |
| `{d}` | int, float, enum | Decimal |
| `{b}` | int, enum | Binary |
| `{o}` | int, enum | Octal |
| `{x}` | int, float, `[]u8`, enum | Lowercase hex |
| `{X}` | int, float, `[]u8`, enum | Uppercase hex |
| `{s}` | `[]const u8`, `[*:0]const u8` | String |
| `{c}` | u8 | ASCII character |
| `{u}` | u21 | UTF-8 codepoint |
| `{e}` | float | Scientific notation |
| `{f}` | has `format` method | Custom formatter (0.15.x) |
| `{*}` | pointer | Address (`Type@0x...`) |
| `{?}` | optional | Value or `null` |
| `{!}` | error union | Value or `error.Name` |
| `{any}` | any | Debug representation |

### Integer Examples

```zig
std.debug.print("{d}\n", .{255});      // "255"
std.debug.print("{x}\n", .{255});      // "ff"
std.debug.print("{X}\n", .{255});      // "FF"
std.debug.print("{b}\n", .{5});        // "101"
std.debug.print("{o}\n", .{64});       // "100"
std.debug.print("{c}\n", .{'A'});      // "A"
std.debug.print("{u}\n", .{0x1F310});  // globe emoji
```

### Float Examples

```zig
std.debug.print("{d}\n", .{3.14159});           // "3.14159"
std.debug.print("{d:.2}\n", .{3.14159});        // "3.14"
std.debug.print("{e}\n", .{1234.5});            // "1.2345e3"
std.debug.print("{e:.3}\n", .{1234.5});         // "1.234e3"
std.debug.print("{x}\n", .{@as(f32, 1.0)});     // "0x1p0"
std.debug.print("{x:.5}\n", .{@as(f32, 1.0)});  // "0x1.00000p0"
```

### Special Float Values

```zig
std.debug.print("{}\n", .{std.math.nan(f64)});  // "nan"
std.debug.print("{}\n", .{std.math.inf(f64)});  // "inf"
std.debug.print("{}\n", .{-std.math.inf(f64)}); // "-inf"
```

### Slice/Array Formatting

```zig
const bytes: []const u8 = "hello";
std.debug.print("{s}\n", .{bytes});    // "hello"
std.debug.print("{x}\n", .{bytes});    // "68656c6c6f"
std.debug.print("{any}\n", .{bytes});  // "{ 104, 101, 108, 108, 111 }"
```

### Padding and Alignment

```zig
std.debug.print("{d:5}\n", .{42});      // "   42" (right, default)
std.debug.print("{d:<5}\n", .{42});     // "42   " (left)
std.debug.print("{d:^5}\n", .{42});     // " 42  " (center)
std.debug.print("{d:0>5}\n", .{42});    // "00042" (zero-pad)
std.debug.print("{d:=>5}\n", .{42});    // "===42" (custom fill)
```

## Integer Parsing

### parseInt

Parse signed or unsigned integers with optional base detection.

```zig
const std = @import("std");

// Explicit base
const a = try std.fmt.parseInt(i32, "-123", 10);    // -123
const b = try std.fmt.parseInt(u32, "ff", 16);      // 255
const c = try std.fmt.parseInt(u8, "101", 2);       // 5

// Auto-detect base (base = 0)
const d = try std.fmt.parseInt(i32, "0x1f", 0);     // 31  (hex)
const e = try std.fmt.parseInt(i32, "0b101", 0);    // 5   (binary)
const f = try std.fmt.parseInt(i32, "0o17", 0);     // 15  (octal)
const g = try std.fmt.parseInt(i32, "42", 0);       // 42  (decimal)

// Underscores allowed between digits
const h = try std.fmt.parseInt(u32, "1_000_000", 10);  // 1000000
const i = try std.fmt.parseInt(u32, "0xff_ff", 0);     // 65535
```

**Errors:**
- `error.InvalidCharacter` - Invalid digit for base, leading/trailing underscore, empty string
- `error.Overflow` - Result doesn't fit in type

### parseUnsigned

Parse unsigned integers only (rejects `+` and `-` signs).

```zig
const a = try std.fmt.parseUnsigned(u16, "65535", 10);  // 65535
const b = try std.fmt.parseUnsigned(u8, "ff", 16);      // 255

// These return error.InvalidCharacter:
// std.fmt.parseUnsigned(u8, "+10", 10)
// std.fmt.parseUnsigned(u8, "-10", 10)
```

### parseIntSizeSuffix

Parse integers with SI size suffixes (K, M, G, T, P, E, Z, Y, R, Q).

```zig
const std = @import("std");

const a = try std.fmt.parseIntSizeSuffix("2", 10);      // 2
const b = try std.fmt.parseIntSizeSuffix("2B", 10);     // 2
const c = try std.fmt.parseIntSizeSuffix("2k", 10);     // 2000
const d = try std.fmt.parseIntSizeSuffix("2kB", 10);    // 2000
const e = try std.fmt.parseIntSizeSuffix("2Ki", 10);    // 2048  (binary)
const f = try std.fmt.parseIntSizeSuffix("2KiB", 10);   // 2048  (binary)
const g = try std.fmt.parseIntSizeSuffix("1M", 10);     // 1000000
const h = try std.fmt.parseIntSizeSuffix("1Mi", 10);    // 1048576
const i = try std.fmt.parseIntSizeSuffix("aKiB", 16);   // 10240 (hex base)
```

### charToDigit / digitToChar

Convert between characters and digit values.

```zig
const d = try std.fmt.charToDigit('a', 16);  // 10
const c = std.fmt.digitToChar(10, .lower);   // 'a'
const C = std.fmt.digitToChar(10, .upper);   // 'A'
```

## Float Parsing

### parseFloat

Parse floating-point numbers from strings.

```zig
const std = @import("std");

// Decimal notation
const a = try std.fmt.parseFloat(f64, "3.14159");      // 3.14159
const b = try std.fmt.parseFloat(f32, "-123.456");     // -123.456
const c = try std.fmt.parseFloat(f64, "1e10");         // 1e10
const d = try std.fmt.parseFloat(f64, "1.5e-3");       // 0.0015
const e = try std.fmt.parseFloat(f64, "+0");           // 0.0
const f = try std.fmt.parseFloat(f64, "-0");           // -0.0

// Hexadecimal notation
const g = try std.fmt.parseFloat(f64, "0x1p0");        // 1.0
const h = try std.fmt.parseFloat(f64, "0x1.8p1");      // 3.0
const i = try std.fmt.parseFloat(f32, "-0x1p-1");      // -0.5

// Special values
const nan = try std.fmt.parseFloat(f64, "nan");        // NaN
const inf = try std.fmt.parseFloat(f64, "inf");        // +Inf
const ninf = try std.fmt.parseFloat(f64, "-inf");      // -Inf

// Underscores allowed between digits
const j = try std.fmt.parseFloat(f64, "1_234.567_8");  // 1234.5678
```

**Supported types:** `f16`, `f32`, `f64`, `f80`, `f128`

**Errors:**
- `error.InvalidCharacter` - Invalid format, empty string, invalid underscore placement

## Hex Encoding/Decoding

### bytesToHex

Convert bytes to hexadecimal string.

```zig
const input = "hello";
const hex_lower = std.fmt.bytesToHex(input, .lower);  // "68656c6c6f"
const hex_upper = std.fmt.bytesToHex(input, .upper);  // "68656C6C6F"
```

### hexToBytes

Decode hexadecimal string to bytes.

```zig
var buf: [32]u8 = undefined;
const decoded = try std.fmt.hexToBytes(&buf, "48656c6c6f");  // "Hello"
```

**Errors:**
- `error.InvalidCharacter` - Non-hex character
- `error.InvalidLength` - Odd number of hex digits
- `error.NoSpaceLeft` - Output buffer too small

### hex

Convert unsigned integer to little-endian hex bytes.

```zig
const h = std.fmt.hex(@as(u32, 0xdeadbeef));  // "efbeadde"
```

## Buffer Printing

### bufPrint

Format into a fixed buffer, returns slice of written data.

```zig
var buf: [256]u8 = undefined;
const result = try std.fmt.bufPrint(&buf, "Hello {s}!", .{"world"});
// result = "Hello world!"
```

**Errors:**
- `error.NoSpaceLeft` - Buffer too small

### bufPrintZ

Format into buffer with null terminator.

```zig
var buf: [256]u8 = undefined;
const result = try std.fmt.bufPrintZ(&buf, "Hello {s}!", .{"world"});
// result is [:0]u8 = "Hello world!" (null-terminated)
```

### count

Count characters needed for format (without allocating).

```zig
const len = std.fmt.count("Value: {d}, Name: {s}", .{ 42, "test" });
// len = 21
```

## Allocating Print

### allocPrint

Format with dynamic allocation.

```zig
const allocator = std.heap.page_allocator;
const result = try std.fmt.allocPrint(allocator, "Hello {s}!", .{"world"});
defer allocator.free(result);
// result = "Hello world!"
```

### allocPrintSentinel

Format with allocation and sentinel terminator.

```zig
const result = try std.fmt.allocPrintSentinel(allocator, "Hello {s}", .{"world"}, 0);
defer allocator.free(result);
// result is [:0]u8 = "Hello world" (null-terminated)
```

## Comptime Print

### comptimePrint

Format at compile time, returns pointer to comptime-known string.

```zig
const msg = comptime std.fmt.comptimePrint("Value: {d}", .{100});
// msg: *const [10:0]u8 = "Value: 100"
```

## Custom Formatters

### Using `{f}` Specifier (0.15.x)

Types with a `format` method use `{f}`:

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

### Alt (Formatter Wrapper)

Create a type that wraps data with a custom format function.

```zig
const std = @import("std");

fn formatReversed(data: []const u8, writer: *std.io.Writer) std.io.Writer.Error!void {
    var i = data.len;
    while (i > 0) {
        i -= 1;
        try writer.writeByte(data[i]);
    }
}

const Reversed = std.fmt.Alt([]const u8, formatReversed);

pub fn main() !void {
    const rev = Reversed{ .data = "hello" };
    std.debug.print("{f}\n", .{rev});  // "olleh"
}
```

### alt Helper

Call alternate format methods by name.

```zig
const Example = struct {
    number: u8,

    pub fn asHex(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print("0x{x:0>2}", .{self.number});
    }
};

const ex = Example{ .number = 42 };
std.debug.print("{f}\n", .{std.fmt.alt(ex, .asHex)});  // "0x2a"
```

## Format String Parser

For implementing custom formatters compatible with std.fmt.

### Parser

Stream-based parser for format strings.

```zig
const std = @import("std");

var parser: std.fmt.Parser = .{ .bytes = "hello:world", .i = 0 };

// Parse until delimiter
const before = parser.until(':');  // "hello"

// Consume delimiter
_ = parser.char();  // ':'

// Check for character
if (parser.maybe('w')) {
    // consumed 'w'
}

// Parse number
parser = .{ .bytes = "42abc", .i = 0 };
const num = parser.number();  // 42

// Peek without consuming
const next = parser.peek(0);  // 'a'
```

### Placeholder

Parse format placeholder syntax.

```zig
const ph = std.fmt.Placeholder.parse("0d:0>8.2");
// ph.arg = .{ .number = 0 }
// ph.specifier_arg = "d"
// ph.fill = '0'
// ph.alignment = .right
// ph.width = .{ .number = 8 }
// ph.precision = .{ .number = 2 }
```

### Specifier

Argument reference in format string.

```zig
const Specifier = union(enum) {
    none,              // {} - auto-increment
    number: usize,     // {0} - positional
    named: []const u8, // {name} - named
};
```

## Utility Functions

### digits2

Fast conversion of 0-99 to two-digit string.

```zig
const d = std.fmt.digits2(42);  // "42"
const z = std.fmt.digits2(7);   // "07"
```

### printInt

Print integer to buffer, returns end index.

```zig
var buf: [32]u8 = undefined;
const end = std.fmt.printInt(&buf, @as(i32, -42), 10, .lower, .{});
const result = buf[0..end];  // "-42"
```

## Types

### Options

Formatting options for numbers.

```zig
const Options = struct {
    precision: ?usize = null,
    width: ?usize = null,
    alignment: Alignment = .right,
    fill: u8 = ' ',
};
```

### Number

Extended options for numeric formatting.

```zig
const Number = struct {
    mode: Mode = .decimal,    // .decimal, .binary, .octal, .hex, .scientific
    case: Case = .lower,      // .lower, .upper
    precision: ?usize = null,
    width: ?usize = null,
    alignment: Alignment = .right,
    fill: u8 = ' ',
};
```

### Alignment

```zig
const Alignment = enum { left, center, right };
```

### Case

```zig
const Case = enum { lower, upper };
```

## Error Types

```zig
const ParseIntError = error{ Overflow, InvalidCharacter };
const ParseFloatError = error{ InvalidCharacter };
const BufPrintError = error{ NoSpaceLeft };
```

## Constants

```zig
const default_max_depth = 3;        // Default recursion depth for {any}
const hex_charset = "0123456789abcdef";
```
