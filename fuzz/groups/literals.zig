//! Fuzz group: literal sets (shared prefixes, prefix-of-another, duplicates, empty, (?i)
//! with fold traps, 1–12 branches, 0–20 code points) over long inputs with planted members
//! and near-misses — literal/Teddy/memmem/prefix-set paths vs the Pike VM, across the
//! strategy tier. See check/literals.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: literal-set searches agree across backends and strategies" {
    try std.testing.fuzz({}, lib.check.literal_sets.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
