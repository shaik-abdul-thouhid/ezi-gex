//! Vacuity guards: the fuzz suite must not pass by doing nothing.
//!
//! A differential in which a backend is *skipped* on every case, or a generator that
//! mostly emits empty or scanner-rejected patterns, still "passes" — silently. These
//! finite tests run each generator and check body over fixed-seed `Smith` inputs and
//! assert: generators emit valid, non-trivial patterns; every backend is actually
//! COMPARED on at least a floor fraction of valid cases. Floors come from measured values
//! with margin (fuzz/README.md → Health). A floor that trips is a finding first (vacuity),
//! a floor adjustment only with a stated reason.

const std = @import("std");
const gex = @import("ezi_gex");
const lib = @import("fuzz_lib");
const common = lib.check.common;
const d = lib.check.differential;
const ps = lib.gen.pattern;
const Smith = std.testing.Smith;

pub const gen_seeds = 2000;
pub const body_seeds = 400;

/// A replaying `Smith` over PRNG bytes. Replay-mode `eos` is `byte != 0`, so generators
/// must not steer loops with `eos` — see Task 3 background. Also: every replayed draw
/// consumes an 8-byte little-endian word, and a word OUTSIDE the requested range silently
/// falls back to the range minimum. Raw random bytes would therefore be almost all
/// out-of-range (all-minimum patterns), so the buffer is filled with small u64 words
/// (half uniform 0..11, half 1..5), which land inside the small ranges the generators draw from.
/// Words beyond `buf.len / 8` draws read as the minimum (the generators terminate).
pub fn smithFrom(prng: *std.Random.DefaultPrng, buf: []u8) Smith {
    const r = prng.random();
    var i: usize = 0;
    while (i + 8 <= buf.len) : (i += 8) {
        // Half the words span 0..11 so high indices (property tables, shorthand kinds)
        // are reachable; the rest sit in 1..5 so count draws are rarely zero/out of range.
        const v: u64 = if (r.boolean()) r.uintLessThan(u8, 12) else 1 + r.uintLessThan(u8, 5);
        std.mem.writeInt(u64, buf[i..][0..8], v, .little);
    }
    return .{ .in = buf };
}

pub const GenStats = struct { valid: f64, mean_len: f64, nonempty: f64 };

/// Validity / size profile of `genFn` over `gen_seeds` fixed seeds.
pub fn genStats(comptime genFn: anytype) GenStats {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4ea1_7400);
    var buf: [4096]u8 = undefined;
    var ok: usize = 0;
    var total_len: usize = 0;
    var nonempty: usize = 0;
    for (0..gen_seeds) |_| {
        var s = smithFrom(&prng, &buf);
        const p = genFn(&s);
        const pat = p.slice();
        total_len += pat.len;
        if (pat.len > 0) nonempty += 1;
        var diag: gex.Diagnostic = .{};
        if (gex.parse(gpa, pat, &diag)) |a| {
            ok += 1;
            a.deinit(gpa);
        } else |_| {}
    }
    const n: f64 = @floatFromInt(gen_seeds);
    return .{
        .valid = @as(f64, @floatFromInt(ok)) / n,
        .mean_len = @as(f64, @floatFromInt(total_len)) / n,
        .nonempty = @as(f64, @floatFromInt(nonempty)) / n,
    };
}

/// Run `body` over `seeds` fixed seeds with fresh stats and per-case reporting suppressed.
/// Returns how many iterations failed. The first few failures are then replayed LOUDLY — the
/// replay line and the minimized case — so a divergence found while measuring is a report,
/// never just a count (one such divergence once sat here unreported). Stats stay as measured.
pub fn measure(comptime body: anytype, seed: u64, seeds: usize) usize {
    common.stats.reset();
    common.quiet = true;
    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [4096]u8 = undefined;
    var failures: usize = 0;
    var failed_at: [3]std.Random.DefaultPrng = undefined;
    for (0..seeds) |_| {
        const before = prng;
        var s = smithFrom(&prng, &buf);
        body({}, &s) catch {
            if (failures < failed_at.len) failed_at[failures] = before;
            failures += 1;
        };
    }
    common.quiet = false;
    const measured = common.stats;
    for (failed_at[0..@min(failures, failed_at.len)]) |p| {
        var again = p;
        var s = smithFrom(&again, &buf);
        body({}, &s) catch {};
    }
    common.stats = measured;
    return failures;
}

fn expectClean(name: []const u8, failures: usize) !void {
    if (failures == 0) return;
    std.debug.print("health: {s} failed on {d} fixed-seed case(s), replayed above — triage it (fix, or gate + ledger entry)\n", .{ name, failures });
    return error.FailureWhileMeasuring;
}

/// valid / seeds: how often the body got as far as its check at all.
fn expectReach(check: common.CheckId, seeds: usize, min: f64) !void {
    const got = @as(f64, @floatFromInt(common.stats.valid[@backingInt(check)])) / @as(f64, @floatFromInt(seeds));
    if (got < min) {
        std.debug.print("health: {s} reached its check on {d:.3} of cases (floor {d:.3}) — vacuous?\n", .{ @tagName(check), got, min });
        printTable(check);
        return error.VacuousCheck;
    }
}

pub fn printTable(check: common.CheckId) void {
    std.debug.print("health[{s}] runs={d} valid={d}:", .{ @tagName(check), common.stats.runs[@backingInt(check)], common.stats.valid[@backingInt(check)] });
    for (common.backend_names, 0..) |name, bi| std.debug.print(" {s}={d:.2}", .{ name, common.comparedFraction(check, bi) });
    std.debug.print("\n", .{});
}

pub fn expectFloor(check: common.CheckId, backend: []const u8, min: f64) !void {
    for (common.backend_names, 0..) |name, bi| {
        if (!std.mem.eql(u8, name, backend)) continue;
        const got = common.comparedFraction(check, bi);
        if (got < min) {
            std.debug.print("health: {s}/{s} compared on {d:.3} of valid cases (floor {d:.3}) — vacuous?\n", .{ @tagName(check), backend, got, min });
            printTable(check);
            return error.VacuousCheck;
        }
        return;
    }
    return error.UnknownBackend;
}

fn expectGen(name: []const u8, st: GenStats, min_valid: f64, min_mean_len: f64, min_nonempty: f64) !void {
    if (st.valid < min_valid or st.mean_len < min_mean_len or st.nonempty < min_nonempty) {
        std.debug.print("health: generator {s}: valid={d:.3} (floor {d:.2}) mean_len={d:.1} (floor {d:.1}) nonempty={d:.3} (floor {d:.2})\n", .{ name, st.valid, min_valid, st.mean_len, min_mean_len, st.nonempty, min_nonempty });
        return error.GeneratorVacuous;
    }
}

test "health: generators emit valid, non-trivial patterns" {
    try expectGen("gen", genStats(ps.gen), 0.70, 12.95, 0.60);
    try expectGen("genAnchors", genStats(ps.genAnchors), 0.80, 3.65, 0.45);
    try expectGen("genUnicode", genStats(ps.genUnicode), 0.80, 4.95, 0.45);
}

test "health: span differential compares every backend" {
    try expectClean("span", measure(d.backendsAgree, 0xd1ff, body_seeds));
    try expectFloor(.span, "backtrack", 0.80);
    try expectFloor(.span, "auto", 0.80);
    try expectFloor(.span, "bytepike", 0.75);
    try expectFloor(.span, "dfa", 0.70);
    try expectFloor(.span, "edfa", 0.70);
    try expectFloor(.span, "onepass", 0.45);
}

test "health: unicode differential compares the code-point engines" {
    try expectClean("unicode", measure(d.unicodeAgree, 0x0c0de, body_seeds));
    try expectFloor(.unicode, "backtrack", 0.80);
    try expectFloor(.unicode, "auto", 0.80);
}

test "health: every generator property name is scanner-accepted" {
    // The generator's own vocabulary must parse: a rejected name silently spends budget on
    // the reject path (the original genUnicode list had 4 such names).
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    var bad: usize = 0;
    for (ps.uni_props) |name| {
        const pat = std.fmt.bufPrint(&buf, "\\p{{{s}}}", .{name}) catch unreachable;
        var diag: gex.Diagnostic = .{};
        if (gex.parse(gpa, pat, &diag)) |a| {
            a.deinit(gpa);
        } else |_| {
            std.debug.print("health: generator property name rejected by scanner: {s}\n", .{name});
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

const known_open = lib.check.known_open;

/// No active gate may account for more than 1 % of `runs` fuzz iterations.
pub fn gateRatesOk(runs: usize) bool {
    for (known_open.active, 0..) |g, i| {
        if (i >= common.max_gates) break;
        if (@as(usize, common.stats.gated[i]) * 100 > runs) {
            std.debug.print("health: gate {s} swallowed {d} of {d} cases (> 1%)\n", .{ g.id, common.stats.gated[i], runs });
            return false;
        }
    }
    return true;
}

const Floor = struct { backend: []const u8, min: f64 };
const Row = struct {
    check: common.CheckId,
    /// Fixed seeds to run; the heavy checks run fewer so the suite stays in its time budget.
    seeds: usize,
    /// Floor on valid / seeds (`expectReach`).
    reach: f64,
    /// Floors on compared / valid per backend (`expectFloor`). A backend a check never runs
    /// by design (the oracle, or one without the capability) has no row.
    floors: []const Floor = &.{},
};

/// Every check body with its floors — each ~0.8 × the value measured at seed 0x6a7e over
/// `seeds` (fuzz/README.md → Health). To re-measure after changing a body or generator, call
/// `printTable(row.check)` (and print valid/seeds) in the test below, then set ~0.8× each.
const rows = .{
    .{ d.anchorsAgree, Row{ .check = .anchors, .seeds = 400, .reach = 0.80, .floors = &.{ .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.77 }, .{ .backend = "dfa", .min = 0.57 }, .{ .backend = "edfa", .min = 0.56 }, .{ .backend = "onepass", .min = 0.49 }, .{ .backend = "literal", .min = 0.43 } } } },
    .{ d.capturesAgree, Row{ .check = .captures, .seeds = 200, .reach = 0.74, .floors = &.{ .{ .backend = "backtrack", .min = 0.86 }, .{ .backend = "auto", .min = 0.86 }, .{ .backend = "bytepike", .min = 0.82 }, .{ .backend = "onepass", .min = 0.50 } } } },
    .{ d.iterationAgree, Row{ .check = .iter, .seeds = 100, .reach = 0.74, .floors = &.{ .{ .backend = "backtrack", .min = 0.86 }, .{ .backend = "auto", .min = 0.86 }, .{ .backend = "bytepike", .min = 0.84 }, .{ .backend = "dfa", .min = 0.79 }, .{ .backend = "edfa", .min = 0.76 } } } },
    .{ d.replaceAgree, Row{ .check = .replace, .seeds = 200, .reach = 0.74, .floors = &.{ .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.76 } } } },
    .{ d.searchOffsetAgree, Row{ .check = .offset, .seeds = 100, .reach = 0.74, .floors = &.{ .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.78 }, .{ .backend = "dfa", .min = 0.72 }, .{ .backend = "edfa", .min = 0.70 } } } },
    .{ d.strategyInvariant, Row{ .check = .strategy, .seeds = 100, .reach = 0.74, .floors = &.{} } },
    .{ lib.check.reference.fuzzOne, Row{ .check = .reference, .seeds = 400, .reach = 0.80, .floors = &.{ .{ .backend = "pikevm", .min = 0.80 }, .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 } } } },
    .{ lib.check.metamorphic.fuzzOne, Row{ .check = .metamorphic, .seeds = 200, .reach = 0.80, .floors = &.{ .{ .backend = "pikevm", .min = 0.80 }, .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.74 }, .{ .backend = "dfa", .min = 0.65 }, .{ .backend = "edfa", .min = 0.64 }, .{ .backend = "onepass", .min = 0.52 }, .{ .backend = "literal", .min = 0.32 } } } },
    .{ lib.check.invariants.fuzzOne, Row{ .check = .invariants, .seeds = 100, .reach = 0.80, .floors = &.{ .{ .backend = "pikevm", .min = 0.73 }, .{ .backend = "backtrack", .min = 0.73 }, .{ .backend = "auto", .min = 0.73 }, .{ .backend = "bytepike", .min = 0.68 }, .{ .backend = "dfa", .min = 0.61 }, .{ .backend = "edfa", .min = 0.60 }, .{ .backend = "onepass", .min = 0.45 }, .{ .backend = "literal", .min = 0.22 } } } },
    .{ lib.check.state.fuzzOne, Row{ .check = .state, .seeds = 100, .reach = 0.80, .floors = &.{ .{ .backend = "pikevm", .min = 0.73 }, .{ .backend = "backtrack", .min = 0.73 }, .{ .backend = "auto", .min = 0.73 }, .{ .backend = "bytepike", .min = 0.69 }, .{ .backend = "dfa", .min = 0.61 }, .{ .backend = "edfa", .min = 0.60 }, .{ .backend = "onepass", .min = 0.45 }, .{ .backend = "literal", .min = 0.22 } } } },
    .{ lib.check.large.fuzzOne, Row{ .check = .large, .seeds = 200, .reach = 0.80, .floors = &.{ .{ .backend = "backtrack", .min = 0.43 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.69 }, .{ .backend = "dfa", .min = 0.64 }, .{ .backend = "edfa", .min = 0.64 }, .{ .backend = "onepass", .min = 0.52 }, .{ .backend = "literal", .min = 0.32 } } } },
    .{ lib.check.literal_sets.fuzzOne, Row{ .check = .literals, .seeds = 400, .reach = 0.80, .floors = &.{ .{ .backend = "backtrack", .min = 0.44 }, .{ .backend = "auto", .min = 3.20 }, .{ .backend = "bytepike", .min = 0.80 }, .{ .backend = "dfa", .min = 0.80 }, .{ .backend = "edfa", .min = 0.80 }, .{ .backend = "literal", .min = 0.32 } } } },
    .{ lib.check.api.fuzzOne, Row{ .check = .api, .seeds = 200, .reach = 0.73, .floors = &.{ .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.73 }, .{ .backend = "onepass", .min = 0.46 } } } },
    .{ lib.check.oom.fuzzOne, Row{ .check = .oom, .seeds = 200, .reach = 0.71, .floors = &.{ .{ .backend = "pikevm", .min = 0.12 }, .{ .backend = "backtrack", .min = 0.12 }, .{ .backend = "auto", .min = 0.05 }, .{ .backend = "bytepike", .min = 0.08 }, .{ .backend = "dfa", .min = 0.07 }, .{ .backend = "edfa", .min = 0.12 }, .{ .backend = "onepass", .min = 0.09 }, .{ .backend = "literal", .min = 0.12 } } } },
    .{ lib.check.comptime_parity.fuzzOne, Row{ .check = .comptime_parity, .seeds = 400, .reach = 0.80, .floors = &.{ .{ .backend = "pikevm", .min = 0.80 }, .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 } } } },
    .{ lib.check.complexity.fuzzOne, Row{ .check = .complexity, .seeds = 200, .reach = 0.73, .floors = &.{ .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.79 } } } },
    .{ lib.check.complexity.bombOne, Row{ .check = .compile_bomb, .seeds = 100, .reach = 0.80, .floors = &.{.{ .backend = "auto", .min = 0.80 }} } },
    .{ lib.check.utf8class.fuzzOne, Row{ .check = .utf8class, .seeds = 400, .reach = 0.80, .floors = &.{ .{ .backend = "pikevm", .min = 0.80 }, .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 }, .{ .backend = "bytepike", .min = 0.80 }, .{ .backend = "dfa", .min = 0.80 }, .{ .backend = "edfa", .min = 0.80 }, .{ .backend = "onepass", .min = 0.80 } } } },
    .{ lib.check.chaos.fuzzOne, Row{ .check = .chaos, .seeds = 100, .reach = 0.80, .floors = &.{} } },
    .{ lib.check.scanner.fuzzOne, Row{ .check = .scanner, .seeds = 200, .reach = 0.80, .floors = &.{} } },
    .{ lib.check.grapheme.fuzzOne, Row{ .check = .grapheme, .seeds = 400, .reach = 0.80, .floors = &.{ .{ .backend = "backtrack", .min = 0.80 }, .{ .backend = "auto", .min = 0.80 } } } },
};

test "health: every check reaches its backends, fails nothing, and no gate swallows > 1%" {
    inline for (rows) |r| {
        const row: Row = r[1];
        try expectClean(@tagName(row.check), measure(r[0], 0x6a7e, row.seeds));
        try std.testing.expect(gateRatesOk(row.seeds));
        try expectReach(row.check, row.seeds, row.reach);
        for (row.floors) |f| try expectFloor(row.check, f.backend, f.min);
    }
}

test "health: the gate-rate guard fires on an over-broad gate" {
    const saved = known_open.active;
    defer known_open.active = saved;
    const everything = struct {
        fn f(_: *const common.Case) bool {
            return true;
        }
    }.f;
    const fake = [_]known_open.Gate{.{ .id = "fake-over-broad", .applies = everything }};
    known_open.active = &fake;
    _ = measure(lib.check.invariants.fuzzOne, 0x6a7e, 50);
    try std.testing.expect(!gateRatesOk(50));
}
