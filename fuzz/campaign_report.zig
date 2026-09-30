//! `zig build campaign` post-processing: one run per group. Reads the captured stderr of
//! `zig build fuzz-<group> --fuzz=<n>` and decides the group's verdict, because that command
//! exits 0 even when a fuzz test fails — its exit code cannot be trusted.
//!
//!     campaign-report <group> <iterations> <captured-stderr-file>
//!
//! Clean: prints one line (iterations, runs, coverage) and exits 0. Any failure marker:
//! prints the whole log — it holds the replay line and the auto-minimized case — and exits 1,
//! which fails the build.

const std = @import("std");

/// Text the harness, the test runner or the fuzzer prints only when something went wrong.
const failure_markers = [_][]const u8{
    "MINIMIZED check", // known_open.runOrGate: a check failed (auto-minimized case follows)
    "failed with error.", // …the minimized case's verdict
    "does not reproduce on replay", // a failure the replay could not reproduce
    "error: test '", // the test runner: a fuzz test failed, crashed or leaked
    "terminated with signal", // a crash / abort in the fuzzed code
    "panic:", // a panic anywhere
    "leaked", // an allocation leak
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: campaign-report <group> <iterations> <captured-stderr-file>\n", .{});
        std.process.exit(2);
    }
    const group = args[1];
    const iterations = args[2];
    const log = try std.Io.Dir.cwd().readFileAlloc(io, args[3], gpa, .limited(256 << 20));
    defer gpa.free(log);

    for (failure_markers) |marker| {
        if (std.mem.indexOf(u8, log, marker) == null) continue;
        std.debug.print("\n══ campaign {s}: FAILED ({s} iterations) ══\n{s}\n", .{ group, iterations, log });
        std.process.exit(1);
    }
    std.debug.print("campaign {s}: clean — {s} iterations, runs {s}, coverage {s}\n", .{ group, iterations, field(log, "Runs: "), field(log, "Coverage: ") });
}

/// The rest of the fuzzing report's first line that starts with `label` (e.g. "0 -> 2792"),
/// or "?" when the report has none.
fn field(log: []const u8, label: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, log, label) orelse return "?";
    const end = std.mem.indexOfScalarPos(u8, log, at, '\n') orelse log.len;
    return log[at + label.len .. end];
}
