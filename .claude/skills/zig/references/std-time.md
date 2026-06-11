# std.time - Time and Timing

Wall-clock timestamps, monotonic timers, high-precision timing, and epoch/calendar utilities.

## Quick Reference

| Category | Types/Functions |
|----------|-----------------|
| Timestamps | `timestamp`, `milliTimestamp`, `microTimestamp`, `nanoTimestamp` |
| Monotonic | `Instant`, `Timer` |
| Epoch | `epoch.EpochSeconds`, `epoch.EpochDay`, `epoch.DaySeconds` |
| Calendar | `epoch.Year`, `epoch.Month`, `epoch.YearAndDay`, `epoch.MonthAndDay` |
| Constants | `ns_per_*`, `us_per_*`, `ms_per_*`, `s_per_*` |

## Choosing the Right Function

```
Need wall-clock time (date/time)?
├─ Yes → timestamp(), milliTimestamp(), microTimestamp(), nanoTimestamp()
└─ No → Need elapsed time / benchmarking?
       ├─ Yes → Timer or Instant
       └─ No → Need monotonic guarantee?
              ├─ Yes → Timer (saturates on backward jumps)
              └─ No → Instant.now()
```

| Function | Resolution | Range | Use Case |
|----------|------------|-------|----------|
| `timestamp()` | 1 second | i64 | Log timestamps, file dates |
| `milliTimestamp()` | 1 ms | i64 | General timing, UI |
| `microTimestamp()` | 1 μs | i64 | Profiling |
| `nanoTimestamp()` | 1-100 ns | i128 | High-precision timing |
| `Instant.now()` | ~1 ns | u64 | Elapsed time, ticks during suspend |
| `Timer` | ~1 ns | u64 | Benchmarking with monotonic guarantee |

## Wall-Clock Timestamps

Get current time relative to Unix epoch (1970-01-01 UTC):

```zig
const std = @import("std");

pub fn main() void {
    // Seconds since epoch
    const secs = std.time.timestamp();  // i64

    // Higher precision
    const ms = std.time.milliTimestamp();  // i64
    const us = std.time.microTimestamp();  // i64
    const ns = std.time.nanoTimestamp();   // i128
}
```

**Platform notes:**
- Windows: 100ns granularity via `RtlGetSystemTimePrecise`
- POSIX: Uses `clock_gettime(REALTIME)`
- WASI/UEFI: Platform-specific implementations

## Instant - High-Resolution Timestamps

`Instant` samples the system's fastest clock, ticking during suspend:

```zig
const std = @import("std");

pub fn main() !void {
    const start = try std.time.Instant.now();

    // ... work ...

    const end = try std.time.Instant.now();
    const elapsed_ns = end.since(start);  // u64 nanoseconds

    std.debug.print("Elapsed: {} ns\n", .{elapsed_ns});
}
```

### Instant Methods

```zig
// Get current instant (may fail on hostile environments)
const instant = try std.time.Instant.now();

// Compare two instants
const order = instant.order(other);  // .lt, .eq, or .gt

// Elapsed time in nanoseconds
const ns = later.since(earlier);
```

**Platform-specific clocks:**
- macOS/iOS: `UPTIME_RAW` (ticks during suspend)
- Linux: `BOOTTIME` (ticks during suspend)
- FreeBSD: `MONOTONIC_FAST`
- Windows: `QueryPerformanceCounter`

## Timer - Monotonic Benchmarking

`Timer` provides monotonic timing by saturating on backward clock jumps:

```zig
const std = @import("std");

pub fn main() !void {
    var timer = try std.time.Timer.start();

    // ... first phase ...
    const phase1_ns = timer.lap();  // read and reset

    // ... second phase ...
    const phase2_ns = timer.lap();

    // Total since start
    timer.reset();
    // ... final phase ...
    const total_ns = timer.read();
}
```

### Timer Methods

```zig
// Initialize timer
var timer = try std.time.Timer.start();  // error.TimerUnsupported if no clock

// Read elapsed nanoseconds since start/reset
const elapsed = timer.read();

// Reset timer to zero/now
timer.reset();

// Read and reset in one call
const lap_time = timer.lap();
```

## Time Unit Constants

```zig
// Nanosecond divisions
std.time.ns_per_us;    // 1_000
std.time.ns_per_ms;    // 1_000_000
std.time.ns_per_s;     // 1_000_000_000
std.time.ns_per_min;   // 60 * ns_per_s
std.time.ns_per_hour;  // 60 * ns_per_min
std.time.ns_per_day;   // 24 * ns_per_hour
std.time.ns_per_week;  // 7 * ns_per_day

// Microsecond divisions
std.time.us_per_ms;    // 1_000
std.time.us_per_s;     // 1_000_000
// ... us_per_min, us_per_hour, us_per_day, us_per_week

// Millisecond divisions
std.time.ms_per_s;     // 1_000
// ... ms_per_min, ms_per_hour, ms_per_day, ms_per_week

// Second divisions
std.time.s_per_min;    // 60
std.time.s_per_hour;   // 3_600
std.time.s_per_day;    // 86_400
std.time.s_per_week;   // 604_800
```

## Epoch Module - Calendar Conversions

Convert epoch timestamps to year/month/day/time components:

### EpochSeconds to Calendar

```zig
const std = @import("std");
const epoch = std.time.epoch;

pub fn main() void {
    const secs: u64 = @intCast(std.time.timestamp());
    const es = epoch.EpochSeconds{ .secs = secs };

    // Get day and time components
    const day = es.getEpochDay();
    const time = es.getDaySeconds();

    // Get year and day-of-year
    const year_day = day.calculateYearDay();
    // year_day.year: u16 (e.g., 2024)
    // year_day.day: u9 (0-365, day of year)

    // Get month and day-of-month
    const month_day = year_day.calculateMonthDay();
    // month_day.month: Month enum (.jan to .dec)
    // month_day.day_index: u5 (0-30, day of month)

    // Get time of day
    const hours = time.getHoursIntoDay();      // u5 (0-23)
    const minutes = time.getMinutesIntoHour(); // u6 (0-59)
    const seconds = time.getSecondsIntoMinute(); // u6 (0-59)
}
```

### Month Enum

```zig
const epoch = std.time.epoch;

const month: epoch.Month = .jun;
const num = month.numeric();  // 6 (u4, 1-12)

// All months
// .jan, .feb, .mar, .apr, .may, .jun, .jul, .aug, .sep, .oct, .nov, .dec
```

### Leap Year and Days

```zig
const epoch = std.time.epoch;

// Check leap year
const is_leap = epoch.isLeapYear(2024);  // true

// Days in year
const days = epoch.getDaysInYear(2024);  // 366

// Days in month
const feb_days = epoch.getDaysInMonth(2024, .feb);  // 29
```

### Epoch Reference Values

Convert between epoch systems (values are seconds offset from Unix epoch):

```zig
const epoch = std.time.epoch;

epoch.posix;   // 0          (Jan 01, 1970 - Unix)
epoch.unix;    // 0          (alias for posix)
epoch.dos;     // 315532800  (Jan 01, 1980 - DOS/VFAT/BIOS)
epoch.windows; // -11644473600 (Jan 01, 1601 - NTFS)
epoch.ios;     // 978307200  (Jan 01, 2001 - Apple)
epoch.gps;     // 315964800  (Jan 06, 1980 - GPS/ATSC)
epoch.ntp;     // -2208988800 (Jan 01, 1900 - NTP/z/OS)
epoch.clr;     // -62135769600 (Jan 01, 0001 - .NET/Go)
```

## Common Patterns

### Simple Benchmark

```zig
pub fn benchmark(comptime func: anytype) u64 {
    var timer = std.time.Timer.start() catch return 0;
    func();
    return timer.read();
}

// Usage
const ns = benchmark(myExpensiveFunction);
std.debug.print("Took {} ns\n", .{ns});
```

### Format Timestamp as ISO 8601

```zig
fn formatTimestamp(secs: u64, buf: []u8) []u8 {
    const epoch = std.time.epoch;
    const es = epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const time = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,  // day_index is 0-based
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch buf[0..0];
}
```

### Timeout Loop

```zig
fn waitWithTimeout(timeout_ns: u64) !void {
    const deadline = (try std.time.Instant.now()).timestamp + timeout_ns;

    while (true) {
        if (try checkCondition()) return;

        const now = try std.time.Instant.now();
        if (now.timestamp >= deadline) return error.Timeout;

        std.Thread.sleep(std.time.ns_per_ms);  // 1ms
    }
}
```

### Rate Limiter

```zig
const RateLimiter = struct {
    interval_ns: u64,
    last: ?std.time.Instant,

    pub fn init(ops_per_second: u64) RateLimiter {
        return .{
            .interval_ns = std.time.ns_per_s / ops_per_second,
            .last = null,
        };
    }

    pub fn acquire(self: *RateLimiter) void {
        const now = std.time.Instant.now() catch return;
        if (self.last) |last| {
            const elapsed = now.since(last);
            if (elapsed < self.interval_ns) {
                std.Thread.sleep(self.interval_ns - elapsed);
            }
        }
        self.last = std.time.Instant.now() catch null;
    }
};
```

### Elapsed Time Formatting

```zig
fn formatElapsed(ns: u64) struct { value: u64, unit: []const u8 } {
    if (ns < std.time.ns_per_us) return .{ .value = ns, .unit = "ns" };
    if (ns < std.time.ns_per_ms) return .{ .value = ns / std.time.ns_per_us, .unit = "us" };
    if (ns < std.time.ns_per_s) return .{ .value = ns / std.time.ns_per_ms, .unit = "ms" };
    return .{ .value = ns / std.time.ns_per_s, .unit = "s" };
}

// Usage
const result = formatElapsed(timer.read());
std.debug.print("Elapsed: {} {s}\n", .{ result.value, result.unit });
```

### Convert Between Epoch Systems

```zig
fn unixToWindows(unix_secs: i64) i64 {
    return unix_secs - std.time.epoch.windows;
}

fn windowsToUnix(windows_secs: i64) i64 {
    return windows_secs + std.time.epoch.windows;
}
```

## Notes

- `timestamp()` and variants return signed `i64`/`i128` (dates before 1970 are negative)
- `Instant` and `Timer` use unsigned `u64` nanoseconds (~585 years max range)
- `Instant.now()` can return `error.Unsupported` in restricted environments
- `Timer` saturates on clock jumps backward (always monotonic)
- `epoch.EpochSeconds` expects unsigned `u64` (use `@intCast` from `timestamp()`)
- Day and month indices in epoch module are 0-based
- For sleeping, use `std.Thread.sleep(ns)` not time module
