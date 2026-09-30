//! Known-open ledger. Each entry is a minimized case that currently FAILS with `err`; the
//! test asserts it still does. When a fix lands the entry flips to "no longer reproduces":
//! move the case into src/engine/conformance.zig as a regression, then delete the entry
//! here and its gate in check/known_open.zig. Entries are either a `FUZZ-CASE` line (what
//! `zig build fuzz-min` prints) or a reference-check tree built with `tree.Builder` (for
//! findings established by reasoning rather than by the fuzzer).

const std = @import("std");
const lib = @import("fuzz_lib");
const common = lib.check.common;
const tree = lib.gen.tree;

pub const Finding = struct {
    id: []const u8,
    line: ?[]const u8 = null,
    build: ?*const fn (*tree.Builder) u16 = null,
    opt: u8 = 0,
    input: []const u8 = "",
    /// The `@errorName` the check must STILL return.
    err: []const u8,
    note: []const u8,
};

pub const ledger = [_]Finding{};

fn replay(gpa: std.mem.Allocator, f: Finding) !?anyerror {
    const saved = common.quiet;
    common.quiet = true;
    defer common.quiet = saved;
    if (f.line) |line| {
        const c = try common.Case.parse(gpa, line);
        defer c.deinitOwned(gpa);
        lib.check.registry.run(gpa, &c) catch |e| return e;
        return null;
    }
    var b = tree.Builder.init(f.opt);
    const t = b.finish(f.build.?(&b));
    const pr = lib.gen.print.canonical(&t, f.opt).?;
    const c: common.Case = .{ .check = .reference, .pattern = pr.slice(), .input = f.input, .tree = t.bytes(), .opt = f.opt };
    lib.check.reference.run(gpa, &c) catch |e| return e;
    return null;
}

test "known-open findings still reproduce" {
    for (ledger) |f| {
        const got = try replay(std.testing.allocator, f);
        if (got) |e| {
            if (std.mem.eql(u8, @errorName(e), f.err)) continue;
            std.debug.print("finding {s} now fails differently: {s} (ledger says {s})\n", .{ f.id, @errorName(e), f.err });
            return error.FindingChanged;
        }
        std.debug.print("finding {s} no longer reproduces — fixed? Move it to src/engine/conformance.zig as a regression, then delete this entry and its gate.\n", .{f.id});
        return error.FindingFixed;
    }
}

test "every known-open gate has a ledger entry" {
    for (lib.check.known_open.gates) |g| {
        for (ledger) |f| {
            if (std.mem.eql(u8, f.id, g.id)) break;
        } else {
            std.debug.print("gate {s} has no ledger entry in fuzz/findings.zig\n", .{g.id});
            return error.GateWithoutFinding;
        }
    }
}
