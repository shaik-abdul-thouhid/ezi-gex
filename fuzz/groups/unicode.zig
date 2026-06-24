//! Fuzz group: Unicode — `\p{}`/`\P{}`/scripts, multi-byte literals, `(?i)` folding,
//! over both valid UTF-8 and raw (often invalid) bytes; plus a `\X` grapheme
//! no-crash target on the backtracker (its only backend). See `harness.zig`.

const std = @import("std");
const h = @import("harness.zig");

test "fuzz: Unicode patterns agree across all backends" {
    try std.testing.fuzz({}, h.unicodeAgree, .{ .corpus = &h.unicode_seed_corpus });
}

test "fuzz: \\X grapheme patterns never crash on the backtracker" {
    try std.testing.fuzz({}, h.graphemeNoCrash, .{ .corpus = &.{ "\\X", "\\X+", "a\\X\\X", "(?:\\X)+" } });
}

test {
    std.testing.refAllDecls(@This());
}
