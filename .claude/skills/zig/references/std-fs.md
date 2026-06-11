# std.fs - File System API Reference

File system operations in Zig 0.15.x. Covers files, directories, iteration, atomic writes, and paths.

## Table of Contents
- [Module Structure](#module-structure)
- [Working with Files](#working-with-files)
- [Working with Directories](#working-with-directories)
- [Directory Iteration](#directory-iteration)
- [Atomic File Operations](#atomic-file-operations)
- [Path Manipulation](#path-manipulation)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.fs.File      // File handle and I/O operations
std.fs.Dir       // Directory handle and operations
std.fs.AtomicFile // Safe file writes with atomic rename
std.fs.path      // Path manipulation utilities
std.fs.cwd()     // Current working directory handle
```

## Working with Files

### Opening Files

```zig
// Open existing file for reading
const file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();

// Open with write access
const file = try std.fs.cwd().openFile("data.txt", .{ .mode = .read_write });

// Create or truncate file
const file = try std.fs.cwd().createFile("output.txt", .{});
defer file.close();

// Create without truncating existing
const file = try std.fs.cwd().createFile("output.txt", .{ .truncate = false });

// Create exclusively (fail if exists)
const file = try std.fs.cwd().createFile("new.txt", .{ .exclusive = true });
```

**OpenFlags**:
- `.mode`: `.read_only` (default), `.write_only`, `.read_write`
- `.lock`: `.none`, `.shared`, `.exclusive` (advisory locking)
- `.lock_nonblocking`: return `error.WouldBlock` instead of waiting

**CreateFlags**:
- `.read`: enable read access (default: false)
- `.truncate`: truncate if exists (default: true)
- `.exclusive`: fail if exists (default: false)
- `.mode`: POSIX file mode (default: 0o666)

### Reading Files (0.15.x)

```zig
const file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var reader = file.reader(&buf);

// Read lines
while (reader.interface.takeDelimiterExclusive('\n')) |line| {
    // process line (does not include '\n')
} else |err| switch (err) {
    error.EndOfStream => {},
    else => return err,
}

// Read all into buffer
const content = try reader.interface.readAllAlloc(allocator, max_size);
defer allocator.free(content);
```

### Writing Files (0.15.x)

```zig
const file = try std.fs.cwd().createFile("output.txt", .{});
defer file.close();

var buf: [4096]u8 = undefined;
var writer = file.writer(&buf);
const w = &writer.interface;

try w.print("Line {d}\n", .{42});
try w.writeAll("Raw bytes\n");
try w.flush();  // REQUIRED - flushes buffer to file
```

### Convenience Methods

```zig
// Read entire file into buffer
var buffer: [4096]u8 = undefined;
const content = try std.fs.cwd().readFile("data.txt", &buffer);

// Read with allocation
const content = try std.fs.cwd().readFileAlloc(allocator, "data.txt", max_size);
defer allocator.free(content);

// Write entire contents
try std.fs.cwd().writeFile(.{
    .sub_path = "output.txt",
    .data = "Hello, World!",
});
```

### File Metadata

```zig
const stat = try file.stat();
stat.size;      // u64 - file size in bytes
stat.kind;      // .file, .directory, .sym_link, etc.
stat.mode;      // POSIX mode (0 on Windows)
stat.mtime;     // i128 - modification time in nanoseconds since Unix epoch
stat.atime;     // i128 - access time
stat.ctime;     // i128 - status change time
stat.inode;     // file system inode number

// Get file size
const size = try file.getEndPos();

// Check if terminal
if (file.isTty()) { ... }
```

### Seeking

```zig
try file.seekTo(0);              // absolute position
try file.seekBy(-100);           // relative to current
try file.seekFromEnd(-100);      // relative to end
const pos = try file.getPos();   // get current position
```

### Standard I/O

```zig
const stdin = std.fs.File.stdin();
const stdout = std.fs.File.stdout();
const stderr = std.fs.File.stderr();

var buf: [4096]u8 = undefined;
var writer = stdout.writer(&buf);
try writer.interface.print("Hello\n", .{});
try writer.interface.flush();
```

## Working with Directories

### Opening Directories

```zig
// Open for file operations (default)
var dir = try std.fs.cwd().openDir("subdir", .{});
defer dir.close();

// Open for iteration
var dir = try std.fs.cwd().openDir("subdir", .{ .iterate = true });
defer dir.close();

// Don't follow symlinks
var dir = try std.fs.cwd().openDir("link", .{ .no_follow = true });
```

**OpenOptions**:
- `.access_sub_paths`: can use as base for file ops (default: true)
- `.iterate`: can iterate contents (default: false)
- `.no_follow`: don't follow symlinks (default: false)

### Creating Directories

```zig
// Create single directory
try std.fs.cwd().makeDir("new_dir");

// Create with all parents
try std.fs.cwd().makePath("path/to/nested/dir");

// Create and open
var dir = try std.fs.cwd().makeOpenPath("path/to/dir", .{});
defer dir.close();
```

### Deleting

```zig
// Delete file
try dir.deleteFile("file.txt");

// Delete empty directory
try dir.deleteDir("empty_dir");

// Delete recursively (files and subdirs)
try dir.deleteTree("dir_with_contents");
```

### Renaming and Copying

```zig
// Rename within same directory
try dir.rename("old.txt", "new.txt");

// Rename across directories
try std.fs.rename(old_dir, "file.txt", new_dir, "file.txt");

// Copy file atomically
try std.fs.Dir.copyFile(src_dir, "source.txt", dest_dir, "dest.txt", .{});

// Update only if source is newer
const status = try std.fs.Dir.updateFile(src_dir, "src.txt", dest_dir, "dst.txt", .{});
if (status == .stale) {
    // file was copied
}
```

### Checking Existence

```zig
// Check if accessible (TOCTOU warning!)
dir.access("file.txt", .{}) catch |err| switch (err) {
    error.FileNotFound => { /* doesn't exist */ },
    else => return err,
};

// Better: just try to open and handle error
const file = dir.openFile("file.txt", .{}) catch |err| switch (err) {
    error.FileNotFound => { /* handle missing */ return; },
    else => return err,
};
defer file.close();
```

## Directory Iteration

### Basic Iteration

```zig
var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
defer dir.close();

var iter = dir.iterate();
while (try iter.next()) |entry| {
    std.debug.print("{s} ({s})\n", .{ entry.name, @tagName(entry.kind) });
}
```

**Entry.Kind**: `.file`, `.directory`, `.sym_link`, `.block_device`, `.character_device`, `.named_pipe`, `.unix_domain_socket`, `.unknown`

### Recursive Walking

```zig
var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
defer dir.close();

var walker = try dir.walk(allocator);
defer walker.deinit();

while (try walker.next()) |entry| {
    // entry.path: full relative path "subdir/file.txt"
    // entry.basename: just filename "file.txt"
    // entry.kind: file type
    // entry.dir: containing directory handle

    if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
        std.debug.print("Found: {s}\n", .{entry.path});
    }
}
```

### Reset Iterator

```zig
var iter = dir.iterate();
while (try iter.next()) |_| { }
iter.reset();  // start over from beginning
```

## Atomic File Operations

Safe file writes using temporary files and atomic rename. Prevents partial writes on crash.

```zig
var buf: [4096]u8 = undefined;
var atomic = try dir.atomicFile("output.txt", .{ .write_buffer = &buf });
defer atomic.deinit();  // always call, even after finish()

const w = &atomic.file_writer.interface;
try w.print("Safe content\n", .{});

try atomic.finish();  // flush + rename atomically
```

**AtomicFileOptions**:
- `.mode`: POSIX mode for new file
- `.make_path`: create parent directories if missing
- `.write_buffer`: required buffer for writer

**Manual control**:
```zig
try atomic.flush();           // flush buffer to temp file
try atomic.renameIntoPlace(); // atomically replace target
```

## Path Manipulation

```zig
const path = std.fs.path;

// Join path components
const full = try path.join(allocator, &.{ "dir", "subdir", "file.txt" });
defer allocator.free(full);

// Split into directory and basename
const dir_part = path.dirname("/foo/bar/file.txt");   // "/foo/bar"
const base = path.basename("/foo/bar/file.txt");      // "file.txt"

// Get extension
const ext = path.extension("file.tar.gz");  // ".gz"
const stem = path.stem("file.tar.gz");      // "file.tar"

// Check if absolute
if (path.isAbsolute(p)) { ... }

// Resolve relative paths
const resolved = try path.resolve(allocator, &.{ base_dir, relative_path });
defer allocator.free(resolved);

// Platform-specific separator
const sep = path.sep;  // '/' on POSIX, '\\' on Windows
```

## Common Patterns

### Process All Files in Directory

```zig
var dir = try std.fs.cwd().openDir("data", .{ .iterate = true });
defer dir.close();

var iter = dir.iterate();
while (try iter.next()) |entry| {
    if (entry.kind != .file) continue;

    var file = try dir.openFile(entry.name, .{});
    defer file.close();
    // process file...
}
```

### Safe Config File Update

```zig
fn saveConfig(dir: std.fs.Dir, config: Config) !void {
    var buf: [4096]u8 = undefined;
    var atomic = try dir.atomicFile("config.json", .{ .write_buffer = &buf });
    defer atomic.deinit();

    const w = &atomic.file_writer.interface;
    try std.json.stringify(config, .{}, w);
    try atomic.finish();
}
```

### Find Files Recursively

```zig
fn findFiles(allocator: Allocator, dir: std.fs.Dir, extension: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |s| allocator.free(s);
        results.deinit(allocator);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, extension)) {
            const copy = try allocator.dupe(u8, entry.path);
            try results.append(allocator, copy);
        }
    }
    return try results.toOwnedSlice(allocator);
}
```

### Copy Directory Tree

```zig
fn copyTree(allocator: Allocator, src: std.fs.Dir, dest: std.fs.Dir) !void {
    var walker = try src.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .directory) {
            try dest.makePath(entry.path);
        } else if (entry.kind == .file) {
            if (std.fs.path.dirname(entry.path)) |parent| {
                try dest.makePath(parent);
            }
            try std.fs.Dir.copyFile(entry.dir, entry.basename, dest, entry.path, .{});
        }
    }
}
```

### Read/Modify/Write Pattern

```zig
// Read existing content
const content = try dir.readFileAlloc(allocator, "data.txt", max_size);
defer allocator.free(content);

// Modify
const modified = try process(allocator, content);
defer allocator.free(modified);

// Write back atomically
var buf: [4096]u8 = undefined;
var atomic = try dir.atomicFile("data.txt", .{ .write_buffer = &buf });
defer atomic.deinit();
try atomic.file_writer.interface.writeAll(modified);
try atomic.finish();
```
