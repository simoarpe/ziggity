# std.zip - ZIP Archive API Reference

ZIP archive reading and extraction in Zig 0.15.x. Supports ZIP and ZIP64 formats with store and deflate compression.

## Table of Contents
- [Module Structure](#module-structure)
- [Extracting ZIP Archives](#extracting-zip-archives)
- [Iterating Over Entries](#iterating-over-entries)
- [Entry Extraction](#entry-extraction)
- [Diagnostics](#diagnostics)
- [Low-Level Structures](#low-level-structures)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.zip.extract()       // Extract entire archive to directory
std.zip.Iterator        // Iterate over archive entries
std.zip.Iterator.Entry  // Single archive entry
std.zip.Diagnostics     // Track extraction metadata
std.zip.ExtractOptions  // Extraction configuration
std.zip.CompressionMethod  // .store, .deflate
```

## Extracting ZIP Archives

### Basic Extraction

Extract all files from a ZIP archive to a directory:

```zig
const file = try std.fs.cwd().openFile("archive.zip", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var file_reader = file.reader(&buf);

try std.zip.extract(output_dir, &file_reader, .{});
```

### With Options and Diagnostics

```zig
var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
defer diagnostics.deinit();

try std.zip.extract(output_dir, &file_reader, .{
    .allow_backslashes = true,  // normalize \ to /
    .diagnostics = &diagnostics,
});

// Check common root directory
if (diagnostics.root_dir.len > 0) {
    std.debug.print("Archive root: {s}\n", .{diagnostics.root_dir});
}
```

### ExtractOptions

```zig
pub const ExtractOptions = struct {
    allow_backslashes: bool = false,   // normalize \ to / in filenames
    diagnostics: ?*Diagnostics = null, // track extraction metadata
    verify_checksums: bool = false,    // TODO: not yet implemented
};
```

## Iterating Over Entries

### Iterator API

For more control, iterate over entries individually:

```zig
const file = try std.fs.cwd().openFile("archive.zip", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var file_reader = file.reader(&buf);

var iter = try std.zip.Iterator.init(&file_reader);

var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
while (try iter.next()) |entry| {
    // Read filename from archive
    try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    const filename = filename_buf[0..entry.filename_len];
    try file_reader.interface.readSliceAll(filename);

    std.debug.print("{s}: {d} bytes (compressed: {d})\n", .{
        filename,
        entry.uncompressed_size,
        entry.compressed_size,
    });
}
```

### Iterator.Entry Structure

```zig
pub const Entry = struct {
    version_needed_to_extract: u16,
    flags: GeneralPurposeFlags,
    compression_method: CompressionMethod,  // .store or .deflate
    last_modification_time: u16,            // DOS time format
    last_modification_date: u16,            // DOS date format
    header_zip_offset: u64,                 // offset to central directory header
    crc32: u32,                             // CRC-32 checksum
    filename_len: u32,
    compressed_size: u64,
    uncompressed_size: u64,
    file_offset: u64,                       // offset to local file header
};
```

## Entry Extraction

### Extract Single Entry

```zig
var iter = try std.zip.Iterator.init(&file_reader);

var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
while (try iter.next()) |entry| {
    // Extract this entry to destination directory
    try entry.extract(&file_reader, .{}, &filename_buf, output_dir);
}
```

### Selective Extraction

Extract only specific files:

```zig
var iter = try std.zip.Iterator.init(&file_reader);

var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
while (try iter.next()) |entry| {
    // Read filename first
    try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    const filename = filename_buf[0..entry.filename_len];
    try file_reader.interface.readSliceAll(filename);

    // Only extract .zig files
    if (std.mem.endsWith(u8, filename, ".zig")) {
        try entry.extract(&file_reader, .{}, &filename_buf, output_dir);
    }
}
```

## Diagnostics

Track metadata during extraction:

```zig
var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
defer diagnostics.deinit();

try std.zip.extract(dest, &file_reader, .{
    .diagnostics = &diagnostics,
});

// root_dir is the common directory prefix for all files (if any)
// e.g., if all files are under "project/", root_dir will be "project"
if (diagnostics.root_dir.len > 0) {
    std.debug.print("Common root: {s}\n", .{diagnostics.root_dir});
}
```

## Low-Level Structures

### CompressionMethod

```zig
pub const CompressionMethod = enum(u16) {
    store = 0,    // no compression
    deflate = 8,  // DEFLATE algorithm
    _,            // other methods (unsupported)
};
```

### EndRecord

Find and parse the end-of-central-directory record:

```zig
// From file
const end_record = try std.zip.EndRecord.findFile(&file_reader);

// From buffer
const end_record = try std.zip.EndRecord.findBuffer(zip_bytes);

// Check if ZIP64 extensions needed
if (end_record.need_zip64()) {
    // Parse ZIP64 end locator and record
}
```

### Header Structures

```zig
// Central directory file header (46 bytes)
std.zip.CentralDirectoryFileHeader

// Local file header (30 bytes)
std.zip.LocalFileHeader

// End of central directory record (22 bytes)
std.zip.EndRecord

// ZIP64 end of central directory record
std.zip.EndRecord64

// ZIP64 end of central directory locator
std.zip.EndLocator64
```

### Signature Constants

```zig
std.zip.central_file_header_sig  // "PK\x01\x02"
std.zip.local_file_header_sig    // "PK\x03\x04"
std.zip.end_record_sig           // "PK\x05\x06"
std.zip.end_record64_sig         // "PK\x06\x06"
std.zip.end_locator64_sig        // "PK\x06\x07"
```

## Common Patterns

### Extract ZIP to Directory

```zig
fn extractZip(allocator: Allocator, zip_path: []const u8, dest_path: []const u8) !void {
    const file = try std.fs.cwd().openFile(zip_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);

    var dest = try std.fs.cwd().makeOpenPath(dest_path, .{});
    defer dest.close();

    var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();

    try std.zip.extract(dest, &file_reader, .{
        .allow_backslashes = true,
        .diagnostics = &diagnostics,
    });
}
```

### List ZIP Contents

```zig
fn listZip(zip_path: []const u8) !void {
    const file = try std.fs.cwd().openFile(zip_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);

    var iter = try std.zip.Iterator.init(&file_reader);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    var total_size: u64 = 0;
    var file_count: u64 = 0;

    while (try iter.next()) |entry| {
        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename = filename_buf[0..entry.filename_len];
        try file_reader.interface.readSliceAll(filename);

        const method: []const u8 = switch (entry.compression_method) {
            .store => "stored",
            .deflate => "deflated",
            else => "unknown",
        };

        std.debug.print("{s:40} {d:>10} {s}\n", .{
            filename,
            entry.uncompressed_size,
            method,
        });

        total_size += entry.uncompressed_size;
        file_count += 1;
    }

    std.debug.print("\n{d} files, {d} bytes total\n", .{ file_count, total_size });
}
```

### Extract Single File by Name

```zig
fn extractFile(
    file_reader: *std.fs.File.Reader,
    target_name: []const u8,
    dest: std.fs.Dir,
) !bool {
    var iter = try std.zip.Iterator.init(file_reader);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename = filename_buf[0..entry.filename_len];
        try file_reader.interface.readSliceAll(filename);

        if (std.mem.eql(u8, filename, target_name)) {
            try entry.extract(file_reader, .{}, &filename_buf, dest);
            return true;
        }
    }
    return false;  // not found
}
```

### Check if File is ZIP

```zig
fn isZipFile(path: []const u8) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);

    _ = std.zip.EndRecord.findFile(&file_reader) catch return false;
    return true;
}
```

## Supported Features

**Formats**: ZIP, ZIP64 (large files > 4GB, > 65535 entries)

**Compression**: Store (uncompressed), Deflate

**Not supported**:
- Encryption (returns `error.ZipEncryptionUnsupported`)
- Multi-disk archives (returns `error.ZipMultiDiskUnsupported`)
- Other compression methods (LZMA, BZip2, etc.)
- Writing ZIP archives (read-only API)

**Path handling**: Optional backslash normalization, directory traversal protection (rejects `..` paths)
