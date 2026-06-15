//! One-pass NFA backend — a linear-time capture fast path for unambiguous patterns.
//!
//! Most structured capture patterns — `(\d{4})-(\d{2})-(\d{2})`, `(\w+)@(\w+)`,
//! `(\d+)\.(\d+)\.(\d+)`, `(\w+):(\d+)` — have the property that **at every point in a
//! match there is never any choice about which way to go through the NFA**: for each input
//! code point at most one transition can fire, and the capture writes on the way to it are
//! unique. Such a pattern is **one-pass**. A one-pass match needs no thread set, no
//! per-thread slot copies, and no epsilon-closure dance at match time: a **single** thread
//! carries one capture-slot array and advances deterministically one code point at a time
//! — `O(input)` with a tiny constant, the cheapest possible way to fill captures.
//!
//! This backend determinizes the shared `engine/nfa.zig` program into a frozen one-pass
//! table **at build time** (comptime *and* runtime) and, if the pattern is provably
//! one-pass, runs that table. If it is **not** one-pass — two transitions could fire on the
//! same code point, or a capture could be written two different ways — the build is declined
//! (`error.Unsupported`, a `@compileError` at comptime), and the caller keeps the pattern on
//! the Pike VM (which handles ambiguity by simulating all threads). So a `false` decision is
//! always *safe*: it only ever routes work to a more general engine.
//!
//! ## What it is (and is not)
//!
//!   * **Captures-capable** (`caps.captures = true`): it fills the full `slots` array, not
//!     just the whole-match span. That is the whole point — it is the *capture* fast path.
//!   * **Stateless** (`caps.stateless = true`): the frozen table is the entire matcher, like
//!     `edfa.zig`/`literal.zig`. `Scratch` is `struct{}` with no-op lifecycle; one immutable
//!     `Program` is freely shareable across threads.
//!   * **Comptime *and* runtime.** `buildComptime` determinizes into `ro_data`; `buildAlloc`
//!     onto the heap. Both run the same determinizer — the CTRE-lane capture engine.
//!   * **Leftmost-first**, byte-identical to every other backend. The determinizer keeps the
//!     NFA in priority order and **cuts on match** (a `match` reachable in the closure
//!     discards every lower-priority alternative) — the same rule the Pike VM and the DFAs
//!     use — so its spans and slots never disagree (`conformance.zig` pins it).
//!   * **Anchored by nature.** A single thread cannot track two different start positions at
//!     once, so the engine matches *from a given start*. An unanchored `search`/`captures`
//!     scans candidate starts left to right (correct, leftmost-first, but `O(input × match)`
//!     in the worst case when pinned directly). The intended driver is `auto`, whose capture
//!     handoff is **already anchored**: a DFA arm locates the span, then this engine fills the
//!     groups anchored at the span start — one linear pass, no scanning.
//!
//! ## Declined patterns (kept correct on the Pike VM)
//!
//! The build declines — soundly, never silently mis-matching — any pattern that is not
//! provably one-pass, plus, **by design**, every pattern carrying a zero-width assertion
//! (`^ $ \A \z \b \B` and `(?m)` line anchors) or a `\X` grapheme. Assertions make a state's
//! closure depend on the input position, not just the symbol; rather than thread positional
//! conditions through the table (and risk a subtle capture bug), an assertion-bearing pattern
//! is left to the Pike VM, which is correct and linear there. The common structured capture
//! patterns above carry no assertions, so they take this fast path; an anchored `^(\d+)-(\d+)$`
//! stays on the Pike VM. More than 31 capturing groups (a `slot_count` past 64) is also
//! declined — the per-transition capture action is a `u64` slot mask.
//!
//! ## Correctness
//!
//! The one-pass decision is **conservative**: any ambiguity (two firable transitions on one
//! symbol, or a capture-slot mask reached two different ways) declines the whole pattern. The
//! executor is a faithful single-thread simulation of the Pike VM's highest-priority thread,
//! which the one-pass property proves is the *only* thread. The decision and the executor are
//! pinned by a wide **differential test against the Pike VM** (every pattern this backend
//! accepts must report byte-identical slots) plus a revert-failing regression — see the tests
//! at the foot of this file and `conformance.zig`.

const std = @import("std");

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const nfa = @import("engine_base").nfa;

const utils = @import("utils");

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const Range = hir.Range;
const CodePoint = utils.unicode.CodePoint;

// ── Contract surface ────────────────────────────────────────────────────────────

/// @stable-since: v0.4.0
pub const caps = Caps{ .captures = true, .stateless = true, .grapheme = false };

/// Build options. The HIR has already applied flags/folding, so nothing is needed here;
/// the field exists to satisfy the contract shape.
///
/// @stable-since: v0.4.0
pub const Options = struct {};

/// Hard ceiling on the number of `slot_count` slots (= `2 * (groups + 1)`): the
/// per-transition capture action is a `u64` mask, so at most 64 slots (31 groups).
const MAX_SLOTS: u32 = 64;

/// What a one-pass transition consumes. `ranges` tests the code point against a sorted
/// range block (shared `nfa.inRanges`); `any`/`any_nonl` are the dot variants (`(?s).`
/// and `.`). Kept distinct so the disjointness check (and `\n`-vs-`.` interplay) is exact.
///
/// @stable-since: v0.4.0
const TransKind = enum(u8) { ranges, any, any_nonl };

/// One transition out of a one-pass state. On a code point in its symbol set: write the
/// **current** position into every slot in `mask`, advance one code point, and move to
/// `target`. Within a state every transition's symbol set is **disjoint** (the one-pass
/// invariant), so at most one fires per code point.
///
/// @stable-since: v0.4.0
const Trans = struct {
    kind: TransKind,
    /// `[rstart, rstart+rlen)` into `Program.ranges` — the symbol set for `.ranges`.
    rstart: u32,
    rlen: u32,
    /// Slots to write with the current position when this transition is taken (the saves
    /// on the unique epsilon path to the consuming instruction).
    mask: u64,
    /// Index of the destination state.
    target: u32,
};

/// One state of the one-pass automaton: a contiguous slice of `Program.trans` plus the
/// accept info. `can_match` ⇒ this state may end a match; `match_mask` is the saves to
/// apply (at the current position) when it does. The match alternative is **lower
/// priority** than every transition stored here (priority-ordered, match-cut), so at
/// runtime a firing transition always wins over matching, and matching is the fallback.
///
/// @stable-since: v0.4.0
const State = struct {
    tstart: u32,
    tlen: u32,
    can_match: bool,
    match_mask: u64,
};

/// The compiled, immutable one-pass program. Self-contained: it copies every range it
/// needs, so the source HIR/NFA may be freed after building. State `0` is the start.
///
/// @stable-since: v0.4.0
pub const Program = struct {
    /// Sorted, non-overlapping code-point ranges referenced by `.ranges` transitions
    /// (a copy of the NFA program's ranges followed by one singleton per literal char).
    ranges: []const Range,
    /// Flat transition pool; each state slices `[tstart, tstart+tlen)`.
    trans: []const Trans,
    /// The states; `states[0]` is the start.
    states: []const State,
    /// `2 * (capture_count + 1)` — the slot array length capture-aware search needs.
    slot_count: u32,
};

// ── Determinizer: NFA program → one-pass table (or a sound decline) ───────────────

/// Sentinel for "this NFA pc has no assigned one-pass state yet".
const NO_STATE: u32 = std.math.maxInt(u32);

/// One entry on the closure walk's explicit stack (no recursion: comptime-safe and
/// overflow-proof). `visit` follows the instruction at a pc; `restore` clears a save bit
/// once its subtree drains, so a sibling branch never observes the write — the bitmask
/// analogue of the Pike VM's save/restore.
const StackEnt = union(enum) {
    visit: u32,
    restore: u6,
};

/// The determinizer. It walks the NFA program building the one-pass table into
/// caller-owned buffers (so the very same body runs at comptime and runtime), and returns
/// `error.Unsupported` the moment the pattern proves *not* one-pass. States are keyed by a
/// **single** NFA pc (the start is pc 0; the target of a consuming instruction at pc `P`
/// is the closure of `P+1`), so there is no subset-construction blow-up: at most one state
/// per instruction.
const Det = struct {
    insts: []const nfa.Inst,
    src_ranges: []const Range,
    slot_count: u32,

    // outputs (caller buffers, trimmed by the caller afterwards)
    ranges: []Range,
    r_len: u32 = 0,
    trans: []Trans,
    t_len: u32 = 0,
    states: []State,
    state_count: u32 = 0,

    // bookkeeping
    state_of: []u32, // NFA pc → state index (NO_STATE = unassigned); len = #insts
    char_off: []u32, // NFA pc → singleton-range offset for a `.char`; len = #insts
    queue: []u32, // BFS queue of entry pcs; len = state-cap
    q_head: u32 = 0,
    q_tail: u32 = 0,

    // per-closure scratch
    seen: []bool, // len = #insts
    rec_mask: []u64, // len = #insts (mask each pc was first reached with)
    stack: []StackEnt, // len ≥ 2 * #insts + 2

    const Err = error{Unsupported};

    fn getState(self: *Det, pc: u32) Err!u32 {
        if (self.state_of[pc] != NO_STATE) return self.state_of[pc];
        const idx = self.state_count;
        if (idx >= self.states.len or self.q_tail >= self.queue.len) return error.Unsupported;
        self.state_of[pc] = idx;
        self.state_count += 1;
        self.queue[self.q_tail] = pc;
        self.q_tail += 1;
        return idx;
    }

    fn emit(self: *Det, t: Trans) Err!void {
        if (self.t_len >= self.trans.len) return error.Unsupported;
        self.trans[self.t_len] = t;
        self.t_len += 1;
    }

    fn push(self: *Det, top: *usize, ent: StackEnt) Err!void {
        if (top.* >= self.stack.len) return error.Unsupported;
        self.stack[top.*] = ent;
        top.* += 1;
    }

    /// Build the range pool (the NFA ranges, then one singleton per `.char`) and run the
    /// BFS over closures. Pre-checks reject the by-design declines (assertion, grapheme,
    /// too many slots) before any work.
    fn run(self: *Det) Err!void {
        if (self.slot_count > MAX_SLOTS) return error.Unsupported;
        for (self.insts) |inst| switch (inst) {
            .assertion, .grapheme => return error.Unsupported,
            else => {},
        };

        const R: u32 = @intCast(self.src_ranges.len);
        if (R > self.ranges.len) return error.Unsupported;
        @memcpy(self.ranges[0..R], self.src_ranges);
        var k = R;
        for (self.insts, 0..) |inst, pc| switch (inst) {
            .char => |cp| {
                if (k >= self.ranges.len) return error.Unsupported;
                self.ranges[k] = .{ .lo = cp, .hi = cp };
                self.char_off[pc] = k;
                k += 1;
            },
            else => {},
        };
        self.r_len = k;

        @memset(self.state_of, NO_STATE);
        _ = try self.getState(0); // start = state 0 = closure(pc 0)
        while (self.q_head < self.q_tail) {
            const entry = self.queue[self.q_head];
            self.q_head += 1;
            try self.closure(entry, self.state_of[entry]);
        }

        // One-pass "no abandoned match" check (needs every state's `can_match`, so it runs
        // after the BFS). Once a state can match, a complete match is available *here*; if a
        // transition out of it leads to a state that CANNOT match, then taking that transition
        // would consume past — and abandon — that available match. The Pike VM copes by
        // keeping the recorded match alongside the speculative thread (two threads); a single
        // thread cannot, so such a pattern is not one-pass. (`a*`, `\w+`, `(\w)+`, `(a|b)*`
        // loop back to a matching state and pass; `(ab|cd)+`, `(abc)*` do not.)
        for (self.states[0..self.state_count]) |st| {
            if (!st.can_match) continue;
            for (self.trans[st.tstart .. st.tstart + st.tlen]) |t| {
                if (!self.states[t.target].can_match) return error.Unsupported;
            }
        }
    }

    /// Walk the epsilon-closure of `entry_pc` in priority order, emitting one transition
    /// per live consuming instruction (those above the first reachable `match`) and
    /// recording the match alternative. Declines on any one-pass violation: a pc reached
    /// with two different save masks (ambiguous captures), or two live transitions whose
    /// symbol sets overlap (ambiguous next step).
    fn closure(self: *Det, entry_pc: u32, state_idx: u32) Err!void {
        @memset(self.seen, false);
        var mask: u64 = 0;
        const tstart = self.t_len;
        var can_match = false;
        var match_mask: u64 = 0;

        var top: usize = 0;
        try self.push(&top, .{ .visit = entry_pc });
        outer: while (top > 0) {
            top -= 1;
            switch (self.stack[top]) {
                .restore => |bit| mask &= ~(@as(u64, 1) << bit),
                .visit => |start_pc| {
                    var pc = start_pc;
                    follow: while (true) {
                        if (self.seen[pc]) {
                            // Re-reaching a pc: one-pass requires the same capture state,
                            // or the match would be ambiguous. (Also breaks epsilon cycles.)
                            if (self.rec_mask[pc] != mask) return error.Unsupported;
                            break :follow;
                        }
                        self.seen[pc] = true;
                        self.rec_mask[pc] = mask;
                        switch (self.insts[pc]) {
                            .jmp => |t| pc = t,
                            .split => |s| {
                                try self.push(&top, .{ .visit = s.b }); // defer lower priority
                                pc = s.a; // pursue higher priority now
                            },
                            .save => |slot| {
                                const bit: u6 = @intCast(slot);
                                if (mask & (@as(u64, 1) << bit) == 0) {
                                    try self.push(&top, .{ .restore = bit });
                                    mask |= @as(u64, 1) << bit;
                                }
                                pc += 1;
                            },
                            .assertion, .grapheme => return error.Unsupported, // pre-checked
                            .char => {
                                try self.emit(.{ .kind = .ranges, .rstart = self.char_off[pc], .rlen = 1, .mask = mask, .target = try self.getState(pc + 1) });
                                break :follow;
                            },
                            .range => |r| {
                                try self.emit(.{ .kind = .ranges, .rstart = r.start, .rlen = r.len, .mask = mask, .target = try self.getState(pc + 1) });
                                break :follow;
                            },
                            .any => |a| {
                                try self.emit(.{ .kind = if (a.dot_all) .any else .any_nonl, .rstart = 0, .rlen = 0, .mask = mask, .target = try self.getState(pc + 1) });
                                break :follow;
                            },
                            .match => {
                                can_match = true;
                                match_mask = mask;
                                break :outer; // cut every lower-priority alternative
                            },
                        }
                    }
                },
            }
        }

        // One-pass disjointness: the live transitions of a state must be pairwise disjoint.
        var i = tstart;
        while (i < self.t_len) : (i += 1) {
            var j = i + 1;
            while (j < self.t_len) : (j += 1) {
                if (self.transOverlap(self.trans[i], self.trans[j])) return error.Unsupported;
            }
        }

        self.states[state_idx] = .{
            .tstart = tstart,
            .tlen = self.t_len - tstart,
            .can_match = can_match,
            .match_mask = match_mask,
        };
    }

    fn transOverlap(self: *const Det, a: Trans, b: Trans) bool {
        if (a.kind == .any or b.kind == .any) return true; // `.` overlaps everything
        if (a.kind == .any_nonl and b.kind == .any_nonl) return true;
        if (a.kind == .any_nonl) return self.blockHasNonNewline(b);
        if (b.kind == .any_nonl) return self.blockHasNonNewline(a);
        return self.blocksOverlap(a, b); // both .ranges
    }

    /// Does a `.ranges` block contain any code point other than `\n`? (Its overlap with a
    /// `.` (any-except-`\n`): a `[\n]`-only block is disjoint from `.`, so `(.|\n)` stays
    /// one-pass.)
    fn blockHasNonNewline(self: *const Det, t: Trans) bool {
        for (self.ranges[t.rstart .. t.rstart + t.rlen]) |r| {
            if (!(r.lo == '\n' and r.hi == '\n')) return true;
        }
        return false;
    }

    fn blocksOverlap(self: *const Det, a: Trans, b: Trans) bool {
        var i = a.rstart;
        var j = b.rstart;
        const ae = a.rstart + a.rlen;
        const be = b.rstart + b.rlen;
        while (i < ae and j < be) {
            const ra = self.ranges[i];
            const rb = self.ranges[j];
            if (ra.hi < rb.lo) {
                i += 1;
            } else if (rb.hi < ra.lo) {
                j += 1;
            } else {
                return true;
            }
        }
        return false;
    }
};

// ── Build (heap + comptime) ───────────────────────────────────────────────────────

/// Cheap, allocation-free pre-check: can this backend *possibly* handle the HIR? (Cheap
/// declines only — the real one-pass property is decided by the determinizer at build.) A
/// `true` here does not promise the build succeeds; a `false` means it certainly won't.
///
/// @stable-since: v0.4.0
pub fn supports(h: hir.Hir) bool {
    if (h.analysis.has_grapheme or h.analysis.has_word_boundary) return false;
    if (2 * (h.capture_count + 1) > MAX_SLOTS) return false;
    return nfa.supports(h);
}

/// Sizes for the determinizer's buffers, derived from the NFA program. `states`/`queue`
/// are bounded by the instruction count (states are keyed by a single pc); `trans` by
/// states × consuming-insts; `ranges` by the NFA ranges plus one singleton per char.
const Bufs = struct {
    ic: u32,
    state_cap: u32,
    trans_cap: u32,
    ranges_cap: u32,
    stack_cap: u32,

    fn of(prog: *const nfa.Program) Bufs {
        const ic: u32 = @intCast(prog.insts.len);
        const state_cap = ic + 1;
        return .{
            .ic = ic,
            .state_cap = state_cap,
            .trans_cap = state_cap *| ic +| 1,
            .ranges_cap = @as(u32, @intCast(prog.ranges.len)) +| ic +| 1,
            .stack_cap = 2 *| ic +| 2,
        };
    }
};

fn finish(det: *Det) Program {
    return .{
        .ranges = det.ranges[0..det.r_len],
        .trans = det.trans[0..det.t_len],
        .states = det.states[0..det.state_count],
        .slot_count = det.slot_count,
    };
}

/// Compile a HIR into a heap-allocated one-pass `Program`, or `error.Unsupported` if the
/// pattern is not provably one-pass (or carries an assertion / `\X` / too many groups).
/// Free with `freeProgram`.
///
/// @stable-since: v0.4.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    var prog = nfa.buildAlloc(gpa, h) catch return error.Unsupported;
    defer nfa.freeProgram(gpa, &prog); // a build-time scaffold; only the one-pass table escapes
    const b = Bufs.of(&prog);

    const ranges = try gpa.alloc(Range, b.ranges_cap);
    errdefer gpa.free(ranges);
    const trans = try gpa.alloc(Trans, b.trans_cap);
    errdefer gpa.free(trans);
    const states = try gpa.alloc(State, b.state_cap);
    errdefer gpa.free(states);

    const state_of = try gpa.alloc(u32, b.ic);
    defer gpa.free(state_of);
    const char_off = try gpa.alloc(u32, b.ic);
    defer gpa.free(char_off);
    const queue = try gpa.alloc(u32, b.state_cap);
    defer gpa.free(queue);
    const seen = try gpa.alloc(bool, b.ic);
    defer gpa.free(seen);
    const rec_mask = try gpa.alloc(u64, b.ic);
    defer gpa.free(rec_mask);
    const stack = try gpa.alloc(StackEnt, b.stack_cap);
    defer gpa.free(stack);

    var det = Det{
        .insts = prog.insts,
        .src_ranges = prog.ranges,
        .slot_count = prog.slot_count,
        .ranges = ranges,
        .trans = trans,
        .states = states,
        .state_of = state_of,
        .char_off = char_off,
        .queue = queue,
        .seen = seen,
        .rec_mask = rec_mask,
        .stack = stack,
    };
    det.run() catch return error.Unsupported;

    // Trim the over-allocated outputs to exactly what was written.
    const out_ranges = try gpa.realloc(ranges, det.r_len);
    const out_trans = try gpa.realloc(trans, det.t_len);
    const out_states = try gpa.realloc(states, det.state_count);
    return .{ .ranges = out_ranges, .trans = out_trans, .states = out_states, .slot_count = det.slot_count };
}

/// Compile a HIR into a ro_data one-pass `Program` at comptime. A non-one-pass pattern (or
/// an assertion / `\X` / too many groups) is a `@compileError` — pin this backend only on a
/// pattern you know is one-pass, or go through `auto` (which keeps such patterns on the Pike
/// VM at comptime).
///
/// @stable-since: v0.4.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    const prog = nfa.buildComptime(h);
    const b = comptime Bufs.of(&prog);
    // Determinization work scales with states × (closure + range-block disjointness), i.e.
    // roughly (#insts + #ranges) × #insts; a generous ceiling so a pinned build on a big
    // Unicode class still completes (`auto` only builds this at comptime for tiny patterns).
    @setEvalBranchQuota(@intCast(@min(200_000 + (@as(u64, b.ic) + @as(u64, prog.ranges.len)) * (@as(u64, b.ic) + 1) * 128, std.math.maxInt(u32))));

    comptime var ranges: [b.ranges_cap]Range = undefined;
    comptime var trans: [b.trans_cap]Trans = undefined;
    comptime var states: [b.state_cap]State = undefined;
    comptime var state_of: [b.ic]u32 = undefined;
    comptime var char_off: [b.ic]u32 = undefined;
    comptime var queue: [b.state_cap]u32 = undefined;
    comptime var seen: [b.ic]bool = undefined;
    comptime var rec_mask: [b.ic]u64 = undefined;
    comptime var stack: [b.stack_cap]StackEnt = undefined;

    comptime var det = Det{
        .insts = prog.insts,
        .src_ranges = prog.ranges,
        .slot_count = prog.slot_count,
        .ranges = &ranges,
        .trans = &trans,
        .states = &states,
        .state_of = &state_of,
        .char_off = &char_off,
        .queue = &queue,
        .seen = &seen,
        .rec_mask = &rec_mask,
        .stack = &stack,
    };
    det.run() catch @compileError("onepass: pattern is not one-pass (or has an assertion / \\X); use the pikevm or auto backend");

    const final_ranges = ranges[0..det.r_len].*;
    const final_trans = trans[0..det.t_len].*;
    const final_states = states[0..det.state_count].*;
    return .{ .ranges = &final_ranges, .trans = &final_trans, .states = &final_states, .slot_count = det.slot_count };
}

/// @stable-since: v0.4.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.ranges);
    gpa.free(program.trans);
    gpa.free(program.states);
}

// ── Scratch: none (the frozen table is the whole matcher) ─────────────────────────

/// Empty per-search state — this backend is stateless, like `edfa`/`literal`. The
/// `Buf`/`bufferLen`/`initBuffer` convention is honoured (no-ops) so the comptime/buffer
/// matching path works.
///
/// @stable-since: v0.4.0
pub const Scratch = struct {
    /// @stable-since: v0.4.0
    pub const Buf = backend.Cell;
    /// @stable-since: v0.4.0
    pub fn bufferLen(_: *const Program) usize {
        return 0;
    }
    /// @stable-since: v0.4.0
    pub fn init(_: std.mem.Allocator, _: *const Program) std.mem.Allocator.Error!Scratch {
        return .{};
    }
    /// @stable-since: v0.4.0
    pub fn initBuffer(_: []backend.Cell, _: *const Program) backend.ScratchError!Scratch {
        return .{};
    }
    /// @stable-since: v0.4.0
    pub fn deinit(_: *Scratch, _: std.mem.Allocator) void {}
    /// @stable-since: v0.4.0
    pub fn reset(_: *Scratch) void {}
};

// ── Matching (a single deterministic thread) ──────────────────────────────────────

fn applyMask(slots: []?usize, mask: u64, pos: usize) void {
    var m = mask;
    while (m != 0) {
        const bit = @ctz(m);
        if (bit < slots.len) slots[bit] = pos;
        m &= m - 1;
    }
}

inline fn fires(program: *const Program, t: Trans, cp: CodePoint, valid: bool) bool {
    if (!valid) return false; // dead-on-invalid: a match never spans malformed UTF-8
    return switch (t.kind) {
        .ranges => nfa.inRanges(program.ranges[t.rstart .. t.rstart + t.rlen], cp),
        .any => true,
        .any_nonl => cp != '\n',
    };
}

/// Run the single one-pass thread anchored at `start`: returns the match END offset (and,
/// when `slots` is non-null, fills the capture slots), or null if no match begins exactly
/// at `start`. A pure forward scan — decode a code point, take the unique firing transition
/// (applying its capture writes), else fall back to the (lower-priority) match. O(match).
fn runAnchored(program: *const Program, input: []const u8, start: usize, slots: ?[]?usize) ?usize {
    var state: u32 = 0;
    var pos = start;
    while (true) {
        const st = program.states[state];
        if (pos < input.len) {
            var cp: CodePoint = 0;
            var cp_len: usize = 1;
            var valid = true;
            const byte0 = input[pos];
            if (byte0 <= 0x7F) {
                cp = byte0;
            } else {
                const d = nfa.decodeAt(input, pos);
                cp = d.cp;
                cp_len = d.len;
                valid = d.valid;
            }
            var taken = false;
            for (program.trans[st.tstart .. st.tstart + st.tlen]) |t| {
                if (fires(program, t, cp, valid)) {
                    if (slots) |sl| applyMask(sl, t.mask, pos);
                    pos += cp_len;
                    state = t.target;
                    taken = true;
                    break;
                }
            }
            if (taken) continue;
        }
        // No consuming transition fired (or end of input): the match is the fallback.
        if (st.can_match) {
            if (slots) |sl| applyMask(sl, st.match_mask, pos);
            return pos;
        }
        return null;
    }
}

/// Advance one UTF-8 code point from `i` (≥ end ⇒ i+1 so the scan terminates); a malformed
/// lead byte advances by 1 (resync), mirroring the other engines' unanchored scan.
fn advance(input: []const u8, i: usize) usize {
    if (i >= input.len) return i + 1;
    if (input[i] <= 0x7F) return i + 1;
    return i + nfa.decodeAt(input, i).len;
}

fn searchImpl(program: *const Program, input: []const u8, opts: SearchOptions, slots: ?[]?usize) ?Match {
    if (opts.start > input.len) return null;
    if (opts.anchored) {
        const end = runAnchored(program, input, opts.start, slots) orelse return null;
        return .{ .start = opts.start, .end = end };
    }
    var pos = opts.start;
    while (pos <= input.len) : (pos = advance(input, pos)) {
        if (slots) |sl| @memset(sl, null); // each trial starts clean (failed trials may dirty)
        if (runAnchored(program, input, pos, slots)) |end| return .{ .start = pos, .end = end };
    }
    return null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.4.0
pub fn isMatch(program: *const Program, _: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return searchImpl(program, input, opts, null) != null;
}

/// @stable-since: v0.4.0
pub fn search(program: *const Program, _: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    return searchImpl(program, input, opts, null);
}

/// @stable-since: v0.4.0
pub fn searchCaptures(program: *const Program, _: *Scratch, input: []const u8, slots: []?usize, opts: SearchOptions) ?Match {
    return searchImpl(program, input, opts, slots);
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("core").compile;
const pikevm = @import("pikevm");
const E = backend.Engine(@This());

test "onepass satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

const Compiled = struct {
    program: Program,
    meta: backend.Meta,
    scratch: Scratch,

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pattern, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        errdefer freeProgram(gpa, &program);
        return .{ .program = program, .meta = .{ .capture_count = h.capture_count }, .scratch = .{} };
    }
    fn deinit(self: *Compiled) void {
        freeProgram(testing.allocator, &self.program);
    }
};

fn expectFind(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = E.find(&re.program, &re.scratch, input, .{}) orelse {
        std.debug.print("\"{s}\" did NOT match in \"{s}\" (expected \"{s}\")\n", .{ pattern, input, expected });
        return error.NoMatch;
    };
    try testing.expectEqualStrings(expected, m.slice(input));
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    try testing.expect(E.find(&re.program, &re.scratch, input, .{}) == null);
}

fn expectUnsupported(pattern: []const u8) !void {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, pattern, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
}

// ── spans (leftmost-first, greedy/lazy, unicode) ──────────────────────────────────

test "onepass: basic spans" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("a.c", "a c", "a c");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("(?s)a.c", "a\nc", "a\nc");
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("ab*", "abbbc", "abbb");
    try expectFind("ab+", "abbbc", "abbb");
    try expectFind("ab?c", "ac", "ac");
    try expectFind("a{2,4}", "aaaaaa", "aaaa");
    try expectFind("cat|dog", "a dog", "dog");
    try expectFind("\\w+", "héllo, wörld", "héllo"); // unicode, by code point
}

test "onepass: lazy quantifiers stop early" {
    try expectFind("a+?", "aaaa", "a"); // lazy plus: match wins at the first 'a'
    // `[ab]+?c` is one-pass ([ab] and c are disjoint); lazy still consumes to reach the c.
    try expectFind("[ab]+?c", "xxabac yy", "abac");
}

test "onepass: empty / zero-length matches" {
    var re = try Compiled.init("a*");
    defer re.deinit();
    const m0 = E.find(&re.program, &re.scratch, "", .{}).?;
    try testing.expectEqual(@as(usize, 0), m0.start);
    try testing.expectEqual(@as(usize, 0), m0.end);
    try testing.expectEqualStrings("aaa", E.find(&re.program, &re.scratch, "aaab", .{}).?.slice("aaab"));
}

// ── captures (the point of this backend) ──────────────────────────────────────────

test "onepass: capture groups" {
    var re = try Compiled.init("(\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    var slots: [8]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "x 2026-06-14 y", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("2026-06-14", c.match().slice("x 2026-06-14 y"));
    try testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try testing.expectEqualStrings("06", c.groupSlice(2).?);
    try testing.expectEqualStrings("14", c.groupSlice(3).?);
}

test "onepass: optional group reads back null" {
    var re = try Compiled.init("a(b)?c");
    defer re.deinit();
    var slots: [4]?usize = undefined;
    const c1 = E.captures(&re.program, &re.scratch, "ac", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("ac", c1.match().slice("ac"));
    try testing.expect(c1.group(1) == null);
    const c2 = E.captures(&re.program, &re.scratch, "abc", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("b", c2.groupSlice(1).?);
}

test "onepass: repeated group captures the last iteration" {
    var re = try Compiled.init("(\\w)+");
    defer re.deinit();
    var slots: [4]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "abc", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("abc", c.match().slice("abc"));
    try testing.expectEqualStrings("c", c.groupSlice(1).?);
}

// ── declines (kept sound — routed to the Pike VM by `auto`) ────────────────────────

test "onepass: declines non-one-pass and assertion / grapheme patterns" {
    // Ambiguous: after an 'a', stay in `a*` or take the final 'a'? Not one-pass.
    try expectUnsupported("a*a");
    try expectUnsupported("a?ab"); // two ways to consume the first 'a'
    try expectUnsupported("(a|a)b"); // overlapping alternation
    try expectUnsupported(".*a"); // `.` overlaps the trailing 'a'
    // Assertions / grapheme are declined by design (position-dependent / variable width).
    try expectUnsupported("^abc");
    try expectUnsupported("abc$");
    try expectUnsupported("\\bcat\\b");
    try expectUnsupported("(?m)^x");
    try expectUnsupported("\\X");
}

// ── differential vs the Pike VM (the correctness net) ─────────────────────────────

const diff_patterns = [_][]const u8{
    "abc",            "a.c",                       "(?s)a.c",
    "[a-z]+",         "\\d+",                      "\\w+",
    "ab*c",           "ab+c",                      "ab?c",
    "a{2,4}",         "a{3}",                      "(ab)+",
    "cat|dog|bird",   "(\\d{4})-(\\d{2})-(\\d{2})", "(\\w+)@(\\w+)",
    "(\\w+)@(\\w+)\\.(\\w+)", "(\\d+):(\\d+)",      "a(b)?(c)",
    "(a+)(b+)",       "(\\w)+",                    "(ab|cd)+",
    "(?<y>\\d+)-(?<m>\\d+)", "((a)(b))+",          "\\p{L}+",
    "(foo)(\\d+)",    "x(.)y",                     "(?i)abc",
    // one-pass: single-char alternation/star, optional tails
    "(a|b)*",         "(a|b)*c",                   "a*b?",
    "[ab]+?c",        "x?y?z",                     "(\\d)+",
    // not one-pass (must decline, not mis-match): multi-char loop bodies, nested loops
    "(ab)+",          "(abc)*",                    "(a+)+",
    "(a*)*",          "(ab|a)",                    "a*a",
};

const diff_inputs = [_][]const u8{
    "",         "abc",            "2026-06-14",   "alice@example.com",
    "aaabbb",   "x ab12 y",       "foo42 bar",    "cat and dog",
    "héllo",    "12:34",          "ababcd",       "no match here!",
    "ABCdef",   "a@b.c",          "x.y z",        "ABCxyz",
};

test "onepass: wide differential vs Pike VM (identical slots wherever onepass builds)" {
    const gpa = testing.allocator;
    for (diff_patterns) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);

        // Only patterns onepass accepts are compared; a decline is sound (Pike VM covers it).
        var op = buildAlloc(gpa, h, .{}) catch |e| switch (e) {
            error.Unsupported => continue,
            else => return e,
        };
        defer freeProgram(gpa, &op);
        var pv = try pikevm.buildAlloc(gpa, h, .{});
        defer pikevm.freeProgram(gpa, &pv);
        var pv_sc = try pikevm.Scratch.init(gpa, &pv);
        defer pv_sc.deinit(gpa);
        var op_sc = Scratch{};

        const meta = backend.Meta{ .capture_count = h.capture_count };
        const PE = backend.Engine(pikevm);
        for (diff_inputs) |in| {
            var a: [16]?usize = undefined;
            var b: [16]?usize = undefined;
            const ra = PE.captures(&pv, &pv_sc, in, &a, meta, .{}) != null;
            const rb = E.captures(&op, &op_sc, in, &b, meta, .{}) != null;
            if (ra != rb) {
                std.debug.print("MATCH DISAGREE pat=\"{s}\" in=\"{s}\" pike={} onepass={}\n", .{ pat, in, ra, rb });
                return error.MatchDisagree;
            }
            if (ra) {
                const sc = meta.slotLen();
                if (!std.mem.eql(?usize, a[0..sc], b[0..sc])) {
                    std.debug.print("SLOTS DISAGREE pat=\"{s}\" in=\"{s}\"\n  pike={any}\n  1pass={any}\n", .{ pat, in, a[0..sc], b[0..sc] });
                    return error.SlotsDisagree;
                }
            }
        }
    }
}

// ── revert-failing regression: detection + executor must match the Pike VM exactly ──

test "onepass: regression — date captures equal the Pike VM, byte for byte" {
    const gpa = testing.allocator;
    const pat = "(\\d{4})-(\\d{2})-(\\d{2})";
    const in = "log 2026-06-14 end";
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, pat, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);

    var op = try buildAlloc(gpa, h, .{}); // MUST build (one-pass) — a regression here fails loudly
    defer freeProgram(gpa, &op);
    var pv = try pikevm.buildAlloc(gpa, h, .{});
    defer pikevm.freeProgram(gpa, &pv);
    var pv_sc = try pikevm.Scratch.init(gpa, &pv);
    defer pv_sc.deinit(gpa);
    var op_sc = Scratch{};

    const meta = backend.Meta{ .capture_count = h.capture_count };
    const PE = backend.Engine(pikevm);
    var a: [8]?usize = undefined;
    var b: [8]?usize = undefined;
    try testing.expect(PE.captures(&pv, &pv_sc, in, &a, meta, .{}) != null);
    try testing.expect(E.captures(&op, &op_sc, in, &b, meta, .{}) != null);
    try testing.expectEqualSlices(?usize, &a, &b);
}

// ── comptime ──────────────────────────────────────────────────────────────────────

test "onepass: captures at COMPTIME (frozen table in ro_data)" {
    const ok = comptime blk: {
        @setEvalBranchQuota(3_000_000);
        const a = compile.compile("(\\w+)@(\\w+)");
        const hh = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(hh, .{});
        var sc = Scratch{};
        var slots: [6]?usize = undefined;
        const input = "user@host";
        const c = E.captures(&program, &sc, input, &slots, .{ .capture_count = 2 }, .{}) orelse
            @compileError("no captures");
        break :blk std.mem.eql(u8, c.groupSlice(1).?, "user") and std.mem.eql(u8, c.groupSlice(2).?, "host");
    };
    try testing.expect(ok);
}

test {
    testing.refAllDecls(@This());
}
