//! Chaos: the other checks each favour their own generators; this one builds a single
//! richly-populated case — a tree printed under a random compatible option variant, an
//! input that usually contains a witness, a hostile template, random search options — and
//! pushes it through every check that can take it, so combinations no single group favours
//! (e.g. an Options-seeded `(?i)` tree under a dirty scratch with a `${name}` template) run.

const std = @import("std");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const reference = @import("reference.zig");
const metamorphic = @import("metamorphic.zig");
const invariants = @import("invariants.zig");
const state = @import("state.zig");
const api = @import("api.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const opt = common.printOpt(smith, t.opt);
    const seed = smith.value(u64);
    var ibuf: [state.max_hay]u8 = undefined;
    const input = try common.inputWithWitness(gpa, smith, &t, &ibuf);
    const pr = print.variant(&t, opt, seed) orelse return;
    var tbuf: [48]u8 = undefined;
    const start = smith.index(input.len + 1);
    const case: Case = .{
        .check = .chaos,
        .pattern = pr.slice(),
        .input = input,
        .tree = t.bytes(),
        .opt = opt,
        .seed = seed,
        .opt2 = common.printOpt(smith, t.opt),
        .seed2 = smith.value(u64) | 1,
        .template = api.genTemplate(smith, &tbuf),
        .n = smith.valueRangeAtMost(u8, 0, 5),
        .start = start,
        .anchored = smith.valueRangeAtMost(u8, 0, 1) == 0,
        .span_end = if (smith.valueRangeAtMost(u8, 0, 3) == 0) start + smith.index(input.len - start + 1) else null,
    };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.chaos, true);
    inline for (.{ reference.run, metamorphic.run, invariants.run, state.run, api.run }) |sub| try sub(gpa, case);
}
