//! ## What This Rule Does
//! Disallows calls to function paths listed in this rule's configuration.
//!
//! This rule ships with an empty list, so it reports nothing until you
//! configure it. It is a policy hook, not an opinion about which functions are
//! dangerous: teams use it to ban whatever their codebase should not call, such
//! as a process-killing helper in library code or a deprecated internal API.
//!
//! ### Configuration
//! `paths` holds the call paths to restrict, written the way they are spelled
//! at the call site after aliases are followed.
//!
//! ```json
//! {
//!   "rules": {
//!     "no-restricted-calls": ["error", {
//!       "paths": ["std.process.exit", "std.time.sleep"]
//!     }]
//!   }
//! }
//! ```
//!
//! ### How Call Paths Are Resolved
//! A call's path is built from the identifiers in its callee expression, joined
//! with `.`. `std.process.exit(1)` has the path `std.process.exit`, and
//! `exit(1)` has the path `exit`.
//!
//! Before comparing, `const` aliases are followed to what they were declared
//! as, so all three calls below have the path `std.process.exit`:
//!
//! ```zig
//! const std = @import("std");
//! const process = std.process;
//! const exit = std.process.exit;
//!
//! fn quit() void {
//!     std.process.exit(1);
//!     process.exit(1);
//!     exit(1);
//! }
//! ```
//!
//! An alias only resolves when it is in scope, so anything that shadows it —
//! a parameter, a local, an inner declaration — keeps the name it was written
//! with.
//!
//! :::info
//! Paths are matched literally and in full, segment for segment. There is no
//! wildcard or glob syntax, so `std.*` restricts a function literally named `*`
//! and matches nothing in practice, and restricting `std.debug` does not
//! restrict `std.debug.print`.
//! :::
//!
//! ### Limitations
//! ZLint has no type checker, so this rule reasons about names alone. Calls
//! whose callee is not a plain dotted path are never reported, which covers
//! method calls on values (`list.append(x)`), calls on the result of another
//! call (`gpa.allocator().free(p)`), and builtins (`@panic("...")`).
//!
//! `@import` is followed only for module names, so `@import("std").process.exit(1)`
//! resolves to `std.process.exit`, while imports of a file path do not resolve.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule, given
//! `{ "paths": ["std.process.exit"] }`:
//! ```zig
//! const std = @import("std");
//! fn quit() void {
//!     std.process.exit(1);
//! }
//! ```
//!
//! ```zig
//! const std = @import("std");
//! const exit = std.process.exit;
//! fn quit() void {
//!     exit(1);
//! }
//! ```
//!
//! Examples of **correct** code for this rule, given the same configuration:
//! ```zig
//! const std = @import("std");
//! fn quit() !void {
//!     // referencing a restricted path without calling it is allowed
//!     const exit = std.process.exit;
//!     _ = exit;
//!     return error.Quit;
//! }
//! ```
//!
//! ```zig
//! const std = @import("std");
//! const process = std.process;
//!
//! // the parameter shadows the alias, so this path is `process.exit`
//! fn quit(process: Process) void {
//!     process.exit(1);
//! }
//! ```

const std = @import("std");
const util = @import("util");
const ast_utils = @import("../ast_utils.zig");
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const eql = std.mem.eql;

const NoRestrictedCalls = @This();

/// Call paths that may not be called, e.g. `std.process.exit`.
paths: []const []const u8 = &[_][]const u8{},

pub const meta: Rule.Meta = .{
    .name = "no-restricted-calls",
    .category = .restriction,
    .default = .off,
};

/// Longest callee path this rule resolves. Doubles as the recursion budget for
/// `collectPath`, which bounds alias chains so a `const a = b; const b = a;`
/// cycle cannot hang the linter.
const MAX_SEGMENTS: u8 = 16;

/// A callee expression split into its identifier segments, left to right.
/// `std.process.exit` becomes `{ "std", "process", "exit" }`.
const Path = struct {
    segments: [MAX_SEGMENTS][]const u8 = undefined,
    len: u8 = 0,

    /// Returns `false` once the path is longer than this rule resolves.
    fn push(self: *Path, segment: []const u8) bool {
        if (self.len >= MAX_SEGMENTS) return false;
        self.segments[self.len] = segment;
        self.len += 1;
        return true;
    }

    fn slice(self: *const Path) []const []const u8 {
        return self.segments[0..self.len];
    }
};

fn restrictedCallDiagnostic(ctx: *LinterContext, callee: Node.Index, path: []const u8) Error {
    var e = ctx.diagnosticf(
        "Calls to `{s}` are not allowed.",
        .{path},
        .{ctx.labelN(callee, "this call path is restricted", .{})},
    );
    e.help = Cow.static("Remove this call, or drop the path from `no-restricted-calls` if it should be allowed.");
    return e;
}

pub fn runOnNode(self: *const NoRestrictedCalls, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.paths.len == 0) return;

    const ast = ctx.ast();
    const callee: Node.Index = switch (wrapper.node.tag) {
        .call, .call_comma => ast.nodeData(wrapper.idx).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(wrapper.idx).node_and_opt_node[0],
        else => return,
    };

    var path: Path = .{};
    if (!collectPath(ctx, callee, &path, MAX_SEGMENTS)) return;

    for (self.paths) |restricted| {
        if (matches(restricted, path.slice())) {
            ctx.report(restrictedCallDiagnostic(ctx, callee, restricted));
            return;
        }
    }
}

/// Split `pattern` on `.` and compare it segment for segment against `segments`.
///
/// Malformed patterns cannot match: an empty pattern, or one with an empty
/// segment such as `std..exit`, produces an empty segment, and no Zig
/// identifier is empty.
fn matches(pattern: []const u8, segments: []const []const u8) bool {
    var parts = std.mem.splitScalar(u8, pattern, '.');
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= segments.len) return false;
        if (!eql(u8, part, segments[i])) return false;
    }
    return i == segments.len;
}

/// Walk a callee expression, pushing one segment per identifier in source
/// order. `budget` bounds recursion; see `MAX_SEGMENTS`.
///
/// Returns `false` when the expression is not a dotted path of identifiers, in
/// which case `path` holds a partial result and must not be used.
fn collectPath(ctx: *LinterContext, node: Node.Index, path: *Path, budget: u8) bool {
    if (budget == 0) return false;
    const ast = ctx.ast();

    switch (ast.nodeTag(node)) {
        // `<object>.field`. The object comes first, so recurse before pushing.
        .field_access => {
            const object_and_field = ast.nodeData(node).node_and_token;
            if (!collectPath(ctx, object_and_field[0], path, budget - 1)) return false;
            return path.push(ctx.semantic.tokenSlice(object_and_field[1]));
        },
        .identifier => {
            // Follow `const` aliases so `exit(1)` and `std.process.exit(1)`
            // resolve to the same path. Declarations that aren't aliases (fn
            // decls, parameters, container fields) resolve to null, leaving the
            // identifier to stand for itself.
            if (ast_utils.resolveConstAlias(ctx, node)) |aliased| {
                return collectPath(ctx, aliased, path, budget - 1);
            }
            return path.push(ctx.semantic.tokenSlice(ast.nodeMainToken(node)));
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const module = importedModuleName(ctx, node) orelse return false;
            return path.push(module);
        },
        else => return false,
    }
}

/// The module name of an `@import("name")` call, or null when `node` is a
/// different builtin or imports a file path.
///
/// File imports are rejected because their name contains `.`, the same
/// separator that splits configured paths, so they could never be spelled
/// unambiguously in a config.
fn importedModuleName(ctx: *LinterContext, node: Node.Index) ?[]const u8 {
    const ast = ctx.ast();
    if (!eql(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(node)), "@import")) return null;

    const args = ast.nodeData(node).opt_node_and_opt_node;
    if (args[1] != .none) return null; // @import takes exactly one argument
    const arg = args[0].unwrap() orelse return null;
    if (ast.nodeTag(arg) != .string_literal) return null;

    const name = std.mem.trim(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(arg)), "\"");
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '.') != null) return null;
    return name;
}

pub fn rule(self: *NoRestrictedCalls) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoRestrictedCalls {
    const t = std.testing;

    var no_restricted_calls = NoRestrictedCalls{
        .paths = &[_][]const u8{
            "std.process.exit",
            "std.time.sleep",
            "exit",
            // a namespace, not a function. Restricts nothing below it.
            "std.debug",
            // malformed entries. None of these can match a real call path.
            "",
            "std..process.exit",
            ".std.process.exit",
            "std.process.exit.",
            // glob-looking entries are literal, not patterns
            "std.*",
            "std.process.*",
        },
    };
    var runner = RuleTester.init(t.allocator, no_restricted_calls.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // an unrestricted path that shares a prefix with a restricted one
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.process.cleanExit();
        \\}
        ,
        // a prefix of a restricted path is not itself restricted
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.process(1);
        \\}
        ,
        // referencing a restricted path without calling it
        \\const std = @import("std");
        \\const quit = std.process.exit;
        \\fn foo() void {
        \\  _ = quit;
        \\  _ = &std.process.exit;
        \\}
        ,
        // a local declaration shadows the restricted path
        \\const std = @import("std");
        \\fn foo() void {
        \\  const process = struct {
        \\    fn exit(code: u8) void { _ = code; }
        \\  };
        \\  process.exit(1);
        \\}
        ,
        // a parameter shadows a container-level alias, so the alias is not
        // followed and the path stays `process.exit`
        \\const std = @import("std");
        \\const process = std.process;
        \\fn foo(process: Process) void {
        \\  process.exit(1);
        \\}
        ,
        // a function that happens to share the last segment
        \\fn sleep(ms: u64) void { _ = ms; }
        \\fn foo() void {
        \\  sleep(1);
        \\}
        ,
        // method calls on values are not dotted paths
        \\fn foo(list: *List) !void {
        \\  try list.exit(1);
        \\}
        ,
        // neither are calls on the result of another call
        \\const std = @import("std");
        \\fn foo(gpa: *Gpa) void {
        \\  gpa.allocator().exit(1);
        \\}
        ,
        // `std.*` is literal: it restricts a function named `*`, not a wildcard.
        // `std.debug` is a restricted path, but it only matches in full, so
        // calls beneath it are untouched.
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.debug.assert(true);
        \\  std.process.abort();
        \\}
        ,
        // builtins are not covered by this rule
        \\fn foo() void {
        \\  @panic("nope");
        \\}
        ,
        // a file import does not resolve to a module name
        \\const helpers = @import("helpers.zig");
        \\fn foo() void {
        \\  helpers.exit(1);
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.process.exit(1);
        \\}
        ,
        // zero-argument calls are still calls
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.process.exit();
        \\}
        ,
        // multi-argument calls, with and without a trailing comma
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.time.sleep(1, 2);
        \\  std.time.sleep(
        \\    1,
        \\    2,
        \\  );
        \\}
        ,
        // aliased namespace
        \\const std = @import("std");
        \\const process = std.process;
        \\fn foo() void {
        \\  process.exit(1);
        \\}
        ,
        // aliased function
        \\const std = @import("std");
        \\const quit = std.process.exit;
        \\fn foo() void {
        \\  quit(1);
        \\}
        ,
        // alias of an alias
        \\const std = @import("std");
        \\const process = std.process;
        \\const quit = process.exit;
        \\fn foo() void {
        \\  quit(1);
        \\}
        ,
        // inline `@import`
        \\fn foo() void {
        \\  @import("std").process.exit(1);
        \\}
        ,
        // a bare identifier matches a single-segment path
        \\fn foo() void {
        \\  exit(1);
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}

test "malformed rule configuration is rejected while parsing" {
    const t = std.testing;
    const json = std.json;

    // `paths` is a list of strings, not a string or an object
    const wrong_type = [_][]const u8{
        \\{ "paths": "std.process.exit" }
        ,
        \\{ "paths": ["std.process.exit", 1] }
        ,
        \\{ "paths": { "0": "std.process.exit" } }
        ,
    };
    for (wrong_type) |source| {
        try t.expectError(error.UnexpectedToken, json.parseFromSlice(
            NoRestrictedCalls,
            t.allocator,
            source,
            .{},
        ));
    }

    // unknown options are typos, not extensions
    try t.expectError(error.UnknownField, json.parseFromSlice(
        NoRestrictedCalls,
        t.allocator,
        \\{ "path": ["std.process.exit"] }
    ,
        .{},
    ));
}

test "well-formed rule configuration parses" {
    const t = std.testing;
    const json = std.json;

    const parsed = try json.parseFromSlice(
        NoRestrictedCalls,
        t.allocator,
        \\{ "paths": ["std.process.exit", "std.time.sleep"] }
    ,
        .{},
    );
    defer parsed.deinit();

    try t.expectEqual(@as(usize, 2), parsed.value.paths.len);
    try t.expectEqualStrings("std.process.exit", parsed.value.paths[0]);
    try t.expectEqualStrings("std.time.sleep", parsed.value.paths[1]);

    const empty = try json.parseFromSlice(NoRestrictedCalls, t.allocator, "{}", .{});
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.value.paths.len);
}
