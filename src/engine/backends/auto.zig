//! `auto` — the default dispatcher backend.
//!
//! `auto` is itself a backend (it satisfies the same contract), but instead of one
//! match strategy it composes the others and **switches on the pattern's analysis
//! and on the input**:
//!
//!   * **By analysis, at build time.** A pure literal / literal-alternation pattern
//!     (`abc`, `cat|dog`) compiles to the `literal` backend — a plain byte scan, no
//!     NFA. Everything else compiles to the shared `nfa` program.
//!   * **By input, at search time.** For NFA patterns, `auto` runs the *same*
//!     program through either `backtrack` (depth-first; smaller constants, but its
//!     visited set costs memory ∝ program × input) or `pikevm` (breadth-first;
//!     constant memory, linear time). It picks `backtrack` for **small inputs**
//!     that fit the scratch and falls back to `pikevm` for large ones. Because both
//!     execute the identical program with identical (leftmost-first) semantics, the
//!     choice is invisible: same match, same captures, every time.
//!
//! This is the backend a casual user gets by default (`compileRuntime` /
//! `compileComptime`); power users opt into a specific backend explicitly. It works
//! at comptime and runtime: the `Program` is a union of the sub-backends' POD
//! programs, and the `Scratch` carves one `[]Cell` buffer shared across whichever
//! sub-scratches it needs.
//!
//! `auto` is just one assembly of the built-ins — a third-party backend (or a
//! different `auto`) drops in the same way; nothing here is privileged by the
//! contract.

const std = @import("std");

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");
const nfa = @import("../nfa.zig");

const literal = @import("literal.zig");
const pikevm = @import("pikevm.zig");
const backtrack = @import("backtrack.zig");

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const Cell = backend.Cell;

/// Input-length ceiling under which `auto` prefers the backtracker (when it also
/// fits the scratch). Above it, the Pike VM runs — constant memory, and no deep
/// backtracking recursion. Chosen so the backtracker's visited set and recursion
/// depth stay modest; the Pike VM is just as correct above it, only with different
/// performance constants.
const BACKTRACK_MAX_INPUT: usize = 4096;

// ── Contract surface ────────────────────────────────────────────────────────────

pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = false };
pub const Options = struct {};

/// A compiled program: either a literal program or the shared NFA program. The
/// active arm is the analysis-time choice; the per-search engine choice (pikevm vs
/// backtrack) does not change the program, only how it is executed.
pub const Program = struct {
    inner: union(enum) {
        literal: literal.Program,
        nfa: nfa.Program,
    },
};

pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    if (literal.supports(h)) {
        return .{ .inner = .{ .literal = try literal.buildAlloc(gpa, h, .{}) } };
    }
    if (!nfa.supports(h)) return error.Unsupported; // e.g. `\X` grapheme
    return .{ .inner = .{ .nfa = try nfa.buildAlloc(gpa, h) } };
}

pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    if (comptime literal.supports(h)) {
        return .{ .inner = .{ .literal = literal.buildComptime(h, .{}) } };
    }
    return .{ .inner = .{ .nfa = nfa.buildComptime(h) } }; // `\X` ⇒ @compileError inside
}

pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    switch (program.inner) {
        .literal => |*p| literal.freeProgram(gpa, p),
        .nfa => |*p| nfa.freeProgram(gpa, p),
    }
}

// ── Scratch ──────────────────────────────────────────────────────────────────────

/// One companion holding whatever the selected sub-backends need. For a literal
/// program that is nothing; for an NFA program it holds **both** a Pike VM and a
/// backtracker scratch, since the engine is chosen per search. Carved from one
/// `[]Cell` buffer (Pike VM region, then backtracker region), so it works at
/// comptime and runtime alike.
pub const Scratch = struct {
    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = Cell;

    const NfaScratch = struct { pike: pikevm.Scratch, back: backtrack.Scratch };

    inner: union(enum) {
        literal: literal.Scratch,
        nfa: NfaScratch,
    },

    pub fn bufferLen(program: *const Program) usize {
        return switch (program.inner) {
            .literal => 0,
            .nfa => |*p| pikevm.Scratch.bufferLen(p) + backtrack.Scratch.bufferLen(p),
        };
    }

    pub fn initBuffer(buf: []Cell, program: *const Program) backend.ScratchError!Scratch {
        switch (program.inner) {
            .literal => return .{ .inner = .{ .literal = .{} } },
            .nfa => |*p| {
                const pike_len = pikevm.Scratch.bufferLen(p);
                if (buf.len < pike_len) return error.BufferTooSmall;
                const pike = try pikevm.Scratch.initBuffer(buf[0..pike_len], p);
                const back = try backtrack.Scratch.initBuffer(buf[pike_len..], p);
                return .{ .inner = .{ .nfa = .{ .pike = pike, .back = back } } };
            },
        }
    }

    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        switch (program.inner) {
            .literal => return .{ .inner = .{ .literal = .{} } },
            .nfa => |*p| {
                var pike = try pikevm.Scratch.init(gpa, p);
                errdefer pike.deinit(gpa);
                const back = try backtrack.Scratch.init(gpa, p);
                return .{ .inner = .{ .nfa = .{ .pike = pike, .back = back } } };
            },
        }
    }

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        switch (self.inner) {
            .literal => |*s| s.deinit(gpa),
            .nfa => |*s| {
                s.pike.deinit(gpa);
                s.back.deinit(gpa);
            },
        }
    }

    pub fn reset(self: *Scratch) void {
        switch (self.inner) {
            .literal => |*s| s.reset(),
            .nfa => |*s| {
                s.pike.reset();
                s.back.reset();
            },
        }
    }
};

/// Per-search engine choice for an NFA program: backtrack on a small input that
/// fits its scratch, else the Pike VM.
fn preferBacktrack(p: *const nfa.Program, back: *const backtrack.Scratch, input: []const u8) bool {
    return input.len <= BACKTRACK_MAX_INPUT and backtrack.fits(p, back, input);
}

// ── Contract: matching entry points ──────────────────────────────────────────────

pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    switch (program.inner) {
        .literal => |*p| return literal.isMatch(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            const s = &scratch.inner.nfa;
            if (preferBacktrack(p, &s.back, input)) return backtrack.isMatch(p, &s.back, input, opts);
            return pikevm.isMatch(p, &s.pike, input, opts);
        },
    }
}

pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    switch (program.inner) {
        .literal => |*p| return literal.search(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            const s = &scratch.inner.nfa;
            if (preferBacktrack(p, &s.back, input)) return backtrack.search(p, &s.back, input, opts);
            return pikevm.search(p, &s.pike, input, opts);
        },
    }
}

pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots: []?usize, opts: SearchOptions) ?Match {
    switch (program.inner) {
        .literal => |*p| return literal.searchCaptures(p, &scratch.inner.literal, input, slots, opts),
        .nfa => |*p| {
            const s = &scratch.inner.nfa;
            if (preferBacktrack(p, &s.back, input)) return backtrack.searchCaptures(p, &s.back, input, slots, opts);
            return pikevm.searchCaptures(p, &s.pike, input, slots, opts);
        },
    }
}

/// Which way a built program routes (for diagnostics/tests): `.literal` or `.nfa`.
pub fn route(program: *const Program) []const u8 {
    return switch (program.inner) {
        .literal => "literal",
        .nfa => "nfa",
    };
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("../../core/compile.zig");
const E = backend.Engine(@This());

const Compiled = struct {
    program: Program,
    scratch: Scratch,
    meta: backend.Meta,

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pattern, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        errdefer freeProgram(gpa, &program);
        return .{
            .program = program,
            .scratch = try Scratch.init(gpa, &program),
            .meta = .{ .capture_count = h.capture_count },
        };
    }
    fn deinit(self: *Compiled) void {
        self.scratch.deinit(testing.allocator);
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

test "auto satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "auto routes literal patterns to the literal backend" {
    const gpa = testing.allocator;
    const cases = [_]struct { pat: []const u8, route: []const u8 }{
        .{ .pat = "abc", .route = "literal" },
        .{ .pat = "cat|dog", .route = "literal" },
        .{ .pat = "a.c", .route = "nfa" },
        .{ .pat = "(a)(b)", .route = "nfa" },
        .{ .pat = "\\d+", .route = "nfa" },
        .{ .pat = "^abc$", .route = "nfa" },
    };
    for (cases) |c| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, c.pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        defer freeProgram(gpa, &program);
        try testing.expectEqualStrings(c.route, route(&program));
    }
}

test "auto matches across literal and nfa routes" {
    try expectFind("cat|dog", "i have a dog", "dog"); // literal route
    try expectFind("a.*c", "abXYZc end c", "abXYZc end c"); // nfa route
    try expectFind("\\w+", "héllo, wörld", "héllo"); // unicode, nfa route
    try expectFind("(\\d{4})-(\\d{2})", "y 2026-06 z", "2026-06"); // captures, nfa route
}

test "auto captures (nfa route)" {
    var re = try Compiled.init("(\\w+)@(\\w+)");
    defer re.deinit();
    var slots: [6]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "to alice@host now", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("alice", c.groupSlice(1).?);
    try testing.expectEqualStrings("host", c.groupSlice(2).?);
}

test "auto: backtrack and pikevm routes agree on a large input (crosses the switch)" {
    // An input longer than BACKTRACK_MAX_INPUT forces the Pike VM; a short slice of
    // the same pattern uses the backtracker. Both must find the same thing.
    var re = try Compiled.init("a\\w+z");
    defer re.deinit();
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, BACKTRACK_MAX_INPUT + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    @memcpy(big[50 .. 50 + 6], "aBCDEz");
    const m_big = re.find(big).?; // pikevm route (len > threshold)
    try testing.expectEqualStrings("aBCDEz", m_big.slice(big));

    const m_small = re.find("..aBCDEz..").?; // backtrack route (len < threshold)
    try testing.expectEqualStrings("aBCDEz", m_small.slice("..aBCDEz.."));
}

test "auto: grapheme pattern is unsupported" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "\\X", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
}

test "auto runs at comptime (both routes) via a buffer scratch" {
    // literal route
    const lit = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        const a = compile.compile("cat|dog|bird");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var buf: [Scratch.bufferLen(&program)]Cell = undefined;
        var sc = Scratch.initBuffer(&buf, &program) catch unreachable;
        const input = "a big bird";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no match");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("bird", lit);

    // nfa route
    const cap = comptime blk: {
        @setEvalBranchQuota(3_000_000);
        const a = compile.compile("(\\d{4})-(\\d{2})");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var buf: [Scratch.bufferLen(&program)]Cell = undefined;
        var sc = Scratch.initBuffer(&buf, &program) catch unreachable;
        const input = "y 2026-06 z";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no match");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("2026-06", cap);
}

test {
    testing.refAllDecls(@This());
}
