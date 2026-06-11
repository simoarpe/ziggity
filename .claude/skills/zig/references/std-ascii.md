# std.ascii

7-bit ASCII character classification and manipulation. For Unicode handling, use `std.unicode`.

## Character Classification

```zig
const std = @import("std");
const ascii = std.ascii;

// Character type checks (all return bool)
ascii.isAlphanumeric('a')    // A-Z, a-z, 0-9
ascii.isAlphabetic('a')      // A-Z, a-z
ascii.isDigit('5')           // 0-9
ascii.isHex('F')             // A-F, a-f, 0-9
ascii.isUpper('A')           // A-Z
ascii.isLower('a')           // a-z
ascii.isWhitespace(' ')      // space, \t, \n, \r, \v, \f
ascii.isPrint('!')           // printable (not control)
ascii.isControl('\n')        // control characters (0x00-0x1F, 0x7F)
ascii.isAscii(c)             // c < 128
```

## Case Conversion

```zig
// Single character
ascii.toUpper('a')  // 'A'
ascii.toLower('A')  // 'a'

// Strings - to buffer
var buf: [100]u8 = undefined;
const lower = ascii.lowerString(&buf, "HeLLo");  // "hello"
const upper = ascii.upperString(&buf, "HeLLo");  // "HELLO"

// Strings - allocating
const lower = try ascii.allocLowerString(allocator, "HeLLo");
defer allocator.free(lower);  // "hello"

const upper = try ascii.allocUpperString(allocator, "HeLLo");
defer allocator.free(upper);  // "HELLO"
```

## Case-Insensitive Comparison

```zig
// Equality
ascii.eqlIgnoreCase("Hello", "HELLO")  // true

// Prefix/suffix
ascii.startsWithIgnoreCase("Hello World", "hello")  // true
ascii.endsWithIgnoreCase("Hello World", "WORLD")    // true

// Search
ascii.indexOfIgnoreCase("Hello World", "world")     // ?usize = 6

// Lexicographical order
ascii.orderIgnoreCase("abc", "ABC")       // .eq
ascii.lessThanIgnoreCase("abc", "abd")    // true
```

## Constants

```zig
// Character sets (as strings)
ascii.lowercase  // "abcdefghijklmnopqrstuvwxyz"
ascii.uppercase  // "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
ascii.letters    // lowercase ++ uppercase

// Whitespace array (for use with std.mem.trim)
ascii.whitespace  // [_]u8{ ' ', '\t', '\n', '\r', '\v', '\f' }
```

## Control Codes

```zig
const cc = std.ascii.control_code;

// Common control codes
cc.nul   // 0x00  Null
cc.bel   // 0x07  Bell
cc.bs    // 0x08  Backspace
cc.ht    // 0x09  Horizontal Tab (\t)
cc.lf    // 0x0A  Line Feed (\n)
cc.vt    // 0x0B  Vertical Tab
cc.ff    // 0x0C  Form Feed
cc.cr    // 0x0D  Carriage Return (\r)
cc.esc   // 0x1B  Escape
cc.del   // 0x7F  Delete

// Flow control
cc.xon   // 0x11  XON (alias for dc1)
cc.xoff  // 0x13  XOFF (alias for dc3)
```

## Hex Escape Formatting

Format bytes with non-printable characters escaped:

```zig
const data = "hello\xffworld";

// Format with hex escapes for non-printable bytes
try stdout.print("{f}\n", .{ascii.hexEscape(data, .lower)});
// Output: hello\xffworld

try stdout.print("{f}\n", .{ascii.hexEscape(data, .upper)});
// Output: hello\xFFworld
```

## Common Patterns

### Trim whitespace
```zig
const trimmed = std.mem.trim(u8, "  hello  ", &ascii.whitespace);
// "hello"
```

### Validate ASCII string
```zig
fn isAsciiString(s: []const u8) bool {
    for (s) |c| {
        if (!ascii.isAscii(c)) return false;
    }
    return true;
}
```

### Case-insensitive map lookup
```zig
// Use ascii.lowerString to normalize keys
var buf: [64]u8 = undefined;
const normalized = ascii.lowerString(&buf, user_input);
if (map.get(normalized)) |value| {
    // found
}
```

## Notes

- All functions handle bytes > 127 gracefully (return `false` for classification)
- Functions use `u8` not `u7` for convenience
- For Unicode text, use `std.unicode` instead
- `lowerString`/`upperString` assert output buffer is large enough
