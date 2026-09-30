//! Fuzz group: comptime/runtime parity — a fixed pattern table compiled at COMPTIME must
//! answer exactly like the runtime compile on fuzzed inputs. See check/comptime_parity.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: comptime-compiled programs agree with runtime-compiled ones" {
    try std.testing.fuzz({}, lib.check.comptime_parity.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
