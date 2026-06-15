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
//! table (`\w+` ≈ 322 states / ~140 KB); such patterns are usually better left to the runtime
//! lazy DFA. The frozen tables are **Hopcroft/Moore-minimized** at build (results-invariant),
//! which mostly helps the larger reverse tables (a prone `\w+@\w+`'s reverse DFA ≈ 3251 → ≈ 1047
//! states); the layout is kept **dense** (one `trans[state*nc + class]` load — the hot loop), so
//! minimization drops the state *count* without slowing matching. A sparse transition encoding
//! was deliberately *not* adopted: it would trade that single-load hot loop for smaller tables.
//!
//! ## Status
//!
//! `auto`'s **default span engine** (since 0.3.0). `find`/`isMatch` are **O(input) on every
//! supported pattern** — quadratic-immune, including `$`/`\z` (matched by a reverse-DFA-from-end
//! pass; covers `anchored_end` patterns and all-branch-`$` alternations like `foo$|bar$`).
//! **`(?m)` line anchors** (`line_start`/`line_end`) run here too, via **anchored restart with line
//! context** (`\n` isolated into its own byte class; the start state chosen by the preceding byte;
//! a one-byte `\n`-lookahead for `line_end`) — but only when **non-prone** (`(?m)^\w+`, `(?m)foo$`);
//! a *prone* `(?m)` (an unbounded run before the anchor, `(?m)\w+$`) is declined (anchored restart
//! would be Θ(n²) and the reverse fix can't carry line context). **`\b`/`\B` word boundaries** run
//! here too, via the **same anchored-restart machinery applied to ASCII word-ness**: the ASCII word
//! set `[0-9A-Za-z_]` is isolated into its own byte classes, the start state is chosen by the
//! preceding byte's word-ness (`startNW`), and acceptance uses a one-byte **word-lookahead**
//! (`accept_before_word`/`accept_before_nonword`) — the mirror of `(?m)$`'s `\n`-lookahead. This is
//! an **ASCII** word boundary (exact for ASCII text); the dispatcher (`auto`) keeps a `\b` program's
//! **non-ASCII** input on the code-point Pike VM (correct **Unicode** boundaries), and `\b` combined
//! with `$`/`(?m)`, a *prone* `\b` (`\b.*x`), or a *chained* `\b\b` are declined. **Known,
//! intentional gaps**, each declined to the code-point engines (correct + linear, just not
//! DFA-accelerated): *mixed* `$` (`a$|b`), *prone* `(?m)`/`\b`, `\b`+`$`/`(?m)`, chained `\b\b`, and
//! `\X` (a grapheme — variable-width, not a byte property). **Build-time:** determinization is
//! hash-interned (~O(states)), so even big Unicode-class builds stay fast — a one-time cost, match
//! time is O(input). All detailed below.
//!
//! **Invariant:** every pattern `supports` accepts matches in **O(input)** (a hard contract — the
//! eager DFA never takes a super-linear path) and **leftmost-first** (byte-identical spans to the
//! Pike VM, `conformance.zig`). If you pin `edfa` directly, a declined or too-large pattern is
//! `error.Unsupported` at build (a `@compileError` at comptime) — there is no silent fallback.
//! Through `auto` the decline is invisible: it routes to a capable backend, so `auto` is correct
//! by construction for every pattern.
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
//!     times are a runtime-lazy-DFA job. `supports(hir)` is **broader than `dfa.supports`**:
//!     byte-lowerable, with `text_start` (`\A`/`^`) and **`anchored_end` `text_end`** (`$`/`\z`
//!     where every match ends at input end) zero-width assertions — see *find* below.
//!
//! ## `find` start location — three O(input) arms, fixed statically per program
//!
//! The match-start strategy is chosen at build (`computeProne` + `anchored_end`), never probed
//! per search, and **every arm is O(input)** (quadratic-immune by contract):
//!
//!   * **Anchored restart** — a non-prone pattern (its consuming loop is itself accepting:
//!     `\w+`, `\d+`, `[A-Za-z]+`) walks the frozen table greedily from each candidate start;
//!     O(input) because no start scans far without hitting an accepting state. A leading
//!     `\A`/`^` (`anchored_start`) tries only offset 0. `isMatch` is the earliest-exit form.
//!   * **Reverse-DFA two-pass** — a *prone* pattern (can consume an unbounded run before it can
//!     accept, e.g. `\w+@\w+`'s pre-`@` run) locates the match END forward (`utrans`) then the
//!     START with a frozen reverse DFA — replacing the old Θ(n²) anchored restart.
//!   * **Reverse-DFA from end** — a trailing-`$` (`end_anchored`) pattern (`\w+$`, `[ab]*c$`,
//!     `\w+@\w+$`, and `$`-in-every-branch alternations like `foo$|bar$`) pins the end at
//!     `input.len`, so one reverse pass from there finds the start. The reverse determinizer
//!     models `$` via a passable `text_end` reverse edge.
//!
//! **Limitation — *mixed* `$` is declined, not run slowly.** A `text_end` in only SOME branches
//! of an alternation (`a$|b`, `[ab]*c$|x`) leaves the match end un-pinned, so neither the
//! forward end-find nor reverse-from-end applies. Rather than fall back to a Θ(n²) anchored
//! restart, `supports` **declines** it (`has_text_end and !anchored_end`) and `auto` routes it
//! to the **Pike VM** — correct and linear, just not DFA-accelerated. A two-seed reverse DFA
//! could keep it on the DFA, but the shape is rare and already linear, so it is intentionally
//! deferred.
//!
//! ## Build-time cost — determinization is ~O(states) (hash-interned)
//!
//! The forward and reverse determinizers intern DFA states through an **open-addressing hash
//! index** (`hashPcs`), so building a big Unicode-class DFA is **~linear in the state count**.
//! (This was an O(states²) linear scan — `\w+@\w+`, `\w+@\w+$`, `\p{L}+$` took ~seconds to
//! *compile*; now milliseconds.) Determinizing a large Unicode class (hundreds-to-thousands of
//! states over a ~100-symbol alphabet) is still the dominant build cost, but it is a **one-time
//! cost; match time is O(input), unaffected**. ASCII-class and literal patterns build instantly.
//!
//! ## Invalid UTF-8 — dead-on-invalid, for free
//!
//! The byte lowering emits edges only for well-formed UTF-8, so a malformed byte has no
//! transition out of any state and lands in the dead state; the restart wrapper resyncs
//! past it. No validity check in the loop, no decode.

const std = @import("std");

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const byte = @import("engine_base").byte;
const dfa = @import("dfa");

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
    /// OR it holds a pending end-of-input assertion (`text_end` `$`/`\z`, or `line_end` `(?m)$`)
    /// whose continuation reaches `match`. The matcher checks this once, when the scan reaches
    /// `input.len`. Equal to `accept` for a pattern with no `$` (so the check is a no-op there).
    ///
    /// @stable-since: v0.3.0
    accept_eoi: []const bool,
    /// `accept_before_nl[state]` — is this state accepting **just before a `\n`**: it holds a
    /// pending `line_end` (`(?m)$`) whose continuation reaches `match`. The matcher checks it at a
    /// position whose next byte is `\n`. Equal to `accept` for a non-`(?m)$` program (the matcher
    /// only consults it for `has_line_anchor` programs).
    ///
    /// @stable-since: v0.4.0
    accept_before_nl: []const bool,
    /// `accept_before_word[state]` — is this state accepting **just before an ASCII word byte**:
    /// it holds a pending `\b`/`\B` whose fire-on-word continuation reaches `match`. Consulted
    /// (with a one-byte word-lookahead) only for `has_word_boundary` programs; equal to `accept`
    /// otherwise.
    ///
    /// @stable-since: v0.4.0
    accept_before_word: []const bool,
    /// `accept_before_nonword[state]` — is this state accepting **just before a non-word byte**:
    /// a pending `\b`/`\B` whose fire-on-non-word continuation reaches `match`. Consulted (one-byte
    /// lookahead) only for `has_word_boundary` programs; equal to `accept` otherwise. (At end of
    /// input the "next byte" is treated as non-word, folded into `accept_eoi`.)
    ///
    /// @stable-since: v0.4.0
    accept_before_nonword: []const bool,
    /// Start state with `text_start` + `line_start` TRUE (used at offset 0).
    start0: u32,
    /// Start state with `text_start` + `line_start` FALSE (offset > 0, not just after a `\n`).
    /// Equals `start0` for a pattern with no `\A`/`^`/`(?m)^`.
    startN: u32,
    /// Start state with `line_start` TRUE, `text_start` FALSE — the entry for an unanchored
    /// match beginning **just after a `\n`** (a `(?m)^` line start at offset > 0). Equals
    /// `startN` for a program with no `(?m)^`. Only consulted for `has_line_anchor` programs.
    ///
    /// @stable-since: v0.4.0
    startL: u32,
    /// Start state with `word_left` TRUE (`text_start`/`line_start` FALSE) — the entry for a match
    /// beginning at offset > 0 whose **preceding byte is an ASCII word byte** (the left context a
    /// leading `\b`/`\B` needs). `runAnchored` picks it when `isAsciiWordByte(input[s-1])`. Equals
    /// `startN` for a program with no `\b`/`\B`. Only consulted for `has_word_boundary` programs.
    ///
    /// @stable-since: v0.4.0
    startNW: u32,
    /// True when the program carries a `(?m)` line anchor (`line_start`/`line_end`). Such a
    /// program runs on **anchored restart** with line context: the start state is chosen per
    /// position by the preceding byte (`start0`/`startL`/`startN`), and `line_end` is matched via
    /// `accept_before_nl` with a one-byte `\n` lookahead. Quadratic-immune because `supports`
    /// declines a *prone* line pattern (an unbounded run before the anchor) to the Pike VM.
    ///
    /// @stable-since: v0.4.0
    has_line_anchor: bool,
    /// True when the program carries a `\b`/`\B` word boundary. Such a program runs on
    /// **anchored restart** with word context: the start state is chosen per position by the
    /// preceding byte's ASCII word-ness (`start0`/`startNW`/`startN`), and acceptance uses a
    /// one-byte word-lookahead (`accept_before_word`/`accept_before_nonword`). The boundary is an
    /// **ASCII** word boundary; `auto` keeps non-ASCII input for such a program on the code-point
    /// Pike VM (Unicode word boundaries). Mutually exclusive with `has_line_anchor` and `$`
    /// (`supports` declines those combos).
    ///
    /// @stable-since: v0.4.0
    has_word_boundary: bool,
    /// True when every match must begin at offset 0 (a leading `\A` / non-multiline `^`).
    /// The search then tries only `s == 0`.
    anchored_start: bool,
    /// True when anchored restart is unsafe — some start can scan a long non-accepting run before
    /// accepting/dying. Two shapes: a **non-accepting cycle** reachable from a start (an *unbounded*
    /// run, Θ(n²) — `\w+@\w+`'s pre-`@` word run), or a **long bounded** non-accepting prefix
    /// (`a{4000}b`, longest non-accepting path > `RESTART_SCAN_LIMIT`, Θ(n·k)). Both take the
    /// O(input) reverse-DFA `find` (and gate `auto`'s per-occurrence prefilter confirm); a non-prone
    /// one (`\w+`, `\d+`, `a{4}b`) keeps the faster anchored restart. Computed once (`computeProne`).
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
    /// For an `end_anchored` (`$`) program the closure passes back through the trailing
    /// `text_end`, so `rstart` represents "at end-of-input, `$` satisfied, ready to match
    /// the pattern backward".
    ///
    /// @stable-since: v0.3.0
    rstart: u32,
    /// True when every match ends at end-of-input (a trailing `$`/`\z`, fully `anchored_end`)
    /// and the pattern is not `anchored_start`. The match end is then pinned to `input.len`,
    /// so `find`/`isMatch` need no forward scan: a single reverse-DFA pass from `input.len`
    /// finds the leftmost start in **O(input)** — the fix for the Θ(n²) anchored-restart
    /// blowup on begin-but-don't-complete `$` shapes (`[ab]*c$`, `\w+@\w+$`, `\w+$`). Implies
    /// `rev_built` (the reverse DFA models `$` via a passable `text_end` reverse edge). A
    /// **mixed** `$` pattern (`text_end` in only some branches, e.g. `a$|b`) is declined by
    /// `supports` and routed to the Pike VM, so it never reaches here.
    ///
    /// @stable-since: v0.3.0
    end_anchored: bool,
};

/// Whether this HIR can run on the eager DFA: byte-lowerable (no `\X` grapheme) **and** whose
/// zero-width assertions are a supported subset:
///   * `text_start` (`\A`/`^`) — evaluated at offset 0 via the start closures.
///   * `text_end` (`$`/`\z`) — only when **every match ends at input end** (`anchored_end`),
///     matched O(input) by the reverse-DFA-from-end path. A **mixed** `$` (text_end in only some
///     branches, `a$|b`) has no pinned end → would be Θ(n²) → declined to the Pike VM.
///   * `line_start`/`line_end` (`(?m)^`/`(?m)$`) — matched by **anchored restart** with line
///     context (`\n` isolated into its own byte class; the start state is chosen per position).
///     This is O(input) only when the pattern is **non-prone** (no unbounded run before the
///     anchor); a *prone* line pattern (`(?m)\w+$`, `(?m).*^x`) is declined at **build** time
///     (`buildAlloc`) and routed to the linear Pike VM, since the reverse-DFA fix does not carry
///     line context. So `supports` admits line anchors here; the proneness gate is in the build.
///   * `word_boundary`/`not_word_boundary` (`\b`/`\B`) — matched by **anchored restart** with ASCII
///     **word context** (the ASCII word set is isolated into its own byte classes; the start state
///     is chosen by the preceding byte's word-ness; acceptance uses a one-byte word-lookahead).
///     Admitted ONLY in isolation — combined with `$` or `(?m)` line anchors it is declined here
///     (the lookahead interactions are deferred), and a *prone* `\b` (`\b.*x`) or *chained* `\b\b`
///     is declined at **build**. The boundary is an **ASCII** word boundary; `auto` keeps a `\b`
///     program's **non-ASCII** input on the code-point Pike VM (correct Unicode boundaries).
/// `\X` stays on the code-point engines. (Whether the determinized DFA *fits* the fixed bounds is a
/// separate build-time check; this is the capability gate.)
///
/// @stable-since: v0.3.0
pub fn supports(h: hir.Hir) bool {
    if (!byte.byteLowerable(h)) return false; // excludes \X (grapheme)
    var has_text_end = false;
    var has_line = false;
    var has_word = false;
    for (h.nodes) |n| {
        if (n.tag == .anchor) switch (n.data.anchor.kind) {
            .text_start => {}, // text_start at offset 0 (the start closures)
            .line_start, .line_end => has_line = true, // line anchors via anchored restart
            .text_end => has_text_end = true,
            .word_boundary, .not_word_boundary => has_word = true, // ASCII \b/\B (see below)
        };
    }
    // Quadratic immunity is a hard contract — the eager DFA never takes a super-linear path.
    // A `text_end` pattern is linear only when its end is pinned to input end (`anchored_end`),
    // matched by the reverse-DFA-from-end pass. A mixed `$` (not `anchored_end`) would fall to
    // the Θ(n²) anchored restart, so decline it; `auto` then uses the linear Pike VM. (Line
    // anchors' analogous proneness gate is in `buildAlloc`, which knows the determinized DFA.)
    if (has_text_end and !h.analysis.anchored_end) return false;
    // `\b`/`\B` are baked into the byte DFA as **ASCII** word boundaries (start-context + a
    // one-byte word-lookahead at acceptance — see the determinizer/`runAnchored`), but only in
    // ISOLATION: combined with `$` (`text_end`) or `(?m)` line anchors the lookahead interactions
    // are deferred to the Pike VM (correct + linear there). `auto` keeps a `\b` program's
    // **non-ASCII** input on the Pike VM too (Unicode word boundaries). Chained boundaries
    // (`\b\b`) are declined at build (`buildAlloc`/`buildComptime`).
    if (has_word and (has_text_end or has_line)) return false;
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
/// FNV-1a hash of a canonical pc list — the key the determinizers intern DFA states by. Pure
/// integer ops (no `@Vector`), so it runs at comptime as well as runtime.
fn hashPcs(pcs: []const u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (pcs) |v| {
        h ^= v;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Open-addressing table capacity for up to `state_count` states: the next power of two that
/// keeps the load factor ≤ 0.5 (so linear probing always finds an empty slot), floored at 16.
/// Caller-sized, so the hash index is a fixed buffer — comptime-able like the rest of the
/// determinizer.
fn htCap(state_count: u32) u32 {
    var c: u32 = 16;
    while (c < state_count *| 2) c *|= 2;
    return c;
}

const Det = struct {
    insts: []const byte.Inst,
    classes: *const byte.ByteClasses,
    class_rep: *const [256]u8,
    n_classes: u32,
    /// `reaches_end[pc]` — does `pc` reach `match` following only epsilon edges with the
    /// end-of-input assertions (`text_end` **and** `line_end`, both true at `input.len`)
    /// passable? Used to compute `accept_eoi` when the closure parks a pending `$` pc.
    /// All-false for a program with no `$`/`(?m)$`.
    reaches_end: []const bool,
    /// `reaches_nl[pc]` — does `pc` reach `match` with **`line_end` passable but `text_end`
    /// not** (the before-a-`\n` view: at a non-final `\n`, `line_end` holds, `text_end` does
    /// not)? Drives `accept_before_nl`. All-false unless the program has a `(?m)$` line anchor.
    reaches_nl: []const bool,
    /// `reaches_meps[pc]` — does `pc` reach `match` via **pure epsilon** edges (`jmp`/`split`/`save`)
    /// only, with every assertion and `byte_range` blocking? Drives word-boundary acceptance: a
    /// parked `\b`/`\B` whose continuation (`pc+1`) `reaches_meps` and that fires for the next
    /// byte's word-ness makes its state accepting before such a byte. All-false for a `$`-style
    /// program; chained boundaries (a `\b` whose continuation epsilon-reaches another assertion)
    /// are declined at build, so this stays a sound acceptance signal for `\b` programs.
    reaches_meps: []const bool,
    /// The byte class of `\n` (0x0A), or `maxInt` for a non-line program (so `c == nl_class`
    /// is never true and the line-context fork is dormant). `byteClasses` isolates `\n` into
    /// its own class exactly when the program has a `(?m)` line anchor.
    nl_class: u32 = std.math.maxInt(u32),
    /// True when the program carries a `\b`/`\B` word boundary (drives word-context determinization:
    /// the closure carries `at_word_left`, boundaries park, and acceptance/transitions resolve the
    /// next byte's ASCII word-ness). False ⇒ the word-context machinery is dormant (no state split).
    has_word: bool = false,
    /// Skip building the unanchored `utrans` rows. Line-anchor and word-boundary programs run on
    /// **anchored restart** only (the `.*?`-prefix unanchored automaton can't carry line-start /
    /// word-left context), so their `utrans` would be unused dead weight that also inflates states.
    skip_utrans: bool = false,

    // ── frozen-DFA outputs (caller buffers) ──
    state_off: []u32, // state id → start of its pc list in `pc_pool`
    state_len: []u32, // state id → length of its pc list
    accept: []bool, // state id → accepting mid-input?
    accept_eoi: []bool, // state id → accepting at end of input (accept ∨ a pending `$`/`\b`-at-end)?
    accept_before_nl: []bool, // state id → accepting just before a `\n` (a pending `(?m)$` line_end)?
    accept_before_word: []bool, // state id → accepting just before an ASCII word byte (pending `\b`/`\B`)?
    accept_before_nonword: []bool, // state id → accepting just before a non-word byte (pending `\b`/`\B`)?
    state_wl: []bool, // state id → the `word_left` context it was closed with (only meaningful when it parks a boundary)
    trans: []u32, // n_states × n_classes (anchored)
    utrans: []u32, // n_states × n_classes (unanchored: ∪ a fresh start each edge)
    pc_pool: []u32, // concatenated, priority-ordered pc lists
    state_hash: []u32, // open-addressing index keyed on the pc list: slot → state id + 1 (0 = empty)
    htmask: u32, // state_hash.len - 1 (a power of two)
    n_states: u32 = 0,
    pool_len: u32 = 0,

    // ── per-closure work buffers (no allocation during a closure) ──
    seen: []u32, // generation-stamped pc dedup
    seen_gen: u32 = 0,
    stack: []u32, // closure DFS stack
    work: []u32, // closure result (the pc list being built)
    work_len: u32 = 0,
    work_match: bool = false,
    work_match_eoi: bool = false, // a pending end-of-input assertion in this closure reaches match
    work_match_nl: bool = false, // a pending `(?m)$` (line_end) in this closure reaches match before a `\n`
    work_match_word: bool = false, // a pending `\b`/`\B` fires before a word byte and reaches match
    work_match_nonword: bool = false, // a pending `\b`/`\B` fires before a non-word byte and reaches match
    work_word_left: bool = false, // the `word_left` context this closure was computed with
    work_has_wb: bool = false, // this closure parked at least one `\b`/`\B` member
    seeds: []u32, // successor pcs feeding a closure

    start0: u32 = DEAD, // text_start + line_start true (offset 0); word_left false
    startN: u32 = DEAD, // text_start + line_start false (offset > 0, not after `\n`); word_left false
    startL: u32 = DEAD, // line_start true, text_start false (offset > 0, just after a `\n`); == startN if no line_start
    startNW: u32 = DEAD, // word_left true (offset > 0, preceding byte a word byte); == startN if no `\b`/`\B`

    /// Epsilon-closure of `seeds` into `work` (priority order, deduplicated, cut on
    /// match) — the byte analogue of the Pike VM's thread closure, minus capture slots,
    /// identical to the lazy DFA's. `at_start` is whether the position is offset 0 (what
    /// `text_start` depends on); `at_line_start` is whether the position is a line start —
    /// offset 0, or just after a `\n` (what `(?m)^` `line_start` depends on). A `text_end`
    /// (`$`/`\z`) or `line_end` (`(?m)$`) is recorded as a pending **member** (it consumes no
    /// byte, so the thread parks): `work_match_eoi` is set when it reaches `match` at end of
    /// input, and `work_match_nl` when a `line_end` reaches `match` before a `\n`. Writes
    /// `work`/`work_len`/`work_match`/`work_match_eoi`/`work_match_nl`.
    fn closure(self: *Det, seeds: []const u32, at_start: bool, at_line_start: bool, at_word_left: bool) void {
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        self.work_len = 0;
        self.work_match = false;
        self.work_match_eoi = false;
        self.work_match_nl = false;
        self.work_match_word = false;
        self.work_match_nonword = false;
        self.work_has_wb = false;
        self.work_word_left = at_word_left;

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
                            // `(?m)^` line_start holds iff at a line start (offset 0 or after a `\n`).
                            .line_start => {
                                if (!at_line_start) break :follow;
                                pc += 1;
                            },
                            // `text_end` parks here (consumes no byte): a member, accepting at end
                            // of input if its continuation reaches `match`.
                            .text_end => {
                                self.work[self.work_len] = pc;
                                self.work_len += 1;
                                if (self.reaches_end[pc]) self.work_match_eoi = true;
                                break :follow;
                            },
                            // `(?m)$` line_end parks too: accepting at end of input AND just before
                            // a `\n` (the two positions where line_end holds).
                            .line_end => {
                                self.work[self.work_len] = pc;
                                self.work_len += 1;
                                if (self.reaches_end[pc]) self.work_match_eoi = true;
                                if (self.reaches_nl[pc]) self.work_match_nl = true;
                                break :follow;
                            },
                            // `\b`/`\B` (ASCII) park here: their fire depends on the **next** byte's
                            // word-ness, resolved per-class at the transition (see collectBoundarySeeds).
                            // For acceptance we know the left context (`at_word_left`); if the boundary's
                            // continuation reaches `match` via pure epsilon, the state accepts when the
                            // boundary fires. `\b` fires iff word_left != word_right; `\B` iff equal.
                            .word_boundary, .not_word_boundary => {
                                self.work[self.work_len] = pc;
                                self.work_len += 1;
                                self.work_has_wb = true;
                                if (self.reaches_meps[pc + 1]) {
                                    const is_b = k == .word_boundary;
                                    const fire_word = if (is_b) !at_word_left else at_word_left; // next byte a word byte
                                    const fire_nonword = if (is_b) at_word_left else !at_word_left; // next byte non-word / eoi
                                    if (fire_word) self.work_match_word = true;
                                    if (fire_nonword) {
                                        self.work_match_nonword = true;
                                        self.work_match_eoi = true; // end of input: the "next byte" is non-word
                                    }
                                }
                                break :follow;
                            },
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
                            self.work_match_eoi = true; // a mid-input match also accepts at end…
                            self.work_match_nl = true; // …before a `\n`…
                            self.work_match_word = true; // …and before a word or non-word byte
                            self.work_match_nonword = true;
                            // Cut: every lower-priority thread (on the stack or in later
                            // seeds) is discarded — the Pike VM's match cut.
                            break :seeds_loop;
                        },
                    }
                }
            }
        }
    }

    /// Intern the state currently in `work[0..work_len]` to a dense id via the open-addressing
    /// hash index (`state_hash`, keyed by `hashPcs`): O(1) amortized — a hash collision falls
    /// back to a pc-list compare. On a fresh state, copies the pc list into `pc_pool` and records
    /// its accepting flags. Declines (`error.Unsupported`) on overflow of the state cap or pc
    /// pool. (Replaces the former O(states²) linear scan — the build-time hot spot for big
    /// Unicode classes; semantics are identical, so the conformance suite guards it.)
    fn intern(self: *Det) DetError!u32 {
        const key = self.work[0..self.work_len];
        // A boundary-bearing closure's identity includes its `word_left` context (it transitions /
        // accepts differently for the same pc list), so fold it into the key — but ONLY then, so a
        // boundary-free program never splits states on word context (zero state inflation).
        var h = hashPcs(key);
        if (self.work_has_wb) h = (h ^ @intFromBool(self.work_word_left)) *% 0x100000001b3;
        var slot: u32 = @as(u32, @truncate(h)) & self.htmask;
        while (self.state_hash[slot] != 0) : (slot = (slot + 1) & self.htmask) {
            const id = self.state_hash[slot] - 1;
            const off = self.state_off[id];
            if (self.state_len[id] == key.len and std.mem.eql(u32, self.pc_pool[off .. off + key.len], key) and
                (!self.work_has_wb or self.state_wl[id] == self.work_word_left))
                return id;
        }
        if (self.n_states >= self.state_off.len) return error.Unsupported; // > max_states
        if (self.pool_len + key.len > self.pc_pool.len) return error.Unsupported; // pool full
        const id = self.n_states;
        const off = self.pool_len;
        @memcpy(self.pc_pool[off .. off + key.len], key);
        self.state_off[id] = off;
        self.state_len[id] = @intCast(key.len);
        self.state_wl[id] = self.work_word_left;
        self.accept[id] = self.work_match;
        self.accept_eoi[id] = self.work_match_eoi;
        self.accept_before_nl[id] = self.work_match_nl;
        self.accept_before_word[id] = self.work_match_word;
        self.accept_before_nonword[id] = self.work_match_nonword;
        self.pool_len += @intCast(key.len);
        self.n_states += 1;
        self.state_hash[slot] = id + 1;
        return id;
    }

    /// Successor pcs of `state_id` on the class with representative byte `rep`: the
    /// `next` of every `byte_range` in the state that contains `rep`, in priority order,
    /// appended starting at `seeds[base]`. Returns the COUNT appended (so callers can
    /// union two states' successors by chaining `base`s — the unanchored row does this).
    fn collectSeeds(self: *Det, state_id: u32, rep: u8, base: u32, word_right: bool) u32 {
        var ns: u32 = base;
        const off = self.state_off[state_id];
        const wl = self.state_wl[state_id];
        for (self.pc_pool[off .. off + self.state_len[state_id]]) |pc| switch (self.insts[pc]) {
            .byte_range => |r| if (r.range.lo <= r.range.hi and r.range.contains(rep)) {
                self.seeds[ns] = r.next;
                ns += 1;
            },
            .match => {}, // terminal: no outgoing edge
            .assertion => |k| switch (k) {
                // A parked `\b`/`\B` fires for the consumed class iff its left/right word-ness
                // match (`\b`: differ; `\B`: equal). When it fires, its continuation contributes
                // byte transitions — followed here in the boundary's priority position.
                .word_boundary, .not_word_boundary => {
                    const is_b = k == .word_boundary;
                    const fires = if (is_b) (wl != word_right) else (wl == word_right);
                    if (fires) ns = self.followBoundary(pc + 1, rep, ns);
                },
                else => {}, // pending end-assertion ($/\z or (?m)$): no byte transition
            },
            else => unreachable, // a canonical state holds only byte_range / match / assertion pcs
        };
        return ns - base;
    }

    /// Priority-ordered pure-epsilon walk from a fired boundary's continuation `start_pc`,
    /// appending the `next` of every `byte_range` reachable (without consuming) that contains
    /// `rep`. Reuses `seen`/`stack` with a fresh generation (no `closure` runs concurrently — a
    /// transition first `collectSeeds`, then `closure`s the result). `text_start` is dead mid-input;
    /// chained boundaries are declined at build, so no `\b`/`\B` appears here. Returns the new count.
    fn followBoundary(self: *Det, start_pc: u32, rep: u8, base: u32) u32 {
        var ns = base;
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        var top: usize = 0;
        self.stack[top] = start_pc;
        top += 1;
        while (top > 0) {
            top -= 1;
            var pc = self.stack[top];
            follow: while (true) {
                if (self.seen[pc] == gen) break :follow;
                self.seen[pc] = gen;
                switch (self.insts[pc]) {
                    .jmp => |t| pc = t,
                    .split => |s| {
                        self.stack[top] = s.b;
                        top += 1;
                        pc = s.a;
                    },
                    .save => pc += 1,
                    .byte_range => |r| {
                        if (r.range.lo <= r.range.hi and r.range.contains(rep)) {
                            self.seeds[ns] = r.next;
                            ns += 1;
                        }
                        break :follow;
                    },
                    .assertion => break :follow, // text_start dead mid; end-assertions park; \b chains declined
                    .match => break :follow, // accepting position, not a byte transition
                }
            }
        }
        return ns;
    }

    /// Determinize fully. Reserve DEAD = the empty set (state 0), intern the start states,
    /// then breadth-first compute every `(state, class)` edge. The worklist is the growing
    /// `0..n_states` range — `intern` appends new states, the loop reaches them. Fills
    /// `state_*`, `accept`, `trans` (and `utrans` unless `skip_utrans`), `start0/startN/startL`.
    fn run(self: *Det) DetError!void {
        @memset(self.seen, 0);
        @memset(self.state_hash, 0); // empty index (0 = empty slot)

        // DEAD = the empty set (work_len already 0).
        self.work_len = 0;
        self.work_match = false;
        self.work_match_eoi = false;
        self.work_match_nl = false;
        self.work_match_word = false;
        self.work_match_nonword = false;
        self.work_has_wb = false;
        std.debug.assert((try self.intern()) == DEAD);

        // Start states: closure of pc 0 in the position contexts. `startL` (line start, not text
        // start) equals `startN` when the program has no `line_start`; `startNW` (word_left true)
        // equals `startN` when the program has no `\b`/`\B` — so each costs nothing when dormant.
        self.closure(&[_]u32{0}, true, true, false); // offset 0: text_start ✓, line_start ✓, word_left ✗
        self.start0 = try self.intern();
        self.closure(&[_]u32{0}, false, false, false); // offset > 0, not after `\n`, preceding non-word
        self.startN = try self.intern();
        self.closure(&[_]u32{0}, false, true, false); // offset > 0, just after a `\n` (line start)
        self.startL = try self.intern();
        self.closure(&[_]u32{0}, false, false, true); // offset > 0, preceding byte a word byte
        self.startNW = try self.intern();

        // Worklist = the growing `0..n_states` range (intern appends, the loop reaches them).
        // DEAD (the empty set) is NOT special-cased: `collectSeeds(DEAD)` yields nothing.
        var sid: u32 = 0;
        while (sid < self.n_states) : (sid += 1) {
            var c: u32 = 0;
            while (c < self.n_classes) : (c += 1) {
                const rep = self.class_rep[c];
                // The destination is a **line start** iff the byte just consumed was `\n` — how the
                // anchored DFA carries `(?m)^` context forward. The destination's **word_left** is
                // the consumed byte's ASCII word-ness — how it carries `\b`/`\B` context forward
                // (`has_word` is false for a non-`\b` program, so this stays false there).
                const at_line_start = (c == self.nl_class);
                const word_right = self.has_word and byte.isAsciiWordByte(rep);
                // Anchored row: successors of this state only (a parked boundary that fires for this
                // class contributes its continuation's byte transitions — see collectSeeds).
                const na = self.collectSeeds(sid, rep, 0, word_right);
                self.closure(self.seeds[0..na], false, at_line_start, word_right); // a transition is always at sp > 0
                self.trans[sid * self.n_classes + c] = try self.intern();
                // Unanchored row: this state's successors ∪ a fresh start (`startN`) — the implicit
                // `(?s:.)*?` prefix. Skipped for line / word-boundary programs (they run on anchored
                // restart; the position-independent re-seed can't carry line-start / word-left context).
                if (!self.skip_utrans) {
                    var nu = self.collectSeeds(sid, rep, 0, word_right);
                    nu += self.collectSeeds(self.startN, rep, nu, word_right);
                    self.closure(self.seeds[0..nu], false, false, word_right);
                    self.utrans[sid * self.n_classes + c] = try self.intern();
                }
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
// determinized into a frozen table at build (comptime + runtime). Built for assertion-free
// programs AND trailing-`$` (`text_end`, `anchored_end`) programs: for the latter the match
// end is pinned at `input.len`, so one reverse pass from there finds the leftmost start, and
// the trailing `text_end` is treated as a passable reverse epsilon (`buildAdj`). A
// `text_start` is position-dependent, so its reverse transitions are not cacheable — those
// keep anchored restart.

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
    r_state_hash: []u32, // open-addressing index keyed on the (sorted) pc list: slot → rstate id + 1
    r_htmask: u32, // r_state_hash.len - 1 (a power of two)

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

    /// Build the reverse adjacency from the byte program: two passes — count in-edges per pc,
    /// prefix-sum to offsets, fill. Programs reaching here are assertion-free except for a
    /// trailing `text_end` (`$`/`\z`), which is recorded as a **passable reverse epsilon** so a
    /// `$` pattern's `revClosure(match)` walks back through it into the pre-`$` states. Reuses
    /// `work`/`seeds` as the transient fill cursors (overwritten by the first closure after).
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
            // `text_end` ($/\z) is a passable epsilon (forward edge i → i+1): record its
            // reverse predecessor so `revClosure(match)` walks back through it. Only `text_end`
            // / assertion-free programs build the reverse DFA (a `text_start` keeps anchored
            // restart), so no other assertion kind occurs here.
            .assertion => |k| if (k == .text_end) {
                self.reps_off[i + 1] += 1;
            },
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
                .assertion => |k| if (k == .text_end) { // passable epsilon — see the count pass
                    self.reps[ec[i + 1]] = pc;
                    ec[i + 1] += 1;
                },
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

    /// Intern the reverse state in `work[0..work_len]` (sorted first, so set-equal states collapse
    /// to one id) via the open-addressing hash index (`r_state_hash`, keyed by `hashPcs` on the
    /// sorted list): O(1) amortized, collision → pc-list compare. Records its accept flag on first
    /// sight. Declines (`error.Unsupported`) on state-cap or pc-pool overflow. (Replaces the former
    /// O(states²) linear scan — semantics identical, conformance-guarded.)
    fn intern(self: *RDet) DetError!u32 {
        sortAsc(self.work[0..self.work_len]);
        const key = self.work[0..self.work_len];
        var slot: u32 = @as(u32, @truncate(hashPcs(key))) & self.r_htmask;
        while (self.r_state_hash[slot] != 0) : (slot = (slot + 1) & self.r_htmask) {
            const id = self.r_state_hash[slot] - 1;
            const off = self.r_state_off[id];
            if (self.r_state_len[id] == key.len and std.mem.eql(u32, self.r_pc_pool[off .. off + key.len], key))
                return id;
        }
        if (self.n_rstates >= self.r_state_off.len) return error.Unsupported;
        if (self.rpool_len + key.len > self.r_pc_pool.len) return error.Unsupported;
        const id = self.n_rstates;
        const off = self.rpool_len;
        @memcpy(self.r_pc_pool[off .. off + key.len], key);
        self.r_state_off[id] = off;
        self.r_state_len[id] = @intCast(key.len);
        self.raccept[id] = self.work_match;
        self.rpool_len += @intCast(key.len);
        self.n_rstates += 1;
        self.r_state_hash[slot] = id + 1;
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
        @memset(self.r_state_hash, 0); // empty index (0 = empty slot)

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
    const r_ht = htCap(r_state_cap);
    const r_state_hash = try gpa.alloc(u32, r_ht); // open-addressing intern index (≤ 0.5 load)
    defer gpa.free(r_state_hash);

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
        .r_state_hash = r_state_hash,
        .r_htmask = r_ht - 1,
    };
    rdet.run() catch return error.Unsupported;

    // Minimize the reverse DFA in place (Moore; single table `rtrans`, colour = `raccept`; no
    // secondary table). Reverse states are plain sets, so this is the biggest win — a prone
    // `\w+@\w+`'s reverse DFA is ~3251 states. `r_state_hash` is reused as the signature index.
    var rn = rdet.n_rstates;
    {
        const blk = try gpa.alloc(u32, rn);
        defer gpa.free(blk);
        const nblk = try gpa.alloc(u32, rn);
        defer gpa.free(nblk);
        const rrep = try gpa.alloc(u32, rn);
        defer gpa.free(rrep);
        var i: u32 = 0;
        while (i < rn) : (i += 1) blk[i] = @intFromBool(rdet.raccept[i]);
        const n_new = minimizeDfa(rdet.rtrans, &.{}, false, rn, nc, blk, nblk, rrep, r_state_hash, r_ht - 1);
        var b: u32 = 0;
        while (b < n_new) : (b += 1) { // rrep[b] >= b ⇒ in-place compaction is safe
            const r = rrep[b];
            rdet.raccept[b] = rdet.raccept[r];
            var c: u32 = 0;
            while (c < nc) : (c += 1) rdet.rtrans[b * nc + c] = blk[rdet.rtrans[r * nc + c]];
        }
        rdet.rstart = blk[rdet.rstart];
        rn = n_new;
    }

    const rtrans = try gpa.dupe(u32, rdet.rtrans[0 .. rn * nc]);
    errdefer gpa.free(rtrans);
    const raccept = try gpa.dupe(bool, rdet.raccept[0..rn]);
    return .{ .rtrans = rtrans, .raccept = raccept, .rstart = rdet.rstart };
}

// ── Anchored-restart safety: a non-accepting cycle, OR a long bounded prefix ─────────

/// Longest **bounded** non-accepting prefix tolerated on anchored restart before a pattern is
/// treated like a prone one. Anchored restart (and the prefilter's per-occurrence confirm) scans
/// up to the longest non-accepting path from a start before it accepts or dies, so the per-restart
/// cost is O(this). A non-accepting *cycle* makes that path unbounded (Θ(n²)); a long *bounded*
/// prefix (`a{4000}b`) makes it Θ(n·k) with a large k — still a ReDoS-shaped blowup. Capping it
/// here routes such patterns to the O(input) reverse two-pass instead. Common patterns sit far
/// below this (`\w+` ≈ 3, `a{4}b` = 4, `foo\d+` ≈ 3), so they keep the fast anchored restart.
///
/// @stable-since: v0.4.0
const RESTART_SCAN_LIMIT: u32 = 64;

/// Whether anchored restart is unsafe on the frozen anchored DFA — i.e. some start can consume a
/// **long run staying entirely in non-accepting states** before it accepts or dies. Two shapes
/// qualify, both routed to the O(input) reverse-DFA find instead of the Θ(per-restart-length)
/// anchored restart:
///   * a **non-accepting cycle** reachable from a start (`\w+@\w+`'s `@`-free run) — the run is
///     *unbounded*, so anchored restart is Θ(n²); a back-edge in the DFS proves it.
///   * a **long bounded** non-accepting prefix (`a{4000}b`) — no cycle, but the longest
///     non-accepting path exceeds `RESTART_SCAN_LIMIT`, so anchored restart is Θ(n·k) with a large
///     k (and the prefilter's per-occurrence confirm re-scans the whole prefix at every dense hit).
/// Non-prone patterns (`\w+`/`\d+` — their consuming loop is accepting; short literals) keep the
/// faster anchored restart. A 3-colour DFS over the non-accepting, non-dead subgraph detects the
/// cycle; `longest[s]` (the longest non-accepting path from `s`, filled post-order — valid since
/// the subgraph is a DAG once cycles are excluded) detects the long bounded prefix.
/// `color`/`stack`/`iter`/`longest` are caller buffers sized to the state count (comptime + runtime).
fn computeProne(
    trans: []const u32,
    accept: []const bool,
    accept_before_word: []const bool,
    accept_before_nonword: []const bool,
    n_states: u32,
    nc: u32,
    start0: u32,
    startN: u32,
    startL: u32,
    startNW: u32,
    color: []u8,
    stack: []u32,
    iter: []u32,
    longest: []u32,
) bool {
    const WHITE: u8 = 0;
    const GRAY: u8 = 1;
    const BLACK: u8 = 2;
    // A state is a **safe exit** if it accepts mid-input OR via a one-byte lookahead (`\b`/`\B`'s
    // `accept_before_word`/`accept_before_nonword`): the anchored-restart run terminates there (it
    // accepts as soon as the run meets the boundary's expected next byte), so it is NOT an
    // unbounded non-accepting run. Folding the word-lookahead in keeps `\b\w+\b` (whose `\w+`
    // self-loop accepts before a non-word byte) correctly classed **non-prone**.
    const Acc = struct {
        a: []const bool,
        w: []const bool,
        nw: []const bool,
        fn at(self: @This(), id: u32) bool {
            return self.a[id] or self.w[id] or self.nw[id];
        }
    };
    const acc = Acc{ .a = accept, .w = accept_before_word, .nw = accept_before_nonword };
    var i: u32 = 0;
    while (i < n_states) : (i += 1) color[i] = WHITE;

    // All entry states a search can begin from — including the line-start (`startL`) and word-left
    // (`startNW`) starts (each equals `startN` for a non-line / non-`\b` program, so the visited
    // check dedups it).
    for ([_]u32{ start0, startN, startL, startNW }) |start| {
        if (start == DEAD or acc.at(start) or color[start] != WHITE) continue;
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
                if (nxt == DEAD or acc.at(nxt)) continue; // dead / accepting = a safe exit, not a Θ(n²) run
                if (color[nxt] == GRAY) return true; // back-edge ⇒ non-accepting cycle
                if (color[nxt] == WHITE) {
                    color[nxt] = GRAY;
                    stack[top] = nxt;
                    iter[top] = 0;
                    top += 1;
                }
            } else {
                // Finish `s` (post-order): every non-accepting, non-dead successor is now BLACK
                // (no cycle ⇒ none is still GRAY), so `longest` is settled for them. The longest
                // non-accepting path from `s` is 1 + the deepest such successor's.
                var best: u32 = 0;
                var cc: u32 = 0;
                while (cc < nc) : (cc += 1) {
                    const nx = trans[@as(usize, s) * nc + cc];
                    if (nx == DEAD or acc.at(nx)) continue;
                    if (longest[nx] + 1 > best) best = longest[nx] + 1;
                }
                longest[s] = best;
                if (best > RESTART_SCAN_LIMIT) return true; // long bounded non-accepting prefix
                color[s] = BLACK;
                top -= 1;
            }
        }
    }
    return false;
}

/// `out[pc]` ← does `pc` reach `match` via epsilon edges only, with the **end-of-input**
/// assertions (`text_end` `$`/`\z` **and** `line_end` `(?m)$`, both true at `input.len`)
/// passable? Drives `accept_eoi`: a closure that parks a pending `$`/`(?m)$` pc whose
/// `reaches_end` is true makes its state accepting at end of input. `text_start`/`line_start`
/// are *not* passable here (they need offset 0 / a preceding `\n`, which the at-end view lacks
/// in general — the empty-input `^…$` case is covered by the start closures). A monotone
/// backward fixpoint; all-false for a program with no `$`. `out` is a caller buffer sized to
/// the instruction count, so the identical code runs at comptime and runtime.
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
                .assertion => |k| (k == .text_end or k == .line_end) and out[i + 1], // both hold at end
                .byte_range => false, // consumes a byte — no input left at end
            };
            if (r) {
                out[i] = true;
                changed = true;
            }
        }
    }
}

/// `out[pc]` ← does `pc` reach `match` with **`line_end` `(?m)$` passable but `text_end` NOT**?
/// This is the view at a *non-final* `\n`, where `(?m)$` holds (the next byte is `\n`) but `$`/`\z`
/// does not (it is not end-of-input). Drives `accept_before_nl`: a closure that parks a pending
/// `(?m)$` whose `reaches_nl` is true makes its state accepting just before a `\n`. All-false
/// unless the program has a `(?m)$`. Caller buffer, comptime + runtime.
fn computeNlReaches(insts: []const byte.Inst, out: []bool) void {
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
                .save => out[i + 1],
                .assertion => |k| k == .line_end and out[i + 1], // only (?m)$ holds before a non-final \n
                .byte_range => false,
            };
            if (r) {
                out[i] = true;
                changed = true;
            }
        }
    }
}

/// `out[pc]` ← does `pc` reach `match` via **pure epsilon** edges (`jmp`/`split`/`save`) only —
/// every assertion AND `byte_range` blocking? Drives `\b`/`\B` acceptance: a parked boundary whose
/// continuation `pc+1` is `reaches_meps` makes its state accepting (when the boundary fires) before
/// the relevant next byte. Chained boundaries are declined at build, so for a `\b` program this is
/// the exact "the boundary's continuation directly reaches match" signal. Monotone backward
/// fixpoint; all-false unless there is a `\b`/`\B`. Caller buffer, comptime + runtime.
fn computeMepsReaches(insts: []const byte.Inst, out: []bool) void {
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
                .save => out[i + 1],
                .assertion => false, // any zero-width assertion blocks a pure-epsilon path to match
                .byte_range => false,
            };
            if (r) {
                out[i] = true;
                changed = true;
            }
        }
    }
}

/// `out[pc]` ← does `pc`, via pure epsilon (`jmp`/`split`/`save`), reach a zero-width **assertion**
/// (the assertion node itself counts)? A `\b`/`\B` whose continuation `pc+1` does is *chained* — its
/// fire/acceptance would need nested word-context resolution (deferred) — so the program is declined
/// to the Pike VM (`hasChainedBoundary`). Real patterns never chain boundaries; this only guards the
/// pathological `\b\b`/`\b\B` shapes. Caller buffer; comptime + runtime.
fn computeEpsReachesAssertion(insts: []const byte.Inst, out: []bool) void {
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
                .assertion => true,
                .jmp => |t| out[t],
                .split => |s| out[s.a] or out[s.b],
                .save => out[i + 1],
                .byte_range, .match => false,
            };
            if (r) {
                out[i] = true;
                changed = true;
            }
        }
    }
}

/// Whether any `\b`/`\B` in `insts` is chained (its continuation `pc+1` epsilon-reaches another
/// assertion). `era` is a caller scratch buffer (`computeEpsReachesAssertion` fills it). A chained
/// program is declined to the Pike VM. Comptime + runtime.
fn hasChainedBoundary(insts: []const byte.Inst, era: []bool) bool {
    computeEpsReachesAssertion(insts, era);
    for (insts, 0..) |inst, idx| switch (inst) {
        .assertion => |k| switch (k) {
            .word_boundary, .not_word_boundary => if (era[idx + 1]) return true,
            else => {},
        },
        else => {},
    };
    return false;
}

// ── DFA minimization (Moore partition-refinement, dense; comptime + runtime) ─────────
//
// After determinization the frozen tables are correct but **not minimal** — distinct DFA states
// can be language-equivalent (e.g. a Unicode class fans its multi-byte continuations into many
// states that behave identically once past the lead byte). Moore's algorithm partitions the
// states by their accept signature, then refines by successor-block signature to a fixpoint;
// each resulting block is one state of the minimal DFA. It is **results-invariant** (the minimal
// DFA accepts exactly the same language) and shrinks `ro_data`/heap and the working set. Kept
// dense (one `trans[state*nc + class]` load in the hot loop — the eager DFA's headline) — only
// the state *count* drops; the row layout is unchanged. Pure integer ops over caller buffers, so
// the identical code runs at comptime and runtime, like the determinizers.

/// FNV-1a over a state's equivalence signature: its current block plus the blocks of its `t1`
/// (and, when `has_t2`, `t2`) successors per class. Two states with different signatures are
/// provably inequivalent; equal hashes are confirmed by `sigEq`.
fn sigHashOf(t1: []const u32, t2: []const u32, has_t2: bool, blk: []const u32, s: u32, nc: u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    h ^= blk[s];
    h *%= 0x100000001b3;
    var c: u32 = 0;
    while (c < nc) : (c += 1) {
        h ^= blk[t1[s * nc + c]];
        h *%= 0x100000001b3;
    }
    if (has_t2) {
        c = 0;
        while (c < nc) : (c += 1) {
            h ^= blk[t2[s * nc + c]];
            h *%= 0x100000001b3;
        }
    }
    return h;
}

/// Exact equality of two states' equivalence signatures (same block, same successor blocks for
/// every class in `t1` and — when `has_t2` — `t2`). The collision check behind `sigHashOf`.
fn sigEqOf(t1: []const u32, t2: []const u32, has_t2: bool, blk: []const u32, r: u32, s: u32, nc: u32) bool {
    if (blk[r] != blk[s]) return false;
    var c: u32 = 0;
    while (c < nc) : (c += 1) if (blk[t1[r * nc + c]] != blk[t1[s * nc + c]]) return false;
    if (has_t2) {
        c = 0;
        while (c < nc) : (c += 1) if (blk[t2[r * nc + c]] != blk[t2[s * nc + c]]) return false;
    }
    return true;
}

/// Moore partition-refinement minimization of a complete dense DFA over caller buffers. `t1` is
/// the primary transition table (`n_states × nc`); `t2` is an optional secondary table folded into
/// the signature (the forward DFA's `utrans` for a prone program — `has_t2 = false` ignores it).
/// `blk` holds the **initial colour** per state on entry (a small dense key combining the accept
/// flags) and the **final block id** (`remap[old] = new`) on return. States merge iff
/// indistinguishable under their colour AND every successor block, to a fixpoint, so the minimised
/// DFA accepts the same language. DEAD (old 0) maps to new 0 (state 0 is scanned first every
/// round, so it always lands in block 0). `rep[new]` is filled with the lowest old state of each
/// block (so `rep[b] >= b`, which makes the caller's in-place compaction safe). Returns the
/// minimised state count. `sig_hash` is an open-addressing index (length a power of two ≥ 2·states,
/// so the load factor stays ≤ 0.5); `htmask = sig_hash.len - 1`. O(rounds × n_states × nc) with
/// `rounds` the partition depth (small in practice).
fn minimizeDfa(
    t1: []const u32,
    t2: []const u32,
    has_t2: bool,
    n_states: u32,
    nc: u32,
    blk: []u32,
    nblk: []u32,
    rep: []u32,
    sig_hash: []u32,
    htmask: u32,
) u32 {
    var cur: u32 = 0;
    while (true) {
        for (sig_hash) |*v| v.* = 0; // empty index (0 = empty slot)
        var next_count: u32 = 0;
        var s: u32 = 0;
        while (s < n_states) : (s += 1) {
            const h = sigHashOf(t1, t2, has_t2, blk, s, nc);
            var slot: u32 = @as(u32, @truncate(h)) & htmask;
            while (sig_hash[slot] != 0) : (slot = (slot + 1) & htmask) {
                const r = sig_hash[slot] - 1;
                if (sigEqOf(t1, t2, has_t2, blk, r, s, nc)) {
                    nblk[s] = nblk[r]; // same group as an earlier state this round
                    break;
                }
            } else {
                sig_hash[slot] = s + 1; // new group: this state is its representative
                nblk[s] = next_count;
                next_count += 1;
            }
        }
        @memcpy(blk[0..n_states], nblk[0..n_states]);
        if (next_count == cur) break; // count stopped growing ⇒ partition is stable
        cur = next_count;
    }
    var b: u32 = 0;
    while (b < cur) : (b += 1) rep[b] = n_states; // sentinel
    var s2: u32 = 0;
    while (s2 < n_states) : (s2 += 1) {
        if (rep[blk[s2]] == n_states) rep[blk[s2]] = s2;
    }
    return cur;
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

    // Which zero-width assertions the program carries (one scan; independent of DFA states).
    // `text_end`/`text_start` choose the reverse-from-end / anchored-restart paths; a `(?m)` line
    // anchor switches on anchored restart with line context (`\n` isolated into `nl_class`).
    var has_text_start = false;
    var has_text_end = false;
    var has_line = false;
    var has_word = false;
    for (bp.insts) |inst| switch (inst) {
        .assertion => |k| switch (k) {
            .text_start => has_text_start = true,
            .text_end => has_text_end = true,
            .line_start, .line_end => has_line = true,
            .word_boundary, .not_word_boundary => has_word = true,
        },
        else => {},
    };
    const nl_class: u32 = if (has_line) classes.map['\n'] else std.math.maxInt(u32);

    const ic: u32 = @intCast(bp.insts.len);

    // Decline a CHAINED `\b`/`\B` (a boundary whose continuation epsilon-reaches another assertion):
    // its nested word-context resolution is deferred to the Pike VM. Real patterns never chain
    // boundaries; this guards the pathological `\b\b`. Done before the big allocations (fail fast).
    if (has_word) {
        const era = try gpa.alloc(bool, ic);
        defer gpa.free(era);
        if (hasChainedBoundary(bp.insts, era)) return error.Unsupported;
    }

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
    const accept_before_nl_buf = try gpa.alloc(bool, state_cap);
    defer gpa.free(accept_before_nl_buf);
    const accept_before_word_buf = try gpa.alloc(bool, state_cap);
    defer gpa.free(accept_before_word_buf);
    const accept_before_nonword_buf = try gpa.alloc(bool, state_cap);
    defer gpa.free(accept_before_nonword_buf);
    const state_wl_buf = try gpa.alloc(bool, state_cap);
    defer gpa.free(state_wl_buf);
    const reaches_end = try gpa.alloc(bool, ic);
    defer gpa.free(reaches_end);
    computeEndReaches(bp.insts, reaches_end);
    const reaches_nl = try gpa.alloc(bool, ic);
    defer gpa.free(reaches_nl);
    if (has_line) computeNlReaches(bp.insts, reaches_nl) else @memset(reaches_nl, false);
    const reaches_meps = try gpa.alloc(bool, ic);
    defer gpa.free(reaches_meps);
    if (has_word) computeMepsReaches(bp.insts, reaches_meps) else @memset(reaches_meps, false);
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
    const ht = htCap(state_cap);
    const state_hash = try gpa.alloc(u32, ht); // open-addressing intern index (≤ 0.5 load)
    defer gpa.free(state_hash);

    var det = Det{
        .insts = bp.insts,
        .classes = &classes,
        .class_rep = &class_rep,
        .n_classes = nc,
        .reaches_end = reaches_end,
        .reaches_nl = reaches_nl,
        .reaches_meps = reaches_meps,
        .nl_class = nl_class,
        .has_word = has_word,
        .skip_utrans = true, // phase 1: trans only (utrans is built in phase 2, prone-only — below)
        .state_off = state_off,
        .state_len = state_len,
        .accept = accept_buf,
        .accept_eoi = accept_eoi_buf,
        .accept_before_nl = accept_before_nl_buf,
        .accept_before_word = accept_before_word_buf,
        .accept_before_nonword = accept_before_nonword_buf,
        .state_wl = state_wl_buf,
        .trans = trans_buf,
        .utrans = utrans_buf,
        .pc_pool = pc_pool,
        .seen = seen,
        .stack = stack,
        .work = work,
        .seeds = seeds,
        .state_hash = state_hash,
        .htmask = ht - 1,
    };
    det.run() catch return error.Unsupported; // phase 1: anchored `trans` only

    // Anchored-restart safety on the **unminimized** trans-only DFA: a non-accepting cycle, OR a
    // long bounded non-accepting prefix (`computeProne`). It is a language property (preserved by
    // minimization and unaffected by the utrans phase), so computing it on the trans-only DFA is
    // valid. `\w+@\w+`'s pre-`@` run is prone; `\w+`/`a{4}b` are not.
    const prone = blk: {
        const pc = det.n_states;
        const pcolor = try gpa.alloc(u8, pc);
        defer gpa.free(pcolor);
        const pstack = try gpa.alloc(u32, pc);
        defer gpa.free(pstack);
        const piter = try gpa.alloc(u32, pc);
        defer gpa.free(piter);
        const plong = try gpa.alloc(u32, pc);
        defer gpa.free(plong);
        break :blk computeProne(det.trans[0 .. pc * nc], det.accept, det.accept_before_word, det.accept_before_nonword, pc, nc, det.start0, det.startN, det.startL, det.startNW, pcolor, pstack, piter, plong);
    };

    // Quadratic-immunity gate for line anchors: a *prone* `(?m)` pattern (an unbounded/long run
    // before the anchor, e.g. `(?m)\w+$`, `(?m).*^x`) can't run linearly on anchored restart, and
    // the reverse fix can't carry line context — so decline it to the linear Pike VM. Non-prone
    // line patterns (`(?m)^\w+`, `(?m)foo$`) stay on anchored restart, O(input).
    if (has_line and prone) return error.Unsupported;
    // Same quadratic-immunity gate for word boundaries: a *prone* `\b` pattern (`\b.*x` — an
    // unbounded non-accepting run after the boundary) can't run linearly on anchored restart, and
    // the reverse DFA can't evaluate `\b`. Decline it to the linear Pike VM. The common `\b`
    // shapes (`\bword\b`, `\b\w+\b`, `s\b`) are non-prone (their loop accepts via the word
    // lookahead, which `computeProne` honours), so they keep the fast anchored restart.
    if (has_word and prone) return error.Unsupported;

    // **Phase 2 (prone, non-line only): re-determinize with the unanchored `utrans` table** for the
    // O(input) reverse two-pass. A NON-prone pattern runs entirely on anchored restart (`trans`),
    // so it never needs `utrans` — skipping it keeps the build smaller/faster (the `.*?`-prefix
    // `utrans` states are the bulk for many patterns) AND lets medium counted reps (`a{64}b`) fit
    // the eager DFA instead of overflowing on unused `utrans` states. A prone pattern whose
    // `utrans` overflows the fixed bounds declines here and falls to the (unbounded) lazy DFA.
    if (prone) { // ⟹ !has_line (declined above)
        det.skip_utrans = false;
        det.n_states = 0;
        det.pool_len = 0;
        det.run() catch return error.Unsupported;
    }

    // Minimize the forward DFA in place (Moore partition-refinement; results-invariant — the
    // minimal DFA accepts the same language). Only the state *count* drops; the dense row layout
    // (one `trans[s*nc + c]` load, the hot loop) is untouched. `has_t2 = prone` so `utrans` is in
    // the signature iff it was built/consulted. `state_hash` is reused as the signature index.
    const n0 = det.n_states;
    var n = n0;
    {
        const blk = try gpa.alloc(u32, n0);
        defer gpa.free(blk);
        const nblk = try gpa.alloc(u32, n0);
        defer gpa.free(nblk);
        const rep = try gpa.alloc(u32, n0);
        defer gpa.free(rep);
        var i: u32 = 0;
        while (i < n0) : (i += 1)
            blk[i] = @as(u32, @intFromBool(det.accept[i])) |
                (@as(u32, @intFromBool(det.accept_eoi[i])) << 1) |
                (@as(u32, @intFromBool(det.accept_before_nl[i])) << 2) |
                (@as(u32, @intFromBool(det.accept_before_word[i])) << 3) |
                (@as(u32, @intFromBool(det.accept_before_nonword[i])) << 4);
        const n_new = minimizeDfa(det.trans, det.utrans, prone, n0, nc, blk, nblk, rep, state_hash, ht - 1);
        var b: u32 = 0;
        while (b < n_new) : (b += 1) { // rep[b] >= b ⇒ writing row b while reading row rep[b] is in-place safe
            const r = rep[b];
            det.accept[b] = det.accept[r];
            det.accept_eoi[b] = det.accept_eoi[r];
            det.accept_before_nl[b] = det.accept_before_nl[r];
            det.accept_before_word[b] = det.accept_before_word[r];
            det.accept_before_nonword[b] = det.accept_before_nonword[r];
            var c: u32 = 0;
            while (c < nc) : (c += 1) {
                det.trans[b * nc + c] = blk[det.trans[r * nc + c]];
                if (prone) det.utrans[b * nc + c] = blk[det.utrans[r * nc + c]];
            }
        }
        det.start0 = blk[det.start0];
        det.startN = blk[det.startN];
        det.startL = blk[det.startL];
        det.startNW = blk[det.startNW];
        n = n_new;
    }

    // Keep only the used prefix of the (now minimized) tables + accept flags (right-sized copies).
    const trans = try gpa.dupe(u32, det.trans[0 .. n * nc]);
    errdefer gpa.free(trans);
    const accept = try gpa.dupe(bool, det.accept[0..n]);
    errdefer gpa.free(accept);
    const accept_eoi = try gpa.dupe(bool, det.accept_eoi[0..n]);
    errdefer gpa.free(accept_eoi);
    const accept_before_nl = try gpa.dupe(bool, det.accept_before_nl[0..n]);
    errdefer gpa.free(accept_before_nl);
    const accept_before_word = try gpa.dupe(bool, det.accept_before_word[0..n]);
    errdefer gpa.free(accept_before_word);
    const accept_before_nonword = try gpa.dupe(bool, det.accept_before_nonword[0..n]);
    errdefer gpa.free(accept_before_nonword);

    // The unanchored `utrans` table and the reverse DFA are consulted **only** on the prone
    // arm (one-pass `isMatch` + reverse-DFA `find`). A non-prone pattern runs entirely on
    // `trans` (anchored restart, O(input)), so neither is built — saving the bulk of the eager
    // DFA's memory on the common case (`\w+` skips ~850 KB of utrans + reverse). A `text_start`
    // program additionally has no reverse table (its reverse transitions are position-dependent),
    // so a prone `text_start` pattern keeps anchored restart.
    const utrans: []const u32 = if (prone) try gpa.dupe(u32, det.utrans[0 .. n * nc]) else &.{};
    errdefer if (prone) gpa.free(utrans);
    // A trailing-`$` pattern (every match ends at input end — `supports` declined mixed `$`,
    // so `has_text_end` ⟹ `anchored_end` here) takes the O(input) reverse-DFA-from-end path
    // instead of anchored restart, so it needs the reverse table too. `prone` and
    // `end_anchored` are mutually exclusive (`prone` requires no `$`), so one reverse
    // table / `rstart` serves whichever applies; a `text_start` keeps anchored restart.
    const end_anchored = has_text_end and h.analysis.anchored_end and !has_text_start;
    var rev = Reverse{ .rtrans = &.{}, .raccept = &.{}, .rstart = DEAD };
    // `\b` programs never build the reverse DFA: they use anchored restart (and a prone one is
    // already declined above), and `RDet` cannot evaluate a word boundary anyway.
    const rev_built = (prone or end_anchored) and !has_text_start and !has_word;
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
        .accept_before_nl = accept_before_nl,
        .accept_before_word = accept_before_word,
        .accept_before_nonword = accept_before_nonword,
        .start0 = det.start0,
        .startN = det.startN,
        .startL = det.startL,
        .startNW = det.startNW,
        .has_line_anchor = has_line,
        .has_word_boundary = has_word,
        .anchored_start = h.analysis.anchored_start,
        .prone = prone,
        .has_text_start = has_text_start,
        .rev_built = rev_built,
        .rtrans = rev.rtrans,
        .raccept = rev.raccept,
        .rstart = rev.rstart,
        .end_anchored = end_anchored,
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
    if (!comptime supports(h)) @compileError("edfa: HIR is not byte/DFA-lowerable (\\X grapheme, a mixed `$`, or `\\b`/`\\B` combined with `$`/`(?m)`)");
    // Comptime-size guard (DX): determinizing a big Unicode class (`\w`, `\p{L}`) or `.` (the whole
    // scalar space) at compile time exhausts the const-eval allocator — an opaque `OutOfMemory` —
    // long before `max_states`. Refuse those up front with a clear message instead. `auto` never
    // trips this: its `tinyForComptimeEdfa` gate keeps such patterns on the NFA at comptime and uses
    // the eager DFA for them only at *runtime* (`buildAlloc`), where there is no such limit. This
    // only guards a direct `compileComptimeWith(backends.edfa, …)`. Thresholds are generous, so
    // moderate ASCII patterns (the CTRE-lane sweet spot) still bake fine.
    comptime {
        if (h.ranges.len > 32 or h.nodes.len > 96 or h.literals.len > 64)
            @compileError("edfa.buildComptime: pattern too large for comptime determinization (big Unicode class) — use buildAlloc at runtime, or backends.dfa");
        for (h.nodes) |n| if (n.tag == .any)
            @compileError("edfa.buildComptime: `.` lowers to the whole-scalar-space automaton, too large at comptime — use buildAlloc at runtime, or backends.dfa");
    }
    const bp = comptime byte.buildComptime(h);
    const classes = comptime byte.byteClasses(&bp);
    const nc = classes.count;
    comptime var class_rep: [256]u8 = @splat(0);
    comptime {
        var b: u16 = 0;
        while (b < 256) : (b += 1) class_rep[classes.map[b]] = @intCast(b);
    }

    // Which zero-width assertions the program carries (see `buildAlloc`).
    comptime var has_text_start = false;
    comptime var has_text_end = false;
    comptime var has_line = false;
    comptime var has_word = false;
    comptime {
        for (bp.insts) |inst| switch (inst) {
            .assertion => |k| switch (k) {
                .text_start => has_text_start = true,
                .text_end => has_text_end = true,
                .line_start, .line_end => has_line = true,
                .word_boundary, .not_word_boundary => has_word = true,
            },
            else => {},
        };
    }
    const nl_class: u32 = if (has_line) classes.map['\n'] else std.math.maxInt(u32);

    const ic: u32 = bp.insts.len;

    // Decline a CHAINED `\b`/`\B` (see `buildAlloc`/`hasChainedBoundary`): a `@compileError` here
    // (a direct comptime `edfa` use; `auto` keeps comptime `\b` on the Pike VM via `tinyForComptimeEdfa`).
    comptime {
        if (has_word) {
            var era: [ic]bool = undefined;
            if (hasChainedBoundary(bp.insts, &era))
                @compileError("edfa: chained word boundary (\\b\\b); route to the Pike VM (use compileComptime, not edfa directly)");
        }
    }
    // Determinization closure work is ~states × classes × (split-tree traversal); a prone pattern
    // determinizes twice (trans-only, then again with `utrans`) and the reverse determinization
    // adds a comparable pass — size the quota for all of them. Large Unicode classes are slow to
    // determinize at comptime but produce a tiny table — the CTRE-lane trade.
    @setEvalBranchQuota(@intCast(@min(600_000 + @as(u64, ic) * 1600, std.math.maxInt(u32))));

    const state_cap = @min(ic + 256, max_states); // pattern-proportional, capped
    comptime var state_off: [state_cap]u32 = undefined;
    comptime var state_len: [state_cap]u32 = undefined;
    comptime var accept_buf: [state_cap]bool = undefined;
    comptime var accept_eoi_buf: [state_cap]bool = undefined;
    comptime var accept_before_nl_buf: [state_cap]bool = undefined;
    comptime var accept_before_word_buf: [state_cap]bool = undefined;
    comptime var accept_before_nonword_buf: [state_cap]bool = undefined;
    comptime var state_wl_buf: [state_cap]bool = undefined;
    comptime var reaches_end: [ic]bool = undefined;
    comptime computeEndReaches(bp.insts, &reaches_end);
    comptime var reaches_nl: [ic]bool = undefined;
    comptime {
        if (has_line) computeNlReaches(bp.insts, &reaches_nl) else @memset(&reaches_nl, false);
    }
    comptime var reaches_meps: [ic]bool = undefined;
    comptime {
        if (has_word) computeMepsReaches(bp.insts, &reaches_meps) else @memset(&reaches_meps, false);
    }
    comptime var trans_buf: [state_cap * @as(usize, nc)]u32 = undefined;
    comptime var utrans_buf: [state_cap * @as(usize, nc)]u32 = undefined;
    comptime var pc_pool: [ic * pool_factor]u32 = undefined;
    comptime var seen: [ic]u32 = undefined;
    comptime var stack: [2 * ic + 1]u32 = undefined;
    comptime var work: [ic + 1]u32 = undefined;
    comptime var seeds: [2 * ic + 2]u32 = undefined; // unanchored row unions two states' seeds
    const ht = htCap(state_cap);
    comptime var state_hash: [ht]u32 = undefined; // open-addressing intern index (zeroed in run)

    comptime var det = Det{
        .insts = bp.insts,
        .classes = &classes,
        .class_rep = &class_rep,
        .n_classes = nc,
        .reaches_end = &reaches_end,
        .reaches_nl = &reaches_nl,
        .reaches_meps = &reaches_meps,
        .nl_class = nl_class,
        .has_word = has_word,
        .skip_utrans = true, // phase 1: trans only (utrans built in phase 2, prone-only — below)
        .state_off = &state_off,
        .state_len = &state_len,
        .accept = &accept_buf,
        .accept_eoi = &accept_eoi_buf,
        .accept_before_nl = &accept_before_nl_buf,
        .accept_before_word = &accept_before_word_buf,
        .accept_before_nonword = &accept_before_nonword_buf,
        .state_wl = &state_wl_buf,
        .trans = &trans_buf,
        .utrans = &utrans_buf,
        .pc_pool = &pc_pool,
        .seen = &seen,
        .stack = &stack,
        .work = &work,
        .seeds = &seeds,
        .state_hash = &state_hash,
        .htmask = ht - 1,
    };
    det.run() catch @compileError("edfa: pattern's DFA exceeds max_states; use the runtime lazy DFA (backends.dfa) instead"); // phase 1: anchored `trans` only

    // Anchored-restart safety on the trans-only DFA (a non-accepting cycle or a long bounded
    // prefix; a language property — see `buildAlloc`). Decides whether `utrans` is needed.
    comptime var pcolor: [state_cap]u8 = undefined;
    comptime var pstack: [state_cap]u32 = undefined;
    comptime var piter: [state_cap]u32 = undefined;
    comptime var plong: [state_cap]u32 = undefined;
    const prone = computeProne(trans_buf[0 .. det.n_states * nc], accept_buf[0..det.n_states], accept_before_word_buf[0..det.n_states], accept_before_nonword_buf[0..det.n_states], det.n_states, nc, det.start0, det.startN, det.startL, det.startNW, &pcolor, &pstack, &piter, &plong);
    // A prone `(?m)` line pattern can't run linearly on anchored restart and the reverse fix can't
    // carry line context — decline it (a `@compileError`; `auto` only calls `buildComptime` for
    // tiny patterns that never reach this).
    if (has_line and prone) @compileError("edfa: prone (?m) line pattern; route to the Pike VM (use compileComptime, not edfa directly)");
    // Same for a prone `\b` pattern (`\b.*x`): anchored restart would be Θ(n²) and the reverse DFA
    // can't evaluate `\b`. (Common `\b` shapes are non-prone — they keep anchored restart.)
    if (has_word and prone) @compileError("edfa: prone \\b pattern; route to the Pike VM (use compileComptime, not edfa directly)");

    // Phase 2 (prone, non-line only): re-determinize WITH the unanchored `utrans` table for the
    // O(input) reverse two-pass. A non-prone pattern runs on anchored restart (`trans` only), so it
    // skips this — keeping the comptime table small AND matching the runtime build. **At comptime
    // there is no lazy-DFA handoff** (the lazy DFA is runtime-only), so a prone pattern whose
    // `utrans` exceeds the fixed bound is a `@compileError`. `auto` never trips this: its
    // `tinyForComptimeEdfa` gate only calls `buildComptime` for patterns that provably fit both
    // phases; this fires only for a *direct* `compileComptimeWith(backends.edfa, …)` on a too-large
    // pattern, telling the user to use the runtime path.
    if (prone) { // ⟹ !has_line (declined above)
        det.skip_utrans = false;
        det.n_states = 0;
        det.pool_len = 0;
        det.run() catch @compileError("edfa: pattern's DFA (with the unanchored table) exceeds max_states at comptime — there is no lazy-DFA handoff at comptime (it is runtime-only); use buildAlloc at runtime, or backends.dfa");
    }
    const n0 = det.n_states;

    // Minimize the forward DFA in place (Moore partition-refinement; results-invariant; the dense
    // row layout is untouched, only the state count drops). `has_t2 = prone` so `utrans` joins the
    // signature iff it will be consulted. `state_hash` is reused as the signature index.
    comptime var blk: [state_cap]u32 = undefined;
    comptime var nblk: [state_cap]u32 = undefined;
    comptime var rep: [state_cap]u32 = undefined;
    const n = comptime min_fwd: {
        var i: u32 = 0;
        while (i < n0) : (i += 1)
            blk[i] = @as(u32, @intFromBool(accept_buf[i])) |
                (@as(u32, @intFromBool(accept_eoi_buf[i])) << 1) |
                (@as(u32, @intFromBool(accept_before_nl_buf[i])) << 2) |
                (@as(u32, @intFromBool(accept_before_word_buf[i])) << 3) |
                (@as(u32, @intFromBool(accept_before_nonword_buf[i])) << 4);
        const n_new = minimizeDfa(&trans_buf, &utrans_buf, prone, n0, nc, &blk, &nblk, &rep, &state_hash, ht - 1);
        var b: u32 = 0;
        while (b < n_new) : (b += 1) { // rep[b] >= b ⇒ in-place compaction is safe
            const r = rep[b];
            accept_buf[b] = accept_buf[r];
            accept_eoi_buf[b] = accept_eoi_buf[r];
            accept_before_nl_buf[b] = accept_before_nl_buf[r];
            accept_before_word_buf[b] = accept_before_word_buf[r];
            accept_before_nonword_buf[b] = accept_before_nonword_buf[r];
            var c: u32 = 0;
            while (c < nc) : (c += 1) {
                trans_buf[b * nc + c] = blk[trans_buf[r * nc + c]];
                if (prone) utrans_buf[b * nc + c] = blk[utrans_buf[r * nc + c]];
            }
        }
        det.start0 = blk[det.start0];
        det.startN = blk[det.startN];
        det.startL = blk[det.startL];
        det.startNW = blk[det.startNW];
        break :min_fwd n_new;
    };

    const final_trans = trans_buf[0 .. n * nc].*;
    const final_accept = accept_buf[0..n].*;
    const final_accept_eoi = accept_eoi_buf[0..n].*;
    const final_accept_before_nl = accept_before_nl_buf[0..n].*;
    const final_accept_before_word = accept_before_word_buf[0..n].*;
    const final_accept_before_nonword = accept_before_nonword_buf[0..n].*;
    const final_utrans = if (prone) utrans_buf[0 .. n * nc].* else [_]u32{};

    // Reverse frozen DFA — only for a prone, assertion-free program or a trailing-`$`
    // (`end_anchored`) program (a `text_start` keeps `find` on anchored restart). Determinized
    // into ro_data at comptime via the same `RDet`.
    const end_anchored = has_text_end and h.analysis.anchored_end and !has_text_start;
    const rev_built = (prone or end_anchored) and !has_text_start and !has_word; // `\b` uses anchored restart; RDet can't evaluate it
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
    const r_ht = htCap(r_state_cap);
    comptime var r_state_hash: [r_ht]u32 = undefined; // open-addressing intern index (zeroed in run)
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
        .r_state_hash = &r_state_hash,
        .r_htmask = r_ht - 1,
    };
    if (rev_built) rdet.run() catch @compileError("edfa: reverse DFA exceeds bounds; use the runtime lazy DFA (backends.dfa) instead");

    // Minimize the reverse DFA in place (Moore; colour = `raccept`, no secondary table) — the
    // biggest table, so the biggest `ro_data` saving. `r_state_hash` is reused as the index.
    comptime var rblk: [r_state_cap]u32 = undefined;
    comptime var rnblk: [r_state_cap]u32 = undefined;
    comptime var rrep: [r_state_cap]u32 = undefined;
    const rn: u32 = if (rev_built) comptime min_rev: {
        const rn0 = rdet.n_rstates;
        var i: u32 = 0;
        while (i < rn0) : (i += 1) rblk[i] = @intFromBool(raccept_buf[i]);
        const n_new = minimizeDfa(&rtrans_buf, &.{}, false, rn0, nc, &rblk, &rnblk, &rrep, &r_state_hash, r_ht - 1);
        var b: u32 = 0;
        while (b < n_new) : (b += 1) { // rrep[b] >= b ⇒ in-place compaction is safe
            const r = rrep[b];
            raccept_buf[b] = raccept_buf[r];
            var c: u32 = 0;
            while (c < nc) : (c += 1) rtrans_buf[b * nc + c] = rblk[rtrans_buf[r * nc + c]];
        }
        rdet.rstart = rblk[rdet.rstart];
        break :min_rev n_new;
    } else 0;
    const final_rtrans = if (rev_built) rtrans_buf[0 .. rn * nc].* else [_]u32{};
    const final_raccept = if (rev_built) raccept_buf[0..rn].* else [_]bool{};

    return .{
        .classes = classes,
        .n_classes = nc,
        .trans = &final_trans,
        .utrans = &final_utrans,
        .accept = &final_accept,
        .accept_eoi = &final_accept_eoi,
        .accept_before_nl = &final_accept_before_nl,
        .accept_before_word = &final_accept_before_word,
        .accept_before_nonword = &final_accept_before_nonword,
        .start0 = det.start0,
        .startN = det.startN,
        .startL = det.startL,
        .startNW = det.startNW,
        .has_line_anchor = has_line,
        .has_word_boundary = has_word,
        .anchored_start = h.analysis.anchored_start,
        .prone = prone,
        .has_text_start = has_text_start,
        .rev_built = rev_built,
        .rtrans = &final_rtrans,
        .raccept = &final_raccept,
        .rstart = rdet.rstart,
        .end_anchored = end_anchored,
    };
}

/// @stable-since: v0.3.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.trans);
    if (program.prone) gpa.free(program.utrans); // empty (never allocated) for non-prone
    gpa.free(program.accept);
    gpa.free(program.accept_eoi);
    gpa.free(program.accept_before_nl);
    gpa.free(program.accept_before_word);
    gpa.free(program.accept_before_nonword);
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

/// Is `state` accepting at position `pos`? Mid-input via a `match` pc (`accept`); at
/// end-of-input via a pending `$`/`(?m)$` (`accept_eoi`); or, for a `(?m)$` line program, just
/// before a `\n` via a pending `line_end` (`accept_before_nl`, a one-byte lookahead). For a
/// `$`-free program `accept_eoi == accept` and `has_line_anchor` is false, so only `accept` matters.
/// **`\b`/`\B` programs do NOT use this** — they take the separate `runAnchoredWord`/`acceptsWord`
/// path, so this stays small enough for the hot common loop to inline (see `runAnchored`).
inline fn accepts(program: *const Program, state: u32, input: []const u8, pos: usize) bool {
    if (program.accept[state]) return true;
    if (pos == input.len) return program.accept_eoi[state];
    if (program.has_line_anchor and input[pos] == '\n') return program.accept_before_nl[state];
    return false;
}

/// Run the DFA anchored at `s`: the leftmost-first match end reached from `s`, or null
/// if no match begins exactly at `s`. With `earliest`, returns as soon as any accepting
/// state is entered; otherwise it scans on, keeping the last accepting position — which,
/// thanks to the priority/cut determinization, is the leftmost-first end. Acceptance is
/// position-aware (`accepts`): end-of-input (`$`/`\z`/`(?m)$`) and before-a-`\n` (`(?m)$`)
/// count too. For a `(?m)^` line program the **start state** is chosen by the preceding byte:
/// `start0` at offset 0, `startL` just after a `\n` (a line start), else `startN`.
fn runAnchored(program: *const Program, input: []const u8, s: usize, earliest: bool) ?usize {
    // BYTE-IDENTICAL to the pre-`\b` engine so the compiler inlines it into the anchored-restart
    // scans exactly as before (no class-scan regression). `\b`/`\B` programs never reach here:
    // `searchImpl`/`isMatch` route them to `runAnchoredWord` instead, keeping all word-boundary
    // code out of this hot common loop.
    const nc = program.n_classes;
    var state = if (s == 0)
        program.start0
    else if (program.has_line_anchor and input[s - 1] == '\n')
        program.startL
    else
        program.startN;
    var match_end: ?usize = if (accepts(program, state, input, s)) s else null;
    if (match_end != null and earliest) return match_end;

    var pos = s;
    while (pos < input.len) {
        const class = program.classes.map[input[pos]];
        state = program.trans[state * nc + class];
        if (state == DEAD) break;
        pos += 1;
        if (accepts(program, state, input, pos)) {
            match_end = pos;
            if (earliest) break;
        }
    }
    return match_end;
}

/// `accepts` for a `\b`/`\B` program: a pending boundary accepts depending on the **next** byte's
/// ASCII word-ness (a one-byte lookahead, the mirror of `accept_before_nl`). Word boundaries are
/// declined in combination with `$`/`(?m)`, so no line/`$`-only term beyond `accept_eoi` is needed.
inline fn acceptsWord(program: *const Program, state: u32, input: []const u8, pos: usize) bool {
    if (program.accept[state]) return true;
    if (pos == input.len) return program.accept_eoi[state];
    return if (byte.isAsciiWordByte(input[pos])) program.accept_before_word[state] else program.accept_before_nonword[state];
}

/// Anchored run for a `\b`/`\B` program (the ASCII word-boundary path). Identical in shape to
/// `runAnchored`, but the start state carries word-left context (`startNW` when the preceding byte
/// is a word byte) and acceptance uses the word lookahead (`acceptsWord`). Split out so the common
/// (non-`\b`) `runAnchored` stays minimal and inlinable.
fn runAnchoredWord(program: *const Program, input: []const u8, s: usize, earliest: bool) ?usize {
    const nc = program.n_classes;
    var state = if (s == 0)
        program.start0
    else if (byte.isAsciiWordByte(input[s - 1]))
        program.startNW // preceding byte is a word byte (the left context a leading `\b`/`\B` needs)
    else
        program.startN;
    var match_end: ?usize = if (acceptsWord(program, state, input, s)) s else null;
    if (match_end != null and earliest) return match_end;

    var pos = s;
    while (pos < input.len) {
        const class = program.classes.map[input[pos]];
        state = program.trans[state * nc + class];
        if (state == DEAD) break;
        pos += 1;
        if (acceptsWord(program, state, input, pos)) {
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

/// Leftmost match START for an `end_anchored` (trailing-`$`) program, where every match ends
/// at `input.len`. One reverse-DFA pass from `input.len` down to `lo` (`opts.start`); the
/// smallest position whose reverse state accepts (forward pc 0 reachable ⇒ `[pos, input.len)`
/// is a full match) is the leftmost-first start, or null if no suffix `[·, input.len)` matches.
/// Because `$`/`\z` pins the end at end-of-input, no forward end-find is needed — this single
/// O(input) backward pass is the whole search, and the fix for the Θ(n²) anchored restart on
/// begin-but-don't-complete `$` shapes (`[ab]*c$`, `\w+@\w+$`, `\w+$`).
///
/// @stable-since: v0.3.0
fn revFindEnd(program: *const Program, input: []const u8, lo: usize) ?usize {
    const nc = program.n_classes;
    const rtrans = program.rtrans;
    const raccept = program.raccept;
    const map = &program.classes.map;
    var state = program.rstart;
    var found: ?usize = if (raccept[state]) input.len else null; // empty match at end (`a*$` on "")
    var pos = input.len;
    while (pos > lo) {
        pos -= 1;
        const class = map[input[pos]];
        state = rtrans[state * nc + class];
        if (raccept[state]) found = pos;
        if (state == DEAD) break;
    }
    return found;
}

/// Leftmost match span. A pinned (`opts.anchored`) or start-anchored (`\A`/`^`) pattern is a
/// single anchored run. Otherwise the strategy is a **static, per-program choice** fixed at
/// build (so there is **no per-search probing**) — and every arm is O(input):
///
///   * **Reverse-DFA from end** — for a trailing-`$` program (`program.end_anchored`: every
///     match ends at `input.len`, e.g. `[ab]*c$`, `\w+@\w+$`, `\w+$`), the end is pinned, so a
///     single reverse pass from `input.len` finds the leftmost start. No forward scan, no
///     anchored restart (which would be Θ(n²) on these begin-but-don't-complete shapes).
///   * **Reverse-DFA two-pass** — for a **Θ(n²)-prone** pattern (`\w+@\w+`: a long pre-`@` word
///     run is a non-accepting cycle, so anchored restart re-scans it from every start), the
///     forward one-pass locates the leftmost match END and the reverse DFA the START.
///   * **Anchored restart** — otherwise (a pattern that *completes* at most start positions:
///     `\w+`, `[A-Za-z]+`, `\d+` — their consuming loop is itself accepting), one greedy table
///     walk per match, the eager DFA's headline ~1.1 GiB/s, O(input) because no start can scan
///     far without hitting an accepting state.
///
/// All arms are leftmost-first and agree (`conformance.zig`). `text_start` programs (no reverse
/// table) keep plain anchored restart. `earliest` only affects the anchored runs.
fn searchImpl(program: *const Program, input: []const u8, opts: SearchOptions, earliest: bool) ?Match {
    if (opts.start > input.len) return null;

    // `\b`/`\B` programs use the word-context anchored restart (`runAnchoredWord`); they are never
    // prone/`$`/end-anchored (declined), so this covers them, and the common `runAnchored` below
    // stays byte-identical to the pre-`\b` engine.
    if (program.has_word_boundary) {
        if (opts.anchored)
            return if (runAnchoredWord(program, input, opts.start, earliest)) |end| Match{ .start = opts.start, .end = end } else null;
        if (program.anchored_start) {
            if (opts.start != 0) return null;
            return if (runAnchoredWord(program, input, 0, earliest)) |end| Match{ .start = 0, .end = end } else null;
        }
        var s = opts.start;
        while (s <= input.len) : (s += 1) {
            if (runAnchoredWord(program, input, s, earliest)) |end| return Match{ .start = s, .end = end };
        }
        return null;
    }

    if (opts.anchored)
        return if (runAnchored(program, input, opts.start, earliest)) |end| Match{ .start = opts.start, .end = end } else null;

    if (program.anchored_start) {
        if (opts.start != 0) return null;
        return if (runAnchored(program, input, 0, earliest)) |end| Match{ .start = 0, .end = end } else null;
    }

    // Trailing `$` (every match ends at input.len): one reverse pass from the end finds the
    // leftmost start in O(input). The end is pinned, so no forward scan — and crucially no
    // anchored restart, which is Θ(n²) on `[ab]*c$`-style begin-but-don't-complete shapes.
    if (program.end_anchored) {
        const st = revFindEnd(program, input, opts.start) orelse return null;
        return Match{ .start = st, .end = input.len };
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
    // `\b`/`\B` programs: word-context anchored restart (earliest-exit). See `searchImpl`.
    if (program.has_word_boundary) {
        if (opts.anchored) return runAnchoredWord(program, input, opts.start, true) != null;
        if (program.anchored_start) {
            if (opts.start != 0) return false;
            return runAnchoredWord(program, input, 0, true) != null;
        }
        var s = opts.start;
        while (s <= input.len) : (s += 1) {
            if (runAnchoredWord(program, input, s, true) != null) return true;
        }
        return false;
    }
    if (opts.anchored) return runAnchored(program, input, opts.start, true) != null;
    if (program.anchored_start) {
        if (opts.start != 0) return false;
        return runAnchored(program, input, 0, true) != null;
    }
    // Trailing `$`: a single reverse pass from input.len — any start ⇒ a match. O(input).
    if (program.end_anchored) return revFindEnd(program, input, opts.start) != null;
    // Prone → one-pass over `utrans` (O(input), no Θ(n²)). Non-prone, non-`$` → anchored
    // restart, earliest-exit (O(input): with no non-accepting cycle and no `$`, no start can
    // scan far without hitting an accepting state), and it has no `utrans` table to consult.
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
const compile = @import("core").compile;
const pikevm = @import("pikevm");
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

// ── Quadratic immunity for trailing-`$` patterns (the begin-but-don't-complete class) ──
//
// Before the reverse-DFA-from-end path, a `text_end` pattern was forced onto anchored
// restart: from every start, walk to end-of-input and fail — Θ(n²) on `[ab]*c$`-style inputs
// with no completer. These tests pin both correctness (vs the Pike VM) and linearity (a large
// input finishes well under a budget a quadratic scan could never meet).

test "differential vs Pike VM: trailing `$` corpus (spans must agree)" {
    const patterns = [_][]const u8{
        "[a-z]+$",  "[a-z]+@[a-z]+$",   "[ab]*c$",  "a+$",      "\\d+$",
        "\\d{3}$",  "[0-9]+\\.[0-9]+$", ".*$",      ".*foo$",   "[a-z]+\\s*$",
        "x*$",      "(foo|bar)$",       "a$|b$",    "abc$",     "[α-ω]+$",
        "é+$",      "(?i)end$",
    };
    const inputs = [_][]const u8{
        "",              "abc",        "trailing 42",  "ends with foo",
        "no terminal c", "abcc",       "12.34",        "  spaced   ",
        "alice@host",    "ALICE@HOST", "αβγ",          "café",
        "the end",       "END",        "aaaaaaaa!",    "ababababc",
        "a@b",           "foo",        "bar",          "αβγδ end",
    };
    for (patterns) |p| try agreesWithPikeVM(testing.allocator, p, &inputs);
}

test "differential vs Pike VM: \\b/\\B corpus (ASCII; spans must agree)" {
    // The byte DFA evaluates `\b`/`\B` as ASCII word boundaries, so the differential corpus is
    // ASCII (where ASCII and Unicode word boundaries coincide). Every span must equal the Pike VM's.
    const patterns = [_][]const u8{
        "\\bcat\\b",   "\\bcat",       "cat\\b",      "\\Bcat\\B",  "\\Bcat",
        "cat\\B",      "\\b\\w+\\b",   "\\w+\\b",     "\\b\\w+",    "\\b\\d+\\b",
        "s\\b",        "\\bs",         "\\b[a-z]+\\b", "\\bword\\b", "a\\bb",
        "a\\Bb",       "\\b.\\b",      "\\B.\\B",      "(\\w+)\\b",  "\\bfoo\\b|\\bbar\\b",
        "\\d+\\b",     "\\b\\d+",      "[A-Z]\\w*\\b", "\\w\\b",     "\\B\\w\\B",
    };
    const inputs = [_][]const u8{
        "",             "cat",            "a cat!",        "category",
        "scattered",    "the cat sat",    "locator",       "concatenate",
        "  hello, world  ", "x",          "s",             "cats dogs",
        "a b c",        "word",           "a word.",       "foo bar baz",
        "123 456",      "_under_score_",  "CamelCase ok",  "ab",
        "a-b",          "one two_three",  "  spaced  ",    "!!!",
    };
    for (patterns) |p| try agreesWithPikeVM(testing.allocator, p, &inputs);
}

test "eager DFA \\b/\\B: direct spans (leading/trailing/mid, start/end of input)" {
    try expectFind("\\bcat\\b", "the cat sat", "cat");
    try expectNoMatch("\\bcat\\b", "category"); // no trailing boundary
    try expectNoMatch("\\bcat\\b", "scat"); // no leading boundary
    try expectFind("\\bcat", "scat cat", "cat"); // leading boundary at the 2nd
    try expectFind("cat\\b", "cat catalog", "cat"); // trailing boundary at the 1st
    try expectFind("\\b\\w+\\b", "  hello, world", "hello");
    try expectFind("\\w+\\b", "hello!", "hello");
    try expectFind("s\\b", "cats dogs", "s"); // word→non-word edge
    try expectFind("\\bx", "x", "x"); // \b at start of input
    try expectFind("x\\b", "x", "x"); // \b at end of input
    try expectFind("\\Bcat\\B", "locator", "cat"); // \B between word bytes
    try expectNoMatch("\\Bcat\\B", "a cat b"); // 'cat' is bounded → \B fails
    try expectFind("a\\Bb", "ab", "ab"); // \B between two word bytes holds
    try expectNoMatch("a\\bb", "ab"); // \b between two word bytes never holds
    try expectFind("\\bword\\b", "a word.", "word"); // punctuation is a boundary
}

test "eager DFA routes \\b to anchored restart (no reverse DFA), non-prone" {
    const gpa = testing.allocator;
    inline for (.{ "\\bcat\\b", "\\b\\w+\\b", "s\\b", "\\bword\\b" }) |pat| {
        var prog = try buildFrom(gpa, pat);
        defer freeProgram(gpa, &prog);
        try testing.expect(prog.has_word_boundary);
        try testing.expect(!prog.prone); // the word lookahead keeps these non-prone
        try testing.expect(!prog.rev_built); // \b never builds the reverse DFA
    }
}

test "eager DFA declines \\b combined with $ / (?m) (→ Pike VM, always correct)" {
    // `\b`/`\B` combined with `$` (text_end) or `(?m)` line anchors is declined by `supports`
    // (the lookahead interactions are deferred) — `auto` routes those to the linear Pike VM. The
    // combo decline is what keeps the eager-DFA `\b` machinery isolated; chained `\b\b` (rare /
    // simplified away) is guarded at build by `hasChainedBoundary` and exercised by the differential
    // corpus (`\b\B`/`\B\b` either decline or match exactly the Pike VM — both handled there).
    const gpa = testing.allocator;
    // Genuine combos: `\b` + text_end (`$`), and `\b` + a `(?m)` line anchor (which needs an actual
    // `^`/`$` under `(?m)` to exist as a node — `(?m)` alone is a no-op).
    inline for (.{ "\\bword\\b$", "\\bword$", "(?m)^\\bword", "(?m)\\bword$" }) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expect(!supports(h)); // declined → `auto` uses the Pike VM (Unicode-correct)
    }
}

test "\\b/\\B count is linear (non-prone anchored restart, no Θ(n²))" {
    const gpa = testing.allocator;
    // `\b\w+\b` over a long all-word input: each match-start scans only its word (bounded), so the
    // whole count is O(input). A quadratic regression makes this visibly hang. ASCII keeps it on
    // the eager DFA (the gate would route non-ASCII to the Pike VM).
    const N = 1 << 17; // 131072
    const buf = try gpa.alloc(u8, N);
    defer gpa.free(buf);
    @memset(buf, 'a');
    var i: usize = 7;
    while (i < N) : (i += 8) buf[i] = ' '; // words of length 7 separated by spaces
    var re = try Compiled.init("\\b\\w+\\b");
    defer re.deinit();
    const c = E.count(&re.program, &re.scratch, buf, .{});
    try testing.expect(c > 0);
}

test "\\b matches at COMPTIME via the eager DFA (ro_data, ASCII word context)" {
    const got = comptime blk: {
        @setEvalBranchQuota(20_000_000);
        const a = compile.compile("\\b[a-z]+\\b");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var sc = Scratch{};
        const input = "  the cat  ";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no \\b match at comptime");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("the", got);
}

test "REGRESSION: \\b\\w+\\b exact spans + count (reverting the determinizer breaks this)" {
    var re = try Compiled.init("\\b\\w+\\b");
    defer re.deinit();
    const input = "ab, cd_e! 12three";
    // words: "ab" [0,2), "cd_e" [4,8), "12three" [10,17)
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("ab", it.next().?.slice(input));
    try testing.expectEqualStrings("cd_e", it.next().?.slice(input));
    try testing.expectEqualStrings("12three", it.next().?.slice(input));
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, input, .{}));
}

test "trailing `$` is linear, not Θ(n²) (ReDoS immunity)" {
    const gpa = testing.allocator;
    // A begin-but-don't-complete `$` shape on a long input with no completer: under the old
    // anchored restart this was Θ(n²) — every start walks to end-of-input and fails, so a
    // 256 KiB input is ~7×10¹⁰ steps (seconds-to-minutes). The reverse-DFA-from-end path makes
    // it ONE O(input) backward pass (~µs), so this test completing near-instantly is itself the
    // signal; a quadratic regression makes it visibly hang. The deterministic guard that the
    // O(n) path is actually taken is the `end_anchored` flag test below. ASCII keeps builds cheap.
    const N = 1 << 18; // 262144
    const buf = try gpa.alloc(u8, N);
    defer gpa.free(buf);

    for ([_][]const u8{ "[a-z]+$", "[a-z]+@[a-z]+$", "[ab]*c$" }) |pat| {
        var re = try Compiled.init(pat);
        defer re.deinit();
        @memset(buf, 'a');
        buf[N - 1] = '!'; // no `[a-z]` at the end ⇒ no match — the old anchored-restart worst case
        try testing.expect(re.find(buf) == null);
        try testing.expect(!E.isMatch(&re.program, &re.scratch, buf, .{}));
        @memset(buf, 'a'); // all `[a-z]`: `[a-z]+$` matches the whole string; the `@`/`c` shapes do not
        _ = re.find(buf);
        _ = E.isMatch(&re.program, &re.scratch, buf, .{});
    }
}

test "trailing `$` matches at COMPTIME (reverse-from-end in const-eval)" {
    const found = comptime blk: {
        @setEvalBranchQuota(20_000_000);
        const a = compile.compile("[a-z]+$");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var sc = Scratch{};
        const m = E.find(&program, &sc, "  hello", .{}) orelse @compileError("no `$` match at comptime");
        break :blk m.slice("  hello");
    };
    try testing.expectEqualStrings("hello", found);

    const no_match = comptime blk: {
        @setEvalBranchQuota(20_000_000);
        const a = compile.compile("[a-z]+$");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var sc = Scratch{};
        break :blk E.find(&program, &sc, "hello!", .{}) == null; // ends with non-`[a-z]`
    };
    try testing.expect(no_match);
}

test "mixed `$` is declined; all-branch `$` (incl. `$`-in-every-branch alternations) is supported" {
    const gpa = testing.allocator;
    // Truly mixed: a branch that matches mid-input (`b`, `x`, `bar`) leaves the match end
    // un-pinned, so anchored restart would be Θ(n²) — the eager DFA declines it and `auto`
    // routes it to the linear Pike VM. `supports` and `buildAlloc` both reflect the decline.
    for ([_][]const u8{ "a$|b", "[ab]*c$|x", "(foo$|bar)" }) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expect(!supports(h));
        try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
    }
    // End pinned at input end (`anchored_end`): a plain trailing `$`, OR an alternation where
    // EVERY branch ends at `$` (`endsAnchored` now proves it). All stay on the eager DFA, linear
    // via the reverse-from-end pass.
    for ([_][]const u8{ "[ab]*c$", "foo$|bar$", "a$|b$" }) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expect(supports(h));
        var prog = try buildAlloc(gpa, h, .{});
        defer freeProgram(gpa, &prog);
        try testing.expect(prog.end_anchored);
    }
}

test "end_anchored / anchored_start flags route `$` patterns correctly" {
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, end_anchored: bool, anchored_start: bool };
    for ([_]Case{
        .{ .pat = "[a-z]+$", .end_anchored = true, .anchored_start = false }, // reverse-from-end
        .{ .pat = "[ab]*c$", .end_anchored = true, .anchored_start = false },
        .{ .pat = "^[a-z]+$", .end_anchored = false, .anchored_start = true }, // anchored-start path
        .{ .pat = "\\A\\d+$", .end_anchored = false, .anchored_start = true },
        .{ .pat = "[a-z]+", .end_anchored = false, .anchored_start = false }, // plain, anchored restart
    }) |c| {
        var prog = buildFrom(gpa, c.pat) catch |e| switch (e) {
            error.Unsupported => continue,
            else => return e,
        };
        defer freeProgram(gpa, &prog);
        try testing.expectEqual(c.end_anchored, prog.end_anchored);
        try testing.expectEqual(c.anchored_start, prog.anchored_start);
        if (prog.end_anchored) try testing.expect(prog.rev_built); // end_anchored ⟹ reverse table built
    }
}

// ── Minimization (Moore): the built DFA is minimal; reverting leaves mergeable states ──

/// Re-run partition refinement on a built `Program` and return the block count. If the program
/// is minimal this equals its state count; if minimization were reverted, a pattern with
/// determinization redundancy would have mergeable states and this returns fewer.
fn forwardBlocks(gpa: std.mem.Allocator, prog: *const Program) !u32 {
    const n: u32 = @intCast(prog.accept.len);
    const nc = prog.n_classes;
    const blk = try gpa.alloc(u32, n);
    defer gpa.free(blk);
    const nblk = try gpa.alloc(u32, n);
    defer gpa.free(nblk);
    const rep = try gpa.alloc(u32, n);
    defer gpa.free(rep);
    const ht = htCap(n);
    const sig = try gpa.alloc(u32, ht);
    defer gpa.free(sig);
    const has_t2 = prog.utrans.len > 0; // utrans is built (and consulted) only for prone programs
    var i: u32 = 0;
    while (i < n) : (i += 1)
        blk[i] = @as(u32, @intFromBool(prog.accept[i])) | (@as(u32, @intFromBool(prog.accept_eoi[i])) << 1);
    return minimizeDfa(prog.trans, prog.utrans, has_t2, n, nc, blk, nblk, rep, sig, ht - 1);
}

fn reverseBlocks(gpa: std.mem.Allocator, prog: *const Program) !u32 {
    const n: u32 = @intCast(prog.raccept.len);
    const nc = prog.n_classes;
    const blk = try gpa.alloc(u32, n);
    defer gpa.free(blk);
    const nblk = try gpa.alloc(u32, n);
    defer gpa.free(nblk);
    const rep = try gpa.alloc(u32, n);
    defer gpa.free(rep);
    const ht = htCap(n);
    const sig = try gpa.alloc(u32, ht);
    defer gpa.free(sig);
    var i: u32 = 0;
    while (i < n) : (i += 1) blk[i] = @intFromBool(prog.raccept[i]);
    return minimizeDfa(prog.rtrans, &.{}, false, n, nc, blk, nblk, rep, sig, ht - 1);
}

test "built eager DFA is minimal (Moore); a redundant pattern is genuinely reduced (revert-failing)" {
    const gpa = testing.allocator;
    // Post-condition of minimization: re-refining a built Program finds no mergeable states, so
    // the block count equals the state count. A pattern with determinization redundancy (`abc|dbc`
    // keeps the 'a'- and 'd'-tails distinct by pc-list even though they are language-equivalent)
    // would, if minimization were reverted, have mergeable states → fewer blocks than states →
    // these assertions fail. Covers plain, prone (utrans in the signature), and end_anchored
    // (reverse table) shapes, at the forward and reverse DFAs.
    const patterns = [_][]const u8{
        "abc|dbc",  "a(?:bc|dc)", "foo|boo|zoo", "\\w+",    "\\d+",
        "[a-z]+",   "\\p{L}+",    "\\w+@\\w+",   "[a-z]+$", "\\w+@\\w+$",
    };
    for (patterns) |p| {
        var prog = buildFrom(gpa, p) catch |e| switch (e) {
            error.Unsupported => continue,
            else => return e,
        };
        defer freeProgram(gpa, &prog);
        try testing.expectEqual(@as(u32, @intCast(prog.accept.len)), try forwardBlocks(gpa, &prog));
        if (prog.rev_built)
            try testing.expectEqual(@as(u32, @intCast(prog.raccept.len)), try reverseBlocks(gpa, &prog));
    }

    // `abc|dbc` is genuinely non-minimal before minimization (the determinizer interns by pc-list,
    // so the 'a'-tail and 'd'-tail stay separate): its minimal anchored DFA is 5 states
    // (start, {a|d}, {b}, accept, DEAD). This exact count is what makes the property test above
    // revert-failing — without minimization the build would keep the extra tail states.
    var prog = try buildFrom(gpa, "abc|dbc");
    defer freeProgram(gpa, &prog);
    try testing.expectEqual(@as(usize, 5), prog.accept.len);
}

// ── Line anchors (?m)^ / (?m)$ — anchored restart with line context ─────────────────

test "line anchors: (?m)^ / (?m)$ spans (anchored restart, \\n-isolated class)" {
    try expectFind("(?m)^foo", "x\nfoo", "foo"); // line start after a \n
    try expectNoMatch("(?m)^foo", "xfoo"); // not a line start
    try expectFind("(?m)^foo", "foo", "foo"); // line start at offset 0
    try expectFind("(?m)^\\w+", "  \nbar baz", "bar"); // first word on a line
    try expectFind("(?m)bar$", "bar\nx", "bar"); // line end just before a \n
    try expectFind("(?m)bar$", "x bar", "bar"); // line end at input end
    try expectNoMatch("(?m)bar$", "barx"); // neither before \n nor at end
    try expectFind("(?m)^abc$", "x\nabc\ny", "abc"); // a whole line
    try expectFind("(?m)^abc$", "abc", "abc");
    try expectNoMatch("(?m)^abc$", "abcd");
    try expectFind("(?m)^$", "a\n\nb", ""); // an empty line (between the two \n)
    try expectFind("(?m)^\\w+", "αβ\nγδ", "αβ"); // multibyte, byte-stepped
}

test "differential vs Pike VM: (?m) line-anchor corpus (spans must agree)" {
    const patterns = [_][]const u8{
        "(?m)^foo", "(?m)^\\w+", "(?m)^\\d+",       "(?m)^abc$", "(?m)foo$",
        "(?m)\\w$", "(?m)^.",    "(?m).$",          "(?m)^$",    "(?m)^[a-z]+",
        "(?m)^x$",  "(?m)^α",    "(?m)β$",          "(?m)^(foo|bar)", "\\A(?m)^x",
    };
    const inputs = [_][]const u8{
        "",           "abc",            "x\nfoo",   "foo\nbar\nbaz",
        "\nabc",      "abc\n",          "\n\n\n",   "a\n\nb",
        "hello\nfoo", "line1\nline2\n", "  \n  ",   "αβ\nγ",
        "foo",        "bar\n",          "x\ny\nz",  "no newlines here",
    };
    for (patterns) |p| try agreesWithPikeVM(testing.allocator, p, &inputs);
}

test "prone (?m) line patterns are declined (Unsupported) → auto routes them to the Pike VM" {
    const gpa = testing.allocator;
    // An unbounded run before the line anchor makes anchored restart Θ(n²); since the reverse-DFA
    // fix can't carry line context, the eager DFA declines these (and `auto` falls to the Pike VM).
    for ([_][]const u8{ "(?m)\\w+$", "(?m)[a-z]+$", "(?m).*^x" }) |pat| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const hh = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, hh);
        try testing.expect(supports(hh)); // the capability gate admits it…
        try testing.expectError(error.Unsupported, buildAlloc(gpa, hh, .{})); // …but the build declines (prone)
    }
}

test "non-prone (?m) line patterns are linear at scale (no Θ(n²))" {
    const gpa = testing.allocator;
    const N = 1 << 18; // 262144
    const buf = try gpa.alloc(u8, N);
    defer gpa.free(buf);
    for ([_][]const u8{ "(?m)^\\w+", "(?m)^foo", "(?m)foo$" }) |pat| {
        var re = try Compiled.init(pat);
        defer re.deinit();
        @memset(buf, 'a'); // one logical line, no \n
        _ = re.find(buf);
        _ = E.isMatch(&re.program, &re.scratch, buf, .{});
        var i: usize = 0; // many short lines: lots of line starts, still O(n) total
        while (i < N) : (i += 1) buf[i] = if (i % 8 == 7) '\n' else 'a';
        _ = re.find(buf);
        _ = E.isMatch(&re.program, &re.scratch, buf, .{});
    }
}

test "line anchors match at COMPTIME (anchored restart with line context in const-eval)" {
    // A small ASCII line pattern (a big Unicode class like `\w` would exhaust the comptime
    // allocator — the CTRE lane is for small, eager-friendly patterns).
    const got = comptime blk: {
        @setEvalBranchQuota(20_000_000);
        const a = compile.compile("(?m)^[a-z]+");
        const hh = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(hh, .{});
        var sc = Scratch{};
        const input = "  \nabc def"; // line start at offset 3 (after the \n); offset 0 is a space
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no (?m)^ match at comptime");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("abc", got);
}

test {
    testing.refAllDecls(@This());
}
