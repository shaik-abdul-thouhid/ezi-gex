//! UTF-8 class boundaries against ground truth. Byte engines lower code-point ranges into
//! UTF-8 byte automata — the classic place for off-by-one bugs at U+7F/80, 7FF/800,
//! D7FF/E000 (the surrogate gap), FFFF/10000 and 10FFFF — and every engine must treat
//! malformed bytes (overlong, surrogate, > U+10FFFF, truncated) as matching nothing, even
//! for a NEGATED class. The expected answer comes from the ranges themselves.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const input_gen = @import("../gen/input.zig");
const uni = @import("../ref/uni.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const boundaries = [_]u21{ 0, 0x7F, 0x80, 0x3FF, 0x400, 0x7FF, 0x800, 0xFFF, 0x1000, 0xD7FF, 0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x3FFFF, 0x40000, 0x10FFFF };

pub const Class = struct { ranges: [3][2]u21 = undefined, n: usize = 0, negated: bool = false };

fn nearBoundary(smith: *Smith) u21 {
    const b: i64 = boundaries[smith.index(boundaries.len)];
    var c: i64 = b + @as(i64, smith.valueRangeAtMost(u8, 0, 4)) - 2;
    c = std.math.clamp(c, 0, 0x10FFFF);
    if (c >= 0xD800 and c <= 0xDFFF) c = if (c < 0xDC00) 0xD7FF else 0xE000;
    return @intCast(c);
}

pub fn formatClass(c: Class, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeByte('[') catch unreachable;
    if (c.negated) w.writeByte('^') catch unreachable;
    for (c.ranges[0..c.n]) |r| w.print("\\x{{{X}}}-\\x{{{X}}}", .{ r[0], r[1] }) catch unreachable;
    w.writeByte(']') catch unreachable;
    return w.buffered();
}

pub fn parseClass(s: []const u8) ?Class {
    var c: Class = .{};
    var i: usize = 0;
    if (i >= s.len or s[i] != '[') return null;
    i += 1;
    if (i < s.len and s[i] == '^') {
        c.negated = true;
        i += 1;
    }
    while (i < s.len and s[i] != ']') {
        if (c.n == c.ranges.len) return null;
        var pair: [2]u21 = undefined;
        for (&pair, 0..) |*v, k| {
            if (!std.mem.startsWith(u8, s[i..], "\\x{")) return null;
            i += 3;
            const close = std.mem.findScalarPos(u8, s, i, '}') orelse return null;
            v.* = std.fmt.parseInt(u21, s[i..close], 16) catch return null;
            i = close + 1;
            if (k == 0) {
                if (i >= s.len or s[i] != '-') return null;
                i += 1;
            }
        }
        c.ranges[c.n] = pair;
        c.n += 1;
    }
    if (i >= s.len or c.n == 0) return null;
    return c;
}

fn member(c: Class, cp: u21) bool {
    var in = false;
    for (c.ranges[0..c.n]) |r| {
        if (cp >= r[0] and cp <= r[1]) in = true;
    }
    return in != c.negated;
}

/// Leftmost valid scalar that is a member; malformed bytes are skipped one at a time.
pub fn expected(c: Class, input: []const u8) ?[2]usize {
    var i: usize = 0;
    while (i < input.len) {
        const d = uni.decode(input, i);
        if (d.valid and member(c, d.cp)) return .{ i, i + d.len };
        i += d.len;
    }
    return null;
}

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var c: Class = .{ .negated = smith.valueRangeAtMost(u8, 0, 2) == 0 };
    c.n = smith.valueRangeAtMost(u8, 1, 3);
    for (c.ranges[0..c.n]) |*r| {
        const a = nearBoundary(smith);
        const b = nearBoundary(smith);
        r.* = .{ @min(a, b), @max(a, b) };
    }
    var pbuf: [128]u8 = undefined;
    const pattern = formatClass(c, &pbuf);
    var ibuf: [96]u8 = undefined;
    var len: usize = 0;
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
        len = input_gen.evilInput(smith, ibuf[0..48]).len;
    }
    const scalars = smith.valueRangeAtMost(u8, 1, 6);
    var k: u8 = 0;
    while (k < scalars and len + 4 <= ibuf.len) : (k += 1) {
        var b: [4]u8 = undefined;
        const n = tree.encodeUtf8(nearBoundary(smith), &b);
        @memcpy(ibuf[len..][0..n], b[0..n]);
        len += n;
    }
    const case: Case = .{ .check = .utf8class, .pattern = pattern, .input = ibuf[0..len] };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const c = parseClass(case.pattern) orelse return error.BadCase;
    const want = expected(c, case.input);
    common.noteRun(.utf8class, true);
    inline for (common.all_backends) |B| try one(B, gpa, case, want);
}

fn one(comptime B: type, gpa: std.mem.Allocator, case: *const Case, want: ?[2]usize) anyerror!void {
    var b = try common.build(B, gpa, case.pattern, 0);
    if (b != .ok) return if (b == .skip) common.noteSkipped(.utf8class, B) else error.ClassRejected;
    defer b.ok.deinit();
    common.noteCompared(.utf8class, B);
    var sc = try b.ok.initScratch(gpa);
    defer sc.deinit(gpa);
    const m = b.ok.find(&sc, case.input);
    const got: ?[2]usize = if (m) |x| .{ x.start, x.end } else null;
    if (!common.spanEq(want, got)) {
        std.debug.print("utf8class ({s}) {s} over {x}: ground truth {?any}, got {?any}\n", .{ @typeName(B), case.pattern, case.input, want, got });
        return error.ClassMembership;
    }
}

test "formatClass / parseClass / expected" {
    var buf: [128]u8 = undefined;
    const c: Class = .{ .ranges = .{ .{ 0x80, 0x7FF }, .{ 0x10000, 0x10FFFF }, .{ 0, 0 } }, .n = 2, .negated = false };
    const s = formatClass(c, &buf);
    try std.testing.expectEqualStrings("[\\x{80}-\\x{7FF}\\x{10000}-\\x{10FFFF}]", s);
    const back = parseClass(s).?;
    try std.testing.expectEqual(c.n, back.n);
    try std.testing.expectEqual(c.ranges[1], back.ranges[1]);
    try std.testing.expectEqual(@as(?[2]usize, .{ 2, 4 }), expected(c, "a\xFF\xC3\xA9"));
    try std.testing.expectEqual(@as(?[2]usize, null), expected(c, "a\xED\xA0\x80")); // a surrogate encoding is not a member
    const neg: Class = .{ .ranges = c.ranges, .n = 2, .negated = true };
    try std.testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), expected(neg, "a\xC3\xA9"));
    try std.testing.expectEqual(@as(?[2]usize, null), expected(neg, "\xFF")); // dead-on-invalid even when negated
}
