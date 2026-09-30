//! A compiled `Program` is immutable and shareable across threads; all per-search state
//! lives in the caller's Scratch (docs/architecture.md §9, "Implicit assumptions" #5). So
//! four threads, each with its own Scratch, searching the SAME compiled regexes must get
//! exactly the serial answers. Finite (runs in `zig build test`).

const std = @import("std");
const gex = @import("ezi_gex");
const lib = @import("fuzz_lib");
const common = lib.check.common;
const input_gen = lib.gen.input;

const n_patterns = 20;
const n_inputs = 40;
const n_threads = 4;

const Ctx = struct {
    re: *const gex.Compiled(gex.backends.auto),
    inputs: []const []const u8,
    out: []common.Summary,
    failed: bool = false,

    fn work(ctx: *Ctx) void {
        for (ctx.inputs, ctx.out) |in, *o| {
            o.* = common.summarize(gex.backends.auto, std.testing.allocator, ctx.re, in) catch {
                ctx.failed = true;
                return;
            };
        }
    }
};

test "shared Program across threads matches serial results" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(61);
    var sb: [4096]u8 = undefined;
    var in_store: [n_inputs][input_gen.max_input_len]u8 = undefined;
    var inputs: [n_inputs][]const u8 = undefined;
    for (&inputs, &in_store) |*in, *st| {
        var s = lib.gen.replay.smith(&prng, &sb);
        in.* = input_gen.pickSmall(&s, st);
    }
    var done: usize = 0;
    while (done < n_patterns) {
        var s = lib.gen.replay.smith(&prng, &sb);
        var pb: common.PatBuf = .{};
        const p = common.pickPattern(&s, &pb) orelse continue;
        var b = try common.build(gex.backends.auto, gpa, p.pattern, p.opt);
        if (b != .ok) continue;
        defer b.ok.deinit();
        done += 1;
        var serial: [n_inputs]common.Summary = undefined;
        for (inputs, &serial) |in, *o| o.* = try common.summarize(gex.backends.auto, gpa, &b.ok, in);
        var outs: [n_threads][n_inputs]common.Summary = undefined;
        var ctxs: [n_threads]Ctx = undefined;
        var threads: [n_threads]std.Thread = undefined;
        for (&ctxs, &outs, &threads) |*c, *o, *t| {
            c.* = .{ .re = &b.ok, .inputs = &inputs, .out = o };
            t.* = try std.Thread.spawn(.{}, Ctx.work, .{c});
        }
        for (threads) |t| t.join();
        for (ctxs, outs) |c, o| {
            try std.testing.expect(!c.failed);
            for (serial, o, 0..) |want, got, k| {
                if (!got.eql(&want)) {
                    std.debug.print("threads: /{s}/ over \"{s}\" differs from serial\n", .{ p.pattern, inputs[k] });
                    return error.ThreadDivergence;
                }
            }
        }
    }
}
