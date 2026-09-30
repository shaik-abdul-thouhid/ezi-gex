//! Literal-set differential. Pure literal alternations are where the literal backend, the
//! Teddy fingerprint scan (slim ≤ 8 / fat 16 buckets), the SIMD memmem, and `auto`'s
//! prefix-set / required-literal prefilters take over — each with its own chunking and
//! verification. Leftmost-FIRST priority among overlapping members (a member that is a
//! prefix of another) and length-changing case folds are the classic ways to get them wrong.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const lits = @import("../gen/literals.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const set = lits.genSet(smith);
    var pbuf: [2048]u8 = undefined;
    const pattern = set.pattern(&pbuf) orelse return;
    var mbuf: [64]u8 = undefined;
    const m = input_gen.motif(smith, &mbuf);
    var nm: [lits.max_lit_len * 4]u8 = undefined;
    var plants: [3][]const u8 = undefined;
    plants[0] = set.get(smith.index(set.n));
    plants[1] = lits.nearMiss(set.get(smith.index(set.n)), &nm);
    plants[2] = set.get(smith.index(set.n));
    const out = try gpa.alloc(u8, input_gen.max_long_len);
    defer gpa.free(out);
    const l = input_gen.longInput(smith, out, m, &plants);
    const case: Case = .{ .check = .literals, .pattern = pattern, .input = l.bytes };
    try known_open.runOrGate(gpa, &case, run);
}

fn summarizeSet(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), input: []const u8) !common.Summary {
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var s: common.Summary = .{};
    s.pushMatch(re.find(&sc, input));
    var it = re.findAll(&sc, input);
    var k: usize = 0;
    while (it.next()) |x| : (k += 1) {
        if (k == 256) break;
        s.pushMatch(x);
    }
    return s;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, 0);
    if (ob != .ok) return error.LiteralPatternRejected;
    defer ob.ok.deinit();
    const want = try summarizeSet(gex.backends.pikevm, gpa, &ob.ok, case.input);
    common.noteRun(.literals, true);
    inline for (.{ gex.backends.literal, gex.backends.auto, gex.backends.dfa, gex.backends.edfa, gex.backends.bytepike, gex.backends.backtrack }) |B| {
        try against(B, .{}, gpa, case, &want);
    }
    try against(gex.backends.auto, .{ .strategy = .{ .simd = .off } }, gpa, case, &want);
    try against(gex.backends.auto, .{ .strategy = .{ .prefilter = false } }, gpa, case, &want);
    try against(gex.backends.auto, .{ .strategy = .{ .byte_engine = .disabled } }, gpa, case, &want);
}

fn against(comptime B: type, comptime opts: gex.Options, gpa: std.mem.Allocator, case: *const Case, want: *const common.Summary) anyerror!void {
    if (B == gex.backends.backtrack and case.input.len > 4096) return;
    var b = try common.buildWith(B, opts, gpa, case.pattern);
    if (b != .ok) return common.noteSkipped(.literals, B);
    defer b.ok.deinit();
    common.noteCompared(.literals, B);
    const got = try summarizeSet(B, gpa, &b.ok, case.input);
    if (!got.eql(want)) {
        std.debug.print("literals ({s}, opts {any}) on /{s}/ over {d} bytes:\n  pikevm {any}\n  other  {any}\n", .{
            @typeName(B), opts.strategy, case.pattern, case.input.len, want.v[0..@min(want.n, 12)], got.v[0..@min(got.n, 12)],
        });
        return error.LiteralDivergence;
    }
}
