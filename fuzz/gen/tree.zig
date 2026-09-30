//! The semantic pattern tree — ground truth for the reference, metamorphic, and
//! witness-planting checks.
//!
//! A `Tree` is generated from a `Smith`, printed to pattern text by `print.zig` in many
//! equivalent spellings, interpreted directly by the reference matcher (`ref/`), and
//! sampled for witness strings (`witness.zig`). It never touches ezi_gex's AST: every
//! node carries the flags (i/m/s) IN FORCE at it, so its meaning is independent of how it
//! is spelled. It is POD (`extern`) so it serializes into `FUZZ-CASE tree=…` and
//! `fuzz-min` can shrink it node by node.
//!
//! Loop lengths come from `valueRangeAtMost`, never `eos` (replay-mode `eos` is
//! `byte != 0` — see fuzz/health.zig).

const std = @import("std");
const Smith = std.testing.Smith;
const props = @import("props.zig");

pub const max_nodes = 48;
pub const max_kids = 96;
pub const max_items = 32;
pub const max_depth = 4;
pub const max_rep = 6;
pub const max_groups = 15;
/// `Node.c` for "no upper bound" (`*`, `+`, `{m,}`).
pub const unbounded: u8 = 0xFF;

pub const Flags = packed struct(u8) {
    i: bool = false,
    m: bool = false,
    s: bool = false,
    _pad: u5 = 0,

    pub fn eql(a: Flags, b: Flags) bool {
        return a.i == b.i and a.m == b.m and a.s == b.s;
    }
};

/// Semantics of each `check/common.zig` `opt_variants` entry, mirrored here so `gen`
/// and `ref` never import `check` (common.zig asserts the two stay in sync at comptime).
pub const OptSem = struct { unicode: bool = true, fold: bool = true, base: Flags = .{} };
pub const opt_sem = [_]OptSem{
    .{}, // 0 defaults
    .{ .unicode = false }, // 1 ASCII \d \w \s
    .{ .fold = false }, // 2 case_fold = .none — (?i) has no effect
    .{ .base = .{ .i = true } }, // 3 case_insensitive
    .{ .base = .{ .m = true } }, // 4 multiline
    .{ .base = .{ .s = true } }, // 5 dot_matches_newline
};

pub const Kind = enum(u8) { empty, lit, dot, class, assert, concat, alt, repeat, group, flags };
pub const Assert = enum(u8) { text_start, text_end, line_start, line_end, word_boundary, not_word_boundary };
pub const Perl = enum(u8) { digit, word, space };
pub const ItemKind = enum(u8) { range, perl, prop };

pub const Item = extern struct {
    kind: ItemKind,
    neg: bool = false,
    /// `Perl` tag or `props.table` index.
    which: u8 = 0,
    _pad: u8 = 0,
    lo: u32 = 0,
    hi: u32 = 0,
};

/// Field meanings by kind — `lit`: `cp`. `class`: `a` negated, `first/len` items.
/// `assert`: `a` = `Assert`. `concat/alt`: `first/len` kids. `repeat`: `a` greedy, `b` min,
/// `c` max (`unbounded`), `first` child. `group` (capturing): `b` index (pre-order,
/// 1-based), `first` child. `flags`: `a` set bits, `b` clear bits, `first` child (whose
/// `flags` are the result).
pub const Node = extern struct {
    kind: Kind,
    flags: Flags = .{},
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    _pad: u8 = 0,
    first: u16 = 0,
    len: u16 = 0,
    cp: u32 = 0,
};

pub const alphabet_cps = [_]u21{ 'a', 'b', 'A', 'B', 'c', '1', ' ', '\n', '_', 'k', 's' };
pub const trap_cps = [_]u21{
    0x212A, 0x017F, 'K',    'S',    0x023A,  0x2C65,  0x03A3,   0x03C3, 0x03C2, 0x00B5, 0x03BC,
    0x0130, 0x0131, 'i',    'I',    0x01C4,  0x01C5,  0x01C6,   0x10400, 0x10428, 0xFFFD, 0x7F,
    0x80,   0x7FF,  0x800,  0xD7FF, 0xE000,  0xFFFF,  0x10000,  0x10FFFF, 0x00E9, 0x65E5, 0x1F600,
    0x00DF, 0x1E9E, '.',    '#',    '$',     '\\',    '[',      ']',    '(',    ')',    '|',
    '?',    '*',    '+',    '{',    '}',     '^',     '-',      '\t',   0x00,   0x1B,
};

pub const Tree = extern struct {
    nodes: [max_nodes]Node,
    kids: [max_kids]u16,
    items: [max_items]Item,
    n_nodes: u16,
    n_kids: u16,
    n_items: u16,
    root: u16,
    opt: u8,
    n_groups: u8,
    _pad: [2]u8,

    /// Only the shared empty leaf (node 0), which `add` falls back to when full.
    pub fn init(opt: u8) Tree {
        var t = std.mem.zeroes(Tree);
        t.opt = opt;
        t.nodes[0] = .{ .kind = .empty, .flags = opt_sem[opt].base };
        t.n_nodes = 1;
        return t;
    }

    pub fn add(t: *Tree, n: Node) u16 {
        if (t.n_nodes >= max_nodes) return 0;
        t.nodes[t.n_nodes] = n;
        t.n_nodes += 1;
        return t.n_nodes - 1;
    }

    pub fn addParent(t: *Tree, kind: Kind, f: Flags, kids: []const u16) u16 {
        if (t.n_kids + kids.len > max_kids or t.n_nodes >= max_nodes) return 0;
        const first = t.n_kids;
        @memcpy(t.kids[first..][0..kids.len], kids);
        t.n_kids += @intCast(kids.len);
        return t.add(.{ .kind = kind, .flags = f, .first = first, .len = @intCast(kids.len) });
    }

    pub fn addItems(t: *Tree, its: []const Item) ?u16 {
        if (its.len == 0 or t.n_items + its.len > max_items) return null;
        const first = t.n_items;
        @memcpy(t.items[first..][0..its.len], its);
        t.n_items += @intCast(its.len);
        return first;
    }

    pub fn kidsOf(t: *const Tree, n: Node) []const u16 {
        return t.kids[n.first..][0..n.len];
    }

    pub fn itemsOf(t: *const Tree, n: Node) []const Item {
        return t.items[n.first..][0..n.len];
    }

    /// Can node `i` match the empty string? (Rust's `is_match_empty`: assertions count.)
    pub fn nullable(t: *const Tree, i: u16) bool {
        const n = t.nodes[i];
        return switch (n.kind) {
            .empty, .assert => true,
            .lit, .dot, .class => false,
            .concat => for (t.kidsOf(n)) |k| {
                if (!t.nullable(k)) break false;
            } else true,
            .alt => for (t.kidsOf(n)) |k| {
                if (t.nullable(k)) break true;
            } else false,
            .repeat => n.b == 0 or t.nullable(n.first),
            .group, .flags => t.nullable(n.first),
        };
    }

    pub fn hasCapture(t: *const Tree, i: u16) bool {
        const n = t.nodes[i];
        return switch (n.kind) {
            .group => true,
            .concat, .alt => for (t.kidsOf(n)) |k| {
                if (t.hasCapture(k)) break true;
            } else false,
            .repeat, .flags => t.hasCapture(n.first),
            else => false,
        };
    }

    /// Node count of the subtree at `i`.
    pub fn size(t: *const Tree, i: u16) usize {
        const n = t.nodes[i];
        return 1 + switch (n.kind) {
            .concat, .alt => blk: {
                var s: usize = 0;
                for (t.kidsOf(n)) |k| s += t.size(k);
                break :blk s;
            },
            .repeat, .group, .flags => t.size(n.first),
            else => 0,
        };
    }

    /// Number capture groups 1.. in pre-order (= order of `(` in any printing) and set
    /// `n_groups`. Call after building or shrinking.
    pub fn renumberGroups(t: *Tree) void {
        var next: u8 = 0;
        t.renumberFrom(t.root, &next);
        t.n_groups = next;
    }

    fn renumberFrom(t: *Tree, i: u16, next: *u8) void {
        const n = t.nodes[i];
        switch (n.kind) {
            .group => {
                next.* += 1;
                t.nodes[i].b = next.*;
                t.renumberFrom(n.first, next);
            },
            .concat, .alt => for (t.kidsOf(n)) |k| t.renumberFrom(k, next),
            .repeat, .flags => t.renumberFrom(n.first, next),
            else => {},
        }
    }

    pub fn bytes(t: *const Tree) []const u8 {
        return std.mem.asBytes(t);
    }

    /// Deserialize + validate (tags are checked on the raw bytes BEFORE any enum field is
    /// read, since an out-of-range tag is illegal behaviour to load).
    pub fn fromBytes(b: []const u8) ?Tree {
        if (b.len != @sizeOf(Tree)) return null;
        for (0..max_nodes) |i| {
            const off = @offsetOf(Tree, "nodes") + i * @sizeOf(Node) + @offsetOf(Node, "kind");
            if (b[off] > @intFromEnum(Kind.flags)) return null;
        }
        for (0..max_items) |i| {
            const base = @offsetOf(Tree, "items") + i * @sizeOf(Item);
            if (b[base + @offsetOf(Item, "kind")] > @intFromEnum(ItemKind.prop)) return null;
            if (b[base + @offsetOf(Item, "neg")] > 1) return null;
        }
        var t: Tree = undefined;
        @memcpy(std.mem.asBytes(&t), b);
        return if (t.wellFormed()) t else null;
    }

    /// Structural validity. Children always have smaller indices than their parent
    /// (bottom-up construction), which also rules out cycles.
    pub fn wellFormed(t: *const Tree) bool {
        if (t.n_nodes == 0 or t.n_nodes > max_nodes or t.n_kids > max_kids or t.n_items > max_items) return false;
        if (t.root >= t.n_nodes or t.opt >= opt_sem.len or t.n_groups > max_groups) return false;
        for (t.nodes[0..t.n_nodes], 0..) |n, i| {
            switch (n.kind) {
                .concat, .alt => {
                    if (@as(usize, n.first) + n.len > t.n_kids) return false;
                    for (t.kidsOf(n)) |k| if (k >= i) return false;
                },
                .repeat, .group, .flags => if (n.first >= i) return false,
                .class => {
                    if (n.len == 0 or @as(usize, n.first) + n.len > t.n_items) return false;
                    for (t.itemsOf(n)) |it| switch (it.kind) {
                        .range => if (it.lo > it.hi or !isScalar(it.lo) or !isScalar(it.hi)) return false,
                        .perl => if (it.which > @intFromEnum(Perl.space)) return false,
                        .prop => if (it.which >= props.table.len) return false,
                    };
                },
                .assert => if (n.a > @intFromEnum(Assert.not_word_boundary)) return false,
                .lit => if (!isScalar(n.cp)) return false,
                .empty, .dot => {},
            }
            if (n.kind == .repeat and n.c != unbounded and n.b > n.c) return false;
        }
        return true;
    }
};

pub fn isScalar(cp: u32) bool {
    return cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF);
}

pub fn encodeUtf8(cp: u21, out: *[4]u8) u3 {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

// ══════════════════════════════════════════════════════════════════════════════
// Builder (tests, reference self-check, fuzz-min)
// ══════════════════════════════════════════════════════════════════════════════

/// Bottom-up construction; every node is stamped with `f` (set it before building a
/// flag-scoped subtree). `finish` renumbers groups in pre-order.
pub const Builder = struct {
    t: Tree,
    f: Flags,

    pub fn init(opt_index: u8) Builder {
        return .{ .t = Tree.init(opt_index), .f = opt_sem[opt_index].base };
    }
    pub fn empty(b: *Builder) u16 {
        return b.t.add(.{ .kind = .empty, .flags = b.f });
    }
    pub fn lit(b: *Builder, cp: u21) u16 {
        return b.t.add(.{ .kind = .lit, .flags = b.f, .cp = cp });
    }
    pub fn dot(b: *Builder) u16 {
        return b.t.add(.{ .kind = .dot, .flags = b.f });
    }
    pub fn assert(b: *Builder, k: Assert) u16 {
        return b.t.add(.{ .kind = .assert, .flags = b.f, .a = @intFromEnum(k) });
    }
    pub fn range(lo: u21, hi: u21) Item {
        return .{ .kind = .range, .lo = lo, .hi = hi };
    }
    pub fn perl(p: Perl, neg: bool) Item {
        return .{ .kind = .perl, .which = @intFromEnum(p), .neg = neg };
    }
    pub fn prop(short: []const u8, neg: bool) Item {
        return .{ .kind = .prop, .which = props.indexOf(short).?, .neg = neg };
    }
    pub fn class(b: *Builder, its: []const Item, negated: bool) u16 {
        const first = b.t.addItems(its) orelse return 0;
        return b.t.add(.{ .kind = .class, .flags = b.f, .a = @intFromBool(negated), .first = first, .len = @intCast(its.len) });
    }
    pub fn cat(b: *Builder, kids: []const u16) u16 {
        return b.t.addParent(.concat, b.f, kids);
    }
    pub fn alt(b: *Builder, kids: []const u16) u16 {
        return b.t.addParent(.alt, b.f, kids);
    }
    pub fn rep(b: *Builder, child: u16, min: u8, max: u8, greedy: bool) u16 {
        return b.t.add(.{ .kind = .repeat, .flags = b.f, .a = @intFromBool(greedy), .b = min, .c = max, .first = child });
    }
    pub fn star(b: *Builder, child: u16) u16 {
        return b.rep(child, 0, unbounded, true);
    }
    pub fn plus(b: *Builder, child: u16) u16 {
        return b.rep(child, 1, unbounded, true);
    }
    pub fn opt(b: *Builder, child: u16) u16 {
        return b.rep(child, 0, 1, true);
    }
    /// A capturing group; its index is assigned by `finish` (pre-order).
    pub fn group(b: *Builder, child: u16) u16 {
        return b.t.add(.{ .kind = .group, .flags = b.f, .first = child });
    }
    /// A flag scope: `child` must have been built with `b.f` already set to the result
    /// flags; this node carries the flags OUTSIDE the scope (`outer`).
    pub fn flags(b: *Builder, outer: Flags, set: Flags, clear: Flags, child: u16) u16 {
        return b.t.add(.{ .kind = .flags, .flags = outer, .a = @bitCast(set), .b = @bitCast(clear), .first = child });
    }
    pub fn finish(b: *Builder, root: u16) Tree {
        b.t.root = root;
        b.t.renumberGroups();
        return b.t;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Smith generator
// ══════════════════════════════════════════════════════════════════════════════

/// Pick an option variant: defaults dominate (the common path), each other variant ~8%.
pub fn pickOpt(smith: *Smith) u8 {
    @disableInstrumentation();
    const r = smith.valueRangeAtMost(u8, 0, 11);
    return if (r < opt_sem.len) r else 0;
}

pub fn generate(smith: *Smith, opt: u8) Tree {
    @disableInstrumentation();
    var g: Gen = .{ .smith = smith, .t = Tree.init(opt) };
    g.t.root = g.alt(opt_sem[opt].base, 0);
    g.t.renumberGroups();
    return g.t;
}

const Gen = struct {
    smith: *Smith,
    t: Tree,

    fn roomy(g: *const Gen) bool {
        return g.t.n_nodes + 10 < max_nodes and g.t.n_kids + 8 < max_kids and g.t.n_items + 4 < max_items;
    }

    fn alt(g: *Gen, f: Flags, depth: u8) u16 {
        var br: [3]u16 = undefined;
        const want: usize = if (g.smith.valueRangeAtMost(u8, 0, 5) == 0) g.smith.valueRangeAtMost(u8, 2, 3) else 1;
        var n: usize = 0;
        while (n < want and (n == 0 or g.roomy())) : (n += 1) br[n] = g.concat(f, depth);
        return if (n == 1) br[0] else g.t.addParent(.alt, f, br[0..n]);
    }

    fn concat(g: *Gen, f: Flags, depth: u8) u16 {
        var xs: [5]u16 = undefined;
        const want = g.smith.valueRangeAtMost(u8, 0, 4);
        var n: usize = 0;
        while (n < want and g.roomy()) : (n += 1) xs[n] = g.quantified(f, depth);
        return switch (n) {
            0 => g.t.add(.{ .kind = .empty, .flags = f }),
            1 => xs[0],
            else => g.t.addParent(.concat, f, xs[0..n]),
        };
    }

    fn quantified(g: *Gen, f: Flags, depth: u8) u16 {
        const operand = g.atom(f, depth);
        if (g.smith.valueRangeAtMost(u8, 0, 2) != 0) return operand; // ~1/3 quantified
        var min: u8 = 0;
        var max: u8 = unbounded;
        switch (g.smith.valueRangeAtMost(u8, 0, 4)) {
            0 => {}, // *
            1 => min = 1, // +
            2 => max = 1, // ?
            3 => { // {m} / {m,n}
                min = g.smith.valueRangeAtMost(u8, 0, max_rep);
                max = g.smith.valueRangeAtMost(u8, min, max_rep);
            },
            else => min = g.smith.valueRangeAtMost(u8, 0, max_rep), // {m,}
        }
        const greedy = g.smith.valueRangeAtMost(u8, 0, 3) != 0;
        return g.t.add(.{ .kind = .repeat, .flags = f, .a = @intFromBool(greedy), .b = min, .c = max, .first = operand });
    }

    fn atom(g: *Gen, f: Flags, depth: u8) u16 {
        const nest = depth < max_depth and g.roomy();
        switch (g.smith.valueRangeAtMost(u8, 0, if (nest) 9 else 5)) {
            0, 1, 2 => return g.t.add(.{ .kind = .lit, .flags = f, .cp = g.pickCp() }),
            3 => return g.t.add(.{ .kind = .dot, .flags = f }),
            4 => return g.class(f),
            5 => return g.assertion(f),
            6, 7 => { // capturing group (index assigned by renumberGroups)
                const child = g.alt(f, depth + 1);
                return g.t.add(.{ .kind = .group, .flags = f, .first = child });
            },
            8 => return g.alt(f, depth + 1), // nested alternation — the printer groups it
            else => { // flag scope
                const set: Flags = @bitCast(g.smith.valueRangeAtMost(u8, 0, 7));
                const clear: Flags = @bitCast(g.smith.valueRangeAtMost(u8, 0, 7) & ~@as(u8, @bitCast(set)));
                const nf: Flags = .{
                    .i = (f.i or set.i) and !clear.i,
                    .m = (f.m or set.m) and !clear.m,
                    .s = (f.s or set.s) and !clear.s,
                };
                const child = g.alt(nf, depth + 1);
                return g.t.add(.{ .kind = .flags, .flags = f, .a = @bitCast(set), .b = @bitCast(clear), .first = child });
            },
        }
    }

    fn pickCp(g: *Gen) u21 {
        // 3:1 the small alphabet shared with haystacks (so matches happen), else a trap.
        if (g.smith.valueRangeAtMost(u8, 0, 3) != 0) return alphabet_cps[g.smith.index(alphabet_cps.len)];
        return trap_cps[g.smith.index(trap_cps.len)];
    }

    fn class(g: *Gen, f: Flags) u16 {
        var its: [3]Item = undefined;
        const n = g.smith.valueRangeAtMost(u8, 1, 3);
        for (its[0..n]) |*it| it.* = g.item();
        const first = g.t.addItems(its[0..n]) orelse return g.t.add(.{ .kind = .dot, .flags = f });
        const neg = g.smith.valueRangeAtMost(u8, 0, 3) == 0;
        return g.t.add(.{ .kind = .class, .flags = f, .a = @intFromBool(neg), .first = first, .len = n });
    }

    fn item(g: *Gen) Item {
        switch (g.smith.valueRangeAtMost(u8, 0, 4)) {
            0, 1 => {
                const a = g.pickCp();
                const b = g.pickCp();
                return .{ .kind = .range, .lo = @min(a, b), .hi = @max(a, b) };
            },
            2 => return .{ .kind = .perl, .which = g.smith.valueRangeAtMost(u8, 0, 2), .neg = g.smith.valueRangeAtMost(u8, 0, 2) == 0 },
            else => return .{ .kind = .prop, .which = @intCast(g.smith.index(props.table.len)), .neg = g.smith.valueRangeAtMost(u8, 0, 2) == 0 },
        }
    }

    fn assertion(g: *Gen, f: Flags) u16 {
        // The spelling decides the meaning under the flags in force: `^`/`$` are line
        // anchors only under `m`.
        const k: Assert = switch (g.smith.valueRangeAtMost(u8, 0, 5)) {
            0 => if (f.m) .line_start else .text_start, // ^
            1 => if (f.m) .line_end else .text_end, // $
            2 => .text_start, // \A
            3 => .text_end, // \z
            4 => .word_boundary,
            else => .not_word_boundary,
        };
        return g.t.add(.{ .kind = .assert, .flags = f, .a = @intFromEnum(k) });
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "Builder + nullable" {
    var b = Builder.init(0);
    const a = b.lit('a');
    try std.testing.expect(b.t.nullable(b.star(a)));
    try std.testing.expect(!b.t.nullable(b.plus(a)));
    try std.testing.expect(b.t.nullable(b.alt(&.{ b.empty(), b.lit('x') })));
    try std.testing.expect(b.t.nullable(b.assert(.word_boundary)));
    try std.testing.expect(b.t.nullable(b.rep(a, 0, 0, true)));
    try std.testing.expect(!b.t.nullable(b.class(&.{Builder.range('a', 'c')}, false)));
    try std.testing.expect(!b.t.nullable(b.cat(&.{ b.opt(a), b.lit('y') })));
}

test "renumberGroups numbers capture groups in pre-order" {
    var b = Builder.init(0);
    const inner_a = b.group(b.lit('a')); // built first (bottom-up) …
    const inner_b = b.group(b.lit('b'));
    const outer = b.group(b.cat(&.{ inner_a, inner_b })); // … but opens first in the text
    const t = b.finish(outer);
    try std.testing.expectEqual(@as(u8, 3), t.n_groups);
    try std.testing.expectEqual(@as(u8, 1), t.nodes[outer].b);
    try std.testing.expectEqual(@as(u8, 2), t.nodes[inner_a].b);
    try std.testing.expectEqual(@as(u8, 3), t.nodes[inner_b].b);
}

test "generated trees are well-formed and round-trip through bytes" {
    var prng = std.Random.DefaultPrng.init(11);
    var buf: [4096]u8 = undefined;
    var kinds_seen: [@typeInfo(Kind).@"enum".field_names.len]bool = @splat(false);
    for (0..3000) |_| {
        var s = @import("replay.zig").smith(&prng, &buf);
        const opt = pickOpt(&s);
        const t = generate(&s, opt);
        try std.testing.expect(t.wellFormed());
        for (t.nodes[0..t.n_nodes]) |n| kinds_seen[@intFromEnum(n.kind)] = true;
        const back = Tree.fromBytes(t.bytes()) orelse return error.RoundTripRejected;
        try std.testing.expectEqualSlices(u8, t.bytes(), back.bytes());
    }
    for (kinds_seen, 0..) |seen, k| if (!seen) {
        std.debug.print("generator never produced kind {s}\n", .{@tagName(@as(Kind, @enumFromInt(k)))});
        return error.KindUnreached;
    };
}

test "fromBytes rejects malformed input" {
    var b = Builder.init(0);
    const t = b.finish(b.cat(&.{ b.lit('a'), b.dot() }));
    try std.testing.expect(Tree.fromBytes(t.bytes()[1..]) == null); // wrong length
    var raw: [@sizeOf(Tree)]u8 = undefined;
    @memcpy(&raw, t.bytes());
    raw[@offsetOf(Tree, "nodes") + @offsetOf(Node, "kind")] = 0xEE; // bad Kind tag
    try std.testing.expect(Tree.fromBytes(&raw) == null);
    @memcpy(&raw, t.bytes());
    std.mem.writeInt(u16, raw[@offsetOf(Tree, "root")..][0..2], max_nodes + 3, .little); // root out of range
    try std.testing.expect(Tree.fromBytes(&raw) == null);
}

test "encodeUtf8" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "a", out[0..encodeUtf8('a', &out)]);
    try std.testing.expectEqualSlices(u8, "\xC3\xA9", out[0..encodeUtf8(0xE9, &out)]);
    try std.testing.expectEqualSlices(u8, "\xE2\x84\xAA", out[0..encodeUtf8(0x212A, &out)]);
    try std.testing.expectEqualSlices(u8, "\xF4\x8F\xBF\xBF", out[0..encodeUtf8(0x10FFFF, &out)]);
}
