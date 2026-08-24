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
    const lines = countLines(source, .{
        .skip_blank_lines = self.skip_blank_lines,
        .skip_comments = self.skip_comments,
    });

    if (lines <= self.max) return;

    ctx.report(ctx.diagnosticf(
        "function is {} lines long; maximum is {}.",
        .{ lines, self.max },
        .{ctx.spanN(wrapper.idx)},
    ));
}

pub fn rule(self: *MaxLinesPerFunction) Rule {
    return Rule.init(self);
}

const CountOptions = struct {
    skip_blank_lines: bool,
    skip_comments: bool,
};

fn countLines(source: []const u8, options: CountOptions) u32 {
    var count: u32 = 0;
    var block_comment_depth: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var has_non_whitespace = false;
        var has_code = false;
        var in_string: u8 = 0;
        var escaped = false;
        var i: usize = 0;
        while (i < line.len) {
            const current = line[i];
            if (block_comment_depth > 0) {
                if (i + 1 < line.len and current == '/' and line[i + 1] == '*') {
                    block_comment_depth += 1;
                    i += 2;
                } else if (i + 1 < line.len and current == '*' and line[i + 1] == '/') {
                    block_comment_depth -= 1;
                    i += 2;
                } else i += 1;
                continue;
            }
            if (in_string != 0) {
                has_non_whitespace = true;
                if (escaped) escaped = false else if (current == '\\') escaped = true else if (current == in_string) in_string = 0;
                i += 1;
                continue;
            }
            if (current == '"' or current == '\'') {
                in_string = current;
                has_non_whitespace = true;
                has_code = true;
                i += 1;
            } else if (i + 1 < line.len and current == '/' and line[i + 1] == '/') {
                break;
            } else if (i + 1 < line.len and current == '/' and line[i + 1] == '*') {
                block_comment_depth = 1;
                i += 2;
            } else {
                if (!std.ascii.isWhitespace(current)) {
                    has_non_whitespace = true;
                    has_code = true;
                }
                i += 1;
            }
        }
        if (options.skip_blank_lines and !has_non_whitespace) continue;
        if (options.skip_comments and !has_code) continue;
        count += 1;
    }
    return count;
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

test "countLines handles inline and multiline comments" {
    const source =
        \\fn example() void { // inline comment
        \\    /* block comment
        \\     * continues on another line
        \\     */
        \\    var value: u32 = 1;
        \\}
    ;

    try std.testing.expectEqual(@as(u32, 3), countLines(source, .{
        .skip_blank_lines = true,
        .skip_comments = true,
    }));
}

test "countLines handles CRLF line endings" {
    const source = "fn example() void {\r\n    return;\r\n}\r\n";

    try std.testing.expectEqual(@as(u32, 3), countLines(source, .{
        .skip_blank_lines = true,
        .skip_comments = true,
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
