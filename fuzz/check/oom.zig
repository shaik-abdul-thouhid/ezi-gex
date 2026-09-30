//! Allocation-failure injection. `std.testing.checkAllAllocationFailures` runs the scenario
//! once to count allocations, then once per allocation with THAT allocation failing. Each
//! induced failure must come back as `error.OutOfMemory` with nothing leaked: a backend that
//! maps OOM to another error or silently degrades is reported as a swallowed failure.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    if (p.pattern.len > 48) return; // the scenario re-runs once per allocation
    var ibuf: [32]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const case: Case = .{ .check = .oom, .pattern = p.pattern, .input = input, .opt = p.opt };
    try known_open.runOrGate(gpa, &case, run);
}

fn Scenario(comptime B: type) type {
    return struct {
        fn f(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, opt: u8) !void {
            var diag: gex.Diagnostic = .{};
            var re = common.compileVariant(B, gpa, pattern, &diag, opt) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return, // invalid / unsupported: not an allocation outcome
            };
            defer re.deinit();
            var sc = try re.initScratch(gpa);
            defer sc.deinit(gpa);
            // Three backends allocate DURING a search, and the search API cannot return an
            // error, so an allocation failure there panics instead of surfacing OutOfMemory:
            // the bare backtracker's heap scratch grows its visited set ("input exceeds
            // buffer-backed scratch capacity"), the lazy DFA grows its transition cache ("out of
            // memory growing the lazy transition cache"), and `auto` reaches both. Recorded as a
            // finding (fuzz/README.md → Open); their compile + Scratch.init allocations are still
            // checked, and the other five backends are checked through search and replace too.
            if (B == gex.backends.backtrack or B == gex.backends.dfa or B == gex.backends.auto) return;
            _ = re.find(&sc, input);
            _ = re.count(&sc, input);
            if (comptime B.caps.captures) {
                var slots: [96]?usize = undefined;
                const ns = re.slotCount();
                if (ns > slots.len) return;
                const out = try re.replaceAllAlloc(gpa, &sc, input, "<$0>", slots[0..ns]);
                gpa.free(out);
            }
        }
    };
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.oom, true);
    inline for (common.all_backends) |B| {
        std.testing.checkAllAllocationFailures(gpa, Scenario(B).f, .{ case.pattern, case.input, case.opt }) catch |e| {
            std.debug.print("oom ({s}) on /{s}/: {s}\n", .{ @typeName(B), case.pattern, @errorName(e) });
            return e;
        };
        common.noteCompared(.oom, B);
    }
}
