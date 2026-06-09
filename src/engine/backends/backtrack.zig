//! Bounded backtracking backend — depth-first NFA search with memoization.
//!
//! Executes the *same* `engine/nfa.zig` program as the Pike VM, but depth-first:
//! it follows the highest-priority branch first and backtracks on failure, so it
//! is naturally leftmost-first and reports captures with the same semantics as the
//! Pike VM (the shared program guarantees bit-for-bit agreement). A `(pc, sp)`
//! **visited set** memoizes dead ends, which is what keeps it linear-time
//! (`O(program × input)`) and kills catastrophic backtracking — `(a*)*b` does not
//! explode here.
//!
//! Why have it at all when the Pike VM is also linear? Backtracking has smaller
//! constants on the common case (it explores one path at a time instead of a whole
//! thread set), so `auto` prefers it for **small inputs**, falling back to the
//! Pike VM for large ones. That is the "switch on the input" half of the dispatcher
//! — and the reason backtracking is *bounded*: its visited set is sized
//! `program × (input+1)` bits, so memory grows with the input. A heap `Scratch`
//! grows it on demand; a fixed-buffer `Scratch` has a hard ceiling (the "with
//! limits" path). `fits()` reports whether a given input is within a buffer's
//! ceiling, so `auto` only ever routes inputs that fit.
//!
//! Comptime + runtime: `Program` is the shared NFA program (ro_data or heap), and
//! the `Scratch` carves one `[]Cell` buffer, so the same `initBuffer` runs at
//! comptime (tiny inputs always fit a modest buffer) and at runtime.

const std = @import("std");

const backend = @import("../backend.zig");
const hir = @import("../../core/hir.zig");
const nfa = @import("../nfa.zig");

const Match = backend.Match;
const SearchOptions = backend.SearchOptions;
const Caps = backend.Caps;
const BuildError = backend.BuildError;
const Cell = backend.Cell;

const WORD_BITS: usize = @bitSizeOf(usize);

/// Input length a default fixed buffer (`bufferLen`) is sized to support. A bigger
/// buffer raises the ceiling automatically (`initBuffer` gives all slack to the
/// visited set); `auto`/heap raise it as needed.
const DEFAULT_MAX_INPUT: usize = 64;

// ── Contract surface ────────────────────────────────────────────────────────────

/// @stable-since: v0.1.0
pub const caps = Caps{ .captures = true, .stateless = false, .grapheme = true };
/// @stable-since: v0.1.0
pub const Options = struct {};

/// Same compiled NFA the Pike VM uses (from the shared `nfa` module).
pub const Inst = nfa.Inst;
pub const Program = nfa.Program;

/// @stable-since: v0.1.0
pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: Options) BuildError!Program {
    return nfa.buildAlloc(gpa, h);
}
/// @stable-since: v0.1.0
pub fn buildComptime(comptime h: hir.Hir, comptime _: Options) Program {
    return nfa.buildComptime(h);
}
/// @stable-since: v0.1.0
pub fn freeProgram(gpa: std.mem.Allocator, program: *Program) void {
    nfa.freeProgram(gpa, program);
}

/// Words a visited bitset needs for `program × (input+1)` states.
fn visitedWords(nprog: usize, n: usize) usize {
    const bits = nprog * (n + 1);
    return (bits + WORD_BITS - 1) / WORD_BITS;
}

// ── Scratch ──────────────────────────────────────────────────────────────────────

/// Per-search state: working + winning capture slots, and the input-sized visited
/// bitset. Carved from one `[]Cell` buffer. A heap `Scratch` (via `init`) grows the
/// visited set as inputs demand; a buffer `Scratch` (via `initBuffer`) has a fixed
/// ceiling — `fits()` tells you (and `auto`) whether an input is within it.
///
/// @stable-since: v0.1.0
pub const Scratch = struct {
    /// Buffer element type for the `initBuffer`/comptime convention (see backend.zig).
    pub const Buf = Cell;

    slots: []Cell, // .slot — working captures
    match_slots: []Cell, // .slot — winning captures
    visited: []Cell, // .w   — (pc,sp) memo bitset (input-sized)
    nprog: u32,
    slot_count: u32,
    gpa: ?std.mem.Allocator = null, // non-null ⇒ heap, visited may grow
    owned: ?[]Cell = null, // slots+match buffer (heap)
    owned_visited: ?[]Cell = null, // grown visited (heap)

    /// Default fixed-buffer size: slots + a visited budget for inputs up to
    /// `DEFAULT_MAX_INPUT`. A larger buffer raises the input ceiling automatically.
    ///
    /// @stable-since: v0.1.0
    pub fn bufferLen(program: *const Program) usize {
        const sc = program.slot_count;
        return 2 * sc + visitedWords(program.insts.len, DEFAULT_MAX_INPUT);
    }

    /// Carve a caller `[]Cell` buffer: slots, match slots, and the remainder as the
    /// visited budget. Works at comptime and runtime. The visited ceiling is
    /// `(buffer - 2*slot_count) words` — `fits()` checks an input against it.
    ///
    /// @stable-since: v0.1.0
    pub fn initBuffer(buf: []Cell, program: *const Program) backend.ScratchError!Scratch {
        const sc = program.slot_count;
        var cur = backend.Carver{ .buf = buf };
        const slots = try cur.take(sc);
        const match = try cur.take(sc);
        const visited = buf[cur.off..]; // all slack → visited
        return .{
            .slots = slots,
            .match_slots = match,
            .visited = visited,
            .nprog = @intCast(program.insts.len),
            .slot_count = @intCast(sc),
        };
    }

    /// Allocator-backed: slots up front; the visited set is grown lazily per search
    /// so any input length works (memory ∝ program × input).
    ///
    /// @stable-since: v0.1.0
    pub fn init(gpa: std.mem.Allocator, program: *const Program) std.mem.Allocator.Error!Scratch {
        const sc = program.slot_count;
        const buf = try gpa.alloc(Cell, 2 * sc);
        return .{
            .slots = buf[0..sc],
            .match_slots = buf[sc .. 2 * sc],
            .visited = &.{},
            .nprog = @intCast(program.insts.len),
            .slot_count = @intCast(sc),
            .gpa = gpa,
            .owned = buf,
        };
    }

    /// @stable-since: v0.1.0
    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        if (self.owned) |b| gpa.free(b);
        if (self.owned_visited) |b| gpa.free(b);
        self.owned = null;
        self.owned_visited = null;
        self.visited = &.{};
    }

    /// @stable-since: v0.1.0
    pub fn reset(self: *Scratch) void {
        _ = self; // `run` clears the visited prefix per search
    }

    /// Grow the visited set to `words` (heap only); a fixed buffer that is too small
    /// yields `error.BufferTooSmall`.
    fn ensureVisited(self: *Scratch, words: usize) backend.ScratchError!void {
        if (self.visited.len >= words) return;
        const g = self.gpa orelse return error.BufferTooSmall;
        const newbuf = try g.alloc(Cell, words);
        if (self.owned_visited) |ov| g.free(ov);
        self.owned_visited = newbuf;
        self.visited = newbuf;
    }
};

/// Whether `input` is within this scratch's visited ceiling. A heap scratch always
/// fits (it grows); a buffer scratch fits iff the input's bitset fits the slack.
/// `auto` consults this before routing to the backtracker.
///
/// @stable-since: v0.1.0
pub fn fits(program: *const Program, scratch: *const Scratch, input: []const u8) bool {
    if (scratch.gpa != null) return true;
    return visitedWords(program.insts.len, input.len) <= scratch.visited.len;
}

// ── The backtracker ──────────────────────────────────────────────────────────────

const Ctx = struct {
    program: *const Program,
    input: []const u8,
    visited: []Cell,
    slots: []Cell,
    match_slots: []Cell,
    stride: usize, // input.len + 1
};

/// Test-and-set the `(pc, sp)` memo bit; returns whether it was already set.
fn seen(ctx: *Ctx, pc: u32, sp: usize) bool {
    const idx = @as(usize, pc) * ctx.stride + sp;
    const w = idx / WORD_BITS;
    const bit = @as(usize, 1) << @intCast(idx % WORD_BITS);
    const was = (ctx.visited[w].w & bit) != 0;
    ctx.visited[w].w |= bit;
    return was;
}

/// Depth-first match from `(pc0, sp0)`. Returns whether a match was found; on the
/// first (highest-priority) match it snapshots captures into `match_slots`. The
/// `seen` memo prunes already-explored states, giving linear time and termination
/// (an empty-width cycle revisits a `(pc, sp)` and is cut). The while-loop carries
/// linear chains (jmp/char/assert and a split's primary arm) without recursing, so
/// recursion depth tracks branch/save nesting, not input length on straight runs.
fn backtrack(ctx: *Ctx, pc0: u32, sp0: usize) bool {
    var pc = pc0;
    var sp = sp0;
    while (true) {
        if (seen(ctx, pc, sp)) return false; // already explored ⇒ same (failing) outcome
        switch (ctx.program.insts[pc]) {
            .match => {
                @memcpy(ctx.match_slots, ctx.slots);
                return true;
            },
            .char => |ch| {
                if (sp >= ctx.input.len) return false;
                const d = nfa.decodeAt(ctx.input, sp);
                if (!d.valid or d.cp != ch) return false; // dead-on-invalid
                pc += 1;
                sp += d.len;
            },
            .range => |r| {
                if (sp >= ctx.input.len) return false;
                const d = nfa.decodeAt(ctx.input, sp);
                if (!d.valid or !nfa.inRanges(ctx.program.ranges[r.start .. r.start + r.len], d.cp)) return false;
                pc += 1;
                sp += d.len;
            },
            .any => |a| {
                if (sp >= ctx.input.len) return false;
                const d = nfa.decodeAt(ctx.input, sp);
                if (!d.valid or !(a.dot_all or d.cp != '\n')) return false; // `.` never matches an invalid byte
                pc += 1;
                sp += d.len;
            },
            .grapheme => {
                // `\X`: consume one whole extended grapheme cluster. Variable width —
                // the depth-first backtracker advances `sp` by the cluster length,
                // which the breadth-first Pike VM cannot do (hence backtrack-only).
                if (sp >= ctx.input.len) return false; // no cluster to consume
                pc += 1;
                sp += nfa.graphemeLenAt(ctx.input, sp);
            },
            .jmp => |t| pc = t,
            .assertion => |k| {
                if (!nfa.assertionHolds(k, ctx.input, sp)) return false;
                pc += 1;
            },
            .split => |s| {
                // Primary arm first (higher priority); on failure, fall through to
                // the secondary arm as the loop's tail.
                if (backtrack(ctx, s.a, sp)) return true;
                pc = s.b;
            },
            .save => |slot| {
                if (slot < ctx.slots.len) {
                    const old = ctx.slots[slot].slot;
                    ctx.slots[slot] = .{ .slot = sp };
                    if (backtrack(ctx, pc + 1, sp)) return true;
                    ctx.slots[slot] = .{ .slot = old }; // undo on backtrack
                    return false;
                }
                pc += 1;
            },
        }
    }
}

fn run(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    const words = visitedWords(program.insts.len, input.len);
    scratch.ensureVisited(words) catch
        @panic("ezi_gex backtrack: input exceeds buffer-backed scratch capacity; enlarge the buffer, use init(), or let `auto` route it");
    @memset(scratch.visited[0..words], .{ .w = 0 });

    var ctx = Ctx{
        .program = program,
        .input = input,
        .visited = scratch.visited,
        .slots = scratch.slots,
        .match_slots = scratch.match_slots,
        .stride = input.len + 1,
    };
    // Leftmost: try start positions in order; the visited memo is shared across
    // starts (a `(pc, sp)` failure is start-independent), so the whole scan stays
    // O(program × input), not O(program × input²).
    var start = opts.start;
    while (start <= input.len) : (start += 1) {
        @memset(scratch.slots, .{ .slot = null });
        if (backtrack(&ctx, 0, start)) return true;
        if (opts.anchored) break;
    }
    return false;
}

// ── Contract: matching entry points ──────────────────────────────────────────────

/// @stable-since: v0.1.0
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
    return run(program, scratch, input, opts);
}

/// @stable-since: v0.1.0
pub fn search(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
    if (!run(program, scratch, input, opts)) return null;
    return .{ .start = scratch.match_slots[0].slot.?, .end = scratch.match_slots[1].slot.? };
}

/// @stable-since: v0.1.0
pub fn searchCaptures(program: *const Program, scratch: *Scratch, input: []const u8, slots_out: []?usize, opts: SearchOptions) ?Match {
    if (!run(program, scratch, input, opts)) return null;
    const k = @min(slots_out.len, scratch.match_slots.len);
    var i: usize = 0;
    while (i < k) : (i += 1) slots_out[i] = scratch.match_slots[i].slot;
    return .{ .start = scratch.match_slots[0].slot.?, .end = scratch.match_slots[1].slot.? };
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

    fn init(pattern: []const u8) !Compiled {
        const gpa = testing.allocator;
        var diag: compile.Diagnostic = .{};
        const ast = try compile.parse(gpa, pattern, &diag);
        defer ast.deinit(gpa);
        const h = try hir.buildAlloc(gpa, ast, .{});
        defer hir.deinitHir(gpa, h);
        var program = try buildAlloc(gpa, h, .{});
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

test "backtrack satisfies the backend contract" {
    comptime backend.verifyBackend(@This());
}

test "literals, classes, dot" {
    try expectFind("abc", "xxabcyy", "abc");
    try expectFind("a.c", "a c", "a c");
    try expectNoMatch("a.c", "a\nc");
    try expectFind("[a-z]+", "ABCdefGHI", "def");
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "héllo, wörld", "héllo"); // unicode
}

test "alternation leftmost-first + quantifiers" {
    try expectFind("cat|dog", "i have a dog", "dog");
    try expectFind("a|ab", "ab", "a");
    try expectFind("ab|a", "ab", "ab");
    try expectFind("ab*", "abbbc", "abbb");
    try expectFind("a.*?c", "abXcYc", "abXc"); // lazy
    try expectFind("a{2,4}", "aaaaaa", "aaaa");
    try expectFind("(ab){2,3}", "ababab", "ababab");
}

test "anchors and word boundaries" {
    try expectFind("^abc", "abcdef", "abc");
    try expectNoMatch("^abc", "xabc");
    try expectFind("abc$", "xxabc", "abc");
    try expectSpan("\\bcat\\b", "a cat!", 2, 5);
    try expectNoMatch("\\bcat\\b", "category");
}

fn expectSpan(pattern: []const u8, input: []const u8, start: usize, end: usize) !void {
    var re = try Compiled.init(pattern);
    defer re.deinit();
    const m = re.find(input) orelse return error.NoMatch;
    try testing.expectEqual(start, m.start);
    try testing.expectEqual(end, m.end);
}

test "captures + named groups" {
    var re = try Compiled.init("(\\d{4})-(\\d{2})-(\\d{2})");
    defer re.deinit();
    var slots: [8]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "x 2026-06-07 y", &slots, .{ .capture_count = 3 }, .{}).?;
    try testing.expectEqualStrings("2026-06-07", c.match().slice("x 2026-06-07 y"));
    try testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try testing.expectEqualStrings("06", c.groupSlice(2).?);
    try testing.expectEqualStrings("07", c.groupSlice(3).?);
}

test "optional group reads null when it does not participate" {
    var re = try Compiled.init("a(b)?c");
    defer re.deinit();
    var slots: [4]?usize = undefined;
    const c = E.captures(&re.program, &re.scratch, "ac", &slots, .{ .capture_count = 1 }, .{}).?;
    try testing.expect(c.group(1) == null);
    const c2 = E.captures(&re.program, &re.scratch, "abc", &slots, .{ .capture_count = 1 }, .{}).?;
    try testing.expectEqualStrings("b", c2.groupSlice(1).?);
}

test "NO catastrophic backtracking: (a*)*b memoized" {
    var re = try Compiled.init("(a*)*b");
    defer re.deinit();
    var ibuf: [120]u8 = undefined; // would be exponential without the (pc,sp) memo
    @memset(&ibuf, 'a');
    try testing.expect(re.find(&ibuf) == null); // no 'b' → no match, returns fast
    var ibuf2: [32]u8 = undefined;
    @memset(&ibuf2, 'a');
    ibuf2[31] = 'b';
    try testing.expect(re.find(&ibuf2) != null);
}

test "agnostic ops: findAll / count / replaceAll" {
    var re = try Compiled.init("(\\w+)@(\\w+)");
    defer re.deinit();
    var slots: [6]?usize = undefined;
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&re.program, &re.scratch, "from a@b to c@d", "$2.$1", &slots, .{ .capture_count = 2 }, &w);
    try testing.expectEqualStrings("from b.a to d.c", w.buffered());
}

test "runtime buffer scratch + fits()" {
    const gpa = testing.allocator;
    var diag: compile.Diagnostic = .{};
    const ast = try compile.parse(gpa, "[a-z]+\\d+", &diag);
    defer ast.deinit(gpa);
    const h = try hir.buildAlloc(gpa, ast, .{});
    defer hir.deinitHir(gpa, h);
    var program = try buildAlloc(gpa, h, .{});
    defer freeProgram(gpa, &program);

    var buf: [4096]Cell = undefined;
    var sc = try Scratch.initBuffer(&buf, &program);
    try testing.expect(fits(&program, &sc, "??abc123!!"));
    try testing.expectEqualStrings("abc123", E.find(&program, &sc, "??abc123!!", .{}).?.slice("??abc123!!"));

    // A buffer with only enough room for the slot arrays (no visited slack) fits no
    // non-empty input — `auto` would route such an input to the Pike VM instead.
    var slots_only: [4]Cell = undefined; // slot_count = 2 → slots(2) + match(2)
    var sc2 = try Scratch.initBuffer(&slots_only, &program);
    try testing.expect(!fits(&program, &sc2, "x"));
}

test "comptime captures via buffer scratch" {
    const ok = comptime blk: {
        @setEvalBranchQuota(3_000_000);
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
            @compileError("no captures at comptime");
        break :blk std.mem.eql(u8, c.groupSlice(1).?, "user") and std.mem.eql(u8, c.groupSlice(2).?, "host");
    };
    try testing.expect(ok);
}

test {
    testing.refAllDecls(@This());
}
