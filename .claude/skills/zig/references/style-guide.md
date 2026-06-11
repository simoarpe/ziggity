# Zig Style Guide

Official coding conventions from the Zig language reference. These are implemented and enforced by `zig fmt`.

## Naming Conventions

### Summary Table

| Element | Convention | Example |
|---------|-----------|---------|
| Types | `TitleCase` | `XmlParser`, `HashMap` |
| Namespace structs (0 fields) | `snake_case` | `std.json`, `std.mem` |
| Functions | `camelCase` | `readU32Be`, `parseJson` |
| Functions returning `type` | `TitleCase` | `ArrayList`, `HashMap` |
| Variables/constants | `snake_case` | `const_name`, `global_var` |
| File names (types) | `TitleCase.zig` | `ArrayList.zig` |
| File names (namespaces) | `snake_case.zig` | `mem.zig`, `json.zig` |
| Directories | `snake_case` | `std/`, `hash_map/` |

### Rules in Detail

**Types use `TitleCase`:**
```zig
const StructName = struct { field: i32 };
const TypeName = @import("dir_name/TypeName.zig");
```

**Exception: Namespace structs (0 fields) use `snake_case`:**
```zig
const namespace_name = @import("dir_name/file_name.zig");
```

**Functions use `camelCase`:**
```zig
fn functionName(param_name: TypeName) void { }
fn readU32Be() u32 { }  // Acronyms treated as words
```

**Functions returning `type` use `TitleCase`:**
```zig
fn ListTemplateFunction(comptime ChildType: type, comptime fixed_size: usize) type {
    return List(ChildType, fixed_size);
}

fn ShortList(comptime T: type, comptime n: usize) type {
    return struct {
        field_name: [n]T,
        fn methodName() void {}
    };
}
```

**Variables and constants use `snake_case`:**
```zig
var global_var: i32 = undefined;
const const_name = 42;
const primitive_type_alias = f32;
const string_alias = []u8;
```

### Acronyms and Initialisms

Acronyms follow normal casing rules—they're treated as regular words:

```zig
// XML loses its all-caps when used in identifiers
const XmlParser = struct { field: i32 };
fn parseXml() void {}
const xml_document = "...";

// BE (Big Endian) treated as a word
fn readU32Be() u32 {}

// URL, HTTP, etc. follow the same rule
const HttpClient = struct {};
fn parseUrl() void {}
const api_url = "...";
```

### Established Conventions

Follow established conventions when they exist (e.g., `ENOENT` from POSIX):
```zig
const ENOENT = error.FileNotFound;
```

## Avoid Redundancy in Names

### Words to Avoid in Type Names

Don't use these words—they apply to everything and communicate nothing:
- `Value`
- `Data`
- `Context`
- `Manager`
- `utils`, `misc`, or somebody's initials

```zig
// BAD
const JsonValue = union(enum) { ... };
const DataManager = struct { ... };
const misc = @import("misc.zig");

// GOOD
const Value = union(enum) { ... };  // In json namespace: json.Value
const Store = struct { ... };
// Put utilities at module root, no namespace needed
```

### Avoid Redundancy in Fully-Qualified Namespaces

Don't repeat the namespace in the type name:

```zig
// BAD - "json" appears twice in json.JsonValue
pub const json = struct {
    pub const JsonValue = union(enum) { number: f64, boolean: bool };
};

// GOOD - json.Value is clear and non-redundant
pub const json = struct {
    pub const Value = union(enum) { number: f64, boolean: bool };
};
```

The same applies to files (which are implicit structs):
```zig
// In json.zig:
// BAD
pub const JsonParser = struct { ... };

// GOOD
pub const Parser = struct { ... };  // Used as json.Parser
```

## Whitespace

- **Indentation:** 4 spaces (not tabs)
- **Braces:** Opening brace on same line, unless wrapping is needed
- **Line length:** Aim for ~100 characters; use common sense
- **Trailing commas:** Use trailing commas for lists with more than 2 items

```zig
// Short list - can be on one line
const pair = .{ a, b };

// Longer list - one item per line with trailing comma
const Config = struct {
    name: []const u8,
    port: u16,
    timeout: u32,
    max_connections: usize,  // trailing comma
};
```

**Line wrapping:**
```zig
// When arguments don't fit, wrap and align
fn processRequest(
    allocator: Allocator,
    request: *const Request,
    options: ProcessOptions,
) !Response {
    // ...
}
```

## Doc Comments

- **Omit redundant information** that's already clear from the name
- **Duplicate information** across similar functions (helps IDEs)
- Use **"assume"** for invariants that cause *unchecked* illegal behavior when violated
- Use **"assert"** for invariants that cause *safety-checked* illegal behavior when violated

```zig
/// Reads a little-endian u32 from the buffer.
///
/// Caller must **assume** buffer has at least 4 bytes remaining.
/// This is not checked and will cause undefined behavior if violated.
fn readU32Le(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

/// Pops the last element from the list.
///
/// **Asserts** the list is not empty. In safe modes, returns an error
/// or panics if the list is empty.
fn pop(self: *Self) T {
    std.debug.assert(self.items.len > 0);
    // ...
}
```

## Source Encoding

- **UTF-8** encoding required
- **LF** (`\n`, 0x0a) line endings (CRLF discouraged but tolerated)
- End files with a newline
- No hard tabs (spaces only)
- `zig fmt` enforces all these conventions

## Applying the Style Guide

Run `zig fmt` to automatically format code according to these conventions:

```bash
# Format a single file
zig fmt src/main.zig

# Format entire project
zig fmt .

# Check without modifying (useful for CI)
zig fmt --check src/
```
