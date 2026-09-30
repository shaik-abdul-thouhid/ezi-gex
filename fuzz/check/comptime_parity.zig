//! Comptime parity. Comptime and runtime share the front end but build storage differently
//! (ro_data vs heap), and the comptime path carves buffers with plain slicing only. A fixed
//! table of patterns (fuzz seeds + conformance shapes) is compiled at comptime for three
//! backends; on fuzzed inputs each must equal the runtime compile. A finite test also runs
//! the `*Comptime` matchers in the const evaluator.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const table = [_][]const u8{
    "abc",        "a|ab",           "(a(b)c)*",      "[a-c]{2,4}",        "\\d+\\w*\\s?", "(?:ab)+",
    "(?i:ABC)",   "^a.c$",          "a{0,6}b{2}",    "\\b\\w+\\b",        "(?i)aB(?-i)c", "[^a-c\\d]+",
    "(a|)*b",     "(?P<x>.)+",      "(?:|.)+",       "(|a)*",             "(?:a?b??)+",   "\\p{L}+",
    "(?i:stra\xC3\x9fe)", "[\xCE\xB1-\xCF\x89]+", "(?m)^a$", "a$|b",      "\\Bcat\\B",    "cat|dog|fish",
};
const backends = .{ gex.backends.auto, gex.backends.pikevm, gex.backends.backtrack };

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const n = smith.index(table.len);
    var ibuf: [input_gen.max_input_len]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const case: Case = .{ .check = .comptime_parity, .pattern = table[n], .input = input, .n = n };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.n >= table.len) return error.BadCase;
    common.noteRun(.comptime_parity, true);
    switch (case.n) {
        inline 0...table.len - 1 => |i| inline for (backends) |B| try parity(B, i, gpa, case.input),
        else => unreachable,
    }
}

fn parity(comptime B: type, comptime i: usize, gpa: std.mem.Allocator, input: []const u8) anyerror!void {
    const ct = comptime gex.compileComptimeWith(B, table[i], .{});
    var rt = try common.build(B, gpa, table[i], 0);
    if (rt != .ok) return error.RuntimeRejectsComptimePattern;
    defer rt.ok.deinit();
    const want = try common.summarize(B, gpa, &rt.ok, input);
    const got = try common.summarize(B, gpa, &ct, input);
    if (!got.eql(&want)) {
        std.debug.print("comptime parity ({s}) /{s}/ over \"{s}\":\n  runtime  {any}\n  comptime {any}\n", .{ @typeName(B), table[i], input, want.v[0..want.n], got.v[0..got.n] });
        return error.ComptimeRuntimeDivergence;
    }
    common.noteCompared(.comptime_parity, B);
}

fn matchEq(a: ?gex.Match, b: ?gex.Match) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.start == b.?.start and a.?.end == b.?.end;
}

test "comptime matchers (const-evaluated) agree with runtime" {
    const gpa = std.testing.allocator;
    inline for (.{ "a|ab", "(a)(b)?", "\\bcat\\b", "(?:|.)+" }) |p| {
        const re = comptime gex.compileComptimeWith(gex.backends.auto, p, .{});
        var rt = try common.build(gex.backends.auto, gpa, p, 0);
        defer rt.ok.deinit();
        var sc = try rt.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        inline for (.{ "ab", "a cat!", "c", "xab ab" }) |in| {
            const cm = comptime re.findComptime(in);
            const cc = comptime re.countComptime(in);
            const ci = comptime re.isMatchComptime(in);
            try std.testing.expect(matchEq(cm, rt.ok.find(&sc, in)));
            try std.testing.expectEqual(cc, rt.ok.count(&sc, in));
            try std.testing.expectEqual(ci, rt.ok.isMatch(&sc, in));
        }
    }
}
