# std.Thread - Threading and Concurrency API Reference

Thread spawning, synchronization primitives, and concurrent programming in Zig 0.15.x.

## Table of Contents
- [Module Structure](#module-structure)
- [Spawning Threads](#spawning-threads)
- [Thread Utilities](#thread-utilities)
- [Synchronization Primitives](#synchronization-primitives)
  - [Mutex](#mutex)
  - [RwLock](#rwlock)
  - [Condition](#condition)
  - [Semaphore](#semaphore)
  - [ResetEvent](#resetevent)
  - [WaitGroup](#waitgroup)
- [Thread Pool](#thread-pool)
- [Common Patterns](#common-patterns)

## Module Structure

```zig
std.Thread                  // Thread spawning and management
std.Thread.Mutex            // Mutual exclusion lock
std.Thread.Mutex.Recursive  // Recursive mutex (same thread can lock multiple times)
std.Thread.RwLock           // Reader-writer lock
std.Thread.Condition        // Condition variable for signaling
std.Thread.Semaphore        // Counting semaphore
std.Thread.ResetEvent       // Boolean event flag with blocking
std.Thread.WaitGroup        // Wait for multiple tasks to complete
std.Thread.Pool             // Thread pool for parallel task execution
std.Thread.Futex            // Low-level futex operations (advanced)
```

## Spawning Threads

### Basic Thread Spawn

```zig
const std = @import("std");

fn workerFn(id: usize) void {
    std.debug.print("Worker {d} running\n", .{id});
}

pub fn main() !void {
    const thread = try std.Thread.spawn(.{}, workerFn, .{42});
    thread.join();  // wait for completion
}
```

### Thread with Return Value

```zig
fn compute(x: i32) void {
    // Zig threads don't return values directly
    // Use shared state or channels for results
}
```

### Detached Threads

```zig
const thread = try std.Thread.spawn(.{}, workerFn, .{1});
thread.detach();  // thread cleans up itself on completion
// Cannot call join() after detach()
```

### Spawn Configuration

```zig
const thread = try std.Thread.spawn(.{
    .stack_size = 8 * 1024 * 1024,  // 8 MB stack (default: 16 MB)
    .allocator = allocator,          // required on WASI
}, workerFn, .{args});
```

### Thread Function Signatures

```zig
// Valid return types: void, !void, u8, noreturn
fn worker1() void { }
fn worker2() !void { return error.Failed; }
fn worker3() u8 { return 0; }  // exit status (ignored on pthreads)
fn worker4() noreturn { while (true) {} }
```

## Thread Utilities

### Get Current Thread ID

```zig
const id = std.Thread.getCurrentId();
std.debug.print("Thread ID: {d}\n", .{id});
```

### Get CPU Count

```zig
const cpu_count = std.Thread.getCpuCount() catch 1;
std.debug.print("CPUs: {d}\n", .{cpu_count});
```

### Sleep

```zig
std.Thread.sleep(100 * std.time.ns_per_ms);  // sleep 100ms
std.Thread.sleep(std.time.ns_per_s);          // sleep 1 second
```

### Yield

```zig
std.Thread.yield() catch {};  // hint to scheduler
```

### Thread Names (Platform-dependent)

```zig
var thread = try std.Thread.spawn(.{}, worker, .{});

// Set thread name (max length varies by OS)
try thread.setName("worker-1");

// Get thread name
var name_buf: [std.Thread.max_name_len:0]u8 = undefined;
if (try thread.getName(&name_buf)) |name| {
    std.debug.print("Thread name: {s}\n", .{name});
}
```

## Synchronization Primitives

### Mutex

Basic mutual exclusion lock. Use `defer` for exception-safe unlocking.

```zig
var mutex: std.Thread.Mutex = .{};
var shared_data: u64 = 0;

fn increment() void {
    mutex.lock();
    defer mutex.unlock();
    shared_data += 1;
}

// tryLock for non-blocking acquisition
if (mutex.tryLock()) {
    defer mutex.unlock();
    // critical section
} else {
    // lock not acquired
}
```

**Debug mode**: Detects deadlocks when same thread tries to lock twice.

#### Recursive Mutex

Allows same thread to lock multiple times (must unlock same number of times).

```zig
var rmutex: std.Thread.Mutex.Recursive = .{};

fn outer() void {
    rmutex.lock();
    defer rmutex.unlock();
    inner();  // can lock again
}

fn inner() void {
    rmutex.lock();
    defer rmutex.unlock();
    // ...
}
```

### RwLock

Reader-writer lock: multiple readers OR one writer.

```zig
var rwlock: std.Thread.RwLock = .{};
var data: []const u8 = "initial";

fn reader() void {
    rwlock.lockShared();
    defer rwlock.unlockShared();
    // read data safely (multiple readers allowed)
    _ = data;
}

fn writer(new_data: []const u8) void {
    rwlock.lock();
    defer rwlock.unlock();
    // exclusive write access
    data = new_data;
}

// Non-blocking variants
if (rwlock.tryLockShared()) {
    defer rwlock.unlockShared();
    // read
}

if (rwlock.tryLock()) {
    defer rwlock.unlock();
    // write
}
```

### Condition

Wait for a condition to become true. Always use with a Mutex.

```zig
var mutex: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};
var ready = false;

fn consumer() void {
    mutex.lock();
    defer mutex.unlock();

    // Wait in a loop (handles spurious wakeups)
    while (!ready) {
        cond.wait(&mutex);  // atomically unlocks, waits, relocks
    }
    // Process data
}

fn producer() void {
    {
        mutex.lock();
        defer mutex.unlock();
        ready = true;
    }
    cond.signal();     // wake one waiter
    // cond.broadcast(); // wake all waiters
}
```

#### Timed Wait

```zig
fn timedConsumer() !void {
    mutex.lock();
    defer mutex.unlock();

    while (!ready) {
        cond.timedWait(&mutex, 5 * std.time.ns_per_s) catch |err| switch (err) {
            error.Timeout => return error.TimedOut,
        };
    }
}
```

### Semaphore

Counting semaphore for resource limiting.

```zig
var sem: std.Thread.Semaphore = .{ .permits = 3 };  // 3 permits available

fn worker() void {
    sem.wait();     // acquire permit (blocks if 0)
    defer sem.post();  // release permit
    // use limited resource
}

// Timed wait
sem.timedWait(1 * std.time.ns_per_s) catch |err| switch (err) {
    error.Timeout => { /* handle timeout */ },
};
```

### ResetEvent

Boolean flag with blocking wait. Useful for one-shot signaling.

```zig
var event: std.Thread.ResetEvent = .{};

fn waiter() void {
    event.wait();  // blocks until set
    // event.isSet() returns true
}

fn signaler() void {
    event.set();   // unblocks all waiters
}

// Reset for reuse
event.reset();

// Check without blocking
if (event.isSet()) {
    // already signaled
}

// Timed wait
event.timedWait(1 * std.time.ns_per_s) catch |err| switch (err) {
    error.Timeout => { /* handle timeout */ },
};
```

### WaitGroup

Wait for multiple concurrent tasks to complete.

```zig
var wg: std.Thread.WaitGroup = .{};

fn spawnTasks() void {
    for (0..10) |i| {
        wg.start();  // increment counter before spawning
        _ = std.Thread.spawn(.{}, task, .{ &wg, i }) catch {
            wg.finish();  // decrement if spawn fails
            continue;
        };
    }
}

fn task(wait_group: *std.Thread.WaitGroup, id: usize) void {
    defer wait_group.finish();  // always decrement when done
    // do work
    _ = id;
}

pub fn main() !void {
    spawnTasks();
    wg.wait();  // blocks until all tasks finish
}
```

#### Batch Operations

```zig
wg.startMany(10);  // increment by 10

// Check if done without blocking
if (wg.isDone()) {
    // all tasks completed
}

// Reset for reuse
wg.reset();
```

#### Spawn Manager Pattern

```zig
var wg: std.Thread.WaitGroup = .{};

// Spawns a detached thread that decrements wg on completion
wg.spawnManager(someFunc, .{arg1, arg2});

wg.wait();  // wait for manager and all its work
```

## Thread Pool

Reusable pool of worker threads for parallel task execution.

### Basic Usage

```zig
var pool: std.Thread.Pool = undefined;
try pool.init(.{
    .allocator = allocator,
    .n_jobs = null,  // default: CPU count
});
defer pool.deinit();

var wg: std.Thread.WaitGroup = .{};

// Queue work
for (items) |item| {
    pool.spawnWg(&wg, processItem, .{item});
}

// Wait for all work to complete
wg.wait();
// Or: participate in work while waiting
pool.waitAndWork(&wg);
```

### Pool Options

```zig
try pool.init(.{
    .allocator = allocator,
    .n_jobs = 4,              // number of worker threads (default: CPU count)
    .track_ids = true,        // enable thread IDs for spawnWgId
    .stack_size = 8 * 1024 * 1024,  // worker stack size
});
```

### Spawn Variants

```zig
// Basic spawn (fire and forget, may fallback to sync)
try pool.spawn(func, .{args});

// With WaitGroup tracking
pool.spawnWg(&wg, func, .{args});

// With thread ID (requires track_ids = true)
pool.spawnWgId(&wg, funcWithId, .{args});

fn funcWithId(thread_id: usize, args: anytype) void {
    // thread_id is dense 0..n_jobs
    _ = thread_id;
    _ = args;
}
```

### Get Thread Count

```zig
const total_threads = pool.getIdCount();  // 1 + n_jobs (includes main)
```

## Common Patterns

### Producer-Consumer Queue

```zig
fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},

        pub fn push(self: *@This(), item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == capacity) {
                self.not_full.wait(&self.mutex);
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;

            self.not_empty.signal();
        }

        pub fn pop(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0) {
                self.not_empty.wait(&self.mutex);
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;

            self.not_full.signal();
            return item;
        }
    };
}
```

### Thread-Safe Counter

```zig
const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn increment(self: *@This()) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn get(self: *const @This()) u64 {
        return self.value.load(.monotonic);
    }
};
```

### Parallel Map

```zig
fn parallelMap(
    pool: *std.Thread.Pool,
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime U: type,
    items: []const T,
    comptime mapFn: fn (T) U,
) ![]U {
    const results = try allocator.alloc(U, items.len);
    var wg: std.Thread.WaitGroup = .{};

    for (items, 0..) |item, i| {
        pool.spawnWg(&wg, struct {
            fn work(r: []U, idx: usize, val: T) void {
                r[idx] = mapFn(val);
            }
        }.work, .{ results, i, item });
    }

    pool.waitAndWork(&wg);
    return results;
}
```

### Once Initialization

```zig
var initialized = std.atomic.Value(bool).init(false);
var init_mutex: std.Thread.Mutex = .{};
var global_resource: ?*Resource = null;

fn getResource() *Resource {
    // Fast path: already initialized
    if (initialized.load(.acquire)) {
        return global_resource.?;
    }

    init_mutex.lock();
    defer init_mutex.unlock();

    // Double-check after acquiring lock
    if (!initialized.load(.acquire)) {
        global_resource = initializeResource();
        initialized.store(true, .release);
    }

    return global_resource.?;
}
```

### Barrier Synchronization

```zig
const Barrier = struct {
    event: std.Thread.ResetEvent = .{},
    counter: std.atomic.Value(usize),

    pub fn init(count: usize) @This() {
        return .{ .counter = std.atomic.Value(usize).init(count) };
    }

    pub fn wait(self: *@This()) void {
        if (self.counter.fetchSub(1, .acq_rel) == 1) {
            self.event.set();  // last thread signals all
        } else {
            self.event.wait();  // others wait
        }
    }
};
```

### Scoped Lock Helper

```zig
fn withLock(mutex: *std.Thread.Mutex, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
    mutex.lock();
    defer mutex.unlock();
    return @call(.auto, func, args);
}

// Usage
const result = withLock(&mutex, computeValue, .{x, y});
```

### Thread-Local Storage

```zig
threadlocal var tls_buffer: [1024]u8 = undefined;
threadlocal var tls_counter: usize = 0;

fn perThreadWork() void {
    tls_counter += 1;  // each thread has its own counter
    // use tls_buffer for thread-local scratch space
}
```
