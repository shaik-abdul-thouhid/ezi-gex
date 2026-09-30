//! `\X` against an independent oracle. `\X` runs only on the backtracker (and `auto`, which
//! routes it there), so it has no differential partner inside ezi_gex — until now it was
//! fuzzed for "no crash" only. ezi_code's UAX #29 segmenter is the oracle: over valid
//! UTF-8, `findAll(\X)` must tile the input into exactly its clusters.

const std = @import("std");
const gex = @import("ezi_gex");
const ez = @import("ezi_code");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const cluster_pool = [_][]const u8{
    "a", "e\u{301}", "\u{1F1FA}\u{1F1F8}", "\u{1F468}\u{200D}\u{1F469}", "\r\n", "\u{1100}\u{1161}\u{11A8}",
    "\n", "\u{0915}\u{094D}\u{0937}", "\u{1F44D}\u{1F3FD}", " ", "\u{0301}", "\u{AC00}", "\r",
};

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var buf: [160]u8 = undefined;
    var len: usize = 0;
    const n = smith.valueRangeAtMost(u8, 0, 10);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const p = cluster_pool[smith.index(cluster_pool.len)];
        if (len + p.len > buf.len) break;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    const case: Case = .{ .check = .grapheme, .pattern = "\\X", .input = buf[0..len] };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (!common.isValidUtf8(case.input)) return error.BadCase;
    common.noteRun(.grapheme, true);
    inline for (.{ gex.backends.backtrack, gex.backends.auto }) |B| {
        var b = try common.build(B, gpa, "\\X", 0);
        if (b != .ok) return error.GraphemeUnsupported;
        defer b.ok.deinit();
        var sc = try b.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        var it = b.ok.findAll(&sc, case.input);
        var seg = ez.unicode.segmentation.iterator(case.input);
        var pos: usize = 0;
        while (seg.next()) |cluster| {
            const m = it.next() orelse {
                std.debug.print("grapheme ({s}): \\X stopped at {d}, expected cluster \"{s}\"\n", .{ @typeName(B), pos, cluster });
                return error.GraphemeTiling;
            };
            if (m.start != pos or m.end != pos + cluster.len) {
                std.debug.print("grapheme ({s}): \\X [{d},{d}] vs cluster [{d},{d}] over {x}\n", .{ @typeName(B), m.start, m.end, pos, pos + cluster.len, case.input });
                return error.GraphemeTiling;
            }
            pos += cluster.len;
        }
        if (it.next()) |m| if (!m.isEmpty()) {
            std.debug.print("grapheme ({s}): extra \\X match [{d},{d}] after the last cluster\n", .{ @typeName(B), m.start, m.end });
            return error.GraphemeTiling;
        };
        common.noteCompared(.grapheme, B);
    }
    if (case.input.len > 0) {
        var b = try common.build(gex.backends.auto, gpa, "\\X+", 0);
        defer if (b == .ok) b.ok.deinit();
        if (b == .ok) {
            var sc = try b.ok.initScratch(gpa);
            defer sc.deinit(gpa);
            const m = b.ok.find(&sc, case.input) orelse return error.GraphemePlusNoMatch;
            if (m.start != 0 or m.end != case.input.len) return error.GraphemePlusNotWhole;
        }
    }
}
