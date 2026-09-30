//! Fuzz group: code-point classes with endpoints on UTF-8 length boundaries, searched over
//! code points around those boundaries and hostile bytes; every backend (byte DFAs
//! included) is checked against the class's own ground truth. See check/utf8class.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: class membership at UTF-8 boundaries matches ground truth on every backend" {
    try std.testing.fuzz({}, lib.check.utf8class.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
