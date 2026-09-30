//! Known-open gates: each skips ONLY the minimized shape of one open finding so a group
//! keeps fuzzing past a bug it already reported. Every skip is counted
//! (`common.stats.gated`); fuzz/health.zig fails if any gate swallows > 1 % of cases. A
//! gate is added together with its ledger entry (fuzz/findings.zig) and removed with the fix.

const std = @import("std");
const common = @import("common.zig");
const minimize = @import("minimize.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");

pub const Gate = struct {
    id: []const u8,
    /// Restrict to one check (null = any).
    check: ?common.CheckId = null,
    applies: *const fn (case: *const common.Case) bool,
};

pub const gates = [_]Gate{};

/// The gate list in force. Tests swap in a fake list to prove the rate guard fires.
pub var active: []const Gate = &gates;

pub fn gated(case: *const common.Case) bool {
    for (active, 0..) |g, i| {
        if (g.check) |c| if (c != case.check) continue;
        if (g.applies(case)) {
            if (i < common.max_gates) common.stats.gated[i] += 1;
            return true;
        }
    }
    return false;
}

/// Skip a gated case; otherwise run it and, on failure, print its replayable line AND a
/// minimized version: the check is re-run under delta debugging (`minimize.zig`) and the
/// smallest case that still fails with the same error is printed — its pattern, input, and
/// `FUZZ-CASE` line — so a report is actionable without a separate `zig build fuzz-min`.
pub fn runOrGate(
    gpa: std.mem.Allocator,
    case: *const common.Case,
    comptime run: fn (std.mem.Allocator, *const common.Case) anyerror!void,
) anyerror!void {
    if (gated(case)) return;
    run(gpa, case) catch |e| {
        case.report("check {s} failed: {s}", .{ @tagName(case.check), @errorName(e) });
        reportMinimized(gpa, case, run);
        return e;
    };
}

fn reportMinimized(
    gpa: std.mem.Allocator,
    case: *const common.Case,
    comptime run: fn (std.mem.Allocator, *const common.Case) anyerror!void,
) void {
    if (common.quiet) return;
    const m = (minimize.minimize(gpa, case, run) catch |e| {
        std.debug.print("  (minimizer failed: {s})\n", .{@errorName(e)});
        return;
    }) orelse {
        std.debug.print("  (does not reproduce on replay — the failure depended on state outside the case)\n", .{});
        return;
    };
    defer m.deinitOwned(gpa);
    if (tree.Tree.fromBytes(m.tree)) |t| {
        // Tree checks compile the tree's printing for (opt, seed): show exactly that text
        // (the case's `pattern` field is the pre-shrink printing).
        if (print.variant(&t, m.opt, m.seed)) |p| {
            var shown = m;
            shown.pattern = p.slice();
            const canon = print.canonical(&t, t.opt);
            shown.report("MINIMIZED check {s} (canonical spelling: /{s}/):", .{ @tagName(m.check), if (canon) |c| c.slice() else "?" });
            return;
        }
    }
    m.report("MINIMIZED check {s}:", .{@tagName(m.check)});
}
