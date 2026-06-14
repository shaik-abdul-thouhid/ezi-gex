//! Cross-backend conformance harness.
//!
//! Every backend is supposed to be interchangeable behind the contract, so the
//! strongest test is to drive the *same* table of cases through each one (via the
//! real front door, `compileRuntimeWith` / `compileComptimeWith`) and assert they
//! all agree — runtime *and* comptime. Per-backend behavioural tests live in each
//! backend's own file; this file proves they don't diverge from each other.
//!
//! Coverage axes:
//!   * `pikevm` (breadth-first NFA), `backtrack` (depth-first NFA), `auto`
//!     (dispatcher) must agree on every general case.
//!   * `literal` additionally matches the pure-literal subset.
//!   * captures: `pikevm`, `backtrack`, `auto` must report identical slot arrays.
//!   * comptime: a subset runs at comptime through each backend and must match the
//!     runtime result.
//!   * `auto` must agree with itself across its internal input-size switch (small
//!     input → backtrack arm, large input → Pike VM arm).

const std = @import("std");
const testing = std.testing;

const regex = @import("regex.zig");
const backend = @import("backend.zig");
const pikevm = @import("backends/pikevm.zig");
const backtrack = @import("backends/backtrack.zig");
const literal = @import("backends/literal.zig");
const bytepike = @import("backends/bytepike.zig");
const dfa = @import("backends/dfa.zig");
const edfa = @import("backends/edfa.zig");
const auto = @import("backends/auto.zig");

const byte = @import("byte.zig");
const hir = @import("../core/hir.zig");
const ccompile = @import("../core/compile.zig");

/// Whether `pattern` can be lowered to a byte program (false for `\X`/`\b` — those
/// route to the code-point engines, so the byte Pike VM is not expected to run them).
fn byteLowerablePattern(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    return byte.byteLowerable(h);
}

/// Small ASCII-only cases for the byte engine's *comptime* parity. Kept separate
/// from `comptime_cases` because the byte lowering of a Unicode class (`\d`/`\w`)
/// expands to many `byte_range` insts, and building + running several of those in
/// the const-evaluator is heavy; these stay small. (`bytepike.zig`'s own tests cover
/// comptime byte matching of `\d`/`\w` directly.)
const byte_comptime_cases = [_]Case{
    .{ .pat = "cat|dog", .input = "a dog", .expect = "dog" },
    .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
    .{ .pat = "ab*c", .input = "xabbbc", .expect = "abbbc" },
};

/// A wide differential corpus spanning the syntax surface (empty/zero-width, greedy vs
/// lazy, alternation priority, counted reps, nested captures, multibyte UTF-8, `\p{}`
/// classes, case folding incl. special folds, `^`/`$`/`(?m)`, `\b`/`\B`, dead-on-invalid
/// `\xFF`, no-match, sparse matches, and pathological-but-linear shapes). Every case is
/// run through every applicable backend and they must all agree (see the test below);
/// the hand-computed leftmost-first `expect` is also checked, catching a systematic bug
/// all engines might share. Authored to be byte-exact (the `\xFF` cases use a real 0xFF).
const wide_cases = [_]Case{
    // empty / zero-width
    .{ .pat = "", .input = "x", .expect = "" },
    .{ .pat = "a*", .input = "bbb", .expect = "" },
    .{ .pat = "a*", .input = "aaab", .expect = "aaa" },
    .{ .pat = "b*", .input = "aaabbb", .expect = "" },
    .{ .pat = "a|", .input = "b", .expect = "" },
    .{ .pat = "^", .input = "abc", .expect = "" },
    .{ .pat = "\\A", .input = "abc", .expect = "" },
    .{ .pat = "\\z", .input = "abc", .expect = "" },
    .{ .pat = "^$", .input = "x", .expect = null },
    .{ .pat = "^abc$", .input = "abc", .expect = "abc" },
    .{ .pat = "^abc$", .input = "abc\n", .expect = null },
    .{ .pat = "a$", .input = "ba", .expect = "a" },
    .{ .pat = "a$", .input = "ab", .expect = null },
    // greedy vs lazy
    .{ .pat = "a.*b", .input = "axbxb", .expect = "axbxb" },
    .{ .pat = "a.*?b", .input = "axbxb", .expect = "axb" },
    .{ .pat = "<.+>", .input = "<a><b>", .expect = "<a><b>" },
    .{ .pat = "<.+?>", .input = "<a><b>", .expect = "<a>" },
    .{ .pat = "a+?", .input = "aaaa", .expect = "a" },
    .{ .pat = "a??", .input = "a", .expect = "" },
    .{ .pat = "x*?y", .input = "xxxy", .expect = "xxxy" },
    .{ .pat = ".*?", .input = "hello", .expect = "" },
    // alternation priority
    .{ .pat = "a|ab", .input = "abc", .expect = "a" },
    .{ .pat = "ab|a", .input = "abc", .expect = "ab" },
    .{ .pat = "abc|ab|a", .input = "abc", .expect = "abc" },
    .{ .pat = "(ab|a)(c|bc)", .input = "abc", .expect = "abc" },
    .{ .pat = "(a|ab)(c|bcd)", .input = "abcd", .expect = "abcd" },
    .{ .pat = "rat|cat|bat", .input = "the bat sat", .expect = "bat" },
    // counted reps
    .{ .pat = "a{3}", .input = "aaaaa", .expect = "aaa" },
    .{ .pat = "a{2,4}?", .input = "aaaaaa", .expect = "aa" },
    .{ .pat = "a{0,3}", .input = "bbb", .expect = "" },
    .{ .pat = "a{3,}", .input = "aaaaa", .expect = "aaaaa" },
    .{ .pat = "a{3,}", .input = "aa", .expect = null },
    .{ .pat = "(ab){2,3}", .input = "abababab", .expect = "ababab" },
    .{ .pat = "\\d{2,4}", .input = "12345", .expect = "1234" },
    // nested groups / captures
    .{ .pat = "(a(b(c)))", .input = "zabcz", .expect = "abc" },
    .{ .pat = "((a)|(b))+", .input = "abab", .expect = "abab" },
    .{ .pat = "(\\w+)@(\\w+)\\.(\\w+)", .input = "x a@b.io y", .expect = "a@b.io" },
    .{ .pat = "(\\d{4})-(\\d{2})-(\\d{2})", .input = "d=2026-06-12!", .expect = "2026-06-12" },
    .{ .pat = "(?<word>\\w+)", .input = "  hi ", .expect = "hi" },
    .{ .pat = "(a+)(a+)", .input = "aaaa", .expect = "aaaa" },
    // multibyte UTF-8
    .{ .pat = "café", .input = "the café here", .expect = "café" },
    .{ .pat = "αβγ", .input = "xαβγy", .expect = "αβγ" },
    .{ .pat = "[α-ω]+", .input = "λόγος!", .expect = "λόγος" },
    .{ .pat = "Привет", .input = "—Привет!", .expect = "Привет" },
    .{ .pat = "日本語", .input = "→日本語←", .expect = "日本語" },
    .{ .pat = "مرحبا", .input = "قل مرحبا", .expect = "مرحبا" },
    .{ .pat = "\\p{Nd}+", .input = "x٤٥٦y", .expect = "٤٥٦" },
    .{ .pat = "😀+", .input = "a😀😀b", .expect = "😀😀" },
    .{ .pat = "é{2,3}", .input = "xééééy", .expect = "ééé" },
    .{ .pat = "\\w+", .input = "héllo wörld", .expect = "héllo" },
    // \p{...} classes & scripts
    .{ .pat = "\\P{L}+", .input = "abc123!!", .expect = "123!!" },
    .{ .pat = "\\p{Lu}+", .input = "abcDEFghi", .expect = "DEF" },
    .{ .pat = "\\p{Greek}+", .input = "abcαβγdef", .expect = "αβγ" },
    .{ .pat = "\\p{Han}+", .input = "ab漢字cd", .expect = "漢字" },
    .{ .pat = "[\\p{L}\\p{N}]+", .input = "  a1b2!! ", .expect = "a1b2" },
    // case folding incl. special folds
    .{ .pat = "(?i)hello", .input = "HeLLo world", .expect = "HeLLo" },
    .{ .pat = "(?i)[a-z]+", .input = "ABCdef", .expect = "ABCdef" },
    .{ .pat = "(?i)k", .input = "\u{212A}", .expect = "\u{212A}" },
    .{ .pat = "(?i)\u{017F}", .input = "S", .expect = "S" },
    .{ .pat = "(?i)\u{00C5}", .input = "\u{212B}", .expect = "\u{212B}" },
    // ^/$ with and without (?m)
    .{ .pat = "(?m)^line2", .input = "line1\nline2\nline3", .expect = "line2" },
    .{ .pat = "(?m)line2$", .input = "line2\nline3", .expect = "line2" },
    .{ .pat = "^b$", .input = "a\nb\nc", .expect = null },
    .{ .pat = "(?m)^\\w+", .input = "\nword", .expect = "word" },
    .{ .pat = "foo$", .input = "foo\nbar", .expect = null },
    // \b / \B
    .{ .pat = "\\bcat\\b", .input = "a cat!", .expect = "cat" },
    .{ .pat = "\\bcat\\b", .input = "category", .expect = null },
    .{ .pat = "\\Bcat\\B", .input = "locator", .expect = "cat" },
    .{ .pat = "\\b\\w+\\b", .input = "(héllo)", .expect = "héllo" },
    .{ .pat = "s\\b", .input = "cats dogs", .expect = "s" },
    // dead-on-invalid (real 0xFF byte)
    .{ .pat = "abc", .input = "ab\xFFabc", .expect = "abc" },
    .{ .pat = "a.c", .input = "a\xFFc", .expect = null },
    .{ .pat = ".", .input = "\xFFa", .expect = "a" },
    .{ .pat = "\\w+", .input = "ab\xFFcd", .expect = "ab" },
    .{ .pat = "a+b", .input = "aa\xFFb", .expect = null },
    .{ .pat = "foo", .input = "\xFF\xFFfoo", .expect = "foo" },
    // no-match / boundaries / sparse
    .{ .pat = "xyz", .input = "abcdef", .expect = null },
    .{ .pat = "\\d+", .input = "no digits here", .expect = null },
    .{ .pat = "\\d+$", .input = "id 9999", .expect = "9999" },
    .{ .pat = "needle", .input = "haystack haystack haystack needle haystack", .expect = "needle" },
    .{ .pat = "\\d+", .input = "........................................42...", .expect = "42" },
    // pathological-but-linear
    .{ .pat = "(a*)*b", .input = "aaaaaaaaaaaaaaaaaaaaaaaaX", .expect = null },
    .{ .pat = "(a*)*b", .input = "aaaaaaaab", .expect = "aaaaaaaab" },
    .{ .pat = "(a+)+b", .input = "aaaaaaaaaaaaaaaaaaaaac", .expect = null },
    .{ .pat = "(a?){10}a{10}", .input = "aaaaaaaaaa", .expect = "aaaaaaaaaa" },
};

const Case = struct { pat: []const u8, input: []const u8, expect: ?[]const u8 };

/// General cases — valid for any NFA-capable backend (pikevm / backtrack / auto).
const general_cases = [_]Case{
    // literals
    .{ .pat = "abc", .input = "xxabcyy", .expect = "abc" },
    .{ .pat = "abc", .input = "ab", .expect = null },
    .{ .pat = "a", .input = "banana", .expect = "a" },
    .{ .pat = "", .input = "abc", .expect = "" },
    // dot / any
    .{ .pat = "a.c", .input = "a c", .expect = "a c" },
    .{ .pat = "a.c", .input = "a\nc", .expect = null },
    .{ .pat = "(?s)a.c", .input = "a\nc", .expect = "a\nc" },
    // classes + shorthands
    .{ .pat = "[a-z]+", .input = "ABCdefGHI", .expect = "def" },
    .{ .pat = "[^a-z]+", .input = "abXY12cd", .expect = "XY12" },
    .{ .pat = "\\d+", .input = "abc123def", .expect = "123" },
    .{ .pat = "\\w+", .input = "  foo_bar! ", .expect = "foo_bar" },
    .{ .pat = "\\D+", .input = "12ab34", .expect = "ab" },
    // alternation priority
    .{ .pat = "cat|dog", .input = "i have a dog", .expect = "dog" },
    .{ .pat = "a|ab", .input = "ab", .expect = "a" },
    .{ .pat = "ab|a", .input = "ab", .expect = "ab" },
    .{ .pat = "foo|foobar", .input = "foobar", .expect = "foo" },
    .{ .pat = "a(b|c|d)e", .input = "ade", .expect = "ade" },
    // quantifiers
    .{ .pat = "ab*", .input = "abbbc", .expect = "abbb" },
    .{ .pat = "ab+", .input = "ac", .expect = null },
    .{ .pat = "ab?c", .input = "ac", .expect = "ac" },
    .{ .pat = "a.*c", .input = "abXYZc end c", .expect = "abXYZc end c" },
    .{ .pat = "a.*?c", .input = "abXcYc", .expect = "abXc" },
    .{ .pat = "a+?", .input = "aaaa", .expect = "a" },
    .{ .pat = "a{3}", .input = "aaaaa", .expect = "aaa" },
    .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
    .{ .pat = "a{0,2}b", .input = "b", .expect = "b" },
    .{ .pat = "(ab){2,3}", .input = "ababab", .expect = "ababab" },
    // anchors
    .{ .pat = "^abc", .input = "abcdef", .expect = "abc" },
    .{ .pat = "^abc", .input = "xabc", .expect = null },
    .{ .pat = "abc$", .input = "xxabc", .expect = "abc" },
    .{ .pat = "^abc$", .input = "abc\n", .expect = null },
    .{ .pat = "(?m)^line2", .input = "line1\nline2\nline3", .expect = "line2" },
    // word boundaries
    .{ .pat = "\\bcat\\b", .input = "a cat!", .expect = "cat" },
    .{ .pat = "\\bcat\\b", .input = "category", .expect = null },
    .{ .pat = "\\Bcat\\B", .input = "locator", .expect = "cat" },
    // captures (the whole-match span must agree even where group reporting differs)
    .{ .pat = "(\\d{4})-(\\d{2})-(\\d{2})", .input = "x 2026-06-07 y", .expect = "2026-06-07" },
    .{ .pat = "a(b)?c", .input = "ac", .expect = "ac" },
    .{ .pat = "(\\w)+", .input = "abc", .expect = "abc" },
    // unicode
    .{ .pat = "\\w+", .input = "héllo, wörld", .expect = "héllo" },
    .{ .pat = "\\p{L}+", .input = "abc123", .expect = "abc" },
    .{ .pat = "\\p{Nd}+", .input = "x٤٥٦y", .expect = "٤٥٦" },
    .{ .pat = "(?i)abc", .input = "XYZABCxyz", .expect = "ABC" },
    .{ .pat = "é{2,3}", .input = "xééééy", .expect = "ééé" },
    // case-fold ORBIT closure: every member of a simple-fold orbit must match,
    // even when reached transitively (K, k, and U+212A KELVIN SIGN all fold to
    // 'k'; A-ring U+00C5, å U+00E5, and U+212B ANGSTROM SIGN all fold to 'å').
    .{ .pat = "(?i)k", .input = "\u{212A}", .expect = "\u{212A}" },
    .{ .pat = "(?i)K", .input = "\u{212A}", .expect = "\u{212A}" },
    .{ .pat = "(?i)\u{212A}", .input = "k", .expect = "k" },
    .{ .pat = "(?i)\u{00C5}", .input = "\u{212B}", .expect = "\u{212B}" },
    .{ .pat = "(?i)[k]", .input = "\u{212A}", .expect = "\u{212A}" },
    // pathological (linear-time guarantee for both engines)
    .{ .pat = "(a*)*b", .input = "aaaaaaaaaaaaX", .expect = null },
};

/// Pure-literal subset — additionally valid for the `literal` backend.
const literal_cases = [_]Case{
    .{ .pat = "abc", .input = "xxabcyy", .expect = "abc" },
    .{ .pat = "abc", .input = "ab", .expect = null },
    .{ .pat = "héllo", .input = "say héllo!", .expect = "héllo" },
    .{ .pat = "cat|dog", .input = "i have a dog", .expect = "dog" },
    .{ .pat = "a|ab", .input = "ab", .expect = "a" },
    .{ .pat = "ab|a", .input = "ab", .expect = "ab" },
    .{ .pat = "cat|dog|fish", .input = "redfish", .expect = "fish" },
};

fn checkRuntime(comptime B: type, case: Case) !void {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, case.pat, &diag, .{}) catch |e| {
        std.debug.print("compile failed for /{s}/ on {s}: {s}\n", .{ case.pat, @typeName(B), @errorName(e) });
        return e;
    };
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const m = re.find(&sc, case.input);
    if (case.expect) |exp| {
        if (m == null) {
            std.debug.print("/{s}/ on {s}: expected \"{s}\", got no match\n", .{ case.pat, @typeName(B), exp });
            return error.NoMatch;
        }
        testing.expectEqualStrings(exp, m.?.slice(case.input)) catch {
            std.debug.print("/{s}/ on {s}: backend disagreed\n", .{ case.pat, @typeName(B) });
            return error.Mismatch;
        };
    } else if (m != null) {
        std.debug.print("/{s}/ on {s}: expected no match, got \"{s}\"\n", .{ case.pat, @typeName(B), m.?.slice(case.input) });
        return error.UnexpectedMatch;
    }
}

test "general cases agree across pikevm / backtrack / auto" {
    for (general_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

test "literal cases agree across all four backends (incl. literal)" {
    for (literal_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
        try checkRuntime(literal, c);
    }
}

test "byte Pike VM agrees on the byte-lowerable subset (the lowering is correct)" {
    // The byte lowering's correctness proof: for every case the byte engine *can*
    // run (i.e. no `\b`/`\X`), it must reach the SAME result the code-point engines
    // are checked against above. Cases it can't lower are covered by those engines.
    var ran: usize = 0;
    for (general_cases) |c| {
        if (!byteLowerablePattern(c.pat)) continue;
        try checkRuntime(bytepike, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!byteLowerablePattern(c.pat)) continue;
        try checkRuntime(bytepike, c);
        ran += 1;
    }
    try testing.expect(ran > 0); // guard against the filter silently skipping everything
}

// ── lazy DFA span conformance ─────────────────────────────────────────────────────

/// Whether `pattern` can run on the lazy DFA (byte-lowerable AND no zero-width
/// anchors — the v1 DFA declines `^ $ \b \X` and line anchors). A narrower gate than
/// `byteLowerablePattern`, so it gets its own predicate.
fn dfaRoutablePattern(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    return dfa.supports(h);
}

test "lazy DFA agrees with the code-point engines on its eligible subset (span-only)" {
    // The DFA is span-only, so it is checked through `re.find` (the whole-match span)
    // exactly like every other backend — its span must equal what pikevm/backtrack/auto
    // are pinned to. Cases with `\b`/`\X`/anchors it cannot run are covered by those.
    var ran: usize = 0;
    for (general_cases) |c| {
        if (!dfaRoutablePattern(c.pat)) continue;
        try checkRuntime(dfa, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!dfaRoutablePattern(c.pat)) continue;
        try checkRuntime(dfa, c);
        ran += 1;
    }
    try testing.expect(ran > 0); // guard against the gate silently skipping everything
}

/// Whether the eager DFA can actually build `pattern` — `edfa.supports` AND its full
/// DFA fits `edfa.max_states` (it is bounded by design; the lazy DFA covers the rest).
fn edfaBuildable(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    var prog = edfa.buildAlloc(gpa, h, .{}) catch return false;
    edfa.freeProgram(gpa, &prog);
    return true;
}

test "eager DFA agrees with the code-point engines on its eligible subset (span-only)" {
    // The eager DFA fully determinizes at build time; its frozen-table span must equal
    // what pikevm/backtrack/auto are pinned to. It is bounded (declines a pattern whose
    // whole DFA exceeds `max_states`), so we check the cases it can actually build — the
    // lazy DFA covers the rest, already pinned above.
    var ran: usize = 0;
    for (general_cases) |c| {
        if (!edfaBuildable(c.pat)) continue;
        try checkRuntime(edfa, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!edfaBuildable(c.pat)) continue;
        try checkRuntime(edfa, c);
        ran += 1;
    }
    try testing.expect(ran > 0);
}

// ── Line anchors (?m): exact spans + cross-engine agreement ─────────────────────────

const LineCase = struct { pat: []const u8, input: []const u8, spans: []const [2]usize };

/// Every non-overlapping match span the `(?m)` line anchors must produce, hand-computed against
/// the reference semantics. There is **no `.crlf` mode** — the line terminator is `\n` only, so
/// `\r` is ordinary content (verified by the CRLF cases). Covers line-start placement off-by-ones,
/// offset-0 ↔ text-start aliasing, `(?m)$` (line_end), empty-line / zero-width placement,
/// empty-match advancement, and CRLF.
const line_cases = [_]LineCase{
    // line-start placement (the core off-by-ones)
    .{ .pat = "(?m)^\\w+", .input = "abc\ndef", .spans = &.{ .{ 0, 3 }, .{ 4, 7 } } }, // 2nd starts at 4 (after \n), not 3/5
    .{ .pat = "(?m)^\\w+", .input = "\nabc", .spans = &.{.{ 1, 4 }} }, // leading \n: ^ fires at 0 (empty; \w+ fails) and 1
    .{ .pat = "(?m)^\\w+", .input = "abc\n", .spans = &.{.{ 0, 3 }} }, // trailing \n: no spurious match past it
    .{ .pat = "(?m)^\\w+", .input = "abc\n\ndef", .spans = &.{ .{ 0, 3 }, .{ 5, 8 } } }, // empty line → no phantom; def at 5
    .{ .pat = "(?m)^", .input = "a\nb\nc", .spans = &.{ .{ 0, 0 }, .{ 2, 2 }, .{ 4, 4 } } }, // bare anchor: empty at each line start
    // offset-0 vs text-start aliasing
    .{ .pat = "(?m)^abc", .input = "abc", .spans = &.{.{ 0, 3 }} }, // line start == text start: no double-count
    .{ .pat = "(?m)^abc", .input = "xabc", .spans = &.{} }, // mid-line, no preceding \n → no match
    .{ .pat = "(?m)^abc", .input = "x\nabc", .spans = &.{.{ 2, 5 }} }, // post-newline start at byte 2
    // (?m)$ line_end (prone on the byte DFA → declined to the Pike VM; cross-checked vs backtrack)
    .{ .pat = "(?m)\\w+$", .input = "abc\ndef", .spans = &.{ .{ 0, 3 }, .{ 4, 7 } } }, // 1st ends at 3 (before \n), not 4
    .{ .pat = "(?m)^\\w+$", .input = "ab\ncd\nef", .spans = &.{ .{ 0, 2 }, .{ 3, 5 }, .{ 6, 8 } } }, // every line, both ends
    .{ .pat = "(?m)^$", .input = "a\n\nb", .spans = &.{.{ 2, 2 }} }, // empty line: ^ and $ coincide on the blank line
    // empty-match advancement
    .{ .pat = "(?m)^", .input = "a\nb", .spans = &.{ .{ 0, 0 }, .{ 2, 2 } } }, // advance by one; no double-emit at offset 0
    // CRLF — no `.crlf` mode, so \r is content: the line start is after \n (byte 5), not split by \r
    .{ .pat = "(?m)^\\w+", .input = "abc\r\ndef", .spans = &.{ .{ 0, 3 }, .{ 5, 8 } } }, // \w+ stops at \r; def at 5
    .{ .pat = "(?m)\\w+$", .input = "abc\r\ndef", .spans = &.{.{ 5, 8 }} }, // $ sits before \n: \r blocks line 1's match
};

/// Collect every non-overlapping match's `[start, end)` for backend `B` over `input`, or null when
/// `B` declines the pattern (so the table can include shapes a given backend doesn't run). Uses the
/// agnostic `findAll` iterator, which advances past empty matches by one position.
fn collectSpans(comptime B: type, gpa: std.mem.Allocator, pat: []const u8, input: []const u8, out: *[16][2]usize) !?usize {
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, pat, &diag, .{}) catch return null; // declined → skip
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var n: usize = 0;
    var it = re.findAll(&sc, input);
    while (it.next()) |m| {
        if (n >= out.len) return error.TooManySpans;
        out[n] = .{ m.start, m.end };
        n += 1;
    }
    return n;
}

test "line anchors (?m): exact spans (vs hand-computed) + cross-engine agreement" {
    const gpa = testing.allocator;
    for (line_cases) |c| {
        // Oracle = the Pike VM: it must produce EXACTLY the hand-computed spans (this catches a
        // bug all engines might share — the line semantics / placement themselves).
        var ov: [16][2]usize = undefined;
        const on = (try collectSpans(pikevm, gpa, c.pat, c.input, &ov)).?;
        testing.expectEqual(c.spans.len, on) catch {
            std.debug.print("/{s}/ on \"{s}\": Pike VM found {d} spans, expected {d}\n", .{ c.pat, c.input, on, c.spans.len });
            return error.Mismatch;
        };
        for (c.spans, 0..) |sp, i| {
            try testing.expectEqual(sp[0], ov[i][0]);
            try testing.expectEqual(sp[1], ov[i][1]);
        }
        // Every other backend must agree span-for-span, or decline → skip. `backtrack` is an
        // INDEPENDENT code-point engine (it cross-checks the prone `(?m)$` cases the byte DFAs
        // decline); `edfa` covers the non-prone cases on the byte DFA; `dfa` declines line anchors.
        inline for (.{ backtrack, auto, edfa, dfa }) |B| {
            var bv: [16][2]usize = undefined;
            if (try collectSpans(B, gpa, c.pat, c.input, &bv)) |bn| {
                testing.expectEqual(on, bn) catch {
                    std.debug.print("/{s}/ on \"{s}\": {s} found {d} spans, Pike VM {d}\n", .{ c.pat, c.input, @typeName(B), bn, on });
                    return error.Mismatch;
                };
                for (0..on) |i| {
                    try testing.expectEqual(ov[i][0], bv[i][0]);
                    try testing.expectEqual(ov[i][1], bv[i][1]);
                }
            }
        }
    }
}

test "auto never @compileErrors at comptime — big/prone patterns route to the Pike VM" {
    // The eager DFA is bounded (fixed comptime tables) and at comptime there is NO runtime lazy-DFA
    // handoff, so pinning it on a too-large pattern (`compileComptimeWith(backends.edfa, …)`) is a
    // `@compileError`. `auto` never hits that: its `tinyForComptimeEdfa` gate keeps non-tiny
    // patterns on the NFA/Pike VM at comptime, so `compileComptime*(auto, …)` ALWAYS compiles. Each
    // pattern here would `@compileError` on a pinned comptime edfa (big Unicode class / prone); the
    // fact this file compiles AND they match proves auto routed them to the Pike VM instead.
    const ok = comptime blk: {
        @setEvalBranchQuota(50_000_000);
        const R1 = regex.compileComptimeWith(auto, "\\w+@\\w+", .{}); // big Unicode + prone
        const R2 = regex.compileComptimeWith(auto, "\\p{L}+", .{}); // big Unicode class
        const R3 = regex.compileComptimeWith(auto, "(?m)\\w+$", .{}); // prone line anchor
        break :blk (R1.findComptime("see a@b") != null) and
            (R2.findComptime("héllo") != null) and
            (R3.findComptime("x\ny") != null);
    };
    try testing.expect(ok);
}

/// `find` a backend's span for `(pat, input)`, or `.skip` when the pattern does not
/// compile for it (an unsupported `\p{…}` name, or a backend declining the shape) — so
/// the differential corpus tolerates patterns outside a given backend's domain without
/// trusting any hand-computed expectation.
const Outcome = union(enum) { skip, span: ?backend.Match };
fn findOutcome(comptime B: type, pat: []const u8, input: []const u8) !Outcome {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, pat, &diag, .{}) catch return .skip;
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    return .{ .span = re.find(&sc, input) };
}
fn expectSameSpan(pat: []const u8, ref: ?backend.Match, other: Outcome) !void {
    const o = switch (other) {
        .skip => return,
        .span => |s| s,
    };
    testing.expectEqual(ref == null, o == null) catch {
        std.debug.print("/{s}/ disagreed on match presence\n", .{pat});
        return error.Mismatch;
    };
    if (ref) |r| {
        try testing.expectEqual(r.start, o.?.start);
        try testing.expectEqual(r.end, o.?.end);
    }
}

test "wide differential corpus: every backend agrees with the Pike VM (byte/eager DFA on eligible patterns)" {
    // Pure differential: the Pike VM is the oracle and every other applicable backend
    // must produce the byte-identical span. (Hand-computed `expect`s are intentionally
    // NOT trusted here — the human-verified `general_cases` guard against a shared bug;
    // this table is for breadth and cross-backend consistency.) The safety net for
    // DFA-on-by-default + the prefilter: any divergence among pikevm / backtrack / auto /
    // dfa / edfa fails.
    for (wide_cases) |c| {
        const ref = switch (try findOutcome(pikevm, c.pat, c.input)) {
            .skip => continue, // unsupported property name etc. — skip the whole case
            .span => |s| s,
        };
        try expectSameSpan(c.pat, ref, try findOutcome(backtrack, c.pat, c.input));
        try expectSameSpan(c.pat, ref, try findOutcome(auto, c.pat, c.input));
        if (dfaRoutablePattern(c.pat)) try expectSameSpan(c.pat, ref, try findOutcome(dfa, c.pat, c.input));
        if (edfaBuildable(c.pat)) try expectSameSpan(c.pat, ref, try findOutcome(edfa, c.pat, c.input));
    }
}

test "prefilter on/off and byte_engine on/off are results-invariant on the wide corpus" {
    // The strategy tier must never change a match. Compile each case four ways and pin
    // every span to the default `auto`. Patterns that do not compile are skipped.
    const gpa = testing.allocator;
    const variants = [_]regex.Options{
        .{}, // default (DFA on, prefilter on)
        .{ .strategy = .{ .prefilter = false } },
        .{ .strategy = .{ .byte_engine = .disabled } },
        .{ .strategy = .{ .byte_engine = .disabled, .prefilter = false } },
    };
    for (wide_cases) |c| {
        var diag: regex.Diagnostic = .{};
        var ref = regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{}) catch continue;
        defer ref.deinit();
        var rsc = try @TypeOf(ref).Scratch.init(gpa, &ref.program);
        defer rsc.deinit(gpa);
        const rm = ref.find(&rsc, c.input);
        inline for (variants) |opts| {
            var re = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, opts);
            defer re.deinit();
            var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
            defer sc.deinit(gpa);
            const m = re.find(&sc, c.input);
            try testing.expectEqual(rm == null, m == null);
            if (rm) |r| {
                try testing.expectEqual(r.start, m.?.start);
                try testing.expectEqual(r.end, m.?.end);
            }
        }
    }
}

test "auto's byte_engine=.enabled is results-invariant (DFA span == NFA span) and routes to dfa" {
    // Flipping the strategy knob must not change a single match (results-invariance). For every
    // DFA-eligible case, the .enabled build and the default build must return
    // byte-identical spans. With .enabled an eligible pattern routes to the DFA span
    // arm ("dfa") unless it is a pure literal (then "literal", already optimal); it is
    // never left on the plain "nfa" arm.
    const gpa = testing.allocator;
    var ran: usize = 0;
    var dfa_routed: usize = 0;
    inline for (general_cases ++ literal_cases) |c| {
        if (dfaRoutablePattern(c.pat)) {
            var diag: regex.Diagnostic = .{};
            var re0 = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{});
            defer re0.deinit();
            var sc0 = try @TypeOf(re0).Scratch.init(gpa, &re0.program);
            defer sc0.deinit(gpa);

            var re1 = try regex.compileRuntimeWith(auto, gpa, c.pat, &diag, .{ .strategy = .{ .byte_engine = .enabled } });
            defer re1.deinit();
            var sc1 = try @TypeOf(re1).Scratch.init(gpa, &re1.program);
            defer sc1.deinit(gpa);

            const r = auto.route(&re1.program);
            try testing.expect(!std.mem.eql(u8, r, "nfa")); // eligible+enabled ⇒ nfa+edfa / nfa+dfa / literal, never plain nfa
            if (std.mem.eql(u8, r, "nfa+edfa") or std.mem.eql(u8, r, "nfa+dfa")) dfa_routed += 1;

            const m0 = re0.find(&sc0, c.input);
            const m1 = re1.find(&sc1, c.input);
            try testing.expectEqual(m0 == null, m1 == null);
            if (m0) |a| {
                try testing.expectEqual(a.start, m1.?.start);
                try testing.expectEqual(a.end, m1.?.end);
            }
            ran += 1;
        }
    }
    try testing.expect(ran > 0);
    try testing.expect(dfa_routed > 0); // the DFA span arm is actually exercised
}

test "auto with byte_engine=.enabled still fills captures via the Pike VM" {
    // The DFA finds the span; captures are span-only's job for the code-point engine.
    // A capture pattern compiled with the DFA enabled must still report correct groups
    // (auto routes searchCaptures to the Pike VM, span scan to the DFA).
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "(\\w+)@(\\w+)", &diag, .{ .strategy = .{ .byte_engine = .enabled } });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);

    try testing.expectEqualStrings("nfa+edfa", auto.route(&re.program));
    var slots: [6]?usize = undefined;
    const c = re.captures(&sc, &slots, "ping bob@example").?;
    try testing.expectEqualStrings("bob@example", c.match().slice("ping bob@example"));
    try testing.expectEqualStrings("bob", c.groupSlice(1).?);
    try testing.expectEqualStrings("example", c.groupSlice(2).?);
}

// ── capture-array conformance ─────────────────────────────────────────────────────

const capture_cases = [_][]const u8{
    "(\\d{4})-(\\d{2})-(\\d{2})",
    "(\\w+)@(\\w+)\\.(\\w+)",
    "a(b)?(c)",
    "(a+)(b+)",
    "(?<y>\\d+)-(?<m>\\d+)",
    "((a)(b))+",
};

fn captureSlots(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, out: []?usize) !bool {
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(B, gpa, pattern, &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    @memset(out, null);
    return re.captures(&sc, out, input) != null;
}

test "capture slot arrays agree across pikevm / backtrack / auto" {
    const gpa = testing.allocator;
    const inputs = [_][]const u8{ "2026-06-07", "alice@example.com", "abc", "aaabb", "2026-06", "abab" };
    for (capture_cases) |pat| {
        for (inputs) |in| {
            var a: [16]?usize = undefined;
            var b: [16]?usize = undefined;
            var c: [16]?usize = undefined;
            const ra = try captureSlots(pikevm, gpa, pat, in, &a);
            const rb = try captureSlots(backtrack, gpa, pat, in, &b);
            const rc = try captureSlots(auto, gpa, pat, in, &c);
            try testing.expectEqual(ra, rb);
            try testing.expectEqual(ra, rc);
            if (ra) {
                try testing.expectEqualSlices(?usize, &a, &b);
                try testing.expectEqualSlices(?usize, &a, &c);
            }
            // The byte Pike VM must report the SAME capture slots for every
            // byte-lowerable capture pattern (none here use `\b`).
            if (byteLowerablePattern(pat)) {
                var d: [16]?usize = undefined;
                const rd = try captureSlots(bytepike, gpa, pat, in, &d);
                try testing.expectEqual(ra, rd);
                if (ra) try testing.expectEqualSlices(?usize, &a, &d);
            }
        }
    }
}

// ── auto's internal input-size switch is transparent ──────────────────────────────

test "auto agrees with itself across the small/large input switch" {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "a\\w+z", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);

    // Small input → backtrack arm.
    try testing.expectEqualStrings("aBCz", re.find(&sc, "..aBCz..").?.slice("..aBCz.."));

    // Large input (> auto's backtrack threshold) → Pike VM arm; same answer.
    const big = try gpa.alloc(u8, 5000);
    defer gpa.free(big);
    @memset(big, '.');
    @memcpy(big[2500 .. 2500 + 4], "aQRz");
    try testing.expectEqualStrings("aQRz", re.find(&sc, big).?.slice(big));
}

// ── comptime parity across backends ───────────────────────────────────────────────

const comptime_cases = [_]Case{
    .{ .pat = "\\d+", .input = "abc123def", .expect = "123" },
    .{ .pat = "[a-z]+\\d*", .input = "  abc123  ", .expect = "abc123" },
    .{ .pat = "cat|dog", .input = "a dog", .expect = "dog" },
    .{ .pat = "(\\w+)@(\\w+)", .input = "x a@b y", .expect = "a@b" },
    .{ .pat = "a{2,4}", .input = "aaaaaa", .expect = "aaaa" },
    .{ .pat = "\\bword\\b", .input = "a word here", .expect = "word" },
};

fn checkComptime(comptime B: type, comptime case: Case) !void {
    const Re = comptime regex.compileComptimeWith(B, case.pat, .{});
    const m = comptime Re.findComptime(case.input);
    if (case.expect) |exp| {
        try testing.expect(m != null);
        try testing.expectEqualStrings(exp, m.?.slice(case.input));
    } else {
        try testing.expect(m == null);
    }
}

test "comptime results match across pikevm / backtrack / auto" {
    inline for (.{ pikevm, backtrack, auto }) |B| {
        inline for (comptime_cases) |c| {
            try checkComptime(B, c);
        }
    }
}

test "comptime == runtime for the same backend" {
    inline for (.{ pikevm, backtrack, auto }) |B| {
        inline for (comptime_cases) |c| {
            try checkRuntime(B, c); // runtime
            try checkComptime(B, c); // comptime — same expectation
        }
    }
}

test "byte Pike VM matches at comptime too (small ASCII subset)" {
    inline for (byte_comptime_cases) |c| {
        try checkComptime(bytepike, c); // ro_data byte program, matched in const-eval
        try checkRuntime(bytepike, c); // and the same answer at runtime
    }
}

// ── program range interning ───────────────────────────────────────────────────────

test "identical class blocks are interned into one range-block in the program" {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};

    // Baseline: a single \w resolves to N ranges.
    var one = try regex.compileRuntimeWith(pikevm, gpa, "\\w", &diag, .{});
    defer one.deinit();
    const n = one.program.ranges.len;
    try testing.expect(n > 1); // \w is a real Unicode class, many ranges

    // Repeating the SAME class — across concatenation, capture groups, and a
    // counted repetition — must NOT multiply the stored ranges: every \w block
    // is interned to the first. The program holds exactly one \w worth of ranges.
    for ([_][]const u8{ "\\w\\w\\w", "(\\w)(\\w)(\\w)", "\\w{4,9}" }) |pat| {
        var re = try regex.compileRuntimeWith(pikevm, gpa, pat, &diag, .{});
        defer re.deinit();
        try testing.expectEqual(n, re.program.ranges.len);
    }

    // Distinct classes are NOT collapsed — \w and \d stay separate blocks.
    var mixed = try regex.compileRuntimeWith(pikevm, gpa, "\\w\\d", &diag, .{});
    defer mixed.deinit();
    try testing.expect(mixed.program.ranges.len > n);
}

test {
    testing.refAllDecls(@This());
}
