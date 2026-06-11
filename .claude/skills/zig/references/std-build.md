
# std.Build - Zig Build System Reference

The Zig build system models projects as directed acyclic graphs (DAG) of build steps. Build scripts are written in Zig itself (`build.zig`), providing full language features during configuration.

## Table of Contents
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Custom Targets](#custom-targets)
- [Creating Executables and Libraries](#creating-executables-and-libraries)
- [Modules](#modules)
- [Build Options](#build-options)
- [Build Steps](#build-steps)
- [Dependencies](#dependencies)
- [Running Commands](#running-commands)
- [Installing Artifacts](#installing-artifacts)
- [Testing](#testing)
- [Generating Files](#generating-files)
- [C/C++ Integration](#cc-integration)
- [LazyPath](#lazypath)
- [LazyPath Deep Dive](#lazypath-deep-dive)
- [Build Allocation](#build-allocation)
- [build.zig.zon](#buildzon)
- [CLI Reference](#cli-reference)

## Quick Start

### Minimal build.zig (0.15.x)
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
```

**CRITICAL (0.15.x):** `root_source_file` field in `addExecutable`/`addLibrary`/`addTest` is REMOVED. Use `root_module` with `b.createModule()`.

## Core Concepts

### Build Graph
The build system is a DAG where:
- **Nodes** are `Step` objects (compile, run, install, etc.)
- **Edges** are dependencies between steps
- Steps run concurrently when dependencies allow
- Caching prevents redundant work

### Key Types
```zig
// Main build context
const Build = std.Build;

// Build steps
const Step = std.Build.Step;

// Compile artifacts (exe, lib, obj, test)
const Compile = std.Build.Step.Compile;

// Module (compilation unit with source, target, optimize)
const Module = std.Build.Module;

// Lazy path reference (resolved at build time)
const LazyPath = std.Build.LazyPath;

// Target configuration
const ResolvedTarget = std.Build.ResolvedTarget;
```

### Standard Options
```zig
// Get target (defaults to native, user can override with -Dtarget)
const target = b.standardTargetOptions(.{});

// Get optimization (defaults to Debug, user can override with -Doptimize)
const optimize = b.standardOptimizeOption(.{});

// With defaults/constraints
const target = b.standardTargetOptions(.{
    .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .whitelist = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    },
});

const optimize = b.standardOptimizeOption(.{
    .preferred_optimize_mode = .ReleaseFast,  // Default for --release
});
```

## Custom Targets

### Programmatic Target Configuration
For cross-compilation or building with specific CPU features, use `std.Target.Query`:

```zig
// Build WebAssembly with specific features
const wasm_query: std.Target.Query = .{
    .cpu_arch = .wasm32,
    .os_tag = .freestanding,
    .cpu_features_add = std.Target.wasm.featureSet(&.{ .bulk_memory, .multivalue }),
};
const wasm_target = b.resolveTargetQuery(wasm_query);

const wasm_module = b.addExecutable(.{
    .name = "module",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    }),
});
```

### Host Target for Build Tools
When building tools that run during the build (code generators, asset processors), use the host target:

```zig
// Build a code generator that runs on the host machine
const codegen_tool = b.addExecutable(.{
    .name = "codegen",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/codegen.zig"),
        .target = b.graph.host,  // Always builds for the machine running the build
        .optimize = .ReleaseFast,
    }),
});

// This tool can be run even when cross-compiling the main project
const run_codegen = b.addRunArtifact(codegen_tool);
```

### CPU Feature Sets
Enable specific CPU features for optimized builds:

```zig
// x86_64 with AVX2 and FMA
const x86_query: std.Target.Query = .{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
    .cpu_features_add = std.Target.x86.featureSet(&.{ .avx2, .fma }),
};

// ARM with NEON
const arm_query: std.Target.Query = .{
    .cpu_arch = .aarch64,
    .os_tag = .linux,
    .cpu_features_add = std.Target.aarch64.featureSet(&.{ .neon, .crypto }),
};
```

## Creating Executables and Libraries

### Executable
```zig
const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
    .version = .{ .major = 1, .minor = 0, .patch = 0 },  // optional
    .linkage = .dynamic,  // optional: .static (default) or .dynamic
});
```

### Static Library
```zig
const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .static,  // default
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Dynamic/Shared Library
```zig
const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .dynamic,
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
    .version = .{ .major = 1, .minor = 2, .patch = 3 },
});
```

### Object File
```zig
const obj = b.addObject(.{
    .name = "myobj",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/obj.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

## Modules

### Creating Modules
```zig
// Private module (not exposed to dependents)
const private_mod = b.createModule(.{
    .root_source_file = b.path("src/helper.zig"),
    .target = target,
    .optimize = optimize,
});

// Public module (exposed to packages depending on this one)
const public_mod = b.addModule("mymodule", .{
    .root_source_file = b.path("src/mymodule.zig"),
    .target = target,
    .optimize = optimize,
});
```

### Adding Imports to Modules
```zig
// Add module import
exe.root_module.addImport("helper", private_mod);

// Add module from dependency
const dep = b.dependency("some_lib", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("some_lib", dep.module("some_lib"));

// Anonymous import (inline module)
exe.root_module.addAnonymousImport("generated", .{
    .root_source_file = generated_file,
    .target = target,
    .optimize = optimize,
});
```

### Build Options as Module
```zig
const options = b.addOptions();
options.addOption(bool, "enable_feature", enable_feature);
options.addOption([]const u8, "version", "1.0.0");

exe.root_module.addOptions("config", options);

// In Zig code:
// const config = @import("config");
// if (config.enable_feature) { ... }
```

## Build Options

### Declaring Options
```zig
// Boolean option
const enable_debug = b.option(bool, "debug", "Enable debug mode") orelse false;

// String option
const output_name = b.option([]const u8, "name", "Output name") orelse "default";

// Enum option
const Backend = enum { opengl, vulkan, metal };
const backend = b.option(Backend, "backend", "Graphics backend") orelse .opengl;

// Integer option
const threads = b.option(u32, "threads", "Number of threads") orelse 4;

// List option
const features = b.option([]const []const u8, "features", "Features to enable") orelse &.{};

// Path option
const config_path = b.option(std.Build.LazyPath, "config", "Path to config file");
```

### Using Options
```zig
// Pass options to compile step
if (enable_debug) {
    exe.root_module.addCMacro("DEBUG", "1");
}

// Create options module for runtime access
const options = b.addOptions();
options.addOption(bool, "debug", enable_debug);
options.addOption(Backend, "backend", backend);
exe.root_module.addOptions("build_options", options);
```

## Build Steps

### Creating Custom Steps
```zig
// Named top-level step (visible in `zig build --list-steps`)
const test_step = b.step("test", "Run unit tests");
const bench_step = b.step("bench", "Run benchmarks");

// Add dependencies
test_step.dependOn(&run_tests.step);
bench_step.dependOn(&run_benchmarks.step);

// Get built-in steps
const install_step = b.getInstallStep();  // default step
const uninstall_step = b.getUninstallStep();
```

### Step Dependencies
```zig
// Make step B depend on step A (A runs first)
step_b.dependOn(&step_a.step);

// Chain multiple dependencies
const build_step = b.step("all", "Build everything");
build_step.dependOn(&exe.step);
build_step.dependOn(&lib.step);
build_step.dependOn(&tests.step);
```

### Fail Step
```zig
// Fail with message (useful for unsupported configurations)
if (!target.result.os.tag.isDarwin()) {
    const fail = b.addFail("This project only supports macOS");
    build_step.dependOn(&fail.step);
    return;
}
```

### Compile Step Outputs
Access various outputs from compile steps:

```zig
const lib = b.addLibrary(.{
    .name = "mylib",
    .linkage = .static,
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

// Get LazyPath to the compiled binary in .zig-cache
const bin_path = lib.getEmittedBin();

// Get assembly output for debugging codegen (like godbolt.org but for your project)
const asm_path = lib.getEmittedAsm();
const install_asm = b.addInstallFile(asm_path, "debug/lib.s");
const asm_step = b.step("asm", "View generated assembly");
asm_step.dependOn(&install_asm.step);
```

### Run Step Data Dependencies
Pass file and directory paths as arguments while establishing proper data dependencies:

```zig
const gen_tool = b.addExecutable(.{
    .name = "gen",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen.zig"),
        .target = b.graph.host,
    }),
});

const run_gen = b.addRunArtifact(gen_tool);

// Directory input with prefix (--shader-dir=/path/to/shaders)
run_gen.addPrefixedDirectoryArg("--shader-dir=", b.path("data/shaders"));

// Output file with prefix (--out=/path/to/output.h)
// Returns LazyPath to the generated file
const generated_header = run_gen.addPrefixedOutputFileArg("--out=", "shaders.h");

// The step now has data dependencies: if shaders change, it re-runs
```

### UpdateSourceFiles Step
Copy generated files back into the source tree (for committing generated code):

```zig
const update_src = b.addUpdateSourceFiles();
update_src.addCopyFileToSource(generated_file, "src/generated.zig");

const update_step = b.step("update-generated", "Update generated source files");
update_step.dependOn(&update_src.step);
```

## Dependencies

### Declaring in build.zig.zon
```zig
.{
    .name = "myproject",
    .version = "1.0.0",
    .dependencies = .{
        .zlib = .{
            .url = "https://github.com/user/zlib-zig/archive/v1.0.0.tar.gz",
            .hash = "1220abc123...",
        },
        .local_lib = .{
            .path = "../local-lib",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

### Using Dependencies
```zig
// Get dependency
const zlib = b.dependency("zlib", .{
    .target = target,
    .optimize = optimize,
});

// Get module from dependency
exe.root_module.addImport("zlib", zlib.module("zlib"));

// Get artifact from dependency
exe.linkLibrary(zlib.artifact("z"));

// Get path from dependency
const include_path = zlib.path("include");
exe.root_module.addIncludePath(include_path);
```

### Lazy Dependencies
Lazy dependencies are only fetched when actually used, avoiding unnecessary downloads for platform-specific or optional dependencies.

**In build.zig.zon:**
```zig
.dependencies = .{
    // Mark platform-specific dependency as lazy
    .@"dawn-windows-x64" = .{
        .url = "https://github.com/example/dawn/releases/download/v1.0/dawn-windows-x64.tar.gz",
        .hash = "1220abc...",
        .lazy = true,  // Only fetched when lazyDependency() is called
    },
    .@"dawn-linux-x64" = .{
        .url = "https://github.com/example/dawn/releases/download/v1.0/dawn-linux-x64.tar.gz",
        .hash = "1220def...",
        .lazy = true,
    },
},
```

**In build.zig:**
```zig
// lazyDependency returns ?*Dependency (null if not yet fetched)
const dawn_dep = switch (target.result.os.tag) {
    .windows => b.lazyDependency("dawn-windows-x64", .{}),
    .linux => b.lazyDependency("dawn-linux-x64", .{}),
    else => null,
};

if (dawn_dep) |dep| {
    // Dependency is available, use normally
    exe.addLibraryPath(dep.path("lib"));
    exe.linkSystemLibrary("dawn");
}
```

**How it works:** After the build graph is constructed, `zig build` checks if any `lazyDependency()` calls require unfetched dependencies (returned null). If so, it fetches them and re-runs the build script with the dependencies now available.

### Passing Options to Dependencies
```zig
const dep = b.dependency("configurable_lib", .{
    .target = target,
    .optimize = optimize,
    .enable_feature = true,
    .backend = @as([]const u8, "vulkan"),
});
```

## Running Commands

### Run Compiled Artifact
```zig
const run_cmd = b.addRunArtifact(exe);

// Pass command line arguments
if (b.args) |args| {
    run_cmd.addArgs(args);
}

// Fixed arguments
run_cmd.addArgs(&.{ "--config", "debug.json" });

// Change working directory
run_cmd.setCwd(b.path("data"));

// Set environment variables
run_cmd.setEnvironmentVariable("DEBUG", "1");

// Create run step
const run_step = b.step("run", "Run the application");
run_step.dependOn(&run_cmd.step);
```

### Run System Command
```zig
const cmd = b.addSystemCommand(&.{ "git", "describe", "--tags" });

// Capture output
const version = cmd.captureStdOut();

// Use output as file
const version_file = b.addInstallFile(version, "version.txt");
```

### Run Project Tool
```zig
// Build and run a tool from the project
const tool = b.addExecutable(.{
    .name = "codegen",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/codegen.zig"),
        .target = b.graph.host,  // Build for host
        .optimize = .ReleaseFast,
    }),
});

const run_tool = b.addRunArtifact(tool);
run_tool.addArgs(&.{ "input.json" });

// Capture generated output
const generated = run_tool.addOutputFileArg("generated.zig");

// Use as source file
exe.root_module.addAnonymousImport("generated", .{
    .root_source_file = generated,
});
```

## Installing Artifacts

### Basic Installation
```zig
// Install to default location (zig-out/bin or zig-out/lib)
b.installArtifact(exe);
b.installArtifact(lib);
```

### Custom Installation
```zig
// Install with custom options
const install = b.addInstallArtifact(exe, .{
    .dest_dir = .{ .custom = "tools" },  // zig-out/tools/
});
b.getInstallStep().dependOn(&install.step);

// Install file
b.installFile("assets/config.json", "share/config.json");
b.installBinFile("scripts/run.sh", "run.sh");

// Install directory
b.installDirectory(.{
    .source_dir = b.path("assets"),
    .install_dir = .{ .custom = "share" },
    .install_subdir = "assets",
});
```

### Install Generated Files
```zig
// Install documentation
const docs_install = b.addInstallDirectory(.{
    .source_dir = lib.getEmittedDocs(),
    .install_dir = .prefix,
    .install_subdir = "docs",
});

const docs_step = b.step("docs", "Generate documentation");
docs_step.dependOn(&docs_install.step);
```

## Testing

### Unit Tests
```zig
const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

// Add imports (same as executable)
tests.root_module.addImport("helper", helper_mod);

// Run tests
const run_tests = b.addRunArtifact(tests);

const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_tests.step);
```

### Test Multiple Files
```zig
const test_files = &[_][]const u8{
    "src/parser.zig",
    "src/lexer.zig",
    "src/codegen.zig",
};

const test_step = b.step("test", "Run all tests");

for (test_files) |file| {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(t).step);
}
```

### Filtering Tests
```zig
const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
    }),
    .filters = &.{"specific_test_name"},  // Only run matching tests
});
```

### Cross-Platform Testing
```zig
const run_tests = b.addRunArtifact(tests);
run_tests.skip_foreign_checks = true;  // Don't fail for non-native targets
```

## Generating Files

### WriteFiles Step
```zig
const wf = b.addWriteFiles();

// Add string content
_ = wf.add("config.json",
    \\{
    \\  "version": "1.0"
    \\}
);

// Copy file
_ = wf.addCopyFile(b.path("template.txt"), "output.txt");

// Get directory for use elsewhere
const dir = wf.getDirectory();
```

### ConfigHeader (for C headers)
```zig
// CMake-style config.h generation
const config_h = b.addConfigHeader(.{
    .style = .{ .cmake = b.path("config.h.in") },
}, .{
    .HAVE_FEATURE = true,
    .VERSION_STRING = "1.0.0",
});

exe.addConfigHeader(config_h);
```

### Code Generation with Zig Tool
```zig
const gen_tool = b.addExecutable(.{
    .name = "gen",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen.zig"),
        .target = b.graph.host,
    }),
});

const gen_run = b.addRunArtifact(gen_tool);
gen_run.addFileArg(b.path("schema.json"));
const generated = gen_run.addOutputFileArg("generated.zig");

exe.root_module.addAnonymousImport("schema", .{
    .root_source_file = generated,
});
```

## C/C++ Integration

> **Note:** Compile-level methods like `exe.addCSourceFiles()`, `exe.linkSystemLibrary()`,
> `exe.addIncludePath()`, `exe.linkLibC()` are **deprecated** (to be removed after 0.15.0).
> Use `exe.root_module.*` equivalents shown below.

### Adding C Sources
```zig
exe.root_module.addCSourceFiles(.{
    .root = b.path("src/c"),
    .files = &.{ "foo.c", "bar.c" },
    .flags = &.{ "-Wall", "-O2" },
});

exe.root_module.addCSourceFile(.{
    .file = b.path("src/main.c"),
    .flags = &.{"-std=c11"},
});
```

### Include Paths and Macros
```zig
exe.root_module.addIncludePath(b.path("include"));
exe.root_module.addSystemIncludePath(b.path("deps/include"));
exe.root_module.addCMacro("DEBUG", "1");
exe.root_module.addCMacro("VERSION", "\"1.0.0\"");
```

### Linking Libraries
```zig
// System library
exe.root_module.linkSystemLibrary("pthread", .{});
exe.root_module.linkSystemLibrary("ssl", .{});

// Static library file
exe.addObjectFile(b.path("lib/libfoo.a"));

// Library search path
exe.addLibraryPath(b.path("lib"));
exe.addRPath(b.path("lib"));

// Link libc (set via createModule options or directly)
exe.root_module.link_libc = true;
exe.root_module.link_libcpp = true;
```

### pkg-config Integration
```zig
// Use pkg-config to find library
exe.root_module.linkSystemLibrary("openssl", .{});
exe.root_module.linkSystemLibrary("libcurl", .{});
```

### Best Practices: Prefer Zig APIs Over Clang Flags
When building C/C++ code, prefer Zig's explicit APIs over raw Clang flags for better type safety and build graph visibility:

```zig
// PREFERRED: Use Zig APIs
exe.root_module.addIncludePath(b.path("include"));          // Instead of -I
exe.root_module.addSystemIncludePath(dep.path("include")); // Instead of -isystem

// PREFERRED: Use Module.CreateOptions
const mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = false,    // Instead of -nolibc flag
    .sanitize_c = .off,    // Type is ?std.zig.SanitizeC (.off/.trap/.full)
});

// AVOID: Raw Clang flags (use only when no Zig API exists)
exe.root_module.addCSourceFiles(.{
    .files = &.{"foo.c"},
    .flags = &.{"-DDEBUG"},  // Use addCMacro instead when possible
});
```

This approach:
- Provides type-checked configuration
- Gives the build graph visibility into dependencies
- Supports LazyPaths for generated/dependency paths
- Prevents flags from conflicting with each other

## LazyPath

LazyPath represents paths that may not exist until build time.

### Types of LazyPath
```zig
// Source file relative to build root
const src = b.path("src/main.zig");

// Generated file from a step
const generated = step.getOutput();

// From dependency
const dep_file = dep.path("include/header.h");

// CWD-relative (avoid when possible)
const cwd_path: std.Build.LazyPath = .{ .cwd_relative = "/absolute/path" };
```

### Using LazyPath
```zig
// As source file
exe.root_module.root_source_file = b.path("src/main.zig");

// As include path
exe.addIncludePath(dep.path("include"));

// Install
b.installFile(generated_file, "share/output.txt");
```

## LazyPath Deep Dive

LazyPath is central to how data flows between build steps. Understanding its variants and methods is key to advanced build scripts.

### The Four Variants
```zig
const LazyPath = union(enum) {
    // Path relative to build root (most common)
    src_path: struct { root: ?*Build, sub_path: []const u8 },

    // Output from a build step (e.g., compiled binary, generated file)
    generated: struct { file: *GeneratedFile, sub_path: ?[]const u8 },

    // Absolute or CWD-relative path (use sparingly)
    cwd_relative: []const u8,

    // Path inside a dependency package
    dependency: struct { dep: *Dependency, sub_path: []const u8 },
};
```

### Creating LazyPaths
```zig
// From build root (returns src_path variant)
const src = b.path("src/main.zig");

// From build step output (returns generated variant)
const bin = exe.getEmittedBin();
const generated = run_step.addOutputFileArg("output.txt");

// From dependency (returns dependency variant)
const dep_header = zlib.path("include/zlib.h");

// Absolute path (returns cwd_relative variant - avoid when possible)
const abs: LazyPath = .{ .cwd_relative = "/usr/include" };
```

### Establishing Data Dependencies
When passing LazyPaths between steps, use `addStepDependencies()` to ensure proper ordering:

```zig
const gen_step = b.addRunArtifact(generator);
const generated_file = gen_step.addOutputFileArg("data.bin");

// IMPORTANT: Establish that compile step depends on gen_step's output
generated_file.addStepDependencies(&exe.step);

// Now exe will wait for gen_step to complete before compiling
exe.root_module.addAnonymousImport("data", .{
    .root_source_file = generated_file,
});
```

### Path Navigation
```zig
const base = b.path("src/modules/parser");

// Navigate to parent directory
const parent = base.dirname();  // "src/modules"

// Concatenate subpath
const file = base.join("lexer.zig");  // "src/modules/parser/lexer.zig"

// Chain operations
const sibling = base.dirname().join("utils/helpers.zig");  // "src/modules/utils/helpers.zig"
```

## Build Allocation

The Build struct provides an arena allocator for convenient memory management in build scripts.

### Using the Arena Allocator
```zig
pub fn build(b: *std.Build) void {
    // b.allocator is an arena - no need to free allocations
    const items = b.allocator.alloc(u8, 1024) catch @panic("OOM");
    // No need to call b.allocator.free(items)

    // All allocations are freed when the build completes
}
```

### Convenience Functions
```zig
// Join paths without allocator noise
const full_path = b.pathJoin(&.{ "src", "modules", "parser.zig" });

// Format strings without worrying about storage
const name = b.fmt("myapp-{s}-{s}", .{
    @tagName(target.result.cpu_arch),
    @tagName(target.result.os_tag),
});

// Both return arena-allocated strings that don't need freeing
```

## build.zig.zon

ZON (Zig Object Notation) is used for package manifests.

### Full Example
```zig
.{
    // Package name (required)
    .name = "my_project",

    // Semantic version (required)
    .version = "1.2.3",

    // Minimum Zig version (optional)
    .minimum_zig_version = "0.15.0",

    // Dependencies (optional)
    .dependencies = .{
        // URL dependency with hash
        .@"zig-network" = .{
            .url = "https://github.com/user/zig-network/archive/v1.0.0.tar.gz",
            .hash = "12205f17c...",
        },

        // Local path dependency
        .local_dep = .{
            .path = "../other-project",
        },

        // Lazy dependency (only fetched if used)
        .optional_dep = .{
            .url = "https://example.com/dep.tar.gz",
            .hash = "1220abc...",
            .lazy = true,
        },
    },

    // Files included in package (required for publishing)
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "LICENSE",
        "README.md",
    },
}
```

### Getting Dependency Hash
```bash
# Zig will tell you the expected hash on first build
zig build

# Or fetch and display hash
zig fetch https://github.com/user/repo/archive/v1.0.0.tar.gz
```

## CLI Reference

### Common Commands
```bash
# Build (runs install step)
zig build

# Run specific step
zig build run
zig build test

# List available steps
zig build --list-steps

# Build with options
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# Release build
zig build --release=fast
zig build --release=safe
zig build --release=small

# Verbose output
zig build --verbose

# Parallel jobs
zig build -j4

# Watch mode (rebuild on changes)
zig build --watch

# Web UI for build visualization
zig build --webui

# Fetch dependencies
zig build --fetch
```

### Debug Options
```bash
# Debug compiler output
zig build --verbose-link
zig build --verbose-cc
zig build --verbose-air
zig build --verbose-llvm-ir

# Reference trace for errors
zig build -freference-trace=10

# Time report
zig build --time-report
```

### Installation Paths
```bash
# Custom install prefix
zig build -p /usr/local
zig build --prefix=/opt/myapp

# Custom subdirectories
zig build --prefix-lib-dir=lib64
zig build --prefix-exe-dir=sbin
```

## Common Patterns

### Build for Multiple Targets
```zig
const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

for (targets) |t| {
    const resolved = b.resolveTargetQuery(t);
    const exe = b.addExecutable(.{
        .name = b.fmt("myapp-{s}-{s}", .{
            @tagName(t.cpu_arch.?),
            @tagName(t.os_tag.?),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(exe);
}
```

### Example Suite
```zig
const examples = [_][]const u8{ "basic", "advanced", "demo" };

const examples_step = b.step("examples", "Build examples");

for (examples) |name| {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("mylib", lib_mod);

    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .custom = "examples" },
    });
    examples_step.dependOn(&install.step);
}
```

### Format Check Step
```zig
const fmt_step = b.step("fmt", "Check formatting");

const fmt = b.addFmt(.{
    .paths = &.{ "src/", "build.zig" },
    .check = true,
});

fmt_step.dependOn(&fmt.step);
```

### Clean Step
```zig
const clean_step = b.step("clean", "Clean build artifacts");

clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);

// Note: zig-cache deletion may fail on Windows while build is running
if (@import("builtin").os.tag != .windows) {
    clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);
}
```
