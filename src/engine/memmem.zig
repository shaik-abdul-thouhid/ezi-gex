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
const simd = @import("simd.zig");

/// Portable vector width: 256-bit on AVX2 (one `vpcmpeqb`/`vpmovmskb` over 32 starts),
/// else 128-bit. Wider on AVX2 only — NEON has no 256-bit register and no cheap 32-lane
/// movemask, so 16 lowers better there.
pub const W: usize = if (builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16;

const V = @Vector(W, u8);
/// Movemask integer: one bit per vector lane (`@bitCast` of a `@Vector(W, bool)`).
const Mask = if (W == 32) u32 else u16;

/// Product of the two rarest probe-byte frequencies (`freq[b_lo] · freq[b_hi]`) at or above
/// which a third probe is added on a needle of length ≥ 3. Tuned (on the rebar Sherlock suite)
/// so only an *all-common* pair whose two-probe candidate density is genuinely punishing
/// (`the` → `t`·`h` = 25500) crosses it; a merely moderate pair (`The` → `T`·`h` = 13200,
/// `Holmes` → `H`·`m` = 8584, `Sherlock` → `S`·`k` = 4290) stays on the cheaper two-probe scan,
/// where the third probe's per-chunk load costs more than the candidates it removes.
/// Speed-only; never affects results.
const THREE_PROBE_MIN_DENSITY: u32 = 18000;

/// Single-width chunks scanned before `find2` escalates to the 4× unrolled bulk loop. Bounds the
/// wasted work for a dense-match needle (which returns inside the head — `HEAD_CHUNKS·W` bytes is
/// sized to cover typical dense inter-match gaps, e.g. `ing` every ~100–200 B) while a sparse /
/// no-match scan pays only this short single-width prefix before reaching the unroll. Speed-only.
const HEAD_CHUNKS: usize = 16;

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

/// A precomputed multi-byte filter for one needle (length ≥ `MIN_LEN`). `needle` aliases the
/// caller's storage (the `literal` program's `needles` buffer) — it owns no memory, so there
/// is nothing to free. `lo`/`hi` (with `lo < hi`) are the two rarest probed needle offsets and
/// `b_lo`/`b_hi` their bytes; on a needle of length ≥ 3 a **third** probe (`mid`/`b_mid`) is
/// added, chosen once at `init` to drive candidate density still lower.
///
/// **Why a third probe.** Candidate density is ≈ `∏ f(probe)/256` per lane: with only two
/// probes a literal whose rarest byte is still common (`Sherlock` → `S`) leaves a candidate in
/// most 16-byte chunks, so on a target without a one-instruction movemask (NEON) nearly every
/// chunk pays the emulated `@bitCast` extraction *and* a verify. A third rare byte multiplies
/// the density down, so far fewer chunks reach the expensive path. When the probes already
/// cover the **whole** needle (`full`, e.g. a 3-byte `the`), every surviving candidate is a
/// guaranteed match and the verify is skipped entirely.
///
/// @stable-since: v0.4.0
pub const Finder = struct {
    needle: []const u8,
    lo: u32,
    hi: u32,
    mid: u32,
    b_lo: u8,
    b_hi: u8,
    b_mid: u8,
    /// Whether the third probe is live (needle length ≥ 3).
    three: bool,
    /// The probes cover every needle byte (`probe count == needle.len`) — a surviving
    /// candidate is then a match with no verify needed. True only for length-2/3 needles.
    full: bool,

    /// Pick the rarest-byte offsets (two, plus a third on a needle ≥ 3 long) and cache them.
    /// Caller guarantees `needle.len >= MIN_LEN`.
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
        // Third probe: the rarest of the remaining offsets (needle ≥ 3). It is engaged **only**
        // when the two rarest bytes are themselves common enough that the two-probe filter would
        // leave a candidate in most chunks (`f(b_lo)·f(b_hi) ≥ THREE_PROBE_MIN_DENSITY`, e.g.
        // `the`, `The`). For a needle whose pair is already selective (`Sherlock` → `S`·`k`,
        // `zqj`) the extra per-chunk load/compare costs more than the candidates it removes, so
        // the two-probe path is kept. Unused → `three == false`; `mid` parks on `lo` so bounds
        // math stays valid.
        var three = false;
        var oc: usize = lo;
        if (needle.len >= 3 and
            @as(u32, freq[needle[lo]]) * @as(u32, freq[needle[hi]]) >= THREE_PROBE_MIN_DENSITY)
        {
            oc = if (oa == 0 or ob == 0) (if (oa == 1 or ob == 1) 2 else 1) else 0;
            k = 0;
            while (k < needle.len) : (k += 1) {
                if (k == oa or k == ob) continue;
                if (freq[needle[k]] < freq[needle[oc]]) oc = k;
            }
            three = true;
        }
        return .{
            .needle = needle,
            .lo = @intCast(lo),
            .hi = @intCast(hi),
            .mid = @intCast(oc),
            .b_lo = needle[lo],
            .b_hi = needle[hi],
            .b_mid = needle[oc],
            .three = three,
            .full = (if (three) @as(usize, 3) else 2) == needle.len,
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
        if (self.three) return self.find3(input, start);
        return self.find2(input, start);
    }

    /// Two-probe SIMD scan (needle length 2, or the third probe declined).
    fn find2(self: *const Finder, input: []const u8, start: usize) ?usize {
        const lo: usize = self.lo;
        const hi: usize = self.hi;
        const vlo: V = @splat(self.b_lo);
        const vhi: V = @splat(self.b_hi);

        var i: usize = start;
        // The chunk probes starts i..i+W-1 at offsets lo and hi; the binding load is at
        // i+hi, so it stays in bounds while i + hi + W <= input.len.
        //
        // **Adaptive head → 4× bulk → tail.** The wide 4× unroll (below) is a big win when the
        // scan runs *far* before a match (rare-pair literals, no-match): four independent 16-byte
        // windows per iteration overlap their compare chains and amortize loop bookkeeping ~4×,
        // bringing a NEON literal scan to Rust parity without any per-architecture code. But when
        // matches are *dense* (e.g. `ing`, hit every ~100 B) each `find` returns almost
        // immediately, and eagerly computing a full 64-byte group is wasted work — a regression.
        // So scan a short HEAD single-width first (cheap early return for the dense case) and only
        // escalate to the 4× bulk once the scan has gone HEAD·W bytes without a match (the sparse
        // case that the unroll is for). A single-width tail mops up the < 4W remainder.
        if (input.len >= hi + W) {
            const max_i1 = input.len - hi - W;
            const head_end = @min(max_i1, start +| HEAD_CHUNKS * W);
            while (i <= head_end) : (i += W) {
                if (self.probeOne(input, i, vlo, vhi)) |c| return c;
            }
        }
        if (input.len >= hi + 4 * W) {
            const max_i4 = input.len - hi - 4 * W;
            const f: @Vector(W, bool) = @splat(false);
            const t: @Vector(W, bool) = @splat(true);
            while (i <= max_i4) : (i += 4 * W) {
                var m: [4]@Vector(W, bool) = undefined;
                inline for (0..4) |k| {
                    const a: V = input[i + lo + k * W ..][0..W].*;
                    const b: V = input[i + hi + k * W ..][0..W].*;
                    m[k] = @select(bool, a == vlo, b == vhi, f);
                }
                if (comptime !simd.cheap_movemask) {
                    // One `umaxv` over the OR of all four masks skips the emulated movemask for the
                    // (overwhelmingly common) all-empty group.
                    const any = @select(bool, m[0], t, @select(bool, m[1], t, @select(bool, m[2], t, m[3])));
                    if (!@reduce(.Or, any)) continue;
                }
                inline for (0..4) |k| {
                    if (self.scanBits(@bitCast(m[k]), input, i + k * W)) |c| return c;
                }
            }
        }
        // Single-window pass for the rest (≤ 4W-1 trailing bytes the bulk loop skipped).
        if (input.len >= hi + W) {
            const max_i = input.len - hi - W;
            while (i <= max_i) : (i += W) {
                if (self.probeOne(input, i, vlo, vhi)) |c| return c;
            }
        }
        return self.scalarFrom(input, i);
    }

    /// One two-probe 16-byte window at `i`: returns a confirmed match in `[i, i+W)` or null
    /// (no candidate, or candidates that failed verify — caller advances). `vlo`/`vhi` are the
    /// caller's hoisted probe-byte broadcasts.
    inline fn probeOne(self: *const Finder, input: []const u8, i: usize, vlo: V, vhi: V) ?usize {
        const wa: V = input[i + self.lo ..][0..W].*;
        const wb: V = input[i + self.hi ..][0..W].*;
        const both = @select(bool, wa == vlo, wb == vhi, @as(@Vector(W, bool), @splat(false)));
        if (comptime !simd.cheap_movemask) {
            if (!@reduce(.Or, both)) return null;
        }
        return self.scanBits(@bitCast(both), input, i);
    }

    /// Verify each candidate lane in `bits` (a movemask over a window starting at `base`),
    /// lowest lane first; return the leftmost confirmed match or null.
    inline fn scanBits(self: *const Finder, bits_in: Mask, input: []const u8, base: usize) ?usize {
        const n = self.needle.len;
        var bits = bits_in;
        while (bits != 0) {
            const j: usize = @ctz(bits);
            const cand = base + j;
            if (cand + n <= input.len and std.mem.eql(u8, input[cand..][0..n], self.needle))
                return cand;
            bits &= bits - 1; // clear lowest set bit
        }
        return null;
    }

    /// Three-probe SIMD scan (needle length ≥ 3): a third rare byte cuts candidate density,
    /// so fewer chunks reach the `@bitCast`/verify path. When `full` the probes cover every
    /// needle byte, so a surviving candidate is a match and the verify is elided.
    fn find3(self: *const Finder, input: []const u8, start: usize) ?usize {
        const n = self.needle.len;
        const lo: usize = self.lo;
        const hi: usize = self.hi;
        const mid: usize = self.mid;
        const vlo: V = @splat(self.b_lo);
        const vhi: V = @splat(self.b_hi);
        const vmid: V = @splat(self.b_mid);
        // Binding (largest) probe offset; `mid` may sit before, between, or after lo/hi.
        const top = @max(hi, mid);

        var i: usize = start;
        if (input.len >= top + W) {
            const max_i = input.len - top - W;
            while (i <= max_i) : (i += W) {
                const wa: V = input[i + lo ..][0..W].*;
                const wb: V = input[i + hi ..][0..W].*;
                const wc: V = input[i + mid ..][0..W].*;
                // Candidate lanes: all three probe bytes coincide, ANDed in the bool domain
                // for a single movemask.
                const ab = @select(bool, wa == vlo, wb == vhi, @as(@Vector(W, bool), @splat(false)));
                const all = @select(bool, ab, wc == vmid, @as(@Vector(W, bool), @splat(false)));
                if (comptime !simd.cheap_movemask) {
                    if (!@reduce(.Or, all)) continue;
                }
                var bits: Mask = @bitCast(all);
                while (bits != 0) {
                    const j: usize = @ctz(bits);
                    const cand = i + j;
                    if (cand + n <= input.len and (self.full or std.mem.eql(u8, input[cand..][0..n], self.needle)))
                        return cand;
                    bits &= bits - 1; // clear lowest set bit
                }
            }
        }
        return self.scalarFrom(input, i);
    }

    /// Scalar filter + verify, from `from` to the end. The SIMD tail and the comptime path
    /// share it; on its own it is a correct (if unvectorised) `find`. Applies the third probe
    /// when live; `full` elides the verify exactly as the SIMD paths do.
    fn scalarFrom(self: *const Finder, input: []const u8, from: usize) ?usize {
        const n = self.needle.len;
        const lo: usize = self.lo;
        const hi: usize = self.hi;
        const mid: usize = self.mid;
        var p = from;
        while (p + n <= input.len) : (p += 1) {
            if (input[p + lo] == self.b_lo and input[p + hi] == self.b_hi and
                (!self.three or input[p + mid] == self.b_mid) and
                (self.full or std.mem.eql(u8, input[p..][0..n], self.needle))) return p;
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

test "memmem: sparse matches over many full vector chunks (empty-chunk gate branch)" {
    // A long haystack of empty (no-probe-hit) chunks with the needle only at the very end,
    // and a wholly-no-match variant. On NEON targets these drive the `@reduce(.Or) == false`
    // continue branch added to skip the emulated movemask; on x86 they take the direct path.
    // Either way the result must equal the scalar oracle at every start offset.
    // ~130 B of prose containing neither 'Q' nor 'z' (the two probe bytes of "Quartz"),
    // so every 16-byte chunk over it is empty and takes the gate's skip branch.
    const filler = "the brown fox jumps over the idle dog, the cat sat on the mat by the river bank as the sun set behind the far green hills late today";
    try expectAgreesEverywhere("Quartz", filler ++ "Quartz" ++ filler);
    try expectAgreesEverywhere("Quartz", filler ++ filler); // never matches: all chunks empty
    // dense-then-sparse seam: many hits then a long empty tail
    try expectAgreesEverywhere(" in", "in in in in in in in in in in in in" ++ filler);
}

test "memmem: three-probe path (dense all-common needle) agrees everywhere" {
    // `the`/`ent`/`ing` pick an all-common rarest pair, so init engages the third probe
    // (`three == true`); for a 3-byte needle the probes cover every byte (`full == true`) and
    // the verify is elided. The differential must still hold at every start offset, including
    // overlaps, the SIMD/scalar seam, and a wholly-absent needle.
    try testing.expect(Finder.init("the").three);
    try testing.expect(Finder.init("the").full);
    const prose = "the theatre, then the other mother gathered the weather; nothing further the the the.";
    try expectAgreesEverywhere("the", prose);
    try expectAgreesEverywhere("ent", "the entrance entrenched entirely, no parent present, entity sent.");
    // a longer (≥4) all-common needle: three probes but NOT full-cover, so the verify still runs
    const f4 = Finder.init("ther");
    try testing.expect(f4.three and !f4.full);
    try expectAgreesEverywhere("ther", "the other mother, weather or whether, gather together there.");
}

test "memmem: 4x-unroll seam — matches straddling the unroll/tail boundary" {
    // Drive needles across the `4*W` unroll stride and the single-window tail so a match can land
    // in any of the four unrolled windows or the trailing tail. Long filler of bytes that never
    // hit the probe pair keeps most window groups empty (the OR-gate skip branch), then the
    // needle appears at staggered offsets spanning the 4W boundary.
    const filler = "qqqqqqqq wwwwwwww qqqqqqqq wwwwwwww qqqqqqqq wwwwwwww qqqqqqqq wwwwwwww qqqqqqqq wwwwwwww"; // no 'S','k', > 4W
    var buf: [256]u8 = undefined;
    var off: usize = 0;
    while (off < 80) : (off += 1) {
        const pad = filler[0..off];
        const hay = std.fmt.bufPrint(&buf, "{s}Sherlock and {s}Sherlock end", .{ pad, filler }) catch unreachable;
        try expectAgreesEverywhere("Sherlock", hay);
    }
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
