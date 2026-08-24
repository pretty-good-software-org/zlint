//! ## What This Rule Does
//!
//! Disallows container-level `var` declarations that are reachable from outside
//! the file declaring them, either because they are `pub` or because they are
//! `export`ed.
//!
//! Container-level variables have static lifetime: exactly one of them exists
//! for the entire program. Publishing one lets every importer read and write it
//! at any point, so its value depends on which code ran first, no caller can
//! rely on it, and concurrent access is a data race unless every writer agrees
//! on a synchronization scheme that the type itself does not enforce.
//!
//! ### What Counts As A Violation
//!
//! A declaration is reported when both of these hold:
//!
//! 1. It is declared with `var`, not `const`.
//! 2. It is marked `pub`, or it is `export`ed. `export` publishes a linker
//!    symbol that other objects can bind to, so it exposes the variable even
//!    without `pub`.
//!
//! Zig only accepts `pub`, `export`, and `threadlocal` on container-level
//! declarations; inside a function body they are parse errors. Every reported
//! declaration is therefore a global, wherever its container is written:
//! at the top level of a file, inside a nested `struct`/`enum`/`union`, or
//! inside a container declared in a function body.
//!
//! `pub threadlocal var` is reported as well. One instance per thread is still
//! process-wide state that any importer can write, and its value depends on
//! which thread happens to be running.
//!
//! ### Allowed Scenarios
//!
//! These are not reported:
//!
//! - Container-level `var`s that stay private to their file. They are still
//!   global state, but this rule is about exposing it.
//! - `pub const`, including `pub const` container types and their fields.
//!   Fields are per-instance state, not globals.
//! - Locals. A `var` inside a function or a `test` block is not global state.
//! - `pub extern var`. The variable is defined by another translation unit
//!   (usually C), so this file cannot make it `const`.
//!
//! :::warning
//! ZLint does not have a type checker, so a `pub const` bound to mutable memory
//! (e.g. `pub const instance = &global_state;`) is not reported even though it
//! also hands out mutable global state.
//! :::
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! pub var counter: u32 = 0;
//!
//! // `export` exposes the symbol to the linker, with or without `pub`.
//! export var shared_flag: bool = false;
//!
//! // Nested containers are globals too.
//! pub const Registry = struct {
//!     pub var instances: u32 = 0;
//! };
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! pub const max_connections: u32 = 100;
//!
//! // Keep the state private and let callers go through functions that can
//! // enforce invariants.
//! var counter: u32 = 0;
//! pub fn increment() void {
//!     counter += 1;
//! }
//! pub fn count() u32 {
//!     return counter;
//! }
//!
//! // Defined by another translation unit, so this file cannot make it `const`.
//! pub extern var environ: [*]?[*:0]u8;
//! ```

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");

const Symbol = Semantic.Symbol;
const TokenIndex = Semantic.Ast.TokenIndex;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

const NoPublicMutableGlobal = @This();
pub const meta: Rule.Meta = .{
    .name = "no-public-mutable-global",
    .category = .restriction,
    .default = .warning,
};

fn publicMutableGlobalDiagnostic(ctx: *LinterContext, name: []const u8, token: TokenIndex) Error {
    var e = ctx.diagnosticf(
        "global variable '{s}' is mutable and visible outside this file.",
        .{name},
        .{ctx.spanT(token)},
    );
    e.help = Cow.static("Make it `const`, or keep it private and expose it through functions.");
    return e;
}

pub fn runOnSymbol(_: *const NoPublicMutableGlobal, symbol: Symbol.Id, ctx: *LinterContext) void {
    const s = symbol.into(usize);
    const symbols = ctx.symbols().symbols.slice();
    const flags: Symbol.Flags = symbols.items(.flags)[s];

    // Only `var` declarations. Constants, container fields, functions, and
    // bound payloads are all out of scope.
    if (!flags.s_variable or flags.s_const) return;

    // `extern var` names a variable owned by another translation unit. Nothing
    // in this file can make it immutable.
    if (flags.s_extern) return;

    // `pub` and `export` are parse errors inside a function body, so either one
    // means this is a container-level variable, i.e. a global.
    const is_visible_outside_file = symbols.items(.visibility)[s] == .public or flags.s_export;
    if (!is_visible_outside_file) return;

    const identifier = symbols.items(.token)[s].unwrap() orelse return;
    ctx.report(publicMutableGlobalDiagnostic(ctx, symbols.items(.name)[s], identifier.int()));
}

pub fn rule(self: *NoPublicMutableGlobal) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoPublicMutableGlobal {
    const t = std.testing;

    var no_public_mutable_global = NoPublicMutableGlobal{};
    var runner = RuleTester.init(t.allocator, no_public_mutable_global.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // public constants are not mutable state
        "pub const max_connections: u32 = 100;",
        "pub const version = \"1.0.0\";",
        // container-level `var`s that stay private
        "var counter: u32 = 0;",
        "threadlocal var scratch: [64]u8 = undefined;",
        \\var counter: u32 = 0;
        \\pub fn increment() void {
        \\    counter += 1;
        \\}
        ,
        // private vars in nested containers
        \\pub const Registry = struct {
        \\    var instances: u32 = 0;
        \\};
        ,
        \\const Outer = struct {
        \\    const Inner = struct {
        \\        var flag: bool = false;
        \\    };
        \\};
        ,
        // container fields are per-instance state, not globals
        \\pub const Config = struct {
        \\    retries: u32 = 3,
        \\};
        ,
        \\pub const Tagged = union(enum) {
        \\    count: u32,
        \\    name: []const u8,
        \\};
        ,
        // locals, including those in public functions
        \\pub fn tally(items: []const u32) u32 {
        \\    var total: u32 = 0;
        \\    for (items) |item| total += item;
        \\    return total;
        \\}
        ,
        \\pub fn Counter(comptime T: type) type {
        \\    return struct {
        \\        count: T,
        \\    };
        \\}
        ,
        \\test "counts up" {
        \\    var seen: u32 = 0;
        \\    seen += 1;
        \\}
        ,
        // `extern var` is defined by another translation unit
        "pub extern var environ: [*]?[*:0]u8;",
        // `pub const` pointing at mutable memory is not reported; ZLint has no
        // type checker.
        \\var state: u32 = 0;
        \\pub const state_ptr = &state;
    };

    const fail = &[_][:0]const u8{
        "pub var counter: u32 = 0;",
        "pub var counter = 0;",
        "pub var buf: [4]u8 = undefined;",
        // `export` exposes the symbol even without `pub`
        "export var shared_flag: bool = false;",
        "pub export var shared_flag: bool = false;",
        // per-thread state is still shared, writable state
        "pub threadlocal var request_id: u64 = 0;",
        // nested containers hold globals too
        \\pub const Registry = struct {
        \\    pub var instances: u32 = 0;
        \\};
        ,
        \\const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub var flag: bool = false;
        \\    };
        \\};
        ,
        \\const Stats = struct {
        \\    export var hits: u32 = 0;
        \\};
        ,
        \\pub const Handle = enum(u8) {
        \\    none,
        \\    some,
        \\
        \\    pub var last: u8 = 0;
        \\};
        ,
        // a container declared inside a function still declares globals
        \\pub fn counters() type {
        \\    return struct {
        \\        pub var hits: u32 = 0;
        \\    };
        \\}
        ,
        // aligned, sectioned, and addrspace-qualified declarations
        "pub var aligned_counter: u32 align(16) = 0;",
        \\pub var counter: u32 = 0;
        \\pub var gauge: u32 = 0;
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
