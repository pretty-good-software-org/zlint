//! Checks that control-flow nesting stays below a configurable depth.

const std = @import("std");
const zlint = @import("zlint");

const Ast = zlint.Semantic.Ast;
const LinterContext = zlint.linter.lint_context.Context;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const Rule = zlint.linter.rule.Rule;

const MaxDepth = @This();

max: u32 = 4,

pub const meta: Rule.Meta = .{
    .name = "max-depth",
    .category = .style,
    .default = .off,
};

pub fn runOnNode(self: *const MaxDepth, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (!isDepthNode(wrapper.node.tag)) return;

    var depth: u32 = 0;
    var in_function = false;
    var parents = ctx.links().iterParentIds(wrapper.idx);
    while (parents.next()) |parent| {
        const tag = ctx.ast().nodeTag(parent);
        if (tag == .fn_decl) {
            in_function = true;
            break;
        }
        if (isDepthNode(tag)) depth += 1;
    }

    if (!in_function or depth <= self.max) return;

    ctx.report(ctx.diagnosticf(
        "control-flow nesting depth is {}; maximum is {}.",
        .{ depth, self.max },
        .{ctx.spanN(wrapper.idx)},
    ));
}

fn isDepthNode(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .for_range,
        .@"switch",
        .switch_comma,
        => true,
        else => false,
    };
}

pub fn rule(self: *MaxDepth) Rule {
    return Rule.init(self);
}

test "rule covers each supported nesting construct" {
    var rule_instance = MaxDepth{ .max = 0 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\const value = if (true) 1 else 2;
        \\fn independent() void {}
    };
    const fail = &[_][:0]const u8{
        \\fn nestedIf(value: bool) void { if (value) { while (value) break; } }
        \\fn nestedFor(value: bool) void { for ([_]u8{1}) |_| { if (value) {} } }
        \\fn nestedSwitch(value: u8) void { if (value > 0) { switch (value) { else => {} } } }
    };

    try tester.withPass(pass).withFail(fail).run();
}

test "rule reports control flow over the limit" {
    var rule_instance = MaxDepth{ .max = 2 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn okay(first: bool, second: bool) void {
        \\    if (first) {
        \\        if (second) return;
        \\    }
        \\}
        ,
        \\const value = if (true) 1 else 2;
    };
    const fail = &[_][:0]const u8{
        \\fn tooDeep(first: bool, second: bool, third: bool) void {
        \\    if (first) {
        \\        if (second) {
        \\            if (third) return;
        \\        }
        \\    }
        \\}
    };

    try tester.withPass(pass).withFail(fail).run();
}
