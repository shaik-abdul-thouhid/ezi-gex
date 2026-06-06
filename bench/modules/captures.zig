//! Capture-extraction throughput: `capturesAll()` (pull submatches for every
//! match) and `replaceAll()` (substitute with `$n` templates) across the corpus.
//!
//! As with `search`, compilation is cached: each pattern compiles **once** and its
//! regex + scratch + buffers are reused across every corpus and sample, so the
//! timed `run` measures only capture/replace work.

const std = @import("std");
const framework = @import("../framework.zig");
const ezi_gex = @import("ezi_gex");

const Case = framework.Case;
const Context = framework.Context;
const RunResult = framework.RunResult;

const PikeVM = ezi_gex.engine.backends.pikevm;
const RX = ezi_gex.Compiled(PikeVM);

const State = struct {
    re: RX,
    sc: RX.Scratch,
    slots: []?usize,
    out: []u8, // replaceAll output buffer
};

fn Pattern(comptime pat: []const u8, comptime tmpl: []const u8) type {
    return struct {
        var cached: ?State = null;

        fn setup(ctx: *Context) anyerror!void {
            if (cached == null) {
                const a = std.heap.page_allocator;
                var diag: ezi_gex.Diagnostic = .{};
                var re = try ezi_gex.compileRuntime(a, pat, &diag, .{});
                cached = .{
                    .re = re,
                    .sc = try re.newScratch(a),
                    .slots = try a.alloc(?usize, re.slotCount()),
                    .out = try a.alloc(u8, ctx.corpus.bytes.len * 2 + 1024),
                };
                var it = cached.?.re.capturesAll(&cached.?.sc, cached.?.slots, ctx.corpus.bytes);
                var m: usize = 0;
                while (it.next()) |_| m += 1;
                std.debug.print("    (compiled once) /{s}/ → {d} matches in {s}\n", .{ pat, m, ctx.corpus.name });
            }
            ctx.user = &cached.?;
        }

        fn capturesAllRun(ctx: *Context) anyerror!RunResult {
            const st: *State = @ptrCast(@alignCast(ctx.user.?));
            var it = st.re.capturesAll(&st.sc, st.slots, ctx.corpus.bytes);
            var matches: u64 = 0;
            var sumlen: u64 = 0;
            while (it.next()) |c| {
                matches += 1;
                sumlen += c.match().len();
            }
            std.mem.doNotOptimizeAway(sumlen);
            return .{ .bytes_processed = ctx.corpus.bytes.len, .ops = matches };
        }

        fn replaceRun(ctx: *Context) anyerror!RunResult {
            const st: *State = @ptrCast(@alignCast(ctx.user.?));
            var w = std.Io.Writer.fixed(st.out);
            try st.re.replaceAll(&st.sc, ctx.corpus.bytes, tmpl, st.slots, &w);
            std.mem.doNotOptimizeAway(w.buffered().len);
            return .{ .bytes_processed = ctx.corpus.bytes.len };
        }
    };
}

fn capturesCase(comptime name: []const u8, comptime pat: []const u8) Case {
    const P = Pattern(pat, "");
    return .{ .name = name, .notes = pat, .run = P.capturesAllRun, .setup = P.setup };
}

fn replaceCase(comptime name: []const u8, comptime pat: []const u8, comptime tmpl: []const u8) Case {
    const P = Pattern(pat, tmpl);
    return .{ .name = name, .notes = pat, .run = P.replaceRun, .setup = P.setup };
}

pub const suite: framework.Suite = .{
    .module_name = "captures",
    .description = "capturesAll() + replaceAll() over the corpus (compile cached; throughput = bytes/sec).",
    .cases = &.{
        capturesCase("capturesAll email", "(\\w+)@(\\w+)"),
        capturesCase("capturesAll date", "(\\d+)-(\\d+)-(\\d+)"),
        replaceCase("replaceAll email -> $2.$1", "(\\w+)@(\\w+)", "$2.$1"),
        replaceCase("replaceAll word -> [$0]", "\\w+", "[$0]"),
    },
};
