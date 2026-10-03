//! Reference-side Unicode: a strict, table-free UTF-8 decoder (dead-on-invalid), and
//! per-code-point predicates evaluated through ezi_code's POINT lookups — never
//! ezi_gex's code and never the enumerable range tables ezi_gex's HIR is built from —
//! plus simple-case-fold orbits for `(?i)`.

const std = @import("std");
const ez = @import("ezi_code");
const P = ez.unicode.properties;
const S = ez.unicode.scripts;
const casing = ez.unicode.casing;
const props = @import("../gen/props.zig");
const tree = @import("../gen/tree.zig");
const testing = std.testing;

pub const Decoded = struct { cp: u21, len: u8, valid: bool };
const bad: Decoded = .{ .cp = 0xFFFD, .len = 1, .valid = false };

/// Strict decode at `i` (`i < s.len`). Overlong forms, surrogates, > U+10FFFF, stray
/// continuations and truncated sequences are invalid, consuming one byte.
pub fn decode(s: []const u8, i: usize) Decoded {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1, .valid = true };
    var need: usize = undefined;
    var min: u32 = undefined;
    var cp: u32 = undefined;
    if (b0 >= 0xC2 and b0 <= 0xDF) {
        need = 1;
        min = 0x80;
        cp = b0 & 0x1F;
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        need = 2;
        min = 0x800;
        cp = b0 & 0x0F;
    } else if (b0 >= 0xF0 and b0 <= 0xF4) {
        need = 3;
        min = 0x10000;
        cp = b0 & 0x07;
    } else return bad;
    if (s.len - i <= need) return bad;
    for (s[i + 1 .. i + 1 + need]) |c| {
        if (c & 0xC0 != 0x80) return bad;
        cp = (cp << 6) | (c & 0x3F);
    }
    if (cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return bad;
    return .{ .cp = @intCast(cp), .len = @intCast(need + 1), .valid = true };
}

/// The scalar ending exactly at byte `i` (for `\b`), `null` at the start of input. Any
/// malformed tail decodes as `valid = false` (a non-word character).
pub fn decodeBefore(s: []const u8, i: usize) ?Decoded {
    if (i == 0) return null;
    var j = i;
    var steps: usize = 0;
    while (j > 0 and steps < 4) {
        j -= 1;
        steps += 1;
        if (s[j] & 0xC0 != 0x80) {
            const d = decode(s, j);
            return if (d.valid and j + d.len == i) d else bad;
        }
    }
    return bad;
}

/// `\w` (Unicode): Alphabetic ∪ Mark ∪ Decimal_Number ∪ Connector_Punctuation ∪ Join_Control.
pub fn isWord(cp: u21) bool {
    if (P.isAlphabetic(cp) or P.isJoinControl(cp)) return true;
    return switch (P.generalCategory(cp)) {
        .decimal_number, .non_spacing_mark, .spacing_mark, .enclosing_mark, .connector_punctuation => true,
        else => false,
    };
}

fn isAsciiWord(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
}

pub fn perl(p: tree.Perl, cp: u21, unicode: bool) bool {
    return switch (p) {
        .digit => if (unicode) P.generalCategory(cp) == .decimal_number else cp >= '0' and cp <= '9',
        .word => if (unicode) isWord(cp) else isAsciiWord(cp),
        .space => if (unicode) P.isWhitespace(cp) else (cp >= 0x09 and cp <= 0x0D) or cp == ' ',
    };
}

fn inGroup(gc: P.GeneralCategory, g: props.Group) bool {
    return switch (g) {
        .letter => switch (gc) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter, .modifier_letter, .other_letter => true,
            else => false,
        },
        .cased_letter => switch (gc) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter => true,
            else => false,
        },
        .mark => switch (gc) {
            .non_spacing_mark, .spacing_mark, .enclosing_mark => true,
            else => false,
        },
        .number => switch (gc) {
            .decimal_number, .letter_number, .other_number => true,
            else => false,
        },
        .punctuation => switch (gc) {
            .connector_punctuation, .dash_punctuation, .open_punctuation, .close_punctuation, .initial_punctuation, .final_punctuation, .other_punctuation => true,
            else => false,
        },
        .symbol => switch (gc) {
            .math_symbol, .currency_symbol, .modifier_symbol, .other_symbol => true,
            else => false,
        },
        .separator => switch (gc) {
            .space_separator, .line_separator, .paragraph_separator => true,
            else => false,
        },
        .other => switch (gc) {
            .control, .format, .surrogate, .private_use, .unassigned => true,
            else => false,
        },
    };
}

pub fn prop(which: u8, cp: u21) bool {
    return switch (props.table[which].sem) {
        .gc => |g| P.generalCategory(cp) == g,
        .group => |g| inGroup(P.generalCategory(cp), g),
        .derived => |d| P.hasDerivedProperty(cp, d),
        .script => |sc| S.scriptType(cp) == sc,
    };
}

pub fn fold(cp: u21) u21 {
    return casing.caseFoldSimple(cp);
}

const Pair = struct { to: u21, from: u21 };
var inverse: [4096]Pair = undefined;
var inverse_len: usize = 0;
var inverse_built = false;

fn buildInverse() void {
    var n: usize = 0;
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        const c: u21 = @intCast(cp);
        const f = fold(c);
        if (f == c) continue;
        if (n == inverse.len) @panic("ref/uni: fold inverse table too small");
        inverse[n] = .{ .to = f, .from = c };
        n += 1;
    }
    std.mem.sortUnstable(Pair, inverse[0..n], {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.to < b.to or (a.to == b.to and a.from < b.from);
        }
    }.lt);
    inverse_len = n;
    inverse_built = true;
}

/// Every code point whose simple fold equals `cp`'s (`cp` included). The inverse table is
/// built on first use — not thread-safe then (the fuzz bodies are single-threaded).
pub fn orbit(cp: u21, out: *[8]u21) []const u21 {
    if (!inverse_built) buildInverse();
    const f = fold(cp);
    out[0] = f;
    var n: usize = 1;
    var lo: usize = 0;
    var hi: usize = inverse_len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (inverse[mid].to < f) lo = mid + 1 else hi = mid;
    }
    while (lo < inverse_len and inverse[lo].to == f and n < out.len) : (lo += 1) {
        out[n] = inverse[lo].from;
        n += 1;
    }
    return out[0..n];
}

pub fn litMatches(x: u21, c: u21, ci: bool) bool {
    return if (ci) fold(x) == fold(c) else x == c;
}

fn itemBase(it: tree.Item, y: u21, unicode: bool) bool {
    return switch (it.kind) {
        .range => y >= it.lo and y <= it.hi,
        .perl => perl(@fromBackingInt(it.which), y, unicode),
        .prop => prop(it.which, y),
    };
}

fn itemsMatch(t: *const tree.Tree, n: tree.Node, y: u21, unicode: bool, ci: bool) bool {
    for (t.itemsOf(n)) |it| {
        // Under (?i) an item is folded BEFORE its own negation: `\P{X}` holds for `y` iff no
        // member of `y`'s fold orbit is in X (regex-syntax `unicode_fold_and_negate`).
        var base = itemBase(it, y, unicode);
        if (ci and !base and it.kind != .range) {
            var ob: [8]u21 = undefined;
            for (orbit(y, &ob)) |z| {
                if (itemBase(it, z, unicode)) {
                    base = true;
                    break;
                }
            }
        }
        if (base != it.neg) return true;
    }
    return false;
}

/// Rust's rule: under `(?i)` each item folds, THEN its own negation applies; the union is
/// closed over simple-fold orbits (a no-op once every item is closed, kept as Rust states
/// it); the class's `[^…]` applies last. So `(?i)\P{Ll}` matches no cased letter.
pub fn classMatches(t: *const tree.Tree, n: tree.Node, c: u21, sem: tree.OptSem) bool {
    const ci = n.flags.i and sem.fold;
    var hit = false;
    if (ci) {
        var ob: [8]u21 = undefined;
        for (orbit(c, &ob)) |y| {
            if (itemsMatch(t, n, y, sem.unicode, true)) {
                hit = true;
                break;
            }
        }
    } else hit = itemsMatch(t, n, c, sem.unicode, false);
    return hit != (n.a != 0);
}

/// Does the consuming node `n` (lit / dot / class) accept scalar `c`?
pub fn charMatches(t: *const tree.Tree, n: tree.Node, c: u21, sem: tree.OptSem) bool {
    return switch (n.kind) {
        .lit => litMatches(@intCast(n.cp), c, n.flags.i and sem.fold),
        .dot => c != '\n' or n.flags.s,
        .class => classMatches(t, n, c, sem),
        else => unreachable,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "decode: valid and every flavour of malformed" {
    const V = struct { s: []const u8, cp: u21, len: u8 };
    for ([_]V{
        .{ .s = "a", .cp = 'a', .len = 1 },
        .{ .s = "\xC3\xA9", .cp = 0xE9, .len = 2 },
        .{ .s = "\xE2\x84\xAA", .cp = 0x212A, .len = 3 },
        .{ .s = "\xF0\x90\x90\x80", .cp = 0x10400, .len = 4 },
        .{ .s = "\xEF\xBF\xBD", .cp = 0xFFFD, .len = 3 },
    }) |v| {
        const d = decode(v.s, 0);
        try testing.expect(d.valid);
        try testing.expectEqual(v.cp, d.cp);
        try testing.expectEqual(v.len, d.len);
    }
    for ([_][]const u8{
        "\xC3", "\xE6\x97", "\xF0\x9F\x98", "\x80", "\xBF", "\xC0\x80", "\xC1\xBF", "\xE0\x80\x80",
        "\xF0\x80\x80\x80", "\xED\xA0\x80", "\xED\xBF\xBF", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xFF", "\xE6a",
    }) |s| {
        const d = decode(s, 0);
        try testing.expect(!d.valid);
        try testing.expectEqual(@as(u8, 1), d.len);
    }
}

test "decodeBefore" {
    try testing.expect(decodeBefore("ab", 0) == null);
    try testing.expectEqual(@as(u21, 'a'), decodeBefore("ab", 1).?.cp);
    try testing.expectEqual(@as(u21, 0xE9), decodeBefore("a\xC3\xA9", 3).?.cp);
    try testing.expect(!decodeBefore("\xC3", 1).?.valid);
    try testing.expect(!decodeBefore("\x80", 1).?.valid);
    try testing.expect(!decodeBefore("a\xC3\xA9", 2).?.valid); // ends mid-sequence
}

test "predicates" {
    try testing.expect(isWord('_') and isWord(0x0663) and isWord(0x200D) and isWord(0x0301) and !isWord(' '));
    try testing.expect(perl(.space, 0x3000, true) and !perl(.space, 0x3000, false));
    try testing.expect(perl(.digit, 0x0663, true) and !perl(.digit, 0x0663, false));
    try testing.expect(perl(.space, 0x0B, false) and !perl(.word, 0xE9, false) and perl(.word, 0xE9, true));
    for (props.table, 0..) |p, i| {
        if (!prop(@intCast(i), p.sample)) {
            std.debug.print("props.table[{d}] {s}: sample U+{X:0>4} not a member\n", .{ i, p.long, p.sample });
            return error.BadPropSample;
        }
    }
}

test "fold orbits" {
    var buf: [8]u21 = undefined;
    const has = struct {
        fn f(o: []const u21, c: u21) bool {
            return std.mem.indexOfScalar(u21, o, c) != null;
        }
    }.f;
    const k = orbit('k', &buf);
    try testing.expect(has(k, 'K') and has(k, 'k') and has(k, 0x212A));
    const sig = orbit(0x03C2, &buf);
    try testing.expect(has(sig, 0x03A3) and has(sig, 0x03C3) and has(sig, 0x03C2));
    try testing.expectEqual(@as(usize, 1), orbit('1', &buf).len);
}

test "class membership follows Rust's rule under (?i)" {
    const B = tree.Builder;
    var b = B.init(3); // (?i) via Options
    const neg_a = b.class(&.{B.range('a', 'a')}, true); // (?i)[^a]
    const not_lu = b.class(&.{B.prop("Lu", true)}, false); // (?i)[\P{Lu}]
    const t = b.finish(b.cat(&.{ neg_a, not_lu }));
    const sem = tree.opt_sem[3];
    try testing.expect(!classMatches(&t, t.nodes[neg_a], 'A', sem)); // negation applied after closure
    try testing.expect(classMatches(&t, t.nodes[neg_a], 'b', sem));
    // The item folds before its own negation: fold(Lu) holds both 'A' and 'a', so
    // (?i)[\P{Lu}] matches neither — only uncased characters.
    try testing.expect(!classMatches(&t, t.nodes[not_lu], 'A', sem));
    try testing.expect(!classMatches(&t, t.nodes[not_lu], 'a', sem));
    try testing.expect(classMatches(&t, t.nodes[not_lu], '1', sem));
}
