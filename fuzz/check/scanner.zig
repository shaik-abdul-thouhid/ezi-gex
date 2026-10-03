//! Scanner hardening. Random bytes mostly die at the first character; mutating a VALID
//! generated pattern by 1–3 edits from a metacharacter-heavy set drives the parser deep
//! into error recovery instead. A rejection must carry a real code and a span inside the
//! pattern; an acceptance must leave the diagnostic clean, and (at default limits) no
//! backend may then call the pattern invalid.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const pattern_gen = @import("../gen/pattern.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const edit_chars = "()[]{}|?*+\\^$.-:<>=!#PpxuQEkbBdDsSwWzZAX0123456789,aZ \n\t";

pub fn mutate(smith: *Smith, base: []const u8, out: []u8) []const u8 {
    @disableInstrumentation();
    var len = @min(base.len, out.len);
    @memcpy(out[0..len], base[0..len]);
    const edits = smith.valueRangeAtMost(u8, 1, 3);
    var e: u8 = 0;
    while (e < edits) : (e += 1) {
        const at = smith.index(len + 1);
        const c = edit_chars[smith.index(edit_chars.len)];
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => if (len < out.len) { // insert
                @memmove(out[at + 1 .. len + 1], out[at..len]);
                out[at] = c;
                len += 1;
            },
            1 => if (at < len) { // delete
                @memmove(out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            else => if (at < len) {
                out[at] = c; // replace
            },
        }
    }
    return out[0..len];
}

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var p = pattern_gen.gen(smith);
    var buf: [pattern_gen.max_pattern_len + 8]u8 = undefined;
    const m = mutate(smith, p.slice(), &buf);
    const limit: usize = if (smith.valueRangeAtMost(u8, 0, 3) == 0) smith.valueRangeAtMost(u16, 1, 2000) else 0;
    const case: Case = .{ .check = .scanner, .pattern = m, .n = limit };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.scanner, true);
    var diag: gex.Diagnostic = .{};
    const limit: u32 = if (case.n == 0) gex.default_max_repetition else @intCast(@min(case.n, std.math.maxInt(u32)));
    const ast = gex.parseWith(gpa, case.pattern, &diag, .{ .max_repetition = limit }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidPattern => {
            if (diag.code == .none) return error.RejectWithoutCode;
            if (diag.span.start > diag.span.end or diag.span.end > case.pattern.len) {
                std.debug.print("scanner: /{s}/ {s} span {d}..{d} outside pattern (len {d})\n", .{ case.pattern, @tagName(diag.code), diag.span.start, diag.span.end, case.pattern.len });
                return error.DiagnosticOutOfRange;
            }
            _ = diag.faultySlice(case.pattern);
            return;
        },
    };
    ast.deinit(gpa);
    if (!diag.isOk()) return error.AcceptWithDiagnostic;
    if (case.n != 0) return;
    inline for (common.all_backends) |B| {
        var b = try common.build(B, gpa, case.pattern, 0);
        switch (b) {
            .ok => |*re| re.deinit(),
            .skip => {},
            .invalid => {
                std.debug.print("scanner: /{s}/ parses but {s} calls it InvalidPattern\n", .{ case.pattern, @typeName(B) });
                return error.BackendRejectsParsedPattern;
            },
        }
    }
}
