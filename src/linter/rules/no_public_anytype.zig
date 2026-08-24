//! ## What This Rule Does
//!
//! Disallows `anytype` parameters on functions that are part of a module's
//! public API.
//!
//! `anytype` erases the parameter from the function's signature. Callers cannot
//! tell what they are allowed to pass, generated documentation shows no type,
//! and a change to what the body requires of the argument breaks downstream
//! code without changing the declaration. Inside a module that cost is cheap:
//! every call site is in front of you. Across a module boundary it is paid by
//! people who cannot see the body.
//!
//! Most `anytype` parameters in public APIs have a concrete replacement:
//! a `comptime T: type` parameter plus a parameter of that type states the same
//! generic contract while keeping it visible in the signature.
//!
//! ### What Counts As Public
//!
//! A function is treated as public API when it is declared `pub` or `export`
//! **and** every declaration enclosing it is also `pub`. A `pub fn` inside a
//! file-private container, or inside a container declared in a function body,
//! cannot be named from another module, so it is left alone.
//!
//! ```zig
//! // not reported: `Impl` is file-private, so `Impl.run` is unreachable
//! // from other modules.
//! const Impl = struct {
//!   pub fn run(x: anytype) void { _ = x; }
//! };
//! ```
//!
//! ### Allowed Scenarios
//!
//! C-variadic parameters (`...`) are not `anytype` and are never reported.
//!
//! Some `std` interfaces require an `anytype` parameter, so the functions that
//! implement them cannot avoid one. `allowed_functions` lists function names
//! that are exempt; it defaults to the `std` interface methods below.
//!
//! ```json
//! {
//!   "rules": {
//!     "no-public-anytype": ["warn", {
//!       "allowed_functions": ["format", "jsonParse", "jsonParseFromValue", "jsonStringify"]
//!     }]
//!   }
//! }
//! ```
//!
//! :::info
//! Setting `allowed_functions` replaces the default list rather than adding to
//! it. Repeat the defaults you want to keep.
//! :::
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! pub fn add(a: anytype, b: anytype) @TypeOf(a, b) {
//!   return a + b;
//! }
//!
//! pub const Store = struct {
//!   // `comptime` does not make the parameter any easier to call correctly.
//!   pub fn put(self: *Store, key: []const u8, value: anytype) void {}
//! };
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // The generic contract is still there, but it is written down.
//! pub fn add(comptime T: type, a: T, b: T) T {
//!   return a + b;
//! }
//!
//! // Private functions may use `anytype` freely.
//! fn debugPrint(value: anytype) void {}
//!
//! pub const Store = struct {
//!   // `std` interfaces that mandate `anytype` are allowed by default.
//!   pub fn jsonStringify(self: Store, jws: anytype) !void {}
//! };
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

const NoPublicAnytype = @This();

/// Names of functions allowed to take `anytype` parameters. Defaults to the
/// `std` interface methods whose signatures mandate one.
allowed_functions: []const []const u8 = &[_][]const u8{
    "format",
    "jsonParse",
    "jsonParseFromValue",
    "jsonStringify",
},

pub const meta: Rule.Meta = .{
    .name = "no-public-anytype",
    .category = .restriction,
    .default = .off,
};

fn noPublicAnytypeDiagnostic(ctx: *LinterContext, fn_name: []const u8, anytype_token: TokenIndex) Error {
    var e = ctx.diagnosticf(
        "Public function '{s}' takes an `anytype` parameter",
        .{fn_name},
        .{ctx.labelT(anytype_token, "this parameter has no type in the signature", .{})},
    );
    e.help = Cow.static("Take a `comptime T: type` and a parameter of type `T`, or name a concrete type. Callers outside this module cannot see the body to find out what is accepted.");
    return e;
}

pub fn runOnNode(self: *const NoPublicAnytype, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();

    // Only functions with a body. A bare `.fn_proto` is either a function type
    // or an `extern` declaration, neither of which can take an `anytype`
    // parameter. Bare protos are also not linked to their parent container, so
    // the reachability check below cannot run on them.
    if (wrapper.node.tag != .fn_decl) return;

    var buf: [1]Node.Index = undefined;
    // SAFETY: `.fn_decl` nodes always have a full fn proto available.
    const proto: Ast.full.FnProto = ast.fullFnProto(&buf, wrapper.idx) orelse unreachable;

    if (!isPublic(ast, proto)) return;
    // Anonymous prototypes (`fn (u32) void` as a type) cannot be `pub`, so a
    // public function always has a name.
    const name_token = proto.name_token orelse return;
    const fn_name = ctx.semantic.tokenSlice(name_token);

    for (self.allowed_functions) |allowed| {
        if (std.mem.eql(u8, fn_name, allowed)) return;
    }
    if (!isEnclosedByPublicDecls(ctx, wrapper.idx)) return;

    var it = proto.iterate(ast);
    while (it.next()) |param| {
        // `anytype` and `...` share this field, so the token tag is what tells
        // them apart. A C-variadic `...` is not an `anytype` parameter.
        const token = param.anytype_ellipsis3 orelse continue;
        if (ast.tokenTag(token) != .keyword_anytype) continue;
        ctx.report(noPublicAnytypeDiagnostic(ctx, fn_name, token));
    }
}

/// `pub` makes a declaration importable; `export` puts it in the binary's
/// symbol table. Both put the signature in front of code that cannot see the
/// body. `extern` and `inline` share a token slot with `export`, so the tag is
/// what distinguishes them.
fn isPublic(ast: *const Ast, proto: Ast.full.FnProto) bool {
    if (proto.visib_token != null) return true;
    const modifier = proto.extern_export_inline_token orelse return false;
    return ast.tokenTag(modifier) == .keyword_export;
}

/// A `pub fn` is only reachable from another module if every declaration
/// wrapping it is public too. `const Impl = struct { pub fn f() void {} };`
/// exposes nothing, and neither does a container declared inside a function
/// body.
fn isEnclosedByPublicDecls(ctx: *LinterContext, fn_node: Node.Index) bool {
    const ast = ctx.ast();
    var buf: [1]Node.Index = undefined;

    var parents = ctx.links().iterParentIds(fn_node);
    // The first element is the function itself; `isPublic` already covers it.
    _ = parents.next();

    while (parents.next()) |parent| {
        if (ast.fullVarDecl(parent)) |var_decl| {
            if (var_decl.visib_token == null) return false;
        } else if (ast.nodeTag(parent) == .fn_decl) {
            // A type-returning function, e.g. `fn List(comptime T: type) type`.
            // Its methods are only public if the factory is.
            const proto = ast.fullFnProto(&buf, parent) orelse continue;
            if (!isPublic(ast, proto)) return false;
        }
    }
    return true;
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *NoPublicAnytype) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoPublicAnytype {
    const t = std.testing;

    var no_public_anytype = NoPublicAnytype{};
    var runner = RuleTester.init(t.allocator, no_public_anytype.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // private functions may use `anytype` freely
        "fn foo(x: anytype) void {}",
        "fn foo(comptime x: anytype) void {}",
        // concrete types
        "pub fn foo(x: u32) void {}",
        "pub fn foo() void {}",
        // `comptime T: type` is the documented alternative, not a violation
        "pub fn foo(comptime T: type, x: T) T { return x; }",
        "pub fn foo(comptime T: type, xs: []const T) void {}",
        // `pub` method on a file-private container is not reachable elsewhere
        \\const Impl = struct {
        \\  pub fn run(x: anytype) void {}
        \\};
        ,
        // container declared inside a function body
        \\pub fn outer() void {
        \\  const S = struct {
        \\    pub fn run(x: anytype) void {}
        \\  };
        \\}
        ,
        // private container nested inside a public one
        \\pub const Foo = struct {
        \\  const Inner = struct {
        \\    pub fn run(x: anytype) void {}
        \\  };
        \\};
        ,
        // private method on a public container
        \\pub const Foo = struct {
        \\  fn helper(x: anytype) void {}
        \\};
        ,
        // methods of a private type factory
        \\fn List(comptime T: type) type {
        \\  return struct {
        \\    pub fn push(self: *@This(), value: anytype) void {}
        \\  };
        \\}
        ,
        // C-variadic `...` shares a token slot with `anytype` in the parse
        // tree, but is not a violation
        "pub fn printf(fmt: [*:0]const u8, ...) c_int {}",
        // `std` interface methods are allowed by default
        \\pub const Foo = struct {
        \\  pub fn format(self: Foo, writer: anytype) !void {}
        \\};
        ,
        \\pub const Foo = struct {
        \\  pub fn jsonStringify(self: Foo, jws: anytype) !void {}
        \\};
        ,
        // a function type is not a declaration, so it is never public
        "pub const Callback = fn (x: u32) void;",
    };

    const fail = &[_][:0]const u8{
        "pub fn foo(x: anytype) void {}",
        // `comptime x: anytype` is still an untyped parameter
        "pub fn foo(comptime x: anytype) void {}",
        // every `anytype` parameter is reported, not just the first
        "pub fn add(a: anytype, b: anytype) @TypeOf(a, b) { return a + b; }",
        // a mix of typed and untyped parameters
        "pub fn foo(name: []const u8, value: anytype) void {}",
        // methods on a public container
        \\pub const Store = struct {
        \\  pub fn put(self: *Store, value: anytype) void {}
        \\};
        ,
        // methods of a public type factory
        \\pub fn List(comptime T: type) type {
        \\  return struct {
        \\    pub fn push(self: *@This(), value: anytype) void {}
        \\  };
        \\}
        ,
        // a name close to, but not on, the default allowlist
        \\pub const Foo = struct {
        \\  pub fn formatValue(self: Foo, writer: anytype) !void {}
        \\};
        ,
        // `export` is public API even without `pub`
        "export fn foo(x: anytype) void {}",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
