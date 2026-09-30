//! Fuzz group: the independent reference differential — Pike VM / backtrack / auto vs the
//! tree-driven reference matcher (span, every capture slot, findAll). See check/reference.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: engines agree with the independent reference (span, captures, findAll)" {
    try std.testing.fuzz({}, lib.check.reference.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
