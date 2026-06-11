# std.io - I/O API Reference (0.15.x)

New buffered I/O API introduced in Zig 0.15.x ("Writergate"). Non-generic, buffer-integrated Reader and Writer interfaces.

## Table of Contents
- [Critical Migration](#critical-migration)
- [std.io.Writer](#stdiowriter)
- [std.io.Reader](#stdioreader)
- [File I/O Integration](#file-io-integration)
- [Common Patterns](#common-patterns)
- [Specialized Writers](#specialized-writers)
- [Specialized Readers](#specialized-readers)

## Critical Migration

### Old API (DEPRECATED)
```zig
// WRONG - deprecated generic writers
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello\n", .{});

// WRONG - deprecated types
var bw = std.io.bufferedWriter(file.writer());
```

### New API (0.15.x)
```zig
// CORRECT - new buffer-integrated writer
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;
try stdout.print("Hello\n", .{});
try stdout.flush();  // REQUIRED!
```

**Removed Types**: `BufferedWriter`, `CountingWriter`, `GenericWriter`, `AnyWriter`, `GenericReader`, `AnyReader`, `FixedBufferStream`

## std.io.Writer

### Structure
```zig
const Writer = struct {
    vtable: *const VTable,
    buffer: []u8,      // Write buffer (can be zero-length for unbuffered)
    end: usize = 0,    // Bytes buffered (0..buffer.len)
};
```

### Core Methods

#### Writing Data
```zig
// Write all bytes (may call drain multiple times)
try w.writeAll("hello");

// Write single byte
try w.writeByte('\n');

// Write with potential short write (returns bytes written)
const n = try w.write(data);

// Write vector of slices
var vecs: [2][]const u8 = .{ "hello", "world" };
try w.writeVecAll(&vecs);

// Write same byte N times
try w.splatByteAll(' ', 10);

// Write same slice N times
try w.splatBytesAll("na", 8);  // "nananananananana"
```

#### Formatted Output
```zig
// Format string (same syntax as before)
try w.print("Value: {d}, Name: {s}\n", .{ 42, "test" });

// Format specifiers:
// {d}  - decimal integer
// {x}  - hex lowercase
// {X}  - hex uppercase
// {s}  - string
// {c}  - ASCII character
// {b}  - binary
// {o}  - octal
// {e}  - scientific notation
// {f}  - call .format() method on type  // NEW in 0.15.x
// {any} - debug format
// {?}  - optional
// {!}  - error union
// {*}  - pointer address
```

#### Binary Data
```zig
// Write integer with endianness
try w.writeInt(u32, value, .big);
try w.writeInt(i16, value, .little);

// Write struct (extern or packed only)
const Header = extern struct { magic: u32, version: u16 };
try w.writeStruct(header, .little);

// Write slice with endianness
try w.writeSliceEndian(u32, values, .big);
```

#### Buffer Management
```zig
// Flush buffer to underlying sink
try w.flush();

// Get buffered data not yet flushed
const pending = w.buffered();

// Get writable slice for direct writes
const dest = try w.writableSlice(len);
@memcpy(dest, src);

// Advance after writing to writableSliceGreedy
const dest = try w.writableSliceGreedy(min_len);
// ... write to dest ...
w.advance(bytes_written);

// Get unused capacity
const remaining = w.unusedCapacitySlice();
```

### Fixed Buffer Writer
```zig
// Write to fixed buffer, error when full
var buf: [256]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try w.print("Hello {s}\n", .{"world"});
const result = w.buffered();  // Get written data
```

### Discarding Writer
```zig
// Discard all output (useful for counting bytes written)
var buffer: [256]u8 = undefined;
var discard: std.Io.Writer.Discarding = .init(&buffer);
try discard.writer.print("test {d}", .{42});
// Output discarded, but count tracked
const bytes_written = discard.fullCount();  // includes buffered data
```

### Allocating Writer
```zig
// Automatically grows buffer
var aw: std.Io.Writer.Allocating = .init(allocator);
defer aw.deinit();

try aw.writer.print("Hello {s}\n", .{"world"});
const result = aw.writer.buffered();  // Get all written data

// Or take ownership
const owned = try aw.toOwnedSlice();
defer allocator.free(owned);
```

## std.io.Reader

### Structure
```zig
const Reader = struct {
    vtable: *const VTable,
    buffer: []u8,       // Read buffer
    seek: usize,        // Consumed position
    end: usize,         // Buffered data end
};
```

### Core Methods

#### Reading Bytes
```zig
// Read single byte
const byte = try r.takeByte();
const signed = try r.takeByteSigned();

// Peek without consuming
const byte = try r.peekByte();

// Read exact amount
const data = try r.take(n);      // Returns slice
const arr = try r.takeArray(n);  // Returns *[n]u8

// Read into provided buffer
try r.readSliceAll(buffer);

// Read up to buffer.len (short read OK)
const n = try r.readSliceShort(buffer);
```

#### Line/Delimiter Reading
```zig
// Read until delimiter (RECOMMENDED for line reading)
// - Consumes delimiter, returns content without it
// - Returns null at EOF (no EndOfStream error)
while (try r.takeDelimiter('\n')) |line| {
    // process line (doesn't include '\n')
}
// Loop ends when takeDelimiter returns null (EOF)

// Read until delimiter, exclude delimiter (doesn't consume delimiter!)
const line = try r.takeDelimiterExclusive('\n');
// If delimiter not found: error.EndOfStream at EOF, error.StreamTooLong if buffer full

// Read until delimiter, include delimiter (doesn't consume!)
const line_with_delim = try r.takeDelimiterInclusive('\n');

// Read null-terminated string (consumes null)
const str = try r.takeSentinel(0);

// Discard until delimiter (inclusive consumes delimiter)
try r.discardDelimiterInclusive('\n');
const n = try r.discardDelimiterExclusive('\n');  // doesn't consume delimiter
```

#### Binary Data
```zig
// Read integer with endianness
const val = try r.takeInt(u32, .big);
const val = try r.takeInt(i16, .little);

// Read variable-size integer
const val = try r.takeVarInt(u64, .big, byte_count);

// Read struct (extern or packed only)
const header = try r.takeStruct(Header, .little);

// Read enum
const e = try r.takeEnum(MyEnum, .little);

// Read LEB128 encoded integer
const val = try r.takeLeb128(i64);
```

#### Streaming
```zig
// Stream to writer
const n = try r.stream(writer, .limited(1024));
const n = try r.stream(writer, .unlimited);

// Stream exact amount
try r.streamExact(writer, exact_bytes);

// Stream until delimiter
const n = try r.streamDelimiter(writer, '\n');

// Stream remaining (until EOF)
const total = try r.streamRemaining(writer);
```

#### Buffer Management
```zig
// Get buffered data
const pending = r.buffered();
const len = r.bufferedLen();

// Fill buffer with at least n bytes
try r.fill(n);

// Consume buffered bytes without reading
r.toss(n);
r.tossBuffered();  // Consume all buffered

// Discard bytes (may read more)
try r.discardAll(n);
const n = try r.discardShort(max);
const total = try r.discardRemaining();
```

#### Allocation
```zig
// Read remaining into allocated slice
const data = try r.allocRemaining(allocator, .limited(max_size));
defer allocator.free(data);

// Append remaining to ArrayList
var list: std.ArrayList(u8) = .empty;
try r.appendRemaining(allocator, &list, .limited(max_size));
```

### Fixed Reader (from buffer)
```zig
// Read from existing buffer
var r: std.Io.Reader = .fixed("hello world");
const word = try r.takeDelimiterExclusive(' ');  // "hello"
```

### Limited Reader
```zig
// Limit bytes readable from underlying reader
var limited_buf: [256]u8 = undefined;
var limited = r.limited(.limited(1024), &limited_buf);
// Read at most 1024 bytes from underlying reader
```

## File I/O Integration

### Reading Files
```zig
const file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var reader = file.reader(&buf);
const r = &reader.interface;

// Read lines (takeDelimiter returns null at EOF, no error)
while (try r.takeDelimiter('\n')) |line| {
    // process line (does not include '\n')
}
// Loop ends when null returned (EOF)
```

### Writing Files
```zig
const file = try std.fs.cwd().createFile("out.txt", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var writer = file.writer(&buf);
const w = &writer.interface;

try w.print("Hello {s}\n", .{"world"});
try w.writeAll("More data\n");
try w.flush();  // REQUIRED!
```

### Stdout/Stderr
```zig
// Stdout
var stdout_buf: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
const stdout = &stdout_writer.interface;

try stdout.print("Output: {d}\n", .{42});
try stdout.flush();

// Stderr
var stderr_buf: [4096]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
const stderr = &stderr_writer.interface;

try stderr.print("Error: {s}\n", .{msg});
try stderr.flush();
```

### Stdin
```zig
var stdin_buf: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
const stdin = &stdin_reader.interface;

// takeDelimiter returns ?[]u8 (null at EOF), wrapped in error union
const maybe_line = try stdin.takeDelimiter('\n');  // null if EOF
if (maybe_line) |line| {
    // process line
}
```

## Common Patterns

### Process Lines from File
```zig
fn processLines(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var reader = file.reader(&buf);
    const r = &reader.interface;

    // takeDelimiter returns null at EOF (not EndOfStream error)
    while (try r.takeDelimiter('\n')) |line| {
        std.debug.print("Line: {s}\n", .{line});
    }
}
```

### Copy File
```zig
fn copyFile(src_path: []const u8, dst_path: []const u8) !void {
    const src = try std.fs.cwd().openFile(src_path, .{});
    defer src.close();

    const dst = try std.fs.cwd().createFile(dst_path, .{});
    defer dst.close();

    var read_buf: [4096]u8 = undefined;
    var reader = src.reader(&read_buf);

    var write_buf: [4096]u8 = undefined;
    var writer = dst.writer(&write_buf);

    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
}
```

### Parse Binary Header
```zig
const FileHeader = extern struct {
    magic: [4]u8,
    version: u16,
    flags: u32,
    data_offset: u64,
};

fn parseHeader(file: std.fs.File) !FileHeader {
    var buf: [128]u8 = undefined;
    var reader = file.reader(&buf);
    const r = &reader.interface;

    const header = try r.takeStruct(FileHeader, .little);
    if (!std.mem.eql(u8, &header.magic, "MYFT")) {
        return error.InvalidMagic;
    }
    return header;
}
```

### Build String with Allocating Writer
```zig
fn buildMessage(allocator: Allocator, items: []const Item) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("Items:\n");
    for (items, 0..) |item, i| {
        try w.print("  {d}. {s}\n", .{ i + 1, item.name });
    }

    return aw.toOwnedSlice();
}
```

### Streaming JSON to File
```zig
fn writeJson(file: std.fs.File, data: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;

    try std.json.stringify(data, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}
```

## Specialized Writers

### Writer.Hashed
Wraps a writer to compute hash of written data.
```zig
var hash_buf: [64]u8 = undefined;
var hasher = std.crypto.hash.sha2.Sha256.init(.{});
var hashed = writer.hashed(&hasher, &hash_buf);
const w = &hashed.writer;

try w.writeAll("data to hash");
try w.flush();

var digest: [32]u8 = undefined;
hashed.hasher.final(&digest);
```

## Specialized Readers

### Reader.Hashed
Wraps a reader to compute hash of read data.
```zig
var hash_buf: [64]u8 = undefined;
var hasher = std.crypto.hash.sha2.Sha256.init(.{});
var hashed = reader.hashed(&hasher, &hash_buf);
const r = &hashed.reader;

const data = try r.take(100);
// hasher updated with read data

var digest: [32]u8 = undefined;
hashed.hasher.final(&digest);
```

### Reader.Limited
Limits bytes readable from underlying reader.
```zig
var limited_buf: [256]u8 = undefined;
var limited = underlying_reader.limited(.limited(1024), &limited_buf);
// Can only read up to 1024 bytes total
```

## Error Types

### Writer Errors
```zig
std.Io.Writer.Error = error{WriteFailed};
```

### Reader Errors
```zig
std.Io.Reader.Error = error{ReadFailed, EndOfStream};
std.Io.Reader.StreamError = error{ReadFailed, WriteFailed, EndOfStream};
std.Io.Reader.DelimiterError = error{ReadFailed, EndOfStream, StreamTooLong};
```

## std.io.Limit

Used to specify byte limits for streaming operations.
```zig
const Limit = enum(usize) {
    nothing = 0,
    unlimited = std.math.maxInt(usize),
    _,

    pub fn limited(n: usize) Limit;
    pub fn limited64(n: u64) Limit;
    pub fn min(a: Limit, b: Limit) Limit;
    pub fn toInt(l: Limit) ?usize;  // null for unlimited
    pub fn subtract(l: Limit, amount: usize) ?Limit;
};
```
