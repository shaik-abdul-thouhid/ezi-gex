//! Fuzz group: allocation-failure injection over compile → Scratch.init → find/count →
//! replaceAllAlloc, on every backend. See check/oom.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: every allocation failure surfaces as OutOfMemory, never a leak or a swallow" {
    try std.testing.fuzz({}, lib.check.oom.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
