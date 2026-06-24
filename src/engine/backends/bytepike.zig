//! Byte Pike VM backend — a Thompson-NFA simulation over the **byte** program.
//!
//! Where `pikevm.zig` executes the code-point `nfa.Program` (decoding one scalar per
//! step and testing it against resolved ranges), this backend executes the
//! byte-grained `byte.Program` from `engine/byte.zig`: it advances **one input byte
//! per step** and each consuming instruction is a `byte_range` test, so matching
//! needs **zero decode** — the Unicode-ness is baked into the byte automaton at
//! lowering time. It is the reference executor that proves the byte lowering correct
//! (via `conformance.zig`) and the substrate the future lazy DFA will determinize.
//! It is *not* `auto`'s default — stepping per byte is not a
//! throughput win over the code-point VM; the DFA is.
//!
//! Semantics are identical to the Pike VM: linear-time `O(input × program)`,
//! leftmost-first (Perl/JS), no catastrophic backtracking. The same caller-owned
//! `Scratch` design (one `[]Cell` buffer, generation-stamped reset, iterative
//! epsilon closure) carries over verbatim, so it runs at comptime and runtime.
//!
//! Not byte-lowerable (so refused at build, `error.Unsupported`): `\X` (grapheme).
//! `\b`/`\B` **are** lowered and evaluated as **ASCII** word boundaries (`byte.assertionHolds`)
//! — exact for ASCII input; the dispatcher (`auto`) keeps non-ASCII `\b` input on the
//! code-point engines, so this byte engine only ever sees ASCII for a `\b` pattern.
//! **Invalid UTF-8** needs no special handling: the lowering only accepts well-formed
//! sequences, so a malformed byte matches nothing and the unanchored scan resyncs to
//! the next start position — dead-on-invalid by construction.

const std = @import("std");

const backend = @import("engine_base").backend;
const hir = @import("core").hir;
const byte = @import("engine_base").byte;
const nfa = @import("engine_base").nfa; // code-point length, to seed start threads only at code-point boundaries

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;

// ── Contract surface ────────────────────────────────────────────────────────────

/// @stable-since: v0.2.0
pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = false };

/// Backend build options. The HIR has already applied flags/folding and the byte
/// lowering needs nothing more; the field exists to satisfy the contract shape.
///
/// @stable-since: v0.2.0
pub const Options = struct {};

/// The byte instruction set and compiled byte program live in `engine/byte.zig`.
pub const Inst = byte.Inst;
pub const Program = byte.Program;

/// Compile a HIR into a heap-allocated byte `Program` (free with `freeProgram`).
/// `\X` (grapheme) is refused with `error.Unsupported`; `\b`/`\B` lower to byte
/// assertions (evaluated as ASCII word boundaries — see the module header).
///
/// @stable-since: v0.2.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    return byte.buildAlloc(gpa, h);
}

/// Compile a HIR into a ro_data byte `Program` at comptime. A non-byte-lowerable HIR
/// (`\X`/`\b`) becomes a `@compileError`.
///
/// @stable-since: v0.2.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    return byte.buildComptime(h);
}

/// @stable-since: v0.2.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    byte.freeProgram(gpa, program);
}

// ── Scratch: one typed word buffer (comptime- and runtime-usable) ────────────────
// Identical in shape to the Pike VM's scratch — the byte program holds no side
// `ranges` array, so the carving depends only on instruction count and slot count.

/// Scratch storage word — the shared contract type, so one `[]Cell` buffer backs
/// every internal array and `auto`/callers forward the same buffer here.
pub const Cell = backend.Cell;

/// Top-bit tag distinguishing the two `Step` kinds packed into the work stack.
const STACK_TAG: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);

/// A priority-ordered set of NFA threads, deduplicated by `pc` via generation
/// stamping (clearing is O(1): bump `gen`).
const ThreadList = struct {
    pcs: []Cell,
    slots: []Cell,
    seen: []Cell,
    gen: usize = 0,
    n: usize = 0,
    sc: usize,

    fn fromParts(pcs: []Cell, slots: []Cell, seen: []Cell, sc: usize) ThreadList {
        @memset(seen, .{ .w = 0 });
        return .{ .pcs = pcs, .slots = slots, .seen = seen, .sc = sc };
    }
    fn clear(self: *ThreadList) void {
        self.n = 0;
        self.gen +%= 1;
    }
};

/// One unit of deferred work for the iterative epsilon closure (see `addThread`).
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

/// Per-search mutable state (caller-owned; see the contract). Carved from one
/// `[]Cell` buffer — same layout as the Pike VM's `Scratch`.
///
/// @stable-since: v0.2.0
pub const Scratch = struct {
    clist: ThreadList,
    n_list: ThreadList,
    entry_slots: []Cell,
    match_slots: []Cell,
    stack: []Cell,
    slot_count: usize,
    owned: ?[]Cell = null,

    pub const Buf = backend.Cell;

    /// Number of `Cell`s a buffer must hold for this program.
    ///
    /// @stable-since: v0.2.0
    pub fn bufferLen(program: *const Program) usize {
        const cap = program.insts.len;
        const sc = program.slot_count;
        return 6 * cap + 2 * cap * sc + 2 * sc;
    }

    /// Carve a caller-provided `[]Cell` buffer (≥ `bufferLen`). Works at comptime and
    /// runtime; a short buffer returns `error.BufferTooSmall`.
    ///
    /// @stable-since: v0.2.0
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

    /// Allocator-backed init: grab one `[]Cell` and carve it (freed by `deinit`).
    ///
    /// @stable-since: v0.2.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        const buf = try gpa.alloc(Cell, bufferLen(program));
        var s = initBuffer(buf, program) catch unreachable;
        s.owned = buf;
        return s;
    }

    /// @stable-since: v0.2.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        if (self.owned) |buf| gpa.free(buf);
        self.owned = null;
    }

    /// @stable-since: v0.2.0
    pub fn reset(self: *Scratch) void {
        self.clist.clear();
        self.n_list.clear();
    }
};

// ── Epsilon closure ──────────────────────────────────────────────────────────────

/// Add a thread at `pc0` to `list`, following epsilon transitions
/// (split/jmp/save/assertion) and appending consuming (`byte_range`) / `match`
/// instructions. Iterative over the caller-owned `stack` (no recursion), dedup by
/// `pc` via `seen`/`gen` — identical in structure to the Pike VM's closure, so
/// leftmost-first priority and capture save/restore nesting are preserved.
fn addThread(program: *const Program, list: *ThreadList, pc0: u32, slots: []Cell, sp: usize, input: []const u8, stack: []Cell) void {
    var top: usize = 0;
    pushVisit(stack, &top, pc0);
    while (top > 0) {
        switch (popStep(stack, &top)) {
            .restore => |r| if (r.slot < slots.len) {
                slots[r.slot] = .{ .slot = r.old };
            },
            .visit => |start_pc| {
                var pc = start_pc;
                follow: while (true) {
                    if (list.seen[pc].w == list.gen) break :follow;
                    list.seen[pc] = .{ .w = list.gen };
                    switch (program.insts[pc]) {
                        .jmp => |t| pc = t,
                        .split => |s| {
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
                            if (!byte.assertionHolds(kind, input, sp)) break :follow;
                            pc += 1;
                        },
                        else => {
                            // Consuming (`byte_range`) or `match`: snapshot slots.
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

// ── The VM ───────────────────────────────────────────────────────────────────────

fn run(program: *const Program, sc: *Scratch, input: []const u8, opts: SearchOptions) ?[]const Cell {
    var c_list = &sc.clist;
    var n_list = &sc.n_list;
    c_list.clear();
    n_list.clear();
    @memset(sc.entry_slots, .{ .slot = null });

    var matched = false;
    var sp = opts.start;
    // Seed a fresh start thread only at code-point-aligned offsets — the byte program steps one
    // byte per iteration, but an unanchored match must not *begin* at an interior byte of a valid
    // multi-byte code point (a zero-width pattern like `\b`/`()` would otherwise report a spurious
    // mid-code-point match, disagreeing with the Pike VM). `next_seed` tracks the next boundary.
    var next_seed = opts.start;

    while (true) {
        if (!matched and (!opts.anchored or sp == opts.start) and sp == next_seed) {
            addThread(program, c_list, 0, sc.entry_slots, sp, input, sc.stack);
        }
        if (sp == next_seed) next_seed += nfa.decodeAt(input, sp).len;
        const at_end = sp >= input.len;
        // Keep scanning even with an empty list mid-input on an unanchored search —
        // the next byte seeds a fresh start thread (needed when a leading assertion
        // like `^` fails here, and for dead-on-invalid resync past a bad byte).
        if (c_list.n == 0 and (matched or opts.anchored or at_end)) break;

        const b: u8 = if (at_end) 0 else input[sp];

        n_list.clear();
        var i: usize = 0;
        while (i < c_list.n) : (i += 1) {
            const t_pc: u32 = @intCast(c_list.pcs[i].w);
            const t_slots = c_list.slots[i * c_list.sc .. i * c_list.sc + c_list.sc];
            switch (program.insts[t_pc]) {
                .byte_range => |r| if (!at_end and r.range.contains(b))
                    addThread(program, n_list, r.next, t_slots, sp + 1, input, sc.stack),
                .match => {
                    @memcpy(sc.match_slots, t_slots);
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
        sp += 1; // one byte per step
    }
    return if (matched) sc.match_slots[0..sc.slot_count] else null;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.2.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return run(program, scratch, input, opts) != null;
}

/// @stable-since: v0.2.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    const slots = run(program, scratch, input, opts) orelse return null;
    return .{ .start = slots[0].slot.?, .end = slots[1].slot.? };
}

/// @stable-since: v0.2.0
pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots_out: []?usize, opts: SearchOptions) ?Match {
    const slots = run(program, scratch, input, opts) orelse return null;
    const k = @min(slots_out.len, slots.len);
    var i: usize = 0;
    while (i < k) : (i += 1) slots_out[i] = slots[i].slot;
    return .{ .start = slots[0].slot.?, .end = slots[1].slot.? };
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests — end-to-end coverage through Engine(BytePikeVM)
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const compile = @import("core").compile;
const E = backend.Engine(@This());

const Compiled = struct {
    program: Program,
    meta: backend.Meta,
    scratch: Scratch,

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var diag: compile.Diagnostic = .{};
        const ast = compile.parse(gpa, pattern, &diag) catch |e| {
            std.debug.print("parse failed for \"{s}\": {s}\n", .{ pattern, @errorName(e) });
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
        std.debug.print("\"{s}\" unexpectedly matched \"{s}\"\n", .{ pattern, m.slice(input) });
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

test "BytePikeVM satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "literals, leftmost, none" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("abc", "abXabc", "abc");
    try expectNoMatch("abc", "ab");
    try expectFind("a", "banana", "a");
    try expectSpan("a", "banana", 1, 2);
    try expectSpan("", "abc", 0, 0);
}

test "dot / classes / shorthands" {
    try expectFind("a.c", "axc", "axc");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("(?s)a.c", "a\nc", "a\nc");
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("[^a-z]+", "abXY12cd", "XY12");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "  foo_bar! ", "foo_bar");
    try expectFind("\\D+", "12ab34", "ab");
}

test "alternation leftmost-first + quantifiers" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("a|ab", "ab", "a");
    try expectFind("ab|a", "ab", "ab");
    try expectFind("foo|foobar", "foobar", "foo");
    try expectFind("ab*", "abbbc", "abbb");
    try expectNoMatch("ab+", "ac");
    try expectFind("a.*?c", "abXcYc", "abXc");
    try expectFind("a{2,4}", "aaaaaa", "aaaa");
    try expectFind("(ab){2,3}", "ababab", "ababab");
}

test "anchors (byte-evaluable)" {
    try expectFind("^abc", "abcdef", "abc");
    try expectNoMatch("^abc", "xabc");
    try expectFind("abc$", "xxabc", "abc");
    try expectNoMatch("^abc$", "abc\n");
    try expectFind("(?m)^line2", "line1\nline2\nline3", "line2");
}

test "multi-byte UTF-8 by byte stepping" {
    try expectFind("héllo", "say héllo!", "héllo");
    try expectFind("\\w+", "héllo, wörld", "héllo");
    try expectFind("\\p{L}+", "abc123", "abc");
    try expectFind("\\p{Nd}+", "x٤٥٦y", "٤٥٦");
    try expectFind("\\p{Script=Greek}+", "abcαβγdef", "αβγ");
    try expectSpan("é", "aé", 1, 3); // byte offsets
    try expectFind("é{2,3}", "xééééy", "ééé");
    try expectFind("(?i)abc", "XYZABCxyz", "ABC");
}

test "invalid UTF-8 input is dead-on-invalid (a match never spans a bad byte)" {
    // 0xFF is never a valid UTF-8 byte; `.` (lowered to byte sequences) cannot match
    // it, and the scan resyncs past it.
    try expectFind("a.c", "a\xFFc abc", "abc"); // skips the bad byte, finds later
    try expectNoMatch("^.$", "\xFF"); // a lone invalid byte is not one "any" char
}

test "captures and named groups" {
    var re = try Compiled.init("(\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    var slots: [8]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "x 2026-06-07 y", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("2026-06-07", c.match().slice("x 2026-06-07 y"));
    try testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try testing.expectEqualStrings("06", c.groupSlice(2).?);

    var re2 = try Compiled.init("(?<y>\\d+)-(?<m>\\d+)");
    defer re2.deinit();
    const names = [_]?[]const u8{ null, "y", "m" };
    re2.meta.group_names = &names;
    var slots2: [6]?usize = undefined;
    const c2 = E.captures(&re2.program, &re2.scratch, "2026-06", &slots2, re2.meta, .{}).?;
    try testing.expectEqualStrings("2026", c2.namedSlice("y").?);
    try testing.expectEqualStrings("06", c2.namedSlice("m").?);
}

test "agnostic ops: findAll / count / split / replaceAll" {
    var re = try Compiled.init("\\d+");
    defer re.deinit();
    const input = "a12b345c6";
    var it = E.findAll(&re.program, &re.scratch, input, .{});
    try testing.expectEqualStrings("12", it.next().?.slice(input));
    try testing.expectEqualStrings("345", it.next().?.slice(input));
    try testing.expectEqualStrings("6", it.next().?.slice(input));
    try testing.expect(it.next() == null);

    var re2 = try Compiled.init("(\\w+)@(\\w+)");
    defer re2.deinit();
    var slots: [6]?usize = undefined;
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&re2.program, &re2.scratch, "from a@b to c@d", "$2.$1", &slots, re2.meta, &w);
    try testing.expectEqualStrings("from b.a to d.c", w.buffered());
}

test "no catastrophic backtracking: (a*)*b" {
    var re = try Compiled.init("(a*)*b");
    defer re.deinit();
    var ibuf: [40]u8 = undefined;
    @memset(&ibuf, 'a');
    try testing.expect(!re.isMatch(&ibuf));
    try testing.expect(re.isMatch("aaaab"));
}

test "scratch reuse without stale state" {
    var re = try Compiled.init("(a+)(b+)");
    defer re.deinit();
    var slots: [6]?usize = undefined;
    const c1 = E.captures(&re.program, &re.scratch, "aabb", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("aa", c1.groupSlice(1).?);
    try testing.expect(E.captures(&re.program, &re.scratch, "xyz", &slots, re.meta, .{}) == null);
    const c3 = E.captures(&re.program, &re.scratch, "ab", &slots, re.meta, .{}).?;
    try testing.expectEqualStrings("a", c3.groupSlice(1).?);
}

test "refuses \\X (grapheme, not byte-lowerable)" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "\\X", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    try testing.expectError(error.Unsupported, buildAlloc(gpa, h, .{}));
}

test "ASCII \\b/\\B: the byte Pike VM evaluates word boundaries (via assertionHolds)" {
    // `\b`/`\B` now lower to a byte `assertion`; the byte Pike VM evaluates them as ASCII word
    // boundaries (exact for ASCII input — the only input the dispatcher routes to a byte engine).
    try expectFind("\\bcat\\b", "the cat sat", "cat");
    try expectNoMatch("\\bcat\\b", "category"); // 'cat' here has no trailing boundary
    try expectNoMatch("\\bcat\\b", "scat"); // no leading boundary
    try expectFind("\\b\\w+\\b", "  hello, world", "hello");
    try expectFind("\\Bcat\\B", "locator", "cat"); // \B holds between word bytes
    try expectFind("s\\b", "cats dogs", "s"); // \b at a word→non-word edge
    try expectFind("\\bword\\b", "a word.", "word"); // punctuation is a boundary
    try expectFind("\\bx", "x", "x"); // \b at start of input
    try expectFind("x\\b", "x", "x"); // \b at end of input
    try expectNoMatch("foo\\bbar", "foobar"); // no boundary mid-word
}

test "full match pipeline runs at COMPTIME via a buffer scratch" {
    const got = comptime blk: {
        @setEvalBranchQuota(3_000_000);
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

test "runtime buffer scratch (no allocator)" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "[a-z]+[0-9]+", &diag); // ASCII classes → compact byte program
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);

    var stack_buf: [1024]Cell = undefined;
    var sc = try Scratch.initBuffer(&stack_buf, &program);
    try testing.expectEqualStrings("abc123", E.find(&program, &sc, "??abc123!!", .{}).?.slice("??abc123!!"));
    var tiny: [4]Cell = undefined;
    try testing.expectError(error.BufferTooSmall, Scratch.initBuffer(&tiny, &program));
}

test {
    testing.refAllDecls(@This());
}
