//! Eager DFA backend — a **fully determinized**, frozen byte DFA (comptime + runtime).
//!
//! Where `dfa.zig` is the *lazy* DFA (it determinizes the byte Thompson NFA on the fly
//! and caches `(state, class)` edges in a caller-owned `Scratch`), this backend
//! determinizes the **whole** automaton **at build time** and freezes the result into an
//! immutable transition table. Because the table is complete, matching is a bare
//! table walk that needs **no per-search state at all** — so, unlike the lazy DFA, this
//! backend has an **empty `Scratch`** and builds at **comptime** (`buildComptime`) as
//! well as runtime. It is the CTRE-lane DFA: a literal or ASCII-class pattern bakes into
//! a handful of states / a few hundred bytes of `ro_data` (`abc` is 5 states, `[a-z]+`
//! is 3), and the matcher is a pure `state = trans[state][class]` loop with zero decode.
//! A big *Unicode* class is a few hundred states with a correspondingly large **dense**
//! table (`\w+` ≈ 323 states / ~145 KB) — minimization and a sparse encoding are the
//! obvious follow-ups; such patterns are usually better left to the runtime lazy DFA.
//!
//! ## What it is (and is not)
//!
//!   * **Span-only** (`caps.captures = false`), exactly like `dfa.zig`: it locates the
//!     match **span** `[start, end)`; `captures`/`replaceAll` are a `@compileError` on
//!     `Engine(edfa)` (route them through `auto`/`pikevm`). The code-point Pike VM fills
//!     captures and evaluates Unicode `\b` over the span.
//!   * **Stateless** (`caps.stateless = true`): the frozen table is the whole matcher;
//!     `Scratch` is `struct{}` with no-op lifecycle (like `literal.zig`). One immutable
//!     `Program` is freely shareable across threads with no scratch coordination.
//!   * **Comptime *and* runtime.** `buildComptime` determinizes into `ro_data`;
//!     `buildAlloc` determinizes onto the heap. Both run the *same* determinizer over
//!     caller-supplied fixed buffers — the lazy DFA's allocator-backed state map can't
//!     run at comptime, which is precisely why that one is runtime-only and this one is
//!     not.
//!   * **Leftmost-first**, identical to every other backend. Determinization keeps the
//!     NFA states in **priority order** and **cuts on match** (a `match` in the closure
//!     discards every lower-priority thread) — the same rule the Pike VM and lazy DFA
//!     use — so a span never disagrees with them (`conformance.zig`).
//!   * **Bounded.** Eager determinization must terminate into fixed storage, so a pattern
//!     whose DFA exceeds `max_states` states (or whose state sets overflow the pc pool)
//!     is declined: `error.Unsupported` at runtime, a `@compileError` at comptime. Such
//!     patterns keep running on the lazy DFA (unbounded) or the code-point engines. The
//!     CTRE lane is small, eager-friendly patterns; big Unicode classes repeated many
//!     times are a runtime-lazy-DFA job. `supports(hir)` gates the same shapes
//!     `dfa.supports` does (byte-lowerable, only `text_start` zero-width assertions).
//!
//! ## `find` start location
//!
//! Like the lazy DFA, this backend has **no reverse DFA**: `find` locates the leftmost
//! start by an anchored restart from each candidate position (the table is shared, so
//! every restart is a bare table walk). A leading `\A`/`^` (`anchored_start`) tries only
//! offset 0. `isMatch` is the earliest-exit form of the same scan. (The lazy DFA's
//! one-pass unanchored `isMatch` via a re-seeding table is a future addition here too.)
//!
//! ## Invalid UTF-8 — dead-on-invalid, for free
//!
//! The byte lowering emits edges only for well-formed UTF-8, so a malformed byte has no
//! transition out of any state and lands in the dead state; the restart wrapper resyncs
//! past it. No validity check in the loop, no decode.

const std = @import("std");

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");
const byte = @import("../byte.zig");
const dfa = @import("dfa.zig");

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;

/// The dead / sink state — the empty set of NFA states, reserved as state `0` so the
/// hot loop tests `next == DEAD` with one comparison. Every malformed byte and every
/// non-matching transition lands here; no match is reachable from it.
const DEAD: u32 = 0;

/// Hard ceiling on the determinized state count. Eager determinization writes into
/// fixed storage, so a pattern whose *full* DFA would exceed this is declined — at
/// runtime it falls back to the (unbounded) lazy DFA, at comptime it is a `@compileError`.
/// The per-build buffers are sized to `min(instruction_count + 256, max_states)`, so a
/// small pattern (the CTRE-lane sweet spot — literals, ASCII classes) costs little even
/// though the ceiling is high. Note the count is the **whole** DFA, not the states one
/// input happens to visit: a Unicode class fans its multi-byte continuations out into a
/// few hundred states (`\w+` ≈ a few hundred, `\w+@\w+` ≈ double that), so the ceiling is
/// generous. Truly large patterns (`\p{L}{30}`) are a runtime-lazy-DFA job.
///
/// @stable-since: v0.3.0
pub const max_states: u32 = 4096;

/// Multiplier sizing the per-build pc pool relative to the byte program's instruction
/// count: the sum of all DFA states' (priority-ordered) NFA-pc lists. A handful of
/// states hold the full class alternation (~one instruction count's worth of pcs); the
/// rest are small, so a small multiple of the instruction count is ample. Overflow is
/// declined exactly like a `max_states` overflow.
const pool_factor: u32 = 16;

// ── Contract surface ──────────────────────────────────────────────────────────────

/// Span-only: the DFA finds `[start, end)`; the code-point engines fill captures and
/// evaluate Unicode `\b` over that span (so `captures`/`replaceAll` are a
/// `@compileError` on `Engine(edfa)` — route them through `auto`/`pikevm`). Stateless:
/// the frozen table is the whole matcher, so `Scratch` carries nothing.
///
/// @stable-since: v0.3.0
pub const caps = Caps{ .captures = false, .stateless = true, .grapheme = false };

/// Backend build options. The byte lowering needs nothing beyond the HIR (flags and
/// folding are already applied); the field exists to satisfy the contract shape.
///
/// @stable-since: v0.3.0
pub const Options = struct {};

/// The compiled, immutable eager DFA. It is the frozen determinization of the byte
/// automaton: `trans` is a dense `n_states × n_classes` table keyed on `classes` (the
/// program's `ByteClasses`, a handful of classes even for a large Unicode program),
/// `accept` marks accepting states, and `start0`/`startN` are the entry states (with a
/// leading `text_start` assertion true / false). Self-contained — the byte NFA it was
/// built from is freed (runtime) or transient (comptime). Build with `buildComptime`
/// (ro_data) or `buildAlloc` (heap, free with `freeProgram`).
///
/// @stable-since: v0.3.0
pub const Program = struct {
    /// Byte equivalence classes — the transition alphabet. `classes.map[b]` is the
    /// class of input byte `b`; `classes.count` is the table stride (`n_classes`).
    classes: byte.ByteClasses,
    /// Stride of `trans` (== `classes.count`), stored so the matcher needs no field math.
    n_classes: u32,
    /// Dense **anchored** transition table: `trans[state * n_classes + class]` is the
    /// next state when the match is pinned to start at the run's start position. `DEAD`
    /// (0) is the sink. Used by anchored `find`, the `find` end-extension phase, and the
    /// anchored-restart fallback.
    trans: []const u32,
    /// Dense **unanchored** transition table — each edge unions the live state's
    /// successors with a fresh start (`startN`), giving the implicit `(?s:.)*?` prefix
    /// automaton that lets a match begin at any byte. Keyed on the **same** state ids as
    /// `trans` (both are closure-canonical pc lists), so a state reached unanchored can be
    /// stepped anchored seamlessly at the find end-extension handoff. Drives one-pass
    /// `isMatch` and the forward end-find — both O(input), no per-position restart.
    ///
    /// @stable-since: v0.3.0
    utrans: []const u32,
    /// `accept[state]` — does this state contain a `match` pc (accepting) **mid-input**
    /// (reachable without an end assertion)?
    accept: []const bool,
    /// `accept_eoi[state]` — is this state accepting **at end of input**: `accept[state]`
    /// OR it holds a pending `text_end` (`$`/`\z`) assertion whose continuation reaches
    /// `match`. The matcher checks this once, when the scan reaches `input.len`. Equal to
    /// `accept` for a pattern with no `$`/`\z` (so the check is a no-op there).
    ///
    /// @stable-since: v0.3.0
    accept_eoi: []const bool,
    /// Start state with `text_start` TRUE (used at offset 0).
    start0: u32,
    /// Start state with `text_start` FALSE (offset > 0). Equals `start0` for a pattern
    /// with no `\A`/`^`.
    startN: u32,
    /// True when every match must begin at offset 0 (a leading `\A` / non-multiline `^`).
    /// The search then tries only `s == 0`.
    anchored_start: bool,
    /// True when anchored restart is **Θ(n²)-prone**: the anchored DFA has a non-accepting
    /// cycle reachable from a start (it can consume an unbounded run without ever accepting,
    /// e.g. `\w+@\w+`'s pre-`@` word run), so re-scanning it from every start is quadratic.
    /// Such a program takes the O(input) reverse-DFA `find`; a non-prone one (`\w+`, `\d+`)
    /// keeps the faster anchored restart. Computed once at build (`computeProne`).
    ///
    /// @stable-since: v0.3.0
    prone: bool,
    /// True when the byte program carries a `text_start` (`\A`/`^`) assertion yet is not
    /// fully `anchored_start` (e.g. `^abc|def`). Such a pattern keeps `find` on the
    /// anchored-restart scan (which evaluates `text_start` per start position), so the
    /// reverse DFA — whose frozen transitions must be position-independent — is not built.
    ///
    /// @stable-since: v0.3.0
    has_text_start: bool,
    /// Whether the reverse frozen table below was built. False for `has_text_start`
    /// programs (they use anchored restart); true for the common assertion-free case,
    /// where `find` is the O(input) forward-end + reverse-start two-pass.
    ///
    /// @stable-since: v0.3.0
    rev_built: bool,
    /// Frozen **reverse** DFA table: `rtrans[rstate * n_classes + class]` is the next
    /// reverse state when consuming the class representative *backward*. Reverse states are
    /// sets of forward pcs (no priority/cut — the end is already fixed, so only
    /// reachability of the forward start matters). Empty for `has_text_start` programs.
    ///
    /// @stable-since: v0.3.0
    rtrans: []const u32,
    /// `raccept[rstate]` — does this reverse state contain forward pc 0 (the forward start
    /// = the reverse accept)? Reaching it means `[pos, end)` is a full match.
    ///
    /// @stable-since: v0.3.0
    raccept: []const bool,
    /// Reverse start state — the closure of the forward `match` pcs (the reverse DFA begins
    /// "at the match" and walks back to forward pc 0). Meaningful only when `rev_built`.
    ///
    /// @stable-since: v0.3.0
    rstart: u32,
};

/// Whether this HIR can run on the eager DFA: byte-lowerable (no `\X`/`\b`) **and** whose
/// only zero-width assertions are `text_start` (`\A`/`^`, evaluated at offset 0 via two
/// start closures) and `text_end` (`$`/`\z`, evaluated at end of input via `accept_eoi`).
/// **Broader than `dfa.supports`** (the lazy DFA still declines `text_end`): `(?m)` line
/// anchors and `\b`/`\X` stay on the code-point engines. (Whether the determinized DFA
/// *fits* the fixed bounds is a separate build-time check; this is the capability gate.)
///
/// @stable-since: v0.3.0
pub fn supports(h: hir.Hir) bool {
    if (!byte.byteLowerable(h)) return false; // excludes \X and \b/\B
    for (h.nodes) |n| {
        // The eager DFA evaluates `text_start` (`\A`/`^`) at offset 0 via two start
        // closures, and `text_end` (`$`/`\z`) at end of input via an `accept_eoi` flag.
        // Line anchors (`(?m)^`/`$`) are position-dependent on the previous/next byte and
        // are not handled here (they route to the code-point engines, like `\b`).
        if (n.tag == .anchor) switch (n.data.anchor.kind) {
            .text_start, .text_end => {},
            else => return false,
        };
    }
    return true;
}

// ── Determinizer (shared by both build paths, allocation-free) ─────────────────────

/// `error.Unsupported` is raised when the determinized DFA does not fit the fixed
/// storage (more than `max_states` states, or the pc pool overflows). The caller maps
/// it to `error.Unsupported` (runtime) / a `@compileError` (comptime).
const DetError = error{Unsupported};

/// One determinization, driven over caller-supplied buffers so the identical code runs
/// at comptime (buffers are `comptime var` arrays) and runtime (buffers are allocated).
/// It mirrors the lazy DFA's closure/intern logic, but **eagerly**: every reachable
/// `(state, class)` edge is computed up front and written into `trans`, rather than
/// memoized on demand. State sets are interned by their priority-ordered pc list (a
/// flat pool + per-state offset/length), the same identity the lazy DFA uses.
const Det = struct {
    insts: []const byte.Inst,
    classes: *const byte.ByteClasses,
    class_rep: *const [256]u8,
    n_classes: u32,
    /// `reaches_end[pc]` — does `pc` reach `match` following only epsilon edges with
    /// `text_end` **passable** (the at-end-of-input view)? Used to compute `accept_eoi`
    /// when the closure records a pending `text_end` pc. All-false for a `$`-free program.
    reaches_end: []const bool,

    // ── frozen-DFA outputs (caller buffers) ──
    state_off: []u32, // state id → start of its pc list in `pc_pool`
    state_len: []u32, // state id → length of its pc list
    accept: []bool, // state id → accepting mid-input?
    accept_eoi: []bool, // state id → accepting at end of input (accept ∨ a pending `text_end`)?
    trans: []u32, // n_states × n_classes (anchored)
    utrans: []u32, // n_states × n_classes (unanchored: ∪ a fresh start each edge)
    pc_pool: []u32, // concatenated, priority-ordered pc lists
    n_states: u32 = 0,
    pool_len: u32 = 0,

    // ── per-closure work buffers (no allocation during a closure) ──
    seen: []u32, // generation-stamped pc dedup
    seen_gen: u32 = 0,
    stack: []u32, // closure DFS stack
    work: []u32, // closure result (the pc list being built)
    work_len: u32 = 0,
    work_match: bool = false,
    work_match_eoi: bool = false, // a pending `text_end` in this closure reaches match at end
    seeds: []u32, // successor pcs feeding a closure

    start0: u32 = DEAD,
    startN: u32 = DEAD,

    /// Epsilon-closure of `seeds` into `work` (priority order, deduplicated, cut on
    /// match) — the byte analogue of the Pike VM's thread closure, minus capture slots,
    /// identical to the lazy DFA's. `at_start` is whether the search position is offset 0
    /// (the only thing `text_start` depends on). A `text_end` (`$`/`\z`) is recorded as a
    /// pending **member** of the state (it consumes no byte, so the thread parks until end
    /// of input) and sets `work_match_eoi` when its continuation reaches `match` — that is
    /// how the state knows it is accepting *at end of input*. Writes
    /// `work`/`work_len`/`work_match`/`work_match_eoi`.
    fn closure(self: *Det, seeds: []const u32, at_start: bool) void {
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        self.work_len = 0;
        self.work_match = false;
        self.work_match_eoi = false;

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
                    switch (self.insts[pc]) {
                        .jmp => |t| pc = t,
                        .split => |s| {
                            self.stack[top] = s.b; // lower-priority arm waits
                            top += 1;
                            pc = s.a; // follow higher-priority arm now
                        },
                        .save => pc += 1, // captures are epsilons to the DFA
                        .assertion => |k| switch (k) {
                            // `text_start` holds iff at offset 0 (a build-time fork).
                            .text_start => {
                                if (!at_start) break :follow;
                                pc += 1;
                            },
                            // `text_end` parks here (consumes no byte): record it as a member,
                            // and mark the state accepting-at-end if it reaches `match`.
                            .text_end => {
                                self.work[self.work_len] = pc;
                                self.work_len += 1;
                                if (self.reaches_end[pc]) self.work_match_eoi = true;
                                break :follow;
                            },
                            else => break :follow, // line anchors etc. — gated out by supports()
                        },
                        .byte_range => {
                            self.work[self.work_len] = pc;
                            self.work_len += 1;
                            break :follow;
                        },
                        .match => {
                            self.work[self.work_len] = pc;
                            self.work_len += 1;
                            self.work_match = true;
                            self.work_match_eoi = true; // a mid-input match also accepts at end
                            // Cut: every lower-priority thread (on the stack or in later
                            // seeds) is discarded — the Pike VM's match cut.
                            break :seeds_loop;
                        },
                    }
                }
            }
        }
    }

    /// Intern the state currently in `work[0..work_len]` to a dense id (linear search;
    /// state counts are tiny). On a fresh state, copies the pc list into `pc_pool` and
    /// records its accepting flag. Declines (`error.Unsupported`) on overflow of either
    /// the state cap or the pc pool.
    fn intern(self: *Det) DetError!u32 {
        const key = self.work[0..self.work_len];
        var id: u32 = 0;
        while (id < self.n_states) : (id += 1) {
            const off = self.state_off[id];
            if (self.state_len[id] == key.len and std.mem.eql(u32, self.pc_pool[off .. off + key.len], key))
                return id;
        }
        if (self.n_states >= self.state_off.len) return error.Unsupported; // > max_states
        if (self.pool_len + key.len > self.pc_pool.len) return error.Unsupported; // pool full
        const off = self.pool_len;
        @memcpy(self.pc_pool[off .. off + key.len], key);
        self.state_off[id] = off;
        self.state_len[id] = @intCast(key.len);
        self.accept[id] = self.work_match;
        self.accept_eoi[id] = self.work_match_eoi;
        self.pool_len += @intCast(key.len);
        self.n_states += 1;
        return id;
    }

    /// Successor pcs of `state_id` on the class with representative byte `rep`: the
    /// `next` of every `byte_range` in the state that contains `rep`, in priority order,
    /// appended starting at `seeds[base]`. Returns the COUNT appended (so callers can
    /// union two states' successors by chaining `base`s — the unanchored row does this).
    fn collectSeeds(self: *Det, state_id: u32, rep: u8, base: u32) u32 {
        var ns: u32 = base;
        const off = self.state_off[state_id];
        for (self.pc_pool[off .. off + self.state_len[state_id]]) |pc| switch (self.insts[pc]) {
            .byte_range => |r| if (r.range.lo <= r.range.hi and r.range.contains(rep)) {
                self.seeds[ns] = r.next;
                ns += 1;
            },
            .match => {}, // terminal: no outgoing edge
            .assertion => {}, // a pending `text_end` member: no byte transition (end-only)
            else => unreachable, // a canonical state holds only byte_range / match / text_end pcs
        };
        return ns - base;
    }

    /// Determinize fully. Reserve DEAD = the empty set (state 0), intern the two start
    /// states, then breadth-first compute every `(state, class)` edge. The worklist is
    /// the growing `0..n_states` range — `intern` appends new states, the loop reaches
    /// them. Returns nothing; fills `state_*`, `accept`, `trans`, `start0`, `startN`.
    fn run(self: *Det) DetError!void {
        @memset(self.seen, 0);

        // DEAD = the empty set (work_len already 0).
        self.work_len = 0;
        self.work_match = false;
        self.work_match_eoi = false;
        std.debug.assert((try self.intern()) == DEAD);

        // Start states: closure of pc 0 with text_start true (offset 0) and false.
        self.closure(&[_]u32{0}, true);
        self.start0 = try self.intern();
        self.closure(&[_]u32{0}, false);
        self.startN = try self.intern();

        // Worklist = the growing `0..n_states` range (intern appends, the loop reaches
        // them). DEAD (the empty set) is NOT special-cased: `collectSeeds(DEAD)` yields
        // nothing, so its anchored row closes to the empty set (DEAD again), while its
        // unanchored row still re-seeds the start — exactly the lazy DFA's `ustep` rule.
        var sid: u32 = 0;
        while (sid < self.n_states) : (sid += 1) {
            var c: u32 = 0;
            while (c < self.n_classes) : (c += 1) {
                const rep = self.class_rep[c];
                // Anchored row: successors of this state only.
                const na = self.collectSeeds(sid, rep, 0);
                self.closure(self.seeds[0..na], false); // a transition is always at sp > 0
                self.trans[sid * self.n_classes + c] = try self.intern();
                // Unanchored row: this state's successors ∪ a fresh start (`startN`) —
                // the implicit `(?s:.)*?` prefix. Same interned id space as `trans`.
                var nu = self.collectSeeds(sid, rep, 0);
                nu += self.collectSeeds(self.startN, rep, nu);
                self.closure(self.seeds[0..nu], false);
                self.utrans[sid * self.n_classes + c] = try self.intern();
            }
        }
    }
};

// ── Reverse determinizer (the O(n) `find` leftmost-start, frozen at build) ──────────
//
// The forward one-pass locates the leftmost match END in a single pass; the reverse DFA,
// anchored at that end and scanning *backward*, locates the leftmost START — replacing the
// Θ(n²) anchored restart on the begin-but-don't-complete class (`\w+@\w+` on a long word
// run). It is the eager analogue of the lazy DFA's `revClosure`/`revStep`/`revFind`, fully
// determinized into a frozen table at build (comptime + runtime). Built only for
// assertion-free programs (a `text_start` is position-dependent, so its reverse
// transitions are not cacheable — those keep anchored restart).

/// Tiny in-place ascending insertion sort — reverse states are small pc sets, and this is
/// comptime-safe (no allocation, no std.sort dependency in const-eval). Sorting the pc
/// list canonicalizes a reverse state (a plain set) so set-equal states intern equal.
fn sortAsc(a: []u32) void {
    var i: usize = 1;
    while (i < a.len) : (i += 1) {
        const x = a[i];
        var j = i;
        while (j > 0 and a[j - 1] > x) : (j -= 1) a[j] = a[j - 1];
        a[j] = x;
    }
}

/// Eager reverse determinizer over caller-supplied fixed buffers (so the identical code
/// runs at comptime and runtime, like `Det`). It first builds the byte program's reverse
/// adjacency (epsilon predecessors + reverse-byte in-edges, CSR) into caller buffers, then
/// determinizes the reverse automaton into a frozen table. Reverse states are SORTED sets
/// of forward pcs (no priority/cut — the end is fixed, so only reachability of forward
/// pc 0 matters). `error.Unsupported` on any fixed-buffer overflow (the caller declines).
const RDet = struct {
    insts: []const byte.Inst,
    class_rep: *const [256]u8,
    n_classes: u32,

    // ── reverse adjacency (filled by `buildAdj`) ──
    reps_off: []u32, // CSR: epsilon predecessors of each pc
    reps: []u32,
    rb_off: []u32, // CSR: reverse-byte in-edges of each pc
    rb_lo: []u8,
    rb_hi: []u8,
    rb_src: []u32,
    byte_target: []bool, // is pc the `next` of some byte_range? (a reverse-state member)
    match_seed: []u32, // forward `match` pcs — the reverse DFA's start seeds
    n_match: u32 = 0,

    // ── frozen reverse-DFA outputs (caller buffers) ──
    r_state_off: []u32,
    r_state_len: []u32,
    r_pc_pool: []u32,
    raccept: []bool, // reverse state contains forward pc 0?
    rtrans: []u32, // n_rstates × n_classes
    n_rstates: u32 = 0,
    rpool_len: u32 = 0,
    rstart: u32 = DEAD,

    // ── per-closure work buffers ──
    seen: []u32,
    seen_gen: u32 = 0,
    stack: []u32,
    work: []u32,
    work_len: u32 = 0,
    work_match: bool = false,
    seeds: []u32,

    /// In-place exclusive prefix sum: per-pc in-edge counts → per-pc CSR start offsets.
    fn prefixSum(arr: []u32) void {
        var acc: u32 = 0;
        for (arr) |*v| {
            const c = v.*;
            v.* = acc;
            acc += c;
        }
    }

    /// Build the reverse adjacency from the (assertion-free) byte program: two passes —
    /// count in-edges per pc, prefix-sum to offsets, fill. Reuses `work`/`seeds` as the
    /// transient fill cursors (they are overwritten by the first closure afterward).
    fn buildAdj(self: *RDet) void {
        const n: u32 = @intCast(self.insts.len);
        for (self.reps_off[0 .. n + 1]) |*v| v.* = 0;
        for (self.rb_off[0 .. n + 1]) |*v| v.* = 0;
        for (self.byte_target[0..n]) |*v| v.* = false;

        for (self.insts, 0..) |inst, i| switch (inst) {
            .byte_range => |r| {
                self.rb_off[r.next] += 1;
                self.byte_target[r.next] = true;
            },
            .split => |s| {
                self.reps_off[s.a] += 1;
                self.reps_off[s.b] += 1;
            },
            .jmp => |t| self.reps_off[t] += 1,
            .save => self.reps_off[i + 1] += 1,
            .assertion => {}, // assertion-free programs only (caller gates on has_text_start)
            .match => {},
        };
        prefixSum(self.reps_off[0 .. n + 1]);
        prefixSum(self.rb_off[0 .. n + 1]);

        const ec = self.work[0..n]; // epsilon fill cursor
        @memcpy(ec, self.reps_off[0..n]);
        const rc = self.seeds[0..n]; // byte fill cursor
        @memcpy(rc, self.rb_off[0..n]);
        var mi: u32 = 0;
        for (self.insts, 0..) |inst, i| {
            const pc: u32 = @intCast(i);
            switch (inst) {
                .byte_range => |r| {
                    const k = rc[r.next];
                    rc[r.next] += 1;
                    self.rb_lo[k] = r.range.lo;
                    self.rb_hi[k] = r.range.hi;
                    self.rb_src[k] = pc;
                },
                .split => |s| {
                    self.reps[ec[s.a]] = pc;
                    ec[s.a] += 1;
                    self.reps[ec[s.b]] = pc;
                    ec[s.b] += 1;
                },
                .jmp => |t| {
                    self.reps[ec[t]] = pc;
                    ec[t] += 1;
                },
                .save => {
                    self.reps[ec[i + 1]] = pc;
                    ec[i + 1] += 1;
                },
                .assertion => {},
                .match => {
                    self.match_seed[mi] = pc;
                    mi += 1;
                },
            }
        }
        self.n_match = mi;
    }

    /// Reverse epsilon-closure of `seeds` into `work`: follow reverse-epsilon edges,
    /// collecting `byte_target` pcs (the reverse-state members) and forward pc 0 (the
    /// reverse accept), setting `work_match` when pc 0 is reached. No priority, no cut.
    fn revClosure(self: *RDet, seeds: []const u32) void {
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        self.work_len = 0;
        self.work_match = false;
        for (seeds) |seed| {
            var top: usize = 0;
            self.stack[top] = seed;
            top += 1;
            while (top > 0) {
                top -= 1;
                const pc = self.stack[top];
                if (self.seen[pc] == gen) continue;
                self.seen[pc] = gen;
                if (pc == 0) self.work_match = true;
                // Include pc 0 as a member (keeps the `[0]` accepting state distinct from
                // the DEAD empty set when interned), plus every byte_target pc.
                if (self.byte_target[pc] or pc == 0) {
                    self.work[self.work_len] = pc;
                    self.work_len += 1;
                }
                var e: usize = self.reps_off[pc];
                const e_end = self.reps_off[pc + 1];
                while (e < e_end) : (e += 1) {
                    const u = self.reps[e];
                    if (self.seen[u] != gen) {
                        self.stack[top] = u;
                        top += 1;
                    }
                }
            }
        }
    }

    /// Intern the reverse state in `work[0..work_len]` (sorted, so set-equal states collapse
    /// to one id) to a dense reverse-state id, recording its accept flag on first sight.
    /// Declines (`error.Unsupported`) on state-cap or pc-pool overflow.
    fn intern(self: *RDet) DetError!u32 {
        sortAsc(self.work[0..self.work_len]);
        const key = self.work[0..self.work_len];
        var id: u32 = 0;
        while (id < self.n_rstates) : (id += 1) {
            const off = self.r_state_off[id];
            if (self.r_state_len[id] == key.len and std.mem.eql(u32, self.r_pc_pool[off .. off + key.len], key))
                return id;
        }
        if (self.n_rstates >= self.r_state_off.len) return error.Unsupported;
        if (self.rpool_len + key.len > self.r_pc_pool.len) return error.Unsupported;
        const off = self.rpool_len;
        @memcpy(self.r_pc_pool[off .. off + key.len], key);
        self.r_state_off[id] = off;
        self.r_state_len[id] = @intCast(key.len);
        self.raccept[id] = self.work_match;
        self.rpool_len += @intCast(key.len);
        self.n_rstates += 1;
        return id;
    }

    /// Predecessors of `rstate` consuming the class rep `rep` *backward*: from each pc in
    /// the state, the `byte_range`s whose `next` is that pc and whose range contains `rep`.
    /// Writes `seeds[0..return]`.
    fn collectRevSeeds(self: *RDet, rstate: u32, rep: u8) u32 {
        var ns: u32 = 0;
        const off = self.r_state_off[rstate];
        for (self.r_pc_pool[off .. off + self.r_state_len[rstate]]) |pc| {
            var b: usize = self.rb_off[pc];
            const b_end = self.rb_off[pc + 1];
            while (b < b_end) : (b += 1) {
                if (rep >= self.rb_lo[b] and rep <= self.rb_hi[b]) {
                    self.seeds[ns] = self.rb_src[b];
                    ns += 1;
                }
            }
        }
        return ns;
    }

    /// Build the adjacency, then determinize fully: reverse DEAD = empty set (rid 0),
    /// reverse start = closure of the forward `match` pcs, then breadth-first compute every
    /// `(rstate, class)` edge. DEAD is not special-cased (its empty seed set closes to DEAD).
    fn run(self: *RDet) DetError!void {
        self.buildAdj();
        @memset(self.seen, 0);

        self.work_len = 0;
        self.work_match = false;
        std.debug.assert((try self.intern()) == DEAD); // empty set = reverse DEAD

        self.revClosure(self.match_seed[0..self.n_match]);
        self.rstart = try self.intern();

        var rid: u32 = 0;
        while (rid < self.n_rstates) : (rid += 1) {
            var c: u32 = 0;
            while (c < self.n_classes) : (c += 1) {
                const ns = self.collectRevSeeds(rid, self.class_rep[c]);
                self.revClosure(self.seeds[0..ns]);
                self.rtrans[rid * self.n_classes + c] = try self.intern();
            }
        }
    }
};

/// The frozen reverse table a build path keeps: just enough for `revFindEager`.
const Reverse = struct {
    rtrans: []const u32,
    raccept: []const bool,
    rstart: u32,
};

/// Build the reverse frozen DFA on the heap (the runtime `find` path). Scratch buffers are
/// freed; only the trimmed `rtrans`/`raccept` survive. `error.Unsupported` on overflow.
fn reverseAlloc(gpa: std.mem.Allocator, insts: []const byte.Inst, class_rep: *const [256]u8, nc: u32) BuildError!Reverse {
    const n: u32 = @intCast(insts.len);
    const r_state_cap = @min(n + 256, max_states);
    const rpool_sz = n *| pool_factor;

    const reps_off = try gpa.alloc(u32, n + 1);
    defer gpa.free(reps_off);
    const reps = try gpa.alloc(u32, 2 * @as(usize, n) + 1);
    defer gpa.free(reps);
    const rb_off = try gpa.alloc(u32, n + 1);
    defer gpa.free(rb_off);
    const rb_lo = try gpa.alloc(u8, n);
    defer gpa.free(rb_lo);
    const rb_hi = try gpa.alloc(u8, n);
    defer gpa.free(rb_hi);
    const rb_src = try gpa.alloc(u32, n);
    defer gpa.free(rb_src);
    const byte_target = try gpa.alloc(bool, n);
    defer gpa.free(byte_target);
    const match_seed = try gpa.alloc(u32, n);
    defer gpa.free(match_seed);

    const r_state_off = try gpa.alloc(u32, r_state_cap);
    defer gpa.free(r_state_off);
    const r_state_len = try gpa.alloc(u32, r_state_cap);
    defer gpa.free(r_state_len);
    const raccept_buf = try gpa.alloc(bool, r_state_cap);
    defer gpa.free(raccept_buf);
    const rtrans_buf = try gpa.alloc(u32, @as(usize, r_state_cap) * nc);
    defer gpa.free(rtrans_buf);
    const r_pc_pool = try gpa.alloc(u32, rpool_sz);
    defer gpa.free(r_pc_pool);

    const seen = try gpa.alloc(u32, n);
    defer gpa.free(seen);
    const stack = try gpa.alloc(u32, 4 * @as(usize, n) + 4);
    defer gpa.free(stack);
    const work = try gpa.alloc(u32, n + 1);
    defer gpa.free(work);
    const seeds = try gpa.alloc(u32, n + 1);
    defer gpa.free(seeds);

    var rdet = RDet{
        .insts = insts,
        .class_rep = class_rep,
        .n_classes = nc,
        .reps_off = reps_off,
        .reps = reps,
        .rb_off = rb_off,
        .rb_lo = rb_lo,
        .rb_hi = rb_hi,
        .rb_src = rb_src,
        .byte_target = byte_target,
        .match_seed = match_seed,
        .r_state_off = r_state_off,
        .r_state_len = r_state_len,
        .raccept = raccept_buf,
        .rtrans = rtrans_buf,
        .r_pc_pool = r_pc_pool,
        .seen = seen,
        .stack = stack,
        .work = work,
        .seeds = seeds,
    };
    rdet.run() catch return error.Unsupported;

    const rtrans = try gpa.dupe(u32, rdet.rtrans[0 .. rdet.n_rstates * nc]);
    errdefer gpa.free(rtrans);
    const raccept = try gpa.dupe(bool, rdet.raccept[0..rdet.n_rstates]);
    return .{ .rtrans = rtrans, .raccept = raccept, .rstart = rdet.rstart };
}

// ── Θ(n²)-proneness: is there a non-accepting cycle reachable from a start? ──────────

/// Whether anchored restart is Θ(n²)-prone on the frozen anchored DFA: can the automaton, from
/// a start state, consume an **unbounded run staying entirely in non-accepting states** — a
/// non-accepting cycle reachable from a start? If so, anchored restart re-scans that run from
/// every start position (`\w+@\w+` on a `@`-free word run), so `find` uses the reverse DFA
/// instead. If not (every consuming cycle passes an accepting state, e.g. `\w+`/`\d+`),
/// anchored restart is O(input) and far faster. A back-edge in a 3-colour DFS over the
/// non-accepting, non-dead subgraph proves a cycle. `color`/`stack`/`iter` are caller buffers
/// sized to the state count (so the identical code runs at comptime and runtime).
fn computeProne(
    trans: []const u32,
    accept: []const bool,
    n_states: u32,
    nc: u32,
    start0: u32,
    startN: u32,
    color: []u8,
    stack: []u32,
    iter: []u32,
) bool {
    const WHITE: u8 = 0;
    const GRAY: u8 = 1;
    const BLACK: u8 = 2;
    var i: u32 = 0;
    while (i < n_states) : (i += 1) color[i] = WHITE;

    for ([_]u32{ start0, startN }) |start| {
        if (start == DEAD or accept[start] or color[start] != WHITE) continue;
        var top: u32 = 0;
        stack[0] = start;
        iter[0] = 0;
        color[start] = GRAY;
        top = 1;
        while (top > 0) {
            const s = stack[top - 1];
            if (iter[top - 1] < nc) {
                const c = iter[top - 1];
                iter[top - 1] += 1;
                const nxt = trans[@as(usize, s) * nc + c];
                if (nxt == DEAD or accept[nxt]) continue; // dead / accepting = a safe exit, not a Θ(n²) run
                if (color[nxt] == GRAY) return true; // back-edge ⇒ non-accepting cycle
                if (color[nxt] == WHITE) {
                    color[nxt] = GRAY;
                    stack[top] = nxt;
                    iter[top] = 0;
                    top += 1;
                }
            } else {
                color[s] = BLACK;
                top -= 1;
            }
        }
    }
    return false;
}

/// `out[pc]` ← does `pc` reach `match` via epsilon edges only, with `text_end` (`$`/`\z`)
/// **passable** (the end-of-input view)? Drives `accept_eoi`: a closure that parks on a
/// `text_end` pc whose `reaches_end` is true makes its state accepting at end of input.
/// `text_start` is treated as *not* passable here (it needs offset 0, which the at-end view
/// lacks in general — the empty-input `^…$` case is covered by the start closures). A monotone
/// backward fixpoint; all-false for a `$`-free program. `out` is a caller buffer sized to the
/// instruction count, so the identical code runs at comptime and runtime.
fn computeEndReaches(insts: []const byte.Inst, out: []bool) void {
    const n = insts.len;
    for (out[0..n]) |*v| v.* = false;
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (out[i]) continue;
            const r = switch (insts[i]) {
                .match => true,
                .jmp => |t| out[t],
                .split => |s| out[s.a] or out[s.b],
                .save => out[i + 1], // captures are epsilons
                .assertion => |k| k == .text_end and out[i + 1], // text_start: not passable at end
                .byte_range => false, // consumes a byte — no input left at end
            };
            if (r) {
                out[i] = true;
                changed = true;
            }
        }
    }
}

// ── Build (comptime + runtime share one determinizer) ──────────────────────────────

/// Compile a HIR into a heap-allocated eager DFA `Program` (free with `freeProgram`).
/// `error.Unsupported` if the pattern is not byte/DFA-lowerable (`supports`) **or** its
/// determinized DFA does not fit the fixed bounds (`> max_states` states); `auto` then
/// keeps it on the lazy DFA / code-point engines.
///
/// @stable-since: v0.3.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    if (!supports(h)) return error.Unsupported;
    var bp = try byte.buildAlloc(gpa, h);
    defer byte.freeProgram(gpa, &bp); // the NFA is a build-time scaffold; only the DFA escapes
    const classes = byte.byteClasses(&bp);
    const nc = classes.count;
    var class_rep: [256]u8 = @splat(0);
    {
        var b: u16 = 0;
        while (b < 256) : (b += 1) class_rep[classes.map[b]] = @intCast(b);
    }

    const ic: u32 = @intCast(bp.insts.len);
    const state_cap = @min(ic + 256, max_states); // pattern-proportional, capped
    const pool_sz = ic *| pool_factor;

    // Determinizer scratch (freed below; only the trimmed outputs are kept).
    const state_off = try gpa.alloc(u32, state_cap);
    defer gpa.free(state_off);
    const state_len = try gpa.alloc(u32, state_cap);
    defer gpa.free(state_len);
    const accept_buf = try gpa.alloc(bool, state_cap);
    defer gpa.free(accept_buf);
    const accept_eoi_buf = try gpa.alloc(bool, state_cap);
    defer gpa.free(accept_eoi_buf);
    const reaches_end = try gpa.alloc(bool, ic);
    defer gpa.free(reaches_end);
    computeEndReaches(bp.insts, reaches_end);
    const trans_buf = try gpa.alloc(u32, @as(usize, state_cap) * nc);
    defer gpa.free(trans_buf);
    const utrans_buf = try gpa.alloc(u32, @as(usize, state_cap) * nc);
    defer gpa.free(utrans_buf);
    const pc_pool = try gpa.alloc(u32, pool_sz);
    defer gpa.free(pc_pool);
    const seen = try gpa.alloc(u32, ic);
    defer gpa.free(seen);
    const stack = try gpa.alloc(u32, 2 * ic + 1);
    defer gpa.free(stack);
    const work = try gpa.alloc(u32, ic + 1);
    defer gpa.free(work);
    const seeds = try gpa.alloc(u32, 2 * ic + 2); // unanchored row unions two states' seeds
    defer gpa.free(seeds);

    var det = Det{
        .insts = bp.insts,
        .classes = &classes,
        .class_rep = &class_rep,
        .n_classes = nc,
        .reaches_end = reaches_end,
        .state_off = state_off,
        .state_len = state_len,
        .accept = accept_buf,
        .accept_eoi = accept_eoi_buf,
        .trans = trans_buf,
        .utrans = utrans_buf,
        .pc_pool = pc_pool,
        .seen = seen,
        .stack = stack,
        .work = work,
        .seeds = seeds,
    };
    det.run() catch return error.Unsupported;

    // Keep only the used prefix of the anchored table + accept flags (right-sized heap copies).
    const n = det.n_states;
    const trans = try gpa.dupe(u32, det.trans[0 .. n * nc]);
    errdefer gpa.free(trans);
    const accept = try gpa.dupe(bool, det.accept[0..n]);
    errdefer gpa.free(accept);
    const accept_eoi = try gpa.dupe(bool, det.accept_eoi[0..n]);
    errdefer gpa.free(accept_eoi);

    // Θ(n²)-proneness of anchored restart — decides which auxiliary tables are even needed. A
    // `text_end` (`$`/`\z`) program is forced non-prone: it is matched by anchored restart with
    // the `accept_eoi` end check (the reverse DFA does not model `$`), and that restart is still
    // O(input) on the usual trailing-`$` shapes (each failed start dies quickly; the match scans
    // to the end once).
    var has_text_end = false;
    for (bp.insts) |inst| switch (inst) {
        .assertion => |k| if (k == .text_end) {
            has_text_end = true;
        },
        else => {},
    };
    const pcolor = try gpa.alloc(u8, n);
    defer gpa.free(pcolor);
    const pstack = try gpa.alloc(u32, n);
    defer gpa.free(pstack);
    const piter = try gpa.alloc(u32, n);
    defer gpa.free(piter);
    const prone = !has_text_end and computeProne(trans, accept, n, nc, det.start0, det.startN, pcolor, pstack, piter);

    // The unanchored `utrans` table and the reverse DFA are consulted **only** on the prone
    // arm (one-pass `isMatch` + reverse-DFA `find`). A non-prone pattern runs entirely on
    // `trans` (anchored restart, O(input)), so neither is built — saving the bulk of the eager
    // DFA's memory on the common case (`\w+` skips ~850 KB of utrans + reverse). A `text_start`
    // program additionally has no reverse table (its reverse transitions are position-dependent),
    // so a prone `text_start` pattern keeps anchored restart.
    var has_text_start = false;
    for (bp.insts) |inst| switch (inst) {
        .assertion => |k| if (k == .text_start) {
            has_text_start = true;
        },
        else => {},
    };
    const utrans: []const u32 = if (prone) try gpa.dupe(u32, det.utrans[0 .. n * nc]) else &.{};
    errdefer if (prone) gpa.free(utrans);
    var rev = Reverse{ .rtrans = &.{}, .raccept = &.{}, .rstart = DEAD };
    const rev_built = prone and !has_text_start;
    if (rev_built) rev = try reverseAlloc(gpa, det.insts, &class_rep, nc);
    errdefer if (rev_built) {
        gpa.free(rev.rtrans);
        gpa.free(rev.raccept);
    };

    return .{
        .classes = classes,
        .n_classes = nc,
        .trans = trans,
        .utrans = utrans,
        .accept = accept,
        .accept_eoi = accept_eoi,
        .start0 = det.start0,
        .startN = det.startN,
        .anchored_start = h.analysis.anchored_start,
        .prone = prone,
        .has_text_start = has_text_start,
        .rev_built = rev_built,
        .rtrans = rev.rtrans,
        .raccept = rev.raccept,
        .rstart = rev.rstart,
    };
}

/// Compile a HIR into a ro_data eager DFA `Program` at comptime. The byte NFA is built
/// and determinized at compile time; only the small frozen table reaches `ro_data`. A
/// pattern that is not byte/DFA-lowerable, or whose DFA exceeds `max_states`, is a
/// `@compileError` — gate with `supports` (and prefer the runtime lazy DFA for large
/// Unicode-class patterns). `auto` calls this only for **tiny** patterns (a low byte-inst
/// ceiling) that provably fit, so the `@compileError` branches are never hit there.
///
/// @stable-since: v0.3.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    if (!comptime supports(h)) @compileError("edfa: HIR is not byte/DFA-lowerable (\\X, \\b/\\B, or a non-text_start anchor)");
    const bp = comptime byte.buildComptime(h);
    const classes = comptime byte.byteClasses(&bp);
    const nc = classes.count;
    comptime var class_rep: [256]u8 = @splat(0);
    comptime {
        var b: u16 = 0;
        while (b < 256) : (b += 1) class_rep[classes.map[b]] = @intCast(b);
    }

    const ic: u32 = bp.insts.len;
    // Determinization closure work is ~states × classes × (split-tree traversal), and the
    // reverse determinization adds a comparable pass; size the quota for both. Large Unicode
    // classes are slow to determinize at comptime but produce a tiny table — the CTRE-lane
    // trade (compile-time cost, small `ro_data`).
    @setEvalBranchQuota(@intCast(@min(400_000 + @as(u64, ic) * 800, std.math.maxInt(u32))));

    const state_cap = @min(ic + 256, max_states); // pattern-proportional, capped
    comptime var state_off: [state_cap]u32 = undefined;
    comptime var state_len: [state_cap]u32 = undefined;
    comptime var accept_buf: [state_cap]bool = undefined;
    comptime var accept_eoi_buf: [state_cap]bool = undefined;
    comptime var reaches_end: [ic]bool = undefined;
    comptime computeEndReaches(bp.insts, &reaches_end);
    comptime var trans_buf: [state_cap * @as(usize, nc)]u32 = undefined;
    comptime var utrans_buf: [state_cap * @as(usize, nc)]u32 = undefined;
    comptime var pc_pool: [ic * pool_factor]u32 = undefined;
    comptime var seen: [ic]u32 = undefined;
    comptime var stack: [2 * ic + 1]u32 = undefined;
    comptime var work: [ic + 1]u32 = undefined;
    comptime var seeds: [2 * ic + 2]u32 = undefined; // unanchored row unions two states' seeds

    comptime var det = Det{
        .insts = bp.insts,
        .classes = &classes,
        .class_rep = &class_rep,
        .n_classes = nc,
        .reaches_end = &reaches_end,
        .state_off = &state_off,
        .state_len = &state_len,
        .accept = &accept_buf,
        .accept_eoi = &accept_eoi_buf,
        .trans = &trans_buf,
        .utrans = &utrans_buf,
        .pc_pool = &pc_pool,
        .seen = &seen,
        .stack = &stack,
        .work = &work,
        .seeds = &seeds,
    };
    det.run() catch @compileError("edfa: pattern's DFA exceeds max_states; use the runtime lazy DFA (backends.dfa) instead");

    const n = det.n_states;
    const final_trans = trans_buf[0 .. n * nc].*;
    const final_accept = accept_buf[0..n].*;
    const final_accept_eoi = accept_eoi_buf[0..n].*;

    // Θ(n²)-proneness of anchored restart — decides which auxiliary tables are built (the
    // unanchored `utrans` and the reverse DFA are consulted only on the prone arm, so a
    // non-prone pattern bakes neither: only `trans` reaches `ro_data`). A `text_end` program
    // is forced non-prone (matched by anchored restart + the `accept_eoi` end check).
    comptime var has_text_end = false;
    comptime {
        for (bp.insts) |inst| switch (inst) {
            .assertion => |k| if (k == .text_end) {
                has_text_end = true;
            },
            else => {},
        };
    }
    comptime var pcolor: [state_cap]u8 = undefined;
    comptime var pstack: [state_cap]u32 = undefined;
    comptime var piter: [state_cap]u32 = undefined;
    const prone = !has_text_end and computeProne(&final_trans, &final_accept, n, nc, det.start0, det.startN, &pcolor, &pstack, &piter);
    const final_utrans = if (prone) utrans_buf[0 .. n * nc].* else [_]u32{};

    // Reverse frozen DFA — only for a prone, assertion-free program (a `text_start` keeps
    // `find` on anchored restart). Determinized into ro_data at comptime via the same `RDet`.
    comptime var has_text_start = false;
    comptime {
        for (bp.insts) |inst| switch (inst) {
            .assertion => |k| if (k == .text_start) {
                has_text_start = true;
            },
            else => {},
        };
    }
    const rev_built = prone and !has_text_start;
    const r_state_cap = @min(ic + 256, max_states);
    comptime var reps_off: [ic + 1]u32 = undefined;
    comptime var reps: [2 * ic + 1]u32 = undefined;
    comptime var rb_off: [ic + 1]u32 = undefined;
    comptime var rb_lo: [ic]u8 = undefined;
    comptime var rb_hi: [ic]u8 = undefined;
    comptime var rb_src: [ic]u32 = undefined;
    comptime var byte_target: [ic]bool = undefined;
    comptime var match_seed: [ic]u32 = undefined;
    comptime var r_state_off: [r_state_cap]u32 = undefined;
    comptime var r_state_len: [r_state_cap]u32 = undefined;
    comptime var raccept_buf: [r_state_cap]bool = undefined;
    comptime var rtrans_buf: [r_state_cap * @as(usize, nc)]u32 = undefined;
    comptime var r_pc_pool: [ic * pool_factor]u32 = undefined;
    comptime var rseen: [ic]u32 = undefined;
    comptime var rstack: [4 * ic + 4]u32 = undefined;
    comptime var rwork: [ic + 1]u32 = undefined;
    comptime var rseeds: [ic + 1]u32 = undefined;
    comptime var rdet = RDet{
        .insts = bp.insts,
        .class_rep = &class_rep,
        .n_classes = nc,
        .reps_off = &reps_off,
        .reps = &reps,
        .rb_off = &rb_off,
        .rb_lo = &rb_lo,
        .rb_hi = &rb_hi,
        .rb_src = &rb_src,
        .byte_target = &byte_target,
        .match_seed = &match_seed,
        .r_state_off = &r_state_off,
        .r_state_len = &r_state_len,
        .raccept = &raccept_buf,
        .rtrans = &rtrans_buf,
        .r_pc_pool = &r_pc_pool,
        .seen = &rseen,
        .stack = &rstack,
        .work = &rwork,
        .seeds = &rseeds,
    };
    if (rev_built) rdet.run() catch @compileError("edfa: reverse DFA exceeds bounds; use the runtime lazy DFA (backends.dfa) instead");
    const rn = rdet.n_rstates;
    const final_rtrans = if (rev_built) rtrans_buf[0 .. rn * nc].* else [_]u32{};
    const final_raccept = if (rev_built) raccept_buf[0..rn].* else [_]bool{};

    return .{
        .classes = classes,
        .n_classes = nc,
        .trans = &final_trans,
        .utrans = &final_utrans,
        .accept = &final_accept,
        .accept_eoi = &final_accept_eoi,
        .start0 = det.start0,
        .startN = det.startN,
        .anchored_start = h.analysis.anchored_start,
        .prone = prone,
        .has_text_start = has_text_start,
        .rev_built = rev_built,
        .rtrans = &final_rtrans,
        .raccept = &final_raccept,
        .rstart = rdet.rstart,
    };
}

/// @stable-since: v0.3.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.trans);
    if (program.prone) gpa.free(program.utrans); // empty (never allocated) for non-prone
    gpa.free(program.accept);
    gpa.free(program.accept_eoi);
    if (program.rev_built) {
        gpa.free(program.rtrans);
        gpa.free(program.raccept);
    }
}

// ── Scratch: stateless (the frozen table is the whole matcher) ──────────────────────

/// Stateless companion: the eager DFA's table is complete, so a search needs no mutable
/// state. Zero-size, with the standard lifecycle as no-ops so the front door / `auto`
/// drive it with the same calls as a stateful backend — and `initBuffer` makes a
/// buffer/comptime `Scratch` trivially available, so matching runs at comptime.
///
/// @stable-since: v0.3.0
pub const Scratch = struct {
    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = backend.Cell;

    /// @stable-since: v0.3.0
    pub fn bufferLen(_: *const Program) usize {
        return 0;
    }
    /// @stable-since: v0.3.0
    pub fn init(_: std.mem.Allocator, _: *const Program) std.mem.Allocator.Error!Scratch {
        return .{};
    }
    /// @stable-since: v0.3.0
    pub fn initBuffer(_: []backend.Cell, _: *const Program) backend.ScratchError!Scratch {
        return .{};
    }
    /// @stable-since: v0.3.0
    pub fn deinit(_: *Scratch, _: std.mem.Allocator) void {}
    /// @stable-since: v0.3.0
    pub fn reset(_: *Scratch) void {}
};

// ── Matching (a bare table walk) ────────────────────────────────────────────────────

/// Run the DFA anchored at `s`: the leftmost-first match end reached from `s`, or null
/// if no match begins exactly at `s`. With `earliest`, returns as soon as any accepting
/// state is entered; otherwise it scans on, keeping the last accepting position — which,
/// thanks to the priority/cut determinization, is the leftmost-first end. A state counts as
/// accepting **at `input.len`** when `accept_eoi` holds (a pending `text_end` `$`/`\z`); for a
/// `$`-free program `accept_eoi == accept`, so that extra term is a no-op.
fn runAnchored(program: *const Program, input: []const u8, s: usize, earliest: bool) ?usize {
    const nc = program.n_classes;
    var state = if (s == 0) program.start0 else program.startN;
    var match_end: ?usize = if (program.accept[state] or (s == input.len and program.accept_eoi[state])) s else null;
    if (match_end != null and earliest) return match_end;

    var pos = s;
    while (pos < input.len) {
        const class = program.classes.map[input[pos]];
        state = program.trans[state * nc + class];
        if (state == DEAD) break;
        pos += 1;
        if (program.accept[state] or (pos == input.len and program.accept_eoi[state])) {
            match_end = pos;
            if (earliest) break;
        }
    }
    return match_end;
}

/// One-pass unanchored match detection (`isMatch`): scan once from `start`, each byte
/// re-seeding the start via the frozen `utrans` table (the implicit `.*?` prefix),
/// accepting the instant the live state is accepting. O(input), no per-position restart
/// — the eager analogue of the lazy DFA's `runUnanchored`, and the fix for the Θ(n²)
/// anchored-restart blowup on the begin-but-don't-complete class (`[ab]*c`, `\w+@\w+`).
///
/// @stable-since: v0.3.0
fn runUnanchoredOnePass(program: *const Program, input: []const u8, start: usize) bool {
    const nc = program.n_classes;
    const utrans = program.utrans;
    const accept = program.accept;
    const map = &program.classes.map;
    var state = if (start == 0) program.start0 else program.startN;
    if (accept[state]) return true;
    var pos = start;
    while (pos < input.len) {
        const class = map[input[pos]];
        state = utrans[state * nc + class];
        pos += 1;
        if (accept[state]) return true;
    }
    return false;
}

/// Find the END offset of the leftmost-first match at or after `start`, or null. Phase 1
/// (unmatched): scan with the unanchored `utrans` (re-seeding the start each byte — the
/// implicit `.*?` prefix) so the FIRST accepting state corresponds to the earliest-starting
/// thread (priority order makes older threads win the match cut). Phase 2 (matched): once a
/// match is seen the leftmost start is fixed, so switch to the anchored `trans` and extend
/// the matched thread greedily; the last accepting position before it dies is the
/// leftmost-first end. The eager analogue of the lazy DFA's `findEndForward` (assertion-free
/// programs only — `searchImpl` routes `text_start` patterns to anchored restart).
///
/// @stable-since: v0.3.0
fn findEndForwardEager(program: *const Program, input: []const u8, start: usize) ?usize {
    const nc = program.n_classes;
    const utrans = program.utrans;
    const trans = program.trans;
    const accept = program.accept;
    const map = &program.classes.map;
    var state = if (start == 0) program.start0 else program.startN;
    var matched = accept[state];
    var end: ?usize = if (matched) start else null;
    var pos = start;
    while (pos < input.len) {
        const class = map[input[pos]];
        if (matched) {
            const next = trans[state * nc + class];
            if (next == DEAD) break; // the matched thread is exhausted
            state = next;
            pos += 1;
            if (accept[state]) end = pos;
        } else {
            state = utrans[state * nc + class]; // re-seeding scan: never dies, a match can still begin later
            pos += 1;
            if (accept[state]) {
                matched = true;
                end = pos;
            }
        }
    }
    return end;
}

/// Leftmost match START for a match known to end at `end`, searching down to `lo` (the
/// search's `opts.start`). Runs the frozen reverse DFA anchored at `end`, scanning backward;
/// the smallest position at which the reverse state accepts (forward pc 0 reachable ⇒
/// `[pos, end)` is a full match) is the leftmost-first start. The eager analogue of the lazy
/// DFA's `revFind`. (The forward already fixed `end` as the leftmost match's end, so no
/// earlier start ≥ `lo` matches `[·, end)`.)
///
/// @stable-since: v0.3.0
fn revFindEager(program: *const Program, input: []const u8, end: usize, lo: usize) usize {
    const nc = program.n_classes;
    const rtrans = program.rtrans;
    const raccept = program.raccept;
    const map = &program.classes.map;
    var state = program.rstart;
    var found: ?usize = if (raccept[state]) end else null; // empty match at `end`?
    var pos = end;
    while (pos > lo) {
        pos -= 1;
        const class = map[input[pos]];
        state = rtrans[state * nc + class];
        if (raccept[state]) found = pos;
        if (state == DEAD) break;
    }
    return found orelse end; // the forward guaranteed a match, so non-null in practice
}

/// Leftmost match span. A pinned (`opts.anchored`) or start-anchored (`\A`/`^`) pattern is a
/// single anchored run. For the unanchored case the strategy is a **static, per-program
/// choice** (`program.prone`, computed once at build):
///
///   * **Anchored restart** — for a pattern that *completes* at most start positions (`\w+`,
///     `[A-Za-z]+`, `\d+`: their consuming loop is itself accepting), this is one greedy table
///     walk per match, the eager DFA's headline ~1.1 GiB/s. It is O(input) precisely because
///     no start can scan far without hitting an accepting state.
///   * **Reverse-DFA two-pass** — for a **Θ(n²)-prone** pattern (`\w+@\w+`: a long pre-`@` word
///     run is a non-accepting cycle, so anchored restart re-scans it from every start), the
///     forward one-pass locates the leftmost match END and the reverse DFA the START, in two
///     linear passes. `program.prone` (a non-accepting cycle reachable from a start) selects
///     this arm, so there is **no per-search probing** — the right strategy is fixed at build.
///
/// Both arms are leftmost-first and agree (`conformance.zig`). `text_start` programs (no
/// reverse table) keep plain anchored restart. `earliest` only affects the anchored runs.
fn searchImpl(program: *const Program, input: []const u8, opts: SearchOptions, earliest: bool) ?Match {
    if (opts.start > input.len) return null;

    if (opts.anchored)
        return if (runAnchored(program, input, opts.start, earliest)) |end| Match{ .start = opts.start, .end = end } else null;

    if (program.anchored_start) {
        if (opts.start != 0) return null;
        return if (runAnchored(program, input, 0, earliest)) |end| Match{ .start = 0, .end = end } else null;
    }

    // Θ(n²)-prone (non-accepting cycle) → the O(input) reverse-DFA two-pass.
    if (program.prone and program.rev_built) {
        const e = findEndForwardEager(program, input, opts.start) orelse return null;
        const st = revFindEager(program, input, e, opts.start);
        return Match{ .start = st, .end = e };
    }

    // Not prone (or no reverse table) → anchored restart, O(input) and cache-tight.
    var s = opts.start;
    while (s <= input.len) : (s += 1) {
        if (runAnchored(program, input, s, earliest)) |end| return Match{ .start = s, .end = end };
    }
    return null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// Does the pattern match anywhere from `opts.start`? One-pass (O(input)) for the common
/// unanchored case (`runUnanchoredOnePass`); a pinned or start-anchored pattern reduces
/// to a single anchored run. The cheapest op.
///
/// @stable-since: v0.3.0
pub fn isMatch(program: *const Program, _: *Scratch, input: []const u8, opts: SearchOptions) bool {
    if (opts.start > input.len) return false;
    if (opts.anchored) return runAnchored(program, input, opts.start, true) != null;
    if (program.anchored_start) {
        if (opts.start != 0) return false;
        return runAnchored(program, input, 0, true) != null;
    }
    // Prone → one-pass over `utrans` (O(input), no Θ(n²)). Non-prone → anchored restart,
    // earliest-exit (also O(input): no start can scan far without hitting an accepting
    // state), and it has no `utrans` table to consult.
    if (program.prone) return runUnanchoredOnePass(program, input, opts.start);
    var s = opts.start;
    while (s <= input.len) : (s += 1) {
        if (runAnchored(program, input, s, true) != null) return true;
    }
    return false;
}

/// The leftmost match span `[start, end)`, or null. Leftmost-first, identical to the
/// code-point engines and the lazy DFA. `SearchOptions.earliest` is advisory and ignored
/// (the span is always leftmost-first); `isMatch` is the earliest-exit entry point.
///
/// @stable-since: v0.3.0
pub fn search(program: *const Program, _: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    return searchImpl(program, input, opts, false);
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests — end-to-end through Engine(edfa), comptime, and differential vs the Pike VM
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
    scratch: Scratch = .{},

    fn init(pattern: []const u8) !Compiled {
        return .{ .program = try buildFrom(testing.allocator, pattern) };
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

test "edfa satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "edfa is span-only and stateless" {
    try testing.expect(!caps.captures);
    try testing.expect(caps.stateless);
}

test "literals, leftmost span, none" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("abc", "abXabc", "abc");
    try expectNoMatch("abc", "ab");
    try expectFind("a", "banana", "a");
    try expectFind("héllo", "say héllo!", "héllo");
}

test "classes / shorthands / dot / negation" {
    try expectFind("a.c", "axc", "axc");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("(?s)a.c", "a\nc", "a\nc");
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("[^a-z]+", "abXY12cd", "XY12");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "  foo_bar! ", "foo_bar");
}

test "alternation, quantifiers (greedy/lazy/counted), anchors" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("a|ab", "ab", "a"); // leftmost-first
    try expectFind("ab|a", "ab", "ab");
    try expectFind("ab*", "abbbc", "abbb"); // greedy
    try expectFind("a.*c", "abXYZc end c", "abXYZc end c");
    try expectFind("a.*?c", "abXcYc", "abXc"); // lazy
    try expectFind("a{2,4}", "aaaaaa", "aaaa");
    try expectFind("(ab){2,3}", "ababab", "ababab");
    try expectFind("^abc", "abcdef", "abc"); // text_start
    try expectNoMatch("^abc", "xabc");
}

test "multi-byte UTF-8 matched by byte stepping (zero decode)" {
    try expectFind("\\w+", "héllo, wörld", "héllo");
    try expectFind("\\p{L}+", "abc123", "abc");
    try expectFind("\\p{Nd}+", "x٤٥٦y", "٤٥٦");
    try expectFind("\\p{Script=Greek}+", "abcαβγdef", "αβγ");
    try expectFind("[α-ω]+", "ΑΒΓαβγ", "αβγ");
    try expectFind("é{2,3}", "xééééy", "ééé");
    try expectFind("(?i)abc", "XYZABCxyz", "ABC");
}

test "invalid UTF-8 is dead-on-invalid (a match never spans a bad byte)" {
    try expectFind("a.c", "a\xFFc abc", "abc"); // resyncs past the bad byte
    try expectNoMatch(".", "\xFF");
}

test "agnostic ops over the frozen table: findAll / count / split" {
    var re = try Compiled.init("\\d+");
    defer re.deinit();
    const input = "a12b345c6";
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("12", it.next().?.slice(input));
    try testing.expectEqualStrings("345", it.next().?.slice(input));
    try testing.expectEqualStrings("6", it.next().?.slice(input));
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, input, .{}));
}

test "isMatch (earliest) and anchored search" {
    var re = try Compiled.init("\\w+");
    defer re.deinit();
    try testing.expect(E.isMatch(&re.program, &re.scratch, "  hello", .{}));
    try testing.expect(!E.isMatch(&re.program, &re.scratch, "  !!  ", .{}));
    try testing.expect(E.find(&re.program, &re.scratch, "  hi", .{ .anchored = true }) == null);
    try testing.expect(E.find(&re.program, &re.scratch, "hi  ", .{ .anchored = true }) != null);
}

test "a too-complex pattern is declined (Unsupported), not mis-determinized" {
    const gpa = testing.allocator;
    // A long counted repetition of a big Unicode class blows past max_states.
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "\\w{200}", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
}

test "eager DFA builds and matches at COMPTIME (ro_data table, stateless scratch)" {
    const got = comptime blk: {
        @setEvalBranchQuota(20_000_000);
        const a = compile.compile("[a-z]+[0-9]+");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var sc = Scratch{};
        const input = "  abc123  ";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no match at comptime");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("abc123", got);
}

// ── Differential: the eager DFA span must equal the Pike VM's whole-match span ──────

/// Differential: the eager DFA's span must equal the Pike VM's for `pattern` over every
/// input. Both engines are built **once per pattern** and reused across all inputs — the
/// determinization (including the prone reverse DFA, which is the heavy part for patterns
/// like `\w+@\w+`) is paid once, not once per input. Scratches are reused too (the Pike VM
/// generation-resets per search; the eager DFA is stateless).
fn agreesWithPikeVM(gpa: std.mem.Allocator, pattern: []const u8, inputs: []const []const u8) !void {
    var eprog = buildFrom(gpa, pattern) catch |e| switch (e) {
        error.Unsupported => return, // edfa is bounded; the lazy DFA covers what it declines
        else => return e,
    };
    defer freeProgram(gpa, &eprog);
    var esc = Scratch{};

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

    for (inputs) |input| {
        const em = E.find(&eprog, &esc, input, .{});
        const pm = PE.find(&pprog, &psc, input, .{});
        try testing.expectEqual(pm == null, em == null);
        if (pm) |p| {
            try testing.expectEqual(p.start, em.?.start);
            try testing.expectEqual(p.end, em.?.end);
        }
    }
}

test "differential vs Pike VM across a corpus (spans must agree)" {
    const patterns = [_][]const u8{
        "abc",        "a.c",     "[a-z]+", "[^a-z]+",   "\\d+",
        "\\w+",       "\\D+",    "cat|dog", "a|ab",     "ab|a",
        "foo|foobar", "ab*",     "ab+",     "ab?c",     "a.*c",
        "a.*?c",      "a{2,4}",  "(ab){2,3}", "\\w+\\d+", "\\p{L}+",
        "\\p{Nd}+",   "[α-ω]+",  "é{2,3}",  "(?i)abc",  "a*",
        "^abc",       "\\Aword", "^\\d+",   "\\w+@\\w+",
        // `text_end` ($/\z) — now DFA-eligible (matched by anchored restart + `accept_eoi`).
        "a$",         "\\d+$",   "^abc$",   "\\w+@\\w+$",
    };
    const inputs = [_][]const u8{
        "",                        "abc",        "  abc123def  ",      "xxabcyy",
        "i have a dog and a cat",  "héllo, wörld 42",                  "ΑΒΓαβγ123",
        "aaaaab",                  "a\xFFc abc", "no match here !!!",  "ababab end",
        "forty2 and 9 lives",      "x٤٥٦y",      "ééééX",              "ABCxyz",
        "word here",              "a word",     "alice@host now",      "trailing 42",
    };
    for (patterns) |p| try agreesWithPikeVM(testing.allocator, p, &inputs);
}

test {
    testing.refAllDecls(@This());
}
