# std.compress - Compression API Reference

Compression and decompression algorithms in Zig 0.15.x. Supports DEFLATE (gzip, zlib), LZMA, LZMA2, XZ, and Zstandard.

## Table of Contents
- [Module Structure](#module-structure)
- [DEFLATE (gzip/zlib)](#deflate-gzipzlib)
- [Zstandard](#zstandard)
- [LZMA](#lzma)
- [LZMA2](#lzma2)
- [XZ](#xz)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.compress.flate      // DEFLATE: gzip, zlib, raw deflate
std.compress.zstd       // Zstandard compression
std.compress.lzma       // LZMA compression
std.compress.lzma2      // LZMA2 compression
std.compress.xz         // XZ format (LZMA2 container)
```

## DEFLATE (gzip/zlib)

DEFLATE compression with gzip, zlib, or raw containers. Defined in RFC 1951 (deflate), RFC 1950 (zlib), RFC 1952 (gzip).

### Container Types

```zig
const Container = enum {
    raw,   // No header/footer, raw deflate stream
    gzip,  // gzip header (10+ bytes) + deflate + CRC32 + size footer (8 bytes)
    zlib,  // zlib header (2 bytes) + deflate + Adler32 footer (4 bytes)
};
```

### Decompression

```zig
const flate = std.compress.flate;

// Decompress gzip data
var input: std.Io.Reader = .fixed(compressed_data);
var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();

var decompress: flate.Decompress = .init(&input, .gzip, &.{});
_ = try decompress.reader.streamRemaining(&output.writer);

const decompressed = output.written();
```

### With History Buffer

For streaming decompression with backref support:

```zig
var buffer: [flate.max_window_len]u8 = undefined;
var decompress: flate.Decompress = .init(&input, .zlib, &buffer);
```

### Decompress Constants

```zig
flate.max_window_len  // 65536 - Maximum window size (32768 * 2)
flate.history_len     // 32768 - History buffer length
```

### Compression

```zig
const flate = std.compress.flate;

var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();

var buffer: [flate.max_window_len]u8 = undefined;
var compress: flate.Compress = .init(&output.writer, &buffer, .{
    .level = .default,
    .container = .gzip,
});

try compress.writer.writeAll(data);
try compress.end();

const compressed = output.written();
```

### Compression Levels

```zig
const Level = enum {
    level_4,  // Fastest
    level_5,
    level_6,  // Default
    level_7,
    level_8,
    level_9,  // Best compression

    fast,     // Alias for level_4
    default,  // Alias for level_6
    best,     // Alias for level_9
};
```

### Huffman-Only Compression

For faster compression without LZ77 match searching:

```zig
const HuffmanEncoder = flate.HuffmanEncoder;
// Used internally for Huffman-only encoding (bigger output, faster compression)
```

## Zstandard

Zstandard (zstd) decompression. High compression ratio with fast decompression.

### Decompression

```zig
const zstd = std.compress.zstd;

var input: std.Io.Reader = .fixed(compressed_data);
var output: std.Io.Writer.Allocating = .init(allocator);
defer output.deinit();

var decompress: zstd.Decompress = .init(&input, &.{}, .{});
_ = try decompress.reader.streamRemaining(&output.writer);

const decompressed = output.written();
```

### With Custom Window Size

```zig
var buffer: [zstd.default_window_len + zstd.block_size_max]u8 = undefined;
var decompress: zstd.Decompress = .init(&input, &buffer, .{
    .window_len = zstd.default_window_len,
    .verify_checksum = false,  // Not yet implemented
});
```

### Zstd Constants

```zig
zstd.default_window_len  // 8 * 1024 * 1024 (8 MB)
zstd.block_size_max      // 1 << 17 (128 KB)
```

### Options

```zig
pub const Options = struct {
    verify_checksum: bool = false,  // Not yet implemented
    window_len: u32 = zstd.default_window_len,
};
```

## LZMA

LZMA decompression with streaming reader interface.

### Decompression

```zig
const lzma = std.compress.lzma;

var decompress = try lzma.decompress(allocator, reader);
defer decompress.deinit();

var buf: [4096]u8 = undefined;
while (true) {
    const n = try decompress.read(&buf);
    if (n == 0) break;
    // Process buf[0..n]
}
```

### With Options

```zig
var decompress = try lzma.decompressWithOptions(allocator, reader, .{
    .memlimit = 128 * 1024 * 1024,  // 128 MB memory limit
});
```

### Decompress Type

```zig
pub fn Decompress(comptime ReaderType: type) type {
    return struct {
        pub const Reader = std.io.GenericReader(*Self, Error, read);

        pub fn init(allocator: Allocator, source: ReaderType, params: Params, memlimit: ?usize) !Self;
        pub fn deinit(self: *Self) void;
        pub fn reader(self: *Self) Reader;
        pub fn read(self: *Self, output: []u8) Error!usize;
    };
}
```

## LZMA2

LZMA2 decompression (improved LZMA with better streaming support).

### Decompression

```zig
const lzma2 = std.compress.lzma2;

var output = std.ArrayList(u8).empty;
defer output.deinit(allocator);

var stream = std.io.fixedBufferStream(compressed_data);
try lzma2.decompress(allocator, stream.reader(), output.writer(allocator));
```

## XZ

XZ format decompression (LZMA2 in a container with checksums).

### Decompression

```zig
const xz = std.compress.xz;

var decompress = try xz.decompress(allocator, reader);
defer decompress.deinit();

var buf: [4096]u8 = undefined;
while (true) {
    const n = try decompress.read(&buf);
    if (n == 0) break;
    // Process buf[0..n]
}
```

### Check Types

XZ supports multiple integrity check types:

```zig
pub const Check = enum(u4) {
    none = 0x00,
    crc32 = 0x01,
    crc64 = 0x04,
    sha256 = 0x0A,
    _,
};
```

## Common Patterns

### Decompress gzip File

```zig
fn decompressGzip(allocator: Allocator, compressed: []const u8) ![]u8 {
    const flate = std.compress.flate;

    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var decompress: flate.Decompress = .init(&input, .gzip, &.{});
    _ = try decompress.reader.streamRemaining(&output.writer);

    return output.toOwnedSlice();
}
```

### Decompress zlib Data

```zig
fn decompressZlib(allocator: Allocator, compressed: []const u8) ![]u8 {
    const flate = std.compress.flate;

    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var decompress: flate.Decompress = .init(&input, .zlib, &.{});
    _ = try decompress.reader.streamRemaining(&output.writer);

    return output.toOwnedSlice();
}
```

### Decompress Zstandard

```zig
fn decompressZstd(allocator: Allocator, compressed: []const u8) ![]u8 {
    const zstd = std.compress.zstd;

    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var decompress: zstd.Decompress = .init(&input, &.{}, .{});
    _ = try decompress.reader.streamRemaining(&output.writer);

    return output.toOwnedSlice();
}
```

### Stream Decompression to File

```zig
fn decompressToFile(
    input_path: []const u8,
    output_path: []const u8,
    container: std.compress.flate.Container,
) !void {
    const flate = std.compress.flate;

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);

    var output_buf: [4096]u8 = undefined;
    var output_writer = output_file.writer(&output_buf);

    var decompress: flate.Decompress = .init(&input_reader.interface, container, &.{});
    _ = try decompress.reader.streamRemaining(&output_writer.interface);
    try output_writer.interface.flush();
}
```

### Detect Compression Format

```zig
fn detectFormat(data: []const u8) ?enum { gzip, zlib, zstd, xz } {
    if (data.len < 2) return null;

    // gzip: 0x1f 0x8b
    if (data[0] == 0x1f and data[1] == 0x8b) return .gzip;

    // zlib: CMF byte with CM=8, CINFO<=7
    const cmf = data[0];
    if ((cmf & 0x0f) == 8 and (cmf >> 4) <= 7) {
        // Check FCHECK makes header divisible by 31
        const header: u16 = (@as(u16, data[0]) << 8) | data[1];
        if (header % 31 == 0) return .zlib;
    }

    // zstd: magic 0xFD2FB528
    if (data.len >= 4) {
        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic == 0xFD2FB528) return .zstd;
    }

    // xz: magic 0xFD377A585A00
    if (data.len >= 6) {
        if (std.mem.eql(u8, data[0..6], &.{ 0xFD, '7', 'z', 'X', 'Z', 0x00 })) return .xz;
    }

    return null;
}
```

## Error Types

### DEFLATE Errors

```zig
pub const Error = Container.Error || error{
    InvalidCode,
    InvalidMatch,
    WrongStoredBlockNlen,
    InvalidBlockType,
    InvalidDynamicBlockHeader,
    ReadFailed,
    OversubscribedHuffmanTree,
    IncompleteHuffmanTree,
    MissingEndOfBlockCode,
    EndOfStream,
};

pub const Container.Error = error{
    BadGzipHeader,
    BadZlibHeader,
    WrongGzipChecksum,
    WrongGzipSize,
    WrongZlibChecksum,
};
```

### Zstandard Errors

```zig
pub const Error = error{
    BadMagic,
    BlockOversize,
    ChecksumFailure,
    ContentOversize,
    DictionaryIdFlagUnsupported,
    EndOfStream,
    HuffmanTreeIncomplete,
    InvalidBitStream,
    MalformedAccuracyLog,
    MalformedBlock,
    MalformedCompressedBlock,
    MalformedFrame,
    MalformedFseBits,
    MalformedFseTable,
    MalformedHuffmanTree,
    MalformedLiteralsHeader,
    MalformedLiteralsLength,
    MalformedLiteralsSection,
    MalformedSequence,
    MissingStartBit,
    OutputBufferUndersize,
    InputBufferUndersize,
    ReadFailed,
    RepeatModeFirst,
    ReservedBitSet,
    ReservedBlock,
    SequenceBufferUndersize,
    TreelessLiteralsFirst,
    UnexpectedEndOfLiteralStream,
    WindowOversize,
    WindowSizeUnknown,
};
```

## Supported Features

**DEFLATE (flate)**:
- Decompression: gzip, zlib, raw deflate
- Compression: gzip, zlib, raw deflate (levels 4-9)
- Streaming with history buffer

**Zstandard (zstd)**:
- Decompression only
- Skippable frames
- Configurable window size
- Dictionary support: Not implemented

**LZMA/LZMA2**:
- Decompression only
- Streaming interface
- Memory limit configuration

**XZ**:
- Decompression only
- CRC32/CRC64/SHA256 integrity checks
- Multiple block support
