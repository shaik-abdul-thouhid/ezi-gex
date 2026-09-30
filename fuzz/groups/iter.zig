//! Fuzz group: iteration + replace. The `findAll` non-overlapping match SEQUENCE
//! agrees across backends (and `count` equals it), and `$`-template `replaceAll`
//! output is byte-identical across the capture backends. See `check/differential.zig`.

const std = @import("std");
const h = @import("fuzz_lib").check.differential;

test "fuzz: findAll sequence + count agree across backends" {
    try std.testing.fuzz({}, h.iterationAgree, .{ .corpus = &h.seed_corpus });
}

test "fuzz: replaceAll output agrees across backends" {
    try std.testing.fuzz({}, h.replaceAgree, .{ .corpus = &h.seed_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
