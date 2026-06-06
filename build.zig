const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const ezi_code = b.dependency("ezi_code", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("ezi_gex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ezi_code", .module = ezi_code.module("ezi_code") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "ezi_gex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ezi_gex", .module = mod },
                .{ .name = "ezi_code", .module = ezi_code.module("ezi_code") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ── Benchmarks ────────────────────────────────────────────────────────────
    // Built (and linked against an ezi_gex module) in ReleaseFast by default so
    // the engine is measured optimized, not in Debug. Override with
    // `-Dbench-optimize=...`.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization level for the bench executable (default ReleaseFast)",
    ) orelse .ReleaseFast;

    const ezi_code_bench = b.dependency("ezi_code", .{
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "ezi_code", .module = ezi_code_bench.module("ezi_code") },
        },
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{ .name = "ezi_gex", .module = bench_mod },
            },
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
