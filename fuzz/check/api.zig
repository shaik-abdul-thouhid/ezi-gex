//! Public-surface check: every search/replace/split entry point, not just find/findAll.
//! Each capture backend must match the Pike VM on all of them, and the entry points must
//! agree with each other (replace == replaceN(1), replaceAllAlloc == replaceAll, …).

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;
const Summary = common.Summary;

/// Templates mixing every `$` form, including the malformed ones the DSL defines as literal.
pub fn genTemplate(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const pieces = [_][]const u8{ "$0", "$1", "$2", "${1}", "${n1}", "${n2}", "${nope}", "$$", "$", "$99", "${", "}", "x", "-", "$a" };
    var len: usize = 0;
    const parts = smith.valueRangeAtMost(u8, 0, 5);
    var i: u8 = 0;
    while (i < parts) : (i += 1) {
        const s = pieces[smith.index(pieces.len)];
        if (len + s.len > out.len) break;
        @memcpy(out[len..][0..s.len], s);
        len += s.len;
    }
    return out[0..len];
}

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var ibuf: [input_gen.max_input_len]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    var tbuf: [48]u8 = undefined;
    const template = genTemplate(smith, &tbuf);
    const case: Case = .{ .check = .api, .pattern = p.pattern, .input = input, .opt = p.opt, .template = template, .n = smith.valueRangeAtMost(u8, 0, 5), .start = smith.index(input.len + 1) };
    try known_open.runOrGate(gpa, &case, run);
}

const Wrap = struct {
    fn angle(_: void, caps: gex.Captures, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('<');
        if (caps.groupSlice(0)) |s| try w.writeAll(s);
        try w.writeByte('>');
    }
};

fn hashOut(s: *Summary, out: []const u8) void {
    s.push(out.len);
    s.push(@intCast(std.hash.Wyhash.hash(0, out)));
}

fn apiSummary(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), case: *const Case) !Summary {
    var s: Summary = .{};
    const in = case.input;
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var slots: [96]?usize = undefined;
    const ns = re.slotCount();
    if (ns > slots.len) return error.TooManyGroups;
    const sl = slots[0..ns];

    // split / splitN (pieces as offsets into `in`)
    var sp = re.split(&sc, in);
    var j: usize = 0;
    while (sp.next()) |piece| : (j += 1) {
        if (j == 32) break;
        s.push(@intFromPtr(piece.ptr) - @intFromPtr(in.ptr));
        s.push(piece.len);
    }
    s.push(NONE_MARK);
    var spn = re.splitN(&sc, in, case.n);
    j = 0;
    while (spn.next()) |piece| : (j += 1) {
        if (j >= case.n) return error.SplitNTooManyPieces;
        s.push(@intFromPtr(piece.ptr) - @intFromPtr(in.ptr));
        s.push(piece.len);
    }
    s.push(NONE_MARK);

    // replace family (+ internal agreement laws)
    var a1: std.Io.Writer.Allocating = .init(gpa);
    defer a1.deinit();
    try re.replace(&sc, in, case.template, sl, &a1.writer);
    var a2: std.Io.Writer.Allocating = .init(gpa);
    defer a2.deinit();
    try re.replaceN(&sc, in, case.template, sl, &a2.writer, 1);
    if (!std.mem.eql(u8, a1.written(), a2.written())) return error.ReplaceNotReplaceN1;
    hashOut(&s, a1.written());
    var a3: std.Io.Writer.Allocating = .init(gpa);
    defer a3.deinit();
    try re.replaceN(&sc, in, case.template, sl, &a3.writer, case.n);
    hashOut(&s, a3.written());
    var a4: std.Io.Writer.Allocating = .init(gpa);
    defer a4.deinit();
    try re.replaceAll(&sc, in, case.template, sl, &a4.writer);
    const alloc_out = try re.replaceAllAlloc(gpa, &sc, in, case.template, sl);
    defer gpa.free(alloc_out);
    if (!std.mem.eql(u8, a4.written(), alloc_out)) return error.ReplaceAllAllocDiffers;
    hashOut(&s, alloc_out);
    var a5: std.Io.Writer.Allocating = .init(gpa);
    defer a5.deinit();
    try re.replaceAllWith(&sc, in, sl, &a5.writer, {}, Wrap.angle);
    const angle_out = try re.replaceAllAlloc(gpa, &sc, in, "<$0>", sl);
    defer gpa.free(angle_out);
    if (!std.mem.eql(u8, a5.written(), angle_out)) return error.ReplaceAllWithDiffers;
    hashOut(&s, angle_out);

    // capturesAll (≤ 16 matches) and capturesAt
    var ca = re.capturesAll(&sc, sl, in);
    j = 0;
    while (ca.next()) |c| : (j += 1) {
        if (j == 16) break;
        for (c.slots) |x| s.push(x orelse common.NONE);
    }
    s.push(NONE_MARK);
    if (re.capturesAt(&sc, sl, in, .{ .start = @min(case.start, in.len) })) |_| {
        for (sl) |x| s.push(x orelse common.NONE);
    } else s.push(common.NONE);

    // names
    var g: usize = 1;
    while (g <= re.captureCount()) : (g += 1) {
        if (re.groupName(g)) |name| {
            if (re.groupIndex(name) != g) return error.GroupNameIndexMismatch;
            s.push(g);
        }
    }
    return s;
}

const NONE_MARK = std.math.maxInt(usize) - 1;

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (ob != .ok) return;
    defer ob.ok.deinit();
    const want = apiSummary(gex.backends.pikevm, gpa, &ob.ok, case) catch |e| switch (e) {
        error.TooManyGroups => return,
        else => {
            std.debug.print("api (pikevm) on /{s}/ tmpl \"{s}\": law {s}\n", .{ case.pattern, case.template, @errorName(e) });
            return e;
        },
    };
    common.noteRun(.api, true);
    const byte_safe = common.byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (common.capture_backends) |B| try against(B, gpa, case, byte_safe, &want);
}

fn against(comptime B: type, gpa: std.mem.Allocator, case: *const Case, byte_safe: bool, want: *const Summary) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.api, B);
    var b = try common.build(B, gpa, case.pattern, case.opt);
    if (b != .ok) return if (b == .skip) common.noteSkipped(.api, B) else error.ValidityDisagreement;
    defer b.ok.deinit();
    common.noteCompared(.api, B);
    const got = apiSummary(B, gpa, &b.ok, case) catch |e| {
        std.debug.print("api ({s}) on /{s}/ tmpl \"{s}\": law {s}\n", .{ @typeName(B), case.pattern, case.template, @errorName(e) });
        return e;
    };
    if (!got.eql(want)) {
        std.debug.print("api ({s}) on /{s}/ tmpl \"{s}\" n={d} over \"{s}\":\n  pikevm {any}\n  other  {any}\n", .{ @typeName(B), case.pattern, case.template, case.n, case.input, want.v[0..want.n], got.v[0..got.n] });
        return error.ApiDivergence;
    }
}
