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
//!       - **multi-prefix set** — a top-level alternation's leading literals (`Holmes…|Watson…`)
//!         OR a synthesised **case-variant set** for a small-class / `(?i)` lead (`(?i)the` →
//!         `{THE…the}`, `(?i)что`) — → the **Teddy** SIMD multi-literal scan (`prefix_teddy`),
//!         scalar `multiPrefixFrom` as the comptime/non-native fallback;
//!       - **interior anchor** — a required literal after a leading class run (`[\w.+-]+@…`,
//!         `\d{4}-…`): memchr to the anchor, then either a bounded reverse-scan + native find
//!         (variable run) or, when the leading run is **fixed-length** and the input is ASCII, a
//!         bounded confirm at the pinned start `anchor − off` (`inner_fixed_off`, one confirm per
//!         occurrence — the win on a dash-dense haystack);
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

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");
const nfa = @import("../nfa.zig");
const simd = @import("../simd.zig");
const memmem = @import("../memmem.zig");
const teddy = @import("../teddy.zig");
const classscan = @import("../classscan.zig");

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
        const n = caseVariantSet(h, &f);
        if (n >= 2) {
            f.prefix_set_n = n;
            f.prefix_set_case_variant = true;
        }
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

    // 4. Leading-class first-byte scan (`\d+`, `\p{N}+`, `\d{4}-…`): no literal / set / inner
    //    anchor applies, but the match begins with a class byte — SIMD-scan to the next
    //    member. Only when the set is selective (a near-universal set like `\p{L}+` is not).
    if (f.prefix_len == 0 and f.prefix_set_n == 0 and f.inner_byte == null) {
        if (an.leading_class_first) |bs| {
            if (classLeadSelective(bs)) f.class_lead = bs;
        }
    }

    // 5. Rarest required byte for a presence fast-reject — only when nothing above gives an
    //    actual skip (with a skip the byte is already implied present).
    if (f.prefix_byte == null and f.prefix_set_n == 0 and f.inner_byte == null and f.class_lead == null and !an.required_bytes.isEmpty()) {
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
    return try teddy.compileAlloc(gpa, slices[0..f.prefix_set_n]);
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
        const eager: BuildError!edfa.Program = if (eager_small_enough) edfa.buildAlloc(gpa, h, .{}) else error.Unsupported;
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
fn memmemFrom(input: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (start <= input.len) start else null;
    if (needle.len == 1) return memchrFrom(input, start, needle[0]);
    const f = memmem.Finder.init(needle);
    return f.find(input, start);
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
        const at = memmemFrom(input, start, needle) orelse continue;
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
                if (input.len - hit < filter.min_bytes) return null;
                if (confirmAt(p, s, input, hit, slots)) |m| return m;
                pos = hit + 1;
            }
            return null;
        }
        o.start = nextPrefixHit(filter, tdy, input, o.start) orelse return null;
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
fn runByteDfa(dp: *const dfa.Program, filter: *const Filter, tdy: ?*const teddy.Teddy, cf: ?*const classscan.ClassFinder, d: *dfa.Scratch, input: []const u8, opts: SearchOptions, match_only: bool, input_ascii: bool) ?Match {
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
        o.start = memmemFrom(input, o.start, pfx) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (filter.prefix_set_n > 0) {
        // Multi-prefix: per-occurrence anchored confirm when bounded (the real win), else one
        // skip + a single native DFA find. See `runNfa` for the bound's soundness.
        if (filter.bounded_confirm) {
            var pos = opts.start;
            while (nextPrefixHit(filter, tdy, input, pos)) |hit| {
                if (input.len - hit < filter.min_bytes) return null;
                if (dfaConfirmAt(dp, d, input, hit, match_only)) |m| return m;
                pos = hit + 1;
            }
            return null;
        }
        o.start = nextPrefixHit(filter, tdy, input, o.start) orelse return null;
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
        o.start = innerSkipFrom(filter, input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
    } else if (cf) |c| {
        // Leading-class SIMD skip → one native DFA find from the first candidate (sound; see runNfa).
        o.start = c.find(input, o.start) orelse return null;
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
/// (length gate, `anchored_start` short-circuit, leading-literal SIMD `memmem` start-skip,
/// rarest-required-byte fast-reject) in front of the frozen-table walk. The eager DFA is
/// stateless; the only state is `probes`, the ReDoS observable (`Scratch.confirm_probes`)
/// incremented per per-occurrence confirm. Captures never come here — they always use the Pike VM.
fn runEdfa(ep: *const edfa.Program, filter: *const Filter, tdy: ?*const teddy.Teddy, cf: ?*const classscan.ClassFinder, input: []const u8, opts: SearchOptions, match_only: bool, input_ascii: bool, probes: *u64) ?Match {
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
                if (input.len - hit < filter.min_bytes) return null;
                probes.* += 1; // ReDoS observable (bounded ⇒ stays linear)
                if (edfaConfirmAt(ep, input, hit, match_only)) |m| return m;
                pos = hit + 1;
            }
            return null;
        }
        o.start = nextPrefixHit(filter, tdy, input, o.start) orelse return null;
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
        o.start = c.find(input, o.start) orelse return null;
        if (input.len - o.start < filter.min_bytes) return null;
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

/// Whether the fixed-offset interior-anchor confirm may engage for this search: the program has a
/// fixed leading run (`inner_fixed_off`) **and** the input is all-ASCII (so each leading code point
/// is one byte and the anchor sits at a fixed byte offset). Computed (and cached on the scratch)
/// only for such programs, so a pattern without the feature never pays the O(n) ASCII scan. `false`
/// keeps the sound reverse-scan + native-find path.
inline fn fixedAscii(program: *const Program, scratch: *Scratch, input: []const u8) bool {
    return program.filter.inner_fixed_off != null and inputAllAscii(scratch, input);
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
            if (edfaArm(program, scratch, input)) |ep| return runEdfa(ep, &program.filter, teddyPtr(program), classPtr(program), input, opts, true, fixedAscii(program, scratch, input), &scratch.confirm_probes) != null;
            // Lazy DFA fallback (prefiltered) when built and not disabled.
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const r = runByteDfa(dp, &program.filter, teddyPtr(program), classPtr(program), d, input, opts, true, fixedAscii(program, scratch, input));
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
            if (edfaArm(program, scratch, input)) |ep| return runEdfa(ep, &program.filter, teddyPtr(program), classPtr(program), input, opts, false, fixedAscii(program, scratch, input), &scratch.confirm_probes);
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const r = runByteDfa(dp, &program.filter, teddyPtr(program), classPtr(program), d, input, opts, false, fixedAscii(program, scratch, input));
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
                const m = runEdfa(ep, &program.filter, teddyPtr(program), classPtr(program), input, opts, false, fixedAscii(program, scratch, input), &scratch.confirm_probes) orelse return null;
                return fillCapturesAnchored(program, &scratch.inner.nfa, p, input, slots, m, opts);
            }
            if (!scratch.dfa_disabled) {
                if (scratch.dfa_sc) |*d| if (program.dfa_prog) |*dp| {
                    const span = runByteDfa(dp, &program.filter, teddyPtr(program), classPtr(program), d, input, opts, false, fixedAscii(program, scratch, input));
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
        .{ .pat = "\\p{Lu}\\p{Ll}+", .want = false }, // broad uppercase letter class (high lead bytes)
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
