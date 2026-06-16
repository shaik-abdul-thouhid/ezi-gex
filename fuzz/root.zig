//! Coverage-guided fuzz targets for ezi_gex, built on Zig's `std.testing.fuzz`
//! + `Smith` (structure-aware input generation).
//!
//! ══════════════════════════════════════════════════════════════════════════════
//! RUNNING — and keeping it bounded
//! ══════════════════════════════════════════════════════════════════════════════
//!
//! These tests double as ordinary, FINITE unit tests: under a plain
//!
//!     zig build test-fuzz            # or the `fuzz` unit of `zig build test`
//!
//! `std.testing.fuzz` just replays the seed corpus plus one empty input through
//! each body and returns — a few iterations, milliseconds, no instrumentation.
//! This is the regression mode and is always safe to run in CI.
//!
//! To actually fuzz, add `--fuzz` — but ALWAYS bound it:
//!
//!     zig build test-fuzz --fuzz=200000     # ~hundreds of thousands of iters
//!     zig build test-fuzz --fuzz=2M         # K/M/G suffixes accepted
//!
//! ⚠️  Bare `zig build test --fuzz` (no `=N`) runs **forever**, across *every*
//! test binary, until you Ctrl-C it. That is by design — it is a soak run, not a
//! hang. For a bounded session always use `--fuzz=<N>` and target the `test-fuzz`
//! unit specifically (not the whole `test` aggregate), so you instrument only
//! this binary. Each iteration here is intentionally cheap — patterns are capped
//! at `pattern_smith.max_pattern_len` bytes with `{m,n}` bounds ≤
//! `max_rep_bound`, and haystacks at `max_input_len` — so the fuzzer makes steady
//! forward progress instead of stalling on one pathological case.
//!
//! ══════════════════════════════════════════════════════════════════════════════
//! WHAT IS COVERED
//! ══════════════════════════════════════════════════════════════════════════════
//!
//!   1. `scanner robustness`  — arbitrary bytes through `parseWith` (with a
//!      fuzzer-chosen repetition limit) must never crash: either a clean AST or
//!      `error.InvalidPattern`, never UB / a panic / a leak.
//!   2. `backends agree`      — a structurally plausible pattern (PatternSmith)
//!      matched against a generated haystack must yield byte-identical spans on
//!      the Pike VM, the bounded backtracker, and the `auto` dispatcher.
//!   3. `repetition limit`    — the new `{m,n}` ceiling is enforced exactly: the
//!      scanner's accept/reject decision matches the specified rule for every
//!      (min, max, limit) triple.
//!   4. `anchors/zero-width`  — a focused differential over the byte-DFA `supports`
//!      gate: anchor- and empty-heavy patterns (`^ $ \A \z \b \B (?m:…)`, empty
//!      branches, nullable quantifiers) from `pattern_smith.genAnchors`, matched
//!      over newline-rich inputs, must agree across the three backends.
//!   5. `captures`            — full capture-slot arrays (every group, not just the
//!      whole-match span) agree across pikevm / backtrack / auto / onepass.
//!   6. `iteration`           — the `findAll` non-overlapping match SEQUENCE agrees
//!      across backends, and `count` equals it (the empty-match-advance hotspot).
//!   7. `unicode`             — `\p{…}` / scripts / multi-byte literals / `(?i)`
//!      folding from `pattern_smith.genUnicode`, over BOTH valid multi-byte UTF-8 and
//!      raw (often invalid) bytes, agree across backends; plus a `\X`-grapheme
//!      no-crash target on the backtracker (its sole backend).
//!   8. `strategy-invariant`  — flipping any `Options.strategy` field (byte_engine /
//!      prefilter / simd) must NEVER change the match — the results-invariance contract.

const std = @import("std");
const builtin = @import("builtin");
const Smith = std.testing.Smith;
const gex = @import("ezi_gex");
const pattern_smith = @import("pattern_smith.zig");

/// Largest haystack a matching target feeds the engine. Small so the bounded
/// backtracker's visited set stays tiny and each iteration is fast.
const max_input_len = 48;

// ══════════════════════════════════════════════════════════════════════════════
// Target 1 — the scanner must never crash on arbitrary input
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: parseWith never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, scannerRobustness, .{ .corpus = &seed_corpus });
}

fn scannerRobustness(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    var buf: [pattern_smith.max_pattern_len]u8 = undefined;
    const n = smith.slice(&buf);
    const pattern = buf[0..n];

    // Exercise the new configurable ceiling too: any u32 limit is legal.
    const limit = smith.value(u32);

    var diag: gex.Diagnostic = .{};
    const a = gex.parseWith(gpa, pattern, &diag, .{ .max_repetition = limit }) catch |e| switch (e) {
        // The only sanctioned failures: a rejected pattern (with a diagnostic) or
        // OOM. Anything else would be a bug surfacing as an unexpected error.
        error.InvalidPattern => {
            // A rejection must always record a real, located reason.
            std.debug.assert(diag.code != .none);
            return;
        },
        error.OutOfMemory => return,
    };
    defer a.deinit(gpa);
    // A success must leave the diagnostic clean.
    std.debug.assert(diag.isOk());
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 2 — every backend agrees (differential)
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: pikevm / backtrack / auto agree on structured patterns" {
    try std.testing.fuzz({}, backendsAgree, .{ .corpus = &seed_corpus });
}

/// Per-backend match outcome, so we can compare across engines.
const Outcome = union(enum) {
    /// Scanner/HIR rejected the pattern (deterministic across backends).
    invalid,
    /// A resource ceiling tripped (PatternTooComplex) — don't compare.
    skip,
    /// Matched span, or `null` for no match.
    span: ?[2]usize,
};

fn matchWith(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!Outcome {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch |e| switch (e) {
        error.InvalidPattern => return .invalid,
        error.OutOfMemory => return error.OutOfMemory,
        // PatternTooComplex / Unsupported / any other build-resource ceiling: a
        // routing/capacity decision, not a match result — don't compare it.
        else => return .skip,
    };
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const m = re.find(&sc, input);
    return .{ .span = if (m) |mm| .{ mm.start, mm.end } else null };
}

fn backendsAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    var ps = pattern_smith.gen(smith);
    const pattern = ps.slice();

    var ibuf: [max_input_len]u8 = undefined;
    const n = smith.slice(&ibuf);
    // Map raw fuzzer bytes onto the shared alphabet so matches actually occur.
    for (ibuf[0..n]) |*b| b.* = pattern_smith.alphabet[b.* % pattern_smith.alphabet.len];
    const input = ibuf[0..n];

    try assertBackendsAgree(gpa, pattern, input);
}

/// The shared differential assertion: the Pike VM, the bounded backtracker, and
/// `auto` must agree on validity and (when valid) on a byte-identical leftmost-first
/// span. The Pike VM is the reference. Used by both the structured and the
/// anchor/zero-width targets.
fn assertBackendsAgree(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!void {
    @disableInstrumentation();
    const pike = try matchWith(gex.backends.pikevm, gpa, pattern, input);
    const back = try matchWith(gex.backends.backtrack, gpa, pattern, input);
    const auto = try matchWith(gex.backends.auto, gpa, pattern, input);

    if (pike == .skip or back == .skip or auto == .skip) return;

    // All three see the same pattern, so the validity verdict must agree.
    if (pike == .invalid or back == .invalid or auto == .invalid) {
        if (!(pike == .invalid and back == .invalid and auto == .invalid)) {
            std.debug.print("validity disagreement on /{s}/: pike={s} back={s} auto={s}\n", .{
                pattern, @tagName(pike), @tagName(back), @tagName(auto),
            });
            return error.ValidityDisagreement;
        }
        return;
    }

    // And the leftmost-first span must be byte-identical.
    if (!spanEq(pike.span, back.span) or !spanEq(pike.span, auto.span)) {
        std.debug.print("span disagreement on /{s}/ over \"{s}\"\n", .{ pattern, input });
        return error.SpanDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 4 — anchors + zero-width: the byte-DFA `supports` gate (differential)
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: anchors/zero-width agree across pikevm / backtrack / auto" {
    try std.testing.fuzz({}, anchorsAgree, .{ .corpus = &anchor_seed_corpus });
}

fn anchorsAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    var ps = pattern_smith.genAnchors(smith);
    const pattern = ps.slice();

    // Inputs over a tiny alphabet rich in newlines, so `^`/`$`/`(?m)` boundaries fire.
    var ibuf: [16]u8 = undefined;
    const n = @min(smith.slice(&ibuf), ibuf.len);
    const alpha = "ab\n";
    for (ibuf[0..n]) |*b| b.* = alpha[b.* % alpha.len];

    try assertBackendsAgree(gpa, pattern, ibuf[0..n]);
}

fn spanEq(a: ?[2]usize, b: ?[2]usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?[0] == b.?[0] and a.?[1] == b.?[1];
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 5 — capture slots agree (not just the whole-match span)
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: capture slots agree across pikevm / backtrack / auto / onepass" {
    try std.testing.fuzz({}, capturesAgree, .{ .corpus = &seed_corpus });
}

/// Largest slot array (= 2·(groups+1)) a capture target compares; bigger → skip.
const max_slots = 96;

const CapRes = struct {
    tag: enum { invalid, skip, none, matched },
    len: usize = 0,
    slots: [max_slots]?usize = undefined,
};

fn capsWith(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!CapRes {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch |e| switch (e) {
        error.InvalidPattern => return .{ .tag = .invalid },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .tag = .skip }, // Unsupported (e.g. onepass declines non-one-pass) / capacity
    };
    defer re.deinit();
    const n = re.slotCount();
    if (n > max_slots) return .{ .tag = .skip };
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var buf: [max_slots]?usize = undefined;
    const c = re.captures(&sc, buf[0..n], input);
    if (c == null) return .{ .tag = .none };
    var r = CapRes{ .tag = .matched, .len = n };
    @memcpy(r.slots[0..n], buf[0..n]);
    return r;
}

fn capResEq(a: CapRes, b: CapRes) bool {
    if (a.tag != b.tag) return false;
    if (a.tag != .matched) return true;
    if (a.len != b.len) return false;
    for (a.slots[0..a.len], b.slots[0..b.len]) |x, y| {
        if ((x == null) != (y == null)) return false;
        if (x != null and x.? != y.?) return false;
    }
    return true;
}

fn capturesAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    var ps = pattern_smith.gen(smith);
    const pattern = ps.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const n = smith.slice(&ibuf);
    for (ibuf[0..n]) |*b| b.* = pattern_smith.alphabet[b.* % pattern_smith.alphabet.len];
    const input = ibuf[0..n];

    const pike = try capsWith(gex.backends.pikevm, gpa, pattern, input); // oracle
    if (pike.tag == .skip) return;
    // backtrack and auto must match the Pike VM's full slot array; onepass too when it
    // accepts the pattern (it declines non-one-pass → .skip, which we ignore).
    try checkCaps(gex.backends.backtrack, gpa, pike, pattern, input);
    try checkCaps(gex.backends.auto, gpa, pike, pattern, input);
    try checkCaps(gex.backends.onepass, gpa, pike, pattern, input);
}

fn checkCaps(comptime B: type, gpa: std.mem.Allocator, oracle: CapRes, pattern: []const u8, input: []const u8) anyerror!void {
    @disableInstrumentation();
    const r = try capsWith(B, gpa, pattern, input);
    if (r.tag == .skip) return;
    if (!capResEq(oracle, r)) {
        std.debug.print("capture disagreement on /{s}/ over \"{s}\" ({s}): pike={s} other={s}\n", .{
            pattern, input, @typeName(B), @tagName(oracle.tag), @tagName(r.tag),
        });
        return error.CaptureDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 6 — non-overlapping iteration agrees (findAll / count consistency)
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: findAll sequence + count agree across pikevm / backtrack / auto" {
    try std.testing.fuzz({}, iterationAgree, .{ .corpus = &seed_corpus });
}

/// Cap on collected matches per run — bounds work; a real pattern over a 48-byte
/// input never produces more (an empty match advances by ≥1).
const max_matches = 64;

const IterRes = struct {
    tag: enum { invalid, skip, ok },
    len: usize = 0,
    spans: [max_matches][2]usize = undefined,
};

fn iterWith(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!IterRes {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch |e| switch (e) {
        error.InvalidPattern => return .{ .tag = .invalid },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .tag = .skip },
    };
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var r = IterRes{ .tag = .ok };
    var it = re.findAll(&sc, input);
    while (it.next()) |m| {
        if (r.len >= max_matches) return .{ .tag = .skip }; // pathological; don't compare
        r.spans[r.len] = .{ m.start, m.end };
        r.len += 1;
    }
    // Internal consistency: count() must equal the number of findAll matches.
    var sc2 = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc2.deinit(gpa);
    if (re.count(&sc2, input) != r.len) {
        std.debug.print("count != findAll on /{s}/ over \"{s}\" ({s})\n", .{ pattern, input, @typeName(B) });
        return error.CountMismatch;
    }
    return r;
}

fn iterResEq(a: IterRes, b: IterRes) bool {
    if (a.tag != b.tag) return false;
    if (a.tag != .ok) return true;
    if (a.len != b.len) return false;
    for (a.spans[0..a.len], b.spans[0..b.len]) |x, y| {
        if (x[0] != y[0] or x[1] != y[1]) return false;
    }
    return true;
}

fn iterationAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var ps = pattern_smith.gen(smith);
    const pattern = ps.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const n = smith.slice(&ibuf);
    for (ibuf[0..n]) |*b| b.* = pattern_smith.alphabet[b.* % pattern_smith.alphabet.len];
    const input = ibuf[0..n];

    const pike = try iterWith(gex.backends.pikevm, gpa, pattern, input);
    if (pike.tag == .skip) return;
    try checkIter(gex.backends.backtrack, gpa, pike, pattern, input);
    try checkIter(gex.backends.auto, gpa, pike, pattern, input);
}

fn checkIter(comptime B: type, gpa: std.mem.Allocator, oracle: IterRes, pattern: []const u8, input: []const u8) anyerror!void {
    @disableInstrumentation();
    const r = try iterWith(B, gpa, pattern, input);
    if (r.tag == .skip) return;
    if (!iterResEq(oracle, r)) {
        std.debug.print("findAll disagreement on /{s}/ over \"{s}\" ({s}): pike.len={d} other.len={d}\n", .{
            pattern, input, @typeName(B), oracle.len, r.len,
        });
        return error.IterationDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 8 — the `strategy` tier is results-invariant (a contract)
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: strategy-tier flags never change the match (results-invariant)" {
    try std.testing.fuzz({}, strategyInvariant, .{ .corpus = &seed_corpus });
}

fn matchWithOpts(comptime opts: gex.Options, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!Outcome {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntime(gpa, pattern, &diag, opts) catch |e| switch (e) {
        error.InvalidPattern => return .invalid,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .skip,
    };
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const m = re.find(&sc, input);
    return .{ .span = if (m) |mm| .{ mm.start, mm.end } else null };
}

fn strategyInvariant(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var ps = pattern_smith.gen(smith);
    const pattern = ps.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const n = smith.slice(&ibuf);
    for (ibuf[0..n]) |*b| b.* = pattern_smith.alphabet[b.* % pattern_smith.alphabet.len];
    const input = ibuf[0..n];

    // Every `strategy` permutation MUST yield the identical span (the contract).
    const base = try matchWithOpts(.{}, gpa, pattern, input);
    if (base == .skip or base == .invalid) return;
    const variants = .{
        gex.Options{ .strategy = .{ .byte_engine = .disabled } },
        gex.Options{ .strategy = .{ .byte_engine = .enabled } },
        gex.Options{ .strategy = .{ .prefilter = false } },
        gex.Options{ .strategy = .{ .simd = .off } },
        gex.Options{ .strategy = .{ .byte_engine = .disabled, .prefilter = false, .simd = .off } },
    };
    inline for (variants) |opts| {
        const r = try matchWithOpts(opts, gpa, pattern, input);
        if (r != .skip and !spanEq(base.span, r.span)) {
            std.debug.print("strategy NOT results-invariant on /{s}/ over \"{s}\"\n", .{ pattern, input });
            return error.StrategyVaried;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 7 — Unicode patterns over valid multi-byte AND raw/invalid UTF-8 input
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: Unicode patterns agree across pikevm / backtrack / auto" {
    try std.testing.fuzz({}, unicodeAgree, .{ .corpus = &unicode_seed_corpus });
}

fn unicodeAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var ps = pattern_smith.genUnicode(smith);
    const pattern = ps.slice();

    var ibuf: [max_input_len]u8 = undefined;
    var input: []const u8 = undefined;
    if (smith.boolWeighted(2, 1)) {
        // Valid multi-byte UTF-8 (assembled from whole code points).
        input = ibuf[0..pattern_smith.unicodeInput(smith, &ibuf)];
    } else {
        // Raw fuzzer bytes — frequently INVALID UTF-8; the engines must still agree
        // (dead-on-invalid is a consistent policy across backends).
        input = ibuf[0..smith.slice(&ibuf)];
    }

    try assertBackendsAgree(gpa, pattern, input);
}

// `\X` (grapheme) is backtrack-only — no differential partner — so just assert it
// never crashes / leaks on the bounded backtracker over arbitrary bytes.
test "fuzz: \\X grapheme patterns never crash on the backtracker" {
    try std.testing.fuzz({}, graphemeNoCrash, .{ .corpus = &.{ "\\X", "\\X+", "a\\X\\X", "(?:\\X)+" } });
}

fn graphemeNoCrash(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    // Prefix a fuzzer-chosen small pattern body with `\X` so it's grapheme-bearing.
    var pbuf: [40]u8 = undefined;
    const pn = @min(smith.slice(&pbuf), pbuf.len - 3);
    var pat: [43]u8 = undefined;
    @memcpy(pat[0..3], "\\X+");
    @memcpy(pat[3 .. 3 + pn], pbuf[0..pn]);
    var ibuf: [max_input_len]u8 = undefined;
    const input = ibuf[0..pattern_smith.unicodeInput(smith, &ibuf)];

    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(gex.backends.backtrack, gpa, pat[0 .. 3 + pn], &diag, .{}) catch return;
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    _ = re.find(&sc, input); // must not crash / leak
}

// ══════════════════════════════════════════════════════════════════════════════
// Target 3 — the {m,n} repetition ceiling is enforced exactly
// ══════════════════════════════════════════════════════════════════════════════

test "fuzz: repetition limit accept/reject is exact" {
    try std.testing.fuzz({}, repetitionLimit, .{ .corpus = &seed_corpus });
}

fn repetitionLimit(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    // A (min, max?, limit) triple over a range that straddles the boundary.
    const min = smith.valueRangeAtMost(u32, 0, 2000);
    const has_max = smith.boolWeighted(1, 2); // mostly {m,n}
    const max: ?u32 = if (has_max) smith.valueRangeAtMost(u32, 0, 2000) else null;
    const limit = smith.valueRangeAtMost(u32, 0, 2000);

    // Build the pattern: `a{min}` / `a{min,}` / `a{min,max}`.
    var buf: [32]u8 = undefined;
    const pattern = if (max) |mx|
        std.fmt.bufPrint(&buf, "a{{{d},{d}}}", .{ min, mx }) catch unreachable
    else if (has_max)
        std.fmt.bufPrint(&buf, "a{{{d},}}", .{min}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "a{{{d}}}", .{min}) catch unreachable;

    // Predict the scanner's verdict from the documented rule:
    //   over-limit bound  → quantifier_exceeds_limit   (checked first)
    //   else min > max    → quantifier_out_of_order
    //   else              → accept
    const over_limit = min > limit or (max != null and max.? > limit);
    const out_of_order = max != null and min > max.?;

    var diag: gex.Diagnostic = .{};
    const r = gex.parseWith(gpa, pattern, &diag, .{ .max_repetition = limit });
    if (r) |a| {
        a.deinit(gpa);
        if (over_limit or out_of_order) {
            std.debug.print("/{s}/ (limit {d}) parsed but should have been rejected\n", .{ pattern, limit });
            return error.ShouldHaveRejected;
        }
    } else |e| switch (e) {
        error.OutOfMemory => return,
        error.InvalidPattern => {
            const want: gex.ErrorCode = if (over_limit) .quantifier_exceeds_limit else .quantifier_out_of_order;
            if (!over_limit and !out_of_order) {
                std.debug.print("/{s}/ (limit {d}) rejected but should have parsed ({s})\n", .{ pattern, limit, @tagName(diag.code) });
                return error.ShouldHaveParsed;
            }
            if (diag.code != want) {
                std.debug.print("/{s}/ (limit {d}): expected {s}, got {s}\n", .{ pattern, limit, @tagName(want), @tagName(diag.code) });
                return error.WrongDiagnostic;
            }
        },
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Seed corpus — a handful of patterns that hit interesting lexer/HIR states.
// In replay mode each is fed through `Smith` (little-endian byte reader), so they
// also serve as deterministic smoke inputs for `zig build test`.
// ══════════════════════════════════════════════════════════════════════════════

const seed_corpus = [_][]const u8{
    "abc",
    "a|b|c",
    "(a(b)c)*",
    "[a-c]{2,4}",
    "\\d+\\w*\\s?",
    "(?:ab)+",
    "(?i:ABC)",
    "^a.c$",
    "a{0,6}b{2}",
    "\\b\\w+\\b",
};

// Seeds for the Unicode target — properties, scripts, multi-byte literals, folding.
const unicode_seed_corpus = [_][]const u8{
    "\\p{L}+",
    "\\w+",
    "(?i:stra\xC3\x9fe)", // (?i:straße) — full-fold ß→ss
    "[\xCE\xB1-\xCF\x89]+", // [α-ω]+
    "\xE6\x97\xA5+", // 日+
    "\\p{Greek}",
    "a\\p{Nd}*?b",
    ".",
};

// Seeds for the anchor/zero-width target — shapes that hit anchor + empty states.
const anchor_seed_corpus = [_][]const u8{
    "^a$",
    "(?m:^a$)",
    "\\bword\\b",
    "a\\z",
    "\\Aa",
    "(?:|a)+",
    "(a|)*",
    "^$",
    "(?m:$)\n",
    "\\b(?:a|)",
};

test {
    std.testing.refAllDecls(@This());
}
