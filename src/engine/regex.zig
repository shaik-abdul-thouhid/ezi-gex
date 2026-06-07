//! The front door: turn a pattern into a ready-to-use, backend-parametric regex.
//!
//! Two entry points, both returning the same `Compiled(Backend)` setup so callers
//! write the same code either way:
//!   * `compileRuntime(allocator, pattern, *Diagnostic)` — heap `Program`; on a
//!     bad pattern returns `error.InvalidPattern` and fills the diagnostic (no
//!     crash). Free with `re.deinit()`.
//!   * `compileComptime(pattern)` — `Program` baked into `ro_data`; a bad pattern
//!     is a `@compileError`. No allocator, no deinit.
//!
//! The compiled value exposes the user-facing API — `isMatch`, `find`, `captures`,
//! `findAll`, `capturesAll`, `count`, `split`, `replaceAll` — all delegating to the
//! backend-agnostic `Engine`. Per the contract, the **caller owns the `Scratch`**
//! and creates it at the call site (`var s = try re.newScratch(alloc);`); the regex
//! methods take `&s`. Default backend is the Pike VM (the `auto` dispatcher will
//! slot in here later without changing this API).

const std = @import("std");

const core = @import("../core/root.zig");
const hir = core.hir;
const parser = core.compile;
const backend = @import("backend.zig");
const auto = @import("backends/auto.zig");

pub const Diagnostic = parser.Diagnostic;
pub const Match = backend.Match;
pub const Captures = backend.Captures;

/// The default backend used by `compileRuntime`/`compileComptime`: the `auto`
/// dispatcher, which picks the literal / backtrack / Pike VM strategy from the
/// pattern's analysis and the input. Power users pass a specific backend to the
/// `*With` constructors instead.
pub const default_backend = auto;

/// Errors from the full compile pipeline (parse → HIR → program).
pub const Error = error{
    /// The pattern is malformed; see the `Diagnostic` for code + span.
    InvalidPattern,
    /// The pattern exceeds an internal size bound.
    PatternTooComplex,
    /// The chosen backend cannot handle a construct in the pattern (e.g. `\X`).
    Unsupported,
    OutOfMemory,
};

/// Pipeline settings, comptime-known on both paths (so the HIR shape and backend
/// can specialize). Every field has a default; pass `.{}` for all defaults or set
/// only what you need. These flow into the HIR builder (and, later, the backend).
pub const Options = struct {
    /// How `(?i)` case-insensitivity is realized (`.none` / `.simple` / `.full`).
    case_fold: hir.CaseFold = .simple,

    /// Project these front-door options onto the HIR builder's options.
    fn toHir(self: Options) hir.Options {
        return .{ .case_fold = self.case_fold };
    }
};

/// A compiled regex over backend `B`: an immutable `Program` + capture `Meta`.
/// Returned by `compileRuntime`/`compileComptime`. Thread-safe to share; each
/// thread uses its own `Scratch`.
pub fn Compiled(comptime B: type) type {
    const Eng = backend.Engine(B);
    return struct {
        const Self = @This();

        /// The per-search state type — initialize one at the call site.
        pub const Scratch = B.Scratch;
        pub const Backend = B;

        program: B.Program,
        meta: backend.Meta,
        /// Non-null for `compileRuntime` (used by `deinit`); null for comptime.
        allocator: ?std.mem.Allocator,

        /// Release heap memory (no-op for a comptime-compiled regex).
        pub fn deinit(self: *Self) void {
            const a = self.allocator orelse return;
            if (@hasDecl(B, "freeProgram")) B.freeProgram(a, &self.program);
            for (self.meta.group_names) |gn| {
                if (gn) |name| a.free(name);
            }
            if (self.meta.group_names.len != 0) a.free(self.meta.group_names);
        }

        // ── scratch (caller-owned) ────────────────────────────────────────────────

        /// Allocate a `Scratch` sized for this program. Caller owns it; reuse it
        /// across searches and `deinit` it when done. For a stateless backend whose
        /// `Scratch` needs no construction, returns a default-initialized value.
        pub fn newScratch(self: *const Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Scratch {
            if (comptime @hasDecl(B.Scratch, "init")) return B.Scratch.init(allocator, &self.program);
            return Scratch{}; // stateless backend with no `init`
        }

        /// Construct a `Scratch` over a caller-provided fixed buffer — no allocator.
        /// The buffer element type is the backend's (`Buf` below); a too-small
        /// buffer yields `error.BufferTooSmall` (the "with limits" path). Available
        /// only for backends that opt into the buffer convention (`initBuffer`).
        pub fn newScratchBuffer(self: *const Self, buf: []Buf) backend.ScratchError!Scratch {
            if (comptime !@hasDecl(B.Scratch, "initBuffer"))
                @compileError("backend `" ++ @typeName(B) ++ "` does not support buffer-backed Scratch");
            return B.Scratch.initBuffer(buf, &self.program);
        }

        /// Buffer element type for `newScratchBuffer` / comptime matching, or `void`
        /// if the backend doesn't opt into the buffer convention.
        pub const Buf = if (@hasDecl(B.Scratch, "Buf")) B.Scratch.Buf else void;

        /// Number of `Buf` words a fixed buffer must hold for this program.
        pub fn bufferLen(self: *const Self) usize {
            if (comptime !@hasDecl(B.Scratch, "bufferLen"))
                @compileError("backend `" ++ @typeName(B) ++ "` does not support buffer-backed Scratch");
            return B.Scratch.bufferLen(&self.program);
        }

        /// How many `?usize` capture slots `captures`/`capturesAll`/`replaceAll`
        /// need: `2 * (captureCount + 1)`. Pre-allocate exactly this many.
        pub fn slotCount(self: Self) usize {
            return self.meta.slotLen();
        }
        /// Number of capturing groups (excluding the whole match).
        pub fn captureCount(self: Self) usize {
            return self.meta.capture_count;
        }

        // ── the user-facing API ──────────────────────────────────────────────────

        pub fn isMatch(self: *const Self, scratch: *Scratch, input: []const u8) bool {
            return Eng.isMatch(&self.program, scratch, input, .{});
        }
        pub fn isMatchAt(self: *const Self, scratch: *Scratch, input: []const u8, opts: backend.SearchOptions) bool {
            return Eng.isMatch(&self.program, scratch, input, opts);
        }
        pub fn find(self: *const Self, scratch: *Scratch, input: []const u8) ?Match {
            return Eng.find(&self.program, scratch, input, .{});
        }
        pub fn findAt(self: *const Self, scratch: *Scratch, input: []const u8, opts: backend.SearchOptions) ?Match {
            return Eng.find(&self.program, scratch, input, opts);
        }
        /// Capture the first match into `slots` (length `slotCount()`).
        pub fn captures(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8) ?Captures {
            return Eng.captures(&self.program, scratch, input, slots, self.meta, .{});
        }
        pub fn findAll(self: *const Self, scratch: *Scratch, input: []const u8) Eng.MatchIterator {
            return Eng.findAll(&self.program, scratch, input, .{});
        }
        pub fn capturesAll(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8) Eng.CaptureIterator {
            return Eng.capturesAll(&self.program, scratch, input, slots, self.meta, .{});
        }
        pub fn count(self: *const Self, scratch: *Scratch, input: []const u8) usize {
            return Eng.count(&self.program, scratch, input, .{});
        }
        pub fn split(self: *const Self, scratch: *Scratch, input: []const u8) Eng.SplitIterator {
            return Eng.split(&self.program, scratch, input, .{});
        }
        pub fn replaceAll(
            self: *const Self,
            scratch: *Scratch,
            input: []const u8,
            template: []const u8,
            slots: []?usize,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            return Eng.replaceAll(&self.program, scratch, input, template, slots, self.meta, writer);
        }

        // ── comptime matching (no allocator, no runtime cost) ─────────────────────
        //
        // When the whole regex is comptime-known (`compileComptime`), these run the
        // match at comptime over a buffer `Scratch` declared inline. They need the
        // backend's buffer convention (`Buf`/`bufferLen`/`initBuffer`) — the
        // built-ins all provide it.

        fn requireBufferConvention() void {
            if (!@hasDecl(B.Scratch, "initBuffer") or !@hasDecl(B.Scratch, "bufferLen") or !@hasDecl(B.Scratch, "Buf"))
                @compileError("comptime matching requires the backend's Scratch to expose Buf/bufferLen/initBuffer");
        }

        pub fn isMatchComptime(comptime self: Self, comptime input: []const u8) bool {
            return self.isMatchAtComptime(input, .{});
        }
        pub fn isMatchAtComptime(comptime self: Self, comptime input: []const u8, comptime opts: backend.SearchOptions) bool {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.isMatch(&self.program, &sc, input, opts);
            }
        }
        pub fn findComptime(comptime self: Self, comptime input: []const u8) ?Match {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.find(&self.program, &sc, input, .{});
            }
        }
        pub fn countComptime(comptime self: Self, comptime input: []const u8) usize {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.count(&self.program, &sc, input, .{});
            }
        }
    };
}

/// A roomy comptime eval-branch ceiling for a match over `input_len` bytes (a
/// guard, not a cost — Zig only spends branches on work actually done).
fn comptimeQuota(input_len: usize) u32 {
    return @intCast(@min(1_000_000 + input_len * 20_000, std.math.maxInt(u32)));
}

// ── constructors ────────────────────────────────────────────────────────────────

/// Runtime: compile `pattern` into a heap-backed regex (default backend). On a
/// malformed pattern, returns `error.InvalidPattern` and writes `diag` — the
/// caller decides how to surface it. Free the result with `re.deinit()`.
pub fn compileRuntime(allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic, comptime opts: Options) Error!Compiled(default_backend) {
    return compileRuntimeWith(default_backend, allocator, pattern, diag, opts);
}

/// Comptime: compile `pattern` into a ro_data regex (default backend). A bad
/// pattern is a compile error. No allocator; `deinit` is a no-op.
pub fn compileComptime(comptime pattern: []const u8, comptime opts: Options) Compiled(default_backend) {
    return compileComptimeWith(default_backend, pattern, opts);
}

/// `compileRuntime` with an explicit backend.
pub fn compileRuntimeWith(comptime B: type, allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic, comptime opts: Options) Error!Compiled(B) {
    const ast = parser.parse(allocator, pattern, diag) catch |e| switch (e) {
        error.InvalidPattern => return error.InvalidPattern,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer ast.deinit(allocator);

    const h = hir.buildAlloc(allocator, ast, opts.toHir()) catch |e| switch (e) {
        error.PatternTooComplex => return error.PatternTooComplex,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer hir.deinitHir(allocator, h);

    var program = try B.buildAlloc(allocator, h, .{});
    errdefer if (@hasDecl(B, "freeProgram")) B.freeProgram(allocator, &program);

    const group_names = try buildGroupNames(allocator, h);
    return .{ .program = program, .meta = .{ .capture_count = h.capture_count, .group_names = group_names }, .allocator = allocator };
}

/// `compileComptime` with an explicit backend.
pub fn compileComptimeWith(comptime B: type, comptime pattern: []const u8, comptime opts: Options) Compiled(B) {
    const ast = comptime parser.compile(pattern); // @compileError on a bad pattern
    const h = comptime switch (hir.buildComptime(ast, opts.toHir())) {
        .ok => |x| x,
        .fail => @compileError("ezi_gex: HIR build failed for pattern \"" ++ pattern ++ "\""),
    };
    const program = comptime B.buildComptime(h, .{});
    const names = comptime comptimeGroupNames(h);
    return .{
        .program = program,
        .meta = .{ .capture_count = h.capture_count, .group_names = names },
        .allocator = null,
    };
}

// ── group-name table (group index → name), built from the HIR ─────────────────────

fn buildGroupNames(allocator: std.mem.Allocator, h: hir.Hir) std.mem.Allocator.Error![]const ?[]const u8 {
    if (h.capture_count == 0) return &.{};
    const arr = try allocator.alloc(?[]const u8, h.capture_count + 1);
    errdefer allocator.free(arr);
    @memset(arr, null);
    var done: usize = 0;
    errdefer for (arr[0..]) |gn| {
        if (gn) |name| allocator.free(name);
    };
    for (h.nodes) |node| {
        if (node.tag == .capture) {
            const c = node.data.capture;
            if (c.name) |ni| {
                arr[c.index] = try allocator.dupe(u8, h.names[ni]); // own it; pattern may not outlive us
                done += 1;
            }
        }
    }
    return arr;
}

fn comptimeGroupNames(comptime h: hir.Hir) []const ?[]const u8 {
    if (h.capture_count == 0) return &.{};
    var arr: [h.capture_count + 1]?[]const u8 = undefined;
    @memset(&arr, null);
    for (h.nodes) |node| {
        if (node.tag == .capture) {
            const c = node.data.capture;
            if (c.name) |ni| arr[c.index] = h.names[ni];
        }
    }
    const final = arr;
    return &final;
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "compileRuntime: full API over a heap-backed regex" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(\\w+)@(\\w+)", &diag, .{});
    defer re.deinit();
    var sc = try re.newScratch(testing.allocator);
    defer sc.deinit(testing.allocator);

    try testing.expect(re.isMatch(&sc, "x a@b y"));
    try testing.expect(!re.isMatch(&sc, "nope"));
    try testing.expectEqualStrings("a@b", re.find(&sc, "x a@b y").?.slice("x a@b y"));

    try testing.expectEqual(@as(usize, 6), re.slotCount()); // 2 * (2 groups + whole match)
    const slots = try testing.allocator.alloc(?usize, re.slotCount());
    defer testing.allocator.free(slots);
    const c = re.captures(&sc, slots, "user@host").?;
    try testing.expectEqualStrings("user", c.groupSlice(1).?);
    try testing.expectEqualStrings("host", c.groupSlice(2).?);
}

test "compileRuntime: invalid pattern returns error + diagnostic, no crash" {
    var diag: Diagnostic = .{};
    const r = compileRuntime(testing.allocator, "a(b", &diag, .{});
    try testing.expectError(error.InvalidPattern, r);
    try testing.expectEqual(core.errors.ErrorCode.unclosed_group, diag.code);
    try testing.expectEqualStrings("(", diag.faultySlice("a(b"));
}

test "compileComptime: program in ro_data, used at runtime" {
    const Re = compileComptime("\\d{3}-\\d{4}", .{});
    var re = Re; // a value; methods take *const Self
    var sc = try re.newScratch(testing.allocator);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "call 555-1234 now"));
    try testing.expectEqualStrings("555-1234", re.find(&sc, "call 555-1234 now").?.slice("call 555-1234 now"));
    // capture slots can be a comptime-sized stack array (capture_count is comptime)
    try testing.expectEqual(@as(usize, 2), re.slotCount());
}

test "compileComptime: named captures resolve" {
    const Re = compileComptime("(?<y>\\d+)-(?<m>\\d+)", .{});
    var re = Re;
    var sc = try re.newScratch(testing.allocator);
    defer sc.deinit(testing.allocator);
    var slots: [6]?usize = undefined;
    const c = re.captures(&sc, &slots, "2026-06").?;
    try testing.expectEqualStrings("2026", c.namedSlice("y").?);
    try testing.expectEqualStrings("06", c.namedSlice("m").?);
}

test "comptime and runtime compile agree" {
    const pat = "[a-z]+\\d*";
    const input = "  abc123  ";
    var diag: Diagnostic = .{};
    var rt = try compileRuntime(testing.allocator, pat, &diag, .{});
    defer rt.deinit();
    var rsc = try rt.newScratch(testing.allocator);
    defer rsc.deinit(testing.allocator);

    var ct = compileComptime(pat, .{});
    var csc = try ct.newScratch(testing.allocator);
    defer csc.deinit(testing.allocator);

    try testing.expectEqualStrings("abc123", rt.find(&rsc, input).?.slice(input));
    try testing.expectEqualStrings("abc123", ct.find(&csc, input).?.slice(input));
}

test "front door: comptime isMatch / find / count (default auto backend)" {
    const Re = comptime compileComptime("\\d+", .{});
    try testing.expect(comptime Re.isMatchComptime("abc123"));
    try testing.expect(!comptime Re.isMatchComptime("abcdef"));
    const m = comptime Re.findComptime("x123y").?;
    try testing.expectEqualStrings("123", m.slice("x123y"));
    try testing.expectEqual(@as(usize, 3), comptime Re.countComptime("a1b22c333"));
}

test "front door: comptime literal route runs at comptime too" {
    const Re = comptime compileComptime("cat|dog", .{});
    try testing.expect(comptime Re.isMatchComptime("a dog here"));
    const m = comptime Re.findComptime("a dog here").?;
    try testing.expectEqualStrings("dog", m.slice("a dog here"));
}

test "front door: runtime buffer scratch needs no allocator for matching" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "[a-z]+\\d+", &diag, .{});
    defer re.deinit();
    var buf: [4096]@TypeOf(re).Buf = undefined; // Buf == the backend's Cell
    var sc = try re.newScratchBuffer(&buf);
    try testing.expectEqualStrings("abc12", re.find(&sc, "??abc12!!").?.slice("??abc12!!"));
    try testing.expect(!re.isMatch(&sc, "ABC"));
}

test "front-door iterators and replace" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try re.newScratch(testing.allocator);
    defer sc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), re.count(&sc, "a1b22c333"));

    var split_re = try compileRuntime(testing.allocator, "\\s+", &diag, .{});
    defer split_re.deinit();
    var ssc = try split_re.newScratch(testing.allocator);
    defer ssc.deinit(testing.allocator);
    var it = split_re.split(&ssc, "the  quick fox");
    try testing.expectEqualStrings("the", it.next().?);
    try testing.expectEqualStrings("quick", it.next().?);
    try testing.expectEqualStrings("fox", it.next().?);
    try testing.expect(it.next() == null);
}

test {
    testing.refAllDecls(@This());
}
