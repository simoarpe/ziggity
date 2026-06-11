# std.zig - Zig Compiler Utilities Reference

Utilities for parsing, tokenizing, and working with Zig source code. Used for tooling, linters, formatters, and custom analysis.

## Table of Contents
- [Quick Start](#quick-start)
- [Tokenizer](#tokenizer)
- [AST Parsing](#ast-parsing)
- [AST Navigation](#ast-navigation)
- [AST Full Node Types](#ast-full-node-types)
- [Error Handling](#error-handling)
- [String/Number Literals](#stringnumber-literals)
- [Identifier Formatting](#identifier-formatting)
- [Source Utilities](#source-utilities)

## Quick Start

### Parse and Analyze Zig Source
```zig
const std = @import("std");

pub fn analyzeSource(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    // Parse source into AST
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    // Check for parse errors
    if (tree.errors.len > 0) {
        for (tree.errors) |err| {
            var buf: [256]u8 = undefined;
            var w: std.io.Writer = .fixed(&buf);
            try tree.renderError(err, &w);
            std.debug.print("Error: {s}\n", .{w.buffered()});
        }
        return error.ParseError;
    }

    // Iterate root declarations
    for (tree.rootDecls()) |decl| {
        const tag = tree.nodeTag(decl);
        std.debug.print("Declaration: {s}\n", .{@tagName(tag)});
    }
}
```

### Parse ZON Data
```zig
var tree = try std.zig.Ast.parse(allocator, zon_source, .zon);
defer tree.deinit(allocator);
// Root node contains the ZON expression
```

## Tokenizer

### std.zig.Tokenizer

Converts source text into tokens.

```zig
const source: [:0]const u8 = "const x = 42;";
var tokenizer = std.zig.Tokenizer.init(source);

while (true) {
    const token = tokenizer.next();
    if (token.tag == .eof) break;

    const lexeme = source[token.loc.start..token.loc.end];
    std.debug.print("{s}: '{s}'\n", .{ @tagName(token.tag), lexeme });
}
// Output:
// keyword_const: 'const'
// identifier: 'x'
// equal: '='
// number_literal: '42'
// semicolon: ';'
```

### Token Structure
```zig
const Token = struct {
    tag: Tag,
    loc: Loc,

    const Loc = struct {
        start: usize,
        end: usize,
    };
};
```

### Common Token Tags
```zig
.identifier          // Variable/function names
.number_literal      // 42, 0xff, 3.14
.string_literal      // "hello"
.char_literal        // 'a'
.builtin             // @import, @as
.keyword_const       // const
.keyword_var         // var
.keyword_fn          // fn
.keyword_pub         // pub
.keyword_if          // if
.keyword_for         // for
.keyword_while       // while
.keyword_return      // return
.equal               // =
.equal_equal         // ==
.l_paren             // (
.r_paren             // )
.l_brace             // {
.r_brace             // }
.semicolon           // ;
.comma               // ,
.period              // .
.doc_comment         // /// comment
.eof                 // End of file
```

### Keyword Lookup
```zig
// Check if identifier is a keyword
if (std.zig.Token.getKeyword("const")) |tag| {
    // tag == .keyword_const
}
```

## AST Parsing

### std.zig.Ast

Abstract Syntax Tree for Zig source code.

```zig
const Ast = struct {
    source: [:0]const u8,       // Original source
    tokens: TokenList.Slice,    // All tokens
    nodes: NodeList.Slice,      // All AST nodes
    extra_data: []u32,          // Additional node data
    mode: Mode,                 // .zig or .zon
    errors: []const Error,      // Parse errors
};
```

### Parsing
```zig
// Parse Zig source
var tree = try std.zig.Ast.parse(allocator, source, .zig);
defer tree.deinit(allocator);

// Parse ZON
var zon_tree = try std.zig.Ast.parse(allocator, zon_source, .zon);
defer zon_tree.deinit(allocator);
```

### Rendering (Formatting)
```zig
// Format AST back to source
const formatted = try tree.renderAlloc(allocator);
defer allocator.free(formatted);

// Or render to writer
var buf: [8192]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
try tree.render(allocator, &writer.interface, .{});
try writer.interface.flush();
```

## AST Navigation

### Basic Node Access
```zig
// Get node tag (what kind of node)
const tag = tree.nodeTag(node_index);

// Get main token for node
const main_token = tree.nodeMainToken(node_index);

// Get node data
const data = tree.nodeData(node_index);

// Get token slice (the actual text)
const text = tree.tokenSlice(token_index);

// Get token tag
const token_tag = tree.tokenTag(token_index);
```

### Root Declarations
```zig
// Get all top-level declarations
for (tree.rootDecls()) |decl| {
    switch (tree.nodeTag(decl)) {
        .fn_decl => handleFunction(tree, decl),
        .global_var_decl, .simple_var_decl => handleVariable(tree, decl),
        .container_decl, .container_decl_two => handleStruct(tree, decl),
        else => {},
    }
}
```

### Token Location
```zig
// Get line/column from token
const loc = tree.tokenLocation(0, token_index);
std.debug.print("Line {d}, Column {d}\n", .{ loc.line + 1, loc.column + 1 });
```

### Node Span (First/Last Token)
```zig
// Get first and last token of a node (for error highlighting)
const first = tree.firstToken(node);
const last = tree.lastToken(node);

// Get source text for entire node
const node_source = tree.getNodeSource(node);
```

## AST Full Node Types

The AST uses compact representations. Use `full*` methods to get structured access.

### Function Declarations
```zig
var buf: [1]std.zig.Ast.Node.Index = undefined;
if (tree.fullFnProto(&buf, node)) |fn_proto| {
    // Name
    if (fn_proto.name_token) |name| {
        std.debug.print("Function: {s}\n", .{tree.tokenSlice(name)});
    }

    // Parameters
    var it = fn_proto.iterate(&tree);
    while (it.next()) |param| {
        if (param.name_token) |name| {
            std.debug.print("  Param: {s}\n", .{tree.tokenSlice(name)});
        }
    }

    // Return type
    if (fn_proto.ast.return_type.unwrap()) |ret_type| {
        // Process return type node
    }
}
```

### Variable Declarations
```zig
fn processVarDecl(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) void {
    const var_decl = switch (tree.nodeTag(node)) {
        .global_var_decl => tree.globalVarDecl(node),
        .local_var_decl => tree.localVarDecl(node),
        .simple_var_decl => tree.simpleVarDecl(node),
        .aligned_var_decl => tree.alignedVarDecl(node),
        else => return,
    };

    // Name is token after mut_token (var/const)
    const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
    std.debug.print("Variable: {s}\n", .{name});

    // Type annotation
    if (var_decl.ast.type_node.unwrap()) |type_node| {
        // Process type
    }

    // Initializer
    if (var_decl.ast.init_node.unwrap()) |init_node| {
        // Process initializer
    }

    // Visibility
    if (var_decl.visib_token != null) {
        // pub
    }
}
```

### Container (Struct/Enum/Union)
```zig
var buf: [2]std.zig.Ast.Node.Index = undefined;
if (tree.fullContainerDecl(&buf, node)) |container| {
    // Get container keyword (struct/enum/union)
    const keyword = tree.tokenSlice(container.ast.main_token);

    // Iterate members
    for (container.ast.members) |member| {
        switch (tree.nodeTag(member)) {
            .container_field, .container_field_init, .container_field_align => {
                const field = tree.containerField(member);
                const name = tree.tokenSlice(field.ast.main_token);
                std.debug.print("  Field: {s}\n", .{name});
            },
            .fn_decl => {
                // Method
            },
            else => {},
        }
    }
}
```

### If Expressions
```zig
if (tree.nodeTag(node) == .@"if" or tree.nodeTag(node) == .if_simple) {
    const if_full = if (tree.nodeTag(node) == .@"if")
        tree.ifFull(node)
    else
        tree.ifSimple(node);

    // Condition
    const cond = if_full.ast.cond_expr;

    // Then branch
    const then_expr = if_full.ast.then_expr;

    // Else branch (if present)
    if (if_full.ast.else_expr.unwrap()) |else_expr| {
        // Process else
    }

    // Payload capture (if |x|)
    if (if_full.payload_token) |payload| {
        std.debug.print("Payload: {s}\n", .{tree.tokenSlice(payload)});
    }
}
```

### While/For Loops
```zig
if (tree.fullWhile(node)) |while_loop| {
    // Condition
    const cond = while_loop.ast.cond_expr;

    // Continue expression (: (i += 1))
    if (while_loop.ast.cont_expr.unwrap()) |cont| {
        // Process continue expr
    }

    // Payload (|item|)
    if (while_loop.payload_token) |payload| {
        std.debug.print("Payload: {s}\n", .{tree.tokenSlice(payload)});
    }

    // Label
    if (while_loop.label_token) |label| {
        std.debug.print("Label: {s}\n", .{tree.tokenSlice(label)});
    }
}

if (tree.fullFor(node)) |for_loop| {
    // Inputs (iterables)
    for (for_loop.ast.inputs) |input| {
        // Process each iterable
    }

    // Body
    const body = for_loop.ast.then_expr;

    // Else branch
    if (for_loop.ast.else_expr.unwrap()) |else_expr| {
        // Process else
    }
}
```

### Switch
```zig
if (tree.fullSwitch(node)) |switch_full| {
    // Condition being switched on
    const cond = switch_full.ast.condition;

    // Cases
    for (switch_full.ast.cases) |case_node| {
        if (tree.fullSwitchCase(case_node)) |case| {
            // Case values
            for (case.ast.values) |val| {
                // Each case value
            }

            // Case body
            const body = case.ast.target_expr;

            // Capture (|x|)
            if (case.payload_token) |payload| {
                std.debug.print("Capture: {s}\n", .{tree.tokenSlice(payload)});
            }
        }
    }
}
```

### Function Calls
```zig
var buf: [1]std.zig.Ast.Node.Index = undefined;
if (tree.fullCall(&buf, node)) |call| {
    // Callee (function being called)
    const callee = call.ast.fn_expr;

    // Arguments
    for (call.ast.params) |arg| {
        // Process each argument
    }
}
```

### Struct/Array Init
```zig
var buf: [2]std.zig.Ast.Node.Index = undefined;

// Struct init: .{ .x = 1, .y = 2 } or Type{ .x = 1 }
if (tree.fullStructInit(&buf, node)) |init| {
    // Type (if explicit)
    if (init.ast.type_expr.unwrap()) |type_node| {
        // Process type
    }

    // Field initializers
    for (init.ast.fields) |field| {
        // Each field init node
    }
}

// Array init: .{ 1, 2, 3 } or [3]u8{ 1, 2, 3 }
if (tree.fullArrayInit(&buf, node)) |init| {
    // Type (if explicit)
    if (init.ast.type_expr.unwrap()) |type_node| {
        // Process type
    }

    // Elements
    for (init.ast.elements) |elem| {
        // Process each element
    }
}
```

### Slices
```zig
if (tree.fullSlice(node)) |slice| {
    // Sliced expression
    const slicee = slice.ast.sliced;

    // Start index
    const start = slice.ast.start;

    // End index (if present)
    if (slice.ast.end.unwrap()) |end| {
        // Process end
    }

    // Sentinel (if present)
    if (slice.ast.sentinel.unwrap()) |sentinel| {
        // Process sentinel
    }
}
```

### Pointer Types
```zig
if (tree.fullPtrType(node)) |ptr| {
    // Child type
    const child = ptr.ast.child_type;

    // Size (.one, .many, .slice, .c)
    const size = ptr.size;

    // Sentinel
    if (ptr.ast.sentinel.unwrap()) |sentinel| {
        // Process sentinel
    }

    // Alignment
    if (ptr.ast.align_node.unwrap()) |align_node| {
        // Process alignment
    }

    // Const/volatile
    const is_const = ptr.const_token != null;
    const is_volatile = ptr.volatile_token != null;
}
```

## Error Handling

### Check for Parse Errors
```zig
var tree = try std.zig.Ast.parse(allocator, source, .zig);
defer tree.deinit(allocator);

if (tree.errors.len > 0) {
    for (tree.errors) |err| {
        // Get error location
        const token = err.token;
        const loc = tree.tokenLocation(0, token);

        // Format error message
        var buf: [512]u8 = undefined;
        var w: std.io.Writer = .fixed(&buf);
        try tree.renderError(err, &w);

        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{
            filename,
            loc.line + 1,
            loc.column + 1,
            w.buffered(),
        });
    }
}
```

### ErrorBundle

Structured error collection for compiler diagnostics.

```zig
const ErrorBundle = std.zig.ErrorBundle;

// Create error bundle from AST errors
var wip_errors: ErrorBundle.Wip = undefined;
try wip_errors.init(allocator);
defer wip_errors.deinit();

try std.zig.putAstErrorsIntoBundle(allocator, tree, "file.zig", &wip_errors);

var bundle = try wip_errors.toOwnedBundle("");
defer bundle.deinit(allocator);

// Render to stderr
bundle.renderToStdErr(.{ .ttyconf = .no_color });

// Or iterate errors
for (bundle.getMessages()) |msg_idx| {
    const msg = bundle.getErrorMessage(msg_idx);
    const text = bundle.nullTerminatedString(msg.msg);
    std.debug.print("Error: {s}\n", .{text});

    // Get source location
    if (msg.src_loc != .none) {
        const loc = bundle.getSourceLocation(msg.src_loc);
        std.debug.print("  at line {d}\n", .{loc.line + 1});
    }
}
```

## String/Number Literals

### Parse Character Literal
```zig
const result = std.zig.string_literal.parseCharLiteral("'\\n'");
switch (result) {
    .success => |codepoint| {
        std.debug.print("Codepoint: {d}\n", .{codepoint}); // 10
    },
    .failure => |err| {
        std.debug.print("Error: {f}\n", .{err.fmt("'\\n'")});
    },
}
```

### Parse Number Literal
```zig
const result = std.zig.number_literal.parseNumberLiteral("0xFF_AB");
switch (result) {
    .int => |value| std.debug.print("Integer: {d}\n", .{value}),
    .big_int => |base| std.debug.print("Big int, base {d}\n", .{@intFromEnum(base)}),
    .float => |base| std.debug.print("Float, base {d}\n", .{@intFromEnum(base)}),
    .failure => |err| std.debug.print("Invalid number\n", .{}),
}
```

## Identifier Formatting

### Escape Identifiers
```zig
// Format identifier, escaping if needed
var buf: [256]u8 = undefined;
var w: std.io.Writer = .fixed(&buf);
try w.print("{f}", .{std.zig.fmtId("while")});   // @"while"
try w.print("{f}", .{std.zig.fmtId("hello")});   // hello
try w.print("{f}", .{std.zig.fmtId("123abc")});  // @"123abc"
```

### Check Valid Identifier
```zig
std.zig.isValidId("foo")    // true
std.zig.isValidId("while")  // false (keyword)
std.zig.isValidId("3d")     // false (starts with digit)
std.zig.isValidId("a b")    // false (contains space)
```

### String Escaping
```zig
// Escape string for Zig string literal
var buf: [256]u8 = undefined;
var w: std.io.Writer = .fixed(&buf);
try w.print("\"{f}\"", .{std.zig.fmtString("hello\nworld")});
// Output: "hello\nworld"

// Escape character for char literal
try w.print("'{f}'", .{std.zig.fmtChar('\t')});
// Output: '\t'
```

## Source Utilities

### Find Line/Column
```zig
const loc = std.zig.findLineColumn(source, byte_offset);
std.debug.print("Line {d}, Column {d}\n", .{ loc.line + 1, loc.column + 1 });
std.debug.print("Source line: {s}\n", .{loc.source_line});
```

### Source Hash
```zig
// Hash source for caching/comparison
const hash = std.zig.hashSrc(source);

// Compare hashes
if (std.zig.srcHashEql(hash1, hash2)) {
    // Sources are identical
}
```

### Read Source File
```zig
// Read and decode source file (handles UTF-16LE BOM)
const file = try std.fs.cwd().openFile("source.zig", .{});
defer file.close();

var reader = file.reader(&buf);
const source = try std.zig.readSourceFileToEndAlloc(allocator, &reader);
defer allocator.free(source);
```

### Binary Name Generation
```zig
// Get output filename for compilation target
const name = try std.zig.binNameAlloc(allocator, .{
    .root_name = "myapp",
    .target = &target,
    .output_mode = .Exe,
    .link_mode = .dynamic,
});
defer allocator.free(name);
// "myapp" (Linux), "myapp.exe" (Windows), etc.
```

## Common Patterns

### Walk AST Recursively
```zig
fn walkNode(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) void {
    const tag = tree.nodeTag(node);

    switch (tag) {
        .fn_decl => {
            // Process function
            const data = tree.nodeData(node);
            walkNode(tree, data.node_and_node[0]); // fn_proto
            walkNode(tree, data.node_and_node[1]); // body
        },
        .block, .block_semicolon => {
            var buf: [2]std.zig.Ast.Node.Index = undefined;
            if (tree.blockStatements(&buf, node)) |stmts| {
                for (stmts) |stmt| {
                    walkNode(tree, stmt);
                }
            }
        },
        // ... handle other node types
        else => {},
    }
}

// Start from root
for (tree.rootDecls()) |decl| {
    walkNode(&tree, decl);
}
```

### Extract All Function Names
```zig
fn extractFunctionNames(allocator: Allocator, tree: *const std.zig.Ast) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buf, decl)) |fn_proto| {
            if (fn_proto.name_token) |name_tok| {
                try names.append(allocator, tree.tokenSlice(name_tok));
            }
        }
    }

    return names.toOwnedSlice(allocator);
}
```

### Simple Linter Example
```zig
fn checkForTodos(tree: *const std.zig.Ast) void {
    const tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);

    for (tags, 0..) |tag, i| {
        if (tag == .doc_comment) {
            const start = starts[i];
            const slice = tree.source[start..];
            const end = std.mem.indexOfScalar(u8, slice, '\n') orelse slice.len;
            const comment = slice[0..end];

            if (std.mem.indexOf(u8, comment, "TODO")) |_| {
                const loc = tree.tokenLocation(0, @intCast(i));
                std.debug.print("TODO found at line {d}\n", .{loc.line + 1});
            }
        }
    }
}
```
