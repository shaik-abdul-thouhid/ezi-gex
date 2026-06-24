//! Fuzz group: scanner robustness + the `{m,n}` repetition ceiling. Parse-only,
//! so the cheapest group — runs many iterations per second. See `harness.zig`.

const std = @import("std");
const h = @import("harness.zig");

test "fuzz: parseWith never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, h.scannerRobustness, .{ .corpus = &h.seed_corpus });
}

test "fuzz: repetition limit accept/reject is exact" {
    try std.testing.fuzz({}, h.repetitionLimit, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
