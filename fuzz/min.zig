//! `zig build fuzz-min -- '<FUZZ-CASE line>'` — replay a failing case exactly and shrink it.
//! Prints the minimized FUZZ-CASE line, a Zig `Case` literal ready for fuzz/findings.zig or
//! src/engine/conformance.zig, and (tree cases) the canonical pattern. Exit 1: the case
//! does not reproduce. Exit 2: not a FUZZ-CASE line. Tip: `-- "$(cat case.txt)"`.

const std = @import("std");
const lib = @import("fuzz_lib");
const common = lib.check.common;

fn zigString(bytes: []const u8) void {
    std.debug.print("\"", .{});
    for (bytes) |c| {
        if (c >= 0x20 and c < 0x7F and c != '"' and c != '\\') std.debug.print("{c}", .{c}) else std.debug.print("\\x{X:0>2}", .{c});
    }
    std.debug.print("\"", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();
    const line = it.next() orelse {
        std.debug.print("usage: zig build fuzz-min -- '<FUZZ-CASE line>'\n", .{});
        std.process.exit(2);
    };
    const case = common.Case.parse(gpa, line) catch {
        std.debug.print("fuzz-min: not a complete FUZZ-CASE line\n", .{});
        std.process.exit(2);
    };
    defer case.deinitOwned(gpa);

    const m = (try lib.check.minimize.minimize(gpa, &case, lib.check.registry.run)) orelse {
        std.debug.print("fuzz-min: does not reproduce (check {s})\n", .{@tagName(case.check)});
        std.process.exit(1);
    };
    defer m.deinitOwned(gpa);

    // Replay once, loudly, so the failure message is shown for the minimized case.
    lib.check.registry.run(gpa, &m) catch |e| std.debug.print("minimized case fails with {s}\n", .{@errorName(e)});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try m.format(&aw.writer);
    std.debug.print("\n{s}\n\n.{{ .check = .{s}, .opt = {d}, .pattern = ", .{ aw.written(), @tagName(m.check), m.opt });
    zigString(m.pattern);
    std.debug.print(", .input = ", .{});
    zigString(m.input);
    std.debug.print(", .template = ", .{});
    zigString(m.template);
    std.debug.print(", .start = {d}, .anchored = {}, .span_end = {?d}, .seed = {d}, .n = {d} }}\n", .{ m.start, m.anchored, m.span_end, m.seed, m.n });
    if (lib.gen.tree.Tree.fromBytes(m.tree)) |t| {
        if (lib.gen.print.canonical(&t, t.opt)) |p| std.debug.print("canonical tree pattern: /{s}/ (opt {d})\n", .{ p.slice(), t.opt });
    }
}
