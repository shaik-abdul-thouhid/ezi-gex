//! Shared Thompson-NFA IR + compiler + code-point match primitives.
//!
//! This is **not a backend** — it is the common substrate two backends execute
//! differently: `pikevm` (breadth-first NFA simulation) and `backtrack`
//! (depth-first bounded backtracking). Both compile the HIR into the *same* flat
//! instruction `Program` here, so they agree bit-for-bit on semantics (the split
//! ordering encodes leftmost-first / greedy priority); they differ only in how
//! they traverse it. Keeping the NFA here means a backend never imports another
//! backend — they share this helper instead.
//!
//! It is **code-point based**: `char`/`range` test a decoded scalar against the
//! HIR's resolved ranges, so Unicode classes work with zero match-time
//! Unicode-table lookups. Compilation is two linear passes (measure, emit) over
//! the already-resolved HIR, identical in shape so the same body serves
//! `buildAlloc` (heap) and `buildComptime` (ro_data). `\X` graphemes are not
//! representable here (`error.Unsupported`).

const std = @import("std");

const backend = @import("backend.zig");
const hir = @import("../core/hir.zig");

const ezi_code = @import("ezi_code");
const properties = ezi_code.unicode.properties;
const utf8 = ezi_code.encoding.utf8;

const BuildError = backend.BuildError;
const Range = hir.Range;
const CodePoint = ezi_code.encoding.CodePoint;

// ── Instruction set ──────────────────────────────────────────────────────────────

/// One NFA instruction. `char`/`range`/`any` consume exactly one code point and
/// fall through to `pc + 1`; the rest are epsilon transitions or terminal.
///
/// @stable-since: v0.1.0
pub const Inst = union(enum) {
    /// Match this exact code point.
    char: CodePoint,
    /// Match a code point inside `ranges[start..start+len]` (already positive).
    range: struct { start: u32, len: u32 },
    /// Match any code point (`dot_all`) or any-except-`\n`.
    any: struct { dot_all: bool },
    /// Record the current byte offset into capture slot `n`.
    save: u32,
    /// Two-way epsilon branch; `a` has higher priority than `b`.
    split: struct { a: u32, b: u32 },
    /// Unconditional epsilon jump.
    jmp: u32,
    /// Zero-width assertion; the thread dies unless it holds.
    assertion: hir.AnchorKind,
    /// Accept.
    match,
};

/// The compiled, immutable program. Self-contained: it copies every range it
/// needs out of the HIR, so the HIR may be freed after building.
///
/// @stable-since: v0.1.0
pub const Program = struct {
    insts: []const Inst,
    ranges: []const Range,
    /// `2 * (capture_count + 1)` — slots needed by capture-aware search.
    slot_count: u32,
};

// ── Compiler: HIR → Program ──────────────────────────────────────────────────────

/// Output sizes from the `.count` pass. `insts` is exact; `ranges` is an UPPER
/// BOUND — the emit pass interns identical class range-blocks (see `addRanges`),
/// so the program's final `ranges` length can be smaller. Buffers are sized to
/// this bound; the comptime path trims to the exact length and the heap path
/// right-sizes its allocation.
const Sizes = struct { insts: u32, ranges: u32 };

/// Bookkeeping for range-block interning: the `(start, len)` of one already-
/// emitted block in the program's `ranges`, so a later identical block can point
/// at it instead of being copied again.
const Mark = struct { start: u32, len: u32 };

fn rangesEqual(a: []const Range, b: []const Range) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.lo != y.lo or x.hi != y.hi) return false;
    }
    return true;
}

const Mode = enum { count, emit };

/// One compiler body, two modes — `.count` measures exact sizes, `.emit` fills
/// caller buffers (with backpatching). Identical control flow ⇒ identical sizes,
/// so the same code serves `buildAlloc` (heap) and `buildComptime` (ro_data),
/// exactly like core/hir.zig. `error.Unsupported` is raised for `\X`.
fn Builder(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        const is_emit = mode == .emit;

        h: hir.Hir,
        insts: if (is_emit) []Inst else void = if (is_emit) undefined else {},
        ranges: if (is_emit) []Range else void = if (is_emit) undefined else {},
        patch: []u32 = &.{},
        marks: if (is_emit) []Mark else void = if (is_emit) undefined else {},
        inst_len: u32 = 0,
        range_len: u32 = 0,
        patch_len: u32 = 0,
        mark_len: u32 = 0,

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
            }
        }
        fn addRanges(self: *Self, src: []const Range) u32 {
            if (!is_emit) {
                // Count pass: an upper bound (interning only ever shrinks).
                const start = self.range_len;
                self.range_len += @intCast(src.len);
                return start;
            }
            // Emit pass: intern. If an identical block was already emitted, point
            // the new class instruction at it rather than copying the ranges
            // again — sound because the program's `ranges` are immutable and only
            // read (never indexed by class identity) at match time. This dedups,
            // for example, the three `\w` blocks in `(\w+)@(\w+)\.(\w+)` down to
            // one, shrinking the heap program and the comptime ro_data alike.
            for (self.marks[0..self.mark_len]) |mk| {
                if (rangesEqual(self.ranges[mk.start .. mk.start + mk.len], src)) return mk.start;
            }
            const start = self.range_len;
            @memcpy(self.ranges[start .. start + src.len], src);
            self.marks[self.mark_len] = .{ .start = start, .len = @intCast(src.len) };
            self.mark_len += 1;
            self.range_len += @intCast(src.len);
            return start;
        }

        fn compileNode(self: *Self, idx: u32) error{Unsupported}!void {
            const node = self.h.nodes[idx];
            switch (node.tag) {
                .empty => {},
                .literal => {
                    const r = node.data.run;
                    for (self.h.literals[r.start .. r.start + r.len]) |cp| _ = self.emit(.{ .char = cp });
                },
                .class => {
                    const c = node.data.class;
                    const start = self.addRanges(self.h.ranges[c.start .. c.start + c.len]);
                    _ = self.emit(.{ .range = .{ .start = start, .len = c.len } });
                },
                .any => _ = self.emit(.{ .any = .{ .dot_all = node.data.any.dot_all } }),
                .anchor => _ = self.emit(.{ .assertion = node.data.anchor.kind }),
                .grapheme => return error.Unsupported,
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

        /// `a|b|c`: a chain of splits, each non-final branch jumping to a common end.
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
                    try self.compileNode(child); // last branch: no split, no jmp
                }
            }
            const end = self.pc();
            while (self.patch_len > base) {
                self.patch_len -= 1;
                self.set(self.patch[self.patch_len], .{ .jmp = end });
            }
        }

        fn compileRepetition(self: *Self, rep: hir.Node.Repetition) error{Unsupported}!void {
            var n: u32 = 0;
            while (n < rep.min) : (n += 1) try self.compileNode(rep.child); // mandatory copies

            if (rep.max) |max| {
                // (max - min) optional copies; each split skips to the common end.
                const base = self.patch_len;
                var k: u32 = rep.min;
                while (k < max) : (k += 1) {
                    self.pushPatch(self.emit(.{ .split = .{ .a = 0, .b = 0 } }));
                    try self.compileNode(rep.child);
                }
                const end = self.pc();
                while (self.patch_len > base) {
                    self.patch_len -= 1;
                    const si = self.patch[self.patch_len];
                    const body = si + 1;
                    self.set(si, if (rep.greedy) .{ .split = .{ .a = body, .b = end } } else .{ .split = .{ .a = end, .b = body } });
                }
            } else {
                // Unbounded tail: a star of the child (x{min,} = x{min} x*).
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

/// Count-only pass: the program is `save 0 · <root> · save 1 · match`.
fn measure(h: hir.Hir) error{Unsupported}!Sizes {
    var b = Builder(.count){ .h = h };
    _ = b.emit(.{ .save = 0 });
    try b.compileNode(h.root);
    _ = b.emit(.{ .save = 1 });
    _ = b.emit(.match);
    return .{ .insts = b.inst_len, .ranges = b.range_len };
}

/// Emit pass: fill caller buffers (each ≥ the matching `measure` size; `patch`
/// and `marks` ≥ `insts.len`) and return the `Program` sub-slicing them. Because
/// `addRanges` interns identical class blocks, the returned `ranges` slice may be
/// SHORTER than the `ranges` buffer; the callers right-size accordingly.
fn build(h: hir.Hir, insts: []Inst, ranges: []Range, patch: []u32, marks: []Mark) error{Unsupported}!Program {
    var b = Builder(.emit){ .h = h, .insts = insts, .ranges = ranges, .patch = patch, .marks = marks };
    _ = b.emit(.{ .save = 0 });
    try b.compileNode(h.root);
    _ = b.emit(.{ .save = 1 });
    _ = b.emit(.match);
    return .{
        .insts = insts[0..b.inst_len],
        .ranges = ranges[0..b.range_len],
        .slot_count = 2 * (h.capture_count + 1),
    };
}

/// Whether this HIR can be lowered to an NFA program (false ⇒ `\X` grapheme).
///
/// @stable-since: v0.1.0
pub fn supports(h: hir.Hir) bool {
    _ = measure(h) catch return false;
    return true;
}

/// Compile a HIR into a heap-allocated `Program` (free with `freeProgram`).
///
/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir) BuildError!Program {
    const sizes = measure(h) catch return error.Unsupported;
    const insts = try gpa.alloc(Inst, sizes.insts);
    errdefer gpa.free(insts);
    const ranges = try gpa.alloc(Range, sizes.ranges);
    errdefer gpa.free(ranges);
    const patch = try gpa.alloc(u32, sizes.insts); // backpatch stack ≤ #insts
    defer gpa.free(patch);
    const marks = try gpa.alloc(Mark, sizes.insts); // one per class inst ≤ #insts
    defer gpa.free(marks);
    var prog = build(h, insts, ranges, patch, marks) catch return error.Unsupported;
    // Interning may leave `ranges` shorter than the measured upper bound. Return
    // the slack to the allocator so `freeProgram` frees exactly what is held.
    if (prog.ranges.len != ranges.len) prog.ranges = try gpa.realloc(ranges, prog.ranges.len);
    return prog;
}

/// Compile a HIR into a ro_data `Program` at comptime. `\X` becomes a `@compileError`.
///
/// @stable-since: v0.1.0
pub fn buildComptime(comptime h: hir.Hir) Program {
    const work: u64 = @as(u64, h.nodes.len) + h.literals.len + h.ranges.len;
    @setEvalBranchQuota(@intCast(@min(20_000 + work * 100, std.math.maxInt(u32))));
    const sizes = comptime (measure(h) catch @compileError("nfa: unsupported HIR node (\\X grapheme is not supported)"));
    comptime var insts: [sizes.insts]Inst = undefined;
    comptime var ranges: [sizes.ranges]Range = undefined;
    comptime var patch: [sizes.insts]u32 = undefined;
    comptime var marks: [sizes.insts]Mark = undefined;
    const prog = build(h, &insts, &ranges, &patch, &marks) catch unreachable; // measure already validated
    const final_insts = insts[0..prog.insts.len].*;
    const final_ranges = ranges[0..prog.ranges.len].*;
    return .{ .insts = &final_insts, .ranges = &final_ranges, .slot_count = prog.slot_count };
}

/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.insts);
    gpa.free(program.ranges);
}

// ── Code-point match primitives (shared by both NFA backends) ────────────────────

/// @stable-since: v0.1.0
pub fn inRanges(ranges: []const Range, cp: CodePoint) bool {
    // Ranges are sorted+merged; a binary search is possible but linear is fine for
    // the modest range counts the HIR produces.
    for (ranges) |r| {
        if (cp < r.lo) return false; // sorted: no later range can contain cp
        if (cp <= r.hi) return true;
    }
    return false;
}

/// @stable-since: v0.1.0
pub const Decoded = struct { cp: CodePoint, len: usize };

/// Decode one code point at byte offset `sp`. Invalid UTF-8 yields U+FFFD with a
/// 1-byte advance — the engine's `fail`-ish policy: it won't match across an
/// invalid byte but still makes progress.
///
/// @stable-since: v0.1.0
pub fn decodeAt(input: []const u8, sp: usize) Decoded {
    const d = utf8.validateAndDecodeCodePointBytes(input, sp) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = d.code_point, .len = d.len };
}

/// Decode the code point ending just before byte offset `sp`, or null at the start.
fn cpBefore(input: []const u8, sp: usize) ?CodePoint {
    if (sp == 0) return null;
    const d = utf8.validateAndDecodeCodePointBytesReverse(input, sp - 1) catch return input[sp - 1];
    return d.code_point;
}

fn wordBefore(input: []const u8, sp: usize) bool {
    return if (cpBefore(input, sp)) |c| properties.isWord(c) else false;
}
fn wordAfter(input: []const u8, sp: usize) bool {
    if (sp >= input.len) return false;
    return properties.isWord(decodeAt(input, sp).cp);
}

/// Whether a zero-width assertion holds at byte offset `sp` in `input`.
///
/// @stable-since: v0.1.0
pub fn assertionHolds(kind: hir.AnchorKind, input: []const u8, sp: usize) bool {
    return switch (kind) {
        .text_start => sp == 0,
        .text_end => sp == input.len,
        .line_start => sp == 0 or input[sp - 1] == '\n',
        .line_end => sp == input.len or input[sp] == '\n',
        .word_boundary => wordBefore(input, sp) != wordAfter(input, sp),
        .not_word_boundary => wordBefore(input, sp) == wordAfter(input, sp),
    };
}

test {
    std.testing.refAllDecls(@This());
}
