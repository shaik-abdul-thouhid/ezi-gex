//! The reference's own guard: it must reproduce ezi_gex's HUMAN-VERIFIED conformance
//! expectations (not the differential-only `wide_cases`). A failure here means the
//! reference is wrong, never ezi_gex. Rows are transcribed from src/engine/conformance.zig
//! into Builder form; `name` is the original pattern text.

const std = @import("std");
const tree = @import("../gen/tree.zig");
const root = @import("root.zig");
const B = tree.Builder;

pub const SelfCase = struct {
    name: []const u8,
    opt: u8 = 0,
    build: *const fn (*B) u16,
    input: []const u8,
    expect: ?[2]usize,
};

fn word(b: *B) u16 {
    return b.class(&.{B.perl(.word, false)}, false);
}
fn str(b: *B, s: []const u8) u16 {
    var ks: [16]u16 = undefined;
    for (s, 0..) |c, i| ks[i] = b.lit(c);
    return if (s.len == 1) ks[0] else b.cat(ks[0..s.len]);
}

pub const cases = [_]SelfCase{
    .{ .name = "a|ab", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.alt(&.{ b.lit('a'), str(b, "ab") }); }
    }.f },
    .{ .name = "ab|a", .input = "ab", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.alt(&.{ str(b, "ab"), b.lit('a') }); }
    }.f },
    .{ .name = "foo|foobar", .input = "foobar", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.alt(&.{ str(b, "foo"), str(b, "foobar") }); }
    }.f },
    .{ .name = "a+?", .input = "aaaa", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 1, tree.unbounded, false); }
    }.f },
    .{ .name = "a{2,4}", .input = "aaaaaa", .expect = .{ 0, 4 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 2, 4, true); }
    }.f },
    .{ .name = "a{2,4}?", .input = "aaaaaa", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 2, 4, false); }
    }.f },
    .{ .name = "a{3,}", .input = "aa", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 3, tree.unbounded, true); }
    }.f },
    .{ .name = "(ab){2,3}", .input = "abababab", .expect = .{ 0, 6 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.group(str(b, "ab")), 2, 3, true); }
    }.f },
    .{ .name = "a??", .input = "a", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 0, 1, false); }
    }.f },
    .{ .name = "x*?y", .input = "xxxy", .expect = .{ 0, 4 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.rep(b.lit('x'), 0, tree.unbounded, false), b.lit('y') }); }
    }.f },
    .{ .name = "^abc$", .input = "abc\n", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.text_start), str(b, "abc"), b.assert(.text_end) }); }
    }.f },
    .{ .name = "a$", .input = "ba", .expect = .{ 1, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.assert(.text_end) }); }
    }.f },
    .{ .name = "(?m)^line2", .opt = 4, .input = "line1\nline2\nline3", .expect = .{ 6, 11 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.line_start), str(b, "line2") }); }
    }.f },
    .{ .name = "(?m)line2$", .opt = 4, .input = "line2\nline3", .expect = .{ 0, 5 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ str(b, "line2"), b.assert(.line_end) }); }
    }.f },
    .{ .name = "^b$", .input = "a\nb\nc", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.text_start), b.lit('b'), b.assert(.text_end) }); }
    }.f },
    .{ .name = "\\bcat\\b", .input = "category", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.word_boundary), str(b, "cat"), b.assert(.word_boundary) }); }
    }.f },
    .{ .name = "\\Bcat\\B", .input = "locator", .expect = .{ 2, 5 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.not_word_boundary), str(b, "cat"), b.assert(.not_word_boundary) }); }
    }.f },
    .{ .name = "\\b\\w+\\b", .input = "(h\xC3\xA9llo)", .expect = .{ 1, 7 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.word_boundary), b.plus(word(b)), b.assert(.word_boundary) }); }
    }.f },
    .{ .name = "s\\b", .input = "cats dogs", .expect = .{ 3, 4 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('s'), b.assert(.word_boundary) }); }
    }.f },
    .{ .name = "a.c", .input = "a\xFFc", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.dot(), b.lit('c') }); }
    }.f },
    .{ .name = ".", .input = "\xFFa", .expect = .{ 1, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.dot(); }
    }.f },
    .{ .name = "\\w+", .input = "ab\xFFcd", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(word(b)); }
    }.f },
    .{ .name = "a+b", .input = "aa\xFFb", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.plus(b.lit('a')), b.lit('b') }); }
    }.f },
    .{ .name = "(?i)k", .opt = 3, .input = "\u{212A}", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.lit('k'); }
    }.f },
    .{ .name = "(?i)\u{017F}", .opt = 3, .input = "S", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.lit(0x017F); }
    }.f },
    .{ .name = "(?i)\u{00C5}", .opt = 3, .input = "\u{212B}", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.lit(0x00C5); }
    }.f },
    .{ .name = "(?i)[a-z]+", .opt = 3, .input = "ABCdef", .expect = .{ 0, 6 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.range('a', 'z')}, false)); }
    }.f },
    .{ .name = "(?s)a.c", .opt = 5, .input = "a\nc", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.dot(), b.lit('c') }); }
    }.f },
    .{ .name = "a.c", .input = "a\nc", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.dot(), b.lit('c') }); }
    }.f },
    .{ .name = "\\p{Nd}+", .input = "x\u{0664}\u{0665}\u{0666}y", .expect = .{ 1, 7 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.prop("Nd", false)}, false)); }
    }.f },
    .{ .name = "\\P{L}+", .input = "abc123!!", .expect = .{ 3, 8 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.prop("L", true)}, false)); }
    }.f },
    .{ .name = "[^a-z]+", .input = "abXY12cd", .expect = .{ 2, 6 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.range('a', 'z')}, true)); }
    }.f },
    .{ .name = "(?:|.)+", .input = "c", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.alt(&.{ b.empty(), b.dot() })); }
    }.f },
    .{ .name = "(?:|a)+", .input = "aa", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.alt(&.{ b.empty(), b.lit('a') })); }
    }.f },
    .{ .name = "(|a)*", .input = "aaa", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.star(b.group(b.alt(&.{ b.empty(), b.lit('a') }))); }
    }.f },
    .{ .name = "(?:a?b??)+", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) })); }
    }.f },
    .{ .name = "(?:a??b??)+", .input = "ab", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.cat(&.{ b.rep(b.lit('a'), 0, 1, false), b.rep(b.lit('b'), 0, 1, false) })); }
    }.f },
    .{ .name = "(?:a?b?c??)+", .input = "abc", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.cat(&.{ b.opt(b.lit('a')), b.opt(b.lit('b')), b.rep(b.lit('c'), 0, 1, false) })); }
    }.f },
    .{ .name = "(?:a?b??){2,}", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) }), 2, tree.unbounded, true); }
    }.f },
    .{ .name = "(a?b??)+", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.group(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) }))); }
    }.f },
    .{ .name = "(?:a?b??)+x", .input = "abx", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.plus(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) })), b.lit('x') }); }
    }.f },
};

test "reference reproduces the human-verified conformance expectations" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    for (cases) |c| {
        var b = B.init(c.opt);
        const t = b.finish(c.build(&b));
        var r = try root.Ref.init(gpa, &t);
        defer r.deinit();
        var slots: [root.max_slots]?usize = undefined;
        const got = try r.find(c.input, .{}, slots[0..r.slotCount()]);
        const ok = if (c.expect) |e| (got != null and got.?[0] == e[0] and got.?[1] == e[1]) else got == null;
        if (!ok) {
            std.debug.print("selfcheck /{s}/ on \"{s}\": want {?any} got {?any}\n", .{ c.name, c.input, c.expect, got });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
