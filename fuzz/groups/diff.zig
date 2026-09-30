//! Fuzz group: the core span/find/isMatch differential over structured patterns —
//! Pike VM (oracle) vs backtrack, auto, bytepike, dfa, edfa, onepass, literal.
//! See `check/differential.zig`.

const std = @import("std");
const h = @import("fuzz_lib").check.differential;

test "fuzz: all backends agree on structured patterns (span + isMatch)" {
    try std.testing.fuzz({}, h.backendsAgree, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
