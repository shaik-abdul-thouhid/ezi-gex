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
//! and creates it at the call site off the `Scratch` type
//! (`var s = try @TypeOf(re).Scratch.init(alloc, &re.program);`); the regex methods
//! take `&s`. The default backend is the `auto` dispatcher (`default_backend`), which
//! picks literal / backtrack / Pike VM from the pattern + input; pass a specific
//! backend to the `*With` constructors to override it.
//!
//! ══════════════════════════════════════════════════════════════════════════════
//! USAGE GUIDE
//! ══════════════════════════════════════════════════════════════════════════════
//!
//! ## Pick an entry point
//!
//!   * `compileRuntime(gpa, pattern, &diag, opts)` — heap-backed; a bad pattern is
//!     `error.InvalidPattern` + a filled `Diagnostic` (never a crash). `re.deinit()`.
//!   * `compileComptime(pattern, opts)` — baked into `ro_data`; a bad pattern is a
//!     `@compileError`. No allocator, no `deinit`.
//!   * `compileRuntimeWith(B, …)` / `compileComptimeWith(B, …)` — same, with an
//!     explicit backend `B` (`backends.pikevm` / `.backtrack` / `.literal` / `.auto`).
//!
//! ## Use it (runtime)
//!
//! ```zig
//! var diag: gex.Diagnostic = .{};
//! var re = try gex.compileRuntime(gpa, "\\d+", &diag, .{}); // .{} = default Options
//! defer re.deinit();
//! var sc = try @TypeOf(re).Scratch.init(gpa, &re.program); // caller-owned, per thread
//! defer sc.deinit(gpa);
//!
//! _ = re.isMatch(&sc, "abc123"); //          bool
//! _ = re.find(&sc, "abc123"); //             ?Match → "123"
//! var it = re.findAll(&sc, "a1 b22 c333"); // iterate non-overlapping matches
//! while (it.next()) |m| _ = m;
//! ```
//!
//! ## Use it (comptime — no allocator)
//!
//! ```zig
//! const re = comptime gex.compileComptime("\\d{3}-\\d{4}", .{});
//! const Scratch = @TypeOf(re).Scratch; // the backend's Scratch type, exposing the buffer convention
//! // (a) match AT comptime — the result is a compile-time constant:
//! const ok = comptime re.isMatchComptime("call 555-1234"); // true
//! // (b) or match at RUNTIME with a buffer Scratch (still no allocator):
//! var buf: [Scratch.bufferLen(&re.program)]Scratch.Buf = undefined;
//! var sc = try Scratch.initBuffer(&buf, &re.program);
//! _ = re.find(&sc, "call 555-1234");
//! _ = ok;
//! ```
//!
//! See `Compiled` for the full method set incl. captures/replace, and
//! `docs/usage-guide.md` for a from-scratch tour (lexer → AST → HIR → backend).

const std = @import("std");

const core = @import("../core/root.zig");
const hir = core.hir;
const parser = core.compile;
const backend = @import("backend.zig");
const auto = @import("backends/auto.zig");

/// Re-export: a parse-failure report — error code + byte span + message + caret renderer.
pub const Diagnostic = parser.Diagnostic;
/// Re-export: a match span as half-open byte offsets (`backend.Match`).
pub const Match = backend.Match;
/// Re-export: a read-only view of one match's captures (`backend.Captures`).
pub const Captures = backend.Captures;

/// The default backend used by `compileRuntime`/`compileComptime`: the `auto`
/// dispatcher, which picks the literal / backtrack / Pike VM strategy from the
/// pattern's analysis and the input. Power users pass a specific backend to the
/// `*With` constructors instead.
///
/// @stable-since: v0.1.0
pub const default_backend = auto;

/// Errors from the full compile pipeline (parse → HIR → program).
///
/// @stable-since: v0.1.0
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
///
/// @stable-since: v0.1.0
pub const Options = struct {
    /// How `(?i)` case-insensitivity is realized (`.none` / `.simple` / `.full`).
    /// See `hir.CaseFold` — `.full` adds the 1→many expansions (`ß`→`ss`).
    case_fold: hir.CaseFold = .simple,

    /// Seed the `i` flag (case-insensitive) for the WHOLE pattern, as if it began
    /// with `(?i)`. Inline flags still compose on top — a scoped `(?-i:…)` turns it
    /// back off within that group. Default off.
    case_insensitive: bool = false,
    /// Seed the `m` flag (multiline): `^`/`$` also match at line boundaries, as if
    /// the pattern began with `(?m)`. Default off.
    multiline: bool = false,
    /// Seed the `s` flag (dot-all): `.` also matches `\n`, as if the pattern began
    /// with `(?s)`. Default off.
    dot_matches_newline: bool = false,

    /// Project these front-door options onto the HIR builder's options.
    fn toHir(self: Options) hir.Options {
        return .{ .case_fold = self.case_fold };
    }

    /// The initial inline-flag state to seed the pattern with. OR-merged with any
    /// bare `(?…)` flags the pattern sets, so `Options` provides the defaults and
    /// inline flags add to them. (A bare `(?-i)` cannot remove an `Options` seed —
    /// set the option to `false` instead; scoped `(?-i:…)` groups still scope
    /// normally because they are applied during lowering, not to the global state.)
    fn initialFlags(self: Options) hir.Flags {
        return .{
            .case_insensitive = self.case_insensitive,
            .multiline = self.multiline,
            .dot_all = self.dot_matches_newline,
        };
    }
};

/// A compiled regex over backend `B`: an immutable `Program` + capture `Meta`.
/// Returned by `compileRuntime`/`compileComptime` (and the `*With` variants). This is
/// the front-door value type — `re.isMatch`/`find`/`captures`/`findAll`/`split`/
/// `replaceAll` live here and forward to `Engine(B)`.
///
/// Thread-safe to SHARE (immutable, `*const`-borrowed by every method); each thread
/// brings its OWN `Scratch`. Per the contract the caller owns the `Scratch` and builds
/// it directly off `@TypeOf(re).Scratch` — `Compiled` only holds the type and forwards
/// `&sc`.
///
/// Step by step (runtime):
///
/// ```zig
/// // 1) compile (heap-backed; free with deinit). A bad pattern fills `diag`.
/// var diag: gex.Diagnostic = .{};
/// var re = try gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &diag, .{});
/// defer re.deinit();
///
/// // 2) make a Scratch off the regex's Scratch type — caller-owned, one per thread.
/// var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
/// defer sc.deinit(gpa);
///
/// // 3) use the API; pass &sc to each call.
/// _ = re.isMatch(&sc, "x a@b y"); //                       bool
/// if (re.find(&sc, "x a@b y")) |m| _ = m.slice("x a@b y"); // ?Match
/// _ = re.count(&sc, "a@b c@d"); //                         non-overlapping match count
///
/// // 4) captures: size the slot array with slotCount().
/// const slots = try gpa.alloc(?usize, re.slotCount());
/// defer gpa.free(slots);
/// if (re.captures(&sc, slots, "user@host")) |c| _ = c.groupSlice(1); // "user"
/// ```
///
/// Comptime (no allocator, no deinit): `const re = compileComptime("\\d+", .{});` then
/// either use the runtime methods with a buffer `Scratch`
/// (`@TypeOf(re).Scratch.initBuffer`), or the `*Comptime` methods that run the match
/// itself at compile time (`isMatchComptime`, `findComptime`, `capturesComptime`, …).
///
/// @stable-since: v0.1.0
pub fn Compiled(comptime B: type) type {
    const Eng = backend.Engine(B);
    return struct {
        const Self = @This();

        /// The per-search state type — initialize one at the call site
        /// (`@TypeOf(re).Scratch.init(gpa, &re.program)`, or `.initBuffer(buf, …)` for
        /// a no-allocator/comptime buffer).
        ///
        /// @stable-since: v0.1.0
        pub const Scratch = B.Scratch;
        /// The backend type `B` this regex was compiled with (e.g. `backends.auto`).
        pub const Backend = B;

        /// The backend's immutable executable form (NFA insts, literal set, …),
        /// shareable across threads. Pass `&re.program` to `Scratch.init`.
        program: B.Program,
        /// Capture metadata (group count + names): sizes `slots` and resolves names.
        meta: backend.Meta,
        /// Non-null for `compileRuntime` (used by `deinit`); null for comptime.
        allocator: ?std.mem.Allocator,

        /// Release heap memory (no-op for a comptime-compiled regex).
        ///
        /// @stable-since: v0.1.0
        pub fn deinit(self: *Self) void {
            const a = self.allocator orelse return;
            if (@hasDecl(B, "freeProgram")) B.freeProgram(a, &self.program);
            for (self.meta.group_names) |gn| {
                if (gn) |name| a.free(name);
            }
            if (self.meta.group_names.len != 0) a.free(self.meta.group_names);
        }

        /// How many `?usize` capture slots `captures`/`capturesAll`/`replaceAll`
        /// need: `2 * (captureCount + 1)`. Pre-allocate exactly this many.
        ///
        /// @stable-since: v0.1.0
        pub fn slotCount(self: Self) usize {
            return self.meta.slotLen();
        }
        /// Number of capturing groups (excluding the whole match).
        ///
        /// @stable-since: v0.1.0
        pub fn captureCount(self: Self) usize {
            return self.meta.capture_count;
        }

        // ── the user-facing API ──────────────────────────────────────────────────

        /// Does the pattern match anywhere in `input`? (Unanchored; cheapest op —
        /// stops at the first match, fills no captures.)
        ///
        /// @stable-since: v0.1.0
        pub fn isMatch(self: *const Self, scratch: *Scratch, input: []const u8) bool {
            return Eng.isMatch(&self.program, scratch, input, .{});
        }
        /// `isMatch` with explicit `SearchOptions` (`.start` offset, `.anchored`).
        ///
        /// @stable-since: v0.1.0
        pub fn isMatchAt(self: *const Self, scratch: *Scratch, input: []const u8, opts: backend.SearchOptions) bool {
            return Eng.isMatch(&self.program, scratch, input, opts);
        }
        /// The leftmost match in `input`, or null. The returned `Match` is byte
        /// offsets; use `m.slice(input)` for the text.
        ///
        /// @stable-since: v0.1.0
        pub fn find(self: *const Self, scratch: *Scratch, input: []const u8) ?Match {
            return Eng.find(&self.program, scratch, input, .{});
        }
        /// `find` with explicit `SearchOptions` (resume at `.start`, or `.anchored`).
        ///
        /// @stable-since: v0.1.0
        pub fn findAt(self: *const Self, scratch: *Scratch, input: []const u8, opts: backend.SearchOptions) ?Match {
            return Eng.find(&self.program, scratch, input, opts);
        }
        /// Resolve the first match's submatches into `slots` (length `slotCount()`),
        /// returning a `Captures` view (or null on no match). Read groups via
        /// `c.group(i)`/`c.groupSlice(i)`/`c.named(...)`.
        ///
        /// @stable-since: v0.1.0
        pub fn captures(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8) ?Captures {
            return Eng.captures(&self.program, scratch, input, slots, self.meta, .{});
        }
        /// Iterator over every non-overlapping match, left to right. Empty matches
        /// advance one code point so iteration always terminates.
        ///
        /// @stable-since: v0.1.0
        pub fn findAll(self: *const Self, scratch: *Scratch, input: []const u8) Eng.MatchIterator {
            return Eng.findAll(&self.program, scratch, input, .{});
        }
        /// Iterator yielding a `Captures` per non-overlapping match into the SHARED
        /// `slots` — each view is valid only until the next `next()` reuses `slots`.
        ///
        /// @stable-since: v0.1.0
        pub fn capturesAll(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8) Eng.CaptureIterator {
            return Eng.capturesAll(&self.program, scratch, input, slots, self.meta, .{});
        }
        /// Count the non-overlapping matches in `input`.
        ///
        /// @stable-since: v0.1.0
        pub fn count(self: *const Self, scratch: *Scratch, input: []const u8) usize {
            return Eng.count(&self.program, scratch, input, .{});
        }
        /// Iterator over the substrings between successive matches (the pattern is the
        /// separator). Empty matches are skipped; the final piece is always yielded.
        ///
        /// @stable-since: v0.1.0
        pub fn split(self: *const Self, scratch: *Scratch, input: []const u8) Eng.SplitIterator {
            return Eng.split(&self.program, scratch, input, .{});
        }
        /// Replace every match, writing the result to `writer`. `template` may
        /// reference captures: `$0`/`$1`/… by number, `${name}` by name, `$$` for a
        /// literal `$`. Needs a `slots` buffer of `slotCount()`.
        ///
        /// @stable-since: v0.1.0
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
                @compileError("the buffer-scratch / comptime-matching path requires the backend's Scratch to expose Buf/bufferLen/initBuffer");
        }

        /// @stable-since: v0.1.0
        pub fn isMatchComptime(comptime self: Self, comptime input: []const u8) bool {
            return self.isMatchAtComptime(input, .{});
        }
        /// @stable-since: v0.1.0
        pub fn isMatchAtComptime(comptime self: Self, comptime input: []const u8, comptime opts: backend.SearchOptions) bool {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.isMatch(&self.program, &sc, input, opts);
            }
        }
        /// @stable-since: v0.1.0
        pub fn findComptime(comptime self: Self, comptime input: []const u8) ?Match {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.find(&self.program, &sc, input, .{});
            }
        }
        /// @stable-since: v0.1.0
        pub fn countComptime(comptime self: Self, comptime input: []const u8) usize {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.count(&self.program, &sc, input, .{});
            }
        }
        /// Comptime captures: resolve the first match's groups at compile time. The
        /// returned `Captures` references `ro_data` (the slot offsets and the input
        /// are frozen into the binary), so `groupSlice`/`namedSlice` work on it at
        /// comptime *and* at runtime. This rounds out `findComptime` with submatch
        /// access; the backend must support captures (`caps.captures`).
        ///
        /// @stable-since: v0.2.0
        pub fn capturesComptime(comptime self: Self, comptime input: []const u8) ?Captures {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                var slots: [self.meta.slotLen()]?usize = undefined;
                _ = Eng.captures(&self.program, &sc, input, &slots, self.meta, .{}) orelse return null;
                // Freeze the resolved slots into ro_data so the returned view does
                // not dangle on this block's comptime-local array — the same const-
                // promotion trick `comptimeGroupNames` uses below.
                const frozen = slots;
                return .{ .slots = &frozen, .meta = self.meta, .input = input };
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
///
/// @stable-since: v0.1.0
pub fn compileRuntime(allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic, comptime opts: Options) Error!Compiled(default_backend) {
    return compileRuntimeWith(default_backend, allocator, pattern, diag, opts);
}

/// Comptime: compile `pattern` into a ro_data regex (default backend). A bad
/// pattern is a compile error. No allocator; `deinit` is a no-op.
///
/// @stable-since: v0.1.0
pub fn compileComptime(comptime pattern: []const u8, comptime opts: Options) Compiled(default_backend) {
    return compileComptimeWith(default_backend, pattern, opts);
}

/// `compileRuntime` with an explicit backend.
///
/// @stable-since: v0.1.0
pub fn compileRuntimeWith(comptime B: type, allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic, comptime opts: Options) Error!Compiled(B) {
    const ast = parser.parse(allocator, pattern, diag) catch |e| switch (e) {
        error.InvalidPattern => return error.InvalidPattern,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer ast.deinit(allocator);

    // Seed the front-door flag options onto the AST's flags (OR-merged with any
    // bare inline flags the pattern set) before lowering. `seeded` shares `ast`'s
    // arrays — only the flag bits change — so `ast.deinit` above still owns them.
    var seeded = ast;
    seeded.flags = opts.initialFlags().merge(ast.flags);

    const h = hir.buildAlloc(allocator, seeded, opts.toHir()) catch |e| switch (e) {
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
///
/// @stable-since: v0.1.0
pub fn compileComptimeWith(comptime B: type, comptime pattern: []const u8, comptime opts: Options) Compiled(B) {
    const ast = comptime parser.compile(pattern); // @compileError on a bad pattern
    // Seed the front-door flag options (OR-merged with any bare inline flags).
    const seeded = comptime blk: {
        var a = ast;
        a.flags = opts.initialFlags().merge(ast.flags);
        break :blk a;
    };
    // HIR lowering with case folding scans ezi_code's fold tables per literal,
    // which at comptime can exceed the default branch budget; raise it (a ceiling,
    // not a cost — spent only on work actually done).
    @setEvalBranchQuota(@intCast(@min(@as(u64, pattern.len) * 20_000 + 200_000, std.math.maxInt(u32))));
    const h = comptime switch (hir.buildComptime(seeded, opts.toHir())) {
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
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
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
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "call 555-1234 now"));
    try testing.expectEqualStrings("555-1234", re.find(&sc, "call 555-1234 now").?.slice("call 555-1234 now"));
    // capture slots can be a comptime-sized stack array (capture_count is comptime)
    try testing.expectEqual(@as(usize, 2), re.slotCount());
}

test "compileComptime: named captures resolve" {
    const Re = compileComptime("(?<y>\\d+)-(?<m>\\d+)", .{});
    var re = Re;
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
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
    var rsc = try @TypeOf(rt).Scratch.init(testing.allocator, &rt.program);
    defer rsc.deinit(testing.allocator);

    var ct = compileComptime(pat, .{});
    var csc = try @TypeOf(ct).Scratch.init(testing.allocator, &ct.program);
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
    var buf: [4096]@TypeOf(re).Scratch.Buf = undefined; // Buf == the backend's Cell
    var sc = try @TypeOf(re).Scratch.initBuffer(&buf, &re.program);
    try testing.expectEqualStrings("abc12", re.find(&sc, "??abc12!!").?.slice("??abc12!!"));
    try testing.expect(!re.isMatch(&sc, "ABC"));
}

test "front-door iterators and replace" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), re.count(&sc, "a1b22c333"));

    var split_re = try compileRuntime(testing.allocator, "\\s+", &diag, .{});
    defer split_re.deinit();
    var ssc = try @TypeOf(split_re).Scratch.init(testing.allocator, &split_re.program);
    defer ssc.deinit(testing.allocator);
    var it = split_re.split(&ssc, "the  quick fox");
    try testing.expectEqualStrings("the", it.next().?);
    try testing.expectEqualStrings("quick", it.next().?);
    try testing.expectEqualStrings("fox", it.next().?);
    try testing.expect(it.next() == null);
}

// ── Full case folding (case_fold = .full) ─────────────────────────────────────

test "full folding: (?i)ß also matches its expansion ss" {
    var diag: Diagnostic = .{};
    // `.full` lowers ß to (?:[ßẞ] | [sSſ][sSſ]) — both the sharp-s code points
    // AND the spelled-out "ss" in any case.
    var re = try compileRuntime(testing.allocator, "(?i)ß", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);

    try testing.expect(re.isMatch(&sc, "ß")); //  the code point itself
    try testing.expect(re.isMatch(&sc, "ẞ")); //  U+1E9E, simple-folds to ß
    try testing.expect(re.isMatch(&sc, "ss")); // the expansion …
    try testing.expect(re.isMatch(&sc, "SS")); // … in any case
    try testing.expect(re.isMatch(&sc, "Ss"));
    try testing.expect(!re.isMatch(&sc, "s")); // a lone s is not enough
    try testing.expectEqualStrings("ss", re.find(&sc, "<<ss>>").?.slice("<<ss>>"));
}

test "full folding: ligature (?i)ﬀ also matches ff" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?i)ﬀ", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ﬀ"));
    try testing.expect(re.isMatch(&sc, "ff"));
    try testing.expect(re.isMatch(&sc, "FF"));
}

test "simple folding leaves ß un-expanded (the .full / .simple contrast)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?i)ß", &diag, .{ .case_fold = .simple });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ß"));
    try testing.expect(re.isMatch(&sc, "ẞ"));
    try testing.expect(!re.isMatch(&sc, "ss")); // simple folding: no 1→many expansion
}

test "full folding in a class stays simple (a class matches one code point)" {
    var diag: Diagnostic = .{};
    // Inside [...] there is no multi-code-point expansion; [ß] under .full still
    // matches only the single sharp-s code points, never the two-char "ss".
    var re = try compileRuntime(testing.allocator, "(?i)[ß]", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ß"));
    try testing.expect(!re.isMatch(&sc, "ss"));
}

test "full folding: plain ASCII literals are unaffected (run coalescing intact)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?i)abc", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ABC"));
    try testing.expect(re.isMatch(&sc, "aBc"));
    try testing.expect(!re.isMatch(&sc, "abd"));
}

// ── Options-seeded inline flags (case_insensitive / multiline / dot_matches_newline)

test "Options.case_insensitive seeds (?i) for the whole pattern" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "abc", &diag, .{ .case_insensitive = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ABC"));
    try testing.expect(re.isMatch(&sc, "aBc"));

    // The default (no option) stays case-sensitive.
    var re2 = try compileRuntime(testing.allocator, "abc", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(!re2.isMatch(&sc2, "ABC"));
}

test "Options.multiline seeds (?m): ^ matches at line starts" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "^b", &diag, .{ .multiline = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "a\nb")); // ^ matches just after the \n

    var re2 = try compileRuntime(testing.allocator, "^b", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(!re2.isMatch(&sc2, "a\nb")); // without (?m), ^ is input start only
}

test "Options.dot_matches_newline seeds (?s): . matches newline" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "a.b", &diag, .{ .dot_matches_newline = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "a\nb"));

    var re2 = try compileRuntime(testing.allocator, "a.b", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(!re2.isMatch(&sc2, "a\nb"));
}

test "Options flags seed the comptime path too" {
    const Re = comptime compileComptime("abc", .{ .case_insensitive = true });
    try testing.expect(comptime Re.isMatchComptime("ABC"));
    const Re2 = comptime compileComptime("abc", .{});
    try testing.expect(!comptime Re2.isMatchComptime("ABC"));
}

test {
    testing.refAllDecls(@This());
}
