//! Fuzz group: anchors + zero-width — the byte-DFA `supports` gate. Anchor/empty-
//! heavy patterns over newline-rich inputs, differenced across all backends.
//! See `harness.zig`.

const std = @import("std");
const h = @import("harness.zig");

test "fuzz: anchors/zero-width agree across all backends" {
    try std.testing.fuzz({}, h.anchorsAgree, .{ .corpus = &h.anchor_seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
