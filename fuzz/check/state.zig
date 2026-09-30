//! Scratch-state check. Every built-in keeps mutable per-search state in the caller's
//! Scratch (generation stamps, lazy-DFA caches, `auto`'s input-derived verdicts). The
//! other groups always use a FRESH scratch, so none of them can see state leaking between
//! searches — the class of 2b48f18 (a `(ptr,len)`-keyed ASCII cache served a stale verdict
//! after the caller refilled the same buffer). Here one scratch lives through a script.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;
const Summary = common.Summary;

pub const max_hay = 64;
pub const steps = 8;

const mutation_bytes = "abAB1 \n_\xC3\xA9\xE2\x84\xAA\xFF\x80\xE6";

/// A second regex, driven on its OWN long-lived scratch between the main script's ops, to
/// catch state shared across compiled regexes (globals, static caches).
const other_patterns = [_][]const u8{ "\\b\\w+\\b", "a|ab", "(?i)k", "\\p{L}+", "[^a]" };

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var ibuf: [max_hay]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const case: Case = .{ .check = .state, .pattern = p.pattern, .input = input, .opt = p.opt, .seed = smith.value(u64) };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.input.len > max_hay) return error.BadCase;
    common.noteRun(.state, true);
    inline for (common.all_backends) |B| try script(B, gpa, case);
}

fn doOp(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), sc: *gex.Compiled(B).Scratch, op: u8, in: []const u8, so: gex.SearchOptions, k: usize) !Summary {
    var s: Summary = .{};
    var slots: [96]?usize = undefined;
    const ns = @min(re.slotCount(), slots.len);
    switch (op) {
        0 => s.pushMatch(re.findAt(sc, in, so)),
        1 => s.push(@intFromBool(re.isMatchAt(sc, in, so))),
        2 => if (comptime B.caps.captures) {
            if (re.capturesAt(sc, slots[0..ns], in, so)) |_| {
                for (slots[0..ns]) |x| s.push(x orelse common.NONE);
            } else s.push(common.NONE);
        } else unreachable,
        3 => s.push(re.count(sc, in)),
        4 => {
            var it = re.findAll(sc, in);
            var j: usize = 0;
            while (it.next()) |m| : (j += 1) {
                if (j == 32) break;
                s.pushMatch(m);
            }
        },
        5 => if (comptime B.caps.captures) {
            const out = try re.replaceAllAlloc(gpa, sc, in, "<$0>", slots[0..ns]);
            defer gpa.free(out);
            s.push(out.len);
            s.push(@intCast(std.hash.Wyhash.hash(0, out)));
        } else unreachable,
        else => { // abandon a findAll after k matches
            var it = re.findAll(sc, in);
            var j: usize = 0;
            while (j < k) : (j += 1) s.pushMatch(it.next() orelse break);
        },
    }
    return s;
}

fn script(comptime B: type, gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    var built = try common.build(B, gpa, case.pattern, case.opt);
    if (built != .ok) return if (built == .skip) common.noteSkipped(.state, B) else {};
    const re = &built.ok;
    defer re.deinit();
    var oracle_b = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (oracle_b != .ok) return;
    const oracle = &oracle_b.ok;
    defer oracle.deinit();
    common.noteCompared(.state, B);

    const Re = @TypeOf(re.*);
    var heap = try re.initScratch(gpa);
    defer heap.deinit(gpa);
    const has_buf = comptime Re.Scratch.Buf != void;
    const cells: []Re.Scratch.Buf = if (has_buf) try gpa.alloc(Re.Scratch.Buf, re.scratchBufferLen()) else &.{};
    defer if (has_buf) gpa.free(cells);
    var buffered: Re.Scratch = if (has_buf) try re.initScratchBuffer(cells) else undefined;

    const other_pat = other_patterns[case.seed % other_patterns.len];
    var other_b = try common.build(B, gpa, other_pat, 0);
    defer if (other_b == .ok) other_b.ok.deinit();
    var other_ob = try common.build(gex.backends.pikevm, gpa, other_pat, 0);
    defer if (other_ob == .ok) other_ob.ok.deinit();
    const have_other = other_b == .ok and other_ob == .ok;
    var other_sc = if (have_other) try other_b.ok.initScratch(gpa) else undefined;
    defer if (have_other) other_sc.deinit(gpa);

    var hay_a: [max_hay]u8 = undefined;
    var hay_b: [max_hay]u8 = undefined;
    @memcpy(hay_a[0..case.input.len], case.input);
    var cur: []u8 = hay_a[0..case.input.len];
    var prev: ?[]const u8 = null;
    var prng = std.Random.DefaultPrng.init(case.seed);
    const r = prng.random();

    for (0..steps) |step| {
        const move = r.uintLessThan(u8, 5);
        switch (move) {
            0 => {
                const n = r.uintAtMost(usize, max_hay);
                const base: []u8 = if (@intFromPtr(cur.ptr) == @intFromPtr(&hay_a)) &hay_a else &hay_b;
                for (base[0..n]) |*b| b.* = mutation_bytes[r.uintLessThan(usize, mutation_bytes.len)];
                cur = base[0..n];
            },
            1 => if (cur.len > 0) {
                const k = 1 + r.uintLessThan(usize, cur.len);
                for (0..k) |_| cur[r.uintLessThan(usize, cur.len)] = mutation_bytes[r.uintLessThan(usize, mutation_bytes.len)];
            },
            2 => cur = cur[0..r.uintAtMost(usize, cur.len)],
            3 => {
                const other: []u8 = if (@intFromPtr(cur.ptr) == @intFromPtr(&hay_a)) &hay_b else &hay_a;
                @memcpy(other[0..cur.len], cur);
                cur = other[0..cur.len];
            },
            else => {},
        }
        const unchanged = move == 4 and prev != null and prev.?.ptr == cur.ptr and prev.?.len == cur.len;
        var op = r.uintLessThan(u8, 7);
        if (!B.caps.captures and (op == 2 or op == 5)) op = 0;
        const start = r.uintAtMost(usize, cur.len);
        var so: gex.SearchOptions = .{
            .start = start,
            .anchored = r.boolean(),
            .span_end = if (r.uintLessThan(u8, 4) == 0) start + r.uintAtMost(usize, cur.len - start) else null,
        };
        const k = r.uintAtMost(usize, 3);

        var osc = try oracle.initScratch(gpa);
        defer osc.deinit(gpa);
        const want = try doOp(gex.backends.pikevm, gpa, oracle, &osc, op, cur, so, k);

        so.same_input = unchanged and r.boolean(); // an HONEST assertion only
        const byte_ok = !common.isByteEngine(B) or common.byteEnginesSafe(gpa, case.pattern, cur);
        if (byte_ok) {
            const got = try doOp(B, gpa, re, &heap, op, cur, so, k);
            if (!got.eql(&want)) return report(B, "heap", case, step, move, op, cur, so, &want, &got);
            if (has_buf) {
                // A buffer-backed backtracker has a fixed visited-set ceiling; `fits` reports it
                // (exceeding it panics by contract). Other backends have no input ceiling.
                const fits = if (comptime B == gex.backends.backtrack) gex.backends.backtrack.fits(&re.program, &buffered.inner, cur) else true;
                if (fits) {
                    const gb = try doOp(B, gpa, re, &buffered, op, cur, so, k);
                    if (!gb.eql(&want)) return report(B, "buffer", case, step, move, op, cur, so, &want, &gb);
                }
            }
        }
        // Interleave the second regex on its own long-lived scratch.
        if (have_other and (!common.isByteEngine(B) or common.byteEnginesSafe(gpa, other_pat, cur))) {
            var fsc = try other_ob.ok.initScratch(gpa);
            defer fsc.deinit(gpa);
            const ow = try doOp(gex.backends.pikevm, gpa, &other_ob.ok, &fsc, 4, cur, .{}, 0);
            const og = try doOp(B, gpa, &other_b.ok, &other_sc, 4, cur, .{}, 0);
            if (!og.eql(&ow)) return report(B, "second-regex", case, step, move, 4, cur, .{}, &ow, &og);
        }
        prev = cur;
    }
}

fn report(comptime B: type, kind: []const u8, case: *const Case, step: usize, move: u8, op: u8, cur: []const u8, so: gex.SearchOptions, want: *const Summary, got: *const Summary) anyerror {
    std.debug.print("state ({s}, {s} scratch) on /{s}/: step {d} move {d} op {d} over \"{s}\" {any}\n  fresh pikevm: {any}\n  long-lived:   {any}\n", .{
        @typeName(B), kind, case.pattern, step, move, op, cur, so, want.v[0..want.n], got.v[0..got.n],
    });
    return error.StaleScratch;
}
