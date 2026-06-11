# std.mem

Memory manipulation utilities: slice operations, searching, splitting, alignment, endianness, and byte conversion.

## Slice Comparison & Search

```zig
// Equality
std.mem.eql(u8, "hello", "hello")  // true
std.mem.order(u8, "abc", "abd")    // .lt

// Find substring/element
std.mem.indexOf(u8, "hello world", "wor")       // ?usize = 6
std.mem.lastIndexOf(u8, "ababa", "ab")          // ?usize = 2
std.mem.indexOfScalar(u8, "hello", 'l')         // ?usize = 2
std.mem.lastIndexOfScalar(u8, "hello", 'l')     // ?usize = 3

// Find any/none of characters
std.mem.indexOfAny(u8, "hello", "aeiou")        // ?usize = 1 (first vowel)
std.mem.indexOfNone(u8, "   hello", " ")        // ?usize = 3 (first non-space)

// Check prefix/suffix
std.mem.startsWith(u8, "hello", "hel")          // true
std.mem.endsWith(u8, "hello.txt", ".txt")       // true

// Count occurrences
std.mem.count(u8, "ababa", "ab")                // 2
std.mem.containsAtLeast(u8, "ababa", 2, "ab")   // true
```

## Tokenize vs Split

**Tokenize**: Skip empty tokens (like shell word splitting)
```zig
var it = std.mem.tokenizeAny(u8, "  hello   world  ", " ");
while (it.next()) |token| {
    // "hello", "world"
}

// Other tokenize variants
std.mem.tokenizeScalar(u8, "a,b,c", ',');       // single delimiter
std.mem.tokenizeSequence(u8, "a::b::c", "::");  // exact sequence
```

**Split**: Preserve empty tokens
```zig
var it = std.mem.splitScalar(u8, "a,,b", ',');
while (it.next()) |part| {
    // "a", "", "b"
}

// Other split variants
std.mem.splitAny(u8, "a,b;c", ",;");            // any of delimiters
std.mem.splitSequence(u8, "a::b::c", "::");     // exact sequence

// Split backwards
var it = std.mem.splitBackwardsScalar(u8, "a/b/c", '/');
// "c", "b", "a"
```

## Window Iterator

Sliding window over slice:
```zig
var it = std.mem.window(u8, "hello", 3, 1);  // size=3, advance=1
while (it.next()) |w| {
    // "hel", "ell", "llo"
}
```

## Join & Concat

```zig
const allocator = std.heap.page_allocator;

// Join with separator
const joined = try std.mem.join(allocator, ", ", &.{ "a", "b", "c" });
defer allocator.free(joined);  // "a, b, c"

// Join with null terminator
const joinedZ = try std.mem.joinZ(allocator, "/", &.{ "path", "to", "file" });
// [:0]u8 = "path/to/file"

// Concatenate without separator
const concatted = try std.mem.concat(allocator, u8, &.{ "hello", " ", "world" });
// "hello world"
```

## Trim

```zig
std.mem.trim(u8, "  hello  ", " ")       // "hello"
std.mem.trimStart(u8, "  hello", " ")    // "hello" (left only)
std.mem.trimEnd(u8, "hello  ", " ")      // "hello" (right only)

// Trim multiple characters
std.mem.trim(u8, "\n\thello\n\t", " \t\n")
```

## Replace

```zig
// In-place replace (returns count)
var buf: [100]u8 = undefined;
const count = std.mem.replace(u8, "hello", "l", "L", &buf);
// buf contains "heLLo", count = 2

// Allocate new slice
const result = try std.mem.replaceOwned(u8, allocator, "hello", "l", "L");
defer allocator.free(result);  // "heLLo"

// Replace single scalar
var data = [_]u8{ 'a', 'b', 'a' };
std.mem.replaceScalar(u8, &data, 'a', 'x');  // "xbx"

// Calculate replacement size first
const size = std.mem.replacementSize(u8, "hello", "l", "LL");  // 7
```

## Byte Conversion

```zig
// Value to bytes
const val: u32 = 0xDEADBEEF;
const bytes = std.mem.asBytes(&val);      // *const [4]u8
const byte_copy = std.mem.toBytes(val);   // [4]u8 (copy)

// Bytes to value
const bytes = [_]u8{ 0xEF, 0xBE, 0xAD, 0xDE };
const ptr = std.mem.bytesAsValue(u32, &bytes);  // *const u32
const val = std.mem.bytesToValue(u32, &bytes);  // u32 (copy)

// Slice conversions
const u16_slice = [_]u16{ 0x0102, 0x0304 };
const u8_slice = std.mem.sliceAsBytes(&u16_slice);  // []const u8

const u8_data = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 };
const u16_view = std.mem.bytesAsSlice(u16, &u8_data);  // []const u16
```

## Alignment

```zig
// Align forward (round up)
std.mem.alignForward(usize, 7, 4)     // 8
std.mem.alignForward(usize, 8, 4)     // 8
std.mem.alignForward(usize, 9, 4)     // 12

// Align backward (round down)
std.mem.alignBackward(usize, 7, 4)    // 4
std.mem.alignBackward(usize, 8, 4)    // 8

// Check alignment
std.mem.isAligned(8, 4)               // true
std.mem.isAligned(7, 4)               // false
std.mem.isValidAlign(4)               // true (power of 2)
std.mem.isValidAlign(3)               // false

// Align pointer
const ptr: [*]u8 = @ptrFromInt(0x123);
const aligned = std.mem.alignPointer(ptr, 0x100);  // ?[*]u8 = 0x200

// Find aligned slice within bytes
const aligned_slice = std.mem.alignInBytes(bytes, 16);  // ?[]align(16) u8
```

## Alignment Type

```zig
const align_val: std.mem.Alignment = .@"16";  // 16-byte alignment
const bytes = align_val.toByteUnits();        // 16

// From byte units
const a = std.mem.Alignment.fromByteUnits(8); // .@"8"

// From type
const a = std.mem.Alignment.of(u64);          // .@"8"

// Forward/backward with Alignment
const addr = align_val.forward(0x123);        // next aligned address
const addr = align_val.backward(0x123);       // previous aligned address
const ok = align_val.check(0x100);            // true if aligned
```

## Endianness Conversion

```zig
// To/from native endianness
const native = std.mem.littleToNative(u32, 0x12345678);
const native = std.mem.bigToNative(u32, 0x12345678);
const little = std.mem.nativeToLittle(u32, native_val);
const big = std.mem.nativeToBig(u32, native_val);

// General conversion
const val = std.mem.toNative(u32, x, .little);     // from little to native
const val = std.mem.nativeTo(u32, x, .big);        // from native to big

// Byte swap all fields in struct
std.mem.byteSwapAllFields(MyStruct, &my_struct);

// Byte swap all elements in slice
std.mem.byteSwapAllElements(u32, slice);
```

## Packed Integer Read/Write

Read/write integers at bit offsets:
```zig
var bytes = [_]u8{ 0, 0, 0, 0 };

// Write u12 at bit offset 4
std.mem.writePackedInt(u12, &bytes, 4, 0xABC, .little);

// Read it back
const val = std.mem.readPackedInt(u12, &bytes, 4, .little);

// Variable-width read/write
std.mem.writeVarPackedInt(&bytes, bit_offset, bit_count, value, .little);
const val = std.mem.readVarPackedInt(u32, &bytes, bit_offset, bit_count, .little, .unsigned);
```

## Zero Initialization

```zig
// Zero-initialize a type
const zeroed: MyStruct = std.mem.zeroes(MyStruct);
// All numeric fields = 0, optionals = null, slices = empty

// Partial initialization with zeros for rest
const partial = std.mem.zeroInit(MyStruct, .{
    .name = "foo",      // explicit value
    // other fields zeroed
});
```

## Min/Max

```zig
const slice = [_]i32{ 3, 1, 4, 1, 5 };

std.mem.min(i32, &slice)          // 1
std.mem.max(i32, &slice)          // 5
std.mem.minMax(i32, &slice)       // .{ 1, 5 }

std.mem.indexOfMin(i32, &slice)   // 1
std.mem.indexOfMax(i32, &slice)   // 4
std.mem.indexOfMinMax(i32, &slice) // .{ 1, 4 }
```

## Reverse & Rotate

```zig
var arr = [_]u8{ 1, 2, 3, 4, 5 };

std.mem.reverse(u8, &arr);        // [5, 4, 3, 2, 1]
std.mem.rotate(u8, &arr, 2);      // rotate left by 2

// Swap two values
std.mem.swap(u32, &a, &b);

// Reverse iterator (no mutation)
var it = std.mem.reverseIterator(&arr);
while (it.next()) |val| {
    // 5, 4, 3, 2, 1
}
```

## Other Utilities

```zig
// All elements equal to value
std.mem.allEqual(u8, slice, 0)    // true if all zeros

// Sentinel-terminated length
const len = std.mem.len(c_string);  // length of null-terminated string

// Span from sentinel pointer (convert [*:0]T to []T)
const slice = std.mem.span(c_string);

// Index of first difference
std.mem.indexOfDiff(u8, "hello", "helps")  // ?usize = 3

// Collapse repeated elements
var data = "aabbcc".*;
const len = std.mem.collapseRepeatsLen(u8, &data, 'a');  // "abbcc", 5
```

## Benchmark Utility

```zig
// Prevent compiler from optimizing away a value
std.mem.doNotOptimizeAway(result);
```
