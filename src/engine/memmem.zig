//! `memmem` — a portable SIMD single-substring search.
//!
//! The single-literal counterpart to Teddy (`teddy.zig`, which handles *alternations*).
//! For a pattern that reduces to one literal run (`Sherlock Holmes`, `héllo`), the
//! `literal` backend used to skip from candidate to candidate with a **one-byte** memchr
//! on the needle's first byte and then verify — but a single common lead byte (`'S'`,
//! `'t'`) leaves a candidate at nearly every occurrence, so most of the work is wasted
//! verification. This module replaces that with the classic **two-byte filter**: probe
//! two needle offsets whose bytes are (heuristically) rarest in typical text, AND their
//! two SIMD equality masks, and verify only where *both* coincide. The candidate density
//! drops to ≈ `(f_lo/256)·(f_hi/256)`, which is what closes the gap to a real `memmem`.
//!
//! ## Portable, unlike Teddy
//!
//! The only SIMD ops here are a broadcast compare (`vec == @splat(b)`) and a movemask
//! (`@bitCast` of the resulting bool vector). Both are portable `@Vector` — LLVM lowers
//! them to SSE2 `pcmpeqb`/`pmovmskb`, NEON, etc. on every target, no inline asm and no
//! feature gate. (`simd.zig`'s dynamic shuffle stays the *only* arch-specific code in the
//! engine.) The vector width widens to 256-bit on AVX2, else 128-bit.
//!
//! ## Sound, and a pure accelerator
//!
//! The two-byte filter never reports a false **negative** (a real occurrence has both
//! probe bytes, so it survives the AND); false positives cost only a verify. The rarity
//! heuristic (`freq`) therefore affects **speed only, never correctness** — every surviving
//! candidate is confirmed with a full `std.mem.eql`. Results are identical to the scalar
//! scan, so the `literal` backend gates this on `Options.simd` purely for performance.
//!
//! ## comptime
//!
//! `Finder.find` routes a `@inComptime()` call to the scalar fallback (no `@Vector` in
//! const-eval, per the project rule). In practice the comptime `literal` program never
//! builds a `Finder` (like Teddy, it is a runtime-only accelerator), but the guard keeps
//! the type usable at comptime regardless.
//!
//! @stable-since: v0.4.0

const std = @import("std");
const builtin = @import("builtin");

/// Portable vector width: 256-bit on AVX2 (one `vpcmpeqb`/`vpmovmskb` over 32 starts),
/// else 128-bit. Wider on AVX2 only — NEON has no 256-bit register and no cheap 32-lane
/// movemask, so 16 lowers better there.
pub const W: usize = if (builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16;

const V = @Vector(W, u8);
/// Movemask integer: one bit per vector lane (`@bitCast` of a `@Vector(W, bool)`).
const Mask = if (W == 32) u32 else u16;

/// Shortest needle the two-byte filter applies to. A 1-byte needle is a plain memchr
/// (already SIMD via `std.mem.indexOfScalarPos`), so the `literal` backend keeps that on
/// the existing path and only builds a `Finder` at length ≥ 2.
///
/// @stable-since: v0.4.0
pub const MIN_LEN: usize = 2;

/// Heuristic byte-commonness, higher = more frequent in typical UTF-8 text (English prose,
/// source code, logs). Built at comptime from a small frequency model so the 256 values
/// aren't opaque magic. **Steers probe-byte choice only** — it never affects which matches
/// are found (every candidate is fully verified), so an imperfect table costs at most a few
/// extra verifies, never a wrong result.
const freq: [256]u8 = blk: {
    var f: [256]u8 = @splat(1);
    const weights = [_]struct { u8, u8 }{
        // whitespace
        .{ ' ', 200 }, .{ '\n', 90 }, .{ '\r', 40 }, .{ '\t', 40 },
        // lowercase, ~English letter frequency order (e t a o i n s h r …)
        .{ 'e', 180 }, .{ 't', 170 }, .{ 'a', 165 }, .{ 'o', 160 }, .{ 'i', 158 },
        .{ 'n', 156 }, .{ 's', 154 }, .{ 'h', 150 }, .{ 'r', 148 }, .{ 'd', 130 },
        .{ 'l', 128 }, .{ 'c', 120 }, .{ 'u', 118 }, .{ 'm', 116 }, .{ 'w', 110 },
        .{ 'f', 108 }, .{ 'g', 104 }, .{ 'y', 102 }, .{ 'p', 100 }, .{ 'b', 96 },
        .{ 'v', 70 }, .{ 'k', 55 }, .{ 'j', 30 }, .{ 'x', 28 }, .{ 'q', 22 }, .{ 'z', 20 },
        // uppercase, less common than lowercase
        .{ 'E', 90 }, .{ 'T', 88 }, .{ 'A', 86 }, .{ 'O', 80 }, .{ 'I', 80 },
        .{ 'N', 78 }, .{ 'S', 78 }, .{ 'H', 74 }, .{ 'R', 72 }, .{ 'D', 60 },
        .{ 'L', 58 }, .{ 'C', 60 }, .{ 'U', 50 }, .{ 'M', 58 }, .{ 'W', 54 },
        .{ 'F', 50 }, .{ 'G', 46 }, .{ 'Y', 44 }, .{ 'P', 52 }, .{ 'B', 56 },
        .{ 'V', 36 }, .{ 'K', 28 }, .{ 'J', 24 }, .{ 'X', 16 }, .{ 'Q', 14 }, .{ 'Z', 12 },
        // digits
        .{ '0', 80 }, .{ '1', 78 }, .{ '2', 70 }, .{ '3', 60 }, .{ '4', 58 },
        .{ '5', 58 }, .{ '6', 56 }, .{ '7', 54 }, .{ '8', 54 }, .{ '9', 56 },
        // common punctuation
        .{ '.', 90 }, .{ ',', 85 }, .{ '"', 60 }, .{ '\'', 60 }, .{ '-', 70 },
        .{ '_', 50 }, .{ '/', 60 }, .{ ':', 55 }, .{ ';', 45 }, .{ '(', 45 },
        .{ ')', 45 }, .{ '<', 35 }, .{ '>', 35 }, .{ '=', 45 }, .{ '!', 30 },
        .{ '?', 30 }, .{ '*', 30 }, .{ '@', 25 }, .{ '#', 25 }, .{ '&', 20 },
        .{ '{', 30 }, .{ '}', 30 }, .{ '[', 30 }, .{ ']', 30 }, .{ '|', 18 },
    };
    for (weights) |w| f[@as(usize, w[0])] = w[1];
    // bytes ≥ 0x80 (UTF-8 lead/continuation) are low-medium common in non-ASCII text;
    // a flat baseline so an all-high-byte needle still picks two sane probe offsets.
    var b: usize = 0x80;
    while (b < 0x100) : (b += 1) f[b] = 64;
    break :blk f;
};

/// Heuristic byte-commonness, higher = more frequent in typical text. The same model the
/// two-byte probe uses (`freq` above), exposed so other prefilters (the `auto` dispatcher's
/// case-variant *window* selection) can rank candidate windows by estimated density. Steers
/// prefilter choice only — never affects which matches are found.
///
/// @stable-since: v0.6.0
pub fn byteFreq(b: u8) u8 {
    return freq[b];
}

/// A precomputed two-byte filter for one needle (length ≥ `MIN_LEN`). `needle` aliases the
/// caller's storage (the `literal` program's `needles` buffer) — it owns no memory, so there
/// is nothing to free. `lo`/`hi` (with `lo < hi`) are the two probed needle offsets and
/// `b_lo`/`b_hi` their bytes, chosen once at `init` to minimise candidate density.
///
/// @stable-since: v0.4.0
pub const Finder = struct {
    needle: []const u8,
    lo: u32,
    hi: u32,
    b_lo: u8,
    b_hi: u8,

    /// Pick the two rarest-byte offsets and cache them. Caller guarantees
    /// `needle.len >= MIN_LEN`.
    ///
    /// @stable-since: v0.4.0
    pub fn init(needle: []const u8) Finder {
        std.debug.assert(needle.len >= MIN_LEN);
        // Offset of the globally rarest byte, then the rarest among the rest.
        var oa: usize = 0;
        var k: usize = 1;
        while (k < needle.len) : (k += 1) {
            if (freq[needle[k]] < freq[needle[oa]]) oa = k;
        }
        var ob: usize = if (oa == 0) 1 else 0;
        k = 0;
        while (k < needle.len) : (k += 1) {
            if (k == oa) continue;
            if (freq[needle[k]] < freq[needle[ob]]) ob = k;
        }
        const lo = @min(oa, ob);
        const hi = @max(oa, ob);
        return .{
            .needle = needle,
            .lo = @intCast(lo),
            .hi = @intCast(hi),
            .b_lo = needle[lo],
            .b_hi = needle[hi],
        };
    }

    /// First index `≥ start` at which `needle` occurs in `input`, or null. Leftmost match
    /// (candidates are scanned left→right, and `@ctz` takes the lowest lane within a chunk).
    ///
    /// @stable-since: v0.4.0
    pub fn find(self: *const Finder, input: []const u8, start: usize) ?usize {
        const n = self.needle.len;
        if (start + n > input.len) return null;
        if (@inComptime()) return self.scalarFrom(input, start);

        const lo: usize = self.lo;
        const hi: usize = self.hi;
        const vlo: V = @splat(self.b_lo);
        const vhi: V = @splat(self.b_hi);

        var i: usize = start;
        // The chunk probes starts i..i+W-1 at offsets lo and hi; the binding load is at
        // i+hi, so it stays in bounds while i + hi + W <= input.len.
        if (input.len >= hi + W) {
            const max_i = input.len - hi - W;
            while (i <= max_i) : (i += W) {
                const wa: V = input[i + lo ..][0..W].*;
                const wb: V = input[i + hi ..][0..W].*;
                const ma: Mask = @bitCast(wa == vlo);
                const mb: Mask = @bitCast(wb == vhi);
                var bits = ma & mb;
                while (bits != 0) {
                    const j: usize = @ctz(bits);
                    const cand = i + j;
                    if (cand + n <= input.len and std.mem.eql(u8, input[cand..][0..n], self.needle))
                        return cand;
                    bits &= bits - 1; // clear lowest set bit
                }
            }
        }
        return self.scalarFrom(input, i);
    }

    /// Scalar two-byte filter + verify, from `from` to the end. The SIMD tail and the
    /// comptime path share it; on its own it is a correct (if unvectorised) `find`.
    fn scalarFrom(self: *const Finder, input: []const u8, from: usize) ?usize {
        const n = self.needle.len;
        const lo: usize = self.lo;
        const hi: usize = self.hi;
        var p = from;
        while (p + n <= input.len) : (p += 1) {
            if (input[p + lo] == self.b_lo and input[p + hi] == self.b_hi and
                std.mem.eql(u8, input[p..][0..n], self.needle)) return p;
        }
        return null;
    }
};

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Trivial leftmost-from-`start` reference scan; the oracle for the differential tests.
fn refIndex(input: []const u8, needle: []const u8, start: usize) ?usize {
    var p = start;
    while (p + needle.len <= input.len) : (p += 1) {
        if (std.mem.eql(u8, input[p..][0..needle.len], needle)) return p;
    }
    return null;
}

/// The crux property: at *every* start offset, the Finder agrees with the reference scan.
/// Covers boundaries, the SIMD/scalar-tail seam, priority of the leftmost hit, and overlap.
fn expectAgreesEverywhere(needle: []const u8, input: []const u8) !void {
    const f = Finder.init(needle);
    var s: usize = 0;
    while (s <= input.len) : (s += 1) {
        try testing.expectEqual(refIndex(input, needle, s), f.find(input, s));
    }
}

test "memmem: short needle, sparse and dense matches" {
    try expectAgreesEverywhere("ab", "xxabyyabzzab");
    try expectAgreesEverywhere("ab", "ababababab"); // overlapping-ish, dense
    try expectAgreesEverywhere("xz", "no such pair anywhere in here at all");
    try expectAgreesEverywhere("the", "the theme of the theatre, the the the");
}

test "memmem: long needle (spans multiple chunks), boundaries" {
    const hay = "....................Sherlock Holmes...........Sherlock Holmes....";
    try expectAgreesEverywhere("Sherlock Holmes", hay);
    // needle right at the end (the binding load at i+hi must not overrun)
    try expectAgreesEverywhere("Holmes", "many words then finally Holmes");
    try expectAgreesEverywhere("end", "the very end");
    // a needle longer than one vector width
    const long = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ"; // > 32 bytes
    try expectAgreesEverywhere(long, "junk " ++ long ++ " trailing " ++ long);
}

test "memmem: repeated bytes / both probes the same value" {
    try expectAgreesEverywhere("aaaa", "baaaaab aa aaaa aaa");
    try expectAgreesEverywhere("....", "a...b....c.....d");
}

test "memmem: UTF-8 needle scans by bytes correctly" {
    try expectAgreesEverywhere("héllo", "say héllo, héllo again, hello (no accent)");
    try expectAgreesEverywhere("café", "le café, the cafe, un café noir");
    try expectAgreesEverywhere("Москва", "город Москва и снова Москва конец");
}

test "memmem: no-match and start-offset past matches" {
    const f = Finder.init("zzz");
    try testing.expectEqual(@as(?usize, null), f.find("aaa bbb ccc", 0));
    const g = Finder.init("ab");
    try testing.expectEqual(@as(?usize, 0), g.find("ab ab", 0));
    try testing.expectEqual(@as(?usize, 3), g.find("ab ab", 1));
    try testing.expectEqual(@as(?usize, null), g.find("ab ab", 4));
    try testing.expectEqual(@as(?usize, null), g.find("ab", 5)); // start past end
}

test "memmem: comptime evaluates via the scalar fallback (no @Vector in const-eval)" {
    const at = comptime blk: {
        const f = Finder.init("Holmes");
        break :blk f.find("Sherlock Holmes", 0);
    };
    try testing.expectEqual(@as(?usize, 9), at);
}

test "memmem: rare-byte choice picks two distinct in-bounds offsets" {
    const f = Finder.init("Sherlock");
    try testing.expect(f.lo < f.hi);
    try testing.expect(f.hi < "Sherlock".len);
    try testing.expectEqual("Sherlock"[f.lo], f.b_lo);
    try testing.expectEqual("Sherlock"[f.hi], f.b_hi);
}

test {
    testing.refAllDecls(@This());
}
