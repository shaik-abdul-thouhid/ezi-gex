//! Fuzz group: metamorphic printing — two equivalent spellings of one semantic tree must
//! give identical find / isMatch / captures / findAll on every backend; plus the fold-swap
//! relation for all-`(?i)` trees. See check/metamorphic.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: equivalent printings of one tree behave identically on every backend" {
    try std.testing.fuzz({}, lib.check.metamorphic.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
