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
//!   * **By analysis, at search time (the prefilter).** Before touching the NFA on an
//!     unanchored search `auto` consults the HIR `Analysis` baked into the program
//!     (a tiny POD `Filter`): a `min_utf8_len` length gate rejects inputs too short
//!     to hold any match; an `anchored_start` pattern (`^…`/`\A…`) only ever matches
//!     at offset 0, so the leftward scan is skipped entirely; and when every match
//!     must begin with a fixed literal, its first byte drives a `memchr` that skips
//!     straight to each candidate start, confirming there with an anchored NFA run.
//!     Every `Analysis` fact is a sound one-sided bound, so the prefilter never drops
//!     a real match — it only avoids running the NFA where one provably cannot start.
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
const dfa = @import("dfa.zig");

const utils = @import("utils");
const encoding = utils.unicode.encoding;
const utf8 = utils.unicode.utf8;

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

/// @stable-since: v0.1.0
pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = true };

/// Build options. `byte_engine` is projected from the front-door
/// `Options.strategy.byte_engine` (see `regex.zig`): `.enabled` builds the byte lazy
/// DFA alongside the NFA program and uses it for the span scan (`isMatch`/`search`)
/// on eligible patterns, with the Pike VM still filling captures and `\b`; `.auto`
/// and `.disabled` keep the code-point engines only. Results-invariant — the DFA arm
/// returns the same span the NFA arm would.
///
/// @stable-since: v0.1.0
pub const Options = struct {
    /// @stable-since: v0.3.0
    byte_engine: ByteEngine = .auto,

    /// @stable-since: v0.3.0
    pub const ByteEngine = enum { auto, enabled, disabled };
};

/// Search-time prefilter facts, distilled from the HIR `Analysis` at build into a
/// tiny POD (so it bakes into `ro_data` at comptime and needs no allocation). Every
/// field is a **sound one-sided bound** — true for *every* match — so acting on it
/// never drops a real match. Only consulted on the NFA arm; the literal arm does its
/// own scanning.
///
/// @stable-since: v0.1.0
pub const Filter = struct {
    /// `analysis.min_utf8_len`: a match needs at least this many bytes, so an input
    /// (slice from the search start) shorter than this cannot match.
    min_bytes: u32 = 0,
    /// `analysis.anchored_start`: every match begins at offset 0 (`^`/`\A`, no
    /// multiline) — an unanchored scan need only try position 0.
    anchored_start: bool = false,
    /// First UTF-8 byte of `analysis.prefix_literal` (the literal run every match
    /// must begin with), or null when no fixed leading literal exists. Drives a
    /// `memchr` start-skip: a match can only begin where this byte appears.
    prefix_byte: ?u8 = null,
};

/// Distil the sound prefilter facts from the HIR analysis.
fn filterFromAnalysis(h: hir.Hir) Filter {
    const an = h.analysis;
    var f = Filter{ .min_bytes = an.min_utf8_len, .anchored_start = an.anchored_start };
    // A leading-byte memchr only helps an unanchored scan; for `anchored_start` the
    // start short-circuit already pins the search to offset 0.
    if (!an.anchored_start) {
        if (an.prefix_literal) |run| {
            if (run.len > 0) {
                const cp = h.literals[run.start];
                if (encoding.isValidCodePoint(cp)) {
                    var buf: [4]u8 = undefined;
                    const n = utf8.encodeCodePointUnchecked(cp, &buf);
                    if (n > 0) f.prefix_byte = buf[0];
                }
            }
        }
    }
    return f;
}

/// A compiled program: either a literal program or the shared NFA program, plus the
/// search-time `Filter` distilled from analysis (meaningful only on the NFA arm).
/// The active arm is the analysis-time choice; the per-search engine choice (pikevm
/// vs backtrack) does not change the program, only how it is executed.
///
/// @stable-since: v0.1.0
pub const Program = struct {
    inner: union(enum) {
        literal: literal.Program,
        nfa: nfa.Program,
    },
    /// Sound prefilter facts for the NFA arm; default (all-permissive) for literal.
    filter: Filter = .{},
    /// True when the program contains `\X` (grapheme). Such a program is matched
    /// only by the backtracker (variable-width consume) — `runNfa` routes it there.
    has_grapheme: bool = false,
    /// The byte lazy DFA program, built **only at runtime** (`buildAlloc`) when
    /// `byte_engine == .enabled` and the pattern is DFA-eligible (`dfa.supports`).
    /// Non-null ⇒ `isMatch`/`search` use the DFA for the span scan; `searchCaptures`
    /// always uses the Pike VM. Null on the comptime path and for `\b`/`\X`/anchored
    /// patterns (which stay on the code-point engines, returning the same spans).
    ///
    /// @stable-since: v0.3.0
    dfa_prog: ?dfa.Program = null,
};

/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, opts: Options) BuildError!Program {
    if (literal.supports(h)) {
        return .{ .inner = .{ .literal = try literal.buildAlloc(gpa, h, .{}) } };
    }
    if (!nfa.supports(h)) return error.Unsupported;
    var program = Program{
        .inner = .{ .nfa = try nfa.buildAlloc(gpa, h) },
        .filter = filterFromAnalysis(h),
        .has_grapheme = h.analysis.has_grapheme,
    };
    errdefer nfa.freeProgram(gpa, &program.inner.nfa);
    // Opt-in byte lazy DFA span arm (runtime-only). Best-effort: a pattern the DFA
    // cannot run (`error.Unsupported`) just leaves `dfa_prog` null and the NFA arm
    // handles it. OOM propagates.
    if (opts.byte_engine == .enabled and dfa.supports(h)) {
        program.dfa_prog = dfa.buildAlloc(gpa, h, .{}) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => null,
        };
    }
    return program;
}

/// @stable-since: v0.1.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    if (comptime literal.supports(h)) {
        return .{ .inner = .{ .literal = literal.buildComptime(h, .{}) } };
    }
    // No DFA at comptime (its cache mutates at match time): the comptime path stays
    // on the NFA program. `dfa_prog` defaults to null.
    return .{
        .inner = .{ .nfa = nfa.buildComptime(h) },
        .filter = filterFromAnalysis(h),
        .has_grapheme = h.analysis.has_grapheme,
    };
}

/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    if (program.dfa_prog) |*d| dfa.freeProgram(gpa, d);
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
///
/// @stable-since: v0.1.0
pub const Scratch = struct {
    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = Cell;

    const NfaScratch = struct { pike: pikevm.Scratch, back: backtrack.Scratch };

    inner: union(enum) {
        literal: literal.Scratch,
        nfa: NfaScratch,
    },
    /// The byte lazy DFA's per-search cache, present only on a heap `Scratch` (`init`)
    /// built for a program that has a `dfa_prog`. Null on a buffer/comptime `Scratch`
    /// (`initBuffer`) — that path falls back to the NFA arm for the span scan.
    ///
    /// @stable-since: v0.3.0
    dfa_sc: ?dfa.Scratch = null,
    /// Sticky: set once the DFA raised `gave_up` (its bounded cache thrashed on this
    /// program under `on_full = .give_up`). Subsequent span ops then route to the NFA
    /// arm instead. Not cleared by `reset` — the signal is about the program, not one
    /// search.
    ///
    /// @stable-since: v0.3.0
    dfa_disabled: bool = false,

    /// @stable-since: v0.1.0
    pub fn bufferLen(program: *const Program) usize {
        return switch (program.inner) {
            .literal => 0,
            .nfa => |*p| pikevm.Scratch.bufferLen(p) + backtrack.Scratch.bufferLen(p),
        };
    }

    /// @stable-since: v0.1.0
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

    /// @stable-since: v0.1.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        switch (program.inner) {
            .literal => return .{ .inner = .{ .literal = .{} } },
            .nfa => |*p| {
                var pike = try pikevm.Scratch.init(gpa, p);
                errdefer pike.deinit(gpa);
                var back = try backtrack.Scratch.init(gpa, p);
                errdefer back.deinit(gpa);
                var dfa_sc: ?dfa.Scratch = null;
                if (program.dfa_prog) |*dp| dfa_sc = try dfa.Scratch.init(gpa, dp);
                return .{ .inner = .{ .nfa = .{ .pike = pike, .back = back } }, .dfa_sc = dfa_sc };
            },
        }
    }

    /// @stable-since: v0.1.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        if (self.dfa_sc) |*d| d.deinit(gpa);
        switch (self.inner) {
            .literal => |*s| s.deinit(gpa),
            .nfa => |*s| {
                s.pike.deinit(gpa);
                s.back.deinit(gpa);
            },
        }
    }

    /// @stable-since: v0.1.0
    pub fn reset(self: *Scratch) void {
        if (self.dfa_sc) |*d| d.reset();
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

/// First byte offset `≥ start` at which `byte` appears in `input`, or null. Runtime
/// uses `std.mem.indexOfScalarPos` (SIMD memchr); comptime uses a plain scan (the
/// project keeps `@Vector` out of const-eval). The prefilter's start-skip primitive.
fn memchrFrom(input: []const u8, start: usize, byte: u8) ?usize {
    if (@inComptime()) {
        var i = start;
        while (i < input.len) : (i += 1) if (input[i] == byte) return i;
        return null;
    }
    return std.mem.indexOfScalarPos(u8, input, start, byte);
}

// ── NFA-arm execution: dispatch + analysis-driven prefilter ───────────────────────

/// Confirm a match starting exactly at `at` (anchored). Uses the **Pike VM**: its
/// per-search reset is O(program), so it stays cheap when the prefilter probes many
/// candidate positions (the backtracker resets an O(program × input) visited set).
/// Fills `slots` when provided; an anchored run that finds nothing leaves `slots`
/// untouched, so repeated failed confirms never dirty a caller's buffer.
fn confirmAt(p: *const nfa.Program, s: *Scratch.NfaScratch, input: []const u8, at: usize, slots: ?[]?usize) ?Match {
    const o = SearchOptions{ .start = at, .anchored = true };
    if (slots) |sl| return pikevm.searchCaptures(p, &s.pike, input, sl, o);
    return pikevm.search(p, &s.pike, input, o);
}

/// Ordinary per-input dispatch over the whole (unfiltered) range: backtrack for a
/// small input that fits, else the Pike VM. Both execute the same program with
/// identical leftmost-first semantics, so the choice is invisible.
fn dispatch(p: *const nfa.Program, s: *Scratch.NfaScratch, input: []const u8, opts: SearchOptions, slots: ?[]?usize) ?Match {
    if (preferBacktrack(p, &s.back, input)) {
        if (slots) |sl| return backtrack.searchCaptures(p, &s.back, input, sl, opts);
        return backtrack.search(p, &s.back, input, opts);
    }
    if (slots) |sl| return pikevm.searchCaptures(p, &s.pike, input, sl, opts);
    return pikevm.search(p, &s.pike, input, opts);
}

/// The NFA arm's single search core, shared by `isMatch`/`search`/`searchCaptures`
/// (`slots` non-null ⇒ capture). Applies the sound analysis prefilter, then either
/// confirms at filtered positions or falls back to the plain dispatch. Returns the
/// leftmost match (filling `slots` on success).
fn runNfa(p: *const nfa.Program, filter: Filter, s: *Scratch.NfaScratch, input: []const u8, opts: SearchOptions, slots: ?[]?usize, has_grapheme: bool) ?Match {
    if (opts.start > input.len) return null;
    // Length gate: too few bytes left from here for even the shortest match.
    if (input.len - opts.start < filter.min_bytes) return null;

    // `\X` (grapheme) consumes a variable number of code points per step, which the
    // Pike VM (one code point per step) cannot do. Route the whole search to the
    // backtracker — it scans unanchored itself, honouring `opts`. This deliberately
    // skips the Pike-VM-based anchored-confirm prefilter, which also assumes one
    // code point per step.
    if (has_grapheme) {
        if (slots) |sl| return backtrack.searchCaptures(p, &s.back, input, sl, opts);
        return backtrack.search(p, &s.back, input, opts);
    }

    // Caller pinned the start: one anchored attempt, no scan, no prefilter.
    if (opts.anchored) return dispatch(p, s, input, opts, slots);

    // `^…`/`\A…`: a match can only begin at offset 0. Past it, none can; at 0, an
    // anchored run avoids scanning the whole input leftward.
    if (filter.anchored_start) {
        if (opts.start != 0) return null;
        return confirmAt(p, s, input, 0, slots);
    }

    // Leading-literal memchr prefilter: every match begins with `prefix_byte`, so
    // jump to each occurrence and confirm anchored there. Leftmost by construction —
    // positions are visited left→right and the first confirmed match wins. A
    // false-positive byte (prefix's first byte without the full match) just fails the
    // confirm; a real match's start is always one of these positions, so none is missed.
    if (filter.prefix_byte) |fb| {
        var pos = opts.start;
        while (memchrFrom(input, pos, fb)) |hit| {
            if (input.len - hit < filter.min_bytes) return null; // no later hit can fit either
            if (confirmAt(p, s, input, hit, slots)) |m| return m;
            pos = hit + 1;
        }
        return null;
    }

    // No usable filter: scan the whole range with the per-input engine choice.
    return dispatch(p, s, input, opts, slots);
}

// ── Byte-DFA arm: span ops with the same prefilter the NFA arm uses ────────────────

/// Confirm/locate a match anchored at `at` via the DFA. `match_only` selects the op
/// (a non-null `Match` with `[at, at)` is a true/false token for `isMatch`).
fn dfaConfirmAt(dp: *const dfa.Program, d: *dfa.Scratch, input: []const u8, at: usize, match_only: bool) ?Match {
    const o = SearchOptions{ .start = at, .anchored = true };
    if (match_only) return if (dfa.isMatch(dp, d, input, o)) Match{ .start = at, .end = at } else null;
    return dfa.search(dp, d, input, o);
}

/// The byte-DFA arm's span search. It applies the **same sound prefilter as `runNfa`**
/// — the `min_bytes` length gate, the `anchored_start` short-circuit, and the
/// leading-literal `memchr` start-skip — before running the DFA, so opting the DFA in
/// is never slower than the default on prefix-literal / sparse-hit patterns. With no
/// usable filter it runs one DFA pass (one-pass O(n) for `isMatch`, anchored-restart
/// for `find`). Captures never come here — they always use the Pike VM (`runNfa`).
fn runByteDfa(dp: *const dfa.Program, filter: Filter, d: *dfa.Scratch, input: []const u8, opts: SearchOptions, match_only: bool) ?Match {
    if (opts.start > input.len) return null;
    if (input.len - opts.start < filter.min_bytes) return null; // length gate
    if (opts.anchored) return dfaConfirmAt(dp, d, input, opts.start, match_only);
    if (filter.anchored_start) {
        if (opts.start != 0) return null;
        return dfaConfirmAt(dp, d, input, 0, match_only);
    }
    if (filter.prefix_byte) |fb| {
        var pos = opts.start;
        while (memchrFrom(input, pos, fb)) |hit| {
            if (input.len - hit < filter.min_bytes) return null;
            if (dfaConfirmAt(dp, d, input, hit, match_only)) |m| return m;
            pos = hit + 1;
        }
        return null;
    }
    if (match_only)
        return if (dfa.isMatch(dp, d, input, opts)) Match{ .start = opts.start, .end = opts.start } else null;
    return dfa.search(dp, d, input, opts);
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.1.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    switch (program.inner) {
        .literal => |*p| return literal.isMatch(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            // Byte lazy DFA span scan (prefiltered) when built and not disabled — same
            // result the NFA arm gives, faster on a long scan.
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const r = runByteDfa(dp, program.filter, d, input, opts, true);
                    if (d.gave_up) scratch.dfa_disabled = true; // cache thrashed → stop using it
                    return r != null;
                };
            }
            return runNfa(p, program.filter, &scratch.inner.nfa, input, opts, null, program.has_grapheme) != null;
        },
    }
}

/// @stable-since: v0.1.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    switch (program.inner) {
        .literal => |*p| return literal.search(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const r = runByteDfa(dp, program.filter, d, input, opts, false);
                    if (d.gave_up) scratch.dfa_disabled = true;
                    return r;
                };
            }
            return runNfa(p, program.filter, &scratch.inner.nfa, input, opts, null, program.has_grapheme);
        },
    }
}

/// @stable-since: v0.1.0
pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots: []?usize, opts: SearchOptions) ?Match {
    switch (program.inner) {
        .literal => |*p| return literal.searchCaptures(p, &scratch.inner.literal, input, slots, opts),
        .nfa => |*p| return runNfa(p, program.filter, &scratch.inner.nfa, input, opts, slots, program.has_grapheme),
    }
}

/// Which way a built program routes (for diagnostics/tests): `"literal"`, `"nfa"`, or
/// `"nfa+dfa"`. The last names what the program actually *is* — an NFA program (it backs
/// captures, `\b`, and the buffer/comptime scratch path) **with** a byte-DFA span arm
/// the heap-scratch span ops (`isMatch`/`find`) use. It is deliberately not `"dfa"`:
/// captures never touch the DFA, and a buffer `Scratch` (no `dfa_sc`) runs the NFA arm.
///
/// @stable-since: v0.1.0
pub fn route(program: *const Program) []const u8 {
    if (program.dfa_prog != null) return "nfa+dfa";
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

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    try testing.expect(re.find(input) == null);
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
    // A pattern with a leading *class* (no fixed leading literal) bypasses the memchr
    // prefilter and exercises the per-input dispatch directly: an input longer than
    // BACKTRACK_MAX_INPUT forces the Pike VM; a short one uses the backtracker. Both
    // must find the same thing. Dot filler is not in `[a-z]`, so the leftmost match
    // starts cleanly at the embedded run rather than absorbing the filler.
    var re = try Compiled.init("[a-z]+!");
    defer re.deinit();
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, BACKTRACK_MAX_INPUT + 100);
    defer gpa.free(big);
    @memset(big, '.');
    @memcpy(big[50 .. 50 + 4], "abc!");
    const m_big = re.find(big).?; // pikevm route (len > threshold)
    try testing.expectEqualStrings("abc!", m_big.slice(big));

    const m_small = re.find("..abc!..").?; // backtrack route (len < threshold)
    try testing.expectEqualStrings("abc!", m_small.slice("..abc!.."));
}

test "auto: prefix-literal memchr prefilter finds the leftmost match" {
    // Every match of `foo\d` begins with the literal "foo" → analysis yields a
    // prefix byte 'f' that drives the memchr skip. A false-positive 'f' ("food",
    // no trailing digit) fails the anchored confirm and the scan moves on.
    try expectFind("foo\\d", "food foo5", "foo5");
    try expectFind("foo\\d+", "xx foo123 yy", "foo123");
    try expectNoMatch("foo\\d", "no digits here foo!");
    // unicode prefix: 'é' is multi-byte; its first byte still seeds the memchr.
    try expectFind("été\\d", "l'été9", "été9");
}

test "auto: prefilter is correct under findAll / count (multiple matches)" {
    var re = try Compiled.init("a\\d"); // prefix 'a'
    defer re.deinit();
    const input = "a1 xa2 yy a3!";
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, input, .{}));
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("a1", it.next().?.slice(input));
    try testing.expectEqualStrings("a2", it.next().?.slice(input));
    try testing.expectEqualStrings("a3", it.next().?.slice(input));
    try testing.expect(it.next() == null);
}

test "auto: anchored_start short-circuit only matches at offset 0" {
    try expectFind("^\\d+", "12 ab", "12");
    try expectNoMatch("^\\d+", "ab 12"); // a match must begin at 0
    // findAll over a start-anchored pattern yields exactly one match.
    var re = try Compiled.init("^\\w+");
    defer re.deinit();
    try testing.expectEqual(@as(usize, 1), E.count(&re.program, &re.scratch, "hello world", .{}));
}

test "auto: length gate rejects too-short input" {
    try expectNoMatch("\\d{5}", "123"); // needs ≥ 5 bytes
    try expectFind("\\d{5}", "x 67890", "67890");
}

test "auto: prefilter preserves captures" {
    var re = try Compiled.init("(foo)(\\d+)"); // prefix 'f', with groups
    defer re.deinit();
    var slots: [6]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "a food foo42 b", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("foo42", c.match().slice("a food foo42 b"));
    try testing.expectEqualStrings("foo", c.groupSlice(1).?);
    try testing.expectEqualStrings("42", c.groupSlice(2).?);
}

test "auto: prefilter path runs at COMPTIME (memchr + anchored confirm)" {
    const got = comptime blk: {
        @setEvalBranchQuota(3_000_000);
        const a = compile.compile("foo\\d+");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var buf: [Scratch.bufferLen(&program)]Cell = undefined;
        var sc = Scratch.initBuffer(&buf, &program) catch unreachable;
        const input = "skip food then foo777 end";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no match");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("foo777", got);
}

test "auto: grapheme pattern (\\X) builds and matches whole clusters" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "\\X", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);
    try testing.expect(program.has_grapheme); // routed to the backtracker
    var sc = try Scratch.init(gpa, &program);
    defer sc.deinit(gpa);
    // "e" + combining acute U+0301 is ONE extended grapheme cluster (3 bytes).
    const m = search(&program, &sc, "e\u{0301}z", .{}).?;
    try testing.expectEqual(@as(usize, 0), m.start);
    try testing.expectEqual(@as(usize, 3), m.end);
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
