# std.unicode

Unicode encoding/decoding for UTF-8, UTF-16, and WTF-8/WTF-16. For ASCII-only operations, use `std.ascii`.

## Quick Reference

| Task | Function |
|------|----------|
| Validate UTF-8 | `utf8ValidateSlice(s)` |
| Count codepoints | `utf8CountCodepoints(s)` |
| Iterate codepoints | `Utf8View.init(s)` then `.iterator()` |
| UTF-8 ↔ UTF-16 | `utf8ToUtf16LeAlloc`, `utf16LeToUtf8Alloc` |
| Encode codepoint | `utf8Encode(codepoint, buf)` |

## UTF-8 Validation

```zig
const std = @import("std");
const unicode = std.unicode;

// Check if string is valid UTF-8
if (unicode.utf8ValidateSlice(input)) {
    // valid UTF-8
}

// Count codepoints (not bytes)
const count = try unicode.utf8CountCodepoints("héllo");  // 5

// Check if codepoint is valid
unicode.utf8ValidCodepoint('é')       // true
unicode.utf8ValidCodepoint(0xD800)    // false (surrogate)
unicode.utf8ValidCodepoint(0x110000)  // false (too large)
```

## Iterating Codepoints

```zig
// Create validated view
const view = try unicode.Utf8View.init("héllo 世界");
var it = view.iterator();

while (it.nextCodepoint()) |codepoint| {
    // codepoint is u21: 'h', 'é', 'l', 'l', 'o', ' ', '世', '界'
}

// Or get UTF-8 slices
var it2 = view.iterator();
while (it2.nextCodepointSlice()) |slice| {
    // slice is []const u8: "h", "é", "l", "l", "o", " ", "世", "界"
}

// Peek ahead without advancing
const next3 = it.peek(3);  // next 3 codepoints as UTF-8 bytes

// Comptime-validated view
const view = unicode.Utf8View.initComptime("hello");

// Unchecked (when you know it's valid)
const view = unicode.Utf8View.initUnchecked(trusted_utf8);
```

## Encoding/Decoding Codepoints

```zig
// Encode codepoint to UTF-8
var buf: [4]u8 = undefined;
const len = try unicode.utf8Encode('é', &buf);  // len = 2
// buf[0..len] contains UTF-8 bytes

// Comptime encoding (returns fixed-size array)
const bytes = unicode.utf8EncodeComptime('世');  // [3]u8

// Get UTF-8 sequence length for a codepoint
const len = try unicode.utf8CodepointSequenceLength('世');  // 3

// Get sequence length from first byte
const len = try unicode.utf8ByteSequenceLength(0xE4);  // 3 (for 3-byte sequence)
```

## UTF-8 ↔ UTF-16 Conversion

### UTF-8 to UTF-16LE (Allocating)

```zig
// Returns []u16
const utf16 = try unicode.utf8ToUtf16LeAlloc(allocator, "hello 世界");
defer allocator.free(utf16);

// Returns [:0]u16 (null-terminated, for Windows APIs)
const utf16z = try unicode.utf8ToUtf16LeAllocZ(allocator, "hello");
defer allocator.free(utf16z);
```

### UTF-16LE to UTF-8 (Allocating)

```zig
// Returns []u8
const utf8 = try unicode.utf16LeToUtf8Alloc(allocator, utf16_data);
defer allocator.free(utf8);

// Returns [:0]u8 (null-terminated)
const utf8z = try unicode.utf16LeToUtf8AllocZ(allocator, utf16_data);
defer allocator.free(utf8z);
```

### Non-Allocating Conversion

```zig
// UTF-8 to UTF-16LE (caller provides buffer)
var utf16_buf: [128]u16 = undefined;
const len = try unicode.utf8ToUtf16Le(&utf16_buf, "hello");
const utf16 = utf16_buf[0..len];

// UTF-16LE to UTF-8 (caller provides buffer)
var utf8_buf: [256]u8 = undefined;
const len = try unicode.utf16LeToUtf8(&utf8_buf, utf16_data);
const utf8 = utf8_buf[0..len];
```

### ArrayList Conversion

```zig
var list = std.ArrayList(u16).empty;
defer list.deinit(allocator);
try unicode.utf8ToUtf16LeArrayList(&list, "hello");

var list8 = std.ArrayList(u8).empty;
defer list8.deinit(allocator);
try unicode.utf16LeToUtf8ArrayList(&list8, utf16_data);
```

### Comptime String Literals

```zig
// Convert UTF-8 literal to UTF-16LE at comptime
const utf16 = unicode.utf8ToUtf16LeStringLiteral("hello");
// Type: *const [5:0]u16 (null-terminated)

// Calculate UTF-16 length
const len = try unicode.calcUtf16LeLen("hello 世界");  // 8 (code units)
```

## UTF-16 Utilities

```zig
// Check surrogate code units
unicode.utf16IsHighSurrogate(0xD800)  // true (0xD800-0xDBFF)
unicode.utf16IsLowSurrogate(0xDC00)   // true (0xDC00-0xDFFF)

// Decode surrogate pair
const codepoint = try unicode.utf16DecodeSurrogatePair(&[_]u16{ 0xD801, 0xDC37 });
// codepoint = 0x10437

// UTF-16 sequence length for codepoint
const len = try unicode.utf16CodepointSequenceLength(0x10000);  // 2

// Iterate UTF-16LE
var it = unicode.Utf16LeIterator.init(utf16_slice);
while (try it.nextCodepoint()) |cp| {
    // cp is u21
}
```

## WTF-8/WTF-16 (Windows Encoding)

WTF-8 is like UTF-8 but allows unpaired surrogates (for Windows compatibility).

```zig
// Validate WTF-8 (allows surrogates)
unicode.wtf8ValidateSlice(data)  // bool

// WTF-8 iteration
const view = try unicode.Wtf8View.init(wtf8_data);
var it = view.iterator();
while (it.nextCodepoint()) |cp| {
    // cp might be a surrogate codepoint
}

// WTF-8 ↔ WTF-16 conversion
const wtf8 = try unicode.wtf16LeToWtf8Alloc(allocator, wtf16_data);
const wtf16 = try unicode.wtf8ToWtf16LeAlloc(allocator, wtf8_data);

// Convert WTF-8 to UTF-8 (lossy - replaces surrogates with U+FFFD)
const utf8 = try unicode.wtf8ToUtf8LossyAlloc(allocator, wtf8_data);

// In-place lossy conversion
try unicode.wtf8ToUtf8Lossy(buffer, wtf8_data);
```

## Formatting

```zig
// Format potentially ill-formed UTF-8 (replaces invalid sequences with U+FFFD)
try stdout.print("{f}", .{unicode.fmtUtf8(possibly_invalid_utf8)});

// Format UTF-16LE as UTF-8 (replaces unpaired surrogates with U+FFFD)
try stdout.print("{f}", .{unicode.fmtUtf16Le(utf16_data)});
```

## Constants

```zig
unicode.replacement_character       // U+FFFD (u21)
unicode.replacement_character_utf8  // [3]u8 for U+FFFD
```

## Common Patterns

### Safe string processing
```zig
fn processText(input: []const u8) !void {
    if (!unicode.utf8ValidateSlice(input)) {
        return error.InvalidUtf8;
    }
    const view = unicode.Utf8View.initUnchecked(input);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // process each codepoint
    }
}
```

### Windows API interop
```zig
fn callWindowsApi(path: []const u8) !void {
    const wide = try unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    // wide is [:0]u16, ready for Windows API
    windows.CreateFileW(wide.ptr, ...);
}
```

### Grapheme-aware truncation
```zig
fn truncateCodepoints(s: []const u8, max_codepoints: usize) ![]const u8 {
    const view = try unicode.Utf8View.init(s);
    var it = view.iterator();
    var count: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (count >= max_codepoints) break;
        end = it.i;
        count += 1;
    }
    return s[0..end];
}
```

## Error Types

| Error | Meaning |
|-------|---------|
| `InvalidUtf8` | Input is not valid UTF-8 |
| `InvalidWtf8` | Input is not valid WTF-8 |
| `Utf8InvalidStartByte` | Invalid first byte in sequence |
| `Utf8ExpectedContinuation` | Missing continuation byte |
| `Utf8OverlongEncoding` | Overlong encoding detected |
| `Utf8EncodesSurrogateHalf` | Surrogate in UTF-8 (use WTF-8) |
| `CodepointTooLarge` | Codepoint > 0x10FFFF |

## Notes

- UTF-8 uses 1-4 bytes per codepoint
- UTF-16 uses 1-2 code units (2-4 bytes) per codepoint
- Surrogates (U+D800-U+DFFF) are invalid in UTF-8 but valid in WTF-8
- Use `fmtUtf8`/`fmtUtf16Le` for safe display of potentially invalid data
- Windows uses UTF-16LE (little-endian) for wide strings
