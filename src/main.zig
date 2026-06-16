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

    // ── replace family / splitN / capturesAt / group lookups (v0.5.0) ─────────
    std.debug.print("\n── replace / split / group lookups ──\n", .{});

    // group name ↔ index straight from the compiled metadata — no match needed.
    std.debug.print("groupIndex(\"word\")={?d}  groupName(1)=\"{?s}\"\n", .{ re.groupIndex("word"), re.groupName(1) });

    // capturesAt: resume a capture search at a byte offset (the peer of findAt/isMatchAt).
    if (re.capturesAt(&sc, cap_slots, text, .{ .start = 5 })) |c|
        std.debug.print("capturesAt(start=5): word=\"{s}\"\n", .{c.namedSlice("word").?});

    // The replace family, on a capturing pattern.
    var mdiag: ezi_gex.Diagnostic = .{};
    var mre = try ezi_gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &mdiag, .{});
    defer mre.deinit();
    var msc = try @TypeOf(mre).Scratch.init(gpa, &mre.program);
    defer msc.deinit(gpa);
    const mslots = try gpa.alloc(?usize, mre.slotCount());
    const emails = "to alice@example and bob@test";

    var rbuf: [256]u8 = undefined;
    var rw = std.Io.Writer.fixed(&rbuf);
    try mre.replace(&msc, emails, "<$1>", mslots, &rw); // first match only
    std.debug.print("replace (first):    {s}\n", .{rw.buffered()});

    // replaceAllAlloc — get the rewritten string as an owned slice; no Writer to manage.
    const swapped = try mre.replaceAllAlloc(gpa, &msc, emails, "$2.$1", mslots);
    std.debug.print("replaceAllAlloc:    {s}\n", .{swapped});

    // replaceAllWith — a callback computes each replacement (here: upper-case the user).
    var cw = std.Io.Writer.fixed(&rbuf);
    try mre.replaceAllWith(&msc, emails, mslots, &cw, {}, struct {
        fn run(_: void, c: ezi_gex.Captures, out: *std.Io.Writer) std.Io.Writer.Error!void {
            for (c.groupSlice(1).?) |ch| try out.writeByte(std.ascii.toUpper(ch));
        }
    }.run);
    std.debug.print("replaceAllWith:     {s}\n", .{cw.buffered()});

    // splitN — at most N pieces; the remainder after N−1 separators is the final piece.
    var cdiag: ezi_gex.Diagnostic = .{};
    var cre = try ezi_gex.compileRuntime(gpa, ",", &cdiag, .{});
    defer cre.deinit();
    var csc = try @TypeOf(cre).Scratch.init(gpa, &cre.program);
    defer csc.deinit(gpa);
    std.debug.print("splitN(\"a,b,c,d\", 2):", .{});
    var nit = cre.splitN(&csc, "a,b,c,d", 2);
    while (nit.next()) |piece| std.debug.print(" [{s}]", .{piece});
    std.debug.print("\n", .{});

    // ══ Byte engine: the zero-decode byte-NFA substrate (v0.2.0) ═══════════════
    // `bytepike` executes a byte-grained lowering of the HIR: each step consumes one
    // input BYTE against a byte range, so a Unicode class matches with NO decode. It
    // is the substrate the lazy DFA (`backends.dfa`, below) determinizes — not the
    // default backend (per-byte stepping is not a throughput win), but selectable via
    // `*With`.
    std.debug.print("\n── byte engine ──\n", .{});
    const BytePike = ezi_gex.backends.bytepike;
    var bdiag: ezi_gex.Diagnostic = .{};
    var bre = try ezi_gex.compileRuntimeWith(BytePike, gpa, "\\p{Script=Greek}+", &bdiag, .{});
    defer bre.deinit();
    var bsc = try @TypeOf(bre).Scratch.init(gpa, &bre.program);
    defer bsc.deinit(gpa);
    const greek = "αβγ rest";
    if (bre.find(&bsc, greek)) |m|
        std.debug.print("bytepike \\p{{Script=Greek}}+ on \"{s}\": \"{s}\" (no decode)\n", .{ greek, m.slice(greek) });

    // Inspect the lowering itself: the byte automaton plus its `ByteMap` equivalence
    // classes — the small alphabet a DFA keys on, even when the NFA is large. (A
    // Unicode class lowers to many byte ranges, so the byte program is bigger than
    // the code-point one; that cost is only paid on the byte path.)
    const byte = ezi_gex.engine.byte;
    const w_hir = try ezi_gex.buildHir(gpa, try ezi_gex.parse(gpa, "\\w+", &bdiag), .{});
    var w_prog = try byte.buildAlloc(gpa, w_hir);
    defer byte.freeProgram(gpa, &w_prog);
    const classes = byte.byteClasses(&w_prog);
    std.debug.print("\\w+ byte program: {d} insts → {d} byte classes (256 bytes compressed)\n", .{ w_prog.insts.len, classes.count });

    // ══ Lazy DFA: the throughput span-finder (v0.3.0) ══════════════════════════
    // `dfa` DETERMINIZES the byte automaton on the fly — one cached DFA state per
    // input byte, keyed on those byte classes. It is SPAN-ONLY (finds [start, end);
    // the Pike VM fills captures) and RUNTIME-ONLY. Determinization keeps the NFA
    // states in priority order and cuts on match, so it is leftmost-first: its span
    // always agrees with the Pike VM. Invalid UTF-8 is dead-on-invalid for free (a
    // malformed byte has no transition, so a match never spans it).
    std.debug.print("\n── lazy DFA (span-only, runtime-only) ──\n", .{});
    try demoDfa(gpa, "\\w+", "  héllo, wörld 42  "); //   multi-byte, zero decode
    try demoDfa(gpa, "[a-z]+[0-9]+", "  test42!  ");
    try demoDfa(gpa, "a|ab", "ab"); //                   leftmost-first → "a"
    try demoDfa(gpa, "ab|a", "ab"); //                   higher-priority longer → "ab"
    try demoDfa(gpa, "a.*?c", "abXcYc"); //              lazy → "abXc"
    try demoDfa(gpa, "\\p{Script=Greek}+", "abcαβγdef"); // unicode property → "αβγ"
    try demoDfa(gpa, "a.c", "a\xFFc abc"); //            dead-on-invalid → "abc"

    // Through `auto`: opt in with `byte_engine = .enabled`. `auto` then runs the DFA
    // for the span scan and the Pike VM for captures — so you still get groups, just a
    // faster span. `auto.route` reports which arm a compiled program took ("nfa+edfa").
    var adiag: ezi_gex.Diagnostic = .{};
    var are = try ezi_gex.compileRuntimeWith(ezi_gex.backends.auto, gpa, "(\\w+)@(\\w+)", &adiag, .{ .strategy = .{ .byte_engine = .enabled } });
    defer are.deinit();
    var asc = try @TypeOf(are).Scratch.init(gpa, &are.program);
    defer asc.deinit(gpa);
    const aslots = try gpa.alloc(?usize, are.slotCount());
    std.debug.print("auto+dfa /(\\w+)@(\\w+)/  route=\"{s}\"  ", .{ezi_gex.backends.auto.route(&are.program)});
    if (are.captures(&asc, aslots, "ping bob@example")) |c|
        std.debug.print("→ \"{s}\"  (g1=\"{s}\", g2=\"{s}\")\n", .{ c.match().slice("ping bob@example"), c.groupSlice(1).?, c.groupSlice(2).? });

    // ══ Eager DFA: the frozen table — comptime-bakeable, and auto's default (v0.3.0) ══
    // `edfa` fully determinizes the byte automaton at BUILD time into a frozen
    // `states × byte_classes` table, so its `Scratch` is EMPTY and it matches at COMPTIME
    // (into ro_data) as well as runtime — where the lazy `dfa` cannot, because its cache
    // mutates while matching. It is now `auto`'s default span engine, O(input) on every
    // pattern via one of three build-time-chosen arms (no per-search probing): a plain anchored
    // table walk for patterns that complete at most positions (`\w+`); a forward-end +
    // reverse-DFA two-pass for begin-but-don't-complete ones (`\w+@\w+`); and a single
    // reverse-DFA-from-end pass for trailing-`$` patterns (`\w+$`, `\w+@\w+$`) — so even `$` is
    // quadratic-immune. (Determinization is hash-interned, so big Unicode-class builds stay
    // ~linear in states.)
    std.debug.print("\n── eager DFA (frozen table; comptime + runtime) ──\n", .{});

    // Runtime, pinned to edfa: span-only, with a zero-sized Scratch.
    var ediag: ezi_gex.Diagnostic = .{};
    var ere = try ezi_gex.compileRuntimeWith(ezi_gex.backends.edfa, gpa, "[a-z]+[0-9]+", &ediag, .{});
    defer ere.deinit();
    var edsc = try @TypeOf(ere).Scratch.init(gpa, &ere.program); // empty struct — no per-search state
    defer edsc.deinit(gpa);
    if (ere.find(&edsc, "  abc123!  ")) |m|
        std.debug.print("edfa /[a-z]+[0-9]+/ → \"{s}\"\n", .{m.slice("  abc123!  ")});

    // `$` / `\z` (text_end) runs on the DFA via a reverse-from-end pass — O(input), never the
    // Θ(n²) anchored restart (the leftmost word run that ENDS the input).
    var tdiag: ezi_gex.Diagnostic = .{};
    var tre = try ezi_gex.compileRuntimeWith(ezi_gex.backends.edfa, gpa, "[a-z]+$", &tdiag, .{});
    defer tre.deinit();
    var tsc = try @TypeOf(tre).Scratch.init(gpa, &tre.program);
    defer tsc.deinit(gpa);
    if (tre.find(&tsc, "first second third")) |m|
        std.debug.print("edfa /[a-z]+$/ on \"first second third\" → \"{s}\" (anchored to end)\n", .{m.slice("first second third")});

    // Comptime: the table is baked into the binary and the match runs in const-eval —
    // no allocator, no Scratch. The returned span is a compile-time constant.
    const EagerRe = comptime ezi_gex.compileComptimeWith(ezi_gex.backends.edfa, "[0-9]{4}-[0-9]{2}", .{});
    const stamp = comptime EagerRe.findComptime("y=2026-06!").?.slice("y=2026-06!");
    std.debug.print("edfa comptime /[0-9]{{4}}-[0-9]{{2}}/ → \"{s}\" (matched in const-eval; table in ro_data)\n", .{stamp});

    // `auto` picks edfa for DFA-eligible patterns by default — `route` names the arm
    // ("nfa+edfa" preferred, "nfa+dfa" the lazy fallback, "nfa"/"literal" otherwise).
    // Captures still come from the Pike VM, anchored at the DFA span.
    std.debug.print("auto routing by pattern:\n", .{});
    inline for (.{ "\\w+", "\\w+@\\w+", "\\d+$", "cat|dog", "(?m)^x" }) |pat| {
        var rd: ezi_gex.Diagnostic = .{};
        var r = try ezi_gex.compileRuntimeWith(ezi_gex.backends.auto, gpa, pat, &rd, .{});
        defer r.deinit();
        std.debug.print("  /{s}/  →  \"{s}\"\n", .{ pat, ezi_gex.backends.auto.route(&r.program) });
    }
}

/// Compile `pat` on the byte lazy DFA, print the leftmost span it finds in `input`.
/// The DFA is span-only, so we only read `m.slice` (no captures) — `find` is all it
/// needs. A helper so each compile's `Scratch` is released at its own scope exit.
fn demoDfa(gpa: std.mem.Allocator, pat: []const u8, input: []const u8) !void {
    var diag: ezi_gex.Diagnostic = .{};
    var re = try ezi_gex.compileRuntimeWith(ezi_gex.backends.dfa, gpa, pat, &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    if (re.find(&sc, input)) |m|
        std.debug.print("  dfa /{s}/ on \"{s}\"  →  \"{s}\"\n", .{ pat, input, m.slice(input) })
    else
        std.debug.print("  dfa /{s}/ on \"{s}\"  →  (no match)\n", .{ pat, input });
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

test "usage: byte engine (bytepike) matches a Unicode class without decoding" {
    const gpa = std.testing.allocator;
    var diag: ezi_gex.Diagnostic = .{};
    var re = try ezi_gex.compileRuntimeWith(ezi_gex.backends.bytepike, gpa, "[α-ω]+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    try std.testing.expectEqualStrings("αβγ", re.find(&sc, "ΑΒΓαβγ").?.slice("ΑΒΓαβγ"));
}

test "usage: lazy DFA finds spans (span-only, runtime-only, leftmost-first)" {
    const gpa = std.testing.allocator;
    var diag: ezi_gex.Diagnostic = .{};
    var re = try ezi_gex.compileRuntimeWith(ezi_gex.backends.dfa, gpa, "[a-z]+[0-9]+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    try std.testing.expectEqualStrings("abc123", re.find(&sc, "  abc123!  ").?.slice("  abc123!  "));

    // leftmost-first, identical to the Pike VM (the first alternative wins on a tie).
    var re2 = try ezi_gex.compileRuntimeWith(ezi_gex.backends.dfa, gpa, "a|ab", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(gpa, &re2.program);
    defer sc2.deinit(gpa);
    try std.testing.expectEqualStrings("a", re2.find(&sc2, "ab").?.slice("ab"));
}

test "usage: auto opts into the DFA span arm (byte_engine=.enabled); captures still work" {
    const gpa = std.testing.allocator;
    var diag: ezi_gex.Diagnostic = .{};
    // A small-class capture pattern keeps the EAGER DFA span arm (a big-class join like `\w+@\w+`
    // exceeds the eager-determinization budget and uses the lazy DFA instead — see `auto`).
    var re = try ezi_gex.compileRuntimeWith(ezi_gex.backends.auto, gpa, "(\\d{4})-(\\d{2})", &diag, .{ .strategy = .{ .byte_engine = .enabled } });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    try std.testing.expectEqualStrings("nfa+edfa", ezi_gex.backends.auto.route(&re.program)); // eager DFA span arm built
    const slots = try gpa.alloc(?usize, re.slotCount());
    defer gpa.free(slots);
    const c = re.captures(&sc, slots, "on 2026-06 ok").?; // captures via the one-pass / Pike VM
    try std.testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try std.testing.expectEqualStrings("06", c.groupSlice(2).?);
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
