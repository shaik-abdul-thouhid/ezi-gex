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
//!     (a tiny POD `Filter`) and picks **at most one** start-skip, in priority order:
//!       - a `min_utf8_len` length gate (and an `anchored_start` `^…`/`\A…` short-circuit to
//!         offset 0) always apply first;
//!       - **single leading literal** → a portable two-byte SIMD `memmem` skip (`memmem.Finder`)
//!         that leaps literal-to-literal (`\bthe\b` jumps "the"→"the"); when the whole pattern is a
//!         literal wrapped in word-boundary assertions (`\bthe\b`, `the\b`), a hit is confirmed by an
//!         **O(1) word-boundary check** (`lit_wb_confirm`), not an anchored automaton walk;
//!       - **multi-prefix set** — a top-level alternation's leading literals (`Holmes…|Watson…`),
//!         a synthesised **case-variant set** for a small-class / `(?i)` lead (`(?i)the` →
//!         `{THE…the}`, `(?i)что`), OR a **case-insensitive alternation set** — one ASCII-folded
//!         needle per branch of `(?i:Sherlock|Holmes|Watson)` / `(?i:Sher[a-z]+|Hol[a-z]+)`
//!         (`caseiAlternationSet`; the fold-aware Teddy masks match either case so casei branches
//!         do not blow the needle budget) — → the **Teddy** SIMD multi-literal scan
//!         (`prefix_teddy`, case-folding via `compileFoldAlloc`), scalar `multiPrefixFrom`
//!         (`caseiFindFrom` when folded) as the comptime/non-native fallback;
//!       - **required interior/suffix literal** — a selective literal anywhere on the mandatory
//!         spine when no leading literal applies (`\w+\s+Holmes`, `[a-zA-Z]+ing`): `memmem` the
//!         *whole* literal, then — when the atoms before it are **disjoint class-repetitions** — a
//!         **structured reverse walk** to the EXACT match start + one anchored confirm per hit
//!         (`req_pre`, the automaton runs only at real candidate starts, not over the gaps; ASCII-
//!         exact, with a flat-scan fallback for non-ASCII windows). A bounded fixed-length pattern
//!         with a **rare byte at a fixed code-point offset** (`[a-q][^u-z]{13}x`) instead `memchr`s
//!         that byte and confirms at `cpBack(q, off)` (`req_lit_fixed_off`). Otherwise a `memmem`
//!         skip + reverse-scan over the preceding alphabet + one unanchored find;
//!       - **interior anchor** — a required literal after a leading class run (`[\w.+-]+@…`,
//!         `\d{4}-…`): memchr to the anchor, then either a bounded reverse-scan + native find
//!         (variable run) or, when the leading run is **fixed-length** and the input is ASCII, a
//!         bounded confirm at the pinned start `anchor − off` (`inner_fixed_off`, one confirm per
//!         occurrence — the win on a dash-dense haystack);
//!       - on the **lazy-DFA arm** specifically, a leading literal or a **rare** interior anchor
//!         drives a *jump-and-confirm* loop (leap to each occurrence, confirm anchored there) rather
//!         than one skip + a full native pass — the win on a prone pattern with a slow native walk
//!         (`the\s+\p{L}+` ~2.4×, `[\w.+-]+@…` ~2.1×). A `reach` budget (`dfa.confirmReach` +
//!         `Scratch.lazy_confirm_bytes`) keeps it linear: an overrun hands the rest to the native
//!         find. A common anchor (`.`) stays on the single-skip path (byte-frequency gate);
//!       - **line-anchored** — a `(?m)^…` pattern with no eager DFA (`log_line`) attempts the match
//!         anchored at each line start (memchr the next `\n`), for span *and* captures, instead of a
//!         lazy-DFA span pass plus a capture-fill pass (`line_anchored`);
//!       - **leading-class scan** — a selective digit/number-class lead (`\d+`, `\p{N}+`) → a
//!         SIMD scan to the next member of the class's first-byte set (`classscan.ClassFinder`);
//!       - else the rarest unconditionally-required byte drives a presence fast-reject.
//!     Every `Analysis` fact is a sound one-sided bound, so the prefilter never drops a real
//!     match — it only avoids running the engine where one provably cannot start.
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

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const nfa = @import("engine_base").nfa;
const simd = @import("engine_base").simd;
const memmem = @import("engine_base").memmem;
const teddy = @import("engine_base").teddy;
const classscan = @import("engine_base").classscan;

const literal = @import("literal");
const pikevm = @import("pikevm");
const backtrack = @import("backtrack");
const dfa = @import("dfa");
const edfa = @import("edfa");
const onepass = @import("onepass");
const byte = @import("engine_base").byte;

const utils = @import("utils");
const encoding = utils.unicode.encoding;
const utf8 = utils.unicode.utf8;
const CodePoint = utils.unicode.CodePoint;

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

/// Byte-NFA instruction ceiling above which `auto` does **not** attempt the eager DFA at runtime,
/// going straight to the lazy DFA. Eager determinization is a full subset construction over the
/// byte NFA; its cost scales with (DFA states × byte_insts) and explodes for a big Unicode class
/// repeated or joined (`\w+@\w+` ≈ 9.3k insts → ~0.5s; `[\w.+-]+@…` ≈ 14k → ~0.9s, and that one
/// overflows `edfa.max_states` and **declines** — pure wasted work, since it then uses the lazy
/// DFA regardless). Every fast-determinizing class scan measured stays well under this (`\d+`,
/// `\p{N}+`, `\p{L}+`, `\p{Lu}\p{Ll}+`, `\w+` ≤ ~5k insts, ≤ ~50 ms), so they keep their eager
/// DFA; only the explosive joins drop to the lazy DFA (same states on demand, amortized over the
/// input). Results-invariant — it only changes which span engine runs, never the match. The
/// comptime CTRE-lane uses the separate, tighter `tinyForComptimeEdfa` gate.
///
/// @stable-since: v0.5.0
const EAGER_BYTE_INST_MAX: u32 = 8000;

/// Byte-frequency ceiling (a `memmem.byteFreq` score) under which a variable interior anchor
/// (`[\w.+-]+@…`) drives a **per-occurrence jump-and-confirm** in the lazy-DFA arm rather than one
/// skip + a native pass. A rare anchor (`@`, freq 25) lets the `memchr` leap over most of the input
/// and run few confirms — a large win; a common anchor (`.`, freq 90) recurs almost everywhere, so
/// the jump loop would confirm at nearly every byte and lose to the single native pass. The cutoff
/// admits clearly-selective punctuation (`@`/`#`/`&`/`|`) and excludes common separators
/// (`.`/`-`/`/`/`:`). Heuristic — it steers speed only; the match is identical either way.
///
/// @stable-since: v0.6.0
const INNER_ANCHOR_RARE_MAX: u8 = 40;

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
    /// leading-literal SIMD `memmem` start-skip, rarest-required-byte fast-reject). On by
    /// default; `false` builds an all-permissive filter so the engine scans without
    /// probing. Results-invariant.
    ///
    /// @stable-since: v0.3.0
    prefilter: bool = true,

    /// SIMD policy for the literal arm's Teddy accelerator, projected from
    /// `Options.strategy.simd`. `.auto` builds Teddy for a literal-alternation pattern on a
    /// target with a native dynamic shuffle; `.off` keeps the portable scan. Only the literal
    /// arm consults it today (the NFA-arm multi-prefix prefilter is a follow-up).
    /// Results-invariant.
    ///
    /// @stable-since: v0.4.0
    simd: simd.SimdMode = .auto,

    /// @stable-since: v0.3.0
    pub const ByteEngine = enum { auto, enabled, disabled };
};

/// Search-time prefilter facts, distilled from the HIR `Analysis` at build into a
/// tiny POD (so it bakes into `ro_data` at comptime and needs no allocation). Every
/// field is a **sound one-sided bound** — true for *every* match — so acting on it
/// never drops a real match. Only consulted on the NFA arm; the literal arm does its
/// own scanning.
///
/// The longest leading literal kept for the `memmem` start-skip: `analysis.prefix_literal`
/// is truncated to this many UTF-8 bytes (always at a code-point boundary). A truncated run
/// is still a **sound necessary prefix** (every match begins with it), and ~8–16 bytes is
/// already maximally selective for a `memmem` skip — a longer needle only grows the `Filter`
/// POD (which bakes into `ro_data` at comptime, so it must stay small and pointer-free).
///
/// @stable-since: v0.4.0
const MAX_PREFIX_LEN = 16;

/// @stable-since: v0.1.0
pub const Filter = struct {
    /// `analysis.min_utf8_len`: a match needs at least this many bytes, so an input
    /// (slice from the search start) shorter than this cannot match.
    min_bytes: u32 = 0,
    /// `analysis.anchored_start`: every match begins at offset 0 (`^`/`\A`, no
    /// multiline) — an unanchored scan need only try position 0.
    anchored_start: bool = false,
    /// First UTF-8 byte of `analysis.prefix_literal`, or null when no fixed leading
    /// literal exists. Retained as the degenerate single-byte fact (== `prefix[0]` when
    /// `prefix_len > 0`); the engine now skips on the whole `prefix[0..prefix_len]` run.
    prefix_byte: ?u8 = null,
    /// The **rarest** byte (by `byteRarity`) of `analysis.required_bytes` — a byte that
    /// appears in *every* match — or null when nothing is unconditionally required.
    /// Drives a sound **fast-reject**: if it does not occur in the remaining input, no
    /// match exists there, so the search returns immediately (the big win for a
    /// prefix-less interior-literal pattern like `\w+@\w+` on input with no `@`). Picked
    /// rarest so the `memchr` is as selective as possible.
    rare_byte: ?u8 = null,
    /// UTF-8 bytes of `analysis.prefix_literal` — the literal run every match must begin
    /// with — truncated to `MAX_PREFIX_LEN` (at a code-point boundary). `prefix[0..prefix_len]`
    /// is the **SIMD `memmem` start-skip needle**: a match can only begin where this whole run
    /// occurs, so the scan leaps literal-to-literal (`\bthe\b` jumps "the"→"the") instead of
    /// byte-to-byte (the old `prefix_byte` memchr). `prefix_len == 0` means no usable leading
    /// literal; `prefix_len == 1` degrades to exactly the `prefix_byte` memchr. Strictly more
    /// selective than the single byte and always sound (it is a necessary prefix of every match).
    ///
    /// @stable-since: v0.4.0
    prefix: [MAX_PREFIX_LEN]u8 = @splat(0),
    /// Number of valid bytes in `prefix` (0 = no usable leading literal).
    ///
    /// @stable-since: v0.4.0
    prefix_len: u8 = 0,

    /// Multi-prefix set: the leading literal of every branch of a top-level alternation
    /// (`Holmes…|Watson…`), each truncated to `MAX_PREFIX_LEN` bytes. `prefix_set[i][0..
    /// prefix_set_len[i]]` is branch `i`'s needle. `prefix_set_n == 0` ⇒ unused. Because
    /// every match begins with one of these, the **leftmost occurrence of any** of them is
    /// a sound start-skip (`multiPrefixFrom`), exactly like the single `prefix` but for an
    /// alternation that has no common leading literal. Only set when `prefix_len == 0`.
    ///
    /// @stable-since: v0.4.0
    prefix_set: [hir.MAX_PREFIX_BRANCHES][MAX_PREFIX_LEN]u8 = @splat(@splat(0)),
    /// Valid byte length of each `prefix_set` needle.
    ///
    /// @stable-since: v0.4.0
    prefix_set_len: [hir.MAX_PREFIX_BRANCHES]u8 = @splat(0),
    /// Number of needles in `prefix_set` (0 = unused; otherwise ≥ 2).
    ///
    /// @stable-since: v0.4.0
    prefix_set_n: u8 = 0,
    /// True when `prefix_set` is a **case-variant set** synthesised from a small-class-led
    /// concat (`(?i)the` → {THE,…,the}, `(?i)что` → 8 Cyrillic variants) rather than the
    /// leading literals of a top-level alternation. Both ride the same multi-prefix skip
    /// machinery; this only documents/diagnoses the source (and pins the white-box test).
    ///
    /// @stable-since: v0.4.0
    prefix_set_case_variant: bool = false,
    /// True when the `prefix_set` needles match **ASCII-case-insensitively** — one needle per
    /// branch of a top-level case-insensitive alternation (`(?i:Sherlock|Holmes|Watson)`,
    /// `(?i:Sher[a-z]+|Hol[a-z]+)`). Unlike `prefix_set_case_variant` (which enumerates the
    /// cartesian product of a single concat's case variants — `2^k` needles), this keeps **one
    /// needle per branch** and folds ASCII case in the Teddy masks + verify, so an alternation
    /// of casei branches stays within the `MAX_PREFIX_BRANCHES` budget. The needle bytes are
    /// stored in their canonical (as-written) case; the per-position fold is applied at match
    /// time. The automaton confirm at each hit enforces full Unicode-correct semantics.
    ///
    /// @stable-since: v0.6.0
    prefix_set_fold_ascii: bool = false,
    /// Byte-offset RANGE of the `prefix_set` window from the **match start**: a Teddy hit at
    /// input position `q` implies a candidate match start at `q - d` for some
    /// `d ∈ [prefix_set_off_min, prefix_set_off_max]`. `0/0` for a leading set (the common
    /// case). A case-variant set may instead sit at the **rarest** interior window of a bounded
    /// phrase (`(?i)sherlock holmes` → the rare `[cC][kK] ` window, far fewer Teddy candidates
    /// than the common leading `[sS][hH][eE]`); the per-occurrence confirm then anchors across
    /// `q - off_max .. q - off_min`. The range (not a single offset) accounts for variable-length
    /// case-fold variants of the **preceding** positions (`s` folds to the 2-byte `ſ`, so a
    /// `ſherlock…` match shifts the window one byte right). Sound — the window is a necessary
    /// substring of every match, and for non-overlapping matches the candidate starts stay
    /// monotonic, so leftmost-first is preserved. Only set for a **bounded** pattern.
    ///
    /// @stable-since: v0.6.0
    prefix_set_off_min: u32 = 0,
    /// @stable-since: v0.6.0
    prefix_set_off_max: u32 = 0,

    /// Inner-anchor byte: the first byte of a required literal that immediately follows a
    /// leading variable class run (`@` in `[\w.+-]+@…`), or null. Drives a sound *skip to
    /// the anchor + bounded reverse-scan over `inner_lead`* start-skip (`innerSkipFrom`) for
    /// a pattern with no leading literal — far better than the mere `rare_byte` presence
    /// reject. Only set when there is no `prefix`/`prefix_set`, and only when the byte is
    /// rare enough (`byteRarity`) that the skip pays off.
    ///
    /// @stable-since: v0.4.0
    inner_byte: ?u8 = null,
    /// The leading variable run's byte alphabet — what the inner-anchor reverse scan walks
    /// back over to reach the earliest possible match start. Meaningful only when
    /// `inner_byte != null`. (Bytes ≥ 0x80 are set conservatively; see `hir.InnerAnchor`.)
    ///
    /// @stable-since: v0.4.0
    inner_lead: hir.ByteSet = .{},

    /// UTF-8 bytes of a **required interior/suffix literal** (`analysis.required_literal_skip`),
    /// truncated to `MAX_PREFIX_LEN` at a code-point boundary — the **memmem** start-skip needle
    /// for a pattern with no leading literal but a selective literal in its interior or at its end
    /// (`\w+\s+Holmes`, `[a-zA-Z]+ing`, `[\w.+-]+@gmail\.com`). The general form of `inner_byte`:
    /// it leaps on the *whole literal* (far fewer candidates than a single common byte like the
    /// `i` of "ing"), then walks back over `req_lead` to the earliest match start and runs one
    /// unanchored pass. `req_lit_len == 0` means unused. Set only when no `prefix`/`prefix_set`
    /// applies, and only when the needle is ≥ 2 bytes (a 1-byte needle is `inner_byte`'s memchr).
    ///
    /// @stable-since: v0.6.0
    req_lit: [MAX_PREFIX_LEN]u8 = @splat(0),
    /// Number of valid bytes in `req_lit` (0 = unused; otherwise ≥ 2).
    ///
    /// @stable-since: v0.6.0
    req_lit_len: u8 = 0,
    /// Reverse-scan alphabet for `req_lit`: the bytes that may precede the literal in any match
    /// (a sound superset). The skip walks back over these from a needle hit to the earliest
    /// possible match start. Meaningful only when `req_lit_len > 0` (see `hir.RequiredLiteralSkip`).
    ///
    /// @stable-since: v0.6.0
    req_lead: hir.ByteSet = .{},
    /// Fixed cp-distance from the match start to `req_lit` when the leading spine is fixed-length
    /// (`hir.RequiredLiteralSkip.lead_fixed_cps`), else null. On ASCII input this is the byte
    /// distance, so a memchr to the (rare) literal byte at `q` pins the start to `q - off`: a single
    /// anchored confirm there per occurrence — the **Pass 2** fixed-offset rare-byte confirm for a
    /// bounded fixed-length pattern (`[a-q][^u-z]{13}x`). Set only when the needle is a single byte
    /// rare enough (`byteFreq ≤ INNER_ANCHOR_RARE_MAX`) and the match is bounded; otherwise the
    /// (≥2-byte) memmem variable path is used instead.
    ///
    /// @stable-since: v0.6.0
    req_lit_fixed_off: ?u32 = null,
    /// True when `req_lit` is the match's **suffix** (last consuming atom) — the match ends exactly
    /// at the literal (`hir.RequiredLiteralSkip.is_suffix`). On the lazy-DFA arm this lets a memmem
    /// hit be confirmed by a precise reverse-DFA pass from the hit's end (no flat-reverse over-reach,
    /// no forward re-seed) rather than reverse-scan + unanchored find.
    ///
    /// @stable-since: v0.6.0
    req_lit_suffix: bool = false,

    /// Structured reverse-walk atoms (`hir.RequiredLiteralSkip.pre`): the disjoint class-repetition
    /// atoms before the literal, in spine order. When `req_pre_n > 0`, the DFA arms find the **exact**
    /// match start from a memmem hit by walking these backward (reverse spine order, greedy within
    /// `[min,max]`) — no over-reach — then run ONE anchored confirm per occurrence (the win for
    /// `\w+\s+Holmes`/`\w+\s+Holmes\s+\w+`: the automaton runs only at real candidate starts, not over
    /// the gaps). The walk is exact only over ASCII (the classes' high bytes are conservative), so the
    /// arm engages on ASCII-dominant input and per occurrence verifies the window is pure-ASCII;
    /// the rare non-ASCII window falls back to a flat reverse-scan + bounded confirm sweep.
    ///
    /// @stable-since: v0.6.0
    req_pre: [hir.MAX_PRE_ATOMS]hir.ByteSet = @splat(.{}),
    /// @stable-since: v0.6.0
    req_pre_min: [hir.MAX_PRE_ATOMS]u32 = @splat(0),
    /// @stable-since: v0.6.0
    req_pre_max: [hir.MAX_PRE_ATOMS]u32 = @splat(0),
    /// Number of valid `req_pre` atoms (0 = structured walk unavailable). @stable-since: v0.6.0
    req_pre_n: u8 = 0,

    /// The match has a **bounded** maximum length (`max_utf8_len ≤ CONFIRM_MAX`), so an
    /// anchored confirm reads at most that many bytes. This makes a **per-occurrence**
    /// multi-prefix confirm (anchored at every prefix hit, advancing past it) O(occurrences ×
    /// max_len) = O(input) — no Θ(n²) — which is the real win for a sparse-but-DFA-heavy
    /// pattern like `Holmes.{0,30}Watson|…` (a single skip + DFA find re-scans the whole gap;
    /// per-occurrence confirms each fail within ~max_len). Unbounded patterns keep the single
    /// skip + linear dispatch. Only consulted on the `prefix_set` arm.
    ///
    /// @stable-since: v0.4.0
    bounded_confirm: bool = false,

    /// Leading-class first-byte set: every match begins with one of these bytes (the
    /// pattern's leading mandatory atom is a class with no fixed leading literal — `\d+`,
    /// `\p{N}+`, `\d{4}-…`). Drives a SIMD scan to the next member (`classscan.ClassFinder`,
    /// built into `Program.class_finder`) — the start-skip that lets the DFA run only on the
    /// real class runs instead of crawling the gaps. Null unless the set is **selective**
    /// (`classLeadSelective`): a set covering most of typical text (`\p{L}+`) would land on
    /// almost every byte and isn't worth it. Set only when no `prefix`/`prefix_set`/
    /// `inner_byte` skip applies.
    ///
    /// @stable-since: v0.4.0
    class_lead: ?hir.ByteSet = null,

    /// True when `class_lead` is the **derived over-approximation** built by `asciiLeadDerived`
    /// for a sparse-ASCII / broad-tail class (`\p{Lu}…`): `{ASCII members} ∪ {all high bytes}`.
    /// Sound on every input, but only *useful* when the input is ASCII-dominant (where the high
    /// bytes are rare, so the scan skips lowercase gaps to the next capital). On non-ASCII input
    /// every byte is ≥ 0x80, so the scan would land on every byte and only add overhead — the
    /// search-time arms therefore engage this class scan **only when the input is all-ASCII**
    /// (and otherwise fall through to the native find, exactly as before this set existed). A
    /// genuinely-selective `class_lead` (`\d+`, `\p{N}+`) leaves this false and always engages.
    ///
    /// @stable-since: v0.6.0
    class_lead_ascii_only: bool = false,

    /// Fixed code-point distance from the match start to `inner_byte` when the leading run is
    /// fixed-length (`\d{4}-…` → 4; mirror of `hir.InnerAnchor.lead_fixed_cps`). On **ASCII
    /// input** the anchor sits exactly this many *bytes* into every match, so a hit at byte `q`
    /// pins the start to `q - inner_fixed_off`: the `inner_byte` skip then jumps anchor-to-anchor
    /// and **bounded-confirms** at the pinned start (one confirm per occurrence) instead of the
    /// reverse-scan + native find, which is the win when the anchor byte is dense and not
    /// selective (nginx `- -` placeholders make `-` appear several times per line). Null when the
    /// leading run is variable; the call site additionally requires ASCII input and a bounded
    /// match length (so each confirm is O(max_len) ⇒ the loop stays O(input), no Θ(n²)).
    ///
    /// @stable-since: v0.5.0
    inner_fixed_off: ?u32 = null,

    /// The whole pattern is a pure literal optionally wrapped in leading/trailing **word-boundary**
    /// assertions (`\bthe\b`, `the\b`, `\bfoo`, `\Bfoo\B`): `prefix[0..prefix_len]` IS the entire
    /// match. A `memmem` prefix hit therefore already confirms the literal, so the match needs only
    /// two O(1) ASCII word-boundary checks (`lit_wb_lead` at the hit, `lit_wb_trail` at hit+len) —
    /// no automaton walk per occurrence. The eager-DFA `\b` arm runs only on ASCII input
    /// (`edfaArm` routes non-ASCII `\b` to the Pike VM), so the ASCII boundary check is exact there.
    /// The headline win for `\bthe\b` over prose, where "the" occurs as a substring far more often
    /// than as a whole word and every false hit otherwise paid a full anchored DFA confirm.
    ///
    /// @stable-since: v0.5.0
    lit_wb_confirm: bool = false,
    /// Word-boundary requirement at the match START / END for `lit_wb_confirm` (`.none` when that
    /// side carries no boundary assertion). @stable-since: v0.5.0
    lit_wb_lead: WbAssert = .none,
    /// @stable-since: v0.5.0
    lit_wb_trail: WbAssert = .none,

    /// Every match begins at a **line start** (offset 0 or just after a `\n`): the pattern's
    /// leading mandatory atom is `(?m)^` (`hir.analysis.line_anchored_start`, and not the tighter
    /// `anchored_start`). Lets a capture search **attempt only at line starts** — `memchr` the next
    /// `\n`, run the capturing engine anchored there — instead of locating each span with the lazy
    /// DFA and then re-filling captures. The win for `log_line` ((?m)^…captures…), which no eager
    /// DFA can hold (so it otherwise pays a lazy-DFA span pass *plus* a Pike VM capture pass per
    /// line). Sound because no match can begin off a line start.
    ///
    /// @stable-since: v0.5.0
    line_anchored: bool = false,
};

/// A word-boundary requirement at one end of a `lit_wb_confirm` literal match: none, `\b`
/// (must be a boundary), or `\B` (must NOT be a boundary). @stable-since: v0.5.0
pub const WbAssert = enum { none, boundary, not_boundary };

/// Max match length (UTF-8 bytes) under which the per-occurrence multi-prefix confirm is
/// used (see `Filter.bounded_confirm`). Each confirm reads ≤ this many bytes, so the loop is
/// linear with this as its constant; a bound keeps that constant modest.
///
/// @stable-since: v0.4.0
const CONFIRM_MAX: u32 = 256;

/// Inner-anchor rarity ceiling: only build the inner-literal skip when the anchor byte
/// scores at or below this on `byteRarity` (punctuation / digits / uppercase). A common
/// anchor (lowercase, space) occurs almost everywhere, so the skip would barely advance
/// and isn't worth its memchr + reverse-scan — fall back to the plain scan there.
///
/// @stable-since: v0.4.0
const INNER_RARITY_MAX: u8 = 50;

/// Largest number of code points a single leading class may have for the **case-variant**
/// expansion to enumerate it. A position with more choices than this aborts the expansion
/// (`\d`'s 10 members → the class-scan lane instead, not a 10-way variant set). Two suffices
/// for a folded ASCII letter (`[Tt]`); a few cover Greek `σ`/`ς`/`Σ` and friends.
///
/// @stable-since: v0.4.0
const VARIANT_CLASS_MAX: usize = 4;

/// Minimum needle length (UTF-8 bytes) for a case-variant set to be worth building. A
/// 1-byte set (`[Tt]` alone) lands almost everywhere; ≥ 2 bytes makes the Teddy fingerprint
/// selective. Soundness is independent of this — it gates speed only.
///
/// @stable-since: v0.4.0
const VARIANT_MIN_LEN: u8 = 2;

/// Ceiling on the number of **high** (≥ 0x80) UTF-8 lead bytes in a leading-class first-byte
/// set for the class scan to apply. A digit / number class spans a few scripts' lead bytes
/// (`\d` → 8, `\p{N}` → 11) and stays selective; a broad **letter** class (`\p{Lu}` → 21,
/// `\p{L}` → 45) covers the lead bytes of whole scripts (Cyrillic `0xD0`/`0xD1`, CJK
/// `0xE4`–`0xE9`), so on a non-Latin corpus it lands on nearly every character — the scan
/// then only adds overhead. The compile-time analysis can't see the corpus, so this caps the
/// breadth instead: ≤ 16 high lead bytes admits digits/numbers and excludes letter classes.
///
/// @stable-since: v0.4.0
const CLASS_HIGH_LEAD_MAX: u32 = 16;

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

/// Encode the leading code points of literal run `run` into `out` as UTF-8, truncating
/// at a code-point boundary to fit `MAX_PREFIX_LEN`. Returns the byte length (0 if none
/// fit). A truncated run is still a sound necessary prefix of every match it leads.
fn encodeRun(h: hir.Hir, run: hir.Node.Run, out: *[MAX_PREFIX_LEN]u8) u8 {
    var n: usize = 0;
    var k: u32 = 0;
    while (k < run.len and n < MAX_PREFIX_LEN) : (k += 1) {
        const cp = h.literals[run.start + k];
        if (!encoding.isValidCodePoint(cp)) break;
        var buf: [4]u8 = undefined;
        const m = utf8.encodeCodePointUnchecked(cp, &buf);
        if (m == 0 or n + m > MAX_PREFIX_LEN) break;
        @memcpy(out[n .. n + m], buf[0..m]);
        n += m;
    }
    return @intCast(n);
}

/// Total UTF-8 byte length of literal run `run` (untruncated). Used to confirm a `\b`-literal's
/// `prefix` run holds the *whole* match (`prefix_len == fullRunBytes`) before enabling the O(1)
/// boundary confirm.
fn fullRunBytes(h: hir.Hir, run: hir.Node.Run) usize {
    var n: usize = 0;
    var k: u32 = 0;
    while (k < run.len) : (k += 1) {
        const cp = h.literals[run.start + k];
        if (!encoding.isValidCodePoint(cp)) return std.math.maxInt(usize); // can't encode → never == prefix_len
        var buf: [4]u8 = undefined;
        const m = utf8.encodeCodePointUnchecked(cp, &buf);
        if (m == 0) return std.math.maxInt(usize);
        n += m;
    }
    return n;
}

/// The `\b`/`\B` shape of a pattern that is exactly `[\b|\B]? literal-run [\b|\B]?` — a pure
/// literal optionally wrapped in leading/trailing word-boundary assertions and nothing else —
/// or null. Drives the `lit_wb_confirm` O(1) boundary check (see `Filter.lit_wb_confirm`). A
/// leading `^`/`\A`/`$` (a non-word-boundary anchor), any extra consuming atom, or no boundary at
/// all returns null (the last because a bare literal already takes the plain `memmem` path).
const LitWbShape = struct { lead: WbAssert, trail: WbAssert, run: hir.Node.Run };
fn literalWbShape(h: hir.Hir) ?LitWbShape {
    if (h.nodes[h.root].tag != .concat) return null; // a bare literal has no boundary → not this shape
    const d = h.nodes[h.root].data.children;
    const kids = h.children[d.start .. d.start + d.len];
    if (kids.len == 0) return null;

    var i: usize = 0;
    var lead: WbAssert = .none;
    if (h.nodes[kids[0]].tag == .anchor) {
        lead = wbKind(h.nodes[kids[0]]) orelse return null; // a non-word-boundary leading anchor → decline
        i = 1;
    }
    if (i >= kids.len or h.nodes[kids[i]].tag != .literal) return null;
    const run = h.nodes[kids[i]].data.run;
    i += 1;
    var trail: WbAssert = .none;
    if (i < kids.len) {
        if (h.nodes[kids[i]].tag != .anchor) return null; // another consuming atom → not a pure literal
        trail = wbKind(h.nodes[kids[i]]) orelse return null;
        i += 1;
    }
    if (i != kids.len) return null; // trailing atoms beyond the optional boundary
    if (lead == .none and trail == .none) return null; // no boundary → plain `memmem`, no O(1) confirm needed
    return .{ .lead = lead, .trail = trail, .run = run };
}

/// The `WbAssert` of an anchor node, or null when it is not a word-boundary anchor (`^ $ \A \z`).
fn wbKind(node: hir.Node) ?WbAssert {
    return switch (node.data.anchor.kind) {
        .word_boundary => .boundary,
        .not_word_boundary => .not_boundary,
        else => null,
    };
}

/// ASCII word boundary at byte offset `i` of `input`: the word-ness of the bytes straddling `i`
/// differ (`isAsciiWordByte(input[i-1]) != isAsciiWordByte(input[i])`, with out-of-range treated
/// as non-word). Exact for ASCII input — and `lit_wb_confirm` only runs on the eager-DFA `\b` arm,
/// which `edfaArm` restricts to ASCII input. Comptime-safe (no `@Vector`).
inline fn asciiWbAt(input: []const u8, i: usize) bool {
    const left = i > 0 and byte.isAsciiWordByte(input[i - 1]);
    const right = i < input.len and byte.isAsciiWordByte(input[i]);
    return left != right;
}

/// Whether the two ASCII word-boundary requirements of a `lit_wb_confirm` match hold for a literal
/// occupying `[p, p + len)` — the whole O(1) confirm (the literal itself is already confirmed by
/// the `memmem` hit).
inline fn litWbHolds(filter: *const Filter, input: []const u8, p: usize, len: usize) bool {
    const lead_ok = switch (filter.lit_wb_lead) {
        .none => true,
        .boundary => asciiWbAt(input, p),
        .not_boundary => !asciiWbAt(input, p),
    };
    if (!lead_ok) return false;
    return switch (filter.lit_wb_trail) {
        .none => true,
        .boundary => asciiWbAt(input, p + len),
        .not_boundary => !asciiWbAt(input, p + len),
    };
}

/// Unicode-correct variant of `litWbHolds`: the boundary requirements evaluated with
/// `nfa.assertionHolds` (it decodes the adjacent code points), so it is exact for **non-ASCII**
/// input too. Used by the lazy-DFA arm (`runByteDfa`), which serves non-ASCII `\b` programs —
/// `\bthe\b` over prose containing `é`/accents, where the eager ASCII `\b` arm is declined and the
/// O(1) confirm here replaces the lazy DFA's decode-hybrid anchored-restart find. Correct for ASCII
/// input as well (every code point is one byte). Comptime-safe (`assertionHolds` decodes, no @Vector).
inline fn litWbHoldsU(filter: *const Filter, input: []const u8, p: usize, len: usize) bool {
    const lead_ok = switch (filter.lit_wb_lead) {
        .none => true,
        .boundary => nfa.assertionHolds(.word_boundary, input, p),
        .not_boundary => nfa.assertionHolds(.not_word_boundary, input, p),
    };
    if (!lead_ok) return false;
    return switch (filter.lit_wb_trail) {
        .none => true,
        .boundary => nfa.assertionHolds(.word_boundary, input, p + len),
        .not_boundary => nfa.assertionHolds(.not_word_boundary, input, p + len),
    };
}

/// Distil the sound prefilter facts from the HIR analysis. Picks **at most one** start-skip
/// in priority order — single leading literal, multi-prefix set, **case-variant set**,
/// interior anchor, **leading-class scan** — falling back to the rarest-required-byte
/// presence reject only when none applies. Every choice is a sound one-sided bound (see
/// `Filter`); a search acting on it never drops a real match.
fn filterFromAnalysis(h: hir.Hir) Filter {
    const an = h.analysis;
    var f = Filter{ .min_bytes = an.min_utf8_len, .anchored_start = an.anchored_start };
    f.bounded_confirm = if (an.max_utf8_len) |mx| mx <= CONFIRM_MAX else false;
    // Line-start anchoring (`(?m)^…`): a capture search may attempt only at line starts. Disjoint
    // from `anchored_start` (which is tighter — offset 0 only); set before the early return so it
    // is false there.
    f.line_anchored = an.line_anchored_start and !an.anchored_start;
    // A start-skip only helps an unanchored scan; for `anchored_start` the start
    // short-circuit already pins the search to offset 0.
    if (an.anchored_start) return f;

    // 1. Single leading literal → two-byte SIMD `memmem` start-skip (`prefix_byte` mirrors
    //    its first byte for the degenerate one-byte case).
    if (an.prefix_literal) |run| {
        const n = encodeRun(h, run, &f.prefix);
        if (n > 0) {
            f.prefix_len = n;
            f.prefix_byte = f.prefix[0];
        }
    }

    // 1b. `\b`-wrapped pure literal (`\bthe\b`, `the\b`): the whole match IS the prefix run, so a
    //     `memmem` hit needs only two O(1) ASCII boundary checks, not an anchored automaton confirm.
    //     Requires the prefix to be the *complete* literal (untruncated) — else hit+prefix_len is
    //     not the true match end.
    if (f.prefix_len > 0) {
        if (literalWbShape(h)) |shape| {
            if (fullRunBytes(h, shape.run) == f.prefix_len) {
                f.lit_wb_confirm = true;
                f.lit_wb_lead = shape.lead;
                f.lit_wb_trail = shape.trail;
            }
        }
    }

    // 2. Multi-prefix set (top-level alternation, no common leading literal) → leftmost-of-
    //    any-needle skip. Needs every branch's leading literal to encode to ≥ 1 byte, else
    //    the set is not a sound necessary prefix and is dropped.
    if (f.prefix_len == 0) {
        if (an.prefix_set) |ps| set_blk: {
            if (ps.len < 2) break :set_blk;
            var i: usize = 0;
            while (i < ps.len) : (i += 1) {
                const n = encodeRun(h, ps.runs[i], &f.prefix_set[i]);
                if (n == 0) break :set_blk; // a branch had no encodable prefix → drop the whole set
                f.prefix_set_len[i] = n;
            }
            f.prefix_set_n = ps.len;
        }
    }

    // 2b. Case-variant set: a small-class-led concat (`(?i)the` → {THE,…,the}) has no fixed
    //     leading literal and no top-level alternation, so it reaches here. Enumerate the
    //     leading positions' choices into a bounded byte-string set (every match begins with
    //     one of them → sound), feeding the same multi-prefix skip — but via Teddy.
    if (f.prefix_len == 0 and f.prefix_set_n == 0) {
        // For a BOUNDED, all-ASCII case-variant phrase, place the Teddy set at the **rarest**
        // interior window (`(?i)sherlock holmes` → `[oO][cC][kK]` at offset 5 instead of the
        // common leading `[sS][hH][eE]`) — far fewer candidates to confirm. The per-occurrence
        // confirm anchors at `hit - offset`. Falls back to the leading set otherwise.
        if (f.bounded_confirm) {
            if (caseVariantWindow(h, &f)) f.prefix_set_case_variant = true;
        }
        if (f.prefix_set_n == 0) {
            const n = caseVariantSet(h, &f);
            if (n >= 2) {
                f.prefix_set_n = n;
                f.prefix_set_case_variant = true;
            }
        }
    }

    // 2c. Case-insensitive alternation set: a top-level `(?i:Sher[a-z]+|Hol[a-z]+)` /
    //     `(?i:Sherlock|Holmes|Watson)`. Case folding turns each branch's leading letters into
    //     classes (`S`→`[Ss]`/`[Ssſ]`), so step 2's `prefix_set` (which needs a fixed leading
    //     literal per branch) declines and the cartesian case-variant set (step 2b, a single
    //     concat) does not apply. Build ONE needle per branch — ASCII case pairs collapse into
    //     the fold-aware Teddy masks, only non-ASCII fold members fan out — so an alternation of
    //     casei branches stays within the needle budget. `caseiAlternationSet` sets
    //     `prefix_set_fold_ascii`.
    if (f.prefix_len == 0 and f.prefix_set_n == 0) {
        const n = caseiAlternationSet(h, &f);
        if (n >= 2) f.prefix_set_n = n;
    }

    // 3. Interior anchor (no leading literal at all) → skip-to-anchor + reverse-scan, when
    //    the anchor byte is rare enough to pay off.
    if (f.prefix_len == 0 and f.prefix_set_n == 0) {
        if (an.inner_anchor) |ia| {
            if (byteRarity(ia.byte) <= INNER_RARITY_MAX) {
                f.inner_byte = ia.byte;
                f.inner_lead = ia.lead_class;
                f.inner_fixed_off = ia.lead_fixed_cps; // fixed leading run → dash-to-dash bounded confirm (ASCII)
            }
        }
    }

    // 3b. General required interior/suffix literal (`\w+\s+Holmes`, `[a-zA-Z]+ing`,
    //     `[\w.+-]+@gmail\.com`): memmem the *whole* literal — selective even when its first byte
    //     is common (the `i` of "ing") — then reverse-scan over the preceding alphabet to the
    //     earliest match start. The general form of `inner_byte` (which only fires for a literal
    //     immediately after one leading class run, and only via a first-byte memchr); the search
    //     arms prefer this whenever it is set (≥ 2-byte needle). Only when no leading literal/set.
    if (f.prefix_len == 0 and f.prefix_set_n == 0) {
        if (an.required_literal_skip) |rl| {
            const n = encodeRun(h, rl.run, &f.req_lit);
            if (n >= 2) {
                // Variable path: memmem the whole (≥ 2-byte) literal, reverse-scan to the start.
                f.req_lit_len = n;
                f.req_lead = rl.lead_class;
                f.req_lit_suffix = rl.is_suffix;
                // Structured reverse-walk atoms (the precise-start fast path; see `Filter.req_pre`).
                f.req_pre_n = rl.pre_n;
                for (0..rl.pre_n) |i| {
                    f.req_pre[i] = rl.pre[i].bits;
                    f.req_pre_min[i] = rl.pre[i].min;
                    f.req_pre_max[i] = rl.pre[i].max;
                }
            } else if (n == 1 and f.bounded_confirm and rl.lead_fixed_cps != null and
                memmem.byteFreq(f.req_lit[0]) <= INNER_ANCHOR_RARE_MAX)
            {
                // Pass 2 fixed-offset path: a single RARE byte at a fixed cp-offset in a bounded
                // fixed-length pattern (`[a-q][^u-z]{13}x`). memchr the byte, confirm at `q - off`.
                f.req_lit_len = 1;
                f.req_lead = rl.lead_class; // used by the runNfa variable fallback
                f.req_lit_fixed_off = rl.lead_fixed_cps;
                f.req_lit_suffix = rl.is_suffix;
            }
        }
    }

    // 4. Leading-class first-byte scan (`\d+`, `\p{N}+`, `\d{4}-…`): no literal / set / inner
    //    anchor applies, but the match begins with a class byte — SIMD-scan to the next
    //    member. Only when the set is selective (a near-universal set like `\p{L}+` is not).
    if (f.prefix_len == 0 and f.prefix_set_n == 0 and f.inner_byte == null and f.req_lit_len == 0) {
        if (an.leading_class_first) |bs| {
            if (classLeadSelective(bs)) {
                f.class_lead = bs;
            } else if (asciiLeadDerived(bs)) |derived| {
                f.class_lead_ascii_only = true; // engage only on ASCII-dominant input (see field doc)
                // A class with a **sparse ASCII lead but a broad Unicode tail** (`\p{Lu}`: A–Z
                // plus uppercase across dozens of scripts). The full first-byte set is too broad
                // (its high lead bytes blanket non-Latin text), but its ASCII members are rare in
                // Latin prose. Scan a SOUND over-approximation — `{ASCII members} ∪ {all high
                // bytes}` — which never skips a real first byte (every match start is one of
                // those). On Latin text this skips the lowercase gaps to the next capital (the
                // win); on non-Latin text every byte is high, so the scan stops at once and the
                // native find runs unchanged (neutral). See `asciiLeadDerived`.
                f.class_lead = derived;
            }
        }
    }

    // 5. Rarest required byte for a presence fast-reject — only when nothing above gives an
    //    actual skip (with a skip the byte is already implied present).
    if (f.prefix_byte == null and f.prefix_set_n == 0 and f.inner_byte == null and f.req_lit_len == 0 and f.class_lead == null and !an.required_bytes.isEmpty()) {
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
    return f;
}

/// One leading position's choice set during case-variant expansion: the code points that may
/// appear there (`[Tt]` → {T,t}; a literal char → a single cp).
const Choice = struct {
    cps: [VARIANT_CLASS_MAX]CodePoint = undefined,
    len: u8 = 0,
};

/// Collect the leading mandatory single-code-point positions of the pattern into `out`,
/// each as its choice set, stopping at the first non-enumerable atom (a class with more than
/// `VARIANT_CLASS_MAX` members, `.`, an alternation, a repetition, an optional) or when `out`
/// fills. Mirrors the `prefixLiteral`/`leadingClassFirst` spine walk (skip leading zero-width
/// anchors; descend capture / `min≥1` repetition bodies). `*count` is advanced as positions
/// are appended; `*stop` latches true once expansion must end. Every appended position is
/// **mandatory** and **complete** (all of its choices), so the cartesian product over
/// `out[0..count]` is a sound necessary prefix of every match.
fn collectChoices(h: hir.Hir, idx: u32, out: []Choice, count: *usize, stop: *bool) void {
    if (stop.*) return;
    const node = h.nodes[idx];
    switch (node.tag) {
        .literal => {
            const run = node.data.run;
            var k: u32 = 0;
            while (k < run.len) : (k += 1) {
                if (count.* >= out.len) {
                    stop.* = true;
                    return;
                }
                out[count.*] = .{ .cps = undefined, .len = 1 };
                out[count.*].cps[0] = h.literals[run.start + k];
                count.* += 1;
            }
        },
        .class => {
            const c = node.data.class;
            const rngs = h.ranges[c.start .. c.start + c.len];
            // Count members; abort if empty (unmatchable) or larger than the per-position cap.
            var total: usize = 0;
            for (rngs) |r| total += @as(usize, r.hi - r.lo) + 1;
            if (total == 0 or total > VARIANT_CLASS_MAX or count.* >= out.len) {
                stop.* = true;
                return;
            }
            var ch = Choice{ .cps = undefined, .len = 0 };
            for (rngs) |r| {
                var cp: CodePoint = r.lo;
                while (cp <= r.hi) : (cp += 1) {
                    ch.cps[ch.len] = cp;
                    ch.len += 1;
                }
            }
            out[count.*] = ch;
            count.* += 1;
        },
        .concat => {
            const d = node.data.children;
            for (h.children[d.start .. d.start + d.len]) |ci| {
                collectChoices(h, ci, out, count, stop);
                if (stop.*) break;
            }
        },
        .capture => collectChoices(h, node.data.capture.child, out, count, stop),
        // A zero-width leading anchor/empty consumes no position; skip it (sound — it adds no
        // bytes). Any other atom (`.`, repetition, alternation, grapheme) ends the prefix.
        .anchor, .empty => {},
        else => stop.* = true,
    }
}

/// Expand the pattern's leading small-class / literal run into a bounded **case-variant
/// prefix set** written to `f.prefix_set`/`f.prefix_set_len`, returning the needle count (0
/// when not worth building). The cartesian product of `collectChoices`'s per-position choice
/// sets, capped at `MAX_PREFIX_BRANCHES` needles and `MAX_PREFIX_LEN` bytes: a position whose
/// inclusion would exceed either cap is dropped (the product of earlier positions is still a
/// sound necessary prefix). Declines a 1-needle product (a pure literal — handled by
/// `prefix_literal`) or one whose shortest needle is below `VARIANT_MIN_LEN` (not selective).
fn caseVariantSet(h: hir.Hir, f: *Filter) u8 {
    var choices: [MAX_PREFIX_LEN]Choice = undefined;
    var nchoices: usize = 0;
    var stop = false;
    collectChoices(h, h.root, &choices, &nchoices, &stop);
    if (nchoices == 0) return 0;

    // Build the product into the filter's needle buffers, position by position.
    var n: usize = 1; // current needle count (starts at one empty needle)
    f.prefix_set[0] = @splat(0);
    f.prefix_set_len[0] = 0;

    for (choices[0..nchoices]) |ch| {
        if (n * ch.len > hir.MAX_PREFIX_BRANCHES) break; // would exceed the needle cap — stop here

        // Pre-encode this position's choices; bail (keep prior product) if any would overrun.
        var enc: [VARIANT_CLASS_MAX][4]u8 = undefined;
        var enc_len: [VARIANT_CLASS_MAX]u8 = undefined;
        var fits = true;
        for (0..ch.len) |ci| {
            if (!encoding.isValidCodePoint(ch.cps[ci])) {
                fits = false;
                break;
            }
            const m = utf8.encodeCodePointUnchecked(ch.cps[ci], &enc[ci]);
            if (m == 0) {
                fits = false;
                break;
            }
            enc_len[ci] = m;
        }
        if (!fits) break;
        // If appending the longest choice to the longest existing needle would overrun, stop.
        var max_add: u8 = 0;
        for (0..ch.len) |ci| max_add = @max(max_add, enc_len[ci]);
        var max_cur: u8 = 0;
        for (0..n) |p| max_cur = @max(max_cur, f.prefix_set_len[p]);
        if (@as(usize, max_cur) + max_add > MAX_PREFIX_LEN) break;

        // Expand: each existing needle × each choice, written into a fresh buffer set.
        var nb: [hir.MAX_PREFIX_BRANCHES][MAX_PREFIX_LEN]u8 = undefined;
        var nl: [hir.MAX_PREFIX_BRANCHES]u8 = undefined;
        var w: usize = 0;
        for (0..n) |p| {
            const plen = f.prefix_set_len[p];
            for (0..ch.len) |ci| {
                nb[w] = @splat(0);
                @memcpy(nb[w][0..plen], f.prefix_set[p][0..plen]);
                @memcpy(nb[w][plen .. plen + enc_len[ci]], enc[ci][0..enc_len[ci]]);
                nl[w] = plen + enc_len[ci];
                w += 1;
            }
        }
        n = w;
        for (0..n) |p| {
            f.prefix_set[p] = nb[p];
            f.prefix_set_len[p] = nl[p];
        }
    }

    if (n < 2) return 0; // a pure literal (or single-choice run) — `prefix_literal` covers it
    var min_len: u8 = 255;
    for (0..n) |p| min_len = @min(min_len, f.prefix_set_len[p]);
    if (min_len < VARIANT_MIN_LEN) return 0; // not selective enough to be worth a prefilter
    return @intCast(n);
}

/// Leading positions of a casei alternation branch fingerprinted by `caseiAlternationSet`. Three
/// is Teddy's selectivity sweet spot (it fingerprints ≤ 3 bytes) and keeps the per-branch needle
/// fan-out small.
const CASEI_WINDOW_LEN: usize = VARIANT_WINDOW_LEN;

/// The byte-string alternatives one leading position may take, after **collapsing ASCII case
/// pairs**: every ASCII letter is reduced to its lowercase canonical (a fold-aware Teddy mask
/// then matches either case), while any non-ASCII / non-letter fold-orbit member (`s`→`ſ`,
/// `k`→KELVIN under simple folding; a literal digit) is kept as its own exact byte sequence.
const PosAlt = struct {
    bytes: [VARIANT_CLASS_MAX][4]u8 = undefined,
    len: [VARIANT_CLASS_MAX]u8 = undefined,
    n: u8 = 0,
    /// True when at least one member was an ASCII letter (so case folding is required to match).
    fold: bool = false,
};

/// Reduce one position's choice set (`collectChoices` orbit) to its `PosAlt` alternatives, or
/// null if a member is unencodable or the dedup'd set would overflow `VARIANT_CLASS_MAX`.
fn positionAlternatives(ch: Choice) ?PosAlt {
    var pa = PosAlt{};
    for (ch.cps[0..ch.len]) |cp| {
        var b: [4]u8 = undefined;
        var blen: u8 = undefined;
        if (cp < 0x80 and ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z'))) {
            b[0] = @as(u8, @intCast(cp)) | 0x20; // lowercase canonical; fold covers the other case
            blen = 1;
            pa.fold = true;
        } else {
            if (!encoding.isValidCodePoint(cp)) return null;
            const m = utf8.encodeCodePointUnchecked(cp, &b);
            if (m == 0) return null;
            blen = m;
        }
        // Dedup (the lowercase canonical collapses `X`/`x` to one entry).
        var dup = false;
        for (0..pa.n) |i| {
            if (pa.len[i] == blen and std.mem.eql(u8, pa.bytes[i][0..blen], b[0..blen])) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            if (pa.n >= VARIANT_CLASS_MAX) return null;
            @memcpy(pa.bytes[pa.n][0..blen], b[0..blen]);
            pa.len[pa.n] = blen;
            pa.n += 1;
        }
    }
    if (pa.n == 0) return null;
    return pa;
}

/// Build a **case-insensitive alternation** prefix set: one (or a few) needle(s) per branch of a
/// top-level `(?i:Sher[a-z]+|Hol[a-z]+)` / `(?i:Sherlock|Holmes|Watson)`, written to
/// `f.prefix_set*` with `f.prefix_set_fold_ascii` set when any branch needs ASCII folding.
///
/// Each branch contributes the canonical bytes of its first ≤ `CASEI_WINDOW_LEN` mandatory
/// positions (`collectChoices` stops at a repetition / optional / alternation / `.`): ASCII
/// letter case-pairs collapse to ONE needle (the fold-aware Teddy masks + verify match either
/// case), and any **non-ASCII** fold-orbit member of a window position (`s`→`ſ`, `k`→KELVIN under
/// simple folding) fans out into an extra needle so the set stays a sound necessary prefix of
/// every match. Returns the total needle count, or 0 to decline (not a casei-ish alternation, a
/// branch shorter than `VARIANT_MIN_LEN`, an unencodable member, or the union exceeds
/// `MAX_PREFIX_BRANCHES`). Only the leading window is stored; the automaton confirm at each Teddy
/// hit enforces the full (Unicode-correct) match — Teddy is purely a candidate generator.
fn caseiAlternationSet(h: hir.Hir, f: *Filter) u8 {
    // Descend a capture wrapper to the alternation (a `(?i:…)` non-capturing group leaves the
    // alternation at the spine; a capturing group wraps it).
    var idx = h.root;
    while (h.nodes[idx].tag == .capture) idx = h.nodes[idx].data.capture.child;
    if (h.nodes[idx].tag != .alternation) return 0;
    const branches = h.nodes[idx].data.children;
    if (branches.len < 2 or branches.len > hir.MAX_PREFIX_BRANCHES) return 0;

    var n: usize = 0; // needles written to f.prefix_set so far
    var any_fold = false;
    for (h.children[branches.start .. branches.start + branches.len]) |ci| {
        // The branch's leading mandatory positions and their fold orbits.
        var choices: [CASEI_WINDOW_LEN]Choice = undefined;
        var nchoices: usize = 0;
        var stop = false;
        collectChoices(h, ci, choices[0..], &nchoices, &stop);
        if (nchoices < VARIANT_MIN_LEN) return 0; // window too short → no selective sound prefix

        // Cartesian product of this branch's per-position alternatives, seeded with one empty
        // needle. ASCII case pairs do not multiply (fold); only non-ASCII members do.
        var bn: [hir.MAX_PREFIX_BRANCHES][MAX_PREFIX_LEN]u8 = undefined;
        var bl: [hir.MAX_PREFIX_BRANCHES]u8 = undefined;
        var bcount: usize = 1;
        bn[0] = @splat(0);
        bl[0] = 0;
        for (choices[0..nchoices]) |ch| {
            const pa = positionAlternatives(ch) orelse return 0;
            any_fold = any_fold or pa.fold;
            if (bcount * pa.n > hir.MAX_PREFIX_BRANCHES) return 0; // branch fan-out over budget
            // Longest current needle + longest alternative must fit MAX_PREFIX_LEN.
            var max_cur: u8 = 0;
            for (0..bcount) |p| max_cur = @max(max_cur, bl[p]);
            var max_add: u8 = 0;
            for (0..pa.n) |a| max_add = @max(max_add, pa.len[a]);
            if (@as(usize, max_cur) + max_add > MAX_PREFIX_LEN) return 0;

            var nb: [hir.MAX_PREFIX_BRANCHES][MAX_PREFIX_LEN]u8 = undefined;
            var nl: [hir.MAX_PREFIX_BRANCHES]u8 = undefined;
            var w: usize = 0;
            for (0..bcount) |p| {
                for (0..pa.n) |a| {
                    nb[w] = @splat(0);
                    @memcpy(nb[w][0..bl[p]], bn[p][0..bl[p]]);
                    @memcpy(nb[w][bl[p] .. bl[p] + pa.len[a]], pa.bytes[a][0..pa.len[a]]);
                    nl[w] = bl[p] + pa.len[a];
                    w += 1;
                }
            }
            bcount = w;
            for (0..bcount) |p| {
                bn[p] = nb[p];
                bl[p] = nl[p];
            }
        }

        // Append this branch's needles to the global set (declining if the union overflows).
        if (n + bcount > hir.MAX_PREFIX_BRANCHES) return 0;
        for (0..bcount) |p| {
            f.prefix_set[n] = bn[p];
            f.prefix_set_len[n] = bl[p];
            n += 1;
        }
    }

    if (n < 2) return 0;
    var min_len: u8 = 255;
    for (0..n) |p| min_len = @min(min_len, f.prefix_set_len[p]);
    if (min_len < VARIANT_MIN_LEN) return 0; // not selective enough to be worth a prefilter
    f.prefix_set_fold_ascii = any_fold;
    return @intCast(n);
}

/// Longest window (in foldable positions) Teddy meaningfully fingerprints — its fingerprint is
/// the first ≤ 3 bytes of each needle, so a 3-byte window is the selectivity sweet spot.
const VARIANT_WINDOW_LEN: usize = 3;

/// Largest offset-range (`off_max - off_min`) tolerated for a rare interior window: each unit is
/// one extra per-hit confirm (a preceding position with a longer-byte case variant, e.g. `s`→`ſ`).
/// Keep it tiny so the rarer window's confirm savings are not eaten by the extra confirms.
const VARIANT_OFFSET_RANGE_MAX: u32 = 2;

/// For a **bounded** case-variant phrase, seed the Teddy prefilter from the **rarest** length-2/3
/// window of leading positions rather than the (often common) leading window — `(?i)sherlock
/// holmes`'s leading `she` occurs ~2× more than the rarer `ck `. Fills `f.prefix_set*` and the
/// `prefix_set_off_min/off_max` range (a Teddy hit at `q` ⇒ candidate start `q - d`, `d` in that
/// range — the range covers variable-length case variants of the preceding positions, `s`→2-byte
/// `ſ`). Returns true on success; false ⇒ the caller falls back to the leading `caseVariantSet`.
/// Rarity is estimated from `memmem.byteFreq` (steers the probe only — every hit is fully
/// confirmed, so the choice never affects which matches are found).
fn caseVariantWindow(h: hir.Hir, f: *Filter) bool {
    var choices: [MAX_PREFIX_LEN]Choice = undefined;
    var nchoices: usize = 0;
    var stop = false;
    collectChoices(h, h.root, &choices, &nchoices, &stop);
    if (nchoices < VARIANT_MIN_LEN) return false;

    // Per-position encoded byte-length min/max (over case variants) and a first-byte frequency
    // sum (Teddy fingerprints leading bytes). Cumulative min/max give each position's byte offset
    // *range* from the match start (variable because a fold variant may be 1 or 2+ bytes).
    var pmin: [MAX_PREFIX_LEN]u32 = undefined;
    var pmax: [MAX_PREFIX_LEN]u32 = undefined;
    var pscore: [MAX_PREFIX_LEN]u32 = undefined;
    var cmin: [MAX_PREFIX_LEN + 1]u32 = undefined;
    var cmax: [MAX_PREFIX_LEN + 1]u32 = undefined;
    cmin[0] = 0;
    cmax[0] = 0;
    for (choices[0..nchoices], 0..) |ch, i| {
        if (ch.len == 0) return false;
        var mn: u32 = 99;
        var mx: u32 = 0;
        var sc: u32 = 0;
        for (0..ch.len) |ci| {
            if (!encoding.isValidCodePoint(ch.cps[ci])) return false;
            var buf: [4]u8 = undefined;
            const m = utf8.encodeCodePointUnchecked(ch.cps[ci], &buf);
            if (m == 0) return false;
            mn = @min(mn, m);
            mx = @max(mx, m);
            sc += memmem.byteFreq(buf[0]);
        }
        pmin[i] = mn;
        pmax[i] = mx;
        pscore[i] = sc;
        cmin[i + 1] = cmin[i] + mn;
        cmax[i + 1] = cmax[i] + mx;
    }

    // Pick the lowest-frequency feasible window: prefer length 3 (Teddy's fingerprint depth),
    // else 2. Feasible = product of variant counts in `[2, MAX_PREFIX_BRANCHES]`, longest needle
    // ≤ MAX_PREFIX_LEN, and the preceding-offset range ≤ VARIANT_OFFSET_RANGE_MAX.
    var best_off: ?usize = null;
    var best_len: usize = 0;
    var best_score: u32 = std.math.maxInt(u32);
    var L: usize = @min(VARIANT_WINDOW_LEN, nchoices);
    while (L >= VARIANT_MIN_LEN) : (L -= 1) {
        var i: usize = 0;
        while (i + L <= nchoices) : (i += 1) {
            if (cmax[i] - cmin[i] > VARIANT_OFFSET_RANGE_MAX) continue; // too many per-hit confirms
            var product: usize = 1;
            var maxneedle: u32 = 0;
            var score: u32 = 0;
            for (i..i + L) |k| {
                product *= choices[k].len;
                maxneedle += pmax[k];
                score += pscore[k];
            }
            if (product < 2 or product > hir.MAX_PREFIX_BRANCHES) continue;
            if (maxneedle > MAX_PREFIX_LEN) continue;
            if (score < best_score) {
                best_score = score;
                best_off = i;
                best_len = L;
            }
        }
        if (best_off != null) break; // a window at this (longest tried) length wins
    }
    const off = best_off orelse return false;

    // Build the cartesian product of the window's positions (each variant encoded to its bytes).
    var n: usize = 1;
    f.prefix_set[0] = @splat(0);
    f.prefix_set_len[0] = 0;
    for (choices[off .. off + best_len]) |ch| {
        var enc: [VARIANT_CLASS_MAX][4]u8 = undefined;
        var enc_len: [VARIANT_CLASS_MAX]u8 = undefined;
        for (0..ch.len) |ci| enc_len[ci] = utf8.encodeCodePointUnchecked(ch.cps[ci], &enc[ci]);
        var nb: [hir.MAX_PREFIX_BRANCHES][MAX_PREFIX_LEN]u8 = undefined;
        var nl: [hir.MAX_PREFIX_BRANCHES]u8 = undefined;
        var w: usize = 0;
        for (0..n) |p| {
            const plen = f.prefix_set_len[p];
            for (0..ch.len) |ci| {
                nb[w] = @splat(0);
                @memcpy(nb[w][0..plen], f.prefix_set[p][0..plen]);
                @memcpy(nb[w][plen .. plen + enc_len[ci]], enc[ci][0..enc_len[ci]]);
                nl[w] = plen + enc_len[ci];
                w += 1;
            }
        }
        n = w;
        for (0..n) |p| {
            f.prefix_set[p] = nb[p];
            f.prefix_set_len[p] = nl[p];
        }
    }
    if (n < 2) return false;
    var min_len: u8 = 255;
    for (0..n) |p| min_len = @min(min_len, f.prefix_set_len[p]);
    if (min_len < VARIANT_MIN_LEN) return false; // not selective enough
    f.prefix_set_n = @intCast(n);
    f.prefix_set_off_min = cmin[off];
    f.prefix_set_off_max = cmax[off];
    return true;
}

/// Whether a leading-class first-byte set is **selective** enough to drive the SIMD class
/// scan. Three sound (corpus-independent) reasons to decline: the set includes whitespace
/// (lands almost everywhere); it includes a swath of ASCII lowercase letters (`[A-Za-z]+`,
/// `\w+`, `\p{L}+` — letter-dense on every corpus); or it spans too many **high** UTF-8 lead
/// bytes (`CLASS_HIGH_LEAD_MAX`), the hallmark of a broad letter class (`\p{Lu}`, `\p{L}`)
/// whose lead bytes blanket non-Latin text. Digit / number / punctuation classes (`\d+`,
/// `\p{N}+`) pass — sparse in all the corpora, so the scan skips real gaps.
fn classLeadSelective(bs: hir.ByteSet) bool {
    if (bs.has(' ') or bs.has('\t') or bs.has('\n') or bs.has('\r')) return false;
    var lower: u32 = 0;
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) if (bs.has(c)) {
        lower += 1;
    };
    if (lower > 4) return false; // a few stray lowercase members are fine; a whole alphabet is not
    var high: u32 = 0;
    var b: u16 = 0x80;
    while (b < 0x100) : (b += 1) if (bs.has(@intCast(b))) {
        high += 1;
    };
    return high <= CLASS_HIGH_LEAD_MAX; // broad letter class (many script lead bytes) → decline
}

/// For a leading class that `classLeadSelective` **declined only for its broad high-byte tail**
/// (`\p{Lu}`: A–Z plus uppercase across dozens of scripts), build a sound over-approximating
/// first-byte set to scan instead: `{the class's ASCII members} ∪ {all bytes ≥ 0x80}`. Returns
/// null when the class is not a fit. Every match begins with a code point in the class, whose
/// first UTF-8 byte is therefore either an ASCII member (a single-byte cp) or a lead byte ≥ 0x80
/// (a multi-byte cp) — both are in the derived set, so scanning to the next member **never skips
/// a real match start** (sound). The payoff is corpus-shaped: on Latin-script text the high bytes
/// are rare, so the scan skips lowercase gaps to the next capital; on non-Latin text every byte
/// is ≥ 0x80, so the scan stops immediately and the caller's native find runs unchanged. Gated to
/// classes whose ASCII portion is genuinely sparse — **non-empty** (an empty ASCII portion, e.g.
/// `\p{Cyrillic}+`/`\p{Han}+`, can never skip and would only add scan overhead), no whitespace,
/// and at most a few stray lowercase letters (a whole lowercase alphabet — `\p{L}+`, `\w+` — is
/// letter-dense on every corpus and stays declined).
fn asciiLeadDerived(bs: hir.ByteSet) ?hir.ByteSet {
    if (bs.has(' ') or bs.has('\t') or bs.has('\n') or bs.has('\r')) return null;
    var lower: u32 = 0;
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) if (bs.has(c)) {
        lower += 1;
    };
    if (lower > 4) return null;
    var ascii_n: u32 = 0;
    var derived = hir.ByteSet{};
    var b: u16 = 0;
    while (b < 0x80) : (b += 1) if (bs.has(@intCast(b))) {
        derived.set(@intCast(b));
        ascii_n += 1;
    };
    if (ascii_n == 0) return null; // empty ASCII lead → nothing to skip to (pure non-ASCII script)
    b = 0x80;
    while (b < 0x100) : (b += 1) derived.set(@intCast(b)); // every high byte is a candidate (sound)
    return derived;
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
    /// SIMD **multi-prefix** accelerator (Teddy) for `filter.prefix_set`: the leftmost
    /// occurrence of any prefix needle in one vectorised pass, replacing the per-needle
    /// `multiPrefixFrom` scan. Built (at runtime, native-shuffle target, `simd != .off`)
    /// for any `prefix_set_n ≥ 2` — both a top-level alternation's leading literals
    /// (`Holmes…|Watson…`) and a synthesised case-variant set (`(?i)the` → {THE,…,the}).
    /// Null on the comptime path / non-native target / `.off` → the scalar `multiPrefixFrom`.
    /// Results-invariant (same leftmost candidate; the engine confirms either way).
    ///
    /// @stable-since: v0.4.0
    prefix_teddy: ?teddy.Teddy = null,
    /// SIMD **leading-class** accelerator for `filter.class_lead`: scan to the next byte in
    /// the leading class's first-byte set (`classscan.ClassFinder`). Built in BOTH
    /// `buildAlloc` and `buildComptime` (POD, no `@Vector` in construction; `find` routes
    /// comptime / non-native to its scalar scan), so the class-led start-skip works on every
    /// path. Null when `filter.class_lead` is null. Results-invariant.
    ///
    /// @stable-since: v0.4.0
    class_finder: ?classscan.ClassFinder = null,
};

/// Build the `prefix_teddy` accelerator for the program's `prefix_set`, or `.none`/null.
/// Runtime only (the dynamic shuffle is asm; comptime keeps the scalar `multiPrefixFrom`).
/// Declines when SIMD is off, the target has no native shuffle, or the set is empty. A
/// slim 8-bucket Teddy suffices — `prefix_set_n ≤ MAX_PREFIX_BRANCHES (8)`.
fn buildPrefixTeddy(gpa: std.mem.Allocator, f: *const Filter, opts: Options) BuildError!?teddy.Teddy {
    if (opts.simd == .off) return null;
    if (comptime !simd.has_native_shuffle16) return null;
    if (f.prefix_set_n < 2) return null;
    var slices: [hir.MAX_PREFIX_BRANCHES][]const u8 = undefined;
    var k: usize = 0;
    while (k < f.prefix_set_n) : (k += 1) {
        if (f.prefix_set_len[k] == 0) return null; // an empty needle matches everywhere — decline
        slices[k] = f.prefix_set[k][0..f.prefix_set_len[k]];
    }
    return try teddy.compileFoldAlloc(gpa, slices[0..f.prefix_set_n], f.prefix_set_fold_ascii);
}

/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, opts: Options) BuildError!Program {
    if (literal.supports(h)) {
        return .{ .inner = .{ .literal = try literal.buildAlloc(gpa, h, .{ .simd = opts.simd }) } };
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
        // Only ATTEMPT the eager DFA when the byte NFA is small enough that determinization is
        // cheap (`EAGER_BYTE_INST_MAX`). Eager determinization is a full subset construction whose
        // cost scales with (states × byte_insts); for a big Unicode class joined/repeated
        // (`\w+@\w+`, `[\w.+-]+@…`) it costs hundreds of ms — and an over-`max_states` pattern like
        // email burns ~900ms only to DECLINE and use the lazy DFA anyway. Above the gate we skip
        // straight to the lazy DFA (same states on demand, amortized over the input) — a large
        // compile-time win and, for the declining cases, no runtime change at all.
        const eager_small_enough = (byte.instCount(h) orelse 0) <= EAGER_BYTE_INST_MAX;
        // A start-skip prefilter (leading literal / alternation / interior anchor) drives the find
        // for a *prone* pattern, so the eager DFA's reverse table would be wasted build work — tell
        // `edfa` to decline a prone pattern early and let the lazy DFA serve it (the user's cascade:
        // edfa → lazy when the eager build is not worth it). `the\s+\p{L}+`: ~10 ms → <1 ms compile,
        // search unchanged (prefilter-driven either way). Results-invariant.
        const has_start_skip = program.filter.prefix_len > 0 or program.filter.prefix_set_n > 0 or program.filter.inner_byte != null;
        const eager: BuildError!edfa.Program = if (eager_small_enough) edfa.buildAlloc(gpa, h, .{ .decline_if_prone = has_start_skip }) else error.Unsupported;
        if (eager) |ep| {
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
            else => { // eager DFA declined (overflowed its bounds) OR was skipped (too big to
                // determinize cheaply) — fall back to the lazy DFA when IT can run the pattern. The
                // lazy DFA covers anchored-end `$`/`\z` (reverse-from-end), so a too-big trailing-`$`
                // pattern stays on the DFA arm; a mixed `$`, `\b`/`\X`, a *prone* `(?m)` line pattern,
                // or a too-big `(?m)` (the lazy DFA declines line anchors) lands on the NFA arm.
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
    // SIMD prefilter accelerators distilled from the filter: a multi-prefix Teddy (alternation
    // or case-variant set) and a leading-class scanner. Both are sound, results-invariant
    // skips; declining either just keeps the scalar `multiPrefixFrom` / `class_lead` scan.
    program.prefix_teddy = try buildPrefixTeddy(gpa, &program.filter, opts);
    errdefer if (program.prefix_teddy) |*t| teddy.free(gpa, t);
    if (program.filter.class_lead) |bs| program.class_finder = classscan.ClassFinder.init(bs.bits);
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
    // The leading-class scanner is POD (no `@Vector` to build) and `find` is comptime-safe, so
    // it works on the comptime path; the multi-prefix Teddy is runtime-only (asm shuffle) and
    // stays null here — the case-variant / alternation skip uses the scalar `multiPrefixFrom`.
    if (program.filter.class_lead) |bs| program.class_finder = classscan.ClassFinder.init(bs.bits);
    return program;
}

/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    if (program.edfa_prog) |*e| edfa.freeProgram(gpa, e);
    if (program.dfa_prog) |*d| dfa.freeProgram(gpa, d);
    if (program.onepass_prog) |*op| onepass.freeProgram(gpa, op);
    if (program.prefix_teddy) |*t| teddy.free(gpa, t);
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
    /// `memmem` start-skip confirms anchored at each occurrence of the whole prefix run; for a
    /// `prone`/`end_anchored` program that confirm can scan an unbounded run, so doing it
    /// per occurrence is Θ(n²) — the fix routes those programs to the DFA's O(n) native
    /// find instead, and this counter therefore stays **0** for them. A non-zero value on a
    /// `prone`/`end_anchored` program is exactly the quadratic regression; `engine/redos.zig`
    /// asserts it is 0 (a revert-failing guard). Bounded by the prefix-run occurrence count
    /// for the fast-confirm case (`foo\d+` — once per "foo", not per 'f'). Observational only —
    /// never affects a result, never read by matching. Accumulates across searches on the scratch;
    /// `reset` zeroes it.
    ///
    /// @stable-since: v0.3.1
    confirm_probes: u64 = 0,

    /// Total input bytes the **lazy-DFA arm's** leading-literal / interior-anchor jump-and-confirm
    /// loop (`runByteDfa`) has scanned across its anchored confirms on this scratch. Unlike the
    /// eager arm's `confirm_probes` (which is 0 for a prone program — it uses the native find), the
    /// lazy arm *does* confirm per occurrence for a prone program, kept linear by a `reach` budget:
    /// once cumulative confirm work overruns ~2×input the loop hands off to the O(input) native find,
    /// so this counter is bounded **linearly** in input size. `engine/redos.zig` asserts that linear
    /// scaling (revert the budget → a quadratic pattern's confirms scan ~n² bytes → the test fails).
    /// Observational only — never affects a result. Accumulates across searches; `reset` zeroes it.
    ///
    /// @stable-since: v0.6.0
    lazy_confirm_bytes: u64 = 0,

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

    /// Cached **ASCII-dominant** verdict for the derived leading-class scan (`class_lead_ascii_only`):
    /// true when fewer than `1/ASCII_DOMINANT_DIV` of the input's bytes are ≥ 0x80, i.e. high bytes
    /// are rare enough that the `{ASCII members} ∪ {all high bytes}` scan still skips the long
    /// ASCII gaps. Distinct from `wb_all_ascii` (strict, early-exit) because Latin prose is rarely
    /// *pure* ASCII (a stray accent / curly quote) yet is overwhelmingly ASCII — a strict gate would
    /// forfeit the skip on real text. O(n) to compute (a full count), so cached on the input slice
    /// like `wb_*`; consulted only by a `class_lead_ascii_only` program. `reset` clears it.
    ///
    /// @stable-since: v0.6.0
    ad_input_ptr: ?[*]const u8 = null,
    ad_input_len: usize = 0,
    ad_dominant: bool = false,

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
        self.lazy_confirm_bytes = 0; // the lazy-arm jump-confirm observable, likewise per-reuse
        self.wb_input_ptr = null; // invalidate the input-ASCII cache (a new search may use a new input)
        self.ad_input_ptr = null; // invalidate the ASCII-dominant cache (likewise input-keyed)
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

/// First byte offset `≥ start` at which `needle` occurs in `input`, or null — the prefilter's
/// **multi-byte** start-skip primitive (a generalisation of `memchrFrom` that leaps literal-to-
/// literal instead of byte-to-byte). For a needle of two or more bytes this is the portable
/// **two-byte** SIMD filter (`memmem.Finder`): it AND-s the SIMD equality masks of the needle's
/// two rarest bytes and only verifies the whole run where both coincide — far fewer candidates
/// than scanning the single rarest byte (the prefilter sees "the"/"http"/"foo"-sized needles,
/// where one common lead byte leaves a candidate almost everywhere).
///
/// We deliberately do **NOT** call `std.mem.indexOfPos`: it falls back to a *non-SIMD* linear
/// scan for needles `≤ 4` bytes (`std.mem.findPos`) — exactly the sizes here. A one-byte needle
/// is exactly `memchrFrom`; an empty needle matches at `start`. Comptime routes to the scalar
/// fallback (`Finder.find` handles `@inComptime()` internally — no `@Vector` in const-eval).
///
/// @stable-since: v0.4.0
/// Byte offset `n` **code points** before `q` in (valid-UTF-8) `input`, or null when fewer than
/// `n` code points precede `q`. Steps back over UTF-8 continuation bytes (`0x80..0xBF`) so each
/// iteration lands on a code-point boundary — exact for ASCII (`q - n`) and multi-byte alike. Used
/// by the fixed-offset required-literal confirm to pin a match start a fixed *code-point* distance
/// before a literal hit without assuming the leading run is ASCII (the byte distance varies).
/// Comptime-safe (plain scalar loop).
fn cpBack(input: []const u8, q: usize, n: u32) ?usize {
    var p = q;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        if (p == 0) return null;
        p -= 1;
        while (p > 0 and (input[p] & 0xC0) == 0x80) p -= 1; // step into the lead byte of this cp
    }
    return p;
}

fn memmemFrom(input: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (start <= input.len) start else null;
    if (needle.len == 1) return memchrFrom(input, start, needle[0]);
    const f = memmem.Finder.init(needle);
    return f.find(input, start);
}

/// ASCII case fold of one byte (`A`–`Z` → `a`–`z`); leaves every other byte — including all
/// UTF-8 lead/continuation bytes (`>= 0x80`) — untouched.
inline fn asciiLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b | 0x20 else b;
}

/// Leftmost offset `≥ start` at which `needle` occurs under **ASCII case folding**, or null.
/// The scalar fallback for a case-insensitive multi-prefix set when no native Teddy was built
/// (comptime / non-native target). Plain O(input × needle); the needles are short and few.
fn caseiFindFrom(input: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (start <= input.len) start else null;
    if (input.len < needle.len) return null;
    var i = start;
    const last = input.len - needle.len;
    while (i <= last) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len and asciiLower(input[i + k]) == asciiLower(needle[k])) : (k += 1) {}
        if (k == needle.len) return i;
    }
    return null;
}

/// Leftmost offset `≥ start` at which **any** of the multi-prefix needles occurs, or null.
/// The sound multi-prefix start-skip (`Holmes…|Watson…`): every match begins with one of the
/// branches' leading literals, so no match can begin before the earliest occurrence of any of
/// them. Each needle uses the two-byte SIMD `memmem` (or memchr for a one-byte needle); the
/// minimum over needles is the leftmost. A handful of needles, scanned once per `find`.
fn multiPrefixFrom(filter: *const Filter, input: []const u8, start: usize) ?usize {
    var best: ?usize = null;
    var i: usize = 0;
    while (i < filter.prefix_set_n) : (i += 1) {
        const needle = filter.prefix_set[i][0..filter.prefix_set_len[i]];
        const at = (if (filter.prefix_set_fold_ascii)
            caseiFindFrom(input, start, needle)
        else
            memmemFrom(input, start, needle)) orelse continue;
        if (best == null or at < best.?) best = at;
        if (best == start) break; // nothing can be earlier than the search start
    }
    return best;
}

/// Leftmost offset `≥ start` of any multi-prefix needle, via the SIMD Teddy when one was
/// built (one vectorised pass over all needles), else the scalar `multiPrefixFrom` (per-needle
/// `memmem`; the comptime / non-native / `.off` path). Same leftmost result either way.
fn nextPrefixHit(filter: *const Filter, tdy: ?*const teddy.Teddy, input: []const u8, start: usize) ?usize {
    if (tdy) |t| return if (t.find(input, start)) |m| m.start else null;
    return multiPrefixFrom(filter, input, start);
}

/// Interior-anchor start-skip: leap to the next anchor byte `≥ start`, then walk **back**
/// over the lead class to the earliest position a match could begin, and return that. Null
/// when the anchor byte is absent (no match can exist). Sound: every match contains the
/// anchor byte, and (because the byte sits right after a `lead_class+` run) no match begins
/// before the reverse-scanned run start — so an unanchored scan from there finds the same
/// leftmost match. Linear: the memchr leaps anchor-to-anchor, the reverse scan is bounded by
/// the run it walks.
fn innerSkipFrom(filter: *const Filter, input: []const u8, start: usize) ?usize {
    const anchor = filter.inner_byte.?;
    const p = memchrFrom(input, start, anchor) orelse return null;
    var cs = p;
    while (cs > start and filter.inner_lead.has(input[cs - 1])) cs -= 1;
    return cs;
}

/// Required-literal start-skip (the general `\w+\s+Holmes` / `[a-zA-Z]+ing` form of
/// `innerSkipFrom`): memmem to the next occurrence of the whole required literal `≥ start`, then
/// walk **back** over `req_lead` to the earliest position a match could begin, and return that.
/// Null when the literal is absent (no match can exist). Sound: every match contains the literal
/// (it is on the mandatory spine), and `req_lead` is a superset of the bytes that may precede it,
/// so no match begins before the reverse-scanned start. Linear: the memmem leaps literal-to-
/// literal, the reverse scan is bounded by the run it walks, then one unanchored pass follows.
fn reqLitSkipFrom(filter: *const Filter, input: []const u8, start: usize) ?usize {
    const needle = filter.req_lit[0..filter.req_lit_len];
    const p = memmemFrom(input, start, needle) orelse return null;
    var cs = p;
    while (cs > start and filter.req_lead.has(input[cs - 1])) cs -= 1;
    return cs;
}

/// Outcome of the structured reverse walk at a literal hit `q` (see `structuredStart`).
const WalkResult = union(enum) {
    /// The pre-atom structure cannot be satisfied before `q` (a real ASCII boundary) — no match
    /// can use this occurrence; skip it.
    skip,
    /// The exact match start (the walk stayed within pure ASCII, so it is precise).
    exact: usize,
    /// A non-ASCII byte was hit inside the pre-region, so the byte walk cannot be trusted (a
    /// multi-byte code point may belong to a class) — the caller must fall back to a sound scan.
    impure,
};

/// Structured reverse walk: from a literal hit at `q`, consume each pre-atom's class backward in
/// **reverse spine order**, greedily within `[min, max]`. Disjoint adjacency (guaranteed by the
/// builder over ASCII) makes the split unambiguous, so the walk lands on the **exact** match start.
/// Returns `.exact` on a clean ASCII walk, `.skip` when an atom's `min` cannot be met (no match
/// here), or `.impure` when a byte `≥ 0x80` is met (the walk would be unsound — fall back).
fn structuredStart(filter: *const Filter, input: []const u8, q: usize, lo: usize) WalkResult {
    var p = q;
    var i: usize = filter.req_pre_n;
    while (i > 0) {
        i -= 1;
        const cls = filter.req_pre[i];
        const mn = filter.req_pre_min[i];
        const mx = filter.req_pre_max[i];
        var cnt: u32 = 0;
        while (p > lo and cnt < mx) {
            const bb = input[p - 1];
            if (bb >= 0x80) return .impure; // multi-byte cp may belong to this class — can't byte-walk
            if (!cls.has(bb)) break; // ASCII boundary: this atom is done
            p -= 1;
            cnt += 1;
        }
        if (cnt < mn) return .skip; // atom's min unmet → no match uses this occurrence
    }
    // The leading atom may still extend into a preceding high byte (a multi-byte word char) — impure.
    if (p > lo and input[p - 1] >= 0x80) return .impure;
    return .{ .exact = p };
}

/// Flat reverse-scan lower bound for the impure fallback: walk back over `req_lead` (the sound
/// superset alphabet) from `q` to the earliest position a match could begin. A sound lower bound
/// (`≤` the true start), so a bounded confirm sweep `[lb, q]` cannot miss the match.
fn reqFlatLowerBound(filter: *const Filter, input: []const u8, q: usize, lo: usize) usize {
    var cs = q;
    while (cs > lo and filter.req_lead.has(input[cs - 1])) cs -= 1;
    return cs;
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
    // No capture groups ⇒ the DFA span IS the entire answer (slots are just group 0). Fill it
    // directly and skip the capturing engine — the win for `replace`/`captures` on a group-less
    // pattern (`\d+`, `\w+`), which would otherwise pay a Pike VM pass per match just to re-derive
    // the span the DFA already found. Results-identical (group 0 = the match span).
    if (p.slot_count <= 2) {
        if (slots.len >= 2) {
            slots[0] = m.start;
            slots[1] = m.end;
        }
        return m;
    }
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
fn runNfa(p: *const nfa.Program, filter: *const Filter, tdy: ?*const teddy.Teddy, cf: ?*const classscan.ClassFinder, s: *Scratch.NfaScratch, input: []const u8, opts: SearchOptions, slots: ?[]?usize, has_grapheme: bool) ?Match {
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

    // Leading-literal memmem start-skip: every match begins with the `prefix` run, so no match
    // begins before its first occurrence — skip straight to it with one SIMD `memmem` (`\bthe\b`
    // leaps "the"→"the", not 't'→'t'). We deliberately do NOT confirm at *each* occurrence: a
    // per-occurrence anchored confirm is O(match-attempt), and on a begin-but-don't-complete
    // pattern with a dense prefix (`\ba+b` on `aaaa…a!`) that makes the loop **Θ(n²)**. The Pike
    // VM's unanchored `dispatch` is a single linear O(input×program) pass, so one leading skip +
    // dispatch stays leftmost-first AND linear. (The eager-DFA arm keeps the per-occurrence
    // memmem-jump where its `prone`/`end_anchored` flags prove confirms fail fast; the NFA arm has
    // no such flag, so it always takes the linear unanchored scan.)
    var o = opts;
    if (filter.prefix_len > 0) {
        o.start = memmemFrom(input, o.start, filter.prefix[0..filter.prefix_len]) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.prefix_set_n > 0) {
        // Multi-prefix skip (`Holmes…|Watson…`). With a BOUNDED match length, confirm anchored
        // at every prefix occurrence (each fails within ~max_len) — O(occurrences × max_len) =
        // O(input), and it avoids re-scanning the sparse gaps. Otherwise one skip + a single
        // linear unanchored dispatch (unbounded confirms could be Θ(n²)).
        if (filter.bounded_confirm) {
            var pos = o.start;
            while (nextPrefixHit(filter, tdy, input, pos)) |hit| {
                pos = hit + 1;
                var d = filter.prefix_set_off_max; // largest d = leftmost candidate, tried first
                while (d + 1 > filter.prefix_set_off_min) : (d -= 1) {
                    if (d <= hit) {
                        const cand = hit - d;
                        if (cand >= o.start and input.len - cand >= filter.min_bytes) {
                            if (confirmAt(p, s, input, cand, slots)) |m| return m;
                        }
                    }
                    if (d == 0) break;
                }
            }
            return null;
        }
        o.start = nextPrefixHit(filter, tdy, input, o.start) orelse return null;
        o.start -|= filter.prefix_set_off_max;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.req_lit_len > 0) {
        // Required interior/suffix-literal skip (`\w+\s+Holmes`, `[a-zA-Z]+ing`): leap to the next
        // occurrence of the whole literal via memmem, reverse-scan over the preceding alphabet to
        // the earliest match start, then one linear dispatch from there. Sound + O(input) (single
        // skip, never a per-occurrence confirm loop — same Θ(n²) hazard avoidance as the prefix arm).
        o.start = reqLitSkipFrom(filter, input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.inner_byte != null) {
        // Interior-anchor skip (`[\w.+-]+@…`): leap to the next anchor byte, reverse-scan to
        // the earliest run start, then one linear dispatch from there. Sound + O(input).
        o.start = innerSkipFrom(filter, input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (cf) |c| {
        // Leading-class scan (`\d+`, `\p{N}+`): SIMD-skip to the next byte that could begin a
        // match (a member of the leading class's first-byte set), then one linear dispatch. The
        // skipped-to byte starts a class run, so the unanchored scan finds the leftmost match at
        // or after it. Sound + O(input) (single skip, never a per-occurrence confirm loop).
        // (A *derived* broad-tail `class_lead` never reaches the Pike VM arm — such patterns are
        // DFA-eligible and route to `runEdfa`/`runByteDfa`, which gate it on ASCII input.)
        o.start = c.find(input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.rare_byte) |rb| {
        // Rarest-required-byte fast-reject: `rare_byte` appears in EVERY match, so if it is
        // absent there is no match — return at once. Sound (one-sided).
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
/// leading-literal SIMD `memmem` start-skip — before running the DFA, so opting the DFA in
/// is never slower than the default on prefix-literal / sparse-hit patterns. With no
/// usable filter it runs one DFA pass (one-pass O(n) for `isMatch`, anchored-restart
/// for `find`). Captures never come here — they always use the Pike VM (`runNfa`).
fn runByteDfa(dp: *const dfa.Program, filter: *const Filter, tdy: ?*const teddy.Teddy, cf: ?*const classscan.ClassFinder, d: *dfa.Scratch, input: []const u8, opts: SearchOptions, match_only: bool, input_ascii: bool, ascii_dominant: bool, lazy_bytes: *u64) ?Match {
    if (opts.start > input.len) return null;
    if (input.len - opts.start < filter.min_bytes) return null; // length gate
    if (opts.anchored) return dfaConfirmAt(dp, d, input, opts.start, match_only);
    if (filter.anchored_start) {
        if (opts.start != 0) return null;
        return dfaConfirmAt(dp, d, input, 0, match_only);
    }
    // Leading-literal start-skip (single SIMD memmem, then the lazy DFA's own O(input) reverse-DFA
    // find) — NOT a per-occurrence anchored-confirm loop, which would be Θ(n²) on a
    // begin-but-don't-complete dense-prefix input (same hazard as `runEdfa`). The lazy DFA's
    // native `find` is already O(input) (reverse DFA; `has_text_start` short-circuits via
    // `anchored_start` above), so one leading skip + native find is leftmost-first and linear.
    var o = opts;
    if (filter.prefix_len > 0) {
        const pfx = filter.prefix[0..filter.prefix_len];
        if (filter.lit_wb_confirm) {
            // `\b`-wrapped pure literal on the lazy `\b` arm (non-ASCII input, e.g. `\bthe\b` over
            // prose with accents): jump literal-to-literal and confirm with a **Unicode** word-boundary
            // check (O(1) per hit) — bypasses the lazy DFA's decode-hybrid anchored-restart find. The
            // memmem hit already confirms the literal, so `[hit, hit+prefix_len]` is the match iff the
            // boundary checks hold. No automaton walk, no ReDoS surface (the literal is the whole match).
            const finder: ?memmem.Finder = if (filter.prefix_len >= 2) memmem.Finder.init(pfx) else null;
            var pos = o.start;
            while (if (finder) |*fd| fd.find(input, pos) else memchrFrom(input, pos, pfx[0])) |hit| {
                if (input.len - hit < filter.min_bytes) return null;
                if (litWbHoldsU(filter, input, hit, filter.prefix_len))
                    return Match{ .start = hit, .end = hit + filter.prefix_len };
                pos = hit + 1;
            }
            return null;
        }
        // Repeated jump-and-confirm: leap literal-to-literal (SIMD `memmem`) and confirm anchored
        // at each occurrence, instead of one skip + a full native DFA pass. The win when the literal
        // is selective (`the\s+\p{L}+` over prose: most hits either match or fail in a few bytes, so
        // the confirms touch far fewer bytes than a whole-input forward+reverse pass). A `reach`
        // budget keeps it **provably linear**: this arm serves *prone* patterns (an unbounded
        // non-accepting run before accept, e.g. the `\s+` in `the\s+…`), where one confirm can walk
        // far; once cumulative confirm work overruns ~2×input we abandon the loop and hand the
        // remainder to the native `find` (already O(input): reverse-DFA two-pass). Sound: the pattern
        // begins with `pfx`, so every match starts at a literal occurrence; all occurrences before
        // `pos` were confirmed not to start a match, so a native find from `pos` is still leftmost.
        // `\b` programs are excluded (the lazy `\b` arm needs the decode-hybrid restart, not the
        // boundary-blind `confirmReach`); they keep the single-skip + native path below.
        if (!dp.has_word_boundary) {
            const finder: ?memmem.Finder = if (filter.prefix_len >= 2) memmem.Finder.init(pfx) else null;
            var budget: isize = @intCast(2 *| input.len + 64);
            var pos = o.start;
            while (if (finder) |*fd| fd.find(input, pos) else memchrFrom(input, pos, pfx[0])) |hit| {
                if (input.len - hit < filter.min_bytes) return null;
                const c = dfa.confirmReach(dp, d, input, hit, match_only);
                lazy_bytes.* += c.reach - hit + 1;
                if (c.end) |end|
                    return Match{ .start = if (match_only) opts.start else hit, .end = if (match_only) opts.start else end };
                budget -= @as(isize, @intCast(c.reach - hit + 1));
                pos = hit + 1;
                if (budget < 0) {
                    o.start = pos; // prefilter proved ineffective → one native O(input) find for the rest
                    break;
                }
            } else return null; // no more literal occurrences ⇒ no match
        } else {
            o.start = memmemFrom(input, o.start, pfx) orelse return null;
            if (input.len - o.start < filter.min_bytes) return null;
        }
    } else if (filter.prefix_set_n > 0) {
        // Multi-prefix: per-occurrence anchored confirm when bounded (the real win), else one
        // skip + a single native DFA find. See `runNfa` for the bound's soundness.
        if (filter.bounded_confirm) {
            var pos = opts.start;
            while (nextPrefixHit(filter, tdy, input, pos)) |hit| {
                pos = hit + 1;
                var dd = filter.prefix_set_off_max; // largest d = leftmost candidate, tried first
                while (dd + 1 > filter.prefix_set_off_min) : (dd -= 1) {
                    if (dd <= hit) {
                        const cand = hit - dd;
                        if (cand >= opts.start and input.len - cand >= filter.min_bytes) {
                            if (dfaConfirmAt(dp, d, input, cand, match_only)) |m| return m;
                        }
                    }
                    if (dd == 0) break;
                }
            }
            return null;
        }
        o.start = nextPrefixHit(filter, tdy, input, o.start) orelse return null;
        o.start -|= filter.prefix_set_off_max;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.req_lit_len > 0) {
        // Structured reverse-walk fast path (`\w+\s+Holmes`, `\w+\s+Holmes\s+\w+`): per memmem hit,
        // walk the disjoint pre-atom classes backward to the EXACT start, then one anchored confirm —
        // the automaton runs only at real candidate starts, not over the gaps. Exact only over ASCII;
        // engage on ASCII-dominant input and verify each window is pure-ASCII, with a sound flat-scan
        // sweep fallback for the rare non-ASCII window. See `Filter.req_pre`.
        if (filter.req_pre_n > 0 and ascii_dominant) {
            const needle = filter.req_lit[0..filter.req_lit_len];
            var pos = o.start;
            while (memmemFrom(input, pos, needle)) |q| {
                pos = q + 1;
                switch (structuredStart(filter, input, q, o.start)) {
                    .skip => {},
                    .exact => |cand| {
                        if (input.len - cand >= filter.min_bytes)
                            if (dfaConfirmAt(dp, d, input, cand, match_only)) |m| return m;
                    },
                    .impure => {
                        var s = reqFlatLowerBound(filter, input, q, o.start);
                        while (s <= q) : (s += 1) {
                            if (input.len - s < filter.min_bytes) break;
                            if (dfaConfirmAt(dp, d, input, s, match_only)) |m| return m;
                        }
                    },
                }
            }
            return null;
        }
        // Required interior/suffix-literal skip (`\w+\s+Holmes`, `[a-zA-Z]+ing`): memmem to the
        // literal, reverse-scan over the preceding alphabet to the earliest match start, then ONE
        // native (unanchored) DFA find from there. We deliberately do NOT do a per-occurrence
        // *anchored* confirm here (unlike the `inner_byte`/`prefix_set` arms): `req_lead` is only a
        // superset of the preceding alphabet, so the reverse scan can over-reach to a position the
        // match does not start at (`\w+\s+Holmes` over "ab cd Holmes" → cs='a', but the match is
        // "cd Holmes"); only an unanchored forward find from cs is leftmost-correct. Sound + O(input)
        // (single skip + the lazy DFA's O(input) reverse find).
        if (filter.req_lit_fixed_off) |off| {
            // Pass 2 — fixed-offset rare-byte confirm (`[a-q][^u-z]{13}x`): the rare literal byte sits
            // a fixed *code-point* distance `off` from the match start in a bounded fixed-length match.
            // memchr the byte at `q`, walk back `off` code points (UTF-8 aware — exact on any input),
            // and confirm anchored at that pinned start, one confirm per occurrence — far fewer than
            // scanning the dense leading class. Leftmost-first (q ascending) + O(input).
            const b = filter.req_lit[0];
            var pos = o.start;
            while (memchrFrom(input, pos, b)) |q| {
                pos = q + 1;
                const cand = cpBack(input, q, off) orelse continue;
                if (cand < o.start) continue;
                if (input.len - cand < filter.min_bytes) return null;
                if (dfaConfirmAt(dp, d, input, cand, match_only)) |m| return m;
            }
            return null;
        }
        o.start = reqLitSkipFrom(filter, input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.inner_byte) |anchor| {
        // Fixed-offset interior anchor on ASCII input (`\d{4}-…` too big for the eager DFA): jump
        // anchor-to-anchor, bounded-confirm at `q - off` (one per occurrence). See `runEdfa`.
        if (input_ascii and filter.bounded_confirm) {
            if (filter.inner_fixed_off) |off| {
                var pos = o.start;
                while (memchrFrom(input, pos, anchor)) |q| {
                    pos = q + 1;
                    if (q < off) continue;
                    const cand = q - off;
                    if (cand < o.start) continue;
                    if (input.len - cand < filter.min_bytes) return null;
                    if (dfaConfirmAt(dp, d, input, cand, match_only)) |m| return m;
                }
                return null;
            }
        }
        // Variable / non-ASCII interior anchor (`[\w.+-]+@…`): jump anchor-to-anchor (`memchr`),
        // reverse-scan each `@` to its `[\w.+-]` run start, and confirm anchored there — instead of
        // one skip + a full native pass. The win when the anchor is rare (`@` in logs: the `memchr`
        // leaps over most of the file, and few confirms run). Leftmost-first: a run start `cs` is
        // strictly increasing across anchors (`@ ∉ [\w.+-]`, so each reverse-scan stays past the
        // previous anchor), so the first confirmed anchor yields the leftmost match. The same `reach`
        // budget as the leading-literal arm keeps it linear (a greedy variable run before the anchor
        // can make one confirm walk far); on overrun, hand the rest to the native O(input) find.
        // `\b` programs keep the single-skip + decode-hybrid path. Gated on a **rare** anchor: a
        // common anchor (`.` in logs: IPs/decimals) recurs at nearly every byte, so jumping
        // anchor-to-anchor would confirm almost everywhere — slower than one skip + a native pass.
        // The byte-frequency heuristic (speed-only, never affects the result) admits only a selective
        // anchor (`@`, freq 25); a common one (`.`, freq 90) keeps the single-skip path below.
        if (!dp.has_word_boundary and memmem.byteFreq(anchor) <= INNER_ANCHOR_RARE_MAX) {
            var budget: isize = @intCast(2 *| input.len + 64);
            var pos = o.start;
            while (memchrFrom(input, pos, anchor)) |q| {
                pos = q + 1;
                var cs = q;
                while (cs > o.start and filter.inner_lead.has(input[cs - 1])) cs -= 1;
                if (input.len - cs < filter.min_bytes) return null; // cs only grows ⇒ no later fit
                const c = dfa.confirmReach(dp, d, input, cs, match_only);
                lazy_bytes.* += c.reach - cs + 1;
                if (c.end) |end|
                    return Match{ .start = if (match_only) opts.start else cs, .end = if (match_only) opts.start else end };
                budget -= @as(isize, @intCast(c.reach - cs + 1));
                if (budget < 0) {
                    o.start = pos; // prefilter proved ineffective → one native O(input) find for the rest
                    break;
                }
            } else return null; // no more anchors ⇒ no match
        } else {
            o.start = innerSkipFrom(filter, input, o.start) orelse return null;
            if (input.len - o.start < filter.min_bytes) return null;
        }
    } else if (cf) |c| {
        // Leading-class SIMD skip → one native DFA find from the first candidate (sound; see runNfa).
        // A *derived* (broad-tail) set engages only on ASCII-dominant input (see `runEdfa`).
        if (!(filter.class_lead_ascii_only and !ascii_dominant)) {
            o.start = c.find(input, o.start) orelse return null;
            if (input.len - o.start < filter.min_bytes) return null;
        }
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
/// (length gate, `anchored_start` short-circuit, leading-literal SIMD `memmem` start-skip,
/// rarest-required-byte fast-reject) in front of the frozen-table walk. The eager DFA is
/// stateless; the only state is `probes`, the ReDoS observable (`Scratch.confirm_probes`)
/// incremented per per-occurrence confirm. Captures never come here — they always use the Pike VM.
fn runEdfa(ep: *const edfa.Program, filter: *const Filter, tdy: ?*const teddy.Teddy, cf: ?*const classscan.ClassFinder, input: []const u8, opts: SearchOptions, match_only: bool, input_ascii: bool, ascii_dominant: bool, probes: *u64) ?Match {
    if (opts.start > input.len) return null;
    if (input.len - opts.start < filter.min_bytes) return null; // length gate
    if (opts.anchored) return edfaConfirmAt(ep, input, opts.start, match_only);
    if (filter.anchored_start) {
        if (opts.start != 0) return null;
        return edfaConfirmAt(ep, input, 0, match_only);
    }
    var o = opts;
    if (filter.prefix_len > 0) {
        const pfx = filter.prefix[0..filter.prefix_len];
        // The leading-literal SIMD `memmem` start-skip confirms anchored at each occurrence of the
        // whole `prefix` run (`\bthe\b` jumps "the"→"the", not 't'→'t' — strictly fewer confirms).
        // Each confirm is O(match-attempt); when a confirm can walk a long run before failing it
        // blows up on a dense-prefix begin-but-don't-complete input (`aaaa…a!`: a leading run at
        // every position, each confirm re-walking it). `ep.prone` flags both hazardous shapes — a
        // non-accepting *cycle* (`(x+x+)+y`, unbounded ⇒ Θ(n²)) AND a long *bounded* prefix
        // (`a{4000}b`, Θ(n·k) with large k) — and `end_anchored` (`$`) flags the run-to-end shape
        // (`(a+)+$`). For all of those the eager DFA's *native* find is O(input) (reverse two-pass /
        // reverse-from-end), so skip to the first candidate once and hand off — no per-position
        // confirm. The fast-confirm case (`foo\d+`, `a{4}b`: the confirm fails within a few bytes)
        // keeps the memmem-jump loop, its intended speedup. (Both leftmost-first; no match begins
        // before the first occurrence of the prefix run.)
        if (ep.prone or ep.end_anchored) {
            o.start = memmemFrom(input, o.start, pfx) orelse return null;
            if (input.len - o.start < filter.min_bytes) return null;
        } else {
            // Build the 2-byte SIMD finder ONCE (prefix ≥ 2 bytes). A fresh `memmemFrom` per hit
            // rebuilds the finder every time, which dominates a dense-prefix scan (`\bthe\b` /
            // `foo\d+`: the prefix run recurs thousands of times in prose/logs). 1-byte prefix → memchr.
            const finder: ?memmem.Finder = if (filter.prefix_len >= 2) memmem.Finder.init(pfx) else null;
            var pos = o.start;
            while (if (finder) |*fd| fd.find(input, pos) else memchrFrom(input, pos, pfx[0])) |hit| {
                if (input.len - hit < filter.min_bytes) return null;
                probes.* += 1; // ReDoS observable: a per-occurrence confirm (0 for prone/end_anchored)
                if (filter.lit_wb_confirm) {
                    // `\b`-wrapped pure literal: the memmem hit already confirms the literal, so the
                    // match is exactly [hit, hit+prefix_len] iff the ASCII boundary checks hold (the
                    // eager `\b` arm runs only on ASCII input — `edfaArm`). O(1) per hit, no walk.
                    if (litWbHolds(filter, input, hit, filter.prefix_len))
                        return Match{ .start = hit, .end = hit + filter.prefix_len };
                } else if (edfaConfirmAt(ep, input, hit, match_only)) |m| return m;
                pos = hit + 1;
            }
            return null;
        }
    } else if (filter.prefix_set_n > 0) {
        // Multi-prefix: per-occurrence anchored confirm when bounded AND not prone/end-anchored
        // (the eager DFA's confirm is fast-failing then); else one skip + a native find.
        if (filter.bounded_confirm and !ep.prone and !ep.end_anchored) {
            var pos = o.start;
            while (nextPrefixHit(filter, tdy, input, pos)) |hit| {
                pos = hit + 1;
                // A window hit at `hit` implies a match start `hit - d`, d in the offset range
                // (largest d = leftmost candidate, tried first). 0/0 for a leading set.
                var d = filter.prefix_set_off_max;
                while (d + 1 > filter.prefix_set_off_min) : (d -= 1) {
                    if (d <= hit) {
                        const cand = hit - d;
                        if (cand >= o.start and input.len - cand >= filter.min_bytes) {
                            probes.* += 1; // ReDoS observable (bounded ⇒ stays linear)
                            if (edfaConfirmAt(ep, input, cand, match_only)) |m| return m;
                        }
                    }
                    if (d == 0) break;
                }
            }
            return null;
        }
        o.start = nextPrefixHit(filter, tdy, input, o.start) orelse return null;
        o.start -|= filter.prefix_set_off_max; // interior window → step back to the earliest match start
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.req_lit_len > 0) {
        // Structured reverse-walk fast path (`\w+\s+Holmes`, `\w+\s+Holmes\s+\w+`): per memmem hit,
        // walk the disjoint pre-atom classes backward to the EXACT start, then one anchored confirm —
        // the eager DFA runs only at real candidate starts, not over the gaps. ASCII-exact; engage on
        // ASCII-dominant input with a per-window pure-ASCII check and a sound flat-scan sweep fallback.
        if (filter.req_pre_n > 0 and ascii_dominant) {
            const needle = filter.req_lit[0..filter.req_lit_len];
            var pos = o.start;
            while (memmemFrom(input, pos, needle)) |q| {
                pos = q + 1;
                switch (structuredStart(filter, input, q, o.start)) {
                    .skip => {},
                    .exact => |cand| {
                        if (input.len - cand >= filter.min_bytes) {
                            probes.* += 1; // ReDoS observable (one confirm per occurrence)
                            if (edfaConfirmAt(ep, input, cand, match_only)) |m| return m;
                        }
                    },
                    .impure => {
                        var s = reqFlatLowerBound(filter, input, q, o.start);
                        while (s <= q) : (s += 1) {
                            if (input.len - s < filter.min_bytes) break;
                            probes.* += 1;
                            if (edfaConfirmAt(ep, input, s, match_only)) |m| return m;
                        }
                    },
                }
            }
            return null;
        }
        // Required interior/suffix-literal skip (`\w+\s+Holmes`, `[a-zA-Z]+ing`): memmem to the
        // literal, reverse-scan to the earliest match start, then ONE native (unanchored) eager-DFA
        // find. As in `runByteDfa`, NOT a per-occurrence anchored confirm — `req_lead` is a superset,
        // so the reverse scan can over-reach to a non-start position; only an unanchored find from cs
        // is leftmost-correct. Sound + O(input).
        if (filter.req_lit_fixed_off) |off| {
            // Pass 2 — fixed-offset rare-byte confirm (`[a-q][^u-z]{13}x`): the rare literal byte sits
            // a fixed *code-point* distance `off` from the match start. memchr the byte at `q`, walk
            // back `off` code points (UTF-8 aware — exact on any input), confirm anchored at that
            // pinned start, one confirm per occurrence instead of scanning the dense leading class.
            // Leftmost-first (q ascending) + O(input).
            const b = filter.req_lit[0];
            var pos = o.start;
            while (memchrFrom(input, pos, b)) |q| {
                pos = q + 1;
                const cand = cpBack(input, q, off) orelse continue;
                if (cand < o.start) continue;
                if (input.len - cand < filter.min_bytes) return null;
                probes.* += 1; // ReDoS observable (bounded ⇒ stays linear)
                if (edfaConfirmAt(ep, input, cand, match_only)) |m| return m;
            }
            return null;
        }
        o.start = reqLitSkipFrom(filter, input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.inner_byte) |anchor| {
        // Fixed-offset interior anchor on ASCII input (`\d{4}-…`): jump anchor-to-anchor and
        // bounded-confirm at the pinned start `q - off` — one confirm per occurrence, the win when
        // the anchor byte is dense and unselective (nginx `- -` placeholders). A bounded match
        // length keeps the loop O(input). Non-ASCII / variable leading run → reverse-scan path below.
        if (input_ascii and filter.bounded_confirm) {
            if (filter.inner_fixed_off) |off| {
                var pos = o.start;
                while (memchrFrom(input, pos, anchor)) |q| {
                    pos = q + 1;
                    if (q < off) continue;
                    const cand = q - off;
                    if (cand < o.start) continue;
                    if (input.len - cand < filter.min_bytes) return null; // cand only grows ⇒ no later fit
                    probes.* += 1;
                    if (edfaConfirmAt(ep, input, cand, match_only)) |m| return m;
                }
                return null;
            }
        }
        // Variable / non-ASCII interior anchor → skip to the next anchor, reverse-scan to the run
        // start, then one native eager-DFA find. Sound + O(input).
        o.start = innerSkipFrom(filter, input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (cf) |c| {
        // Leading-class SIMD skip → one native eager-DFA find from the first candidate
        // (sound; the skipped-to byte begins a class run, so the find lands on the leftmost
        // match). Single skip, never a per-occurrence confirm loop — no ReDoS observable.
        // A *derived* (broad-tail) set engages only on ASCII-dominant input — on non-ASCII input
        // every byte is a candidate, so the scan can't skip and would only add overhead; we then
        // fall through to the native find unchanged (`class_lead_ascii_only`, see its field doc).
        if (!(filter.class_lead_ascii_only and !ascii_dominant)) {
            o.start = c.find(input, o.start) orelse return null;
            if (input.len - o.start < filter.min_bytes) return null;
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

/// The derived leading-class scan engages only when high (≥ 0x80) bytes are at most `1 / this` of
/// the input — Latin prose is ~0% high, Cyrillic/CJK UTF-8 is 75–90% high, so 1/8 sits in a wide
/// gap and separates them with large margin. Speed-only; never affects results.
const ASCII_DOMINANT_DIV: usize = 8;

/// Whether `input` is **ASCII-dominant** (high bytes < `1/ASCII_DOMINANT_DIV` of its length) — the
/// gate for the derived `class_lead_ascii_only` scan. A full O(n) count (not an early-exit like
/// `inputAllAscii`), cached on the input slice so a `count`/`findAll` pays it once.
fn inputAsciiDominant(scratch: *Scratch, input: []const u8) bool {
    if (scratch.ad_input_ptr == input.ptr and scratch.ad_input_len == input.len) return scratch.ad_dominant;
    var high: usize = 0;
    for (input) |b| high += @intFromBool(b >= 0x80);
    const dominant = high *| ASCII_DOMINANT_DIV < input.len;
    scratch.ad_input_ptr = input.ptr;
    scratch.ad_input_len = input.len;
    scratch.ad_dominant = dominant;
    return dominant;
}

/// The `ascii_dominant` argument for the span arms: the O(n) dominance count runs **only** for a
/// program that consults it — a derived (broad-tail) `class_lead` (`class_lead_ascii_only`) or a
/// structured reverse-walk required-literal (`req_pre_n > 0`). Every other program never reads the
/// flag, so it pays nothing. The count is cached per input in the scratch.
inline fn asciiDominantArg(program: *const Program, scratch: *Scratch, input: []const u8) bool {
    if (!program.filter.class_lead_ascii_only and program.filter.req_pre_n == 0) return false;
    return inputAsciiDominant(scratch, input);
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

/// Pointer to the program's multi-prefix Teddy accelerator (or null) — the SIMD finder the
/// `run*` arms use for `prefix_set`. Pointer into the program, valid for the call.
inline fn teddyPtr(program: *const Program) ?*const teddy.Teddy {
    return if (program.prefix_teddy) |*t| t else null;
}

/// Pointer to the program's leading-class scanner (or null) — the SIMD finder the `run*`
/// arms use for `class_lead`. Pointer into the program, valid for the call.
inline fn classPtr(program: *const Program) ?*const classscan.ClassFinder {
    return if (program.class_finder) |*c| c else null;
}

/// Line-anchored capture search (`(?m)^…` patterns, `filter.line_anchored`): every match begins at
/// a line start, so attempt the capturing engine **anchored at each line start** — `memchr` the
/// next `\n` to skip between lines — instead of locating each span with the lazy DFA and then
/// re-filling captures. One capture pass per candidate line, no DFA span pass. Leftmost-first and
/// sound (no match can begin off a line start). `searchCaptures` uses this when there is no eager
/// DFA span arm (the `log_line` case: a `(?m)^…captures…` pattern too big for the eager DFA, which
/// otherwise pays a lazy-DFA span pass *and* a Pike VM capture pass per line).
fn lineAnchoredCaptures(program: *const Program, scratch: *Scratch, p: *const nfa.Program, input: []const u8, slots: []?usize, opts: SearchOptions) ?Match {
    if (opts.start > input.len) return null;
    var pos = opts.start;
    while (pos <= input.len) {
        // Land `pos` on a line start (offset 0, or just after a `\n`); else jump to the next one.
        if (pos != 0 and input[pos - 1] != '\n') {
            const nl = memchrFrom(input, pos, '\n') orelse return null;
            pos = nl + 1;
            continue;
        }
        if (input.len - pos >= program.filter.min_bytes) {
            const seed = Match{ .start = pos, .end = pos };
            if (fillCapturesAnchored(program, &scratch.inner.nfa, p, input, slots, seed, opts)) |m| return m;
        }
        if (pos == input.len) break;
        const nl = memchrFrom(input, pos, '\n') orelse return null;
        pos = nl + 1;
    }
    return null;
}

/// Line-anchored **span** search (`(?m)^…`, `filter.line_anchored`): attempt the span engine
/// anchored at each line start (`memchr` the next `\n` to skip between lines) instead of the lazy
/// DFA's line-gated forward scan **plus** a reverse-DFA start pass. One anchored forward pass per
/// candidate line — no reverse pass. Leftmost-first and sound (no match begins off a line start).
/// `search`/`isMatch` use this when there is no eager DFA span arm (the `log_line` case).
/// `match_only` selects isMatch (true/false token) vs search (the real span).
fn lineAnchoredSpan(program: *const Program, scratch: *Scratch, p: *const nfa.Program, input: []const u8, opts: SearchOptions, match_only: bool) ?Match {
    if (opts.start > input.len) return null;
    var pos = opts.start;
    while (pos <= input.len) {
        if (pos != 0 and input[pos - 1] != '\n') {
            const nl = memchrFrom(input, pos, '\n') orelse return null;
            pos = nl + 1;
            continue;
        }
        if (input.len - pos >= program.filter.min_bytes) {
            if (lineAnchoredAttempt(program, scratch, p, input, pos, match_only)) |m| return m;
        }
        if (pos == input.len) break;
        const nl = memchrFrom(input, pos, '\n') orelse return null;
        pos = nl + 1;
    }
    return null;
}

/// One anchored span attempt at line start `at`: the lazy DFA when built (its `runAnchored`'s
/// `startFor` selects the line-start start state, so an anchored run at a line start honours `(?m)^`),
/// else the Pike VM. `null` when no match begins at `at`. A lazy-DFA `gave_up` falls through to the
/// Pike VM (and disables the DFA arm for the rest of the search).
fn lineAnchoredAttempt(program: *const Program, scratch: *Scratch, p: *const nfa.Program, input: []const u8, at: usize, match_only: bool) ?Match {
    if (!scratch.dfa_disabled) {
        if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
            const m = dfaConfirmAt(dp, d, input, at, match_only);
            if (d.gave_up) {
                scratch.dfa_disabled = true; // cache thrashed → use the Pike VM below
            } else {
                return m;
            }
        };
    }
    const o = SearchOptions{ .start = at, .anchored = true };
    const m = dispatch(p, &scratch.inner.nfa, input, o, null) orelse return null;
    return if (match_only) Match{ .start = at, .end = at } else m;
}

/// @stable-since: v0.1.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    switch (program.inner) {
        .literal => |*p| return literal.isMatch(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            // Line-anchored span fast path (`(?m)^…`, no eager DFA — `log_line`): attempt anchored at
            // each line start instead of the lazy DFA's forward + reverse find. See `lineAnchoredSpan`.
            if (program.filter.line_anchored and !opts.anchored and program.edfa_prog == null)
                return lineAnchoredSpan(program, scratch, p, input, opts, true) != null;
            // Eager DFA span scan (prefiltered, stateless) when built and usable — the fastest arm,
            // same result the NFA arm gives. A `\b` program's eager DFA is used only on ASCII input
            // (`edfaArm`); non-ASCII `\b` input falls through to the Pike VM (Unicode boundaries).
            if (edfaArm(program, scratch, input)) |ep| return runEdfa(ep, &program.filter, teddyPtr(program), classPtr(program), input, opts, true, inputAllAscii(scratch, input), asciiDominantArg(program, scratch, input), &scratch.confirm_probes) != null;
            // Lazy DFA fallback (prefiltered) when built and not disabled.
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const r = runByteDfa(dp, &program.filter, teddyPtr(program), classPtr(program), d, input, opts, true, inputAllAscii(scratch, input), asciiDominantArg(program, scratch, input), &scratch.lazy_confirm_bytes);
                    if (d.gave_up) scratch.dfa_disabled = true; // cache thrashed → stop using it
                    return r != null;
                };
            }
            return runNfa(p, &program.filter, teddyPtr(program), classPtr(program), &scratch.inner.nfa, input, opts, null, program.has_grapheme) != null;
        },
    }
}

/// @stable-since: v0.1.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    switch (program.inner) {
        .literal => |*p| return literal.search(p, &scratch.inner.literal, input, opts),
        .nfa => |*p| {
            // Line-anchored span fast path (`(?m)^…`, no eager DFA — `log_line`): see `lineAnchoredSpan`.
            if (program.filter.line_anchored and !opts.anchored and program.edfa_prog == null)
                return lineAnchoredSpan(program, scratch, p, input, opts, false);
            if (edfaArm(program, scratch, input)) |ep| return runEdfa(ep, &program.filter, teddyPtr(program), classPtr(program), input, opts, false, inputAllAscii(scratch, input), asciiDominantArg(program, scratch, input), &scratch.confirm_probes);
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const r = runByteDfa(dp, &program.filter, teddyPtr(program), classPtr(program), d, input, opts, false, inputAllAscii(scratch, input), asciiDominantArg(program, scratch, input), &scratch.lazy_confirm_bytes);
                    if (d.gave_up) scratch.dfa_disabled = true;
                    return r;
                };
            }
            return runNfa(p, &program.filter, teddyPtr(program), classPtr(program), &scratch.inner.nfa, input, opts, null, program.has_grapheme);
        },
    }
}

/// @stable-since: v0.1.0
pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots: []?usize, opts: SearchOptions) ?Match {
    switch (program.inner) {
        .literal => |*p| return literal.searchCaptures(p, &scratch.inner.literal, input, slots, opts),
        .nfa => |*p| {
            // Line-anchored capture fast path (`(?m)^…`): when no eager DFA span arm exists (the
            // pattern is too big — `log_line`), attempt the capturing engine anchored at each line
            // start instead of a lazy-DFA span pass + a re-fill pass. Only for an unanchored search.
            if (program.filter.line_anchored and !opts.anchored and program.edfa_prog == null) {
                return lineAnchoredCaptures(program, scratch, p, input, slots, opts);
            }
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
                const m = runEdfa(ep, &program.filter, teddyPtr(program), classPtr(program), input, opts, false, inputAllAscii(scratch, input), asciiDominantArg(program, scratch, input), &scratch.confirm_probes) orelse return null;
                return fillCapturesAnchored(program, &scratch.inner.nfa, p, input, slots, m, opts);
            }
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const span = runByteDfa(dp, &program.filter, teddyPtr(program), classPtr(program), d, input, opts, false, inputAllAscii(scratch, input), asciiDominantArg(program, scratch, input), &scratch.lazy_confirm_bytes);
                    if (d.gave_up) {
                        scratch.dfa_disabled = true; // cache thrashed → fall through to the NFA arm
                    } else {
                        const m = span orelse return null; // DFA is exact: no span ⇒ no match
                        return fillCapturesAnchored(program, &scratch.inner.nfa, p, input, slots, m, opts);
                    }
                };
            }
            return runNfa(p, &program.filter, teddyPtr(program), classPtr(program), &scratch.inner.nfa, input, opts, slots, program.has_grapheme);
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
const compile = @import("core").compile;
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

test "auto cascades a PRONE + prefiltered pattern from the eager to the lazy DFA" {
    const gpa = testing.allocator;
    // A prone pattern with a start-skip prefilter (a leading literal `the`) drives its find from the
    // prefilter, so the eager DFA's reverse table would be wasted build work — `auto` declines the
    // eager DFA and routes the span scan to the lazy DFA (`decline_if_prone`). A *non-prone* class
    // scan keeps the eager DFA. Results are identical either way (the spans below pin it).
    const Case = struct { pat: []const u8, route_str: []const u8 };
    const cases = [_]Case{
        .{ .pat = "the\\s+\\p{L}+", .route_str = "nfa+dfa" }, // prone + "the" prefilter → lazy DFA
        .{ .pat = "\\p{L}+", .route_str = "nfa+edfa" }, // non-prone → eager DFA (no cascade)
        .{ .pat = "\\w+", .route_str = "nfa+edfa" },
        .{ .pat = "\\bthe\\b", .route_str = "nfa+edfa" }, // prefilter but NON-prone → keeps eager
    };
    for (cases) |c| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, c.pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        defer freeProgram(gpa, &program);
        try testing.expectEqualStrings(c.route_str, route(&program));
    }
    // The cascade must not change a single match: spans identical to what the eager DFA produced.
    try expectFind("the\\s+\\p{L}+", "say the  quick fox", "the  quick");
    try expectFind("the\\s+\\p{L}+", "in the lazy dog", "the lazy");
    try expectNoMatch("the\\s+\\p{L}+", "theater (no space then letter)");
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
    // A pattern with a leading *class* (no fixed leading literal) bypasses the memmem
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

test "auto: prefix-literal memmem prefilter finds the leftmost match" {
    // Every match of `foo\d` begins with the literal "foo" → analysis yields the
    // prefix run "foo" that drives a SIMD `memmem` skip (literal-to-literal). A
    // false-positive "foo" ("food", no trailing digit) fails the anchored confirm
    // and the scan moves on to the next "foo".
    try expectFind("foo\\d", "food foo5", "foo5");
    try expectFind("foo\\d+", "xx foo123 yy", "foo123");
    try expectNoMatch("foo\\d", "no digits here foo!");
    // unicode prefix: 'é' is multi-byte; the whole "été" run (UTF-8) is the memmem needle.
    try expectFind("été\\d", "l'été9", "été9");
}

test "auto: multi-byte prefix run drives the memmem skip (the \\bthe\\b lane)" {
    // `\bthe\b` consumes the literal "the" after a zero-width `\b`, so the prefix run is the
    // whole word "the" — the SIMD `memmem` leaps "the"→"the" instead of 't'→'t', skipping past
    // every interior "the" (in "other", "there") far more cheaply than the old single-byte memchr.
    try expectFind("\\bthe\\b", "soothe the other theory", "the");
    try expectNoMatch("\\bthe\\b", "soothe theory bathear"); // every "the" is interior — no boundary
    // findAll / count agree with the per-match scan over a boundary-heavy input.
    var re = try Compiled.init("\\bthe\\b");
    defer re.deinit();
    const input = "the theatre then the end, other the";
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, input, .{}));
    // A leading multi-char literal before a class behaves identically.
    try expectFind("abc[0-9]+", "ab abc abc7 x", "abc7");
}

test "auto: filterFromAnalysis distils the WHOLE leading literal run (revert-failing)" {
    // White-box guard for the substring-skip upgrade: the prefilter needle must be the full
    // leading literal run, not just its first byte. Reverting to a single-byte prefix collapses
    // `prefix_len` back to 1 here and fails this test.
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, prefix: []const u8 };
    const cases = [_]Case{
        .{ .pat = "foo\\d+", .prefix = "foo" }, // leading literal "foo", len 3
        .{ .pat = "\\bthe\\b", .prefix = "the" }, // zero-width `\b` is skipped; run is "the"
        .{ .pat = "abc[0-9]+xy$", .prefix = "abc" }, // leading run is "abc" (not "xy")
        .{ .pat = "été\\d", .prefix = "été" }, // multi-byte code points: 4 UTF-8 bytes
        .{ .pat = "a{4}b", .prefix = "a" }, // counted repeat keeps a 1-byte run (memmem→memchr)
    };
    inline for (cases) |c| {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, c.pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        const f = filterFromAnalysis(h);
        try testing.expectEqual(@as(u8, @intCast(c.prefix.len)), f.prefix_len);
        try testing.expectEqualStrings(c.prefix, f.prefix[0..f.prefix_len]);
        try testing.expectEqual(@as(?u8, c.prefix[0]), f.prefix_byte); // first byte still mirrored
    }
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

test "auto: prefilter path runs at COMPTIME (memmem + anchored confirm)" {
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

// ── White-box tests for the v0.4.0 prefilters (case-variant Teddy + leading-class scan) ──

/// Build a HIR for `pat` and return its distilled `Filter` (test helper).
fn filterOf(gpa: std.mem.Allocator, pat: []const u8) !Filter {
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, pat, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    return filterFromAnalysis(h);
}

test "auto: required-literal skip is distilled for interior/suffix literals (revert-failing)" {
    // Reverting the `required_literal_skip` analysis or its filter distillation drops `req_lit_len`
    // to 0 here. These are patterns with NO leading literal and NO selective leading-class scan, so
    // the whole-literal memmem skip is the only good prefilter.
    const gpa = testing.allocator;
    {
        const f = try filterOf(gpa, "\\w+\\s+Holmes"); // suffix literal after two class runs
        try testing.expectEqual(@as(u8, 6), f.req_lit_len);
        try testing.expectEqualStrings("Holmes", f.req_lit[0..f.req_lit_len]);
        try testing.expect(f.req_lead.has('a') and f.req_lead.has(' ')); // word ∪ space
        try testing.expect(!f.req_lead.has('!')); // punctuation excluded → reverse scan stops there
        try testing.expectEqual(@as(u8, 0), f.prefix_len);
    }
    {
        const f = try filterOf(gpa, "[a-zA-Z]+ing"); // common first byte ('i'), selective whole needle
        try testing.expectEqual(@as(u8, 3), f.req_lit_len);
        try testing.expectEqualStrings("ing", f.req_lit[0..f.req_lit_len]);
        try testing.expect(f.req_lead.has('Z') and !f.req_lead.has('0'));
    }
    {
        // A leading literal takes priority — `req_lit` is not used even if an interior literal exists.
        const f = try filterOf(gpa, "abc\\d+xyz");
        try testing.expect(f.prefix_len > 0);
        try testing.expectEqual(@as(u8, 0), f.req_lit_len);
    }
    {
        // A 1-byte interior literal is left to `inner_byte`'s memchr (needle must be ≥ 2 bytes).
        const f = try filterOf(gpa, "\\w+\\s+x");
        try testing.expectEqual(@as(u8, 0), f.req_lit_len);
    }
}

test "auto: structured reverse-walk atoms are distilled for disjoint class-rep prefixes (revert-failing)" {
    // The structured reverse walk (the precise per-occurrence confirm that closes before-holmes /
    // before-after-holmes) needs the disjoint class-rep pre-atoms. Reverting the `pre`/`pre_n`
    // analysis or its distillation drops `req_pre_n` to 0 → back to the slow flat-scan path.
    const gpa = testing.allocator;
    {
        const f = try filterOf(gpa, "\\w+\\s+Holmes"); // \w+ \s+ (disjoint) before "Holmes"
        try testing.expectEqual(@as(u8, 2), f.req_pre_n);
        try testing.expectEqual(@as(u8, 6), f.req_lit_len);
    }
    {
        const f = try filterOf(gpa, "\\w+\\s+Holmes\\s+\\w+"); // non-suffix: trailing \s+\w+
        try testing.expectEqual(@as(u8, 2), f.req_pre_n); // walk still applies (confirm validates the tail)
    }
    {
        const f = try filterOf(gpa, "[a-zA-Z]+ing"); // one pre-atom
        try testing.expectEqual(@as(u8, 1), f.req_pre_n);
    }
}

test "auto: required-literal skip stays leftmost-correct when the reverse scan over-reaches (revert-failing)" {
    // THE soundness regression for the required-literal skip. `req_lead` is a *superset* of the
    // preceding alphabet, so the reverse scan from a literal hit can land before the true match
    // start. The arm MUST therefore run an *unanchored* forward find from that position — NOT a
    // per-occurrence anchored confirm. With an anchored confirm, `\w+\s+Holmes` over "ab cd Holmes"
    // confirms at 'a' (fails: `\w+` can't span the space) and wrongly reports no match, missing
    // "cd Holmes". Reverting the arm to an anchored confirm fails the first case below.
    try expectFind("\\w+\\s+Holmes", "ab cd Holmes", "cd Holmes");
    try expectFind("\\w+\\s+Holmes", "xx   Holmes", "xx   Holmes");
    try expectFind("\\w+\\s+Holmes", "!!! word Holmes rest", "word Holmes");
    try expectNoMatch("\\w+\\s+Holmes", "Holmes alone"); // single Holmes, nothing before
    try expectNoMatch("\\w+\\s+Holmes", "no name here");

    // The `[a-zA-Z]+ing` shape (needle first byte is itself in the lead alphabet).
    try expectFind("[a-zA-Z]+ing", "running", "running");
    try expectFind("[a-zA-Z]+ing", "  the morning sun", "morning");
    try expectNoMatch("[a-zA-Z]+ing", "ing"); // needs ≥ 1 letter before "ing"
}

test "auto: required-literal skip matches the Pike VM oracle over prose (differential)" {
    // Differential vs the Pike VM (the leftmost-first reference): `count` over a Sherlock-shaped
    // haystack must agree for the required-literal-skip patterns. A wrong skip (mis-ordered or
    // dropped matches) diverges from the oracle here.
    const gpa = testing.allocator;
    const hay =
        "When Holmes spoke, John Watson and the morning visitor stood. " ++
        "Inspector Lestrade Holmes greeted, then mister Holmes again. " ++
        // accented words before "Holmes" exercise the structured walk's non-ASCII (impure) fallback:
        "caf\u{e9} Holmes and na\u{ef}ve\u{2014}Holmes plus r\u{e9}sum\u{e9}  Holmes here. " ++
        "Nothing was happening in the evening; the ring was missing. Mr Holmes!";
    const pats = [_][]const u8{ "\\w+\\s+Holmes", "[a-zA-Z]+ing", "\\w+\\s+Holmes\\s+\\w+" };
    for (pats) |pat| {
        var re = try Compiled.init(pat);
        defer re.deinit();

        // Oracle: a plain leftmost-first unanchored Pike VM scan, no prefilter.
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const ph = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, ph);
        var pp = try pikevm.buildAlloc(gpa, ph, .{});
        defer pikevm.freeProgram(gpa, &pp);
        var ps = try pikevm.Scratch.init(gpa, &pp);
        defer ps.deinit(gpa);

        var pos: usize = 0;
        while (true) {
            const am = E.find(&re.program, &re.scratch, hay, .{ .start = pos });
            const om = pikevm.search(&pp, &ps, hay, .{ .start = pos });
            if (am == null or om == null) {
                try testing.expect(am == null and om == null);
                break;
            }
            try testing.expectEqual(om.?.start, am.?.start);
            try testing.expectEqual(om.?.end, am.?.end);
            pos = if (am.?.end > am.?.start) am.?.end else am.?.end + 1;
        }
    }
}

test "auto: fixed-offset rare-byte confirm for a bounded negated-class pattern (Pass 2, revert-failing)" {
    // `[a-q][^u-z]{13}x` is fixed-length (15) with the rare literal 'x' at fixed cp-offset 14. The
    // dispatcher must take the fixed-offset memchr+confirm path (`req_lit_fixed_off`), not the dense
    // `[a-q]` leading-class scan. Reverting `lead_fixed_cps` / the distiller gate drops the fixed
    // path. Correctness is the priority; these pin the matches.
    const gpa = testing.allocator;
    {
        const f = try filterOf(gpa, "[a-q][^u-z]{13}x");
        try testing.expectEqual(@as(u8, 1), f.req_lit_len);
        try testing.expectEqual(@as(u8, 'x'), f.req_lit[0]);
        try testing.expectEqual(@as(?u32, 14), f.req_lit_fixed_off);
        try testing.expect(f.class_lead == null); // the dense [a-q] scan is dropped in favour of 'x'
        try testing.expect(f.rare_byte == null); // and the presence-only reject too
    }
    // A valid 15-char window: 'a' + 13 bytes none in u-z + 'x'.
    try expectFind("[a-q][^u-z]{13}x", "  abcdefghijklmnx  ", "abcdefghijklmnx");
    // Near-miss: a 'u' inside the 13-window breaks it; the next 'x' has no valid window → no match.
    try expectNoMatch("[a-q][^u-z]{13}x", "abcdefghijkuvwx");
    // The leading char must be [a-q]: 'r' is not, so no match even with a clean window + 'x'.
    try expectNoMatch("[a-q][^u-z]{13}x", "rbcdefghijklmnx");
}

test "auto: Pass 2 fixed-offset confirm matches the Pike VM oracle (differential)" {
    const gpa = testing.allocator;
    // Build inputs with valid and near-miss windows for `[a-q][^u-z]{13}x`.
    const hay =
        "the quick brown fox jumps; a_______note_x and another aQQQQQQQQQQQQx here " ++
        "plus abcdefghijklmnx tail, and zzz a1234567890!?x end, noise xxxxxxxxxxxxxx done. " ++
        // multi-byte code points inside a candidate window: cpBack must count CODE POINTS, not bytes,
        // so the fixed-offset confirm pins the right start (or correctly finds none) past the é/ü/—.
        "a\u{e9}\u{fc}cd\u{2014}fghijklmx and aééüü\u{2014}\u{2014}klmnx done b\u{e9}\u{e9}x";
    const pats = [_][]const u8{ "[a-q][^u-z]{13}x", "[a-q][^u-z]{13}x", "\\d[^/]{5}/" };
    for (pats) |pat| {
        var re = try Compiled.init(pat);
        defer re.deinit();
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const ph = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, ph);
        var pp = try pikevm.buildAlloc(gpa, ph, .{});
        defer pikevm.freeProgram(gpa, &pp);
        var ps = try pikevm.Scratch.init(gpa, &pp);
        defer ps.deinit(gpa);
        var pos: usize = 0;
        while (true) {
            const am = E.find(&re.program, &re.scratch, hay, .{ .start = pos });
            const om = pikevm.search(&pp, &ps, hay, .{ .start = pos });
            if (am == null or om == null) {
                try testing.expect(am == null and om == null);
                break;
            }
            try testing.expectEqual(om.?.start, am.?.start);
            try testing.expectEqual(om.?.end, am.?.end);
            pos = if (am.?.end > am.?.start) am.?.end else am.?.end + 1;
        }
    }
}

test "auto: case-variant prefix set is synthesised for a small-class-led concat (revert-failing)" {
    // `(?i)the` lowers to `[Tt][Hh][Ee]` — no fixed leading literal, no top-level alternation —
    // so the case-variant expansion must produce the needle set. Reverting `caseVariantSet`
    // collapses `prefix_set_n` to 0 here and fails. Pure literals must NOT come here.
    const gpa = testing.allocator;
    {
        const f = try filterOf(gpa, "(?i)the");
        try testing.expectEqual(@as(u8, 8), f.prefix_set_n); // {T,t}×{H,h}×{E,e}
        try testing.expect(f.prefix_set_case_variant);
        try testing.expectEqual(@as(u8, 0), f.prefix_len); // no single leading literal
        // Every needle is the full 3-byte run and they are distinct (sound necessary prefixes).
        var seen = std.AutoHashMap([3]u8, void).init(gpa);
        defer seen.deinit();
        var i: usize = 0;
        while (i < f.prefix_set_n) : (i += 1) {
            try testing.expectEqual(@as(u8, 3), f.prefix_set_len[i]);
            try seen.put(f.prefix_set[i][0..3].*, {});
        }
        try testing.expectEqual(@as(usize, 8), seen.count()); // all 8 variants distinct
    }
    {
        const f = try filterOf(gpa, "[Tt]he"); // only the first position is a class → 2 variants
        try testing.expectEqual(@as(u8, 2), f.prefix_set_n);
        try testing.expect(f.prefix_set_case_variant);
    }
    {
        const f = try filterOf(gpa, "(?i)что"); // Cyrillic, each letter 2 bytes
        try testing.expect(f.prefix_set_n >= 2);
        try testing.expect(f.prefix_set_case_variant);
        try testing.expect(f.prefix_set_len[0] >= VARIANT_MIN_LEN);
    }
    {
        const f = try filterOf(gpa, "the"); // pure literal → prefix_literal, NOT a case-variant set
        try testing.expect(f.prefix_len > 0);
        try testing.expectEqual(@as(u8, 0), f.prefix_set_n);
        try testing.expect(!f.prefix_set_case_variant);
    }
}

test "auto: case-insensitive alternation set is synthesised one needle per branch (revert-failing)" {
    // `(?i:Sher[a-z]+|Hol[a-z]+)` / `(?i:Sherlock|Holmes|Watson)` — case folding turns each
    // branch's leading letters into classes, so step 2's `prefix_set` (needs a fixed leading
    // literal) declines and the single-concat case-variant set (step 2b) does not apply. The new
    // casei-alternation set must produce a folded multi-prefix. Reverting `caseiAlternationSet`
    // collapses `prefix_set_n` to 0 here.
    const gpa = testing.allocator;

    // Helper: is `needle` (ASCII-folded) among the prefix set?
    const has = struct {
        fn f(flt: *const Filter, want: []const u8) bool {
            var i: usize = 0;
            while (i < flt.prefix_set_n) : (i += 1) {
                if (caseiFindFrom(flt.prefix_set[i][0..flt.prefix_set_len[i]], 0, want)) |at| {
                    if (at == 0 and flt.prefix_set_len[i] == want.len) return true;
                }
            }
            return false;
        }
    }.f;

    {
        const f = try filterOf(gpa, "(?i:Sher[a-z]+|Hol[a-z]+)");
        try testing.expect(f.prefix_set_n >= 2);
        try testing.expect(f.prefix_set_fold_ascii);
        try testing.expect(!f.prefix_set_case_variant); // a leading set, not the rare-window variant
        try testing.expectEqual(@as(u8, 0), f.prefix_len);
        try testing.expect(has(&f, "she")); // Sherlock window (ASCII case pair collapsed)
        try testing.expect(has(&f, "hol")); // Holmes window
        // The non-ASCII `s`→`ſ` simple-fold member fans the Sher branch into a second needle.
        try testing.expect(has(&f, "\u{017F}he"));
    }
    {
        const f = try filterOf(gpa, "(?i:Sherlock|Holmes|Watson)");
        try testing.expect(f.prefix_set_n >= 3);
        try testing.expect(f.prefix_set_fold_ascii);
        try testing.expect(has(&f, "she"));
        try testing.expect(has(&f, "hol"));
        try testing.expect(has(&f, "wat"));
    }
    {
        // A non-casei alternation keeps a *case-sensitive* set via step 2 (no fold flag).
        const f = try filterOf(gpa, "Sherlock|Holmes");
        try testing.expect(f.prefix_set_n >= 2);
        try testing.expect(!f.prefix_set_fold_ascii);
    }
    {
        // A single casei branch (no alternation) is the case-variant set's job, not this path.
        const f = try filterOf(gpa, "(?i:Holmes)");
        try testing.expect(!f.prefix_set_fold_ascii); // would only be set by caseiAlternationSet
    }
}

test "auto: case-insensitive alternation Teddy matches the Pike VM oracle over prose (differential)" {
    // The fold-aware multi-prefix skip must agree with the unfiltered Pike VM on real text that
    // mixes cases (and a long-s `ſ`), proving the prefilter drops no real match and the per-hit
    // confirm stays leftmost-first.
    const gpa = testing.allocator;
    const corpus =
        "Sherlock and SHERLOCK met holmes; HOLMES greeted Watson and watson. " ++
        "A ſherlock spelling, sHeRlOcK casing, and plain text with no names at all. " ++
        "Holmes, holmes, HoLmEs — and Sheraton (not a match for Sher[a-z]+? it is). " ++
        "watsons, WATSONing, and a lone Wat. The end.";
    const pats = [_][]const u8{
        "(?i:Sherlock|Holmes|Watson)",
        "(?i:Sher[a-z]+|Hol[a-z]+)",
        "(?i:sherlock|holmes|watson)",
    };
    for (pats) |pat| {
        var re = try Compiled.init(pat);
        defer re.deinit();

        // Oracle: a plain leftmost-first unanchored Pike VM scan, no prefilter.
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const ph = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, ph);
        var pp = try pikevm.buildAlloc(gpa, ph, .{});
        defer pikevm.freeProgram(gpa, &pp);
        var ps = try pikevm.Scratch.init(gpa, &pp);
        defer ps.deinit(gpa);

        var pos: usize = 0;
        while (true) {
            const am = E.find(&re.program, &re.scratch, corpus, .{ .start = pos });
            const om = pikevm.search(&pp, &ps, corpus, .{ .start = pos });
            if (am == null or om == null) {
                try testing.expect(am == null and om == null);
                break;
            }
            try testing.expectEqual(om.?.start, am.?.start);
            try testing.expectEqual(om.?.end, am.?.end);
            pos = if (am.?.end > am.?.start) am.?.end else am.?.end + 1;
        }
    }
}

test "auto: leading-class scan gate — digit/number classes yes, letter classes no (revert-failing)" {
    // The selectivity gate must admit digit/number leading classes (sparse on all corpora) and
    // decline letter classes (dense, or broad high-byte lead sets). Reverting `leadingClassFirst`
    // or loosening `classLeadSelective` flips one of these.
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, want: bool };
    const cases = [_]Case{
        .{ .pat = "\\d+", .want = true },
        .{ .pat = "\\p{N}+", .want = true },
        .{ .pat = "[0-9]+", .want = true },
        .{ .pat = "\\d{4}", .want = true }, // counted rep of a class still leads with the class
        .{ .pat = "\\p{Lu}\\p{Ll}+", .want = true }, // sparse ASCII lead (A–Z) + broad tail → derived skip (`asciiLeadDerived`)
        .{ .pat = "\\p{Lu}+", .want = true }, // uppercase run — same sparse-ASCII-lead admission
        .{ .pat = "[A-Za-z]+", .want = false }, // ASCII letters (lowercase present)
        .{ .pat = "\\p{L}+", .want = false }, // all letters
        .{ .pat = "\\w+", .want = false }, // word chars include a-z
        .{ .pat = "foo\\d+", .want = false }, // a leading literal wins → no class scan
    };
    inline for (cases) |c| {
        const f = try filterOf(gpa, c.pat);
        try testing.expectEqual(c.want, f.class_lead != null);
    }
}

test "auto: asciiLeadDerived — sparse-ASCII lead admitted (sound over-approx), empty/dense declined" {
    // A sparse uppercase ASCII lead with a broad high-byte tail (the `\p{Lu}` shape) → derived
    // set = {its ASCII members} ∪ {all high bytes}. The ASCII members are preserved exactly and
    // every high byte is a candidate (sound: no real match start is ever skipped).
    {
        var bs = hir.ByteSet{};
        var c: u8 = 'A';
        while (c <= 'Z') : (c += 1) bs.set(c);
        bs.set(0xC3); // Latin-1 uppercase lead (À…)
        bs.set(0xD0); // Cyrillic uppercase lead
        const d = asciiLeadDerived(bs) orelse return error.TestUnexpectedResult;
        try testing.expect(d.has('A') and d.has('Z'));
        try testing.expect(!d.has('a') and !d.has('5')); // ASCII non-members stay skippable
        var b: u16 = 0x80; // every high byte is a candidate
        while (b < 0x100) : (b += 1) try testing.expect(d.has(@intCast(b)));
    }
    // Empty ASCII portion (a pure non-ASCII set) → null: nothing to skip to, only overhead.
    {
        var bs = hir.ByteSet{};
        bs.set(0xE4);
        bs.set(0xE5);
        try testing.expectEqual(@as(?hir.ByteSet, null), asciiLeadDerived(bs));
    }
    // A whole lowercase alphabet (letter-dense, the `\p{L}+`/`\w+` shape) → null.
    {
        var bs = hir.ByteSet{};
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) bs.set(c);
        bs.set(0xD0);
        try testing.expectEqual(@as(?hir.ByteSet, null), asciiLeadDerived(bs));
    }
    // Whitespace member (lands almost everywhere) → null.
    {
        var bs = hir.ByteSet{};
        bs.set(' ');
        bs.set('A');
        bs.set(0xD0);
        try testing.expectEqual(@as(?hir.ByteSet, null), asciiLeadDerived(bs));
    }
}

test "auto: class_finder / prefix_teddy are built to back the filter facts" {
    const gpa = testing.allocator;
    // A class-led pattern builds the leading-class scanner (both build paths).
    {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, "\\d+", &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        defer freeProgram(gpa, &program);
        try testing.expect(program.filter.class_lead != null);
        try testing.expect(program.class_finder != null);
    }
    // A letter-class pattern does not.
    {
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, "\\p{L}+", &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        defer freeProgram(gpa, &program);
        try testing.expect(program.class_finder == null);
    }
    // The multi-prefix Teddy is built for a case-variant set and a top-level alternation set,
    // but not for a lone leading literal — only on a native-shuffle target (else scalar path).
    if (comptime simd.has_native_shuffle16) {
        const Case = struct { pat: []const u8, want: bool };
        const cases = [_]Case{
            .{ .pat = "(?i)the", .want = true }, // case-variant set → Teddy
            .{ .pat = "Holmes.{0,30}Watson|Watson.{0,30}Holmes", .want = true }, // alternation set
            .{ .pat = "foo\\d+", .want = false }, // single leading literal → memmem, not Teddy
            .{ .pat = "\\d+", .want = false }, // class scan, no prefix set
        };
        inline for (cases) |c| {
            var diag: compile.Diagnostic = .{};
            const ast = try compile.parse(gpa, c.pat, &diag);
            defer ast.deinit(gpa);
            const h = try hir.buildAlloc(gpa, ast, .{});
            defer hir.deinitHir(gpa, h);
            var program = try buildAlloc(gpa, h, .{});
            defer freeProgram(gpa, &program);
            try testing.expectEqual(c.want, program.prefix_teddy != null);
        }
    }
}

test "auto: case-variant + class-scan prefilters find/count correctly (functional)" {
    // Smoke functional checks on the dispatcher's own harness (the heavy differential lives in
    // conformance.zig). Leftmost-first, mixed case, multiple matches.
    try expectFind("(?i)the", "oh THE end", "THE");
    try expectFind("(?i)sherlock holmes", "she Sherlock Holmes!", "Sherlock Holmes");
    // The rare-window prefilter places the Teddy set at an interior window (`ck `) reached past
    // the leading `s`, whose fold includes the 2-byte `ſ` — so the offset is a RANGE. Both the
    // plain and the `ſ`-shifted spellings must still match (the range covers the shift).
    try expectFind("(?i)sherlock holmes", "x sherlock holmes y", "sherlock holmes");
    try expectFind("(?i)sherlock holmes", "x \u{17F}herlock holmes y", "\u{17F}herlock holmes"); // long-s
    try testing.expect(blk: {
        var re2 = try Compiled.init("(?i)sherlock holmes");
        defer re2.deinit();
        break :blk E.count(&re2.program, &re2.scratch, "Sherlock Holmes and SHERLOCK HOLMES, not sherlock x", .{}) == 2;
    });
    try expectFind("\\d+", "no nums .... 4567 yes", "4567");
    var re = try Compiled.init("(?i)the");
    defer re.deinit();
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, "the The tHe x", .{}));
    var rn = try Compiled.init("\\d+");
    defer rn.deinit();
    try testing.expectEqual(@as(usize, 3), E.count(&rn.program, &rn.scratch, "1 .. 22 ... 333", .{}));
}

// ── White-box + functional tests for the v0.5.0 prefilters ──────────────────────────────
// (`\b`-literal O(1) confirm, fixed-offset interior anchor, line-anchored capture/span dispatch)

test "auto: lit_wb_confirm shape detection (revert-failing)" {
    // The `\b`-wrapped pure-literal fast confirm must trigger for EXACTLY a literal wrapped in
    // leading/trailing word-boundary assertions and nothing else. Reverting `literalWbShape`
    // (or the `prefix_len == fullRunBytes` untruncated guard) flips one of these.
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, on: bool, lead: WbAssert = .none, trail: WbAssert = .none };
    const cases = [_]Case{
        .{ .pat = "\\bthe\\b", .on = true, .lead = .boundary, .trail = .boundary },
        .{ .pat = "the\\b", .on = true, .lead = .none, .trail = .boundary },
        .{ .pat = "\\bthe", .on = true, .lead = .boundary, .trail = .none },
        .{ .pat = "\\Bthe\\B", .on = true, .lead = .not_boundary, .trail = .not_boundary },
        .{ .pat = "the", .on = false }, // no boundary → plain memmem path
        .{ .pat = "^the$", .on = false }, // text anchors, not word boundaries
        .{ .pat = "\\bthe\\w+", .on = false }, // more than the literal consumes
        .{ .pat = "\\bthe\\b!", .on = false }, // a trailing literal after the boundary
        .{ .pat = "\\b\\d{4}\\b", .on = false }, // leading atom is a class, not a fixed literal
        .{ .pat = "\\babcdefghijklmnopqrstuvwxyz\\b", .on = false }, // literal > MAX_PREFIX_LEN → truncated, declined
    };
    inline for (cases) |c| {
        const f = try filterOf(gpa, c.pat);
        try testing.expectEqual(c.on, f.lit_wb_confirm);
        if (c.on) {
            try testing.expectEqual(c.lead, f.lit_wb_lead);
            try testing.expectEqual(c.trail, f.lit_wb_trail);
        }
    }
}

test "auto: inner_fixed_off (fixed leading run) detection (revert-failing)" {
    // A fixed-length leading class run before the anchor yields `inner_fixed_off`; a variable run
    // (`+`/`*`/`{m,n}`) leaves it null (the reverse-scan path). Reverting `leadFixedCps` breaks this.
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, byte: ?u8, off: ?u32 };
    const cases = [_]Case{
        .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .byte = '-', .off = 4 },
        .{ .pat = "\\d{2}-\\d{2}", .byte = '-', .off = 2 },
        .{ .pat = "(\\d{4})-(\\d{2})-(\\d{2})", .byte = '-', .off = 4 }, // capture-wrapped leading run
        .{ .pat = "[\\w.+-]+@[\\w-]+", .byte = '@', .off = null }, // variable `+` lead → no fixed offset
    };
    inline for (cases) |c| {
        const f = try filterOf(gpa, c.pat);
        try testing.expectEqual(c.byte, f.inner_byte);
        try testing.expectEqual(c.off, f.inner_fixed_off);
    }
}

test "auto: line_anchored detection (revert-failing)" {
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, on: bool };
    const cases = [_]Case{
        .{ .pat = "(?m)^foo", .on = true },
        .{ .pat = "(?m)^(\\w+) (\\w+)", .on = true },
        .{ .pat = "^foo", .on = false }, // text_start: the tighter `anchored_start` covers it
        .{ .pat = "foo", .on = false },
        .{ .pat = "(?m)foo$", .on = false }, // line_end, not a leading line_start
    };
    inline for (cases) |c| {
        const f = try filterOf(gpa, c.pat);
        try testing.expectEqual(c.on, f.line_anchored);
    }
}

test "auto: \\b-literal fast confirm finds/counts correctly (ASCII + non-ASCII)" {
    try expectFind("\\bthe\\b", "soothe the other", "the");
    try expectNoMatch("\\bthe\\b", "breathe theory bathe");
    try expectFind("\\bthe\\b", "café the end", "the"); // non-ASCII input → lazy Unicode-\b arm
    try expectFind("the\\b", "soothe the!", "the");
    try expectFind("\\bcat", "scatter a cat!", "cat");
    var re = try Compiled.init("\\bthe\\b");
    defer re.deinit();
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, "the theatre then the end the", .{}));
    var rn = try Compiled.init("\\bcat\\b"); // café (non-ASCII) must not break the count
    defer rn.deinit();
    try testing.expectEqual(@as(usize, 2), E.count(&rn.program, &rn.scratch, "a cat café a cat!", .{}));
}

test "auto: \\d{4}-\\d{2}-\\d{2} fixed-offset confirm (ASCII + non-ASCII + alignment)" {
    try expectFind("\\d{4}-\\d{2}-\\d{2}", "ip - - 2026-06-07 ok", "2026-06-07"); // dash-dense
    try expectFind("\\d{4}-\\d{2}-\\d{2}", "123456-78-90", "3456-78-90"); // alignment: 6 leading digits
    try expectFind("\\d{4}-\\d{2}-\\d{2}", "café 2020-01-02 z", "2020-01-02"); // non-ASCII → reverse-scan fallback
    try expectNoMatch("\\d{4}-\\d{2}-\\d{2}", "12-34-56 no four-digit year");
    var re = try Compiled.init("\\d{4}-\\d{2}-\\d{2}");
    defer re.deinit();
    try testing.expectEqual(@as(usize, 2), E.count(&re.program, &re.scratch, "x 2020-01-02 y 1999-12-31 z", .{}));
}

test "auto: (?m)^ line-anchored span + captures fast path" {
    var re = try Compiled.init("(?m)^(\\S+) \\[([^\\]]+)\\] (\\d{3})");
    defer re.deinit();
    try testing.expect(re.program.edfa_prog == null); // too big for the eager DFA → line-anchored arm
    try testing.expect(re.program.filter.line_anchored);
    const input = "a [x] 200\nbad line\nb [y] 404";
    try testing.expectEqual(@as(usize, 2), E.count(&re.program, &re.scratch, input, .{})); // span via lineAnchoredSpan
    var slots: [8]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, input, &slots, re.meta, .{}).?; // via lineAnchoredCaptures
    try testing.expectEqualStrings("a [x] 200", c.match().slice(input));
    try testing.expectEqualStrings("a", c.groupSlice(1).?);
    try testing.expectEqualStrings("x", c.groupSlice(2).?);
    try testing.expectEqualStrings("200", c.groupSlice(3).?);
}

test "auto: a big-class join (`\\w+@\\w+`, email) skips the eager DFA for the lazy one (compile-time gate)" {
    // The eager-DFA determinization budget (`EAGER_BYTE_INST_MAX`) keeps a big Unicode-class join
    // off the eager arm: `\w+@\w+` / `[\w.+-]+@…` have huge byte NFAs whose determinization costs
    // hundreds of ms (and email's overflows `max_states` and declines anyway). They must still get
    // a DFA span arm — the LAZY one ("nfa+dfa") — and a small class scan must KEEP the eager arm.
    const gpa = testing.allocator;
    const Case = struct { pat: []const u8, route: []const u8 };
    const cases = [_]Case{
        .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .route = "nfa+edfa" }, // small → eager kept
        .{ .pat = "\\d+", .route = "nfa+edfa" },
        .{ .pat = "\\p{L}+", .route = "nfa+edfa" }, // ~3.9k insts, still under the gate
        .{ .pat = "\\w+@\\w+", .route = "nfa+dfa" }, // big join → lazy
        .{ .pat = "[\\w.+-]+@[\\w-]+\\.[\\w.-]+", .route = "nfa+dfa" }, // email → lazy (was ~900ms eager waste)
    };
    inline for (cases) |c| {
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

test {
    testing.refAllDecls(@This());
}
