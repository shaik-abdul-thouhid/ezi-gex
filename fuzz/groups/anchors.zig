//! Fuzz group: anchors + zero-width — the byte-DFA `supports` gate. Anchor/empty-
//! heavy patterns over newline-rich inputs, differenced across all backends.
//! See `check/differential.zig`.

const std = @import("std");
const h = @import("fuzz_lib").check.differential;

test "fuzz: anchors/zero-width agree across all backends" {
    try std.testing.fuzz({}, h.anchorsAgree, .{ .corpus = &h.anchor_seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
