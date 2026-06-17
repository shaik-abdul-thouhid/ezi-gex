//! Lazy DFA backend — a caching subset-construction over the **byte** automaton.
//!
//! This is the byte substrate's (`engine/byte.zig`) throughput backend. It is **opt-in**
//! and **off by default**: a plain `compileRuntime`/`auto` does NOT build or use it;
//! you reach it via `compileRuntimeWith(backends.dfa, …)` or by setting
//! `Options.strategy.byte_engine = .enabled` (then `auto` uses it for the span scan).
//! Where `bytepike` *simulates* the byte Thompson NFA (every live thread stepped
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
//!     `[start, end)`; it does not fill capture slots. A standalone `Engine(dfa)` thus
//!     offers `isMatch`/`find`/`findAll`/`count`/`split`, but `captures`/`replaceAll`
//!     are a `@compileError` (use `auto` or `pikevm`). When you opt the DFA in through
//!     `auto`, `auto` uses the DFA only for the span ops (`isMatch`/`search`); capture
//!     ops (`searchCaptures`) run the code-point Pike VM as a **full, independent
//!     search** — there is no DFA-span → Pike-VM handoff (a possible future
//!     optimization), so captures are correct but not DFA-accelerated.
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
//! ## `isMatch` vs `find` (start location)
//!
//!   * **`isMatch` is one-pass, O(input).** Detection needs neither endpoint, so it runs
//!     the *unanchored* automaton (`ustep`/`utrans`): every byte re-seeds the start into
//!     the live state — the implicit `(?s:.)*?` prefix — and it accepts the instant the
//!     state is accepting. A single forward scan; no per-position restart.
//!   * **`find` is O(input) via the reverse DFA** — a forward pass + a reverse pass, no
//!     per-position restart. The **forward** pass (`findEndForward`) locates the leftmost
//!     match *end*: it re-seeds the start each byte (`ustep`) until the first match — so
//!     the earliest-starting thread wins by priority — then switches to the anchored
//!     `step` to extend that match greedily; the last accepting position is the
//!     leftmost-first end. The **reverse** DFA (`revFind`), anchored at that end and
//!     scanning *backward* over the reverse automaton (`ReverseAdj`), locates the leftmost
//!     *start*: the smallest position from which `[s, end)` is a full match. This kills
//!     the old anchored-restart **quadratic** worst case — a pattern that can *begin* but
//!     not *complete* at many positions (`\w+@\w+` on a long word run, `[ab]*c`) — which is
//!     now two linear passes. The reverse transitions are a plain subset construction (no
//!     priority or cut — the end is already fixed, so we only need *reachability* of the
//!     forward start), cached like the forward ones. A leading `\A`/`^` (`anchored_start`)
//!     still tries only offset 0; a pattern with an *interior* `text_start` (rare, not
//!     fully `anchored_start`) keeps anchored restart so the reverse transitions stay
//!     position-independent.
//!   * **Trailing `$` (`end_anchored`) is O(input) via one reverse pass.** When every match
//!     ends at input end the end is pinned, so `find`/`isMatch` skip the forward scan and run
//!     a single reverse-DFA pass from `input.len` (`revFindEnd`) — the same quadratic-immune
//!     shape the eager DFA uses for begin-but-don't-complete `$` inputs. (`isMatch` also uses
//!     this pass: a `$` program has no *mid-input* accepting state for the one-pass `utrans`
//!     scan to hit.)
//!
//! ## Prefilter (only via `auto`, and only for *leading*-literal patterns)
//!
//! The DFA backend itself has no prefilter — its restart loop is a bare `s += 1`. When
//! reached through `auto`, the same sound `Analysis` facts the NFA arm uses apply to the
//! DFA arm too: a `min_utf8_len` length gate, an `anchored_start` short-circuit, and a
//! **leading-literal** `memchr` start-skip (jump to each candidate byte, confirm with an
//! anchored DFA run). So opting the DFA in is never *slower* than the default on patterns
//! with a fixed leading literal. A leading-class pattern with **no** fixed literal is also
//! covered now: `auto` adds an **interior-anchor** skip (`[\w.+-]+@…` — jump to the rare `@`,
//! reverse-scan the lead class) and, for a digit/number-class lead (`\d+`, `\p{N}+`), a
//! **leading-class SIMD scan** (`classscan`); a small-class / `(?i)` lead (`(?i)the`) drives the
//! **case-variant Teddy** multi-prefix skip. The O(input) reverse-DFA `find` keeps the remaining
//! no-prefilter cases linear regardless.
//!
//! ## Invalid UTF-8 — dead-on-invalid, for free
//!
//! The byte lowering only ever emits `byte_range`s that cover well-formed UTF-8
//! (continuation bytes are always `[0x80, 0xBF]`, leads are tight, surrogates are
//! split out), so a malformed byte has **no transition out of any state** — it lands
//! in the dead state. The search resyncs past it (`find`'s restart advances the start;
//! `isMatch`'s unanchored scan re-seeds the start each byte), so a match never spans a
//! bad byte. No validity check in the hot loop, no decode.
//!
//! ## Capabilities & invariants (read this before opting directly into `backends.dfa`)
//!
//! `supports(hir)` is the capability gate. A pattern runs here iff it is byte-lowerable
//! (`byte.byteLowerable` — **no `\X`, no `\b`/`\B`**) and its zero-width assertions are a
//! supported subset:
//!
//!   * **`text_start`** (`\A`, non-multiline `^`) — depends only on the search position, so
//!     two start closures (true at offset 0, false past it) handle it with no
//!     position-dependent transition state.
//!   * **`text_end`** (`$`/`\z`) **when `anchored_end`** (every match ends at input end) —
//!     matched in O(input) by the reverse-DFA-from-end pass (`@stable-since v0.4.0`).
//!   * a single **leading `(?m)^`** (`line_start`) — matched in O(input) with no anchored
//!     restart: the forward scan re-seeds the pattern start ONLY at line starts (offset 0 or
//!     just after a `\n`, keyed on the `\n` byte class — `ustep`/`startL`), and the reverse
//!     `find` accepts a start only where the position is a line start (`revFind`, gated on
//!     `atLineStart`). A newline-crossing complement class (`[^"]*` spanning lines) is handled
//!     in a single pass — quadratic-immune, unlike the eager DFA's anchored-restart line
//!     support (which declines such *prone* patterns; `log_line` is the motivating case).
//!     `@stable-since v0.4.0`.
//!
//! **`\b`/`\B` word boundaries (Unicode)** run here too, via the **decode-hybrid**: consumption is
//! the cached byte-DFA walk, but at a state holding a pending boundary the position is resolved by
//! **decoding the adjacent code points** (`nfa.assertionHolds` — the Pike VM's own routine, so it is
//! Unicode-correct). Only code-point-boundary states pay a decode (sparse). This is the lazy DFA's
//! complement to the eager DFA's *ASCII-only* `\b`: `auto` routes a `\b` program's ASCII input to
//! the eager DFA (fastest) and its **non-ASCII** input here (correct Unicode boundaries) instead of
//! the Pike VM. Admitted only in isolation (a `\b` combined with `$` is declined). The reverse DFA
//! is never built for a `\b` program (a decoded boundary can't be woven into the reverse automaton),
//! so `find`/`isMatch` use the anchored-restart decode-hybrid.
//!
//! **Declined** (→ code-point engines, where they are correct **and linear**, so this is a
//! routing decision, not a limitation of the library):
//!
//!   * `\X` — a grapheme cluster is variable-width, not a byte (or single-code-point) property.
//!   * a **mixed** `$` (a `text_end` in only some alternation branches, e.g. `a$|b`) — the end
//!     is not pinned, so anchored restart would be Θ(n²); declined to stay quadratic-immune.
//!   * `(?m)$` (`line_end`) — position-dependent on the byte *ahead*, and an interior or repeated
//!     `(?m)^`, or `(?m)^…$` — only a single leading `(?m)^` (above) is admitted.
//!   * `\b` **combined with** `$` — the boundary-vs-reverse-end interaction is deferred to the Pike VM.
//!
//! **Invariants this backend upholds for every pattern `supports` accepts:** matching is
//! **O(input)** (no quadratic path — a hard contract), **leftmost-first** (byte-identical
//! spans to the Pike VM, proven in `conformance.zig`), **span-only** (no captures), and
//! **dead-on-invalid** UTF-8. If you opt directly into `backends.dfa`, a pattern it declines
//! is `error.Unsupported` at build — there is no silent fallback. Through **`auto`** the
//! decline is invisible: `auto` routes the pattern to a backend that handles it, so `auto`
//! is correct by construction for every pattern.

const std = @import("std");

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const byte = @import("engine_base").byte;
const nfa = @import("engine_base").nfa; // for the Unicode-correct `\b`/`\B` decode at match time (assertionHolds)

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
    /// True when every match must begin at offset 0 (a leading `\A` / non-multiline
    /// `^` — `analysis.anchored_start`). The search then tries only `s == 0`, where the
    /// anchored restart has no overhead at all.
    ///
    /// @stable-since: v0.3.0
    anchored_start: bool,
    /// True when the byte program contains a `text_start` assertion (`\A`/`^`) yet is not
    /// fully `anchored_start` (e.g. `^abc|def`). Such a pattern keeps `find` on the
    /// anchored-restart scan (which evaluates `text_start` per start position), so the
    /// reverse-DFA `find` — whose cached reverse transitions must be **position-
    /// independent** — excludes it. The vast majority of patterns have no assertion and
    /// take the O(n) reverse-DFA path.
    ///
    /// @stable-since: v0.3.0
    has_text_start: bool,
    /// Reverse adjacency of the byte automaton, driving the reverse-DFA `find` (forward
    /// scan locates the leftmost match **end** in one pass; the reverse DFA, anchored at
    /// that end, locates the leftmost **start** — replacing the Θ(n²) anchored restart).
    /// `built == false` (and the slices empty) for `has_text_start` programs. For a
    /// `text_end` (`$`/`\z`) program the trailing `$` is woven in as a **passable reverse
    /// epsilon** (`buildReverse`), so the reverse start represents "at end-of-input, `$`
    /// satisfied" and one backward pass from `input.len` (`revFindEnd`) finds the leftmost
    /// start in O(input).
    ///
    /// @stable-since: v0.3.0
    rev: ReverseAdj,
    /// True when the byte program carries a `text_end` (`$`/`\z`) assertion. Such a program
    /// is always `anchored_end` (`supports` declines a mixed `$`), so the match end is pinned
    /// at `input.len`. Used to route `find`/`isMatch` to the reverse-DFA-from-end pass.
    ///
    /// @stable-since: v0.4.0
    has_text_end: bool,
    /// True when every match must end at end-of-input (a trailing `$`/`\z`, `anchored_end`)
    /// and the pattern is not `anchored_start` (`^…$` tries only offset 0 instead). The match
    /// end is then pinned to `input.len`, so a single reverse-DFA pass from there
    /// (`revFindEnd`) is the whole search — O(input), the same fix the eager DFA uses for
    /// begin-but-don't-complete `$` shapes (`[ab]*c$`, `\w+@\w+$`). Implies `rev.built`.
    ///
    /// @stable-since: v0.4.0
    end_anchored: bool,
    /// `reaches_end[pc]` — does `pc` reach `match` via epsilon edges only, with `text_end`
    /// (`$`/`\z`) **passable** (the at-end-of-input view)? Drives `accept_eoi`: a closure that
    /// parks on a `text_end` pc whose `reaches_end` is true makes its DFA state accepting *at
    /// end of input*. Empty (`&.{}`) for a `$`-free program (the closure never indexes it).
    ///
    /// @stable-since: v0.4.0
    reaches_end: []const bool,
    /// True when the byte program carries a `\b`/`\B` word boundary. Such a program runs on the
    /// **decode-hybrid** path: anchored restart where consumption is the cached byte-DFA walk, but
    /// at a state holding a pending `\b`/`\B` (`Scratch.state_has_wb`) the boundary is resolved by
    /// **decoding the adjacent code points** (`nfa.assertionHolds`) — a correct **Unicode** word
    /// boundary, the lazy DFA's complement to the eager DFA's ASCII-only one. The reverse DFA is
    /// never built for such a program (it can't be reversed through a decoded boundary), so
    /// `rev.built` is false and `find`/`isMatch` use anchored restart.
    ///
    /// @stable-since: v0.4.0
    has_word_boundary: bool,
    /// True when the byte program's sole special anchor is a single **leading** `(?m)^`
    /// (`line_start`). `supports` admits exactly this shape (no `$`/`\A`/`\b`/`line_end`,
    /// `line_anchored_start`). It runs in **O(input)**, no anchored restart: the forward scan
    /// re-seeds the pattern start **only at line starts** (after a `\n`, or offset 0 — see
    /// `ustep`/`startL`), and the reverse `find` accepts a start only where the position is a
    /// line start (`revFind`, gated on `atLineStart`). Position-dependence is confined to the
    /// re-seed point and the reverse accept; the cached transitions stay position-independent.
    ///
    /// @stable-since: v0.4.0
    has_line_start: bool = false,
    /// Byte class of `\n` (the line separator), valid only when `has_line_start`. `byte.byteClasses`
    /// isolates `\n` into its own class when line anchors are present, so a transition consuming it
    /// (`class == nl_class`) is exactly "the next position is a line start" — the re-seed trigger.
    ///
    /// @stable-since: v0.4.0
    nl_class: u32 = 0,
};

/// Whether this HIR can run on the lazy DFA. The capability gate (read this if you opt
/// directly into `backends.dfa` rather than `auto`):
///
///   * **Required:** byte-lowerable — no `\X` (a grapheme cluster is variable-width). `\b`/`\B`
///     ARE accepted (in isolation): they are Unicode word boundaries resolved at match time by the
///     decode-hybrid (`runAnchoredWb`/`resolveWb`), the lazy DFA's complement to the eager DFA's
///     ASCII-only `\b`. `\X` still stays on the code-point engines.
///   * **Allowed assertions:** `text_start` (`\A`, non-multiline `^`) — evaluable purely from
///     the search position (true only at offset 0), handled by two start closures with no
///     position-dependent transition state; and **`text_end` (`$`/`\z`) when the pattern is
///     `anchored_end`** (every match ends at input end), matched in O(input) by the
///     reverse-DFA-from-end pass (`@stable-since v0.4.0`).
///   * **Declined (→ code-point engines, correct + linear there):** a **mixed** `$` (a
///     `text_end` in only some alternation branches, e.g. `a$|b`) — its end is not pinned, so
///     anchored restart would be Θ(n²); and `(?m)` line anchors (`line_start`/`line_end`),
///     which are position-dependent on the adjacent byte.
///
/// **Invariant:** every pattern this returns `true` for matches in **O(input)** (no
/// quadratic path) and **leftmost-first** (identical spans to every other backend). A pattern
/// it declines is not wrong — it runs on another engine. `auto` consults this to route, so
/// through `auto` the decline is invisible.
///
/// @stable-since: v0.3.0
pub fn supports(h: hir.Hir) bool {
    if (!byte.byteLowerable(h)) return false; // excludes \X (grapheme)
    var has_text_start = false;
    var has_text_end = false;
    var has_word = false;
    var line_start_count: u32 = 0;
    var has_line_end = false;
    for (h.nodes) |n| {
        if (n.tag == .anchor) switch (n.data.anchor.kind) {
            .text_start => has_text_start = true,
            .text_end => has_text_end = true,
            .word_boundary, .not_word_boundary => has_word = true, // Unicode \b/\B (decode-hybrid, below)
            .line_start => line_start_count += 1,
            .line_end => has_line_end = true, // (?m)$ → code-point engines (position-dependent end)
        };
    }
    // `(?m)^` (`line_start`): admitted ONLY as a single LEADING anchor (`line_anchored_start`)
    // with nothing else special. Handled in O(input) by line-gated forward re-seeding +
    // a reverse line-start accept check (no anchored restart, so quadratic-immune even for a
    // `[^"]*`-across-newlines pattern like `log_line`). Any other shape — `(?m)$`, an interior
    // or repeated `^`, or a mix with `\A`/`$`/`\b` — stays on the code-point engines.
    if (line_start_count > 0 or has_line_end) {
        return line_start_count == 1 and !has_line_end and !has_word and
            !has_text_end and !has_text_start and h.analysis.line_anchored_start;
    }
    // `text_end` is linear here only when the match end is pinned to input end
    // (`anchored_end`), matched by the reverse-DFA-from-end pass. A mixed `$` would fall to the
    // Θ(n²) anchored restart, so decline it; `auto` then routes it to the linear Pike VM.
    if (has_text_end and !h.analysis.anchored_end) return false;
    // `\b`/`\B` are evaluated as **Unicode** word boundaries by decoding the adjacent code points
    // at match time (the decode-hybrid anchored-restart path — consumption stays DFA-cached, only
    // boundary positions decode). Admitted only in ISOLATION: combined with `$` the boundary-vs-
    // reverse-end interaction is deferred to the Pike VM. (Linearity for `\b` programs assumes
    // non-prone, which `auto` guarantees — it builds this arm only for an eager-DFA-accepted, i.e.
    // non-prone, pattern; a direct `backends.dfa` user on a prone `\b` like `\b.*x` should prefer
    // `auto`.)
    if (has_word and has_text_end) return false;
    // A `\b`/`\B` inside an alternation needs leftmost-FIRST branch priority across
    // the assertion, which the leftmost-longest DFA cannot encode (`\b|.` on `"b"`
    // must be the empty match `{0,0}`, not `{0,1}`). Decline to the Pike VM. See
    // `hir.Analysis.word_boundary_in_alternation`.
    if (h.analysis.word_boundary_in_alternation) return false;
    // A repetition over a nullable alternation (`(?:|.)+`) has the same leftmost-
    // first-vs-longest mismatch in the empty-loop direction — decline to the Pike
    // VM. See `hir.Analysis.nullable_alternation_in_repetition`.
    if (h.analysis.nullable_alternation_in_repetition) return false;
    // A non-trailing `text_end` (`$a`, `\z.\z`) wrongly matches via the reverse-end
    // path. Decline. See `hir.Analysis.interior_text_end`.
    if (h.analysis.interior_text_end) return false;
    // A `\b`/`\B` adjacent to a nullable alternation (`\B(?:|.*)`). Decline. See
    // `hir.Analysis.word_boundary_with_nullable_alternation`.
    if (h.analysis.word_boundary_with_nullable_alternation) return false;
    // A `\b`/`\B` with a lazy repetition (`a*?\b`, `[^a]+?\B *`). Decline. See
    // `hir.Analysis.word_boundary_with_lazy_repetition`.
    if (h.analysis.word_boundary_with_lazy_repetition) return false;
    // A `\b`/`\B` with two adjacent consuming repetitions (`\n+(\n.*){0,2}\b`): their
    // ambiguous split + the boundary defeats leftmost-first on the DFA. Decline. See
    // `hir.Analysis.word_boundary_with_adjacent_repetition`.
    if (h.analysis.word_boundary_with_adjacent_repetition) return false;
    return true;
}

/// Reverse adjacency of the byte automaton: the predecessors of each pc, in CSR form, so
/// the reverse DFA can walk the automaton **backward** from a match end to the match
/// start. Built for `!has_text_start` programs (the reverse-DFA `find` path): the
/// assertion-free case (every epsilon edge a plain `split`/`jmp`/`save`) and the
/// **`text_end`** case, where a trailing `$`/`\z` is recorded as a passable reverse epsilon
/// (its forward edge `i → i+1` becomes a reverse predecessor). A position-dependent
/// `text_start` is *not* reverse-cacheable, so `has_text_start` programs keep anchored
/// restart and build no reverse adjacency.
///
/// @stable-since: v0.3.0
pub const ReverseAdj = struct {
    /// CSR reverse-epsilon: `eps[eps_off[pc] .. eps_off[pc+1]]` are the forward-epsilon
    /// **predecessors** of `pc` (every `u` with a forward `u →ε pc`: a `split` to `pc`, a
    /// `jmp` to `pc`, or a `save` at `pc-1`).
    eps_off: []const u32,
    eps: []const u32,
    /// CSR reverse-byte: `[rb_off[pc] .. rb_off[pc+1]]` are the `byte_range`s whose
    /// `next == pc` — consuming a byte in `[rb_lo, rb_hi]` *backward* goes from `pc` to
    /// `rb_src` (the byte_range's own pc).
    rb_off: []const u32,
    rb_lo: []const u8,
    rb_hi: []const u8,
    rb_src: []const u32,
    /// `byte_target[pc]` — is `pc` the `next` of some `byte_range` (i.e. has a reverse-byte
    /// out-edge)? Only such pcs are reverse-DFA state members (the reverse analogue of a
    /// forward state's `byte_range` pcs).
    byte_target: []const bool,
    /// The forward `match` pcs — the reverse DFA's start seeds (it begins "at the match"
    /// and walks back to `pc 0`, the forward start = the reverse accept).
    match_seed: []const u32,
    /// Whether this adjacency was actually built (false + empty slices for a
    /// `has_text_start` program, which uses anchored restart instead).
    built: bool,
};

const empty_rev = ReverseAdj{
    .eps_off = &.{},  .eps = &.{},     .rb_off = &.{},      .rb_lo = &.{}, .rb_hi = &.{},
    .rb_src = &.{},   .byte_target = &.{}, .match_seed = &.{}, .built = false,
};

/// In-place exclusive prefix sum: each slot becomes the sum of all earlier slots, so an
/// array of per-pc in-edge **counts** becomes the per-pc CSR **start offsets** (and the
/// final slot the total).
fn prefixSum(arr: []u32) void {
    var acc: u32 = 0;
    for (arr) |*v| {
        const c = v.*;
        v.* = acc;
        acc += c;
    }
}

/// Build the reverse adjacency from a `!has_text_start` byte program (two passes: count
/// in-edges per pc, prefix-sum to offsets, fill). A trailing `text_end` (`$`/`\z`) is a
/// passable forward epsilon (`i → i+1`), so it gets a reverse predecessor exactly like a
/// `jmp` — that is what lets `revClosure(match)` walk back through the `$` into the pre-`$`
/// states. No other assertion kind reaches here (`text_start` programs build no reverse
/// adjacency; `\b`/line anchors are declined by `supports`).
fn buildReverse(gpa: std.mem.Allocator, bp: byte.Program) Err!ReverseAdj {
    const n: u32 = @intCast(bp.insts.len);
    const eps_off = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(eps_off);
    const rb_off = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(rb_off);
    const byte_target = try gpa.alloc(bool, n);
    errdefer gpa.free(byte_target);
    @memset(eps_off, 0);
    @memset(rb_off, 0);
    @memset(byte_target, false);

    var n_match: u32 = 0;
    for (bp.insts, 0..) |inst, i| switch (inst) {
        .byte_range => |r| {
            rb_off[r.next] += 1;
            byte_target[r.next] = true;
        },
        .split => |s| {
            eps_off[s.a] += 1;
            eps_off[s.b] += 1;
        },
        .jmp => |t| eps_off[t] += 1,
        .save => eps_off[i + 1] += 1,
        // `text_end` ($/\z) and a leading `line_start` ((?m)^) are passable epsilons (forward edge
        // i → i+1): record the reverse predecessor so `revClosure(match)` walks back through them.
        // `line_start` additionally gates the reverse ACCEPT on the position being a line start
        // (handled in `revClosure`/`revFind`); only these two assertion kinds reach here.
        .assertion => |k| if (k == .text_end or k == .line_start) {
            eps_off[i + 1] += 1;
        },
        .match => n_match += 1,
    };
    prefixSum(eps_off);
    prefixSum(rb_off);

    const eps = try gpa.alloc(u32, eps_off[n]);
    errdefer gpa.free(eps);
    const rb_lo = try gpa.alloc(u8, rb_off[n]);
    errdefer gpa.free(rb_lo);
    const rb_hi = try gpa.alloc(u8, rb_off[n]);
    errdefer gpa.free(rb_hi);
    const rb_src = try gpa.alloc(u32, rb_off[n]);
    errdefer gpa.free(rb_src);
    const match_seed = try gpa.alloc(u32, n_match);
    errdefer gpa.free(match_seed);

    const ec = try gpa.alloc(u32, n); // per-pc fill cursor (epsilon)
    defer gpa.free(ec);
    @memcpy(ec, eps_off[0..n]);
    const rc = try gpa.alloc(u32, n); // per-pc fill cursor (byte)
    defer gpa.free(rc);
    @memcpy(rc, rb_off[0..n]);

    var mi: u32 = 0;
    for (bp.insts, 0..) |inst, i| {
        const pc: u32 = @intCast(i);
        switch (inst) {
            .byte_range => |r| {
                const k = rc[r.next];
                rc[r.next] += 1;
                rb_lo[k] = r.range.lo;
                rb_hi[k] = r.range.hi;
                rb_src[k] = pc;
            },
            .split => |s| {
                eps[ec[s.a]] = pc;
                ec[s.a] += 1;
                eps[ec[s.b]] = pc;
                ec[s.b] += 1;
            },
            .jmp => |t| {
                eps[ec[t]] = pc;
                ec[t] += 1;
            },
            .save => {
                eps[ec[i + 1]] = pc;
                ec[i + 1] += 1;
            },
            .assertion => |k| if (k == .text_end or k == .line_start) { // passable epsilon — see the count pass
                eps[ec[i + 1]] = pc;
                ec[i + 1] += 1;
            },
            .match => {
                match_seed[mi] = pc;
                mi += 1;
            },
        }
    }
    return .{
        .eps_off = eps_off,
        .eps = eps,
        .rb_off = rb_off,
        .rb_lo = rb_lo,
        .rb_hi = rb_hi,
        .rb_src = rb_src,
        .byte_target = byte_target,
        .match_seed = match_seed,
        .built = true,
    };
}

fn freeReverse(gpa: std.mem.Allocator, rev: *ReverseAdj) void {
    if (!rev.built) return;
    gpa.free(rev.eps_off);
    gpa.free(rev.eps);
    gpa.free(rev.rb_off);
    gpa.free(rev.rb_lo);
    gpa.free(rev.rb_hi);
    gpa.free(rev.rb_src);
    gpa.free(rev.byte_target);
    gpa.free(rev.match_seed);
}

/// `out[pc]` ← does `pc` reach `match` via epsilon edges only, with `text_end` (`$`/`\z`)
/// **passable** (the end-of-input view)? Drives `accept_eoi`: a closure that parks on a
/// `text_end` pc whose `reaches_end` is true makes its DFA state accepting at end of input.
/// `text_start` is *not* passable here (it needs offset 0, which the at-end view lacks; the
/// empty-input `^…$` case is covered by the start closures). A monotone backward fixpoint;
/// all-false for a `$`-free program. Mirrors `edfa.computeEndReaches` (kept local to avoid a
/// `dfa`↔`edfa` import cycle).
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

/// Allocate + compute `reaches_end` for a `text_end` program (caller owns the result).
fn buildEndReaches(gpa: std.mem.Allocator, bp: byte.Program) Err![]bool {
    const out = try gpa.alloc(bool, bp.insts.len);
    computeEndReaches(bp.insts, out);
    return out;
}

/// Compile a HIR into a heap-allocated DFA `Program` (free with `freeProgram`).
/// A pattern this backend cannot run (`\X`/`\b`/`$`/line anchors) is rejected with
/// `error.Unsupported`; `auto` then keeps it on the code-point engines.
///
/// @stable-since: v0.3.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    if (!supports(h)) return error.Unsupported;
    var bp = try byte.buildAlloc(gpa, h);
    errdefer byte.freeProgram(gpa, &bp);
    // Defensive: only `text_start` (offset 0) and `text_end` (end of input) assertions are
    // DFA-evaluable here; `supports` already excludes the rest, but double-check the lowered
    // program and note which are present — `text_start` forces anchored restart; `text_end`
    // takes the reverse-from-end path (and `supports` guarantees it is `anchored_end`).
    var has_text_start = false;
    var has_text_end = false;
    var has_word = false;
    var has_line_start = false;
    for (bp.insts) |inst| switch (inst) {
        .assertion => |k| switch (k) {
            .text_start => has_text_start = true,
            .text_end => has_text_end = true,
            .word_boundary, .not_word_boundary => has_word = true, // Unicode \b/\B (decode-hybrid)
            .line_start => has_line_start = true, // (?m)^ leading anchor (line-gated re-seed)
            else => return error.Unsupported, // line_end (declined by supports)
        },
        else => {},
    };
    const classes = byte.byteClasses(&bp);
    var class_rep: [256]u8 = @splat(0);
    var b: u16 = 0;
    while (b < 256) : (b += 1) class_rep[classes.map[b]] = @intCast(b);
    // Reverse adjacency for the O(n) reverse-DFA `find` — built for `!has_text_start` programs: the
    // assertion-free case (forward-end + reverse-start two-pass) and the `text_end` case
    // (reverse-from-end, trailing `$` woven in as a passable reverse epsilon). `has_text_start`
    // patterns keep anchored restart (reverse transitions must stay position-independent); a `\b`
    // program likewise keeps anchored restart (a decoded boundary cannot be woven into the reverse
    // automaton — `find`/`isMatch` run the decode-hybrid `runAnchoredWb`).
    var rev = if (has_text_start or has_word) empty_rev else try buildReverse(gpa, bp);
    // Byte class of `\n` — the re-seed trigger for the `(?m)^` line-gated forward scan. `\n` is
    // isolated into its own class by `byteClasses` whenever a line anchor is present.
    const nl_class: u32 = if (has_line_start) classes.map['\n'] else 0;
    errdefer freeReverse(gpa, &rev);
    // `reaches_end` drives `accept_eoi`; only a `text_end` program needs it (empty otherwise,
    // and the closure never indexes it for a `$`-free program).
    const reaches_end: []const bool = if (has_text_end) try buildEndReaches(gpa, bp) else &.{};
    errdefer if (has_text_end) gpa.free(reaches_end);
    // A `text_end` program is `anchored_end` (mixed `$` was declined by `supports`); with no
    // leading anchor (`!has_text_start`) the end is pinned at `input.len`, so `find`/`isMatch`
    // take the single-pass reverse-from-end path.
    const end_anchored = has_text_end and h.analysis.anchored_end and !has_text_start;
    return .{
        .byte_prog = bp,
        .classes = classes,
        .class_rep = class_rep,
        .anchored_start = h.analysis.anchored_start,
        .has_text_start = has_text_start,
        .rev = rev,
        .has_text_end = has_text_end,
        .end_anchored = end_anchored,
        .reaches_end = reaches_end,
        .has_word_boundary = has_word,
        .has_line_start = has_line_start,
        .nl_class = nl_class,
    };
}

/// Release a `Program` built with `buildAlloc`.
///
/// @stable-since: v0.3.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    freeReverse(gpa, &program.rev);
    if (program.has_text_end) gpa.free(program.reaches_end);
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

/// How many mid-search cache flushes are tolerated before `on_full = .give_up` raises
/// the `gave_up` flag (a routing hint for `auto`; results stay correct regardless).
const MAX_FLUSHES: u32 = 4;

/// Whether byte offset `sp` is a **line start**: offset 0, or immediately after a `\n`. The
/// position predicate `(?m)^` (`line_start`) tests; used to gate the forward re-seed's start
/// state and the reverse `find` accept.
inline fn atLineStart(input: []const u8, sp: usize) bool {
    return sp == 0 or input[sp - 1] == '\n';
}

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
    /// `state_match_eoi.items[id]` — is state `id` accepting **at end of input**
    /// (`accept_eoi`): `state_match` OR it parks on a pending `text_end` (`$`/`\z`) whose
    /// continuation reaches `match`. Equal to `state_match` for a `$`-free program, so the
    /// extra end-of-input check `runAnchored` does is a no-op there.
    ///
    /// @stable-since: v0.4.0
    state_match_eoi: std.ArrayListUnmanaged(bool) = .empty,
    /// `state_has_wb.items[id]` — does state `id` hold a pending `\b`/`\B` member? Such a state is
    /// **boundary-resolved at match time** (`resolveWb`) by decoding the adjacent code points, rather
    /// than via a cached transition. All-false for a non-`\b` program (the decode path is dormant).
    ///
    /// @stable-since: v0.4.0
    state_has_wb: std.ArrayListUnmanaged(bool) = .empty,
    /// Memoized boundary resolution for the decode-hybrid: `wb_cache.items[id*2 + b]` is the
    /// boundary-free effective state `resolveWb` produces for raw `\b` state `id` when the word
    /// boundary `b` (= `\b` holds at the position; `\B` is its negation) is the resolution outcome.
    /// `UNKNOWN` until first computed; the resolved state depends ONLY on that one bit (every parked
    /// boundary fires as a function of it), so two entries per state suffice — turning the per-byte
    /// boundary work from a closure into an O(1) lookup (+ one decode for the bit). Only the
    /// position-independent `pos > 0` case is cached (`pos == 0` also depends on `text_start`).
    /// All-empty for a non-`\b` program.
    ///
    /// @stable-since: v0.4.0
    wb_cache: std.ArrayListUnmanaged(u32) = .empty,
    /// Flat `id * nclass + class` **anchored** transition table; `UNKNOWN` until first
    /// computed. Used by `search` (anchored restart from each start).
    trans: std.ArrayListUnmanaged(u32) = .empty,
    /// Flat `id * nclass + class` **unanchored** transition table — each edge re-seeds
    /// the start (`startN`) into the successors, giving the implicit `.*?`-prefix
    /// automaton that drives one-pass `isMatch`.
    utrans: std.ArrayListUnmanaged(u32) = .empty,
    /// Start closure with `text_start` TRUE (used at offset 0).
    start0: u32 = DEAD,
    /// Start closure with `text_start` FALSE (used at offset > 0, and as the
    /// unanchored re-seed). Equals `start0` for patterns with no `\A`/`^`.
    startN: u32 = DEAD,
    /// Start closure with `line_start` TRUE (`text_start` false) — the re-seed at a line start
    /// for a `(?m)^` program (offset 0 uses `start0`, which is also at a line start; positions
    /// just after a `\n` use this). `DEAD` for a non-line program.
    ///
    /// @stable-since: v0.4.0
    startL: u32 = DEAD,
    start_ready: bool = false,
    /// Approximate live cache footprint in bytes (drives `ScratchOptions` eviction).
    cache_bytes: usize = 0,
    /// Raised when the cache was flushed `MAX_FLUSHES` times within one search and
    /// `on_full == .give_up`: a hint that the DFA is thrashing on this program. A
    /// wrapper (e.g. `auto`) may then stop routing to the DFA. Results stay correct.
    ///
    /// @stable-since: v0.3.0
    gave_up: bool = false,
    opts: ScratchOptions,

    // ── reusable per-closure work buffers (no allocation during a closure) ──
    seen: []u32, // generation-stamped pc dedup
    seen_gen: u32 = 0,
    stack: []u32, // closure DFS stack
    work: []u32, // the closure result (canonical pc list being built)
    work_len: usize = 0,
    work_match: bool = false,
    work_match_eoi: bool = false, // a pending `text_end` in this closure reaches match at end
    work_has_wb: bool = false, // this closure parked a `\b`/`\B` member (resolved at match time by decode)
    work_match_line: bool = false, // revClosure reached pc 0 of a `(?m)^` program → accept IF at a line start
    seeds: []u32, // successor pcs feeding the next closure

    // ── reverse-DFA cache (the O(n) reverse `find`; set-based, no priority/cut) ──
    // Reverse states are sets of forward pcs (sorted, so set-equal states intern equal),
    // independent of the forward cache (they hold program pcs, not forward state ids), so
    // a forward eviction never invalidates them. The work buffers above are reused (a
    // `find` runs the forward scan to completion, then the reverse — never interleaved).
    r_intern: InternMap = .empty,
    r_states: std.ArrayListUnmanaged([]const u32) = .empty,
    r_accept: std.ArrayListUnmanaged(bool) = .empty, // does the state contain pc 0 (reverse accept)?
    r_accept_line: std.ArrayListUnmanaged(bool) = .empty, // (?m)^: accepts ONLY where the position is a line start
    r_trans: std.ArrayListUnmanaged(u32) = .empty, // r_state × nclass, UNKNOWN until computed
    r_start: u32 = DEAD,
    r_start_ready: bool = false,

    /// Construct a cache-backed `Scratch` with the default cache budget
    /// (`ScratchOptions{}`).
    ///
    /// @stable-since: v0.3.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) Err!Scratch {
        return initOptions(gpa, program, .{});
    }

    /// Construct a cache-backed `Scratch` with an explicit cache budget. When the
    /// memo's footprint exceeds `opts.max_bytes` it is flushed **mid-search** (the live
    /// state is preserved across the flush), so `max_bytes` actually bounds memory
    /// within one search — not just between searches. `opts.on_full`:
    ///   * `.reset` (default) — flush and keep matching with the DFA, indefinitely.
    ///   * `.give_up` — flush, but after `MAX_FLUSHES` flushes in one search raise
    ///     `gave_up`; a wrapper (`auto`) then stops routing to the DFA for this program.
    ///     Standalone, `.give_up` matches `.reset` behaviour but sets the flag.
    ///   * `.grow` — never flush; grow until the allocator is exhausted (then `@panic`).
    /// Every choice is results-invariant — the cache is a pure optimization.
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
        const seeds = try gpa.alloc(u32, 2 * n + 2); // `ustep` unions two pc-lists
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
        errdefer sc.state_match_eoi.deinit(gpa);
        errdefer sc.state_has_wb.deinit(gpa);
        errdefer sc.wb_cache.deinit(gpa);
        errdefer sc.trans.deinit(gpa);
        errdefer sc.utrans.deinit(gpa);

        // Intern the empty set as the DEAD sink (state id 0).
        sc.work_len = 0;
        _ = try sc.internState(false, false);
        return sc;
    }

    /// @stable-since: v0.3.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        for (self.states.items) |o| gpa.free(o);
        self.states.deinit(gpa);
        self.state_match.deinit(gpa);
        self.state_match_eoi.deinit(gpa);
        self.state_has_wb.deinit(gpa);
        self.wb_cache.deinit(gpa);
        self.trans.deinit(gpa);
        self.utrans.deinit(gpa);
        self.intern.deinit(gpa);
        for (self.r_states.items) |o| gpa.free(o);
        self.r_states.deinit(gpa);
        self.r_accept.deinit(gpa);
        self.r_accept_line.deinit(gpa);
        self.r_trans.deinit(gpa);
        self.r_intern.deinit(gpa);
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

    /// Drop the entire memo and re-seed the DEAD sink. Invalidates every state id, so a
    /// mid-search caller must preserve the live state across it (see `flushPreserving`);
    /// at a search boundary nothing needs preserving. The cache is a pure optimization,
    /// so this is always results-invariant. Does NOT touch the `work` buffer beyond
    /// `work[0..0]`, so a caller may stage a pc-list in `work` across it.
    fn clearCache(self: *Scratch) void {
        for (self.states.items) |o| self.gpa.free(o);
        self.states.deinit(self.gpa);
        self.states = .empty;
        self.state_match.deinit(self.gpa);
        self.state_match = .empty;
        self.state_match_eoi.deinit(self.gpa);
        self.state_match_eoi = .empty;
        self.state_has_wb.deinit(self.gpa);
        self.state_has_wb = .empty;
        self.wb_cache.deinit(self.gpa);
        self.wb_cache = .empty;
        self.trans.deinit(self.gpa);
        self.trans = .empty;
        self.utrans.deinit(self.gpa);
        self.utrans = .empty;
        self.intern.deinit(self.gpa);
        self.intern = .empty;
        self.cache_bytes = 0;
        self.start_ready = false;
        self.work_len = 0;
        _ = self.internState(false, false) catch @panic(OOM_PANIC); // re-seed DEAD = state 0
    }

    /// Evict the cache if it has outgrown its budget, at a search boundary (no live
    /// state to preserve). Mid-search enforcement is `evictIfNeeded`/`flushPreserving`.
    fn maybeEvict(self: *Scratch) void {
        if (self.opts.on_full == .grow) return;
        if (self.cache_bytes <= self.opts.max_bytes) return;
        self.clearCache();
    }

    /// Flush the cache mid-search, preserving the live `state_id`: copy its pc list into
    /// `work` (which `clearCache` leaves intact), clear, re-intern it (and the start
    /// states), and return its new id. Bounds memory *within* a single search — the
    /// scenario `ScratchOptions.max_bytes` exists for. After `MAX_FLUSHES` flushes in
    /// one search, `.give_up` raises `gave_up`.
    fn flushPreserving(self: *Scratch, program: *const Program, state_id: u32, flushes: *u32) Err!u32 {
        const pcs = self.states.items[state_id];
        const plen = pcs.len;
        @memcpy(self.work[0..plen], pcs); // stage across the clear (clearCache spares `work`)
        const is_match = self.state_match.items[state_id];
        const is_match_eoi = self.state_match_eoi.items[state_id];
        const has_wb = self.state_has_wb.items[state_id];
        self.clearCache();
        self.work_len = plen;
        self.work_has_wb = has_wb; // preserve across the flush (internState reads it)
        const new_id = try self.internState(is_match, is_match_eoi);
        try self.ensureStart(program); // start0/startN are invalid after the clear
        flushes.* += 1;
        if (self.opts.on_full == .give_up and flushes.* >= MAX_FLUSHES) self.gave_up = true;
        return new_id;
    }

    /// Intern the state currently in `work[0..work_len]` (accepting flag `is_match`,
    /// end-of-input accepting flag `is_match_eoi`) to a dense id, allocating it on first
    /// sight. On a fresh state it owns a copy of the pc list, appends an all-`UNKNOWN`
    /// transition row, and bumps the footprint estimate. For a `$`-free program
    /// `is_match_eoi == is_match` at every call.
    fn internState(self: *Scratch, is_match: bool, is_match_eoi: bool) Err!u32 {
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
        try self.state_match_eoi.append(self.gpa, is_match_eoi);
        try self.state_has_wb.append(self.gpa, self.work_has_wb); // set by the closure that built `work`
        try self.wb_cache.appendNTimes(self.gpa, UNKNOWN, 2); // two resolution outcomes per state
        try self.trans.appendNTimes(self.gpa, UNKNOWN, self.nclass);
        try self.utrans.appendNTimes(self.gpa, UNKNOWN, self.nclass);

        self.cache_bytes += owned.len * @sizeOf(u32) + 2 * @as(usize, self.nclass) * @sizeOf(u32) + 58;
        return id;
    }

    /// Epsilon-closure of `seeds` into `work` (priority order, deduplicated, cut on
    /// match). The byte analogue of the Pike VM's thread closure, minus capture slots.
    /// `at_start` is whether the search position is offset 0 — what a `text_start` assertion
    /// depends on. A `text_end` (`$`/`\z`) is recorded as a pending **member** (it consumes no
    /// byte, so the thread parks until end of input) and sets `work_match_eoi` when its
    /// continuation reaches `match` — that is how a state knows it is accepting *at end of
    /// input*. Writes `work`/`work_len` and sets `work_match`/`work_match_eoi`. Allocation-free
    /// (all buffers pre-sized to the program).
    fn closure(self: *Scratch, program: *const Program, seeds: []const u32, at_start: bool, at_line_start: bool) void {
        const insts = program.byte_prog.insts;
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        self.work_len = 0;
        self.work_match = false;
        self.work_match_eoi = false;
        self.work_has_wb = false;

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
                        .assertion => |k| switch (k) {
                            // `text_start` holds iff at offset 0 (a build-time fork).
                            .text_start => {
                                if (!at_start) break :follow;
                                pc += 1;
                            },
                            // `text_end` parks here (consumes no byte): record it as a member,
                            // and mark the state accepting-at-end if its continuation reaches
                            // `match` (`reaches_end`). buildAlloc rejects every other kind.
                            .text_end => {
                                self.work[self.work_len] = pc;
                                self.work_len += 1;
                                if (program.reaches_end[pc]) self.work_match_eoi = true;
                                break :follow;
                            },
                            // `\b`/`\B` park as a member with NO baked context — they are resolved at
                            // match time by decoding the adjacent code points (`resolveWb`), so this
                            // state is `state_has_wb` and the run path resolves it per position.
                            .word_boundary, .not_word_boundary => {
                                self.work[self.work_len] = pc;
                                self.work_len += 1;
                                self.work_has_wb = true;
                                break :follow;
                            },
                            // `(?m)^` holds iff the position is a line start — a build-time fork
                            // (`at_line_start`), exactly like `text_start`/`at_start`. The forward
                            // scan supplies `at_line_start` only at line starts (offset 0 / after a
                            // `\n`), so a non-line-start re-seed dies here.
                            .line_start => {
                                if (!at_line_start) break :follow;
                                pc += 1;
                            },
                            else => break :follow, // line_end — gated out by supports()
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

        // Successors: the `next` of every `byte_range` in this state that contains the
        // class representative, in the state's (priority) order.
        const rep = program.class_rep[class];
        var ns: usize = 0;
        self.collectSeeds(program, state_id, rep, &ns);
        self.closure(program, self.seeds[0..ns], false, false); // sp > 0; body has no leading anchor
        const next = try self.internState(self.work_match, self.work_match_eoi);
        // `internState` may have grown `trans` (realloc) — re-index to write the edge.
        self.trans.items[@as(usize, state_id) * self.nclass + class] = next;
        return next;
    }

    /// Unanchored transition: the next state from `state_id` on `class`, where the
    /// successors are unioned with the start's (`startN`) successors — the implicit
    /// `(?s:.)*?` prefix that lets a match begin at any position. Drives one-pass
    /// `isMatch`. Cached in `utrans`.
    fn ustep(self: *Scratch, program: *const Program, state_id: u32, class: u32) Err!u32 {
        const idx = @as(usize, state_id) * self.nclass + class;
        const cached = self.utrans.items[idx];
        if (cached != UNKNOWN) return cached;

        const rep = program.class_rep[class];
        var ns: usize = 0;
        self.collectSeeds(program, state_id, rep, &ns); // successors of the live state
        if (program.has_line_start) {
            // `(?m)^`: a new match may begin only at a line start. The destination of THIS
            // transition is at a line start iff the byte consumed is `\n` (`class == nl_class`);
            // there, re-seed the pattern start (pc 0) — closed with `at_line_start = true`, so
            // its `line_start` passes — appended AFTER the carried successors (lower priority,
            // the `.*?` semantics). On a non-`\n` byte nothing is re-seeded, so between line
            // starts the scan only carries live threads (and stays alive through an empty state).
            const at_ls = class == program.nl_class;
            if (at_ls) {
                self.seeds[ns] = 0;
                ns += 1;
            }
            self.closure(program, self.seeds[0..ns], false, at_ls);
        } else {
            self.collectSeeds(program, self.startN, rep, &ns); // ∪ a fresh start at this byte
            self.closure(program, self.seeds[0..ns], false, false);
        }
        const next = try self.internState(self.work_match, self.work_match_eoi);
        self.utrans.items[@as(usize, state_id) * self.nclass + class] = next;
        return next;
    }

    /// Append the explicit successor `next` of every `byte_range` in `state_id` that
    /// contains `rep`, in the state's priority order. Shared by `step`/`ustep`.
    fn collectSeeds(self: *Scratch, program: *const Program, state_id: u32, rep: u8, ns: *usize) void {
        for (self.states.items[state_id]) |pc| switch (program.byte_prog.insts[pc]) {
            .byte_range => |r| if (r.range.lo <= r.range.hi and r.range.contains(rep)) {
                self.seeds[ns.*] = r.next;
                ns.* += 1;
            },
            .match => {}, // terminal: no outgoing edge
            .assertion => {}, // a pending `text_end` member: no byte transition (end-only)
            else => unreachable, // a canonical state holds only byte_range / match / text_end
        };
    }

    fn ensureStart(self: *Scratch, program: *const Program) Err!void {
        if (self.start_ready) return;
        self.closure(program, &[_]u32{0}, true, true); // offset 0: text_start AND line_start hold
        self.start0 = try self.internState(self.work_match, self.work_match_eoi);
        self.closure(program, &[_]u32{0}, false, false); // mid-input, not at a line start
        self.startN = try self.internState(self.work_match, self.work_match_eoi);
        // Line-start re-seed (`(?m)^` after a `\n`): line_start holds, text_start does not.
        if (program.has_line_start) {
            self.closure(program, &[_]u32{0}, false, true);
            self.startL = try self.internState(self.work_match, self.work_match_eoi);
        } else self.startL = self.startN;
        self.start_ready = true;
    }

    /// The start state to begin a forward scan at position `s`: `start0` at offset 0 (text +
    /// line start), `startL` at a `(?m)^` line start mid-input (just after a `\n`), else
    /// `startN`. For a non-line program `startL == startN`, so this is just the `s == 0` fork.
    inline fn startFor(self: *const Scratch, program: *const Program, input: []const u8, s: usize) u32 {
        if (s == 0) return self.start0;
        if (program.has_line_start and atLineStart(input, s)) return self.startL;
        return self.startN;
    }

    /// Whether reverse state `state` accepts a match START at position `pos`: an unconditional
    /// reverse accept (pc 0 reached), or — for a `(?m)^` program (`ls`) — a line-conditional one
    /// that also requires `pos` be a line start.
    inline fn revAccepts(self: *const Scratch, state: u32, ls: bool, input: []const u8, pos: usize) bool {
        return self.r_accept.items[state] or (ls and self.r_accept_line.items[state] and atLineStart(input, pos));
    }

    /// Run the DFA anchored at `s`: returns the leftmost-first match end reached from
    /// `s`, or null if no match begins exactly at `s`. With `earliest`, returns as soon
    /// as any accepting state is entered; otherwise it scans on, keeping the last
    /// accepting position — which, thanks to the priority/cut closure, is the
    /// leftmost-first end. The caller must have run `ensureStart`. (No dead check on the
    /// start: the closure of pc 0 always interns at least one `byte_range`/`match` pc,
    /// so the start is never the empty set.) A state also counts as accepting **at
    /// `input.len`** when its `accept_eoi` holds (a pending `text_end` `$`/`\z`); for a
    /// `$`-free program `accept_eoi == accept`, so that extra term is a no-op. (Used for
    /// `$` patterns reached via the pinned/`anchored_start` paths, e.g. `^abc$`; a plain
    /// trailing `$` takes the reverse-from-end path instead.)
    fn runAnchored(self: *Scratch, program: *const Program, input: []const u8, s: usize, earliest: bool, flushes: *u32) Err!?usize {
        var state = self.startFor(program, input, s); // text_start@0; (?m)^ line start; else startN
        // A state accepts at `s` if it holds a `match`, or — only when `s` is end-of-input — a
        // pending `text_end` (`accept_eoi`). For a `$`-free program `accept_eoi == accept`.
        var match_end: ?usize = if (self.state_match.items[state] or
            (s == input.len and self.state_match_eoi.items[state])) s else null;
        if (match_end != null and earliest) return match_end;

        // ── Warm-path pointer cache ──
        // The per-byte loop is a tight array walk over raw `[*]` pointers, *not* the
        // ArrayList `.items[...]` accessor: that accessor reloads `.ptr` on every byte
        // (the bound `self`-mutating `step` call boundary forces it), turning each
        // transition into a pointer reload + slice-bounds check. Hoisting the bases here
        // and indexing `[*]` directly keeps the warm transition a single load.
        //
        // INVALIDATION: a COLD `step` may grow `trans`/`state_match` (an all-UNKNOWN row
        // is appended per new state) and so **realloc** their backing buffer — every
        // cached pointer below would dangle. A `flushPreserving` reallocs everything too.
        // So both bases are **re-fetched after any cold transition or flush** (and never
        // touched on the warm path, which cannot grow the tables).
        var trans: [*]const u32 = self.trans.items.ptr;
        var accept: [*]const bool = self.state_match.items.ptr;
        var accept_eoi: [*]const bool = self.state_match_eoi.items.ptr;
        const map: *const [256]u8 = &program.classes.map;
        const nclass: usize = self.nclass;

        var pos = s;
        while (pos < input.len) {
            const class = map[input[pos]];
            const next = trans[@as(usize, state) * nclass + class];
            if (next != UNKNOWN) {
                // Warm path: memoized edge. No `try`, no table growth, no budget check —
                // `cache_bytes` cannot change here.
                state = next;
                if (state == DEAD) break;
                pos += 1;
                if (accept[state] or (pos == input.len and accept_eoi[state])) {
                    match_end = pos;
                    if (earliest) break;
                }
                continue;
            }
            // Cold path: compute + memoize the edge (may realloc the tables, and may push
            // `cache_bytes` over budget). Re-fetch the bases, then enforce the budget — the
            // only point `cache_bytes` grows, so the per-byte budget check is gone.
            state = try self.step(program, state, class);
            trans = self.trans.items.ptr;
            accept = self.state_match.items.ptr;
            accept_eoi = self.state_match_eoi.items.ptr;
            if (state == DEAD) break;
            pos += 1;
            if (accept[state] or (pos == input.len and accept_eoi[state])) {
                match_end = pos;
                if (earliest) break;
            }
            // Bound the cache mid-scan (only reachable just after a cold transition that
            // grew `cache_bytes`). After a flush, the tables are reallocated → re-fetch.
            if (self.opts.on_full != .grow and self.cache_bytes > self.opts.max_bytes) {
                state = try self.flushPreserving(program, state, flushes);
                trans = self.trans.items.ptr;
                accept = self.state_match.items.ptr;
                accept_eoi = self.state_match_eoi.items.ptr;
            }
        }
        return match_end;
    }

    // ── Decode-hybrid `\b`/`\B` (Unicode word boundaries on the lazy DFA) ──────────────
    //
    // A byte cannot classify a *code point's* word-ness (a continuation byte is part of a word char
    // after one lead and a non-word char after another), so the eager DFA's byte-class trick only
    // does the ASCII boundary. The lazy DFA runs over the live input, so it resolves `\b`/`\B` at
    // match time by **decoding the adjacent code points** (`nfa.assertionHolds` — the very routine
    // the Pike VM uses, so it is Unicode-correct by construction). Consumption stays the cached
    // byte-DFA walk; only a state holding a pending boundary (`state_has_wb`) pays a decode, and
    // only at code-point boundaries (a mid-multi-byte state never parks one).

    /// Resolve a state that holds pending `\b`/`\B` members at byte offset `pos`, by decoding the
    /// adjacent code points. Returns the **boundary-free** effective state: every consuming member
    /// carried over, plus the continuation of each boundary that holds at `pos`, re-closed. The
    /// caller resolves to a fixpoint (chained boundaries are rare and converge). `at_start` reflects
    /// `pos == 0` for any `text_start` reachable from a fired continuation.
    fn resolveWb(self: *Scratch, program: *const Program, state: u32, input: []const u8, pos: usize) Err!u32 {
        // The single bit that decides every parked boundary: `\b` holds at `pos` iff the adjacent
        // code points differ in word-ness (`nfa.assertionHolds`, Unicode-correct); `\B` is its
        // negation. So the resolved state depends only on (state, b) — memoize it (`pos > 0` only;
        // `pos == 0` also depends on `text_start`, so it is recomputed).
        const b = nfa.assertionHolds(.word_boundary, input, pos);
        const at_start = pos == 0;
        if (!at_start) {
            const cached = self.wb_cache.items[@as(usize, state) * 2 + @intFromBool(b)];
            if (cached != UNKNOWN) return cached;
        }
        const insts = program.byte_prog.insts;
        var ns: usize = 0;
        for (self.states.items[state]) |pc| switch (insts[pc]) {
            .assertion => |k| switch (k) {
                // `\b` fires iff b; `\B` fires iff !b. A fired boundary's continuation joins (zero-width).
                .word_boundary => if (b) {
                    self.seeds[ns] = pc + 1;
                    ns += 1;
                },
                .not_word_boundary => if (!b) {
                    self.seeds[ns] = pc + 1;
                    ns += 1;
                },
                else => { // a pending `text_end` (none in a `\b` program, but keep general)
                    self.seeds[ns] = pc;
                    ns += 1;
                },
            },
            else => { // byte_range / match members carry over (closure re-adds them idempotently)
                self.seeds[ns] = pc;
                ns += 1;
            },
        };
        self.closure(program, self.seeds[0..ns], at_start, false); // `\b` programs never carry `(?m)^` (supports excludes the combo)
        const eff = try self.internState(self.work_match, self.work_match_eoi);
        // `internState` may have grown `wb_cache` (realloc) — index through `.items` after it.
        if (!at_start) self.wb_cache.items[@as(usize, state) * 2 + @intFromBool(b)] = eff;
        return eff;
    }

    /// Anchored run for a `\b`/`\B` (word-boundary) program: the decode-hybrid. Consumption is the
    /// cached byte-DFA walk; at each state holding a pending boundary the position is resolved by
    /// decoding the adjacent code points (`resolveWb`) into a boundary-free effective state, used for
    /// both acceptance and the next transition. Leftmost-first; O(input) for the non-prone shapes
    /// `auto` routes here. (Decodes only at code-point-boundary `\b` states — sparse.)
    fn runAnchoredWb(self: *Scratch, program: *const Program, input: []const u8, s: usize, earliest: bool, flushes: *u32) Err!?usize {
        var state = if (s == 0) self.start0 else self.startN;
        var match_end: ?usize = null;
        var pos = s;
        while (true) {
            // Resolve any pending boundary at this position to a fixpoint (chained `\b` converge).
            var eff = state;
            var guard: usize = 0;
            while (self.state_has_wb.items[eff]) {
                const r = try self.resolveWb(program, eff, input, pos);
                if (r == eff) break; // degenerate zero-width loop (`\b*`): no progress → stop
                eff = r;
                guard += 1;
                if (guard > self.states.items.len) break; // safety bound
            }
            if (self.state_match.items[eff] or (pos == input.len and self.state_match_eoi.items[eff])) {
                match_end = pos;
                if (earliest) break;
            }
            if (pos >= input.len) break;
            const class = program.classes.map[input[pos]];
            state = try self.step(program, eff, class); // eff is boundary-free → a normal cached step
            if (state == DEAD) break;
            pos += 1;
            if (self.opts.on_full != .grow and self.cache_bytes > self.opts.max_bytes)
                state = try self.flushPreserving(program, state, flushes);
        }
        return match_end;
    }

    /// One-pass unanchored match detection (`isMatch`): scan once from `start`, each
    /// byte re-seeding the start via `ustep`, accepting the instant the live state is
    /// accepting. O(input), no per-position restart — the fix for the Θ(n²) `[ab]*c`
    /// class of patterns. Caller must have run `ensureStart`.
    fn runUnanchored(self: *Scratch, program: *const Program, input: []const u8, start: usize, flushes: *u32) Err!bool {
        var state = self.startFor(program, input, start);
        if (self.state_match.items[state]) return true;

        // Warm-path pointer cache — same rationale as `runAnchored`, over the *unanchored*
        // table `utrans`. INVALIDATION: a cold `ustep` may realloc `utrans`/`state_match`
        // (new-state row append), and a flush reallocs everything, so both bases are
        // re-fetched after any cold transition or flush; the warm path never grows them.
        var utrans: [*]const u32 = self.utrans.items.ptr;
        var accept: [*]const bool = self.state_match.items.ptr;
        const map: *const [256]u8 = &program.classes.map;
        const nclass: usize = self.nclass;

        var pos = start;
        while (pos < input.len) {
            const class = map[input[pos]];
            const next = utrans[@as(usize, state) * nclass + class];
            if (next != UNKNOWN) {
                // Warm path: no `try`, no growth, no budget check.
                state = next;
                if (accept[state]) return true;
                pos += 1;
                continue;
            }
            // Cold path: compute + cache (may realloc → re-fetch the bases) and, only here,
            // honour the budget (the sole place `cache_bytes` grows).
            state = try self.ustep(program, state, class);
            utrans = self.utrans.items.ptr;
            accept = self.state_match.items.ptr;
            if (accept[state]) return true;
            pos += 1;
            if (self.opts.on_full != .grow and self.cache_bytes > self.opts.max_bytes) {
                state = try self.flushPreserving(program, state, flushes);
                utrans = self.utrans.items.ptr;
                accept = self.state_match.items.ptr;
            }
        }
        return false;
    }

    // ── Reverse-DFA find: forward leftmost END, then reverse leftmost START (O(n)) ──

    /// Find the END offset of the leftmost-first match at or after `start`, or null.
    /// Phase 1 (unmatched): scan with `ustep` (re-seeding the start each byte — the
    /// implicit `.*?` prefix) so the FIRST accepting state corresponds to the earliest
    /// starting thread (priority order makes older threads win the match cut). Phase 2
    /// (matched): once a match is seen the leftmost start is fixed, so switch to the
    /// anchored `step` and extend the matched thread greedily; the last accepting position
    /// before it dies is the leftmost-first end. (Assertion-free programs only —
    /// `searchImpl` routes `text_start` patterns to anchored restart.)
    fn findEndForward(self: *Scratch, program: *const Program, input: []const u8, start: usize, flushes: *u32) Err!?usize {
        var state = self.startFor(program, input, start);
        var matched = self.state_match.items[state];
        var end: ?usize = if (matched) start else null;

        // Warm-path pointer cache — both forward tables are live here: `utrans` drives the
        // pre-match re-seeding scan (phase 1), `trans` the post-match greedy extension
        // (phase 2); `state_match` (`accept`) is read in both. INVALIDATION: a cold
        // `step`/`ustep` may realloc any of the three (new-state row append), and a flush
        // reallocs everything — so every base is re-fetched after any cold transition or
        // flush. The warm path never grows the tables.
        var trans: [*]const u32 = self.trans.items.ptr;
        var utrans: [*]const u32 = self.utrans.items.ptr;
        var accept: [*]const bool = self.state_match.items.ptr;
        const map: *const [256]u8 = &program.classes.map;
        const nclass: usize = self.nclass;

        var pos = start;
        while (pos < input.len) {
            const class = map[input[pos]];
            if (matched) {
                const idx = @as(usize, state) * nclass + class;
                var next = trans[idx];
                if (next == UNKNOWN) {
                    // Cold: compute + cache (may realloc → re-fetch), then budget-check.
                    next = try self.step(program, state, class);
                    trans = self.trans.items.ptr;
                    utrans = self.utrans.items.ptr;
                    accept = self.state_match.items.ptr;
                    if (next == DEAD) break; // the matched thread is exhausted
                    state = next;
                    pos += 1;
                    if (accept[state]) end = pos;
                    if (self.opts.on_full != .grow and self.cache_bytes > self.opts.max_bytes) {
                        state = try self.flushPreserving(program, state, flushes);
                        trans = self.trans.items.ptr;
                        utrans = self.utrans.items.ptr;
                        accept = self.state_match.items.ptr;
                    }
                    continue;
                }
                // Warm: memoized edge, no growth, no budget check.
                if (next == DEAD) break;
                state = next;
                pos += 1;
                if (accept[state]) end = pos;
            } else {
                // Re-seeding scan: never breaks on an empty state — `ustep` re-seeds the
                // start, so a match can still begin at a later byte.
                const idx = @as(usize, state) * nclass + class;
                const next = utrans[idx];
                if (next == UNKNOWN) {
                    // Cold: compute + cache (may realloc → re-fetch), then budget-check.
                    state = try self.ustep(program, state, class);
                    trans = self.trans.items.ptr;
                    utrans = self.utrans.items.ptr;
                    accept = self.state_match.items.ptr;
                    pos += 1;
                    if (accept[state]) {
                        matched = true;
                        end = pos;
                    }
                    if (self.opts.on_full != .grow and self.cache_bytes > self.opts.max_bytes) {
                        state = try self.flushPreserving(program, state, flushes);
                        trans = self.trans.items.ptr;
                        utrans = self.utrans.items.ptr;
                        accept = self.state_match.items.ptr;
                    }
                    continue;
                }
                // Warm: memoized edge, no growth, no budget check.
                state = next;
                pos += 1;
                if (accept[state]) {
                    matched = true;
                    end = pos;
                }
            }
        }
        return end;
    }

    /// Epsilon-closure (reverse) of `seeds` into `work`: follow reverse-epsilon edges,
    /// collecting `byte_target` pcs (the reverse state members) and setting `work_match`
    /// when pc 0 (the forward start = reverse accept) is reached. No priority, no cut — a
    /// reverse state is a plain set, since the end is already fixed and we only need "is
    /// `[s, end)` a match" (reachability of pc 0).
    fn revClosure(self: *Scratch, program: *const Program, seeds: []const u32) void {
        const rev = &program.rev;
        self.seen_gen +%= 1;
        const gen = self.seen_gen;
        self.work_len = 0;
        self.work_match = false;
        self.work_match_line = false;
        for (seeds) |seed| {
            var top: usize = 0;
            self.stack[top] = seed;
            top += 1;
            while (top > 0) {
                top -= 1;
                const pc = self.stack[top];
                if (self.seen[pc] == gen) continue;
                self.seen[pc] = gen;
                // pc 0 = the forward start = reverse accept. For `(?m)^` pc 0 is the leading
                // `line_start` assertion, so the accept is CONDITIONAL on the current reverse
                // position being a line start — recorded separately and checked in `revFind`.
                if (pc == 0) {
                    if (program.has_line_start) self.work_match_line = true else self.work_match = true;
                }
                // Collect byte_target pcs (have reverse-byte out-edges) AND pc 0 (the
                // accept). Including pc 0 as a member is what keeps an "accepting but no
                // byte edges" state's key (`[0]`) distinct from the DEAD empty set (`[]`)
                // when interned — otherwise its accept flag would collide with DEAD's.
                if (rev.byte_target[pc] or pc == 0) {
                    self.work[self.work_len] = pc;
                    self.work_len += 1;
                }
                var e: usize = rev.eps_off[pc];
                const e_end = rev.eps_off[pc + 1];
                while (e < e_end) : (e += 1) {
                    const u = rev.eps[e];
                    if (self.seen[u] != gen) {
                        self.stack[top] = u;
                        top += 1;
                    }
                }
            }
        }
    }

    /// Intern the reverse state in `work[0..work_len]` (sorted, so set-equal states
    /// collapse to one id) to a dense reverse-state id, appending its accept flag and an
    /// all-`UNKNOWN` transition row on first sight.
    fn revInternState(self: *Scratch) Err!u32 {
        std.mem.sort(u32, self.work[0..self.work_len], {}, std.sort.asc(u32));
        const key = self.work[0..self.work_len];
        const gop = try self.r_intern.getOrPut(self.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = try self.gpa.dupe(u32, key);
        gop.key_ptr.* = owned;
        const id: u32 = @intCast(self.r_states.items.len);
        gop.value_ptr.* = id;
        try self.r_states.append(self.gpa, owned);
        try self.r_accept.append(self.gpa, self.work_match);
        try self.r_accept_line.append(self.gpa, self.work_match_line);
        try self.r_trans.appendNTimes(self.gpa, UNKNOWN, self.nclass);
        return id;
    }

    /// The next reverse state from `state_id` on byte-`class` (memoized): consume the
    /// class representative *backward* — from each byte_target pc in the state, follow its
    /// reverse-byte edges to the `byte_range`s that lead into it — then close.
    fn revStep(self: *Scratch, program: *const Program, state_id: u32, class: u32) Err!u32 {
        const idx = @as(usize, state_id) * self.nclass + class;
        const cached = self.r_trans.items[idx];
        if (cached != UNKNOWN) return cached;
        const rep = program.class_rep[class];
        const rev = &program.rev;
        var ns: usize = 0;
        for (self.r_states.items[state_id]) |pc| {
            var b: usize = rev.rb_off[pc];
            const b_end = rev.rb_off[pc + 1];
            while (b < b_end) : (b += 1) {
                if (rep >= rev.rb_lo[b] and rep <= rev.rb_hi[b]) {
                    self.seeds[ns] = rev.rb_src[b];
                    ns += 1;
                }
            }
        }
        self.revClosure(program, self.seeds[0..ns]);
        const next = try self.revInternState();
        self.r_trans.items[@as(usize, state_id) * self.nclass + class] = next;
        return next;
    }

    /// Intern the reverse DEAD sink (empty set, id 0) and the reverse start (the closure
    /// of the forward `match` pcs). Idempotent across searches.
    fn ensureRevStart(self: *Scratch, program: *const Program) Err!void {
        if (self.r_start_ready) return;
        self.work_len = 0;
        self.work_match = false;
        std.debug.assert((try self.revInternState()) == DEAD); // empty set = DEAD
        self.revClosure(program, program.rev.match_seed);
        self.r_start = try self.revInternState();
        self.r_start_ready = true;
    }

    /// Leftmost match START for a match known to end at `end`, searching down to `lo`
    /// (the search's `opts.start`). Runs the reverse DFA anchored at `end`, scanning
    /// backward; the smallest position at which pc 0 is reachable — i.e. `[s, end)` is a
    /// full match — is the leftmost-first start. (The forward already fixed `end` as the
    /// leftmost match's end, so no earlier start ≥ `lo` matches `[·, end)`.)
    fn revFind(self: *Scratch, program: *const Program, input: []const u8, end: usize, lo: usize) Err!usize {
        try self.ensureRevStart(program);
        const ls = program.has_line_start; // (?m)^: accept a start only where it's a line start
        var state = self.r_start;
        var found: ?usize = if (self.revAccepts(state, ls, input, end)) end else null; // empty match at `end`?

        // Warm-path pointer cache over the *reverse* tables `r_trans`/`r_accept`(`_line`). The
        // reverse cache is never flushed (it grows unbounded; only the forward cache is
        // budgeted), so the sole invalidation is a cold `revStep` realloc'ing the reverse
        // tables on a new-state row append — re-fetch all bases after every cold step.
        var r_trans: [*]const u32 = self.r_trans.items.ptr;
        var r_accept: [*]const bool = self.r_accept.items.ptr;
        var r_accept_line: [*]const bool = self.r_accept_line.items.ptr;
        const map: *const [256]u8 = &program.classes.map;
        const nclass: usize = self.nclass;

        var pos = end;
        while (pos > lo) {
            pos -= 1;
            const class = map[input[pos]];
            const next = r_trans[@as(usize, state) * nclass + class];
            if (next != UNKNOWN) {
                // Warm path: memoized reverse edge, no growth.
                state = next;
                if (r_accept[state] or (ls and r_accept_line[state] and atLineStart(input, pos))) found = pos;
                if (state == DEAD) break;
                continue;
            }
            // Cold path: compute + cache the reverse edge (may realloc → re-fetch bases).
            state = try self.revStep(program, state, class);
            r_trans = self.r_trans.items.ptr;
            r_accept = self.r_accept.items.ptr;
            r_accept_line = self.r_accept_line.items.ptr;
            if (r_accept[state] or (ls and r_accept_line[state] and atLineStart(input, pos))) found = pos;
            if (state == DEAD) break;
        }
        return found orelse end; // the forward guaranteed a match, so non-null in practice
    }

    /// Leftmost match START for an `end_anchored` (trailing-`$`) program, where every match
    /// ends at `input.len`. One reverse-DFA pass from `input.len` down to `lo` (`opts.start`);
    /// the smallest position whose reverse state accepts (forward pc 0 reachable ⇒
    /// `[pos, input.len)` is a full match) is the leftmost-first start, or null if no suffix
    /// `[·, input.len)` matches. Because `$`/`\z` pins the end at end-of-input, no forward
    /// end-find is needed — this single O(input) backward pass is the whole search (the eager
    /// DFA's `revFindEnd`, lazily cached). The trailing `$` is woven into the reverse start as
    /// a passable epsilon (`buildReverse`), so `r_start` already represents "at end-of-input,
    /// `$` satisfied". The fix for the Θ(n²) anchored restart on begin-but-don't-complete `$`
    /// shapes (`[ab]*c$`, `\w+@\w+$`, `\w+$`).
    ///
    /// @stable-since: v0.4.0
    fn revFindEnd(self: *Scratch, program: *const Program, input: []const u8, lo: usize) Err!?usize {
        try self.ensureRevStart(program);
        var state = self.r_start;
        var found: ?usize = if (self.r_accept.items[state]) input.len else null; // empty match at end (`a*$` on "")

        // Warm-path pointer cache over the *reverse* tables (see `revFind`): the reverse cache
        // is never flushed, so the sole invalidation is a cold `revStep` realloc — re-fetch
        // both bases after every cold step.
        var r_trans: [*]const u32 = self.r_trans.items.ptr;
        var r_accept: [*]const bool = self.r_accept.items.ptr;
        const map: *const [256]u8 = &program.classes.map;
        const nclass: usize = self.nclass;

        var pos = input.len;
        while (pos > lo) {
            pos -= 1;
            const class = map[input[pos]];
            const next = r_trans[@as(usize, state) * nclass + class];
            if (next != UNKNOWN) {
                // Warm path: memoized reverse edge, no growth.
                state = next;
                if (r_accept[state]) found = pos;
                if (state == DEAD) break;
                continue;
            }
            // Cold path: compute + cache the reverse edge (may realloc → re-fetch bases).
            state = try self.revStep(program, state, class);
            r_trans = self.r_trans.items.ptr;
            r_accept = self.r_accept.items.ptr;
            if (r_accept[state]) found = pos;
            if (state == DEAD) break;
        }
        return found;
    }
};

// ── Search core ───────────────────────────────────────────────────────────────────

/// Leftmost match: scan start positions from `opts.start`, run the DFA anchored at
/// each, return the first that matches. A start-anchored pattern (`\A`/`^`) tries only
/// `s == 0`. Internal (returns the allocator error); the entry points turn OOM into a
/// `@panic`.
fn searchImpl(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions, earliest: bool) Err!?Match {
    if (opts.start > input.len) return null;
    scratch.gave_up = false;
    scratch.maybeEvict();
    try scratch.ensureStart(program);
    var flushes: u32 = 0;

    // `\b`/`\B` programs run the decode-hybrid on anchored restart (no reverse DFA for `\b`):
    // consumption is the cached byte-DFA walk, boundary positions decode the adjacent code points.
    if (program.has_word_boundary) {
        if (opts.anchored)
            return if (try scratch.runAnchoredWb(program, input, opts.start, earliest, &flushes)) |e| Match{ .start = opts.start, .end = e } else null;
        if (program.anchored_start) {
            if (opts.start != 0) return null;
            return if (try scratch.runAnchoredWb(program, input, 0, earliest, &flushes)) |e| Match{ .start = 0, .end = e } else null;
        }
        var s = opts.start;
        while (s <= input.len) : (s += 1) {
            if (try scratch.runAnchoredWb(program, input, s, earliest, &flushes)) |e| return Match{ .start = s, .end = e };
        }
        return null;
    }

    if (program.anchored_start and !opts.anchored) {
        // Every match begins at offset 0 — try only there.
        if (opts.start != 0) return null;
        if (try scratch.runAnchored(program, input, 0, earliest, &flushes)) |end|
            return Match{ .start = 0, .end = end };
        return null;
    }
    if (opts.anchored) {
        // Pinned start: one anchored run.
        if (try scratch.runAnchored(program, input, opts.start, earliest, &flushes)) |end|
            return Match{ .start = opts.start, .end = end };
        return null;
    }

    // Trailing `$` (every match ends at input.len): one reverse pass from the end finds the
    // leftmost start in O(input). The end is pinned, so no forward scan — and crucially no
    // anchored restart, which is Θ(n²) on `[ab]*c$`-style begin-but-don't-complete shapes.
    // (`^…$` is `anchored_start`, handled above; this is a plain trailing `$`.)
    if (program.end_anchored) {
        const st = (try scratch.revFindEnd(program, input, opts.start)) orelse return null;
        return Match{ .start = st, .end = input.len };
    }

    // Unanchored find. The reverse-DFA path is **O(input)**: one forward pass (`ustep`
    // then anchored `step`) locates the leftmost match END, then the reverse DFA — anchored
    // at that end, scanning backward — locates the leftmost START, replacing the Θ(n²)
    // anchored restart. A `text_start` pattern (rare, and not fully `anchored_start`) keeps
    // anchored restart, since the reverse transitions must stay position-independent.
    if (program.rev.built) {
        const e0 = (try scratch.findEndForward(program, input, opts.start, &flushes)) orelse return null;
        const s0 = try scratch.revFind(program, input, e0, opts.start);
        return Match{ .start = s0, .end = e0 };
    }

    var s = opts.start;
    while (s <= input.len) : (s += 1) {
        if (try scratch.runAnchored(program, input, s, earliest, &flushes)) |end|
            return Match{ .start = s, .end = end };
    }
    return null;
}

/// One-pass `isMatch`. An anchored or start-anchored pattern reduces to a single
/// anchored run (no scan); otherwise the unanchored automaton detects a match anywhere
/// in O(input).
fn isMatchImpl(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) Err!bool {
    if (opts.start > input.len) return false;
    scratch.gave_up = false;
    scratch.maybeEvict();
    try scratch.ensureStart(program);
    var flushes: u32 = 0;

    // `\b`/`\B` programs run the decode-hybrid (anchored restart, earliest-exit).
    if (program.has_word_boundary) {
        if (opts.anchored) return (try scratch.runAnchoredWb(program, input, opts.start, true, &flushes)) != null;
        if (program.anchored_start) {
            if (opts.start != 0) return false;
            return (try scratch.runAnchoredWb(program, input, 0, true, &flushes)) != null;
        }
        var s = opts.start;
        while (s <= input.len) : (s += 1) {
            if ((try scratch.runAnchoredWb(program, input, s, true, &flushes)) != null) return true;
        }
        return false;
    }

    if (opts.anchored)
        return (try scratch.runAnchored(program, input, opts.start, true, &flushes)) != null;
    if (program.anchored_start) {
        if (opts.start != 0) return false;
        return (try scratch.runAnchored(program, input, 0, true, &flushes)) != null;
    }
    // Trailing `$`: a single reverse pass from input.len — any start position reaching the
    // forward start ⇒ a match. O(input). (A `$` program has no mid-input `match`, so the
    // one-pass `runUnanchored` over `utrans` would wrongly never accept — route to the
    // reverse pass instead.)
    if (program.end_anchored) return (try scratch.revFindEnd(program, input, opts.start)) != null;
    return scratch.runUnanchored(program, input, opts.start, &flushes);
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// Does the pattern match anywhere from `opts.start`? One-pass (O(input)) for the
/// common unanchored case; the cheapest op.
///
/// @stable-since: v0.3.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return isMatchImpl(program, scratch, input, opts) catch @panic(OOM_PANIC);
}

/// The leftmost match span `[start, end)`, or null. Leftmost-first, identical to the
/// code-point engines. `SearchOptions.earliest` is advisory and ignored here (the span
/// is always leftmost-first); `isMatch` is the earliest-exit entry point.
///
/// @stable-since: v0.3.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    return searchImpl(program, scratch, input, opts, false) catch @panic(OOM_PANIC);
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests — end-to-end through Engine(dfa), plus differential checks vs. the Pike VM
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

test "supports(): accepts byte-class + \\A/^ + anchored-end $ + isolated \\b/\\B + leading (?m)^; declines mixed-$/(?m)$/\\X/\\b-combos" {
    const gpa = testing.allocator;
    // \A and non-multiline ^ lower to a text_start assertion; an `anchored_end` $/\z lowers to
    // a text_end assertion matched by the reverse-from-end pass — both DFA-evaluable. `\b`/`\B`
    // (Unicode word boundaries) are accepted in isolation and run on the decode-hybrid path. A
    // single LEADING `(?m)^` (line_start) is accepted — line-gated forward re-seed + reverse
    // line-accept, O(input).
    const accepts = [_][]const u8{
        "[a-z]+",  "\\w+\\d*", "cat|dog",         "héllo", "a.*c",
        "\\p{L}+", "^abc",     "\\Aword",         "^\\d+",
        // text_end, anchored_end (every match ends at input end):
        "abc$",    "\\w+$",    "[a-z]+@[a-z]+$",  "^abc$", "x\\z",  "foo$|bar$",
        // isolated word boundaries (decode-hybrid):
        "\\bcat\\b", "\\Bx",   "\\b\\w+\\b",      "s\\b",  "\\bword\\b",
        // leading (?m)^ (line_start) — the only line anchor the lazy DFA now runs:
        "(?m)^line", "(?m)^\\w+", "(?m)^\\S+ \\S+",
    };
    // \X is a grapheme (variable-width); `(?m)$` (line_end) is position-dependent on the byte
    // AHEAD (not supported); an INTERIOR/repeated `(?m)^` is not a single leading anchor; a
    // `(?m)^…$` mixes line_start with text_end; a *mixed* $ is not anchored_end → Θ(n²); a `\b`
    // COMBINED with `$` is deferred — all declined to the code-point engines.
    const declines = [_][]const u8{
        "a\\Xb", "(?m)$", "(?m)\\w+$", "a(?m)^b", "(?m)^a$", "a$|b", "(foo$|bar)", "\\bword$", "\\bword\\b$",
    };
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

test "text_start anchors (\\A / non-multiline ^) match only at offset 0" {
    try expectFind("^abc", "abcdef", "abc");
    try expectNoMatch("^abc", "xabc");
    try expectFind("\\Aword", "word here", "word");
    try expectNoMatch("\\Aword", "a word");
    try expectFind("^\\d+", "123abc", "123");
    try expectNoMatch("^\\d+", "x123");
    try expectSpan("^a*", "aaab", 0, 3); // greedy from the anchored start
    try expectFind("^a*", "baaa", ""); // empty match at 0 (no 'a' there)
}

test "one-pass isMatch is correct on the Θ(n²)-restart pattern class" {
    // `[ab]*c` can BEGIN at every position of `aaaa…` but completes nowhere — the case
    // anchored-restart handles in O(n²). The unanchored one-pass isMatch is O(n) and
    // must still answer correctly.
    var re = try Compiled.init("[ab]*c");
    defer re.deinit();
    var big: [4096]u8 = undefined;
    @memset(&big, 'a');
    try testing.expect(!re.isMatch(&big)); // no 'c' anywhere
    @memcpy(big[2048..][0..2], "bc");
    try testing.expect(re.isMatch(&big)); // now there is
    // isMatch must agree with find != null on a spread of inputs.
    const inputs = [_][]const u8{ "", "c", "aaac", "no c here", "  abc  ", "zzbbaac!" };
    for (inputs) |in| try testing.expectEqual(re.find(in) != null, re.isMatch(in));
}

test "on_full = .give_up raises gave_up after thrashing; .reset does not; both stay correct" {
    const gpa = testing.allocator;
    var program = try buildFrom(gpa, "\\w+");
    defer freeProgram(gpa, &program);
    const input = "  hello world  ";

    // A 1-byte budget forces a flush nearly every step (mid-search eviction). `.give_up`
    // raises `gave_up` once it has thrashed past MAX_FLUSHES; the result stays correct.
    var g = try Scratch.initOptions(gpa, &program, .{ .max_bytes = 1, .on_full = .give_up });
    defer g.deinit(gpa);
    try testing.expectEqualStrings("hello", E.find(&program, &g, input, .{}).?.slice(input));
    try testing.expect(g.gave_up);

    // `.reset` thrashes identically and is just as correct, but never raises `gave_up`.
    var r = try Scratch.initOptions(gpa, &program, .{ .max_bytes = 1, .on_full = .reset });
    defer r.deinit(gpa);
    try testing.expectEqualStrings("hello", E.find(&program, &r, input, .{}).?.slice(input));
    try testing.expect(!r.gave_up);
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

test "lazy DFA \\b/\\B is UNICODE-correct (decode-hybrid; non-ASCII boundaries agree with Pike VM)" {
    // The decode-hybrid resolves word boundaries over CODE POINTS (`nfa.assertionHolds`), so the
    // boundary is correct even when a non-ASCII word char sits right at it — the case the eager
    // DFA's ASCII byte-classes get wrong (and route to the Pike VM for). The lazy DFA must AGREE
    // with the Pike VM on every one of these.
    const patterns = [_][]const u8{
        "\\bword\\b", "\\b\\w+\\b", "\\w+\\b",  "\\b\\w+",   "\\Bcat\\B",
        "\\bété\\b",  "\\b\\p{L}+\\b", "\\p{L}+\\b", "s\\b",  "\\bx",
        "x\\b",       "café\\b",    "\\bcafé\\b", "\\b\\w+",  "(\\w+)\\b",
    };
    const inputs = [_][]const u8{
        "",              "the café is",  "déjà vu",       "naïve approach",
        "café au lait",  "Ολα καλά",     "Привет мир",    "日本語 text",
        "über alles",    "x café y",     "_id_ über",     "résumé done",
        "a wörd here",   "ÀÉÎ",          "cafés",         "l'été chaud",
    };
    for (patterns) |p| for (inputs) |in| try expectAgreesWithPikeVM(p, in);
}

test "lazy DFA \\b/\\B: direct Unicode-correct spans (ASCII would differ)" {
    try expectFind("\\bword\\b", "a word here", "word");
    try expectFind("\\b\\w+\\b", "  café au lait", "café"); // é is a word char (Unicode)
    try expectFind("\\bété\\b", "l'été chaud", "été"); // boundary adjacent to é
    try expectFind("café\\b", "le café noir", "café");
    // The decisive case: "cafés" = café + 's' (both word at the seam) → NO boundary after é, so
    // `\bcafé\b` must NOT match. ASCII byte-`\b` (treating the é continuation byte as non-word)
    // would WRONGLY match "café" here; the Unicode decode-hybrid gets it right.
    try expectNoMatch("\\bcafé\\b", "cafés");
    try expectFind("\\Bcat\\B", "locator", "cat");
    try expectFind("\\b\\w+\\b", "Привет мир", "Привет"); // Cyrillic word
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

test "reverse-DFA find: O(n) leftmost-first on the anchored-restart-pathological class" {
    // `\w+@\w+` can BEGIN at every word position but only completes at an `@`, so the
    // old anchored-restart `find` is Θ(n²). The reverse-DFA path (forward locates the
    // match END in one pass, the reverse DFA locates the START) is O(n) and must stay
    // leftmost-first. These run instantly only because the path is linear.
    const gpa = testing.allocator;
    var re = try Compiled.init("\\w+@\\w+");
    defer re.deinit();
    const big = try gpa.alloc(u8, 8000);
    defer gpa.free(big);
    // No `@` at all: every one of the 8000 word positions begins a long run that never
    // completes — the Θ(n²) worst case — yet the reverse-DFA path rejects in O(n).
    @memset(big, 'a');
    try testing.expect(re.find(big) == null);
    // A single match bounded by non-word separators, deep inside the buffer.
    @memset(big, '.');
    @memcpy(big[4000..][0..5], "ab@cd");
    try testing.expectEqualStrings("ab@cd", re.find(big).?.slice(big));
    try testing.expectEqual(@as(usize, 4000), re.find(big).?.start);
}

test "reverse-DFA find agrees with anchored restart (has_text_start) across a corpus" {
    // The reverse-DFA path (assertion-free) and the anchored-restart path (`text_start`)
    // must return identical spans. Pair each pattern with a `^`-prefixed variant that is
    // semantically the same on these inputs but forced onto anchored restart.
    const pairs = [_]struct { rev: []const u8, anc: []const u8, in: []const u8, exp: ?[]const u8 }{
        .{ .rev = "a.*c", .anc = "(?:a.*c|\\Az)", .in = "xabXcYc", .exp = "abXcYc" },
        .{ .rev = "\\w+", .anc = "(?:\\w+|\\Az)", .in = "  héllo  ", .exp = "héllo" },
        .{ .rev = "[0-9]+", .anc = "(?:[0-9]+|\\Az)", .in = "ab123cd", .exp = "123" },
    };
    for (pairs) |p| {
        var r = try Compiled.init(p.rev);
        defer r.deinit();
        var a = try Compiled.init(p.anc);
        defer a.deinit();
        const rm = r.find(p.in);
        const am = a.find(p.in);
        try testing.expectEqual(rm == null, am == null);
        if (rm) |m| {
            try testing.expectEqual(m.start, am.?.start);
            try testing.expectEqual(m.end, am.?.end);
            if (p.exp) |e| try testing.expectEqualStrings(e, m.slice(p.in));
        }
    }
}

// ── text_end ($/\z): the reverse-from-end path (anchored_end only) ──────────────────

test "text_end ($ / \\z): leftmost-first spans on the reverse-from-end path" {
    try expectFind("\\w+$", "  hello world", "world");
    try expectFind("[a-z]+$", "ABCdef", "def");
    try expectNoMatch("[a-z]+$", "abc!"); // no [a-z] at the very end
    try expectFind("abc$", "xxabcabc", "abc");
    try expectNoMatch("abc$", "abcx");
    try expectFind("\\d+$", "a1b234", "234");
    try expectFind("x\\z", "axx", "x");
    try expectFind("[a-z]+@[a-z]+$", "see alice@host", "alice@host");
    try expectNoMatch("[a-z]+@[a-z]+$", "alice@host!");
    try expectFind("foo$|bar$", "a foo a bar", "bar"); // every branch ends $ → anchored_end
    try expectFind("a*$", "", ""); // empty match at end of empty input
    try expectSpan("a*$", "baaa", 1, 4); // greedy run ending at input end (leftmost start)
    try expectFind("[α-ω]+$", "ΑΒΓαβγ", "αβγ"); // multi-byte, byte-stepped
}

test "text_end with ^ / \\A uses the anchored-start path (accept_eoi at end)" {
    try expectFind("^abc$", "abc", "abc");
    try expectNoMatch("^abc$", "abcd");
    try expectNoMatch("^abc$", "xabc");
    try expectFind("\\A\\d+$", "12345", "12345");
    try expectNoMatch("\\A\\d+$", "12345x");
    try expectFind("^[a-z]*$", "", ""); // empty input, ^…$ holds
    try expectSpan("^\\w+$", "héllo", 0, 6); // byte offsets
}

test "end_anchored / has_text_end flags route $ patterns correctly" {
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, has_text_end: bool, end_anchored: bool, anchored_start: bool };
    for ([_]Case{
        .{ .pat = "[a-z]+$", .has_text_end = true, .end_anchored = true, .anchored_start = false }, // reverse-from-end
        .{ .pat = "\\w+@\\w+$", .has_text_end = true, .end_anchored = true, .anchored_start = false },
        .{ .pat = "foo$|bar$", .has_text_end = true, .end_anchored = true, .anchored_start = false },
        .{ .pat = "^abc$", .has_text_end = true, .end_anchored = false, .anchored_start = true }, // anchored-start path
        .{ .pat = "\\A\\d+$", .has_text_end = true, .end_anchored = false, .anchored_start = true },
        .{ .pat = "[a-z]+", .has_text_end = false, .end_anchored = false, .anchored_start = false }, // no $
    }) |c| {
        var prog = try buildFrom(gpa, c.pat);
        defer freeProgram(gpa, &prog);
        try testing.expectEqual(c.has_text_end, prog.has_text_end);
        try testing.expectEqual(c.end_anchored, prog.end_anchored);
        try testing.expectEqual(c.anchored_start, prog.anchored_start);
        if (prog.end_anchored) try testing.expect(prog.rev.built); // end_anchored ⟹ reverse built
    }
}

test "differential vs Pike VM: trailing-$ corpus (spans must agree)" {
    const patterns = [_][]const u8{
        "[a-z]+$",  "[a-z]+@[a-z]+$",   "[ab]*c$",  "a+$",      "\\d+$",
        "\\d{3}$",  "[0-9]+\\.[0-9]+$", ".*$",      ".*foo$",   "[a-z]+\\s*$",
        "x*$",      "(foo|bar)$",       "abc$",     "[α-ω]+$",  "é+$",
        "(?i)end$", "^abc$",            "\\A\\d+$", "^[a-z]*$", "foo$|bar$",
    };
    const inputs = [_][]const u8{
        "",              "abc",        "trailing 42", "ends with foo",
        "no terminal c", "abcc",       "12.34",       "  spaced   ",
        "alice@host",    "ALICE@HOST", "αβγ",         "café",
        "the end",       "END",        "aaaaaaaa!",   "ababababc",
        "a@b",           "foo",        "bar",         "αβγδ end",
    };
    for (patterns) |p| {
        for (inputs) |in| try expectAgreesWithPikeVM(p, in);
    }
}

test "trailing $ is linear, not Θ(n²) (ReDoS immunity, reverse-from-end)" {
    // A begin-but-don't-complete `$` shape on a long input with no completer: under anchored
    // restart this is Θ(n²) (every start walks to end-of-input and fails). The reverse-from-end
    // path makes it ONE O(input) backward pass, so this completing near-instantly is the signal;
    // a quadratic regression makes it visibly hang. ASCII keeps determinization cheap.
    const gpa = testing.allocator;
    const N = 1 << 18; // 262144
    const buf = try gpa.alloc(u8, N);
    defer gpa.free(buf);
    for ([_][]const u8{ "[a-z]+$", "[a-z]+@[a-z]+$", "[ab]*c$" }) |pat| {
        var re = try Compiled.init(pat);
        defer re.deinit();
        @memset(buf, 'a');
        buf[N - 1] = '!'; // no terminal [a-z]/@/c ⇒ no match — the worst case
        try testing.expect(re.find(buf) == null);
        try testing.expect(!re.isMatch(buf));
        @memset(buf, 'a'); // all [a-z]: [a-z]+$ matches the whole string; @/c shapes do not
        _ = re.find(buf);
        _ = re.isMatch(buf);
    }
}

test {
    testing.refAllDecls(@This());
}
