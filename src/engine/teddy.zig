//! `teddy` — a SIMD multi-literal prefilter (the Teddy algorithm).
//!
//! Teddy searches many short literals at once using a **dynamic in-vector byte
//! shuffle** (`simd.shuffle16`/`shuffle32`) as a nibble-indexed fingerprint lookup. It
//! is the accelerator behind a literal *alternation* (`foo|bar|baz`) and behind
//! `auto`'s multi-prefix start-skip — the cases the single-needle `memmem` cannot
//! vectorise well.
//!
//! ## How it works (slim, 8 buckets)
//!
//! Each literal is hashed into one of ≤8 **buckets**. For each fingerprint byte
//! position `p` (the first `n` bytes of every literal, `n ∈ 1..3`) two 16-entry tables
//! are built, indexed by a nibble:
//!
//!   * `lo[p][nibble]` — bitmask of buckets whose literal has `literal[p] & 0x0F == nibble`
//!   * `hi[p][nibble]` — bitmask of buckets whose literal has `literal[p] >> 4   == nibble`
//!
//! At search time, for a 16-byte input chunk `v`, one shuffle looks up the low-nibble
//! table by `v & 0x0F` and another the high-nibble table by `v >> 4`; their AND gives,
//! per lane, the buckets whose byte-`p` fingerprint matches the input there. With one
//! literal per bucket the per-bucket AND is an **exact** byte test (both nibbles belong
//! to the *same* literal), so false positives only arise when literals share a bucket —
//! and those are caught by the verify step. ANDing the `n` fingerprint positions
//! (aligned by a comptime shuffle, multi-byte case) yields candidate positions; each is
//! then verified against the actual literals in priority order.
//!
//! **Soundness:** the masks never drop a real match (if a literal matches at `i`, its
//! first `n` bytes match, so every fingerprint position is flagged) — Teddy only ever
//! produces *candidate* positions, which the verify step (or, in `auto`, the real
//! engine) confirms. False positives cost time, never correctness.
//!
//! ## Portability
//!
//! The only architecture-specific op is the dynamic shuffle in `simd.zig` (`pshufb`/
//! `vpshufb`/`tbl`); everything here — nibble split, the per-position carry alignment
//! (a comptime `@shuffle`), the candidate mask, verification — is portable `@Vector`.
//! At comptime and on unsupported targets the shuffle is the scalar fallback, so Teddy
//! stays correct everywhere; it is simply not selected as the *runtime* prefilter when
//! `simd.has_native_shuffle16` is false (that wiring lives in `auto`, a later layer).
//!
//! @stable-since: v0.4.0

const std = @import("std");

const simd = @import("simd.zig");
const backend = @import("backend.zig");

const Match = backend.Match;

/// Maximum fingerprint length (leading bytes tested in the vector step). Longer is more
/// selective but requires every literal be at least this long; 3 is the usual sweet spot.
pub const MAX_FINGERPRINT = 3;

/// Slim Teddy bucket count (one `u8` mask per lane). Fat Teddy (16 buckets, AVX2) is a
/// later layer; this module is the slim-128 base.
pub const SLIM_BUCKETS = 8;

/// One literal's slice into `needles`, plus the bucket it hashes to. `bounds` is kept in
/// **alternation (priority) order** so verification is leftmost-first like `literal.zig`.
pub const Bound = struct { start: u32, len: u32, bucket: u8 };

/// Leftmost-first match at exactly `pos`: the first literal (priority order) whose bytes
/// occur at `pos`, or null. Shared by the slim and fat searchers; mirrors `literal.zig`'s
/// `matchAtPos` so all three agree.
fn verifyNeedles(needles: []const u8, bounds: []const Bound, input: []const u8, pos: usize) ?Match {
    for (bounds) |b| {
        const needle = needles[b.start .. b.start + b.len];
        if (pos + needle.len <= input.len and std.mem.eql(u8, input[pos .. pos + needle.len], needle))
            return .{ .start = pos, .end = pos + needle.len };
    }
    return null;
}

/// A compiled Teddy matcher: the fingerprint mask tables (POD, so comptime-bakeable) plus
/// the literal bytes for verification. Built by `compileAlloc` (heap) or `compileComptime`
/// (ro_data). Search via `find`.
///
/// @stable-since: v0.4.0
pub const Teddy = struct {
    /// Fingerprint length actually used (`1..MAX_FINGERPRINT`), = min literal length capped.
    n: u8,
    /// Number of buckets in use (`1..SLIM_BUCKETS`).
    buckets: u8,
    /// Low-/high-nibble bucket-mask tables, one row per fingerprint position. Rows `>= n`
    /// are zero (unused). `lo[p][nibble]`/`hi[p][nibble]` per the module doc.
    lo: [MAX_FINGERPRINT][16]u8,
    hi: [MAX_FINGERPRINT][16]u8,
    /// Concatenated literal bytes; `bounds[k]` delimits literal `k` (priority order).
    needles: []const u8,
    bounds: []const Bound,

    fn loVec(self: *const Teddy, p: usize) @Vector(16, u8) {
        return self.lo[p];
    }
    fn hiVec(self: *const Teddy, p: usize) @Vector(16, u8) {
        return self.hi[p];
    }

    /// Leftmost-first match at exactly `pos`: the first literal (priority order) whose bytes
    /// occur at `pos`, or null.
    fn verifyAt(self: *const Teddy, input: []const u8, pos: usize) ?Match {
        return verifyNeedles(self.needles, self.bounds, input, pos);
    }

    /// First leftmost-first match at byte offset `>= start`, or null.
    ///
    /// Slim-128, **`n`-byte fingerprint** (`n ∈ 1..3`). Dispatches to the comptime-`n`
    /// kernel; see `findN`.
    ///
    /// @stable-since: v0.4.0
    pub fn find(self: *const Teddy, input: []const u8, start: usize) ?Match {
        if (start > input.len) return null;
        return switch (self.n) {
            1 => self.findN(1, input, start),
            2 => self.findN(2, input, start),
            3 => self.findN(3, input, start),
            else => unreachable, // fingerprintLen caps at MAX_FINGERPRINT (3)
        };
    }

    /// The comptime-`n` slim-128 kernel. Uses **overlapping windows with a within-chunk
    /// lower-lane shift**: a candidate START at lane `j` needs fingerprint byte `p` at lane
    /// `j+p` (`p < n`), so `res[j] = AND_p shiftLo(a_p, p)[j]` where `a_p` is the dynamic
    /// fingerprint shuffle for position `p`. Only lanes `0..=16-n` have all `n` bytes inside
    /// the loaded 16-byte window, so we keep `17-n` candidate lanes per window and step the
    /// base by exactly that — starts partition with **no gap and no overlap**, and no
    /// cross-chunk carry state is needed. The shift is a comptime `@shuffle` (portable); only
    /// the fingerprint lookup is the arch-specific `simd.shuffle16`. A scalar tail covers the
    /// final `< 16` bytes. Each flagged lane is verified left-to-right (leftmost-first), so a
    /// false positive (shared bucket) costs only a verify, never a missed/wrong match.
    fn findN(self: *const Teddy, comptime n: usize, input: []const u8, start: usize) ?Match {
        const lomask: @Vector(16, u8) = @splat(0x0F);
        const shift4: @Vector(16, u3) = @splat(4);
        const zero: @Vector(16, u8) = @splat(0);
        const valid_lanes: usize = 17 - n; // lanes 0..=16-n hold all n fingerprint bytes
        const lane_mask: u16 = if (valid_lanes >= 16) 0xFFFF else (@as(u16, 1) << @intCast(valid_lanes)) - 1;

        var rows_lo: [n]@Vector(16, u8) = undefined;
        var rows_hi: [n]@Vector(16, u8) = undefined;
        inline for (0..n) |p| {
            rows_lo[p] = self.loVec(p);
            rows_hi[p] = self.hiVec(p);
        }

        var i = start;
        // Vector body: only while a full 16-byte chunk is in bounds (never read past the slice).
        while (i + 16 <= input.len) : (i += valid_lanes) {
            const v: @Vector(16, u8) = input[i..][0..16].*;
            const vlo = v & lomask;
            const vhi = v >> shift4;
            var res: @Vector(16, u8) = @splat(0xFF); // AND identity
            inline for (0..n) |p| {
                const a_p = simd.shuffle16(rows_lo[p], vlo) & simd.shuffle16(rows_hi[p], vhi);
                res &= shiftLo(p, a_p);
            }
            var mask: u16 = @as(u16, @bitCast(res != zero)) & lane_mask;
            while (mask != 0) {
                const j = @ctz(mask);
                if (self.verifyAt(input, i + j)) |m| return m;
                mask &= mask - 1; // clear lowest set bit; advance to the next candidate lane
            }
        }
        // Scalar tail: the final < 16 bytes the vector body could not cover.
        while (i < input.len) : (i += 1) {
            if (self.verifyAt(input, i)) |m| return m;
        }
        return null;
    }
};

/// Shift a 16-lane vector toward LOWER lane index by a comptime `k`: result lane `j` takes
/// `v[j+k]` (the fingerprint byte `k` positions ahead), with lanes that would read past the
/// end filled with 0. Portable `@shuffle` (comptime mask) — this is the cross-lane alignment
/// that lets one loaded chunk test an `n`-byte fingerprint. `k == 0` is the identity.
fn shiftLo(comptime k: usize, v: @Vector(16, u8)) @Vector(16, u8) {
    if (k == 0) return v;
    const mask: @Vector(16, i32) = comptime blk: {
        var m: [16]i32 = undefined;
        for (0..16) |j| m[j] = if (j + k < 16) @as(i32, @intCast(j + k)) else -1; // -1 ⇒ b[0] = 0
        break :blk m;
    };
    const zero: @Vector(16, u8) = @splat(0);
    return @shuffle(u8, v, zero, mask);
}

// ── Compiler: literal set → Teddy ─────────────────────────────────────────────────

/// Whether Teddy can handle this literal set: at least one literal, none empty (an empty
/// literal matches everywhere — the caller handles that case directly). Bucketing handles
/// any count (sharing buckets when `> SLIM_BUCKETS`), so only the empty/zero cases decline.
///
/// @stable-since: v0.4.0
pub fn supports(needles: []const []const u8) bool {
    if (needles.len == 0) return false;
    for (needles) |nd| if (nd.len == 0) return false;
    return true;
}

/// Bucket a literal index: identity while they fit, else fold by modulo (sharing a bucket,
/// disambiguated at verify). Kept simple and deterministic (comptime-stable).
fn bucketOf(idx: usize, count: usize) u8 {
    if (count <= SLIM_BUCKETS) return @intCast(idx);
    return @intCast(idx % SLIM_BUCKETS);
}

/// Fingerprint length for a set: the shortest literal, capped at `MAX_FINGERPRINT`.
fn fingerprintLen(needles: []const []const u8) u8 {
    var m: usize = std.math.maxInt(usize);
    for (needles) |nd| m = @min(m, nd.len);
    return @intCast(@min(m, MAX_FINGERPRINT));
}

/// Fill the nibble mask tables (shared by the heap and comptime builders). `out_lo`/`out_hi`
/// must be zero-initialised; sets, for each literal and each fingerprint position `p < n`,
/// the literal's bucket bit in the low- and high-nibble rows.
fn buildMasks(needles: []const []const u8, n: u8, lo: *[MAX_FINGERPRINT][16]u8, hi: *[MAX_FINGERPRINT][16]u8) void {
    for (needles, 0..) |nd, idx| {
        const bit: u8 = @as(u8, 1) << @intCast(bucketOf(idx, needles.len));
        var p: usize = 0;
        while (p < n) : (p += 1) {
            const c = nd[p];
            lo[p][c & 0x0F] |= bit;
            hi[p][c >> 4] |= bit;
        }
    }
}

/// Compile a literal set into a heap-backed `Teddy` (free with `free`). Caller must have
/// checked `supports`. `needles` are copied, so the source may be freed after.
///
/// @stable-since: v0.4.0
pub fn compileAlloc(gpa: std.mem.Allocator, needles: []const []const u8) std.mem.Allocator.Error!Teddy {
    std.debug.assert(supports(needles));
    const n = fingerprintLen(needles);

    var total: usize = 0;
    for (needles) |nd| total += nd.len;
    const bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(bytes);
    const bounds = try gpa.alloc(Bound, needles.len);
    errdefer gpa.free(bounds);

    var off: u32 = 0;
    var max_bucket: u8 = 0;
    for (needles, 0..) |nd, idx| {
        @memcpy(bytes[off .. off + nd.len], nd);
        const bkt = bucketOf(idx, needles.len);
        max_bucket = @max(max_bucket, bkt);
        bounds[idx] = .{ .start = off, .len = @intCast(nd.len), .bucket = bkt };
        off += @intCast(nd.len);
    }

    var lo = std.mem.zeroes([MAX_FINGERPRINT][16]u8);
    var hi = std.mem.zeroes([MAX_FINGERPRINT][16]u8);
    buildMasks(needles, n, &lo, &hi);

    return .{
        .n = n,
        .buckets = max_bucket + 1,
        .lo = lo,
        .hi = hi,
        .needles = bytes,
        .bounds = bounds,
    };
}

/// @stable-since: v0.4.0
pub fn free(gpa: std.mem.Allocator, t: *Teddy) void {
    gpa.free(t.needles);
    gpa.free(t.bounds);
}

// ── Fat Teddy: 16 buckets via the AVX2 256-bit lane-split shuffle ──────────────────

/// Fat Teddy bucket count. Twice slim's — fewer collisions when literals are many, at the
/// cost of half the per-step input width (16 positions, not 32). AVX2 only; chosen by
/// `auto` (a later layer) over slim when `simd.has_native_shuffle32` AND the set is large.
pub const FAT_BUCKETS = 16;

/// Bucket a literal index into `num_buckets`: identity while they fit, else fold by modulo.
fn bucketOfN(idx: usize, count: usize, num_buckets: usize) u8 {
    if (count <= num_buckets) return @intCast(idx);
    return @intCast(idx % num_buckets);
}

/// A compiled **fat** Teddy matcher. The mask rows are 32-byte tables laid out as two
/// 128-bit halves: the **low** half (bytes `0..15`) holds the bucket-`0..7` masks indexed
/// by nibble, the **high** half (bytes `16..31`) holds the bucket-`8..15` masks. Feeding the
/// input nibbles duplicated into both 128-bit lanes, one `vpshufb` looks up buckets `0..7`
/// in lane 0 and `8..15` in lane 1 (the lane-split is the whole trick) — 16 buckets in one
/// instruction. Search via `find`.
///
/// @stable-since: v0.4.0
pub const FatTeddy = struct {
    n: u8,
    buckets: u8,
    /// 32-byte mask rows (low half = buckets 0..7, high half = buckets 8..15), per fingerprint
    /// position. Rows `>= n` are zero.
    lo: [MAX_FINGERPRINT][32]u8,
    hi: [MAX_FINGERPRINT][32]u8,
    needles: []const u8,
    bounds: []const Bound,

    fn loVec(self: *const FatTeddy, p: usize) @Vector(32, u8) {
        return self.lo[p];
    }
    fn hiVec(self: *const FatTeddy, p: usize) @Vector(32, u8) {
        return self.hi[p];
    }

    /// First leftmost-first match at byte offset `>= start`, or null. Same semantics as the
    /// slim `Teddy.find`; dispatches to the comptime-`n` kernel.
    ///
    /// @stable-since: v0.4.0
    pub fn find(self: *const FatTeddy, input: []const u8, start: usize) ?Match {
        if (start > input.len) return null;
        return switch (self.n) {
            1 => self.findN(1, input, start),
            2 => self.findN(2, input, start),
            3 => self.findN(3, input, start),
            else => unreachable,
        };
    }

    /// The comptime-`n` fat kernel. Like the slim kernel (overlapping windows, within-chunk
    /// lower-lane shift, `17-n` candidate lanes per window), but the input nibbles are
    /// **duplicated into both 128-bit lanes** so one `simd.shuffle32` resolves all 16 buckets;
    /// lane 0 of the result carries buckets `0..7`, lane 1 buckets `8..15`, so a position is a
    /// candidate when *either* lane is nonzero (`(m & 0xFFFF) | (m >> 16)`). Only the shuffle
    /// is arch-specific; the duplicate, shift, and combine are portable `@shuffle`/`@Vector`.
    fn findN(self: *const FatTeddy, comptime n: usize, input: []const u8, start: usize) ?Match {
        const lomask: @Vector(32, u8) = @splat(0x0F);
        const shift4: @Vector(32, u3) = @splat(4);
        const zero: @Vector(32, u8) = @splat(0);
        const valid_lanes: usize = 17 - n; // input positions 0..=16-n hold all n fingerprint bytes
        const lane_mask: u16 = if (valid_lanes >= 16) 0xFFFF else (@as(u16, 1) << @intCast(valid_lanes)) - 1;

        var rows_lo: [n]@Vector(32, u8) = undefined;
        var rows_hi: [n]@Vector(32, u8) = undefined;
        inline for (0..n) |p| {
            rows_lo[p] = self.loVec(p);
            rows_hi[p] = self.hiVec(p);
        }

        var i = start;
        while (i + 16 <= input.len) : (i += valid_lanes) {
            const v16: @Vector(16, u8) = input[i..][0..16].*;
            const dv = dup16to32(v16); // both 128-bit lanes = the same 16 input bytes
            const vlo = dv & lomask;
            const vhi = dv >> shift4;
            var res: @Vector(32, u8) = @splat(0xFF);
            inline for (0..n) |p| {
                const a_p = simd.shuffle32(rows_lo[p], vlo) & simd.shuffle32(rows_hi[p], vhi);
                res &= shiftLo32(p, a_p);
            }
            const m32: u32 = @bitCast(res != zero);
            // Position j is a candidate if its low-bucket lane (bit j) OR high-bucket lane
            // (bit 16+j) is set.
            var mask: u16 = @intCast((m32 & 0xFFFF) | ((m32 >> 16) & 0xFFFF));
            mask &= lane_mask;
            while (mask != 0) {
                const j = @ctz(mask);
                if (verifyNeedles(self.needles, self.bounds, input, i + j)) |m| return m;
                mask &= mask - 1;
            }
        }
        while (i < input.len) : (i += 1) {
            if (verifyNeedles(self.needles, self.bounds, input, i)) |m| return m;
        }
        return null;
    }
};

/// Duplicate a 16-byte vector into both 128-bit lanes of a 32-byte vector (portable
/// comptime `@shuffle`). Fat Teddy feeds the same 16 input bytes to both lanes so the one
/// `vpshufb` resolves the low- and high-bucket halves of the same positions.
fn dup16to32(v: @Vector(16, u8)) @Vector(32, u8) {
    const mask: @Vector(32, i32) = comptime blk: {
        var m: [32]i32 = undefined;
        for (0..32) |j| m[j] = @intCast(j % 16);
        break :blk m;
    };
    return @shuffle(u8, v, v, mask);
}

/// `shiftLo` for a 32-byte vector with **per-128-bit-lane** semantics: each lane shifts
/// toward lower index by `k` independently (so the duplicated halves stay aligned), filling
/// past-end lanes with 0. Portable comptime `@shuffle`. `k == 0` is the identity.
fn shiftLo32(comptime k: usize, v: @Vector(32, u8)) @Vector(32, u8) {
    if (k == 0) return v;
    const mask: @Vector(32, i32) = comptime blk: {
        var m: [32]i32 = undefined;
        for (0..2) |lane| {
            for (0..16) |j| {
                const o = lane * 16 + j;
                m[o] = if (j + k < 16) @as(i32, @intCast(lane * 16 + j + k)) else -1; // -1 ⇒ b[0] = 0
            }
        }
        break :blk m;
    };
    const zero: @Vector(32, u8) = @splat(0);
    return @shuffle(u8, v, zero, mask);
}

/// Fill the fat nibble mask tables. A bucket `b` sets bit `b%8` in the **half** `b/8` (low
/// half for buckets 0..7, high half for 8..15) of the low- and high-nibble rows.
fn buildMasksFat(needles: []const []const u8, n: u8, lo: *[MAX_FINGERPRINT][32]u8, hi: *[MAX_FINGERPRINT][32]u8) void {
    for (needles, 0..) |nd, idx| {
        const bkt = bucketOfN(idx, needles.len, FAT_BUCKETS);
        const half: usize = @as(usize, bkt / 8) * 16; // 0 (buckets 0..7) or 16 (buckets 8..15)
        const bit: u8 = @as(u8, 1) << @intCast(bkt % 8);
        var p: usize = 0;
        while (p < n) : (p += 1) {
            const c = nd[p];
            lo[p][half + (c & 0x0F)] |= bit;
            hi[p][half + (c >> 4)] |= bit;
        }
    }
}

/// Compile a literal set into a heap-backed `FatTeddy` (free with `freeFat`). Caller must
/// have checked `supports`. `needles` are copied.
///
/// @stable-since: v0.4.0
pub fn compileFatAlloc(gpa: std.mem.Allocator, needles: []const []const u8) std.mem.Allocator.Error!FatTeddy {
    std.debug.assert(supports(needles));
    const n = fingerprintLen(needles);

    var total: usize = 0;
    for (needles) |nd| total += nd.len;
    const bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(bytes);
    const bounds = try gpa.alloc(Bound, needles.len);
    errdefer gpa.free(bounds);

    var off: u32 = 0;
    var max_bucket: u8 = 0;
    for (needles, 0..) |nd, idx| {
        @memcpy(bytes[off .. off + nd.len], nd);
        const bkt = bucketOfN(idx, needles.len, FAT_BUCKETS);
        max_bucket = @max(max_bucket, bkt);
        bounds[idx] = .{ .start = off, .len = @intCast(nd.len), .bucket = bkt };
        off += @intCast(nd.len);
    }

    var lo = std.mem.zeroes([MAX_FINGERPRINT][32]u8);
    var hi = std.mem.zeroes([MAX_FINGERPRINT][32]u8);
    buildMasksFat(needles, n, &lo, &hi);

    return .{
        .n = n,
        .buckets = max_bucket + 1,
        .lo = lo,
        .hi = hi,
        .needles = bytes,
        .bounds = bounds,
    };
}

/// @stable-since: v0.4.0
pub fn freeFat(gpa: std.mem.Allocator, t: *FatTeddy) void {
    gpa.free(t.needles);
    gpa.free(t.bounds);
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Reference leftmost-first multi-literal scan (the semantics `literal.zig` implements),
/// used to differentially validate `Teddy.find`. Plain, obviously correct, no SIMD.
fn refFind(needles: []const []const u8, input: []const u8, start: usize) ?Match {
    var i = start;
    while (i <= input.len) : (i += 1) {
        for (needles) |nd| {
            if (i + nd.len <= input.len and std.mem.eql(u8, input[i .. i + nd.len], nd))
                return .{ .start = i, .end = i + nd.len };
        }
    }
    return null;
}

/// Assert Teddy agrees with the reference at every start offset over `input` (so it pins
/// leftmost-first AND every interior position — chunk boundaries, tail, overlaps).
fn expectAgreesEverywhere(needles: []const []const u8, input: []const u8) !void {
    var t = try compileAlloc(testing.allocator, needles);
    defer free(testing.allocator, &t);
    var s: usize = 0;
    while (s <= input.len) : (s += 1) {
        const got = t.find(input, s);
        const want = refFind(needles, input, s);
        if (want) |w| {
            try testing.expect(got != null);
            try testing.expectEqual(w.start, got.?.start);
            try testing.expectEqual(w.end, got.?.end);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "teddy: single literal across chunk boundaries and tail" {
    const set = [_][]const u8{"abc"};
    try expectAgreesEverywhere(&set, "abc");
    try expectAgreesEverywhere(&set, "xxabcyy");
    // Force matches at lane 15/16/17 (chunk boundary) and in the scalar tail.
    try expectAgreesEverywhere(&set, "0123456789abcdeabcfghijklmnopqrstuvwxyzabc");
    try expectAgreesEverywhere(&set, "................abc"); // match starts exactly at offset 16
    try expectAgreesEverywhere(&set, "no match here at all, none whatsoever, nope");
}

test "teddy: alternation is leftmost-first with priority ties" {
    const set = [_][]const u8{ "cat", "dog" };
    try expectAgreesEverywhere(&set, "i have a dog and a cat");
    try expectAgreesEverywhere(&set, "cat and dog");
    // Priority: earlier-listed branch wins at the same position.
    const pri = [_][]const u8{ "ab", "abc" };
    try expectAgreesEverywhere(&pri, "abc");
    const pri2 = [_][]const u8{ "abc", "ab" };
    try expectAgreesEverywhere(&pri2, "abc");
}

test "teddy: shared first byte (bucket precision) and many buckets" {
    // Same first byte 'f' across branches — the per-bucket AND must keep them distinct.
    const shared = [_][]const u8{ "foo", "far", "fizz" };
    try expectAgreesEverywhere(&shared, "the foo and the far in the fizz buzz foofar");
    // > 8 needles ⇒ buckets are shared (folded by modulo); verify disambiguates.
    const many = [_][]const u8{ "aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj", "kk" };
    try expectAgreesEverywhere(&many, "zzkkzzaazzjjzziizzbbzzhhzzccz dd ee ff gg");
}

test "teddy: multi-byte UTF-8 literals (byte-scan soundness)" {
    const set = [_][]const u8{ "héllo", "café" };
    try expectAgreesEverywhere(&set, "say héllo at the café please");
    try expectAgreesEverywhere(&set, "cafécafé héllo");
}

test "teddy: short inputs (all scalar tail, no full chunk)" {
    const set = [_][]const u8{ "ab", "xy" };
    try expectAgreesEverywhere(&set, "");
    try expectAgreesEverywhere(&set, "a");
    try expectAgreesEverywhere(&set, "ab");
    try expectAgreesEverywhere(&set, "zxy");
    try expectAgreesEverywhere(&set, "123456789012345"); // 15 bytes, no match
}

test "teddy: no false negatives on a dense near-miss input" {
    // Lots of first-byte hits that do NOT complete — stresses verify rejecting candidates.
    const set = [_][]const u8{"abcd"};
    try expectAgreesEverywhere(&set, "aaaaaaaaaaaaaaaaaaaaaaaaabcdaaaaaaaaaaaaaaaa");
    try expectAgreesEverywhere(&set, "abababababababababababababababababcdabababab");
}

// ── Fat Teddy tests (validate the lane-split algorithm; on arm64 these exercise the ──
// ── scalar `shuffle32` that models AVX2 `vpshufb` exactly, so a green run here means ──
// ── the vpshufb path is correct too — QEMU only confirms the instruction == model). ──

/// As `expectAgreesEverywhere`, but for the fat (16-bucket) searcher.
fn expectFatAgreesEverywhere(needles: []const []const u8, input: []const u8) !void {
    var t = try compileFatAlloc(testing.allocator, needles);
    defer freeFat(testing.allocator, &t);
    var s: usize = 0;
    while (s <= input.len) : (s += 1) {
        const got = t.find(input, s);
        const want = refFind(needles, input, s);
        if (want) |w| {
            try testing.expect(got != null);
            try testing.expectEqual(w.start, got.?.start);
            try testing.expectEqual(w.end, got.?.end);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "fat teddy: single + alternation, boundaries, priority (parity with slim)" {
    const one = [_][]const u8{"abc"};
    try expectFatAgreesEverywhere(&one, "0123456789abcdeabcfghijklmnopqrstuvwxyzabc");
    try expectFatAgreesEverywhere(&one, "................abc"); // match at offset 16
    const alt = [_][]const u8{ "cat", "dog" };
    try expectFatAgreesEverywhere(&alt, "i have a dog and a cat");
    const pri = [_][]const u8{ "ab", "abc" };
    try expectFatAgreesEverywhere(&pri, "abc");
}

test "fat teddy: 9..16 literals are EXACT (one per bucket — slim would collide)" {
    // 13 distinct 2-byte literals: > slim's 8 buckets (would share), <= fat's 16 (one each).
    const set = [_][]const u8{ "aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj", "kk", "ll", "mm" };
    try expectFatAgreesEverywhere(&set, "zz ll zz aa zz mm zz ii zz bb hh cc dd ee ff gg jj kk");
    try expectFatAgreesEverywhere(&set, "nothing matches in this haystack at all, nope nope");
}

test "fat teddy: > 16 literals (buckets fold; verify disambiguates)" {
    const set = [_][]const u8{
        "aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii",
        "jj", "kk", "ll", "mm", "nn", "oo", "pp", "qq", "rr",
    }; // 18 > FAT_BUCKETS
    try expectFatAgreesEverywhere(&set, "xx rr xx qq xx aa pp bb oo cc nn dd mm ee ll ff kk gg");
}

test "fat teddy: shared first byte, multi-byte UTF-8, short inputs" {
    const shared = [_][]const u8{ "foo", "far", "fizz", "fun", "fab" };
    try expectFatAgreesEverywhere(&shared, "the foo and far fun in the fizz fab buzz foofar");
    const uni = [_][]const u8{ "héllo", "café" };
    try expectFatAgreesEverywhere(&uni, "say héllo at the café please");
    const short = [_][]const u8{ "ab", "xy" };
    try expectFatAgreesEverywhere(&short, "");
    try expectFatAgreesEverywhere(&short, "zxy");
    try expectFatAgreesEverywhere(&short, "123456789012345"); // 15 bytes, no match
}

test "fat teddy: dense near-miss (verify rejects candidates, no false negatives)" {
    const set = [_][]const u8{"abcd"};
    try expectFatAgreesEverywhere(&set, "aaaaaaaaaaaaaaaaaaaaaaaaabcdaaaaaaaaaaaaaaaa");
    try expectFatAgreesEverywhere(&set, "abababababababababababababababababcdabababab");
}

test {
    testing.refAllDecls(@This());
}
