//! ## What This Rule Does
//! Checks for empty blocks (`{}`) attached to constructs that do nothing
//! without a body.
//!
//! An empty `if` branch, loop body, or `defer` is either an unfinished edit or
//! a roundabout way of saying something the code could say directly. Deleting
//! the construct, or inverting the condition that guards it, leaves less for
//! the next reader to puzzle over.
//!
//! A block is empty when it holds no statements *and* no comments. The
//! following constructs are checked:
//!
//! - `if` and `else` branches
//! - `while` and `for` bodies, and their `else` branches
//! - `defer` and `errdefer` bodies
//! - `test` bodies
//!
//! ### Allowed Scenarios
//! Zig leans on empty blocks in places where they carry meaning, so this rule
//! leaves them alone:
//!
//! - **Function bodies.** A no-op body is how a function satisfies a callback
//!   or interface signature, as in `fn deinit(_: *Self) void {}`.
//! - **`switch` prongs.** Exhaustive switches need a prong per case, and
//!   `=> {}` is the idiomatic way to spell "nothing to do here".
//! - **`catch` blocks and `else |err| {}`.** Both swallow an error, which is
//!   `suppressed-errors`' call to make rather than this rule's.
//! - **`while` loops with a continue expression.** In
//!   `while (c) : (i += 1) {}` the per-iteration work lives in the continue
//!   expression, so the loop does something without a body.
//! - **Branches producing a value.** When the other branch holds a bare
//!   expression, as in `const h = if (store_hash) hashKey(key) else {};`, the
//!   `{}` is the `void` value and cannot be removed.
//! - **Blocks containing a comment.** A comment records why the block is
//!   empty, which is exactly the intent this rule asks for. Use one to keep a
//!   deliberate no-op, such as a loop that exists only to drain an iterator.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo(x: bool, items: []const u8) void {
//!     if (x) {}
//!     while (x) {}
//!     for (items) |_| {}
//!     defer {}
//! }
//!
//! test "not written yet" {}
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // a no-op body satisfies the callback signature
//! fn onEvent(_: u32) void {}
//!
//! fn foo(x: u8, it: *Iterator) void {
//!     switch (x) {
//!         // an explicit no-op prong keeps the switch exhaustive
//!         0 => {},
//!         else => bar(),
//!     }
//!     while (it.next()) |_| {
//!         // drain the iterator; the values are not needed
//!     }
//! }
//! ```

const std = @import("std");
const ast_utils = @import("../ast_utils.zig");
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;

const Error = @import("../../Error.zig");

const NoEmptyBlock = @This();
pub const meta: Rule.Meta = .{
    .name = "no-empty-block",
    .category = .suspicious,
    .default = .off,
};

/// The construct owning a reported block. Diagnostics name the construct
/// rather than the block so the message says what to delete.
const Construct = enum {
    if_then,
    if_else,
    while_body,
    while_else,
    for_body,
    for_else,
    defer_body,
    errdefer_body,
    test_body,

    fn message(comptime self: Construct) []const u8 {
        return switch (self) {
            .if_then => "This `if` branch is empty.",
            .if_else => "This `else` branch is empty.",
            .while_body => "This `while` loop has an empty body.",
            .while_else => "This `while` loop has an empty `else` branch.",
            .for_body => "This `for` loop has an empty body.",
            .for_else => "This `for` loop has an empty `else` branch.",
            .defer_body => "This `defer` runs an empty block.",
            .errdefer_body => "This `errdefer` runs an empty block.",
            .test_body => "This test has an empty body.",
        };
    }

    fn help(comptime self: Construct) []const u8 {
        return switch (self) {
            .if_then => "Invert the condition and keep only the `else` branch, " ++
                "or leave a comment saying why nothing happens here.",
            .if_else, .while_else, .for_else => "Remove the `else` branch, " ++
                "or leave a comment saying why nothing happens here.",
            .while_body, .for_body => "Remove the loop, or leave a comment " ++
                "saying why it runs for its side effects alone.",
            .defer_body => "Remove the `defer`; it does nothing on scope exit.",
            .errdefer_body => "Remove the `errdefer`; it does nothing when an error is returned.",
            .test_body => "Assert something, or remove the test.",
        };
    }
};

fn emptyBlockDiagnostic(ctx: *LinterContext, block: Node.Index, comptime construct: Construct) Error {
    var d = ctx.diagnostic(
        construct.message(),
        .{ctx.labelN(block, "this block is empty", .{})},
    );
    d.help = .static(construct.help());
    return d;
}

/// Report `body` when it is an empty block. Nodes that are not blocks — a
/// `defer bar();`, an `else if`, a single-expression loop body — are left
/// alone.
fn checkBody(ctx: *LinterContext, body: Node.Index, comptime construct: Construct) void {
    if (!isEmptyBlock(ctx, body)) return;
    ctx.report(emptyBlockDiagnostic(ctx, body, construct));
}

/// Report a branch of an `if`/`while`/`for`, unless its sibling branch holds a
/// bare expression. A sibling expression means the construct is producing a
/// value, so `{}` is the `void` value rather than an empty body:
///
/// ```zig
/// const hash = if (store_hash) hashKey(key) else {};
/// ```
///
/// Removing that `else`, as the diagnostic would advise, does not compile.
fn checkBranch(
    ctx: *LinterContext,
    branch: Node.Index,
    sibling: Node.OptionalIndex,
    comptime construct: Construct,
) void {
    if (sibling.unwrap()) |other| {
        if (!ast_utils.isBlock(ctx.ast(), other)) return;
    }
    checkBody(ctx, branch, construct);
}

fn isEmptyBlock(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();

    var buf: [2]Node.Index = undefined;
    const statements = ast.blockStatements(&buf, node) orelse return false;
    if (statements.len > 0) return false;

    return !hasComment(ctx, node);
}

/// A block with no statements can only hold whitespace and comments between
/// its braces, so any other byte there is part of a comment. Comments are how
/// authors record that an empty block is deliberate, so a block holding one is
/// not reported.
fn hasComment(ctx: *LinterContext, block: Node.Index) bool {
    const ast = ctx.ast();
    const tok_tags = ast.tokens.items(.tag);

    const lbrace = ast.nodeMainToken(block);
    const rbrace = ast.lastToken(block);
    std.debug.assert(tok_tags[lbrace] == .l_brace);
    std.debug.assert(tok_tags[rbrace] == .r_brace);

    const start = ctx.semantic.tokenSpan(lbrace).end;
    const end = ctx.semantic.tokenSpan(rbrace).start;
    std.debug.assert(start <= end);

    const between = ctx.source.text()[start..end];
    return std.mem.indexOfNone(u8, between, &std.ascii.whitespace) != null;
}

pub fn runOnNode(_: *const NoEmptyBlock, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();

    // Checking each construct from the top down means function bodies and
    // `switch` prongs are never visited, so their empty blocks cannot be
    // reported by accident.
    switch (wrapper.node.tag) {
        .if_simple, .@"if" => {
            const if_node = ast.fullIf(wrapper.idx) orelse return;
            const then_expr = if_node.ast.then_expr;
            checkBranch(ctx, then_expr, if_node.ast.else_expr, .if_then);
            // `else |err| {}` swallows an error; that is `suppressed-errors`'
            // call to make, not this rule's.
            if (if_node.error_token == null) {
                if (if_node.ast.else_expr.unwrap()) |else_expr| {
                    checkBranch(ctx, else_expr, then_expr.toOptional(), .if_else);
                }
            }
        },
        .while_simple, .while_cont, .@"while" => {
            const while_node = ast.fullWhile(wrapper.idx) orelse return;
            const then_expr = while_node.ast.then_expr;
            // A continue expression, as in `while (c) : (i += 1) {}`, is the
            // loop's per-iteration work. Such a loop does something without a
            // body, so an empty one is deliberate.
            if (while_node.ast.cont_expr == .none) {
                checkBranch(ctx, then_expr, while_node.ast.else_expr, .while_body);
            }
            if (while_node.error_token == null) {
                if (while_node.ast.else_expr.unwrap()) |else_expr| {
                    checkBranch(ctx, else_expr, then_expr.toOptional(), .while_else);
                }
            }
        },
        .for_simple, .@"for" => {
            const for_node = ast.fullFor(wrapper.idx) orelse return;
            const then_expr = for_node.ast.then_expr;
            checkBranch(ctx, then_expr, for_node.ast.else_expr, .for_body);
            if (for_node.ast.else_expr.unwrap()) |else_expr| {
                checkBranch(ctx, else_expr, then_expr.toOptional(), .for_else);
            }
        },
        // `.@"defer"` stores the deferred expression directly; `.@"errdefer"`
        // and `.test_decl` store an optional token (the payload, the test
        // name) alongside it.
        .@"defer" => checkBody(ctx, ast.nodeData(wrapper.idx).node, .defer_body),
        .@"errdefer" => checkBody(ctx, ast.nodeData(wrapper.idx).opt_token_and_node[1], .errdefer_body),
        .test_decl => checkBody(ctx, ast.nodeData(wrapper.idx).opt_token_and_node[1], .test_body),
        else => return,
    }
}

pub fn rule(self: *NoEmptyBlock) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoEmptyBlock {
    const t = std.testing;

    var no_empty_block = NoEmptyBlock{};
    var runner = RuleTester.init(t.allocator, no_empty_block.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // empty function bodies satisfy a signature; they are not reported
        \\fn onEvent(_: u32) void {}
        \\fn deinit(_: *u32) void {
        \\}
        ,
        // an explicit no-op prong keeps a switch exhaustive
        \\fn handle(x: u8) void {
        \\  switch (x) {
        \\    0 => {},
        \\    1 => {
        \\    },
        \\    else => noop(),
        \\  }
        \\}
        \\fn noop() void {}
        ,
        // `catch {}` belongs to the `suppressed-errors` rule
        \\fn mayFail() !void {}
        \\fn foo() void {
        \\  mayFail() catch {};
        \\}
        ,
        // a comment documents a deliberate no-op
        \\fn foo(x: bool) void {
        \\  if (x) {
        \\    // nothing to do when x is set
        \\  } else {
        \\    // nor when it is not
        \\  }
        \\}
        ,
        \\fn drain(it: anytype) void {
        \\  while (it.next()) |_| {
        \\    // discard the remaining items
        \\  }
        \\}
        ,
        \\fn foo(items: []const u8) void {
        \\  for (items) |_| {
        \\    // walking the slice is enough
        \\  }
        \\}
        ,
        \\fn foo() void {
        \\  defer {
        \\    // ownership moved to the caller
        \\  }
        \\  errdefer {
        \\    // the caller reports this
        \\  }
        \\}
        ,
        \\test "placeholder" {
        \\  // waiting on the parser rewrite
        \\}
        ,
        // bodies with statements
        \\fn foo(x: bool, items: []const u8) void {
        \\  if (x) {
        \\    bar();
        \\  } else {
        \\    bar();
        \\  }
        \\  while (x) {
        \\    bar();
        \\  }
        \\  for (items) |_| {
        \\    bar();
        \\  }
        \\  defer {
        \\    bar();
        \\  }
        \\  errdefer bar();
        \\}
        \\fn bar() void {}
        ,
        // `else` branches that carry statements, plus a non-empty test
        \\fn find(items: []const u8) bool {
        \\  for (items) |item| {
        \\    if (item == 0) break;
        \\  } else {
        \\    return false;
        \\  }
        \\  return true;
        \\}
        \\test find {
        \\  _ = find(&.{});
        \\}
        ,
        // `else |err| {}` swallows an error; `suppressed-errors` owns that call
        \\fn parse(s: []const u8) !u32 {
        \\  _ = s;
        \\  return 0;
        \\}
        \\fn foo(s: []const u8) void {
        \\  if (parse(s)) |n| {
        \\    use(n);
        \\  } else |_| {}
        \\}
        \\fn use(_: u32) void {}
        ,
        // `{}` is the `void` value when the other branch is an expression
        \\fn hash(store_hash: bool, key: u32) void {
        \\  const h = if (store_hash) checkedHash(key) else {};
        \\  _ = h;
        \\}
        \\fn checkedHash(_: u32) void {}
        ,
        \\fn foo(store_hash: bool, ctx: u32) void {
        \\  insert(if (store_hash) {} else ctx);
        \\}
        \\fn insert(_: anytype) void {}
        ,
        // the continue expression does the loop's work
        \\fn skipWhitespace(src: []const u8, start: usize) usize {
        \\  var i = start;
        \\  while (i < src.len and src[i] == ' ') : (i += 1) {}
        \\  return i;
        \\}
        ,
        // an `else if` chain is not an empty block
        \\fn classify(x: u8) u8 {
        \\  if (x == 0) {
        \\    return 1;
        \\  } else if (x == 1) {
        \\    return 2;
        \\  }
        \\  return 0;
        \\}
    };

    const fail = &[_][:0]const u8{
        // if / else
        \\fn foo(x: bool) void {
        \\  if (x) {}
        \\}
        ,
        \\fn foo(x: bool) void {
        \\  if (x) {
        \\    bar();
        \\  } else {}
        \\}
        \\fn bar() void {}
        ,
        // while body and while-else
        \\fn foo(x: bool) void {
        \\  while (x) {}
        \\}
        ,
        \\fn foo(x: bool) void {
        \\  while (x) {
        \\    break;
        \\  } else {}
        \\}
        ,
        // a continue expression excuses the body, not the `else` branch
        \\fn foo(n: usize) void {
        \\  var i: usize = 0;
        \\  while (i < n) : (i += 1) {
        \\    break;
        \\  } else {}
        \\}
        ,
        // for body and for-else
        \\fn foo(items: []const u8) void {
        \\  for (items) |_| {}
        \\}
        ,
        \\fn foo(items: []const u8) void {
        \\  for (items) |_| {
        \\    break;
        \\  } else {}
        \\}
        ,
        // defer / errdefer, with and without a payload
        \\fn foo() void {
        \\  defer {}
        \\}
        ,
        \\fn foo() !void {
        \\  errdefer {}
        \\}
        ,
        \\fn foo() !void {
        \\  errdefer |e| {}
        \\}
        ,
        // test bodies, named and unnamed
        \\test {}
        ,
        \\test "not written yet" {}
        ,
        \\fn foo() void {}
        \\test foo {}
        ,
        // the `switch` carve-out covers the prong body, not what nests inside it
        \\fn foo(x: u8, y: bool) void {
        \\  switch (x) {
        \\    0 => if (y) {},
        \\    else => {},
        \\  }
        \\}
        ,
        // a blank line is still an empty block
        \\fn foo(x: bool) void {
        \\  if (x) {
        \\
        \\  }
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
