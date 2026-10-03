//! Tree → pattern text, canonically or through randomized EQUIVALENT spellings.
//!
//! Every randomized choice is a rewrite the ezi_gex front end must treat as a no-op; two
//! printings of one tree are the metamorphic check's pair, and the canonical printing is
//! what reports and `fuzz-min` show. The printer tracks the flags in force in the text it
//! has written (`pf`; the lexical `x` as `px`) and, wherever a node's own flags differ,
//! opens a scoped `(?…:…)` — or, at the start of a group body, a bare `(?…)` toggle — so
//! flags can be scoped, bare, pushed down to leaves, or seeded via `Options` without
//! changing the meaning.

const std = @import("std");
const tree = @import("tree.zig");
const props = @import("props.zig");
const Smith = std.testing.Smith;
const Tree = tree.Tree;
const Node = tree.Node;
const Item = tree.Item;
const Flags = tree.Flags;

pub const max_len = 1024;

pub const Printed = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Printed) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Deterministic printing.
pub fn canonical(t: *const Tree, opt_print: u8) ?Printed {
    return printLimited(t, opt_print, 0, max_len);
}

/// Randomized equivalent printing (`seed == 0` ⇒ canonical). `opt_print` is the option
/// variant the text will be compiled with; it must satisfy `compatibleOpts(t.opt, opt_print)`.
pub fn variant(t: *const Tree, opt_print: u8, seed: u64) ?Printed {
    return printLimited(t, opt_print, seed, max_len);
}

/// Only the Options-seeded base flags may differ between the tree's variant and the
/// printing's — the printer re-establishes each node's flags inline.
pub fn compatibleOpts(tree_opt: u8, print_opt: u8) bool {
    const a = tree.opt_sem[tree_opt];
    const b = tree.opt_sem[print_opt];
    return a.unicode == b.unicode and a.fold == b.fold;
}

/// `null` when the text would exceed `limit` bytes — never a truncated pattern.
pub fn printLimited(t: *const Tree, opt_print: u8, seed: u64, limit: usize) ?Printed {
    std.debug.assert(limit <= max_len);
    std.debug.assert(compatibleOpts(t.opt, opt_print));
    var out: Printed = .{};
    var prng = std.Random.DefaultPrng.init(seed);
    var p: P = .{
        .t = t,
        .out = &out,
        .limit = limit,
        .rng = if (seed == 0) null else prng.random(),
        .pf = tree.opt_sem[opt_print].base,
    };
    p.body(t.root);
    if (p.overflow) return null;
    return out;
}

const Ctx = enum { top, elem, operand };

fn isComposite(k: tree.Kind) bool {
    return switch (k) {
        .empty, .concat, .alt, .repeat, .group, .flags => true,
        else => false,
    };
}

fn isMeta(c: u8) bool {
    return std.mem.findScalar(u8, ".^$|?*+()[]{}\\", c) != null;
}

fn namedEscape(cp: u21) ?[]const u8 {
    return switch (cp) {
        0x0A => "\\n",
        0x0D => "\\r",
        0x09 => "\\t",
        0x0C => "\\f",
        0x0B => "\\v",
        0x07 => "\\a",
        0x1B => "\\e",
        0x00 => "\\0",
        else => null,
    };
}

fn canExpand(t: *const Tree, n: Node) bool {
    return !t.nullable(n.first) and !t.hasCapture(n.first) and t.size(n.first) <= 4;
}

const P = struct {
    t: *const Tree,
    out: *Printed,
    limit: usize,
    rng: ?std.Random,
    pf: Flags,
    px: bool = false,
    overflow: bool = false,

    fn chance(p: *P, num: u32, den: u32) bool {
        const r = p.rng orelse return false;
        return r.uintLessThan(u32, den) < num;
    }

    fn pick(p: *P, n: u8) u8 {
        const r = p.rng orelse return 0;
        return r.uintLessThan(u8, n);
    }

    fn put(p: *P, c: u8) void {
        if (p.out.len >= p.limit) {
            p.overflow = true;
            return;
        }
        p.out.buf[p.out.len] = c;
        p.out.len += 1;
    }

    fn puts(p: *P, s: []const u8) void {
        for (s) |c| p.put(c);
    }

    fn printf(p: *P, comptime fmt: []const u8, args: anytype) void {
        var b: [48]u8 = undefined;
        p.puts(std.mem.print(&b, fmt, args) catch unreachable);
    }

    fn raw(p: *P, cp: u21) void {
        var b: [4]u8 = undefined;
        p.puts(b[0..tree.encodeUtf8(cp, &b)]);
    }

    /// Insignificant text between concat elements / around `|`, only while `x` is on.
    fn junk(p: *P) void {
        if (!p.px or !p.chance(1, 3)) return;
        switch (p.pick(3)) {
            0 => p.put(' '),
            1 => p.puts("\t "),
            else => p.puts(" #c\n"),
        }
    }

    /// Emit `(?adds-removes` + `term`, moving the text's flags from (pf, px) to (want, want_x).
    fn toggle(p: *P, want: Flags, want_x: bool, term: u8) void {
        p.puts("(?");
        if (want.i and !p.pf.i) p.put('i');
        if (want.m and !p.pf.m) p.put('m');
        if (want.s and !p.pf.s) p.put('s');
        if (want_x and !p.px) p.put('x');
        const ri = !want.i and p.pf.i;
        const rm = !want.m and p.pf.m;
        const rs = !want.s and p.pf.s;
        const rx = !want_x and p.px;
        if (ri or rm or rs or rx) {
            p.put('-');
            if (ri) p.put('i');
            if (rm) p.put('m');
            if (rs) p.put('s');
            if (rx) p.put('x');
        }
        p.put(term);
        p.pf = want;
        p.px = want_x;
    }

    /// Node `i` as the whole body of a group or the pattern: alternation needs no grouping,
    /// and a bare `(?…)` toggle may set flags for the rest of the body.
    fn body(p: *P, i: u16) void {
        const n = p.t.nodes[i];
        if (p.rng != null) {
            const want_x = p.px or p.chance(1, 8);
            const differs = !n.flags.eql(p.pf) or want_x != p.px;
            // A bare toggle must change something — `(?)` is `empty_flag_group`.
            if (differs and p.chance(1, 2)) p.toggle(n.flags, want_x, ')');
        }
        p.node(i, .top);
    }

    fn node(p: *P, i: u16, ctx: Ctx) void {
        const n = p.t.nodes[i];
        if (!n.flags.eql(p.pf)) {
            // Composites have no flag-dependent syntax: optionally push the mismatch down
            // to their children instead of scoping here.
            if (isComposite(n.kind) and p.chance(1, 3)) return p.inner(i, ctx);
            return p.scoped(i, n.flags);
        }
        if (p.chance(1, 12)) return p.scoped(i, n.flags); // gratuitous (?:…) / (?x:…)
        p.inner(i, ctx);
    }

    /// `(?toggle:` node `)` — an atom in any context.
    fn scoped(p: *P, i: u16, want: Flags) void {
        const sf = p.pf;
        const sx = p.px;
        const want_x = if (p.px) !p.chance(1, 4) else p.chance(1, 6);
        p.toggle(want, want_x, ':');
        p.inner(i, .top);
        p.put(')');
        p.pf = sf;
        p.px = sx;
    }

    fn inner(p: *P, i: u16, ctx: Ctx) void {
        const n = p.t.nodes[i];
        switch (n.kind) {
            .empty => if (ctx == .operand) p.puts("(?:)"),
            .lit => p.literal(@intCast(n.cp)),
            .dot => p.put('.'),
            .class => p.class(n),
            .assert => p.assertion(n),
            .concat => p.concat(n, ctx),
            .alt => p.alt(n, ctx),
            .repeat => p.repeat(n, ctx),
            .group => p.group(n),
            .flags => p.node(n.first, ctx),
        }
    }

    fn concat(p: *P, n: Node, ctx: Ctx) void {
        const wrap = ctx == .operand;
        const sf = p.pf;
        const sx = p.px;
        if (wrap) p.puts("(?:");
        for (p.t.kidsOf(n), 0..) |k, j| {
            if (j > 0) p.junk();
            p.node(k, .elem);
        }
        if (wrap) {
            p.put(')');
            p.pf = sf;
            p.px = sx;
        }
    }

    fn alt(p: *P, n: Node, ctx: Ctx) void {
        const wrap = ctx != .top;
        const sf = p.pf;
        const sx = p.px;
        if (wrap) p.puts("(?:");
        for (p.t.kidsOf(n), 0..) |k, j| {
            if (j > 0) {
                p.junk();
                p.put('|');
                p.junk();
            }
            p.node(k, .top);
        }
        if (wrap) {
            p.put(')');
            p.pf = sf;
            p.px = sx;
        }
    }

    fn repeat(p: *P, n: Node, ctx: Ctx) void {
        const wrap = ctx == .operand; // `a**` is `multiple_quantifiers`
        const sf = p.pf;
        const sx = p.px;
        if (wrap) p.puts("(?:");
        const greedy = n.a != 0;
        if (p.rng != null and canExpand(p.t, n) and p.chance(1, 4)) {
            p.expand(n, greedy);
        } else {
            p.node(n.first, .operand);
            p.quant(n.b, n.c, greedy);
        }
        if (wrap) {
            p.put(')');
            p.pf = sf;
            p.px = sx;
        }
    }

    fn quant(p: *P, min: u8, max: u8, greedy: bool) void {
        const unb = max == tree.unbounded;
        const canon = p.rng == null or p.chance(1, 2);
        if (canon and unb and min == 0) {
            p.put('*');
        } else if (canon and unb and min == 1) {
            p.put('+');
        } else if (canon and !unb and min == 0 and max == 1) {
            p.put('?');
        } else if (unb) {
            p.printf("{{{d},}}", .{min});
        } else if (min == max and (canon or p.chance(1, 2))) {
            p.printf("{{{d}}}", .{min});
        } else {
            p.printf("{{{d},{d}}}", .{ min, max });
        }
        if (!greedy) p.put('?');
    }

    /// Structural rewrites for a non-nullable, capture-free, small operand.
    fn expand(p: *P, n: Node, greedy: bool) void {
        const lazy: []const u8 = if (greedy) "" else "?";
        const min = n.b;
        const max = n.c;
        if (max == tree.unbounded and min == 0) { // x* ≡ (?:x+)?
            p.puts("(?:");
            p.node(n.first, .operand);
            p.put('+');
            p.puts(lazy);
            p.puts(")?");
            p.puts(lazy);
            return;
        }
        var k: u8 = 0;
        while (k < min) : (k += 1) p.node(n.first, .operand); // m copies
        if (max == tree.unbounded) { // x{m,} ≡ x…x x*
            p.node(n.first, .operand);
            p.put('*');
            p.puts(lazy);
            return;
        }
        // x{m,n} ≡ x…x (?:x(?:x)?)?  — (n−m) nested optionals, as Rust compiles it
        k = 0;
        while (k < max - min) : (k += 1) {
            p.puts("(?:");
            p.node(n.first, .elem);
        }
        k = 0;
        while (k < max - min) : (k += 1) {
            p.puts(")?");
            p.puts(lazy);
        }
    }

    fn group(p: *P, n: Node) void {
        const sf = p.pf;
        const sx = p.px;
        switch (p.pick(3)) {
            0 => p.put('('),
            1 => p.printf("(?<n{d}>", .{n.b}),
            else => p.printf("(?P<n{d}>", .{n.b}),
        }
        p.body(n.first);
        p.put(')');
        p.pf = sf;
        p.px = sx;
    }

    fn assertion(p: *P, n: Node) void {
        const k: tree.Assert = @fromBackingInt(n.a);
        p.puts(switch (k) {
            .text_start => if (!p.pf.m and p.chance(1, 2)) "^" else "\\A",
            .text_end => if (!p.pf.m and p.chance(1, 3)) "$" else if (p.chance(1, 2)) "\\Z" else "\\z",
            .line_start => "^", // node flags == pf here, and the generator only makes it under m
            .line_end => "$",
            .word_boundary => "\\b",
            .not_word_boundary => "\\B",
        });
    }

    fn literal(p: *P, cp: u21) void {
        if (p.rng != null) switch (p.pick(9)) {
            0 => return p.printf("\\x{{{X}}}", .{cp}),
            1 => return p.printf("\\u{{{x}}}", .{cp}),
            2 => if (cp <= 0xFF) return p.printf("\\x{X:0>2}", .{cp}),
            3 => if (cp <= 0xFFFF) return p.printf("\\u{x:0>4}", .{cp}),
            4 => if (namedEscape(cp)) |e| return p.puts(e),
            5 => {
                p.put('[');
                p.classLit(cp);
                p.put(']');
                return;
            },
            6 => if (cp >= 1 and cp <= 26) {
                const base: u8 = if (p.chance(1, 2)) '@' else '`';
                return p.printf("\\c{c}", .{base + @as(u8, @intCast(cp))});
            },
            else => {},
        };
        p.plainLit(cp);
    }

    fn plainLit(p: *P, cp: u21) void {
        if (cp < 0x80) {
            const c: u8 = @intCast(cp);
            if (isMeta(c) or (p.px and c == '#')) {
                p.put('\\');
                return p.put(c);
            }
            if (p.px and c == ' ') return p.puts("\\ ");
            if (c < 0x20 or c == 0x7F) return p.printf("\\x{{{X}}}", .{cp}); // controls (incl. \t \n)
            return p.put(c);
        }
        p.raw(cp);
    }

    fn class(p: *P, n: Node) void {
        const its = p.t.itemsOf(n);
        if (n.a == 0 and its.len == 1 and its[0].kind != .range and p.chance(1, 2)) {
            return p.classItem(its[0]); // `[\d]` ≡ `\d`, `[\p{L}]` ≡ `\p{L}`
        }
        p.put('[');
        if (n.a != 0) p.put('^');
        for (its) |it| p.classItem(it);
        p.put(']');
    }

    fn classItem(p: *P, it: Item) void {
        switch (it.kind) {
            .range => {
                p.classLit(@intCast(it.lo));
                if (it.hi != it.lo) {
                    p.put('-');
                    p.classLit(@intCast(it.hi));
                }
            },
            .perl => {
                const c = "dws"[it.which];
                p.put('\\');
                p.put(if (it.neg) std.ascii.toUpper(c) else c);
            },
            .prop => {
                const pr = props.table[it.which];
                const name = if (p.chance(1, 2)) pr.long else pr.short;
                if (name.len == 1 and p.chance(1, 2)) {
                    p.put('\\');
                    p.put(if (it.neg) 'P' else 'p');
                    return p.puts(name); // `\pL`
                }
                p.puts(if (it.neg) "\\P{" else "\\p{");
                p.puts(name);
                p.put('}');
            },
        }
    }

    /// A code point inside `[...]`: `]` `\` `[` `-` `^` are escaped (so `[` never forms
    /// `[:` and `-` never forms a range); controls use `\x{…}`.
    fn classLit(p: *P, cp: u21) void {
        if (p.rng != null) switch (p.pick(4)) {
            0 => return p.printf("\\x{{{X}}}", .{cp}),
            1 => return p.printf("\\u{{{x}}}", .{cp}),
            2 => if (cp <= 0xFF) return p.printf("\\x{X:0>2}", .{cp}),
            else => {},
        };
        if (cp < 0x80) {
            const c: u8 = @intCast(cp);
            if (std.mem.findScalar(u8, "]\\[-^", c) != null) {
                p.put('\\');
                return p.put(c);
            }
            if (c < 0x20 or c == 0x7F) return p.printf("\\x{{{X}}}", .{cp});
            return p.put(c);
        }
        p.raw(cp);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

fn canonStr(t: tree.Tree) ![]const u8 {
    const S = struct {
        var p: Printed = .{};
    };
    S.p = canonical(&t, t.opt) orelse return error.Overflow;
    return S.p.slice();
}

test "canonical spellings" {
    const B = tree.Builder;
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("\\.", try canonStr(b.finish(b.lit('.'))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("\xE2\x84\xAA", try canonStr(b.finish(b.lit(0x212A))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("[^a-c\\d]", try canonStr(b.finish(b.class(&.{ B.range('a', 'c'), B.perl(.digit, false) }, true))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("a{2,4}?", try canonStr(b.finish(b.rep(b.lit('a'), 2, 4, false))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("a(?:b|c)", try canonStr(b.finish(b.cat(&.{ b.lit('a'), b.alt(&.{ b.lit('b'), b.lit('c') }) }))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("(?:a*)?", try canonStr(b.finish(b.opt(b.star(b.lit('a'))))));
    }
    {
        var b = B.init(0);
        const outer = b.f;
        b.f.i = true;
        const inner = b.lit('a');
        try std.testing.expectEqualStrings("(?i:a)", try canonStr(b.finish(b.flags(outer, .{ .i = true }, .{}, inner))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("\\A\\z", try canonStr(b.finish(b.cat(&.{ b.assert(.text_start), b.assert(.text_end) }))));
    }
    {
        var b = B.init(4); // multiline seeded from Options
        try std.testing.expectEqualStrings("^b$", try canonStr(b.finish(b.cat(&.{ b.assert(.line_start), b.lit('b'), b.assert(.line_end) }))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("(a)(b)", try canonStr(b.finish(b.cat(&.{ b.group(b.lit('a')), b.group(b.lit('b')) }))));
    }
}

test "printer overflow returns null, never a truncated pattern" {
    var b = tree.Builder.init(0);
    var kids: [8]u16 = undefined;
    for (&kids) |*k| k.* = b.lit(0x10FFFF);
    const t = b.finish(b.cat(&kids));
    try std.testing.expect(printLimited(&t, 0, 0, 16) == null);
    try std.testing.expect(printLimited(&t, 0, 0, max_len) != null);
}

test "every printing of generated trees compiles with the right capture count" {
    const gex = @import("ezi_gex");
    const common = @import("../check/common.zig");
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(23);
    var buf: [4096]u8 = undefined;
    var printed: usize = 0;
    for (0..1500) |iter| {
        var s = @import("replay.zig").smith(&prng, &buf);
        const opt = tree.pickOpt(&s);
        const t = tree.generate(&s, opt);
        for ([_]u64{ 0, iter + 1, iter * 7919 + 3 }) |seed| {
            const pr = variant(&t, opt, seed) orelse continue;
            printed += 1;
            var diag: gex.Diagnostic = .{};
            var re = common.compileVariant(gex.backends.pikevm, gpa, pr.slice(), &diag, opt) catch |e| {
                std.debug.print("printed tree failed to compile ({s}, {s}): /{s}/ seed={d}\n", .{ @errorName(e), @tagName(diag.code), pr.slice(), seed });
                return error.PrintedPatternRejected;
            };
            defer re.deinit();
            if (re.captureCount() != t.n_groups) {
                std.debug.print("capture count {d} != tree groups {d}: /{s}/\n", .{ re.captureCount(), t.n_groups, pr.slice() });
                return error.CaptureCountMismatch;
            }
        }
    }
    try std.testing.expect(printed > 4000);
}

test "compatibleOpts" {
    try std.testing.expect(compatibleOpts(0, 3) and compatibleOpts(3, 5) and compatibleOpts(4, 0));
    try std.testing.expect(!compatibleOpts(0, 1) and !compatibleOpts(2, 0) and compatibleOpts(1, 1));
}
