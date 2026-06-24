const std = @import("std");

/// Local copy of the `any`-style predicate used for build-option logic. Kept in
/// the build script so `build.zig` never imports library source (`src/`) — the
/// build graph stays decoupled from internal module layout.
fn some(comptime T: type, context: anytype, elements: []const T, predicate: fn (ctx: @TypeOf(context), T, index: usize) bool) bool {
    for (elements, 0..) |element, i| {
        if (predicate(context, element, i)) return true;
    }
    return false;
}

/// One test unit per independently-cacheable test binary. `all` selects every
/// unit. Each non-`all` tag names exactly one `b.addTest` artifact, so a flag
/// like `-Dinclude-test=auto,conformance` runs only those — a genuine partial
/// run, not a slice of one giant binary. `exe` is `src/main.zig`'s own tests.
const TestEnum = enum {
    all,
    utils,
    core,
    engine_base,
    backtrack,
    pikevm,
    bytepike,
    dfa,
    edfa,
    onepass,
    literal,
    auto,
    regex,
    conformance,
    redos,
    fuzz,
    exe,
};

/// True if `tag` (or `all`) is in the selected `include-test` list.
fn selected(include: []const TestEnum, tag: TestEnum) bool {
    const Ctx = struct { want: TestEnum };
    return some(TestEnum, Ctx{ .want = tag }, include, struct {
        fn predicate(ctx: Ctx, t: TestEnum, _: usize) bool {
            return t == .all or t == ctx.want;
        }
    }.predicate);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_tests = b.option(
        []const TestEnum,
        "include-test",
        "Test units to run with `zig build test` (default: all)",
    ) orelse &[_]TestEnum{.all};

    const ezi_code = b.dependency("ezi_code", .{
        .target = target,
        .optimize = optimize,
    });

    // ── The single Unicode/encoding seam ──────────────────────────────────────
    // `utils` is the ONLY module that imports `ezi_code`. Every other module imports
    // `utils`, NOT `ezi_code`, so a stray `@import("ezi_code")` anywhere else is a
    // *compile error* — the no-direct-ezi_code rule is enforced by the build graph.
    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ezi_code", .module = ezi_code.module("ezi_code") },
        },
    });
    const utils: std.Build.Module.Import = .{ .name = "utils", .module = utils_mod };

    // ── core: front end (token, ast, error, scanner, compile, hir) ────────────
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{utils},
    });
    const core: std.Build.Module.Import = .{ .name = "core", .module = core_mod };

    // ── engine_base: the shared engine substrate (7 files behind one boundary) ─
    const engine_base_mod = b.addModule("engine_base", .{
        .root_source_file = b.path("src/engine/base.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core },
    });
    const engine_base: std.Build.Module.Import = .{ .name = "engine_base", .module = engine_base_mod };

    // ── backends: each its own module (so each caches/tests independently) ─────
    const pikevm_mod = b.addModule("pikevm", .{
        .root_source_file = b.path("src/engine/backends/pikevm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const pikevm: std.Build.Module.Import = .{ .name = "pikevm", .module = pikevm_mod };

    const backtrack_mod = b.addModule("backtrack", .{
        .root_source_file = b.path("src/engine/backends/backtrack.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const backtrack: std.Build.Module.Import = .{ .name = "backtrack", .module = backtrack_mod };

    const bytepike_mod = b.addModule("bytepike", .{
        .root_source_file = b.path("src/engine/backends/bytepike.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const bytepike: std.Build.Module.Import = .{ .name = "bytepike", .module = bytepike_mod };

    const literal_mod = b.addModule("literal", .{
        .root_source_file = b.path("src/engine/backends/literal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const literal: std.Build.Module.Import = .{ .name = "literal", .module = literal_mod };

    const onepass_mod = b.addModule("onepass", .{
        .root_source_file = b.path("src/engine/backends/onepass.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, pikevm },
    });
    const onepass: std.Build.Module.Import = .{ .name = "onepass", .module = onepass_mod };

    const dfa_mod = b.addModule("dfa", .{
        .root_source_file = b.path("src/engine/backends/dfa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, pikevm },
    });
    const dfa: std.Build.Module.Import = .{ .name = "dfa", .module = dfa_mod };

    const edfa_mod = b.addModule("edfa", .{
        .root_source_file = b.path("src/engine/backends/edfa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, dfa, pikevm },
    });
    const edfa: std.Build.Module.Import = .{ .name = "edfa", .module = edfa_mod };

    const auto_mod = b.addModule("auto", .{
        .root_source_file = b.path("src/engine/backends/auto.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, literal, pikevm, backtrack, dfa, edfa, onepass },
    });
    const auto: std.Build.Module.Import = .{ .name = "auto", .module = auto_mod };

    // ── regex: the front door (depends on auto) ───────────────────────────────
    const regex_mod = b.addModule("regex", .{
        .root_source_file = b.path("src/engine/regex.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, auto },
    });
    const regex: std.Build.Module.Import = .{ .name = "regex", .module = regex_mod };

    // ── conformance: cross-backend differential (drives every backend) ────────
    const conformance_mod = b.addModule("conformance", .{
        .root_source_file = b.path("src/engine/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, regex, pikevm, backtrack, literal, bytepike, dfa, edfa, onepass, auto },
    });
    const conformance: std.Build.Module.Import = .{ .name = "conformance", .module = conformance_mod };

    // ── redos: ReDoS-immunity regression suite ────────────────────────────────
    const redos_mod = b.addModule("redos", .{
        .root_source_file = b.path("src/engine/redos.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, regex, pikevm, backtrack, auto, edfa, dfa },
    });
    const redos: std.Build.Module.Import = .{ .name = "redos", .module = redos_mod };

    // ── engine aggregate: thin re-export over the units (no tests of its own) ──
    const engine_mod = b.addModule("engine", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ engine_base, pikevm, backtrack, bytepike, literal, dfa, edfa, onepass, auto, regex, conformance, redos },
    });
    const engine: std.Build.Module.Import = .{ .name = "engine", .module = engine_mod };

    // ── ezi_gex facade: the published module (exe + bench + downstream use it) ─
    const mod = b.addModule("ezi_gex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine },
    });

    // ── fuzz: coverage-guided fuzz targets (Smith-driven) over the facade ──────
    // Imports only the published `ezi_gex` module, exactly as a downstream user
    // would — the fuzzer drives the public surface, not internals. `fuzz` is left
    // null (default), so instrumentation is added only under `--fuzz`; a plain
    // `zig build test-fuzz` runs the bodies as finite corpus-replay smoke tests.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ezi_gex", .module = mod },
        },
    });

    // ── demo executable ───────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "ezi_gex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ezi_gex", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // ── per-unit test artifacts ───────────────────────────────────────────────
    // One `addTest` per module → one independently-cacheable test binary. Editing a
    // file only recompiles/re-runs the unit(s) whose inputs changed; the rest stay
    // cached. The facade module (`ezi_gex`) is NOT tested here — its relative-free
    // surface re-exports the units, so testing it would just re-run them.
    const utils_tests = b.addTest(.{ .root_module = utils_mod });
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const engine_base_tests = b.addTest(.{ .root_module = engine_base_mod });
    const backtrack_tests = b.addTest(.{ .root_module = backtrack_mod });
    const pikevm_tests = b.addTest(.{ .root_module = pikevm_mod });
    const bytepike_tests = b.addTest(.{ .root_module = bytepike_mod });
    const dfa_tests = b.addTest(.{ .root_module = dfa_mod });
    const edfa_tests = b.addTest(.{ .root_module = edfa_mod });
    const onepass_tests = b.addTest(.{ .root_module = onepass_mod });
    const literal_tests = b.addTest(.{ .root_module = literal_mod });
    const auto_tests = b.addTest(.{ .root_module = auto_mod });
    const regex_tests = b.addTest(.{ .root_module = regex_mod });
    const conformance_tests = b.addTest(.{ .root_module = conformance_mod });
    const redos_tests = b.addTest(.{ .root_module = redos_mod });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const run_utils_tests = b.addRunArtifact(utils_tests);
    const run_core_tests = b.addRunArtifact(core_tests);
    const run_engine_base_tests = b.addRunArtifact(engine_base_tests);
    const run_backtrack_tests = b.addRunArtifact(backtrack_tests);
    const run_pikevm_tests = b.addRunArtifact(pikevm_tests);
    const run_bytepike_tests = b.addRunArtifact(bytepike_tests);
    const run_dfa_tests = b.addRunArtifact(dfa_tests);
    const run_edfa_tests = b.addRunArtifact(edfa_tests);
    const run_onepass_tests = b.addRunArtifact(onepass_tests);
    const run_literal_tests = b.addRunArtifact(literal_tests);
    const run_auto_tests = b.addRunArtifact(auto_tests);
    const run_regex_tests = b.addRunArtifact(regex_tests);
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    const run_redos_tests = b.addRunArtifact(redos_tests);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Pair each unit's tag with its run step, so the `test` step gates them by
    // `-Dinclude-test`, and so each gets a `test-<unit>` convenience step.
    const Unit = struct { tag: TestEnum, run: *std.Build.Step, name: []const u8 };
    const units = [_]Unit{
        .{ .tag = .utils, .run = &run_utils_tests.step, .name = "test-utils" },
        .{ .tag = .core, .run = &run_core_tests.step, .name = "test-core" },
        .{ .tag = .engine_base, .run = &run_engine_base_tests.step, .name = "test-engine_base" },
        .{ .tag = .backtrack, .run = &run_backtrack_tests.step, .name = "test-backtrack" },
        .{ .tag = .pikevm, .run = &run_pikevm_tests.step, .name = "test-pikevm" },
        .{ .tag = .bytepike, .run = &run_bytepike_tests.step, .name = "test-bytepike" },
        .{ .tag = .dfa, .run = &run_dfa_tests.step, .name = "test-dfa" },
        .{ .tag = .edfa, .run = &run_edfa_tests.step, .name = "test-edfa" },
        .{ .tag = .onepass, .run = &run_onepass_tests.step, .name = "test-onepass" },
        .{ .tag = .literal, .run = &run_literal_tests.step, .name = "test-literal" },
        .{ .tag = .auto, .run = &run_auto_tests.step, .name = "test-auto" },
        .{ .tag = .regex, .run = &run_regex_tests.step, .name = "test-regex" },
        .{ .tag = .conformance, .run = &run_conformance_tests.step, .name = "test-conformance" },
        .{ .tag = .redos, .run = &run_redos_tests.step, .name = "test-redos" },
        .{ .tag = .fuzz, .run = &run_fuzz_tests.step, .name = "test-fuzz" },
        .{ .tag = .exe, .run = &run_exe_tests.step, .name = "test-exe" },
    };

    const test_step = b.step("test", "Run tests (gate units with -Dinclude-test=...)");
    for (units) |u| {
        // Always expose a `test-<unit>` step that runs just this unit.
        const single = b.step(u.name, b.fmt("Run only the {s} unit's tests", .{@tagName(u.tag)}));
        single.dependOn(u.run);
        // Fold into the aggregate `test` step iff selected by -Dinclude-test.
        if (selected(include_tests, u.tag)) test_step.dependOn(u.run);
    }

    // ── fuzzing: one binary per group, run in PARALLEL by the build scheduler ───
    // Each file under `fuzz/groups/` compiles into its OWN test binary (its targets
    // share the differential bodies in `fuzz/groups/harness.zig`). The `fuzz` step
    // depends on all of them, and the build scheduler runs independent run-steps
    // concurrently — exactly like `zig build test` runs the 15 unit binaries at once
    // — so `zig build fuzz --fuzz=N` fuzzes every group in parallel, N iters EACH
    // (7 groups × N). Bare `zig build fuzz` is a finite seed-replay smoke of all.
    // Each group also gets a `zig build fuzz-<group>` step for a single session.
    // (The aggregate `fuzz` UNIT — fuzz/root.zig, run via `test-fuzz` and folded
    // into `zig build test` — still bundles every group into one binary for the
    // finite regression pass.)
    const fuzz_step = b.step("fuzz", "Fuzz every group in parallel (add --fuzz=N for N iters/group)");
    const fuzz_groups = [_][]const u8{ "scanner", "diff", "anchors", "unicode", "captures", "iter", "search" };
    for (fuzz_groups) |g| {
        const gmod = b.createModule(.{
            .root_source_file = b.path(b.fmt("fuzz/groups/{s}.zig", .{g})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ezi_gex", .module = mod }},
        });
        const gtest = b.addTest(.{ .root_module = gmod });
        const grun = b.addRunArtifact(gtest);
        const gstep = b.step(b.fmt("fuzz-{s}", .{g}), b.fmt("Fuzz only the {s} group (add --fuzz=N)", .{g}));
        gstep.dependOn(&grun.step);
        fuzz_step.dependOn(&grun.step); // `zig build fuzz` → every group, in parallel
    }

    // ── Benchmarks ────────────────────────────────────────────────────────────
    // Built against an `ezi_gex` module in ReleaseFast by default so the engine is
    // measured optimized. The seam (and the whole module tree) is rebuilt at the
    // bench optimize level — a distinct ezi_code instance needs distinct wrappers.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization level for the bench executable (default ReleaseFast)",
    ) orelse .ReleaseFast;

    const ezi_code_bench = b.dependency("ezi_code", .{
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "ezi_code", .module = ezi_code_bench.module("ezi_code") },
        },
    });
    const bench_utils: std.Build.Module.Import = .{ .name = "utils", .module = bench_utils_mod };

    const bench_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{bench_utils},
    });
    const bench_core: std.Build.Module.Import = .{ .name = "core", .module = bench_core_mod };

    const bench_engine_base_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/base.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core },
    });
    const bench_engine_base: std.Build.Module.Import = .{ .name = "engine_base", .module = bench_engine_base_mod };

    const bench_pikevm_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/pikevm.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base },
    });
    const bench_pikevm: std.Build.Module.Import = .{ .name = "pikevm", .module = bench_pikevm_mod };

    const bench_backtrack_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/backtrack.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base },
    });
    const bench_backtrack: std.Build.Module.Import = .{ .name = "backtrack", .module = bench_backtrack_mod };

    const bench_bytepike_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/bytepike.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base },
    });
    const bench_bytepike: std.Build.Module.Import = .{ .name = "bytepike", .module = bench_bytepike_mod };

    const bench_literal_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/literal.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base },
    });
    const bench_literal: std.Build.Module.Import = .{ .name = "literal", .module = bench_literal_mod };

    const bench_onepass_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/onepass.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_pikevm },
    });
    const bench_onepass: std.Build.Module.Import = .{ .name = "onepass", .module = bench_onepass_mod };

    const bench_dfa_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/dfa.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_pikevm },
    });
    const bench_dfa: std.Build.Module.Import = .{ .name = "dfa", .module = bench_dfa_mod };

    const bench_edfa_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/edfa.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_dfa, bench_pikevm },
    });
    const bench_edfa: std.Build.Module.Import = .{ .name = "edfa", .module = bench_edfa_mod };

    const bench_auto_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/backends/auto.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_literal, bench_pikevm, bench_backtrack, bench_dfa, bench_edfa, bench_onepass },
    });
    const bench_auto: std.Build.Module.Import = .{ .name = "auto", .module = bench_auto_mod };

    const bench_regex_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/regex.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_auto },
    });
    const bench_regex: std.Build.Module.Import = .{ .name = "regex", .module = bench_regex_mod };

    const bench_conformance_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/conformance.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_regex, bench_pikevm, bench_backtrack, bench_literal, bench_bytepike, bench_dfa, bench_edfa, bench_onepass, bench_auto },
    });
    const bench_conformance: std.Build.Module.Import = .{ .name = "conformance", .module = bench_conformance_mod };

    const bench_redos_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/redos.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine_base, bench_regex, bench_pikevm, bench_backtrack, bench_auto, bench_edfa, bench_dfa },
    });
    const bench_redos: std.Build.Module.Import = .{ .name = "redos", .module = bench_redos_mod };

    const bench_engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_engine_base, bench_pikevm, bench_backtrack, bench_bytepike, bench_literal, bench_dfa, bench_edfa, bench_onepass, bench_auto, bench_regex, bench_conformance, bench_redos },
    });
    const bench_engine: std.Build.Module.Import = .{ .name = "engine", .module = bench_engine_mod };

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{ bench_utils, bench_core, bench_engine },
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
