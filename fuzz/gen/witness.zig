//! Witness sampler: a string the tree matches when searched ANCHORED at offset 0, used to
//! plant real matches (and near-misses) in long haystacks. Sampled structurally, then
//! confirmed with the reference matcher and trimmed to exactly the reference's match.

const std = @import("std");
const tree = @import("tree.zig");
const ref = @import("../ref/root.zig");
const Smith = std.testing.Smith;

pub const max_witness = 256;

pub const Witness = struct {
    buf: [max_witness]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Witness) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn sample(gpa: std.mem.Allocator, t: *const tree.Tree, seed: u64) !?Witness {
    var prng = std.Random.DefaultPrng.init(seed);
    var s: Sampler = .{ .t = t, .r = prng.random(), .sem = tree.opt_sem[t.opt] };
    s.node(t.root);
    if (s.overflow) return null;
    var r = ref.Ref.init(gpa, t) catch |e| switch (e) {
        error.ProgramTooBig => return null,
        else => return e,
    };
    defer r.deinit();
    var slots: [ref.max_slots]?usize = undefined;
    const m = (try r.find(s.w.slice(), .{ .anchored = true }, slots[0..r.slotCount()])) orelse return null;
    s.w.len = m[1];
    return s.w;
}

const pool = tree.alphabet_cps ++ tree.trap_cps ++ [_]u21{ '0', '7', 0x0663, 'Z', 'q', 0x00E9, 0x03B1, 0x0436, 0x3000, 0x0301, 0x200D, '!', '+', '_' };

const Sampler = struct {
    t: *const tree.Tree,
    r: std.Random,
    sem: tree.OptSem,
    w: Witness = .{},
    overflow: bool = false,

    fn emit(s: *Sampler, cp: u21) void {
        var b: [4]u8 = undefined;
        const n = tree.encodeUtf8(cp, &b);
        if (s.w.len + n > max_witness) {
            s.overflow = true;
            return;
        }
        @memcpy(s.w.buf[s.w.len..][0..n], b[0..n]);
        s.w.len += n;
    }

    /// A random member of `n` (lit / dot / class) from the pool plus item-derived
    /// candidates, or 'a' if none fits (the reference confirmation then rejects).
    fn member(s: *Sampler, n: tree.Node) u21 {
        if (n.kind == .lit) {
            const cp: u21 = @intCast(n.cp);
            if (n.flags.i and s.sem.fold and s.r.boolean()) {
                var ob: [8]u21 = undefined;
                const o = ref.uni.orbit(cp, &ob);
                return o[s.r.uintLessThan(usize, o.len)];
            }
            return cp;
        }
        var cands: [pool.len + 3 * tree.max_items]u21 = undefined;
        var k: usize = 0;
        for (pool) |c| {
            cands[k] = c;
            k += 1;
        }
        if (n.kind == .class) for (s.t.itemsOf(n)) |it| {
            switch (it.kind) {
                .range => {
                    cands[k] = @intCast(it.lo);
                    cands[k + 1] = @intCast(it.hi);
                    cands[k + 2] = @intCast(it.lo + (it.hi - it.lo) / 2);
                    k += 3;
                },
                .prop => {
                    cands[k] = @import("props.zig").table[it.which].sample;
                    k += 1;
                },
                .perl => {},
            }
        };
        var fits: [cands.len]u21 = undefined;
        var nf: usize = 0;
        for (cands[0..k]) |c| {
            if (!tree.isScalar(c)) continue;
            if (ref.uni.charMatches(s.t, n, c, s.sem)) {
                fits[nf] = c;
                nf += 1;
            }
        }
        return if (nf == 0) 'a' else fits[s.r.uintLessThan(usize, nf)];
    }

    fn node(s: *Sampler, i: u16) void {
        if (s.overflow) return;
        const n = s.t.nodes[i];
        switch (n.kind) {
            .empty, .assert => {},
            .lit, .dot, .class => s.emit(s.member(n)),
            .concat => for (s.t.kidsOf(n)) |k| s.node(k),
            .alt => {
                const ks = s.t.kidsOf(n);
                if (ks.len > 0) s.node(ks[s.r.uintLessThan(usize, ks.len)]);
            },
            .repeat => {
                const hi: u8 = if (n.c == tree.unbounded) n.b +| 2 else n.c;
                const count = n.b + s.r.uintAtMost(u8, hi - n.b);
                var j: u8 = 0;
                while (j < count) : (j += 1) s.node(n.first);
            },
            .group, .flags => s.node(n.first),
        }
    }
};

test "witnesses match anchored at 0 and are produced for most trees" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(31);
    var buf: [4096]u8 = undefined;
    var produced: usize = 0;
    const n = 1500;
    for (0..n) |i| {
        var s = @import("replay.zig").smith(&prng, &buf);
        const t = tree.generate(&s, tree.pickOpt(&s));
        const w = (try sample(gpa, &t, i + 1)) orelse continue;
        produced += 1;
        var r = try ref.Ref.init(gpa, &t);
        defer r.deinit();
        var slots: [ref.max_slots]?usize = undefined;
        const m = (try r.find(w.slice(), .{ .anchored = true }, slots[0..r.slotCount()])).?;
        try std.testing.expectEqual(@as(usize, 0), m[0]);
        try std.testing.expectEqual(w.len, m[1]);
    }
    // Most trees are satisfiable; a low rate means the sampler lost track of a node kind.
    try std.testing.expect(produced * 2 > n);
}
