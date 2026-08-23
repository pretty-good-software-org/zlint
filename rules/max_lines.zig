//! Checks that source files stay below a configurable physical line count.

const std = @import("std");
const zlint = @import("zlint");

const LinterContext = zlint.linter.lint_context.Context;
const Rule = zlint.linter.rule.Rule;

const MaxLines = @This();

max: u32 = 250,
skip_blank_lines: bool = true,
skip_comments: bool = true,

pub const meta: Rule.Meta = .{
    .name = "max-lines",
    .category = .style,
    .default = .off,
};

pub fn runOnce(self: *const MaxLines, ctx: *LinterContext) void {
    const line_count = countLines(ctx.source.text(), .{
        .skip_blank_lines = self.skip_blank_lines,
        .skip_comments = self.skip_comments,
    });

    if (line_count <= self.max) return;

    ctx.report(ctx.diagnosticf(
        "file is {} lines long; maximum is {}.",
        .{ line_count, self.max },
        .{},
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

pub fn rule(self: *MaxLines) Rule {
    return Rule.init(self);
}

test "countLines skips blank lines and comments" {
    const source =
        \\const first = 1;
        \\// comment
        \\
        \\const second = 2;
    ;

    try std.testing.expectEqual(@as(u32, 2), countLines(source, .{
        .skip_blank_lines = true,
        .skip_comments = true,
    }));
    try std.testing.expectEqual(@as(u32, 4), countLines(source, .{
        .skip_blank_lines = false,
        .skip_comments = false,
    }));
}

test "rule reports files over the limit" {
    var rule_instance = MaxLines{ .max = 2 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\const first = 1;
        \\const second = 2;
    };
    const fail = &[_][:0]const u8{
        \\const first = 1;
        \\const second = 2;
        \\const third = 3;
    };

    try tester.withPass(pass).withFail(fail).run();
}
