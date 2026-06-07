//! Literal backend — a substring / literal-alternation matcher.
//!
//! The fast path for patterns that reduce to plain text: a single literal run
//! (`abc`, `héllo`) or a top-level alternation of literal runs (`cat|dog|fish`).
//! It encodes each branch to its UTF-8 bytes once and then does a leftmost-first
//! byte scan — no NFA, no per-search state. This is what the `auto` dispatcher
//! routes whole-literal patterns to; everything else falls through to a real
//! engine (the Pike VM).
//!
//! **Stateless** (`Scratch` carries nothing) and fully usable at comptime and
//! runtime: `Program` is slices/POD, so `buildComptime` bakes it into ro_data and
//! `buildAlloc` heap-allocates it. The `Scratch` lifecycle methods are trivial
//! no-ops so the front door and `auto` can treat it uniformly with the stateful
//! backends (same `init`/`initBuffer`/`bufferLen`/`reset`/`deinit` surface).
//!
//! Semantics: **leftmost-first** (Perl/JS), identical to the Pike VM. The scan
//! walks byte positions left→right; at the leftmost position where any branch
//! matches, the highest-priority (earliest-listed) branch that matches there
//! wins — so `a|ab` yields `a`, `ab|a` yields `ab`, exactly like the NFA. Byte
//! scanning is sound for UTF-8: a needle is a sequence of whole code points, and
//! its bytes can only occur at a code-point boundary of valid UTF-8 input.
//!
//! Captures: only the whole match (group 0). Patterns with capturing groups are
//! not this backend's domain — `auto` never routes them here, and a direct user
//! of `literal` on such a pattern gets `error.Unsupported` at build.

const std = @import("std");

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");

const ezi_code = @import("ezi_code");
const utf8 = ezi_code.encoding.utf8;
const encoding = ezi_code.encoding;

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const CodePoint = ezi_code.encoding.CodePoint;

// ── Contract surface ────────────────────────────────────────────────────────────

pub const caps = Caps{ .captures = true, .stateless = true, .grapheme = false };

/// Backend build options. The HIR has already applied flags/folding, so nothing is
/// needed here; the field exists to satisfy the contract shape.
pub const Options = struct {};

/// One needle's slice into `Program.needles`.
const Bound = struct { start: u32, len: u32 };

/// Immutable program: every branch's UTF-8 bytes concatenated into `needles`, with
/// `bounds` delimiting them **in alternation (priority) order**. Self-contained, so
/// the HIR may be freed after `buildAlloc`.
pub const Program = struct {
    needles: []const u8,
    bounds: []const Bound,
};

/// Stateless companion. Zero-size, with the standard lifecycle as no-ops so the
/// front door / `auto` use the same calls as a stateful backend.
pub const Scratch = struct {
    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = backend.Cell;

    pub fn bufferLen(_: *const Program) usize {
        return 0;
    }
    pub fn init(_: std.mem.Allocator, _: *const Program) std.mem.Allocator.Error!Scratch {
        return .{};
    }
    pub fn initBuffer(_: []backend.Cell, _: *const Program) backend.ScratchError!Scratch {
        return .{};
    }
    pub fn deinit(_: *Scratch, _: std.mem.Allocator) void {}
    pub fn reset(_: *Scratch) void {}
};

// ── Compiler: HIR → Program (one body, two modes) ────────────────────────────────

const Sizes = struct { bytes: u32, bounds: u32 };
const Mode = enum { count, emit };

fn Builder(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        const is_emit = mode == .emit;

        h: hir.Hir,
        needles: if (is_emit) []u8 else void = if (is_emit) undefined else {},
        bounds: if (is_emit) []Bound else void = if (is_emit) undefined else {},
        byte_len: u32 = 0,
        bound_len: u32 = 0,

        fn emitByte(self: *Self, b: u8) void {
            if (is_emit) self.needles[self.byte_len] = b;
            self.byte_len += 1;
        }

        fn addRun(self: *Self, lit: hir.Node.Run) void {
            const start = self.byte_len;
            for (self.h.literals[lit.start .. lit.start + lit.len]) |cp| {
                // HIR literals are guaranteed-valid scalars; encode each to UTF-8.
                if (!encoding.isValidCodePoint(cp)) continue;
                var buf: [4]u8 = undefined;
                const n = utf8.encodeCodePointUnchecked(cp, &buf);
                for (buf[0..n]) |b| self.emitByte(b);
            }
            self.finishBound(start);
        }

        fn addEmpty(self: *Self) void {
            self.finishBound(self.byte_len); // zero-length needle: matches empty
        }

        fn finishBound(self: *Self, start: u32) void {
            if (is_emit) self.bounds[self.bound_len] = .{ .start = start, .len = self.byte_len - start };
            self.bound_len += 1;
        }

        /// A single alternation branch (or the whole pattern): must be a literal run
        /// or the empty string — anything else means this isn't a literal pattern.
        fn addBranch(self: *Self, idx: u32) error{Unsupported}!void {
            const node = self.h.nodes[idx];
            switch (node.tag) {
                .literal => self.addRun(node.data.run),
                .empty => self.addEmpty(),
                else => return error.Unsupported,
            }
        }

        fn run(self: *Self) error{Unsupported}!void {
            const root = self.h.nodes[self.h.root];
            switch (root.tag) {
                .literal => self.addRun(root.data.run),
                .empty => self.addEmpty(),
                .alternation => {
                    const d = root.data.children;
                    for (self.h.children[d.start .. d.start + d.len]) |c| try self.addBranch(c);
                },
                else => return error.Unsupported,
            }
        }
    };
}

fn measure(h: hir.Hir) error{Unsupported}!Sizes {
    var b = Builder(.count){ .h = h };
    try b.run();
    return .{ .bytes = b.byte_len, .bounds = b.bound_len };
}

fn emit(h: hir.Hir, needles: []u8, bounds: []Bound) error{Unsupported}!Program {
    var b = Builder(.emit){ .h = h, .needles = needles, .bounds = bounds };
    try b.run();
    return .{ .needles = needles[0..b.byte_len], .bounds = bounds[0..b.bound_len] };
}

/// Can the literal backend handle this HIR? True only for a pure literal / literal
/// alternation with no capturing groups and no grapheme node. Used by `auto`.
pub fn supports(h: hir.Hir) bool {
    if (h.capture_count != 0 or h.analysis.has_grapheme) return false;
    _ = measure(h) catch return false;
    return true;
}

/// Compile a HIR into a heap-allocated `Program` (free with `freeProgram`).
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    const sizes = measure(h) catch return error.Unsupported;
    const needles = try gpa.alloc(u8, sizes.bytes);
    errdefer gpa.free(needles);
    const bounds = try gpa.alloc(Bound, sizes.bounds);
    errdefer gpa.free(bounds);
    return emit(h, needles, bounds) catch error.Unsupported;
}

/// Compile a HIR into a ro_data `Program` at comptime. An unsupported pattern is a
/// `@compileError` (callers that might pass a non-literal must gate on `supports`).
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    const work: u64 = @as(u64, h.nodes.len) + h.literals.len;
    @setEvalBranchQuota(@intCast(@min(20_000 + work * 100, std.math.maxInt(u32))));
    const sizes = comptime (measure(h) catch @compileError("literal: pattern is not a pure literal / literal-alternation"));
    comptime var needles: [sizes.bytes]u8 = undefined;
    comptime var bounds: [sizes.bounds]Bound = undefined;
    const prog = emit(h, &needles, &bounds) catch unreachable; // measure already validated
    const final_needles = needles[0..prog.needles.len].*;
    const final_bounds = bounds[0..prog.bounds.len].*;
    return .{ .needles = &final_needles, .bounds = &final_bounds };
}

pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.needles);
    gpa.free(program.bounds);
}

// ── Contract: matching entry points ──────────────────────────────────────────────

pub fn search(program: *const Program, _: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    var pos = opts.start;
    while (pos <= input.len) : (pos += 1) {
        // Leftmost position first; at this position, alternation priority order.
        for (program.bounds) |b| {
            const needle = program.needles[b.start .. b.start + b.len];
            if (pos + needle.len <= input.len and std.mem.eql(u8, input[pos .. pos + needle.len], needle))
                return .{ .start = pos, .end = pos + needle.len };
        }
        if (opts.anchored) break; // anchored: only the start position
    }
    return null;
}

pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return search(program, scratch, input, opts) != null;
}

pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots: []?usize, opts: SearchOptions) ?Match {
    const m = search(program, scratch, input, opts) orelse return null;
    if (slots.len >= 1) slots[0] = m.start;
    if (slots.len >= 2) slots[1] = m.end;
    return m;
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("../../core/compile.zig");
const E = backend.Engine(@This());

const Compiled = struct {
    program: Program,
    scratch: Scratch = .{},

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pattern, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        return .{ .program = try buildAlloc(gpa, h, .{}) };
    }
    fn deinit(self: *Compiled) void {
        freeProgram(testing.allocator, &self.program);
    }
    fn find(self: *Compiled, input: []const u8) ?Match {
        return E.find(&self.program, &self.scratch, input, .{});
    }
};

fn expectFind(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = re.find(input) orelse return error.NoMatch;
    try testing.expectEqualStrings(expected, m.slice(input));
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    try testing.expect(re.find(input) == null);
}

test "literal satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "single literal: exact, leftmost, none" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("abc", "abXabc", "abc");
    try expectNoMatch("abc", "ab");
    try expectFind("a", "banana", "a");
}

test "unicode literal scans by bytes correctly" {
    try expectFind("héllo", "say héllo!", "héllo");
    try expectFind("café", "le café noir", "café");
    try expectNoMatch("café", "cafe");
}

test "literal alternation is leftmost-first" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("cat|dog", "cat and dog", "cat");
    try expectFind("a|ab", "ab", "a"); // priority: first branch wins at pos 0
    try expectFind("ab|a", "ab", "ab");
    try expectFind("foo|foobar", "foobar", "foo");
    try expectFind("cat|dog|fish", "redfish", "fish");
    try expectNoMatch("cat|dog", "fish");
}

test "anchored / start-offset search" {
    var re = try Compiled.init("abc");
    defer re.deinit();
    try testing.expect(E.find(&re.program, &re.scratch, "abc", .{ .anchored = true }) != null);
    try testing.expect(E.find(&re.program, &re.scratch, "xabc", .{ .anchored = true }) == null);
    const m = E.find(&re.program, &re.scratch, "abcabc", .{ .start = 1 }).?;
    try testing.expectEqual(@as(usize, 3), m.start);
}

test "agnostic ops: findAll / count / split / whole-match captures" {
    var re = try Compiled.init("ab");
    defer re.deinit();
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, "abXabYab", .{}));
    var slots: [2]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "ZZab", &slots, .{ .capture_count = 0 }, .{}).?;
    try testing.expectEqualStrings("ab", c.match().slice("ZZab"));
}

test "supports() gates correctly" {
    const gpa = testing.allocator;
    const cases = [_]struct { pat: []const u8, ok: bool }{
        .{ .pat = "abc", .ok = true },
        .{ .pat = "cat|dog", .ok = true },
        .{ .pat = "a.c", .ok = false }, // dot
        .{ .pat = "a+", .ok = false }, // repetition
        .{ .pat = "(a)", .ok = false }, // capture group
        .{ .pat = "[a-z]", .ok = false }, // class
        .{ .pat = "^a", .ok = false }, // anchor
    };
    for (cases) |c| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, c.pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expectEqual(c.ok, supports(h));
        if (!c.ok) try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
    }
}

test "literal runs at comptime (ro_data program, no allocator)" {
    const got = comptime blk: {
        @setEvalBranchQuota(200_000);
        const a = compile.compile("cat|dog|bird");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var sc = Scratch{};
        const input = "a big bird flew";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no match");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("bird", got);
}

test {
    testing.refAllDecls(@This());
}
