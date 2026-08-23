//! Checks that functions stay below a configurable cyclomatic complexity.

const std = @import("std");
const zlint = @import("zlint");

const Ast = zlint.Semantic.Ast;
const LinterContext = zlint.linter.lint_context.Context;
const Rule = zlint.linter.rule.Rule;

const Complexity = @This();

max: u32 = 15,

pub const meta: Rule.Meta = .{
    .name = "complexity",
    .category = .style,
    .default = .off,
};

pub fn runOnce(self: *const Complexity, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const nodes = ctx.semantic.nodes();
    const counts = ctx.gpa.alloc(u32, nodes.len) catch @panic("OOM");
    defer ctx.gpa.free(counts);
    @memset(counts, 0);

    for (0..nodes.len) |i| {
        const node_id: Ast.Node.Index = @enumFromInt(i);
        const increment = complexityIncrement(ast.nodeTag(node_id));
        if (increment == 0) continue;

        var parents = ctx.links().iterParentIds(node_id);
        while (parents.next()) |parent| {
            if (ast.nodeTag(parent) != .fn_decl) continue;
            counts[@intFromEnum(parent)] += increment;
            break;
        }
    }

    for (0..nodes.len) |i| {
        const node_id: Ast.Node.Index = @enumFromInt(i);
        if (ast.nodeTag(node_id) != .fn_decl) continue;

        const complexity = counts[i] + 1;
        if (complexity <= self.max) continue;

        ctx.report(ctx.diagnosticf(
            "function has complexity {}; maximum is {}.",
            .{ complexity, self.max },
            .{ctx.spanN(node_id)},
        ));
    }
}

fn complexityIncrement(tag: Ast.Node.Tag) u32 {
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
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        .@"catch",
        .bool_and,
        .bool_or,
        => 1,
        else => 0,
    };
}

pub fn rule(self: *Complexity) Rule {
    return Rule.init(self);
}

test "rule reports functions over the limit" {
    var rule_instance = Complexity{ .max = 3 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn okay(first: bool, second: bool) void {
        \\    if (first and second) return;
        \\}
    };
    const fail = &[_][:0]const u8{
        \\fn tooComplex(first: bool, second: bool, third: bool) void {
        \\    if (first) {
        \\        if (second) {
        \\            if (third) return;
        \\        }
        \\    }
        \\}
    };

    try tester.withPass(pass).withFail(fail).run();
}
