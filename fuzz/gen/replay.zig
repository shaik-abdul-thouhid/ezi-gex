//! Replay-mode `Smith` input. When a `Smith` REPLAYS bytes (seed corpora, fuzz/health.zig,
//! unit tests), every value draw consumes one little-endian `u64` and an out-of-range word
//! collapses to the range's MINIMUM, while `eos` consumes one byte and is `byte != 0`. Raw
//! random bytes therefore make nearly every draw its minimum and the generators produce
//! trivial cases. These helpers write SMALL words instead, so replayed generators actually
//! explore their ranges. Generators help by putting the INTERESTING branch of a switch
//! at the draw's minimum (the replay fallback); live fuzzing stays uniform either way.

const std = @import("std");
const Smith = std.testing.Smith;

/// One replay word: mostly tiny (counts, kinds), sometimes wider (table indices, code-point
/// pools, u16 lengths). Values past a draw's range still fall back to its minimum.
fn word(r: std.Random) u64 {
    return switch (r.uintLessThan(u8, 20)) {
        0...11 => r.uintLessThan(u64, 8),
        12...15 => r.uintLessThan(u64, 16),
        16...18 => r.uintLessThan(u64, 64),
        else => r.uintLessThan(u64, 1 << 14),
    };
}

pub fn fill(r: std.Random, buf: []u8) void {
    var i: usize = 0;
    while (i + 8 <= buf.len) : (i += 8) std.mem.writeInt(u64, buf[i..][0..8], word(r), .little);
    @memset(buf[i..], 0);
}

/// A replaying `Smith` over `buf`, refilled from `prng`.
pub fn smith(prng: *std.Random.DefaultPrng, buf: []u8) Smith {
    fill(prng.random(), buf);
    return .{ .in = buf };
}

/// `n` comptime seed corpora of `words` replay words each — the `.corpus` for fuzz groups,
/// so a finite `zig build test` replays non-trivial cases.
pub fn corpus(comptime n: usize, comptime words: usize, comptime seed: u64) [n][]const u8 {
    @setEvalBranchQuota(100_000);
    {
        var out: [n][]const u8 = undefined;
        var x: u64 = seed | 1;
        for (0..n) |k| {
            var bytes: [words * 8]u8 = undefined;
            for (0..words) |w| {
                // xorshift64 — comptime-friendly; values shaped like `word` above.
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const v: u64 = switch (x % 20) {
                    0...11 => (x >> 8) % 8,
                    12...15 => (x >> 8) % 16,
                    16...18 => (x >> 8) % 64,
                    else => (x >> 8) % (1 << 14),
                };
                std.mem.writeInt(u64, bytes[w * 8 ..][0..8], v, .little);
            }
            const final = bytes;
            out[k] = &final;
        }
        return out;
    }
}

test "replay words keep draws inside small ranges" {
    var prng = std.Random.DefaultPrng.init(1);
    var buf: [8 * 64]u8 = undefined;
    var s = smith(&prng, &buf);
    var nonzero: usize = 0;
    for (0..64) |_| {
        if (s.valueRangeAtMost(u8, 0, 5) != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 20);
    const c = comptime corpus(3, 16, 7);
    try std.testing.expectEqual(@as(usize, 128), c[0].len);
}
