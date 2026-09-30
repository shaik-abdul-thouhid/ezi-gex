//! Reference differential — the one check that can catch a bug in ezi_gex's SHARED front
//! end: Pike VM, backtrack, and `auto` must agree with the independent reference matcher
//! (ref/) on the span, every capture slot, and the findAll sequence, over trees printed in
//! a random equivalent spelling under a random (compatible) option variant.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const witness = @import("../gen/witness.zig");
const ref = @import("../ref/root.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

const max_matches = 64;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const popt = common.printOpt(smith, t.opt);
    const seed = smith.value(u64);
    var ibuf: [2 * witness.max_witness]u8 = undefined;
    const input = try common.inputWithWitness(gpa, smith, &t, &ibuf);
    const pr = print.variant(&t, popt, seed) orelse return;
    const case: Case = .{ .check = .reference, .pattern = pr.slice(), .input = input, .tree = t.bytes(), .opt = popt, .seed = seed };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const t = tree.Tree.fromBytes(case.tree) orelse return error.BadTree;
    if (!print.compatibleOpts(t.opt, case.opt)) return error.BadCase;
    const pr = print.variant(&t, case.opt, case.seed) orelse return;
    var r = ref.Ref.init(gpa, &t) catch |e| switch (e) {
        error.ProgramTooBig => return,
        else => return e,
    };
    defer r.deinit();
    const ns = r.slotCount();
    var want_slots: [ref.max_slots]?usize = undefined;
    const want = try r.find(case.input, .{}, want_slots[0..ns]);
    var want_all: std.ArrayList([2]usize) = .empty;
    defer want_all.deinit(gpa);
    try r.findAll(case.input, &want_all, max_matches);
    common.noteRun(.reference, true);
    inline for (.{ gex.backends.pikevm, gex.backends.backtrack, gex.backends.auto }) |B| {
        try check(B, gpa, pr.slice(), case, want, want_slots[0..ns], want_all.items);
    }
}

fn check(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, case: *const Case, want: ?[2]usize, want_slots: []const ?usize, want_all: []const [2]usize) anyerror!void {
    var built = try common.build(B, gpa, pattern, case.opt);
    switch (built) {
        .ok => {},
        .invalid => {
            std.debug.print("reference: {s} rejected a printed tree /{s}/\n", .{ @typeName(B), pattern });
            return error.PrintedTreeRejected;
        },
        .skip => return common.noteSkipped(.reference, B),
    }
    const re = &built.ok;
    defer re.deinit();
    common.noteCompared(.reference, B);
    if (re.slotCount() != want_slots.len) {
        std.debug.print("reference ({s}): slot count {d} != reference {d}\n", .{ @typeName(B), re.slotCount(), want_slots.len });
        return error.CaptureCountMismatch;
    }
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var slots: [ref.max_slots]?usize = undefined;
    const got = re.captures(&sc, slots[0..want_slots.len], case.input);
    const got_span: ?[2]usize = if (got) |c| .{ c.match().start, c.match().end } else null;
    if (!common.spanEq(want, got_span)) {
        std.debug.print("reference ({s}): span want {?any} got {?any}\n", .{ @typeName(B), want, got_span });
        return error.ReferenceSpan;
    }
    if (got != null and !common.slotsEq(want_slots, slots[0..want_slots.len])) {
        std.debug.print("reference ({s}): slots want {any} got {any}\n", .{ @typeName(B), want_slots, slots[0..want_slots.len] });
        return error.ReferenceCaptures;
    }
    var it = re.findAll(&sc, case.input);
    for (want_all, 0..) |w, k| {
        const m = it.next() orelse {
            std.debug.print("reference ({s}): findAll ended after {d} matches, reference has {d} (next {any})\n", .{ @typeName(B), k, want_all.len, w });
            return error.ReferenceFindAll;
        };
        if (m.start != w[0] or m.end != w[1]) {
            std.debug.print("reference ({s}): findAll[{d}] want {any} got [{d},{d}]\n", .{ @typeName(B), k, w, m.start, m.end });
            return error.ReferenceFindAll;
        }
    }
    if (want_all.len < max_matches) if (it.next()) |m| {
        std.debug.print("reference ({s}): findAll has an extra match [{d},{d}] after {d}\n", .{ @typeName(B), m.start, m.end, want_all.len });
        return error.ReferenceFindAll;
    };
}

test "reference check passes on a simple case and rejects a corrupt tree" {
    const gpa = std.testing.allocator;
    var b = tree.Builder.init(0);
    const t = b.finish(b.alt(&.{ b.lit('a'), b.cat(&.{ b.lit('a'), b.lit('b') }) }));
    const pr = print.canonical(&t, 0).?;
    try run(gpa, &.{ .check = .reference, .pattern = pr.slice(), .input = "xab", .tree = t.bytes() });
    try std.testing.expectError(error.BadTree, run(gpa, &.{ .check = .reference, .tree = "junk" }));
}
