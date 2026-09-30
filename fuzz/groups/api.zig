//! Fuzz group: the rest of the public surface — split/splitN, replace/replaceN/
//! replaceAllWith, capturesAll/capturesAt, groupIndex/groupName — with hostile `$`
//! templates (`${name}`, bare `$`, `$99`, unterminated `${`). See check/api.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: the whole public search/replace/split surface agrees across capture backends" {
    try std.testing.fuzz({}, lib.check.api.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
