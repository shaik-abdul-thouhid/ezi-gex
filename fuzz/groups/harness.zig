//! Shared fuzz harness: the differential bodies + helpers every fuzz group calls.
//!
//! The targets in `fuzz/groups/*.zig` are thin — each is a `test` block that hands
//! one of the `pub fn` bodies here to `std.testing.fuzz`. Splitting the bodies out
//! lets each group compile into its **own** test binary (so they fuzz in parallel,
//! one OS process per core — see `fuzz/run-parallel.sh`) while sharing exactly one
//! copy of the differential logic.
//!
//! ── The differential, in one place ────────────────────────────────────────────
//! The **Pike VM is the oracle** (linear-time, capture-complete, every feature bar
//! `\X`). Every other backend that *accepts* a generated pattern must agree with it
//! byte-for-byte; a backend that *declines* (its `build` returns `Unsupported`, or a
//! resource ceiling trips) is `.skip`ped, never compared. That keeps the assertions
//! sound while still differencing the whole capability matrix:
//!
//!   * span / find / isMatch — pikevm vs backtrack, auto, bytepike, **dfa, edfa**,
//!     onepass, literal. (The DFA family — `dfa`/`edfa` — was previously unfuzzed.)
//!   * captures            — pikevm vs backtrack, auto, onepass, bytepike.
//!   * iteration + count   — pikevm vs backtrack, auto, bytepike, dfa, edfa.
//!   * replace             — pikevm vs backtrack, auto, bytepike ($-templates).
//!   * search offset / anchored — pikevm vs backtrack, auto, bytepike, dfa, edfa,
//!     over `findAt(.{ .start, .anchored, .span_end })`.
//!
//! Plus per-backend invariants that need no peer: `isMatch == (find != null)`,
//! `count == |findAll|`, and the anchored/offset relationships on the oracle itself.

const std = @import("std");
const builtin = @import("builtin");
const Smith = std.testing.Smith;
const gex = @import("ezi_gex");
const ps = @import("pattern_smith.zig");

pub const pattern_smith = ps;

/// Largest haystack a matching target feeds the engine. Small so the bounded
/// backtracker's visited set (`program × (input+1)` bits) stays tiny and each
/// iteration is fast.
pub const max_input_len = 64;

// ══════════════════════════════════════════════════════════════════════════════
// Input generation
// ══════════════════════════════════════════════════════════════════════════════

/// Generate a haystack into `buf`. 3:1 it draws from the shared alphabet (so
/// matches actually happen and match-path code is exercised) vs raw full-range
/// bytes (so the no-match / prefilter-miss / invalid-UTF-8 paths are too).
pub fn genInput(smith: *Smith, buf: []u8) []const u8 {
    @disableInstrumentation();
    const n = smith.slice(buf[0..@min(buf.len, max_input_len)]);
    if (smith.boolWeighted(3, 1)) {
        for (buf[0..n]) |*b| b.* = ps.alphabet[b.* % ps.alphabet.len];
    }
    return buf[0..n];
}

// ══════════════════════════════════════════════════════════════════════════════
// Byte-engine ASCII-`\b` contract (see engine/conformance.zig)
// ══════════════════════════════════════════════════════════════════════════════
//
// CONVENTION: the byte engines — `bytepike`, eager `edfa`, lazy `dfa` — evaluate `\b`/`\B`
// as **ASCII** word boundaries. That is exact on ASCII input (ASCII and Unicode boundaries
// coincide there), and the dispatcher (`auto`) routes a `\b` pattern over **non-ASCII** input
// to the code-point engines, so a *pinned* byte engine is only contracted on ASCII input for a
// `\b` pattern. The differential honours that: for a `\b`-bearing pattern over a non-ASCII
// haystack, the byte engines are skipped (the code-point engines — pikevm/backtrack/onepass —
// and `auto`, which routes correctly, still run every case). Mirrors `conformance.byteEngineCanRunCase`.

fn isAsciiStr(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

/// True if `pattern` carries a `\b`/`\B` (via the HIR analysis flag, so a `\\b` literal or a
/// `[\b]` backspace does not count). Conservative: a parse/HIR failure ⇒ false (then every
/// backend agrees `.invalid` anyway).
fn patternHasWordBoundary(gpa: std.mem.Allocator, pattern: []const u8) bool {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = gex.buildHir(gpa, ast, .{}) catch return false;
    defer gex.freeHir(gpa, h);
    return h.analysis.has_word_boundary;
}

/// Whether the ASCII-`\b` byte engines may be compared on this case: always on ASCII input;
/// on non-ASCII input only when the pattern has no word boundary.
fn byteEnginesSafe(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) bool {
    @disableInstrumentation();
    if (isAsciiStr(input)) return true;
    return !patternHasWordBoundary(gpa, pattern);
}

/// Is `B` one of the ASCII-`\b` byte engines (gated on non-ASCII `\b` cases)?
fn isByteEngine(comptime B: type) bool {
    return B == gex.backends.bytepike or B == gex.backends.dfa or B == gex.backends.edfa;
}

// ══════════════════════════════════════════════════════════════════════════════
// Span / find / isMatch differential
// ══════════════════════════════════════════════════════════════════════════════

/// Per-backend match outcome, so we can compare across engines.
pub const Outcome = union(enum) {
    /// Scanner/HIR rejected the pattern (deterministic — same parse for every backend).
    invalid,
    /// The backend declined this pattern (Unsupported) or a resource ceiling tripped.
    skip,
    /// Matched span, or `null` for no match.
    span: ?[2]usize,
};

fn spanEq(a: ?[2]usize, b: ?[2]usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?[0] == b.?[0] and a.?[1] == b.?[1];
}

/// Compile `pattern` on backend `B`, run `find` over `input`, and check the
/// per-backend `isMatch == (find != null)` invariant before returning the span.
fn spanOf(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!Outcome {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch |e| switch (e) {
        error.InvalidPattern => return .invalid,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .skip, // Unsupported / PatternTooComplex — a routing decision, not a result.
    };
    defer re.deinit();

    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const m = re.find(&sc, input);
    const span: ?[2]usize = if (m) |mm| .{ mm.start, mm.end } else null;

    var sc2 = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc2.deinit(gpa);
    const im = re.isMatch(&sc2, input);
    if (im != (span != null)) {
        std.debug.print("isMatch != find on /{s}/ over \"{s}\" ({s}): isMatch={} find={?any}\n  pat.hex={x}\n  in.hex ={x}\n", .{ pattern, input, @typeName(B), im, span, pattern, input });
        return error.IsMatchInconsistent;
    }
    return .{ .span = span };
}

/// The backends compared against the Pike VM for plain `find`. dfa/edfa are
/// span-only but `find`-capable; onepass/literal decline most patterns (→ skip).
const span_backends = .{
    gex.backends.backtrack,
    gex.backends.auto,
    gex.backends.bytepike,
    gex.backends.dfa,
    gex.backends.edfa,
    gex.backends.onepass,
    gex.backends.literal,
};

/// Compare one backend's span against the oracle's (a normal fn so an early
/// `return` skips it — `inline for` forbids a runtime-guarded `continue`).
fn checkSpan(comptime B: type, gpa: std.mem.Allocator, oracle: Outcome, pattern: []const u8, input: []const u8, byte_safe: bool) anyerror!void {
    @disableInstrumentation();
    if (comptime isByteEngine(B)) if (!byte_safe) return;
    const r = try spanOf(B, gpa, pattern, input);
    if (r == .skip) return;
    if (oracle == .invalid or r == .invalid) {
        if ((oracle == .invalid) != (r == .invalid)) {
            std.debug.print("validity disagreement on /{s}/ ({s}): oracle={s} other={s}\n", .{ pattern, @typeName(B), @tagName(oracle), @tagName(r) });
            return error.ValidityDisagreement;
        }
        return;
    }
    if (!spanEq(oracle.span, r.span)) {
        std.debug.print("span disagreement on /{s}/ over \"{s}\" ({s}): oracle={?any} other={?any}\n  pat.hex={x}\n  in.hex ={x}\n", .{ pattern, input, @typeName(B), oracle.span, r.span, pattern, input });
        return error.SpanDisagreement;
    }
}

/// The shared differential assertion: every accepting backend must agree with the
/// Pike VM on validity and (when valid) on a byte-identical leftmost-first span.
pub fn assertBackendsAgree(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) anyerror!void {
    @disableInstrumentation();
    const oracle = try spanOf(gex.backends.pikevm, gpa, pattern, input);
    if (oracle == .skip) return; // even the oracle ducked it (shouldn't happen, but be safe)
    const byte_safe = byteEnginesSafe(gpa, pattern, input);
    inline for (span_backends) |B| try checkSpan(B, gpa, oracle, pattern, input, byte_safe);
}

// ── Target bodies (span) ──────────────────────────────────────────────────────

pub fn backendsAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.gen(smith);
    var ibuf: [max_input_len]u8 = undefined;
    try assertBackendsAgree(gpa, pat.slice(), genInput(smith, &ibuf));
}

pub fn anchorsAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.genAnchors(smith);
    // Inputs over a tiny alphabet rich in newlines, so `^`/`$`/`(?m)` boundaries fire.
    var ibuf: [24]u8 = undefined;
    const n = @min(smith.slice(&ibuf), ibuf.len);
    const alpha = "ab\n";
    for (ibuf[0..n]) |*b| b.* = alpha[b.* % alpha.len];
    try assertBackendsAgree(gpa, pat.slice(), ibuf[0..n]);
}

pub fn unicodeAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.genUnicode(smith);
    var ibuf: [max_input_len]u8 = undefined;
    var input: []const u8 = undefined;
    if (smith.boolWeighted(2, 1)) {
        input = ibuf[0..ps.unicodeInput(smith, &ibuf)]; // valid multi-byte UTF-8
    } else {
        input = ibuf[0..smith.slice(&ibuf)]; // raw fuzzer bytes — often invalid UTF-8
    }
    try assertBackendsAgree(gpa, pat.slice(), input);
}

// ══════════════════════════════════════════════════════════════════════════════
// Scanner robustness + repetition ceiling
// ══════════════════════════════════════════════════════════════════════════════

pub fn scannerRobustness(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    var buf: [ps.max_pattern_len]u8 = undefined;
    const n = smith.slice(&buf);
    const pattern = buf[0..n];
    const limit = smith.value(u32);

    var diag: gex.Diagnostic = .{};
    const a = gex.parseWith(gpa, pattern, &diag, .{ .max_repetition = limit }) catch |e| switch (e) {
        error.InvalidPattern => {
            std.debug.assert(diag.code != .none); // a rejection must record a real, located reason
            return;
        },
        error.OutOfMemory => return,
    };
    defer a.deinit(gpa);
    std.debug.assert(diag.isOk()); // a success must leave the diagnostic clean
}

pub fn repetitionLimit(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;

    const min = smith.valueRangeAtMost(u32, 0, 2000);
    const has_max = smith.boolWeighted(1, 2);
    const max: ?u32 = if (has_max) smith.valueRangeAtMost(u32, 0, 2000) else null;
    const limit = smith.valueRangeAtMost(u32, 0, 2000);

    var buf: [32]u8 = undefined;
    const pattern = if (max) |mx|
        std.fmt.bufPrint(&buf, "a{{{d},{d}}}", .{ min, mx }) catch unreachable
    else if (has_max)
        std.fmt.bufPrint(&buf, "a{{{d},}}", .{min}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "a{{{d}}}", .{min}) catch unreachable;

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
// Capture-slot differential
// ══════════════════════════════════════════════════════════════════════════════

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
        else => return .{ .tag = .skip },
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

const capture_backends = .{
    gex.backends.backtrack,
    gex.backends.auto,
    gex.backends.onepass,
    gex.backends.bytepike,
};

pub fn capturesAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.gen(smith);
    const pattern = pat.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);

    const oracle = try capsWith(gex.backends.pikevm, gpa, pattern, input);
    if (oracle.tag == .skip) return;
    const byte_safe = byteEnginesSafe(gpa, pattern, input);
    inline for (capture_backends) |B| try checkCaps(B, gpa, oracle, pattern, input, byte_safe);
}

fn checkCaps(comptime B: type, gpa: std.mem.Allocator, oracle: CapRes, pattern: []const u8, input: []const u8, byte_safe: bool) anyerror!void {
    @disableInstrumentation();
    if (comptime isByteEngine(B)) if (!byte_safe) return;
    const r = try capsWith(B, gpa, pattern, input);
    if (r.tag == .skip) return;
    if (!capResEq(oracle, r)) {
        std.debug.print("capture disagreement on /{s}/ over \"{s}\" ({s}): oracle={s} other={s}\n  pat.hex={x}\n  in.hex ={x}\n", .{ pattern, input, @typeName(B), @tagName(oracle.tag), @tagName(r.tag), pattern, input });
        return error.CaptureDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Iteration: findAll sequence + count consistency
// ══════════════════════════════════════════════════════════════════════════════

/// Cap on collected matches per run — bounds work; a real pattern over a 64-byte
/// input never produces more (an empty match advances by ≥1).
const max_matches = 96;

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

const iter_backends = .{
    gex.backends.backtrack,
    gex.backends.auto,
    gex.backends.bytepike,
    gex.backends.dfa,
    gex.backends.edfa,
};

pub fn iterationAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.gen(smith);
    const pattern = pat.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);

    const oracle = try iterWith(gex.backends.pikevm, gpa, pattern, input);
    if (oracle.tag == .skip) return;
    const byte_safe = byteEnginesSafe(gpa, pattern, input);
    inline for (iter_backends) |B| try checkIter(B, gpa, oracle, pattern, input, byte_safe);
}

fn checkIter(comptime B: type, gpa: std.mem.Allocator, oracle: IterRes, pattern: []const u8, input: []const u8, byte_safe: bool) anyerror!void {
    @disableInstrumentation();
    if (comptime isByteEngine(B)) if (!byte_safe) return;
    const r = try iterWith(B, gpa, pattern, input);
    if (r.tag == .skip) return;
    if (!iterResEq(oracle, r)) {
        std.debug.print("findAll disagreement on /{s}/ over \"{s}\" ({s}): oracle.len={d} other.len={d}\n  pat.hex={x}\n  in.hex ={x}\n", .{ pattern, input, @typeName(B), oracle.len, r.len, pattern, input });
        return error.IterationDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Replace differential ($-template substitution)
// ══════════════════════════════════════════════════════════════════════════════

const ReplaceRes = struct {
    tag: enum { invalid, skip, ok },
    bytes: []u8 = &.{},
};

/// Build a small, well-formed `$`-template: numbered groups, `$$`, and literals.
/// (No `${name}`/bare `$` — those edge cases are template-DSL fuzzing, separate
/// from the capture-substitution agreement this target pins.)
fn genTemplate(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const pieces = [_][]const u8{ "$0", "$1", "$2", "$$", "x", "-", " ", "" };
    var len: usize = 0;
    var i: u8 = 0;
    const parts = smith.valueRangeAtMost(u8, 1, 4);
    while (i < parts) : (i += 1) {
        const s = pieces[smith.index(pieces.len)];
        if (len + s.len > out.len) break;
        @memcpy(out[len .. len + s.len], s);
        len += s.len;
    }
    return out[0..len];
}

fn replaceWith(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, template: []const u8) anyerror!ReplaceRes {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch |e| switch (e) {
        error.InvalidPattern => return .{ .tag = .invalid },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .tag = .skip },
    };
    defer re.deinit();
    const n = re.slotCount();
    if (n > max_slots) return .{ .tag = .skip };
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var slots: [max_slots]?usize = undefined;
    const out = re.replaceAllAlloc(gpa, &sc, input, template, slots[0..n]) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .tag = .ok, .bytes = out };
}

const replace_backends = .{
    gex.backends.backtrack,
    gex.backends.auto,
    gex.backends.bytepike,
};

pub fn replaceAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.gen(smith);
    const pattern = pat.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);
    var tbuf: [24]u8 = undefined;
    const template = genTemplate(smith, &tbuf);

    const oracle = try replaceWith(gex.backends.pikevm, gpa, pattern, input, template);
    if (oracle.tag != .ok) return;
    defer gpa.free(oracle.bytes);
    const byte_safe = byteEnginesSafe(gpa, pattern, input);
    inline for (replace_backends) |B| try checkReplace(B, gpa, oracle.bytes, pattern, input, template, byte_safe);
}

fn checkReplace(comptime B: type, gpa: std.mem.Allocator, oracle: []const u8, pattern: []const u8, input: []const u8, template: []const u8, byte_safe: bool) anyerror!void {
    @disableInstrumentation();
    if (comptime isByteEngine(B)) if (!byte_safe) return;
    const r = try replaceWith(B, gpa, pattern, input, template);
    if (r.tag != .ok) return;
    defer gpa.free(r.bytes);
    if (!std.mem.eql(u8, oracle, r.bytes)) {
        std.debug.print("replace disagreement on /{s}/ ~ \"{s}\" over \"{s}\" ({s}):\n  oracle=\"{s}\"\n  other =\"{s}\"\n  pat.hex={x}\n  in.hex ={x}\n  tmpl.hex={x}\n", .{ pattern, template, input, @typeName(B), oracle, r.bytes, pattern, input, template });
        return error.ReplaceDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Search-offset / anchored differential (findAt)
// ══════════════════════════════════════════════════════════════════════════════

fn findAtOf(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, opts: gex.SearchOptions) anyerror!Outcome {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch |e| switch (e) {
        error.InvalidPattern => return .invalid,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .skip,
    };
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const m = re.findAt(&sc, input, opts);
    return .{ .span = if (m) |mm| .{ mm.start, mm.end } else null };
}

const offset_backends = .{
    gex.backends.backtrack,
    gex.backends.auto,
    gex.backends.bytepike,
    gex.backends.dfa,
    gex.backends.edfa,
};

pub fn searchOffsetAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.gen(smith);
    const pattern = pat.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);

    // `smith.index(n)` ∈ [0, n) — so `index(len+1)` ∈ [0, len] gives every valid
    // start (incl. len). (Smith can't range over `usize`, hence not valueRangeAtMost.)
    const start = smith.index(input.len + 1);
    const anchored = smith.boolWeighted(1, 1);
    const span_end: ?usize = if (smith.boolWeighted(3, 1)) start + smith.index(input.len - start + 1) else null;
    const opts: gex.SearchOptions = .{ .start = start, .anchored = anchored, .span_end = span_end };

    const oracle = try findAtOf(gex.backends.pikevm, gpa, pattern, input, opts);
    if (oracle == .skip or oracle == .invalid) return;

    // Oracle self-invariants: anchored ⇒ match starts exactly at `start`; unanchored
    // ⇒ at/after `start`; and no match may end past `span_end`.
    if (oracle.span) |s| {
        if (anchored and s[0] != start) {
            std.debug.print("anchored findAt didn't start at {d} on /{s}/: got {any}\n", .{ start, pattern, s });
            return error.AnchoredStartWrong;
        }
        if (!anchored and s[0] < start) {
            std.debug.print("findAt(start={d}) matched before start on /{s}/: got {any}\n", .{ start, pattern, s });
            return error.OffsetStartWrong;
        }
        if (span_end) |e| if (s[1] > e) {
            std.debug.print("findAt(span_end={d}) ended past bound on /{s}/: got {any}\n", .{ e, pattern, s });
            return error.SpanEndViolated;
        };
    }

    const byte_safe = byteEnginesSafe(gpa, pattern, input);
    inline for (offset_backends) |B| try checkOffset(B, gpa, oracle, pattern, input, opts, byte_safe);
}

fn checkOffset(comptime B: type, gpa: std.mem.Allocator, oracle: Outcome, pattern: []const u8, input: []const u8, opts: gex.SearchOptions, byte_safe: bool) anyerror!void {
    @disableInstrumentation();
    if (comptime isByteEngine(B)) if (!byte_safe) return;
    const r = try findAtOf(B, gpa, pattern, input, opts);
    if (r == .skip or r == .invalid) return;
    if (!spanEq(oracle.span, r.span)) {
        std.debug.print("findAt disagreement on /{s}/ over \"{s}\" (start={d} anchored={} span_end={?d}) ({s}): oracle={?any} other={?any}\n  pat.hex={x}\n  in.hex ={x}\n", .{ pattern, input, opts.start, opts.anchored, opts.span_end, @typeName(B), oracle.span, r.span, pattern, input });
        return error.OffsetDisagreement;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Strategy-tier results-invariance (a contract)
// ══════════════════════════════════════════════════════════════════════════════

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

pub fn strategyInvariant(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pat = ps.gen(smith);
    const pattern = pat.slice();
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);

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
// `\X` (grapheme) — backtrack-only, so no differential partner: just no-crash.
// ══════════════════════════════════════════════════════════════════════════════

pub fn graphemeNoCrash(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pbuf: [40]u8 = undefined;
    const pn = @min(smith.slice(&pbuf), pbuf.len - 3);
    var pat: [43]u8 = undefined;
    @memcpy(pat[0..3], "\\X+");
    @memcpy(pat[3 .. 3 + pn], pbuf[0..pn]);
    var ibuf: [max_input_len]u8 = undefined;
    const input = ibuf[0..ps.unicodeInput(smith, &ibuf)];

    var diag: gex.Diagnostic = .{};
    var re = gex.compileRuntimeWith(gex.backends.backtrack, gpa, pat[0 .. 3 + pn], &diag, .{}) catch return;
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    _ = re.find(&sc, input); // must not crash / leak
}

// ══════════════════════════════════════════════════════════════════════════════
// Seed corpora — patterns that hit interesting lexer/HIR/backend states. In replay
// mode each is fed through `Smith` (little-endian byte reader), so they double as
// deterministic smoke inputs for `zig build test`.
// ══════════════════════════════════════════════════════════════════════════════

pub const seed_corpus = [_][]const u8{
    "abc",            "a|b|c",        "(a(b)c)*",       "[a-c]{2,4}",
    "\\d+\\w*\\s?",   "(?:ab)+",      "(?i:ABC)",       "^a.c$",
    "a{0,6}b{2}",     "\\b\\w+\\b",   "(?<name>a)b\\1", "(?i)aB(?-i)c",
    "[^a-c\\d]+",     "\\x61\\u{62}", "(a|)*b",         "(?P<x>.)+",
};

pub const unicode_seed_corpus = [_][]const u8{
    "\\p{L}+",                   "\\w+",
    "(?i:stra\xC3\x9fe)",        "[\xCE\xB1-\xCF\x89]+",
    "\xE6\x97\xA5+",             "\\p{Greek}",
    "a\\p{Nd}*?b",              ".",
    "\\P{L}",                    "\\x{1f600}",
    "(?i:\xCE\xA9)",             "[a-z\\p{Cyrillic}]+",
};

pub const anchor_seed_corpus = [_][]const u8{
    "^a$",      "(?m:^a$)",   "\\bword\\b", "a\\z",
    "\\Aa",     "(?:|a)+",    "(a|)*",      "^$",
    "(?m:$)\n", "\\b(?:a|)",  "(?m)^a",     "a$|b",
};
