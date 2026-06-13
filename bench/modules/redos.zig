//! ReDoS-immunity, made visible. Each case is a textbook catastrophic pattern fed its
//! worst-case input (a long run the inner quantifier chews on, ending in a byte that
//! blocks completion) at GROWING sizes. The headline is **throughput (MiB/s)**: a linear
//! engine holds it ~flat as the input grows (constant work per byte); a catastrophic one
//! (exponential or even Θ(n²)) makes throughput collapse as the input grows. A flat MiB/s
//! column down each pattern's 4 KiB → 256 KiB rows is the proof of linearity.
//!
//! This drives the default `auto` engine — what a user actually gets — so it also
//! exercises the eager-DFA / Pike VM path (auto routes large inputs off the recursive
//! backtracker; see backtrack.zig → "Resource bounds"). The deterministic, machine-
//! independent version of this guard lives in `src/engine/redos.zig` (it asserts the
//! backtracker's exact work count grows ~2× per input doubling); this bench is the
//! human-eyeballed companion.

const std = @import("std");
const framework = @import("../framework.zig");
const ezi_gex = @import("ezi_gex");

const Case = framework.Case;
const Context = framework.Context;
const RunResult = framework.RunResult;

const Auto = ezi_gex.engine.backends.auto;
const RX = ezi_gex.Compiled(Auto);

/// Sizes (bytes) each pattern is scanned at. Spanning 6 doublings makes a non-linear
/// trend impossible to miss in the ns/byte column.
// 4 KiB → 64 KiB: three doublings — enough that any non-linear trend is unmistakable in the
// MiB/s column (a flat column is linear; a ~16×-per-4× collapse was the Θ(n²) these patterns
// had before the prefilter fix). Kept modest so the full bench stays quick.
const sizes = [_]usize{ 4096, 16384, 65536 };

const Pat = struct { pat: []const u8, fill: u8, tail: u8 };

/// The corpus: nested quantifiers, overlapping alternations, quantified classes, and the
/// trailing-`$` "begin-but-don't-complete" Θ(n²) shape — the patterns that bring naive
/// engines down. Each `fill` run ends in a `tail` that prevents a match, forcing the
/// engine to do its full worst-case work.
const corpus = [_]Pat{
    .{ .pat = "a+b", .fill = 'a', .tail = '!' }, // prefix-literal begin-but-don't-complete (was Θ(n²))
    .{ .pat = "(a+)+$", .fill = 'a', .tail = '!' }, // nested +, end-anchored (was Θ(n²))
    .{ .pat = "(x+x+)+y", .fill = 'x', .tail = '!' }, // canonical bomb (was Θ(n²))
    .{ .pat = "a{4}b", .fill = 'a', .tail = '!' }, // fast-confirm (bounded tail): the KEPT memchr loop — must stay flat
    .{ .pat = "a{4,}b", .fill = 'a', .tail = '!' }, // unbounded tail → prone → reverse two-pass
    .{ .pat = "(a*)*$", .fill = 'a', .tail = '!' }, // nested *, end-anchored DFA
    .{ .pat = "(a|ab)*$", .fill = 'a', .tail = '!' }, // overlapping alternation
    .{ .pat = "\\w+@\\w+", .fill = 'a', .tail = '!' }, // interior literal, rare-byte prefilter
    .{ .pat = "[a-z]+$", .fill = 'a', .tail = '!' }, // trailing-$ class, reverse-from-end
};

const State = struct {
    re: RX,
    sc: RX.Scratch,
    inputs: [sizes.len][]u8,
    cur: usize = 0, // which size the next `run` measures
};

fn Bench(comptime p: Pat) type {
    return struct {
        var cached: ?State = null;

        fn setup(ctx: *Context) anyerror!void {
            const a = std.heap.page_allocator;
            if (cached == null) {
                var diag: ezi_gex.Diagnostic = .{};
                const re = try ezi_gex.compileRuntimeWith(Auto, a, p.pat, &diag, .{});
                var st = State{ .re = re, .sc = try RX.Scratch.init(a, &re.program), .inputs = undefined };
                for (sizes, 0..) |n, i| {
                    const buf = try a.alloc(u8, n);
                    @memset(buf, p.fill);
                    buf[n - 1] = p.tail;
                    st.inputs[i] = buf;
                }
                cached = st;
            }
            ctx.user = &cached.?;
        }

        // One case per (pattern, size): the framework calls `run` repeatedly for the
        // SAME size, so we pin the size via a per-case closure index rather than `cur`.
        fn runAt(comptime idx: usize) framework.RunFn {
            return struct {
                fn f(ctx: *Context) anyerror!RunResult {
                    const st: *State = @ptrCast(@alignCast(ctx.user.?));
                    const n = st.re.count(&st.sc, st.inputs[idx]); // count() = full worst-case scan
                    std.mem.doNotOptimizeAway(n);
                    return .{ .bytes_processed = st.inputs[idx].len, .ops = n };
                }
            }.f;
        }
    };
}

fn cases() []const Case {
    @setEvalBranchQuota(20_000);
    comptime var list: []const Case = &.{};
    inline for (corpus) |p| {
        const B = Bench(p);
        inline for (sizes, 0..) |n, i| {
            const name = std.fmt.comptimePrint("{s}  @{d}KiB", .{ p.pat, n / 1024 });
            list = list ++ &[_]Case{.{ .name = name, .notes = p.pat, .run = B.runAt(i), .setup = B.setup }};
        }
    }
    return list;
}

pub const suite: framework.Suite = .{
    .module_name = "redos",
    .description = "catastrophic patterns at growing sizes — throughput (MiB/s) must stay FLAT (linear = ReDoS-immune).",
    .corpus_independent = true, // the bench builds its own inputs; corpus is irrelevant
    .cases = cases(),
};
