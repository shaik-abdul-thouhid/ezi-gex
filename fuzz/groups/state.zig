//! Fuzz group: scratch state — a script of searches on ONE long-lived Scratch (heap and
//! buffer-backed) over a buffer that is refilled in place, truncated, moved, and iterated
//! partially, must match a fresh-scratch Pike VM at every step. See check/state.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: a long-lived, dirty scratch behaves like a fresh one" {
    try std.testing.fuzz({}, lib.check.state.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
