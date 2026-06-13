//! ReDoS-immunity guards — the regression suite behind the library's headline claim.
//!
//! "ReDoS-immune" means a *crafted pattern + input* can never force super-linear
//! matching time (catastrophic backtracking). This file proves that **deterministically**,
//! not with wall-clock timing (which is flaky and machine-dependent):
//!
//!   1. **Linear work, exactly.** The bounded backtracker stamps every `(pc, sp)` into a
//!      visited memo at most once, so its work count (`backtrack.Scratch.steps`) is
//!      bounded by `program × (input+1)`. We compile the textbook catastrophic patterns
//!      (`(a+)+$`, `(a*)*$`, `(a|ab)*$`, `(x+x+)+y`, …), feed them their worst-case
//!      inputs at sizes n, 2n, 4n, and assert the **work at most ~doubles per input
//!      doubling**. A linear engine reads ≈2.0×; a *quadratic* regression reads 4.0×
//!      (caught); an *exponential* one reads astronomically more (caught). No timer,
//!      no machine dependence — a memo regression fails this at n≈1000.
//!
//!   2. **The default engine stays linear AND crash-free at scale.** The same corpus,
//!      run through `auto` (the default) on a large input, must complete with the correct
//!      result. `auto` routes large inputs to the iterative Pike VM / DFA, so this also
//!      pins that the default path never recurses deep (the backtracker's one *non*-time
//!      limit — see backtrack.zig → "Resource bounds" — is stack depth ∝ matched length,
//!      which `auto` shields by capping backtracker input at `BACKTRACK_MAX_INPUT`).
//!
//!   2b. **The default-engine prefilter is not Θ(n²).** A second, *hard* deterministic
//!      guard: `auto`'s eager-DFA prefilter must do **zero** per-occurrence anchored
//!      confirms on `prone`/`end_anchored` programs (`Scratch.confirm_probes == 0`). A
//!      non-zero count is the real Θ(n²) ReDoS the `redos` bench caught (`a+b` on `aaaa…a!`
//!      was ~1.1 s at 64 KiB) — reverting the fix trips this at n=4096.
//!
//!   3. **The trailing-`$` Θ(n²) class is linear.** The "begin-but-don't-complete"
//!      shape (`[a-z]+$` on `aa…a!`) was Θ(n²) under the old anchored-restart; the
//!      reverse-DFA-from-end path made it O(n). Pinned across backends at scale.
//!
//!   4. **Comptime can't blow up either.** A catastrophic pattern matched in the const
//!      evaluator completes within a bounded branch quota.
//!
//! Scope note: the bare `backtrack` backend has a stack-depth limit on *long* inputs
//! (documented in backtrack.zig); the deterministic work-count tests therefore drive it
//! at safe sizes (≤ a few thousand bytes, the regime `auto` actually uses it in), while
//! the at-scale tests drive the default `auto` engine, which is iterative above the cap.

const std = @import("std");
const testing = std.testing;

const regex = @import("regex.zig");
const backend = @import("backend.zig");
const pikevm = @import("backends/pikevm.zig");
const backtrack = @import("backends/backtrack.zig");
const auto = @import("backends/auto.zig");
const edfa = @import("backends/edfa.zig");
const dfa = @import("backends/dfa.zig");

/// A catastrophic pattern paired with the bytes that maximise its backtracking: a long
/// run of `fill` (the unit the inner quantifier chews on) ending in `tail` (a byte that
/// breaks completion, forcing the engine to exhaust every partition before it can decide).
const Cat = struct { pat: []const u8, fill: u8, tail: u8 };

/// Work ∝ n cases — the engine must scan the whole input (it never finds a quick win),
/// so `steps` should scale linearly with the input. Every one is a classic ReDoS shape:
/// nested quantifiers, overlapping alternations, and quantified classes.
const linear_corpus = [_]Cat{
    .{ .pat = "(a+)+$", .fill = 'a', .tail = '!' }, // nested +, anchored
    .{ .pat = "(a*)*$", .fill = 'a', .tail = '!' }, // nested *, the (a*)* explosion
    .{ .pat = "(a+)+b", .fill = 'a', .tail = '!' }, // nested +, literal sentinel never present
    .{ .pat = "(a|a)*$", .fill = 'a', .tail = '!' }, // redundant alternation under *
    .{ .pat = "(a|ab)*$", .fill = 'a', .tail = '!' }, // overlapping alternation under *
    .{ .pat = "([a-z]+)*$", .fill = 'a', .tail = '1' }, // quantified class, nested *
    .{ .pat = "(x+x+)+y", .fill = 'x', .tail = '!' }, // the canonical (x+x+)+y bomb
    .{ .pat = "(\\d+)*$", .fill = '7', .tail = '!' }, // quantified \d class, nested *
};

fn worstCase(gpa: std.mem.Allocator, n: usize, fill: u8, tail: u8) ![]u8 {
    const buf = try gpa.alloc(u8, n);
    @memset(buf, fill);
    if (n > 0) buf[n - 1] = tail;
    return buf;
}

// ── 1. Deterministic linear work (the headline guard) ─────────────────────────────

test "backtracker work is deterministically linear on catastrophic patterns" {
    const gpa = testing.allocator;
    // Linear ≈ 2.0× per input doubling; a quadratic regression reads 4.0×, an exponential
    // one reads ~2^n. 3.0 cleanly separates "linear" (≤ ~2.1 in practice) from "quadratic"
    // (4.0) with headroom for the small additive program-size constant. Sizes stay in the
    // few-thousand range — the regime `auto` actually routes to the backtracker, and well
    // within its stack-depth limit (see backtrack.zig → "Resource bounds").
    const LINEAR_SLACK: f64 = 3.0;
    // Small sizes, two doublings: a genuine quadratic still reads 4.0× per doubling
    // (caught), while staying safely under the bare backtracker's per-pattern stack-depth
    // limit (some shapes — `(a|ab)*$` — recurse deeper per char than others). The at-scale
    // safety is proven separately through `auto` below.
    const sizes = [_]usize{ 256, 512, 1024 };

    for (linear_corpus) |c| {
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(backtrack, gpa, c.pat, &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);

        var steps: [sizes.len]u64 = undefined;
        var matched: [sizes.len]bool = undefined;
        for (sizes, 0..) |n, i| {
            const input = try worstCase(gpa, n, c.fill, c.tail);
            defer gpa.free(input);
            const m = re.find(&sc, input);
            steps[i] = sc.steps;
            matched[i] = m != null;
        }

        // Real work happened (not a trivial short-circuit that would make the ratio
        // meaningless): the smallest input already costs more than its own length.
        if (steps[0] <= sizes[0]) {
            std.debug.print("/{s}/: steps[0]={d} did not exceed n={d} — work too small to be meaningful\n", .{ c.pat, steps[0], sizes[0] });
            return error.WorkTooSmall;
        }
        // The outcome must be identical across sizes (same worst-case shape, just longer)
        // — otherwise the step ratio compares apples to oranges.
        try testing.expectEqual(matched[0], matched[1]);
        try testing.expectEqual(matched[0], matched[2]);

        // The core assertion: work grows linearly. A super-linear (poly OR exponential)
        // regression in the visited memo blows past LINEAR_SLACK here, deterministically.
        var i: usize = 1;
        while (i < sizes.len) : (i += 1) {
            const ratio = @as(f64, @floatFromInt(steps[i])) / @as(f64, @floatFromInt(steps[i - 1]));
            if (ratio > LINEAR_SLACK) {
                std.debug.print(
                    "/{s}/: work grew {d:.3}× from n={d} ({d} steps) to n={d} ({d} steps) — exceeds linear bound {d:.1}× (ReDoS!)\n",
                    .{ c.pat, ratio, sizes[i - 1], steps[i - 1], sizes[i], steps[i], LINEAR_SLACK },
                );
                return error.SuperLinearWork;
            }
        }
    }
}

// ── 2. Default engine: linear & crash-free at scale ───────────────────────────────

/// `find` a backend's match for `(pat, input)`, or `.skip` when the pattern does not
/// compile for it (lets the corpus include shapes a given backend declines).
const Outcome = union(enum) { skip, span: ?backend.Match };
fn findWith(comptime B: type, gpa: std.mem.Allocator, pat: []const u8, input: []const u8) !Outcome {
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, pat, &diag, .{}) catch return .skip;
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    return .{ .span = re.find(&sc, input) };
}

test "default engine (auto) stays linear and crash-free on catastrophic patterns at scale" {
    const gpa = testing.allocator;
    // 64 KiB — far past auto's BACKTRACK_MAX_INPUT (4096), so auto runs the iterative
    // Pike VM / DFA, never deep native recursion. Completing this near-instantly with the
    // correct result is the signal: an exponential engine never returns, a Θ(n²) one
    // takes far too long to finish the test, and a deep-recursive one would crash. The
    // Pike VM is the oracle (provably linear, iterative — safe at any size).
    const N: usize = 1 << 16;
    for (linear_corpus) |c| {
        const input = try worstCase(gpa, N, c.fill, c.tail);
        defer gpa.free(input);

        const oracle = switch (try findWith(pikevm, gpa, c.pat, input)) {
            .skip => continue,
            .span => |s| s,
        };
        // auto must agree with the Pike VM, and must complete (no hang, no crash).
        switch (try findWith(auto, gpa, c.pat, input)) {
            .skip => {},
            .span => |s| {
                try testing.expectEqual(oracle == null, s == null);
                if (oracle) |o| {
                    try testing.expectEqual(o.start, s.?.start);
                    try testing.expectEqual(o.end, s.?.end);
                }
            },
        }
    }
}

// ── 2b. Default-engine prefilter is not quadratic (the `a+b` regression) ────────────

test "default-engine prefilter does ZERO per-occurrence confirms on prone/end_anchored programs (hard ReDoS guard)" {
    // Revert-failing guard for the real quadratic ReDoS the `redos` bench caught. The bug:
    // `auto`'s eager-DFA prefilter (`runEdfa`) did a leading-literal `memchr` that confirmed
    // anchored at EVERY prefix-byte occurrence; on `aaaa...a!` the byte is at every position
    // and each confirm re-walks the whole run, so `a+b` was Theta(n^2) (~1.1 s at 64 KiB) even
    // though the eager DFA's own find is O(n). The fix routes prone/end_anchored programs to
    // that O(n) native find and does NO per-occurrence confirms.
    //
    // Deterministic and machine-independent -- no timing. `Scratch.confirm_probes` counts the
    // per-occurrence confirms, so it must be 0 for these programs: with the bug it is ~input.len,
    // with the fix it is 0. Reverting the prone/end_anchored gate in `runEdfa` makes this fail.
    // The positive control at the end proves the counter is actually wired (a fast-confirm
    // pattern DOES register probes), so a 0 above is real, not vacuous.
    const gpa = testing.allocator;
    const N: usize = 4096; // a buggy confirm loop racks up ~N probes here; the fix does 0
    const cases = [_]Cat{
        .{ .pat = "a+b", .fill = 'a', .tail = '!' }, // prone, prefix 'a' -- the headline regression
        .{ .pat = "(a+)+$", .fill = 'a', .tail = '!' }, // end_anchored, prefix 'a'
        .{ .pat = "(x+x+)+y", .fill = 'x', .tail = '!' }, // prone, prefix 'x' -- the canonical bomb
    };
    for (cases) |c| {
        const input = try worstCase(gpa, N, c.fill, c.tail);
        defer gpa.free(input);
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);
        try testing.expect(re.find(&sc, input) == null); // worst case is a no-match (correctness)
        if (sc.confirm_probes != 0) {
            std.debug.print("/{s}/: {d} per-occurrence confirms (expected 0) -- quadratic prefilter regression\n", .{ c.pat, sc.confirm_probes });
            return error.QuadraticPrefilterRegression;
        }
    }

    // Positive control: a fast-confirm pattern (`foo\d+` — bounded literal prefix, confirm fails
    // within a few bytes) legitimately KEEPS the per-occurrence memchr-jump loop, so it MUST
    // register probes. If this were 0 the counter would be dead and the assertions above vacuous.
    {
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, "foo\\d+", &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);
        _ = re.find(&sc, "fx fo food foo9 bar"); // several 'f's; the loop probes each candidate
        try testing.expect(sc.confirm_probes > 0);
    }
}

// ── 3. Cross-backend agreement on the catastrophic corpus (match + no-match) ───────

const Diff = struct { pat: []const u8, input: []const u8, expect: ?[]const u8 };

/// Small inputs (safe for the bare backtracker), covering BOTH the matching and the
/// pathological no-match cases of each shape. The hand-computed leftmost-first `expect`
/// guards against a bug all engines might share; the cross-backend check guards against
/// divergence. (`(a*)*$` matches the empty string at end-of-input — that is correct.)
const diff_cases = [_]Diff{
    .{ .pat = "(a+)+$", .input = "aaaa", .expect = "aaaa" },
    .{ .pat = "(a+)+$", .input = "aaaa!", .expect = null },
    .{ .pat = "(a*)*b", .input = "aaaab", .expect = "aaaab" },
    .{ .pat = "(a*)*b", .input = "aaaa", .expect = null },
    .{ .pat = "(a+)+b", .input = "aaab", .expect = "aaab" },
    .{ .pat = "(a+)+b", .input = "aaa!", .expect = null },
    .{ .pat = "(a|a)*$", .input = "aaa", .expect = "aaa" },
    .{ .pat = "(a|ab)*$", .input = "abab", .expect = "abab" },
    .{ .pat = "(x+x+)+y", .input = "xxxxy", .expect = "xxxxy" },
    .{ .pat = "(x+x+)+y", .input = "xxxx!", .expect = null },
    .{ .pat = "([a-z]+)*$", .input = "abc", .expect = "abc" },
    .{ .pat = "(\\d+)*$", .input = "123", .expect = "123" },
};

test "all NFA backends agree with the Pike VM on the catastrophic corpus" {
    const gpa = testing.allocator;
    for (diff_cases) |c| {
        const oracle = switch (try findWith(pikevm, gpa, c.pat, c.input)) {
            .skip => continue,
            .span => |s| s,
        };
        // The hand-verified expectation (catches a systematic bug shared by all engines).
        if (c.expect) |exp| {
            try testing.expect(oracle != null);
            try testing.expectEqualStrings(exp, oracle.?.slice(c.input));
        } else {
            try testing.expect(oracle == null);
        }
        // Every other backend must produce the byte-identical span (or decline the shape).
        inline for (.{ backtrack, auto, edfa, dfa }) |B| {
            switch (try findWith(B, gpa, c.pat, c.input)) {
                .skip => {},
                .span => |s| {
                    testing.expectEqual(oracle == null, s == null) catch {
                        std.debug.print("/{s}/ on {s}: {s} disagreed on match presence\n", .{ c.pat, c.input, @typeName(B) });
                        return error.Mismatch;
                    };
                    if (oracle) |o| {
                        try testing.expectEqual(o.start, s.?.start);
                        try testing.expectEqual(o.end, s.?.end);
                    }
                },
            }
        }
    }
}

// ── 4. Trailing-`$` Θ(n²) class is linear at scale (across backends) ───────────────

test "trailing `$` patterns are linear, not Θ(n²), across the default + Pike VM at scale" {
    const gpa = testing.allocator;
    // The begin-but-don't-complete `$` shape on a long input with no completer: Θ(n²)
    // under the old anchored-restart (every start walks to end-of-input and fails). The
    // reverse-DFA-from-end path makes it one O(input) backward pass. A 256 KiB input
    // completing near-instantly is the signal; a quadratic regression would not finish.
    const N: usize = 1 << 18;
    for ([_][]const u8{ "[a-z]+$", "[a-z]+@[a-z]+$", "[ab]*c$", "\\d+$" }) |pat| {
        const input = try worstCase(gpa, N, 'a', '!'); // no `[a-z]`/digit at the very end → no match
        defer gpa.free(input);
        // Both the linear-by-construction Pike VM and the default auto (eager-DFA span)
        // must agree and complete.
        const oracle = switch (try findWith(pikevm, gpa, pat, input)) {
            .skip => continue,
            .span => |s| s,
        };
        switch (try findWith(auto, gpa, pat, input)) {
            .skip => {},
            .span => |s| {
                try testing.expectEqual(oracle == null, s == null);
                if (oracle) |o| {
                    try testing.expectEqual(o.start, s.?.start);
                    try testing.expectEqual(o.end, s.?.end);
                }
            },
        }
    }
}

// ── 5. Comptime matching is bounded too ───────────────────────────────────────────

test "catastrophic patterns are bounded at comptime (no const-eval blowup)" {
    // (a*)*b matched in the const evaluator: a quadratic/exponential matcher would exhaust
    // the branch quota and fail to compile. A modest quota proving it completes is the guard.
    const results = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        const Re = regex.compileComptimeWith(auto, "(a*)*b", .{});
        const hit = Re.findComptime("aaaaaaaab") != null; // matches
        const miss = Re.findComptime("aaaaaaaa") == null; // no 'b' → no match, still bounded
        break :blk .{ hit, miss };
    };
    try testing.expect(results[0]);
    try testing.expect(results[1]);
}

test {
    testing.refAllDecls(@This());
}
