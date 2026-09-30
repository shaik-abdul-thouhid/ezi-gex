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

/// Run `body` over `body_seeds` fixed seeds with fresh stats and reporting suppressed.
/// Returns how many iterations returned an error (a divergence found while measuring —
/// counted, not failed: finding bugs is the groups' job, measuring reach is ours).
pub fn measure(comptime body: anytype, seed: u64) usize {
    common.stats.reset();
    common.quiet = true;
    defer common.quiet = false;
    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [4096]u8 = undefined;
    var failures: usize = 0;
    for (0..body_seeds) |_| {
        var s = smithFrom(&prng, &buf);
        body({}, &s) catch {
            failures += 1;
        };
    }
    return failures;
}

pub fn printTable(check: common.CheckId) void {
    std.debug.print("health[{s}] runs={d} valid={d}:", .{ @tagName(check), common.stats.runs[@intFromEnum(check)], common.stats.valid[@intFromEnum(check)] });
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
    _ = measure(d.backendsAgree, 0xd1ff);
    try expectFloor(.span, "backtrack", 0.80);
    try expectFloor(.span, "auto", 0.80);
    try expectFloor(.span, "bytepike", 0.75);
    try expectFloor(.span, "dfa", 0.70);
    try expectFloor(.span, "edfa", 0.70);
    try expectFloor(.span, "onepass", 0.45);
}

test "health: unicode differential compares the code-point engines" {
    _ = measure(d.unicodeAgree, 0x0c0de);
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
