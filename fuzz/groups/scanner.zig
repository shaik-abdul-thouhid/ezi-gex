//! Fuzz group: scanner robustness + the `{m,n}` repetition ceiling. Parse-only,
//! so the cheapest group — runs many iterations per second. See `check/differential.zig`.

const std = @import("std");
const h = @import("fuzz_lib").check.differential;

test "fuzz: parseWith never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, h.scannerRobustness, .{ .corpus = &h.seed_corpus });
}

test "fuzz: repetition limit accept/reject is exact" {
    try std.testing.fuzz({}, h.repetitionLimit, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
