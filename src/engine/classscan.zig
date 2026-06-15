//! `classscan` — a portable SIMD scan for "the next byte in a set".
//!
//! The byte-set counterpart to `memmem` (single literal) and `teddy` (literal
//! alternation): given a 256-bit set of bytes, find the first input position whose
//! byte is a member. It is the **leading-class start-skip** the `auto` dispatcher uses
//! for a class-led pattern with no fixed leading literal (`\d+`, `\d{4}-\d{2}-\d{2}`,
//! `\p{N}+`): every match begins with a byte in the leading class's first-byte set, so
//! the leftmost member is a sound lower bound on where a match can begin. Vectorising
//! that skip is what closes the gap to Rust on a sparse class scan — the DFA only ever
//! runs on the actual class runs instead of crawling the gaps one byte at a time.
//!
//! ## How it works (one-bucket nibble classifier)
//!
//! Membership is tested with the same nibble-indexed dynamic shuffle Teddy uses, but
//! with a *single* bucket. Two 16-entry tables are built from the set:
//!
//!   * `lo[n]` bit 0 set ⇔ some set member has low nibble `b & 0x0F == n`
//!   * `hi[n]` bit 0 set ⇔ some set member has high nibble `b >> 4   == n`
//!
//! For a 16-byte chunk, `shuffle16(lo, v & 0x0F) & shuffle16(hi, v >> 4)` is nonzero in
//! lane `j` exactly when both nibbles of `v[j]` belong to *some* set member — a sound
//! **superset** of membership (a present byte always survives; a non-member may also
//! survive when its two nibbles come from two different members). Each surviving lane is
//! then confirmed against the exact bitset (`has`), so the result is exact: no false
//! negatives (soundness), and false positives cost only a bitset test.
//!
//! ## Portability
//!
//! The only arch-specific op is `simd.shuffle16` (already quarantined in `simd.zig`);
//! everything else is portable `@Vector`. At comptime, and on a target without a native
//! shuffle, `find` uses the plain scalar bitset scan (the native shuffle would otherwise
//! be a scalar emulation slower than a direct `has` loop), so the type is correct
//! everywhere and is simply not vectorised there.
//!
//! @stable-since: v0.4.0

const std = @import("std");

const simd = @import("simd.zig");

/// A compiled byte-set finder: the exact 256-bit membership plus the nibble classifier
/// tables. POD (no pointers), so it bakes into `ro_data` at comptime and needs no
/// allocation. Build with `init`; search with `find`.
///
/// @stable-since: v0.4.0
pub const ClassFinder = struct {
    /// 256-bit membership: byte `b` is in the set iff bit `b & 63` of word `b >> 6` is
    /// set (the `hir.ByteSet` layout, so `auto` passes `class_lead.bits` straight in).
    present: [4]u64,
    /// Low-/high-nibble classifier tables (one bucket → bit 0). `lo[n]`/`hi[n]` per the
    /// module doc.
    lo: [16]u8,
    hi: [16]u8,

    /// Build the classifier from a 256-bit membership word array (`hir.ByteSet.bits`).
    /// Pure scalar table fill — no `@Vector` — so it is usable at comptime and runtime.
    ///
    /// @stable-since: v0.4.0
    pub fn init(present: [4]u64) ClassFinder {
        var lo = std.mem.zeroes([16]u8);
        var hi = std.mem.zeroes([16]u8);
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            if ((present[b >> 6] >> @truncate(b)) & 1 != 0) {
                lo[b & 0x0F] |= 1;
                hi[b >> 4] |= 1;
            }
        }
        return .{ .present = present, .lo = lo, .hi = hi };
    }

    /// Whether byte `b` is in the set (the exact membership test).
    inline fn has(self: *const ClassFinder, b: u8) bool {
        return (self.present[b >> 6] >> @truncate(b)) & 1 != 0;
    }

    /// First offset `≥ start` whose byte is in the set, or null. Leftmost (lanes are
    /// scanned low→high, `@ctz` takes the lowest within a chunk). SIMD on a native-shuffle
    /// target; the plain `has` scan at comptime and elsewhere.
    ///
    /// @stable-since: v0.4.0
    pub fn find(self: *const ClassFinder, input: []const u8, start: usize) ?usize {
        if (start >= input.len) return null;
        if (@inComptime() or comptime !simd.has_native_shuffle16) return self.scalarFrom(input, start);

        const lomask: @Vector(16, u8) = @splat(0x0F);
        const shift4: @Vector(16, u3) = @splat(4);
        const zero: @Vector(16, u8) = @splat(0);
        const lo_tab: @Vector(16, u8) = self.lo;
        const hi_tab: @Vector(16, u8) = self.hi;

        var i: usize = start;
        while (i + 16 <= input.len) : (i += 16) {
            const v: @Vector(16, u8) = input[i..][0..16].*;
            const a = simd.shuffle16(lo_tab, v & lomask) & simd.shuffle16(hi_tab, v >> shift4);
            var mask: u16 = @bitCast(a != zero);
            while (mask != 0) {
                const j = @ctz(mask);
                if (self.has(input[i + j])) return i + j; // exact confirm (superset → exact)
                mask &= mask - 1; // clear lowest set bit; advance to the next candidate lane
            }
        }
        return self.scalarFrom(input, i);
    }

    /// Scalar membership scan from `from` to the end. The SIMD tail and the comptime /
    /// no-native-shuffle path share it; on its own it is a correct (unvectorised) `find`.
    fn scalarFrom(self: *const ClassFinder, input: []const u8, from: usize) ?usize {
        var p = from;
        while (p < input.len) : (p += 1) {
            if (self.has(input[p])) return p;
        }
        return null;
    }
};

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Build a `present` word array from an explicit list of member bytes (test helper).
fn setOf(bytes: []const u8) [4]u64 {
    var p = std.mem.zeroes([4]u64);
    for (bytes) |b| p[b >> 6] |= @as(u64, 1) << @truncate(b);
    return p;
}

/// Build `present` for a contiguous inclusive byte range (test helper).
fn rangeSet(lo: u8, hi: u8) [4]u64 {
    var p = std.mem.zeroes([4]u64);
    var b: u16 = lo;
    while (b <= hi) : (b += 1) p[b >> 6] |= @as(u64, 1) << @truncate(@as(u8, @intCast(b)));
    return p;
}

/// Trivial leftmost-from-`start` reference scan over the membership; the differential oracle.
fn refFind(present: [4]u64, input: []const u8, start: usize) ?usize {
    var p = start;
    while (p < input.len) : (p += 1) {
        const b = input[p];
        if ((present[b >> 6] >> @truncate(b)) & 1 != 0) return p;
    }
    return null;
}

/// The crux property: at *every* start offset the finder agrees with the reference scan —
/// pins leftmost-first, the SIMD/scalar-tail seam, chunk boundaries, and the no-match tail.
fn expectAgreesEverywhere(present: [4]u64, input: []const u8) !void {
    const f = ClassFinder.init(present);
    var s: usize = 0;
    while (s <= input.len) : (s += 1) {
        try testing.expectEqual(refFind(present, input, s), f.find(input, s));
    }
}

test "classscan: digits (nibble-aligned, exact classifier)" {
    const digits = rangeSet('0', '9');
    try expectAgreesEverywhere(digits, "abc123def456");
    try expectAgreesEverywhere(digits, "no digits in this sentence at all whatsoever");
    try expectAgreesEverywhere(digits, "0000000000000000000000000000"); // dense, > 1 chunk
    try expectAgreesEverywhere(digits, "...............7"); // member exactly at offset 16
    try expectAgreesEverywhere(digits, "trailing digit at the very end 9");
}

test "classscan: scattered set stresses the superset+verify path" {
    // {0x10, 0x21}: the nibble AND flags 0x11 and 0x20 too (cross-member nibbles) — the
    // exact `has` confirm must reject those false positives.
    const scattered = setOf(&.{ 0x10, 0x21 });
    try expectAgreesEverywhere(scattered, "\x11\x20\x10\x21\x11\x20"); // only 0x10,0x21 are members
    var dense: [40]u8 = undefined;
    @memset(&dense, 0x11); // every byte a nibble-AND false positive, no real member
    try expectAgreesEverywhere(scattered, &dense);
}

test "classscan: hex letters, uppercase, and high bytes" {
    try expectAgreesEverywhere(setOf(&.{ 'a', 'b', 'c', 'd', 'e', 'f' }), "the cafe at 0xDEAD beef");
    try expectAgreesEverywhere(rangeSet('A', 'Z'), "mostly lower with One Capital here");
    // high (≥0x80) members — UTF-8 lead bytes, the Unicode-class lead-byte case.
    try expectAgreesEverywhere(rangeSet(0xD0, 0xEF), "ascii then \xd0\xb0 cyrillic \xe4\xb8\xad han");
}

test "classscan: short inputs (all scalar tail, no full chunk) and empty/no match" {
    const digits = rangeSet('0', '9');
    try expectAgreesEverywhere(digits, "");
    try expectAgreesEverywhere(digits, "a");
    try expectAgreesEverywhere(digits, "5");
    try expectAgreesEverywhere(digits, "123456789012345"); // 15 bytes (< one chunk)
    // start past end / on the boundary.
    const f = ClassFinder.init(digits);
    try testing.expectEqual(@as(?usize, null), f.find("abc", 5));
    try testing.expectEqual(@as(?usize, null), f.find("abc", 3));
    try testing.expectEqual(@as(?usize, 1), f.find("a1c", 0));
}

test "classscan: comptime evaluates via the scalar fallback (no @Vector in const-eval)" {
    const at = comptime blk: {
        const f = ClassFinder.init(rangeSet('0', '9'));
        break :blk f.find("abc42", 0);
    };
    try testing.expectEqual(@as(?usize, 3), at);
}

test {
    testing.refAllDecls(@This());
}
