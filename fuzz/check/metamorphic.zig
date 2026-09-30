//! Metamorphic check. Each printer choice (escape spelling, grouping, flag placement,
//! `(?x)` text, quantifier spelling, `{m,n}` expansion, named vs numbered groups,
//! Options-seeded vs inline flags) is a no-op the front end must honour; so two printings
//! of one tree must produce the same Summary on every backend. And when every node is
//! `(?i)` under simple folding, swapping input code points within their fold orbits must
//! not change `isMatch` or the match count.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const input_gen = @import("../gen/input.zig");
const witness = @import("../gen/witness.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const opt_a = common.printOpt(smith, t.opt);
    const opt_b = common.printOpt(smith, t.opt);
    const seed_a = smith.value(u64);
    const seed_b = smith.value(u64) | 1;
    var ibuf: [2 * witness.max_witness]u8 = undefined;
    const input = try common.inputWithWitness(gpa, smith, &t, &ibuf);
    const pa = print.variant(&t, opt_a, seed_a) orelse return;
    const case: Case = .{ .check = .metamorphic, .pattern = pa.slice(), .input = input, .tree = t.bytes(), .opt = opt_a, .seed = seed_a, .opt2 = opt_b, .seed2 = seed_b };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn allCaseInsensitive(t: *const tree.Tree) bool {
    for (t.nodes[0..t.n_nodes]) |n| if (!n.flags.i) return false;
    return true;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const t = tree.Tree.fromBytes(case.tree) orelse return error.BadTree;
    if (!print.compatibleOpts(t.opt, case.opt) or !print.compatibleOpts(t.opt, case.opt2)) return error.BadCase;
    const pa = print.variant(&t, case.opt, case.seed) orelse return;
    const pb = print.variant(&t, case.opt2, case.seed2) orelse return;
    common.noteRun(.metamorphic, true);
    const byte_safe = common.byteEnginesSafe(gpa, pa.slice(), case.input);
    inline for (common.all_backends) |B| try pair(B, gpa, case, pa.slice(), pb.slice(), byte_safe);
    if (allCaseInsensitive(&t) and tree.opt_sem[t.opt].fold) try foldSwapRelation(gpa, case, pa.slice());
}

fn pair(comptime B: type, gpa: std.mem.Allocator, case: *const Case, pa: []const u8, pb: []const u8, byte_safe: bool) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.metamorphic, B);
    var ba = try common.build(B, gpa, pa, case.opt);
    defer if (ba == .ok) ba.ok.deinit();
    var bb = try common.build(B, gpa, pb, case.opt2);
    defer if (bb == .ok) bb.ok.deinit();
    if (ba == .skip or bb == .skip) return common.noteSkipped(.metamorphic, B);
    if (ba == .invalid or bb == .invalid) {
        std.debug.print("metamorphic ({s}): validity A={s} B={s}\n  A=/{s}/\n  B=/{s}/\n", .{ @typeName(B), @tagName(ba), @tagName(bb), pa, pb });
        return error.PrintedTreeRejected;
    }
    common.noteCompared(.metamorphic, B);
    const sa = try common.summarize(B, gpa, &ba.ok, case.input);
    const sb = try common.summarize(B, gpa, &bb.ok, case.input);
    if (!sa.eql(&sb)) {
        std.debug.print("metamorphic ({s}): printings disagree\n  A=/{s}/ → {any}\n  B=/{s}/ → {any}\n", .{ @typeName(B), pa, sa.v[0..sa.n], pb, sb.v[0..sb.n] });
        return error.MetamorphicDivergence;
    }
}

fn foldSwapRelation(gpa: std.mem.Allocator, case: *const Case, pattern: []const u8) anyerror!void {
    var sbuf: [4 * 2 * witness.max_witness]u8 = undefined;
    const swapped = input_gen.foldSwap(case.input, &sbuf, case.seed2);
    inline for (.{ gex.backends.pikevm, gex.backends.auto }) |B| {
        var b = try common.build(B, gpa, pattern, case.opt);
        if (b == .ok) {
            defer b.ok.deinit();
            var sc = try b.ok.initScratch(gpa);
            defer sc.deinit(gpa);
            const m1 = b.ok.isMatch(&sc, case.input);
            const m2 = b.ok.isMatch(&sc, swapped);
            const c1 = b.ok.count(&sc, case.input);
            const c2 = b.ok.count(&sc, swapped);
            if (m1 != m2 or c1 != c2) {
                std.debug.print("fold-swap ({s}): /{s}/ isMatch {} vs {}, count {d} vs {d}\n  in  = \"{s}\"\n  swap= \"{s}\"\n", .{ @typeName(B), pattern, m1, m2, c1, c2, case.input, swapped });
                return error.FoldSwapDivergence;
            }
        }
    }
}
