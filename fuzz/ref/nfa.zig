//! Tree → Thompson NFA following Rust `regex-automata`'s thompson compiler — the
//! empty-width-loop semantics ezi_gex adopted in 0.6.0 (RE2/Rust leftmost-first):
//!
//!   x?        split(x, next)
//!   x+        x ; split(x.start, next)
//!   x*        x nullable ? (x+)?  :  L: split(x, next); x → L
//!   x{n,}     x{n-1} x+
//!   x{m,n}    m copies, then n−m nested optionals that share one exit
//!
//! Lazy forms swap split priority. Compiled right-to-left: `node(i, next)` returns the
//! entry pc of node `i` whose exits continue at `next`.

const std = @import("std");
const tree = @import("../gen/tree.zig");

pub const Op = enum(u8) { match, char, split, jmp, save, assert };
/// `char`: arg = tree node index (lit/dot/class). `split`: x preferred, y alternative.
/// `save`: arg = slot. `assert`: arg = `tree.Assert`. Everything else continues at x.
pub const Inst = struct { op: Op, x: u32 = 0, y: u32 = 0, arg: u32 = 0 };
pub const max_insts = 20_000;

pub const Prog = struct {
    insts: []Inst,
    start: u32,
    n_slots: u32,

    pub fn deinit(p: *Prog, gpa: std.mem.Allocator) void {
        gpa.free(p.insts);
    }
};

pub fn compile(gpa: std.mem.Allocator, t: *const tree.Tree) !Prog {
    var c: Compiler = .{ .gpa = gpa, .t = t };
    errdefer c.list.deinit(gpa);
    const m = try c.emit(.{ .op = .match });
    const s1 = try c.emit(.{ .op = .save, .arg = 1, .x = m });
    const body = try c.node(t.root, s1);
    const s0 = try c.emit(.{ .op = .save, .arg = 0, .x = body });
    return .{ .insts = try c.list.toOwnedSlice(gpa), .start = s0, .n_slots = 2 * (@as(u32, t.n_groups) + 1) };
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    t: *const tree.Tree,
    list: std.ArrayList(Inst) = .empty,

    fn emit(c: *Compiler, inst: Inst) !u32 {
        if (c.list.items.len >= max_insts) return error.ProgramTooBig;
        try c.list.append(c.gpa, inst);
        return @intCast(c.list.items.len - 1);
    }

    fn setSplit(c: *Compiler, at: u32, body: u32, exit: u32, greedy: bool) void {
        c.list.items[at] = if (greedy)
            .{ .op = .split, .x = body, .y = exit }
        else
            .{ .op = .split, .x = exit, .y = body };
    }

    fn node(c: *Compiler, i: u16, next: u32) anyerror!u32 {
        const n = c.t.nodes[i];
        switch (n.kind) {
            .empty => return next,
            .lit, .dot, .class => return c.emit(.{ .op = .char, .arg = i, .x = next }),
            .assert => return c.emit(.{ .op = .assert, .arg = n.a, .x = next }),
            .flags => return c.node(n.first, next),
            .concat => {
                var cur = next;
                const ks = c.t.kidsOf(n);
                var j = ks.len;
                while (j > 0) {
                    j -= 1;
                    cur = try c.node(ks[j], cur);
                }
                return cur;
            },
            .alt => {
                const ks = c.t.kidsOf(n);
                if (ks.len == 0) return next;
                var starts: [tree.max_kids]u32 = undefined;
                for (ks, 0..) |k, j| starts[j] = try c.node(k, next);
                var cur = starts[ks.len - 1];
                var j = ks.len - 1;
                while (j > 0) {
                    j -= 1;
                    cur = try c.emit(.{ .op = .split, .x = starts[j], .y = cur });
                }
                return cur;
            },
            .group => {
                const k: u32 = n.b;
                const close = try c.emit(.{ .op = .save, .arg = 2 * k + 1, .x = next });
                const b = try c.node(n.first, close);
                return c.emit(.{ .op = .save, .arg = 2 * k, .x = b });
            },
            .repeat => return c.repeat(n, next),
        }
    }

    fn exactly(c: *Compiler, child: u16, count: u8, next: u32) anyerror!u32 {
        var cur = next;
        var k: u8 = 0;
        while (k < count) : (k += 1) cur = try c.node(child, cur);
        return cur;
    }

    fn repeat(c: *Compiler, n: tree.Node, next: u32) anyerror!u32 {
        const greedy = n.a != 0;
        const min = n.b;
        const max = n.c;
        if (max != tree.unbounded) {
            if (max == 0) return next;
            if (min == max) return c.exactly(n.first, min, next);
            // m copies, then (n−m) nested optionals sharing the exit `next` (Rust c_bounded).
            var after = next;
            var k: u8 = max - min;
            while (k > 0) : (k -= 1) {
                const u = try c.emit(.{ .op = .split });
                const xs = try c.node(n.first, after);
                c.setSplit(u, xs, next, greedy);
                after = u;
            }
            return c.exactly(n.first, min, after);
        }
        if (min == 0) {
            const l = try c.emit(.{ .op = .split });
            const xs = try c.node(n.first, l);
            c.setSplit(l, xs, next, greedy);
            if (!c.t.nullable(n.first)) return l; // L: split(x, next); x → L
            // Nullable body: (x+)? — `l` is the `+` loop-back; the `?` goes in front. With
            // the plain loop, the empty path through x would outrank exiting (wrong tiebreak).
            const q = try c.emit(.{ .op = .split });
            c.setSplit(q, xs, next, greedy);
            return q;
        }
        // x{n,} (n ≥ 1) = x{n-1} x+
        const p = try c.emit(.{ .op = .split });
        const last = try c.node(n.first, p);
        c.setSplit(p, last, next, greedy);
        return c.exactly(n.first, min - 1, last);
    }
};
