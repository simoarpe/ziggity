# std.c - C ABI Types and Libc Bindings Reference

Platform-specific C ABI types and libc function bindings. Provides cross-platform type definitions that match the C ABI for each target OS, enabling FFI with C libraries and direct syscall access.

## Table of Contents
- [When to Use std.c](#when-to-use-stdc)
- [Fundamental Types](#fundamental-types)
- [File and I/O Types](#file-and-io-types)
- [Time Types](#time-types)
- [Process Types](#process-types)
- [Socket Types](#socket-types)
- [Signal Types](#signal-types)
- [Memory Types](#memory-types)
- [Constants and Flags](#constants-and-flags)
- [Libc Function Bindings](#libc-function-bindings)
- [Platform-Specific Submodules](#platform-specific-submodules)
- [Common Patterns](#common-patterns)

## When to Use std.c

Use `std.c` when:
- Interfacing with C libraries via FFI
- Making direct syscalls that require C-compatible types
- Working with platform-specific kernel interfaces
- Need exact type layout matching C headers

Prefer higher-level alternatives when available:
```zig
// High-level (recommended)
const file = try std.fs.cwd().openFile("data.txt", .{});

// POSIX-level
const fd = try std.posix.open("data.txt", .{}, 0);

// C-level (direct libc, lowest level)
const fd = std.c.open("data.txt", .{}, 0);
```

## Fundamental Types

### Integer Types
```zig
const c = std.c;

// Fixed-size types (same as C)
c.c_char       // char (usually i8)
c.c_short      // short
c.c_int        // int
c.c_long       // long (platform-dependent size)
c.c_longlong   // long long
c.c_uchar      // unsigned char
c.c_ushort     // unsigned short
c.c_uint       // unsigned int
c.c_ulong      // unsigned long
c.c_ulonglong  // unsigned long long

// Size types
c.size_t       // size_t
c.ssize_t      // ssize_t (signed size)
c.intptr_t     // intptr_t
c.uintptr_t    // uintptr_t
c.ptrdiff_t    // ptrdiff_t
c.intmax_t     // i64
c.uintmax_t    // u64
c.max_align_t  // maximum alignment type
```

### File Descriptor Types
```zig
c.fd_t        // File descriptor (i32 on POSIX, HANDLE on Windows)
c.ino_t       // Inode number
c.off_t       // File offset (i64)
c.dev_t       // Device ID
c.mode_t      // File mode/permissions
c.nlink_t     // Link count
c.blksize_t   // Block size
c.blkcnt_t    // Block count
```

### User/Group Types
```zig
c.uid_t       // User ID (u32)
c.gid_t       // Group ID (u32)
c.pid_t       // Process ID (platform-specific)
```

## File and I/O Types

### Stat Structure
```zig
const c = std.c;

// Platform-specific stat structure
const stat: c.Stat = undefined;
// Fields (vary by platform):
stat.dev          // Device ID
stat.ino          // Inode number
stat.mode         // File mode
stat.nlink        // Number of hard links
stat.uid          // Owner UID
stat.gid          // Owner GID
stat.size         // File size in bytes
stat.atim         // Last access time (timespec)
stat.mtim         // Last modification time
stat.ctim         // Last status change time
stat.blksize      // Preferred block size
stat.blocks       // Number of 512-byte blocks
```

### I/O Vectors
```zig
// Scatter/gather I/O
c.iovec         // { .base: [*]u8, .len: usize }
c.iovec_const   // { .base: [*]const u8, .len: usize }

c.IOV_MAX       // Maximum iovec count per operation (platform-specific)
```

### Directory Types
```zig
c.DIR           // Directory stream (opaque)
c.dirent        // Directory entry structure
c.dirent64      // 64-bit directory entry (Linux)
c.MAXNAMLEN     // Max filename length in dirent
c.DT            // Directory entry type constants
    .UNKNOWN, .FIFO, .CHR, .DIR, .BLK, .REG, .LNK, .SOCK, .WHT
```

### File Locking
```zig
c.Flock         // File lock structure
    .start      // Starting offset
    .len        // Length (0 = to EOF)
    .pid        // Process ID holding lock
    .type       // Lock type (F.RDLCK, F.WRLCK, F.UNLCK)
    .whence     // SEEK.SET/CUR/END

c.LOCK          // Lock operations (from std.posix)
    .SH         // Shared lock
    .EX         // Exclusive lock
    .NB         // Non-blocking
    .UN         // Unlock
```

## Time Types

### timespec
```zig
c.timespec      // High-resolution time
    .sec        // Seconds (time_t or isize)
    .nsec       // Nanoseconds (isize or c_long)

c.time_t        // Calendar time in seconds
c.clock_t       // CPU time
c.suseconds_t   // Microseconds component
```

### timeval
```zig
c.timeval       // Time with microsecond resolution
    .sec        // Seconds
    .usec       // Microseconds (suseconds_t)

c.timezone      // Timezone info (deprecated on most systems)
    .minuteswest
    .dsttime
```

### Interval Timer
```zig
c.itimerspec    // Timer specification
    .interval   // timespec - repeat interval
    .value      // timespec - initial expiration
```

### Clock IDs
```zig
c.clockid_t     // Clock identifier enum
c.CLOCK         // Clock ID constants (platform-specific)
    .REALTIME           // Wall clock
    .MONOTONIC          // Monotonic clock
    .PROCESS_CPUTIME_ID // Process CPU time
    .THREAD_CPUTIME_ID  // Thread CPU time
    // Platform-specific additions:
    // macOS: MONOTONIC_RAW, UPTIME_RAW
    // Linux: BOOTTIME, REALTIME_COARSE, MONOTONIC_COARSE
    // FreeBSD: UPTIME, REALTIME_FAST, MONOTONIC_FAST
```

## Process Types

### Process and Thread IDs
```zig
c.pid_t         // Process ID
c.pthread_t     // POSIX thread handle

// Pthread synchronization primitives
c.pthread_mutex_t       // Mutex
c.pthread_cond_t        // Condition variable
c.pthread_rwlock_t      // Read-write lock
c.pthread_attr_t        // Thread attributes
c.pthread_key_t         // Thread-local storage key
c.pthread_spin_t        // Spinlock (some platforms)
c.sem_t                 // Semaphore
```

### Mutex Initializers
```zig
c.PTHREAD_MUTEX_INITIALIZER  // Static mutex initializer
c.PTHREAD_COND_INITIALIZER   // Static condvar initializer
```

### User/Group Info
```zig
c.passwd        // Password entry structure
    .name       // Username
    .passwd     // Encrypted password
    .uid        // User ID
    .gid        // Group ID
    .gecos      // User info (real name)
    .dir        // Home directory
    .shell      // Login shell
    // BSD/macOS additions: .change, .class, .expire

c.group         // Group entry structure
    .name       // Group name
    .passwd     // Group password
    .gid        // Group ID
    .mem        // Null-terminated member list
```

### Resource Limits
```zig
c.rlimit        // Resource limit structure
    .cur        // Current (soft) limit
    .max        // Maximum (hard) limit

c.rlim_t        // Resource limit value type
c.rlimit_resource  // Resource type enum
    .NOFILE     // Max open files
    .STACK      // Stack size
    .DATA       // Data segment size
    .AS         // Address space
    // ... (many more platform-specific)

c.RLIM          // Special limit values
    .INFINITY   // No limit
    .SAVED_MAX, .SAVED_CUR
```

### Resource Usage
```zig
c.rusage        // Resource usage statistics
    .utime      // User CPU time (timeval)
    .stime      // System CPU time
    .maxrss     // Maximum resident set size
    .minflt     // Minor page faults
    .majflt     // Major page faults
    .nvcsw      // Voluntary context switches
    .nivcsw     // Involuntary context switches
    // ... additional fields
```

## Socket Types

### Address Structures
```zig
c.sockaddr         // Generic socket address
    .family        // Address family (sa_family_t)
    .data          // Address data

c.sockaddr_in      // IPv4 address (from std.posix)
c.sockaddr_in6     // IPv6 address
c.sockaddr_un      // Unix domain socket
c.sockaddr_storage // Large enough for any address

c.socklen_t        // Socket address length type
c.sa_family_t      // Address family type
c.in_port_t        // Port number (u16)
```

### Address Families
```zig
c.AF               // Address family constants
    .UNSPEC        // Unspecified
    .UNIX, .LOCAL  // Unix domain
    .INET          // IPv4
    .INET6         // IPv6
    .PACKET        // Packet (Linux)
    .NETLINK       // Netlink (Linux)
    // Many platform-specific families

c.PF               // Protocol families (same values as AF)
```

### Socket Options
```zig
c.SOCK            // Socket types
    .STREAM       // TCP
    .DGRAM        // UDP
    .RAW          // Raw socket
    .SEQPACKET    // Sequenced packet
    .CLOEXEC      // Set close-on-exec
    .NONBLOCK     // Non-blocking

c.SOL             // Socket level for options
    .SOCKET       // Socket-level options
    .IP, .IPV6    // IP-level options
    .TCP, .UDP    // Protocol-level options

c.SO              // Socket options (SOL_SOCKET level)
    .REUSEADDR, .REUSEPORT
    .KEEPALIVE
    .BROADCAST
    .LINGER
    .RCVBUF, .SNDBUF
    .RCVTIMEO, .SNDTIMEO
    .ERROR
    // Many more

c.TCP             // TCP options (SOL_TCP level)
    .NODELAY      // Disable Nagle
    .KEEPIDLE     // Idle time before keepalive
    .KEEPINTVL    // Keepalive interval
    .KEEPCNT      // Keepalive count

c.IPPROTO         // IP protocols
    .IP, .ICMP, .TCP, .UDP, .IPV6, .RAW
```

### Message Flags
```zig
c.MSG             // Send/recv flags
    .OOB          // Out-of-band data
    .PEEK         // Peek at incoming data
    .DONTROUTE    // Bypass routing
    .DONTWAIT     // Non-blocking
    .NOSIGNAL     // Don't generate SIGPIPE
    .TRUNC, .CTRUNC
    .WAITALL      // Wait for full request
```

### Message Headers
```zig
c.msghdr          // Message header for sendmsg/recvmsg
    .name         // Optional address
    .namelen      // Address length
    .iov          // Scatter/gather array
    .iovlen       // Elements in iov
    .control      // Ancillary data
    .controllen   // Ancillary data length
    .flags        // Flags on received message

c.msghdr_const    // Const version for sendmsg
```

### Address Info (DNS)
```zig
c.addrinfo        // Address info structure
    .flags        // AI flags
    .family       // Address family
    .socktype     // Socket type
    .protocol     // Protocol
    .addrlen      // Address length
    .addr         // Socket address
    .canonname    // Canonical name
    .next         // Next in list

c.AI              // getaddrinfo flags
    .PASSIVE      // For bind()
    .CANONNAME    // Request canonical name
    .NUMERICHOST  // Don't resolve hostname
    .NUMERICSERV  // Don't resolve service
    .V4MAPPED, .ALL, .ADDRCONFIG

c.NI              // getnameinfo flags
    .NUMERICHOST, .NUMERICSERV
    .NOFQDN, .NAMEREQD
    .DGRAM

c.EAI             // getaddrinfo errors
    .AGAIN, .BADFLAGS, .FAIL, .FAMILY
    .MEMORY, .NONAME, .SERVICE, .SOCKTYPE
    .SYSTEM, .OVERFLOW
```

## Signal Types

### Signal Numbers
```zig
c.SIG             // Signal constants (platform-specific enum)
    .HUP, .INT, .QUIT, .ILL, .TRAP, .ABRT
    .FPE, .KILL, .BUS, .SEGV, .SYS, .PIPE
    .ALRM, .TERM, .URG, .STOP, .TSTP, .CONT
    .CHLD, .TTIN, .TTOU, .IO, .XCPU, .XFSZ
    .VTALRM, .PROF, .WINCH, .USR1, .USR2
```

### Signal Handling
```zig
c.Sigaction       // Signal action structure
    .handler      // Handler function or SIG_DFL/SIG_IGN
    .mask         // Signals to block during handler
    .flags        // SA flags

c.SA              // Sigaction flags
    .NOCLDSTOP    // Don't notify on child stop
    .NOCLDWAIT    // Don't create zombies
    .SIGINFO      // Use sa_sigaction handler
    .RESTART      // Restart interrupted syscalls
    .NODEFER      // Don't block signal in handler
    .RESETHAND    // Reset to default after handling
    .ONSTACK      // Use alternate signal stack

c.siginfo_t       // Signal info (with SA_SIGINFO)
c.sigset_t        // Signal set
c.sigval          // Signal value union
c.sig_atomic_t    // Async-signal-safe integer

c.NSIG            // Number of signals
c.MINSIGSTKSZ     // Minimum signal stack size
c.SIGSTKSZ        // Default signal stack size
```

### Signal Stack
```zig
c.stack_t         // Alternate signal stack
    .sp           // Stack pointer
    .flags        // SS flags
    .size         // Stack size

c.SS              // Stack flags
    .ONSTACK      // Currently on signal stack
    .DISABLE      // Signal stack disabled
```

## Memory Types

### Memory Protection
```zig
c.PROT            // Memory protection flags
    .NONE         // No access
    .READ         // Read permission
    .WRITE        // Write permission
    .EXEC         // Execute permission
```

### Memory Mapping
```zig
c.MAP             // mmap flags
    .SHARED       // Share changes
    .PRIVATE      // Private copy-on-write
    .FIXED        // Use exact address
    .ANONYMOUS    // No file backing (Linux/BSD)
    .ANON         // Alias for ANONYMOUS
    .NORESERVE    // Don't reserve swap
    .STACK        // Stack mapping
    // Platform-specific flags

c.MAP_FAILED      // mmap failure return value

c.MREMAP          // mremap flags (Linux)
    .MAYMOVE
    .FIXED
```

### Memory Advice
```zig
c.MADV            // madvise hints
    .NORMAL       // Default behavior
    .RANDOM       // Random access pattern
    .SEQUENTIAL   // Sequential access
    .WILLNEED     // Will need soon
    .DONTNEED     // Won't need soon
    .FREE         // Can free pages (Linux)
    .REMOVE       // Remove from memory
    // Platform-specific hints
```

### Memory Sync
```zig
c.MSF             // msync flags
    .ASYNC        // Asynchronous sync
    .SYNC         // Synchronous sync
    .INVALIDATE   // Invalidate caches
```

## Constants and Flags

### Error Numbers
```zig
c.E               // errno values (platform-specific enum)
    .SUCCESS      // No error (0)
    .PERM         // Operation not permitted
    .NOENT        // No such file or directory
    .SRCH         // No such process
    .INTR         // Interrupted system call
    .IO           // I/O error
    .NXIO         // No such device
    .@"2BIG"      // Arg list too long
    .NOEXEC       // Exec format error
    .BADF         // Bad file descriptor
    .CHILD        // No child processes
    .AGAIN        // Try again (also WOULDBLOCK)
    .NOMEM        // Out of memory
    .ACCES        // Permission denied
    .FAULT        // Bad address
    .BUSY         // Device busy
    .EXIST        // File exists
    .XDEV         // Cross-device link
    .NODEV        // No such device
    .NOTDIR       // Not a directory
    .ISDIR        // Is a directory
    .INVAL        // Invalid argument
    .NFILE        // File table overflow
    .MFILE        // Too many open files
    .NOTTY        // Not a typewriter
    .FBIG         // File too large
    .NOSPC        // No space on device
    .SPIPE        // Illegal seek
    .ROFS         // Read-only filesystem
    .PIPE         // Broken pipe
    .DEADLK       // Deadlock avoided
    .NAMETOOLONG  // Name too long
    .NOSYS        // Function not implemented
    .NOTEMPTY     // Directory not empty
    .TIMEDOUT     // Connection timed out
    .CONNREFUSED  // Connection refused
    // Many more platform-specific errors
```

### File Control (fcntl)
```zig
c.F               // fcntl commands
    .DUPFD        // Duplicate fd
    .GETFD        // Get fd flags
    .SETFD        // Set fd flags
    .GETFL        // Get file flags
    .SETFL        // Set file flags
    .GETLK        // Get lock info
    .SETLK        // Set lock (non-blocking)
    .SETLKW       // Set lock (blocking)
    .DUPFD_CLOEXEC // Dup with close-on-exec
    // Lock types:
    .RDLCK        // Read lock
    .WRLCK        // Write lock
    .UNLCK        // Unlock

c.FD_CLOEXEC      // Close-on-exec flag (1)
```

### Access Mode
```zig
c.F_OK            // Test existence (0)
c.X_OK            // Test execute (1)
c.W_OK            // Test write (2)
c.R_OK            // Test read (4)
```

### Open Flags
```zig
c.O               // open() flags (struct on some platforms)
    .RDONLY       // Read only
    .WRONLY       // Write only
    .RDWR         // Read/write
    .CREAT        // Create if not exists
    .EXCL         // Exclusive create
    .TRUNC        // Truncate
    .APPEND       // Append mode
    .NONBLOCK     // Non-blocking
    .SYNC         // Synchronous writes
    .CLOEXEC      // Close on exec
    .DIRECTORY    // Must be directory
    .NOFOLLOW     // Don't follow symlinks
    // Platform-specific flags
```

### Seek Whence
```zig
c.SEEK            // lseek whence values
    .SET          // From beginning
    .CUR          // From current position
    .END          // From end
c.whence_t        // Whence type (c_int or wasi.whence_t)
```

### File Mode Bits
```zig
c.S               // File mode constants
    .IFMT         // File type mask
    .IFSOCK       // Socket
    .IFLNK        // Symbolic link
    .IFREG        // Regular file
    .IFBLK        // Block device
    .IFDIR        // Directory
    .IFCHR        // Character device
    .IFIFO        // FIFO
    .ISUID        // Set-user-ID
    .ISGID        // Set-group-ID
    .ISVTX        // Sticky bit
    .IRWXU        // Owner rwx
    .IRUSR, .IWUSR, .IXUSR
    .IRWXG        // Group rwx
    .IRGRP, .IWGRP, .IXGRP
    .IRWXO        // Other rwx
    .IROTH, .IWOTH, .IXOTH
```

### Poll Events
```zig
c.POLL            // poll() events
    .IN           // Data to read
    .PRI          // Priority data
    .OUT          // Writing possible
    .ERR          // Error condition
    .HUP          // Hang up
    .NVAL         // Invalid fd
    .RDNORM, .RDBAND
    .WRNORM, .WRBAND

c.pollfd          // poll file descriptor
    .fd           // File descriptor
    .events       // Requested events
    .revents      // Returned events

c.nfds_t          // Number of poll fds
```

### AT Flags (openat, etc.)
```zig
c.AT              // *at() function flags
    .FDCWD        // Use current directory
    .SYMLINK_NOFOLLOW
    .REMOVEDIR
    .SYMLINK_FOLLOW
    .EACCESS
    .EMPTY_PATH   // Linux
```

### Terminal I/O
```zig
c.termios         // Terminal attributes
    .iflag        // Input flags
    .oflag        // Output flags
    .cflag        // Control flags
    .lflag        // Local flags
    .cc           // Control characters

c.NCCS            // Number of control chars
c.V               // Control character indices
    .INTR, .QUIT, .ERASE, .KILL
    .EOF, .TIME, .MIN, .START, .STOP
    // ... (many more)

c.tc_iflag_t      // Input flag type
c.tc_oflag_t      // Output flag type
c.tc_cflag_t      // Control flag type
c.tc_lflag_t      // Local flag type
c.speed_t         // Baud rate type
c.cc_t            // Control character type

c.TCSA            // tcsetattr actions (from std.posix)
c.CSIZE           // Character size mask
```

### Wait Flags
```zig
c.W               // waitpid flags
    .NOHANG       // Don't block
    .UNTRACED     // Report stopped children
    .CONTINUED    // Report continued children (Linux)
```

### Shutdown
```zig
c.SHUT            // shutdown() how values
    .RD           // Stop receiving
    .WR           // Stop sending
    .RDWR         // Stop both
```

### Kqueue (BSD/macOS)
```zig
c.Kevent          // kevent structure
    .ident        // Identifier
    .filter       // Filter type
    .flags        // Action flags
    .fflags       // Filter-specific flags
    .data         // Filter data
    .udata        // User data

c.EV              // Event flags
    .ADD, .DELETE, .ENABLE, .DISABLE
    .ONESHOT, .CLEAR, .RECEIPT
    .EOF, .ERROR

c.EVFILT          // Event filters
    .READ, .WRITE, .AIO
    .VNODE, .PROC, .SIGNAL
    .TIMER, .USER, .MACHPORT (macOS)

c.NOTE            // Filter-specific notes
```

### Port Events (Solaris/illumos)
```zig
c.port_t          // Event port handle
c.port_event      // Port event structure
```

## Libc Function Bindings

### File Operations
```zig
c.close           // Close file descriptor
c.fstat           // Get file status by fd
c.fstatat         // Get file status relative to directory fd
c.stat            // Get file status by path
c.readdir         // Read directory entry
c.realpath        // Resolve canonical path
c.flock           // Apply/remove advisory lock
```

### Time Functions
```zig
c.clock_getres    // Get clock resolution
c.clock_gettime   // Get clock time
c.nanosleep       // High-resolution sleep
c.gettimeofday    // Get wall clock time
```

### Memory Functions
```zig
c.msync           // Synchronize mapped memory
c.posix_memalign  // Aligned memory allocation
c.malloc_size     // macOS: get allocation size
c.malloc_usable_size  // Linux: get allocation size
c._msize          // Windows: get allocation size
```

### Process Functions
```zig
c.fork            // Create child process
c.getrusage       // Get resource usage
c.sched_yield     // Yield processor
c.sysconf         // Get system configuration
c.getentropy      // Get random bytes (secure)
c.arc4random_buf  // Get random bytes (BSD)
c.getrandom       // Get random bytes (Linux)
```

### Signal Functions
```zig
c.sigaction       // Examine/change signal action
c.sigaltstack     // Set alternate signal stack
c.sigfillset      // Fill signal set
c.sigemptyset     // Empty signal set
c.sigaddset       // Add signal to set
c.sigdelset       // Remove signal from set
c.sigismember     // Test signal membership
c.sigprocmask     // Block/unblock signals
c.sigrtmin()      // First real-time signal
c.sigrtmax()      // Last real-time signal
```

### Network Functions
```zig
c.socket          // Create socket
c.sendfile        // Efficient file-to-socket copy
```

### I/O Functions
```zig
c.pipe2           // Create pipe with flags
c.copy_file_range // Efficient file copy (Linux)
c.getdirentries   // Read directory entries (BSD)
c.getdents        // Read directory entries (Linux)
```

### Thread Functions
```zig
c.pthread_setname_np   // Set thread name
c.pthread_threadid_np  // Get thread ID (macOS)
c.getcontext           // Get current context (some platforms)
```

## Platform-Specific Submodules

### darwin (macOS/iOS)
```zig
const darwin = std.c.darwin;  // Internal, re-exported via std.c

// Mach types and functions
darwin.mach_port_t
darwin.mach_task_self()
darwin.mach_msg()
darwin.mach_host_self()
darwin.mach_timebase_info()
darwin.mach_absolute_time()

// Exception handling
darwin.EXC, darwin.EXCEPTION
darwin.task_set_exception_ports()
darwin.task_get_exception_ports()

// Thread state
darwin.thread_state
darwin.thread_get_state()
darwin.thread_set_state()

// VM operations
darwin.mach_vm_read()
darwin.mach_vm_write()
darwin.mach_vm_protect()
darwin.mach_vm_region()

// Dispatch/GCD semaphores
darwin.dispatch_semaphore_create()
darwin.dispatch_semaphore_wait()
darwin.dispatch_semaphore_signal()

// Unfair locks
darwin.os_unfair_lock
darwin.os_unfair_lock_lock()
darwin.os_unfair_lock_unlock()

// Process spawning
darwin.posix_spawn()
darwin.posix_spawn_file_actions_*

// File copy
darwin.fcopyfile()
darwin.COPYFILE
```

### freebsd
```zig
// Futex-like operations
std.c._umtx_op()
std.c.UMTX_OP, std.c.UMTX_ABSTIME

// Capability rights
std.c.cap_rights

// Memory file descriptors
std.c.MFD

// Process info
std.c.kinfo_file
std.c.kinfo_getfile()
```

### openbsd
```zig
// Security
std.c.pledge()
std.c.unveil()

// Password hashing
std.c.bcrypt()
std.c.bcrypt_newhash()
std.c.bcrypt_checkpass()

// BSD authentication
std.c.auth_*  // Various auth functions

// Login capabilities
std.c.login_getclass()
std.c.login_getcapstr()
```

### netbsd
```zig
std.c._lwp_self()
std.c.lwpid_t
std.c._ksiginfo
```

### dragonfly
```zig
std.c.lwp_gettid()
std.c.umtx_sleep()
std.c.umtx_wakeup()
```

### solaris/illumos
```zig
// Port-based events
std.c.port_t
std.c.port_event
std.c.PORT_SOURCE
std.c.FILE_EVENT

// Types
std.c.zoneid_t
std.c.ctid_t
std.c.projid_t
```

### haiku
```zig
std.c.team_id
std.c.thread_id
std.c.area_id
std.c.area_info
std.c._get_next_area_info()
std.c._get_next_image_info()
std.c.find_directory()
std.c.get_system_info()
```

### serenity
```zig
std.c.PERF_EVENT
std.c.profiling_enable()
std.c.profiling_disable()
std.c.futex_wait()
std.c.futex_wake()
std.c.anon_create()
```

## Common Patterns

### Version Checking (glibc/musl)
```zig
// Check if glibc version supports a feature
if (std.c.versionCheck(.{ .major = 2, .minor = 28, .patch = 0 })) {
    // Use newer glibc feature
}
// Returns true for musl (always "current")
// Returns false if not linking libc
```

### FFI with C Libraries
```zig
// Declare external C function
extern "c" fn c_function(fd: std.c.fd_t, buf: [*]u8, len: std.c.size_t) std.c.ssize_t;

// Use std.c types for ABI compatibility
pub fn wrapper(fd: std.posix.fd_t, buf: []u8) !usize {
    const result = c_function(fd, buf.ptr, buf.len);
    if (result < 0) {
        const err = std.posix.errno(std.c._errno().*);
        return std.posix.unexpectedErrno(err);
    }
    return @intCast(result);
}
```

### Platform-Specific Type Handling
```zig
const builtin = @import("builtin");

fn platformSpecificCall() void {
    switch (builtin.os.tag) {
        .linux => {
            // Linux uses c_int for some syscalls
            const result: std.c.c_int = ...;
        },
        .macos, .ios => {
            // Darwin uses different types
            const port = std.c.darwin.mach_port_t;
        },
        .windows => {
            // Windows uses HANDLE
            const fd: std.c.fd_t = ...; // This is HANDLE on Windows
        },
        else => @compileError("Unsupported"),
    }
}
```

### Getting errno
```zig
// std.c._errno returns a pointer to errno
const c = std.c;

fn checkError(result: c.c_int) !void {
    if (result < 0) {
        const errno_val = c._errno().*;
        // Convert to std.posix error
        return std.posix.unexpectedErrno(@enumFromInt(errno_val));
    }
}
```

### Standard File Descriptors
```zig
const c = std.c;

c.STDIN_FILENO   // 0 (or equivalent)
c.STDOUT_FILENO  // 1
c.STDERR_FILENO  // 2
```

### Path Limits
```zig
c.PATH_MAX       // Maximum path length
c.NAME_MAX       // Maximum filename length
c.HOST_NAME_MAX  // Maximum hostname length
```
