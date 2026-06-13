//! Full-input scan throughput: `count()` every non-overlapping match across the
//! corpus. Throughput is bytes-scanned/sec (the headline MiB/s); ops/sec is
//! matches found/sec.
//!
//! Compilation is NOT what this measures: each pattern is compiled **once** and
//! its regex + scratch are cached for the whole run (reused across every corpus
//! and sample), so the timed `run` is pure matching — zero compile, zero alloc.

const std = @import("std");
const framework = @import("../framework.zig");
const ezi_gex = @import("ezi_gex");

const Case = framework.Case;
const Context = framework.Context;
const RunResult = framework.RunResult;

const Auto = ezi_gex.engine.backends.auto;
const RX = ezi_gex.Compiled(Auto);

const State = struct {
    re: RX,
    sc: RX.Scratch,
};

/// One case bound to a fixed pattern, with a process-lifetime compile cache so it
/// compiles exactly once (not once per corpus). Freed at process exit.
fn Pattern(comptime pat: []const u8) type {
    return struct {
        var cached: ?State = null;

        fn setup(ctx: *Context) anyerror!void {
            if (cached == null) {
                const a = std.heap.page_allocator;
                var diag: ezi_gex.Diagnostic = .{};
                var re = try ezi_gex.compileRuntimeWith(Auto, a, pat, &diag, .{});
                const sc = try RX.Scratch.init(a, &re.program);
                cached = .{ .re = re, .sc = sc };
                // print-once: show the work this bench will measure.
                const n = cached.?.re.count(&cached.?.sc, ctx.corpus.bytes);
                std.debug.print("    (compiled once) /{s}/ → {d} matches in {s}\n", .{ pat, n, ctx.corpus.name });
            }
            ctx.user = &cached.?;
        }

        fn run(ctx: *Context) anyerror!RunResult {
            const st: *State = @ptrCast(@alignCast(ctx.user.?));
            const n = st.re.count(&st.sc, ctx.corpus.bytes);
            std.mem.doNotOptimizeAway(n);
            return .{ .bytes_processed = ctx.corpus.bytes.len, .ops = n };
        }
    };
}

fn case(comptime name: []const u8, comptime pat: []const u8) Case {
    const P = Pattern(pat);
    return .{ .name = name, .notes = pat, .run = P.run, .setup = P.setup };
}

pub const suite: framework.Suite = .{
    .module_name = "search",
    .description = "count() every non-overlapping match — throughput is bytes scanned/sec (compile cached).",
    .cases = &.{
        case("literal", "the"),
        case("word", "\\w+"),
        case("class", "[A-Za-z]+"),
        case("alternation", "foo|bar|baz|qux"),
        case("digits", "\\d+"),
        case("email-ish", "\\w+@\\w+"),
        case("dot-star", "a.*b"),
        case("anchored-ml", "(?m)^\\w+"),
        case("unicode-prop", "\\p{L}+"),
        case("case-insens", "(?i)the"),
    },
};
