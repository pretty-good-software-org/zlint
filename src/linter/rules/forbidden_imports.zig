//! ## What This Rule Does
//! Restricts imports between source-path patterns.
//!
//! This rule is intended for project architecture boundaries. Each boundary
//! applies when the importing file matches `source` and the imported `.zig`
//! file matches one of the `forbidden` patterns.
//!
//! ```json
//! {
//!   "forbidden-imports": ["error", {
//!     "rules": [
//!       {
//!         "source": "src/ui/**",
//!         "forbidden": ["src/database/**"]
//!       }
//!     ]
//!   }]
//! }
//! ```
//!
//! Patterns are resolved relative to the current working directory. Build
//! provided module imports such as `@import("database")` are ignored because
//! their source path is not available to a source-level rule.
const std = @import("std");
const path = std.fs.path;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;

const ForbiddenImports = @This();

pub const Boundary = struct {
    source: []const u8,
    forbidden: []const []const u8,
};

pub const meta: Rule.Meta = .{
    .name = "forbidden-imports",
    .category = .restriction,
    .default = .off,
};

rules: []const Boundary = &.{},

pub fn runOnNode(self: *const ForbiddenImports, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const source_path = ctx.source.pathname orelse return;
    const ast = ctx.ast();
    const node = wrapper.node;
    if (node.tag != .builtin_call_two) return;
    if (!std.mem.eql(u8, ctx.semantic.tokenSlice(node.main_token), "@import")) return;

    const argument = node.data.opt_node_and_opt_node[0].unwrap() orelse return;
    if (ast.nodeTag(argument) != .string_literal) return;

    const specifier = std.mem.trim(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(argument)), "\"");
    if (!isFileImport(specifier)) return;

    const importer = path.resolve(ctx.gpa, &.{source_path}) catch @panic("Failed to resolve importer path");
    defer ctx.gpa.free(importer);
    const importer_dir = path.dirname(importer) orelse return;
    const imported = path.resolve(ctx.gpa, &.{ importer_dir, specifier }) catch @panic("Failed to resolve imported path");
    defer ctx.gpa.free(imported);

    for (self.rules) |boundary| {
        if (!matchesPattern(ctx.gpa, boundary.source, importer)) continue;
        for (boundary.forbidden) |forbidden| {
            if (!matchesPattern(ctx.gpa, forbidden, imported)) continue;
            ctx.report(ctx.diagnosticf(
                "Import violates forbidden-imports boundary: {s} imports {s}",
                .{ source_path, imported },
                .{ctx.labelN(argument, "forbidden import", .{})},
            ));
            return;
        }
    }
}

fn matchesPattern(allocator: std.mem.Allocator, pattern: []const u8, value: []const u8) bool {
    const absolute_pattern = path.resolve(allocator, &.{pattern}) catch @panic("Failed to resolve import boundary pattern");
    defer allocator.free(absolute_pattern);
    return matchPattern(absolute_pattern, value);
}

const Segment = struct {
    value: []const u8,
    next: usize,
};

fn segmentAt(input: []const u8, start: usize) ?Segment {
    if (start >= input.len) return null;
    const end = std.mem.indexOfScalarPos(u8, input, start, '/') orelse input.len;
    return .{ .value = input[start..end], .next = if (end == input.len) end else end + 1 };
}

fn matchPattern(pattern: []const u8, value: []const u8) bool {
    return matchSegments(pattern, 0, value, 0);
}

fn matchSegments(pattern: []const u8, pattern_start: usize, value: []const u8, value_start: usize) bool {
    const pattern_segment = segmentAt(pattern, pattern_start) orelse return segmentAt(value, value_start) == null;
    if (std.mem.eql(u8, pattern_segment.value, "**")) {
        if (matchSegments(pattern, pattern_segment.next, value, value_start)) return true;
        const value_segment = segmentAt(value, value_start) orelse return false;
        return matchSegments(pattern, pattern_start, value, value_segment.next);
    }

    const value_segment = segmentAt(value, value_start) orelse return false;
    if (!matchSegment(pattern_segment.value, value_segment.value)) return false;
    return matchSegments(pattern, pattern_segment.next, value, value_segment.next);
}

fn matchSegment(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;

    while (value_index < value.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == value[value_index])) {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
        } else if (star_index) |index| {
            pattern_index = index + 1;
            star_value_index += 1;
            value_index = star_value_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn isFileImport(specifier: []const u8) bool {
    if (specifier.len < 4) return false;
    if (specifier[0] == '.' and specifier.len >= 2 and (specifier[1] == '/' or specifier[1] == '\\')) return true;
    return std.mem.eql(u8, specifier[specifier.len - 4 ..], ".zig");
}

pub fn rule(self: *ForbiddenImports) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");

test ForbiddenImports {
    const t = std.testing;
    const forbidden = &[_][]const u8{"src/database/**"};
    const boundaries = &[_]Boundary{
        .{ .source = "src/ui/**", .forbidden = forbidden },
    };
    var rule_instance = ForbiddenImports{ .rules = boundaries };
    var runner = RuleTester.init(t.allocator, rule_instance.rule());
    defer runner.deinit();

    runner.setFileName("view.zig");
    try runner
        .withPath("src/ui")
        .withPass(&[_][:0]const u8{
            "const util = @import(\"../util.zig\");",
            "const db = @import(\"../other/store.zig\");",
            "const db = @import(\"database\");",
        })
        .withFail(&[_][:0]const u8{
            "const db = @import(\"../database/store.zig\");",
        })
        .run();
}

test "forbidden-imports configuration parses boundaries" {
    const t = std.testing;
    var scanner = std.json.Scanner.initCompleteInput(t.allocator,
        \\{
        \\  "rules": [
        \\    {"source": "src/ui/**", "forbidden": ["src/database/**"]}
        \\  ]
        \\}
    );
    defer scanner.deinit();

    const parsed = try std.json.parseFromTokenSource(ForbiddenImports, t.allocator, &scanner, .{});
    defer parsed.deinit();
    try t.expectEqual(1, parsed.value.rules.len);
    try t.expectEqualStrings("src/ui/**", parsed.value.rules[0].source);
    try t.expectEqualStrings("src/database/**", parsed.value.rules[0].forbidden[0]);
}

test "forbidden-imports supports nested glob patterns" {
    const t = std.testing;
    const forbidden = &[_][]const u8{"src/database/**"};
    const boundaries = &[_]Boundary{
        .{ .source = "src/**/ui/*.zig", .forbidden = forbidden },
    };
    var rule_instance = ForbiddenImports{ .rules = boundaries };
    var runner = RuleTester.init(t.allocator, rule_instance.rule());
    defer runner.deinit();

    runner.setFileName("view.zig");
    try runner
        .withPath("src/features/ui")
        .withPass(&[_][:0]const u8{"const x = @import(\"../../util.zig\");"})
        .withFail(&[_][:0]const u8{"const x = @import(\"../../database/store.zig\");"})
        .run();
}
