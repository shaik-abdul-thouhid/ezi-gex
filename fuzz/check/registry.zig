//! CheckId → the check's deterministic `run`, for `fuzz-min` and the findings ledger.

const std = @import("std");
const common = @import("common.zig");
const d = @import("differential.zig");

pub fn run(gpa: std.mem.Allocator, case: *const common.Case) anyerror!void {
    return switch (case.check) {
        .span, .anchors, .unicode => d.runSpan(gpa, case),
        .captures => d.runCaptures(gpa, case),
        .iter => d.runIter(gpa, case),
        .replace => d.runReplace(gpa, case),
        .offset => d.runOffset(gpa, case),
        .strategy => d.runStrategy(gpa, case),
        .scanner => @import("scanner.zig").run(gpa, case),
        .grapheme => @import("grapheme.zig").run(gpa, case),
        .reference => @import("reference.zig").run(gpa, case),
        .metamorphic => @import("metamorphic.zig").run(gpa, case),
        .invariants => @import("invariants.zig").run(gpa, case),
        .state => @import("state.zig").run(gpa, case),
        .large => @import("large.zig").run(gpa, case),
        .literals => @import("literals.zig").run(gpa, case),
        .api => @import("api.zig").run(gpa, case),
        .oom => @import("oom.zig").run(gpa, case),
        .comptime_parity => @import("comptime_parity.zig").run(gpa, case),
        .complexity => @import("complexity.zig").run(gpa, case),
        .utf8class => @import("utf8class.zig").run(gpa, case),
        .chaos => @import("chaos.zig").run(gpa, case),
        .compile_bomb => @import("complexity.zig").runBomb(gpa, case),
    };
}

test "registry replays a differential case" {
    try run(std.testing.allocator, &.{ .check = .span, .pattern = "a|ab", .input = "xab" });
}
