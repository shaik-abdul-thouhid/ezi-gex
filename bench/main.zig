//! Benchmark driver for the ezi_gex regex engine. Runs each module against
//! ASCII / Multilingual / Pathological corpora and prints mean (of N runs) ±
//! stddev, throughput, ops/sec, and memory.
//!
//! Usage:
//!   zig build bench                         # run everything
//!   zig build bench -- search              # one module
//!   zig build bench -- search captures      # several modules
//!   zig build bench -- --list              # list registered modules
//!   zig build bench -- --size=1048576       # custom corpus size (bytes per corpus)
//!   zig build bench -- --runs=15            # samples per case (default 7)
//!
//! Add a module: drop a file in `bench/modules/`, export
//! `pub const suite: framework.Suite = .{...}`, and register it below.

const std = @import("std");
const framework = @import("framework.zig");
const corpus = @import("corpus.zig");

const search = @import("modules/search.zig");
const captures = @import("modules/captures.zig");
const compile = @import("modules/compile.zig");
const redos = @import("modules/redos.zig");

const registry: []const framework.Suite = &.{
    search.suite,
    captures.suite,
    compile.suite,
    redos.suite,
};

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  bench                       run all modules
        \\  bench MOD [MOD ...]         run only the listed modules
        \\  bench --list                list registered modules
        \\  bench --size=N              corpus size per type in bytes (default {d})
        \\  bench --runs=N              number of samples (default 7)
        \\
        \\Registered modules:
        \\
    , .{corpus.default_size});
    for (registry) |s| std.debug.print("  {s}\n", .{s.module_name});
}

fn parseUsize(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip(); // argv[0]

    var corpus_size: usize = corpus.default_size;
    var sample_runs: usize = 7;

    var selected: std.ArrayList([]const u8) = .empty;
    defer {
        for (selected.items) |s| allocator.free(s);
        selected.deinit(allocator);
    }

    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, a, "--list")) {
            std.debug.print("Registered benchmark modules:\n", .{});
            for (registry) |s| std.debug.print("  {s}\n", .{s.module_name});
            return;
        } else if (std.mem.startsWith(u8, a, "--size=")) {
            corpus_size = parseUsize(a["--size=".len..]) orelse {
                std.debug.print("invalid --size value\n", .{});
                return;
            };
        } else if (std.mem.startsWith(u8, a, "--runs=")) {
            sample_runs = parseUsize(a["--runs=".len..]) orelse {
                std.debug.print("invalid --runs value\n", .{});
                return;
            };
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("unknown flag: '{s}'\n", .{a});
            printUsage();
            return;
        } else {
            try selected.append(allocator, try allocator.dupe(u8, a));
        }
    }

    if (sample_runs == 0) sample_runs = 1;

    var corpora_set = try corpus.CorpusSet.init(allocator, corpus_size);
    defer corpora_set.deinit();

    std.debug.print(
        \\ezi_gex benchmarks
        \\==================
        \\backend:          auto (backend dispatcher)
        \\samples per case: {d} (plus 1 warmup, discarded)
        \\corpus size:      {d} bytes × 3 (ASCII / Multilingual / Pathological)
        \\
    , .{ sample_runs, corpus_size });

    var ran_any = false;
    for (registry) |s| {
        if (selected.items.len > 0) {
            var matched = false;
            for (selected.items) |q| {
                if (std.mem.eql(u8, s.module_name, q)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }
        framework.runSuite(s, allocator, sample_runs, &corpora_set.corpora);
        ran_any = true;
    }

    if (selected.items.len > 0 and !ran_any) {
        std.debug.print("\nNo modules matched. Use --list to see registered modules.\n", .{});
    }

    std.debug.print("\nDone.\n", .{});
}
