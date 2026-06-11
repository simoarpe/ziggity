# std.Tz - TZif Timezone Database Parsing

Parse IANA Time Zone Database files (TZif format, RFC 8536). Used to look up UTC offsets, DST rules, and timezone abbreviations.

## Quick Reference

| Type | Description |
|------|-------------|
| `Tz` | Parsed timezone with transitions, time types, and leap seconds |
| `Transition` | Point in time when timezone rules change |
| `Timetype` | Timezone offset, DST flag, and abbreviation |
| `Leapsecond` | Leap second occurrence and cumulative correction |

## Basic Usage

```zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open system timezone file
    const file = try std.fs.openFileAbsolute("/usr/share/zoneinfo/America/New_York", .{});
    defer file.close();

    // Parse TZif data
    var tz = try std.Tz.parse(allocator, file.reader());
    defer tz.deinit();

    // Access timezone information
    std.debug.print("Transitions: {}\n", .{tz.transitions.len});
    std.debug.print("Footer (POSIX TZ): {s}\n", .{tz.footer orelse "(none)"});
}
```

## Parsing from Embedded Data

```zig
const std = @import("std");

// Embed TZif file at compile time
const tokyo_tz = @embedFile("tz/asia_tokyo.tzif");

pub fn main() !void {
    var stream = std.io.fixedBufferStream(tokyo_tz);
    var tz = try std.Tz.parse(std.heap.page_allocator, stream.reader());
    defer tz.deinit();

    // Use timezone data...
}
```

## Tz Struct

```zig
pub const Tz = struct {
    allocator: std.mem.Allocator,
    transitions: []const Transition,  // Sorted by timestamp
    timetypes: []const Timetype,
    leapseconds: []const Leapsecond,
    footer: ?[]const u8,              // POSIX TZ string for future dates

    pub fn parse(allocator: std.mem.Allocator, reader: anytype) !Tz
    pub fn deinit(self: *Tz) void
};
```

## Transition

A transition marks when timezone rules change (e.g., DST start/end):

```zig
pub const Transition = struct {
    ts: i64,              // Unix timestamp (seconds since epoch)
    timetype: *Timetype,  // Pointer to active time type after this transition
};
```

## Timetype

Describes timezone offset and DST status:

```zig
pub const Timetype = struct {
    offset: i32,          // UTC offset in seconds (e.g., -18000 for EST = UTC-5)
    flags: u8,            // Packed flags
    name_data: [6:0]u8,   // Null-terminated abbreviation (e.g., "EST", "PDT")

    pub fn name(self: *const Timetype) [:0]const u8  // Get abbreviation
    pub fn isDst(self: Timetype) bool                // Is daylight saving time?
    pub fn standardTimeIndicator(self: Timetype) bool
    pub fn utIndicator(self: Timetype) bool
};
```

## Leapsecond

Leap second corrections for TAI-UTC:

```zig
pub const Leapsecond = struct {
    occurrence: i48,  // Unix timestamp when leap second occurs
    correction: i16,  // Cumulative TAI-UTC difference
};
```

## Look Up Current Timezone Offset

```zig
fn getUtcOffset(tz: *const std.Tz, unix_timestamp: i64) i32 {
    // Find the last transition before or at the given timestamp
    var result: ?*const std.Timetype = null;

    for (tz.transitions) |t| {
        if (t.ts <= unix_timestamp) {
            result = t.timetype;
        } else {
            break;
        }
    }

    // Return offset or default to first timetype
    if (result) |tt| {
        return tt.offset;
    } else if (tz.timetypes.len > 0) {
        return tz.timetypes[0].offset;
    }
    return 0;
}

// Usage
const offset = getUtcOffset(&tz, std.time.timestamp());
const local_time = unix_timestamp + offset;
```

## Check if DST is Active

```zig
fn isDstActive(tz: *const std.Tz, unix_timestamp: i64) bool {
    for (tz.transitions) |t| {
        if (t.ts <= unix_timestamp) {
            if (t.timetype.isDst()) return true;
        } else {
            break;
        }
    }
    return false;
}
```

## Get Timezone Abbreviation

```zig
fn getTimezoneAbbrev(tz: *const std.Tz, unix_timestamp: i64) []const u8 {
    var result: ?*const std.Timetype = null;

    for (tz.transitions) |t| {
        if (t.ts <= unix_timestamp) {
            result = t.timetype;
        } else {
            break;
        }
    }

    if (result) |tt| {
        return tt.name();
    } else if (tz.timetypes.len > 0) {
        return tz.timetypes[0].name();
    }
    return "UTC";
}

// Returns "EST", "EDT", "PST", "PDT", "JST", etc.
```

## List All Transitions

```zig
fn printTransitions(tz: *const std.Tz) void {
    for (tz.transitions) |t| {
        std.debug.print("{d}: {s} (offset {d}s, DST: {})\n", .{
            t.ts,
            t.timetype.name(),
            t.timetype.offset,
            t.timetype.isDst(),
        });
    }
}
```

## Parse Errors

| Error | Cause |
|-------|-------|
| `error.BadHeader` | Invalid TZif magic bytes (not "TZif") |
| `error.BadVersion` | Unsupported TZif version (only 0, 2, 3 supported) |
| `error.Malformed` | RFC 8536 validation failure |
| `error.OverlargeFooter` | POSIX TZ string exceeds 128 bytes |

## System Timezone Paths

| Platform | Path |
|----------|------|
| Linux/BSD | `/usr/share/zoneinfo/<Region>/<City>` |
| macOS | `/var/db/timezone/zoneinfo/<Region>/<City>` |

Common timezone identifiers:
- `America/New_York`, `America/Los_Angeles`, `America/Chicago`
- `Europe/London`, `Europe/Paris`, `Europe/Berlin`
- `Asia/Tokyo`, `Asia/Shanghai`, `Asia/Kolkata`
- `UTC`, `Etc/GMT`

## POSIX TZ Footer

Modern TZif files (v2+) include a POSIX TZ string in the footer for calculating offsets beyond the last transition:

```zig
if (tz.footer) |posix_tz| {
    // e.g., "EST5EDT,M3.2.0,M11.1.0" for US Eastern
    std.debug.print("POSIX TZ: {s}\n", .{posix_tz});
}
```

## Notes

- Allocates memory for transitions, timetypes, leapseconds, and footer
- Call `deinit()` to free allocated memory
- Supports TZif version 0 (legacy 32-bit), 2, and 3 (64-bit timestamps)
- Timezone abbreviations are limited to 6 characters (POSIX compliance)
- Transition timestamps are Unix epoch seconds (signed i64)
- Offset is in seconds, negative for west of UTC (e.g., -18000 = UTC-5)
