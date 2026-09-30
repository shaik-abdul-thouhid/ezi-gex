//! Fuzz group: full capture-slot arrays (every group, not just the whole-match
//! span) agree across pikevm / backtrack / auto / onepass / bytepike.
//! See `check/differential.zig`.

const std = @import("std");
const h = @import("fuzz_lib").check.differential;

test "fuzz: capture slots agree across capture-capable backends" {
    try std.testing.fuzz({}, h.capturesAgree, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
