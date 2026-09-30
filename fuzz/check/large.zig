//! Large-input differential. The small-input groups stop at 64 bytes, but `auto` only
//! switches its NFA engine at 4096 bytes, the DFA arms have per-search reach budgets, and
//! the memmem / Teddy / class-scan loops unroll across 16/32/64-byte blocks. Long inputs
//! built from a repeated motif, with the tree's witness (and a near-miss) planted at block
//! edges and near the end, reach all of that.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const witness = @import("../gen/witness.zig");
const lits = @import("../gen/literals.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub var over_4096: u32 = 0;
const max_spans = 256;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const popt = common.printOpt(smith, t.opt);
    const pr = print.variant(&t, popt, smith.value(u64)) orelse return;
    var w = try witness.sample(gpa, &t, smith.value(u64));
    var nm: [witness.max_witness]u8 = undefined;
    var mbuf: [64]u8 = undefined;
    const m = input_gen.motif(smith, &mbuf);
    var plants: [3][]const u8 = undefined;
    var np: usize = 0;
    if (w) |*ww| {
        plants[0] = ww.slice();
        plants[1] = lits.nearMiss(ww.slice(), &nm);
        plants[2] = ww.slice();
        np = 3;
    }
    const out = try gpa.alloc(u8, input_gen.max_long_len);
    defer gpa.free(out);
    const l = input_gen.longInput(smith, out, m, plants[0..np]);
    if (l.bytes.len > 4096) over_4096 += 1;
    const case: Case = .{ .check = .large, .pattern = pr.slice(), .input = l.bytes, .opt = popt };
    try known_open.runOrGate(gpa, &case, run);
}

fn summarizeLong(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), input: []const u8) !common.Summary {
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var s: common.Summary = .{};
    s.pushMatch(re.find(&sc, input));
    s.push(@intFromBool(re.isMatch(&sc, input)));
    var it = re.findAll(&sc, input);
    var k: usize = 0;
    while (it.next()) |m| : (k += 1) {
        if (k == max_spans) break;
        s.pushMatch(m);
    }
    return s;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (ob != .ok) return;
    defer ob.ok.deinit();
    const want = try summarizeLong(gex.backends.pikevm, gpa, &ob.ok, case.input);
    common.noteRun(.large, true);
    const byte_safe = common.byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (common.span_backends) |B| try one(B, gpa, case, byte_safe, &want);
}

fn one(comptime B: type, gpa: std.mem.Allocator, case: *const Case, byte_safe: bool, want: *const common.Summary) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.large, B);
    if (B == gex.backends.backtrack and case.input.len > 4096) return common.noteSkipped(.large, B);
    var b = try common.build(B, gpa, case.pattern, case.opt);
    if (b != .ok) return if (b == .skip) common.noteSkipped(.large, B) else error.ValidityDisagreement;
    defer b.ok.deinit();
    common.noteCompared(.large, B);
    const got = try summarizeLong(B, gpa, &b.ok, case.input);
    if (!got.eql(want)) {
        var first: usize = 0;
        while (first < @min(got.n, want.n) and got.v[first] == want.v[first]) first += 1;
        std.debug.print("large ({s}) on /{s}/ over {d} bytes: first difference at summary index {d}: pikevm {any} vs {any}\n", .{
            @typeName(B), case.pattern, case.input.len, first, want.v[first..@min(first + 4, want.n)], got.v[first..@min(first + 4, got.n)],
        });
        return error.LargeDivergence;
    }
}
