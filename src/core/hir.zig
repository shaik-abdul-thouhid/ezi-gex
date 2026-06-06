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
//!     closure via ezi_code's enumerable fold table. (`full`'s 1→many rewrite,
//!     e.g. ß→ss, is a documented v1 gap — see `Options.case_fold`.)
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

const std = @import("std");

const ast = @import("ast.zig");
const token = @import("token.zig");

const ezi_code = @import("ezi_code");
const CodePoint = ezi_code.encoding.CodePoint;
const props = ezi_code.unicode.properties;
const u_scripts = ezi_code.unicode.scripts;
const casing = ezi_code.unicode.casing;

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
pub const Options = struct {
    /// How `i` (case-insensitive) folding is realized in the HIR.
    ///   `none`   — no folding, even under `(?i)`.
    ///   `simple` — widen literal/class ranges to the simple-fold closure (1:1).
    ///   `full`   — currently behaves like `simple` for single code points; the
    ///              1→many rewrite (ß ↔ ss) is not yet implemented (v1 gap).
    case_fold: CaseFold = .simple,
};

pub const CaseFold = enum { none, simple, full };

/// An inclusive code-point range, the atom of a resolved class.
pub const Range = struct { lo: CodePoint, hi: CodePoint };

/// Resolved anchor kind. Flags (`m`) are already applied: `line_*` only appear
/// when multiline was in effect, otherwise `^`/`$` became `text_*`.
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

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Run = struct { start: u32, len: u32 };
    pub const Class = struct { start: u32, len: u32 };
    pub const Any = struct { dot_all: bool };
    pub const Anchor = struct { kind: AnchorKind };
    pub const Children = struct { start: u32, len: u32 };
    pub const Repetition = struct { child: u32, min: u32, max: ?u32, greedy: bool };
    pub const Capture = struct { child: u32, index: u32, name: ?u32 };

    pub const Data = union {
        run: Run,
        class: Class,
        any: Any,
        anchor: Anchor,
        children: Children,
        repetition: Repetition,
        capture: Capture,
        none: void,
    };
};

/// A 256-bit set of byte values — backing storage for the `required_bytes`
/// prefilter hint. Tiny and `comptime`-constructible, so it lives directly inside
/// the HIR (ro_data at comptime, heap at runtime) with no separate allocation.
pub const ByteSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn set(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] |= @as(u64, 1) << @truncate(b);
    }
    pub fn has(self: ByteSet, b: u8) bool {
        return (self.bits[b >> 6] >> @truncate(b)) & 1 != 0;
    }
    pub fn isEmpty(self: ByteSet) bool {
        return (self.bits[0] | self.bits[1] | self.bits[2] | self.bits[3]) == 0;
    }
    /// Number of distinct bytes in the set (a prefilter picks the rarest member).
    pub fn count(self: ByteSet) u32 {
        var c: u64 = 0;
        for (self.bits) |w| c += @popCount(w);
        return @intCast(c);
    }
};

/// Cheap, precomputed facts a dispatcher/backend can consult without rewalking the
/// tree. Everything here is a *sound* property of the HIR: bounds are true bounds
/// and the "required"/"anchored" facts hold for *every* match, so a prefilter or
/// length gate built on them never yields a false negative.
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
};

/// The resolved program shape. All slices are sub-slices of caller storage
/// (ro_data at comptime, heap at runtime). Immutable and shareable.
pub const Hir = struct {
    nodes: []const Node,
    children: []const u32,
    ranges: []const Range,
    literals: []const CodePoint,
    names: []const []const u8,
    root: u32,
    capture_count: u32,
    analysis: Analysis,
};

/// The only failure the builder can raise: a class/pattern that overruns the
/// caller's buffers (e.g. an enormous resolved class). Mirrors the scanner's
/// "guard every write, never overrun" model.
pub const BuildError = error{PatternTooComplex};

// ── Sizes / Buffers (storage-agnostic core) ─────────────────────────────────────

/// Exact output sizes, computed by `measure`. Unlike the scanner's
/// pattern-length bounds these are exact, because a resolved class's range count
/// is data-dependent and can be large; over-provisioning would bloat comptime.
pub const Sizes = struct {
    nodes: usize,
    children: usize,
    ranges: usize,
    literals: usize,
    names: usize,
};

/// Transient scratch the builder needs while lowering. `stack` gathers child
/// node indices (depth-balanced, scanner-style); `main`/`member` hold a class's
/// ranges mid-resolution. Caller-owned; location is the caller's choice.
pub const Scratch = struct {
    stack: []u32,
    main: []Range,
    member: []Range,
    /// Aux buffer for the merge sort (same size as `main`/`member`).
    aux: []Range,
};

/// Backing storage for the produced HIR. Each slice must be at least the length
/// given by `measure` (`nodes`, `children`, `ranges`, `literals`, `names`).
pub const Buffers = struct {
    nodes: []Node,
    children: []u32,
    ranges: []Range,
    literals: []CodePoint,
    names: [][]const u8,
};

/// Upper bound on scratch sizes for an AST. The stack depth is bounded by the
/// produced node count, itself O(ast nodes); the class scratch is a fixed cap.
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

        fn foldActive(self: *Self, flags: Flags) bool {
            return flags.case_insensitive and self.opts.case_fold != .none;
        }

        /// Append `[lo,hi]` to the member scratch, plus its simple-fold closure
        /// when case folding is active (both directions of the fold table).
        fn addFolded(self: *Self, lo: CodePoint, hi: CodePoint, flags: Flags) BuildError!void {
            try self.addMember(lo, hi);
            if (!self.foldActive(flags)) return;
            for (casing.case_folding.common_simple_table) |entry| {
                if (entry.to.len != 1) continue;
                const t = entry.to[0];
                const f = entry.from;
                if (f >= lo and f <= hi) try self.addMember(t, t);
                if (t >= lo and t <= hi) try self.addMember(f, f);
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

        /// Resolve a Perl shorthand into the member scratch (positive form).
        fn addPerl(self: *Self, kind: PerlClassKind) BuildError!void {
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

        fn lowerLiteral(self: *Self, cp: CodePoint, flags: Flags) BuildError!u32 {
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
            return self.addNode(.{ .tag = .repetition, .data = .{ .repetition = .{
                .child = child,
                .min = q.min,
                .max = q.max,
                .greedy = q.greedy,
            } } });
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
        .is_whole_literal = nodes[root].tag == .literal,
        .is_one_pass = false, // decided by the backend's NFA compiler; see Analysis
        .prefix_literal = prefixLiteral(nodes, children, root),
        .required_literal = req.best,
        .required_bytes = req.bytes,
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
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return; // skip non-encodable
    for (buf[0..n]) |b| set.set(b);
}

const ByteBounds = struct { min: u32, max: ?u32 };

/// UTF-8 byte length of a code point (1–4). Resolved HIR code points are always
/// encodable; the `catch 4` is a defensive upper bound.
fn utf8Len(cp: CodePoint) u32 {
    return std.unicode.utf8CodepointSequenceLength(@intCast(cp)) catch 4;
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
pub const Outcome = union(enum) {
    ok: Hir,
    fail: BuildError,
};

/// Build a HIR at runtime into heap memory. Provisions scratch + exactly-sized
/// output buffers from `allocator`. Free with `hir.deinitHir(allocator, &hir)`.
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
