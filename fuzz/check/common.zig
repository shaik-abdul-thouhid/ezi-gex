//! Shared fuzz-check plumbing: outcomes, backend lists, the byte-engine ASCII-`\b` gate,
//! compile-option variants, per-check × per-backend comparison accounting (read by
//! `fuzz/health.zig`), and the replayable `Case` every failing check prints as one
//! `FUZZ-CASE …` line (read back by `zig build fuzz-min`).

const std = @import("std");
const gex = @import("ezi_gex");
const testing = std.testing;

// ══════════════════════════════════════════════════════════════════════════════
// Outcomes
// ══════════════════════════════════════════════════════════════════════════════

/// Per-backend match outcome.
pub const Outcome = union(enum) {
    /// Scanner/HIR rejected the pattern (deterministic — same parse for every backend).
    invalid,
    /// The backend declined this pattern (Unsupported) or a resource ceiling tripped.
    skip,
    /// Matched span, or `null` for no match.
    span: ?[2]usize,
};

pub fn spanEq(a: ?[2]usize, b: ?[2]usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?[0] == b.?[0] and a.?[1] == b.?[1];
}

// ══════════════════════════════════════════════════════════════════════════════
// Backends
// ══════════════════════════════════════════════════════════════════════════════

pub const all_backends = .{
    gex.backends.pikevm,  gex.backends.backtrack, gex.backends.auto,    gex.backends.bytepike,
    gex.backends.dfa,     gex.backends.edfa,      gex.backends.onepass, gex.backends.literal,
};
pub const n_backends = 8;
pub const backend_names = [n_backends][]const u8{ "pikevm", "backtrack", "auto", "bytepike", "dfa", "edfa", "onepass", "literal" };

pub fn backendIndex(comptime B: type) usize {
    inline for (all_backends, 0..) |X, i| {
        if (X == B) return i;
    }
    @compileError("backendIndex: unknown backend " ++ @typeName(B));
}

/// The backends compared against the Pike VM for plain `find`.
pub const span_backends = .{
    gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike, gex.backends.dfa,
    gex.backends.edfa,      gex.backends.onepass, gex.backends.literal,
};
pub const capture_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.onepass, gex.backends.bytepike };
pub const iter_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike, gex.backends.dfa, gex.backends.edfa };
pub const replace_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike };
pub const offset_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike, gex.backends.dfa, gex.backends.edfa };

// ── Byte-engine ASCII-`\b` contract (mirrors conformance.byteEngineCanRunCase) ──
// `bytepike`/`dfa`/`edfa` evaluate `\b`/`\B` as ASCII word boundaries — exact on ASCII
// input; `auto` routes non-ASCII `\b` to the code-point engines. So a pinned byte engine
// is only contracted on ASCII input for a `\b` pattern, and the checks skip it otherwise.

pub fn isByteEngine(comptime B: type) bool {
    return B == gex.backends.bytepike or B == gex.backends.dfa or B == gex.backends.edfa;
}

pub fn isAsciiStr(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

/// True if `pattern` carries a `\b`/`\B` (via the HIR analysis flag). A parse/HIR
/// failure ⇒ false (then every backend agrees `.invalid` anyway).
pub fn patternHasWordBoundary(gpa: std.mem.Allocator, pattern: []const u8) bool {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = gex.buildHir(gpa, ast, .{}) catch return false;
    defer gex.freeHir(gpa, h);
    return h.analysis.has_word_boundary;
}

pub fn byteEnginesSafe(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) bool {
    @disableInstrumentation();
    if (isAsciiStr(input)) return true;
    return !patternHasWordBoundary(gpa, pattern);
}

// ══════════════════════════════════════════════════════════════════════════════
// Compile-option variants
// ══════════════════════════════════════════════════════════════════════════════

/// `Options` is a comptime parameter in ezi_gex, so a case carries an INDEX into this
/// table and `compileVariant` dispatches with `inline` prongs (one instantiation each).
/// Keep in sync with `gen/tree.zig`'s `opt_sem` (a comptime assertion in tree.zig checks).
pub const opt_variants = [_]gex.Options{
    .{}, // 0: defaults
    .{ .unicode = false }, // 1: ASCII \d \w \s
    .{ .case_fold = .none }, // 2: (?i) ignored
    .{ .case_insensitive = true }, // 3: i seeded from Options
    .{ .multiline = true }, // 4: m seeded from Options
    .{ .dot_matches_newline = true }, // 5: s seeded from Options
};

pub fn compileVariant(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, diag: *gex.Diagnostic, opt: u8) anyerror!gex.Compiled(B) {
    return switch (opt) {
        inline 0...opt_variants.len - 1 => |i| gex.compileRuntimeWith(B, gpa, pattern, diag, opt_variants[i]),
        else => error.BadOptionVariant,
    };
}

const tree = @import("../gen/tree.zig");
comptime {
    std.debug.assert(opt_variants.len == tree.opt_sem.len);
    for (opt_variants, tree.opt_sem) |o, sm| {
        std.debug.assert(o.unicode == sm.unicode);
        std.debug.assert((o.case_fold != .none) == sm.fold);
        std.debug.assert(o.case_insensitive == sm.base.i and o.multiline == sm.base.m and o.dot_matches_newline == sm.base.s);
    }
}

const print = @import("../gen/print.zig");
const pattern_gen = @import("../gen/pattern.zig");
const input_gen = @import("../gen/input.zig");
const witness = @import("../gen/witness.zig");
const uni = @import("../ref/uni.zig");
const Smith = std.testing.Smith;
const replay = @import("../gen/replay.zig");

pub const NONE = std.math.maxInt(usize);

pub fn Built(comptime B: type) type {
    return union(enum) { ok: gex.Compiled(B), invalid, skip };
}

/// Compile under option variant `opt`: InvalidPattern → `.invalid`; Unsupported /
/// PatternTooComplex / any routing decline → `.skip`; OOM propagates.
pub fn build(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, opt: u8) error{OutOfMemory}!Built(B) {
    var diag: gex.Diagnostic = .{};
    const re = compileVariant(B, gpa, pattern, &diag, opt) catch |e| return switch (e) {
        error.InvalidPattern => .invalid,
        error.OutOfMemory => error.OutOfMemory,
        else => .skip,
    };
    return .{ .ok = re };
}

/// `build` with an explicit comptime `Options` (strategy-tier variants).
pub fn buildWith(comptime B: type, comptime opts: gex.Options, gpa: std.mem.Allocator, pattern: []const u8) error{OutOfMemory}!Built(B) {
    var diag: gex.Diagnostic = .{};
    const re = gex.compileRuntimeWith(B, gpa, pattern, &diag, opts) catch |e| return switch (e) {
        error.InvalidPattern => .invalid,
        error.OutOfMemory => error.OutOfMemory,
        else => .skip,
    };
    return .{ .ok = re };
}

pub fn slotsEq(a: []const ?usize, b: []const ?usize) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if ((x == null) != (y == null)) return false;
        if (x != null and x.? != y.?) return false;
    }
    return true;
}

/// A flat, comparable record of what an engine returned.
pub const Summary = struct {
    v: [640]usize = undefined,
    n: usize = 0,

    pub fn push(s: *Summary, x: usize) void {
        if (s.n < s.v.len) {
            s.v[s.n] = x;
            s.n += 1;
        }
    }
    pub fn pushMatch(s: *Summary, m: ?gex.Match) void {
        s.push(if (m) |x| x.start else NONE);
        s.push(if (m) |x| x.end else NONE);
    }
    pub fn eql(a: *const Summary, b: *const Summary) bool {
        return a.n == b.n and std.mem.eql(usize, a.v[0..a.n], b.v[0..b.n]);
    }
};

/// find, isMatch, captures (capture backends), and the first 32 findAll spans.
pub fn summarize(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), input: []const u8) !Summary {
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var s: Summary = .{};
    s.pushMatch(re.find(&sc, input));
    s.push(@intFromBool(re.isMatch(&sc, input)));
    if (comptime B.caps.captures) {
        var slots: [96]?usize = undefined;
        const n = re.slotCount();
        if (n <= slots.len) {
            if (re.captures(&sc, slots[0..n], input)) |_| {
                for (slots[0..n]) |x| s.push(x orelse NONE);
            } else s.push(NONE);
        }
    }
    var it = re.findAll(&sc, input);
    var k: usize = 0;
    while (it.next()) |m| : (k += 1) {
        if (k == 32) break;
        s.pushMatch(m);
    }
    return s;
}

/// The option variant to PRINT and COMPILE a tree with: any variant whose only difference
/// from the tree's is the Options-seeded flags (the printer re-establishes them inline).
pub fn printOpt(smith: *Smith, tree_opt: u8) u8 {
    @disableInstrumentation();
    const flag_only = [_]u8{ 0, 3, 4, 5 };
    if (std.mem.findScalar(u8, &flag_only, tree_opt) == null) return tree_opt;
    return flag_only[smith.index(flag_only.len)];
}

pub const PatBuf = struct {
    printed: print.Printed = .{},
    smithy: pattern_gen.PatternSmith = .{},
    t: tree.Tree = undefined,
};
pub const Picked = struct { pattern: []const u8, opt: u8, tree: ?*const tree.Tree };

/// 1:1 a string-level `pattern.gen` pattern (opt 0) or a randomly printed tree.
pub fn pickPattern(smith: *Smith, buf: *PatBuf) ?Picked {
    @disableInstrumentation();
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
        buf.smithy = pattern_gen.gen(smith);
        return .{ .pattern = buf.smithy.slice(), .opt = 0, .tree = null };
    }
    buf.t = tree.generate(smith, tree.pickOpt(smith));
    const popt = printOpt(smith, buf.t.opt);
    buf.printed = print.variant(&buf.t, popt, smith.value(u64)) orelse return null;
    return .{ .pattern = buf.printed.slice(), .opt = popt, .tree = &buf.t };
}

/// Half the time a small generated input; half the time noise + a witness of `t` + noise,
/// so the tree actually matches somewhere.
pub fn inputWithWitness(gpa: std.mem.Allocator, smith: *Smith, t: *const tree.Tree, buf: []u8) ![]const u8 {
    @disableInstrumentation();
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) return input_gen.pickSmall(smith, buf);
    var w = (try witness.sample(gpa, t, smith.value(u64))) orelse return input_gen.pickSmall(smith, buf);
    const pre = input_gen.pickSmall(smith, buf[0..@min(buf.len, 12)]);
    var len = pre.len;
    const ws = w.slice();
    if (len + ws.len > buf.len) return buf[0..len];
    @memcpy(buf[len..][0..ws.len], ws);
    len += ws.len;
    var tail: [12]u8 = undefined;
    const post = input_gen.pickSmall(smith, &tail);
    const n = @min(post.len, buf.len - len);
    @memcpy(buf[len..][0..n], post[0..n]);
    return buf[0 .. len + n];
}

pub fn isValidUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const d = uni.decode(s, i);
        if (!d.valid) return false;
        i += d.len;
    }
    return true;
}

/// Bytes to the next scalar boundary from `i`: the decoded length, or 1 over a malformed
/// byte (the reference's reading of "resync one byte").
pub fn scalarLen(input: []const u8, i: usize) usize {
    if (i >= input.len) return 1;
    return uni.decode(input, i).len;
}

/// Seed corpora for the fuzz groups: replay-word streams (see gen/replay.zig) so each
/// finite `zig build test` replay drives the generators through non-trivial cases.
pub const generic_corpus = replay.corpus(10, 256, 0xC0FFEE);

// ══════════════════════════════════════════════════════════════════════════════
// Accounting (read by fuzz/health.zig)
// ══════════════════════════════════════════════════════════════════════════════

pub const CheckId = enum(u8) {
    span, anchors, unicode, captures, iter, replace, offset, strategy, scanner, grapheme,
    reference, metamorphic, invariants, state, large, literals, api, oom, comptime_parity,
    complexity, utf8class, chaos, compile_bomb,
};
pub const n_checks = @typeInfo(CheckId).@"enum".field_names.len;
pub const max_gates = 32;

pub const Stats = struct {
    runs: [n_checks]u32 = std.mem.zeroes([n_checks]u32),
    valid: [n_checks]u32 = std.mem.zeroes([n_checks]u32),
    compared: [n_checks][n_backends]u32 = std.mem.zeroes([n_checks][n_backends]u32),
    skipped: [n_checks][n_backends]u32 = std.mem.zeroes([n_checks][n_backends]u32),
    gated: [max_gates]u32 = std.mem.zeroes([max_gates]u32),

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

/// Process-global counters. Single-threaded use only (the fuzz bodies and health tests).
pub var stats: Stats = .{};

pub fn noteRun(c: CheckId, valid: bool) void {
    stats.runs[@backingInt(c)] += 1;
    if (valid) stats.valid[@backingInt(c)] += 1;
}
pub fn noteCompared(c: CheckId, comptime B: type) void {
    stats.compared[@backingInt(c)][backendIndex(B)] += 1;
}
pub fn noteSkipped(c: CheckId, comptime B: type) void {
    stats.skipped[@backingInt(c)][backendIndex(B)] += 1;
}
/// compared / valid for (check, backend); 0 when the check saw no valid case.
pub fn comparedFraction(c: CheckId, bi: usize) f64 {
    const v = stats.valid[@backingInt(c)];
    if (v == 0) return 0;
    return @as(f64, @floatFromInt(stats.compared[@backingInt(c)][bi])) / @as(f64, @floatFromInt(v));
}

// ══════════════════════════════════════════════════════════════════════════════
// Replayable cases
// ══════════════════════════════════════════════════════════════════════════════

/// Suppresses `Case.report` output (health measurement, `fuzz-min` shrinking).
pub var quiet: bool = false;

/// Everything needed to replay one check deterministically. Slices are borrowed,
/// except for a `Case` returned by `parse` (free it with `deinitOwned`).
pub const Case = struct {
    check: CheckId,
    pattern: []const u8 = "",
    input: []const u8 = "",
    /// Serialized `gen/tree.zig` `Tree` (tree-driven checks), else empty.
    tree: []const u8 = "",
    template: []const u8 = "",
    /// Index into `opt_variants`.
    opt: u8 = 0,
    start: usize = 0,
    anchored: bool = false,
    span_end: ?usize = null,
    /// Check-specific PRNG seed (printer variant, op script, witness, …).
    seed: u64 = 0,
    /// Check-specific count (splitN/replaceN n, complexity n, comptime table index, …).
    n: usize = 0,
    /// Second option variant / seed (the metamorphic check's second printing).
    opt2: u8 = 0,
    seed2: u64 = 0,

    pub fn searchOptions(self: *const Case) gex.SearchOptions {
        return .{ .start = self.start, .anchored = self.anchored, .span_end = self.span_end };
    }

    const line_fmt = "FUZZ-CASE check={s} opt={d} start={d} anchored={d} span_end={?d} seed={d} n={d} opt2={d} seed2={d} pat={x} in={x} tmpl={x} tree={x}";
    const LineArgs = struct { []const u8, u8, usize, u1, ?usize, u64, usize, u8, u64, []const u8, []const u8, []const u8, []const u8 };

    fn lineArgs(self: *const Case) LineArgs {
        return .{
            @tagName(self.check), self.opt,      self.start, @intFromBool(self.anchored), self.span_end,
            self.seed,            self.n,        self.opt2,  self.seed2,                  self.pattern,
            self.input,           self.template, self.tree,
        };
    }

    /// One machine-readable line (no trailing newline).
    pub fn format(self: *const Case, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(line_fmt, self.lineArgs());
    }

    /// Print `why` (formatted) plus the replay line to stderr, unless `quiet`.
    pub fn report(self: *const Case, comptime why: []const u8, args: anytype) void {
        if (quiet) return;
        std.debug.print("\n" ++ why ++ "\n  pattern: /{s}/\n  input:   \"{s}\"\n", args ++ .{ self.pattern, self.input });
        std.debug.print(line_fmt ++ "\n", self.lineArgs());
    }

    /// Parse a `FUZZ-CASE …` line (as printed by `format`). The returned case OWNS its
    /// byte slices — release with `deinitOwned`.
    pub fn parse(gpa: std.mem.Allocator, line_in: []const u8) !Case {
        const line = std.mem.trim(u8, line_in, " \r\n\t");
        const at = std.mem.find(u8, line, "FUZZ-CASE ") orelse return error.BadCaseLine;
        var c: Case = .{ .check = .span };
        var seen: u16 = 0;
        var it = std.mem.tokenizeScalar(u8, line[at + "FUZZ-CASE ".len ..], ' ');
        errdefer c.deinitOwned(gpa);
        while (it.next()) |kv| {
            const eq = std.mem.findScalar(u8, kv, '=') orelse return error.BadCaseLine;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "check")) {
                c.check = std.meta.stringToEnum(CheckId, v) orelse return error.BadCaseLine;
                seen |= 1 << 0;
            } else if (std.mem.eql(u8, k, "opt")) {
                c.opt = try std.fmt.parseInt(u8, v, 10);
                seen |= 1 << 1;
            } else if (std.mem.eql(u8, k, "start")) {
                c.start = try std.fmt.parseInt(usize, v, 10);
                seen |= 1 << 2;
            } else if (std.mem.eql(u8, k, "anchored")) {
                c.anchored = !std.mem.eql(u8, v, "0");
                seen |= 1 << 3;
            } else if (std.mem.eql(u8, k, "span_end")) {
                c.span_end = if (std.mem.eql(u8, v, "null")) null else try std.fmt.parseInt(usize, v, 10);
                seen |= 1 << 4;
            } else if (std.mem.eql(u8, k, "seed")) {
                c.seed = try std.fmt.parseInt(u64, v, 10);
                seen |= 1 << 5;
            } else if (std.mem.eql(u8, k, "n")) {
                c.n = try std.fmt.parseInt(usize, v, 10);
                seen |= 1 << 6;
            } else if (std.mem.eql(u8, k, "opt2")) {
                c.opt2 = try std.fmt.parseInt(u8, v, 10);
                seen |= 1 << 7;
            } else if (std.mem.eql(u8, k, "seed2")) {
                c.seed2 = try std.fmt.parseInt(u64, v, 10);
                seen |= 1 << 8;
            } else if (std.mem.eql(u8, k, "pat")) {
                c.pattern = try hexDup(gpa, v);
                seen |= 1 << 9;
            } else if (std.mem.eql(u8, k, "in")) {
                c.input = try hexDup(gpa, v);
                seen |= 1 << 10;
            } else if (std.mem.eql(u8, k, "tmpl")) {
                c.template = try hexDup(gpa, v);
                seen |= 1 << 11;
            } else if (std.mem.eql(u8, k, "tree")) {
                c.tree = try hexDup(gpa, v);
                seen |= 1 << 12;
            } else return error.BadCaseLine;
        }
        if (seen != (1 << 13) - 1) return error.BadCaseLine; // every field must be present
        return c;
    }

    pub fn deinitOwned(self: *const Case, gpa: std.mem.Allocator) void {
        gpa.free(self.pattern);
        gpa.free(self.input);
        gpa.free(self.template);
        gpa.free(self.tree);
    }
};

fn hexDup(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.BadCaseLine;
    const out = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return error.BadCaseLine;
    return out;
}


test "Case report/parse round-trips byte-exactly (incl. 12 KiB input and empty fields)" {
    const gpa = testing.allocator;
    var big: [12 * 1024]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    const cases = [_]Case{
        .{ .check = .span, .pattern = "a|b", .input = "xab", .opt = 3, .start = 1, .anchored = true, .span_end = 3, .seed = 42, .n = 7, .template = "$1-${g}", .opt2 = 5, .seed2 = 99 },
        .{ .check = .large, .pattern = "", .input = &big },
        .{ .check = .reference, .pattern = "\xff\x00", .input = "", .tree = "\x01\x02\x03", .span_end = null },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try c.format(&aw.writer);
        const back = try Case.parse(gpa, aw.written());
        defer back.deinitOwned(gpa);
        try testing.expectEqual(c.check, back.check);
        try testing.expectEqualSlices(u8, c.pattern, back.pattern);
        try testing.expectEqualSlices(u8, c.input, back.input);
        try testing.expectEqualSlices(u8, c.tree, back.tree);
        try testing.expectEqualSlices(u8, c.template, back.template);
        try testing.expectEqual(c.opt, back.opt);
        try testing.expectEqual(c.start, back.start);
        try testing.expectEqual(c.anchored, back.anchored);
        try testing.expectEqual(c.span_end, back.span_end);
        try testing.expectEqual(c.seed, back.seed);
        try testing.expectEqual(c.n, back.n);
        try testing.expectEqual(c.opt2, back.opt2);
        try testing.expectEqual(c.seed2, back.seed2);
    }
}

test "Case.parse rejects a truncated line" {
    try testing.expectError(error.BadCaseLine, Case.parse(testing.allocator, "FUZZ-CASE check=span opt=0 pat=61"));
    try testing.expectError(error.BadCaseLine, Case.parse(testing.allocator, "nonsense"));
}

test "compileVariant honours each option variant" {
    const gpa = testing.allocator;
    const P = gex.backends.pikevm;
    const Probe = struct { pat: []const u8, in: []const u8, opt: u8, want: bool };
    const probes = [_]Probe{
        .{ .pat = "a", .in = "A", .opt = 0, .want = false },
        .{ .pat = "a", .in = "A", .opt = 3, .want = true }, // case_insensitive via Options
        .{ .pat = "(?i)a", .in = "A", .opt = 2, .want = false }, // case_fold = .none ignores (?i)
        .{ .pat = "\\d", .in = "\u{0663}", .opt = 0, .want = true }, // Unicode \d
        .{ .pat = "\\d", .in = "\u{0663}", .opt = 1, .want = false }, // ASCII \d
        .{ .pat = "^b", .in = "a\nb", .opt = 4, .want = true }, // multiline via Options
        .{ .pat = "a.b", .in = "a\nb", .opt = 5, .want = true }, // dot_matches_newline via Options
    };
    for (probes) |p| {
        var diag: gex.Diagnostic = .{};
        var re = try compileVariant(P, gpa, p.pat, &diag, p.opt);
        defer re.deinit();
        var sc = try re.initScratch(gpa);
        defer sc.deinit(gpa);
        try testing.expectEqual(p.want, re.isMatch(&sc, p.in));
    }
}

test "stats count compared and skipped per check and backend" {
    stats.reset();
    noteRun(.span, true);
    noteCompared(.span, gex.backends.dfa);
    noteSkipped(.span, gex.backends.literal);
    try testing.expectEqual(@as(u32, 1), stats.compared[@backingInt(CheckId.span)][backendIndex(gex.backends.dfa)]);
    try testing.expectEqual(@as(u32, 1), stats.skipped[@backingInt(CheckId.span)][backendIndex(gex.backends.literal)]);
    try testing.expectEqual(@as(f64, 1.0), comparedFraction(.span, backendIndex(gex.backends.dfa)));
    stats.reset();
}

test "summarize + build classify patterns" {
    const gpa = testing.allocator;
    const bad = try build(gex.backends.pikevm, gpa, "(", 0);
    try testing.expect(bad == .invalid);
    var good = try build(gex.backends.pikevm, gpa, "(a)b", 0);
    defer if (good == .ok) good.ok.deinit();
    const s = try summarize(gex.backends.pikevm, gpa, &good.ok, "xab ab");
    // find [1,3], isMatch, captures (0/1 = 1,3; group 1 = 1,2), findAll [1,3] [4,6]
    try testing.expectEqualSlices(usize, &.{ 1, 3, 1, 1, 3, 1, 2, 1, 3, 4, 6 }, s.v[0..s.n]);
}

test "pickPattern mostly yields parseable patterns" {
    var prng = std.Random.DefaultPrng.init(53);
    var sb: [4096]u8 = undefined;
    var pb: PatBuf = .{};
    var ok: usize = 0;
    for (0..500) |_| {
        var s = replay.smith(&prng, &sb);
        const p = pickPattern(&s, &pb) orelse continue;
        var diag: gex.Diagnostic = .{};
        if (gex.parse(testing.allocator, p.pattern, &diag)) |a| {
            ok += 1;
            a.deinit(testing.allocator);
        } else |_| {}
    }
    try testing.expect(ok >= 400);
}
