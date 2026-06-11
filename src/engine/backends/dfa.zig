//! Lazy DFA backend — a caching subset-construction over the **byte** automaton.
//!
//! This is the throughput backend the byte substrate (`engine/byte.zig`) was built
//! for. Where `bytepike` *simulates* the byte Thompson NFA (every live thread stepped
//! per input byte), this backend **determinizes** it on the fly: it groups the NFA
//! states reachable so far into a single DFA state, and advances **one DFA state per
//! input byte** via a cached transition table keyed on the program's `ByteClasses`
//! (the compressed alphabet — typically a handful of classes, even for a large
//! Unicode program). The first time a `(state, class)` edge is taken it is *computed*
//! (epsilon-closure of the successors) and *memoized*; every later visit is a single
//! array lookup. That memo is the "lazy" part, and it lives in the caller-owned
//! `Scratch` (never on the immutable `Program`), so the compiled artifact stays
//! shareable.
//!
//! ## What it is (and is not)
//!
//!   * **Span-only.** `caps.captures = false`: the DFA locates the match **span**
//!     `[start, end)`; it does not fill capture slots. By the division of labour the
//!     engine is designed around, the code-point Pike VM runs over the located span to
//!     fill captures and evaluate Unicode `\b` (the `auto` dispatcher wires this up).
//!     A standalone `Engine(dfa)` therefore offers `isMatch`/`find`/`findAll`/`count`/
//!     `split`, but `captures`/`replaceAll` are a `@compileError` (use `auto` or
//!     `pikevm` for those).
//!   * **Runtime-only.** The transition cache grows during matching (it allocates),
//!     which a const-evaluator cannot do, so this backend defines only `buildAlloc` —
//!     no `buildComptime`, no buffer-`Scratch` convention. The contract allows this
//!     (`verifyBackend` requires *one* build path). For compile-time matching use a
//!     comptime-capable backend (`pikevm`/`auto`); the eager comptime DFA is a
//!     separate, future backend.
//!   * **Leftmost-first**, identical to every other backend. Determinization keeps the
//!     NFA states in **priority order** and **cuts on match** (a `match` in the closure
//!     discards every lower-priority thread), which is exactly the Pike VM's
//!     "cut lower-priority threads on match" rule lifted into the DFA state. So a span
//!     never disagrees with `pikevm` (proven in `conformance.zig`). Greedy vs. lazy
//!     quantifiers fall out of the priority order for free.
//!
//! ## Match start, without a reverse DFA
//!
//! A forward DFA naturally finds a match *end*, not its leftmost *start*. Rather than
//! build a reverse DFA (a separate, future piece), v1 finds the start by an
//! **anchored restart**: it runs the DFA anchored at each candidate start position,
//! left to right, and the first position that reaches an accepting state is the
//! leftmost match — then the last accepting position reached from there is the
//! leftmost-first end. The transition cache is shared across all start positions and
//! all searches on one `Scratch`, so determinization is paid once and amortized. A
//! non-matching start dies in a single `step` (its first byte has no edge → the dead
//! state), so the scan is linear on typical input; the worst case (a pattern that can
//! begin, but not complete, at very many positions) is quadratic — a known v1 limit,
//! superseded later by a prefilter / reverse DFA.
//!
//! ## Invalid UTF-8 — dead-on-invalid, for free
//!
//! The byte lowering only ever emits `byte_range`s that cover well-formed UTF-8
//! (continuation bytes are always `[0x80, 0xBF]`, leads are tight, surrogates are
//! split out), so a malformed byte has **no transition out of any state** — it lands
//! in the dead state. The anchored-restart wrapper then resyncs to the next start, so
//! a match never spans a bad byte. No validity check in the hot loop, no decode.
//!
//! ## Feature gate
//!
//! `supports(hir)` accepts a pattern iff it is byte-lowerable (`byte.byteLowerable`,
//! i.e. no `\X`/`\b`) **and** carries no zero-width assertions (`^`, `$`, `\A`, `\z`,
//! line anchors). Assertions are position-dependent, which would make a closed DFA
//! state position-dependent (defeating the cache); v1 declines them so the closure is
//! purely structural. `auto` keeps those patterns on the code-point engines, exactly
//! as it does for `\b`/`\X` today.

const std = @import("std");

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");
const byte = @import("../byte.zig");

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const ScratchOptions = backend.ScratchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;

/// Sentinel for a `(state, class)` transition that has not been computed yet. The
/// table is initialized to this; the first visit computes and overwrites it.
const UNKNOWN: u32 = std.math.maxInt(u32);

/// The dead / sink state id (the empty set of NFA states). Reserved as state `0` at
/// `Scratch` construction so the hot loop can test `next == DEAD` with no branch on
/// the state's contents. No match is reachable from it; every malformed byte and
/// every non-matching transition lands here.
const DEAD: u32 = 0;

/// Panic message for a true out-of-memory while growing the transition cache. Like
/// the bounded backtracker, the contract's `search`/`isMatch` have no error channel,
/// so an exhausted allocator panics rather than silently returning a wrong answer.
const OOM_PANIC = "ezi_gex dfa: out of memory growing the lazy transition cache; " ++
    "use a larger allocator, lower ScratchOptions.max_bytes (on_full = .reset), or route via `auto`";

/// Allocation is the only failure inside the determinizer; surfaced internally, then
/// turned into a `@panic` at the contract boundary.
const Err = std.mem.Allocator.Error;

// ── Contract surface ──────────────────────────────────────────────────────────────

/// Span-only: the DFA finds `[start, end)`; the code-point engines fill captures and
/// evaluate Unicode `\b` over that span (so `captures`/`replaceAll` are a
/// `@compileError` on `Engine(dfa)` — route them through `auto`/`pikevm`).
///
/// @stable-since: v0.3.0
pub const caps = Caps{ .captures = false, .stateless = false, .grapheme = false };

/// Backend build options. The byte lowering needs nothing beyond the HIR (flags and
/// folding are already applied); the field exists to satisfy the contract shape.
///
/// @stable-since: v0.3.0
pub const Options = struct {};

/// The compiled, immutable DFA program. It is just the byte substrate plus the
/// compressed alphabet the determinizer keys on; the mutable per-search transition
/// cache lives in `Scratch`, never here, so a `Program` stays shareable across
/// threads. Build with `buildAlloc` (runtime-only); free with `freeProgram`.
///
/// @stable-since: v0.3.0
pub const Program = struct {
    /// The byte-grained Thompson NFA the DFA determinizes (from `engine/byte.zig`).
    byte_prog: byte.Program,
    /// Byte equivalence classes — the DFA's transition alphabet. Two bytes in one
    /// class are indistinguishable to every `byte_range`, so the table stores one
    /// transition per *class*, not per byte.
    classes: byte.ByteClasses,
    /// `class_rep[c]` is one representative input byte of class `c` (only
    /// `[0 .. classes.count)` is meaningful). Because a `byte_range` is class-uniform,
    /// testing the representative decides the whole class.
    class_rep: [256]u8,
};

/// Whether this HIR can run on the lazy DFA: byte-lowerable (no `\X`/`\b`) **and**
/// free of zero-width assertions (`^ $ \A \z` and line anchors), which v1 declines
/// because they make a closed state position-dependent. `auto` consults this to route
/// eligible patterns here and leave the rest on the code-point engines.
///
/// @stable-since: v0.3.0
pub fn supports(h: hir.Hir) bool {
    if (!byte.byteLowerable(h)) return false; // excludes \X and \b/\B
    for (h.nodes) |n| switch (n.tag) {
        .anchor => return false, // ^ $ \A \z (?m) line — position-dependent
        else => {},
    };
    return true;
}

/// Compile a HIR into a heap-allocated DFA `Program` (free with `freeProgram`).
/// A pattern this backend cannot run (`\X`/`\b`/anchors) is rejected with
/// `error.Unsupported`; `auto` then keeps it on the code-point engines.
///
/// @stable-since: v0.3.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    if (!supports(h)) return error.Unsupported;
    var bp = try byte.buildAlloc(gpa, h);
    errdefer byte.freeProgram(gpa, &bp);
    // Defensive: the closure is position-independent, so it cannot evaluate an
    // assertion. `supports` already excludes anchors; double-check the lowered program.
    for (bp.insts) |inst| switch (inst) {
        .assertion => return error.Unsupported,
        else => {},
    };
    const classes = byte.byteClasses(&bp);
    var class_rep: [256]u8 = @splat(0);
    var b: u16 = 0;
    while (b < 256) : (b += 1) class_rep[classes.map[b]] = @intCast(b);
    return .{ .byte_prog = bp, .classes = classes, .class_rep = class_rep };
}

/// Release a `Program` built with `buildAlloc`.
///
/// @stable-since: v0.3.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    byte.freeProgram(gpa, &program.byte_prog);
}

// ── State interning ───────────────────────────────────────────────────────────────

/// Hash-map context interning a DFA state (a priority-ordered, deduplicated `[]u32`
/// of NFA program counters) to a dense state id. Stateless (zero-sized), so the
/// non-context `getOrPut(allocator, key)` is available.
const StateCtx = struct {
    pub fn hash(_: StateCtx, key: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }
    pub fn eql(_: StateCtx, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

const InternMap = std.HashMapUnmanaged([]const u32, u32, StateCtx, std.hash_map.default_max_load_percentage);

// ── Scratch: the caller-owned lazy transition cache ──────────────────────────────

/// Per-search companion holding the lazy DFA's growable state. The cache (interned
/// states + transition table) **persists across searches** on the same `Scratch` so
/// determinization is amortized, so `reset` is a no-op (unlike the per-search backends).
/// One `Scratch` per thread; never share one across threads concurrently (it mutates
/// the cache on every search). Construct with `init` (or `initOptions` for a cache
/// budget); release with `deinit`.
///
/// @stable-since: v0.3.0
pub const Scratch = struct {
    gpa: std.mem.Allocator,
    /// Number of byte classes (the transition-table stride).
    nclass: u32,

    // ── the cache (grows lazily) ──
    /// Interns a state's canonical `[]u32` (priority-ordered pcs) → dense id.
    intern: InternMap = .empty,
    /// `states.items[id]` is state `id`'s owned, priority-ordered pc list (also the
    /// key the intern map points at). `id == DEAD` is the empty set.
    states: std.ArrayListUnmanaged([]const u32) = .empty,
    /// `state_match.items[id]` — does state `id` contain the `match` pc (accepting)?
    state_match: std.ArrayListUnmanaged(bool) = .empty,
    /// Flat `id * nclass + class` transition table; `UNKNOWN` until first computed.
    trans: std.ArrayListUnmanaged(u32) = .empty,
    /// The anchored start state (closure of `{0}`); determinized lazily on first use.
    start_state: u32 = DEAD,
    start_ready: bool = false,
    /// Approximate live cache footprint in bytes (drives `ScratchOptions` eviction).
    cache_bytes: usize = 0,
    opts: ScratchOptions,

    // ── reusable per-closure work buffers (no allocation during a closure) ──
    seen: []u32, // generation-stamped pc dedup
    seen_gen: u32 = 0,
    stack: []u32, // closure DFS stack
    work: []u32, // the closure result (canonical pc list being built)
    work_len: usize = 0,
    work_match: bool = false,
    seeds: []u32, // successor pcs feeding the next closure

    /// Construct a cache-backed `Scratch` with the default cache budget
    /// (`ScratchOptions{}`).
    ///
    /// @stable-since: v0.3.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) Err!Scratch {
        return initOptions(gpa, program, .{});
    }

    /// Construct a cache-backed `Scratch` with an explicit cache budget. When the
    /// memo's footprint exceeds `opts.max_bytes`, `opts.on_full` decides what happens
    /// at the next search boundary: `.reset` clears and re-determinizes (default,
    /// always results-invariant — the cache is pure optimization), `.give_up` also
    /// clears (a standalone DFA has no other engine to defer to), `.grow` never
    /// clears (the memo saturates at the program's natural state count anyway).
    ///
    /// @stable-since: v0.3.0
    pub fn initOptions(gpa: std.mem.Allocator, program: *const Program, opts: ScratchOptions) Err!Scratch {
        const n = program.byte_prog.insts.len;
        const seen = try gpa.alloc(u32, n);
        errdefer gpa.free(seen);
        @memset(seen, 0);
        const stack = try gpa.alloc(u32, 2 * n + 1);
        errdefer gpa.free(stack);
        const work = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(work);
        const seeds = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(seeds);

        var sc = Scratch{
            .gpa = gpa,
            .nclass = program.classes.count,
            .opts = opts,
            .seen = seen,
            .stack = stack,
            .work = work,
            .seeds = seeds,
        };
        errdefer sc.intern.deinit(gpa);
        errdefer {
            for (sc.states.items) |o| gpa.free(o);
            sc.states.deinit(gpa);
        }
        errdefer sc.state_match.deinit(gpa);
        errdefer sc.trans.deinit(gpa);

        // Intern the empty set as the DEAD sink (state id 0).
        sc.work_len = 0;
        _ = try sc.internState(false);
        return sc;
    }

    /// @stable-since: v0.3.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        for (self.states.items) |o| gpa.free(o);
        self.states.deinit(gpa);
        self.state_match.deinit(gpa);
        self.trans.deinit(gpa);
        self.intern.deinit(gpa);
        gpa.free(self.seen);
        gpa.free(self.stack);
        gpa.free(self.work);
        gpa.free(self.seeds);
    }

    /// No-op: the DFA cache is meant to persist across searches (that is what makes it
    /// pay off). Required by the contract's reset convention; there is no per-search
    /// state to clear — the work buffers are overwritten on each use.
    ///
    /// @stable-since: v0.3.0
    pub fn reset(self: *Scratch) void {
        _ = self;
    }

    /// Drop the entire memo and re-seed the DEAD sink. Safe only at a search boundary
    /// (the cache is a pure optimization; the next search re-determinizes from the
    /// start). Triggered by the `ScratchOptions` budget.
    fn clearCache(self: *Scratch) void {
        for (self.states.items) |o| self.gpa.free(o);
        self.states.deinit(self.gpa);
        self.states = .empty;
        self.state_match.deinit(self.gpa);
        self.state_match = .empty;
        self.trans.deinit(self.gpa);
        self.trans = .empty;
        self.intern.deinit(self.gpa);
        self.intern = .empty;
        self.cache_bytes = 0;
        self.start_ready = false;
        self.work_len = 0;
        _ = self.internState(false) catch @panic(OOM_PANIC); // re-seed DEAD = state 0
    }

    /// Evict the cache if it has outgrown its budget. Called at the top of each
    /// search, where dropping the memo is always correct.
    fn maybeEvict(self: *Scratch) void {
        if (self.opts.on_full == .grow) return;
        if (self.cache_bytes <= self.opts.max_bytes) return;
        self.clearCache();
    }

    /// Intern the state currently in `work[0..work_len]` (with accepting flag
    /// `is_match`) to a dense id, allocating it on first sight. On a fresh state it
    /// owns a copy of the pc list, appends an all-`UNKNOWN` transition row, and bumps
    /// the footprint estimate.
    fn internState(self: *Scratch, is_match: bool) Err!u32 {
        const key = self.work[0..self.work_len];
        const gop = try self.intern.getOrPut(self.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;

        // New state: own the key (the work buffer is reused next closure), assign id,
        // and extend the transition table by one all-UNKNOWN row.
        const owned = try self.gpa.dupe(u32, key);
        gop.key_ptr.* = owned;
        const id: u32 = @intCast(self.states.items.len);
        gop.value_ptr.* = id;
        try self.states.append(self.gpa, owned);
        try self.state_match.append(self.gpa, is_match);
        var i: u32 = 0;
        while (i < self.nclass) : (i += 1) try self.trans.append(self.gpa, UNKNOWN);

        self.cache_bytes += owned.len * @sizeOf(u32) + @as(usize, self.nclass) * @sizeOf(u32) + 48;
        return id;
    }

    /// Epsilon-closure of `seeds` into `work` (priority order, deduplicated, cut on
    /// match). The byte analogue of the Pike VM's thread closure, minus capture slots
    /// and minus assertions (none survive `supports`). Writes `work`/`work_len` and
    /// sets `work_match`. Allocation-free (all buffers pre-sized to the program).
    fn closure(self: *Scratch, program: *const Program, seeds: []const u32) void {
        const insts = program.byte_prog.insts;
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        self.work_len = 0;
        self.work_match = false;

        seeds_loop: for (seeds) |seed| {
            var top: usize = 0;
            self.stack[top] = seed;
            top += 1;
            while (top > 0) {
                top -= 1;
                var pc = self.stack[top];
                follow: while (true) {
                    if (self.seen[pc] == gen) break :follow; // already in this closure
                    self.seen[pc] = gen;
                    switch (insts[pc]) {
                        .jmp => |t| pc = t,
                        .split => |s| {
                            // Lower-priority arm `b` waits on the stack; follow `a` now.
                            self.stack[top] = s.b;
                            top += 1;
                            pc = s.a;
                        },
                        .save => pc += 1, // captures are epsilons to the DFA
                        .assertion => unreachable, // excluded by `supports`/`buildAlloc`
                        .byte_range => {
                            self.work[self.work_len] = pc;
                            self.work_len += 1;
                            break :follow;
                        },
                        .match => {
                            self.work[self.work_len] = pc;
                            self.work_len += 1;
                            self.work_match = true;
                            // Cut: every lower-priority thread (still on the stack or in
                            // later seeds) is discarded — the Pike VM's match cut.
                            break :seeds_loop;
                        },
                    }
                }
            }
        }
    }

    /// Determinize lazily: the next state from `state_id` on byte-`class`. Returns a
    /// memoized edge if present, else computes it (step matching `byte_range`s,
    /// closure, intern) and caches it.
    fn step(self: *Scratch, program: *const Program, state_id: u32, class: u32) Err!u32 {
        const idx = @as(usize, state_id) * self.nclass + class;
        const cached = self.trans.items[idx];
        if (cached != UNKNOWN) return cached;

        // Successors: pc+1 of every `byte_range` in this state that contains the
        // class representative, in the state's (priority) order. `pcs` is a stable
        // owned slice, so it survives the `intern` reallocation below.
        const pcs = self.states.items[state_id];
        const rep = program.class_rep[class];
        var ns: usize = 0;
        for (pcs) |pc| switch (program.byte_prog.insts[pc]) {
            .byte_range => |r| if (r.lo <= r.hi and r.contains(rep)) {
                self.seeds[ns] = pc + 1;
                ns += 1;
            },
            .match => {}, // terminal: no outgoing edge
            else => unreachable, // a canonical state holds only byte_range / match
        };

        self.closure(program, self.seeds[0..ns]);
        const next = try self.internState(self.work_match);
        // `internState` may have grown `trans` (realloc) — re-index to write the edge.
        self.trans.items[@as(usize, state_id) * self.nclass + class] = next;
        return next;
    }

    fn ensureStart(self: *Scratch, program: *const Program) Err!void {
        if (self.start_ready) return;
        self.closure(program, &[_]u32{0});
        self.start_state = try self.internState(self.work_match);
        self.start_ready = true;
    }

    /// Run the DFA anchored at `s`: returns the leftmost-first match end reached from
    /// `s`, or null if no match begins exactly at `s`. With `earliest`, returns as soon
    /// as any accepting state is entered (used by `isMatch`); otherwise it scans on,
    /// keeping the last accepting position — which, thanks to the priority/cut closure,
    /// is the leftmost-first end.
    fn runAnchored(self: *Scratch, program: *const Program, input: []const u8, s: usize, earliest: bool) Err!?usize {
        try self.ensureStart(program);
        var state = self.start_state;
        if (state == DEAD) return null;
        var match_end: ?usize = if (self.state_match.items[state]) s else null;
        if (match_end != null and earliest) return match_end;

        var pos = s;
        while (pos < input.len) {
            const class = program.classes.get(input[pos]);
            state = try self.step(program, state, class);
            if (state == DEAD) break;
            pos += 1;
            if (self.state_match.items[state]) {
                match_end = pos;
                if (earliest) break;
            }
        }
        return match_end;
    }
};

// ── Search core ───────────────────────────────────────────────────────────────────

/// Leftmost match: scan start positions from `opts.start`, run the DFA anchored at
/// each, and return the first that matches. Internal (returns the allocator error);
/// the contract entry points turn OOM into a `@panic`.
fn searchImpl(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions, earliest: bool) Err!?Match {
    if (opts.start > input.len) return null;
    scratch.maybeEvict();
    var s = opts.start;
    while (s <= input.len) : (s += 1) {
        if (try scratch.runAnchored(program, input, s, earliest)) |end| {
            return Match{ .start = s, .end = end };
        }
        if (opts.anchored) break; // anchored: only the start position
    }
    return null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// Does the pattern match anywhere from `opts.start`? Uses earliest-exit (stops at the
/// first accepting state), so it is the cheapest op.
///
/// @stable-since: v0.3.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    const m = searchImpl(program, scratch, input, opts, true) catch @panic(OOM_PANIC);
    return m != null;
}

/// The leftmost match span `[start, end)`, or null. Leftmost-first, identical to the
/// code-point engines. `SearchOptions.earliest` is advisory and ignored here (the span
/// is always leftmost-first); it only short-circuits `isMatch`.
///
/// @stable-since: v0.3.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    return searchImpl(program, scratch, input, opts, false) catch @panic(OOM_PANIC);
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests — end-to-end through Engine(dfa), plus differential checks vs. the Pike VM
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("../../core/compile.zig");
const pikevm = @import("pikevm.zig");
const E = backend.Engine(@This());

fn buildFrom(gpa: std.mem.Allocator, pattern: []const u8) !Program {
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, pattern, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    return buildAlloc(gpa, h, .{});
}

const Compiled = struct {
    program: Program,
    scratch: Scratch,

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var program = try buildFrom(gpa, pattern);
        errdefer freeProgram(gpa, &program);
        return .{ .program = program, .scratch = try Scratch.init(gpa, &program) };
    }
    fn deinit(self: *Compiled) void {
        self.scratch.deinit(testing.allocator);
        freeProgram(testing.allocator, &self.program);
    }
    fn find(self: *Compiled, input: []const u8) ?Match {
        return E.find(&self.program, &self.scratch, input, .{});
    }
    fn isMatch(self: *Compiled, input: []const u8) bool {
        return E.isMatch(&self.program, &self.scratch, input, .{});
    }
};

fn expectFind(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = re.find(input) orelse {
        std.debug.print("/{s}/ did NOT match in \"{s}\" (expected \"{s}\")\n", .{ pattern, input, expected });
        return error.NoMatch;
    };
    try testing.expectEqualStrings(expected, m.slice(input));
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    if (re.find(input)) |m| {
        std.debug.print("/{s}/ unexpectedly matched \"{s}\"\n", .{ pattern, m.slice(input) });
        return error.UnexpectedMatch;
    }
}

fn expectSpan(pattern: []const u8, input: []const u8, start: usize, end: usize) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = re.find(input) orelse return error.NoMatch;
    try testing.expectEqual(start, m.start);
    try testing.expectEqual(end, m.end);
}

test "dfa satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "dfa is span-only (captures = false)" {
    try testing.expect(!caps.captures);
}

test "literals, leftmost span, none" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("abc", "abXabc", "abc");
    try expectNoMatch("abc", "ab");
    try expectFind("a", "banana", "a");
    try expectSpan("a", "banana", 1, 2);
    try expectSpan("", "abc", 0, 0); // empty match at start
    try expectFind("héllo", "say héllo!", "héllo");
}

test "dot / classes / shorthands / negation" {
    try expectFind("a.c", "axc", "axc");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("(?s)a.c", "a\nc", "a\nc");
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("[^a-z]+", "abXY12cd", "XY12");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "  foo_bar! ", "foo_bar");
    try expectFind("\\D+", "12ab34", "ab");
    try expectFind("\\s+", "ab \t cd", " \t ");
}

test "alternation is leftmost-first" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("a|ab", "ab", "a"); // first alternative wins at equal start
    try expectFind("ab|a", "ab", "ab"); // longer higher-priority alternative wins
    try expectFind("foo|foobar", "foobar", "foo");
    try expectFind("a(b|c|d)e", "ade", "ade");
}

test "quantifiers: greedy, lazy, counted" {
    try expectFind("ab*", "abbbc", "abbb"); // greedy
    try expectNoMatch("ab+", "ac");
    try expectFind("ab?c", "ac", "ac");
    try expectFind("a.*c", "abXYZc end c", "abXYZc end c"); // greedy to last c
    try expectFind("a.*?c", "abXcYc", "abXc"); // lazy to first c
    try expectFind("a+?", "aaaa", "a"); // lazy one
    try expectFind("a*", "baaa", ""); // greedy but no 'a' at 0 → empty match
    try expectFind("a*", "aaab", "aaa");
    try expectFind("a{3}", "aaaaa", "aaa");
    try expectFind("a{2,4}", "aaaaaa", "aaaa");
    try expectFind("a{0,2}b", "b", "b");
    try expectFind("(ab){2,3}", "ababab", "ababab");
}

test "multi-byte UTF-8 matched by byte stepping (zero decode)" {
    try expectFind("\\w+", "héllo, wörld", "héllo");
    try expectFind("\\p{L}+", "abc123", "abc");
    try expectFind("\\p{Nd}+", "x٤٥٦y", "٤٥٦");
    try expectFind("\\p{Script=Greek}+", "abcαβγdef", "αβγ");
    try expectFind("[α-ω]+", "ΑΒΓαβγ", "αβγ"); // lowercase Greek only
    try expectSpan("é", "aé", 1, 3); // byte offsets, not code points
    try expectFind("é{2,3}", "xééééy", "ééé");
    try expectFind("(?i)abc", "XYZABCxyz", "ABC");
}

test "invalid UTF-8 input is dead-on-invalid (a match never spans a bad byte)" {
    try expectFind("a.c", "a\xFFc abc", "abc"); // resyncs past the bad byte
    try expectFind(".", "\xFFa", "a"); // `.` cannot match the lone invalid byte
    try expectNoMatch(".", "\xFF");
    try expectNoMatch("\\w+", "\xFF\xFE");
}

test "supports(): accepts byte-class patterns, declines anchors / \\b / \\X" {
    const gpa = testing.allocator;
    const accepts = [_][]const u8{ "[a-z]+", "\\w+\\d*", "cat|dog", "héllo", "a.*c", "\\p{L}+" };
    const declines = [_][]const u8{ "^abc", "abc$", "\\bcat\\b", "\\Bx", "a\\Xb", "(?m)^line" };
    inline for (accepts) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expect(supports(h));
        var prog = try buildAlloc(gpa, h, .{});
        freeProgram(gpa, &prog);
    }
    inline for (declines) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expect(!supports(h));
        try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
    }
}

test "agnostic ops: findAll / count / split over the shared cache" {
    var re = try Compiled.init("\\d+");
    defer re.deinit();
    const input = "a12b345c6";
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("12", it.next().?.slice(input));
    try testing.expectEqualStrings("345", it.next().?.slice(input));
    try testing.expectEqualStrings("6", it.next().?.slice(input));
    try testing.expect(it.next() == null);

    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, input, .{}));

    var sp = E.split(&re.program, &re.scratch, "a12b345c6", .{});
    try testing.expectEqualStrings("a", sp.next().?);
    try testing.expectEqualStrings("b", sp.next().?);
    try testing.expectEqualStrings("c", sp.next().?);
}

test "isMatch (earliest-exit) and anchored search" {
    var re = try Compiled.init("\\w+");
    defer re.deinit();
    try testing.expect(re.isMatch("  hello"));
    try testing.expect(!re.isMatch("  !!  "));
    // anchored: must begin exactly at the offset
    try testing.expect(E.find(&re.program, &re.scratch, "  hi", .{ .anchored = true }) == null);
    try testing.expect(E.find(&re.program, &re.scratch, "hi  ", .{ .anchored = true }) != null);
}

test "cache persists and stays correct across many searches on one scratch" {
    var re = try Compiled.init("[a-z]+[0-9]+");
    defer re.deinit();
    const inputs = [_]struct { in: []const u8, exp: ?[]const u8 }{
        .{ .in = "  abc123  ", .exp = "abc123" },
        .{ .in = "QQ", .exp = null },
        .{ .in = "x9", .exp = "x9" },
        .{ .in = "the answer is forty2 ok", .exp = "forty2" },
        .{ .in = "  abc123  ", .exp = "abc123" }, // repeat — served from the warm cache
    };
    for (inputs) |t| {
        const m = re.find(t.in);
        if (t.exp) |e| try testing.expectEqualStrings(e, m.?.slice(t.in)) else try testing.expect(m == null);
    }
}

test "tiny cache budget forces eviction but stays results-invariant" {
    const gpa = testing.allocator;
    var program = try buildFrom(gpa, "\\w+");
    defer freeProgram(gpa, &program);
    // A 1-byte budget evicts the whole cache before (almost) every search.
    var sc = try Scratch.initOptions(gpa, &program, .{ .max_bytes = 1, .on_full = .reset });
    defer sc.deinit(gpa);
    try testing.expectEqualStrings("héllo", E.find(&program, &sc, "  héllo, wörld", .{}).?.slice("  héllo, wörld"));
    try testing.expectEqualStrings("wörld", E.find(&program, &sc, "wörld!", .{}).?.slice("wörld!"));
    try testing.expect(E.find(&program, &sc, "...", .{}) == null);
}

test "large input determinism (the throughput path)" {
    const gpa = testing.allocator;
    var re = try Compiled.init("a\\w+z");
    defer re.deinit();
    const big = try gpa.alloc(u8, 5000);
    defer gpa.free(big);
    @memset(big, '.');
    @memcpy(big[2500 .. 2500 + 5], "aQRsz");
    try testing.expectEqualStrings("aQRsz", re.find(big).?.slice(big));
}

// ── Differential: the DFA span must equal the Pike VM's whole-match span ──────────

fn expectAgreesWithPikeVM(pattern: []const u8, input: []const u8) !void {
    const gpa = testing.allocator;

    var dprog = try buildFrom(gpa, pattern);
    defer freeProgram(gpa, &dprog);
    var dsc = try Scratch.init(gpa, &dprog);
    defer dsc.deinit(gpa);
    const dm = E.find(&dprog, &dsc, input, .{});

    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, pattern, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var pprog = try pikevm.buildAlloc(gpa, h, .{});
    defer pikevm.freeProgram(gpa, &pprog);
    var psc = try pikevm.Scratch.init(gpa, &pprog);
    defer psc.deinit(gpa);
    const PE = backend.Engine(pikevm);
    const pm = PE.find(&pprog, &psc, input, .{});

    try testing.expectEqual(pm == null, dm == null);
    if (pm) |p| {
        try testing.expectEqual(p.start, dm.?.start);
        try testing.expectEqual(p.end, dm.?.end);
    }
}

test "differential vs Pike VM across a corpus (spans must agree)" {
    const patterns = [_][]const u8{
        "abc",        "a.c",      "[a-z]+",  "[^a-z]+",   "\\d+",
        "\\w+",       "\\D+",     "cat|dog", "a|ab",      "ab|a",
        "foo|foobar", "ab*",      "ab+",     "ab?c",      "a.*c",
        "a.*?c",      "a+?",      "a{2,4}",  "(ab){2,3}", "\\w+\\d+",
        "\\p{L}+",    "\\p{Nd}+",
        "[α-ω]+",
        "é{2,3}",
        "(?i)abc",    "a*",       "(?:ab)+", "x?y?z?",    "\\w*",
    };
    const inputs = [_][]const u8{
        "",                       "abc",        "  abc123def  ",     "xxabcyy",
        "i have a dog and a cat",
        "héllo, wörld 42",
        "ΑΒΓαβγ123",
        "aaaaab",                 "a\xFFc abc", "no match here !!!", "ababab end",
        "forty2 and 9 lives",
        "x٤٥٦y",
        "ééééX",
        "ABCxyz",
    };
    for (patterns) |p| {
        for (inputs) |in| try expectAgreesWithPikeVM(p, in);
    }
}

test "byte classes are actually consumed (the alphabet the DFA keys on)" {
    const gpa = testing.allocator;
    var program = try buildFrom(gpa, "[a-z]"); // boundaries below 'a' and at 'z' → 3 classes
    defer freeProgram(gpa, &program);
    try testing.expectEqual(@as(u16, 3), program.classes.count);
    // class representatives round-trip through the class map.
    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        const c = program.classes.get(@intCast(b));
        try testing.expectEqual(c, program.classes.get(program.class_rep[c]));
    }
}

test {
    testing.refAllDecls(@This());
}
