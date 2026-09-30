//! Haystack generators. `genInput` is the original small-input generator (moved from
//! the old harness); later tasks add evil UTF-8, long inputs with planted witnesses,
//! and fold-swapped copies.

const std = @import("std");
const Smith = std.testing.Smith;
const ps = @import("pattern.zig");
const tree = @import("tree.zig");
const uni = @import("../ref/uni.zig");
const replay = @import("replay.zig");

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


/// Whole units of hostile UTF-8, mixed with ordinary text so matches still happen.
pub const evil_pieces = [_][]const u8{
    "\xC3",             "\xE6\x97",         "\xF0\x9F\x98", // truncated leads
    "\x80",             "\xBF", // stray continuations
    "\xC0\x80",         "\xC1\xBF",         "\xE0\x80\x80", "\xF0\x80\x80\x80", // overlong
    "\xED\xA0\x80",     "\xED\xBF\xBF", // surrogates
    "\xF4\x90\x80\x80", "\xF5",             "\xFF", // > U+10FFFF / never valid
    "\xEF\xBF\xBD", // a REAL U+FFFD (must differ from a malformed byte)
    "\xEF\xBF\xBF", // U+FFFF noncharacter (valid)
    "a",                "b",                "A", " ", "\n", "_", "1",
    "\xC3\xA9",         "\xE2\x84\xAA",     "\xF0\x90\x90\x80",
};
pub const truncated_tails = [_][]const u8{ "\xC3", "\xE6\x97", "\xF0\x9F\x98", "\xE2" };

pub fn evilInput(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const n = smith.valueRangeAtMost(u8, 0, 16);
    var len: usize = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const p = evil_pieces[smith.index(evil_pieces.len)];
        if (len + p.len > out.len) break;
        @memcpy(out[len..][0..p.len], p);
        len += p.len;
    }
    if (smith.valueRangeAtMost(u8, 0, 2) == 0) { // end on a truncated sequence
        const tail = truncated_tails[smith.index(truncated_tails.len)];
        if (len + tail.len <= out.len) {
            @memcpy(out[len..][0..tail.len], tail);
            len += tail.len;
        }
    }
    return out[0..len];
}

pub const max_long_len = 12 * 1024;

/// Lengths biased to the regimes that switch code paths: around 4096 (auto's
/// backtrack→Pike-VM cut), SIMD block multiples ±1, and far past both.
pub fn longLen(smith: *Smith) usize {
    @disableInstrumentation();
    // Case 0 (the value a replayed out-of-range draw falls back to) is the long regime.
    return switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0, 1 => smith.valueRangeAtMost(u16, 4097, max_long_len),
        2 => 4095 + @as(usize, smith.valueRangeAtMost(u8, 0, 2)),
        3 => @as(usize, smith.valueRangeAtMost(u16, 1, 190)) * 64 + smith.valueRangeAtMost(u8, 0, 2) - 1,
        4 => smith.valueRangeAtMost(u16, 65, 4094),
        else => smith.valueRangeAtMost(u16, 0, 200),
    };
}

/// A 4–32 byte motif of whole code points (alphabet + traps).
pub fn motif(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const want = smith.valueRangeAtMost(u8, 4, 32);
    var len: usize = 0;
    while (len < want) {
        const piece: []const u8 = if (smith.valueRangeAtMost(u8, 0, 4) == 0)
            ps.trap_raw[smith.index(ps.trap_raw.len)]
        else
            ps.alphabet[smith.index(ps.alphabet.len)..][0..1];
        if (len + piece.len > out.len) break;
        @memcpy(out[len..][0..piece.len], piece);
        len += piece.len;
    }
    return out[0..len];
}

pub const Long = struct { bytes: []u8, plants_at: [4]usize = undefined, n_plants: usize = 0 };

/// `motif` repeated to an edge-biased length, then each of `plants` (≤ 4) copied in at a
/// block-edge / near-end offset. Later plants may overlap earlier ones; `plants_at` records
/// where each landed.
pub fn longInput(smith: *Smith, out: []u8, m: []const u8, plants: []const []const u8) Long {
    @disableInstrumentation();
    const len = @min(longLen(smith), out.len);
    if (m.len == 0) @memset(out[0..len], 'x') else for (out[0..len], 0..) |*b, i| {
        b.* = m[i % m.len];
    }
    var l: Long = .{ .bytes = out[0..len] };
    for (plants[0..@min(plants.len, 4)]) |p| {
        if (p.len == 0 or p.len > len) continue;
        const room = len - p.len;
        const pos: usize = switch (smith.valueRangeAtMost(u8, 0, 4)) {
            0 => room,
            1 => room -| smith.valueRangeAtMost(u8, 0, 3),
            2 => (@as(usize, smith.valueRangeAtMost(u16, 0, 760)) * 16 + smith.valueRangeAtMost(u8, 0, 2)) -| 1,
            3 => (@as(usize, smith.valueRangeAtMost(u16, 0, 380)) * 32 + smith.valueRangeAtMost(u8, 0, 2)) -| 1,
            else => (@as(usize, smith.valueRangeAtMost(u16, 0, 190)) * 64 + smith.valueRangeAtMost(u8, 0, 2)) -| 1,
        };
        const at = @min(pos, room);
        @memcpy(out[at..][0..p.len], p);
        l.plants_at[l.n_plants] = at;
        l.n_plants += 1;
    }
    return l;
}

/// Replace every valid scalar by a random member of its simple-fold orbit (lengths may
/// change: k ↔ K U+212A is 1 ↔ 3 bytes); malformed bytes are copied unchanged.
pub fn foldSwap(in: []const u8, out: []u8, seed: u64) []const u8 {
    std.debug.assert(out.len >= 4 * in.len);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var i: usize = 0;
    var j: usize = 0;
    while (i < in.len) {
        const d = uni.decode(in, i);
        if (!d.valid) {
            out[j] = in[i];
            j += 1;
            i += 1;
            continue;
        }
        var ob: [8]u21 = undefined;
        const o = uni.orbit(d.cp, &ob);
        var b: [4]u8 = undefined;
        const n = tree.encodeUtf8(o[r.uintLessThan(usize, o.len)], &b);
        @memcpy(out[j..][0..n], b[0..n]);
        j += n;
        i += d.len;
    }
    return out[0..j];
}

/// The small-input mix every check uses: 2:1:1 alphabet text, valid Unicode, evil bytes.
pub fn pickSmall(smith: *Smith, buf: []u8) []const u8 {
    @disableInstrumentation();
    return switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0, 1 => genInput(smith, buf),
        2 => buf[0..ps.unicodeInput(smith, buf[0..@min(buf.len, max_input_len)])],
        else => evilInput(smith, buf[0..@min(buf.len, max_input_len)]),
    };
}


test "evilInput is usually malformed somewhere" {
    var prng = std.Random.DefaultPrng.init(41);
    var sb: [4096]u8 = undefined;
    var out: [128]u8 = undefined;
    var bad: usize = 0;
    for (0..1000) |_| {
        var s = replay.smith(&prng, &sb);
        const in = evilInput(&s, &out);
        var i: usize = 0;
        while (i < in.len) {
            const d = uni.decode(in, i);
            if (!d.valid) {
                bad += 1;
                break;
            }
            i += d.len;
        }
    }
    try std.testing.expect(bad >= 700);
}

test "longInput crosses 4096 often and plants where it says" {
    var prng = std.Random.DefaultPrng.init(43);
    var sb: [4096]u8 = undefined;
    const out = try std.testing.allocator.alloc(u8, max_long_len);
    defer std.testing.allocator.free(out);
    var over: usize = 0;
    for (0..400) |_| {
        var s = replay.smith(&prng, &sb);
        const l = longInput(&s, out, "ab c\n", &.{ "NEEDLE", "XY" });
        if (l.bytes.len > 4096) over += 1;
        // Plants may overlap earlier ones (or be skipped when the input is shorter than the
        // plant), so check only that the LAST recorded plant is intact.
        if (l.n_plants > 0) {
            const tail = l.bytes[l.plants_at[l.n_plants - 1]..];
            try std.testing.expect(std.mem.startsWith(u8, tail, "XY") or std.mem.startsWith(u8, tail, "NEEDLE"));
        }
    }
    try std.testing.expect(over * 4 >= 400); // ≥ 25%
}

test "foldSwap preserves every scalar's fold and copies malformed bytes" {
    var out: [64]u8 = undefined;
    const in = "k\xE2\x84\xAAs\xC5\xBF\xCF\x82\xFFx";
    for (0..50) |seed| {
        const sw = foldSwap(in, &out, seed);
        var i: usize = 0;
        var j: usize = 0;
        while (i < in.len) {
            const a = uni.decode(in, i);
            const b = uni.decode(sw, j);
            try std.testing.expectEqual(a.valid, b.valid);
            if (a.valid) try std.testing.expectEqual(uni.fold(a.cp), uni.fold(b.cp)) else try std.testing.expectEqual(in[i], sw[j]);
            i += a.len;
            j += b.len;
        }
        try std.testing.expectEqual(sw.len, j);
    }
}
