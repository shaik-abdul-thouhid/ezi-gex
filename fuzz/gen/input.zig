//! Haystack generators. `genInput` is the original small-input generator (moved from
//! the old harness); later tasks add evil UTF-8, long inputs with planted witnesses,
//! and fold-swapped copies.

const std = @import("std");
const Smith = std.testing.Smith;
const ps = @import("pattern.zig");

/// Largest haystack a small-input target feeds the engine.
pub const max_input_len = 64;

/// Generate a haystack into `buf`. 3:1 it draws from the shared alphabet (so matches
/// happen) vs raw full-range bytes (so no-match / prefilter-miss / invalid-UTF-8 paths run).
pub fn genInput(smith: *Smith, buf: []u8) []const u8 {
    @disableInstrumentation();
    const n = smith.slice(buf[0..@min(buf.len, max_input_len)]);
    if (smith.boolWeighted(3, 1)) {
        for (buf[0..n]) |*b| b.* = ps.alphabet[b.* % ps.alphabet.len];
    }
    return buf[0..n];
}
