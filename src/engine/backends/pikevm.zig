//! Pike VM backend — a Thompson-NFA simulation with capture slots.
//!
//! The captures-capable, general backstop: linear-time `O(input × program)`, no
//! catastrophic backtracking, leftmost-first (Perl/JS) semantics. It executes the
//! shared `engine/nfa.zig` program breadth-first (a set of threads advanced one
//! code point at a time), so Unicode classes work with zero match-time
//! Unicode-table lookups. The HIR/NFA compiler and the code-point primitives live
//! in `nfa.zig`; this file is just the breadth-first execution + its `Scratch`.
//!
//! Contract: it satisfies `engine/backend.zig`. The `Program` is immutable and
//! shareable; all per-search mutable state lives in a caller-owned `Scratch`,
//! reset per search via generation stamping. `Scratch` carves a single `[]Cell`
//! buffer, so the exact same `initBuffer` path runs at comptime and runtime.
//!
//! `\X` graphemes are not supported (`caps.grapheme = false`); a pattern with one
//! is rejected at build with `error.Unsupported` (by the shared compiler).

const std = @import("std");

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const nfa = @import("engine_base").nfa;

const utils = @import("utils");

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const CodePoint = utils.unicode.CodePoint;

// ── Contract surface ────────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = false };

/// Backend build options. The HIR has already applied flags/folding, so the Pike
/// VM needs nothing here; the field exists to satisfy the contract shape.
///
/// @stable-since: v0.1.0
pub const Options = struct {};

/// The NFA instruction set and compiled program live in the shared `nfa` module
/// (the backtracking backend executes the *same* program differently).
pub const Inst = nfa.Inst;
pub const Program = nfa.Program;

/// Compile a HIR into a heap-allocated `Program` (free with `freeProgram`).
///
/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    // The breadth-first Pike VM cannot consume a variable-width `\X` cluster; refuse
    // grapheme programs at build (the backtracker / `auto` handle them instead).
    if (h.analysis.has_grapheme) return error.Unsupported;
    return nfa.buildAlloc(gpa, h);
}

/// Compile a HIR into a ro_data `Program` at comptime. `\X` becomes a `@compileError`.
///
/// @stable-since: v0.1.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    if (comptime h.analysis.has_grapheme)
        @compileError("ezi_gex: the Pike VM cannot match `\\X` (grapheme); use the backtrack or auto backend");
    return nfa.buildComptime(h);
}

/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    nfa.freeProgram(gpa, program);
}

// ── Scratch: one typed word buffer (comptime- and runtime-usable) ────────────────

/// Scratch storage word — the shared contract type, so one `[]Cell` buffer backs
/// every internal array and `auto` can forward the same buffer here. `.w` holds
/// thread `pc`s and generation stamps, `.slot` holds capture offsets (a natural
/// `?usize`). Carving by plain slicing is what lets `initBuffer` run at comptime.
pub const Cell = backend.Cell;

/// Top-bit tag distinguishing the two `Step` kinds packed into the work stack.
/// A `pc`/`slot` index never reaches the top bit of a `usize`, so it is free.
const STACK_TAG: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);

/// A priority-ordered set of NFA threads, deduplicated by `pc` via generation
/// stamping (clearing is O(1): bump `gen`).
const ThreadList = struct {
    pcs: []Cell, // .w   — instruction pointer per live thread (len = capacity)
    slots: []Cell, // .slot — capture offsets (len = capacity * sc)
    seen: []Cell, // .w   — generation stamp per pc (len = capacity)
    gen: usize = 0,
    n: usize = 0,
    sc: usize,

    /// Build from caller-provided backing arrays (carved out of the one buffer).
    /// `seen` is zeroed so the generation stamp starts clean.
    fn fromParts(pcs: []Cell, slots: []Cell, seen: []Cell, sc: usize) ThreadList {
        @memset(seen, .{ .w = 0 });
        return .{ .pcs = pcs, .slots = slots, .seen = seen, .sc = sc };
    }
    fn clear(self: *ThreadList) void {
        self.n = 0;
        self.gen +%= 1;
    }
};

/// One unit of deferred work for the iterative epsilon closure (`addThread`).
/// `visit` follows the instruction at `pc`; `restore` writes `old` back into a
/// capture slot once a `save`'s subtree has been fully explored, so sibling
/// branches never observe the write. This is the explicit-stack form of the
/// recursive closure's save/restore — see `addThread`. It is packed into the
/// `[]Cell` stack two cells at a time (payload word + optional `old`).
const Step = union(enum) {
    visit: u32,
    restore: struct { slot: u32, old: ?usize },
};

fn pushVisit(stack: []Cell, top: *usize, pc: u32) void {
    stack[top.*] = .{ .w = pc };
    top.* += 2;
}
fn pushRestore(stack: []Cell, top: *usize, slot: u32, old: ?usize) void {
    stack[top.*] = .{ .w = @as(usize, slot) | STACK_TAG };
    stack[top.* + 1] = .{ .slot = old };
    top.* += 2;
}
fn popStep(stack: []Cell, top: *usize) Step {
    top.* -= 2;
    const w0 = stack[top.*].w;
    if (w0 & STACK_TAG != 0)
        return .{ .restore = .{ .slot = @intCast(w0 & ~STACK_TAG), .old = stack[top.* + 1].slot } };
    return .{ .visit = @intCast(w0) };
}

/// Per-search mutable state (caller-owned; see the contract). Two thread lists, a
/// working slot array for the epsilon closure, the closure's iterative work stack,
/// and the winning match's slots — all carved from one `[]Cell` buffer.
///
/// @stable-since: v0.1.0
pub const Scratch = struct {
    clist: ThreadList,
    n_list: ThreadList,
    entry_slots: []Cell, // .slot — working captures for the seed closure
    match_slots: []Cell, // .slot — the winning thread's captures
    /// Work stack for `addThread` (the epsilon closure runs iteratively, not by
    /// recursion). Each `Step` is two cells; the closure expands each `pc` at most
    /// once (the `seen` guard) and only `split`/`save` push, so the live depth
    /// never exceeds the instruction count — hence `2 * #insts` cells.
    stack: []Cell,
    slot_count: usize,
    /// The buffer `init` allocated, freed by `deinit`. `null` for a buffer-backed
    /// Scratch (the caller owns that storage; `deinit` is then a no-op).
    owned: ?[]Cell = null,

    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = backend.Cell;

    /// Number of `Cell`s a buffer must hold for this program. Use it to size a
    /// fixed buffer (`var buf: [Scratch.bufferLen(&prog)]Scratch.Cell = undefined;`).
    ///
    /// @stable-since: v0.1.0
    pub fn bufferLen(program: *const Program) usize {
        const cap = program.insts.len;
        const sc = program.slot_count;
        // c{pcs,slots,seen} + n{pcs,slots,seen} + entry + match + stack
        return 6 * cap + 2 * cap * sc + 2 * sc;
    }

    /// Carve a caller-provided `[]Cell` buffer (≥ `bufferLen`) into the scratch
    /// arrays. **Works at comptime and runtime** — at comptime the caller declares
    /// the buffer as `var buf: [N]Cell` and references it. No allocator, no
    /// teardown (the caller owns `buf`); on a short buffer returns
    /// `error.BufferTooSmall`. This is the "with limits" path of the design.
    ///
    /// @stable-since: v0.1.0
    pub fn initBuffer(buf: []Cell, program: *const Program) backend.ScratchError!Scratch {
        const cap = program.insts.len;
        const sc = program.slot_count;
        var cur = backend.Carver{ .buf = buf };
        const c_pcs = try cur.take(cap);
        const c_slots = try cur.take(cap * sc);
        const c_seen = try cur.take(cap);
        const n_pcs = try cur.take(cap);
        const n_slots = try cur.take(cap * sc);
        const n_seen = try cur.take(cap);
        const e_slots = try cur.take(sc);
        const m_slots = try cur.take(sc);
        const stk = try cur.take(2 * cap);
        return .{
            .clist = ThreadList.fromParts(c_pcs, c_slots, c_seen, sc),
            .n_list = ThreadList.fromParts(n_pcs, n_slots, n_seen, sc),
            .entry_slots = e_slots,
            .match_slots = m_slots,
            .stack = stk,
            .slot_count = sc,
        };
    }

    /// Allocator-backed init: grab one `[]Cell` and carve it. The buffer is owned
    /// and released by `deinit`.
    ///
    /// @stable-since: v0.1.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        const buf = try gpa.alloc(Cell, bufferLen(program));
        var s = initBuffer(buf, program) catch unreachable; // buffer sized exactly
        s.owned = buf;
        return s;
    }

    /// @stable-since: v0.1.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        if (self.owned) |buf| gpa.free(buf);
        self.owned = null;
    }

    /// Optional fast reuse — `run` already re-initializes per call, so this is a
    /// no-op kept for contract symmetry / explicit intent.
    ///
    /// @stable-since: v0.1.0
    pub fn reset(self: *Scratch) void {
        self.clist.clear();
        self.n_list.clear();
    }
};

// ── Epsilon closure ──────────────────────────────────────────────────────────────

/// Add a thread at `pc0` to `list`, following epsilon transitions
/// (split/jmp/save/assertion) and appending consuming/match instructions. `slots`
/// is the working capture array; a `save` mutates it and queues a `restore` so
/// sibling branches are unaffected, and the value at a consuming/match inst is
/// snapshotted into the list entry. Dedup by `pc` (via `seen`/`gen`) keeps it
/// linear and breaks epsilon cycles.
///
/// Done **iteratively** over the caller-owned `stack`, not by recursion: a deeply
/// nested pattern produces a long epsilon chain, and recursing it once per `pc`
/// would overflow the call stack. Each non-branching step (jmp/save/assertion and
/// the higher-priority `split` arm) is followed in place; only the lower-priority
/// `split` arm and a `save`'s deferred `restore` are pushed. A pushed entry pops
/// only after everything above it drains — exactly the dynamic extent of the
/// recursive call it replaces — so leftmost-first priority and capture save/restore
/// nesting are preserved bit-for-bit.
fn addThread(program: *const Program, list: *ThreadList, pc0: u32, slots: []Cell, sp: usize, input: []const u8, stack: []Cell) void {
    var top: usize = 0;
    pushVisit(stack, &top, pc0);
    while (top > 0) {
        switch (popStep(stack, &top)) {
            // A `save`'s subtree (everything pushed above this) is now drained —
            // undo the slot write so it stays local to that subtree.
            .restore => |r| if (r.slot < slots.len) {
                slots[r.slot] = .{ .slot = r.old };
            },
            .visit => |start_pc| {
                var pc = start_pc;
                follow: while (true) {
                    if (list.seen[pc].w == list.gen) break :follow; // already queued / cycle
                    list.seen[pc] = .{ .w = list.gen };
                    switch (program.insts[pc]) {
                        .jmp => |t| {
                            // Empty-width-loop guard. The compiler emits exactly one
                            // BACKWARD jmp — the loop-back of an unbounded repetition
                            // `B*`/`B+`/`B{m,}` (alternation enders all jmp forward), and its
                            // loop EXIT is always the next instruction (`pc + 1`, the `after`
                            // label). When the loop head `t` was already visited in THIS
                            // epsilon closure (same position), the body matched the empty
                            // string this iteration — a consuming inst would have ended the
                            // walk before reaching here — so leftmost-first terminates the
                            // loop: route to the exit at the empty path's priority instead of
                            // looping (which would dedup-die on the seen head and demote the
                            // exit below a lower-priority consuming sibling). This is the
                            // RE2/Rust leftmost-first empty-loop rule, applied uniformly:
                            // `(?:a?b??)+` on "ab" → "a", and an empty-first nullable
                            // alternation `(?:|.)+` on "c" → "" (the empty branch is highest
                            // priority, so the loop exits). A forward jmp, or a back-edge whose
                            // head is not yet seen (a genuine non-empty next iteration), loops
                            // as before. See nfa.zig `compileRepetition`.
                            if (t < pc and list.seen[t].w == list.gen) {
                                pc += 1; // empty iteration → loop exit (`after`)
                            } else pc = t;
                        },
                        .split => |s| {
                            // Pursue the higher-priority branch now; defer `b` so it
                            // pops only after everything `a` reaches — leftmost-first.
                            pushVisit(stack, &top, s.b);
                            pc = s.a;
                        },
                        .save => |slot| {
                            if (slot < slots.len) {
                                pushRestore(stack, &top, slot, slots[slot].slot);
                                slots[slot] = .{ .slot = sp };
                            }
                            pc += 1;
                        },
                        .assertion => |kind| {
                            if (!nfa.assertionHolds(kind, input, sp)) break :follow; // thread dies
                            pc += 1;
                        },
                        else => {
                            // Consuming (char/range/any) or match: snapshot slots into
                            // a list entry; this epsilon chain ends here.
                            const i = list.n;
                            list.pcs[i] = .{ .w = pc };
                            @memcpy(list.slots[i * list.sc .. i * list.sc + list.sc], slots[0..list.sc]);
                            list.n += 1;
                            break :follow;
                        },
                    }
                }
            },
        }
    }
}

// ── Line-anchored fast scan (`(?m)^` seed-gating) ─────────────────────────────────

/// Whether byte offset `sp` is a **line start**: offset 0, or just after a `\n`. The
/// position where `(?m)^` (`line_start`) holds, so the only place a `line_anchored`
/// program can begin a match.
inline fn atLineStart(input: []const u8, sp: usize) bool {
    return sp == 0 or input[sp - 1] == '\n';
}

/// First `\n` at offset `≥ from`, or null. Runtime uses the SIMD `memchr`; comptime
/// uses a plain scan (the project keeps `@Vector` out of const-eval). Drives the leap
/// between line starts when a `line_anchored` search has no live threads.
fn nextNewline(input: []const u8, from: usize) ?usize {
    if (@inComptime()) {
        var i = from;
        while (i < input.len) : (i += 1) if (input[i] == '\n') return i;
        return null;
    }
    return std.mem.indexOfScalarPos(u8, input, from, '\n');
}

// ── The VM ───────────────────────────────────────────────────────────────────────

fn run(program: *const Program, sc: *Scratch, input: []const u8, opts: SearchOptions, span_only: bool) ?[]const Cell {
    var c_list = &sc.clist;
    var n_list = &sc.n_list;
    // Span-only: `search`/`isMatch` need just the overall match bounds (slots 0,1), so track a
    // 2-slot stride instead of `2*(groups+1)`. Inner `save`s are skipped (slot ≥ 2) and only
    // two cells are copied per thread — a big cut on a many-group pattern's `count`/`find`
    // (`(?m)^(\S+) … (\d+)`). The found match is identical (priority is by `pc`, not slots); only
    // the unrecorded inner groups differ, which span ops never read. `searchCaptures` passes
    // `false` to keep every slot.
    const eff_sc: usize = if (span_only) @min(@as(usize, 2), sc.slot_count) else sc.slot_count;
    c_list.sc = eff_sc;
    n_list.sc = eff_sc;
    c_list.clear();
    n_list.clear();
    @memset(sc.entry_slots, .{ .slot = null });

    var matched = false;
    var sp = opts.start;

    // `(?m)^` seed-gating: a `line_anchored` program can only begin a match at a line
    // start, so on an unanchored search we seed a start thread **only** at line starts
    // and, when the thread set empties, leap to the next line start with a `\n` memchr
    // (below). One linear pass, leftmost-first preserved — no per-line confirm loop, so
    // no Θ(n²). Disabled for anchored searches (the seed is already pinned to `start`).
    const line_gate = program.line_anchored and !opts.anchored;

    while (true) {
        if (!matched and (!opts.anchored or sp == opts.start) and (!line_gate or atLineStart(input, sp))) {
            addThread(program, c_list, 0, sc.entry_slots[0..eff_sc], sp, input, sc.stack);
        }
        const at_end = sp >= input.len;
        // Stop only when there are no live threads AND no way to spawn a new
        // start thread later: a match is locked in, the search is anchored, or
        // we've run out of input. For an unanchored search mid-input we keep
        // going even with an empty list — the next position seeds a fresh start
        // thread (crucial when a leading assertion like `^`/`\b` fails here).
        if (c_list.n == 0 and (matched or opts.anchored or at_end)) break;
        // Line-anchored leap: no live threads here (so we are NOT at a line start — a
        // line-start seed always yields ≥1 thread), so no match can begin before the
        // next line start. Jump straight to it instead of stepping byte-by-byte; if
        // there is no further `\n`, there is no later line start, so no match remains.
        if (line_gate and !matched and c_list.n == 0) {
            const nl = nextNewline(input, sp) orelse break;
            // A dead seed at this position left generation stamps in `c_list`; bump the
            // generation (the step/swap that normally does so is skipped by `continue`)
            // so the next line start's seed is not deduped away as "already queued".
            c_list.clear();
            sp = nl + 1;
            continue;
        }

        var cp: CodePoint = 0;
        var cp_len: usize = 1;
        var valid = true; // dead-on-invalid: an invalid UTF-8 byte matches nothing
        if (!at_end) {
            const b = input[sp];
            if (b <= 0x7F) {
                // ASCII fast path: one byte, one scalar (the overwhelmingly common
                // case for the scan's hot loop). `cp_len` already defaults to 1.
                @branchHint(.likely);
                cp = b;
            } else {
                const d = nfa.decodeAt(input, sp);
                cp = d.cp;
                cp_len = d.len;
                valid = d.valid;
            }
        }

        n_list.clear();
        var i: usize = 0;
        while (i < c_list.n) : (i += 1) {
            const t_pc: u32 = @intCast(c_list.pcs[i].w);
            const t_slots = c_list.slots[i * c_list.sc .. i * c_list.sc + c_list.sc];
            switch (program.insts[t_pc]) {
                .char => |ch| if (!at_end and valid and cp == ch)
                    addThread(program, n_list, t_pc + 1, t_slots, sp + cp_len, input, sc.stack),
                .range => |r| if (!at_end and valid and nfa.inRanges(program.ranges[r.start .. r.start + r.len], cp))
                    addThread(program, n_list, t_pc + 1, t_slots, sp + cp_len, input, sc.stack),
                .any => |a| if (!at_end and valid and (a.dot_all or cp != '\n'))
                    addThread(program, n_list, t_pc + 1, t_slots, sp + cp_len, input, sc.stack),
                .match => {
                    @memcpy(sc.match_slots[0..eff_sc], t_slots);
                    matched = true;
                    break; // cut lower-priority threads
                },
                else => unreachable, // epsilon insts never enter a thread list
            }
        }

        const tmp = c_list;
        c_list = n_list;
        n_list = tmp;
        if (at_end) break;
        sp += cp_len;
    }
    return if (matched) sc.match_slots[0..eff_sc] else null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.1.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return run(program, scratch, input, opts, true) != null; // span-only: bounds suffice
}

/// @stable-since: v0.1.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    const slots = run(program, scratch, input, opts, true) orelse return null; // span-only
    return .{ .start = slots[0].slot.?, .end = slots[1].slot.? };
}

/// @stable-since: v0.1.0
pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots_out: []?usize, opts: SearchOptions) ?Match {
    const slots = run(program, scratch, input, opts, false) orelse return null; // need every group
    const k = @min(slots_out.len, slots.len);
    var i: usize = 0;
    while (i < k) : (i += 1) slots_out[i] = slots[i].slot;
    return .{ .start = slots[0].slot.?, .end = slots[1].slot.? };
}

// Code-point match primitives (`inRanges`, `decodeAt`, `assertionHolds`) live in
// the shared `nfa` module — see the `run` loop above.

// ════════════════════════════════════════════════════════════════════════════════
// Tests — extensive end-to-end coverage through Engine(PikeVM)
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("core").compile;
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

test "deep nesting does not overflow the call stack (iterative epsilon closure)" {
    // `a?a?a?…` (n times) lowers to a chain of n `split`s with no consuming inst
    // between them. The seed closure has to walk every skip-branch in one go, so it
    // descends n epsilon transitions deep — the old recursive `addThread` recursed
    // once per `split` and overflowed the call stack well before this n. The
    // iterative closure walks the same chain on `Scratch.stack` (capacity #insts),
    // so it just works.
    const gpa = testing.allocator;
    const n = 100_000;
    const pat = try gpa.alloc(u8, 2 * n);
    defer gpa.free(pat);
    for (0..n) |i| {
        pat[2 * i] = 'a';
        pat[2 * i + 1] = '?';
    }
    var re = try Compiled.init(pat);
    defer re.deinit();
    // All optionals may be skipped → matches empty at position 0; and greedily
    // consumes as many 'a's as present.
    try testing.expectEqual(@as(usize, 0), re.find("").?.start);
    try testing.expectEqual(@as(usize, 0), re.find("").?.end);
    try testing.expectEqualStrings("aaa", re.find("aaab").?.slice("aaab"));
}

test "nested quantifiers terminate" {
    try expectFind("(a+)+", "aaa", "aaa");
    try expectFind("(a?)*", "aaa", "aaa");
    var re = try Compiled.init("(a|a)*");
    defer re.deinit();
    try testing.expect(re.isMatch("aaaaaa"));
}

test "empty-width-loop guard: an empty iteration terminates the loop (leftmost-first)" {
    // An unbounded loop over a nullable concat/lazy body must STOP at the first empty
    // iteration rather than over-consume — the RE2/Rust leftmost-first rule, now uniform.
    try expectFind("(?:a?b??)+", "ab", "a"); // iter1 "a", iter2 empty → stop (was "ab")
    try expectFind("(?:a?b?c??)+", "abc", "ab");
    try expectSpan("(?:a??b??)+", "ab", 0, 0); // both lazy → empty at 0
    // The body's consume capability is intact when downstream forces it.
    try expectFind("(?:a?b??)+x", "abx", "abx");
    try expectFind("(?:a??b??)+b", "ab", "ab");
    // A greedy body still consumes (the empty exit is lower priority than consuming).
    try expectFind("(?:a?b?)+", "ab", "ab");
    // Empty-first nullable alternation exits empty; consuming-first consumes.
    try expectSpan("(?:|.)+", "c", 0, 0);
    try expectFind("(a|)+", "aa", "aa");
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

// ── comptime matching + buffer scratch (the new capability) ───────────────────────

test "pikevm: full match pipeline runs at COMPTIME via a buffer scratch" {
    // Build program + scratch and run a search entirely at comptime: the buffer is
    // a plain `[N]Cell` array, carved by slicing — no allocator, no reinterpret.
    const got = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        const a = compile.compile("(\\d{4})-(\\d{2})");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir build failed"),
        };
        const program = buildComptime(h, .{});
        var buf: [Scratch.bufferLen(&program)]Cell = undefined;
        var sc = Scratch.initBuffer(&buf, &program) catch unreachable;
        const input = "date 2026-06 end";
        const m = E.find(&program, &sc, input, .{}) orelse @compileError("no match at comptime");
        break :blk m.slice(input);
    };
    try testing.expectEqualStrings("2026-06", got);
}

test "pikevm: comptime captures via a buffer scratch" {
    const ok = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        const a = compile.compile("(\\w+)@(\\w+)");
        const h = switch (hir.buildComptime(a, .{})) {
            .ok => |x| x,
            .fail => @compileError("hir"),
        };
        const program = buildComptime(h, .{});
        var buf: [Scratch.bufferLen(&program)]Cell = undefined;
        var sc = Scratch.initBuffer(&buf, &program) catch unreachable;
        var slots: [6]?usize = undefined;
        const input = "user@host";
        const c = E.captures(&program, &sc, input, &slots, .{ .capture_count = 2 }, .{}) orelse
            @compileError("no captures");
        break :blk std.mem.eql(u8, c.groupSlice(1).?, "user") and std.mem.eql(u8, c.groupSlice(2).?, "host");
    };
    try testing.expect(ok);
}

test "pikevm: runtime buffer scratch (no allocator) + BufferTooSmall" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "[a-z]+\\d+", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);

    // A generous fixed stack buffer — no heap at all. At runtime the program size
    // is dynamic, so the caller picks a capacity and checks the result; a
    // too-small buffer is reported, never a crash.
    var stack_buf: [1024]Cell = undefined;
    var sc = try Scratch.initBuffer(&stack_buf, &program);
    try testing.expectEqualStrings("abc123", E.find(&program, &sc, "??abc123!!", .{}).?.slice("??abc123!!"));
    // reusable across searches, same as the heap scratch
    try testing.expect(!E.isMatch(&program, &sc, "ABC", .{}));

    // A buffer too small is rejected cleanly (no crash, no UB).
    var tiny: [4]Cell = undefined;
    try testing.expectError(error.BufferTooSmall, Scratch.initBuffer(&tiny, &program));
}

test "pikevm: comptime and buffer scratch agree with the heap scratch" {
    const pat = "a(b|c)+d";
    const input = "xxabcbcd!";
    // heap
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, pat, &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);
    var heap_sc = try Scratch.init(gpa, &program);
    defer heap_sc.deinit(gpa);
    const heap_span = E.find(&program, &heap_sc, input, .{}).?;

    // buffer (runtime, generous fixed capacity)
    var buf: [1024]Cell = undefined;
    var buf_sc = try Scratch.initBuffer(&buf, &program);
    const buf_span = E.find(&program, &buf_sc, input, .{}).?;

    try testing.expectEqual(heap_span.start, buf_span.start);
    try testing.expectEqual(heap_span.end, buf_span.end);
    try testing.expectEqualStrings("abcbcd", heap_span.slice(input));
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
