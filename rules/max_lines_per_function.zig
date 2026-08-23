//! Checks that functions stay below a configurable physical line count.

const std = @import("std");
const zlint = @import("zlint");

const LinterContext = zlint.linter.lint_context.Context;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const Rule = zlint.linter.rule.Rule;

const MaxLinesPerFunction = @This();

max: u32 = 60,
skip_blank_lines: bool = true,
skip_comments: bool = true,

pub const meta: Rule.Meta = .{
    .name = "max-lines-per-function",
    .category = .style,
    .default = .off,
};

pub fn runOnNode(self: *const MaxLinesPerFunction, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .fn_decl) return;

    const span = ctx.semantic.nodeSpan(wrapper.idx);
    const source = ctx.source.text()[span.start..span.end];
    const line_count = countLines(source, .{
        .skip_blank_lines = self.skip_blank_lines,
        .skip_comments = self.skip_comments,
    });

    if (line_count <= self.max) return;

    ctx.report(ctx.diagnosticf(
        "function is {} lines long; maximum is {}.",
        .{ line_count, self.max },
        .{ctx.spanN(wrapper.idx)},
    ));
}

const CountOptions = struct {
    skip_blank_lines: bool,
    skip_comments: bool,
};

fn countLines(source: []const u8, options: CountOptions) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (options.skip_blank_lines and trimmed.len == 0) continue;
        if (options.skip_comments and std.mem.startsWith(u8, trimmed, "//")) continue;
        count += 1;
    }
    return count;
}

pub fn rule(self: *MaxLinesPerFunction) Rule {
    return Rule.init(self);
}

test "countLines skips blank lines and comments" {
    const source =
        \\fn example() void {
        \\    // comment
        \\
        \\    var value: u32 = 1;
        \\}
    ;

    try std.testing.expectEqual(@as(u32, 3), countLines(source, .{
        .skip_blank_lines = true,
        .skip_comments = true,
    }));
    try std.testing.expectEqual(@as(u32, 5), countLines(source, .{
        .skip_blank_lines = false,
        .skip_comments = false,
    }));
}

test "rule reports functions over the limit" {
    var rule_instance = MaxLinesPerFunction{ .max = 4 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn short() void {
        \\    var value: u32 = 1;
        \\    _ = value;
        \\}
    };
    const fail = &[_][:0]const u8{
        \\fn long() void {
        \\    var first: u32 = 1;
        \\    var second: u32 = 2;
        \\    _ = first + second;
        \\}
    };

    try tester.withPass(pass).withFail(fail).run();
}
