# std.http Reference (0.15.x)

HTTP client and server implementation with TLS, connection pooling, compression, and WebSocket support.

## Table of Contents
- [HTTP Client](#http-client)
- [HTTP Server](#http-server)
- [WebSocket](#websocket)
- [Core Types](#core-types)
- [Common Patterns](#common-patterns)

## HTTP Client

### Quick Fetch (Simple Requests)

```zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Simple GET - response body discarded
    const result = try client.fetch(.{
        .location = .{ .url = "https://example.com/api" },
    });
    std.debug.print("Status: {d}\n", .{@intFromEnum(result.status)});
}
```

### Fetch with Response Body

```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

// Create writer to capture response
var body_buf: [65536]u8 = undefined;
var body_writer: std.Io.Writer = .fixed(&body_buf);

const result = try client.fetch(.{
    .location = .{ .url = "https://api.example.com/data" },
    .response_writer = &body_writer,
});

const body = body_writer.buffered();
std.debug.print("Response ({d}): {s}\n", .{@intFromEnum(result.status), body});
```

### Fetch with POST Body

```zig
const result = try client.fetch(.{
    .location = .{ .url = "https://api.example.com/submit" },
    .method = .POST,
    .payload = "{\"key\": \"value\"}",
    .headers = .{
        .content_type = .{ .override = "application/json" },
    },
    .response_writer = &body_writer,
});
```

### Full Request Control

For more control over the request lifecycle:

```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

const uri = try std.Uri.parse("https://api.example.com/resource");

var req = try client.request(.GET, uri, .{
    .keep_alive = true,
    .headers = .{
        .authorization = .{ .override = "Bearer token123" },
    },
    .extra_headers = &.{
        .{ .name = "X-Custom-Header", .value = "custom-value" },
    },
});
defer req.deinit();

// Send request (no body for GET)
try req.sendBodiless();

// Receive response headers
var redirect_buf: [8192]u8 = undefined;
var response = try req.receiveHead(&redirect_buf);

std.debug.print("Status: {d} {s}\n", .{
    @intFromEnum(response.head.status),
    response.head.reason,
});

// Read response body
var reader_buf: [4096]u8 = undefined;
const body_reader = response.reader(&reader_buf);

while (true) {
    const chunk = body_reader.take(4096) catch |err| switch (err) {
        error.EndOfStream => break,
        else => return err,
    };
    // process chunk...
}
```

### POST with Request Body

```zig
var req = try client.request(.POST, uri, .{});
defer req.deinit();

// Set content length and send body
const body = "request body content";
try req.sendBodyComplete(@constCast(body));

// Or for streaming:
req.transfer_encoding = .{ .content_length = body.len };
var body_writer_buf: [1024]u8 = undefined;
var bw = try req.sendBody(&body_writer_buf);
try bw.writer.writeAll(body);
try bw.end();

var response = try req.receiveHead(&.{});
```

### Chunked Transfer Encoding

```zig
var req = try client.request(.POST, uri, .{});
defer req.deinit();

req.transfer_encoding = .chunked;
var body_writer_buf: [1024]u8 = undefined;
var bw = try req.sendBody(&body_writer_buf);

// Write chunks
try bw.writer.writeAll("first chunk");
try bw.writer.writeAll("second chunk");
try bw.end();  // Sends final chunk marker

var response = try req.receiveHead(&.{});
```

### Decompressing Response Bodies

```zig
var response = try req.receiveHead(&redirect_buf);

var transfer_buf: [64]u8 = undefined;
var decompress: std.http.Decompress = undefined;

// Allocate decompression buffer based on content encoding
const decompress_buf = switch (response.head.content_encoding) {
    .identity => &.{},
    .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
    .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
    .compress => return error.UnsupportedCompression,
};
defer if (decompress_buf.len > 0) allocator.free(decompress_buf);

const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
// reader now returns decompressed bytes
```

### Redirect Handling

```zig
var req = try client.request(.GET, uri, .{
    // Follow up to 5 redirects (default is 3)
    .redirect_behavior = .init(5),
    // Or disable redirects:
    // .redirect_behavior = .not_allowed,
    // Or handle manually:
    // .redirect_behavior = .unhandled,
});
defer req.deinit();

try req.sendBodiless();

// redirect_buf stores the redirect location URI
var redirect_buf: [8192]u8 = undefined;
var response = try req.receiveHead(&redirect_buf);

// After redirects, req.uri contains the final URI
std.debug.print("Final URL: {s}\n", .{req.uri.path.raw});
```

### Connection Pooling

Connections are automatically pooled and reused:

```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

// Configure pool size (default 32)
client.connection_pool.free_size = 64;

// Configure buffer sizes
client.read_buffer_size = 16384;  // default 8192
client.write_buffer_size = 2048;  // default 1024

// Connections are reused when host/port/protocol match
for (0..10) |_| {
    var req = try client.request(.GET, uri, .{ .keep_alive = true });
    defer req.deinit();
    // ... same connection reused
}
```

### Proxy Configuration

```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

// Load from environment (HTTP_PROXY, HTTPS_PROXY, etc.)
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
try client.initDefaultProxies(arena.allocator());

// Or configure manually:
var proxy: std.http.Proxy = .{
    .protocol = .plain,
    .host = "proxy.example.com",
    .port = 8080,
    .authorization = null,  // or "Basic base64credentials"
    .supports_connect = true,
};
client.http_proxy = &proxy;
```

### TLS Configuration

```zig
var client: std.http.Client = .{ .allocator = allocator };
defer client.deinit();

// TLS is enabled by default for https://
// Configure TLS buffer size (affects memory usage)
client.tls_buffer_size = std.crypto.tls.Client.min_buffer_len;

// Force certificate rescan on next HTTPS request
client.next_https_rescan_certs = true;

// Disable TLS at compile time via std.options.http_disable_tls
```

## HTTP Server

### Basic Server

```zig
const std = @import("std");
const net = std.net;
const http = std.http;

pub fn main() !void {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    var tcp_server = try address.listen(.{});
    defer tcp_server.deinit();

    while (true) {
        const conn = try tcp_server.accept();
        defer conn.stream.close();

        var read_buf: [8192]u8 = undefined;
        var write_buf: [4096]u8 = undefined;

        var reader = conn.stream.reader(&read_buf);
        var writer = conn.stream.writer(&write_buf);

        var server = http.Server.init(reader.interface(), &writer.interface);

        const request = server.receiveHead() catch |err| {
            std.debug.print("Failed to receive: {}\n", .{err});
            continue;
        };

        try handleRequest(&request);
    }
}

fn handleRequest(request: *http.Server.Request) !void {
    const head = request.head;
    std.debug.print("{s} {s}\n", .{@tagName(head.method), head.target});

    // Simple response
    try request.respond("Hello, World!", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
    });
}
```

### Reading Request Body

```zig
fn handleRequest(request: *http.Server.Request) !void {
    // Handle Expect: 100-continue
    var body_buf: [4096]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);

    // Read entire body
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    while (true) {
        const chunk = body_reader.take(1024) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try body.appendSlice(allocator, chunk);
    }

    try request.respond("Received", .{});
}
```

### Streaming Response

```zig
fn handleRequest(request: *http.Server.Request) !void {
    var response_buf: [4096]u8 = undefined;

    // Start streaming response (uses chunked transfer encoding by default)
    var body = try request.respondStreaming(&response_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        },
    });

    // Write chunks
    try body.writer.writeAll("data: chunk 1\n\n");
    try body.flush();

    try body.writer.writeAll("data: chunk 2\n\n");
    try body.end();  // Finishes chunked response
}
```

### Response with Known Length

```zig
fn handleRequest(request: *http.Server.Request) !void {
    const content = "Fixed length response";

    var response_buf: [1024]u8 = undefined;
    var body = try request.respondStreaming(&response_buf, .{
        .content_length = content.len,  // Uses Content-Length instead of chunked
        .respond_options = .{ .status = .ok },
    });

    try body.writer.writeAll(content);
    try body.end();
}
```

### Iterating Headers

```zig
fn handleRequest(request: *http.Server.Request) !void {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        std.debug.print("{s}: {s}\n", .{header.name, header.value});
    }

    try request.respond("OK", .{});
}
```

## WebSocket

### Server-Side WebSocket Upgrade

```zig
fn handleRequest(request: *http.Server.Request) !void {
    const upgrade = request.upgradeRequested();

    switch (upgrade) {
        .websocket => |key| {
            if (key) |k| {
                var ws = try request.respondWebSocket(.{ .key = k });
                try handleWebSocket(&ws);
            } else {
                try request.respond("Missing key", .{ .status = .bad_request });
            }
        },
        .other => |name| {
            std.debug.print("Unknown upgrade: {s}\n", .{name});
            try request.respond("Not supported", .{ .status = .bad_request });
        },
        .none => {
            try request.respond("Expected WebSocket", .{ .status = .bad_request });
        },
    }
}

fn handleWebSocket(ws: *http.Server.WebSocket) !void {
    try ws.flush();  // Send upgrade response

    while (true) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => break,
            else => return err,
        };

        switch (msg.opcode) {
            .text, .binary => {
                // Echo back
                try ws.writeMessage(msg.data, msg.opcode);
            },
            .ping => {
                try ws.writeMessage(msg.data, .pong);
            },
            else => {},
        }
    }
}
```

### WebSocket Message Types

```zig
// Opcodes
const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
};

// Write different message types
try ws.writeMessage("Hello", .text);
try ws.writeMessage(&binary_data, .binary);
try ws.writeMessage("", .ping);

// Unflushed writes (batch multiple messages)
try ws.writeMessageUnflushed("msg1", .text);
try ws.writeMessageUnflushed("msg2", .text);
try ws.flush();
```

## Core Types

### HTTP Methods

```zig
const Method = enum {
    GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH,

    pub fn requestHasBody(m: Method) bool;   // POST, PUT, PATCH
    pub fn responseHasBody(m: Method) bool;  // GET, POST, DELETE, CONNECT, OPTIONS, PATCH
    pub fn safe(m: Method) bool;             // GET, HEAD, OPTIONS, TRACE
    pub fn idempotent(m: Method) bool;       // GET, HEAD, PUT, DELETE, OPTIONS, TRACE
    pub fn cacheable(m: Method) bool;        // GET, HEAD
};
```

### HTTP Status Codes

```zig
const Status = enum(u10) {
    // 1xx Informational
    @"continue" = 100,
    switching_protocols = 101,

    // 2xx Success
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,

    // 3xx Redirection
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,

    // 4xx Client Error
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    too_many_requests = 429,

    // 5xx Server Error
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,

    _,  // Non-exhaustive for custom codes

    pub fn phrase(self: Status) ?[]const u8;
    pub fn class(self: Status) Class;
};

const Class = enum { informational, success, redirect, client_error, server_error };
```

### Content Encoding

```zig
const ContentEncoding = enum {
    zstd,
    gzip,
    deflate,
    compress,
    identity,

    pub fn fromString(s: []const u8) ?ContentEncoding;
    pub fn minBufferCapacity(ce: ContentEncoding) usize;
};
```

### Transfer Encoding

```zig
const TransferEncoding = enum {
    chunked,
    none,
};
```

### Header Struct

```zig
const Header = struct {
    name: []const u8,
    value: []const u8,
};
```

## Common Patterns

### JSON API Client

```zig
fn fetchJson(comptime T: type, allocator: Allocator, url: []const u8) !T {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body_buf: [65536]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &body_writer,
    });

    if (result.status != .ok) return error.HttpError;

    const parsed = try std.json.parseFromSlice(T, allocator, body_writer.buffered(), .{});
    return parsed.value;
}
```

### POST JSON Data

```zig
fn postJson(allocator: Allocator, url: []const u8, data: anytype) !void {
    const json = try std.json.stringifyAlloc(allocator, data, .{});
    defer allocator.free(json);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = json,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });

    if (result.status.class() != .success) return error.HttpError;
}
```

### Download File

```zig
fn downloadFile(allocator: Allocator, url: []const u8, path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) return error.HttpError;

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buf);

    var reader_buf: [4096]u8 = undefined;
    const body_reader = response.reader(&reader_buf);

    _ = body_reader.streamRemaining(&file_writer.interface) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => return err,
    };

    try file_writer.interface.flush();
}
```

### Simple REST Server

```zig
fn handleApi(request: *http.Server.Request) !void {
    const head = request.head;

    if (std.mem.eql(u8, head.target, "/api/health")) {
        try request.respond("{\"status\":\"ok\"}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        return;
    }

    if (std.mem.startsWith(u8, head.target, "/api/users")) {
        switch (head.method) {
            .GET => try handleGetUsers(request),
            .POST => try handleCreateUser(request),
            else => try request.respond("", .{ .status = .method_not_allowed }),
        }
        return;
    }

    try request.respond("Not Found", .{ .status = .not_found });
}
```

### Error Handling

```zig
fn makeRequest(client: *std.http.Client, uri: std.Uri) ![]const u8 {
    var req = client.request(.GET, uri, .{}) catch |err| switch (err) {
        error.ConnectionRefused => return error.ServerDown,
        error.TlsInitializationFailed => return error.TlsError,
        error.UnknownHostName => return error.DnsError,
        else => return err,
    };
    defer req.deinit();

    try req.sendBodiless();

    var buf: [8192]u8 = undefined;
    var response = req.receiveHead(&buf) catch |err| switch (err) {
        error.HttpHeadersOversize => return error.ResponseTooLarge,
        error.HttpHeadersInvalid => return error.MalformedResponse,
        error.TooManyHttpRedirects => return error.RedirectLoop,
        else => return err,
    };

    if (response.head.status.class() != .success) {
        return error.HttpError;
    }

    // ...
}
```
