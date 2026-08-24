//! Checks that functions do not accept more than a configurable number of parameters.

const std = @import("std");
const zlint = @import("zlint");

const Ast = zlint.Semantic.Ast;
const LinterContext = zlint.linter.lint_context.Context;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const Rule = zlint.linter.rule.Rule;

const MaxParams = @This();

max: u32 = 4,

pub const meta: Rule.Meta = .{
    .name = "max-params",
    .category = .style,
    .default = .off,
};

pub fn runOnNode(self: *const MaxParams, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .fn_decl) return;

    const ast = ctx.ast();
    const fn_proto_node, _ = wrapper.node.data.node_and_node;
    var buffer: [1]Ast.Node.Index = undefined;
    const fn_proto = ast.fullFnProto(&buffer, fn_proto_node) orelse return;

    var count: u32 = 0;
    var params = fn_proto.iterate(ast);
    while (params.next() != null) count += 1;

    if (count <= self.max) return;

    ctx.report(ctx.diagnosticf(
        "function has {} parameters; maximum is {}.",
        .{ count, self.max },
        .{ctx.spanN(wrapper.idx)},
    ));
}

pub fn rule(self: *MaxParams) Rule {
    return Rule.init(self);
}

test "rule handles the zero and exact boundaries" {
    var rule_instance = MaxParams{ .max = 0 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn noParams() void {}
    };
    const fail = &[_][:0]const u8{
        \\fn oneParam(value: u32) void { _ = value; }
    };

    try tester.withPass(pass).withFail(fail).run();
}

test "rule reports functions over the limit" {
    var rule_instance = MaxParams{ .max = 2 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn okay(first: u32, second: u32) void {
        \\    _ = first + second;
        \\}
    };
    const fail = &[_][:0]const u8{
        \\fn tooMany(first: u32, second: u32, third: u32) void {
        \\    _ = first + second + third;
        \\}
    };

    try tester.withPass(pass).withFail(fail).run();
}
