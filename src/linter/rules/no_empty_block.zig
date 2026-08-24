//! ## What This Rule Does
//! Checks for blocks that contain no statements.
//!
//! An empty block runs no code. It is nearly always either debris left behind
//! when its contents were deleted or a branch someone meant to come back and
//! fill in. Either way the next reader has to stop and work out whether the
//! emptiness was deliberate.
//!
//! ### Blocks This Rule Ignores
//! Only blocks in statement position are reported: standalone blocks, branch
//! and loop bodies, `defer` and `errdefer` bodies, `comptime` blocks, and test
//! bodies. Everywhere else an empty pair of braces is the void value rather
//! than a block that runs no code, so it is left alone.
//!
//! ```zig
//! fn foo(fixes: []Fix) void {
//!     std.sort.insertion(Fix, fixes, {}, lessThan);
//! }
//! ```
//!
//! Two more positions require a block, and an empty one there is the normal
//! way to say "do nothing":
//!
//! - Function bodies. `fn noop() void {}` is a legitimate stub.
//! - Switch prongs. `else => {}` is the only way to give a prong no body.
//!
//! Swallowed errors such as `foo() catch {}` are reported by the
//! `suppressed-errors` rule instead, which knows when suppression is
//! acceptable.
//!
//! A block is also ignored when a comment sits between its braces. Use one to
//! record why the block is deliberately empty. A comment trailing the closing
//! brace does not count, since it reads as a note on the whole statement.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo(cond: bool) void {
//!     if (cond) {}
//!
//!     while (cond) {}
//!
//!     defer {}
//!
//!     {}
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn noop() void {}
//!
//! fn foo(tag: u8, queue: *Queue) void {
//!     switch (tag) {
//!         1 => noop(),
//!         else => {},
//!     }
//!
//!     while (queue.pop()) |_| {
//!         // drain whatever is left over
//!     }
//! }
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const NoEmptyBlock = @This();
pub const meta: Rule.Meta = .{
    .name = "no-empty-block",
    .category = .suspicious,
    .default = .off,
};

fn emptyBlockDiagnostic(ctx: *LinterContext, block: Node.Index) Error {
    var e = ctx.diagnostic(
        "This block is empty",
        .{ctx.labelN(block, "no code ever runs here", .{})},
    );
    e.help = Cow.static("Remove it, or leave a comment saying why it is empty on purpose.");
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const NoEmptyBlock, wrapper: NodeWrapper, ctx: *LinterContext) void {
    // `.block` and `.block_semicolon` are only ever constructed for blocks with
    // more than two statements, so they can never be empty.
    switch (wrapper.node.tag) {
        .block_two, .block_two_semicolon => {},
        else => return,
    }
    const first, const second = wrapper.node.data.opt_node_and_opt_node;
    if (first != .none or second != .none) return;

    if (!isStatement(ctx, wrapper.idx)) return;
    if (hasCommentBetweenBraces(ctx.ast(), wrapper.idx)) return;

    ctx.report(emptyBlockDiagnostic(ctx, wrapper.idx));
}

/// Does this block run as a statement, rather than evaluate to the void value?
///
/// Parents left out on purpose:
/// - `.fn_decl` and the `.switch_case*` tags, where the grammar demands a block
///   and an empty one means "do nothing".
/// - `.@"catch"`, which `suppressed-errors` reports on instead.
/// - Every expression, where `{}` is the void value: `return {}`,
///   `sort(T, items, {}, lessThan)`, `foo() orelse {}`.
fn isStatement(ctx: *const LinterContext, block: Node.Index) bool {
    const parent = ctx.links().getParent(block) orelse return false;
    return switch (ctx.ast().nodeTag(parent)) {
        // a block nested directly in another block
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        // a branch or loop body, or the `else` that follows one
        .@"if",
        .if_simple,
        .@"while",
        .while_simple,
        .while_cont,
        .@"for",
        .for_simple,
        // deferred work
        .@"defer",
        .@"errdefer",
        // `comptime {}` and `test {}`
        .@"comptime",
        .test_decl,
        => true,
        else => false,
    };
}

/// A comment is how this rule expects a deliberately empty block to be marked.
/// Comments are not in the AST, so read the source between the braces.
fn hasCommentBetweenBraces(ast: *const Ast, block: Node.Index) bool {
    const token_starts = ast.tokens.items(.start);
    const lbrace = ast.nodeMainToken(block);
    const rbrace = ast.lastToken(block);
    const between = ast.source[token_starts[lbrace] + 1 .. token_starts[rbrace]];
    return std.mem.indexOfNone(u8, between, &std.ascii.whitespace) != null;
}

// Used by the Linter to register the rule so it can be run.
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
        // an empty function is a legitimate stub
        \\fn noop() void {}
        ,
        // an empty prong is the only way to say "this case does nothing"
        \\fn foo(tag: u8) void {
        \\  switch (tag) {
        \\    1 => noop(),
        \\    else => {},
        \\  }
        \\}
        ,
        // multi-value and inline prongs go through different AST tags
        \\fn foo(tag: u8) void {
        \\  switch (tag) {
        \\    1, 2 => {},
        \\    inline 3 => {},
        \\    else => noop(),
        \\  }
        \\}
        ,
        // `suppressed-errors` owns this one
        \\fn foo() void {
        \\  bar() catch {};
        \\}
        ,
        // `{}` in expression position is the void value, not an empty body
        \\fn foo() void {
        \\  return {};
        \\}
        ,
        \\fn foo(items: []u8) void {
        \\  std.sort.insertion(u8, items, {}, lessThan);
        \\}
        ,
        \\fn foo(self: *Parser) void {
        \\  self.eat(',') orelse {};
        \\}
        ,
        \\const nothing: void = {};
        ,
        // a comment marks the block as deliberately empty
        \\fn foo(cond: bool) void {
        \\  if (cond) {
        \\    // nothing to undo yet
        \\  }
        \\}
        ,
        \\fn foo(items: []const u8) void {
        \\  for (items) |_| {
        \\    // drain whatever is left over
        \\  }
        \\}
        ,
        // blocks with statements
        \\fn foo(cond: bool) void {
        \\  if (cond) {
        \\    noop();
        \\  } else {
        \\    noop();
        \\    noop();
        \\  }
        \\}
        ,
        // containers and initializers are not blocks
        \\const Foo = struct {};
        \\const Empty = error{};
        \\const foo: Foo = .{};
        ,
    };

    const fail = &[_][:0]const u8{
        // a block statement that does nothing
        \\fn foo() void {
        \\  {}
        \\}
        ,
        \\fn foo() void {
        \\  blk: {}
        \\}
        ,
        // branches
        \\fn foo(cond: bool) void {
        \\  if (cond) {}
        \\}
        ,
        \\fn foo(cond: bool) void {
        \\  if (cond) {
        \\    noop();
        \\  } else {}
        \\}
        ,
        // loops
        \\fn foo(cond: bool) void {
        \\  while (cond) {}
        \\}
        ,
        // the comment has to sit between the braces to count
        \\fn foo(cond: bool) void {
        \\  while (cond) {} // spin
        \\}
        ,
        \\fn foo(items: []const u8) void {
        \\  for (items) |_| {}
        \\}
        ,
        // deferred work
        \\fn foo() void {
        \\  defer {}
        \\}
        ,
        \\fn foo() !void {
        \\  errdefer {}
        \\  return error.Foo;
        \\}
        ,
        \\comptime {}
        ,
        // a test that tests nothing
        \\test "does nothing" {}
        ,
        // the carve-outs cover the block itself, not blocks nested inside it
        \\fn foo(cond: bool) void {
        \\  if (cond) {
        \\    {}
        \\  }
        \\}
        ,
        \\fn foo(tag: u8, cond: bool) void {
        \\  switch (tag) {
        \\    else => {
        \\      if (cond) {}
        \\    },
        \\  }
        \\}
        ,
        \\fn foo(cond: bool) void {
        \\  bar() catch {
        \\    if (cond) {}
        \\  };
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
