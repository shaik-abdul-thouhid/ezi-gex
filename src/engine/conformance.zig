//! Cross-backend conformance harness.
//!
//! Every backend is supposed to be interchangeable behind the contract, so the
//! strongest test is to drive the *same* table of cases through each one (via the
//! real front door, `compileRuntimeWith` / `compileComptimeWith`) and assert they
//! all agree — runtime *and* comptime. Per-backend behavioural tests live in each
//! backend's own file; this file proves they don't diverge from each other.
//!
//! Coverage axes:
//!   * `pikevm` (breadth-first NFA), `backtrack` (depth-first NFA), `auto`
//!     (dispatcher) must agree on every general case.
//!   * `literal` additionally matches the pure-literal subset.
//!   * captures: `pikevm`, `backtrack`, `auto` must report identical slot arrays.
//!   * comptime: a subset runs at comptime through each backend and must match the
//!     runtime result.
//!   * `auto` must agree with itself across its internal input-size switch (small
//!     input → backtrack arm, large input → Pike VM arm).

const std = @import("std");
const testing = std.testing;

const regex = @import("regex.zig");
const backend = @import("backend.zig");
const pikevm = @import("backends/pikevm.zig");
const backtrack = @import("backends/backtrack.zig");
const literal = @import("backends/literal.zig");
const bytepike = @import("backends/bytepike.zig");
const dfa = @import("backends/dfa.zig");
const auto = @import("backends/auto.zig");

const byte = @import("byte.zig");
const hir = @import("../core/hir.zig");
const ccompile = @import("../core/compile.zig");

/// Whether `pattern` can be lowered to a byte program (false for `\X`/`\b` — those
/// route to the code-point engines, so the byte Pike VM is not expected to run them).
fn byteLowerablePattern(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    return byte.byteLowerable(h);
}

/// Small ASCII-only cases for the byte engine's *comptime* parity. Kept separate
/// from `comptime_cases` because the byte lowering of a Unicode class (`\d`/`\w`)
/// expands to many `byte_range` insts, and building + running several of those in
/// the const-evaluator is heavy; these stay small. (`bytepike.zig`'s own tests cover
/// comptime byte matching of `\d`/`\w` directly.)
const byte_comptime_cases = [_]Case{
    .{ .pat = "cat|dog", .input = "a dog", .expect = "dog" },
    .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
    .{ .pat = "ab*c", .input = "xabbbc", .expect = "abbbc" },
};

const Case = struct { pat: []const u8, input: []const u8, expect: ?[]const u8 };

/// General cases — valid for any NFA-capable backend (pikevm / backtrack / auto).
const general_cases = [_]Case{
    // literals
    .{ .pat = "abc", .input = "xxabcyy", .expect = "abc" },
    .{ .pat = "abc", .input = "ab", .expect = null },
    .{ .pat = "a", .input = "banana", .expect = "a" },
    .{ .pat = "", .input = "abc", .expect = "" },
    // dot / any
    .{ .pat = "a.c", .input = "a c", .expect = "a c" },
    .{ .pat = "a.c", .input = "a\nc", .expect = null },
    .{ .pat = "(?s)a.c", .input = "a\nc", .expect = "a\nc" },
    // classes + shorthands
    .{ .pat = "[a-z]+", .input = "ABCdefGHI", .expect = "def" },
    .{ .pat = "[^a-z]+", .input = "abXY12cd", .expect = "XY12" },
    .{ .pat = "\\d+", .input = "abc123def", .expect = "123" },
    .{ .pat = "\\w+", .input = "  foo_bar! ", .expect = "foo_bar" },
    .{ .pat = "\\D+", .input = "12ab34", .expect = "ab" },
    // alternation priority
    .{ .pat = "cat|dog", .input = "i have a dog", .expect = "dog" },
    .{ .pat = "a|ab", .input = "ab", .expect = "a" },
    .{ .pat = "ab|a", .input = "ab", .expect = "ab" },
    .{ .pat = "foo|foobar", .input = "foobar", .expect = "foo" },
    .{ .pat = "a(b|c|d)e", .input = "ade", .expect = "ade" },
    // quantifiers
    .{ .pat = "ab*", .input = "abbbc", .expect = "abbb" },
    .{ .pat = "ab+", .input = "ac", .expect = null },
    .{ .pat = "ab?c", .input = "ac", .expect = "ac" },
    .{ .pat = "a.*c", .input = "abXYZc end c", .expect = "abXYZc end c" },
    .{ .pat = "a.*?c", .input = "abXcYc", .expect = "abXc" },
    .{ .pat = "a+?", .input = "aaaa", .expect = "a" },
    .{ .pat = "a{3}", .input = "aaaaa", .expect = "aaa" },
    .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
    .{ .pat = "a{0,2}b", .input = "b", .expect = "b" },
    .{ .pat = "(ab){2,3}", .input = "ababab", .expect = "ababab" },
    // anchors
    .{ .pat = "^abc", .input = "abcdef", .expect = "abc" },
    .{ .pat = "^abc", .input = "xabc", .expect = null },
    .{ .pat = "abc$", .input = "xxabc", .expect = "abc" },
    .{ .pat = "^abc$", .input = "abc\n", .expect = null },
    .{ .pat = "(?m)^line2", .input = "line1\nline2\nline3", .expect = "line2" },
    // word boundaries
    .{ .pat = "\\bcat\\b", .input = "a cat!", .expect = "cat" },
    .{ .pat = "\\bcat\\b", .input = "category", .expect = null },
    .{ .pat = "\\Bcat\\B", .input = "locator", .expect = "cat" },
    // captures (the whole-match span must agree even where group reporting differs)
    .{ .pat = "(\\d{4})-(\\d{2})-(\\d{2})", .input = "x 2026-06-07 y", .expect = "2026-06-07" },
    .{ .pat = "a(b)?c", .input = "ac", .expect = "ac" },
    .{ .pat = "(\\w)+", .input = "abc", .expect = "abc" },
    // unicode
    .{ .pat = "\\w+", .input = "héllo, wörld", .expect = "héllo" },
    .{ .pat = "\\p{L}+", .input = "abc123", .expect = "abc" },
    .{ .pat = "\\p{Nd}+", .input = "x٤٥٦y", .expect = "٤٥٦" },
    .{ .pat = "(?i)abc", .input = "XYZABCxyz", .expect = "ABC" },
    .{ .pat = "é{2,3}", .input = "xééééy", .expect = "ééé" },
    // case-fold ORBIT closure: every member of a simple-fold orbit must match,
    // even when reached transitively (K, k, and U+212A KELVIN SIGN all fold to
    // 'k'; A-ring U+00C5, å U+00E5, and U+212B ANGSTROM SIGN all fold to 'å').
    .{ .pat = "(?i)k", .input = "\u{212A}", .expect = "\u{212A}" },
    .{ .pat = "(?i)K", .input = "\u{212A}", .expect = "\u{212A}" },
    .{ .pat = "(?i)\u{212A}", .input = "k", .expect = "k" },
    .{ .pat = "(?i)\u{00C5}", .input = "\u{212B}", .expect = "\u{212B}" },
    .{ .pat = "(?i)[k]", .input = "\u{212A}", .expect = "\u{212A}" },
    // pathological (linear-time guarantee for both engines)
    .{ .pat = "(a*)*b", .input = "aaaaaaaaaaaaX", .expect = null },
};

/// Pure-literal subset — additionally valid for the `literal` backend.
const literal_cases = [_]Case{
    .{ .pat = "abc", .input = "xxabcyy", .expect = "abc" },
    .{ .pat = "abc", .input = "ab", .expect = null },
    .{ .pat = "héllo", .input = "say héllo!", .expect = "héllo" },
    .{ .pat = "cat|dog", .input = "i have a dog", .expect = "dog" },
    .{ .pat = "a|ab", .input = "ab", .expect = "a" },
    .{ .pat = "ab|a", .input = "ab", .expect = "ab" },
    .{ .pat = "cat|dog|fish", .input = "redfish", .expect = "fish" },
};

fn checkRuntime(comptime B: type, case: Case) !void {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, case.pat, &diag, .{}) catch |e| {
        std.debug.print("compile failed for /{s}/ on {s}: {s}\n", .{ case.pat, @typeName(B), @errorName(e) });
        return e;
    };
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const m = re.find(&sc, case.input);
    if (case.expect) |exp| {
        if (m == null) {
            std.debug.print("/{s}/ on {s}: expected \"{s}\", got no match\n", .{ case.pat, @typeName(B), exp });
            return error.NoMatch;
        }
        testing.expectEqualStrings(exp, m.?.slice(case.input)) catch {
            std.debug.print("/{s}/ on {s}: backend disagreed\n", .{ case.pat, @typeName(B) });
            return error.Mismatch;
        };
    } else if (m != null) {
        std.debug.print("/{s}/ on {s}: expected no match, got \"{s}\"\n", .{ case.pat, @typeName(B), m.?.slice(case.input) });
        return error.UnexpectedMatch;
    }
}

test "general cases agree across pikevm / backtrack / auto" {
    for (general_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

test "literal cases agree across all four backends (incl. literal)" {
    for (literal_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
        try checkRuntime(literal, c);
    }
}

test "byte Pike VM agrees on the byte-lowerable subset (the lowering is correct)" {
    // The byte lowering's correctness proof: for every case the byte engine *can*
    // run (i.e. no `\b`/`\X`), it must reach the SAME result the code-point engines
    // are checked against above. Cases it can't lower are covered by those engines.
    var ran: usize = 0;
    for (general_cases) |c| {
        if (!byteLowerablePattern(c.pat)) continue;
        try checkRuntime(bytepike, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!byteLowerablePattern(c.pat)) continue;
        try checkRuntime(bytepike, c);
        ran += 1;
    }
    try testing.expect(ran > 0); // guard against the filter silently skipping everything
}

// ── lazy DFA span conformance ─────────────────────────────────────────────────────

/// Whether `pattern` can run on the lazy DFA (byte-lowerable AND no zero-width
/// anchors — the v1 DFA declines `^ $ \b \X` and line anchors). A narrower gate than
/// `byteLowerablePattern`, so it gets its own predicate.
fn dfaRoutablePattern(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    return dfa.supports(h);
}

test "lazy DFA agrees with the code-point engines on its eligible subset (span-only)" {
    // The DFA is span-only, so it is checked through `re.find` (the whole-match span)
    // exactly like every other backend — its span must equal what pikevm/backtrack/auto
    // are pinned to. Cases with `\b`/`\X`/anchors it cannot run are covered by those.
    var ran: usize = 0;
    for (general_cases) |c| {
        if (!dfaRoutablePattern(c.pat)) continue;
        try checkRuntime(dfa, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!dfaRoutablePattern(c.pat)) continue;
        try checkRuntime(dfa, c);
        ran += 1;
    }
    try testing.expect(ran > 0); // guard against the gate silently skipping everything
}

test "auto's byte_engine=.enabled is results-invariant (DFA span == NFA span) and routes to dfa" {
    // Flipping the strategy knob must not change a single match (DESIGN §3). For every
    // DFA-eligible case, the .enabled build and the default build must return
    // byte-identical spans. With .enabled an eligible pattern routes to the DFA span
    // arm ("dfa") unless it is a pure literal (then "literal", already optimal); it is
    // never left on the plain "nfa" arm.
    const gpa = testing.allocator;
    var ran: usize = 0;
    var dfa_routed: usize = 0;
    inline for (general_cases ++ literal_cases) |c| {
        if (dfaRoutablePattern(c.pat)) {
            var diag: regex.Diagnostic = .{};
            var re0 = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{});
            defer re0.deinit();
            var sc0 = try @TypeOf(re0).Scratch.init(gpa, &re0.program);
            defer sc0.deinit(gpa);

            var re1 = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{ .strategy = .{ .byte_engine = .enabled } });
            defer re1.deinit();
            var sc1 = try @TypeOf(re1).Scratch.init(gpa, &re1.program);
            defer sc1.deinit(gpa);

            const r = auto.route(&re1.program);
            try testing.expect(!std.mem.eql(u8, r, "nfa")); // eligible+enabled ⇒ nfa+dfa or literal, never plain nfa
            if (std.mem.eql(u8, r, "nfa+dfa")) dfa_routed += 1;

            const m0 = re0.find(&sc0, c.input);
            const m1 = re1.find(&sc1, c.input);
            try testing.expectEqual(m0 == null, m1 == null);
            if (m0) |a| {
                try testing.expectEqual(a.start, m1.?.start);
                try testing.expectEqual(a.end, m1.?.end);
            }
            ran += 1;
        }
    }
    try testing.expect(ran > 0);
    try testing.expect(dfa_routed > 0); // the DFA span arm is actually exercised
}

test "auto with byte_engine=.enabled still fills captures via the Pike VM" {
    // The DFA finds the span; captures are span-only's job for the code-point engine.
    // A capture pattern compiled with the DFA enabled must still report correct groups
    // (auto routes searchCaptures to the Pike VM, span scan to the DFA).
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "(\\w+)@(\\w+)", &diag, .{ .strategy = .{ .byte_engine = .enabled } });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);

    try testing.expectEqualStrings("nfa+dfa", auto.route(&re.program));
    var slots: [6]?usize = undefined;
    const c = re.captures(&sc, &slots, "ping bob@example").?;
    try testing.expectEqualStrings("bob@example", c.match().slice("ping bob@example"));
    try testing.expectEqualStrings("bob", c.groupSlice(1).?);
    try testing.expectEqualStrings("example", c.groupSlice(2).?);
}

// ── capture-array conformance ─────────────────────────────────────────────────────

const capture_cases = [_][]const u8{
    "(\\d{4})-(\\d{2})-(\\d{2})",
    "(\\w+)@(\\w+)\\.(\\w+)",
    "a(b)?(c)",
    "(a+)(b+)",
    "(?<y>\\d+)-(?<m>\\d+)",
    "((a)(b))+",
};

fn captureSlots(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, out: []?usize) !bool {
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(B, gpa, pattern, &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    @memset(out, null);
    return re.captures(&sc, out, input) != null;
}

test "capture slot arrays agree across pikevm / backtrack / auto" {
    const gpa = testing.allocator;
    const inputs = [_][]const u8{ "2026-06-07", "alice@example.com", "abc", "aaabb", "2026-06", "abab" };
    for (capture_cases) |pat| {
        for (inputs) |in| {
            var a: [16]?usize = undefined;
            var b: [16]?usize = undefined;
            var c: [16]?usize = undefined;
            const ra = try captureSlots(pikevm, gpa, pat, in, &a);
            const rb = try captureSlots(backtrack, gpa, pat, in, &b);
            const rc = try captureSlots(auto, gpa, pat, in, &c);
            try testing.expectEqual(ra, rb);
            try testing.expectEqual(ra, rc);
            if (ra) {
                try testing.expectEqualSlices(?usize, &a, &b);
                try testing.expectEqualSlices(?usize, &a, &c);
            }
            // The byte Pike VM must report the SAME capture slots for every
            // byte-lowerable capture pattern (none here use `\b`).
            if (byteLowerablePattern(pat)) {
                var d: [16]?usize = undefined;
                const rd = try captureSlots(bytepike, gpa, pat, in, &d);
                try testing.expectEqual(ra, rd);
                if (ra) try testing.expectEqualSlices(?usize, &a, &d);
            }
        }
    }
}

// ── auto's internal input-size switch is transparent ──────────────────────────────

test "auto agrees with itself across the small/large input switch" {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "a\\w+z", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);

    // Small input → backtrack arm.
    try testing.expectEqualStrings("aBCz", re.find(&sc, "..aBCz..").?.slice("..aBCz.."));

    // Large input (> auto's backtrack threshold) → Pike VM arm; same answer.
    const big = try gpa.alloc(u8, 5000);
    defer gpa.free(big);
    @memset(big, '.');
    @memcpy(big[2500 .. 2500 + 4], "aQRz");
    try testing.expectEqualStrings("aQRz", re.find(&sc, big).?.slice(big));
}

// ── comptime parity across backends ───────────────────────────────────────────────

const comptime_cases = [_]Case{
    .{ .pat = "\\d+", .input = "abc123def", .expect = "123" },
    .{ .pat = "[a-z]+\\d*", .input = "  abc123  ", .expect = "abc123" },
    .{ .pat = "cat|dog", .input = "a dog", .expect = "dog" },
    .{ .pat = "(\\w+)@(\\w+)", .input = "x a@b y", .expect = "a@b" },
    .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
    .{ .pat = "\\bword\\b", .input = "a word here", .expect = "word" },
};

fn checkComptime(comptime B: type, comptime case: Case) !void {
    const Re = comptime regex.compileComptimeWith(B, case.pat, .{});
    const m = comptime Re.findComptime(case.input);
    if (case.expect) |exp| {
        try testing.expect(m != null);
        try testing.expectEqualStrings(exp, m.?.slice(case.input));
    } else {
        try testing.expect(m == null);
    }
}

test "comptime results match across pikevm / backtrack / auto" {
    inline for (.{ pikevm, backtrack, auto }) |B| {
        inline for (comptime_cases) |c| {
            try checkComptime(B, c);
        }
    }
}

test "comptime == runtime for the same backend" {
    inline for (.{ pikevm, backtrack, auto }) |B| {
        inline for (comptime_cases) |c| {
            try checkRuntime(B, c); // runtime
            try checkComptime(B, c); // comptime — same expectation
        }
    }
}

test "byte Pike VM matches at comptime too (small ASCII subset)" {
    inline for (byte_comptime_cases) |c| {
        try checkComptime(bytepike, c); // ro_data byte program, matched in const-eval
        try checkRuntime(bytepike, c); // and the same answer at runtime
    }
}

// ── program range interning ───────────────────────────────────────────────────────

test "identical class blocks are interned into one range-block in the program" {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};

    // Baseline: a single \w resolves to N ranges.
    var one = try regex.compileRuntimeWith(pikevm, gpa, "\\w", &diag, .{});
    defer one.deinit();
    const n = one.program.ranges.len;
    try testing.expect(n > 1); // \w is a real Unicode class, many ranges

    // Repeating the SAME class — across concatenation, capture groups, and a
    // counted repetition — must NOT multiply the stored ranges: every \w block
    // is interned to the first. The program holds exactly one \w worth of ranges.
    for ([_][]const u8{ "\\w\\w\\w", "(\\w)(\\w)(\\w)", "\\w{4,9}" }) |pat| {
        var re = try regex.compileRuntimeWith(pikevm, gpa, pat, &diag, .{});
        defer re.deinit();
        try testing.expectEqual(n, re.program.ranges.len);
    }

    // Distinct classes are NOT collapsed — \w and \d stay separate blocks.
    var mixed = try regex.compileRuntimeWith(pikevm, gpa, "\\w\\d", &diag, .{});
    defer mixed.deinit();
    try testing.expect(mixed.program.ranges.len > n);
}

test {
    testing.refAllDecls(@This());
}
