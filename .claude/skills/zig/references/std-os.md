# std.os - OS-Specific APIs Reference

Thin wrappers around OS-specific APIs in Zig 0.15.x. Converts errno-style error codes to Zig errors, provides slice-accepting APIs alongside null-terminated ones, and offers cross-platform abstractions for POSIX systems.

## Table of Contents
- [Module Structure](#module-structure)
- [Platform Submodules](#platform-submodules)
- [Linux-Specific APIs](#linux-specific-apis)
- [Windows-Specific APIs](#windows-specific-apis)
- [WASI-Specific APIs](#wasi-specific-apis)
- [io_uring (Linux)](#io_uring-linux)
- [Common Functions](#common-functions)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.os.linux      // Linux syscalls and constants
std.os.windows    // Windows NT APIs
std.os.wasi       // WebAssembly System Interface
std.os.plan9      // Plan 9 system calls
std.os.uefi       // UEFI firmware interface
std.os.emscripten // Emscripten runtime
std.os.freebsd    // FreeBSD-specific definitions

std.os.environ    // Environment variables (populated at startup)
std.os.argv       // Command line arguments (POSIX only)
```

**Note**: For most use cases, prefer `std.posix` (cross-platform POSIX-like APIs) or `std.fs`/`std.process` (high-level abstractions). Use `std.os` when you need direct OS-specific functionality.

## Platform Submodules

### When to Use Each Level

```zig
// High-level (recommended for most code)
const file = try std.fs.cwd().openFile("data.txt", .{});

// POSIX-level (cross-platform low-level)
const fd = try std.posix.open("data.txt", .{}, 0);

// OS-specific (platform-specific features)
const result = std.os.linux.syscall3(.read, fd, buf.ptr, buf.len);
```

## Linux-Specific APIs

### Direct Syscalls

```zig
const linux = std.os.linux;

// Raw syscall interface
const result = linux.syscall3(.write, fd, @intFromPtr(buf.ptr), buf.len);
if (linux.E.init(result) != .SUCCESS) {
    // handle error
}

// Common syscalls with typed wrappers
_ = linux.dup(old_fd);
_ = linux.dup2(old_fd, new_fd);
_ = linux.fork();
_ = linux.execve(path, argv, envp);
_ = linux.chdir(path);
_ = linux.chroot(path);
```

### Memory Mapping

```zig
const linux = std.os.linux;

// mmap with typed flags
const addr = linux.mmap(
    null,
    length,
    linux.PROT.READ | linux.PROT.WRITE,
    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
    -1,
    0,
);
if (addr == linux.MAP_FAILED) {
    // handle error
}

// Remap
_ = linux.mremap(old_addr, old_size, new_size, .{ .MAYMOVE = true }, null);

// Unmap
_ = linux.munmap(addr, length);
```

### File Operations

```zig
const linux = std.os.linux;

// Open flags (architecture-specific packed struct)
const flags: linux.O = .{
    .ACCMODE = .RDWR,
    .CREAT = true,
    .TRUNC = true,
    .CLOEXEC = true,
};

// fallocate - preallocate file space
_ = linux.fallocate(fd, 0, 0, size);

// utimensat - set file timestamps
_ = linux.utimensat(dirfd, path, &times, 0);
```

### Futex (Fast Userspace Mutex)

```zig
const linux = std.os.linux;

// Wait on futex
_ = linux.futex(
    &futex_word,
    .{ .op = .WAIT, .PRIVATE = true },
    expected_value,
    .{ .timeout = &timeout },
    null,
    0,
);

// Wake waiters
_ = linux.futex(
    &futex_word,
    .{ .op = .WAKE, .PRIVATE = true },
    num_to_wake,
    .{ .val2 = 0 },
    null,
    0,
);
```

### Signals

```zig
const linux = std.os.linux;

// Signal handling
var act: linux.Sigaction = .{
    .handler = .{ .handler = signal_handler },
    .mask = linux.empty_sigset,
    .flags = .{},
};
_ = linux.sigaction(linux.SIG.INT, &act, null);

// Kill process
_ = linux.kill(pid, linux.SIG.TERM);
```

### Epoll

```zig
const linux = std.os.linux;

// Create epoll instance
const epfd = linux.epoll_create1(.{ .CLOEXEC = true });

// Add file descriptor
var event: linux.epoll_event = .{
    .events = linux.EPOLL.IN | linux.EPOLL.ET,
    .data = .{ .fd = client_fd },
};
_ = linux.epoll_ctl(epfd, .ADD, client_fd, &event);

// Wait for events
var events: [64]linux.epoll_event = undefined;
const n = linux.epoll_wait(epfd, &events, -1);
for (events[0..n]) |ev| {
    // handle event
}
```

### getauxval

```zig
const linux = std.os.linux;

// Get auxiliary vector values (set by kernel at process start)
const page_size = linux.getauxval(std.elf.AT_PAGESZ);
const entry_point = linux.getauxval(std.elf.AT_ENTRY);
const platform = linux.getauxval(std.elf.AT_PLATFORM);
```

## Windows-Specific APIs

### File Operations

```zig
const windows = std.os.windows;

// Open file with NT API
const handle = try windows.OpenFile(path_utf16, .{
    .access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE,
    .creation = windows.FILE_OPEN,
    .share_access = windows.FILE_SHARE_READ,
    .filter = .file_only,
    .follow_symlinks = true,
});
defer windows.CloseHandle(handle);
```

### Process Information

```zig
const windows = std.os.windows;

// Current process/thread
const process = windows.GetCurrentProcess();
const pid = windows.GetCurrentProcessId();
const thread = windows.GetCurrentThread();
const tid = windows.GetCurrentThreadId();

// Last error
const err = windows.GetLastError();
```

### Pipes

```zig
const windows = std.os.windows;

var read_handle: windows.HANDLE = undefined;
var write_handle: windows.HANDLE = undefined;
var sa: windows.SECURITY_ATTRIBUTES = .{
    .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = null,
    .bInheritHandle = windows.TRUE,
};

try windows.CreatePipe(&read_handle, &write_handle, &sa);
```

### Submodules

```zig
windows.kernel32   // kernel32.dll functions
windows.ntdll      // ntdll.dll functions (NT native API)
windows.advapi32   // advapi32.dll (security, registry)
windows.ws2_32     // Winsock 2 networking
windows.crypt32    // Cryptographic functions
windows.nls        // National Language Support
```

## WASI-Specific APIs

### File Descriptors

```zig
const wasi = std.os.wasi;

// Read/write
var nread: usize = undefined;
switch (wasi.fd_read(fd, &iovs, iovs.len, &nread)) {
    .SUCCESS => {},
    .BADF => return error.BadFileDescriptor,
    else => |e| return unexpectedErrno(e),
}

// Seek
var new_offset: wasi.filesize_t = undefined;
_ = wasi.fd_seek(fd, offset, .SET, &new_offset);

// Sync
_ = wasi.fd_sync(fd);
_ = wasi.fd_datasync(fd);
```

### Path Operations

```zig
const wasi = std.os.wasi;

// Create directory
_ = wasi.path_create_directory(dirfd, path.ptr, path.len);

// Open file
var result_fd: wasi.fd_t = undefined;
_ = wasi.path_open(
    dirfd,
    .{ .SYMLINK_FOLLOW = true },
    path.ptr,
    path.len,
    .{ .CREAT = true },
    rights_base,
    rights_inheriting,
    .{},
    &result_fd,
);

// Symlinks
_ = wasi.path_symlink(old_path.ptr, old_path.len, dirfd, new_path.ptr, new_path.len);
_ = wasi.path_readlink(dirfd, path.ptr, path.len, buf.ptr, buf.len, &bufused);
```

### Clock

```zig
const wasi = std.os.wasi;

var timestamp: wasi.timestamp_t = undefined;
switch (wasi.clock_time_get(.MONOTONIC, 1, &timestamp)) {
    .SUCCESS => {},
    else => |e| return error.ClockGetFailed,
}
```

### Environment and Arguments

```zig
const wasi = std.os.wasi;

// Arguments
var argc: usize = undefined;
var argv_buf_size: usize = undefined;
_ = wasi.args_sizes_get(&argc, &argv_buf_size);

// Environment
var environ_count: usize = undefined;
var environ_buf_size: usize = undefined;
_ = wasi.environ_sizes_get(&environ_count, &environ_buf_size);
```

### Random

```zig
const wasi = std.os.wasi;

var buf: [32]u8 = undefined;
switch (wasi.random_get(&buf, buf.len)) {
    .SUCCESS => {},
    else => return error.RandomFailed,
}
```

## io_uring (Linux)

High-performance async I/O for Linux 5.4+.

### Basic Setup

```zig
const IoUring = std.os.linux.IoUring;

// Initialize with 256 entries
var ring = try IoUring.init(256, 0);
defer ring.deinit();

// With custom parameters
var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
    .flags = std.os.linux.IORING_SETUP_SQPOLL,  // kernel-side submission
    .sq_thread_idle = 2000,  // ms before SQ thread sleeps
});
var ring = try IoUring.init_params(256, &params);
```

### Submitting Operations

```zig
// Get submission queue entry
const sqe = try ring.get_sqe();

// Prepare read operation
sqe.prep_read(fd, buffer, offset);
sqe.user_data = my_context;  // identify this request in completion

// Or write
sqe.prep_write(fd, data, offset);

// Submit to kernel
const submitted = try ring.submit();
```

### Waiting for Completions

```zig
// Submit and wait for at least 1 completion
_ = try ring.submit_and_wait(1);

// Process completions
while (ring.cq_ready() > 0) {
    const cqe = ring.peek_cqe() orelse break;

    const user_data = cqe.user_data;
    const result = cqe.res;  // bytes transferred or -errno

    if (result < 0) {
        const err = std.os.linux.E.init(@intCast(-result));
        // handle error
    }

    ring.cq_advance(1);  // mark CQE as consumed
}
```

### Common Operations

```zig
// File I/O
sqe.prep_read(fd, buf, offset);
sqe.prep_write(fd, data, offset);
sqe.prep_readv(fd, iovecs, offset);
sqe.prep_writev(fd, iovecs, offset);

// Fixed buffers (pre-registered, zero-copy)
sqe.prep_read_fixed(fd, buf, offset, buf_index);
sqe.prep_write_fixed(fd, data, offset, buf_index);

// Network
sqe.prep_accept(listen_fd, &client_addr, &addr_len, 0);
sqe.prep_connect(fd, &addr, addr_len);
sqe.prep_recv(fd, buf, 0);
sqe.prep_send(fd, data, 0);

// Timeouts
sqe.prep_timeout(&timespec, 0, 0);
sqe.prep_link_timeout(&timespec, 0);  // timeout linked op

// File operations
sqe.prep_openat(dirfd, path, flags, mode);
sqe.prep_close(fd);
sqe.prep_statx(dirfd, path, flags, mask, &statx);

// Misc
sqe.prep_nop();  // no-op (for benchmarking)
sqe.prep_cancel(user_data, 0);  // cancel pending request
```

### Linked Operations

```zig
// Chain operations: second runs only if first succeeds
const sqe1 = try ring.get_sqe();
sqe1.prep_write(fd, header, 0);
sqe1.flags |= std.os.linux.IOSQE_IO_LINK;

const sqe2 = try ring.get_sqe();
sqe2.prep_write(fd, body, header.len);

_ = try ring.submit();
```

### Buffer Registration

```zig
// Register buffers for zero-copy I/O
var buffers: [16][4096]u8 = undefined;
var iovecs: [16]std.posix.iovec = undefined;
for (&iovecs, &buffers) |*iov, *buf| {
    iov.* = .{ .base = buf, .len = buf.len };
}

try ring.register_buffers(&iovecs);
defer ring.unregister_buffers() catch {};

// Use registered buffer
const sqe = try ring.get_sqe();
sqe.prep_read_fixed(fd, &buffers[0], 0, 0);  // buf_index = 0
```

### File Descriptor Registration

```zig
// Register FDs for faster access
var fds = [_]std.posix.fd_t{ fd1, fd2, fd3 };
try ring.register_files(&fds);
defer ring.unregister_files() catch {};

// Use with IOSQE_FIXED_FILE flag
const sqe = try ring.get_sqe();
sqe.prep_read(0, buf, 0);  // fd index, not actual fd
sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
```

## Common Functions

### getFdPath

Get canonical path from file descriptor (not all platforms).

```zig
var buf: [std.fs.max_path_bytes]u8 = undefined;
const path = try std.os.getFdPath(fd, &buf);
std.debug.print("Path: {s}\n", .{path});

// Check if supported at comptime
if (comptime std.os.isGetFdPathSupportedOnTarget(builtin.os)) {
    // safe to call
}
```

**Supported**: Linux, macOS, FreeBSD, Windows, Solaris/illumos, DragonFly (6.0+), NetBSD (10.0+)

### accessW (Windows)

Check file accessibility with WTF-16LE path.

```zig
const path_w = std.unicode.utf8ToUtf16LeStringLiteral("C:\\file.txt");
std.os.accessW(path_w) catch |err| switch (err) {
    error.FileNotFound => {},
    error.AccessDenied => {},
    else => return err,
};
```

### WASI stat functions

```zig
// stat by path
const stat = try std.os.fstatat_wasi(dirfd, path, .{ .SYMLINK_FOLLOW = true });

// stat by fd
const stat = try std.os.fstat_wasi(fd);

stat.size;      // file size
stat.filetype;  // .REGULAR_FILE, .DIRECTORY, .SYMBOLIC_LINK, etc.
stat.atim;      // access time (nanoseconds)
stat.mtim;      // modification time
stat.ctim;      // status change time
```

## Common Patterns

### Platform-Specific Code

```zig
const builtin = @import("builtin");

fn platformSpecific() !void {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            // Linux-specific code
        },
        .windows => {
            const windows = std.os.windows;
            // Windows-specific code
        },
        .wasi => {
            const wasi = std.os.wasi;
            // WASI-specific code
        },
        else => @compileError("Unsupported OS"),
    }
}
```

### io_uring Event Loop

```zig
fn eventLoop(ring: *std.os.linux.IoUring) !void {
    while (running) {
        // Submit pending and wait for completions
        _ = try ring.submit_and_wait(1);

        // Process all available completions
        while (ring.cq_ready() > 0) {
            const cqe = ring.peek_cqe() orelse break;
            defer ring.cq_advance(1);

            const ctx = @as(*Context, @ptrFromInt(cqe.user_data));
            try ctx.handle_completion(cqe.res);
        }
    }
}
```

### Handling Syscall Errors

```zig
const linux = std.os.linux;

fn readSyscall(fd: i32, buf: []u8) !usize {
    const result = linux.syscall3(.read, @intCast(fd), @intFromPtr(buf.ptr), buf.len);

    switch (linux.E.init(result)) {
        .SUCCESS => return result,
        .INTR => return error.Interrupted,
        .AGAIN => return error.WouldBlock,
        .BADF => return error.BadFileDescriptor,
        .FAULT => return error.BadAddress,
        .INVAL => return error.InvalidArgument,
        .IO => return error.InputOutput,
        .ISDIR => return error.IsDir,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}
```

### Windows Error Handling

```zig
const windows = std.os.windows;

fn windowsOperation() !void {
    const result = windows.kernel32.SomeFunction(...);
    if (result == windows.FALSE) {
        switch (windows.GetLastError()) {
            .ERROR_FILE_NOT_FOUND => return error.FileNotFound,
            .ERROR_ACCESS_DENIED => return error.AccessDenied,
            else => |e| return windows.unexpectedError(e),
        }
    }
}
```

### Cross-Platform File Descriptor Path

```zig
fn getFilePath(fd: std.posix.fd_t, allocator: Allocator) ![]u8 {
    if (comptime !std.os.isGetFdPathSupportedOnTarget(builtin.os)) {
        return error.Unsupported;
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.os.getFdPath(fd, &buf);
    return try allocator.dupe(u8, path);
}
```
