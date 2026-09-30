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

/// Whether every match of `pattern` ends at input end AND the pattern has no `\A`. `auto`
/// finds such a pattern with one reverse pass from the end, never per-occurrence confirms. A
/// `\A` rules that pass out (the reverse DFA can't evaluate it), so there the eager DFA's
/// bounded confirms are the design — a prone `\A` pattern, where they would add up to Θ(n²),
/// is declined off the DFAs entirely (conformance regression "a prone pattern with a partial
/// \A…"). Those confirms are not counted here as a violation.
fn anchoredEnd(gpa: std.mem.Allocator, pattern: []const u8) bool {
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = gex.buildHir(gpa, ast, .{}) catch return false;
    defer gex.freeHir(gpa, h);
    for (h.nodes) |n| {
        if (n.tag == .anchor and n.data.anchor.kind == .text_start) return false;
    }
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

    // End-anchored patterns must never take `auto`'s per-occurrence confirm. Few generated
    // patterns end in `$` (~1 %), so a pattern that doesn't is checked as `(?:p)$` — the
    // group scopes any inline flags, so the appended `$` is always text-end (opt 4 is `(?m)`).
    if (case.opt != 4) {
        var ebuf: [4096]u8 = undefined;
        const ep = if (anchoredEnd(gpa, case.pattern)) case.pattern else std.fmt.bufPrint(&ebuf, "(?:{s})$", .{case.pattern}) catch return;
        if (!anchoredEnd(gpa, ep)) return;
        var ab = try common.build(gex.backends.auto, gpa, ep, case.opt);
        if (ab != .ok) return;
        defer ab.ok.deinit();
        const in = try repeated(gpa, case.input, case.n * 4, tail);
        defer gpa.free(in);
        var sc = try ab.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        _ = ab.ok.find(&sc, in);
        common.noteCompared(.complexity, gex.backends.auto);
        if (sc.inner.confirm_probes != 0) {
            std.debug.print("complexity: /{s}/ is end-anchored but auto did {d} per-occurrence confirms\n", .{ ep, sc.inner.confirm_probes });
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

/// Peak live bytes a successful compile may hold per `expandedSize` unit, on top of
/// `base_bytes`. Measured ≤ ~150 B/unit on unrolled capture groups; `base_bytes` covers the
/// fixed, capped costs — a big Unicode class's DFA construction (`\pL` ≈ 4 MB), the eager
/// DFA's `max_states` tables.
const bytes_per_unit = 256;
const base_bytes = 32 << 20;

/// Live-byte high-water mark — what exhausts memory (a cumulative total conflates it with
/// short-lived scratch).
const Peak = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Peak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grew(self: *Peak, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.grew(0, len);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.grew(m.len, n);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.grew(m.len, n);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.live -= m.len;
    }
};

fn sizeOf(gpa: std.mem.Allocator, pattern: []const u8) !?usize {
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null, // scanner-rejected: not a bomb
    };
    defer ast.deinit(gpa);
    const h = try gex.buildHir(gpa, ast, .{});
    defer gex.freeHir(gpa, h);
    return gex.hir.expandedSize(h);
}

const Compiled = struct { peak: usize, accepted: bool };

fn compilePeak(gpa: std.mem.Allocator, pattern: []const u8) !Compiled {
    var pk: Peak = .{ .child = gpa };
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntime(pk.allocator(), pattern, &diag, .{}) catch |e| switch (e) {
        error.PatternTooComplex => return .{ .peak = pk.peak, .accepted = false },
        else => return e,
    };
    re.deinit();
    return .{ .peak = pk.peak, .accepted = true };
}

/// The same bomb with its OUTERMOST count doubled (`…){lo,hi}` → `…){2lo,2hi}`), or null
/// when the pattern doesn't end that way (a minimized variant) or won't fit `buf`.
fn doubledOuter(pattern: []const u8, buf: []u8) ?[]const u8 {
    if (pattern.len < 2 or pattern[pattern.len - 1] != '}') return null;
    const open = std.mem.lastIndexOfScalar(u8, pattern, '{') orelse return null;
    const body = pattern[open + 1 .. pattern.len - 1];
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return null;
    const lo = std.fmt.parseInt(u32, body[0..comma], 10) catch return null;
    const hi = std.fmt.parseInt(u32, body[comma + 1 ..], 10) catch return null;
    return std.fmt.bufPrint(buf, "{s}{{{d},{d}}}", .{ pattern[0..open], 2 * lo, 2 * hi }) catch null;
}

pub fn runBomb(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.compile_bomb, true);
    const size = (try sizeOf(gpa, case.pattern)) orelse return;
    const c = try compilePeak(gpa, case.pattern);
    if (!c.accepted) {
        if (size <= gex.hir.default_size_limit) return error.RejectedUnderLimit;
        if (c.peak >= 1 << 20) {
            std.debug.print("compile bomb /{s}/: rejected after holding {d} bytes\n", .{ case.pattern, c.peak });
            return error.RejectionAllocatedTooMuch;
        }
        return;
    }
    common.noteCompared(.compile_bomb, gex.backends.auto);
    if (size > gex.hir.default_size_limit) return error.AcceptedOverLimit;
    if (c.peak > size * bytes_per_unit + base_bytes) {
        std.debug.print("compile bomb /{s}/: size {d} but compile held {d} bytes\n", .{ case.pattern, size, c.peak });
        return error.CompileMemoryOverBudget;
    }
    // Scaling, independent of constants: doubling the outermost count ~doubles the size, so
    // the peak may grow ~2× (≤ 3× with slack) — a quadratic structure grows 4×. (The one-pass
    // table once did: `(?:(a)){10000}` held 21 GB.)
    var buf: [128]u8 = undefined;
    const p2 = doubledOuter(case.pattern, &buf) orelse return;
    const size2 = (try sizeOf(gpa, p2)) orelse return;
    if (size2 > gex.hir.default_size_limit) return;
    const c2 = try compilePeak(gpa, p2);
    if (!c2.accepted) return error.RejectedUnderLimit;
    if (c2.peak > 3 * c.peak + (1 << 20)) {
        std.debug.print("compile bomb /{s}/: peak {d} bytes, but /{s}/ (outer count doubled) held {d}\n", .{ case.pattern, c.peak, p2, c2.peak });
        return error.CompileMemorySuperLinear;
    }
}
