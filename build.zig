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

/// Every fuzz group (`fuzz/groups/<name>.zig`) with its measured fuzzing throughput in `safe`
/// mode: iterations of `--fuzz=N` per minute (N counts per fuzz test in the group), set to
/// ~0.7 × a timed `zig build fuzz-<name> -Doptimize=safe --fuzz=K` on a warm build (Apple M-series,
/// 2026-09-30), since inputs grow as coverage does. `zig build campaign` sizes each group's
/// count from it; the spread (125/min for `search`, 71 000/min for `utf8class`) is why one
/// global `--fuzz=N` can't serve every group. Re-measure when a group's checks change a lot.
const FuzzGroup = struct { name: []const u8, per_minute: u32 };
const fuzz_groups = [_]FuzzGroup{
    .{ .name = "scanner", .per_minute = 1400 },
    .{ .name = "diff", .per_minute = 770 },
    .{ .name = "anchors", .per_minute = 58000 },
    .{ .name = "unicode", .per_minute = 125 },
    .{ .name = "captures", .per_minute = 3000 },
    .{ .name = "iter", .per_minute = 150 },
    .{ .name = "search", .per_minute = 125 },
    .{ .name = "reference", .per_minute = 12700 },
    .{ .name = "metamorphic", .per_minute = 490 },
    .{ .name = "invariants", .per_minute = 820 },
    .{ .name = "state", .per_minute = 290 },
    .{ .name = "large", .per_minute = 780 },
    .{ .name = "literals", .per_minute = 1780 },
    .{ .name = "api", .per_minute = 2100 },
    .{ .name = "oom", .per_minute = 9800 },
    .{ .name = "comptime_parity", .per_minute = 39000 },
    .{ .name = "complexity", .per_minute = 790 },
    .{ .name = "utf8class", .per_minute = 71000 },
    .{ .name = "chaos", .per_minute = 140 },
};

/// The library's module graph, wired for one target and optimize mode. `build` makes it for the
/// host with `publish` set, so the tests and a downstream `dep.module("…")` can import each
/// module by name. It makes it again, unpublished, for the bench (its own optimize mode): a
/// distinct `ezi_code` instance needs its own wrappers.
const Modules = struct {
    ezi_code: *std.Build.Module,
    utils: *std.Build.Module,
    core: *std.Build.Module,
    engine_base: *std.Build.Module,
    pikevm: *std.Build.Module,
    backtrack: *std.Build.Module,
    bytepike: *std.Build.Module,
    literal: *std.Build.Module,
    onepass: *std.Build.Module,
    dfa: *std.Build.Module,
    edfa: *std.Build.Module,
    auto: *std.Build.Module,
    regex: *std.Build.Module,
    conformance: *std.Build.Module,
    redos: *std.Build.Module,
    engine: *std.Build.Module,
    /// `src/root.zig`, the module users import as `ezi_gex`.
    ezi_gex: *std.Build.Module,
};

/// `b.addModule`, published under `name`, when `publish`; otherwise an anonymous `b.createModule`.
fn libModule(b: *std.Build, publish: bool, name: []const u8, options: std.Build.Module.CreateOptions) *std.Build.Module {
    return if (publish) b.addModule(name, options) else b.createModule(options);
}

fn addModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, publish: bool) Modules {
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
    const core_mod = libModule(b, publish, "core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{utils},
    });
    const core: std.Build.Module.Import = .{ .name = "core", .module = core_mod };

    // ── engine_base: the shared engine substrate (7 files behind one boundary) ─
    const engine_base_mod = libModule(b, publish, "engine_base", .{
        .root_source_file = b.path("src/engine/base.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core },
    });
    const engine_base: std.Build.Module.Import = .{ .name = "engine_base", .module = engine_base_mod };

    // ── backends: each its own module (so each caches/tests independently) ─────
    const pikevm_mod = libModule(b, publish, "pikevm", .{
        .root_source_file = b.path("src/engine/backends/pikevm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const pikevm: std.Build.Module.Import = .{ .name = "pikevm", .module = pikevm_mod };

    const backtrack_mod = libModule(b, publish, "backtrack", .{
        .root_source_file = b.path("src/engine/backends/backtrack.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const backtrack: std.Build.Module.Import = .{ .name = "backtrack", .module = backtrack_mod };

    const bytepike_mod = libModule(b, publish, "bytepike", .{
        .root_source_file = b.path("src/engine/backends/bytepike.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const bytepike: std.Build.Module.Import = .{ .name = "bytepike", .module = bytepike_mod };

    const literal_mod = libModule(b, publish, "literal", .{
        .root_source_file = b.path("src/engine/backends/literal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base },
    });
    const literal: std.Build.Module.Import = .{ .name = "literal", .module = literal_mod };

    const onepass_mod = libModule(b, publish, "onepass", .{
        .root_source_file = b.path("src/engine/backends/onepass.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, pikevm },
    });
    const onepass: std.Build.Module.Import = .{ .name = "onepass", .module = onepass_mod };

    const dfa_mod = libModule(b, publish, "dfa", .{
        .root_source_file = b.path("src/engine/backends/dfa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, pikevm },
    });
    const dfa: std.Build.Module.Import = .{ .name = "dfa", .module = dfa_mod };

    const edfa_mod = libModule(b, publish, "edfa", .{
        .root_source_file = b.path("src/engine/backends/edfa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, dfa, pikevm },
    });
    const edfa: std.Build.Module.Import = .{ .name = "edfa", .module = edfa_mod };

    const auto_mod = libModule(b, publish, "auto", .{
        .root_source_file = b.path("src/engine/backends/auto.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, literal, pikevm, backtrack, dfa, edfa, onepass },
    });
    const auto: std.Build.Module.Import = .{ .name = "auto", .module = auto_mod };

    // ── regex: the front door (depends on auto) ───────────────────────────────
    const regex_mod = libModule(b, publish, "regex", .{
        .root_source_file = b.path("src/engine/regex.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, auto },
    });
    const regex: std.Build.Module.Import = .{ .name = "regex", .module = regex_mod };

    // ── conformance: cross-backend differential (drives every backend) ────────
    const conformance_mod = libModule(b, publish, "conformance", .{
        .root_source_file = b.path("src/engine/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, regex, pikevm, backtrack, literal, bytepike, dfa, edfa, onepass, auto },
    });
    const conformance: std.Build.Module.Import = .{ .name = "conformance", .module = conformance_mod };

    // ── redos: ReDoS-immunity regression suite ────────────────────────────────
    const redos_mod = libModule(b, publish, "redos", .{
        .root_source_file = b.path("src/engine/redos.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine_base, regex, pikevm, backtrack, auto, edfa, dfa },
    });
    const redos: std.Build.Module.Import = .{ .name = "redos", .module = redos_mod };

    // ── engine aggregate: thin re-export over the units (no tests of its own) ──
    const engine_mod = libModule(b, publish, "engine", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ engine_base, pikevm, backtrack, bytepike, literal, dfa, edfa, onepass, auto, regex, conformance, redos },
    });
    const engine: std.Build.Module.Import = .{ .name = "engine", .module = engine_mod };

    // ── ezi_gex facade: the published module (exe + bench + downstream use it) ─
    const mod = libModule(b, publish, "ezi_gex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ utils, core, engine },
    });

    return .{
        .ezi_code = ezi_code.module("ezi_code"),
        .utils = utils_mod,
        .core = core_mod,
        .engine_base = engine_base_mod,
        .pikevm = pikevm_mod,
        .backtrack = backtrack_mod,
        .bytepike = bytepike_mod,
        .literal = literal_mod,
        .onepass = onepass_mod,
        .dfa = dfa_mod,
        .edfa = edfa_mod,
        .auto = auto_mod,
        .regex = regex_mod,
        .conformance = conformance_mod,
        .redos = redos_mod,
        .engine = engine_mod,
        .ezi_gex = mod,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_tests = b.option(
        []const TestEnum,
        "include-test",
        "Test units to run with `zig build test` (default: all)",
    ) orelse &[_]TestEnum{.all};

    const lib = addModules(b, target, optimize, true);
    const mod = lib.ezi_gex;

    // ── fuzz: coverage-guided fuzz targets (Smith-driven) over the facade ──────
    // `fuzz_lib` (fuzz/lib.zig) holds what every fuzz binary shares: generators
    // (gen/), the independent reference matcher (ref/), and check bodies (check/).
    // It drives the published `ezi_gex` module exactly as a downstream user would,
    // and imports `ezi_code` DIRECTLY — the one module besides `utils` allowed to —
    // because the reference matcher must evaluate Unicode predicates per code point
    // without going through ezi_gex's own range tables (independence is its point).
    // The library itself still only sees `ezi_code` through `utils`.
    const fuzz_lib_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ezi_gex", .module = mod },
            .{ .name = "ezi_code", .module = lib.ezi_code },
        },
    });
    const fuzz_lib: std.Build.Module.Import = .{ .name = "fuzz_lib", .module = fuzz_lib_mod };
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ezi_gex", .module = mod }, fuzz_lib },
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
    const utils_tests = b.addTest(.{ .root_module = lib.utils });
    const core_tests = b.addTest(.{ .root_module = lib.core });
    const engine_base_tests = b.addTest(.{ .root_module = lib.engine_base });
    const backtrack_tests = b.addTest(.{ .root_module = lib.backtrack });
    const pikevm_tests = b.addTest(.{ .root_module = lib.pikevm });
    const bytepike_tests = b.addTest(.{ .root_module = lib.bytepike });
    const dfa_tests = b.addTest(.{ .root_module = lib.dfa });
    const edfa_tests = b.addTest(.{ .root_module = lib.edfa });
    const onepass_tests = b.addTest(.{ .root_module = lib.onepass });
    const literal_tests = b.addTest(.{ .root_module = lib.literal });
    const auto_tests = b.addTest(.{ .root_module = lib.auto });
    const regex_tests = b.addTest(.{ .root_module = lib.regex });
    const conformance_tests = b.addTest(.{ .root_module = lib.conformance });
    const redos_tests = b.addTest(.{ .root_module = lib.redos });
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
    // fuzz_lib's own unit tests (generators, reference matcher, check helpers) live in a
    // different module than the aggregate, so they are a separate binary — chained here so
    // `test-fuzz` / `-Dinclude-test=fuzz` runs both.
    const fuzz_lib_tests = b.addTest(.{ .root_module = fuzz_lib_mod });
    run_fuzz_tests.step.dependOn(&b.addRunArtifact(fuzz_lib_tests).step);
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
    // share the bodies in fuzz_lib (`fuzz/lib.zig`). The `fuzz` step
    // depends on all of them, and the build scheduler runs independent run-steps
    // concurrently — exactly like `zig build test` runs the 15 unit binaries at once
    // — so `zig build fuzz --fuzz=N` fuzzes every group in parallel, N iters EACH
    // (19 groups × N). Bare `zig build fuzz` is a finite seed-replay smoke of all.
    // Each group also gets a `zig build fuzz-<group>` step for a single session.
    // (The aggregate `fuzz` UNIT — fuzz/root.zig, run via `test-fuzz` and folded
    // into `zig build test` — still bundles every group into one binary for the
    // finite regression pass.)
    const fuzz_step = b.step("fuzz", "Fuzz every group in parallel (add --fuzz=N for N iters/group)");
    for (fuzz_groups) |fg| {
        const g = fg.name;
        const gmod = b.createModule(.{
            .root_source_file = b.path(b.fmt("fuzz/groups/{s}.zig", .{g})),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "ezi_gex", .module = mod }, fuzz_lib },
        });
        const gtest = b.addTest(.{ .root_module = gmod });
        const grun = b.addRunArtifact(gtest);
        const gstep = b.step(b.fmt("fuzz-{s}", .{g}), b.fmt("Fuzz only the {s} group (add --fuzz=N)", .{g}));
        gstep.dependOn(&grun.step);
        fuzz_step.dependOn(&grun.step); // `zig build fuzz` → every group, in parallel
    }

    // ── campaign: every group fuzzed for about the same wall time ────────────────
    // `--fuzz=N` is ONE global limit, so `zig build fuzz --fuzz=N` gives every group the same
    // N — seconds for `anchors`, hours for `search` (per-case cost spans ~300×). The campaign
    // instead runs each group as its own child `zig build fuzz-<group> --fuzz=<n>` with
    // n = the group's measured iterations per minute × -Dcampaign-minutes, so each group gets
    // roughly the requested time. Run steps have no timeout: the COUNT is the bound, and it
    // is approximate (inputs grow as the fuzzer finds coverage, so later iterations cost
    // more). The scheduler runs up to -j children at once (one fuzzer process each). Always
    // `safe`: the rates are measured there, and the fuzzer wants the safety checks. A failing
    // group fails the step with the child's output — the harness has already printed the
    // replay line and the auto-minimized case.
    const campaign_minutes = b.option(u32, "campaign-minutes", "`zig build campaign`: target minutes per group (default 10)") orelse 10;
    const campaign_only = b.option([]const []const u8, "campaign-group", "`zig build campaign`: only this group (repeat the flag)");
    // Wall time ≈ minutes × ceil(19 groups / -j), since each child fuzzes on one core.
    const campaign_step = b.step("campaign", "Fuzz every group for ~-Dcampaign-minutes each (default 10), counts sized per group");
    // `zig build fuzz-<group> --fuzz=N` exits 0 even when a fuzz test fails, so each group's
    // verdict comes from its captured stderr: `fuzz/campaign_report.zig` prints one summary
    // line for a clean group, or the whole log (replay line + minimized case) and exit 1.
    const campaign_report = b.addExecutable(.{
        .name = "campaign-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/campaign_report.zig"),
            .target = b.graph.host,
        }),
    });
    for (fuzz_groups) |fg| {
        if (campaign_only) |only| {
            const want = for (only) |o| {
                if (std.mem.eql(u8, o, fg.name)) break true;
            } else false;
            if (!want) continue;
        }
        const n = @as(u64, fg.per_minute) * campaign_minutes;
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("fuzz-{s}", .{fg.name}), b.fmt("--fuzz={d}", .{n}), "-Doptimize=safe" });
        run.setName(b.fmt("campaign {s} ({d} iterations)", .{ fg.name, n }));
        run.setCwd(b.path("."));
        // Captured (`check`) stdio, not the default: an `inherit` Run step holds the global
        // stderr lock for the child's whole life, which ran the groups one at a time.
        run.expectExitCode(0); // a build/compile error still fails here
        run.has_side_effects = true; // fuzzing is never "up to date"
        const report = b.addRunArtifact(campaign_report);
        report.addArgs(&.{ fg.name, b.fmt("{d}", .{n}) });
        report.addFileArg2(run.captureStdErr(.{}), .{});
        report.has_side_effects = true;
        campaign_step.dependOn(&report.step);
    }

    // `zig build fuzz-min -- '<FUZZ-CASE line>'`: replay a failing fuzz case and shrink it.
    const fuzz_min_exe = b.addExecutable(.{
        .name = "fuzz-min",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/min.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{fuzz_lib},
        }),
    });
    const run_fuzz_min = b.addRunArtifact(fuzz_min_exe);
    run_fuzz_min.addPassthruArgs();
    b.step("fuzz-min", "Replay and shrink a FUZZ-CASE line: zig build fuzz-min -- '<line>'").dependOn(&run_fuzz_min.step);

    // ── Benchmarks ────────────────────────────────────────────────────────────
    // Built against an `ezi_gex` module in `fast` mode by default so the engine is
    // measured optimized: `addModules` rebuilds the whole module graph at that level.
    const bench_optimize = b.option(
        std.lang.Optimize,
        "bench-optimize",
        "Optimization level for the bench executable (default fast)",
    ) orelse .fast;

    const bench_mod = addModules(b, target, bench_optimize, false).ezi_gex;

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
