//! Pike VM backend — a Thompson-NFA simulation with capture slots.
//!
//! This is the captures-capable backstop (and v1's only backend): linear-time
//! `O(input × program)`, no catastrophic backtracking, leftmost-first (Perl/JS)
//! semantics. It is **code_point-based** — it decodes one UTF-8 code_point per step
//! and tests it against the HIR's resolved ranges directly, so Unicode classes
//! (`\w`, `\p{…}`, scripts) work with zero match-time Unicode-table lookups. (A
//! future `hybrid` backend will lower to a UTF-8 byte DFA; that is a separate
//! module — this one keeps the simple, correct code_point model.)
//!
//! Contract: it satisfies `engine/backend.zig`. The HIR is compiled once into a
//! flat instruction `Program` (immutable, shareable); all per-search mutable state
//! lives in `Scratch` (caller-owned, reset per search via generation stamping).
//!
//! v1 scope: `buildAlloc` (heap) only — `buildComptime` (ro_data) is a follow-up
//! (needs the storage-agnostic two-pass like core/hir.zig). `\X` graphemes are not
//! supported (`caps.grapheme = false`); a pattern containing one is rejected at
//! build with `error.Unsupported`.

const std = @import("std");

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");

const ezi_code = @import("ezi_code");
const properties = ezi_code.unicode.properties;

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const Range = hir.Range;
const CodePoint = ezi_code.encoding.CodePoint;

// ── Contract surface ────────────────────────────────────────────────────────────

pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = false };

/// Backend build options. The HIR has already applied flags/folding, so the Pike
/// VM needs nothing here; the field exists to satisfy the contract shape.
pub const Options = struct {};

// ── Instruction set ─────────────────────────────────────────────────────────────

/// One NFA instruction. `char`/`range`/`any` consume exactly one code_point and
/// fall through to `pc + 1`; the rest are epsilon transitions or terminal.
pub const Inst = union(enum) {
    /// Match this exact code_point.
    char: CodePoint,
    /// Match a code_point inside `ranges[start..start+len]` (already positive).
    range: struct { start: u32, len: u32 },
    /// Match any code_point (`dot_all`) or any-except-`\n`.
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
/// needs out of the HIR, so the HIR may be freed after `buildAlloc`.
pub const Program = struct {
    insts: []const Inst,
    ranges: []const Range,
    /// `2 * (capture_count + 1)` — slots needed by `searchCaptures`.
    slot_count: u32,
};

// ── Compiler: HIR → Program ──────────────────────────────────────────────────────

/// Exact output sizes, from the `.count` pass.
const Sizes = struct { insts: u32, ranges: u32 };

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
        // Buffers + a backpatch stack exist only when emitting.
        insts: if (is_emit) []Inst else void = if (is_emit) undefined else {},
        ranges: if (is_emit) []Range else void = if (is_emit) undefined else {},
        // A real (empty in count mode) slice so the backpatch loops type-check in
        // both modes; count mode never pushes, so the loops run zero iterations.
        patch: []u32 = &.{},
        inst_len: u32 = 0,
        range_len: u32 = 0,
        patch_len: u32 = 0,

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
            const start = self.range_len;
            if (is_emit) @memcpy(self.ranges[start .. start + src.len], src);
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

/// Emit pass: fill caller buffers (each ≥ the matching `measure` size; `patch` ≥
/// `insts.len`) and return the `Program` sub-slicing them.
fn build(h: hir.Hir, insts: []Inst, ranges: []Range, patch: []u32) error{Unsupported}!Program {
    var b = Builder(.emit){ .h = h, .insts = insts, .ranges = ranges, .patch = patch };
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

/// Compile a HIR into a heap-allocated `Program` (free with `freeProgram`).
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    const sizes = measure(h) catch return error.Unsupported;
    const insts = try gpa.alloc(Inst, sizes.insts);
    errdefer gpa.free(insts);
    const ranges = try gpa.alloc(Range, sizes.ranges);
    errdefer gpa.free(ranges);
    const patch = try gpa.alloc(u32, sizes.insts); // backpatch stack ≤ #insts
    defer gpa.free(patch);
    return build(h, insts, ranges, patch) catch error.Unsupported;
}

/// Compile a HIR into a ro_data `Program` at comptime — the basis for
/// `compileComptime`. `\X` becomes a `@compileError`.
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    // Compilation here is just two linear walks of the (already-resolved) HIR —
    // no Unicode-table scans. Cost is ~O(nodes + literals + ranges), so the quota
    // ceiling scales with those. Generous (~100×) but nowhere near the old
    // 20k/node blanket.
    const work: u64 = @as(u64, h.nodes.len) + h.literals.len + h.ranges.len;
    @setEvalBranchQuota(@intCast(@min(20_000 + work * 100, std.math.maxInt(u32))));
    const sizes = comptime (measure(h) catch @compileError("pikevm: unsupported HIR node (\\X grapheme is not supported by this backend)"));
    comptime var insts: [sizes.insts]Inst = undefined;
    comptime var ranges: [sizes.ranges]Range = undefined;
    comptime var patch: [sizes.insts]u32 = undefined;
    const prog = build(h, &insts, &ranges, &patch) catch unreachable; // measure already validated
    const final_insts = insts[0..prog.insts.len].*;
    const final_ranges = ranges[0..prog.ranges.len].*;
    return .{ .insts = &final_insts, .ranges = &final_ranges, .slot_count = prog.slot_count };
}

pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    gpa.free(program.insts);
    gpa.free(program.ranges);
}

// ── Scratch: thread lists ────────────────────────────────────────────────────────

/// A priority-ordered set of NFA threads, deduplicated by `pc` via generation
/// stamping (clearing is O(1): bump `gen`).
const ThreadList = struct {
    pcs: []u32,
    slots: []?usize, // capacity * slot_count
    seen: []u32,
    gen: u32 = 0,
    n: usize = 0,
    sc: usize,

    fn init(gpa: std.mem.Allocator, capacity: usize, sc: usize) std.mem.Allocator.Error!ThreadList {
        const seen = try gpa.alloc(u32, capacity);
        @memset(seen, 0);
        return .{
            .pcs = try gpa.alloc(u32, capacity),
            .slots = try gpa.alloc(?usize, capacity * sc),
            .seen = seen,
            .sc = sc,
        };
    }
    fn deinit(self: *ThreadList, gpa: std.mem.Allocator) void {
        gpa.free(self.pcs);
        gpa.free(self.slots);
        gpa.free(self.seen);
    }
    fn clear(self: *ThreadList) void {
        self.n = 0;
        self.gen +%= 1;
    }
};

/// Per-search mutable state (caller-owned; see the contract). Two thread lists, a
/// working slot array for the epsilon closure, and the winning match's slots.
pub const Scratch = struct {
    clist: ThreadList,
    nlist: ThreadList,
    entry_slots: []?usize,
    match_slots: []?usize,
    slot_count: usize,

    /// Allocator-backed init. Sized from the program (thread capacity = #insts).
    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        const cap = program.insts.len;
        const sc = program.slot_count;
        return .{
            .clist = try ThreadList.init(gpa, cap, sc),
            .nlist = try ThreadList.init(gpa, cap, sc),
            .entry_slots = try gpa.alloc(?usize, sc),
            .match_slots = try gpa.alloc(?usize, sc),
            .slot_count = sc,
        };
    }

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        self.clist.deinit(gpa);
        self.nlist.deinit(gpa);
        gpa.free(self.entry_slots);
        gpa.free(self.match_slots);
    }

    /// Optional fast reuse — `run` already re-initializes per call, so this is a
    /// no-op kept for contract symmetry / explicit intent.
    pub fn reset(self: *Scratch) void {
        self.clist.clear();
        self.nlist.clear();
    }
};

// ── Epsilon closure ──────────────────────────────────────────────────────────────

/// Add a thread at `pc` to `list`, following epsilon transitions
/// (split/jmp/save/assertion) and appending consuming/match instructions. `slots`
/// is the working capture array; `save` mutates then restores it so sibling
/// branches are unaffected, and the value at a consuming/match inst is snapshotted
/// into the list entry. Dedup by `pc` keeps it linear.
fn addThread(program: *const Program, list: *ThreadList, pc: u32, slots: []?usize, sp: usize, input: []const u8) void {
    if (list.seen[pc] == list.gen) return;
    list.seen[pc] = list.gen;
    switch (program.insts[pc]) {
        .jmp => |t| addThread(program, list, t, slots, sp, input),
        .split => |s| {
            addThread(program, list, s.a, slots, sp, input);
            addThread(program, list, s.b, slots, sp, input);
        },
        .save => |slot| {
            if (slot < slots.len) {
                const old = slots[slot];
                slots[slot] = sp;
                addThread(program, list, pc + 1, slots, sp, input);
                slots[slot] = old;
            } else {
                addThread(program, list, pc + 1, slots, sp, input);
            }
        },
        .assertion => |kind| {
            if (assertionHolds(kind, input, sp)) addThread(program, list, pc + 1, slots, sp, input);
        },
        else => {
            const i = list.n;
            list.pcs[i] = pc;
            @memcpy(list.slots[i * list.sc .. i * list.sc + list.sc], slots[0..list.sc]);
            list.n += 1;
        },
    }
}

// ── The VM ───────────────────────────────────────────────────────────────────────

fn run(program: *const Program, sc: *Scratch, input: []const u8, opts: SearchOptions) ?[]const ?usize {
    var clist = &sc.clist;
    var nlist = &sc.nlist;
    clist.clear();
    nlist.clear();
    @memset(sc.entry_slots, null);

    var matched = false;
    var sp = opts.start;
    while (true) {
        if (!matched and (!opts.anchored or sp == opts.start)) {
            addThread(program, clist, 0, sc.entry_slots, sp, input);
        }
        const at_end = sp >= input.len;
        // Stop only when there are no live threads AND no way to spawn a new
        // start thread later: a match is locked in, the search is anchored, or
        // we've run out of input. For an unanchored search mid-input we keep
        // going even with an empty list — the next position seeds a fresh start
        // thread (crucial when a leading assertion like `^`/`\b` fails here).
        if (clist.n == 0 and (matched or opts.anchored or at_end)) break;

        var cp: CodePoint = 0;
        var cplen: usize = 1;
        if (!at_end) {
            const d = decodeAt(input, sp);
            cp = d.cp;
            cplen = d.len;
        }

        nlist.clear();
        var i: usize = 0;
        while (i < clist.n) : (i += 1) {
            const t_pc = clist.pcs[i];
            const tslots = clist.slots[i * clist.sc .. i * clist.sc + clist.sc];
            switch (program.insts[t_pc]) {
                .char => |ch| if (!at_end and cp == ch)
                    addThread(program, nlist, t_pc + 1, tslots, sp + cplen, input),
                .range => |r| if (!at_end and inRanges(program.ranges[r.start .. r.start + r.len], cp))
                    addThread(program, nlist, t_pc + 1, tslots, sp + cplen, input),
                .any => |a| if (!at_end and (a.dot_all or cp != '\n'))
                    addThread(program, nlist, t_pc + 1, tslots, sp + cplen, input),
                .match => {
                    @memcpy(sc.match_slots, tslots);
                    matched = true;
                    break; // cut lower-priority threads
                },
                else => unreachable, // epsilon insts never enter a thread list
            }
        }

        const tmp = clist;
        clist = nlist;
        nlist = tmp;
        if (at_end) break;
        sp += cplen;
    }
    return if (matched) sc.match_slots[0..sc.slot_count] else null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return run(program, scratch, input, opts) != null;
}

pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    const slots = run(program, scratch, input, opts) orelse return null;
    return .{ .start = slots[0].?, .end = slots[1].? };
}

pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots_out: []?usize, opts: SearchOptions) ?Match {
    const slots = run(program, scratch, input, opts) orelse return null;
    const k = @min(slots_out.len, slots.len);
    @memcpy(slots_out[0..k], slots[0..k]);
    return .{ .start = slots[0].?, .end = slots[1].? };
}

// ── helpers ──────────────────────────────────────────────────────────────────────

fn inRanges(ranges: []const Range, cp: CodePoint) bool {
    // Ranges are sorted+merged; a binary search is possible but linear is fine for
    // the modest range counts the HIR produces.
    for (ranges) |r| {
        if (cp < r.lo) return false; // sorted: no later range can contain cp
        if (cp <= r.hi) return true;
    }
    return false;
}

const Decoded = struct { cp: CodePoint, len: usize };

/// Decode one code_point at byte offset `sp`. Invalid UTF-8 yields U+FFFD with a
/// 1-byte advance — the engine's `fail`-ish policy: it won't match across an
/// invalid byte but still makes progress.
fn decodeAt(input: []const u8, sp: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(input[sp]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (sp + len > input.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(input[sp .. sp + len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn isCont(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Decode the code_point ending just before byte offset `sp`, or null at the start.
fn cpBefore(input: []const u8, sp: usize) ?CodePoint {
    if (sp == 0) return null;
    var i = sp - 1;
    var back: usize = 0;
    while (i > 0 and isCont(input[i]) and back < 3) : (back += 1) i -= 1;
    const len = std.unicode.utf8ByteSequenceLength(input[i]) catch return input[sp - 1];
    if (i + len != sp) return input[sp - 1]; // misaligned/invalid → last byte as scalar
    return std.unicode.utf8Decode(input[i .. i + len]) catch input[sp - 1];
}

fn wordBefore(input: []const u8, sp: usize) bool {
    return if (cpBefore(input, sp)) |c| properties.isWord(c) else false;
}
fn wordAfter(input: []const u8, sp: usize) bool {
    if (sp >= input.len) return false;
    return properties.isWord(decodeAt(input, sp).cp);
}

fn assertionHolds(kind: hir.AnchorKind, input: []const u8, sp: usize) bool {
    return switch (kind) {
        .text_start => sp == 0,
        .text_end => sp == input.len,
        .line_start => sp == 0 or input[sp - 1] == '\n',
        .line_end => sp == input.len or input[sp] == '\n',
        .word_boundary => wordBefore(input, sp) != wordAfter(input, sp),
        .not_word_boundary => wordBefore(input, sp) == wordAfter(input, sp),
    };
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests — extensive end-to-end coverage through Engine(PikeVM)
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("../../core/compile.zig");
const E = backend.Engine(@This());

/// A compiled pattern + the metadata the agnostic layer needs. The AST and HIR are
/// freed immediately — the Program is self-contained.
const Compiled = struct {
    program: Program,
    meta: backend.Meta,
    scratch: Scratch,

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var diag: compile.Diagnostic = .{};
        const ast = compile.parse(gpa, pattern, &diag) catch |e| {
            std.debug.print("parse failed for \"{s}\": {s} ({s})\n", .{ pattern, @errorName(e), @tagName(diag.code) });
            return e;
        };
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
        errdefer freeProgram(gpa, &program);
        return .{
            .program = program,
            .meta = .{ .capture_count = h.capture_count },
            .scratch = try Scratch.init(gpa, &program),
        };
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

/// Assert that `pattern` finds its leftmost match in `input` equal to `expected`.
fn expectFind(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = re.find(input) orelse {
        std.debug.print("\"{s}\" did NOT match in \"{s}\" (expected \"{s}\")\n", .{ pattern, input, expected });
        return error.NoMatch;
    };
    try testing.expectEqualStrings(expected, m.slice(input));
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    if (re.find(input)) |m| {
        std.debug.print("\"{s}\" unexpectedly matched \"{s}\" in \"{s}\"\n", .{ pattern, m.slice(input), input });
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

// ── verifyBackend / contract ────────────────────────────────────────────────────

test "PikeVM satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

// ── literals ─────────────────────────────────────────────────────────────────────

test "literal: exact, leftmost, none" {
    try expectFind("abc", "abc", "abc");
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("abc", "abXabc", "abc"); // leftmost full match
    try expectNoMatch("abc", "ab");
    try expectNoMatch("abc", "");
    try expectFind("a", "banana", "a"); // leftmost single
    try expectSpan("a", "banana", 1, 2);
}

test "empty pattern matches empty leftmost" {
    try expectSpan("", "abc", 0, 0);
    try expectSpan("", "", 0, 0);
}

test "escaped metacharacters are literal" {
    try expectFind("a\\.c", "a.c", "a.c");
    try expectNoMatch("a\\.c", "axc");
    try expectFind("\\(\\)", "()", "()");
}

// ── dot / any ────────────────────────────────────────────────────────────────────

test "dot matches any but newline unless dot_all" {
    try expectFind("a.c", "axc", "axc");
    try expectFind("a.c", "a c", "a c");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("(?s)a.c", "a\nc", "a\nc");
    try expectFind("a.c", "a\u{1F600}c", "a\u{1F600}c"); // dot = one code_point (emoji)
}

// ── character classes ────────────────────────────────────────────────────────────

test "classes: ranges, negation, shorthands" {
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("[^a-z]+", "abXY12cd", "XY12");
    try expectFind("[0-9]+", "abc123def", "123");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "  foo_bar! ", "foo_bar");
    try expectFind("\\s+", "ab \t cd", " \t ");
    try expectNoMatch("[a-z]", "ABC");
}

test "negated shorthand classes" {
    try expectFind("\\D+", "12ab34", "ab");
    try expectFind("\\W+", "ab??cd", "??");
    try expectFind("\\S+", "  word  ", "word");
}

test "class with mixed members and metachars" {
    try expectFind("[-+]?[0-9]+", "x-42y", "-42");
    try expectFind("[.!?]+", "hi!!?", "!!?");
}

// ── alternation ──────────────────────────────────────────────────────────────────

test "alternation: leftmost-first priority" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("cat|dog", "cat and dog", "cat");
    // leftmost-first: earlier alternative wins at the same position
    try expectFind("a|ab", "ab", "a");
    try expectFind("ab|a", "ab", "ab");
    try expectFind("foo|foobar", "foobar", "foo");
    try expectNoMatch("cat|dog", "fish");
}

test "nested alternation in groups" {
    try expectFind("(ab|cd)+", "abcdab!", "abcdab");
    try expectFind("a(b|c|d)e", "ace", "ace");
    try expectFind("a(b|c|d)e", "ade", "ade");
}

// ── quantifiers ──────────────────────────────────────────────────────────────────

test "star / plus / question (greedy)" {
    try expectFind("ab*", "abbbc", "abbb");
    try expectFind("ab*", "ac", "a");
    try expectFind("ab+", "abbbc", "abbb");
    try expectNoMatch("ab+", "ac");
    try expectFind("ab?c", "abc", "abc");
    try expectFind("ab?c", "ac", "ac");
    try expectFind("a.*c", "abXYZc end c", "abXYZc end c"); // greedy to last c
}

test "lazy quantifiers" {
    try expectFind("a.*?c", "abXcYc", "abXc"); // lazy stops at first c
    try expectFind("a+?", "aaaa", "a");
    try expectFind("ab??", "ab", "a"); // lazy ? prefers skipping
}

test "counted repetition {m}, {m,}, {m,n}" {
    try expectFind("a{3}", "aaaaa", "aaa");
    try expectNoMatch("a{3}", "aa");
    try expectFind("a{2,}", "aaaa", "aaaa");
    try expectFind("a{2,4}", "aaaaaa", "aaaa"); // capped at 4
    try expectFind("a{2,4}", "aaa", "aaa");
    try expectNoMatch("a{2,4}", "a");
    try expectFind("a{0,2}b", "b", "b"); // zero copies allowed
    try expectFind("(ab){2,3}", "ababab", "ababab");
}

test "quantifier on group and class" {
    try expectFind("(abc)+", "abcabcab", "abcabc");
    try expectFind("[ab]{2,3}", "ababab", "aba");
}

// ── anchors ──────────────────────────────────────────────────────────────────────

test "text anchors ^ $ \\A \\z" {
    try expectFind("^abc", "abcdef", "abc");
    try expectNoMatch("^abc", "xabc");
    try expectFind("abc$", "xxabc", "abc");
    try expectNoMatch("abc$", "abcx");
    try expectFind("^abc$", "abc", "abc");
    try expectNoMatch("^abc$", "abc\n"); // $ is end-of-text here (\z semantics)
    try expectFind("\\Aabc", "abc", "abc");
    try expectFind("abc\\z", "xabc", "abc");
}

test "multiline ^ $ match around newlines" {
    try expectSpan("(?m)^b", "a\nb\nc", 2, 3);
    try expectSpan("(?m)b$", "ab\ncd", 1, 2);
    try expectFind("(?m)^line2", "line1\nline2\nline3", "line2");
}

test "word boundaries \\b \\B" {
    try expectSpan("\\bcat\\b", "a cat!", 2, 5);
    try expectNoMatch("\\bcat\\b", "category"); // 'cat' not a whole word
    try expectFind("\\bword\\b", "a word here", "word");
    try expectFind("\\Bcat\\B", "locator", "cat"); // cat surrounded by word chars
    try expectFind("foo\\b", "foo bar", "foo");
}

// ── captures ─────────────────────────────────────────────────────────────────────

test "captures: groups and spans" {
    var re = try Compiled.init("(\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    var slots: [8]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "x 2026-06-07 y", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("2026-06-07", c.match().slice("x 2026-06-07 y"));
    try testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try testing.expectEqualStrings("06", c.groupSlice(2).?);
    try testing.expectEqualStrings("07", c.groupSlice(3).?);
}

test "named captures via Meta" {
    var re = try Compiled.init("(?<y>\\d+)-(?<m>\\d+)");
    defer re.deinit();
    const names = [_]?[]const u8{ null, "y", "m" };
    re.meta.group_names = &names;
    var slots: [6]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "2026-06", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("2026", c.namedSlice("y").?);
    try testing.expectEqualStrings("06", c.namedSlice("m").?);
    try testing.expect(c.named("d") == null);
}

test "optional group does not participate -> null" {
    var re = try Compiled.init("a(b)?c");
    defer re.deinit();
    var slots: [4]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "ac", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("ac", c.match().slice("ac"));
    try testing.expect(c.group(1) == null); // (b)? skipped
    // and when it does participate:
    const c2 = E.captures(&re.program, &re.scratch, "abc", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("b", c2.groupSlice(1).?);
}

test "repeated group captures the last iteration" {
    var re = try Compiled.init("(\\w)+");
    defer re.deinit();
    var slots: [4]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "abc", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("abc", c.match().slice("abc"));
    try testing.expectEqualStrings("c", c.groupSlice(1).?); // last iteration
}

test "non-capturing group has no slot" {
    var re = try Compiled.init("(?:ab)(c)");
    defer re.deinit();
    try testing.expectEqual(@as(u32, 1), re.meta.capture_count);
    var slots: [4]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "abc", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("c", c.groupSlice(1).?);
}

// ── agnostic ops over the real backend ───────────────────────────────────────────

test "findAll over real matches" {
    var re = try Compiled.init("\\d+");
    defer re.deinit();
    const input = "a12b345c6";
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("12", it.next().?.slice(input));
    try testing.expectEqualStrings("345", it.next().?.slice(input));
    try testing.expectEqualStrings("6", it.next().?.slice(input));
    try testing.expect(it.next() == null);
}

test "count and split" {
    var re = try Compiled.init(",");
    defer re.deinit();
    try testing.expectEqual(@as(usize, 3), E.count(&re.program, &re.scratch, "a,b,c,d", .{}));
    var it = E.split(&re.program, &re.scratch, "a,b,,d", .{});
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqualStrings("d", it.next().?);
    try testing.expect(it.next() == null);
}

test "replaceAll with capture references" {
    var re = try Compiled.init("(\\w+)@(\\w+)");
    defer re.deinit();
    var slots: [6]?usize = undefined;
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&re.program, &re.scratch, "from a@b to c@d", "$2.$1", &slots, re.meta, &w);
    try testing.expectEqualStrings("from b.a to d.c", w.buffered());
}

test "anchored vs unanchored search options" {
    var re = try Compiled.init("abc");
    defer re.deinit();
    try testing.expect(E.find(&re.program, &re.scratch, "abc", .{ .anchored = true }) != null);
    try testing.expect(E.find(&re.program, &re.scratch, "xabc", .{ .anchored = true }) == null);
    try testing.expect(E.find(&re.program, &re.scratch, "xabc", .{ .anchored = false }) != null);
    // start offset
    const m = E.find(&re.program, &re.scratch, "abcabc", .{ .start = 1 }).?;
    try testing.expectEqual(@as(usize, 3), m.start);
}

// ── Unicode (the selling point) ──────────────────────────────────────────────────

test "unicode word and property classes match non-ASCII" {
    try expectFind("\\w+", "héllo, wörld", "héllo");
    try expectFind("\\w+", "naïve café", "naïve");
    try expectFind("\\p{L}+", "abc123", "abc");
    try expectFind("\\p{Lu}+", "abcDEFghi", "DEF");
    try expectFind("\\p{Nd}+", "x٤٥٦y", "٤٥٦"); // Arabic-Indic digits
    try expectFind("\\p{Script=Greek}+", "abcαβγdef", "αβγ");
}

test "case-insensitive folding (simple) matches both cases, ASCII and unicode" {
    try expectFind("(?i)abc", "XYZABCxyz", "ABC");
    try expectFind("(?i)abc", "abc", "abc");
    try expectFind("(?i)[a-z]+", "ABCdef", "ABCdef");
    try expectFind("(?i)Σ", "σ", "σ"); // Greek sigma fold
}

test "unicode literal and counted repetition by code_point" {
    try expectFind("é{2,3}", "xééééy", "ééé"); // counts code_points, not bytes
    try expectSpan("é", "aé", 1, 3); // byte offsets: 'a'=1 byte, 'é'=2 bytes
}

// ── stress / pathological (linear-time guarantee) ────────────────────────────────

test "no catastrophic backtracking: (a*)*b on long non-matching input" {
    var re = try Compiled.init("(a*)*b");
    defer re.deinit();
    var ibuf: [40]u8 = undefined; // would explode under naive backtracking
    @memset(&ibuf, 'a');
    const input: []const u8 = &ibuf;
    try testing.expect(!re.isMatch(input));
    try testing.expect(re.isMatch("aaaab"));
}

test "nested quantifiers terminate" {
    try expectFind("(a+)+", "aaa", "aaa");
    try expectFind("(a?)*", "aaa", "aaa");
    var re = try Compiled.init("(a|a)*");
    defer re.deinit();
    try testing.expect(re.isMatch("aaaaaa"));
}

test "scratch is reusable across many searches without stale state" {
    var re = try Compiled.init("(a+)(b+)");
    defer re.deinit();
    var slots: [6]?usize = undefined;
    // first search fills both groups
    const c1 = E.captures(&re.program, &re.scratch, "aabb", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("aa", c1.groupSlice(1).?);
    try testing.expectEqualStrings("bb", c1.groupSlice(2).?);
    // a non-matching search must not leave stale captures readable as a match
    try testing.expect(E.captures(&re.program, &re.scratch, "xyz", &slots, re.meta, .{}) == null);
    // a different match reuses the same scratch cleanly
    const c3 = E.captures(&re.program, &re.scratch, "ab", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("a", c3.groupSlice(1).?);
    try testing.expectEqualStrings("b", c3.groupSlice(2).?);
}

test "grapheme node is rejected (caps.grapheme = false)" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "\\X", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
}

test {
    testing.refAllDecls(@This());
}
