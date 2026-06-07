//! Compile throughput: pattern → AST → HIR → Pike VM program, then free. This is
//! corpus-independent, so the three rows are ~equal (a sanity check that compile
//! cost doesn't depend on match input). Throughput is pattern-bytes/sec; ops/sec
//! is patterns-compiled/sec. The memory column shows per-compile allocation.

const std = @import("std");
const framework = @import("../framework.zig");
const ezi_gex = @import("ezi_gex");

const Context = framework.Context;
const RunResult = framework.RunResult;

const PikeVM = ezi_gex.engine.backends.pikevm;

const patterns = [_][]const u8{
    "the",
    "\\w+",
    "[A-Za-z0-9_]+",
    "foo|bar|baz|qux",
    "\\d{3}-\\d{4}",
    "(\\w+)@(\\w+)\\.(\\w+)",
    "(?<y>\\d{4})-(?<m>\\d{2})-(?<d>\\d{2})",
    "a.*b",
    "\\p{L}+",
    "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$",
};

const inner: u32 = 20;

fn run(ctx: *Context) anyerror!RunResult {
    var bytes: u64 = 0;
    var ops: u64 = 0;
    var n: u32 = 0;
    while (n < inner) : (n += 1) {
        for (patterns) |p| {
            var diag: ezi_gex.Diagnostic = .{};
            var re = ezi_gex.compileRuntimeWith(PikeVM, ctx.allocator, p, &diag, .{}) catch continue;
            re.deinit();
            bytes += p.len;
            ops += 1;
        }
    }
    return .{ .bytes_processed = bytes, .ops = ops };
}

pub const suite: framework.Suite = .{
    .module_name = "compile",
    .description = "compileRuntime() over a 10-pattern set (corpus-independent; rows ~equal).",
    .cases = &.{
        .{ .name = "compileRuntime x10 patterns", .notes = "parse + HIR + Pike VM build + free", .run = run },
    },
};
