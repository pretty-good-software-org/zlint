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
    const counted_switches = ctx.gpa.alloc(bool, nodes.len) catch @panic("OOM");
    defer ctx.gpa.free(counted_switches);
    @memset(counted_switches, false);

    for (0..nodes.len) |i| {
        const node_id: Ast.Node.Index = @enumFromInt(i);
        const tag = ast.nodeTag(node_id);
        const increment = complexityIncrement(tag);
        if (increment == 0 and !isSwitchCase(tag)) continue;

        var function_id: ?Ast.Node.Index = null;
        var switch_id: ?Ast.Node.Index = null;
        var parents = ctx.links().iterParentIds(node_id);
        while (parents.next()) |parent| {
            const parent_tag = ast.nodeTag(parent);
            if (switch_id == null and isSwitch(parent_tag)) switch_id = parent;
            if (parent_tag == .fn_decl) {
                function_id = parent;
                break;
            }
        }
        const function = function_id orelse continue;

        if (isSwitchCase(tag)) {
            const switch_node = switch_id orelse continue;
            if (!counted_switches[@intFromEnum(switch_node)]) {
                counted_switches[@intFromEnum(switch_node)] = true;
                continue;
            }
            counts[@intFromEnum(function)] += 1;
            continue;
        }
        counts[@intFromEnum(function)] += increment;
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
        .@"catch",
        => 1,
        else => 0,
    };
}

fn isSwitch(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .@"switch", .switch_comma => true,
        else => false,
    };
}

fn isSwitchCase(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => true,
        else => false,
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

test "rule handles each supported complexity construct" {
    var rule_instance = Complexity{ .max = 1 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn straightLine() void {}
        \\fn withAnd(first: bool, second: bool) void { _ = first and second; }
        \\fn withOr(first: bool, second: bool) void { _ = first or second; }
    };
    const fail = &[_][:0]const u8{
        \\fn withIf(value: bool) void { if (value) return; }
        \\fn withElseIf(value: bool) void { if (value) {} else if (!value) {} }
        \\fn withWhile(value: bool) void { while (value) break; }
        \\fn withFor() void { for ([_]u8{1}) |_| {} }
        \\fn withSwitch(value: u8) void {
        \\    switch (value) {
        \\        0 => {},
        \\        else => {},
        \\    }
        \\}
        \\fn withCatch() void { _ = errorValue() catch return; }
    };

    try tester.withPass(pass).withFail(fail).run();
}

test "rule applies limits independently to each function" {
    var rule_instance = Complexity{ .max = 2 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\const top_level = if (true) 1 else 2;
        \\fn first(value: bool) void { if (value) return; }
        \\fn second(value: bool) void { if (value) return; }
    };
    const fail = &[_][:0]const u8{
        \\fn first(value: bool) void {
        \\    if (value) {
        \\        while (value) break;
        \\    }
        \\}
        \\fn second() void {}
    };

    try tester.withPass(pass).withFail(fail).run();
}

test "rule counts switch arms after the first" {
    var rule_instance = Complexity{ .max = 2 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn twoArms(value: u8) void {
        \\    switch (value) {
        \\        0 => {},
        \\        else => {},
        \\    }
        \\}
    };
    const fail = &[_][:0]const u8{
        \\fn threeArms(value: u8) void {
        \\    switch (value) {
        \\        0 => {},
        \\        1 => {},
        \\        else => {},
        \\    }
        \\}
    };

    try tester.withPass(pass).withFail(fail).run();
}

test "rule isolates nested functions and ignores non-branches" {
    var rule_instance = Complexity{ .max = 2 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{
        \\fn outer() void { _ = null orelse 0; }
        \\fn inner(value: bool) void { if (value) {} }
        \\fn withNested(value: bool) void {
        \\    const Container = struct {
        \\        fn inner(inner_value: bool) void { if (inner_value) {} }
        \\    };
        \\    if (value) {}
        \\    _ = Container;
        \\}
    };
    const fail = &[_][:0]const u8{
        \\fn outer(value: bool) void {
        \\    if (value) {
        \\        if (value) {}
        \\    }
        \\}
        \\fn inner() void {}
    };

    try tester.withPass(pass).withFail(fail).run();
}

test "rule reports a function at zero limit" {
    var rule_instance = Complexity{ .max = 0 };
    var tester = zlint.linter.tester.RuleTester.init(std.testing.allocator, rule_instance.rule());
    defer tester.deinit();

    const pass = &[_][:0]const u8{};
    const fail = &[_][:0]const u8{
        \\fn straightLine() void {}
    };

    try tester.withPass(pass).withFail(fail).run();
}
