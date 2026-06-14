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
const edfa = @import("edfa.zig");
const onepass = @import("onepass.zig");
const byte = @import("../byte.zig");

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

/// Cheap, **measure-free** HIR check for whether `auto` should build the eager DFA span arm
/// **at comptime** (the CTRE-lane). It must be cheap because it gates a `comptime` call: the
/// byte-lowering size probes (`dfa.supports`/`byteWorthLowering`, which run the count pass and
/// `enumerate` a class's UTF-8 sequences) are *expensive in the const evaluator* — running
/// them on a big Unicode class (`\w+@\w+`) at compile time exhausts the comptime allocator.
/// So this short-circuits the big cases by inspecting only HIR node/range/literal counts (no
/// byte lowering, no `enumerate`) and excluding `.` (`any`, which enumerates the whole scalar
/// space), `\X` (grapheme), and `\b`/`\B`. A pattern that passes is tiny enough that the
/// subsequent `dfa.supports` + `edfa.buildComptime` are cheap and can never overflow
/// `edfa.max_states`. Runtime has no such gate — `buildAlloc` pays the determinization once
/// for any DFA-eligible pattern (the throughput path); this comptime lane is the ro_data
/// convenience for small ASCII classes / alternations / counted reps.
///
/// @stable-since: v0.3.0
fn tinyForComptimeEdfa(h: hir.Hir) bool {
    if (h.analysis.has_grapheme) return false; // `\X`
    if (h.nodes.len > 24 or h.ranges.len > 8 or h.literals.len > 32) return false;
    for (h.nodes) |n| switch (n.tag) {
        .any => return false, // `.` lowers to the whole-scalar-space byte automaton — not tiny
        .anchor => switch (n.data.anchor.kind) {
            .word_boundary, .not_word_boundary => return false, // `\b`/`\B` — not byte-DFA-able
            else => {},
        },
        else => {},
    };
    return true;
}

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
    /// Whether to distil and apply the sound analysis prefilter (length gate,
    /// leading-literal `memchr` start-skip, rarest-required-byte fast-reject). On by
    /// default; `false` builds an all-permissive filter so the engine scans without
    /// probing. Results-invariant.
    ///
    /// @stable-since: v0.3.0
    prefilter: bool = true,

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
    /// The **rarest** byte (by `byteRarity`) of `analysis.required_bytes` — a byte that
    /// appears in *every* match — or null when nothing is unconditionally required.
    /// Drives a sound **fast-reject**: if it does not occur in the remaining input, no
    /// match exists there, so the search returns immediately (the big win for a
    /// prefix-less interior-literal pattern like `\w+@\w+` on input with no `@`). Picked
    /// rarest so the `memchr` is as selective as possible.
    rare_byte: ?u8 = null,
};

/// A coarse "commonness" score for a byte: **higher = more common** in typical text, so
/// the prefilter picks the lowest-scoring required byte as the most selective `memchr`
/// target. Punctuation/symbols (often the discriminating byte of a pattern — `@`, `.`,
/// `-`) score low; spaces and lowercase letters score high.
fn byteRarity(b: u8) u8 {
    return switch (b) {
        ' ', '\t', '\n', '\r' => 100,
        'a'...'z' => 90,
        0x80...0xFF => 60, // UTF-8 lead/continuation — common in Unicode text
        'A'...'Z' => 50,
        '0'...'9' => 45,
        else => 10, // ASCII punctuation / control — usually the rare, discriminating byte
    };
}

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
        // Rarest required byte for the fast-reject (only when there is no fixed prefix
        // to memchr — with a prefix the start-skip already implies the byte is present).
        if (f.prefix_byte == null and !an.required_bytes.isEmpty()) {
            var best: ?u8 = null;
            var best_score: u8 = 255;
            var b: u16 = 0;
            while (b < 256) : (b += 1) {
                const by: u8 = @intCast(b);
                if (an.required_bytes.has(by) and byteRarity(by) < best_score) {
                    best = by;
                    best_score = byteRarity(by);
                }
            }
            f.rare_byte = best;
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
    /// The **eager** DFA program — the preferred span arm (a fully frozen byte DFA;
    /// ~5–10× the lazy DFA, stateless, builds at comptime **and** runtime). Non-null ⇒
    /// `isMatch`/`search` use it for the span scan and `searchCaptures` hands its span to
    /// the Pike VM for groups. Built when DFA-eligible (`dfa.supports`) and within
    /// `edfa.max_states`; a pattern whose DFA overflows those bounds falls back to
    /// `dfa_prog` (runtime) or the NFA arm. Results-invariant (`conformance.zig` pins it).
    ///
    /// @stable-since: v0.3.0
    edfa_prog: ?edfa.Program = null,
    /// The byte **lazy** DFA program — the fallback span arm, built **only at runtime**
    /// (`buildAlloc`) when the pattern is DFA-eligible but its eager DFA overflows
    /// `edfa`'s fixed bounds (a big Unicode class repeated many times). Unbounded (its
    /// cache grows on demand). Non-null ⇒ used for the span scan when `edfa_prog` is null;
    /// `searchCaptures` hands its span to the Pike VM. Null on the comptime path and for
    /// `\b`/`\X`/`$`/line-anchor patterns (which stay on the code-point engines).
    ///
    /// @stable-since: v0.3.0
    dfa_prog: ?dfa.Program = null,
    /// The **one-pass** capture table — a linear-time, single-thread capture fast path,
    /// built (at runtime) for a capture-bearing pattern that is provably one-pass
    /// (`(\d{4})-(\d{2})-(\d{2})`, `(\w+)@(\w+)`). Non-null ⇒ `searchCaptures` fills the
    /// slots with it (anchored at the span a DFA arm located) instead of the Pike VM — same
    /// slots, no thread set. Null for a non-one-pass pattern, a capture-less pattern, or the
    /// comptime path (comptime captures stay on the Pike VM); such patterns fall back to the
    /// Pike VM capture fill, so this is purely an accelerator. Results-invariant
    /// (`conformance.zig` pins its slots to the Pike VM's).
    ///
    /// @stable-since: v0.4.0
    onepass_prog: ?onepass.Program = null,
};

/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, opts: Options) BuildError!Program {
    if (literal.supports(h)) {
        return .{ .inner = .{ .literal = try literal.buildAlloc(gpa, h, .{}) } };
    }
    if (!nfa.supports(h)) return error.Unsupported;
    var program = Program{
        .inner = .{ .nfa = try nfa.buildAlloc(gpa, h) },
        .filter = if (opts.prefilter) filterFromAnalysis(h) else .{},
        .has_grapheme = h.analysis.has_grapheme,
    };
    errdefer nfa.freeProgram(gpa, &program.inner.nfa);
    // Byte DFA span arm, built by default (`byte_engine != .disabled`). The DFA serves
    // `isMatch`/`find` and feeds the capture handoff; the bench shows it is **5–10× the
    // code-point Pike VM** on class scans (and never slower), so building it by default is a
    // strict throughput win, and it is **results-invariant** (`conformance.zig` pins its
    // span and captures to the Pike VM's). Two-tier: prefer the **eager** DFA (fully frozen,
    // stateless, fastest); fall back to the **lazy** DFA when the eager one overflows its
    // fixed bounds (a big Unicode class repeated many times). `.disabled` opts back to the
    // compact NFA-only program (minimal memory, no determinization). `byteWorthLowering`
    // additionally declines a pathologically large byte automaton, keeping it on the NFA.
    if (opts.byte_engine != .disabled and edfa.supports(h) and byte.byteWorthLowering(h)) {
        if (edfa.buildAlloc(gpa, h, .{})) |ep| {
            program.edfa_prog = ep;
            // A `\b`/`\B` program's EAGER DFA does only the ASCII boundary; build the LAZY DFA too
            // as the **non-ASCII** arm — it evaluates Unicode word boundaries via the decode-hybrid.
            // `auto` then routes a `\b` program's non-ASCII input here instead of the Pike VM
            // (`edfaArm` returns null on non-ASCII, and the lazy arm below picks it up). Built only
            // when the eager built (a non-prone, bounded `\b`); a heap `Scratch` gets its `dfa_sc`.
            if (h.analysis.has_word_boundary and dfa.supports(h)) {
                // Optional accelerator arm — any build failure (incl. OOM) just degrades non-ASCII
                // `\b` to the Pike VM (correct), so swallow it rather than leak the eager program.
                program.dfa_prog = dfa.buildAlloc(gpa, h, .{}) catch null;
            }
        } else |e| switch (e) {
            error.OutOfMemory => return e,
            else => { // eager DFA declined (exceeded its fixed bounds) — fall back to the lazy
                // DFA when IT can run the pattern. The lazy DFA covers anchored-end `$`/`\z`
                // (reverse-from-end), so a too-big trailing-`$` pattern stays on the DFA arm; a
                // mixed `$`, `\b`/`\X`, a *prone* `(?m)` line pattern, or a too-big `(?m)` (the
                // lazy DFA declines line anchors) lands on the NFA arm.
                if (dfa.supports(h)) {
                    program.dfa_prog = dfa.buildAlloc(gpa, h, .{}) catch |e2| switch (e2) {
                        error.OutOfMemory => return e2,
                        else => null,
                    };
                }
            },
        }
    }
    // One-pass capture accelerator: for a capture-bearing pattern that is provably one-pass,
    // build the single-thread capture table. `searchCaptures` then fills slots with it
    // (anchored at the DFA-located span) instead of the Pike VM — same slots, no thread set.
    // A non-one-pass / assertion-bearing pattern is declined here (left null) and keeps using
    // the Pike VM capture fill, so this never changes a result, only the capture cost.
    if (h.capture_count > 0) {
        if (onepass.buildAlloc(gpa, h, .{})) |op| {
            program.onepass_prog = op;
        } else |e| switch (e) {
            error.OutOfMemory => return e,
            else => {}, // not one-pass → Pike VM fills captures (no change in result)
        }
    }
    return program;
}

/// @stable-since: v0.1.0
pub fn buildComptime(comptime h: hir.Hir, comptime opts: Options) Program {
    if (comptime literal.supports(h)) {
        return .{ .inner = .{ .literal = literal.buildComptime(h, .{}) } };
    }
    var program = Program{
        .inner = .{ .nfa = nfa.buildComptime(h) },
        .filter = if (opts.prefilter) filterFromAnalysis(h) else .{},
        .has_grapheme = h.analysis.has_grapheme,
    };
    // Eager DFA span arm at comptime — the CTRE-lane fast path (a frozen `ro_data` table,
    // ~5–10× the code-point engines). The **lazy** DFA can't run at comptime (its cache
    // mutates while matching), but the eager one freezes everything at build, so it can.
    // `searchCaptures` still hands the span to the Pike VM (the comptime buffer scratch
    // backs it). Results-invariant.
    //
    // Gated on a *measure-free* tininess check FIRST (`tinyForComptimeEdfa`), so a big Unicode
    // class short-circuits before any byte-lowering size probe runs in the const evaluator
    // (those `enumerate` the class and exhaust the comptime allocator). Only a tiny, provably
    // bounded pattern reaches `dfa.supports` + `edfa.buildComptime` — both cheap at that size,
    // and unable to overflow `edfa.max_states`, so `buildComptime`'s `@compileError` branches
    // are unreachable here. Big patterns still get the eager DFA at **runtime**.
    if (opts.byte_engine != .disabled and tinyForComptimeEdfa(h) and edfa.supports(h)) {
        program.edfa_prog = edfa.buildComptime(h, .{});
    }
    return program;
}

/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    if (program.edfa_prog) |*e| edfa.freeProgram(gpa, e);
    if (program.dfa_prog) |*d| dfa.freeProgram(gpa, d);
    if (program.onepass_prog) |*op| onepass.freeProgram(gpa, op);
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
    /// ReDoS observable: the number of **per-occurrence prefilter confirms** the eager-DFA
    /// arm (`runEdfa`) has performed on this scratch. The prefilter's leading-literal
    /// `memchr` start-skip confirms anchored at each prefix-byte occurrence; for a
    /// `prone`/`end_anchored` program that confirm can scan an unbounded run, so doing it
    /// per occurrence is Θ(n²) — the fix routes those programs to the DFA's O(n) native
    /// find instead, and this counter therefore stays **0** for them. A non-zero value on a
    /// `prone`/`end_anchored` program is exactly the quadratic regression; `engine/redos.zig`
    /// asserts it is 0 (a revert-failing guard). Bounded by the prefix-byte occurrence count
    /// for the fast-confirm case (`foo\d+`). Observational only — never affects a result, never
    /// read by matching. Accumulates across searches on the scratch; `reset` zeroes it.
    ///
    /// @stable-since: v0.3.1
    confirm_probes: u64 = 0,

    /// Cached ASCII-ness of the current input, for `\b`/`\B` (word-boundary) programs. The byte DFA
    /// evaluates `\b` as an **ASCII** word boundary (exact for ASCII text); for **non-ASCII** input
    /// `auto` must instead use the code-point Pike VM (correct **Unicode** word boundaries). Scanning
    /// the input for non-ASCII bytes is O(n), so it is cached here keyed on the input slice
    /// (`ptr`+`len`) — a `count`/`findAll` over one input pays the scan **once**, not per match.
    /// `reset` clears it; a caller reusing one `Scratch` across DIFFERENT inputs must `reset` between
    /// them (the conventional contract). Dormant (never consulted) for non-`\b` programs.
    ///
    /// @stable-since: v0.4.0
    wb_input_ptr: ?[*]const u8 = null,
    wb_input_len: usize = 0,
    wb_all_ascii: bool = false,

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
        self.confirm_probes = 0; // the ReDoS observable is per-reuse
        self.wb_input_ptr = null; // invalidate the input-ASCII cache (a new search may use a new input)
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
fn memchrFrom(input: []const u8, start: usize, b: u8) ?usize {
    if (@inComptime()) {
        var i = start;
        while (i < input.len) : (i += 1) if (input[i] == b) return i;
        return null;
    }
    return std.mem.indexOfScalarPos(u8, input, start, b);
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

/// Fill `slots` for the match whose span a DFA arm already located, anchored at its start.
/// Prefers the **one-pass** table (a single deterministic thread — no thread set) when the
/// pattern built one; otherwise the Pike VM. Both are anchored at the same span start and
/// are leftmost-first, so they fill identical slots (`conformance.zig` pins it) — this only
/// changes the capture cost, never the result.
fn fillCapturesAnchored(program: *const Program, s: *Scratch.NfaScratch, p: *const nfa.Program, input: []const u8, slots: []?usize, m: Match, opts: SearchOptions) ?Match {
    var o = opts;
    o.start = m.start;
    o.anchored = true;
    if (program.onepass_prog) |*op| {
        var os = onepass.Scratch{};
        return onepass.searchCaptures(op, &os, input, slots, o);
    }
    return pikevm.searchCaptures(p, &s.pike, input, slots, o);
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
    //
    // NOTE (resource bound): this path is **not** length-capped like the non-grapheme
    // dispatch (no `BACKTRACK_MAX_INPUT` gate) — backtrack is the only `\X`-capable
    // backend, so there is nowhere else to route. The backtracker recurses with depth
    // ∝ matched length (see backtrack.zig → "Resource bounds"), so a *large quantified*
    // `\X` input (e.g. `\X+` over many graphemes) can overflow the stack. Documented
    // constraint; the fix is an iterative backtracker. Bounded/typical `\X` use is fine.
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

    // Leading-literal memchr start-skip: every match begins with `prefix_byte`, so no match
    // begins before its first occurrence — skip straight to it. We deliberately do NOT confirm
    // at *each* occurrence: a per-occurrence anchored confirm is O(match-attempt), and on a
    // begin-but-don't-complete pattern with a dense prefix byte (`\ba+b` on `aaaa…a!`) that
    // makes the loop **Θ(n²)**. The Pike VM's unanchored `dispatch` is a single linear
    // O(input×program) pass, so one leading skip + dispatch stays leftmost-first AND linear.
    // (The eager-DFA arm keeps the per-occurrence memchr-jump where its `prone`/`end_anchored`
    // flags prove confirms fail fast; the NFA arm has no such flag, so it always takes the
    // linear unanchored scan.)
    var o = opts;
    if (filter.prefix_byte) |fb| {
        o.start = memchrFrom(input, o.start, fb) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.rare_byte) |rb| {
        // Rarest-required-byte fast-reject: `rare_byte` appears in EVERY match, so if it is
        // absent there is no match — return at once. Sound (one-sided). The big win for a
        // prefix-less interior-literal pattern (`\w+@\w+` on text with no `@`).
        if (memchrFrom(input, o.start, rb) == null) return null;
    }

    // Scan the (possibly skipped-into) range with the per-input engine choice.
    return dispatch(p, s, input, o, slots);
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
    // Leading-literal start-skip (single memchr, then the lazy DFA's own O(input) reverse-DFA
    // find) — NOT a per-occurrence anchored-confirm loop, which would be Θ(n²) on a
    // begin-but-don't-complete dense-prefix input (same hazard as `runEdfa`). The lazy DFA's
    // native `find` is already O(input) (reverse DFA; `has_text_start` short-circuits via
    // `anchored_start` above), so one leading skip + native find is leftmost-first and linear.
    var o = opts;
    if (filter.prefix_byte) |fb| {
        o.start = memchrFrom(input, o.start, fb) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.rare_byte) |rb| {
        // Rarest-required-byte fast-reject (sound; see `runNfa`).
        if (memchrFrom(input, o.start, rb) == null) return null;
    }
    if (match_only)
        return if (dfa.isMatch(dp, d, input, o)) Match{ .start = opts.start, .end = opts.start } else null;
    return dfa.search(dp, d, input, o);
}

// ── Eager-DFA arm: span ops with the same prefilter, but stateless (no scratch) ────

/// Confirm/locate a match anchored at `at` via the **eager** DFA. The eager DFA is
/// stateless, so a throwaway `edfa.Scratch{}` is all it needs. `match_only` selects the op.
fn edfaConfirmAt(ep: *const edfa.Program, input: []const u8, at: usize, match_only: bool) ?Match {
    var es = edfa.Scratch{};
    const o = SearchOptions{ .start = at, .anchored = true };
    if (match_only) return if (edfa.isMatch(ep, &es, input, o)) Match{ .start = at, .end = at } else null;
    return edfa.search(ep, &es, input, o);
}

/// The eager-DFA arm's span search — the same sound prefilter as `runNfa`/`runByteDfa`
/// (length gate, `anchored_start` short-circuit, leading-literal `memchr` start-skip,
/// rarest-required-byte fast-reject) in front of the frozen-table walk. The eager DFA is
/// stateless; the only state is `probes`, the ReDoS observable (`Scratch.confirm_probes`)
/// incremented per per-occurrence confirm. Captures never come here — they always use the Pike VM.
fn runEdfa(ep: *const edfa.Program, filter: Filter, input: []const u8, opts: SearchOptions, match_only: bool, probes: *u64) ?Match {
    if (opts.start > input.len) return null;
    if (input.len - opts.start < filter.min_bytes) return null; // length gate
    if (opts.anchored) return edfaConfirmAt(ep, input, opts.start, match_only);
    if (filter.anchored_start) {
        if (opts.start != 0) return null;
        return edfaConfirmAt(ep, input, 0, match_only);
    }
    var o = opts;
    if (filter.prefix_byte) |fb| {
        // The leading-literal `memchr` start-skip confirms anchored at each prefix-byte
        // occurrence. Each confirm is O(match-attempt); when a confirm can walk a long run before
        // failing it blows up on a dense-prefix begin-but-don't-complete input (`aaaa…a!`: a
        // leading byte at every position, each confirm re-walking the run). `ep.prone` flags both
        // hazardous shapes — a non-accepting *cycle* (`(x+x+)+y`, unbounded ⇒ Θ(n²)) AND a long
        // *bounded* prefix (`a{4000}b`, Θ(n·k) with large k) — and `end_anchored` (`$`) flags the
        // run-to-end shape (`(a+)+$`). For all of those the eager DFA's *native* find is O(input)
        // (reverse two-pass / reverse-from-end), so skip to the first candidate once and hand off —
        // no per-position confirm. The fast-confirm case (`foo\d+`, `a{4}b`: the confirm fails
        // within a few bytes) keeps the memchr-jump loop, its intended speedup. (Both leftmost-first;
        // no match begins before the first prefix byte.)
        if (ep.prone or ep.end_anchored) {
            o.start = memchrFrom(input, o.start, fb) orelse return null;
            if (input.len - o.start < filter.min_bytes) return null;
        } else {
            var pos = o.start;
            while (memchrFrom(input, pos, fb)) |hit| {
                if (input.len - hit < filter.min_bytes) return null;
                probes.* += 1; // ReDoS observable: a per-occurrence confirm (0 for prone/end_anchored)
                if (edfaConfirmAt(ep, input, hit, match_only)) |m| return m;
                pos = hit + 1;
            }
            return null;
        }
    } else if (filter.rare_byte) |rb| {
        if (memchrFrom(input, o.start, rb) == null) return null;
    }
    var es = edfa.Scratch{};
    if (match_only)
        return if (edfa.isMatch(ep, &es, input, o)) Match{ .start = opts.start, .end = opts.start } else null;
    return edfa.search(ep, &es, input, o);
}

// ── Word-boundary ASCII gate: keep non-ASCII `\b` input on the code-point Pike VM ──────

/// Whether `s` is wholly ASCII (no byte ≥ 0x80). Used by the `\b` gate; cached per input.
fn isAsciiSlice(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

/// Whether `input` is wholly ASCII — cached on `scratch` keyed by the input slice so a
/// `count`/`findAll` over one input scans once (see `Scratch.wb_*`).
fn inputAllAscii(scratch: *Scratch, input: []const u8) bool {
    if (scratch.wb_input_ptr == input.ptr and scratch.wb_input_len == input.len) return scratch.wb_all_ascii;
    const a = isAsciiSlice(input);
    scratch.wb_input_ptr = input.ptr;
    scratch.wb_input_len = input.len;
    scratch.wb_all_ascii = a;
    return a;
}

/// The eager-DFA span arm to use for this search, or `null` to fall through to the lazy DFA / NFA
/// arm. The eager DFA evaluates `\b`/`\B` as **ASCII** word boundaries, so a `\b` program's eager
/// DFA is used **only on ASCII input**; non-ASCII input falls through to the code-point Pike VM,
/// which evaluates correct **Unicode** word boundaries. (For a non-`\b` program this is just
/// `program.edfa_prog`.) This is what keeps `auto` correct for **every** input.
///
/// `inline` is load-bearing: this runs **once per `find`**, so a `count`/`findAll` over a
/// dense-match pattern (`\p{L}+`, 100k+ matches) would otherwise pay a function call per match —
/// a measurable regression on the hot span arm. Inlined, the common (non-`\b`) path is just the
/// `program.edfa_prog` test it replaced, plus one already-false `has_word_boundary` load.
inline fn edfaArm(program: *const Program, scratch: *Scratch, input: []const u8) ?*const edfa.Program {
    if (program.edfa_prog) |*ep| {
        if (ep.has_word_boundary and !inputAllAscii(scratch, input)) return null; // Unicode \b → Pike VM
        return ep;
    }
    return null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.1.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    switch (program.inner) {
        .literal => |*p| return literal.isMatch(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            // Eager DFA span scan (prefiltered, stateless) when built and usable — the fastest arm,
            // same result the NFA arm gives. A `\b` program's eager DFA is used only on ASCII input
            // (`edfaArm`); non-ASCII `\b` input falls through to the Pike VM (Unicode boundaries).
            if (edfaArm(program, scratch, input)) |ep| return runEdfa(ep, program.filter, input, opts, true, &scratch.confirm_probes) != null;
            // Lazy DFA fallback (prefiltered) when built and not disabled.
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
            if (edfaArm(program, scratch, input)) |ep| return runEdfa(ep, program.filter, input, opts, false, &scratch.confirm_probes);
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
        .nfa => |*p| {
            // Capture handoff: when the byte DFA arm is available, locate the **span**
            // cheaply with the DFA, then fill captures **anchored at the span start**
            // (`fillCapturesAnchored`: the one-pass table when the pattern built one, else
            // the Pike VM) — bounded to the match — instead of an unanchored scan over the
            // whole input. The DFA span *is* the leftmost-first match (`conformance.zig`
            // pins it), so the anchored fill finds the same match and the same groups, just
            // without re-scanning to locate it. On a sparse match in a long input this turns
            // an O(input) capture search into an O(match) one.
            // Eager DFA span → anchored capture fill (one-pass table when built, else Pike VM).
            // A `\b` program's eager DFA is used only on ASCII input (`edfaArm`); otherwise the whole
            // capture search runs on the Pike VM (Unicode boundaries), via the NFA arm below.
            if (edfaArm(program, scratch, input)) |ep| {
                const m = runEdfa(ep, program.filter, input, opts, false, &scratch.confirm_probes) orelse return null;
                return fillCapturesAnchored(program, &scratch.inner.nfa, p, input, slots, m, opts);
            }
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const span = runByteDfa(dp, program.filter, d, input, opts, false);
                    if (d.gave_up) {
                        scratch.dfa_disabled = true; // cache thrashed → fall through to the NFA arm
                    } else {
                        const m = span orelse return null; // DFA is exact: no span ⇒ no match
                        return fillCapturesAnchored(program, &scratch.inner.nfa, p, input, slots, m, opts);
                    }
                };
            }
            return runNfa(p, program.filter, &scratch.inner.nfa, input, opts, slots, program.has_grapheme);
        },
    }
}

/// Which way a built program routes (for diagnostics/tests): `"literal"`, `"nfa"`,
/// `"nfa+edfa"` (eager DFA span arm — the preferred fast path), or `"nfa+dfa"` (lazy DFA
/// fallback span arm). The `nfa+…` names what the program actually *is* — an NFA program
/// (it backs captures, `\b`, and the buffer/comptime scratch path) **with** a byte-DFA span
/// arm the span ops (`isMatch`/`find`) use. It is deliberately not bare `"dfa"`: captures
/// hand the DFA span to the Pike VM, and a buffer `Scratch` may run the NFA arm.
///
/// @stable-since: v0.1.0
pub fn route(program: *const Program) []const u8 {
    if (program.edfa_prog != null) return "nfa+edfa"; // eager DFA span arm (preferred)
    if (program.dfa_prog != null) return "nfa+dfa"; // lazy DFA fallback span arm
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

test "auto routes literal patterns to the literal backend; DFA-eligible NFA patterns build the eager DFA by default" {
    const gpa = testing.allocator;
    const cases = [_]struct { pat: []const u8, route: []const u8 }{
        .{ .pat = "abc", .route = "literal" }, // pure literal → literal backend
        .{ .pat = "cat|dog", .route = "literal" }, // literal alternation → literal backend
        .{ .pat = "a.c", .route = "nfa+edfa" }, // DFA-eligible & small → eager DFA built by default
        .{ .pat = "(a)(b)", .route = "nfa+edfa" }, // captures don't block the DFA span arm
        .{ .pat = "\\d+", .route = "nfa+edfa" },
        .{ .pat = "^abc$", .route = "nfa+edfa" }, // `^`/`$` now both DFA-eligible (text_start + text_end)
        .{ .pat = "(?m)^\\w+", .route = "nfa+edfa" }, // non-prone (?m)^ → eager DFA (anchored restart w/ line context)
        .{ .pat = "(?m)foo$", .route = "nfa+edfa" }, // non-prone (?m)$ → eager DFA
        .{ .pat = "(?m)\\w+$", .route = "nfa" }, // PRONE (?m)$ → declined to the Pike VM (quadratic-immune)
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
