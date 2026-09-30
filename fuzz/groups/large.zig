//! Fuzz group: long inputs (up to 12 KiB) with planted witnesses and near-misses at SIMD
//! block edges, around auto's 4096-byte backtrack→Pike-VM switch. See check/large.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: every backend agrees with the Pike VM on long inputs" {
    try std.testing.fuzz({}, lib.check.large.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
