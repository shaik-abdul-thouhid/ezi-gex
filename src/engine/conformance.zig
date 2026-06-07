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
const auto = @import("backends/auto.zig");

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
    var sc = try re.newScratch(gpa);
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
    var sc = try re.newScratch(gpa);
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
        }
    }
}

// ── auto's internal input-size switch is transparent ──────────────────────────────

test "auto agrees with itself across the small/large input switch" {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "a\\w+z", &diag, .{});
    defer re.deinit();
    var sc = try re.newScratch(gpa);
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

test {
    testing.refAllDecls(@This());
}
