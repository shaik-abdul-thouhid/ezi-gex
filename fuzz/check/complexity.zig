//! Complexity, deterministically. `redos.zig` pins the ReDoS-immunity claim on hand-picked
//! catastrophic patterns; this extends it to GENERATED patterns using the same timer-free
//! observables: the bounded backtracker's `(pc, sp)` memo probe count must grow ≤ 2.25× per
//! input doubling, and `auto` must never do per-occurrence confirms on an end-anchored
//! program (its documented anti-Θ(n²) contract; `prone` programs are classified inside
//! `auto` and are not externally observable, so only `anchored_end` is checked).

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
    var mbuf: [32]u8 = undefined;
    const m = input_gen.motif(smith, &mbuf);
    const case: Case = .{
        .check = .complexity,
        .pattern = p.pattern,
        .input = m,
        .opt = p.opt,
        .n = smith.valueRangeAtMost(u8, 8, 64),
        .seed = smith.value(u8),
    };
    try known_open.runOrGate(gpa, &case, run);
}

fn repeated(gpa: std.mem.Allocator, motif: []const u8, reps: usize, tail: u8) ![]u8 {
    const out = try gpa.alloc(u8, motif.len * reps + 1);
    for (0..reps) |i| @memcpy(out[i * motif.len ..][0..motif.len], motif);
    out[out.len - 1] = tail;
    return out;
}

fn anchoredEnd(gpa: std.mem.Allocator, pattern: []const u8) bool {
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = gex.buildHir(gpa, ast, .{}) catch return false;
    defer gex.freeHir(gpa, h);
    return h.analysis.anchored_end;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.input.len == 0 or case.n == 0) return;
    const tail: u8 = @truncate(case.seed);
    var bb = try common.build(gex.backends.backtrack, gpa, case.pattern, case.opt);
    if (bb != .ok) return;
    defer bb.ok.deinit();
    common.noteRun(.complexity, true);

    var steps: [3]u64 = undefined;
    for ([_]usize{ 1, 2, 4 }, 0..) |mult, i| {
        const in = try repeated(gpa, case.input, case.n * mult, tail);
        defer gpa.free(in);
        if (in.len > 4096) return;
        var sc = try bb.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        _ = bb.ok.find(&sc, in);
        steps[i] = sc.inner.steps;
    }
    common.noteCompared(.complexity, gex.backends.backtrack);
    if (steps[0] >= 512) {
        const slack = 256 + steps[0] / 4;
        if (4 * steps[1] > 9 * steps[0] + slack or 4 * steps[2] > 9 * steps[1] + slack) {
            std.debug.print("complexity: /{s}/ backtrack steps {d} → {d} → {d} over n/2n/4n (motif \"{s}\" ×{d}, tail 0x{X:0>2})\n", .{ case.pattern, steps[0], steps[1], steps[2], case.input, case.n, tail });
            return error.SuperLinearWork;
        }
    }

    if (case.opt != 4 and anchoredEnd(gpa, case.pattern)) {
        var ab = try common.build(gex.backends.auto, gpa, case.pattern, case.opt);
        if (ab != .ok) return;
        defer ab.ok.deinit();
        const in = try repeated(gpa, case.input, case.n * 4, tail);
        defer gpa.free(in);
        var sc = try ab.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        _ = ab.ok.find(&sc, in);
        common.noteCompared(.complexity, gex.backends.auto);
        if (sc.inner.confirm_probes != 0) {
            std.debug.print("complexity: /{s}/ is end-anchored but auto did {d} per-occurrence confirms\n", .{ case.pattern, sc.inner.confirm_probes });
            return error.PrefilterConfirmsOnEndAnchored;
        }
    }
}

/// Compile bombs: nested counted repetitions (depth 1–3, counts up to 3000, each under
/// max_repetition). Compiling under the default Options must either reject with
/// PatternTooComplex having allocated < 1 MiB, or succeed within a memory budget
/// proportional to size_limit — and success must imply expandedSize ≤ size_limit.
pub fn bombOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const bodies = [_][]const u8{ "a", "[a-z]", "\\p{L}", "(?:ab|c)", "\\w", "(a)", "." };
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const depth = smith.valueRangeAtMost(u8, 1, 3);
    var d: u8 = 0;
    while (d < depth) : (d += 1) w.writeAll("(?:") catch return;
    w.writeAll(bodies[smith.index(bodies.len)]) catch return;
    d = 0;
    while (d < depth) : (d += 1) {
        const lo = smith.valueRangeAtMost(u16, 0, 3000);
        const hi = smith.valueRangeAtMost(u16, lo, 3000);
        w.print("){{{d},{d}}}", .{ lo, hi }) catch return;
    }
    const case: Case = .{ .check = .compile_bomb, .pattern = w.buffered() };
    try known_open.runOrGate(gpa, &case, runBomb);
}

/// Bytes a successful compile may allocate per `expandedSize` unit (generous: the
/// widest instruction plus its share of side tables and the byte/DFA arms of `auto`).
const bytes_per_unit = 256;

pub fn runBomb(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.compile_bomb, true);
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, case.pattern, &diag) catch return; // scanner-rejected: not a bomb
    defer ast.deinit(gpa);
    const h = try gex.buildHir(gpa, ast, .{});
    defer gex.freeHir(gpa, h);
    const size = gex.hir.expandedSize(h);
    var counting = std.testing.FailingAllocator.init(gpa, .{});
    var re = gex.compileRuntime(counting.allocator(), case.pattern, &diag, .{}) catch |e| switch (e) {
        error.PatternTooComplex => {
            if (size <= gex.hir.default_size_limit) return error.RejectedUnderLimit;
            if (counting.allocated_bytes >= 1 << 20) {
                std.debug.print("compile bomb /{s}/: rejected after allocating {d} bytes\n", .{ case.pattern, counting.allocated_bytes });
                return error.RejectionAllocatedTooMuch;
            }
            return;
        },
        else => return e,
    };
    defer re.deinit();
    common.noteCompared(.compile_bomb, gex.backends.auto);
    if (size > gex.hir.default_size_limit) return error.AcceptedOverLimit;
    if (counting.allocated_bytes > size * bytes_per_unit + (1 << 20)) {
        std.debug.print("compile bomb /{s}/: size {d} but compile allocated {d} bytes\n", .{ case.pattern, size, counting.allocated_bytes });
        return error.CompileMemoryOverBudget;
    }
}
