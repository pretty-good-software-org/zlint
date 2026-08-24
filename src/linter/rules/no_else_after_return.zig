//! ## What This Rule Does
//!
//! Disallows `else` branches attached to an `if` branch that never falls
//! through. When the `if` branch always `return`s, `break`s, `continue`s, or
//! otherwise stops running the enclosing block, the `else` body already only
//! runs when the condition was false. Keeping it indents the rest of the
//! function for nothing.
//!
//! A branch never falls through when it ends in `return`, `break`, `continue`,
//! `unreachable`, `@panic`, `@compileError`, or `@trap`, or when it is a block,
//! an `if`/`else`, or a `switch` whose every path does the same.
//!
//! ### Allowed scenarios
//!
//! This rule only fires on `if` statements whose value is discarded. It leaves
//! alone:
//!
//! - `if` expressions, where `else` supplies the value of the false branch.
//! - `else |err|` branches, which bind the error payload of an error union and
//!   cannot be un-indented without rewriting the `if` into a `catch`.
//! - `while`/`for` `else` clauses, which run when the loop finishes without
//!   `break` rather than when a condition is false.
//! - `else` bodies holding a top-level `defer` or `errdefer`, because
//!   un-indenting one delays it to the end of the enclosing block.
//!
//! Branches ending in a loop, a labeled block, or a labeled `switch` count as
//! falling through: `break :label` and `continue :label` resume inside the
//! enclosing block rather than leaving it.
//!
//! :::info
//! This rule reports but does not fix. Un-indenting an `else` that declares a
//! name also declared later in the enclosing block is a redeclaration error,
//! so keep the braces (or rename) in that case.
//! :::
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn abs(x: i32) i32 {
//!     if (x < 0) {
//!         return -x;
//!     } else {
//!         return x;
//!     }
//! }
//!
//! fn countNonZero(items: []const u8) usize {
//!     var n: usize = 0;
//!     for (items) |item| {
//!         if (item == 0) {
//!             continue;
//!         } else {
//!             n += 1;
//!         }
//!     }
//!     return n;
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn abs(x: i32) i32 {
//!     if (x < 0) return -x;
//!     return x;
//! }
//!
//! // `else` supplies the value of the false branch
//! fn sign(x: i32) i32 {
//!     return if (x < 0) -1 else 1;
//! }
//!
//! // `else |err|` binds the error payload
//! fn lenOrZero(path: []const u8) usize {
//!     if (statSize(path)) |size| {
//!         return size;
//!     } else |_| {
//!         return 0;
//!     }
//! }
//!
//! // the `if` branch falls through
//! fn bump(x: i32) i32 {
//!     var y = x;
//!     if (y < 0) {
//!         y = 0;
//!     } else {
//!         y += 1;
//!     }
//!     return y;
//! }
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

// Rule metadata
const NoElseAfterReturn = @This();
pub const meta: Rule.Meta = .{
    .name = "no-else-after-return",
    .category = .pedantic,
    .default = .off,
};

/// Builtins that never give control back to their caller. A call to one of
/// these ends a branch just like `return` does.
const noreturn_builtins = [_][]const u8{ "@panic", "@compileError", "@trap" };

fn noElseAfterReturnDiagnostic(ctx: *LinterContext, else_token: TokenIndex, exit_node: Node.Index) Error {
    var e = ctx.diagnostic(
        "This `else` follows a branch that never falls through",
        .{
            ctx.labelT(else_token, "this `else` is unnecessary", .{}),
            ctx.labelN(exit_node, "the `if` branch always exits here", .{}),
        },
    );
    e.help = Cow.static("Drop the `else` and un-indent its body.");
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const NoElseAfterReturn, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();
    // `.if_simple` has no `else`. `while`/`for` carry an `else` too, but it
    // runs on normal loop exit, which is not an `if`'s false branch.
    if (wrapper.node.tag != .@"if") return;

    const if_stmt = ast.fullIf(wrapper.idx) orelse return;
    const else_expr = if_stmt.ast.else_expr.unwrap() orelse return;

    if (if_stmt.error_token != null) return;
    if (!isStatementPosition(ctx, wrapper.idx)) return;
    if (hasTopLevelDefer(ast, else_expr)) return;

    const exit_node = exitStatement(ctx, if_stmt.ast.then_expr) orelse return;
    ctx.report(noElseAfterReturnDiagnostic(ctx, if_stmt.else_token, exit_node));
}

/// Find the statement that makes `node` transfer control out of the block
/// holding it, or `null` when control can reach the code after `node`.
fn exitStatement(ctx: *LinterContext, node: Node.Index) ?Node.Index {
    const ast = ctx.ast();

    switch (ast.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => return node,

        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            const name = ctx.semantic.tokenSlice(ast.nodeMainToken(node));
            for (noreturn_builtins) |builtin| {
                if (std.mem.eql(u8, name, builtin)) return node;
            }
            return null;
        },

        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            // A labeled block is left by `break :label`, which lands right
            // back in the enclosing block.
            if (isLabeledBlock(ast, ast.nodeMainToken(node))) return null;

            var buf: [2]Node.Index = undefined;
            const stmts = ast.blockStatements(&buf, node) orelse return null;
            if (stmts.len == 0) return null;
            return exitStatement(ctx, stmts[stmts.len - 1]);
        },

        // An `if` exits only when neither branch can fall through, so an
        // `if` without an `else` never qualifies.
        .@"if" => {
            const nested = ast.fullIf(node).?;
            const nested_else = nested.ast.else_expr.unwrap() orelse return null;
            if (exitStatement(ctx, nested.ast.then_expr) == null) return null;
            if (exitStatement(ctx, nested_else) == null) return null;
            return node;
        },

        // `switch` statements are exhaustive, so every prong exiting means the
        // `switch` exits.
        .@"switch", .switch_comma => {
            const switch_stmt = ast.fullSwitch(node).?;
            // On a labeled switch, `continue :label` re-dispatches and
            // `break :label` leaves only the switch.
            if (switch_stmt.label_token != null) return null;
            if (switch_stmt.ast.cases.len == 0) return null;

            for (switch_stmt.ast.cases) |case| {
                const prong = ast.fullSwitchCase(case) orelse return null;
                if (exitStatement(ctx, prong.ast.target_expr) == null) return null;
            }
            return node;
        },

        // Loops can finish normally, `defer` bodies run later, and every other
        // expression falls through to the next statement.
        else => return null,
    }
}

/// Report only on `if`s whose value is discarded. Everywhere else the `else`
/// supplies the value of the false branch and is mandatory.
fn isStatementPosition(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    const links = ctx.links();

    var current = node;
    while (links.getParent(current)) |parent| {
        switch (ast.nodeTag(parent)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => return true,

            // Branches inherit the position of the construct they belong to;
            // a condition is always an expression.
            .@"if", .if_simple => {
                const parent_if = ast.fullIf(parent).?;
                if (current != parent_if.ast.then_expr and
                    current.toOptional() != parent_if.ast.else_expr) return false;
                current = parent;
            },

            // A loop body's value is always discarded; only `break` yields one.
            .@"while", .while_simple, .while_cont => {
                const loop = ast.fullWhile(parent).?;
                if (current == loop.ast.then_expr) return true;
                if (current.toOptional() != loop.ast.else_expr) return false;
                current = parent;
            },
            .@"for", .for_simple => {
                const loop = ast.fullFor(parent).?;
                if (current == loop.ast.then_expr) return true;
                if (current.toOptional() != loop.ast.else_expr) return false;
                current = parent;
            },

            .switch_case, .switch_case_one, .switch_case_inline, .switch_case_inline_one => {
                current = parent;
            },
            .@"switch", .switch_comma => {
                const switch_stmt = ast.fullSwitch(parent).?;
                if (current == switch_stmt.ast.condition) return false;
                current = parent;
            },

            else => return false,
        }
    }

    return false;
}

/// Un-indenting a body moves its top-level `defer`s to the end of the
/// enclosing block, which changes when they run.
fn hasTopLevelDefer(ast: *const Ast, node: Node.Index) bool {
    if (isDefer(ast.nodeTag(node))) return true;

    var buf: [2]Node.Index = undefined;
    const stmts = ast.blockStatements(&buf, node) orelse return false;
    for (stmts) |stmt| {
        if (isDefer(ast.nodeTag(stmt))) return true;
    }
    return false;
}

fn isDefer(tag: Node.Tag) bool {
    return switch (tag) {
        .@"defer", .@"errdefer" => true,
        else => false,
    };
}

fn isLabeledBlock(ast: *const Ast, lbrace: TokenIndex) bool {
    return ast.isTokenPrecededByTags(lbrace, &.{ .identifier, .colon });
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *NoElseAfterReturn) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoElseAfterReturn {
    const t = std.testing;

    var no_else_after_return = NoElseAfterReturn{};
    var runner = RuleTester.init(t.allocator, no_else_after_return.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // no `else` to report on
        \\fn foo(c: bool) void {
        \\    if (c) return;
        \\    bar();
        \\}
        ,
        // the `if` branch falls through
        \\fn foo(c: bool) i32 {
        \\    var x: i32 = 0;
        \\    if (c) {
        \\        x = 1;
        \\    } else {
        \\        x = 2;
        \\    }
        \\    return x;
        \\}
        ,
        // `else` supplies the value of an expression
        \\fn foo(c: bool) i32 {
        \\    const x = if (c) 1 else 2;
        \\    return x;
        \\}
        ,
        \\fn foo(c: bool) i32 {
        \\    return if (c) 1 else 2;
        \\}
        ,
        // a `return` in one arm still does not make the `if` a statement
        \\fn foo(c: bool) i32 {
        \\    const x: i32 = if (c) return 0 else 2;
        \\    return x;
        \\}
        ,
        // `else |err|` binds the error payload
        \\fn foo() u32 {
        \\    if (bar()) |x| {
        \\        return x;
        \\    } else |_| {
        \\        return 0;
        \\    }
        \\}
        ,
        // a loop `else` runs when the loop ends without `break`
        \\fn foo(items: []const u8) u8 {
        \\    for (items) |item| {
        \\        return item;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        ,
        \\fn foo(it: *Iter) u8 {
        \\    while (it.next()) |item| {
        \\        return item;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        ,
        // `break :blk` lands back in the enclosing block
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        blk: {
        \\            break :blk;
        \\        }
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // the `if` branch itself is a labeled block
        \\fn foo(c: bool) void {
        \\    if (c) blk: {
        \\        break :blk;
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // `continue :sw` re-dispatches instead of leaving the switch
        \\fn foo(c: bool, x: u8) void {
        \\    if (c) {
        \\        sw: switch (x) {
        \\            0 => continue :sw 1,
        \\            else => break :sw,
        \\        }
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // one prong falls through
        \\fn foo(c: bool, x: u8) void {
        \\    if (c) {
        \\        switch (x) {
        \\            0 => return,
        \\            else => bar(),
        \\        }
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // the nested `if` has no `else`, so it can fall through
        \\fn foo(c: bool, d: bool) void {
        \\    if (c) {
        \\        if (d) return;
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // a loop can finish normally
        \\fn foo(c: bool, items: []const u8) void {
        \\    if (c) {
        \\        for (items) |item| {
        \\            bar(item);
        \\        }
        \\    } else {
        \\        bar(0);
        \\    }
        \\}
        ,
        // un-indenting would delay the `defer`
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        return;
        \\    } else {
        \\        defer bar();
        \\        baz();
        \\    }
        \\    qux();
        \\}
        ,
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        return;
        \\    } else {
        \\        errdefer bar();
        \\        baz();
        \\    }
        \\    qux();
        \\}
        ,
        // the earlier arm of the chain falls through
        \\fn foo(a: bool, b: bool) void {
        \\    if (a) {
        \\        bar();
        \\    } else if (b) {
        \\        baz();
        \\    } else {
        \\        qux();
        \\    }
        \\}
        ,
        // an empty `if` branch falls through
        \\fn foo(c: bool) void {
        \\    if (c) {} else {
        \\        bar();
        \\    }
        \\}
        ,
        // a `catch` only returns on the error path
        \\fn foo(c: bool) !void {
        \\    if (c) {
        \\        bar() catch return;
        \\    } else {
        \\        baz();
        \\    }
        \\}
        ,

        // == boundaries ==

        // both branches empty
        \\fn foo(c: bool) void {
        \\    if (c) {} else {}
        \\}
        ,
        // an empty nested block exits nothing
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        {}
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // a switch with no prongs
        \\fn foo(c: bool, x: Never) void {
        \\    if (c) {
        \\        switch (x) {}
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // only some paths out of the labeled block return
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        blk: {
        \\            if (c) break :blk;
        \\            return;
        \\        }
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // `while (true)` is treated as able to finish
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        while (true) {
        \\            bar();
        \\        }
        \\    } else {
        \\        baz();
        \\    }
        \\}
        ,
        // the exit is not the last statement, so the branch still reaches the end
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        if (c) return;
        \\        bar();
        \\    } else {
        \\        baz();
        \\    }
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        \\fn foo(c: bool) i32 {
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        ,
        // no braces around either branch
        \\fn foo(c: bool) void {
        \\    if (c) return else bar();
        \\}
        ,
        // `break` leaves the loop
        \\fn foo(items: []const u8) void {
        \\    for (items) |item| {
        \\        if (item == 0) {
        \\            break;
        \\        } else {
        \\            bar(item);
        \\        }
        \\    }
        \\}
        ,
        // `continue` leaves the iteration
        \\fn foo(items: []const u8) void {
        \\    for (items) |item| {
        \\        if (item == 0) {
        \\            continue;
        \\        } else {
        \\            bar(item);
        \\        }
        \\    }
        \\}
        ,
        // `break :outer` leaves an enclosing labeled block
        \\fn foo(c: bool) void {
        \\    outer: {
        \\        if (c) {
        \\            break :outer;
        \\        } else {
        \\            bar();
        \\        }
        \\        baz();
        \\    }
        \\}
        ,
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        unreachable;
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        @panic("nope");
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // both arms of the nested `if` exit
        \\fn foo(c: bool, d: bool) i32 {
        \\    if (c) {
        \\        if (d) {
        \\            return 1;
        \\        } else {
        \\            return 2;
        \\        }
        \\    } else {
        \\        return 3;
        \\    }
        \\}
        ,
        // every prong of the switch exits
        \\fn foo(c: bool, x: u8) i32 {
        \\    if (c) {
        \\        switch (x) {
        \\            0 => return 1,
        \\            else => return 2,
        \\        }
        \\    } else {
        \\        return 3;
        \\    }
        \\}
        ,
        // the whole chain exits, so both `else`s are unnecessary
        \\fn foo(a: bool, b: bool) i32 {
        \\    if (a) {
        \\        return 1;
        \\    } else if (b) {
        \\        return 2;
        \\    } else {
        \\        return 3;
        \\    }
        \\}
        ,
        // an optional payload on the `if`, but a plain `else`
        \\fn foo(opt: ?u32) u32 {
        \\    if (opt) |x| {
        \\        return x;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        ,
        // the `else` body is a labeled block
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        return;
        \\    } else blk: {
        \\        break :blk;
        \\    }
        \\}
        ,
        // a `defer` nested below the top level of the `else` still reports
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        return;
        \\    } else {
        \\        {
        \\            defer bar();
        \\            baz();
        \\        }
        \\    }
        \\}
        ,
        // inside a loop body that is not wrapped in a block
        \\fn foo(c: bool, items: []const u8) void {
        \\    for (items) |_| if (c) return else bar();
        \\}
        ,
        // inside a switch prong
        \\fn foo(c: bool, x: u8) void {
        \\    switch (x) {
        \\        0 => if (c) {
        \\            return;
        \\        } else {
        \\            bar();
        \\        },
        \\        else => {},
        \\    }
        \\}
        ,

        // == boundaries ==

        // an empty `else`
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        return;
        \\    } else {}
        \\}
        ,
        // exactly two statements in the branch
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        bar();
        \\        return;
        \\    } else {
        \\        baz();
        \\    }
        \\}
        ,
        // more statements than a `block_two` can hold
        \\fn foo(c: bool) i32 {
        \\    if (c) {
        \\        bar();
        \\        baz();
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        ,
        // the exit sits inside an unlabeled nested block
        \\fn foo(c: bool) void {
        \\    if (c) {
        \\        {
        \\            return;
        \\        }
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
        // a switch with a single prong
        \\fn foo(c: bool, x: u8) void {
        \\    if (c) {
        \\        switch (x) {
        \\            else => return,
        \\        }
        \\    } else {
        \\        bar();
        \\    }
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
