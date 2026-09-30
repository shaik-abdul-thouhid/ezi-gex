//! The reference matcher: an independent, deliberately naive regex engine that consumes
//! the generator's semantic `Tree` directly (no parser), so a bug anywhere in ezi_gex's
//! shared scanner → AST → HIR → nfa front end cannot make it agree. Never imports
//! `ezi_gex`; Unicode facts come from `ezi_code` point lookups (`uni.zig`).

const std = @import("std");
const tree = @import("../gen/tree.zig");
const testing = std.testing;
const B = tree.Builder;

pub const uni = @import("uni.zig");
pub const nfa = @import("nfa.zig");
pub const pike = @import("pike.zig");

pub const max_slots = 2 * (@as(usize, tree.max_groups) + 1);

pub const Ref = struct {
    gpa: std.mem.Allocator,
    t: *const tree.Tree,
    prog: nfa.Prog,

    pub fn init(gpa: std.mem.Allocator, t: *const tree.Tree) !Ref {
        return .{ .gpa = gpa, .t = t, .prog = try nfa.compile(gpa, t) };
    }

    pub fn deinit(r: *Ref) void {
        r.prog.deinit(r.gpa);
    }

    pub fn slotCount(r: *const Ref) usize {
        return r.prog.n_slots;
    }

    /// Leftmost-first match; `slots.len == slotCount()`, filled on a match.
    pub fn find(r: *const Ref, input: []const u8, so: pike.Search, slots: []?usize) !?[2]usize {
        const vm: pike.Vm = .{ .gpa = r.gpa, .prog = &r.prog, .t = r.t, .sem = tree.opt_sem[r.t.opt] };
        if (!try vm.search(input, so, slots)) return null;
        return .{ slots[0].?, slots[1].? };
    }

    /// Non-overlapping matches (at most `max`). After an empty match the next search starts
    /// one SCALAR on — the decoded length, or one byte over a malformed byte.
    pub fn findAll(r: *const Ref, input: []const u8, out: *std.ArrayList([2]usize), max: usize) !void {
        var slots: [max_slots]?usize = undefined;
        const s = slots[0..r.slotCount()];
        var pos: usize = 0;
        while (pos <= input.len and out.items.len < max) {
            const m = (try r.find(input, .{ .start = pos }, s)) orelse break;
            try out.append(r.gpa, m);
            pos = if (m[1] > m[0]) m[1] else if (m[1] >= input.len) input.len + 1 else m[1] + uni.decode(input, m[1]).len;
        }
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

fn expectFind(t: tree.Tree, input: []const u8, so: pike.Search, want: ?[2]usize) !void {
    var r = try Ref.init(testing.allocator, &t);
    defer r.deinit();
    var slots: [max_slots]?usize = undefined;
    const got = try r.find(input, so, slots[0..r.slotCount()]);
    if ((got == null) != (want == null) or (got != null and (got.?[0] != want.?[0] or got.?[1] != want.?[1]))) {
        std.debug.print("ref: input \"{s}\" so={any}: want {?any} got {?any}\n", .{ input, so, want, got });
        return error.RefMismatch;
    }
}

test "leftmost-first alternation and laziness" {
    var b = B.init(0);
    try expectFind(b.finish(b.alt(&.{ b.lit('a'), b.cat(&.{ b.lit('a'), b.lit('b') }) })), "ab", .{}, .{ 0, 1 });
    b = B.init(0);
    try expectFind(b.finish(b.rep(b.lit('a'), 1, tree.unbounded, false)), "aaa", .{}, .{ 0, 1 });
    b = B.init(0);
    try expectFind(b.finish(b.rep(b.lit('a'), 2, 3, true)), "aaaa", .{}, .{ 0, 3 });
}

test "RE2/Rust empty-width loops (the 0.6.0 semantics)" {
    var b = B.init(0);
    try expectFind(b.finish(b.plus(b.alt(&.{ b.empty(), b.dot() }))), "c", .{}, .{ 0, 0 }); // (?:|.)+
    b = B.init(0);
    try expectFind(b.finish(b.star(b.group(b.alt(&.{ b.empty(), b.lit('a') })))), "aaa", .{}, .{ 0, 0 }); // (|a)*
    b = B.init(0);
    try expectFind(b.finish(b.plus(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) }))), "ab", .{}, .{ 0, 1 }); // (?:a?b??)+
    b = B.init(0);
    try expectFind(b.finish(b.plus(b.cat(&.{ b.rep(b.lit('a'), 0, 1, false), b.rep(b.lit('b'), 0, 1, false) }))), "ab", .{}, .{ 0, 0 }); // (?:a??b??)+
}

test "anchors, word boundaries, dead-on-invalid" {
    var b = B.init(0);
    try expectFind(b.finish(b.cat(&.{ b.lit('a'), b.lit('b'), b.lit('c'), b.assert(.text_end) })), "abc\n", .{}, null); // abc$
    b = B.init(4); // (?m)
    try expectFind(b.finish(b.cat(&.{ b.assert(.line_start), b.lit('b') })), "a\nb", .{}, .{ 2, 3 });
    b = B.init(0);
    const w = b.plus(b.class(&.{B.perl(.word, false)}, false));
    try expectFind(b.finish(b.cat(&.{ b.assert(.word_boundary), w, b.assert(.word_boundary) })), "\xC3\xA9b", .{}, .{ 0, 3 });
    b = B.init(0);
    try expectFind(b.finish(b.dot()), "\xFF", .{}, null);
    b = B.init(0);
    try expectFind(b.finish(b.dot()), "\xFFa", .{}, .{ 1, 2 }); // resync one byte on
    b = B.init(0);
    try expectFind(b.finish(b.cat(&.{ b.lit('a'), b.dot(), b.lit('b') })), "a\xFFb", .{}, null);
    b = B.init(3); // (?i)
    try expectFind(b.finish(b.lit('k')), "\xE2\x84\xAA", .{}, .{ 0, 3 });
}

test "captures" {
    var b = B.init(0);
    const t = b.finish(b.cat(&.{ b.group(b.lit('a')), b.opt(b.group(b.lit('b'))) })); // (a)(b)?
    var r = try Ref.init(testing.allocator, &t);
    defer r.deinit();
    var slots: [max_slots]?usize = undefined;
    const s = slots[0..r.slotCount()];
    _ = (try r.find("a", .{}, s)).?;
    try testing.expectEqualSlices(?usize, &.{ 0, 1, 0, 1, null, null }, s);
}

test "odd search options never panic" {
    var b = B.init(0);
    const t = b.finish(b.dot());
    try expectFind(t, "\xC3\xA9", .{ .start = 1 }, null); // start inside a code point
    try expectFind(t, "\xC3\xA9x", .{ .start = 1 }, .{ 2, 3 });
    try expectFind(t, "ab", .{ .start = 2 }, null); // start == len
    try expectFind(t, "ab", .{ .start = 2, .span_end = 1 }, null); // span_end < start
    try expectFind(t, "ab", .{ .start = 1, .anchored = true }, .{ 1, 2 });
    try expectFind(t, "ab", .{ .span_end = 1 }, .{ 0, 1 });
}

test "findAll steps one scalar after an empty match (one byte over a malformed byte)" {
    var b = B.init(0);
    const t = b.finish(b.opt(b.lit('a'))); // a?
    var r = try Ref.init(testing.allocator, &t);
    defer r.deinit();
    var out: std.ArrayList([2]usize) = .empty;
    defer out.deinit(testing.allocator);
    try r.findAll("\xE6a", &out, 16);
    try testing.expectEqualSlices([2]usize, &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 2, 2 } }, out.items);
}
