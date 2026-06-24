//! Fuzz group: search offset / anchored (`findAt(.{ .start, .anchored, .span_end })`)
//! differenced across backends, plus the strategy-tier results-invariance contract
//! (flipping byte_engine / prefilter / simd must never change the match).
//! See `harness.zig`.

const std = @import("std");
const h = @import("harness.zig");

test "fuzz: findAt offset/anchored agree across backends" {
    try std.testing.fuzz({}, h.searchOffsetAgree, .{ .corpus = &h.seed_corpus });
}

test "fuzz: strategy-tier flags never change the match (results-invariant)" {
    try std.testing.fuzz({}, h.strategyInvariant, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
