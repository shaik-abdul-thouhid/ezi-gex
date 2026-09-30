//! Fuzz group: oracle-free laws on EVERY backend — isMatchAt/findAt consistency,
//! unanchored = first anchored, findAll resume consistency, capture-slot containment,
//! replace/split reconstruction. See check/invariants.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: oracle-free laws hold on every backend" {
    try std.testing.fuzz({}, lib.check.invariants.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
