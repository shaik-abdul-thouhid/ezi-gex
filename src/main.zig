const std = @import("std");

const ezi_gex = @import("ezi_gex");

// Until the `Regex`/`Compiled` front door lands, wire the pipeline by hand:
// pattern → AST → HIR → Pike VM `Program`, then drive it through the
// backend-agnostic `Engine` (isMatch/find/captures/findAll/count/split/replace).
const PikeVM = ezi_gex.engine.backends.pikevm;
const E = ezi_gex.engine.Engine(PikeVM);

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator(); // arena: freed wholesale at exit

    const pattern = "(\\w+)@(\\w+)\\.(\\w+)";
    const input = "contact: alice@example.com and bob@test.org";

    // ── compile: pattern → AST → HIR → program ───────────────────────────────
    var diag: ezi_gex.Diagnostic = .{};
    const ast = ezi_gex.parse(gpa, pattern, &diag) catch |err| {
        std.debug.print("invalid regex: {s} at \"{s}\"\n", .{ diag.message(), diag.faultySlice(pattern) });
        return err;
    };
    const hir = try ezi_gex.buildHir(gpa, ast, .{});
    var program = try PikeVM.buildAlloc(gpa, hir, .{});
    var scratch = try PikeVM.Scratch.init(gpa, &program);
    const meta = ezi_gex.engine.Meta{ .capture_count = hir.capture_count };

    std.debug.print("pattern: {s}\ninput:   {s}\n\n", .{ pattern, input });

    // ── isMatch / find ────────────────────────────────────────────────────────
    std.debug.print("isMatch: {}\n", .{E.isMatch(&program, &scratch, input, .{})});
    if (E.find(&program, &scratch, input, .{})) |m| {
        std.debug.print("first:   \"{s}\" at [{d}..{d}]\n", .{ m.slice(input), m.start, m.end });
    }

    // ── capturesAll: every match with its submatches ──────────────────────────
    std.debug.print("\nall matches (user / host / tld):\n", .{});
    var slots: [8]?usize = undefined; // 2 * (capture_count + 1)
    var it = E.capturesAll(&program, &scratch, input, &slots, meta, .{});
    var i: usize = 0;
    while (it.next()) |c| {
        i += 1;
        std.debug.print("  {d}. {s}  ->  {s} / {s} / {s}\n", .{
            i,                 c.match().slice(input),
            c.groupSlice(1).?, c.groupSlice(2).?,
            c.groupSlice(3).?,
        });
    }
    std.debug.print("\ncount:   {d}\n", .{E.count(&program, &scratch, input, .{})});

    // ── replaceAll with capture references ($1, $2 …) ─────────────────────────
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&program, &scratch, input, "$1 [at] $2 [dot] $3", &slots, meta, &w);
    std.debug.print("redact:  {s}\n", .{w.buffered()});

    // ── split on a separate pattern ───────────────────────────────────────────
    var sdiag: ezi_gex.Diagnostic = .{};
    const sep_ast = try ezi_gex.parse(gpa, "\\s*,\\s*", &sdiag);
    var sep_prog = try PikeVM.buildAlloc(gpa, try ezi_gex.buildHir(gpa, sep_ast, .{}), .{});
    var sep_scratch = try PikeVM.Scratch.init(gpa, &sep_prog);
    std.debug.print("\nsplit \"a, b ,c,d\" on /\\s*,\\s*/:\n", .{});
    var sit = E.split(&sep_prog, &sep_scratch, "a, b ,c,d", .{});
    while (sit.next()) |piece| std.debug.print("  [{s}]\n", .{piece});

    // ── a Unicode flex: \w is Unicode-aware ───────────────────────────────────
    var udiag: ezi_gex.Diagnostic = .{};
    const u_ast = try ezi_gex.parse(gpa, "\\w+", &udiag);
    var u_prog = try PikeVM.buildAlloc(gpa, try ezi_gex.buildHir(gpa, u_ast, .{}), .{});
    var u_scratch = try PikeVM.Scratch.init(gpa, &u_prog);
    if (E.find(&u_prog, &u_scratch, "héllo, wörld", .{})) |m| {
        std.debug.print("\nunicode \\w+ on \"héllo, wörld\": \"{s}\"\n", .{m.slice("héllo, wörld")});
    }

    // ── invalid pattern: report a diagnostic, don't crash ─────────────────────
    // The runtime `parse` returns `error.InvalidPattern` and fills `diag` with a
    // code + byte span. Catch it, print, and carry on — no panic, no abort.
    const bad_pattern = "a(b|c[d-";
    var bad_diag: ezi_gex.Diagnostic = .{};
    if (ezi_gex.parse(gpa, bad_pattern, &bad_diag)) |bad_ast| {
        bad_ast.deinit(gpa); // unreachable for this pattern, but shown for symmetry
    } else |err| {
        std.debug.print("\n", .{});
        printDiagnostic(bad_pattern, bad_diag);
        std.debug.print("handled {s} gracefully — program continues.\n", .{@errorName(err)});
    }

    // ══ Front door: the simple way (compileRuntime / compileComptime) ══════════
    // No manual pipeline — `compile*` returns a ready regex. The caller only
    // touches isMatch / find / captures, and owns the Scratch.
    std.debug.print("\n── front door ──\n", .{});

    // Runtime: compile from a (possibly user-supplied) pattern. On a bad pattern
    // this returns error.InvalidPattern + a filled diagnostic — never crashes.
    var rdiag: ezi_gex.Diagnostic = .{};
    var re = ezi_gex.compileRuntime(gpa, "(?<word>\\p{L}+)", &rdiag, .{}) catch |err| {
        printDiagnostic("(?<word>\\p{L}+)", rdiag);
        return err;
    };
    defer re.deinit(); // frees the heap program

    // The Scratch is the per-search working state — you own it, reuse it across
    // searches, one per thread. The front door never builds it for you: construct it
    // directly off the backend's `Scratch` type (heap-backed here). For a no-allocator
    // path use `@TypeOf(re).Scratch.initBuffer(buf, &re.program)` over a
    // `@TypeOf(re).Scratch.bufferLen(&re.program)`-sized `@TypeOf(re).Scratch.Buf` buffer.
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);

    const text = "Þú ert hér 2026";
    std.debug.print("isMatch: {}\n", .{re.isMatch(&sc, text)});
    if (re.find(&sc, text)) |m| std.debug.print("find:    \"{s}\"\n", .{m.slice(text)});

    // ── slots: the capture-output buffer ──────────────────────────────────────
    // `captures`/`capturesAll`/`replaceAll` write match boundaries into a `[]?usize`
    // you provide: two entries (start, end) per group, plus the whole match at
    // index 0. So you need exactly `re.slotCount()` == 2*(captureCount+1) slots.
    // At runtime, capture_count is dynamic → heap-allocate that many:
    const cap_slots = try gpa.alloc(?usize, re.slotCount());
    std.debug.print("slotCount: {d} (= 2*({d} groups + 1))\n", .{ re.slotCount(), re.captureCount() });
    if (re.captures(&sc, cap_slots, text)) |c| {
        std.debug.print("named:   word = \"{s}\"\n", .{c.namedSlice("word").?});
    }

    // Comptime: the program is baked into the binary and the match runs at compile
    // time — no allocator, no Scratch to manage. `capturesComptime` resolves the
    // groups during const-eval and freezes them into ro_data, so the returned view
    // works here at runtime too (this rounds out isMatchComptime/findComptime).
    const Re = comptime ezi_gex.compileComptime("(\\d{4})-(\\d{2})", .{});
    if (comptime Re.capturesComptime("y2026-06")) |c| {
        std.debug.print("comptime captures: {s} / {s}\n", .{ c.groupSlice(1).?, c.groupSlice(2).? });
    }

    // …and the same with *named* groups — `namedSlice` resolves at compile time too,
    // so you can pull a group out by name entirely during const-eval.
    const ReNamed = comptime ezi_gex.compileComptime("(?<year>\\d{4})-(?<month>\\d{2})", .{});
    if (comptime ReNamed.capturesComptime("y2026-06")) |c| {
        std.debug.print("comptime named:    year={s} month={s}\n", .{ c.namedSlice("year").?, c.namedSlice("month").? });
    }
    // Pulled out as plain comptime constants (the slices live in ro_data):
    const year = comptime ReNamed.capturesComptime("y2026-06").?.namedSlice("year").?;
    std.debug.print("comptime const:    year = \"{s}\"\n", .{year});
}

/// Pretty-print a parse diagnostic with a caret under the offending span. Pure
/// formatting over the public `Diagnostic` API — nothing here can fail or crash.
fn printDiagnostic(pattern: []const u8, diag: ezi_gex.Diagnostic) void {
    std.debug.print("invalid regex: {s}\n  {s}\n  ", .{ diag.message(), pattern });
    var col: usize = 0;
    while (col < diag.span.start) : (col += 1) std.debug.print(" ", .{});
    const width = @max(diag.span.end - diag.span.start, 1); // point spans still get one caret
    var k: usize = 0;
    while (k < width) : (k += 1) std.debug.print("^", .{});
    std.debug.print("  [{s}] at bytes {d}..{d} (\"{s}\")\n", .{
        @tagName(diag.code), diag.span.start, diag.span.end, diag.faultySlice(pattern),
    });
}

// ── Usage examples (also serve as consumer-side API tests) ────────────────────

test "usage: runtime parse, inspect, free" {
    const gpa = std.testing.allocator;
    const pattern = "(\\w+)@(\\w+)";

    var diag: ezi_gex.Diagnostic = .{};
    const re = ezi_gex.parse(gpa, pattern, &diag) catch |err| {
        // Caller decides how to surface the error.
        std.debug.print("regex error: {s} at \"{s}\"\n", .{ diag.message(), diag.faultySlice(pattern) });
        return err;
    };
    defer re.deinit(gpa); // heap AST: free when done

    try std.testing.expectEqual(@as(u32, 2), re.capture_count);
    try std.testing.expect(re.nodes.len > 0);
    // re.nodes[re.root] is the tree root; walk from there.
}

// `compile` runs at compile time, so call it in a comptime context: either at
// container scope (like this) or with the `comptime` keyword inside a function.
const phone_re = ezi_gex.compile("\\d{3}-\\d{4}");

test "usage: comptime compile bakes the AST into the binary (no allocator)" {
    // `phone_re`'s slices point into .rodata. No deinit, no parsing at runtime.
    // An invalid pattern would have been a compile error.
    try std.testing.expect(phone_re.nodes.len > 0);
}

test "usage: bad pattern yields a precise diagnostic" {
    var diag: ezi_gex.Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidPattern,
        ezi_gex.parse(std.testing.allocator, "a(b", &diag),
    );
    try std.testing.expectEqual(ezi_gex.ErrorCode.unclosed_group, diag.code);
    try std.testing.expectEqualStrings("(", diag.faultySlice("a(b"));
}

/// Example AST walk: count how many literal code points a pattern matches
/// unconditionally (ignoring quantifiers/alternation), just to show traversal.
fn countLiterals(re: ezi_gex.Ast, idx: u32) usize {
    const node = re.nodes[idx];
    return switch (node.tag) {
        .literal => 1,
        .concat, .alternation => blk: {
            const d = node.data.children;
            var total: usize = 0;
            for (re.children[d.start .. d.start + d.len]) |c| total += countLiterals(re, c);
            break :blk total;
        },
        .range => countLiterals(re, node.data.range.child),
        .capture => countLiterals(re, node.data.capture.child),
        .non_capture => countLiterals(re, node.data.non_capture.child),
        else => 0,
    };
}

test "usage: walk the AST" {
    const re = comptime ezi_gex.compile("ab(cd)");
    try std.testing.expectEqual(@as(usize, 4), countLiterals(re, re.root));
}
