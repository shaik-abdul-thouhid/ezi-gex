//! Fuzz group: deterministic complexity — the backtracker's work counter must scale
//! linearly on generated patterns; auto must do zero per-occurrence confirms on
//! end-anchored programs. See check/complexity.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: matching work stays linear (counter-based, no timers)" {
    try std.testing.fuzz({}, lib.check.complexity.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test "fuzz: nested counted repetition never blows compile memory (size_limit)" {
    try std.testing.fuzz({}, lib.check.complexity.bombOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
