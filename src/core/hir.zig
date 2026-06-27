//! AST → HIR: the desugared, resolved intermediate form handed to backends.
//!
//! The HIR is the stable contract between the fixed frontend (scanner → AST →
//! HIR) and pluggable backends (Pike VM, DFA, …). It is produced once, is
//! immutable, and is computable at BOTH comptime and runtime from the same
//! code — only where the storage lives differs (ro_data vs heap), exactly like
//! the scanner/compile split.
//!
//! What the builder does (driven by comptime-known `Options`):
//!   * Apply & drop flags. `(?i)`/`(?m)`/`(?s)` and scoped `(?flags:…)` groups
//!     disappear: `m` resolves `^`/`$` into the right anchor kind, `s` sets
//!     dot-all on `.`, `i` (with `Options.case_fold`) folds literals/classes.
//!     Backends never see flags.
//!   * Resolve everything Unicode to concrete code-point RANGES. `\d \w \s`,
//!     `\p{…}`/`\P{…}`, scripts, and `[...]` collapse into one normalized,
//!     sorted, merged, non-overlapping range set with negation already applied.
//!     ezi_code's *range tables* (added in 0.3.0; enumerable at comptime) are
//!     consulted here, once; after HIR a backend does plain range membership —
//!     no Unicode tables at match time for classes.
//!   * Case folding. `simple` widens literal/class ranges to their simple-fold
//!     closure via ezi_code's enumerable fold table; `full` additionally expands
//!     the 1→many foldings (`ß`→`ss`, `ﬀ`→`ff`) for literals into an alternation —
//!     see `Options.case_fold` and `lowerLiteralFull`.
//!   * Simplify. Merge adjacent literals into runs, inline non-capturing groups
//!     (keeping capture numbering), drop redundant single-repeat wrappers.
//!   * Keep `{m,n}` compact (each backend lowers it its own way).
//!   * `\X` stays an opaque `grapheme` node (needs runtime segmentation).
//!   * Attach cheap `Analysis` (anchored?, min/max len, whole-literal, …).
//!
//! Storage-agnostic core, like the scanner: `build` fills caller-provided
//! `Buffers`; the comptime/runtime wrappers (`buildComptime`, `buildAlloc`)
//! are the only places that know where those buffers live. Because the size of
//! a resolved class is data-dependent (a single `\p{L}` is hundreds of ranges),
//! sizing uses a `measure` pre-pass that runs the identical lowering in
//! count-only mode to get exact output sizes — so comptime arrays stay exact
//! and small rather than wildly over-provisioned.
//!
//! ══════════════════════════════════════════════════════════════════════════════
//! USAGE GUIDE
//! ══════════════════════════════════════════════════════════════════════════════
//!
//! ## What this module CONSUMES
//!
//! An `ast.Ast` (produced by `core/scanner.zig`, wrapped by `core/compile.zig`)
//! plus a comptime-known `Options`. The AST is the faithful, flag-bearing syntax
//! tree — three parallel arrays (`nodes`/`children`/`class_items`), capture
//! `names`, a `root` index, a `capture_count`, and the global `flags`. The builder
//! only READS the AST; it never mutates it, and the AST may be freed the instant
//! `build`/`buildAlloc`/`buildComptime` returns (the HIR copies out everything it
//! keeps, except `names`, which it borrows — see "Lifetimes" below).
//!
//! ## What this module PRODUCES / EMITS
//!
//! One immutable `Hir` value: a structure-of-arrays "program shape" whose slices
//! point into caller storage (`ro_data` at comptime, heap at runtime). Its arrays:
//!
//!   * `nodes`         — every HIR `Node`, flat. `nodes[root]` is the tree root.
//!   * `children`      — packed child-index lists. A `concat`/`alternation` node's
//!                       children are `children[d.start .. d.start + d.len]`.
//!   * `ranges`        — packed, sorted, merged, NON-overlapping, POSITIVE code-point
//!                       `Range`s. A `class` node's set is
//!                       `ranges[c.start .. c.start + c.len]`.
//!   * `literals`      — packed post-fold `CodePoint`s. A `literal` run is
//!                       `literals[r.start .. r.start + r.len]`.
//!   * `names`         — capture-group names, borrowed from the pattern string.
//!   * `root`          — index of the root node within `nodes`.
//!   * `capture_count` — number of capturing groups (group 0, the whole match,
//!                       is NOT counted).
//!   * `analysis`      — precomputed, sound prefilter/feasibility facts (`Analysis`).
//!
//! Everything is desugared and resolved. NO flags survive; `\d`/`\w`/`\s`,
//! `\p{…}`/`\P{…}`, scripts, and `[...]` are already sorted/merged ranges with
//! negation applied; `(?i)a` is already `[Aa]`; `(?m)^` is already `line_start`.
//! A backend does PLAIN range membership and never performs a Unicode-table lookup
//! for a class at match time.
//!
//! ## How to TRAVERSE a `Hir`
//!
//! Start at `h.nodes[h.root]` and `switch` on `node.tag` (`Tag`). The tag selects
//! the active field of `node.data` — a BARE union, so read only the field the tag
//! names (any other field is undefined):
//!
//! ```zig
//! const hir = @import("core/hir.zig");
//!
//! fn walk(h: hir.Hir, idx: u32) void {
//!     const node = h.nodes[idx];
//!     switch (node.tag) {
//!         .empty => {}, //                          matches the empty string
//!         .literal => { //                          a run of exact code points
//!             const r = node.data.run; //           Node.Run{ start, len }
//!             for (h.literals[r.start .. r.start + r.len]) |cp| { _ = cp; }
//!         },
//!         .class => { //                            a resolved class (positive ranges)
//!             const c = node.data.class; //         Node.Class{ start, len }
//!             // len == 0 ⇒ the class matches NOTHING (a fully-negated total set).
//!             for (h.ranges[c.start .. c.start + c.len]) |rg| { _ = rg; } // [lo,hi]
//!         },
//!         .any => { _ = node.data.any.dot_all; }, // `.`  (dot_all ⇒ also matches \n)
//!         .grapheme => {}, //                       `\X` — opaque; needs segmentation
//!         .anchor => { _ = node.data.anchor.kind; }, // AnchorKind (m already applied)
//!         .concat, .alternation => { //             composite: indexes children[]
//!             const d = node.data.children; //      Node.Children{ start, len }
//!             for (h.children[d.start .. d.start + d.len]) |ci| walk(h, ci);
//!         },
//!         .repetition => { //                       child repeated min..max times
//!             const rep = node.data.repetition; //  Node.Repetition
//!             walk(h, rep.child);
//!         },
//!         .capture => { //                          a capturing group
//!             const cap = node.data.capture; //     Node.Capture{ child, index, name }
//!             walk(h, cap.child);
//!         },
//!     }
//! }
//! ```
//!
//! ## How to BUILD a `Hir`
//!
//! Three entry points run the SAME lowering; they differ only in where storage
//! lives. Prefer the wrappers (a, b); reach for the storage-agnostic core (c) only
//! when you want to own the buffers (freestanding / no-heap / custom arena).
//!
//! ```zig
//! // (a) Runtime, heap-backed. Free with `deinitHir`.
//! const h = try hir.buildAlloc(allocator, ast, .{ .case_fold = .simple });
//! defer hir.deinitHir(allocator, h);
//!
//! // (b) Comptime, baked into ro_data. No allocator, no deinit; returns an
//! //     `Outcome` union you switch on.
//! const h2 = comptime switch (hir.buildComptime(ast, .{})) {
//!     .ok => |x| x,
//!     .fail => @compileError("HIR build failed"),
//! };
//!
//! // (c) Storage-agnostic core (no allocator): measure exact sizes, then emit
//! //     into buffers YOU own. This is exactly what (a)/(b) wrap. `scratch` must
//! //     be at least `scratchSizes(ast)`; each output buffer at least its `Sizes`.
//! const ss = hir.scratchSizes(ast);
//! var stack: [ss.stack]u32 = undefined;
//! var main:   [ss.ranges]hir.Range = undefined;
//! var member: [ss.ranges]hir.Range = undefined;
//! var aux:    [ss.ranges]hir.Range = undefined;
//! const scratch = hir.Scratch{ .stack = &stack, .main = &main, .member = &member, .aux = &aux };
//! const sizes = try hir.measure(ast, .{}, scratch);
//! // …declare/allocate nodes/children/ranges/literals/names of `sizes` lengths…
//! const h3 = try hir.build(ast, .{}, scratch, buffers);
//! ```
//!
//! ## FAILURE & limits
//!
//! The only failure is `error.PatternTooComplex` — a resolved class or node count
//! that overruns the caller's buffers (e.g. an enormous class, capped at
//! `CLASS_SCRATCH_CAP` ranges). At comptime the same overrun surfaces as
//! `Outcome.fail`. The builder NEVER overruns: every write is bounds-guarded.
//!
//! ## LIFETIMES (read before retaining a `Hir`)
//!
//!   * `names` entries BORROW the original pattern string — keep the pattern alive
//!     for as long as you read `names`, or dupe them (the front-door `Compiled`
//!     dupes them so a compiled regex outlives the pattern).
//!   * A comptime `Hir`'s slices are `const` ro_data — NEVER pass one to `deinitHir`.
//!   * The produced `Hir` is immutable and freely shareable across threads.

const std = @import("std");

const ast = @import("ast.zig");
const token = @import("token.zig");

const utils = @import("utils");
const encoding = utils.unicode.encoding;
const utf8 = utils.unicode.utf8;
const CodePoint = utils.unicode.CodePoint;
const props = utils.unicode.properties;
const u_scripts = utils.unicode.scripts;
const casing = utils.unicode.casing;

pub const Flags = token.Flags;
pub const PerlClassKind = token.PerlClassKind;
pub const PropertyId = token.PropertyId;
pub const GeneralCategoryGroup = token.GeneralCategoryGroup;

const MAX_CP: CodePoint = 0x10FFFF;

/// Largest number of code-point ranges a single class may hold while being
/// resolved (before and after merge). Generous: the union of every Unicode
/// General_Category is ~4k ranges. Exceeding it raises `error.PatternTooComplex`.
const CLASS_SCRATCH_CAP: usize = 1 << 14;

// ── Public types ───────────────────────────────────────────────────────────────

/// Options governing the AST→HIR lowering. Comptime-known on both paths so the
/// HIR shape (and backends) can specialize.
///
/// @stable-since: v0.1.0
pub const Options = struct {
    /// How `i` (case-insensitive) folding is realized in the HIR.
    ///   `none`   — no folding, even under `(?i)`.
    ///   `simple` — widen literal/class ranges to the simple-fold closure (1:1).
    ///   `full`   — `simple` PLUS the 1→many expansions: `(?i)ß` also matches
    ///              `ss`, `(?i)ﬀ` also matches `ff` (literals only; classes use
    ///              simple folding). See `CaseFold.full`.
    case_fold: CaseFold = .simple,

    /// Unicode mode for the shorthand classes. When `true` (the default),
    /// `\d`/`\w`/`\s` resolve to their full Unicode definitions (any Unicode digit,
    /// word, or whitespace code point). When `false` (ASCII mode) they use the
    /// classic ASCII sets — `\d`=`[0-9]`, `\w`=`[0-9A-Za-z_]`, `\s`=`[ \t\n\v\f\r]` —
    /// which keeps automata small. NOTE: this affects only the shorthand classes;
    /// `.` and `\b` remain code-point / Unicode-aware.
    unicode: bool = true,
};

/// How `i` (case-insensitive) folding is realized when lowering literals/classes.
///
/// @stable-since: v0.1.0
pub const CaseFold = enum {
    /// No folding at all, even under `(?i)` — `a` matches only `a`.
    none,
    /// Widen every literal/class range to its SIMPLE-fold closure (a 1:1 mapping):
    /// `a` under `(?i)` becomes `[Aa]`, `σ` becomes `[Σςσ]`. The default.
    simple,
    /// FULL folding: everything `simple` does, plus the 1→many expansions a single
    /// code point can fold to. A literal whose full fold expands (`ß`→`ss`,
    /// `ﬀ`→`ff`, `ﬃ`→`ffi`) lowers to an alternation matching BOTH the single code
    /// point (any case) AND its spelled-out expansion (each letter, any case) — so
    /// `(?i)ß` matches `ß`, `ẞ`, and `ss`/`SS`/`ſs`. The pattern is folded, not the
    /// input, so the converse (`ss` matching a lone `ß`) does not hold, and
    /// character classes use simple folding only. See `lowerLiteralFull`.
    full,
};

/// An inclusive code-point range `[lo, hi]`, the atom of a resolved class. A bare
/// single code point is encoded as `lo == hi`. Inside a `class` node's slice these
/// are sorted by `lo`, merged, and non-overlapping.
///
/// @stable-since: v0.1.0
pub const Range = struct {
    /// Inclusive lower bound — the smallest code point the range covers.
    lo: CodePoint,
    /// Inclusive upper bound — the largest code point the range covers (≥ `lo`).
    hi: CodePoint,
};

/// Resolved anchor kind. Flags (`m`) are already applied: `line_*` only appear
/// when multiline was in effect, otherwise `^`/`$` became `text_*`.
///
/// @stable-since: v0.1.0
pub const AnchorKind = enum {
    /// `\A`, or `^` without multiline — start of the whole input.
    text_start,
    /// `\z`/`\Z`, or `$` without multiline — end of the whole input.
    text_end,
    /// `^` with multiline — start of input or just after a `\n`.
    line_start,
    /// `$` with multiline — end of input or just before a `\n`.
    line_end,
    /// `\b` — boundary between a word and a non-word code point.
    word_boundary,
    /// `\B` — a position that is not a word boundary.
    not_word_boundary,
};

/// @stable-since: v0.1.0
pub const Tag = enum {
    /// Matches the empty string.
    empty,
    /// A run of exact code points (post-fold), in `literals[start..start+len]`.
    literal,
    /// A resolved class: positive, sorted, merged ranges in `ranges[..]`. Any
    /// negation (`[^…]`, `\D`, `\P`) is already applied — membership is "cp in
    /// some range", nothing more.
    class,
    /// `.` — any code point, or any-except-`\n` when `!dot_all`.
    any,
    /// `\X` — one extended grapheme cluster (opaque; needs runtime segmentation).
    grapheme,
    /// A zero-width assertion.
    anchor,
    /// Sequence of children in `children[start..start+len]`.
    concat,
    /// Alternatives in `children[start..start+len]`.
    alternation,
    /// `child` repeated `min..max` times (max null = unbounded).
    repetition,
    /// Capturing group wrapping `child`.
    capture,
};

/// One node of the HIR tree. `tag` selects which member of `data` is active — read
/// ONLY that member (`data` is a bare union, not tagged). Children, class ranges,
/// and literal runs are referenced by `(start, len)` index pairs into the `Hir`'s
/// `children` / `ranges` / `literals` arrays, never by pointer. See `Tag` for what
/// each variant means and `Hir` for the backing arrays.
///
/// @stable-since: v0.1.0
pub const Node = struct {
    /// Discriminator: which kind of node this is, and which `data` field is live.
    tag: Tag,
    /// The payload. Read the field named by `tag`; the others are undefined.
    data: Data,

    /// `literal` payload: a run of `len` code points at `literals[start..start+len]`.
    pub const Run = struct {
        /// Offset of the first code point in `Hir.literals`.
        start: u32,
        /// Number of code points in the run (≥ 1).
        len: u32,
    };
    /// `class` payload: `len` sorted/merged positive ranges at
    /// `ranges[start..start+len]`. `len == 0` ⇒ matches nothing (fully-negated set).
    pub const Class = struct {
        /// Offset of the first range in `Hir.ranges`.
        start: u32,
        /// Number of ranges (`0` ⇒ an unmatchable class).
        len: u32,
    };
    /// `any` payload: the resolved `.` wildcard.
    pub const Any = struct {
        /// True under `(?s)`: `.` matches EVERY code point including `\n`. False ⇒
        /// `.` matches any code point except `\n`.
        dot_all: bool,
    };
    /// `anchor` payload: a zero-width assertion.
    pub const Anchor = struct {
        /// Which assertion — already resolved for multiline (`^`→`line_start` or
        /// `text_start`, `$`→`line_end`/`text_end`). See `AnchorKind`.
        kind: AnchorKind,
    };
    /// `concat` / `alternation` payload: `len` child node indices at
    /// `children[start..start+len]` — sequence members, or alternation branches in
    /// priority (leftmost-first) order.
    pub const Children = struct {
        /// Offset of the first child index in `Hir.children`.
        start: u32,
        /// Number of children (always ≥ 2 — the builder collapses the 0/1-child cases).
        len: u32,
    };
    /// `repetition` payload: `child` repeated `min..max` times.
    pub const Repetition = struct {
        /// Index of the repeated child node in `Hir.nodes`.
        child: u32,
        /// Minimum repeat count (`*`→0, `+`→1, `{m,n}`→m).
        min: u32,
        /// Maximum repeat count, or `null` for unbounded (`*`, `+`, `{m,}`).
        max: ?u32,
        /// Greedy (`a*`) when true, lazy (`a*?`) when false. Backends encode this as
        /// split priority; it changes WHICH match wins, never WHETHER one exists.
        greedy: bool,
    };
    /// `capture` payload: a capturing group wrapping `child`.
    pub const Capture = struct {
        /// Index of the group's body node in `Hir.nodes`.
        child: u32,
        /// 1-based capture-group number (group 0 is the whole match). Its capture
        /// slots are at offsets `2*index` (start) and `2*index + 1` (end).
        index: u32,
        /// Index into `Hir.names` for a named group `(?<n>…)`, else `null`.
        name: ?u32,
    };

    /// The per-tag payload. A BARE union (untagged): `Node.tag` is the discriminator,
    /// so it is the caller's responsibility to read only the active field.
    pub const Data = union {
        /// active when `tag == .literal`
        run: Run,
        /// active when `tag == .class`
        class: Class,
        /// active when `tag == .any`
        any: Any,
        /// active when `tag == .anchor`
        anchor: Anchor,
        /// active when `tag == .concat` or `.alternation`
        children: Children,
        /// active when `tag == .repetition`
        repetition: Repetition,
        /// active when `tag == .capture`
        capture: Capture,
        /// active when `tag == .empty` or `.grapheme` (these carry no payload)
        none: void,
    };
};

/// A 256-bit set of byte values — backing storage for the `required_bytes`
/// prefilter hint. Tiny and `comptime`-constructible, so it lives directly inside
/// the HIR (ro_data at comptime, heap at runtime) with no separate allocation.
///
/// @stable-since: v0.1.0
pub const ByteSet = struct {
    /// 256 bits packed into four 64-bit words; byte `b` is present when bit
    /// `b & 63` of word `b >> 6` is set. Prefer `set`/`has`/`isEmpty`/`count` over
    /// touching this directly.
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    /// @stable-since: v0.1.0
    pub fn set(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] |= @as(u64, 1) << @truncate(b);
    }
    /// @stable-since: v0.1.0
    pub fn has(self: ByteSet, b: u8) bool {
        return (self.bits[b >> 6] >> @truncate(b)) & 1 != 0;
    }
    /// @stable-since: v0.1.0
    pub fn isEmpty(self: ByteSet) bool {
        return (self.bits[0] | self.bits[1] | self.bits[2] | self.bits[3]) == 0;
    }
    /// Number of distinct bytes in the set (a prefilter picks the rarest member).
    ///
    /// @stable-since: v0.1.0
    pub fn count(self: ByteSet) u32 {
        var c: u64 = 0;
        for (self.bits) |w| c += @popCount(w);
        return @intCast(c);
    }
    /// In-place set union (OR every member of `other` into `self`). Used to accumulate the
    /// reverse-scan alphabet of a required-literal skip over the atoms preceding the literal.
    ///
    /// @stable-since: v0.6.0
    pub fn unionWith(self: *ByteSet, other: ByteSet) void {
        for (0..4) |i| self.bits[i] |= other.bits[i];
    }
};

/// Largest number of top-level alternation branches the multi-prefix prefilter
/// tracks (see `PrefixSet`). A pattern with more branches than this declines the
/// set (the prefilter just isn't built; matching is unaffected).
///
/// @stable-since: v0.4.0
pub const MAX_PREFIX_BRANCHES = 8;

/// One leading literal run per branch of a top-level alternation in which **every**
/// branch begins with a fixed literal (`Holmes…|Watson…` → {"Holmes","Watson"}).
/// Because every match begins with one of these runs, the leftmost occurrence of
/// ANY of them is a **sound** lower bound on where a match can start — a multi-needle
/// generalisation of `prefix_literal`. Null when some branch lacks a fixed leading
/// literal (then no sound multi-prefix bound exists).
///
/// @stable-since: v0.4.0
pub const PrefixSet = struct {
    /// `runs[0..len]` — each a leading literal run (index pair into `Hir.literals`).
    runs: [MAX_PREFIX_BRANCHES]Node.Run,
    /// Number of valid runs (always ≥ 2 — a single prefix uses `prefix_literal`).
    len: u8,
};

/// An interior required literal that immediately follows a leading **variable-length
/// class run**, e.g. the `@` in `[\w.+-]+@…` or `(\w+)@(\w+)`. For a pattern with no
/// fixed leading literal this drives a sound *skip-to-anchor + bounded reverse-scan*
/// prefilter: jump to the next `byte`, walk back over `lead_class` to the earliest
/// possible run start, then scan from there — far better than the mere presence
/// fast-reject `required_bytes` gives. Null when the pattern has no such shape.
///
/// @stable-since: v0.4.0
pub const InnerAnchor = struct {
    /// First UTF-8 byte of the required literal right after the lead run (the memchr
    /// target). A necessary byte of every match; a false hit only costs a verify.
    byte: u8,
    /// Bytes that may appear in the leading variable atom's class — the alphabet the
    /// reverse scan walks back over to find the run start. Bytes ≥ 0x80 are set
    /// **conservatively** (all of them) when the class has any non-ASCII member, so
    /// the scan never stops short of a real start (sound: a superset only over-scans).
    lead_class: ByteSet,
    /// Code-point length of the leading run when it is **fixed** (`\d{4}-…` → 4, a bare
    /// class `\d-…` → 1), or null when the run is variable (`[\w.+-]+@…` → null). When
    /// non-null **and the input is all-ASCII**, every leading code point is one byte, so
    /// the anchor sits exactly this many *bytes* into every match: a hit at byte `q` pins
    /// the match start to `q - lead_fixed_cps`, and a single bounded anchored confirm
    /// there replaces the reverse-scan + native find — turning a dash-dense, linearly
    /// scanned pattern (`\d{4}-\d{2}-\d{2}` over nginx logs) into one bounded confirm per
    /// anchor occurrence. Null / non-ASCII keeps the sound reverse-scan + native-find path.
    ///
    /// @stable-since: v0.5.0
    lead_fixed_cps: ?u32 = null,
};

/// A **required interior/suffix literal** with the alphabet of everything that may precede it
/// within a match — the general form of `InnerAnchor`. Where `InnerAnchor` keys off a single
/// *byte* immediately after one leading class run, this carries the **whole literal run** (the
/// memmem needle, far more selective than a first-byte memchr) and works for a literal sitting
/// anywhere on the mandatory concat spine — after several class/literal runs, or at the very end
/// (`\w+\s+Holmes`, `[a-zA-Z]+ing`, `[\w.+-]+@gmail\.com`).
///
/// The skip: memmem to the next occurrence of `run`'s bytes at `q ≥ start`; walk **back** over
/// `lead_class` to the earliest position a match could begin; run the engine unanchored from
/// there. Sound because (1) `run` appears in *every* match (it is on the mandatory spine), so its
/// first occurrence `≥ start` lower-bounds where the leftmost match's literal can sit, and (2)
/// `lead_class` is a **superset** of every byte that can appear between a match's start and the
/// literal, so the reverse scan never stops *after* the true start — it only ever over-reaches
/// (still leftmost-correct, never missing a match). Linear: one memmem + one bounded reverse scan
/// + one unanchored pass.
///
/// Largest number of leading class-repetition atoms (`\w+`, `\s+`, `[a-z]*`, a bare class) before
/// the required literal that the **structured reverse walk** tracks. A pattern with more declines
/// the walk (it falls back to the flat reverse-scan + unanchored find — slower but still correct).
///
/// @stable-since: v0.6.0
pub const MAX_PRE_ATOMS = 4;

/// One leading class-repetition atom before the required literal, for the structured reverse walk:
/// its byte alphabet plus the repetition bounds. `max == maxInt(u32)` encodes an unbounded `+`/`*`.
///
/// @stable-since: v0.6.0
pub const PreAtom = struct { bits: ByteSet, min: u32, max: u32 };

/// @stable-since: v0.6.0
pub const RequiredLiteralSkip = struct {
    /// The required literal run (index pair into `Hir.literals`); its UTF-8 bytes are the memmem
    /// needle. Always `len ≥ 1` here; the dispatcher additionally requires it to encode to ≥ 2
    /// bytes (a one-byte needle degrades to a memchr already covered by `InnerAnchor`).
    run: Node.Run,
    /// Superset of the bytes that may appear before the literal in any match — the reverse-scan
    /// alphabet. ASCII members exact; if any preceding atom has a code point ≥ 0x80, all high
    /// bytes are set conservatively (see `classBytes`). Never the full 256 (the builder declines
    /// a universal alphabet — `.`/`\X` before the literal — since the reverse scan would never
    /// advance).
    lead_class: ByteSet,
    /// Fixed code-point distance from the match start to the literal when **every** atom before it
    /// on the spine is fixed-length (`[a-q][^u-z]{13}x` → 14), else null. When non-null **and the
    /// input is all-ASCII**, the literal sits exactly this many *bytes* into every match, so a
    /// rare-byte memchr to the literal at `q` pins the start to `q - lead_fixed_cps`: a single
    /// bounded anchored confirm there (one per occurrence) replaces a dense leading-class scan —
    /// the win for a fixed-length negated-class pattern whose only selective feature is a rare
    /// suffix byte. Null keeps the reverse-scan + unanchored-find path (`lead_class`).
    ///
    /// @stable-since: v0.6.0
    lead_fixed_cps: ?u32 = null,
    /// True when the literal is the **last consuming atom** — the match ends exactly at the literal
    /// (`\w+\s+Holmes`, `[a-zA-Z]+ing`); only trailing zero-width anchors may follow. Lets the lazy
    /// DFA arm confirm a memmem hit by a single **reverse-DFA pass** from the hit's end (precise
    /// match start, no flat-reverse over-reach, no forward re-seed) instead of a reverse-scan +
    /// unanchored find. False when a consuming atom follows the literal (`…Holmes\s+\w+`).
    ///
    /// @stable-since: v0.6.0
    is_suffix: bool = false,
    /// The leading class-repetition atoms **before** the literal (`\w+`, `\s+` in `\w+\s+Holmes`),
    /// in spine order, when there are 1..`MAX_PRE_ATOMS` of them, each a single-class repetition,
    /// and **adjacent classes are pairwise disjoint** — else `pre_n == 0`. When set, a matcher finds
    /// the *exact* match start from a literal hit by a **structured reverse walk** (consume each
    /// atom's class backward, in reverse spine order, greedily within `[min, max]`): disjoint
    /// adjacency forces the split, so the walk lands on the true start with no over-reach. One
    /// anchored confirm there per literal occurrence then validates the *whole* pattern (including
    /// any atoms after the literal), so this drives both suffix (`\w+\s+Holmes`) and non-suffix
    /// (`\w+\s+Holmes\s+\w+`) patterns — the win is running the automaton only at real candidate
    /// starts instead of scanning the gaps. `pre_n == 0` keeps the flat reverse-scan path.
    ///
    /// @stable-since: v0.6.0
    pre: [MAX_PRE_ATOMS]PreAtom = @splat(.{ .bits = .{}, .min = 0, .max = 0 }),
    /// Number of valid entries in `pre` (0 = structured reverse walk unavailable).
    ///
    /// @stable-since: v0.6.0
    pre_n: u8 = 0,
};

/// Cheap, precomputed facts a dispatcher/backend can consult without rewalking the
/// tree. Everything here is a *sound* property of the HIR: bounds are true bounds
/// and the "required"/"anchored" facts hold for *every* match, so a prefilter or
/// length gate built on them never yields a false negative.
///
/// @stable-since: v0.1.0
pub const Analysis = struct {
    /// Match can only start at the very beginning of input (`\A`, or `^` without
    /// multiline).
    anchored_start: bool,
    /// Match can only end at the very end of input (`\z`/`\Z`, or `$` without
    /// multiline). Mirror of `anchored_start`.
    anchored_end: bool,
    /// Minimum match length, in code points.
    min_len: u32,
    /// Maximum match length in code points, or null if unbounded.
    max_len: ?u32,
    /// Minimum match length, in UTF-8 bytes (≥ `min_len`; strictly larger when a
    /// required atom is multi-byte). For "remaining input too short" gating.
    min_utf8_len: u32,
    /// Maximum match length, in UTF-8 bytes, or null if unbounded.
    max_utf8_len: ?u32,
    /// Contains a `\X` grapheme node (routes to a grapheme-capable backend).
    has_grapheme: bool,
    /// Contains a `\b`/`\B` word-boundary assertion — relevant to byte-DFA
    /// feasibility (a boundary needs the previous code point, not just a byte).
    has_word_boundary: bool,
    /// A `\b`/`\B` assertion sits inside an alternation (has an `alternation`
    /// ancestor). The byte DFAs match leftmost-*longest* on the merged branches,
    /// which silently loses leftmost-*first* priority when an assertion-gated
    /// branch can match empty while a sibling consumes (`\b|.` on `"b"` must be
    /// the empty match `{0,0}`, not `{0,1}`). The DFAs cannot encode that branch
    /// priority across an assertion, so such a pattern is declined to the Pike VM
    /// (correct + still O(input)). Set conservatively: any `\b` under an
    /// alternation trips it, even when both branches consume — over-declining only
    /// costs the DFA fast path, never correctness.
    ///
    /// @stable-since: v0.5.0
    word_boundary_in_alternation: bool,
    /// A repetition loops over an `alternation` that has a **nullable** branch (one that
    /// can match the empty string, e.g. `(?:|.)+`, `(a*|b)+`, `(b{0}\n*|.{2}…)+`). The byte
    /// DFA's priority-ordered determinization cannot reliably reproduce the engine's
    /// leftmost-first **empty-width-loop** priority for this shape — when the preferred
    /// (earlier) branch can match empty, the loop must terminate at that empty iteration
    /// (`(?:|.)+` on `"c"` is `""`), but the DFA can let a later consuming branch win.
    /// Declined to the Pike VM (leftmost-first correct + still O(input)). Conservative: any
    /// nullable alternation under any repetition trips it — over-declining only forgoes the
    /// DFA fast path, never trades correctness. (Pre-0.6.0 this carve-out also encoded ezi's
    /// then-deliberate JS empty-loop divergence; 0.6.0 made the Pike VM uniformly RE2/Rust
    /// leftmost-first, so the decline is now purely a routing detail — the answer is the same
    /// RE2 span either way.) The non-alternation nullable-concat shape is handled directly on
    /// every backend (the empty-width-loop guard) and is NOT declined.
    ///
    /// @stable-since: v0.5.0
    nullable_alternation_in_repetition: bool,
    /// A `text_end` (`$` outside `(?m)`, or `\z`) sits in a **non-trailing**
    /// position — a consuming atom (or a degenerate trailing `text_start`, `$^\z`)
    /// can follow it on some path (`$a`, `\z.\z`, `$\n$`, `$b$`, `$^\z`). Such a
    /// pattern is unsatisfiable / contradictory past that anchor, but the
    /// byte DFA's anchored-end / reverse-from-end path keys off the *trailing*
    /// `text_end` (which sets `anchored_end`) and ignores the interior one, so it
    /// can wrongly match. Declined to the Pike VM. The common single-trailing-`$`
    /// (`\d+$`, `^abc$`) is NOT flagged — only a `text_end` with a consumer after
    /// it trips this, so the benchmarked `$` DFA fast path is untouched. (Line
    /// anchors `(?m)$` = `line_end` are a separate, still-open family.)
    ///
    /// @stable-since: v0.5.0
    interior_text_end: bool,
    /// The pattern has a `\b`/`\B` word boundary AND a **nullable** alternation
    /// (`\B(?:|.*)`, `b{0}\b(|b)`, `(a?|aa*)\b`). The DFA mishandles the boundary's
    /// interaction with the empty-branch choice (a sibling-of-`\b` empty branch),
    /// the same leftmost-first-across-an-assertion problem as
    /// `word_boundary_in_alternation` but with the boundary *adjacent to* rather
    /// than *inside* the alternation. Declined to the Pike VM. Conservative
    /// (whole-pattern co-occurrence) but it spares every benchmarked `\b` pattern —
    /// none (`\bthe\b`, `\b\w+\b`) contains a nullable alternation.
    ///
    /// @stable-since: v0.5.0
    word_boundary_with_nullable_alternation: bool,
    /// The pattern has a `\b`/`\B` word boundary AND a **lazy** repetition (`a*?`,
    /// `a+?`, `\n??` — any non-greedy quantifier). A lazy quantifier prefers *fewer*
    /// reps, so leftmost-first takes the short match when the boundary also holds
    /// there (`a*?\b` on `"a"` is `{0,0}`; `[^a]+?\B *` likewise stops early), but the
    /// leftmost-**longest** byte DFA takes the long one. (Greedy `\w*\b`/`a*\b` are
    /// fine — greedy and the boundary agree — and are NOT flagged, keeping the DFA
    /// fast path.) Declined to the Pike VM. Conservative whole-pattern co-occurrence;
    /// spares every benchmarked `\b` pattern (none has a lazy repetition).
    ///
    /// @stable-since: v0.5.0
    word_boundary_with_lazy_repetition: bool,
    /// The pattern has a `\b`/`\B` word boundary AND two **adjacent** consuming
    /// repetitions in a concat (a repetition immediately followed by another, e.g.
    /// `\n+(\n.*){0,2}`). When the two reps can consume the same leading byte their
    /// split is ambiguous, and a trailing `\b` can then hold at an earlier
    /// (greedy-first, shorter) end *and* a later one: leftmost-first takes the early
    /// end (`\n+(\n.*){0,2}\b` on `"\n\nab"` is `{0,2}`), the leftmost-**longest** byte
    /// DFA's word-context model takes the late one (`{0,4}`). A single repetition
    /// tight against the boundary (`\w*\b`, `\b\w+\b`, `.*\b`) is unambiguous and is
    /// NOT flagged — the benchmarked `\b` fast paths stay on the DFA. Declined to the
    /// Pike VM. Conservative whole-pattern co-occurrence (it may forgo the DFA on an
    /// adjacent-rep `\b` pattern that would have agreed), never trading correctness.
    ///
    /// @stable-since: v0.5.1
    word_boundary_with_adjacent_repetition: bool,
    /// A `\b`/`\B` word boundary immediately **follows** an `alternation` whose branches
    /// have **overlapping first code points** (so they can match the same start at
    /// different lengths, e.g. `(b+|.+)\B`, `(?:b|baaa)\B`) — **directly, or through a
    /// repetition wrapping** such an alternation (`(?:.|b\n)*\b`, `(?:b+|.+)*\B`), which only
    /// adds match-end ambiguity. Leftmost-first must try the
    /// earlier branch first — `b+` matches `"b"`, the `\B` holds between `b` and `a`, so the
    /// span is `"b"` and the longer `.+` branch is never used — but the **eager** byte DFA's
    /// word-boundary determinization loses that branch priority once a boundary follows and
    /// takes the longest boundary-valid end (`"baa"`). The `pikevm`/`backtrack` and the
    /// **lazy `dfa`** (decode-hybrid boundary) are leftmost-first correct, so this is gated
    /// only in `edfa.supports` (the eager arm). Branches with **disjoint** first code points
    /// (`(?:b+|a+)\B`, `\b(foo|bar)\b`, `\bthe\b`, `\b\w+\b`) are unambiguous at the boundary
    /// and are NOT flagged — they stay on the eager DFA fast path. Same eager-DFA
    /// `\b`-priority family as [`word_boundary_with_adjacent_repetition`].
    ///
    /// @stable-since: v0.6.0
    word_boundary_after_varying_alternation: bool,
    /// A `\b`/`\B` word boundary sits **lexically inside a repetition** (`(b.{0,2}\B)+`,
    /// `(?:\w\b)+`). The repeated body makes the boundary's position ambiguous across
    /// iterations — it can hold at an earlier (leftmost-first) end and a later one — and the
    /// **eager** byte DFA's word-boundary determinization takes the longer (`(b.{0,2}\B)+` on
    /// `"bbbab…"` → `"bbbab"`, leftmost-first is `"bbb"`). The `pikevm`/`backtrack` and the
    /// **lazy `dfa`** are leftmost-first correct, so this is gated only in `edfa.supports`. A
    /// boundary at the **top level** (`\b\w+\b`, `\bthe\b`, `\w+\b` — the repetition `\w+` is
    /// beside the boundary, the boundary itself not under a rep) is NOT flagged and stays on
    /// the eager DFA fast path. Same eager-DFA `\b`-priority family as
    /// [`word_boundary_with_adjacent_repetition`]. Found by the differential anchor fuzz.
    ///
    /// @stable-since: v0.6.0
    word_boundary_in_repetition: bool,
    /// A `(?m)` line anchor (`line_start`/`line_end`) appears in a shape the eager
    /// byte DFA's line support cannot handle: a **non-leading** `(?m)^` (a consumer —
    /// or an earlier `line_end`, `$^` — precedes it), a **non-trailing** `(?m)$` (a
    /// consumer follows it, `(?m:$\n)`), **any** line anchor inside a repetition
    /// (`(?m:\n$)*`), or **any** line anchor inside an alternation branch
    /// (`(?m:$)|.` — a zero-width branch the line model can't priority-order against a
    /// consuming sibling, so the DFA takes the longer branch). The eager DFA does line
    /// anchors by anchored-restart with a
    /// one-byte `\n`-lookahead, which is only correct for a single leading `(?m)^…` or
    /// trailing `…(?m)$`; the shapes above diverge from the Pike VM (both over- and
    /// under-matching), so they are declined to it. Note `$^` (line_end then
    /// line_start) is interior even though it is zero-width — the two line contexts
    /// can't be carried at one offset — whereas the natural `^…$` order is fine. The
    /// benchmarked leading-`(?m)^` (`(?m)^\w+`, `log_line`) and trailing `(?m)$` are
    /// NOT flagged — they keep the DFA fast path. (Mixing a line anchor with a
    /// `text_start`/`text_end` is a separate boolean check in the supports gate.)
    ///
    /// @stable-since: v0.5.0
    complex_line_anchor: bool,
    /// A `(?m)$` `line_end` immediately preceded — on the concat path, with no MANDATORY
    /// consumer between — by a **nullable alternation** (`(?:|\n)$`). The alternation's
    /// leftmost-FIRST branch order prefers the shorter (empty) match, but a `(?m)$` holds at
    /// BOTH the short end and the longer branch's end (a `\n` consumed by a branch lands on the
    /// next line end), so the leftmost-LONGEST eager DFA takes the long branch — `(?m:(?:|\n)$)`
    /// over `"aaa\n\n"` is the empty `{3,3}`, the eager DFA returned `{3,4}`. This is the line
    /// analogue of `word_boundary_with_nullable_alternation`; it gates the **eager DFA only**
    /// (the lazy DFA already declines every `line_end`; the code-point engines are correct). A
    /// *greedy* optional/repetition before `$` (`\n?$`, `.*$`, `[\n ]*$`) does NOT trip it —
    /// greedy prefers the longer match too, so it agrees with the DFA.
    line_end_after_nullable_alternation: bool,
    /// The whole pattern is a single literal run (no anchors, classes, …) — route
    /// straight to a memmem/substring backend.
    is_whole_literal: bool,
    /// Reserved one-pass hint (an unambiguous NFA → fast single-pass capture path).
    /// Soundly deciding this needs first/follow overlap analysis on the *lowered*
    /// NFA, not the HIR tree, so the HIR leaves it conservatively `false`; the
    /// backend that builds the NFA flips it on when it proves the property. A
    /// `false` is always safe — the dispatcher just falls through to the Pike VM.
    is_one_pass: bool,
    /// A literal run that *every* match must begin with, or null — indexes
    /// `Hir.literals`. The needle for a start-anchored scan. Null when the leading
    /// atom isn't a fixed literal (a class, `.`, an alternation, an optional, or a
    /// `(?i)`-folded letter that became a class). Leading zero-width anchors
    /// (`^`, `\b`) are skipped.
    prefix_literal: ?Node.Run,
    /// The longest literal run that *every* match must contain somewhere — the best
    /// general memmem prefilter needle — or null. May coincide with
    /// `prefix_literal` when the leading run is also the longest.
    required_literal: ?Node.Run,
    /// Bytes that must appear in *every* match: the UTF-8 bytes of every required
    /// literal code point. A `memchr` for any member is a sound prefilter (pick the
    /// rarest). Empty when nothing is unconditionally required (e.g. a top-level
    /// alternation, or a leading optional).
    required_bytes: ByteSet,
    /// Every match begins at a **line start** (offset 0 or just after a `\n`): the
    /// pattern's leading mandatory atom is a `line_start` (`(?m)^`) or `text_start`
    /// (`^`/`\A`) anchor. Lets a matcher seed only at line starts (and skip between
    /// them with a `\n` memchr) instead of trying every position — the win for a
    /// `(?m)^…` pattern that no DFA can hold. `text_start` implies this too, but that
    /// case is already covered more tightly by `anchored_start`.
    ///
    /// @stable-since: v0.4.0
    line_anchored_start: bool,
    /// Leading literal of every branch of a top-level alternation, or null (see
    /// `PrefixSet`). Drives the multi-prefix start-skip for `cat…|dog…|fish…`.
    ///
    /// @stable-since: v0.4.0
    prefix_set: ?PrefixSet,
    /// An interior required literal after a leading variable class run, or null (see
    /// `InnerAnchor`). Drives the inner-literal skip for `[\w.+-]+@…`-shaped patterns.
    ///
    /// @stable-since: v0.4.0
    inner_anchor: ?InnerAnchor,
    /// A required interior/suffix literal with the alphabet of everything that may precede it,
    /// or null (see `RequiredLiteralSkip`). Drives the general required-literal memmem skip for
    /// `\w+\s+Holmes`-, `[a-zA-Z]+ing`-shaped patterns (a prefilter where neither a leading
    /// literal nor a leading-class scan applies but a selective literal sits in the interior).
    ///
    /// @stable-since: v0.6.0
    required_literal_skip: ?RequiredLiteralSkip,
    /// The possible **first UTF-8 bytes** of a match whose leading mandatory atom is a
    /// **class** with no fixed leading literal (`\d+`, `\d{4}-…`, `\p{N}+`, `\p{Lu}\p{Ll}+`),
    /// or null. Every match begins with a byte in this set, so a SIMD scan for the next
    /// member is a sound start-skip (`engine/classscan.zig`) — the leading-class lane the
    /// dispatcher uses when no literal / multi-prefix / inner-anchor skip applies. Null when
    /// the leading atom is a literal (covered by `prefix_literal`), `.`, an alternation, an
    /// optional, or a grapheme. The dispatcher additionally gates it on *selectivity* (a set
    /// covering most of typical text — `\p{L}+` — would scan to almost every byte and isn't
    /// worth it).
    ///
    /// @stable-since: v0.4.0
    leading_class_first: ?ByteSet,
};

/// The resolved program shape. All slices are sub-slices of caller storage
/// (ro_data at comptime, heap at runtime). Immutable and shareable.
///
/// @stable-since: v0.1.0
pub const Hir = struct {
    /// Every HIR node, flat. The tree is reconstructed by index; `nodes[root]` is
    /// the entry. Composite nodes point into `children`; leaves into `ranges`/`literals`.
    nodes: []const Node,
    /// Packed child-index lists. A `concat`/`alternation` node's children are
    /// `children[d.start .. d.start + d.len]` for its `Node.Children` payload `d`.
    children: []const u32,
    /// Packed, sorted, merged, non-overlapping, POSITIVE code-point ranges. A
    /// `class` node's set is `ranges[c.start .. c.start + c.len]`. Negation is
    /// already applied — membership is just "cp ∈ some range".
    ranges: []const Range,
    /// Packed post-fold code points. A `literal` run is
    /// `literals[r.start .. r.start + r.len]`. Each is a valid scalar (encodable).
    literals: []const CodePoint,
    /// Capture-group names, indexed by `Node.Capture.name`. Each slice BORROWS the
    /// original pattern string (not copied) — keep the pattern alive while reading.
    names: []const []const u8,
    /// Index of the root node within `nodes` (the entry point for traversal/compile).
    root: u32,
    /// Number of capturing groups, excluding group 0 (the whole match). Capture-aware
    /// search needs `2 * (capture_count + 1)` slots.
    capture_count: u32,
    /// Precomputed, sound prefilter/feasibility facts about every match (see `Analysis`).
    analysis: Analysis,
};

/// The only failure the builder can raise: a class/pattern that overruns the
/// caller's buffers (e.g. an enormous resolved class). Mirrors the scanner's
/// "guard every write, never overrun" model.
///
/// @stable-since: v0.1.0
pub const BuildError = error{PatternTooComplex};

// ── Sizes / Buffers (storage-agnostic core) ─────────────────────────────────────

/// Exact output sizes, computed by `measure`. Unlike the scanner's
/// pattern-length bounds these are exact, because a resolved class's range count
/// is data-dependent and can be large; over-provisioning would bloat comptime.
///
/// @stable-since: v0.1.0
pub const Sizes = struct {
    /// Exact `Node` count the emit pass will write — minimum length of `Buffers.nodes`.
    nodes: usize,
    /// Exact child-index count — minimum length of `Buffers.children`.
    children: usize,
    /// Exact resolved-range count — minimum length of `Buffers.ranges`.
    ranges: usize,
    /// Exact post-fold code-point count — minimum length of `Buffers.literals`.
    literals: usize,
    /// Exact capture-name count (= `ast.names.len`) — minimum length of `Buffers.names`.
    names: usize,
};

/// Transient scratch the builder needs while lowering. `stack` gathers child
/// node indices (depth-balanced, scanner-style); `main`/`member` hold a class's
/// ranges mid-resolution. Caller-owned; location is the caller's choice.
///
/// @stable-since: v0.1.0
pub const Scratch = struct {
    /// Gathers child node indices during lowering (depth-balanced, scanner-style).
    /// Size it to `scratchSizes(ast).stack`.
    stack: []u32,
    /// Accumulates a class's ranges as members are unioned in. Size it to
    /// `scratchSizes(ast).ranges`.
    main: []Range,
    /// Holds the ranges of ONE class member mid-resolution before it is merged into
    /// `main`. Same size as `main`.
    member: []Range,
    /// Aux buffer for the merge sort (same size as `main`/`member`).
    aux: []Range,
};

/// Backing storage for the produced HIR. Each slice must be at least the length
/// given by `measure` (`nodes`, `children`, `ranges`, `literals`, `names`).
///
/// @stable-since: v0.1.0
pub const Buffers = struct {
    /// Receives the emitted nodes; length ≥ `measure(...).nodes`.
    nodes: []Node,
    /// Receives the packed child indices; length ≥ `measure(...).children`.
    children: []u32,
    /// Receives the resolved class ranges; length ≥ `measure(...).ranges`.
    ranges: []Range,
    /// Receives the post-fold literal code points; length ≥ `measure(...).literals`.
    literals: []CodePoint,
    /// Receives the borrowed capture names; length ≥ `measure(...).names`.
    names: [][]const u8,
};

/// Upper bound on scratch sizes for an AST. The stack depth is bounded by the
/// produced node count, itself O(ast nodes); the class scratch is a fixed cap.
///
/// @stable-since: v0.1.0
pub fn scratchSizes(a: ast.Ast) struct { stack: usize, ranges: usize } {
    return .{ .stack = 8 * a.nodes.len + 16, .ranges = CLASS_SCRATCH_CAP };
}

// ── Builder (one body, two modes: .count for measure, .emit for build) ──────────

const Mode = enum { count, emit };

fn Builder(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        const emit = mode == .emit;

        a: ast.Ast,
        opts: Options,

        // output cursors (and, in emit mode, the buffers themselves)
        node_len: u32 = 0,
        child_len: u32 = 0,
        range_len: u32 = 0,
        lit_len: u32 = 0,
        name_len: u32 = 0,
        nodes: if (emit) []Node else void = if (emit) undefined else {},
        children: if (emit) []u32 else void = if (emit) undefined else {},
        ranges: if (emit) []Range else void = if (emit) undefined else {},
        literals: if (emit) []CodePoint else void = if (emit) undefined else {},
        names: if (emit) [][]const u8 else void = if (emit) undefined else {},

        // scratch
        stack: []u32,
        stack_len: u32 = 0,
        main: []Range,
        main_len: u32 = 0,
        member: []Range,
        member_len: u32 = 0,
        aux: []Range,

        has_grapheme: bool = false,

        // ── output sinks (write in emit mode; always advance the cursor) ────────

        fn addNode(self: *Self, n: Node) BuildError!u32 {
            const i = self.node_len;
            if (emit) {
                if (i >= self.nodes.len) return error.PatternTooComplex;
                self.nodes[i] = n;
            }
            self.node_len += 1;
            return i;
        }

        fn addChild(self: *Self, idx: u32) BuildError!void {
            const i = self.child_len;
            if (emit) {
                if (i >= self.children.len) return error.PatternTooComplex;
                self.children[i] = idx;
            }
            self.child_len += 1;
        }

        fn addOutRange(self: *Self, r: Range) BuildError!void {
            const i = self.range_len;
            if (emit) {
                if (i >= self.ranges.len) return error.PatternTooComplex;
                self.ranges[i] = r;
            }
            self.range_len += 1;
        }

        fn addLiteralCp(self: *Self, cp: CodePoint) BuildError!void {
            const i = self.lit_len;
            if (emit) {
                if (i >= self.literals.len) return error.PatternTooComplex;
                self.literals[i] = cp;
            }
            self.lit_len += 1;
        }

        fn addName(self: *Self, name: []const u8) BuildError!void {
            const i = self.name_len;
            if (emit) {
                if (i >= self.names.len) return error.PatternTooComplex;
                self.names[i] = name;
            }
            self.name_len += 1;
        }

        // ── stack ───────────────────────────────────────────────────────────────

        fn push(self: *Self, idx: u32) BuildError!void {
            if (self.stack_len >= self.stack.len) return error.PatternTooComplex;
            self.stack[self.stack_len] = idx;
            self.stack_len += 1;
        }

        // ── class scratch ────────────────────────────────────────────────────────

        fn addMember(self: *Self, lo: CodePoint, hi: CodePoint) BuildError!void {
            if (self.member_len >= self.member.len) return error.PatternTooComplex;
            self.member[self.member_len] = .{ .lo = lo, .hi = hi };
            self.member_len += 1;
        }

        fn addMain(self: *Self, r: Range) BuildError!void {
            if (self.main_len >= self.main.len) return error.PatternTooComplex;
            self.main[self.main_len] = r;
            self.main_len += 1;
        }

        /// Whether `cp` is already present in the member scratch (the ranges
        /// accumulated for the class member being resolved). Used by `addFolded`
        /// to close a simple-fold orbit transitively.
        fn memberHas(self: *Self, cp: CodePoint) bool {
            for (self.member[0..self.member_len]) |r| {
                if (cp >= r.lo and cp <= r.hi) return true;
            }
            return false;
        }

        fn foldActive(self: *Self, flags: Flags) bool {
            return flags.case_insensitive and self.opts.case_fold != .none;
        }

        /// Append `[lo,hi]` to the member scratch, plus the full simple-fold
        /// ORBIT of every code point it covers when case folding is active.
        ///
        /// Two table passes give the transitive closure. A single pass (add a
        /// member's fold target, and add the sources of any target that lands in
        /// the original range) misses *siblings*: code points that fold to the
        /// same target as a member but whose shared target is outside `[lo,hi]`.
        /// e.g. `(?i)K` (U+004B) — both `k` (U+006B) and U+212A KELVIN SIGN fold
        /// to `k`; the forward pass adds `k`, and the closure pass then adds every
        /// source of `k`, including the KELVIN SIGN. Simple-fold orbits have depth
        /// ≤ 2 (each code point folds in one step to a canonical form that folds
        /// to itself), so forward-then-closure is complete.
        fn addFolded(self: *Self, lo: CodePoint, hi: CodePoint, flags: Flags) BuildError!void {
            try self.addMember(lo, hi);
            if (!self.foldActive(flags)) return;
            const table = casing.case_folding.common_simple_table;
            // Forward: add the simple-fold target of every code point in [lo,hi].
            for (table) |entry| {
                if (entry.to.len != 1) continue;
                if (entry.from >= lo and entry.from <= hi) try self.addMember(entry.to[0], entry.to[0]);
            }
            // Closure: add every source whose target is now a member (an original
            // code point OR a target added above) — completing each fold orbit.
            for (table) |entry| {
                if (entry.to.len != 1) continue;
                if (self.memberHas(entry.to[0])) try self.addMember(entry.from, entry.from);
            }
        }

        // ── members → ranges ──────────────────────────────────────────────────────

        fn addCategory(self: *Self, cat: props.GeneralCategory) BuildError!void {
            for (props.category_runs) |run| {
                if (run.category == cat) try self.addMember(run.start, run.end);
            }
        }

        fn addCategoryGroup(self: *Self, group: GeneralCategoryGroup) BuildError!void {
            for (props.category_runs) |run| {
                if (inGroup(run.category, group)) try self.addMember(run.start, run.end);
            }
        }

        fn addDerived(self: *Self, prop: props.DerivedProperty) BuildError!void {
            const bit = @intFromEnum(prop);
            for (props.derived_runs) |run| {
                if (run.mask & bit != 0) try self.addMember(run.start, run.end);
            }
        }

        fn addScript(self: *Self, st: u_scripts.ScriptType) BuildError!void {
            for (u_scripts.script_runs) |run| {
                if (run.script == st) try self.addMember(run.start, run.end);
            }
        }

        fn addPropList(self: *Self, ranges: anytype) BuildError!void {
            for (ranges) |r| try self.addMember(r.start, r.end);
        }

        /// Resolve a Perl shorthand (`\d`/`\w`/`\s`) into the member scratch
        /// (positive form). Unicode mode (the default) uses the full Unicode
        /// definitions; ASCII mode (`Options.unicode == false`) uses the classic
        /// ASCII sets — see `addPerlAscii`.
        fn addPerl(self: *Self, kind: PerlClassKind) BuildError!void {
            if (!self.opts.unicode) return self.addPerlAscii(kind);
            switch (kind) {
                .digit => try self.addCategory(.decimal_number),
                .space => try self.addPropList(props.white_space_ranges),
                .word => {
                    try self.addDerived(.alphabetic);
                    try self.addCategoryGroup(.mark);
                    try self.addCategory(.decimal_number);
                    try self.addCategory(.connector_punctuation);
                    try self.addPropList(props.join_control_ranges);
                },
            }
        }

        /// ASCII-mode (`Options.unicode == false`) shorthand classes:
        /// `\d`=`[0-9]`, `\w`=`[0-9A-Za-z_]`, `\s`=`[ \t\n\v\f\r]` (U+0009–U+000D and
        /// U+0020). Negation (`\D`/`\W`/`\S`) is applied by the caller afterwards.
        fn addPerlAscii(self: *Self, kind: PerlClassKind) BuildError!void {
            switch (kind) {
                .digit => try self.addMember('0', '9'),
                .space => {
                    try self.addMember(0x09, 0x0D); // \t \n \v \f \r
                    try self.addMember(0x20, 0x20); // space
                },
                .word => {
                    try self.addMember('0', '9');
                    try self.addMember('A', 'Z');
                    try self.addMember('a', 'z');
                    try self.addMember('_', '_');
                },
            }
        }

        /// Resolve a `\p{…}` identifier into the member scratch (positive form).
        fn addProperty(self: *Self, pid: PropertyId) BuildError!void {
            switch (pid) {
                .general_category => |gc| try self.addCategory(gc),
                .general_category_group => |g| try self.addCategoryGroup(g),
                .derived => |d| try self.addDerived(d),
                // Script_Extensions falls back to the plain Script ranges in v1
                // (the extension sets are not yet enumerable as ranges).
                .script, .script_extension => |st| try self.addScript(st),
            }
        }

        /// Sort+merge the member scratch, complement it if `negated`, and union
        /// the result into the main scratch.
        fn flushMemberIntoMain(self: *Self, negated: bool) BuildError!void {
            sortRanges(self.member[0..self.member_len], self.aux);
            const k = mergeRanges(self.member[0..self.member_len]);
            if (negated) {
                try self.complementInto(self.member[0..k], addMain);
            } else {
                for (self.member[0..k]) |r| try self.addMain(r);
            }
        }

        /// Sort+merge the main scratch and commit it to the output ranges,
        /// complementing first when the class itself is negated. Returns the
        /// committed `(start, len)`.
        fn commitMain(self: *Self, class_negated: bool) BuildError!Node.Class {
            sortRanges(self.main[0..self.main_len], self.aux);
            const m = mergeRanges(self.main[0..self.main_len]);
            const start = self.range_len;
            if (class_negated) {
                try self.complementInto(self.main[0..m], addOutRange);
            } else {
                for (self.main[0..m]) |r| try self.addOutRange(r);
            }
            return .{ .start = start, .len = self.range_len - start };
        }

        /// Walk the gaps of a sorted+merged range list over `[0, MAX_CP]`,
        /// emitting each gap through `sink` (either `addMain` or `addOutRange`).
        fn complementInto(self: *Self, sorted: []const Range, comptime sink: fn (*Self, Range) BuildError!void) BuildError!void {
            var next: CodePoint = 0; // next code point not yet covered
            for (sorted) |r| {
                if (r.lo > next) try sink(self, .{ .lo = next, .hi = r.lo - 1 });
                if (r.hi >= MAX_CP) return; // covered to the top; no trailing gap
                next = r.hi + 1;
            }
            try sink(self, .{ .lo = next, .hi = MAX_CP });
        }

        // ── lowering ───────────────────────────────────────────────────────────────

        fn lower(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const node = self.a.nodes[idx];
            return switch (node.tag) {
                .literal => self.lowerLiteral(node.data.literal.code_point, flags),
                .dot => self.addNode(.{ .tag = .any, .data = .{ .any = .{ .dot_all = flags.dot_all } } }),
                .char_class => self.lowerClass(idx, flags),
                .unicode_property => self.lowerUnicodeProp(node.data.unicode_prop, flags),
                .grapheme_cluster => blk: {
                    self.has_grapheme = true;
                    break :blk self.addNode(.{ .tag = .grapheme, .data = .{ .none = {} } });
                },
                .anchor => self.addNode(.{ .tag = .anchor, .data = .{ .anchor = .{ .kind = resolveAnchor(node.data.anchor.kind, flags) } } }),
                .concat => self.lowerConcat(idx, flags),
                .alternation => self.lowerAlternation(idx, flags),
                .range => self.lowerRepetition(idx, flags),
                .capture => self.lowerCapture(idx, flags),
                .non_capture => self.lowerNonCapture(idx, flags),
            };
        }

        /// Lower a single literal code point under the active case-fold mode.
        /// `none`/`simple` produce one node (a literal, or a small fold-orbit class);
        /// `full` additionally expands the 1→many foldings (`ß`→`ss`, `ﬀ`→`ff`) into
        /// an alternation — see `lowerLiteralFull`.
        fn lowerLiteral(self: *Self, cp: CodePoint, flags: Flags) BuildError!u32 {
            if (self.foldActive(flags) and self.opts.case_fold == .full and fullFoldExpands(cp))
                return self.lowerLiteralFull(cp, flags);
            return self.lowerLiteralSimple(cp, flags);
        }

        /// Lower a literal under no-fold or SIMPLE folding: a 1:1 fold orbit stays a
        /// literal, a wider orbit becomes a (tiny) class. Also the per-element builder
        /// `lowerLiteralFull` composes — each code point of a full expansion is lowered
        /// through here, so its own simple orbit (e.g. `s`→`[sSſ]`) is honoured.
        fn lowerLiteralSimple(self: *Self, cp: CodePoint, flags: Flags) BuildError!u32 {
            if (!self.foldActive(flags)) {
                const start = self.lit_len;
                try self.addLiteralCp(cp);
                return self.addNode(.{ .tag = .literal, .data = .{ .run = .{ .start = start, .len = 1 } } });
            }
            // Fold the single code point; a 1:1 orbit stays a literal, otherwise
            // it becomes a (tiny) class.
            self.member_len = 0;
            try self.addFolded(cp, cp, flags);
            sortRanges(self.member[0..self.member_len], self.aux);
            const k = mergeRanges(self.member[0..self.member_len]);
            if (k == 1 and self.member[0].lo == self.member[0].hi) {
                const start = self.lit_len;
                try self.addLiteralCp(self.member[0].lo);
                return self.addNode(.{ .tag = .literal, .data = .{ .run = .{ .start = start, .len = 1 } } });
            }
            self.main_len = 0;
            for (self.member[0..k]) |r| try self.addMain(r);
            const cls = try self.commitMain(false);
            return self.addNode(.{ .tag = .class, .data = .{ .class = cls } });
        }

        /// Lower a literal whose FULL case fold expands to multiple code points
        /// (`ß`→`ss`, `ﬀ`→`ff`, `ﬃ`→`ffi`, …) under `(?i)` with `case_fold = .full`.
        ///
        /// Caseless matching of such a code point must accept BOTH its single-code-
        /// point forms and its spelled-out expansion, so the literal becomes an
        /// alternation of two branches:
        ///
        ///   * **A** — the SIMPLE fold orbit of `cp` itself (e.g. `[ßẞ]`): the input
        ///     is one of the single code points that fold together.
        ///   * **B** — a concat of the simple fold orbit of each code point in the
        ///     expansion (e.g. `[sSſ][sSſ]`): the input spells the expansion out, in
        ///     any case.
        ///
        /// So `(?i)ß` (full) lowers to `(?:[ßẞ]|[sSſ][sSſ])` — matching `ß`, `ẞ`, and
        /// `ss`/`SS`/`ſs`/… . NOTE the converse is *not* covered: a pattern `ss` does
        /// not match a lone `ß`, because the matcher folds the PATTERN, not the input
        /// (the standard limitation). Character classes likewise use simple folding
        /// only — a class matches exactly one code point.
        ///
        /// The expansion comes straight from `ezi_code`'s full-fold table (an O(1)
        /// indexed lookup returning a slice into static data), at build time only;
        /// the resolved HIR carries no folding state into match time.
        fn lowerLiteralFull(self: *Self, cp: CodePoint, flags: Flags) BuildError!u32 {
            // Branch A: the single-code-point forms (simple orbit of cp).
            const alt_a = try self.lowerLiteralSimple(cp, flags);

            // Branch B: the spelled-out expansion, each code point simple-folded.
            const seq = casing.case_folding.lookup(.full, .default, cp) orelse return alt_a;
            const base_b = self.stack_len;
            for (seq) |c| try self.push(try self.lowerLiteralSimple(c, flags));
            const alt_b = try self.finishChildren(base_b, .concat);

            // Top-level alternation [A, B].
            const base = self.stack_len;
            try self.push(alt_a);
            try self.push(alt_b);
            return self.finishChildren(base, .alternation);
        }

        /// True when `cp`'s FULL case fold expands to more than one code point (so
        /// `.full` must lower it specially). ASCII never expands, so it short-circuits
        /// before the table lookup — keeping the hot path (plain ASCII literals) free.
        fn fullFoldExpands(cp: CodePoint) bool {
            if (cp <= encoding.MAX_ASCII) return false;
            const mapped = casing.case_folding.lookup(.full, .default, cp) orelse return false;
            return mapped.len > 1;
        }

        fn lowerClass(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const cc = self.a.nodes[idx].data.char_class;
            self.main_len = 0;
            for (self.a.class_items[cc.start .. cc.start + cc.len]) |item| {
                self.member_len = 0;
                switch (item) {
                    .range => |r| {
                        try self.addFolded(r.lo, r.hi, flags);
                        try self.flushMemberIntoMain(false);
                    },
                    .perl => |p| {
                        try self.addPerl(p.kind);
                        try self.flushMemberIntoMain(p.negated);
                    },
                    .property => |p| {
                        try self.addProperty(p.property);
                        try self.flushMemberIntoMain(p.negated);
                    },
                }
            }
            const cls = try self.commitMain(cc.negated);
            return self.addNode(.{ .tag = .class, .data = .{ .class = cls } });
        }

        fn lowerUnicodeProp(self: *Self, up: ast.UnicodePropData, flags: Flags) BuildError!u32 {
            _ = flags;
            self.main_len = 0;
            self.member_len = 0;
            try self.addProperty(up.property);
            try self.flushMemberIntoMain(up.negated);
            const cls = try self.commitMain(false);
            return self.addNode(.{ .tag = .class, .data = .{ .class = cls } });
        }

        /// In-flight run of plain literals being coalesced into one `literal`
        /// node. Owns `literals[start..lit_len]`; flushed before any non-literal
        /// element so the slice stays contiguous.
        const RunState = struct { have: bool = false, start: u32 = 0, len: u32 = 0 };

        fn flushRun(self: *Self, rs: *RunState) BuildError!void {
            if (!rs.have) return;
            const n = try self.addNode(.{ .tag = .literal, .data = .{ .run = .{ .start = rs.start, .len = rs.len } } });
            try self.push(n);
            rs.have = false;
            rs.len = 0;
        }

        /// Lower a concat, flattening nested concats and inlining non-capturing
        /// groups into a single flat sequence, and merging runs of plain
        /// literals across those boundaries into single `literal` nodes.
        fn lowerConcat(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const d = self.a.nodes[idx].data.children;
            const base = self.stack_len;
            var rs = RunState{};
            for (self.a.children[d.start .. d.start + d.len]) |c| try self.appendSeq(c, flags, &rs);
            try self.flushRun(&rs);
            return self.finishChildren(base, .concat);
        }

        /// Append one AST node to the current concat sequence. Concats are
        /// flattened and non-capturing groups inlined (their flag delta applied
        /// to the inlined subtree) so adjacent literals coalesce maximally.
        fn appendSeq(self: *Self, idx: u32, flags: Flags, rs: *RunState) BuildError!void {
            const node = self.a.nodes[idx];
            switch (node.tag) {
                .concat => {
                    const d = node.data.children;
                    for (self.a.children[d.start .. d.start + d.len]) |c| try self.appendSeq(c, flags, rs);
                },
                .non_capture => {
                    const nc = node.data.non_capture;
                    try self.appendSeq(nc.child, applyDelta(flags, nc.flags_add, nc.flags_remove), rs);
                },
                .literal => {
                    if (try self.plainLiteralCp(idx, flags)) |cp| {
                        if (!rs.have) {
                            rs.start = self.lit_len;
                            rs.have = true;
                        }
                        try self.addLiteralCp(cp);
                        rs.len += 1;
                    } else {
                        try self.flushRun(rs);
                        try self.push(try self.lowerLiteral(node.data.literal.code_point, flags));
                    }
                },
                else => {
                    try self.flushRun(rs);
                    try self.push(try self.lower(idx, flags));
                },
            }
        }

        fn lowerAlternation(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const d = self.a.nodes[idx].data.children;
            const base = self.stack_len;
            for (self.a.children[d.start .. d.start + d.len]) |c| {
                const child = try self.lower(c, flags);
                try self.push(child);
            }
            return self.finishChildren(base, .alternation);
        }

        /// Pop the gathered child indices above `base`, and build a `concat`/
        /// `alternation` node — collapsing the empty and single-child cases.
        fn finishChildren(self: *Self, base: u32, comptime tag: Tag) BuildError!u32 {
            const n = self.stack_len - base;
            defer self.stack_len = base;
            if (n == 0) return self.addNode(.{ .tag = .empty, .data = .{ .none = {} } });
            if (n == 1) return self.stack[base];
            const cstart = self.child_len;
            var i = base;
            while (i < self.stack_len) : (i += 1) try self.addChild(self.stack[i]);
            return self.addNode(.{ .tag = tag, .data = .{ .children = .{ .start = cstart, .len = n } } });
        }

        fn lowerRepetition(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const r = self.a.nodes[idx].data.range;
            const child = try self.lower(r.child, flags);
            const q = r.quantifier;
            if (q.min == 1 and q.max != null and q.max.? == 1) return child; // {1} → child
            if (q.min == 0 and q.max != null and q.max.? == 0) return self.addNode(.{ .tag = .empty, .data = .{ .none = {} } });
            // Empty-width-loop collapse: an UNBOUNDED outer (`*`/`+`/`{m,}`) over a
            // body that lowers to a NULLABLE repetition (`S*`, `S?`, `S{0,k}` and their
            // lazy forms, optionally wrapped in a capture) is idempotent up to the
            // body's unbounded form — `(S*)* ≡ S*`, `(S?)+ ≡ S*`, `(S??){3,} ≡ S*?` —
            // because repeating a nullable repetition any number of times matches the
            // same language as one unbounded repetition with the body's greediness.
            // Without this, the redundant outer loop lets the Pike VM over-consume on a
            // nullable lazy body (`(?:c*?)+.` matched "cc" not "c"; `(?:a??){3,}` matched
            // "aaa" not ""), diverging from leftmost-first (Rust/RE2). So drop the outer
            // and widen the body's repetition to unbounded (`max = null`); the body
            // keeps its consume capability, so downstream-forced cases (`(?:a*?)+b` →
            // "aaab") are intact. Decided from the AST (mirrors these collapses
            // recursively) so the count/emit passes agree; the widening mutates the
            // freshly-lowered body in place (emit only — a no-op for an already
            // unbounded body), adding no node. See `astNullableRepBody`.
            if (q.max == null and self.astNullableRepBody(r.child)) {
                if (emit) self.widenBodyRepToUnbounded(child);
                return child;
            }
            return self.addNode(.{ .tag = .repetition, .data = .{ .repetition = .{
                .child = child,
                .min = q.min,
                .max = q.max,
                .greedy = q.greedy,
            } } });
        }

        /// Widen the repetition reached through `idx` (looking past a capture wrapper)
        /// to unbounded (`max = null`) — the emit-only half of the empty-width-loop
        /// collapse. The body is already nullable (`min == 0`), so only `max` changes;
        /// for an already-unbounded body this is a no-op.
        fn widenBodyRepToUnbounded(self: *Self, idx: u32) void {
            switch (self.nodes[idx].tag) {
                .repetition => self.nodes[idx].data.repetition.max = null,
                .capture => self.widenBodyRepToUnbounded(self.nodes[idx].data.capture.child),
                else => {},
            }
        }

        /// Whether the AST subtree at `idx` lowers to a **nullable repetition** (a
        /// `repetition` node with `min == 0` — `S*`/`S*?`/`S?`/`S??`/`S{0,k}`), seen
        /// through transparent wrappers and the same structural collapses `lower`
        /// applies. Used to decide the empty-width-loop collapse in `lowerRepetition`;
        /// pure over the AST so both builder passes agree.
        fn astNullableRepBody(self: *Self, idx: u32) bool {
            const node = self.a.nodes[idx];
            return switch (node.tag) {
                .non_capture => self.astNullableRepBody(node.data.non_capture.child),
                .capture => self.astNullableRepBody(node.data.capture.child),
                .range => blk: {
                    const q = node.data.range.quantifier;
                    // `{1}` → child: defer to the child's lowering.
                    if (q.min == 1 and q.max != null and q.max.? == 1)
                        break :blk self.astNullableRepBody(node.data.range.child);
                    // `{0,0}` → `empty` (not a repetition).
                    if (q.max != null and q.max.? == 0) break :blk false;
                    if (q.min == 0) break :blk true; // nullable rep: `S*`/`S*?`/`S?`/`S??`/`S{0,k}`
                    // `S+` / `S{k,}` (min ≥ 1): unbounded ones collapse to their child
                    // iff that child is itself a nullable rep (same rule, one level
                    // down); bounded min-≥1 reps are not nullable.
                    if (q.max == null) break :blk self.astNullableRepBody(node.data.range.child);
                    break :blk false;
                },
                else => false,
            };
        }

        fn lowerCapture(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const c = self.a.nodes[idx].data.capture;
            const child = try self.lower(c.child, flags);
            return self.addNode(.{ .tag = .capture, .data = .{ .capture = .{
                .child = child,
                .index = c.index,
                .name = c.name,
            } } });
        }

        /// Non-capturing groups disappear: apply any scoped flag delta to the
        /// subtree and return the lowered child directly.
        fn lowerNonCapture(self: *Self, idx: u32, flags: Flags) BuildError!u32 {
            const nc = self.a.nodes[idx].data.non_capture;
            const inner = applyDelta(flags, nc.flags_add, nc.flags_remove);
            return self.lower(nc.child, inner);
        }

        /// Returns the code point if `idx` is a literal that lowers to a single
        /// code point (so it can join a literal run), else null.
        fn plainLiteralCp(self: *Self, idx: u32, flags: Flags) BuildError!?CodePoint {
            const node = self.a.nodes[idx];
            if (node.tag != .literal) return null;
            const cp = node.data.literal.code_point;
            if (!self.foldActive(flags)) return cp;
            // A full-fold code point that expands (`ß`→`ss`, `ﬀ`→`ff`) cannot join a
            // plain literal run — it must go through `lowerLiteral` to become an
            // alternation. Force the non-run path.
            if (self.opts.case_fold == .full and fullFoldExpands(cp)) return null;
            self.member_len = 0;
            try self.addFolded(cp, cp, flags);
            sortRanges(self.member[0..self.member_len], self.aux);
            const k = mergeRanges(self.member[0..self.member_len]);
            if (k == 1 and self.member[0].lo == self.member[0].hi) return cp;
            return null;
        }
    };
}

// ── flag / anchor helpers ───────────────────────────────────────────────────────

fn applyDelta(base: Flags, add: Flags, remove: Flags) Flags {
    return .{
        .case_insensitive = (base.case_insensitive or add.case_insensitive) and !remove.case_insensitive,
        .multiline = (base.multiline or add.multiline) and !remove.multiline,
        .dot_all = (base.dot_all or add.dot_all) and !remove.dot_all,
        .verbose = (base.verbose or add.verbose) and !remove.verbose,
    };
}

fn resolveAnchor(kind: ast.AnchorKind, flags: Flags) AnchorKind {
    return switch (kind) {
        .line_begin => if (flags.multiline) .line_start else .text_start,
        .line_end => if (flags.multiline) .line_end else .text_end,
        .input_begin => .text_start,
        .input_end => .text_end,
        .word => .word_boundary,
        .non_word => .not_word_boundary,
    };
}

fn inGroup(cat: props.GeneralCategory, group: GeneralCategoryGroup) bool {
    return switch (group) {
        .letter => switch (cat) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter, .modifier_letter, .other_letter => true,
            else => false,
        },
        .cased_letter => switch (cat) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter => true,
            else => false,
        },
        .mark => switch (cat) {
            .non_spacing_mark, .spacing_mark, .enclosing_mark => true,
            else => false,
        },
        .number => switch (cat) {
            .decimal_number, .letter_number, .other_number => true,
            else => false,
        },
        .punctuation => switch (cat) {
            .connector_punctuation, .dash_punctuation, .open_punctuation, .close_punctuation, .initial_punctuation, .final_punctuation, .other_punctuation => true,
            else => false,
        },
        .symbol => switch (cat) {
            .math_symbol, .currency_symbol, .modifier_symbol, .other_symbol => true,
            else => false,
        },
        .separator => switch (cat) {
            .space_separator, .line_separator, .paragraph_separator => true,
            else => false,
        },
        .other => switch (cat) {
            .control, .format, .surrogate, .private_use, .unassigned => true,
            else => false,
        },
    };
}

// ── range sort / merge ──────────────────────────────────────────────────────────

fn isSorted(s: []const Range) bool {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i].lo < s[i - 1].lo) return false;
    }
    return true;
}

/// Sort `s` by `lo`. Two properties keep this cheap *at comptime* (where every
/// backward branch counts against the eval quota):
///   * ezi_code's range tables are sorted partitions, so a single-member class
///     (`\d`, `\p{L}`, `[a-z]`) and the post-merge `main` set arrive already
///     sorted — `isSorted` returns immediately, no sort at all.
///   * Only a multi-table member (`\w` = Alphabetic∪Mark∪Nd∪Pc∪Join_Control)
///     arrives unsorted. We use a hand-rolled **bottom-up merge sort with an
///     inline comparison** — no `std.sort` comparator-function-pointer overhead,
///     which at comptime costs several branches *per comparison*. `aux` is a
///     same-sized scratch buffer.
fn sortRanges(s: []Range, aux: []Range) void {
    if (isSorted(s)) return;
    const n: usize = s.len;
    var src: []Range = s;
    var dst: []Range = aux[0..n];
    var width: usize = 1;
    while (width < n) : (width *= 2) {
        var i: usize = 0;
        while (i < n) : (i += 2 * width) {
            const mid: usize = @min(i + width, n);
            const hi: usize = @min(i + 2 * width, n);
            var a: usize = i;
            var b: usize = mid;
            var k: usize = i;
            while (a < mid and b < hi) : (k += 1) {
                if (src[b].lo < src[a].lo) {
                    dst[k] = src[b];
                    b += 1;
                } else {
                    dst[k] = src[a];
                    a += 1;
                }
            }
            while (a < mid) : (a += 1) {
                dst[k] = src[a];
                k += 1;
            }
            while (b < hi) : (b += 1) {
                dst[k] = src[b];
                k += 1;
            }
        }
        const t = src;
        src = dst;
        dst = t;
    }
    if (src.ptr != s.ptr) @memcpy(s, src[0..n]);
}

/// Coalesce a sorted range list in place, merging overlapping and adjacent
/// ranges. Returns the merged length.
fn mergeRanges(s: []Range) usize {
    if (s.len == 0) return 0;
    var w: usize = 0;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const cur = s[i];
        // Adjacent (cur.lo == s[w].hi + 1) merges too; guard the +1 at the top.
        if (s[w].hi != MAX_CP and cur.lo <= s[w].hi + 1) {
            if (cur.hi > s[w].hi) s[w].hi = cur.hi;
        } else {
            w += 1;
            s[w] = cur;
        }
    }
    return w + 1;
}

// ── Analysis ────────────────────────────────────────────────────────────────────

fn analyze(
    nodes: []const Node,
    children: []const u32,
    ranges: []const Range,
    literals: []const CodePoint,
    root: u32,
    has_grapheme: bool,
) Analysis {
    const cp = lenBounds(nodes, children, root);
    const by = byteBounds(nodes, children, ranges, literals, root);
    var req = Required{};
    collectRequired(nodes, children, literals, root, &req);
    return .{
        .anchored_start = startsAnchored(nodes, children, root),
        .anchored_end = endsAnchored(nodes, children, root),
        .min_len = cp.min,
        .max_len = cp.max,
        .min_utf8_len = by.min,
        .max_utf8_len = by.max,
        .has_grapheme = has_grapheme,
        .has_word_boundary = hasWordBoundary(nodes, children, root),
        .word_boundary_in_alternation = wordBoundaryInAlternation(nodes, children, root, false),
        .nullable_alternation_in_repetition = nullableAlternationInRepetition(nodes, children, root, false),
        .interior_text_end = interiorTextEnd(nodes, children, root, false),
        .word_boundary_with_nullable_alternation = hasWordBoundary(nodes, children, root) and
            hasNullableAlternation(nodes, children, root),
        .word_boundary_with_lazy_repetition = hasWordBoundary(nodes, children, root) and
            hasLazyRepetition(nodes, children, root),
        .word_boundary_with_adjacent_repetition = hasWordBoundary(nodes, children, root) and
            hasAdjacentRepetition(nodes, children, root),
        .word_boundary_after_varying_alternation = wordBoundaryAfterVaryingAlternation(nodes, children, ranges, literals, root),
        .word_boundary_in_repetition = wordBoundaryInRepetition(nodes, children, root, false),
        .complex_line_anchor = complexLineAnchor(nodes, children, root, false, false, false, false, false),
        .line_end_after_nullable_alternation = lineEndAfterNullableAlternation(nodes, children, root),
        .is_whole_literal = nodes[root].tag == .literal,
        .is_one_pass = false, // decided by the backend's NFA compiler; see Analysis
        .prefix_literal = prefixLiteral(nodes, children, root),
        .required_literal = req.best,
        .required_bytes = req.bytes,
        .line_anchored_start = startsLineAnchored(nodes, children, root),
        .prefix_set = prefixSet(nodes, children, root),
        .inner_anchor = innerAnchor(nodes, children, ranges, literals, root),
        .required_literal_skip = requiredLiteralSkip(nodes, children, ranges, literals, root),
        .leading_class_first = leadingClassFirst(nodes, children, ranges, root),
    };
}

const Bounds = struct { min: u32, max: ?u32 };

fn lenBounds(nodes: []const Node, children: []const u32, idx: u32) Bounds {
    const node = nodes[idx];
    return switch (node.tag) {
        .empty, .anchor => .{ .min = 0, .max = 0 },
        .literal => .{ .min = node.data.run.len, .max = node.data.run.len },
        .class, .any => .{ .min = 1, .max = 1 },
        .grapheme => .{ .min = 1, .max = null }, // a cluster is ≥1 code points, unbounded
        .capture => lenBounds(nodes, children, node.data.capture.child),
        .repetition => blk: {
            const c = lenBounds(nodes, children, node.data.repetition.child);
            const min = c.min * node.data.repetition.min;
            const max: ?u32 = if (node.data.repetition.max) |mx|
                (if (c.max) |cm| cm * mx else null)
            else
                null;
            break :blk .{ .min = min, .max = max };
        },
        .concat => blk: {
            const d = node.data.children;
            var min: u32 = 0;
            var max: ?u32 = 0;
            for (children[d.start .. d.start + d.len]) |ci| {
                const c = lenBounds(nodes, children, ci);
                min += c.min;
                max = addMax(max, c.max);
            }
            break :blk .{ .min = min, .max = max };
        },
        .alternation => blk: {
            const d = node.data.children;
            var min: u32 = std.math.maxInt(u32);
            var max: ?u32 = 0;
            for (children[d.start .. d.start + d.len]) |ci| {
                const c = lenBounds(nodes, children, ci);
                if (c.min < min) min = c.min;
                max = maxMax(max, c.max);
            }
            break :blk .{ .min = min, .max = max };
        },
    };
}

fn addMax(a: ?u32, b: ?u32) ?u32 {
    return if (a) |x| (if (b) |y| x + y else null) else null;
}

fn maxMax(a: ?u32, b: ?u32) ?u32 {
    if (a == null or b == null) return null;
    return @max(a.?, b.?);
}

fn startsAnchored(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => node.data.anchor.kind == .text_start,
        .concat => blk: {
            const d = node.data.children;
            if (d.len == 0) break :blk false;
            break :blk startsAnchored(nodes, children, children[d.start]);
        },
        // An alternation starts anchored iff EVERY branch does (`^a|^b`): then every match
        // begins at offset 0. (Sound widening of a one-sided fact — a branch that can start
        // anywhere keeps the whole alternation un-anchored.)
        .alternation => blk: {
            const d = node.data.children;
            if (d.len == 0) break :blk false;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (!startsAnchored(nodes, children, ci)) break :blk false;
            }
            break :blk true;
        },
        .capture => startsAnchored(nodes, children, node.data.capture.child),
        else => false,
    };
}

/// Mirror of `startsAnchored`: the pattern is pinned to end-of-input (`text_end`).
/// Looks at the *last* element of a concat / the capture body.
fn endsAnchored(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => node.data.anchor.kind == .text_end,
        .concat => blk: {
            const d = node.data.children;
            if (d.len == 0) break :blk false;
            break :blk endsAnchored(nodes, children, children[d.start + d.len - 1]);
        },
        // An alternation ends anchored iff EVERY branch does (`foo$|bar$`, `a$|b$`): then every
        // match ends at input end. This lets the eager DFA take its O(input) reverse-from-end
        // path for these instead of declining to the Pike VM. A branch that can end mid-input
        // (truly mixed `$`, e.g. `a$|b`) keeps the whole alternation un-anchored — see
        // `engine/backends/edfa.zig` `supports`.
        .alternation => blk: {
            const d = node.data.children;
            if (d.len == 0) break :blk false;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (!endsAnchored(nodes, children, ci)) break :blk false;
            }
            break :blk true;
        },
        .capture => endsAnchored(nodes, children, node.data.capture.child),
        else => false,
    };
}

/// Whether any `\b`/`\B` assertion appears anywhere in the tree.
fn hasWordBoundary(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => switch (node.data.anchor.kind) {
            .word_boundary, .not_word_boundary => true,
            else => false,
        },
        .concat, .alternation => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (hasWordBoundary(nodes, children, ci)) break :blk true;
            }
            break :blk false;
        },
        .capture => hasWordBoundary(nodes, children, node.data.capture.child),
        .repetition => hasWordBoundary(nodes, children, node.data.repetition.child),
        else => false,
    };
}

/// Whether a `\b`/`\B` assertion appears with an `alternation` ancestor. `in_alt`
/// becomes true once we descend through an alternation node; a boundary reached
/// while it is set means the DFAs can't preserve leftmost-first across the
/// assertion (see `Analysis.word_boundary_in_alternation`). Conservative: it does
/// not try to prove the sibling branches consume — any `\b` under an `|` trips it.
fn wordBoundaryInAlternation(nodes: []const Node, children: []const u32, idx: u32, in_alt: bool) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => in_alt and switch (node.data.anchor.kind) {
            .word_boundary, .not_word_boundary => true,
            else => false,
        },
        .alternation => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (wordBoundaryInAlternation(nodes, children, ci, true)) break :blk true;
            }
            break :blk false;
        },
        .concat => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (wordBoundaryInAlternation(nodes, children, ci, in_alt)) break :blk true;
            }
            break :blk false;
        },
        .capture => wordBoundaryInAlternation(nodes, children, node.data.capture.child, in_alt),
        .repetition => wordBoundaryInAlternation(nodes, children, node.data.repetition.child, in_alt),
        else => false,
    };
}

/// Whether a repetition loops over an `alternation` with a nullable branch (see
/// `Analysis.nullable_alternation_in_repetition`). `in_rep` becomes true once we descend
/// through a `repetition` child; an alternation reached while it is set, with
/// `lenBounds(alt).min == 0` (some branch matches empty), trips it. Conservative — it does
/// not check that the alternation is the *immediate* loop body, only that it sits somewhere
/// inside the looped subtree.
fn nullableAlternationInRepetition(nodes: []const Node, children: []const u32, idx: u32, in_rep: bool) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .alternation => blk: {
            if (in_rep and lenBounds(nodes, children, idx).min == 0) break :blk true;
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (nullableAlternationInRepetition(nodes, children, ci, in_rep)) break :blk true;
            }
            break :blk false;
        },
        .concat => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (nullableAlternationInRepetition(nodes, children, ci, in_rep)) break :blk true;
            }
            break :blk false;
        },
        .capture => nullableAlternationInRepetition(nodes, children, node.data.capture.child, in_rep),
        // Descending through a repetition puts its child subtree inside a loop.
        .repetition => nullableAlternationInRepetition(nodes, children, node.data.repetition.child, true),
        else => false,
    };
}

/// Whether the subtree contains an `alternation` with a nullable branch
/// (`lenBounds(alt).min == 0`). Paired with `hasWordBoundary` to flag
/// `Analysis.word_boundary_with_nullable_alternation`.
fn hasNullableAlternation(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .alternation => blk: {
            if (lenBounds(nodes, children, idx).min == 0) break :blk true;
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (hasNullableAlternation(nodes, children, ci)) break :blk true;
            }
            break :blk false;
        },
        .concat => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (hasNullableAlternation(nodes, children, ci)) break :blk true;
            }
            break :blk false;
        },
        .capture => hasNullableAlternation(nodes, children, node.data.capture.child),
        .repetition => hasNullableAlternation(nodes, children, node.data.repetition.child),
        else => false,
    };
}

/// Whether the subtree contains a **lazy** repetition — any non-greedy repetition
/// (`a*?`, `a+?`, `a??`, `a{m,n}?`), regardless of `min`. Paired with
/// `hasWordBoundary` for `Analysis.word_boundary_with_lazy_repetition`.
fn hasLazyRepetition(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .repetition => blk: {
            const r = node.data.repetition;
            if (!r.greedy) break :blk true;
            break :blk hasLazyRepetition(nodes, children, r.child);
        },
        .concat, .alternation => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (hasLazyRepetition(nodes, children, ci)) break :blk true;
            }
            break :blk false;
        },
        .capture => hasLazyRepetition(nodes, children, node.data.capture.child),
        else => false,
    };
}

/// Whether any concat holds two **adjacent consuming repetitions** — a repetition
/// (looking through a capture wrapper) immediately followed by another, with no
/// consumer between. Their split is ambiguous, which combined with a `\b` defeats the
/// byte DFA's leftmost-first priority (see
/// `Analysis.word_boundary_with_adjacent_repetition`). Used only gated behind
/// `hasWordBoundary`, so a rep pair without a boundary stays on the DFA.
fn hasAdjacentRepetition(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    switch (node.tag) {
        .concat => {
            const d = node.data.children;
            const slice = children[d.start .. d.start + d.len];
            var prev_is_rep = false;
            for (slice) |ci| {
                if (hasAdjacentRepetition(nodes, children, ci)) return true; // nested
                const leads = leadingRepetition(nodes, children, ci);
                if (leads and prev_is_rep) return true;
                // A purely zero-width atom (anchor/empty) doesn't break adjacency;
                // any consuming non-rep resets it.
                if (!isZeroWidth(nodes, children, ci)) prev_is_rep = leads;
            }
            return false;
        },
        .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (hasAdjacentRepetition(nodes, children, ci)) return true;
            }
            return false;
        },
        .capture => return hasAdjacentRepetition(nodes, children, node.data.capture.child),
        .repetition => return hasAdjacentRepetition(nodes, children, node.data.repetition.child),
        else => return false,
    }
}

/// Whether a `\b`/`\B` appears **lexically inside a repetition** (see
/// `Analysis.word_boundary_in_repetition`). `in_rep` latches true once we descend through a
/// `repetition`; a word-boundary anchor reached while it is set trips it. Conservative — a
/// boundary anywhere under any repetition flags it, which over-declines the eager DFA only
/// (never trades correctness) and spares the top-level `\b\w+\b` / `\bthe\b` benchmarks.
fn wordBoundaryInRepetition(nodes: []const Node, children: []const u32, idx: u32, in_rep: bool) bool {
    const node = nodes[idx];
    switch (node.tag) {
        .anchor => return in_rep and switch (node.data.anchor.kind) {
            .word_boundary, .not_word_boundary => true,
            else => false,
        },
        .concat, .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci|
                if (wordBoundaryInRepetition(nodes, children, ci, in_rep)) return true;
            return false;
        },
        .capture => return wordBoundaryInRepetition(nodes, children, node.data.capture.child, in_rep),
        .repetition => return wordBoundaryInRepetition(nodes, children, node.data.repetition.child, true),
        else => return false,
    }
}

/// Whether `idx` is (or, through a capture, wraps) a repetition node — its match
/// begins with a repeated atom.
fn leadingRepetition(nodes: []const Node, children: []const u32, idx: u32) bool {
    return switch (nodes[idx].tag) {
        .repetition => true,
        .capture => leadingRepetition(nodes, children, nodes[idx].data.capture.child),
        else => false,
    };
}

/// Whether the subtree is purely zero-width (no path consumes a byte): an anchor,
/// `empty`, or a capture/alternation/concat built only from those.
fn isZeroWidth(nodes: []const Node, children: []const u32, idx: u32) bool {
    return !canConsume(nodes, children, idx);
}

// ── `\b` after a length-varying alternation (see Analysis.word_boundary_after_varying_alternation) ──

/// The code-point ranges a subtree can **begin** with — its FIRST set. `broad` means
/// "overlaps everything" (`.`/`\X`, or more ranges than the small fixed buffer holds); it
/// keeps the overlap test sound by over-approximating (over-declines the eager DFA, never
/// mis-matches). Allocation-free so the analysis runs at comptime.
const FirstSet = struct {
    const CAP = 16;
    ranges: [CAP]Range = undefined,
    n: usize = 0,
    broad: bool = false,

    fn add(self: *FirstSet, r: Range) void {
        if (self.broad) return;
        if (self.n >= CAP) {
            self.broad = true;
            return;
        }
        self.ranges[self.n] = r;
        self.n += 1;
    }
};

/// Fill `out` with the FIRST set of the subtree at `idx`, following nullable prefixes (a
/// nullable leading child contributes its first set and we continue to the next). Pure.
fn firstSet(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32, out: *FirstSet) void {
    const node = nodes[idx];
    switch (node.tag) {
        .empty, .anchor => {}, // zero-width: contributes nothing
        .any, .grapheme => out.broad = true, // matches (almost) any scalar
        .literal => {
            const r = node.data.run;
            if (r.len > 0) {
                const cp = literals[r.start];
                out.add(.{ .lo = cp, .hi = cp });
            }
        },
        .class => {
            const c = node.data.class;
            for (ranges[c.start .. c.start + c.len]) |rg| out.add(rg);
        },
        .capture => firstSet(nodes, children, ranges, literals, node.data.capture.child, out),
        .repetition => firstSet(nodes, children, ranges, literals, node.data.repetition.child, out),
        .concat => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                firstSet(nodes, children, ranges, literals, ci, out);
                if (lenBounds(nodes, children, ci).min > 0) break; // first mandatory child ends the FIRST set
            }
        },
        .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| firstSet(nodes, children, ranges, literals, ci, out);
        },
    }
}

fn firstSetsOverlap(a: *const FirstSet, b: *const FirstSet) bool {
    if (a.broad or b.broad) return true;
    for (a.ranges[0..a.n]) |ra| {
        for (b.ranges[0..b.n]) |rb| {
            if (ra.lo <= rb.hi and rb.lo <= ra.hi) return true;
        }
    }
    return false;
}

/// Whether the `alternation` at `idx` has two branches whose FIRST sets overlap — i.e. they
/// can both match some common starting code point (so they can match the same start at
/// different lengths). Disjoint-first alternations (`b+|a+`, `foo|bar`) return false.
fn alternationBranchesOverlapFirst(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32) bool {
    const d = nodes[idx].data.children;
    const kids = children[d.start .. d.start + d.len];
    var i: usize = 0;
    while (i < kids.len) : (i += 1) {
        var fi = FirstSet{};
        firstSet(nodes, children, ranges, literals, kids[i], &fi);
        var j = i + 1;
        while (j < kids.len) : (j += 1) {
            var fj = FirstSet{};
            firstSet(nodes, children, ranges, literals, kids[j], &fj);
            if (firstSetsOverlap(&fi, &fj)) return true;
        }
    }
    return false;
}

/// The `alternation` node `idx` wraps (directly, or via a capture and/or a **repetition**),
/// else null. Non-capturing groups are already removed in HIR, so an alternation is bare,
/// capture-wrapped, or repetition-wrapped. Seeing through a repetition catches a varying
/// alternation under a quantifier immediately before a `\b` (`(?:.|b\n)*\b`, `(?:b+|.+)*\B`):
/// the repetition only ADDS match-end ambiguity, so the same eager-DFA leftmost-first loss
/// applies. (Found by the differential anchor fuzz; the body-overlap + boundary-follows gate
/// at the call site keeps it tight, and over-flagging only forgoes the eager arm.)
fn alternationThroughWrap(nodes: []const Node, idx: u32) ?u32 {
    return switch (nodes[idx].tag) {
        .alternation => idx,
        .capture => alternationThroughWrap(nodes, nodes[idx].data.capture.child),
        .repetition => alternationThroughWrap(nodes, nodes[idx].data.repetition.child),
        else => null,
    };
}

/// Whether matching the subtree at `idx` can reach a `\b`/`\B` with **zero** consumption
/// first (the boundary is at the start of its match path). Used to test whether a boundary
/// immediately follows the alternation.
fn leadsToWordBoundary(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => switch (node.data.anchor.kind) {
            .word_boundary, .not_word_boundary => true,
            else => false,
        },
        .capture => leadsToWordBoundary(nodes, children, node.data.capture.child),
        .concat => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (leadsToWordBoundary(nodes, children, ci)) break :blk true;
                if (lenBounds(nodes, children, ci).min > 0) break :blk false; // a mandatory consumer first
            }
            break :blk false;
        },
        .alternation => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| if (leadsToWordBoundary(nodes, children, ci)) break :blk true;
            break :blk false;
        },
        .repetition => node.data.repetition.min > 0 and leadsToWordBoundary(nodes, children, node.data.repetition.child),
        else => false,
    };
}

/// Whether a `\b`/`\B` appears anywhere after position `from` in the concat children `kids`.
///
/// The earlier version stopped at the first MANDATORY consumer on the assumption that it
/// "pins the alternation's end and removes the ambiguity". The fuzz differential disproved
/// that: `(?:ba()|b+)*.\B` over "bbabb" — the `.` between the repetition and `\B` is exactly
/// one code point, so leftmost-first (a later `{3,4}` span) and the eager DFA's
/// leftmost-longest (`{0,4}`) still diverge. A consumer between the alternation and the
/// boundary only *shifts* where the boundary lands; it does not collapse the overlapping-first
/// alternation's end ambiguity. So the scan sees through any consumer — fixed or varying.
///
/// This is only ever reached behind the call site's overlapping-first-alternation gate
/// (`alternationBranchesOverlapFirst`), a rare pathological shape, and it gates ONLY the eager
/// DFA arm (`auto` falls back to the equally-linear lazy DFA / Pike VM), so over-flagging here
/// costs at most that fast path, never correctness.
fn boundaryFollowsInConcat(nodes: []const Node, children: []const u32, kids: []const u32, from: usize) bool {
    var i = from;
    while (i < kids.len) : (i += 1) {
        if (leadsToWordBoundary(nodes, children, kids[i])) return true;
    }
    return false;
}

/// Whether the pattern has a `\b`/`\B` immediately following an `alternation` whose branches
/// have overlapping FIRST sets (see `Analysis.word_boundary_after_varying_alternation`). The
/// eager byte DFA loses the alternation's leftmost-first priority across the trailing
/// boundary; the Pike VM / backtracker / lazy DFA are correct, so this gates only the eager
/// DFA. Conservative (over-flagging only forgoes the eager arm, never trades correctness).
fn wordBoundaryAfterVaryingAlternation(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32) bool {
    const node = nodes[idx];
    switch (node.tag) {
        .concat => {
            const d = node.data.children;
            const kids = children[d.start .. d.start + d.len];
            for (kids, 0..) |ci, i| {
                if (wordBoundaryAfterVaryingAlternation(nodes, children, ranges, literals, ci)) return true; // nested
                if (alternationThroughWrap(nodes, ci)) |alt| {
                    if (alternationBranchesOverlapFirst(nodes, children, ranges, literals, alt) and
                        boundaryFollowsInConcat(nodes, children, kids, i + 1)) return true;
                }
            }
            return false;
        },
        .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci|
                if (wordBoundaryAfterVaryingAlternation(nodes, children, ranges, literals, ci)) return true;
            return false;
        },
        .capture => return wordBoundaryAfterVaryingAlternation(nodes, children, ranges, literals, node.data.capture.child),
        .repetition => return wordBoundaryAfterVaryingAlternation(nodes, children, ranges, literals, node.data.repetition.child),
        else => return false,
    }
}

/// Whether a `text_end` anchor sits in a non-trailing position — i.e. a consuming
/// atom can follow it (see `Analysis.interior_text_end`). `consumer_follows`
/// tracks, top-down, whether something after the current node in the match can
/// consume; a `text_end` reached while it is set is interior. A concat threads it
/// right-to-left (a later child that consumes makes earlier children "followed by a
/// consumer"); a repetition that can iterate again with a consuming body also
/// counts as a consumer following its body.
fn interiorTextEnd(nodes: []const Node, children: []const u32, idx: u32, consumer_follows: bool) bool {
    const node = nodes[idx];
    switch (node.tag) {
        .anchor => return consumer_follows and node.data.anchor.kind == .text_end,
        .concat => {
            const d = node.data.children;
            var cf = consumer_follows;
            var i = d.len;
            while (i > 0) {
                i -= 1;
                const ci = children[d.start + i];
                if (interiorTextEnd(nodes, children, ci, cf)) return true;
                // A `text_end` is non-trailing if a consumer follows it OR a
                // `text_start` follows it (`$^\z` — a text_start after an end is
                // degenerate, and the DFA's reverse-end path mishandles it).
                if (canConsume(nodes, children, ci) or subtreeHasTextStart(nodes, children, ci)) cf = true;
            }
            return false;
        },
        .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (interiorTextEnd(nodes, children, ci, consumer_follows)) return true;
            }
            return false;
        },
        .capture => return interiorTextEnd(nodes, children, node.data.capture.child, consumer_follows),
        .repetition => {
            const rep = node.data.repetition;
            // Another iteration can follow (and consume) when the rep allows >1 reps
            // and its body can consume.
            const can_repeat = rep.max == null or rep.max.? > 1;
            const child_cf = consumer_follows or
                (can_repeat and canConsume(nodes, children, rep.child));
            return interiorTextEnd(nodes, children, rep.child, child_cf);
        },
        else => return false,
    }
}

/// Whether a subtree can consume at least one byte on some path — i.e. it is not
/// purely zero-width (anchors / empty). A nullable-but-consuming atom (`.?`, `a*`,
/// `\n?`) counts: it *may* consume, which is enough to make a preceding `text_end`
/// non-trailing. (`lenBounds.max` is 0 only for a purely zero-width subtree.)
fn canConsume(nodes: []const Node, children: []const u32, idx: u32) bool {
    const b = lenBounds(nodes, children, idx);
    return b.max == null or b.max.? > 0;
}

/// Whether the subtree contains a `text_start` (`\A` / non-multiline `^`) anchor.
fn subtreeHasTextStart(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => node.data.anchor.kind == .text_start,
        .concat, .alternation => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (subtreeHasTextStart(nodes, children, ci)) break :blk true;
            }
            break :blk false;
        },
        .capture => subtreeHasTextStart(nodes, children, node.data.capture.child),
        .repetition => subtreeHasTextStart(nodes, children, node.data.repetition.child),
        else => false,
    };
}

/// Whether a `(?m)` line anchor sits in a shape the eager byte DFA can't handle —
/// a non-leading `line_start`, a non-trailing `line_end`, or any line anchor under a
/// repetition (see `Analysis.complex_line_anchor`). The DFA can model at most a
/// *leading* line-start context and a *trailing* line-end context, so a `line_start`
/// must have nothing but other line-starts before it and a `line_end` nothing but
/// other line-ends after it. `consumer_before`/`consumer_after` track whether
/// something on the match path can consume before/after the current node;
/// `line_end_before` tracks whether a `line_end` precedes it with no consumer between
/// (which makes a following `line_start` interior — `$^` is zero-width yet the two
/// contexts can't be carried at one offset, unlike the natural `^$` order); `in_rep`
/// is set once we descend through a repetition (whose body repeats, so a line anchor
/// there can never be cleanly leading/trailing); `in_alt` is set once we descend into
/// an alternation branch — a line anchor there is a zero-width branch the DFA's line
/// model can't priority-order against a consuming sibling (`(?m:$)|.` matches empty
/// leftmost-first, the DFA takes the longer branch), the line analogue of
/// `word_boundary_in_alternation`.
fn complexLineAnchor(
    nodes: []const Node,
    children: []const u32,
    idx: u32,
    in_rep: bool,
    consumer_before: bool,
    consumer_after: bool,
    line_end_before: bool,
    in_alt: bool,
) bool {
    const node = nodes[idx];
    switch (node.tag) {
        .anchor => return switch (node.data.anchor.kind) {
            // a `(?m)^` that isn't leading: a consumer or an earlier `line_end`
            // (`$^`) on the path before it puts it past the match's leading edge.
            .line_start => in_rep or consumer_before or line_end_before or in_alt,
            .line_end => in_rep or consumer_after or in_alt, // a `(?m)$` that isn't trailing / is a branch
            else => false,
        },
        .concat => {
            const d = node.data.children;
            const slice = children[d.start .. d.start + d.len];
            for (slice, 0..) |ci, i| {
                var cb = consumer_before;
                var le_before = line_end_before;
                for (slice[0..i]) |cj| {
                    if (canConsume(nodes, children, cj)) cb = true;
                    if (subtreeHasLineEnd(nodes, children, cj)) le_before = true;
                }
                var ca = consumer_after;
                for (slice[i + 1 ..]) |cj| {
                    if (canConsume(nodes, children, cj)) ca = true;
                }
                if (complexLineAnchor(nodes, children, ci, in_rep, cb, ca, le_before, in_alt)) return true;
            }
            return false;
        },
        .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (complexLineAnchor(nodes, children, ci, in_rep, consumer_before, consumer_after, line_end_before, true)) return true;
            }
            return false;
        },
        .capture => return complexLineAnchor(nodes, children, node.data.capture.child, in_rep, consumer_before, consumer_after, line_end_before, in_alt),
        .repetition => return complexLineAnchor(nodes, children, node.data.repetition.child, true, consumer_before, consumer_after, line_end_before, in_alt),
        else => return false,
    }
}

/// Whether the subtree contains a `line_end` (`(?m)$`) anchor — used to detect a
/// `line_end` that precedes a later `line_start` on the match path (`$^`), a shape the
/// eager byte DFA can't carry. Conservative: a `line_end` anywhere in an earlier
/// sibling counts (an over-match just declines the pattern to the correct Pike VM).
fn subtreeHasLineEnd(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => node.data.anchor.kind == .line_end,
        .concat, .alternation => blk: {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (subtreeHasLineEnd(nodes, children, ci)) break :blk true;
            }
            break :blk false;
        },
        .capture => subtreeHasLineEnd(nodes, children, node.data.capture.child),
        .repetition => subtreeHasLineEnd(nodes, children, node.data.repetition.child),
        else => false,
    };
}

/// Whether the node (directly or through a capture) is an `alternation` with a **nullable**
/// branch (`lenBounds.min == 0`). The head-of-branch test for `lineEndAfterNullableAlternation`.
fn nullableAlternationHead(nodes: []const Node, children: []const u32, idx: u32) bool {
    return switch (nodes[idx].tag) {
        .alternation => lenBounds(nodes, children, idx).min == 0,
        .capture => nullableAlternationHead(nodes, children, nodes[idx].data.capture.child),
        else => false,
    };
}

/// Whether a `(?m)$` `line_end` sits in a concat with a **nullable alternation** before it and no
/// MANDATORY consumer in between (see `Analysis.line_end_after_nullable_alternation`). The eager
/// DFA loses leftmost-first there: the alternation's empty branch is preferred (shorter), but the
/// line_end also holds after a consuming branch (`\n`), so the longest-match DFA takes the longer
/// end. Gates the eager DFA only. Conservative — a nullable alternation anywhere before the
/// line_end with only nullable/zero-width siblings between trips it (over-flagging just forgoes the
/// eager arm).
fn lineEndAfterNullableAlternation(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    switch (node.tag) {
        .concat => {
            const d = node.data.children;
            const kids = children[d.start .. d.start + d.len];
            var nullable_alt_pending = false;
            for (kids) |ci| {
                if (lineEndAfterNullableAlternation(nodes, children, ci)) return true; // nested concat
                const cn = nodes[ci];
                if (cn.tag == .anchor and cn.data.anchor.kind == .line_end and nullable_alt_pending) return true;
                if (nullableAlternationHead(nodes, children, ci)) {
                    nullable_alt_pending = true;
                } else if (lenBounds(nodes, children, ci).min > 0) {
                    nullable_alt_pending = false; // a mandatory consumer pins the position — ambiguity gone
                }
            }
            return false;
        },
        .alternation => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (lineEndAfterNullableAlternation(nodes, children, ci)) return true;
            }
            return false;
        },
        .capture => return lineEndAfterNullableAlternation(nodes, children, node.data.capture.child),
        .repetition => return lineEndAfterNullableAlternation(nodes, children, node.data.repetition.child),
        else => return false,
    }
}

/// The literal run every match must begin with, or null. Follows the mandatory
/// leading atom — skipping leading zero-width anchors (`^`, `\b`) in a concat, and
/// descending through capture / `min≥1` repetition bodies — down to a literal node.
/// A class, `.`, alternation, or optional (`min==0`) leading atom ends it with null.
fn prefixLiteral(nodes: []const Node, children: []const u32, idx: u32) ?Node.Run {
    const node = nodes[idx];
    return switch (node.tag) {
        .literal => node.data.run,
        .concat => blk: {
            const d = node.data.children;
            var i = d.start;
            while (i < d.start + d.len) : (i += 1) {
                const ci = children[i];
                switch (nodes[ci].tag) {
                    .anchor, .empty => continue, // zero-width: the match begins after it
                    else => break :blk prefixLiteral(nodes, children, ci),
                }
            }
            break :blk null;
        },
        .capture => prefixLiteral(nodes, children, node.data.capture.child),
        .repetition => if (node.data.repetition.min >= 1)
            prefixLiteral(nodes, children, node.data.repetition.child)
        else
            null,
        else => null,
    };
}

/// Mirror of `startsAnchored`, widened to **line** starts: true when every match
/// begins at offset 0 or just after a `\n`. The leading mandatory anchor must be
/// `line_start` (`(?m)^`) or `text_start` (`^`/`\A`); an alternation qualifies only
/// when every branch does. Sound one-sided fact (a branch that can start anywhere
/// keeps the whole pattern un-line-anchored).
fn startsLineAnchored(nodes: []const Node, children: []const u32, idx: u32) bool {
    const node = nodes[idx];
    return switch (node.tag) {
        .anchor => switch (node.data.anchor.kind) {
            .line_start, .text_start => true,
            else => false,
        },
        .concat => blk: {
            const d = node.data.children;
            if (d.len == 0) break :blk false;
            break :blk startsLineAnchored(nodes, children, children[d.start]);
        },
        .alternation => blk: {
            const d = node.data.children;
            if (d.len == 0) break :blk false;
            for (children[d.start .. d.start + d.len]) |ci| {
                if (!startsLineAnchored(nodes, children, ci)) break :blk false;
            }
            break :blk true;
        },
        .capture => startsLineAnchored(nodes, children, node.data.capture.child),
        else => false,
    };
}

/// The leading-literal set of a top-level alternation in which every branch begins
/// with a fixed literal (see `PrefixSet`), or null. Descends a capture wrapping the
/// alternation. Declines when the branch count is outside `[2, MAX_PREFIX_BRANCHES]`
/// or any branch lacks a leading literal — in which case no sound multi-prefix bound
/// exists and the dispatcher falls back to an unfiltered scan.
fn prefixSet(nodes: []const Node, children: []const u32, idx: u32) ?PrefixSet {
    const node = nodes[idx];
    switch (node.tag) {
        .capture => return prefixSet(nodes, children, node.data.capture.child),
        .alternation => {
            const d = node.data.children;
            if (d.len < 2 or d.len > MAX_PREFIX_BRANCHES) return null;
            var set = PrefixSet{ .runs = undefined, .len = 0 };
            for (children[d.start .. d.start + d.len]) |ci| {
                const pl = prefixLiteral(nodes, children, ci) orelse return null;
                set.runs[set.len] = pl;
                set.len += 1;
            }
            return set;
        },
        else => return null,
    }
}

/// The interior required-literal anchor of a `[\w.+-]+@…`-shaped pattern (see
/// `InnerAnchor`), or null. Recognizes: an optional capture wrapping a concat whose
/// first mandatory atom is a variable **class** run (a class, or a repetition of one)
/// and whose next mandatory atom is a **literal**. The literal's first byte is the
/// memchr target; the class's byte alphabet is the reverse-scan set.
fn innerAnchor(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32) ?InnerAnchor {
    var root_idx = idx;
    if (nodes[root_idx].tag == .capture) root_idx = nodes[root_idx].data.capture.child;
    if (nodes[root_idx].tag != .concat) return null;
    const d = nodes[root_idx].data.children;
    if (d.len < 2) return null;
    const lead = leadClassBytes(nodes, children, ranges, children[d.start]) orelse return null;
    const cp = firstLiteralCp(nodes, children, literals, children[d.start + 1]) orelse return null;
    if (!encoding.isValidCodePoint(cp)) return null;
    var buf: [4]u8 = undefined;
    const n = utf8.encodeCodePointUnchecked(cp, &buf);
    if (n == 0) return null;
    return .{ .byte = buf[0], .lead_class = lead, .lead_fixed_cps = leadFixedCps(nodes, children[d.start]) };
}

/// The general required-literal skip (see `RequiredLiteralSkip`), or null. Descends a capture to
/// reach the top-level **concat**, then walks its children left to right accumulating `lead` —
/// the union of every preceding atom's possible bytes (`atomByteSet`) — and records the **longest**
/// mandatory `.literal` child preceded by at least one consuming atom, paired with the `lead`
/// accumulated up to it. Stops extending at the first atom whose byte set is not computable (`.`,
/// `\X`) — no literal past such an atom can have a bounded preceding alphabet. Returns null when
/// no qualifying literal exists, or when the accumulated alphabet is the full 256 bytes (a reverse
/// scan over which never advances). The longest literal is chosen for memmem selectivity.
fn requiredLiteralSkip(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32) ?RequiredLiteralSkip {
    var root_idx = idx;
    if (nodes[root_idx].tag == .capture) root_idx = nodes[root_idx].data.capture.child;
    if (nodes[root_idx].tag != .concat) return null;
    const d = nodes[root_idx].data.children;

    var lead = ByteSet{};
    var seen_consuming = false; // a prior atom that contributes bytes (else a leading literal — `prefixLiteral`'s job)
    var fixed: ?u32 = 0; // running fixed cp-offset from match start; null once a variable atom is seen
    var best: ?Node.Run = null;
    var best_lead = ByteSet{};
    var best_fixed: ?u32 = null;
    var best_len: u32 = 0;
    var best_pos: usize = 0; // index in `children` of the chosen literal (to test the suffix property)

    var i = d.start;
    while (i < d.start + d.len) : (i += 1) {
        const ci = children[i];
        const node = nodes[ci];
        if (node.tag == .literal and seen_consuming and node.data.run.len > best_len) {
            best = node.data.run;
            best_lead = lead;
            best_fixed = fixed;
            best_len = node.data.run.len;
            best_pos = i;
        }
        // Fold this atom's bytes into the running alphabet for any later literal. An
        // uncomputable atom (`.`/`\X`) bounds how far we can extend — stop here.
        const bs = atomByteSet(nodes, children, ranges, literals, ci) orelse break;
        if (!bs.isEmpty()) seen_consuming = true;
        lead.unionWith(bs);
        // Track the fixed cp-offset (for the fixed-offset confirm); a variable atom latches null.
        if (fixed) |fx| {
            fixed = if (atomFixedCps(nodes, children, ci)) |a| fx + a else null;
        }
    }

    const run = best orelse return null;
    if (best_lead.count() >= 256) return null; // universal alphabet — the reverse scan can't advance

    // Suffix property: every consuming atom is at or before the literal — the match ends exactly at
    // the literal end (`\w+\s+Holmes`, `[a-zA-Z]+ing`), which lets a matcher reverse-confirm from a
    // memmem hit's end with no forward extension. False when a consuming atom follows it
    // (`\w+\s+Holmes\s+\w+`); only trailing zero-width anchors/empties are allowed after.
    var is_suffix = true;
    var j = best_pos + 1;
    while (j < d.start + d.len) : (j += 1) {
        switch (nodes[children[j]].tag) {
            .anchor, .empty => {},
            else => {
                is_suffix = false;
                break;
            },
        }
    }

    // Structured reverse-walk atoms: the class-repetition atoms before the literal, in spine order,
    // when each is a single-class repetition and adjacent classes are pairwise disjoint (so a greedy
    // reverse consume per atom lands on the exact start). Zero-width atoms are skipped. Any other
    // atom (a literal, `.`, an alternation, an overlapping-class neighbour, or > MAX) disables it.
    var pre: [MAX_PRE_ATOMS]PreAtom = @splat(.{ .bits = .{}, .min = 0, .max = 0 });
    var pre_n: u8 = 0;
    var pre_ok = true;
    {
        var k = d.start;
        while (k < best_pos) : (k += 1) {
            switch (nodes[children[k]].tag) {
                .anchor, .empty => continue, // zero-width: consumes nothing
                else => {},
            }
            const cr = classRepInfo(nodes, children, ranges, children[k]) orelse {
                pre_ok = false;
                break;
            };
            if (pre_n >= MAX_PRE_ATOMS) {
                pre_ok = false;
                break;
            }
            pre[pre_n] = cr;
            pre_n += 1;
        }
    }
    if (pre_ok and pre_n > 0) {
        // Adjacent spine classes must be disjoint so the greedy reverse split is forced (and exact).
        var a: usize = 1;
        while (a < pre_n) : (a += 1) {
            if (!bytesDisjoint(pre[a - 1].bits, pre[a].bits)) {
                pre_ok = false;
                break;
            }
        }
    } else pre_ok = false;
    if (!pre_ok) pre_n = 0;

    return .{
        .run = run,
        .lead_class = best_lead,
        .lead_fixed_cps = best_fixed,
        .is_suffix = is_suffix,
        .pre = pre,
        .pre_n = pre_n,
    };
}

/// Byte alphabet + repetition bounds of a single-class-repetition atom (`\w+`, `[a-z]{2,5}`, a bare
/// class), or null when `idx` is not such an atom (a literal, `.`, an alternation, a multi-atom
/// group). A bare class is `[1,1]`; an unbounded repetition reports `max = maxInt`. Descends a
/// capture. Used to build the structured reverse-walk atoms (`RequiredLiteralSkip.pre`).
fn classRepInfo(nodes: []const Node, children: []const u32, ranges: []const Range, idx: u32) ?PreAtom {
    const node = nodes[idx];
    return switch (node.tag) {
        .class => .{ .bits = classBytes(ranges[node.data.class.start .. node.data.class.start + node.data.class.len]), .min = 1, .max = 1 },
        .capture => classRepInfo(nodes, children, ranges, node.data.capture.child),
        .repetition => blk: {
            const r = node.data.repetition;
            if (nodes[r.child].tag != .class) break :blk null; // only a direct class body
            const c = nodes[r.child].data.class;
            break :blk .{ .bits = classBytes(ranges[c.start .. c.start + c.len]), .min = r.min, .max = r.max orelse std.math.maxInt(u32) };
        },
        else => null,
    };
}

/// Whether two byte sets share no **ASCII** (`< 0x80`) member — the condition that makes a greedy
/// reverse consume of adjacent structured-walk atoms unambiguous. Only ASCII matters: the
/// structured walk's fast path runs on pure-ASCII windows (high bytes, which `classBytes` sets
/// conservatively for every Unicode class, fall to the dispatcher's flat-scan fallback), so the
/// shared high bytes of `\w`/`\s` must not spuriously fail the disjointness gate.
fn bytesDisjoint(a: ByteSet, b: ByteSet) bool {
    return (a.bits[0] & b.bits[0]) == 0 and (a.bits[1] & b.bits[1]) == 0; // bytes 0..127
}

/// Fixed code-point length of an atom, or null when it is variable-length. Like `leadFixedCps`
/// but over the general atom set used by `requiredLiteralSkip`: a class / `.` is one code point,
/// a literal run its length, a fixed (`min==max`) repetition `count × body`, a concat the sum,
/// an alternation the common length only when every branch agrees, zero-width atoms contribute 0.
fn atomFixedCps(nodes: []const Node, children: []const u32, idx: u32) ?u32 {
    const node = nodes[idx];
    return switch (node.tag) {
        .empty, .anchor => 0,
        .literal => node.data.run.len,
        .class, .any => 1,
        .grapheme => null, // a grapheme cluster is a variable number of code points
        .capture => atomFixedCps(nodes, children, node.data.capture.child),
        .repetition => blk: {
            const r = node.data.repetition;
            const mx = r.max orelse break :blk null;
            if (mx != r.min) break :blk null;
            const body = atomFixedCps(nodes, children, r.child) orelse break :blk null;
            break :blk r.min * body;
        },
        .concat => blk: {
            const d = node.data.children;
            var sum: u32 = 0;
            for (children[d.start .. d.start + d.len]) |ci| sum += atomFixedCps(nodes, children, ci) orelse break :blk null;
            break :blk sum;
        },
        .alternation => blk: {
            const d = node.data.children;
            var common: ?u32 = null;
            for (children[d.start .. d.start + d.len]) |ci| {
                const c = atomFixedCps(nodes, children, ci) orelse break :blk null;
                if (common) |cm| {
                    if (cm != c) break :blk null; // branches differ in length → variable
                } else common = c;
            }
            break :blk common;
        },
    };
}

/// The superset of UTF-8 bytes an atom can contribute to a match, or null when that set is the
/// whole byte space / not statically computable (`.` `any`, `\X` grapheme). Literals contribute
/// their code points' bytes; a class its `classBytes` (ASCII exact, high conservative); a
/// repetition/capture descends to the child; a concat/alternation unions its members (a sound
/// superset — every branch's bytes may appear). Used to accumulate a required literal's
/// reverse-scan alphabet (`requiredLiteralSkip`).
fn atomByteSet(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32) ?ByteSet {
    const node = nodes[idx];
    switch (node.tag) {
        .empty, .anchor => return ByteSet{}, // zero-width: no bytes
        .literal => {
            var bs = ByteSet{};
            const r = node.data.run;
            for (literals[r.start .. r.start + r.len]) |c| addCpBytes(&bs, c);
            return bs;
        },
        .class => return classBytes(ranges[node.data.class.start .. node.data.class.start + node.data.class.len]),
        .capture => return atomByteSet(nodes, children, ranges, literals, node.data.capture.child),
        .repetition => return atomByteSet(nodes, children, ranges, literals, node.data.repetition.child),
        .concat, .alternation => {
            var bs = ByteSet{};
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| {
                const child = atomByteSet(nodes, children, ranges, literals, ci) orelse return null;
                bs.unionWith(child);
            }
            return bs;
        },
        .any, .grapheme => return null, // universal / unbounded alphabet
    }
}

/// Code-point length of a leading run when it is **fixed**, else null (see
/// `InnerAnchor.lead_fixed_cps`). A bare class is one code point; a counted repetition of a
/// fixed-length body (`\d{4}`) is `min × body` when `min == max`; a capture descends to its
/// child. A variable repetition (`+`, `*`, `{m,}`, `{m,n}` with `m≠n`), or a body that is
/// not itself fixed, yields null. The reverse-scan path covers those.
fn leadFixedCps(nodes: []const Node, idx: u32) ?u32 {
    const node = nodes[idx];
    return switch (node.tag) {
        .class => 1,
        .capture => leadFixedCps(nodes, node.data.capture.child),
        .repetition => blk: {
            const r = node.data.repetition;
            const mx = r.max orelse break :blk null; // unbounded → variable
            if (mx != r.min) break :blk null; // {m,n}, m≠n → variable
            const body = leadFixedCps(nodes, r.child) orelse break :blk null;
            break :blk r.min * body;
        },
        else => null,
    };
}

/// The byte alphabet of a leading variable **class** atom (`[\w.+-]+`, `\S+`, `[a-z]*`,
/// a bare class), or null when `idx` is not such an atom. Descends a capture / a
/// repetition wrapping the class. ASCII members are set exactly; if the class has any
/// code point ≥ 0x80, **all** high bytes are set (a sound superset for the reverse scan).
fn leadClassBytes(nodes: []const Node, children: []const u32, ranges: []const Range, idx: u32) ?ByteSet {
    const node = nodes[idx];
    return switch (node.tag) {
        .class => classBytes(ranges[node.data.class.start .. node.data.class.start + node.data.class.len]),
        .capture => leadClassBytes(nodes, children, ranges, node.data.capture.child),
        .repetition => leadClassBytes(nodes, children, ranges, node.data.repetition.child),
        else => null,
    };
}

/// Build a `ByteSet` from a class's resolved (sorted, positive) ranges, with the
/// non-ASCII conservatism described on `leadClassBytes`.
fn classBytes(rngs: []const Range) ByteSet {
    var bs = ByteSet{};
    var any_high = false;
    for (rngs) |r| {
        if (r.lo <= 0x7F) {
            var b: CodePoint = r.lo;
            const hi: CodePoint = @min(r.hi, 0x7F);
            while (b <= hi) : (b += 1) bs.set(@intCast(b));
        }
        if (r.hi >= 0x80) any_high = true;
    }
    if (any_high) {
        var b: u16 = 0x80;
        while (b < 0x100) : (b += 1) bs.set(@intCast(b));
    }
    return bs;
}

/// First code point of a leading literal atom (descending a capture / `min≥1`
/// repetition), or null when `idx` is not a literal-bearing mandatory atom.
fn firstLiteralCp(nodes: []const Node, children: []const u32, literals: []const CodePoint, idx: u32) ?CodePoint {
    const node = nodes[idx];
    return switch (node.tag) {
        .literal => literals[node.data.run.start],
        .capture => firstLiteralCp(nodes, children, literals, node.data.capture.child),
        .repetition => if (node.data.repetition.min >= 1)
            firstLiteralCp(nodes, children, literals, node.data.repetition.child)
        else
            null,
        else => null,
    };
}

/// First-UTF-8-byte set of the leading mandatory **class** atom, or null. Mirrors
/// `prefixLiteral`'s spine walk (skip leading zero-width anchors in a concat; descend
/// capture / `min≥1` repetition bodies), but stops at a `class` — returning its possible
/// leading bytes (`classFirstByteSet`) — and returns null when the leading atom is a
/// literal (covered by `prefixLiteral`), `.`, an alternation, an optional, or a grapheme.
/// Sound: every match's first code point is in the class, so its first byte is in the set.
fn leadingClassFirst(nodes: []const Node, children: []const u32, ranges: []const Range, idx: u32) ?ByteSet {
    const node = nodes[idx];
    return switch (node.tag) {
        .class => classFirstByteSet(ranges[node.data.class.start .. node.data.class.start + node.data.class.len]),
        .concat => blk: {
            const d = node.data.children;
            var i = d.start;
            while (i < d.start + d.len) : (i += 1) {
                const ci = children[i];
                switch (nodes[ci].tag) {
                    .anchor, .empty => continue, // zero-width: the match begins after it
                    else => break :blk leadingClassFirst(nodes, children, ranges, ci),
                }
            }
            break :blk null;
        },
        .capture => leadingClassFirst(nodes, children, ranges, node.data.capture.child),
        .repetition => if (node.data.repetition.min >= 1)
            leadingClassFirst(nodes, children, ranges, node.data.repetition.child)
        else
            null,
        else => null,
    };
}

/// The set of possible **first UTF-8 bytes** of any code point in a class's resolved
/// (sorted, positive) ranges. ASCII members contribute themselves; a multi-byte member
/// contributes the lead byte of its UTF-8 encoding. Computed per tier (1/2/3/4-byte) so a
/// huge range never iterates code points: within a tier the lead byte is monotic in the
/// code point, so `leadByte(lo)..leadByte(hi)` is the exact contiguous lead-byte span.
fn classFirstByteSet(rngs: []const Range) ByteSet {
    var bs = ByteSet{};
    for (rngs) |r| addFirstBytes(&bs, r.lo, @min(r.hi, MAX_CP));
    return bs;
}

/// Add to `bs` the UTF-8 lead bytes for code points in `[lo, hi]`, split by UTF-8 length
/// tier (the lead byte is monotonic in the code point within each tier, so each tier
/// contributes one contiguous byte range).
fn addFirstBytes(bs: *ByteSet, lo: CodePoint, hi: CodePoint) void {
    const tiers = [_]struct { lo: CodePoint, hi: CodePoint }{
        .{ .lo = 0, .hi = 0x7F },
        .{ .lo = 0x80, .hi = 0x7FF },
        .{ .lo = 0x800, .hi = 0xFFFF },
        .{ .lo = 0x10000, .hi = MAX_CP },
    };
    for (tiers) |t| {
        const a = @max(lo, t.lo);
        const b = @min(hi, t.hi);
        if (a > b) continue;
        var byte = leadByte(a);
        const last = leadByte(b);
        while (byte <= last) : (byte += 1) bs.set(byte);
    }
}

/// First UTF-8 byte of `cp` (its encoding's lead byte), computed arithmetically so it works
/// over a whole tier without encoding. Surrogates never reach here (HIR ranges are scalars).
fn leadByte(cp: CodePoint) u8 {
    if (cp <= 0x7F) return @intCast(cp);
    if (cp <= 0x7FF) return @intCast(0xC0 | (cp >> 6));
    if (cp <= 0xFFFF) return @intCast(0xE0 | (cp >> 12));
    return @intCast(0xF0 | (cp >> 18));
}

/// Accumulator for `collectRequired`: the longest required literal run found
/// (`best`, the prefilter needle) and the union of required literal bytes.
const Required = struct { best: ?Node.Run = null, bytes: ByteSet = .{} };

/// Gather literal facts that hold for *every* match. Walks only the **mandatory
/// spine** — every concat child, capture / `min≥1` repetition bodies — recording
/// the longest literal run seen and every literal code point's UTF-8 bytes.
/// Alternations (no single branch is required) and `min==0` repetitions (optional)
/// are skipped, so every recorded fact is sound (a true lower bound on "must
/// appear").
fn collectRequired(nodes: []const Node, children: []const u32, literals: []const CodePoint, idx: u32, acc: *Required) void {
    const node = nodes[idx];
    switch (node.tag) {
        .literal => {
            const r = node.data.run;
            if (acc.best == null or r.len > acc.best.?.len) acc.best = r;
            for (literals[r.start .. r.start + r.len]) |c| addCpBytes(&acc.bytes, c);
        },
        .concat => {
            const d = node.data.children;
            for (children[d.start .. d.start + d.len]) |ci| collectRequired(nodes, children, literals, ci, acc);
        },
        .capture => collectRequired(nodes, children, literals, node.data.capture.child, acc),
        .repetition => if (node.data.repetition.min >= 1)
            collectRequired(nodes, children, literals, node.data.repetition.child, acc),
        // class/any/grapheme/anchor/empty contribute no fixed literal; alternation
        // is skipped — no single branch is mandatory.
        else => {},
    }
}

/// Set the UTF-8 bytes of `cp` in `set`. A required code point's bytes appear
/// verbatim and contiguously in every match (UTF-8 is self-synchronizing), so each
/// is individually a "must appear" byte.
fn addCpBytes(set: *ByteSet, cp: CodePoint) void {
    // `encodeCodePointUnchecked` assumes a valid scalar (a surrogate or
    // out-of-range value is illegal behaviour), so guard first — this also
    // reproduces the old `utf8Encode … catch return`: non-encodable code points
    // are skipped.
    if (!encoding.isValidCodePoint(cp)) return;
    var buf: [4]u8 = undefined;
    const n = utf8.encodeCodePointUnchecked(cp, &buf);
    for (buf[0..n]) |b| set.set(b);
}

const ByteBounds = struct { min: u32, max: ?u32 };

/// UTF-8 byte length of a code point (1–4). Resolved HIR code points are always
/// encodable; the `catch 4` is a defensive upper bound.
fn utf8Len(cp: CodePoint) u32 {
    // `utf8EncodeLen` is `unreachable` on an out-of-range scalar; guard so the
    // defensive upper bound of 4 still applies to any non-encodable value.
    if (!encoding.isValidCodePoint(cp)) return 4;
    return utf8.utf8EncodeLen(cp);
}

/// Match-length bounds in UTF-8 bytes (parallels `lenBounds`, which counts code
/// points). A class spans `[utf8Len(lo) .. utf8Len(hi)]`: UTF-8 length is monotonic
/// in code-point value and the class ranges are sorted, so the first range's `lo`
/// is the shortest member and the last range's `hi` the longest.
fn byteBounds(nodes: []const Node, children: []const u32, ranges: []const Range, literals: []const CodePoint, idx: u32) ByteBounds {
    const node = nodes[idx];
    return switch (node.tag) {
        .empty, .anchor => .{ .min = 0, .max = 0 },
        .literal => blk: {
            const r = node.data.run;
            var n: u32 = 0;
            for (literals[r.start .. r.start + r.len]) |c| n += utf8Len(c);
            break :blk .{ .min = n, .max = n };
        },
        .class => blk: {
            const c = node.data.class;
            if (c.len == 0) break :blk .{ .min = 1, .max = 1 }; // unmatchable; vacuous bound
            break :blk .{ .min = utf8Len(ranges[c.start].lo), .max = utf8Len(ranges[c.start + c.len - 1].hi) };
        },
        .any => .{ .min = 1, .max = 4 }, // any code point is 1–4 UTF-8 bytes
        .grapheme => .{ .min = 1, .max = null },
        .capture => byteBounds(nodes, children, ranges, literals, node.data.capture.child),
        .repetition => blk: {
            const c = byteBounds(nodes, children, ranges, literals, node.data.repetition.child);
            const rep = node.data.repetition;
            const min = c.min * rep.min;
            const max: ?u32 = if (rep.max) |mx| (if (c.max) |cm| cm * mx else null) else null;
            break :blk .{ .min = min, .max = max };
        },
        .concat => blk: {
            const d = node.data.children;
            var min: u32 = 0;
            var max: ?u32 = 0;
            for (children[d.start .. d.start + d.len]) |ci| {
                const c = byteBounds(nodes, children, ranges, literals, ci);
                min += c.min;
                max = addMax(max, c.max);
            }
            break :blk .{ .min = min, .max = max };
        },
        .alternation => blk: {
            const d = node.data.children;
            var min: u32 = std.math.maxInt(u32);
            var max: ?u32 = 0;
            for (children[d.start .. d.start + d.len]) |ci| {
                const c = byteBounds(nodes, children, ranges, literals, ci);
                if (c.min < min) min = c.min;
                max = maxMax(max, c.max);
            }
            break :blk .{ .min = min, .max = max };
        },
    };
}

// ════════════════════════════════════════════════════════════════════════════════
// Storage-agnostic entry points
// ════════════════════════════════════════════════════════════════════════════════

/// Count-only pass: run the identical lowering and report exact output sizes.
/// `scratch` must be at least `scratchSizes(a)`.
///
/// @stable-since: v0.1.0
pub fn measure(a: ast.Ast, opts: Options, scratch: Scratch) BuildError!Sizes {
    var b = Builder(.count){
        .a = a,
        .opts = opts,
        .stack = scratch.stack,
        .main = scratch.main,
        .member = scratch.member,
        .aux = scratch.aux,
    };
    _ = try b.lower(a.root, a.flags);
    return .{
        .nodes = b.node_len,
        .children = b.child_len,
        .ranges = b.range_len,
        .literals = b.lit_len,
        .names = a.names.len,
    };
}

/// Emit pass: lower `a` into the caller's `buffers` (each at least the matching
/// `measure` size) and return the `Hir` sub-slicing them. `scratch` is as for
/// `measure`.
///
/// @stable-since: v0.1.0
pub fn build(a: ast.Ast, opts: Options, scratch: Scratch, buffers: Buffers) BuildError!Hir {
    var b = Builder(.emit){
        .a = a,
        .opts = opts,
        .nodes = buffers.nodes,
        .children = buffers.children,
        .ranges = buffers.ranges,
        .literals = buffers.literals,
        .names = buffers.names,
        .stack = scratch.stack,
        .main = scratch.main,
        .member = scratch.member,
        .aux = scratch.aux,
    };
    const root = try b.lower(a.root, a.flags);
    // Names are borrowed verbatim from the AST (which borrows the pattern).
    for (a.names) |nm| try b.addName(nm);

    const nodes = b.nodes[0..b.node_len];
    const children = b.children[0..b.child_len];
    const ranges = b.ranges[0..b.range_len];
    const literals = b.literals[0..b.lit_len];

    return .{
        .nodes = nodes,
        .children = children,
        .ranges = ranges,
        .literals = literals,
        .names = b.names[0..b.name_len],
        .root = root,
        .capture_count = a.capture_count,
        .analysis = analyze(nodes, children, ranges, literals, root, b.has_grapheme),
    };
}

// ════════════════════════════════════════════════════════════════════════════════
// Comptime / runtime wrappers (the only places that know where storage lives)
// ════════════════════════════════════════════════════════════════════════════════

/// Result of the comptime builder (comptime can't thread an out-parameter).
///
/// @stable-since: v0.1.0
pub const Outcome = union(enum) {
    ok: Hir,
    fail: BuildError,
};

/// Build a HIR at runtime into heap memory. Provisions scratch + exactly-sized
/// output buffers from `allocator`. Free with `hir.deinitHir(allocator, &hir)`.
///
/// @stable-since: v0.1.0
pub fn buildAlloc(allocator: std.mem.Allocator, a: ast.Ast, opts: Options) (BuildError || std.mem.Allocator.Error)!Hir {
    const ss = scratchSizes(a);
    const stack = try allocator.alloc(u32, ss.stack);
    defer allocator.free(stack);
    const main = try allocator.alloc(Range, ss.ranges);
    defer allocator.free(main);
    const member = try allocator.alloc(Range, ss.ranges);
    defer allocator.free(member);
    const aux = try allocator.alloc(Range, ss.ranges);
    defer allocator.free(aux);
    const scratch = Scratch{ .stack = stack, .main = main, .member = member, .aux = aux };

    const sizes = try measure(a, opts, scratch);

    // Zero-length allocations are valid and free cleanly, so we always alloc —
    // it keeps every buffer a mutable `[]T` (an empty const literal would not
    // coerce to the mutable `Buffers` fields).
    const nodes = try allocator.alloc(Node, sizes.nodes);
    errdefer allocator.free(nodes);
    const children = try allocator.alloc(u32, sizes.children);
    errdefer allocator.free(children);
    const ranges = try allocator.alloc(Range, sizes.ranges);
    errdefer allocator.free(ranges);
    const literals = try allocator.alloc(CodePoint, sizes.literals);
    errdefer allocator.free(literals);
    const names = try allocator.alloc([]const u8, sizes.names);

    return try build(a, opts, scratch, .{
        .nodes = nodes,
        .children = children,
        .ranges = ranges,
        .literals = literals,
        .names = names,
    });
}

/// Free the heap arrays of a runtime-built HIR. Never call on a comptime HIR
/// (its slices are const data). `names` entries borrow the pattern and are not
/// freed — only the `names` array is.
///
/// @stable-since: v0.1.0
pub fn deinitHir(allocator: std.mem.Allocator, hir: Hir) void {
    allocator.free(hir.nodes);
    allocator.free(hir.children);
    allocator.free(hir.ranges);
    allocator.free(hir.literals);
    allocator.free(hir.names);
}

/// Comptime eval-branch ceiling for `buildComptime`.
///
/// IMPORTANT: this is a *guard ceiling*, not a cost — Zig only spends branches on
/// work actually done, so a roomy ceiling never slows a pattern that does little.
/// We still size it from the real worst case, not a blanket per-node number (the
/// old bug: 200k × nodes gave a trivial 50-char literal a ~13M ceiling). Cost is
/// dominated by, across the two passes (measure + build):
///   * **class members** (`\d`/`\w`/`\p{…}`/range): walk ezi_code's range tables
///     and merge-sort the result. The worst single member is `\w`
///     (Alphabetic∪Mark∪Nd∪Pc∪Join_Control ≈ 1070 ranges from 4 tables) —
///     **measured ~250k branches** for both passes → `per_class_item` covers it.
///   * **nodes under `(?i)`**: a per-code-point fold-table scan, twice → `per_node`.
/// The ceiling thus scales with the genuinely expensive parts (Unicode class
/// items, which are rare); literal/ASCII patterns get tens of thousands, not millions.
fn comptimeBranchBudget(a: ast.Ast) u64 {
    const base: u64 = 20_000;
    const per_node: u64 = 8_000; // per-code-point case-fold table scan, both passes
    const per_class_item: u64 = 300_000; // measured \w ≈ 250k + ~20% headroom
    return base + @as(u64, a.nodes.len) * per_node + @as(u64, a.class_items.len) * per_class_item;
}

/// Build a HIR at comptime into ro_data. Returns `.ok` with a HIR whose slices
/// point at const data, or `.fail`.
///
/// @stable-since: v0.1.0
pub fn buildComptime(comptime a: ast.Ast, comptime opts: Options) Outcome {
    @setEvalBranchQuota(@intCast(@min(comptimeBranchBudget(a), std.math.maxInt(u32))));
    const ss = comptime scratchSizes(a);

    var stack: [ss.stack]u32 = undefined;
    var main: [ss.ranges]Range = undefined;
    var member: [ss.ranges]Range = undefined;
    var aux: [ss.ranges]Range = undefined;
    const scratch = Scratch{ .stack = &stack, .main = &main, .member = &member, .aux = &aux };

    const sizes = measure(a, opts, scratch) catch |e| return .{ .fail = e };

    var nodes: [sizes.nodes]Node = undefined;
    var children: [sizes.children]u32 = undefined;
    var ranges: [sizes.ranges]Range = undefined;
    var literals: [sizes.literals]CodePoint = undefined;
    var names: [sizes.names][]const u8 = undefined;

    const hir = build(a, opts, scratch, .{
        .nodes = &nodes,
        .children = &children,
        .ranges = &ranges,
        .literals = &literals,
        .names = &names,
    }) catch |e| return .{ .fail = e };

    // Promote the used sub-slices to ro_data so the HIR outlives this scope.
    const final_nodes = hir.nodes[0..hir.nodes.len].*;
    const final_children = hir.children[0..hir.children.len].*;
    const final_ranges = hir.ranges[0..hir.ranges.len].*;
    const final_literals = hir.literals[0..hir.literals.len].*;
    const final_names = hir.names[0..hir.names.len].*;

    return .{ .ok = .{
        .nodes = &final_nodes,
        .children = &final_children,
        .ranges = &final_ranges,
        .literals = &final_literals,
        .names = &final_names,
        .root = hir.root,
        .capture_count = hir.capture_count,
        .analysis = hir.analysis,
    } };
}

// ════════════════════════════════════════════════════════════════════════════════
// Debug: s-expression serialization (parallels scanner.formatAst)
// ════════════════════════════════════════════════════════════════════════════════

/// Write a compact s-expression for `h`. Grammar:
///   (cat …) (alt …)                 concat / alternation
///   (rep MIN MAX G X)               repetition; MAX is a number or "inf"; G g|l
///   (cap N X) / (cap N=name X)      capture
///   (run c…) / (run U+XX …)         literal run
///   (cls R…) / R = c | lo-hi        resolved class (positive ranges)
///   (any) (any.) (graph) (eps)      dot / dot-all / grapheme / empty
///   (anc KIND)                      anchor
///
/// @stable-since: v0.1.0
pub fn formatHir(h: Hir, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNode(h, h.root, w);
}

fn writeNode(h: Hir, idx: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const node = h.nodes[idx];
    switch (node.tag) {
        .empty => try w.writeAll("(eps)"),
        .literal => {
            const r = node.data.run;
            try w.writeAll("(run");
            for (h.literals[r.start .. r.start + r.len]) |cp| {
                try w.writeAll(" ");
                try writeCp(cp, w);
            }
            try w.writeAll(")");
        },
        .class => {
            const c = node.data.class;
            try w.writeAll("(cls");
            for (h.ranges[c.start .. c.start + c.len]) |rg| {
                try w.writeAll(" ");
                try writeCp(rg.lo, w);
                if (rg.hi != rg.lo) {
                    try w.writeAll("-");
                    try writeCp(rg.hi, w);
                }
            }
            try w.writeAll(")");
        },
        .any => try w.writeAll(if (node.data.any.dot_all) "(any.)" else "(any)"),
        .grapheme => try w.writeAll("(graph)"),
        .anchor => try w.print("(anc {s})", .{@tagName(node.data.anchor.kind)}),
        .concat => {
            try w.writeAll("(cat");
            const d = node.data.children;
            for (h.children[d.start .. d.start + d.len]) |ci| {
                try w.writeAll(" ");
                try writeNode(h, ci, w);
            }
            try w.writeAll(")");
        },
        .alternation => {
            try w.writeAll("(alt");
            const d = node.data.children;
            for (h.children[d.start .. d.start + d.len]) |ci| {
                try w.writeAll(" ");
                try writeNode(h, ci, w);
            }
            try w.writeAll(")");
        },
        .repetition => {
            const r = node.data.repetition;
            try w.print("(rep {d} ", .{r.min});
            if (r.max) |mx| try w.print("{d}", .{mx}) else try w.writeAll("inf");
            try w.writeAll(if (r.greedy) " g " else " l ");
            try writeNode(h, r.child, w);
            try w.writeAll(")");
        },
        .capture => {
            const c = node.data.capture;
            if (c.name) |ni| {
                try w.print("(cap {d}={s} ", .{ c.index, h.names[ni] });
            } else {
                try w.print("(cap {d} ", .{c.index});
            }
            try writeNode(h, c.child, w);
            try w.writeAll(")");
        },
    }
}

fn writeCp(cp: CodePoint, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (cp >= 0x21 and cp <= 0x7E) {
        try w.print("{c}", .{@as(u8, @intCast(cp))});
    } else {
        try w.print("U+{X}", .{cp});
    }
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("compile.zig");

/// Runtime: parse → HIR → s-expr, comparing against `expected` and freeing.
fn expectHir(pattern: []const u8, opts: Options, expected: []const u8) !void {
    var diag: compile.Diagnostic = .{};
    const a = try compile.parse(testing.allocator, pattern, &diag);
    defer a.deinit(testing.allocator);
    const h = try buildAlloc(testing.allocator, a, opts);
    defer deinitHir(testing.allocator, h);
    var buf: [1 << 16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatHir(h, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

/// Comptime: parse → HIR → s-expr at comptime.
fn comptimeHirSExpr(comptime pattern: []const u8, comptime opts: Options) []const u8 {
    comptime {
        const a = compile.compile(pattern);
        const h = switch (buildComptime(a, opts)) {
            .ok => |x| x,
            .fail => @compileError("HIR build failed for: " ++ pattern),
        };
        var buf: [1 << 16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        formatHir(h, &w) catch unreachable;
        const out = w.buffered();
        const arr = out[0..out.len].*;
        return &arr;
    }
}

test "literal run merging" {
    try expectHir("abc", .{}, "(run a b c)");
}

test "alternation and groups" {
    try expectHir("a(b|c)d", .{}, "(cat (run a) (cap 1 (alt (run b) (run c))) (run d))");
}

test "non-capturing group is inlined" {
    try expectHir("a(?:bc)d", .{}, "(run a b c d)");
}

test "repetition kept compact" {
    try expectHir("a{2,4}?", .{}, "(rep 2 4 l (run a))");
    try expectHir("a*", .{}, "(rep 0 inf g (run a))");
}

test "anchors resolve with multiline" {
    try expectHir("^a$", .{}, "(cat (anc text_start) (run a) (anc text_end))");
    try expectHir("(?m)^a$", .{}, "(cat (anc line_start) (run a) (anc line_end))");
}

test "ascii class merges and sorts" {
    try expectHir("[c-ea-b]", .{}, "(cls a-e)");
}

test "negated ascii class is complemented" {
    try expectHir("[^a]", .{}, "(cls U+0-` b-U+10FFFF)");
}

test "dot and dot-all" {
    try expectHir(".", .{}, "(any)");
    try expectHir("(?s).", .{}, "(any.)");
}

test "simple case folding widens a literal into a class" {
    // 'a' under (?i) → [Aa]
    try expectHir("(?i)a", .{ .case_fold = .simple }, "(cls A a)");
    // digit has no fold orbit → stays a literal
    try expectHir("(?i)5", .{ .case_fold = .simple }, "(run 5)");
    // case_fold = .none disables folding even under (?i)
    try expectHir("(?i)a", .{ .case_fold = .none }, "(run a)");
}

test "perl \\d resolves to the decimal-number ranges (ascii prefix)" {
    var diag: compile.Diagnostic = .{};
    const a = try compile.parse(testing.allocator, "\\d", &diag);
    defer a.deinit(testing.allocator);
    const h = try buildAlloc(testing.allocator, a, .{});
    defer deinitHir(testing.allocator, h);
    try testing.expectEqual(Tag.class, h.nodes[h.root].tag);
    const c = h.nodes[h.root].data.class;
    // First range must be ASCII 0-9.
    try testing.expectEqual(@as(CodePoint, '0'), h.ranges[c.start].lo);
    try testing.expectEqual(@as(CodePoint, '9'), h.ranges[c.start].hi);
    try testing.expect(c.len >= 1);
}

test "analysis: anchored, lengths, whole-literal" {
    var diag: compile.Diagnostic = .{};
    const a = try compile.parse(testing.allocator, "^abc", &diag);
    defer a.deinit(testing.allocator);
    const h = try buildAlloc(testing.allocator, a, .{});
    defer deinitHir(testing.allocator, h);
    try testing.expect(h.analysis.anchored_start);
    try testing.expect(!h.analysis.anchored_end);
    try testing.expectEqual(@as(u32, 3), h.analysis.min_len);
    try testing.expectEqual(@as(?u32, 3), h.analysis.max_len);
    try testing.expect(!h.analysis.is_whole_literal); // wrapped in a concat with the anchor
    // the leading `^` is zero-width — the prefix is still the run that follows it
    try testing.expectEqual(@as(u32, 3), h.analysis.prefix_literal.?.len);

    const a2 = try compile.parse(testing.allocator, "abc", &diag);
    defer a2.deinit(testing.allocator);
    const h2 = try buildAlloc(testing.allocator, a2, .{});
    defer deinitHir(testing.allocator, h2);
    try testing.expect(h2.analysis.is_whole_literal);
    try testing.expect(!h2.analysis.anchored_start);
    try testing.expectEqual(@as(u32, 3), h2.analysis.required_literal.?.len);
    try testing.expectEqual(@as(u32, 3), h2.analysis.min_utf8_len);
    try testing.expectEqual(@as(?u32, 3), h2.analysis.max_utf8_len.?);
}

test "analysis: prefilter + feasibility facts" {
    var diag: compile.Diagnostic = .{};

    // Leading literal "abc", an inner class, trailing literal "xy" then `$`.
    {
        const a = try compile.parse(testing.allocator, "abc[0-9]+xy$", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const an = h.analysis;
        try testing.expect(!an.anchored_start);
        try testing.expect(an.anchored_end); // trailing `$` (no multiline) → text_end
        // prefix is the leading run "abc"
        const pre = an.prefix_literal.?;
        try testing.expectEqual(@as(u32, 3), pre.len);
        try testing.expectEqual(@as(CodePoint, 'a'), h.literals[pre.start]);
        // best needle is the longest required run ("abc" len 3 beats "xy" len 2)
        try testing.expectEqual(@as(u32, 3), an.required_literal.?.len);
        // every required literal byte is present; the class member '0' is not
        for ("abcxy") |b| try testing.expect(an.required_bytes.has(b));
        try testing.expect(!an.required_bytes.has('0'));
        try testing.expectEqual(@as(u32, 6), an.min_len); // a b c <digit> x y
    }

    // Top-level alternation: nothing is unconditionally required.
    {
        const a = try compile.parse(testing.allocator, "cat|dog", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        try testing.expect(h.analysis.prefix_literal == null);
        try testing.expect(h.analysis.required_literal == null);
        try testing.expect(h.analysis.required_bytes.isEmpty());
        try testing.expect(!h.analysis.is_one_pass); // HIR leaves it conservatively false
    }

    // Word boundary + multi-byte UTF-8 byte bounds (é = U+00E9 → 2 bytes).
    {
        const a = try compile.parse(testing.allocator, "\\bné\\b", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const an = h.analysis;
        try testing.expect(an.has_word_boundary);
        try testing.expectEqual(@as(u32, 2), an.min_len); // 'n', 'é' — two code points
        try testing.expectEqual(@as(?u32, 2), an.max_len);
        try testing.expectEqual(@as(u32, 3), an.min_utf8_len); // 1 + 2 bytes
        try testing.expectEqual(@as(?u32, 3), an.max_utf8_len.?);
    }

    // Dot is 1–4 bytes; `.*` is unbounded above.
    {
        const a = try compile.parse(testing.allocator, "a.*", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        try testing.expectEqual(@as(?u32, null), h.analysis.max_len);
        try testing.expectEqual(@as(?u32, null), h.analysis.max_utf8_len);
        try testing.expectEqual(@as(u32, 1), h.analysis.min_utf8_len); // just the leading 'a'
    }
}

test "analysis: required_literal_skip — interior/suffix literal with preceding alphabet" {
    var diag: compile.Diagnostic = .{};

    // `\w+\s+Holmes`: suffix literal "Holmes" after two class runs. The skip needle is the
    // literal run; the reverse-scan alphabet is word ∪ space (∪ all high bytes, since \w/\s
    // include non-ASCII), and excludes ASCII punctuation.
    {
        const a = try compile.parse(testing.allocator, "\\w+\\s+Holmes", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const rl = h.analysis.required_literal_skip.?;
        try testing.expectEqual(@as(u32, 6), rl.run.len);
        try testing.expectEqual(@as(CodePoint, 'H'), h.literals[rl.run.start]);
        for ("abcXYZ0_9 \t") |b| try testing.expect(rl.lead_class.has(b)); // word + space members
        try testing.expect(!rl.lead_class.has('!')); // ASCII punctuation excluded → scan stops there
        try testing.expect(!rl.lead_class.has('@'));
        try testing.expect(rl.is_suffix); // "Holmes" is the last consuming atom
        try testing.expectEqual(@as(?u32, null), rl.lead_fixed_cps); // \w+ is variable-length
        // Structured reverse walk: two disjoint class-reps (\w+, \s+) precede the literal.
        try testing.expectEqual(@as(u8, 2), rl.pre_n);
        try testing.expect(rl.pre[0].bits.has('a') and rl.pre[0].min == 1); // \w+
        try testing.expect(rl.pre[1].bits.has(' ') and !rl.pre[1].bits.has('a')); // \s+ (disjoint from \w)
    }

    // `[a-q][^u-z]{13}x`: fixed-length (15 cp), literal "x" at fixed cp-offset 14, suffix.
    {
        const a = try compile.parse(testing.allocator, "[a-q][^u-z]{13}x", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const rl = h.analysis.required_literal_skip.?;
        try testing.expectEqual(@as(CodePoint, 'x'), h.literals[rl.run.start]);
        try testing.expectEqual(@as(?u32, 14), rl.lead_fixed_cps); // 1 ([a-q]) + 13 ([^u-z]{13})
        try testing.expect(rl.is_suffix);
    }

    // `[a-zA-Z]+ing`: the first-byte memchr ('i') is common, but the whole "ing" needle is
    // selective. Alphabet is the ASCII letters only (no high bytes — class is ASCII-only).
    {
        const a = try compile.parse(testing.allocator, "[a-zA-Z]+ing", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const rl = h.analysis.required_literal_skip.?;
        try testing.expectEqual(@as(u32, 3), rl.run.len);
        try testing.expectEqual(@as(CodePoint, 'i'), h.literals[rl.run.start]);
        try testing.expect(rl.lead_class.has('a') and rl.lead_class.has('Z'));
        try testing.expect(!rl.lead_class.has('0') and !rl.lead_class.has(' '));
        try testing.expect(!rl.lead_class.has(0x80)); // ASCII-only class — no high bytes
    }

    // A leading literal (`abc[0-9]+xy`) is the `prefix_literal`'s job; the skip is still offered
    // for the longest *interior/suffix* required literal, but the dispatcher only consults it when
    // there is no leading literal. Here the longest interior literal preceded by a consuming atom
    // is "xy" (after "abc" and the class run).
    {
        const a = try compile.parse(testing.allocator, "abc[0-9]+xy", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const rl = h.analysis.required_literal_skip.?;
        try testing.expectEqual(@as(CodePoint, 'x'), h.literals[rl.run.start]);
        try testing.expect(rl.lead_class.has('a') and rl.lead_class.has('0')); // "abc" ∪ [0-9]
        try testing.expect(rl.is_suffix); // "xy" is the last consuming atom
        try testing.expectEqual(@as(?u32, null), rl.lead_fixed_cps); // [0-9]+ is variable
    }

    // Interior (non-suffix) literal: a consuming atom follows it.
    {
        const a = try compile.parse(testing.allocator, "\\w+\\s+Holmes\\s+\\w+", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const rl = h.analysis.required_literal_skip.?;
        try testing.expectEqual(@as(CodePoint, 'H'), h.literals[rl.run.start]);
        try testing.expect(!rl.is_suffix); // trailing \s+\w+ follows "Holmes"
        try testing.expectEqual(@as(u8, 2), rl.pre_n); // \w+ \s+ before "Holmes" — structured walk applies
    }

    // A `.`/`.*` before any interior literal makes the preceding alphabet universal → declined.
    {
        const a = try compile.parse(testing.allocator, ".*Holmes", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        try testing.expect(h.analysis.required_literal_skip == null);
    }

    // A top-level alternation has no mandatory spine literal → declined.
    {
        const a = try compile.parse(testing.allocator, "cat|dog", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        try testing.expect(h.analysis.required_literal_skip == null);
    }
}

test "analysis: leading_class_first only for class-led patterns" {
    var diag: compile.Diagnostic = .{};
    // A class-led pattern exposes the first-byte set; the digit set has 0-9 and excludes letters.
    {
        const a = try compile.parse(testing.allocator, "\\d{4}-\\d{2}", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        const bs = h.analysis.leading_class_first.?;
        for ("0123456789") |b| try testing.expect(bs.has(b));
        try testing.expect(!bs.has('a'));
        try testing.expect(!bs.has(' '));
    }
    // A literal-led pattern has none (prefix_literal covers it).
    {
        const a = try compile.parse(testing.allocator, "foo\\d+", &diag);
        defer a.deinit(testing.allocator);
        const h = try buildAlloc(testing.allocator, a, .{});
        defer deinitHir(testing.allocator, h);
        try testing.expect(h.analysis.leading_class_first == null);
    }
}

test "classFirstByteSet: tier-split lead bytes match a brute-force encode" {
    // The per-tier lead-byte arithmetic (`addFirstBytes`/`leadByte`) must equal encoding every
    // code point and taking its first UTF-8 byte. Cover ASCII, the 2/3-byte tier boundaries,
    // and a 4-byte range — at the exact boundary code points where an off-by-one would show.
    const ranges = [_]Range{
        .{ .lo = '0', .hi = '9' }, // ASCII
        .{ .lo = 0x7E, .hi = 0x81 }, // crosses the 1↔2-byte boundary (0x7F→0x80)
        .{ .lo = 0x7F0, .hi = 0x810 }, // crosses the 2↔3-byte boundary (0x7FF→0x800)
        .{ .lo = 0x0400, .hi = 0x04FF }, // Cyrillic (lead 0xD0/0xD1)
        .{ .lo = 0xFFF0, .hi = 0x10010 }, // crosses the 3↔4-byte boundary (0xFFFF→0x10000)
    };
    for (ranges) |r| {
        const got = classFirstByteSet(&.{r});
        // Brute-force oracle: encode each scalar, record its first byte.
        var want = ByteSet{};
        var cp: CodePoint = r.lo;
        while (cp <= r.hi) : (cp += 1) {
            if (!encoding.isValidCodePoint(cp)) continue; // skip surrogates
            var buf: [4]u8 = undefined;
            const n = utf8.encodeCodePointUnchecked(cp, &buf);
            if (n > 0) want.set(buf[0]);
        }
        var b: u16 = 0;
        while (b < 256) : (b += 1) {
            const by: u8 = @intCast(b);
            try testing.expectEqual(want.has(by), got.has(by));
        }
    }
}

test "comptime build matches runtime build (parity)" {
    try testing.expectEqualStrings("(run a b c)", comptime comptimeHirSExpr("abc", .{}));
    try testing.expectEqualStrings("(cls a-e)", comptime comptimeHirSExpr("[c-ea-b]", .{}));
    try testing.expectEqualStrings(
        "(cat (run a) (cap 1 (alt (run b) (run c))) (run d))",
        comptime comptimeHirSExpr("a(b|c)d", .{}),
    );
    try testing.expectEqualStrings("(cls A a)", comptime comptimeHirSExpr("(?i)a", .{ .case_fold = .simple }));
}

test "comptime resolves a unicode property class in ro_data" {
    const sexpr = comptime comptimeHirSExpr("\\w", .{});
    // \w begins with the ASCII run 0-9 (the decimal-number block) — proves the
    // range tables were enumerated at comptime.
    try testing.expect(std.mem.indexOf(u8, sexpr, "0-9") != null);
}

test {
    testing.refAllDecls(@This());
}
