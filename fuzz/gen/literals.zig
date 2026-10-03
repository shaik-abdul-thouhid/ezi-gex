//! Literal sets for the literal backend, `auto`'s Teddy / memmem / prefix-set paths:
//! 1–12 literals (crossing MAX_PREFIX_BRANCHES = 8), 0–20 code points each (crossing
//! MAX_PREFIX_LEN = 16 bytes), with shared prefixes, one literal a prefix of another,
//! duplicates, the empty literal, and optional `(?i)` with fold traps.

const std = @import("std");
const ps = @import("pattern.zig");
const Smith = std.testing.Smith;

pub const max_lits = 12;
pub const max_lit_len = 20;

pub const LitSet = struct {
    bufs: [max_lits][max_lit_len * 4]u8 = undefined,
    lens: [max_lits]usize = @splat(0),
    n: usize = 0,
    ci: bool = false,

    pub fn get(self: *const LitSet, i: usize) []const u8 {
        return self.bufs[i][0..self.lens[i]];
    }

    /// `(?i)`? `lit|lit|…`, metacharacters escaped. `null` if it doesn't fit.
    pub fn pattern(self: *const LitSet, out: []u8) ?[]const u8 {
        var len: usize = 0;
        const put = struct {
            fn f(o: []u8, l: *usize, c: u8) bool {
                if (l.* >= o.len) return false;
                o[l.*] = c;
                l.* += 1;
                return true;
            }
        }.f;
        if (self.ci) for ("(?i)") |c| if (!put(out, &len, c)) return null;
        for (0..self.n) |i| {
            if (i > 0 and !put(out, &len, '|')) return null;
            for (self.get(i)) |c| {
                if (c < 0x80 and std.mem.findScalar(u8, ".^$|?*+()[]{}\\#", c) != null) {
                    if (!put(out, &len, '\\')) return null;
                }
                if (!put(out, &len, c)) return null;
            }
        }
        return out[0..len];
    }
};

fn appendPiece(set: *LitSet, i: usize, piece: []const u8) void {
    if (set.lens[i] + piece.len > set.bufs[i].len) return;
    @memcpy(set.bufs[i][set.lens[i]..][0..piece.len], piece);
    set.lens[i] += piece.len;
}

pub fn genSet(smith: *Smith) LitSet {
    @disableInstrumentation();
    var set: LitSet = .{};
    set.ci = smith.valueRangeAtMost(u8, 0, 3) == 0;
    // Replayed out-of-range draws fall back to the minimum, so the minimum picks the
    // interesting regime: more branches than MAX_PREFIX_BRANCHES (8).
    set.n = if (smith.valueRangeAtMost(u8, 0, 2) == 0) smith.valueRangeAtMost(u8, 9, max_lits) else smith.valueRangeAtMost(u8, 1, 8);
    for (0..set.n) |i| {
        // 1 in 3 literals derive from an earlier one (prefix / extension / duplicate).
        if (i > 0 and smith.valueRangeAtMost(u8, 0, 2) == 0) {
            const src = set.get(smith.index(i));
            switch (smith.valueRangeAtMost(u8, 0, 2)) {
                0 => { // prefix of an earlier literal, cut on a code-point boundary
                    var cut = smith.index(src.len + 1);
                    while (cut > 0 and cut < src.len and src[cut] & 0xC0 == 0x80) cut -= 1;
                    appendPiece(&set, i, src[0..cut]);
                },
                1 => { // extension
                    appendPiece(&set, i, src);
                    appendPiece(&set, i, ps.alphabet[smith.index(ps.alphabet.len)..][0..1]);
                },
                else => appendPiece(&set, i, src), // duplicate
            }
            continue;
        }
        // As above: the minimum picks literals longer than MAX_PREFIX_LEN (16 bytes).
        const cps = if (smith.valueRangeAtMost(u8, 0, 2) == 0) smith.valueRangeAtMost(u8, 17, max_lit_len) else smith.valueRangeAtMost(u8, 0, 16);
        var k: u8 = 0;
        while (k < cps) : (k += 1) {
            if (smith.valueRangeAtMost(u8, 0, 5) == 0) {
                appendPiece(&set, i, ps.trap_raw[smith.index(ps.trap_raw.len)]);
            } else {
                appendPiece(&set, i, ps.alphabet[smith.index(ps.alphabet.len)..][0..1]);
            }
        }
    }
    return set;
}

/// `lit` with its last ASCII byte changed — a near-miss plant.
pub fn nearMiss(lit: []const u8, out: []u8) []const u8 {
    const n = @min(lit.len, out.len);
    @memcpy(out[0..n], lit[0..n]);
    var i = n;
    while (i > 0) {
        i -= 1;
        if (out[i] < 0x80) {
            out[i] = if (out[i] == 'z') 'y' else 'z';
            break;
        }
    }
    return out[0..n];
}

test "literal sets cross the prefix-set and prefix-length limits and always parse" {
    const gex = @import("ezi_gex");
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(47);
    var sb: [4096]u8 = undefined;
    var many: usize = 0; // > 8 branches (MAX_PREFIX_BRANCHES)
    var long: usize = 0; // a literal > 16 bytes (MAX_PREFIX_LEN)
    var pbuf: [2048]u8 = undefined;
    for (0..1000) |_| {
        var s = @import("replay.zig").smith(&prng, &sb);
        const set = genSet(&s);
        if (set.n > 8) many += 1;
        for (0..set.n) |i| {
            if (set.get(i).len > 16) {
                long += 1;
                break;
            }
        }
        const pat = set.pattern(&pbuf) orelse continue;
        var diag: gex.Diagnostic = .{};
        const a = gex.parse(gpa, pat, &diag) catch {
            std.debug.print("literal set pattern rejected: /{s}/ ({s})\n", .{ pat, @tagName(diag.code) });
            return error.LiteralPatternRejected;
        };
        a.deinit(gpa);
    }
    try std.testing.expect(many >= 150 and long >= 150);
}
