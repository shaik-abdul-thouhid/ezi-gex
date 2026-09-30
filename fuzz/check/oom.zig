//! Allocation-failure injection. Each case picks ONE backend (`case.n`) and runs its
//! scenario once to count allocations, then once per SAMPLED fail point (`case.seed`) with
//! that allocation failing. Each induced failure must come back as `error.OutOfMemory` with
//! nothing leaked: a backend that maps OOM to another error or silently degrades is reported
//! as a swallowed failure. Checking every allocation of every backend per case re-ran the
//! whole compile ~500 times an iteration; across a run's cases the sample still reaches every
//! backend and every fail point.
//!
//! The scenarios run over `NoInPlace`, so the allocation count is a function of the code
//! alone (see there) — otherwise allocator-state noise reads as `NondeterministicMemoryUsage`.

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
    var case: Case = .{
        .check = .oom,
        .pattern = p.pattern,
        .input = input,
        .opt = p.opt,
        .seed = smith.value(u64), // which allocations fail (`sampleFailPoints`)
    };
    // The one backend this case checks, hashed from the case rather than drawn: a replayed
    // draw that is out of range (or past the end of the input) reads as 0, which skewed ~70%
    // of cases onto pikevm. Stored in `n`, so the replay line still pins it.
    var h = std.hash.Wyhash.init(case.seed);
    h.update(case.pattern);
    h.update(case.input);
    case.n = @intCast(h.final() % common.n_backends);
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
            // Backends that allocate DURING a search can't report a failure through the
            // contract's (error-free) search API. The bare backtracker (visited set) and lazy
            // DFA (transition cache) expose `reserve` / `try*` for exactly that — exercise
            // those; their plain search would panic on OOM by design. `auto` must ABSORB a
            // failure (fall back to the Pike VM), which `checkSampled` would call "swallowed";
            // `searchUnderFailure` checks it separately (same answer, no panic, no leak).
            if (B == gex.backends.auto) return;
            if (B == gex.backends.dfa) {
                _ = try B.trySearch(&re.program, &sc.inner, input, .{});
                _ = try B.tryIsMatch(&re.program, &sc.inner, input, .{});
                return;
            }
            if (B == gex.backends.backtrack) try B.reserve(&re.program, &sc.inner, input.len);
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

/// A backing allocator that never resizes or remaps in place, so every growth or shrink is
/// `alloc` + copy + `free`. The general-purpose allocator's in-place success depends on its
/// own state — a shrinking `toOwnedSlice` remap can fail on one build and succeed on the
/// next — which makes the allocation COUNT differ between identical runs. Forcing the copy
/// path makes it deterministic, and turns every growth into a fail point of its own.
const NoInPlace = struct {
    child: std.mem.Allocator,

    fn allocator(self: *NoInPlace) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoInPlace = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, a, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *NoInPlace = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};

/// `auto` under allocation failure DURING a search: after `Scratch.init`, let only `j` more
/// allocations succeed (j = 0..7). Every search must still return the Pike VM's answer —
/// `auto` reserves the backtracker's visited set / uses the lazy DFA's try-variants and falls
/// back to the Pike VM, which never allocates mid-search — without panicking or leaking.
fn searchUnderFailure(backing: std.mem.Allocator, case: *const Case) anyerror!void {
    var nip: NoInPlace = .{ .child = backing };
    const gpa = nip.allocator();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (ob != .ok) return;
    defer ob.ok.deinit();
    var ab = try common.build(gex.backends.auto, gpa, case.pattern, case.opt);
    if (ab != .ok) return;
    defer ab.ok.deinit();
    var osc = try ob.ok.initScratch(gpa);
    defer osc.deinit(gpa);
    const want = ob.ok.find(&osc, case.input);
    const want_match = ob.ok.isMatch(&osc, case.input);
    var j: usize = 0;
    while (j < 8) : (j += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        const fa = failing.allocator();
        var sc = try ab.ok.initScratch(fa);
        defer sc.deinit(fa);
        failing.fail_index = failing.alloc_index + j;
        failing.resize_fail_index = failing.resize_index + j;
        const got = ab.ok.find(&sc, case.input);
        const got_match = ab.ok.isMatch(&sc, case.input);
        const same = (want == null) == (got == null) and (want == null or (want.?.start == got.?.start and want.?.end == got.?.end));
        if (!same or got_match != want_match) {
            std.debug.print("oom (auto) on /{s}/ with {d} allocations allowed mid-search: find {?any} vs pikevm {?any}, isMatch {} vs {}\n", .{ case.pattern, j, got, want, got_match, want_match });
            return error.WrongAnswerUnderAllocationFailure;
        }
    }
}

/// Fail points per case: the first and last few allocations (parse; scratch + search) plus a
/// few seeded picks in between — ≤ `max_points` scenario runs instead of one per allocation.
const head_points = 3;
const tail_points = 3;
const mid_points = 4;
const max_points = head_points + tail_points + mid_points;

fn sampleFailPoints(total: usize, seed: u64, out: *[max_points]usize) []const usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < @min(head_points, total)) : (i += 1) {
        out[n] = i;
        n += 1;
    }
    i = total -| tail_points;
    while (i < total) : (i += 1) {
        out[n] = i;
        n += 1;
    }
    if (total > 0) {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..mid_points) |_| {
            out[n] = prng.random().uintLessThan(usize, total);
            n += 1;
        }
    }
    std.mem.sort(usize, out[0..n], {}, std.sort.asc(usize));
    var u: usize = 0; // dedupe in place (sorted)
    for (out[0..n]) |x| {
        if (u == 0 or out[u - 1] != x) {
            out[u] = x;
            u += 1;
        }
    }
    return out[0..u];
}

/// `std.testing.checkAllAllocationFailures` over the sampled fail points only: same verdicts
/// (swallowed / nondeterministic / leaked), same report of where the failed allocation was.
fn checkSampled(comptime B: type, backing: std.mem.Allocator, case: *const Case) anyerror!void {
    const f = Scenario(B).f;
    const total = blk: {
        var fa = std.testing.FailingAllocator.init(backing, .{});
        try f(fa.allocator(), case.pattern, case.input, case.opt);
        break :blk fa.alloc_index;
    };
    var buf: [max_points]usize = undefined;
    for (sampleFailPoints(total, case.seed, &buf)) |fail_index| {
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (f(fa.allocator(), case.pattern, case.input, case.opt)) |_| {
            return if (fa.has_induced_failure) error.SwallowedOutOfMemoryError else error.NondeterministicMemoryUsage;
        } else |e| {
            if (e != error.OutOfMemory) return e;
            if (fa.allocated_bytes != fa.freed_bytes) {
                std.debug.print("\nfail_index: {d}/{d}\nallocated bytes: {d}\nfreed bytes: {d}\nallocation that was made to fail: {f}", .{
                    fail_index,
                    total,
                    fa.allocated_bytes,
                    fa.freed_bytes,
                    std.debug.FormatStackTrace{ .stack_trace = fa.getStackTrace() },
                });
                return error.MemoryLeakDetected;
            }
        }
    }
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.oom, true);
    var nip: NoInPlace = .{ .child = gpa };
    inline for (common.all_backends, 0..) |B, bi| {
        if (bi == case.n % common.n_backends) {
            if (B == gex.backends.auto) try searchUnderFailure(gpa, case);
            checkSampled(B, nip.allocator(), case) catch |e| {
                std.debug.print("oom ({s}) on /{s}/: {s}\n", .{ @typeName(B), case.pattern, @errorName(e) });
                return e;
            };
            common.noteCompared(.oom, B);
        }
    }
}

test "sampleFailPoints: head, tail and seeded middle, sorted and unique, in range" {
    var buf: [max_points]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{}, sampleFailPoints(0, 1, &buf));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, sampleFailPoints(2, 1, &buf));
    for (0..200) |seed| {
        const pts = sampleFailPoints(100, seed, &buf);
        try std.testing.expect(pts.len >= head_points + tail_points and pts.len <= max_points);
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, pts[0..3]);
        try std.testing.expectEqualSlices(usize, &.{ 97, 98, 99 }, pts[pts.len - 3 ..]);
        for (pts[1..], pts[0 .. pts.len - 1]) |b, a| try std.testing.expect(a < b);
    }
}
