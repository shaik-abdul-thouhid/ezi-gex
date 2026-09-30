//! Fuzz group: chaos — one tree-printed case (random option variant, witness-bearing input,
//! hostile template, random search options) through reference, metamorphic, invariants,
//! state and api in turn. See check/chaos.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: one case through every check that can take it" {
    try std.testing.fuzz({}, lib.check.chaos.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
