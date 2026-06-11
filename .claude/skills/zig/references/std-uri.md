# std.Uri Reference (0.15.x)

URI parsing and formatting conforming to RFC 3986, with percent-encoding/decoding and resolution support.

## Table of Contents
- [Parsing URIs](#parsing-uris)
- [URI Components](#uri-components)
- [Formatting URIs](#formatting-uris)
- [Percent Encoding/Decoding](#percent-encodingdecoding)
- [URI Resolution](#uri-resolution)
- [Common Patterns](#common-patterns)

## Parsing URIs

### Basic Parsing

```zig
const std = @import("std");

pub fn main() !void {
    const uri = try std.Uri.parse("https://user:pass@example.com:8080/path?query=1#fragment");

    std.debug.print("Scheme: {s}\n", .{uri.scheme});                    // "https"
    std.debug.print("User: {s}\n", .{uri.user.?.percent_encoded});      // "user"
    std.debug.print("Password: {s}\n", .{uri.password.?.percent_encoded}); // "pass"
    std.debug.print("Host: {s}\n", .{uri.host.?.percent_encoded});      // "example.com"
    std.debug.print("Port: {d}\n", .{uri.port.?});                      // 8080
    std.debug.print("Path: {s}\n", .{uri.path.percent_encoded});        // "/path"
    std.debug.print("Query: {s}\n", .{uri.query.?.percent_encoded});    // "query=1"
    std.debug.print("Fragment: {s}\n", .{uri.fragment.?.percent_encoded}); // "fragment"
}
```

### Parse After Scheme

For URIs where scheme is already known (e.g., HTTP redirects):

```zig
// Parse "//example.com/path" as an HTTP URI
const uri = try std.Uri.parseAfterScheme("http", "//example.com/path");
std.debug.print("Scheme: {s}, Host: {s}\n", .{
    uri.scheme,
    uri.host.?.percent_encoded,
});
```

### Error Handling

```zig
const uri = std.Uri.parse(input) catch |err| switch (err) {
    error.UnexpectedCharacter => {
        std.debug.print("Invalid character in URI\n", .{});
        return err;
    },
    error.InvalidFormat => {
        std.debug.print("Malformed URI\n", .{});
        return err;
    },
    error.InvalidPort => {
        std.debug.print("Port not a valid u16\n", .{});
        return err;
    },
};
```

## URI Components

### Uri Struct

```zig
const Uri = struct {
    scheme: []const u8,
    user: ?Component = null,
    password: ?Component = null,
    host: ?Component = null,
    port: ?u16 = null,
    path: Component = Component.empty,
    query: ?Component = null,
    fragment: ?Component = null,

    pub const host_name_max = 255;
};
```

### Component Union

Components can be raw (needs encoding) or already percent-encoded:

```zig
const Component = union(enum) {
    /// Needs percent encoding before use in URI
    raw: []const u8,
    /// Already percent-encoded, can be used directly
    percent_encoded: []const u8,

    pub const empty: Component = .{ .percent_encoded = "" };

    pub fn isEmpty(component: Component) bool;
};
```

### Getting Host

```zig
var buffer: [std.Uri.host_name_max]u8 = undefined;
const host = uri.getHost(&buffer) catch |err| switch (err) {
    error.UriMissingHost => return error.NoHost,
    error.UriHostTooLong => return error.HostTooLong,
};
```

With allocation:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const host = try uri.getHostAlloc(arena.allocator());
```

### Creating URIs Programmatically

```zig
const uri: std.Uri = .{
    .scheme = "https",
    .host = .{ .raw = "example.com" },
    .port = 8080,
    .path = .{ .raw = "/api/users" },
    .query = .{ .raw = "page=1&limit=10" },
};
```

### Component Methods

```zig
const component: std.Uri.Component = .{ .percent_encoded = "hello%20world" };

// Check if empty
if (component.isEmpty()) {
    // ...
}

// Get raw (decoded) value with buffer
var buf: [256]u8 = undefined;
const raw = try component.toRaw(&buf);  // "hello world"

// Get raw (decoded) value with allocation (only allocates if needed)
const raw_alloc = try component.toRawMaybeAlloc(allocator);  // "hello world"
```

## Formatting URIs

### Full URI

```zig
const uri = try std.Uri.parse("https://example.com:8080/path?query#frag");

var buf: [1024]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try uri.format(&writer);
const formatted = writer.buffered();  // "https://example.com:8080/path?query#frag"
```

### Selective Formatting

```zig
var buf: [1024]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);

// Format only specific parts
try std.fmt.format(&writer, "{f}", .{uri.fmt(.{
    .scheme = true,
    .authority = true,
    .path = true,
    .query = true,
    .fragment = false,  // omit fragment
})});
```

### Format Flags

```zig
const Flags = struct {
    scheme: bool = false,         // Include scheme (e.g., "https:")
    authentication: bool = false, // Include user:password@ (requires authority)
    authority: bool = false,      // Include host and port
    path: bool = false,           // Include path
    query: bool = false,          // Include ?query (requires path)
    fragment: bool = false,       // Include #fragment (requires path)
    port: bool = true,            // Include :port (requires authority)

    pub const all: Flags = .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
        .fragment = true,
        .port = true,
    };
};
```

### Component Formatting Methods

```zig
var buf: [256]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);

const component: std.Uri.Component = .{ .raw = "hello world" };

// Different encoding rules for different URI parts
try component.formatEscaped(&writer);  // General: unreserved chars only
try component.formatUser(&writer);     // User: unreserved + sub-delims
try component.formatPassword(&writer); // Password: user chars + ':'
try component.formatHost(&writer);     // Host: password chars + '[' + ']'
try component.formatPath(&writer);     // Path: user chars + '/' + ':' + '@'
try component.formatQuery(&writer);    // Query: path chars + '?'
try component.formatFragment(&writer); // Fragment: same as query

// Get raw (decoded) output
try component.formatRaw(&writer);      // Decodes percent-encoded chars
```

## Percent Encoding/Decoding

### Decode In Place

```zig
var buffer = "hello%20world%21".*;
const decoded = std.Uri.percentDecodeInPlace(&buffer);
// decoded == "hello world!"
```

### Decode Backwards (Safe for Aliasing)

```zig
const input = "%48%65%6C%6C%6F";
var output: [5]u8 = undefined;
const decoded = std.Uri.percentDecodeBackwards(&output, input);
// decoded == "Hello"
```

### Encode with Component

```zig
var buf: [256]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);

// Raw component will be percent-encoded when formatted
const component: std.Uri.Component = .{ .raw = "hello world!" };
try component.formatPath(&writer);
const encoded = writer.buffered();  // "hello%20world%21"
```

### Custom Percent Encoding

```zig
var buf: [256]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);

// Encode with custom character validation
std.Uri.Component.percentEncode(&writer, "custom data", struct {
    fn isValid(c: u8) bool {
        return std.ascii.isAlphanumeric(c);
    }
}.isValid);
```

## URI Resolution

### Resolve Relative URI

Resolves a relative URI against a base URI per RFC 3986 Section 5:

```zig
const base = try std.Uri.parse("http://a/b/c/d;p?q");

var aux_buf: [1024]u8 = undefined;
var aux_slice: []u8 = &aux_buf;

// Copy relative URI to start of aux_buf
const relative = "../g";
@memcpy(aux_buf[0..relative.len], relative);

const resolved = try std.Uri.resolveInPlace(base, relative.len, &aux_slice);
// resolved.path.percent_encoded == "/a/g"
```

### Resolution Examples (RFC 3986)

| Base: `http://a/b/c/d;p?q` | Reference | Result |
|---------------------------|-----------|--------|
| | `g` | `http://a/b/c/g` |
| | `./g` | `http://a/b/c/g` |
| | `g/` | `http://a/b/c/g/` |
| | `/g` | `http://a/g` |
| | `//g` | `http://g` |
| | `?y` | `http://a/b/c/d;p?y` |
| | `g?y` | `http://a/b/c/g?y` |
| | `#s` | `http://a/b/c/d;p?q#s` |
| | `g#s` | `http://a/b/c/g#s` |
| | `../` | `http://a/b/` |
| | `../g` | `http://a/b/g` |
| | `../../g` | `http://a/g` |

## Common Patterns

### Extract Query Parameters

```zig
fn getQueryParam(uri: std.Uri, key: []const u8) ?[]const u8 {
    const query = uri.query orelse return null;
    const query_str = query.percent_encoded;

    var iter = std.mem.splitScalar(u8, query_str, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            if (std.mem.eql(u8, pair[0..eq_pos], key)) {
                return pair[eq_pos + 1 ..];
            }
        } else if (std.mem.eql(u8, pair, key)) {
            return "";  // Key exists with no value
        }
    }
    return null;
}

// Usage
const uri = try std.Uri.parse("https://example.com?name=alice&age=30");
const name = getQueryParam(uri, "name");  // "alice"
```

### Build URL with Query Parameters

```zig
fn buildUrl(allocator: Allocator, base: []const u8, params: []const [2][]const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, base);

    for (params, 0..) |param, i| {
        try result.append(allocator, if (i == 0) '?' else '&');

        // Encode key
        for (param[0]) |c| {
            if (std.Uri.isUnreserved(c)) {
                try result.append(allocator, c);
            } else {
                try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "%{X:0>2}", .{c}));
            }
        }

        try result.append(allocator, '=');

        // Encode value
        for (param[1]) |c| {
            if (std.Uri.isUnreserved(c)) {
                try result.append(allocator, c);
            } else {
                try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "%{X:0>2}", .{c}));
            }
        }
    }

    return result.toOwnedSlice(allocator);
}
```

### Normalize URI

```zig
fn normalizeUri(allocator: Allocator, uri_str: []const u8) ![]u8 {
    const uri = try std.Uri.parse(uri_str);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Format with all components to normalize encoding
    try uri.format(&writer);

    return try allocator.dupe(u8, writer.buffered());
}
```

### Validate URI

```zig
fn isValidUri(str: []const u8) bool {
    _ = std.Uri.parse(str) catch return false;
    return true;
}

fn isValidHttpUri(str: []const u8) bool {
    const uri = std.Uri.parse(str) catch return false;
    return std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https");
}
```

### Join Path Segments

```zig
fn joinPath(allocator: Allocator, base_uri: std.Uri, segments: []const []const u8) !std.Uri {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(allocator);

    // Start with base path (remove trailing slash if any)
    const base_path = base_uri.path.percent_encoded;
    if (base_path.len > 0 and base_path[base_path.len - 1] == '/') {
        try path.appendSlice(allocator, base_path[0 .. base_path.len - 1]);
    } else {
        try path.appendSlice(allocator, base_path);
    }

    // Append segments
    for (segments) |seg| {
        try path.append(allocator, '/');
        try path.appendSlice(allocator, seg);
    }

    var result = base_uri;
    result.path = .{ .percent_encoded = try path.toOwnedSlice(allocator) };
    result.query = null;
    result.fragment = null;
    return result;
}
```

### Extract Base URL

```zig
fn getBaseUrl(allocator: Allocator, uri: std.Uri) ![]u8 {
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try std.fmt.format(&writer, "{f}", .{uri.fmt(.{
        .scheme = true,
        .authority = true,
        .port = true,
    })});

    return try allocator.dupe(u8, writer.buffered());
}

// Usage
const uri = try std.Uri.parse("https://example.com:8080/path?query#frag");
const base = try getBaseUrl(allocator, uri);  // "https://example.com:8080"
```

## Error Types

### ParseError

```zig
pub const ParseError = error{
    UnexpectedCharacter,  // Invalid character in URI component
    InvalidFormat,        // Malformed URI structure
    InvalidPort,          // Port not a valid u16
};
```

### ResolveInPlaceError

```zig
pub const ResolveInPlaceError = ParseError || error{
    NoSpaceLeft,  // Auxiliary buffer too small
};
```

### Component Errors

```zig
// getHost errors
error.UriMissingHost   // URI has no host component
error.UriHostTooLong   // Host exceeds host_name_max (255)

// toRaw errors
error.NoSpaceLeft      // Buffer too small for decoded string
```
