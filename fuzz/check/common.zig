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

// ══════════════════════════════════════════════════════════════════════════════
// Accounting (read by fuzz/health.zig)
// ══════════════════════════════════════════════════════════════════════════════

pub const CheckId = enum(u8) {
    span, anchors, unicode, captures, iter, replace, offset, strategy, scanner, grapheme,
    reference, metamorphic, invariants, state, large, literals, api, oom, comptime_parity,
    complexity, utf8class, chaos,
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
    stats.runs[@intFromEnum(c)] += 1;
    if (valid) stats.valid[@intFromEnum(c)] += 1;
}
pub fn noteCompared(c: CheckId, comptime B: type) void {
    stats.compared[@intFromEnum(c)][backendIndex(B)] += 1;
}
pub fn noteSkipped(c: CheckId, comptime B: type) void {
    stats.skipped[@intFromEnum(c)][backendIndex(B)] += 1;
}
/// compared / valid for (check, backend); 0 when the check saw no valid case.
pub fn comparedFraction(c: CheckId, bi: usize) f64 {
    const v = stats.valid[@intFromEnum(c)];
    if (v == 0) return 0;
    return @as(f64, @floatFromInt(stats.compared[@intFromEnum(c)][bi])) / @as(f64, @floatFromInt(v));
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
        const at = std.mem.indexOf(u8, line, "FUZZ-CASE ") orelse return error.BadCaseLine;
        var c: Case = .{ .check = .span };
        var seen: u16 = 0;
        var it = std.mem.tokenizeScalar(u8, line[at + "FUZZ-CASE ".len ..], ' ');
        errdefer c.deinitOwned(gpa);
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadCaseLine;
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
    try testing.expectEqual(@as(u32, 1), stats.compared[@intFromEnum(CheckId.span)][backendIndex(gex.backends.dfa)]);
    try testing.expectEqual(@as(u32, 1), stats.skipped[@intFromEnum(CheckId.span)][backendIndex(gex.backends.literal)]);
    try testing.expectEqual(@as(f64, 1.0), comparedFraction(.span, backendIndex(gex.backends.dfa)));
    stats.reset();
}
