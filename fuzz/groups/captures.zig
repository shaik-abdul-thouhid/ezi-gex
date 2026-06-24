//! Fuzz group: full capture-slot arrays (every group, not just the whole-match
//! span) agree across pikevm / backtrack / auto / onepass / bytepike.
//! See `harness.zig`.

const std = @import("std");
const h = @import("harness.zig");

test "fuzz: capture slots agree across capture-capable backends" {
    try std.testing.fuzz({}, h.capturesAgree, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
