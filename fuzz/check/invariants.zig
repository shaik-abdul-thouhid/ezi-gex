//! Oracle-free invariants: laws every backend must satisfy on its own, independent of any
//! other engine. Because they need no oracle they hold for backends the differential can
//! only skip, and they pin the search API's contract (offsets, anchoring, span_end,
//! iteration resume_at) rather than a particular answer.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var ibuf: [input_gen.max_input_len]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const start = smith.index(input.len + 1);
    const span_end: ?usize = if (smith.valueRangeAtMost(u8, 0, 3) == 0) start + smith.index(input.len - start + 1) else null;
    const case: Case = .{ .check = .invariants, .pattern = p.pattern, .input = input, .opt = p.opt, .start = start, .anchored = smith.valueRangeAtMost(u8, 0, 1) == 0, .span_end = span_end };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.start > case.input.len) return error.BadCase;
    common.noteRun(.invariants, true);
    const byte_safe = common.byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (common.all_backends) |B| try laws(B, gpa, case, byte_safe);
}

fn fail(comptime B: type, case: *const Case, comptime what: []const u8, args: anytype, e: anyerror) anyerror {
    std.debug.print("invariant ({s}) on /{s}/: " ++ what ++ "\n", .{ @typeName(B), case.pattern } ++ args);
    return e;
}

fn matchEq(a: ?gex.Match, b: ?gex.Match) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.start == b.?.start and a.?.end == b.?.end;
}

fn isBoundary(s: []const u8, off: usize) bool {
    return off == 0 or off >= s.len or (s[off] & 0xC0) != 0x80;
}

fn laws(comptime B: type, gpa: std.mem.Allocator, case: *const Case, byte_safe: bool) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.invariants, B);
    var built = try common.build(B, gpa, case.pattern, case.opt);
    switch (built) {
        .ok => {},
        .invalid => return,
        .skip => return common.noteSkipped(.invariants, B),
    }
    const re = &built.ok;
    defer re.deinit();
    common.noteCompared(.invariants, B);
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var sc2 = try re.initScratch(gpa);
    defer sc2.deinit(gpa);
    const in = case.input;
    const so = case.searchOptions();

    // 1 ── isMatchAt == (findAt != null)
    const fa = re.findAt(&sc, in, so);
    if (re.isMatchAt(&sc, in, so) != (fa != null)) return fail(B, case, "isMatchAt != (findAt != null) at {any}", .{so}, error.IsMatchAtInconsistent);

    // 2 ── unanchored == first anchored success over scalar-stepped starts
    {
        var ua = so;
        ua.anchored = false;
        const u = re.findAt(&sc, in, ua);
        const end = if (so.span_end) |e| @min(e, in.len) else in.len;
        var first: ?gex.Match = null;
        var k = so.start;
        while (k <= end) {
            var a = ua;
            a.start = k;
            a.anchored = true;
            if (re.findAt(&sc, in, a)) |m| {
                first = m;
                break;
            }
            if (k == end) break;
            k += common.scalarLen(in[0..end], k);
        }
        if (!matchEq(u, first)) return fail(B, case, "unanchored {?any} != first anchored {?any} (start={d} span_end={?d})", .{ u, first, so.start, so.span_end }, error.UnanchoredNotFirstAnchored);
    }

    // 3 ── findAll resume_at consistency, monotonicity, count
    {
        var it = re.findAll(&sc, in);
        var prev: ?gex.Match = null;
        var n: usize = 0;
        while (it.next()) |m| : (n += 1) {
            if (n == 64) break;
            if (m.start > m.end or m.end > in.len) return fail(B, case, "findAll match [{d},{d}] out of range", .{ m.start, m.end }, error.FindAllRange);
            const resume_at = if (prev) |p| (if (p.end > p.start) p.end else p.end + common.scalarLen(in, p.end)) else 0;
            if (prev) |p| if (m.start < p.end) return fail(B, case, "findAll overlap [{d},{d}] after [{d},{d}]", .{ m.start, m.end, p.start, p.end }, error.FindAllOverlap);
            const want = if (resume_at <= in.len) re.findAt(&sc2, in, .{ .start = resume_at }) else null;
            if (!matchEq(want, m)) return fail(B, case, "findAll[{d}] = [{d},{d}] but findAt(resume_at={d}) = {?any}", .{ n, m.start, m.end, resume_at, want }, error.FindAllResume);
            prev = m;
        }
        if (n < 64) {
            const c = re.count(&sc2, in);
            if (c != n) return fail(B, case, "count {d} != findAll length {d}", .{ c, n }, error.CountMismatch);
            // The iteration also must not stop early: nothing left after the last resume_at point.
            if (prev) |p| {
                const resume_at = if (p.end > p.start) p.end else p.end + common.scalarLen(in, p.end);
                if (resume_at <= in.len) if (re.findAt(&sc2, in, .{ .start = resume_at })) |extra|
                    return fail(B, case, "findAll stopped but findAt(resume_at={d}) = [{d},{d}]", .{ resume_at, extra.start, extra.end }, error.FindAllStoppedEarly);
            }
        }
    }

    if (comptime !B.caps.captures) return;
    var slots: [96]?usize = undefined;
    const ns = re.slotCount();
    if (ns > slots.len) return;

    // 4 ── capture slots
    if (re.captures(&sc, slots[0..ns], in)) |_| {
        const f = re.find(&sc2, in) orelse return fail(B, case, "captures matched but find returned null", .{}, error.CaptureFindDisagree);
        if (slots[0] != f.start or slots[1] != f.end) return fail(B, case, "captures slot0 {?d}..{?d} != find [{d},{d}]", .{ slots[0], slots[1], f.start, f.end }, error.CaptureSpanMismatch);
        const valid = common.isValidUtf8(in);
        var g: usize = 1;
        while (2 * g + 1 < ns) : (g += 1) {
            const s = slots[2 * g] orelse continue;
            const e = slots[2 * g + 1] orelse return fail(B, case, "group {d} has a start but no end", .{g}, error.CaptureHalfSet);
            if (s > e or s < f.start or e > f.end) return fail(B, case, "group {d} [{d},{d}] outside group 0 [{d},{d}]", .{ g, s, e, f.start, f.end }, error.CaptureOutsideMatch);
            if (valid and (!isBoundary(in, s) or !isBoundary(in, e))) return fail(B, case, "group {d} [{d},{d}] splits a code point", .{ g, s, e }, error.CaptureMidCodePoint);
        }
    }

    // 5 ── replace / split reconstruction
    {
        const out = try re.replaceAllAlloc(gpa, &sc, in, "$0", slots[0..ns]);
        defer gpa.free(out);
        if (!std.mem.eql(u8, out, in)) return fail(B, case, "replaceAll(\"$0\") = \"{s}\" != input \"{s}\"", .{ out, in }, error.ReplaceIdentity);

        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        var pieces = re.split(&sc, in);
        var matches = re.findAll(&sc2, in);
        try rebuilt.appendSlice(gpa, pieces.next() orelse "");
        var guard: usize = 0;
        while (matches.next()) |m| {
            guard += 1;
            if (guard > 256) return;
            if (m.isEmpty()) continue;
            try rebuilt.appendSlice(gpa, in[m.start..m.end]);
            try rebuilt.appendSlice(gpa, pieces.next() orelse return fail(B, case, "split ran out of pieces", .{}, error.SplitPieces));
        }
        if (!std.mem.eql(u8, rebuilt.items, in)) return fail(B, case, "split ⧺ matches = \"{s}\" != input \"{s}\"", .{ rebuilt.items, in }, error.SplitReconstruction);
    }
}

test "odd search options never panic (start mid-code-point / at len, span_end before start)" {
    // Only "no panic, no out-of-bounds" is asserted here; a law violation on these inputs
    // is a finding the fuzz group reports, not a failure of this test.
    const gpa = std.testing.allocator;
    for ([_]Case{
        .{ .check = .invariants, .pattern = ".", .input = "\xC3\xA9x", .start = 1 },
        .{ .check = .invariants, .pattern = "a*", .input = "ab", .start = 2 },
        .{ .check = .invariants, .pattern = "b", .input = "ab", .start = 2, .span_end = 1 },
        .{ .check = .invariants, .pattern = "\\b", .input = "\xC3\xA9", .start = 1, .anchored = true },
        .{ .check = .invariants, .pattern = "(a)|b", .input = "", .start = 0, .span_end = 0 },
    }) |c| run(gpa, &c) catch {};
}
