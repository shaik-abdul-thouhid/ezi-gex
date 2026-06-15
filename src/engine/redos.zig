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

const regex = @import("regex");
const backend = @import("engine_base").backend;
const pikevm = @import("pikevm");
const backtrack = @import("backtrack");
const auto = @import("auto");
const edfa = @import("edfa");
const dfa = @import("dfa");

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

test "default-engine prefilter: prone/end_anchored => 0 confirms; fast-confirm => loop kept (hard ReDoS guard)" {
    // Revert-failing guard for the real quadratic ReDoS the `redos` bench caught. The bug:
    // `auto`'s eager-DFA prefilter (`runEdfa`) did a leading-literal `memchr` that confirmed
    // anchored at EVERY prefix-byte occurrence. When a confirm can scan an unbounded run before
    // failing -- a `prone` program (a non-accepting cycle) or an `end_anchored` one (trailing
    // `$`, the confirm runs to end) -- that is O(n) confirms each O(n) = Theta(n^2) on a
    // dense-prefix begin-but-don't-complete input (`a+b` on `aaaa...a!` was ~1.1 s at 64 KiB).
    // The fix routes exactly those programs to the eager DFA's O(n) native find, doing NO
    // per-occurrence confirms; `Scratch.confirm_probes` (the observable) is then 0 for them.
    //
    // Deterministic and machine-independent -- no timing. Two groups pin BOTH sides of the gate,
    // so neither assertion is vacuous (the classifications are VERIFIED, not assumed -- see the
    // bounded vs. unbounded contrast below).
    const gpa = testing.allocator;
    const N: usize = 4096; // a buggy confirm loop racks up ~N probes here

    // (A) Dangerous class -- a confirm can scan an unbounded run, so the loop MUST be skipped:
    // `confirm_probes == 0`. Reverting the prone/end_anchored gate in `runEdfa` makes this fail
    // (the loop would run ~N times). `a{4,}b` has an UNBOUNDED tail (a non-accepting cycle) so it
    // is `prone` and belongs here -- the precise contrast with the BOUNDED-tail `a{4}b` in (B).
    const gated = [_]Cat{
        .{ .pat = "a+b", .fill = 'a', .tail = '!' }, // prone, prefix 'a' -- the headline regression
        .{ .pat = "(a+)+$", .fill = 'a', .tail = '!' }, // end_anchored, prefix 'a'
        .{ .pat = "(x+x+)+y", .fill = 'x', .tail = '!' }, // prone, prefix 'x' -- the canonical bomb
        .{ .pat = "a{4,}b", .fill = 'a', .tail = '!' }, // prone (UNBOUNDED tail) -- cf. a{4}b in (B)
        // Bounded-LARGE prefix: no cycle, but a 100-long non-accepting prefix exceeds
        // RESTART_SCAN_LIMIT (64), so it is `prone` too -- the per-occurrence confirm would be
        // Θ(n·100). Reverting the bounded-prefix branch of `computeProne` makes this fail
        // (a{100}b would be classified non-prone → ~N confirms each re-scanning the 100-a prefix).
        .{ .pat = "a{100}b", .fill = 'a', .tail = '!' },
    };
    for (gated) |c| {
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

    // (B) Fast-confirm class -- a confirm fails within a program-bounded window (non-prone,
    // non-`$`), so the memmem-jump loop is KEPT (its intended speedup) and `confirm_probes > 0`.
    // This is also the positive control: a 0 here would mean the counter is dead and (A) vacuous.
    // `a{4}b` on a dense-prefix no-match input is the stress case -- the loop runs ~N times and
    // must still return the correct no-match; it stays O(n) because each confirm is bounded by the
    // program, not the input (the `redos` bench pins that linearity quantitatively). NOTE it is
    // `a{4}b`, not `aaab`: `aaab` is a pure literal -> the `literal` backend, which bypasses this
    // prefilter entirely (its 0 would be trivial -- not a test of the gate). Verified via the
    // DIAG probe: a{4}b -> nfa+edfa, prone=no, probes=4092; a{4,}b -> prone=yes, probes=0.
    {
        const input = try worstCase(gpa, N, 'a', '!'); // 'a' at every position, no 'b' -> no match
        defer gpa.free(input);
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, "a{4}b", &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);
        try testing.expect(re.find(&sc, input) == null); // correct no-match despite the loop running
        try testing.expect(sc.confirm_probes > 0); // the loop is kept for fast-confirm patterns
    }
    {
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, "foo\\d+", &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);
        _ = re.find(&sc, "fx fo food foo9 bar"); // two "foo" runs; the memmem loop probes each
        try testing.expect(sc.confirm_probes > 0);
    }
}

test "prefilter: bounded-prefix proneness threshold (a{64}b on edfa vs a{65}b off it)" {
    // RESTART_SCAN_LIMIT = 64 (edfa.zig) is the longest non-accepting prefix that keeps a pattern
    // on the eager DFA's per-occurrence confirm loop. With the two-phase build (non-prone patterns
    // skip the unanchored `utrans` table), a{64}b's prefix is exactly 64 (≤ limit) → non-prone →
    // it fits the eager DFA and KEEPS the memmem-jump loop bounded to ≤64 bytes/confirm
    // (probes > 0). a{65}b's is 65 (> limit) → prone → its `utrans` overflows the eager pool → it
    // falls to the lazy DFA, whose `find` is a single-skip + O(input) reverse pass (probes == 0).
    //
    // The pair pins the EXACT boundary and is revert-failing for BOTH fixes:
    //   * revert the bounded-prefix branch of `computeProne` → a{65}b stays non-prone → eager DFA
    //     fast-confirm → probes > 0 (boundary breaks);
    //   * revert the two-phase (non-prone skips utrans) → a{64}b's unused utrans overflows the eager
    //     pool → it falls to the lazy DFA → probes == 0 (a{64}b's positive control breaks).
    const gpa = testing.allocator;
    const N: usize = 4096;
    const input = try worstCase(gpa, N, 'a', '!'); // dense 'a', no 'b' → no match
    defer gpa.free(input);

    const Case = struct { pat: []const u8, want_probes_zero: bool };
    for ([_]Case{
        .{ .pat = "a{64}b", .want_probes_zero = false }, // 64 == limit → eager DFA fast-confirm (loop kept, ≤64/confirm)
        .{ .pat = "a{65}b", .want_probes_zero = true }, // 65 > limit → prone → lazy DFA (no per-occurrence confirm)
    }) |c| {
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);
        try testing.expect(re.find(&sc, input) == null); // correct no-match either way
        if (c.want_probes_zero) {
            if (sc.confirm_probes != 0) {
                std.debug.print("/{s}/: {d} per-occurrence confirms (expected 0) — bounded-prefix gate regression\n", .{ c.pat, sc.confirm_probes });
                return error.BoundedPrefixQuadratic;
            }
        } else {
            try testing.expect(sc.confirm_probes > 0); // positive control: the loop is live & bounded
        }
    }
}

test "bounded-large-prefix a{N}b is linear (not Θ(n·k)) at scale" {
    // a{N}b on dense 'a' with no 'b': the prefilter used to confirm-scan the whole N-long prefix at
    // every position → Θ(n·N) (the bounded-large-prefix ReDoS). Now any N > RESTART_SCAN_LIMIT is
    // `prone` → the eager DFA's O(input) reverse find, or the lazy DFA's O(input) reverse find when
    // the (utrans-inflated) eager bound overflows. 64 KiB completing near-instantly with the correct
    // no-match is the signal; the Θ(n·N) regression would not finish in any reasonable time.
    const gpa = testing.allocator;
    const N_input: usize = 1 << 16;
    const no_b = try worstCase(gpa, N_input, 'a', '!'); // dense 'a', no 'b' → no match
    defer gpa.free(no_b);
    for ([_]usize{ 100, 1000, 4000 }) |k| {
        const pat = try std.fmt.allocPrint(gpa, "a{{{d}}}b", .{k});
        defer gpa.free(pat);
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, pat, &diag, .{});
        defer re.deinit();
        var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
        defer sc.deinit(gpa);
        try testing.expect(re.find(&sc, no_b) == null);
        // And a genuine match still works (k a's then b), proving the fast path didn't break it.
        const yes = try gpa.alloc(u8, k + 1);
        defer gpa.free(yes);
        @memset(yes[0..k], 'a');
        yes[k] = 'b';
        try testing.expect(re.find(&sc, yes) != null);
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
    // Counted ranges — bounded `a{4}b` (fast-confirm) vs. unbounded `a{4,}b` (prone): `{n,}`
    // desugars to n copies + a star, a distinct NFA shape, so verify BOTH the kept confirm loop
    // and the prone reverse-two-pass return the right span against the Pike VM oracle.
    .{ .pat = "a{4}b", .input = "aaaab", .expect = "aaaab" }, // exactly 4 a's, then b
    .{ .pat = "a{4}b", .input = "aaaaab", .expect = "aaaab" }, // leftmost is the start-1 window
    .{ .pat = "a{4}b", .input = "aaab", .expect = null }, // only 3 a's
    .{ .pat = "a{4}b", .input = "aaaa", .expect = null }, // no b
    .{ .pat = "a{4,}b", .input = "aaaab", .expect = "aaaab" }, // 4-or-more, then b
    .{ .pat = "a{4,}b", .input = "aaaaab", .expect = "aaaaab" }, // greedy: all a's, then b
    .{ .pat = "a{4,}b", .input = "aaab", .expect = null }, // only 3 a's
    .{ .pat = "a{4,}b", .input = "aaaa", .expect = null }, // no b
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
