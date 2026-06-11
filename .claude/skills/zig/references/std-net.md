# std.net Reference (0.15.x)

Cross-platform networking abstractions for TCP/IP connections, address handling, and DNS resolution.

## Table of Contents
- [TCP Client](#tcp-client)
- [TCP Server](#tcp-server)
- [Address Types](#address-types)
- [Stream I/O](#stream-io)
- [DNS Resolution](#dns-resolution)
- [Unix Sockets](#unix-sockets)
- [Common Patterns](#common-patterns)

## TCP Client

### Connect by Hostname

```zig
const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to host:port (handles DNS resolution)
    const stream = try net.tcpConnectToHost(allocator, "example.com", 80);
    defer stream.close();

    // Create buffered reader/writer
    var read_buf: [4096]u8 = undefined;
    var write_buf: [1024]u8 = undefined;

    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);

    // Write request
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");
    try writer.interface.flush();

    // Read response
    while (reader.interface().take(4096)) |chunk| {
        std.debug.print("{s}", .{chunk});
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}
```

### Connect by Address

```zig
// Parse and connect to IP address directly (no DNS)
const address = try net.Address.parseIp4("192.168.1.1", 8080);
const stream = try net.tcpConnectToAddress(address);
defer stream.close();
```

### Connect with IPv6

```zig
// IPv6 address
const addr6 = try net.Address.parseIp6("::1", 8080);
const stream = try net.tcpConnectToAddress(addr6);
defer stream.close();

// IPv6 with scope ID (link-local)
const link_local = try net.Address.resolveIp6("fe80::1%eth0", 8080);
```

## TCP Server

### Basic Server

```zig
const std = @import("std");
const net = std.net;

pub fn main() !void {
    // Create address to listen on
    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 8080);

    // Start listening
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Listening on port {d}\n", .{server.listen_address.getPort()});

    // Accept loop
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        // Handle connection
        try handleClient(conn.stream, conn.address);
    }
}

fn handleClient(stream: net.Stream, client_addr: net.Address) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [1024]u8 = undefined;

    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);

    // Read request
    const request = reader.interface().takeDelimiter('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    } orelse return;

    std.debug.print("Request from client: {s}\n", .{request});

    // Send response
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello");
    try writer.interface.flush();
}
```

### Listen Options

```zig
const server = try address.listen(.{
    // Allow address reuse (SO_REUSEADDR + SO_REUSEPORT on POSIX)
    .reuse_address = true,

    // Connection backlog (default 128)
    .kernel_backlog = 256,

    // Non-blocking accept (O_NONBLOCK)
    .force_nonblocking = false,
});
```

### Server on Any Available Port

```zig
// Listen on port 0 to let OS assign an available port
const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
var server = try address.listen(.{});
defer server.deinit();

// Get the assigned port
const port = server.listen_address.getPort();
std.debug.print("Listening on port {d}\n", .{port});
```

## Address Types

### Address Union

```zig
pub const Address = extern union {
    any: posix.sockaddr,
    in: Ip4Address,
    in6: Ip6Address,
    un: posix.sockaddr.un,  // Unix socket (if supported)
};
```

### Creating Addresses

```zig
// IPv4 from bytes
const addr4 = net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);

// IPv6 from bytes
const addr6 = net.Address.initIp6(
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },  // ::1
    8080,      // port
    0,         // flowinfo
    0,         // scope_id
);

// Unix socket
const unix = try net.Address.initUnix("/tmp/my.sock");
```

### Parsing Addresses

```zig
// Parse IPv4
const addr4 = try net.Address.parseIp4("192.168.1.1", 8080);

// Parse IPv6
const addr6 = try net.Address.parseIp6("2001:db8::1", 8080);

// Parse either (tries IPv4 first, then IPv6)
const addr = try net.Address.parseIp("::1", 8080);

// Parse IP:port format
// IPv4: "192.168.1.1:8080"
// IPv6: "[::1]:8080" (brackets required)
const addr_port = try net.Address.parseIpAndPort("[::1]:8080");

// Resolve with interface lookup (for link-local IPv6)
const resolved = try net.Address.resolveIp6("fe80::1%eth0", 8080);
```

### Address Methods

```zig
var addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);

// Get/set port (native endian)
const port = addr.getPort();  // 8080
addr.setPort(9090);

// Get socket length for syscalls
const socklen = addr.getOsSockLen();

// Compare addresses
if (addr.eql(other_addr)) {
    // addresses match
}

// Format for printing
var buf: [64]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try addr.format(&writer);
const formatted = writer.buffered();  // "127.0.0.1:8080"
```

### Ip4Address

```zig
const Ip4Address = extern struct {
    sa: posix.sockaddr.in,

    pub fn parse(buf: []const u8, port: u16) !Ip4Address;
    pub fn init(addr: [4]u8, port: u16) Ip4Address;
    pub fn getPort(self: Ip4Address) u16;
    pub fn setPort(self: *Ip4Address, port: u16) void;
    pub fn format(self: Ip4Address, w: *std.Io.Writer) !void;
};
```

### Ip6Address

```zig
const Ip6Address = extern struct {
    sa: posix.sockaddr.in6,

    pub fn parse(buf: []const u8, port: u16) !Ip6Address;
    pub fn resolve(buf: []const u8, port: u16) !Ip6Address;  // handles %interface
    pub fn init(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Ip6Address;
    pub fn getPort(self: Ip6Address) u16;
    pub fn setPort(self: *Ip6Address, port: u16) void;
    pub fn format(self: Ip6Address, w: *std.Io.Writer) !void;
};
```

## Stream I/O

### Stream Type

```zig
pub const Stream = struct {
    handle: Handle,  // fd on POSIX, SOCKET on Windows

    pub fn close(s: Stream) void;
    pub fn reader(stream: Stream, buffer: []u8) Reader;
    pub fn writer(stream: Stream, buffer: []u8) Writer;
};
```

### Reading from Stream

```zig
const stream = try net.tcpConnectToHost(allocator, "example.com", 80);
defer stream.close();

var buf: [4096]u8 = undefined;
var reader = stream.reader(&buf);
const r = reader.interface();

// Read bytes
const data = r.take(100) catch |err| switch (err) {
    error.EndOfStream => &.{},
    error.ReadFailed => return reader.getError().?,
};

// Read until delimiter
const line = r.takeDelimiter('\n') catch |err| switch (err) {
    error.EndOfStream => null,
    error.StreamTooLong => return error.LineTooLong,
    error.ReadFailed => return reader.getError().?,
} orelse return;

// Discard bytes
_ = try r.discard(.limited(100));

// Stream to writer
_ = try r.streamRemaining(&output_writer);
```

### Writing to Stream

```zig
var buf: [1024]u8 = undefined;
var writer = stream.writer(&buf);
const w = &writer.interface;

// Write bytes
try w.writeAll("Hello, World!");

// Formatted output
try w.print("Count: {d}\n", .{42});

// MUST flush before close
try w.flush();
```

### Error Handling

```zig
var reader = stream.reader(&buf);
const r = reader.interface();

const data = r.take(100) catch |err| switch (err) {
    error.EndOfStream => {
        // Connection closed normally
        return;
    },
    error.ReadFailed => {
        // Get underlying error
        const read_err = reader.getError().?;
        switch (read_err) {
            error.ConnectionResetByPeer => return error.Disconnected,
            error.SocketNotConnected => return error.Disconnected,
            else => return read_err,
        }
    },
};
```

## DNS Resolution

### Get Address List

```zig
const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Resolve hostname to addresses
    const list = try net.getAddressList(allocator, "example.com", 80);
    defer list.deinit();

    // Canonical name (if available)
    if (list.canon_name) |name| {
        std.debug.print("Canonical name: {s}\n", .{name});
    }

    // Iterate addresses
    for (list.addrs) |addr| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try addr.format(&w);
        std.debug.print("Address: {s}\n", .{w.buffered()});
    }
}
```

### Connect with Fallback

`tcpConnectToHost` automatically tries all resolved addresses:

```zig
// Tries each resolved address until one connects
const stream = net.tcpConnectToHost(allocator, "example.com", 80) catch |err| switch (err) {
    error.ConnectionRefused => return error.ServerDown,
    error.UnknownHostName => return error.DnsError,
    error.TemporaryNameServerFailure => return error.DnsError,
    else => return err,
};
```

## Unix Sockets

### Check Platform Support

```zig
if (net.has_unix_sockets) {
    // Unix sockets available
}
```

### Connect to Unix Socket

```zig
const stream = try net.connectUnixSocket("/var/run/app.sock");
defer stream.close();

var buf: [4096]u8 = undefined;
var reader = stream.reader(&buf);
var writer = stream.writer(&buf);
// ... use like TCP
```

### Unix Socket Server

```zig
const address = try net.Address.initUnix("/tmp/my.sock");
var server = try address.listen(.{ .reuse_address = true });
defer server.deinit();

// Remove socket file on cleanup
defer std.fs.deleteFileAbsolute("/tmp/my.sock") catch {};

while (true) {
    const conn = try server.accept();
    defer conn.stream.close();
    // handle connection...
}
```

## Common Patterns

### Echo Server

```zig
const std = @import("std");
const net = std.net;

pub fn main() !void {
    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 7);  // echo port
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        var buf: [4096]u8 = undefined;
        var reader = conn.stream.reader(&buf);
        var writer = conn.stream.writer(&buf);

        // Echo back everything received
        _ = reader.interface().streamRemaining(&writer.interface) catch {};
        writer.interface.flush() catch {};
    }
}
```

### Simple HTTP GET

```zig
fn httpGet(allocator: Allocator, host: []const u8, path: []const u8) ![]u8 {
    const stream = try net.tcpConnectToHost(allocator, host, 80);
    defer stream.close();

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(&write_buf);
    const w = &writer.interface;

    try w.print("GET {s} HTTP/1.1\r\n", .{path});
    try w.print("Host: {s}\r\n", .{host});
    try w.writeAll("Connection: close\r\n\r\n");
    try w.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(&read_buf);

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);

    while (true) {
        const chunk = reader.interface().take(4096) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.getError().?,
        };
        try response.appendSlice(allocator, chunk);
    }

    return response.toOwnedSlice(allocator);
}
```

### Non-blocking Accept with Timeout

```zig
const std = @import("std");
const net = std.net;
const posix = std.posix;

fn acceptWithTimeout(server: *net.Server, timeout_ms: i32) !?net.Server.Connection {
    var pfd = [1]posix.pollfd{.{
        .fd = server.stream.handle,
        .events = posix.POLL.IN,
        .revents = undefined,
    }};

    const ready = try posix.poll(&pfd, timeout_ms);
    if (ready == 0) return null;  // timeout

    return try server.accept();
}
```

### Address Validation

```zig
fn isValidIpAddress(str: []const u8) bool {
    _ = net.Address.parseIp(str, 0) catch return false;
    return true;
}

fn isValidHostname(hostname: []const u8) bool {
    return net.isValidHostName(hostname);
}
```

### Dual-Stack Server (IPv4 + IPv6)

```zig
// Listen on IPv6 with dual-stack (accepts both IPv4 and IPv6)
const address = net.Address.initIp6(
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },  // ::
    8080,
    0,
    0,
);

var server = try address.listen(.{ .reuse_address = true });
defer server.deinit();

// IPv4 clients appear as IPv4-mapped IPv6 addresses (::ffff:x.x.x.x)
```

### Connection Pool Pattern

```zig
const Connection = struct {
    stream: net.Stream,
    in_use: bool,
};

const Pool = struct {
    connections: std.ArrayList(Connection),
    allocator: Allocator,

    pub fn acquire(self: *Pool, address: net.Address) !net.Stream {
        // Find free connection
        for (self.connections.items) |*conn| {
            if (!conn.in_use) {
                conn.in_use = true;
                return conn.stream;
            }
        }
        // Create new connection
        const stream = try net.tcpConnectToAddress(address);
        try self.connections.append(self.allocator, .{
            .stream = stream,
            .in_use = true,
        });
        return stream;
    }

    pub fn release(self: *Pool, stream: net.Stream) void {
        for (self.connections.items) |*conn| {
            if (conn.stream.handle == stream.handle) {
                conn.in_use = false;
                return;
            }
        }
    }

    pub fn deinit(self: *Pool) void {
        for (self.connections.items) |conn| {
            conn.stream.close();
        }
        self.connections.deinit(self.allocator);
    }
};
```

## Error Types

### Connection Errors

```zig
pub const TcpConnectToHostError = GetAddressListError || TcpConnectToAddressError;

pub const TcpConnectToAddressError = posix.SocketError || posix.ConnectError;
// Includes: ConnectionRefused, NetworkUnreachable, ConnectionTimedOut, etc.
```

### DNS Errors

```zig
pub const GetAddressListError = error{
    TemporaryNameServerFailure,
    NameServerFailure,
    AddressFamilyNotSupported,
    UnknownHostName,
    HostLacksNetworkAddresses,
    // ... and others
};
```

### Address Parse Errors

```zig
pub const IPv4ParseError = error{
    Overflow,
    InvalidEnd,
    InvalidCharacter,
    Incomplete,
    NonCanonical,  // e.g., leading zeros like "01.02.03.04"
};

pub const IPv6ParseError = error{
    Overflow,
    InvalidEnd,
    InvalidCharacter,
    Incomplete,
    InvalidIpv4Mapping,
};
```
