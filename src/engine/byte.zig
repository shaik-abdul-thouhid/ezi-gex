//! Byte-grained lowering of the code-point HIR — the UTF-8 automaton substrate.
//!
//! This is **not a backend** (like `nfa.zig`, it is a shared substrate). Where
//! `nfa.zig` produces a *code-point* program whose consuming instructions decode a
//! scalar and test it against resolved ranges, this module lowers the same HIR to a
//! **byte-grained** Thompson NFA: every consuming instruction tests one input byte
//! against a `[lo, hi]` byte range, and a Unicode class becomes a little
//! sub-automaton over UTF-8 byte-range sequences. The Unicode-ness is baked into the
//! byte automaton at lowering time, so matching needs **zero decode** — a class like
//! `\p{Greek}` matches exactly the same code points purely by byte comparison.
//!
//! It is the substrate the (future) lazy DFA will determinize; for
//! now the byte Pike VM (`backends/bytepike.zig`) executes it, and `conformance.zig`
//! proves it agrees with the code-point engines.
//!
//! The core is `enumerate` — the classic Cox/RE2 / BurntSushi `utf8-ranges`
//! algorithm: a scalar range `[lo, hi]` → the set of 1–4 byte **`Seq`uences** whose
//! concatenation matches exactly the UTF-8 encodings of the scalars in that range. A
//! class (a union of scalar ranges) lowers to the union of all their sequences.

const std = @import("std");

const backend = @import("backend.zig");
const hir = @import("../core/hir.zig");

const utils = @import("utils");
const utf8 = utils.unicode.utf8;
const CodePoint = utils.unicode.CodePoint;

const BuildError = backend.BuildError;
const Range = hir.Range;

// ── Byte-range sequences (the lowering's vocabulary) ──────────────────────────────

/// One inclusive byte range `[lo, hi]`, tested against a single input byte. The
/// atom a byte-NFA consuming instruction holds (the byte analogue of a code-point
/// `Range`).
///
/// @stable-since: v0.2.0
pub const ByteRange = struct {
    lo: u8,
    hi: u8,

    /// Whether `b` falls in `[lo, hi]`.
    pub fn contains(self: ByteRange, b: u8) bool {
        return b >= self.lo and b <= self.hi;
    }
};

/// A UTF-8 byte-range **sequence**: `len` (1–4) consecutive `ByteRange`s whose
/// concatenation matches exactly the UTF-8 encodings of one contiguous block of
/// scalars that all encode to the same number of bytes. A scalar range lowers to a
/// *union* (alternation) of these; `enumerate` yields them.
///
/// @stable-since: v0.2.0
pub const Seq = struct {
    /// The byte ranges, position 0 first; only `[0..len]` are meaningful.
    ranges: [4]ByteRange,
    /// Number of active byte ranges (1–4 — the UTF-8 length of every scalar this
    /// sequence covers).
    len: u8,

    /// Whether `bytes` (exactly `len` of them) is matched by this sequence — every
    /// position falls in its range. Used by the byte VM and by the tests.
    pub fn matches(self: Seq, bytes: []const u8) bool {
        if (bytes.len != self.len) return false;
        for (self.ranges[0..self.len], bytes) |r, b| {
            if (!r.contains(b)) return false;
        }
        return true;
    }
};

// ── Surrogate / length boundaries ─────────────────────────────────────────────────

/// Last scalar before the UTF-16 surrogate gap (`U+D800..U+DFFF` are not scalars
/// and have no UTF-8 encoding, so a scalar range straddling the gap is split here).
const SURR_LO: CodePoint = 0xD7FF;
/// First scalar after the surrogate gap.
const SURR_HI: CodePoint = 0xE000;

/// The largest scalar encodable in 1/2/3/4 UTF-8 bytes — the split points where a
/// range crosses an encoded-length boundary.
const LEN_BOUNDS = [_]CodePoint{ 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };

// ── enumerate: scalar range → UTF-8 byte-range sequences ──────────────────────────

/// Call `visit(ctx, seq)` for each UTF-8 byte-range `Seq` needed to match exactly the
/// scalars in `[lo, hi]` (inclusive). Sequences are yielded in ascending scalar
/// order. Surrogate code points inside the range are skipped (they have no UTF-8
/// encoding). Runs at comptime and runtime (no allocation; bounded recursion ≤ 4
/// deep). `visit` is a comptime-known function so this stays allocation-free and
/// inlines into the compiler's count/emit passes.
///
/// @stable-since: v0.2.0
pub fn enumerate(
    lo: CodePoint,
    hi: CodePoint,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), Seq) void,
) void {
    if (lo > hi) return;
    // Split off the surrogate gap so we never try to UTF-8-encode a surrogate.
    // HIR range endpoints are valid scalars, but a class range may still *span* the
    // gap (e.g. `[\x{D000}-\x{F000}]`); clamp/split it into surrogate-free pieces.
    if (lo <= SURR_LO and hi >= SURR_HI) {
        lengthSplit(lo, SURR_LO, ctx, visit);
        lengthSplit(SURR_HI, hi, ctx, visit);
    } else if (lo <= SURR_LO and hi > SURR_LO) {
        lengthSplit(lo, SURR_LO, ctx, visit); // hi lands inside the gap → clamp down
    } else if (lo < SURR_HI and lo > SURR_LO) {
        if (hi >= SURR_HI) lengthSplit(SURR_HI, hi, ctx, visit); // lo inside the gap → clamp up
    } else {
        lengthSplit(lo, hi, ctx, visit); // wholly below or wholly above the gap
    }
}

/// Split `[lo, hi]` (surrogate-free) at the UTF-8 encoded-length boundaries so each
/// piece encodes to a single byte count, then lower each piece byte-wise.
fn lengthSplit(
    lo: CodePoint,
    hi: CodePoint,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), Seq) void,
) void {
    if (lo > hi) return;
    for (LEN_BOUNDS) |b| {
        if (lo <= b and b < hi) {
            lengthSplit(lo, b, ctx, visit);
            lengthSplit(b + 1, hi, ctx, visit);
            return;
        }
    }
    // `lo` and `hi` now encode to the same number of bytes.
    var lob: [4]u8 = undefined;
    var hib: [4]u8 = undefined;
    const n = utf8.encodeCodePointUnchecked(lo, &lob);
    _ = utf8.encodeCodePointUnchecked(hi, &hib);
    var seq: Seq = .{ .ranges = undefined, .len = @intCast(n) };
    encBytes(lob[0..n], hib[0..n], &seq, 0, ctx, visit);
}

/// Lower a same-length scalar range, given as its low/high UTF-8 byte arrays, into
/// byte-range sequences. `seq` is the shared output buffer (its `.len` is the total
/// sequence length, already set); `depth` is the byte position being filled. The
/// classic RE2/Go recursion: when the leading bytes match, fix that byte and recurse
/// on the tail; when they differ, split into low-tail / full-middle / high-tail.
fn encBytes(
    lob: []const u8,
    hib: []const u8,
    seq: *Seq,
    depth: u8,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), Seq) void,
) void {
    const n = lob.len;
    if (n == 1) {
        seq.ranges[depth] = .{ .lo = lob[0], .hi = hib[0] };
        visit(ctx, seq.*);
        return;
    }
    if (lob[0] == hib[0]) {
        // Leading byte fixed; recurse on the tail.
        seq.ranges[depth] = .{ .lo = lob[0], .hi = lob[0] };
        encBytes(lob[1..], hib[1..], seq, depth + 1, ctx, visit);
        return;
    }
    // Leading bytes differ (lob[0] < hib[0]). Three pieces:
    //  A) lead == lob[0], tail from the actual low up to all-0xBF (max continuation);
    //  B) lead in (lob[0], hib[0]), tail full [0x80,0xBF] in every position;
    //  C) lead == hib[0], tail from all-0x80 (min continuation) up to the actual high.
    const max_tail = [4]u8{ 0xBF, 0xBF, 0xBF, 0xBF };
    const min_tail = [4]u8{ 0x80, 0x80, 0x80, 0x80 };

    seq.ranges[depth] = .{ .lo = lob[0], .hi = lob[0] }; // A
    encBytes(lob[1..], max_tail[0 .. n - 1], seq, depth + 1, ctx, visit);

    if (hib[0] >= lob[0] + 2) { // B — only if a strict middle exists
        seq.ranges[depth] = .{ .lo = lob[0] + 1, .hi = hib[0] - 1 };
        var d: u8 = depth + 1;
        var k: usize = 0;
        while (k < n - 1) : (k += 1) {
            seq.ranges[d] = .{ .lo = 0x80, .hi = 0xBF };
            d += 1;
        }
        visit(ctx, seq.*);
    }

    seq.ranges[depth] = .{ .lo = hib[0], .hi = hib[0] }; // C
    encBytes(min_tail[0 .. n - 1], hib[1..], seq, depth + 1, ctx, visit);
}

// ── Byte-NFA instruction set ──────────────────────────────────────────────────────

/// One byte-NFA instruction. `byte_range` consumes exactly one input byte and falls
/// through to `pc + 1`; the rest are epsilon transitions or terminal. This is the
/// byte analogue of `nfa.Inst` — there is no `char`/`range`/`any`/`grapheme`: every
/// consuming construct (literal, class, `.`) is lowered to a chain/alternation of
/// `byte_range`s by the compiler, so matching needs no decode.
///
/// @stable-since: v0.2.0
pub const Inst = union(enum) {
    /// Consume one input byte inside `[lo, hi]`.
    byte_range: ByteRange,
    /// Record the current byte offset into capture slot `n`.
    save: u32,
    /// Two-way epsilon branch; `a` has higher priority than `b` (leftmost-first).
    split: struct { a: u32, b: u32 },
    /// Unconditional epsilon jump.
    jmp: u32,
    /// Zero-width assertion (byte-evaluable kinds only — see `lowerableAssertion`).
    assertion: hir.AnchorKind,
    /// Accept.
    match,
};

/// The compiled, immutable byte program. Self-contained (byte ranges are inline in
/// the instructions, so unlike `nfa.Program` there is no side `ranges` array).
///
/// @stable-since: v0.2.0
pub const Program = struct {
    insts: []const Inst,
    /// `2 * (capture_count + 1)` — slots needed by capture-aware search.
    slot_count: u32,
};

/// A `\b`/`\B` word boundary needs the adjacent *code point*'s word-ness, not just a
/// byte, so it is **not** byte-lowerable here (it routes to the code-point engines).
/// Every other assertion is a byte-level test.
fn lowerableAssertion(kind: hir.AnchorKind) bool {
    return switch (kind) {
        .word_boundary, .not_word_boundary => false,
        .text_start, .text_end, .line_start, .line_end => true,
    };
}

/// Whether a zero-width assertion holds at byte offset `sp`. Byte programs only ever
/// carry byte-evaluable kinds (see `lowerableAssertion`), so this needs no decode —
/// it is the byte VM's analogue of `nfa.assertionHolds`. `\b`/`\B` are `unreachable`
/// (they are never byte-lowered).
///
/// @stable-since: v0.2.0
pub fn assertionHolds(kind: hir.AnchorKind, input: []const u8, sp: usize) bool {
    return switch (kind) {
        .text_start => sp == 0,
        .text_end => sp == input.len,
        .line_start => sp == 0 or input[sp - 1] == '\n',
        .line_end => sp == input.len or input[sp] == '\n',
        .word_boundary, .not_word_boundary => unreachable, // never byte-lowered
    };
}

// ── Compiler: HIR → byte Program ──────────────────────────────────────────────────

/// Exact instruction count from the `.count` pass (the byte program holds no side
/// arrays, so this single number sizes everything).
const Sizes = struct { insts: u32 };

const Mode = enum { count, emit };

/// One compiler body, two modes (`.count` measures the exact instruction count,
/// `.emit` fills caller buffers with backpatching) — identical control flow, so the
/// same code serves `buildAlloc` (heap) and `buildComptime` (ro_data), exactly like
/// `nfa.zig`. `error.Unsupported` is raised for `\X` and `\b`/`\B`.
fn Builder(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        const is_emit = mode == .emit;

        h: hir.Hir,
        insts: if (is_emit) []Inst else void = if (is_emit) undefined else {},
        patch: []u32 = &.{},
        inst_len: u32 = 0,
        patch_len: u32 = 0,
        // Per-class alternation bookkeeping. Classes/`.` are HIR *leaves* (they never
        // nest another class), so a single set of fields is reentrancy-safe.
        alt_idx: u32 = 0,
        alt_total: u32 = 0,
        alt_patch_base: u32 = 0,

        fn emit(self: *Self, inst: Inst) u32 {
            const i = self.inst_len;
            if (is_emit) self.insts[i] = inst;
            self.inst_len += 1;
            return i;
        }
        fn set(self: *Self, idx: u32, inst: Inst) void {
            if (is_emit) self.insts[idx] = inst;
        }
        fn pc(self: *const Self) u32 {
            return self.inst_len;
        }
        fn pushPatch(self: *Self, idx: u32) void {
            if (is_emit) {
                self.patch[self.patch_len] = idx;
                self.patch_len += 1;
            } else self.patch_len += 1; // count mode: track depth so sizes still match
        }

        fn compileNode(self: *Self, idx: u32) error{Unsupported}!void {
            const node = self.h.nodes[idx];
            switch (node.tag) {
                .empty => {},
                .literal => {
                    // A literal run is a CONCATENATION of its code points; each code
                    // point is its exact UTF-8 bytes (fixed `[b, b]` byte ranges).
                    const r = node.data.run;
                    for (self.h.literals[r.start .. r.start + r.len]) |cp| {
                        var buf: [4]u8 = undefined;
                        const n = utf8.encodeCodePointUnchecked(cp, &buf);
                        for (buf[0..n]) |b| _ = self.emit(.{ .byte_range = .{ .lo = b, .hi = b } });
                    }
                },
                .class => {
                    const c = node.data.class;
                    self.emitScalarRanges(self.h.ranges[c.start .. c.start + c.len]);
                },
                .any => {
                    // `.` is a class over all scalars (minus `\n` unless dot_all);
                    // `enumerate` drops the surrogate gap on its own.
                    if (node.data.any.dot_all) {
                        self.emitScalarRanges(&[_]Range{.{ .lo = 0, .hi = 0x10FFFF }});
                    } else {
                        self.emitScalarRanges(&[_]Range{
                            .{ .lo = 0, .hi = 0x09 },
                            .{ .lo = 0x0B, .hi = 0x10FFFF },
                        });
                    }
                },
                .anchor => {
                    const kind = node.data.anchor.kind;
                    if (!lowerableAssertion(kind)) return error.Unsupported; // `\b`/`\B`
                    _ = self.emit(.{ .assertion = kind });
                },
                .grapheme => return error.Unsupported, // `\X` is not byte-lowerable
                .concat => {
                    const d = node.data.children;
                    for (self.h.children[d.start .. d.start + d.len]) |child| try self.compileNode(child);
                },
                .alternation => try self.compileAlternation(node.data.children),
                .repetition => try self.compileRepetition(node.data.repetition),
                .capture => {
                    const c = node.data.capture;
                    _ = self.emit(.{ .save = 2 * c.index });
                    try self.compileNode(c.child);
                    _ = self.emit(.{ .save = 2 * c.index + 1 });
                },
            }
        }

        /// Emit an alternation of the UTF-8 byte sequences covering `ranges` (a class
        /// or `.`). Counts the sequences first so the LAST branch is emitted without a
        /// split (mandatory + consuming → a non-matching class kills the thread, never
        /// falls through). `enumerate` is deterministic, so the count pass and the
        /// emit pass walk the same sequences in the same order.
        fn emitScalarRanges(self: *Self, ranges: []const Range) void {
            var total: u32 = 0;
            for (ranges) |r| total += countSeqs(r.lo, r.hi);
            if (total == 0) {
                // Unmatchable class (a fully-negated set): a byte range that no byte
                // can satisfy, so the thread dies here.
                _ = self.emit(.{ .byte_range = .{ .lo = 1, .hi = 0 } });
                return;
            }
            self.alt_idx = 0;
            self.alt_total = total;
            self.alt_patch_base = self.patch_len;
            for (ranges) |r| enumerate(r.lo, r.hi, self, emitSeqBranch);
            const end = self.pc();
            while (self.patch_len > self.alt_patch_base) {
                self.patch_len -= 1;
                if (is_emit) self.set(self.patch[self.patch_len], .{ .jmp = end });
            }
        }

        /// Emit one alternation branch for `seq`: a split guarding all but the last
        /// branch, the sequence's `byte_range`s, then a jump to the common end.
        fn emitSeqBranch(self: *Self, seq: Seq) void {
            const last = self.alt_idx + 1 == self.alt_total;
            if (last) {
                self.emitSeq(seq);
            } else {
                const split_at = self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const branch = self.pc();
                self.emitSeq(seq);
                self.pushPatch(self.emit(.{ .jmp = 0 }));
                self.set(split_at, .{ .split = .{ .a = branch, .b = self.pc() } });
            }
            self.alt_idx += 1;
        }

        fn emitSeq(self: *Self, seq: Seq) void {
            for (seq.ranges[0..seq.len]) |br| _ = self.emit(.{ .byte_range = br });
        }

        /// `a|b|c`: a chain of splits, each non-final branch jumping to a common end —
        /// identical to `nfa.zig` (priority = leftmost-first).
        fn compileAlternation(self: *Self, d: hir.Node.Children) error{Unsupported}!void {
            const kids = self.h.children[d.start .. d.start + d.len];
            const base = self.patch_len;
            for (kids, 0..) |child, i| {
                if (i + 1 < kids.len) {
                    const split_at = self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                    const branch = self.pc();
                    try self.compileNode(child);
                    self.pushPatch(self.emit(.{ .jmp = 0 }));
                    self.set(split_at, .{ .split = .{ .a = branch, .b = self.pc() } });
                } else {
                    try self.compileNode(child);
                }
            }
            const end = self.pc();
            while (self.patch_len > base) {
                self.patch_len -= 1;
                if (is_emit) self.set(self.patch[self.patch_len], .{ .jmp = end });
            }
        }

        fn compileRepetition(self: *Self, rep: hir.Node.Repetition) error{Unsupported}!void {
            var n: u32 = 0;
            while (n < rep.min) : (n += 1) try self.compileNode(rep.child);

            if (rep.max) |max| {
                const base = self.patch_len;
                var k: u32 = rep.min;
                while (k < max) : (k += 1) {
                    self.pushPatch(self.emit(.{ .split = .{ .a = 0, .b = 0 } }));
                    try self.compileNode(rep.child);
                }
                const end = self.pc();
                while (self.patch_len > base) {
                    self.patch_len -= 1;
                    if (is_emit) {
                        const si = self.patch[self.patch_len];
                        const body = si + 1;
                        self.set(si, if (rep.greedy) .{ .split = .{ .a = body, .b = end } } else .{ .split = .{ .a = end, .b = body } });
                    }
                }
            } else {
                const split_at = self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const body = self.pc();
                try self.compileNode(rep.child);
                _ = self.emit(.{ .jmp = split_at });
                const after = self.pc();
                self.set(split_at, if (rep.greedy) .{ .split = .{ .a = body, .b = after } } else .{ .split = .{ .a = after, .b = body } });
            }
        }
    };
}

/// Count the byte sequences `enumerate` yields for `[lo, hi]` (pure; identical at
/// count and emit time).
fn countSeqs(lo: CodePoint, hi: CodePoint) u32 {
    var c: u32 = 0;
    enumerate(lo, hi, &c, struct {
        fn add(p: *u32, _: Seq) void {
            p.* += 1;
        }
    }.add);
    return c;
}

/// Count-only pass: the program is `save 0 · <root> · save 1 · match`.
fn measure(h: hir.Hir) error{Unsupported}!Sizes {
    var b = Builder(.count){ .h = h };
    _ = b.emit(.{ .save = 0 });
    try b.compileNode(h.root);
    _ = b.emit(.{ .save = 1 });
    _ = b.emit(.match);
    return .{ .insts = b.inst_len };
}

/// Emit pass: fill caller buffers (`insts` ≥ the measured size, `patch` ≥ `insts.len`).
fn build(h: hir.Hir, insts: []Inst, patch: []u32) error{Unsupported}!Program {
    var b = Builder(.emit){ .h = h, .insts = insts, .patch = patch };
    _ = b.emit(.{ .save = 0 });
    try b.compileNode(h.root);
    _ = b.emit(.{ .save = 1 });
    _ = b.emit(.match);
    return .{ .insts = insts[0..b.inst_len], .slot_count = 2 * (h.capture_count + 1) };
}

/// Whether this HIR can be lowered to a **byte** program. False for `\X` (grapheme)
/// and for `\b`/`\B` (word boundary needs the adjacent code point, not a byte).
/// The dispatcher falls back to the code-point engines otherwise.
///
/// @stable-since: v0.2.0
pub fn byteLowerable(h: hir.Hir) bool {
    _ = measure(h) catch return false;
    return true;
}

/// Compile a HIR into a heap-allocated byte `Program` (free with `freeProgram`).
///
/// @stable-since: v0.2.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir) BuildError!Program {
    const sizes = measure(h) catch return error.Unsupported;
    const insts = try gpa.alloc(Inst, sizes.insts);
    errdefer gpa.free(insts);
    const patch = try gpa.alloc(u32, sizes.insts); // backpatch stack ≤ #insts
    defer gpa.free(patch);
    return build(h, insts, patch) catch return error.Unsupported;
}

/// Compile a HIR into a ro_data byte `Program` at comptime.
///
/// @stable-since: v0.2.0
pub fn buildComptime(comptime h: hir.Hir) Program {
    const work: u64 = @as(u64, h.nodes.len) + h.literals.len + h.ranges.len;
    @setEvalBranchQuota(@intCast(@min(20_000 + work * 200, std.math.maxInt(u32))));
    const sizes = comptime (measure(h) catch @compileError("byte: HIR is not byte-lowerable (\\X grapheme or \\b word boundary)"));
    comptime var insts: [sizes.insts]Inst = undefined;
    comptime var patch: [sizes.insts]u32 = undefined;
    const prog = build(h, &insts, &patch) catch unreachable;
    const final = insts[0..prog.insts.len].*;
    return .{ .insts = &final, .slot_count = prog.slot_count };
}

/// @stable-since: v0.2.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.insts);
}

// ── ByteMap: equivalence classes (alphabet compression) ───────────────────────────

/// Equivalence classes over the 256 possible input bytes for one byte `Program`:
/// two bytes share a class **iff every `byte_range` in the program treats them
/// identically** (both in, or both out, of every range). This compresses the
/// alphabet a DFA must key transitions on — a pattern over ASCII letters collapses
/// 256 bytes into a handful of classes, so each DFA state stores one transition per
/// *class* instead of per byte. The classes are sound by construction: bytes in the
/// same class are indistinguishable to the automaton, so a DFA keyed on class id
/// matches exactly the same inputs.
///
/// This is scaffolding for the lazy DFA — computed and verified now,
/// consumed when the DFA lands; the byte Pike VM tests `byte_range`s directly and
/// does not need it (just as the HIR's `is_one_pass` is computed ahead of its user).
///
/// @stable-since: v0.2.0
pub const ByteClasses = struct {
    /// `map[b]` is the class id (`0..count-1`) of input byte `b`.
    map: [256]u8,
    /// Number of distinct classes (`1..=256`).
    count: u16,

    /// The class id of byte `b`.
    pub fn get(self: *const ByteClasses, b: u8) u8 {
        return self.map[b];
    }
};

/// Compute the byte equivalence classes for `prog`. Each `byte_range [lo, hi]`
/// introduces class boundaries just below `lo` and at `hi`; scanning the boundary
/// set left to right assigns ascending class ids. Empty ranges (`lo > hi`, the
/// unmatchable-class marker) distinguish no bytes and are skipped.
///
/// @stable-since: v0.2.0
pub fn byteClasses(prog: *const Program) ByteClasses {
    // `boundary[b]` ⇒ a class boundary falls between byte `b` and `b + 1`.
    var boundary: [256]bool = @splat(false);
    for (prog.insts) |inst| {
        switch (inst) {
            .byte_range => |r| {
                if (r.lo > r.hi) continue; // dead range: matches nothing
                boundary[r.hi] = true;
                if (r.lo > 0) boundary[r.lo - 1] = true;
            },
            else => {},
        }
    }
    var classes = ByteClasses{ .map = undefined, .count = 0 };
    var id: u16 = 0;
    var b: u16 = 0;
    while (b < 256) : (b += 1) {
        classes.map[b] = @intCast(id);
        if (boundary[b] and b < 255) id += 1;
    }
    classes.count = id + 1;
    return classes;
}

// ── Tests ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test sink: collects every yielded `Seq`.
const Collector = struct {
    buf: [64]Seq = undefined,
    n: usize = 0,
    fn add(self: *Collector, s: Seq) void {
        self.buf[self.n] = s;
        self.n += 1;
    }
    fn seqs(self: *const Collector) []const Seq {
        return self.buf[0..self.n];
    }
    fn anyMatch(self: *const Collector, bytes: []const u8) bool {
        for (self.seqs()) |s| if (s.matches(bytes)) return true;
        return false;
    }
};

fn collect(lo: CodePoint, hi: CodePoint) Collector {
    var c = Collector{};
    enumerate(lo, hi, &c, Collector.add);
    return c;
}

test "ascii range is a single one-byte sequence" {
    const c = collect('a', 'z');
    try testing.expectEqual(@as(usize, 1), c.n);
    try testing.expectEqual(@as(u8, 1), c.buf[0].len);
    try testing.expectEqual(ByteRange{ .lo = 'a', .hi = 'z' }, c.buf[0].ranges[0]);
}

test "single scalar lowers to its exact UTF-8 bytes" {
    // U+00E9 'é' = C3 A9 (2 bytes).
    const c = collect(0xE9, 0xE9);
    try testing.expectEqual(@as(usize, 1), c.n);
    try testing.expectEqual(@as(u8, 2), c.buf[0].len);
    try testing.expect(c.buf[0].matches(&[_]u8{ 0xC3, 0xA9 }));
    // U+1F600 😀 = F0 9F 98 80 (4 bytes).
    const e = collect(0x1F600, 0x1F600);
    try testing.expectEqual(@as(u8, 4), e.buf[0].len);
    try testing.expect(e.buf[0].matches(&[_]u8{ 0xF0, 0x9F, 0x98, 0x80 }));
}

/// The defining property: across the whole scalar space, a byte string is matched by
/// SOME yielded sequence **iff** it is the UTF-8 encoding of a (non-surrogate) scalar
/// inside the requested range. Checked exhaustively for several ranges.
fn assertExact(lo: CodePoint, hi: CodePoint) !void {
    const c = collect(lo, hi);
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue; // surrogate: no encoding
        var buf: [4]u8 = undefined;
        const n = utf8.encodeCodePointUnchecked(@intCast(cp), &buf);
        const in_range = cp >= lo and cp <= hi;
        const matched = c.anyMatch(buf[0..n]);
        if (in_range != matched) {
            std.debug.print("cp U+{X} in[{X}..{X}]={} matched={}\n", .{ cp, lo, hi, in_range, matched });
            return error.LoweringMismatch;
        }
    }
}

test "lowering is exact across length and surrogate boundaries" {
    try assertExact(0x00, 0x10FFFF); // everything (dot-all)
    try assertExact(0x00, 0x7F); // pure ASCII
    try assertExact(0x80, 0x7FF); // all 2-byte
    try assertExact(0x800, 0xFFFF); // 3-byte incl. the surrogate gap
    try assertExact(0x10000, 0x10FFFF); // all 4-byte
    try assertExact(0x41, 0x5A); // A-Z
    try assertExact(0x370, 0x3FF); // Greek block (2-byte)
    try assertExact(0xD000, 0xF000); // straddles the surrogate gap
    try assertExact(0x7E, 0x82); // straddles the 1/2-byte boundary
    try assertExact(0x7FE, 0x802); // straddles the 2/3-byte boundary
    try assertExact(0xFFFE, 0x10002); // straddles the 3/4-byte boundary
}

test "comptime enumeration works (ro_data path)" {
    const c = comptime collect('A', 'Z');
    try testing.expectEqual(@as(usize, 1), c.n);
}

// ── Compiler tests (a tiny reference acceptor validates the lowering) ──────────────

/// A minimal leftmost-first/greedy backtracking acceptor over a byte program,
/// anchored at `start`. Returns the end offset of the highest-priority match, or
/// null. Test-only — it has no visited memo, so it is run on small,
/// non-empty-cycling patterns; a `budget` guards against runaway recursion.
const Acceptor = struct {
    prog: *const Program,
    input: []const u8,
    budget: usize = 1_000_000,

    fn run(self: *Acceptor, pc: u32, sp: usize) ?usize {
        if (self.budget == 0) return null;
        self.budget -= 1;
        switch (self.prog.insts[pc]) {
            .match => return sp,
            .save => return self.run(pc + 1, sp),
            .jmp => |t| return self.run(t, sp),
            .split => |s| return self.run(s.a, sp) orelse self.run(s.b, sp),
            .assertion => |k| return if (assertionHolds(k, self.input, sp)) self.run(pc + 1, sp) else null,
            .byte_range => |r| {
                if (sp < self.input.len and r.contains(self.input[sp])) return self.run(pc + 1, sp + 1);
                return null;
            },
        }
    }
};

/// Leftmost match span `[start, end)` for `prog` over `input`, or null.
fn findSpan(prog: *const Program, input: []const u8) ?[2]usize {
    var start: usize = 0;
    while (start <= input.len) : (start += 1) {
        var acc = Acceptor{ .prog = prog, .input = input };
        if (acc.run(0, start)) |end| return .{ start, end };
    }
    return null;
}

fn buildByteFromPattern(gpa: std.mem.Allocator, pattern: []const u8) !Program {
    const core = @import("../core/root.zig");
    var diag: core.errors.Diagnostic = .{};
    const ast = try core.compile.parse(gpa, pattern, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    return try buildAlloc(gpa, h);
}

fn expectByteMatch(pattern: []const u8, input: []const u8, expect: ?[]const u8) !void {
    const gpa = testing.allocator;
    var prog = try buildByteFromPattern(gpa, pattern);
    defer freeProgram(gpa, &prog);
    const span = findSpan(&prog, input);
    if (expect) |exp| {
        try testing.expect(span != null);
        try testing.expectEqualStrings(exp, input[span.?[0]..span.?[1]]);
    } else {
        try testing.expect(span == null);
    }
}

test "byte lowering: literals, classes, dot, quantifiers, anchors, alternation" {
    try expectByteMatch("abc", "xxabcyy", "abc");
    try expectByteMatch("abc", "ab", null);
    try expectByteMatch("[a-z]+", "ABCdefGHI", "def");
    try expectByteMatch("[^a-z]+", "abXY12cd", "XY12");
    try expectByteMatch("\\d+", "abc123def", "123");
    try expectByteMatch("a.c", "a c", "a c");
    try expectByteMatch("a.c", "a\nc", null);
    try expectByteMatch("(?s)a.c", "a\nc", "a\nc");
    try expectByteMatch("ab*", "abbbc", "abbb");
    try expectByteMatch("a{2,4}", "aaaaaa", "aaaa");
    try expectByteMatch("cat|dog", "i have a dog", "dog");
    try expectByteMatch("a|ab", "ab", "a"); // leftmost-first
    try expectByteMatch("^abc", "xabc", null);
    try expectByteMatch("abc$", "xxabc", "abc");
}

test "byte lowering: multi-byte UTF-8 literals and classes" {
    try expectByteMatch("héllo", "say héllo!", "héllo");
    try expectByteMatch("\\w+", "héllo, wörld", "héllo");
    try expectByteMatch("\\p{Nd}+", "x٤٥٦y", "٤٥٦");
    try expectByteMatch("é{2,3}", "xééééy", "ééé");
    try expectByteMatch("[α-ω]+", "ΑΒΓαβγ", "αβγ"); // Greek lowercase only
}

test "byte lowering refuses \\X and \\b" {
    const gpa = testing.allocator;
    inline for (.{ "a\\Xb", "\\bcat\\b" }) |pat| {
        var diag = @import("../core/root.zig").errors.Diagnostic{};
        const core = @import("../core/root.zig");
        const ast = try core.compile.parse(gpa, pat, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        try testing.expect(!byteLowerable(h));
        try testing.expectError(error.Unsupported, buildAlloc(gpa, h));
    }
}

test "byte classes are sound and contiguous" {
    const gpa = testing.allocator;
    inline for (.{ "[a-z]+", "\\w+", "\\d{3}-\\d{4}", "héllo", "[α-ω]|cat", "a.c" }) |pat| {
        var prog = try buildByteFromPattern(gpa, pat);
        defer freeProgram(gpa, &prog);
        const classes = byteClasses(&prog);

        // SOUNDNESS (the property a DFA relies on): any two bytes sharing a class
        // agree on EVERY byte_range, so keying transitions on class id is exact.
        // (The classes are contiguous, not globally minimal — two non-adjacent byte
        // runs with identical membership may get different ids; that over-splits the
        // alphabet harmlessly, never under-splits.)
        var x: u16 = 0;
        while (x < 256) : (x += 1) {
            var y: u16 = x + 1;
            while (y < 256) : (y += 1) {
                const bx: u8 = @intCast(x);
                const by: u8 = @intCast(y);
                if (classes.get(bx) != classes.get(by)) continue;
                for (prog.insts) |inst| switch (inst) {
                    .byte_range => |r| {
                        if (r.lo > r.hi) continue;
                        if (r.contains(bx) != r.contains(by)) return error.ClassNotSound;
                    },
                    else => {},
                };
            }
        }

        // Contiguity: the map is non-decreasing and uses every id in 0..count-1.
        var prev: u8 = classes.get(0);
        var b: u16 = 1;
        while (b < 256) : (b += 1) {
            const cur = classes.get(@intCast(b));
            try testing.expect(cur == prev or cur == prev + 1);
            prev = cur;
        }
        try testing.expectEqual(classes.count, @as(u16, prev) + 1);
        try testing.expect(classes.count >= 1 and classes.count <= 256);
    }
}

test "byte classes: a single ASCII class collapses to three groups" {
    const gpa = testing.allocator;
    var prog = try buildByteFromPattern(gpa, "[a-z]"); // boundaries below 'a' and at 'z'
    defer freeProgram(gpa, &prog);
    const classes = byteClasses(&prog);
    // below 'a', the letters, and above 'z' → three distinct classes.
    try testing.expectEqual(@as(u16, 3), classes.count);
    try testing.expectEqual(classes.get('a'), classes.get('z'));
    try testing.expect(classes.get('a') != classes.get('A'));
    try testing.expect(classes.get('a') != classes.get('{')); // '{' is 0x7B, just past 'z'
}

test "byte program builds at comptime (ro_data)" {
    const core = @import("../core/root.zig");
    const h = comptime switch (core.hir.buildComptime(@import("../core/root.zig").compile.compile("[a-z]+\\d"), .{})) {
        .ok => |x| x,
        .fail => @compileError("bad pattern"),
    };
    const prog = comptime buildComptime(h);
    try testing.expect(prog.insts.len > 0);
}

test {
    testing.refAllDecls(@This());
}
