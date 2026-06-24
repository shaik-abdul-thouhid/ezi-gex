//! Bounded backtracking backend — depth-first NFA search with memoization.
//!
//! Executes the *same* `engine/nfa.zig` program as the Pike VM, but depth-first:
//! it follows the highest-priority branch first and backtracks on failure, so it
//! is naturally leftmost-first and reports captures with the same semantics as the
//! Pike VM (the shared program guarantees bit-for-bit agreement). A `(pc, sp)`
//! **visited set** memoizes dead ends, which is what keeps it linear-time
//! (`O(program × input)`) and kills catastrophic backtracking — `(a*)*b` does not
//! explode here.
//!
//! Why have it at all when the Pike VM is also linear? Backtracking has smaller
//! constants on the common case (it explores one path at a time instead of a whole
//! thread set), so `auto` prefers it for **small inputs**, falling back to the
//! Pike VM for large ones. That is the "switch on the input" half of the dispatcher
//! — and the reason backtracking is *bounded*: its visited set is sized
//! `program × (input+1)` bits, so memory grows with the input. A heap `Scratch`
//! grows it on demand; a fixed-buffer `Scratch` has a hard ceiling (the "with
//! limits" path). `fits()` reports whether a given input is within a buffer's
//! ceiling, so `auto` only ever routes inputs that fit.
//!
//! Comptime + runtime: `Program` is the shared NFA program (ro_data or heap), and
//! the `Scratch` carves one `[]Cell` buffer, so the same `initBuffer` runs at
//! comptime (tiny inputs always fit a modest buffer) and at runtime.
//!
//! ## Resource bounds (read before using this backend directly)
//!
//! *Time* is linear and ReDoS-immune: the `(pc, sp)` memo admits each state once, so
//! the work count is bounded by `program × (input+1)` for **every** pattern, including
//! `(a+)+$` / `(a*)*b` (`Scratch.steps` exposes the count; `engine/redos.zig` pins the
//! linearity deterministically). *Stack* is the catch: `backtrack()` recurses natively,
//! and on a quantified subpattern the recursion depth grows with the **matched length**
//! (see its doc) — so a long enough input **overflows the stack and crashes**. This is a
//! stack-exhaustion limit, not a time blowup.
//!
//! Therefore the bare `backtrack` backend is a **bounded-input** tool. The default
//! `auto` dispatcher shields you: it routes only inputs `≤ BACKTRACK_MAX_INPUT` (4096)
//! here and runs the iterative Pike VM above that, so the default non-grapheme path
//! never recurses deep. The one uncapped path is grapheme (`\X`) — backtrack is the only
//! `\X`-capable backend, so `auto` sends it the full input; a large *quantified*-`\X`
//! match is a documented constraint, not yet fixed (an explicit heap-stack rewrite would
//! lift it). If you select `backtrack` explicitly, keep inputs bounded or use `auto`.
//!
//! Per-search clearing — only what was dirtied. A naive backtracker `@memset`s the
//! whole `program × (input+1)`-bit visited set before every search, which is
//! `O(program × input)` even when the match is found at offset 0 after touching a
//! handful of `(pc, sp)` cells. Instead the `Scratch` keeps a **touched-words list**
//! (`touched`, `touched_count`): the first time a bit is set in a visited *word*
//! during a run, that word's index is appended to the list; the NEXT run clears only
//! the words on that list (then empties it), rather than memsetting the whole prefix.
//! The memo is intentionally shared across the multi-start scan within one `run`, so
//! the list accumulates across starts and is cleared only between separate searches.
//! Each word is recorded at most once (a word is appended only on the `0 → nonzero`
//! transition), so the list is bounded by the number of *distinct* words touched —
//! ≤ the full word count. Worst case (a search that touches every word) is therefore
//! no worse than the old full memset; the common early-exit case is far cheaper. The
//! list is one extra `[]Cell` region the size of the visited set: `init` allocates it
//! alongside the grown visited set, `initBuffer` carves it from the same buffer (so a
//! fixed buffer's input ceiling halves — `bufferLen`/`fits` account for it).

const std = @import("std");

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const nfa = @import("engine_base").nfa;

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const Cell = backend.Cell;

const WORD_BITS: usize = @bitSizeOf(usize);

/// Input length a default fixed buffer (`bufferLen`) is sized to support. A bigger
/// buffer raises the ceiling automatically (`initBuffer` gives all slack to the
/// visited set); `auto`/heap raise it as needed.
const DEFAULT_MAX_INPUT: usize = 64;

// ── Contract surface ────────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = true };
/// @stable-since: v0.1.0
pub const Options = struct {};

/// Same compiled NFA the Pike VM uses (from the shared `nfa` module).
pub const Inst = nfa.Inst;
pub const Program = nfa.Program;

/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    return nfa.buildAlloc(gpa, h);
}
/// @stable-since: v0.1.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    return nfa.buildComptime(h);
}
/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    nfa.freeProgram(gpa, program);
}

/// Words a visited bitset needs for `program × (input+1)` states.
fn visitedWords(nprog: usize, n: usize) usize {
    const bits = nprog * (n + 1);
    return (bits + WORD_BITS - 1) / WORD_BITS;
}

// ── Scratch ──────────────────────────────────────────────────────────────────────

/// Per-search state: working + winning capture slots, and the input-sized visited
/// bitset. Carved from one `[]Cell` buffer. A heap `Scratch` (via `init`) grows the
/// visited set as inputs demand; a buffer `Scratch` (via `initBuffer`) has a fixed
/// ceiling — `fits()` tells you (and `auto`) whether an input is within it.
///
/// @stable-since: v0.1.0
pub const Scratch = struct {
    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = Cell;

    slots: []Cell, // .slot — working captures
    match_slots: []Cell, // .slot — winning captures
    visited: []Cell, // .w   — (pc,sp) memo bitset (input-sized)
    touched: []Cell, // .w   — indices of dirtied visited words (cleared next run)
    touched_count: usize = 0, // how many of `touched` are live for the pending clear
    cleared_words: usize = 0, // high-water mark: visited[0..cleared_words] is known-zero
    /// Backtracking work performed by the LAST `run` — one unit per `(pc, sp)` memo
    /// probe (`seen`). The visited memo admits each `(pc, sp)` exactly once, so this is
    /// bounded by `program × (input + 1)` and therefore grows **linearly** with the
    /// input on *every* pattern, catastrophic ones included (`(a+)+$`, `(a*)*b`). It is
    /// the observable that makes ReDoS-immunity *testable* rather than wall-clock-flaky:
    /// a super-linear jump in `steps` across a doubling input is a memo regression (see
    /// `engine/redos.zig`). Observational only — never read by matching, never affects a
    /// result.
    ///
    /// @stable-since: v0.3.1
    steps: u64 = 0,
    nprog: u32,
    slot_count: u32,
    gpa: ?std.mem.Allocator = null, // non-null ⇒ heap, visited may grow
    owned: ?[]Cell = null, // slots+match buffer (heap)
    owned_visited: ?[]Cell = null, // grown visited+touched (heap)

    /// Default fixed-buffer size: slots + a visited budget for inputs up to
    /// `DEFAULT_MAX_INPUT`, PLUS an equally-sized touched-words list (so the cheap
    /// per-search clear can run on a buffer scratch too). A larger buffer raises the
    /// input ceiling automatically — `initBuffer` splits the slack evenly between the
    /// visited bitset and its touched-words list, and `fits()` checks both.
    ///
    /// @stable-since: v0.1.0
    pub fn bufferLen(program: *const Program) usize {
        const sc = program.slot_count;
        return 2 * sc + 2 * visitedWords(program.insts.len, DEFAULT_MAX_INPUT);
    }

    /// Carve a caller `[]Cell` buffer: slots, match slots, then the remaining slack
    /// split evenly into the visited bitset and its same-length touched-words list (a
    /// visited word index never exceeds the visited length, so the list never needs
    /// more entries than the bitset has words). Works at comptime and runtime. The
    /// visited ceiling is `floor((buffer - 2*slot_count) / 2) words` — `fits()` checks
    /// an input against it (an odd leftover Cell is harmlessly unused).
    ///
    /// @stable-since: v0.1.0
    pub fn initBuffer(buf: []Cell, program: *const Program) backend.ScratchError!Scratch {
        const sc = program.slot_count;
        var cur = backend.Carver{ .buf = buf };
        const slots = try cur.take(sc);
        const match = try cur.take(sc);
        const slack = buf.len - cur.off; // remaining Cells for visited + touched
        const words = slack / 2; // equal split; the touched list is ≤ the bitset
        const visited = try cur.take(words);
        const touched = try cur.take(words);
        return .{
            .slots = slots,
            .match_slots = match,
            .visited = visited,
            .touched = touched,
            .nprog = @intCast(program.insts.len),
            .slot_count = @intCast(sc),
        };
    }

    /// Allocator-backed: slots up front; the visited set (and its same-length
    /// touched-words list) are grown lazily per search so any input length works
    /// (memory ∝ program × input). Both grow together in `ensureVisited`.
    ///
    /// @stable-since: v0.1.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        const sc = program.slot_count;
        const buf = try gpa.alloc(Cell, 2 * sc);
        return .{
            .slots = buf[0..sc],
            .match_slots = buf[sc .. 2 * sc],
            .visited = &.{},
            .touched = &.{},
            .nprog = @intCast(program.insts.len),
            .slot_count = @intCast(sc),
            .gpa = gpa,
            .owned = buf,
        };
    }

    /// @stable-since: v0.1.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        if (self.owned) |b| gpa.free(b);
        if (self.owned_visited) |b| gpa.free(b);
        self.owned = null;
        self.owned_visited = null;
        self.visited = &.{};
        self.touched = &.{};
        self.touched_count = 0;
        self.cleared_words = 0;
    }

    /// @stable-since: v0.1.0
    pub fn reset(self: *Scratch) void {
        // Forget any prior run: drop the pending touched-words clear AND the
        // known-zero high-water mark, so the next `run` re-zeroes the prefix it uses
        // in full (rather than trusting a touched list from a run the caller wants to
        // discard). `run` then re-establishes the invariant. Cheap — no memset here.
        self.touched_count = 0;
        self.cleared_words = 0;
    }

    /// Grow the visited set (and its same-length touched-words list) to hold at least
    /// `words` each (heap only); a fixed buffer that is too small yields
    /// `error.BufferTooSmall`. A fresh allocation is UNINITIALISED, so the high-water
    /// mark is reset to 0 — the next `run` then full-zeroes the prefix it uses before
    /// relying on the touched-words clear. One allocation backs both halves
    /// (`[0..words]` visited, `[words..2*words]` touched), so they free together.
    fn ensureVisited(self: *Scratch, words: usize) backend.ScratchError!void {
        if (self.visited.len >= words) return;
        const g = self.gpa orelse return error.BufferTooSmall;
        const newbuf = try g.alloc(Cell, 2 * words);
        if (self.owned_visited) |ov| g.free(ov);
        self.owned_visited = newbuf;
        self.visited = newbuf[0..words];
        self.touched = newbuf[words .. 2 * words];
        self.touched_count = 0; // the prior list pointed into the freed buffer
        self.cleared_words = 0; // fresh memory is uninitialised → force a full zero
    }
};

/// Whether `input` is within this scratch's visited ceiling. A heap scratch always
/// fits (it grows); a buffer scratch fits iff the input's bitset AND its same-length
/// touched-words list both fit the slack (`initBuffer` sizes them equally, so this is
/// `min(visited, touched)`). `auto` consults this before routing to the backtracker.
///
/// @stable-since: v0.1.0
pub fn fits(program: *const Program, scratch: *const Scratch, input: []const u8) bool {
    if (scratch.gpa != null) return true;
    return visitedWords(program.insts.len, input.len) <= @min(scratch.visited.len, scratch.touched.len);
}

// ── The backtracker ──────────────────────────────────────────────────────────────

const Ctx = struct {
    program: *const Program,
    input: []const u8,
    visited: []Cell,
    touched: []Cell, // dirtied visited-word indices (read as .w), for the next clear
    touched_count: usize, // live length of `touched`; written back to the scratch
    slots: []Cell,
    match_slots: []Cell,
    stride: usize, // input.len + 1
    steps: u64, // `(pc, sp)` memo probes this run (persisted to Scratch.steps)
};

/// Test-and-set the `(pc, sp)` memo bit; returns whether it was already set. On the
/// `0 → nonzero` transition of a visited word (its first set bit this run) the word's
/// index is appended to the touched-words list so the next `run` can clear exactly
/// the dirtied words instead of the whole bitset. The `== 0` test fires at most once
/// per word per run (a word stays nonzero afterwards), so the list holds each touched
/// word exactly once and is bounded by the distinct words touched.
fn seen(ctx: *Ctx, pc: u32, sp: usize) bool {
    ctx.steps += 1; // one unit of backtracking work — the linear-time observable
    const idx = @as(usize, pc) * ctx.stride + sp;
    const w = idx / WORD_BITS;
    const bit = @as(usize, 1) << @intCast(idx % WORD_BITS);
    const cur = ctx.visited[w].w;
    if (cur == 0) { // first bit set in this word this run → record it for clearing
        ctx.touched[ctx.touched_count] = .{ .w = w };
        ctx.touched_count += 1;
    }
    ctx.visited[w].w = cur | bit;
    return (cur & bit) != 0;
}

/// Read-only test of the `(pc, sp)` memo bit — like `seen` but with **no** set and no
/// `steps`/`touched` side effects. Used by the empty-width-loop guard to ask "did we
/// enter this loop head at the current position?" without marking the state explored.
fn peekSeen(ctx: *const Ctx, pc: u32, sp: usize) bool {
    const idx = @as(usize, pc) * ctx.stride + sp;
    const w = idx / WORD_BITS;
    const bit = @as(usize, 1) << @intCast(idx % WORD_BITS);
    return (ctx.visited[w].w & bit) != 0;
}

/// Depth-first match from `(pc0, sp0)`. Returns whether a match was found; on the
/// first (highest-priority) match it snapshots captures into `match_slots`. The
/// `seen` memo prunes already-explored states, giving linear *time* and termination
/// (an empty-width cycle revisits a `(pc, sp)` and is cut).
///
/// Recursion depth — **proportional to the matched-repetition length, NOT bounded by
/// the program.** Native recursion happens on two arms: `split.a` (the higher-priority
/// branch — its `split.b` continuation is carried by the while-loop's tail) and `.save`
/// (which must recurse so it can undo the slot on backtrack). The catch: a quantified
/// subpattern loops back into its OWN `split` after consuming input, and each
/// iteration's `split.a`/`.save` frame stays live until the whole match resolves — so a
/// long run matched by `a+`, `(a|a)*`, `\X+`, … recurses once per consumed unit. Depth
/// therefore grows with the input, and a long enough input **overflows the native stack
/// (a crash)**. This is a stack-exhaustion limit, NOT a time blowup — `seen` keeps the
/// step count strictly linear regardless (`engine/redos.zig` pins that with a
/// deterministic work-count test, and `Scratch.steps` exposes it).
///
/// Consequence (see the module header → "Resource bounds"): the bare `backtrack`
/// backend is a **bounded-input** tool. `auto` enforces this by routing only inputs
/// `≤ BACKTRACK_MAX_INPUT` here and running the iterative Pike VM (no input-proportional
/// stack) above it. The sole uncapped path is grapheme (`\X`) matching — backtrack is
/// the only `\X`-capable backend, so `auto` hands it the full input; a large
/// *quantified*-`\X` input is therefore a documented constraint. (An explicit
/// heap-stack rewrite would erase the limit entirely; deferred — the cap covers the
/// default non-grapheme path.)
fn backtrack(ctx: *Ctx, pc0: u32, sp0: usize) bool {
    var pc = pc0;
    var sp = sp0;
    while (true) {
        if (seen(ctx, pc, sp)) return false; // already explored ⇒ same (failing) outcome
        switch (ctx.program.insts[pc]) {
            .match => {
                @memcpy(ctx.match_slots, ctx.slots);
                return true;
            },
            .char => |ch| {
                if (sp >= ctx.input.len) return false;
                const d = nfa.decodeAt(ctx.input, sp);
                if (!d.valid or d.cp != ch) return false; // dead-on-invalid
                pc += 1;
                sp += d.len;
            },
            .range => |r| {
                if (sp >= ctx.input.len) return false;
                const d = nfa.decodeAt(ctx.input, sp);
                if (!d.valid or !nfa.inRanges(ctx.program.ranges[r.start .. r.start + r.len], d.cp)) return false;
                pc += 1;
                sp += d.len;
            },
            .any => |a| {
                if (sp >= ctx.input.len) return false;
                const d = nfa.decodeAt(ctx.input, sp);
                if (!d.valid or !(a.dot_all or d.cp != '\n')) return false; // `.` never matches an invalid byte
                pc += 1;
                sp += d.len;
            },
            .grapheme => {
                // `\X`: consume one whole extended grapheme cluster. Variable width —
                // the depth-first backtracker advances `sp` by the cluster length,
                // which the breadth-first Pike VM cannot do (hence backtrack-only).
                if (sp >= ctx.input.len) return false; // no cluster to consume
                pc += 1;
                sp += nfa.graphemeLenAt(ctx.input, sp);
            },
            .jmp => |t| {
                // Empty-width-loop guard (mirrors the Pike VM closure). The only BACKWARD
                // jmp the compiler emits is an unbounded repetition's loop-back, whose exit
                // is always `pc + 1` (the `after` label); alternation enders jmp forward.
                // If the loop head `t` was already entered at THIS position (`peekSeen`), the
                // iteration matched empty — leftmost-first terminates the loop, so take the
                // exit directly (at the empty path's depth-first priority) rather than looping
                // back into the head (which the `seen` memo would dead-end, only then trying
                // the exit *below* a lower-priority consuming sibling). A forward jmp, or a
                // back-edge whose head is unseen at this sp (a real non-empty iteration),
                // loops as before. Fixes `(?:a?b??)+` on "ab" → "a". See nfa.zig.
                if (t < pc and peekSeen(ctx, t, sp)) {
                    pc += 1; // empty iteration → loop exit (`after`)
                } else pc = t;
            },
            .assertion => |k| {
                if (!nfa.assertionHolds(k, ctx.input, sp)) return false;
                pc += 1;
            },
            .split => |s| {
                // Primary arm first (higher priority); on failure, fall through to
                // the secondary arm as the loop's tail.
                if (backtrack(ctx, s.a, sp)) return true;
                pc = s.b;
            },
            .save => |slot| {
                // `slot` indices come from the NFA compiler, every one `< slot_count`,
                // and `slots` is always sized exactly `slot_count` (`Scratch.init`/
                // `initBuffer`), so an out-of-range slot is impossible by construction.
                // Assert the invariant rather than silently skipping (a skipped save
                // would drop a capture, a quiet correctness bug); the recurse/undo path
                // is the only real behaviour.
                std.debug.assert(slot < ctx.slots.len);
                const old = ctx.slots[slot].slot;
                ctx.slots[slot] = .{ .slot = sp };
                if (backtrack(ctx, pc + 1, sp)) return true;
                ctx.slots[slot] = .{ .slot = old }; // undo on backtrack
                return false;
            },
        }
    }
}

fn run(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    const words = visitedWords(program.insts.len, input.len);
    // Grow if needed. A fixed buffer that cannot hold this input panics by design:
    // the contract's `search`/`isMatch` have no error channel, and `auto` pre-checks
    // with `fits()` so it never routes an oversized input here — a panic means a
    // direct caller skipped that guard. `init()` (heap) always grows; raise the
    // buffer (its ceiling halved to make room for the touched-words list, see
    // `bufferLen`) or use `init()` to lift the cap.
    scratch.ensureVisited(words) catch
        @panic("ezi_gex backtrack: input exceeds buffer-backed scratch capacity; enlarge the buffer (bufferLen), use init(), or let `auto`/fits() route it");

    // Establish an all-zero `visited[0..words]` cheaply. Steady state (`words` within
    // the known-zero high-water mark): clear ONLY the words the previous run dirtied —
    // the touched-words list — instead of memsetting the whole `program × (input+1)`-bit
    // prefix. First use of a (possibly larger) prefix, or freshly-(re)allocated memory:
    // `words > cleared_words`, so full-zero the prefix this once and raise the mark; the
    // touched list is then subsumed by that memset. The touched list is rebuilt below.
    if (words > scratch.cleared_words) {
        @memset(scratch.visited[0..words], .{ .w = 0 });
        scratch.cleared_words = words;
    } else {
        for (scratch.touched[0..scratch.touched_count]) |t| scratch.visited[t.w].w = 0;
    }
    scratch.touched_count = 0;

    var ctx = Ctx{
        .program = program,
        .input = input,
        .visited = scratch.visited,
        .touched = scratch.touched,
        .touched_count = 0,
        .slots = scratch.slots,
        .match_slots = scratch.match_slots,
        .stride = input.len + 1,
        .steps = 0,
    };
    // Leftmost: try start positions in order; the visited memo is shared across
    // starts (a `(pc, sp)` failure is start-independent), so the whole scan stays
    // O(program × input), not O(program × input²). The touched-words list accumulates
    // across starts for the same reason — it is cleared only between separate `run`s.
    var start = opts.start;
    while (start <= input.len) {
        @memset(scratch.slots, .{ .slot = null });
        if (backtrack(&ctx, 0, start)) {
            scratch.touched_count = ctx.touched_count; // persist for the next clear
            scratch.steps = ctx.steps; // persist the work count (ReDoS observable)
            return true;
        }
        if (opts.anchored) break;
        // Advance to the next code-point boundary — 1 byte for ASCII / an invalid lead,
        // the full sequence length for a valid multi-byte lead — so an unanchored scan never
        // *starts* a match mid-code-point over valid UTF-8. This mirrors the Pike VM's
        // `sp += cp_len` monotonic scan; a byte-by-byte `start += 1` would otherwise report a
        // spurious zero-width match (e.g. `\B`) at an interior byte of a multi-byte code point.
        start += if (start < input.len) nfa.decodeAt(input, start).len else 1;
    }
    scratch.touched_count = ctx.touched_count; // persist for the next clear
    scratch.steps = ctx.steps; // persist the work count (ReDoS observable)
    return false;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.1.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return run(program, scratch, input, opts);
}

/// @stable-since: v0.1.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    if (!run(program, scratch, input, opts)) return null;
    return .{ .start = scratch.match_slots[0].slot.?, .end = scratch.match_slots[1].slot.? };
}

/// @stable-since: v0.1.0
pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots_out: []?usize, opts: SearchOptions) ?Match {
    if (!run(program, scratch, input, opts)) return null;
    const k = @min(slots_out.len, scratch.match_slots.len);
    var i: usize = 0;
    while (i < k) : (i += 1) slots_out[i] = scratch.match_slots[i].slot;
    return .{ .start = scratch.match_slots[0].slot.?, .end = scratch.match_slots[1].slot.? };
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("core").compile;
const E = backend.Engine(@This());

const Compiled = struct {
    program: Program,
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
        return .{ .program = program, .scratch = try Scratch.init(gpa, &program) };
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

test "backtrack satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "literals, classes, dot" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("a.c", "a c", "a c");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "héllo, wörld", "héllo"); // unicode
}

test "alternation leftmost-first + quantifiers" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("a|ab", "ab", "a");
    try expectFind("ab|a", "ab", "ab");
    try expectFind("ab*", "abbbc", "abbb");
    try expectFind("a.*?c", "abXcYc", "abXc"); // lazy
    try expectFind("a{2,4}", "aaaaaa", "aaaa");
    try expectFind("(ab){2,3}", "ababab", "ababab");
}

test "empty-width-loop guard: an empty iteration terminates the loop (leftmost-first)" {
    // Mirrors the Pike VM: the depth-first backtracker takes the empty-iteration exit at the
    // empty path's priority instead of looping into a consuming sibling.
    try expectFind("(?:a?b??)+", "ab", "a");
    try expectSpan("(?:a??b??)+", "ab", 0, 0);
    try expectFind("(?:a?b??)+x", "abx", "abx"); // body still consumes when forced
    try expectFind("(?:a?b?)+", "ab", "ab"); // greedy body consumes
    try expectFind("(a|)+", "aa", "aa"); // consuming-first alternation branch
}

test "anchors and word boundaries" {
    try expectFind("^abc", "abcdef", "abc");
    try expectNoMatch("^abc", "xabc");
    try expectFind("abc$", "xxabc", "abc");
    try expectSpan("\\bcat\\b", "a cat!", 2, 5);
    try expectNoMatch("\\bcat\\b", "category");
}

fn expectSpan(pattern: []const u8, input: []const u8, start: usize, end: usize) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = re.find(input) orelse return error.NoMatch;
    try testing.expectEqual(start, m.start);
    try testing.expectEqual(end, m.end);
}

test "captures + named groups" {
    var re = try Compiled.init("(\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    var slots: [8]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "x 2026-06-07 y", &slots, .{ .capture_count = 3 }, .{}).?;
    try testing.expectEqualStrings("2026-06-07", c.match().slice("x 2026-06-07 y"));
    try testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try testing.expectEqualStrings("06", c.groupSlice(2).?);
    try testing.expectEqualStrings("07", c.groupSlice(3).?);
}

test "optional group reads null when it does not participate" {
    var re = try Compiled.init("a(b)?c");
    defer re.deinit();
    var slots: [4]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "ac", &slots, .{ .capture_count = 1 }, .{}).?;
    try testing.expect(c.group(1) == null);
    const c2 = E.captures(&re.program, &re.scratch, "abc", &slots, .{ .capture_count = 1 }, .{}).?;
    try testing.expectEqualStrings("b", c2.groupSlice(1).?);
}

test "NO catastrophic backtracking: (a*)*b memoized" {
    var re = try Compiled.init("(a*)*b");
    defer re.deinit();
    var ibuf: [120]u8 = undefined; // would be exponential without the (pc,sp) memo
    @memset(&ibuf, 'a');
    try testing.expect(re.find(&ibuf) == null); // no 'b' → no match, returns fast
    var ibuf2: [32]u8 = undefined;
    @memset(&ibuf2, 'a');
    ibuf2[31] = 'b';
    try testing.expect(re.find(&ibuf2) != null);
}

test "agnostic ops: findAll / count / replaceAll" {
    var re = try Compiled.init("(\\w+)@(\\w+)");
    defer re.deinit();
    var slots: [6]?usize = undefined;
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&re.program, &re.scratch, "from a@b to c@d", "$2.$1", &slots, .{ .capture_count = 2 }, &w);
    try testing.expectEqualStrings("from b.a to d.c", w.buffered());
}

test "runtime buffer scratch + fits()" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "[a-z]+\\d+", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);

    var buf: [4096]Cell = undefined;
    var sc = try Scratch.initBuffer(&buf, &program);
    try testing.expect(fits(&program, &sc, "??abc123!!"));
    try testing.expectEqualStrings("abc123", E.find(&program, &sc, "??abc123!!", .{}).?.slice("??abc123!!"));

    // A buffer with only enough room for the slot arrays (no visited slack) fits no
    // non-empty input — `auto` would route such an input to the Pike VM instead.
    var slots_only: [4]Cell = undefined; // slot_count = 2 → slots(2) + match(2)
    var sc2 = try Scratch.initBuffer(&slots_only, &program);
    try testing.expect(!fits(&program, &sc2, "x"));
}

test "comptime captures via buffer scratch" {
    const ok = comptime blk: {
        @setEvalBranchQuota(3_000_000);
        const a = compile.compile("(\\w+)@(\\w+)");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var buf: [Scratch.bufferLen(&program)]Cell = undefined;
        var sc = Scratch.initBuffer(&buf, &program) catch unreachable;
        var slots: [6]?usize = undefined;
        const input = "user@host";
        const c = E.captures(&program, &sc, input, &slots, .{ .capture_count = 2 }, .{}) orelse
            @compileError("no captures at comptime");
        break :blk std.mem.eql(u8, c.groupSlice(1).?, "user") and std.mem.eql(u8, c.groupSlice(2).?, "host");
    };
    try testing.expect(ok);
}

// ── Touched-words clearing scheme: results-invariance + reuse correctness ─────────

test "touched-list clear is results-invariant across a battery of patterns" {
    // Each row asserts an exact leftmost-first span the engine must report regardless
    // of how the visited set is cleared. Run on a freshly-built Compiled (so the FIRST
    // run hits the full-zero / high-water branch) and again on the same scratch (so the
    // SECOND hits the touched-list branch) — both must agree.
    const Row = struct { pat: []const u8, input: []const u8, expect: ?[]const u8 };
    const rows = [_]Row{
        .{ .pat = "abc", .input = "xxabcyy", .expect = "abc" },
        .{ .pat = "a.c", .input = "a\nc", .expect = null },
        .{ .pat = "[a-z]+", .input = "ABCdefGHI", .expect = "def" },
        .{ .pat = "\\d+", .input = "abc123def", .expect = "123" },
        .{ .pat = "cat|dog", .input = "i have a dog", .expect = "dog" },
        .{ .pat = "a|ab", .input = "ab", .expect = "a" },
        .{ .pat = "ab|a", .input = "ab", .expect = "ab" },
        .{ .pat = "a.*?c", .input = "abXcYc", .expect = "abXc" },
        .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
        .{ .pat = "(ab){2,3}", .input = "ababab", .expect = "ababab" },
        .{ .pat = "\\bcat\\b", .input = "a cat!", .expect = "cat" },
        .{ .pat = "\\bcat\\b", .input = "category", .expect = null },
        .{ .pat = "\\w+", .input = "héllo, wörld", .expect = "héllo" }, // multi-byte
    };
    for (rows) |row| {
        var re = try Compiled.init(row.pat);
        defer re.deinit();
        // Repeat on the SAME scratch so we exercise both the first-run (high-water)
        // and reuse (touched-list) clear paths against the identical expected result.
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const m = re.find(row.input);
            if (row.expect) |e| {
                try testing.expectEqualStrings(e, (m orelse return error.NoMatch).slice(row.input));
            } else {
                try testing.expect(m == null);
            }
        }
    }
}

test "touched-list clear resets correctly between mismatched/matched searches" {
    // Interleave matching and non-matching inputs on ONE scratch. If the touched-list
    // clear ever leaks a dirty `(pc, sp)` bit into the next search, a later run would
    // wrongly prune a live path (false negative) or accept a dead one. Loop so the
    // touched list is built, cleared, and rebuilt many times.
    var re = try Compiled.init("[a-z]+\\d+");
    defer re.deinit();
    const matching = "  abc123  ";
    const nonmatching = "  ABC!!!  ";
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        try testing.expectEqualStrings("abc123", re.find(matching).?.slice(matching));
        try testing.expect(re.find(nonmatching) == null);
        try testing.expect(re.find(nonmatching) == null); // two misses in a row
        try testing.expectEqualStrings("abc123", re.find(matching).?.slice(matching));
    }
}

test "touched-list clear stays correct as the input length grows then shrinks" {
    // A larger input raises `words` past the high-water mark (full-zero branch once);
    // a subsequent SHORTER input falls back to the touched-list branch and must still
    // see an all-zero prefix. Mixing lengths on one scratch is the regression target.
    var re = try Compiled.init("x\\d+");
    defer re.deinit();
    const lens = [_]usize{ 8, 200, 16, 512, 4 };
    const gpa = testing.allocator;
    for (lens) |n| {
        const inp = try gpa.alloc(u8, n);
        defer gpa.free(inp);
        @memset(inp, '.');
        if (n >= 3) {
            inp[n - 3] = 'x';
            inp[n - 2] = '4';
            inp[n - 1] = '2';
            try testing.expectEqualStrings("x42", re.find(inp).?.slice(inp));
        } else {
            try testing.expect(re.find(inp) == null);
        }
    }
}

test "captures survive the touched-list clear across repeated searches" {
    var re = try Compiled.init("(\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    var slots: [8]?usize = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const c = E.captures(&re.program, &re.scratch, "x 2026-06-07 y", &slots, .{ .capture_count = 3 }, .{}).?;
        try testing.expectEqualStrings("2026-06-07", c.match().slice("x 2026-06-07 y"));
        try testing.expectEqualStrings("2026", c.groupSlice(1).?);
        try testing.expectEqualStrings("06", c.groupSlice(2).?);
        try testing.expectEqualStrings("07", c.groupSlice(3).?);
        // A non-match between captures must not corrupt the next capture's slots.
        try testing.expect(E.captures(&re.program, &re.scratch, "nope", &slots, .{ .capture_count = 3 }, .{}) == null);
    }
}

test "memo still shared across start positions: (a*)*b stays linear on a big input" {
    // The shared memo (and the touched list that accumulates across starts within ONE
    // run, cleared only between runs) is what makes this not explode. A larger input
    // than the existing test, run repeatedly on one scratch, would blow up time/memory
    // if a start position ever reset the memo or the touched list overflowed.
    var re = try Compiled.init("(a*)*b");
    defer re.deinit();
    const gpa = testing.allocator;
    const big = try gpa.alloc(u8, 2000); // exponential without the (pc,sp) memo
    defer gpa.free(big);
    @memset(big, 'a');
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        try testing.expect(re.find(big) == null); // no 'b' → no match, returns fast
    }
    big[big.len - 1] = 'b';
    try testing.expect(re.find(big) != null);
}

test "findAll / count over many matches on one scratch (touched list rebuilt per match)" {
    var re = try Compiled.init("[a-z]+\\d");
    defer re.deinit();
    const input = "a1 bb2 ccc3 d4 ee5";
    // count walks findAll, each step a fresh `search` on the same scratch.
    try testing.expectEqual(@as(usize, 5), E.count(&re.program, &re.scratch, input, .{}));
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("a1", it.next().?.slice(input));
    try testing.expectEqualStrings("bb2", it.next().?.slice(input));
    try testing.expectEqualStrings("ccc3", it.next().?.slice(input));
    try testing.expectEqualStrings("d4", it.next().?.slice(input));
    try testing.expectEqualStrings("ee5", it.next().?.slice(input));
    try testing.expect(it.next() == null);
}

test "buffer-scratch fits() boundary after the touched-list bufferLen change" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "[a-z]+\\d+", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);

    // `bufferLen` now budgets visited + an equal touched list for DEFAULT_MAX_INPUT.
    // Build a buffer with EXACTLY one input's worth of slack and probe the boundary:
    // an input that needs `words` fits, one that needs `words + 1` does not, and the
    // ceiling must be the SAME whether measured by visited or touched (they are equal).
    const sc_count = program.slot_count;
    const want_words = visitedWords(program.insts.len, 40); // pick a mid-size input
    const buf = try gpa.alloc(Cell, 2 * sc_count + 2 * want_words);
    defer gpa.free(buf);
    var sc = try Scratch.initBuffer(buf, &program);
    try testing.expectEqual(want_words, sc.visited.len);
    try testing.expectEqual(want_words, sc.touched.len); // equal split

    // An input whose bitset needs ≤ want_words fits; one needing more does not.
    const fit_n = 40;
    const fit_in = try gpa.alloc(u8, fit_n);
    defer gpa.free(fit_in);
    @memset(fit_in, '.');
    try testing.expect(fits(&program, &sc, fit_in));

    // Find the first input length whose word count exceeds want_words and confirm
    // fits() flips to false there — the ceiling is honoured exactly.
    var n: usize = fit_n;
    while (visitedWords(program.insts.len, n) <= want_words) : (n += 1) {}
    const over_in = try gpa.alloc(u8, n);
    defer gpa.free(over_in);
    @memset(over_in, '.');
    try testing.expect(!fits(&program, &sc, over_in));

    // And a real search on a fitting input still produces the right span.
    @memcpy(fit_in[10 .. 10 + 6], "abc123");
    try testing.expectEqualStrings("abc123", E.find(&program, &sc, fit_in, .{}).?.slice(fit_in));
}

test "buffer scratch: repeated searches reuse the touched-list clear (no full memset path)" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "(\\w+)@(\\w+)", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);

    var buf: [8192]Cell = undefined;
    var sc = try Scratch.initBuffer(&buf, &program);
    var slots: [6]?usize = undefined;
    // First search establishes the high-water mark; the rest hit the touched-list
    // branch on the fixed buffer. All must agree (same captures, same misses).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const c = E.captures(&program, &sc, "to alice@host now", &slots, .{ .capture_count = 2 }, .{}).?;
        try testing.expectEqualStrings("alice", c.groupSlice(1).?);
        try testing.expectEqualStrings("host", c.groupSlice(2).?);
        try testing.expect(E.captures(&program, &sc, "no at sign", &slots, .{ .capture_count = 2 }, .{}) == null);
    }
}

test "reset() forces a clean prefix on the next search" {
    var re = try Compiled.init("[a-z]+\\d+");
    defer re.deinit();
    try testing.expectEqualStrings("abc123", re.find("  abc123  ").?.slice("  abc123  "));
    re.scratch.reset(); // drop the touched list + high-water mark
    try testing.expectEqual(@as(usize, 0), re.scratch.touched_count);
    try testing.expectEqual(@as(usize, 0), re.scratch.cleared_words);
    // Next search must re-zero the prefix and still be correct.
    try testing.expectEqualStrings("xyz789", re.find("..xyz789!!").?.slice("..xyz789!!"));
}

test {
    testing.refAllDecls(@This());
}
