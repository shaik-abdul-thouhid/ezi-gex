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

const regex = @import("regex");
const backend = @import("engine_base").backend;
const pikevm = @import("pikevm");
const backtrack = @import("backtrack");
const literal = @import("literal");
const bytepike = @import("bytepike");
const dfa = @import("dfa");
const edfa = @import("edfa");
const onepass = @import("onepass");
const auto = @import("auto");

const byte = @import("engine_base").byte;
const hir = @import("core").hir;
const ccompile = @import("core").compile;

/// Whether `pattern` can be lowered to a byte program (false for `\X` grapheme; **`\b`/`\B`
/// now lower** — they are evaluated as ASCII word boundaries by the byte engines).
fn byteLowerablePattern(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    return byte.byteLowerable(h);
}

/// Whether `pattern` carries a `\b`/`\B` word boundary (via the HIR analysis flag).
fn patternHasWordBoundary(pattern: []const u8) bool {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    const ast = ccompile.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = hir.buildAlloc(gpa, ast, .{}) catch return false;
    defer hir.deinitHir(gpa, h);
    return h.analysis.has_word_boundary;
}

fn isAsciiStr(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

/// CONVENTION: the byte engines (`bytepike`, lazy `dfa`, eager `edfa`) evaluate `\b`/`\B` as
/// **ASCII** word boundaries — exact for ASCII input (where ASCII and Unicode word boundaries
/// coincide). For a `\b` pattern on **non-ASCII** input the dispatcher (`auto`) routes to the
/// code-point engines instead, so the byte engines are only contracted on ASCII input. This
/// harness honours that contract: a `\b`-bearing case with a non-ASCII byte in its input is
/// skipped when cross-checking a byte engine (the code-point engines still run every case).
fn byteEngineCanRunCase(pattern: []const u8, input: []const u8) bool {
    if (isAsciiStr(input)) return true;
    return !patternHasWordBoundary(pattern);
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
    // case-variant prefilter (small-class-led concat → multi-prefix Teddy start-skip): the
    // synthesised needle set + per-occurrence confirm must find the same leftmost span as the
    // Pike VM, incl. mixed-case hits and dense near-misses ("she" before "Sherlock Holmes").
    .{ .pat = "(?i)the", .input = "----- THE end", .expect = "THE" },
    .{ .pat = "(?i)the", .input = "a tHe b", .expect = "tHe" },
    .{ .pat = "(?i)что", .input = "—там ЧТО здесь", .expect = "ЧТО" },
    .{ .pat = "(?i)sherlock holmes", .input = "she said: Sherlock Holmes!", .expect = "Sherlock Holmes" },
    .{ .pat = "[Tt]he", .input = "xxxxThe end", .expect = "The" },
    // leading-class SIMD scan (`\d+`, `\p{N}+`): the start-skip must land on the leftmost
    // class run across a long non-class gap.
    .{ .pat = "\\p{N}+", .input = "................................ 4567 z", .expect = "4567" },
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
    // \b-wrapped pure-literal fast confirm (a `memmem` hit + an O(1) boundary check: the ASCII
    // eager arm, or the Unicode lazy arm). Must equal the Pike VM incl. on NON-ASCII input (`é`
    // forces the lazy Unicode-boundary arm), with dense interior near-misses and lead-/trail-only
    // boundaries. (v0.5.0 `lit_wb_confirm`.)
    .{ .pat = "\\bthe\\b", .input = "soothe the other theory", .expect = "the" },
    .{ .pat = "\\bthe\\b", .input = "the café — the end", .expect = "the" }, // non-ASCII input → lazy Unicode-\b arm
    .{ .pat = "\\bthe\\b", .input = "breathe theory bathe", .expect = null }, // every "the" is interior
    .{ .pat = "the\\b", .input = "soothe the!", .expect = "the" }, // trailing boundary only
    .{ .pat = "\\bcat", .input = "scatter a cat!", .expect = "cat" }, // leading boundary only (interior "cat" rejected)
    .{ .pat = "\\Bthe\\B", .input = "xtheyz", .expect = "the" }, // interior-only (\B…\B)
    // fixed-offset interior anchor (`\d{4}-…`): dash-to-dash bounded confirm at q-4 on ASCII; a
    // non-ASCII input falls back to the reverse-scan + native find. Both must equal the Pike VM.
    // (v0.5.0 `inner_fixed_off`.)
    .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .input = "ip - - 2026-06-07 ok", .expect = "2026-06-07" }, // dash-dense (nginx-like)
    .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .input = "123456-78-90", .expect = "3456-78-90" }, // alignment: 6 leading digits
    .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .input = "café 2020-01-02 z", .expect = "2020-01-02" }, // non-ASCII → reverse-scan fallback
    .{ .pat = "\\d{2}-\\d{2}", .input = "x - 11-22 y", .expect = "11-22" }, // off=2; placeholder dash fast-fails
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

// Regression (v0.5.0): a `\b`/`\B` alternated with a *consuming* branch must keep
// leftmost-FIRST priority on `auto`. Found by the differential fuzzer: `auto`
// routed `\b|.` to a byte DFA, which matches leftmost-LONGEST and returned `{0,1}`
// ("b") instead of the empty `{0,0}` the Pike VM / backtracker give (the `\b`
// branch matches empty at position 0 and wins). Fixed by declining a
// `\b`-in-alternation to the Pike VM (`hir.Analysis.word_boundary_in_alternation`,
// gated in `dfa.supports` / `edfa.supports`). These cases pin the exact spans and
// would fail on `auto` before the fix.
const word_boundary_alternation_cases = [_]Case{
    // `\b` branch matches empty at 0 → leftmost-first picks it (empty match).
    .{ .pat = "\\b|.", .input = "b", .expect = "" },
    .{ .pat = "\\b-*|.", .input = "b", .expect = "" },
    .{ .pat = "\\ba*|.", .input = "b", .expect = "" },
    .{ .pat = "\\bx*|.", .input = "b", .expect = "" },
    .{ .pat = "(\\b)|.", .input = "b", .expect = "" },
    .{ .pat = "\\b|c", .input = "b", .expect = "" },
    .{ .pat = "\\b-*|.", .input = "b\n \n", .expect = "" },
    // Controls — the consuming branch legitimately wins, so spans must NOT change:
    // at offset 0 before a word char, `\B` (not-a-boundary) fails, so `.` matches.
    .{ .pat = "\\B-*|.", .input = "b", .expect = "b" },
    // `\b` after a separator still finds the empty boundary before the word char.
    .{ .pat = "x|\\b", .input = " a", .expect = "" },
};

test "word-boundary-in-alternation keeps leftmost-first on auto (v0.5.0 regression)" {
    for (word_boundary_alternation_cases) |c| {
        try checkRuntime(pikevm, c); // oracle
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c); // the one that regressed
    }
}

// A repetition over a nullable alternation (`(?:|.)+`). ezi_gex follows **RE2/Rust
// leftmost-first** here (the empty-width-loop rule): when the highest-priority body path
// matches empty, the loop terminates. So an **empty-first** branch (`(?:|.)+`, `(|a)*`)
// wins the empty iteration and exits with `""`, while a **consuming-first** branch (`(a|)+`)
// consumes greedily until it can't. (Through 0.5.1 ezi deliberately diverged here to JS/V8 —
// the consuming branch won; 0.6.0 made every backend uniformly RE2/Rust leftmost-first.)
// The shape stays routed off the byte DFA via `nullable_alternation_in_repetition`: the
// priority-ordered DFA can't reliably reproduce this empty-loop priority — a fuzz repro is
// `(b*)(?:b{0}(?:\n*)|.{2}(?:(){0}))+` on "\nba", where the eager DFA took `[0,3)` and the
// Pike VM the correct `[0,1)` — so `auto` serves it on the leftmost-first-correct Pike VM.
const nullable_alt_repetition_cases = [_]Case{
    .{ .pat = "(?:|.)+", .input = "c", .expect = "" }, // empty-first branch → empty iteration exits
    .{ .pat = "(?:|a)+", .input = "aa", .expect = "" },
    .{ .pat = "(?:|.)*", .input = "c", .expect = "" },
    .{ .pat = "(|a)*", .input = "aaa", .expect = "" }, // RE2/Rust tiebreaker (was JS "aaa")
    .{ .pat = "(|a)+", .input = "aa", .expect = "" },
    .{ .pat = "(a|)+", .input = "aa", .expect = "aa" }, // consuming-first branch → greedily consumes
    .{ .pat = "(?:a|)*b", .input = "aab", .expect = "aab" },
    .{ .pat = "(b*)(?:b{0}(?:\n*)|.{2}(?:(){0}))+", .input = "\nba", .expect = "\n" }, // fuzz repro (0.6.0)
    // Controls — an alternation under a repetition with NO nullable branch.
    .{ .pat = "(?:a|b)+", .input = "abab", .expect = "abab" },
    .{ .pat = "(cat|dog)+", .input = "catdog", .expect = "catdog" },
};

test "nullable-alternation-in-repetition agrees across backends (RE2/Rust leftmost-first, 0.6.0)" {
    // Routed off the byte DFA (`nullable_alternation_in_repetition`), so `auto` runs the Pike
    // VM here; the byte engines decline this shape and are not checked directly. The non-nullable
    // controls below DO stay DFA-eligible and are checked via `auto`.
    for (nullable_alt_repetition_cases) |c| {
        try checkRuntime(pikevm, c); // leftmost-first reference
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (v0.5.0): a NON-trailing `text_end` (`$` outside `(?m)`, or `\z`).
// Found by the supports-gate fuzz campaign. The pattern is unsatisfiable past the
// interior anchor, but the DFA's reverse-from-end path keyed off the *trailing*
// `text_end` (which sets `anchored_end`) and ignored the interior one — so `auto`
// wrongly matched. Fixed by declining a non-trailing `text_end` to the Pike VM
// (`hir.Analysis.interior_text_end`). The controls must STAY on the DFA fast path.
const interior_text_end_cases = [_]Case{
    .{ .pat = "$b$", .input = "b", .expect = null }, // auto wrongly matched {0,1}
    .{ .pat = "\\z.\\z", .input = "a", .expect = null },
    .{ .pat = "\\za\\z", .input = "a", .expect = null },
    .{ .pat = "$\n$", .input = "\n", .expect = null },
    .{ .pat = "\\z.$", .input = "a", .expect = null },
    // …including a NULLABLE (not must-consume) atom between the anchors — the
    // interior `text_end` is still non-trailing, so it must still be declined.
    // These match the empty string at end-of-text on the Pike VM.
    .{ .pat = "\\z.?\\z", .input = "a", .expect = "" },
    .{ .pat = "$\n?$", .input = "\n", .expect = "" },
    .{ .pat = "\\za*\\z", .input = "a", .expect = "" },
    // Controls — a single TRAILING `$`/`\z` is the common shape and must NOT be
    // declined (it stays DFA-eligible and must match correctly).
    .{ .pat = "a$", .input = "a", .expect = "a" },
    .{ .pat = "\\d+$", .input = "12", .expect = "12" },
    .{ .pat = "^abc$", .input = "abc", .expect = "abc" },
    .{ .pat = "abc\\z", .input = "abc", .expect = "abc" },
};

test "interior text_end is declined / trailing $ still matches (v0.5.0 regression)" {
    for (interior_text_end_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (v0.5.0): a `\b`/`\B` ADJACENT to a nullable alternation (sibling of,
// not inside, the `|`). Found by the supports-gate fuzz campaign. Same leftmost-
// first-across-an-assertion problem as `word_boundary_in_alternation`. Fixed by
// declining `\b`-with-a-nullable-alternation to the Pike VM
// (`hir.Analysis.word_boundary_with_nullable_alternation`). Controls: a `\b` with a
// NON-nullable alternation (and the benched `\bthe\b`) must STAY on the DFA.
const word_boundary_nullable_cases = [_]Case{
    .{ .pat = "\\B(?:|.*)", .input = "ab", .expect = "" }, // auto wrongly matched "a" ({1,2})
    .{ .pat = "b{0}\\b(|b)", .input = "b", .expect = "" },
    .{ .pat = "(?:a?|aa*)\\b", .input = "aa", .expect = "" },
    // Controls — `\b` with NO nullable alternation stays DFA-eligible.
    .{ .pat = "\\b(?:cat|dog)", .input = "cat", .expect = "cat" },
    .{ .pat = "\\bthe\\b", .input = "the", .expect = "the" },
    .{ .pat = "\\b\\w+\\b", .input = "hello", .expect = "hello" },
};

test "word-boundary-adjacent-nullable-alternation agrees across backends (v0.5.0 regression)" {
    for (word_boundary_nullable_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (v0.5.0): a LAZY repetition anywhere in a `\b`/`\B` pattern. Found by
// the differential fuzzer (`\n??\B`) and the external Rust oracle (`[^a]+?\B *`). A
// lazy quantifier prefers fewer reps, so leftmost-first takes the short match where
// the boundary holds; the longest-match DFA took the long one. Fixed by declining to
// the Pike VM (`hir.Analysis.word_boundary_with_lazy_repetition` — any non-greedy
// rep, not just nullable). Controls: the GREEDY forms (`a*\b`, `\w*\b`) agree on the
// DFA and must STAY on it (no bench loss).
const word_boundary_lazy_cases = [_]Case{
    .{ .pat = "a*?\\b", .input = "a", .expect = "" }, // auto wrongly matched "a"
    .{ .pat = "a??\\b", .input = "a", .expect = "" },
    .{ .pat = "\n??\\B", .input = "\n", .expect = "" },
    .{ .pat = "[^a]+?\\B *", .input = "-@11", .expect = "-" }, // lazy `+?` (min≥1); Rust-oracle find
    // Controls — greedy (nullable or not) before `\b` is correct on the DFA, stays eligible.
    .{ .pat = "a*\\b", .input = "ab", .expect = "" }, // greedy backtracks to {0,0}
    .{ .pat = "\\w*\\b", .input = "ab", .expect = "ab" },
    .{ .pat = "\n?\\B", .input = "\n", .expect = "\n" },
};

test "word-boundary-with-lazy-nullable agrees across backends (v0.5.0 regression)" {
    for (word_boundary_lazy_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (0.5.1): a `\b`/`\B` with two ADJACENT consuming repetitions whose split
// is ambiguous (`\n+(\n.*){0,2}\b` — a leading `\n+` overlapping a `(\n.*){0,2}` body).
// The boundary then holds at an early (greedy-`\n+`-first, shorter) end AND a later
// one; leftmost-first takes the early end (`{0,2}`), the longest-match byte DFA took
// the late one (`{0,4}`). Found by the 2M-run differential fuzz campaign. Declined to
// the Pike VM (`hir.Analysis.word_boundary_with_adjacent_repetition`). Controls: a
// single rep tight against the boundary (`\b\w+\b`, `\w*\b`, `.*\b`) is unambiguous and
// must STAY on the DFA (verified DFA-routed in the supports tests).
const word_boundary_adjacent_rep_cases = [_]Case{
    .{ .pat = "\n+(\n.*){0,2}\\b", .input = "\n\nab", .expect = "\n\n" }, // auto matched "\n\nab"
    .{ .pat = "\n+(\\B?\n.*){0,2}\\b", .input = "\n\nab", .expect = "\n\n" }, // the raw fuzzer find
    .{ .pat = "\n+(\n.*)*\\b", .input = "\n\nab", .expect = "\n\n" }, // unbounded outer too
    .{ .pat = "\n*(\n.*){0,2}\\b", .input = "\n\nab", .expect = "\n\n" }, // `\n*` leading
    // Controls — a single boundary-tight rep agrees on the DFA, stays eligible.
    .{ .pat = "\\b\\w+\\b", .input = "ab cd", .expect = "ab" },
    .{ .pat = "\\w*\\b", .input = "abc", .expect = "abc" },
    .{ .pat = ".*\\b", .input = "ab cd", .expect = "ab cd" },
    .{ .pat = "(\n.*){1,2}\\b", .input = "\n\nab", .expect = "\n\nab" }, // min-1, no leading overlap: stays
};

test "word-boundary-with-adjacent-repetition agrees across backends (0.5.1 regression)" {
    for (word_boundary_adjacent_rep_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (v0.5.0): a `(?m)` line anchor in a shape the eager DFA's `\n`-lookahead
// model can't carry — a non-trailing `(?m)$` (`(?m:$\n)`), a line anchor under a
// repetition (`(?m:\n$)*`), or a line anchor mixed with a `text_start`/`text_end`
// (`(?m:$)\A`, `$^\z`). Found by the supports-gate fuzz campaign (the largest
// family). Declined to the Pike VM (`hir.Analysis.complex_line_anchor` + the
// `has_line and (has_text_end or has_text_start)` gate). The benchmarked clean
// leading-`(?m)^` / trailing-`(?m)$` controls must STAY on the DFA fast path.
const complex_line_anchor_cases = [_]Case{
    .{ .pat = "(?m:$\n)", .input = "\n", .expect = "\n" }, // non-trailing (?m)$ (auto missed it)
    .{ .pat = "(?m:\n$)*", .input = "\n\n", .expect = "\n\n" }, // line anchor under *
    .{ .pat = "(?m:$\n){2}", .input = "\n\n", .expect = "\n\n" },
    .{ .pat = "(?m:$)\\A", .input = "", .expect = "" }, // line + text_start
    .{ .pat = "$^\\z", .input = "", .expect = "" }, // text_end + text_start + text_end
    // `(?m)$^` — a line_end immediately FOLLOWED by a line_start (the two contexts
    // can't be carried at one zero-width offset). The natural `^$` order is fine
    // (it's a control below); only `$`-then-`^` is interior. Found by the v0.5.0
    // supports-gate fuzz campaign (`(?m:$$^)` over "").
    .{ .pat = "(?m:$^)", .input = "", .expect = "" },
    .{ .pat = "(?m:$$^)", .input = "", .expect = "" },
    .{ .pat = "(?m:$^)", .input = "x", .expect = null }, // no match: x is neither at EOI nor 0-width
    // A `(?m)` line anchor INSIDE an alternation branch — a zero-width branch the
    // DFA's line model can't priority-order against a consuming sibling, so it took
    // the longer branch (leftmost-longest) instead of the empty leftmost-first match.
    // The line analogue of `\b`-in-alternation (class 1). Found by the 0.5.1 2M-run
    // fuzz campaign (`(?m:b{0,2}$)|(\n+|).?`).
    .{ .pat = "(?m:$)|(\n+|).?", .input = "\n\n", .expect = "" }, // line_end branch wins empty at 0
    .{ .pat = "(?m:b{0,2}$)|(\n+|).?", .input = "\n\n", .expect = "" },
    // Controls — clean leading `(?m)^` / trailing `(?m)$` (and the natural `^…$`
    // order) stay DFA-eligible.
    .{ .pat = "(?m)^line2", .input = "line1\nline2\nline3", .expect = "line2" },
    .{ .pat = "(?m)line2$", .input = "line2\nline3", .expect = "line2" },
    .{ .pat = "(?m)^\\w+", .input = "\nword", .expect = "word" },
    .{ .pat = "(?m)^\\w+$", .input = "ab\ncd", .expect = "ab" }, // ^…$ natural order stays on DFA
};

test "complex line anchors decline to Pike VM / simple (?m) stays on DFA (v0.5.0 regression)" {
    for (complex_line_anchor_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (0.5.1): the empty-width-loop collapse. An UNBOUNDED outer repetition
// (`*`/`+`/`{m,}`) over a body that lowers to a NULLABLE repetition (`S*`/`S*?`, but
// also bounded `S?`/`S??`/`S{0,k}`, optionally captured) is idempotent up to the body's
// unbounded form — `(S*)* ≡ S*`, `(S??){3,} ≡ S*?` — and is collapsed in HIR
// (`astNullableRepBody` + `widenBodyRepToUnbounded`). Without it the redundant outer
// loop made the Pike VM over-consume on a nullable lazy body (`(?:c*?)+.` matched "cc";
// `(?:a??){3,}` matched "aaa"; leftmost-first / Rust say "c" / ""). Found by the
// differential fuzzer (`b(){5,}|(?:[cc]*?){3,}.`, then `(?i:[cca-c1]??){3,}`).
// Expectations cross-checked against Rust `regex` (an automata, leftmost-first engine).
// Controls: non-nullable inner (`c+?`), greedy bounded inner (`a?`→ greedy `a*`),
// bounded OUTER (`{2,3}`), and downstream-forced consume (`(?:a*?)+b`) UNAFFECTED.
const empty_loop_collapse_cases = [_]Case{
    .{ .pat = "(?:c*?)+.", .input = "ccc", .expect = "c" }, // was "cc"
    .{ .pat = "(?:c*?){3,}.", .input = "ccc", .expect = "c" }, // the fuzzer's seed
    .{ .pat = "(?:c*?)+", .input = "ccc", .expect = "" }, // was "c"
    .{ .pat = "(?:c*?){2,}", .input = "ccc", .expect = "" },
    .{ .pat = "(?:c*?)*", .input = "ccc", .expect = "" },
    .{ .pat = "(?:(?:c*?)+)+", .input = "ccc", .expect = "" }, // doubly nested
    .{ .pat = "(c*?)+", .input = "ccc", .expect = "" }, // capturing body
    .{ .pat = "(?:c*?){2,}?", .input = "ccc", .expect = "" }, // lazy outer too
    // Bounded nullable inner (`S?`/`S??`/`S{0,k}`) — collapses to a star (2nd fuzz find):
    .{ .pat = "(?:a??){3,}", .input = "aaa", .expect = "" }, // ≡ a*? ; was "aaa"
    .{ .pat = "(?:a??)+", .input = "aaa", .expect = "" },
    .{ .pat = "(?:a?){3,}", .input = "aaa", .expect = "aaa" }, // a? greedy ≡ a* ; stays "aaa"
    .{ .pat = "(?:a{0,3}?)+b", .input = "aaab", .expect = "aaab" }, // lazy bounded, forced
    .{ .pat = "(a??){2,}", .input = "aaa", .expect = "" }, // capturing bounded nullable
    // Controls — must stay exactly as before (NOT collapsed):
    .{ .pat = "(?:c+?)+", .input = "ccc", .expect = "ccc" }, // non-nullable inner
    .{ .pat = "(?:c*)+.", .input = "ccc", .expect = "ccc" }, // greedy inner
    .{ .pat = "(?:c*?){2,3}.", .input = "ccc", .expect = "c" }, // bounded outer
    .{ .pat = "(?:a*?)+b", .input = "aaab", .expect = "aaab" }, // downstream-forced
    .{ .pat = "(?:[ab]*?)+c", .input = "abbac", .expect = "abbac" },
};

test "empty-width-loop collapse: unbounded-over-nullable matches leftmost-first (0.5.1 regression)" {
    for (empty_loop_collapse_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (0.6.0): the empty-width-loop guard fixes an unbounded outer over a nullable
// CONCAT body with a lazy part (`(?:a?b??)+`, `(?:a??b??)+`) — the form the HIR collapse
// could NOT reach (a concat body is not a single repetition to widen). The fix is the
// empty-width-loop guard in the pikevm/backtrack/onepass `.jmp` handlers (a loop-back that
// closes an empty iteration routes to the loop exit at the empty path's priority instead of
// over-consuming) plus the do-while loop shape for nullable `x*` in `byte.zig` (the byte
// DFAs / bytepike). All backends — pikevm, backtrack, AND auto — now agree on the
// leftmost-first answer. Was a documented limitation through 0.5.1; the guard closes it.
// (A nullable-*alternation* body, `(?:|.)+`, is a different shape: it stays routed to the
// Pike VM via `nullable_alternation_in_repetition`; see that test above.)
const empty_loop_concat_cases = [_]Case{
    .{ .pat = "(?:a?b??)+", .input = "ab", .expect = "a" }, // was pikevm "ab"
    .{ .pat = "(?:a??b??)+", .input = "ab", .expect = "" }, // was pikevm "a"
    .{ .pat = "(?:a?b?c??)+", .input = "abc", .expect = "ab" },
    .{ .pat = "(?:a?b??){2,}", .input = "ab", .expect = "a" }, // counted unbounded form
    .{ .pat = "(a?b??)+", .input = "ab", .expect = "a" }, // capturing body
    // Forced-consume controls (all engines already agreed here):
    .{ .pat = "(?:a?b??)+x", .input = "abx", .expect = "abx" },
    .{ .pat = "(?:a??b??)+b", .input = "ab", .expect = "ab" },
    .{ .pat = "(?:a?b?)+", .input = "ab", .expect = "ab" }, // greedy body: consumes (unchanged)
};

test "empty-width-loop over a nullable concat body: all backends leftmost-first correct (0.6.0 regression)" {
    // pikevm + backtrack now agree with the byte DFA (`auto`) thanks to the empty-loop guard.
    for (empty_loop_concat_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (0.6.0): a `\b`/`\B` trailing an alternation with length-varying, OVERLAPPING
// branches used to lose leftmost-first priority on the EAGER byte DFA (`edfa`), and so on
// `auto`. `(b+|.+)\B` on "baaa": leftmost-first tries `b+` first → "b" `[0,1)` (`\B` holds
// between 'b' and 'a'); the eager DFA took the longer `.+` branch → `[0,3)`. Fixed by
// declining the shape from the eager arm (`hir.Analysis.word_boundary_after_varying_alternation`,
// gated in `edfa.supports`); `auto` then serves it on the leftmost-first-correct path and the
// lazy `dfa` (decode-hybrid boundary) stays eligible. Found by a differential anchor fuzz campaign.
const word_boundary_after_alt_cases = [_]Case{
    .{ .pat = "(b+|.+)\\B", .input = "baaa", .expect = "b" }, // was edfa/auto "baa"
    .{ .pat = "(?:b|baaa)\\B", .input = "baaab", .expect = "b" }, // was edfa/auto "baaa"
};
const word_boundary_after_alt_ok_cases = [_]Case{
    // Control: non-overlapping (disjoint-first) branches → no priority conflict → stays on the
    // eager DFA fast path and ALL backends agree.
    .{ .pat = "(?:b+|a+)\\B", .input = "baaa", .expect = "b" },
    .{ .pat = "\\b(foo|bar)\\b", .input = "a foo b", .expect = "foo" }, // disjoint-first: eager DFA
};

test "word boundary after a length-varying alternation agrees across backends (0.6.0 regression)" {
    // Previously a documented eager-DFA gap; now `auto` (and the lazy DFA) are leftmost-first
    // correct. `edfa` declines the diverging shape (it is the eager arm), so it is not checked
    // directly on the diverging set.
    for (word_boundary_after_alt_cases) |c| {
        try checkRuntime(pikevm, c); // leftmost-first reference
        try checkRuntime(backtrack, c);
        try checkRuntime(dfa, c); // lazy DFA — leftmost-first correct
        try checkRuntime(auto, c);
    }
    // The disjoint-first controls stay correct on every backend, incl. `auto`/`edfa`.
    for (word_boundary_after_alt_ok_cases) |c| {
        try checkRuntime(pikevm, c);
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c);
    }
}

// Regression (0.6.0): a `\b`/`\B` lexically INSIDE a repetition (`(b.{0,2}\B)+`) — the repeated
// body makes the boundary position ambiguous across iterations, and the eager byte DFA took the
// longer end (`(b.{0,2}\B)+` on "bbbab…" → "bbbab"; leftmost-first is "bbb"). Fixed by declining
// the shape from the eager arm (`hir.Analysis.word_boundary_in_repetition`, gated in
// `edfa.supports`); `auto` then serves it on the leftmost-first-correct path (Pike VM / lazy DFA).
// Found by the differential anchor fuzz. A top-level boundary (`\b\w+\b`) is NOT inside a rep and
// stays on the eager DFA.
const word_boundary_in_rep_cases = [_]Case{
    .{ .pat = "((?m:b).{0,2}\\B)+", .input = "bbbabb\naababba\na", .expect = "bbb" }, // was edfa/auto "bbbab"
    .{ .pat = "(b.{0,2}\\B)+", .input = "bbbab", .expect = "bbb" },
};

test "word boundary inside a repetition agrees across backends (0.6.0 regression)" {
    for (word_boundary_in_rep_cases) |c| {
        try checkRuntime(pikevm, c); // leftmost-first reference
        try checkRuntime(backtrack, c);
        try checkRuntime(dfa, c); // lazy DFA — correct
        try checkRuntime(auto, c);
    }
    // Control: a top-level `\b\w+\b` is not inside a repetition → stays on the eager DFA fast path.
    try checkRuntime(auto, .{ .pat = "\\b\\w+\\b", .input = "  hello  ", .expect = "hello" });
    try checkRuntime(edfa, .{ .pat = "\\b\\w+\\b", .input = "  hello  ", .expect = "hello" });
}

// Regression (0.6.0): the leading-class first-byte SIMD scan (`classscan`, the `class_lead`
// prefilter `auto` uses for `\p{N}+`, `\d+`, `\d{4}-…`) must find the SAME leftmost match as
// the Pike VM over **non-ASCII** text. The shufti classifier rewrite (per-high-nibble buckets)
// fixed a precision bug — the old single-bucket scheme let Cyrillic lead bytes (0xD0/0xD1) pass
// the nibble filter for the broad `\p{N}` lead set, a false-positive storm that was correct but
// slow (subtitles-ru 515µs → 308µs). These cases pin the end-to-end correctness of that scan
// path over Cyrillic / mixed-script input — a soundness break in `classscan` would skip or
// misplace a match here, diverging from the Pike VM oracle.
const class_lead_nonascii_cases = [_]Case{
    .{ .pat = "\\p{N}+", .input = "Привет 42 — мир 7", .expect = "42" }, // digits amid Cyrillic + em-dash
    .{ .pat = "\\p{N}+", .input = "только буквы здесь", .expect = null }, // no number anywhere
    .{ .pat = "\\p{N}+", .input = "год ٢٠٢٤ конец", .expect = "٢٠٢٤" }, // Arabic-Indic digits (lead 0xD9)
    .{ .pat = "\\p{N}+", .input = "число 一二三 ⅩⅠⅤ 99", .expect = "ⅩⅠⅤ" }, // Roman numerals = \p{Nl}; CJK 一二三 = \p{Lo}, skipped (3-byte lead)
    .{ .pat = "\\d+", .input = "абвгд123еёжз", .expect = "123" }, // ASCII digits inside 2-byte text
};

test "leading-class scan finds leftmost match over non-ASCII (0.6.0 shufti regression)" {
    for (class_lead_nonascii_cases) |c| {
        try checkRuntime(pikevm, c); // leftmost-first reference
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c); // exercises the class_lead / classscan prefilter
    }
}

// Regression (0.6.0): the lazy-DFA arm's leading-literal and rare interior-anchor
// jump-and-confirm loops (`auto.runByteDfa`) — the prefilter that replaced a single skip
// + full native pass with a per-occurrence anchored confirm (~2× on `the\s+\p{L}+`, ~2× on
// `[\w.+-]+@…`). These are *prone* patterns (an unbounded run before accept), so they route to
// the lazy DFA; the loop confirms anchored at each occurrence under a `reach` budget. The crux
// is leftmost-first correctness: the first confirmed occurrence must be the leftmost match, and
// failed/overlapping confirms must not drop or shift a match. Each case below has a leading
// literal ("the") or a rare anchor ('@') and exercises a mix of fast-fail, match, and
// no-match-after-many-candidates inputs. `auto` (the jump-confirm) must agree with the Pike VM.
const jump_confirm_cases = [_]Case{
    // Leading literal "the" + `\s+\p{L}+`: many "the" candidates; most are inside other words.
    .{ .pat = "the\\s+\\p{L}+", .input = "there then the cat sat", .expect = "the cat" }, // "there"/"then" fail \s+; leftmost real "the " wins
    .{ .pat = "the\\s+\\p{L}+", .input = "the\tquick brown", .expect = "the\tquick" }, // tab counts as \s
    .{ .pat = "the\\s+\\p{L}+", .input = "theatre theme thesis", .expect = null }, // every "the" fails \s+
    .{ .pat = "the\\s+\\p{L}+", .input = "the   späte Stunde", .expect = "the   späte" }, // multi-space + non-ASCII letter
    .{ .pat = "the\\s+\\p{L}+", .input = "xxx the end", .expect = "the end" }, // leftmost after a gap
    .{ .pat = "the\\s+\\p{L}+", .input = "the the the the x", .expect = "the the" }, // dense; first wins
    // Rare interior anchor '@' (email-shaped): the anchor leaps over non-'@' regions.
    .{ .pat = "[\\w.+-]+@[\\w-]+\\.[\\w.-]+", .input = "log: a.b+c@mail.example.com end", .expect = "a.b+c@mail.example.com" },
    .{ .pat = "[\\w.+-]+@[\\w-]+\\.[\\w.-]+", .input = "no at-sign here at all", .expect = null },
    .{ .pat = "[\\w.+-]+@[\\w-]+\\.[\\w.-]+", .input = "bad@ then good@host.io rest", .expect = "good@host.io" }, // first '@' fails (no domain), second matches (greedy lead reverse-scan stops at the space)
    .{ .pat = "[\\w.+-]+@[\\w-]+\\.[\\w.-]+", .input = "a@@@@@@b.c@d.e", .expect = "b.c@d.e" }, // adversarial '@' density; leftmost valid
};

test "lazy-arm jump-and-confirm (leading literal / rare interior anchor) is leftmost-first (0.6.0 regression)" {
    for (jump_confirm_cases) |c| {
        try checkRuntime(pikevm, c); // leftmost-first oracle
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c); // exercises runByteDfa's jump-confirm loops
    }
}

// Regression (0.6.0): the leading-class SIMD skip now admits a **sparse-ASCII / broad-tail**
// class (`\p{Lu}…`) via a sound over-approximating derived set — `{ASCII members} ∪ {all high
// bytes}` (`auto.asciiLeadDerived`) — so capitalized-word scans (`\p{Lu}\p{Ll}+`) skip the
// lowercase gaps to the next capital instead of stepping byte-by-byte (~2–3× on Latin prose). The
// over-approximation must stay **leftmost-first**: the scan may not skip past any real start, and
// a failing capital (a `\p{Lu}` not followed by `\p{Ll}`) must not drop the next match. These
// inputs mix ASCII capitals, isolated capitals, non-ASCII uppercase (whose lead is a high byte),
// and capitals at offset 0 / after a gap. `auto` (the derived class skip) must agree with the
// Pike VM.
const class_lead_derived_cases = [_]Case{
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "the Quick brown Fox", .expect = "Quick" }, // skip lowercase to first capital word
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "Hello world", .expect = "Hello" }, // capital at offset 0
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "A I X then Yes", .expect = "Yes" }, // isolated capitals (A,I,X) fail \p{Ll}+; leftmost real word wins
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "ALLCAPS shout Then", .expect = "Then" }, // run of capitals, no lowercase, until "Then"
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "café Über straße", .expect = "Über" }, // non-ASCII uppercase Ü (high lead byte) is a candidate
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "nothing here lowercase", .expect = null }, // no capital at all
    .{ .pat = "\\p{Lu}\\p{Ll}+", .input = "Привет мир Слово", .expect = "Привет" }, // Cyrillic: every byte high → stops at once, native find (neutral path)
    .{ .pat = "\\p{Lu}+", .input = "abcDEFghi", .expect = "DEF" }, // uppercase run, derived skip over abc
    .{ .pat = "\\p{Lu}+", .input = "lower ONLY caps", .expect = "ONLY" },
};

test "leading-class derived skip (sparse-ASCII / broad-tail class) is leftmost-first (0.6.0 regression)" {
    for (class_lead_derived_cases) |c| {
        try checkRuntime(pikevm, c); // leftmost-first oracle
        try checkRuntime(backtrack, c);
        try checkRuntime(auto, c); // exercises auto.asciiLeadDerived's class skip on the eager/lazy arm
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
        if (!byteEngineCanRunCase(c.pat, c.input)) continue; // ASCII-\b contract
        try checkRuntime(bytepike, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!byteLowerablePattern(c.pat)) continue;
        if (!byteEngineCanRunCase(c.pat, c.input)) continue;
        try checkRuntime(bytepike, c);
        ran += 1;
    }
    try testing.expect(ran > 0); // guard against the filter silently skipping everything
}

// ── lazy DFA span conformance ─────────────────────────────────────────────────────

/// Whether `pattern` can run on the lazy DFA (`dfa.supports`): byte-lowerable, with `\A`/`^`,
/// anchored-end `$`, and **isolated `\b`/`\B`** (Unicode, via the decode-hybrid) allowed; mixed `$`,
/// `(?m)` line anchors, `\X`, and `\b`+`$` declined. A narrower gate than `byteLowerablePattern`.
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
        // NOTE: no ASCII-\b guard here — the LAZY DFA evaluates Unicode `\b`/`\B` (decode-hybrid),
        // so it must agree with the code-point engines on non-ASCII `\b` input too.
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
        if (!byteEngineCanRunCase(c.pat, c.input)) continue; // ASCII-\b contract
        try checkRuntime(edfa, c);
        ran += 1;
    }
    for (literal_cases) |c| {
        if (!edfaBuildable(c.pat)) continue;
        if (!byteEngineCanRunCase(c.pat, c.input)) continue;
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
    // leading (?m)^ on the LAZY DFA: the eager DFA declines the prone / many-state shapes below
    // (a `\S+`/`[^…]` run before more pattern), so these exercise the lazy DFA's line-gated
    // forward re-seed + reverse line-accept directly (the log_line fix). Spans hand-computed.
    .{ .pat = "(?m)^\\S+ \\S+", .input = "aa bb\ncc dd\nee", .spans = &.{ .{ 0, 5 }, .{ 6, 11 } } }, // 3rd line has no 2nd field
    .{ .pat = "(?m)^\\S+ \\S+", .input = "x yy zz\nq w", .spans = &.{ .{ 0, 4 }, .{ 8, 11 } } }, // greedy \S+ stops at first space; line 2 at 8
    // a class that CROSSES newlines ([^z] matches \n) — the match may legitimately span lines;
    // the leftmost still begins at a line start. (Prone shape: this is exactly why log_line is
    // declined by the eager DFA and the Pike VM; the lazy DFA does it in one O(n) pass.)
    .{ .pat = "(?m)^a[^z]*z", .input = "qq\nab\ncz", .spans = &.{.{ 3, 8 }} }, // starts at line-2 'a' (3), [^z]* eats "b\nc", ends at z(7)→8
    .{ .pat = "(?m)^a[^z]*z", .input = "az\nayz", .spans = &.{ .{ 0, 2 }, .{ 3, 6 } } }, // two line-anchored matches
    // log_line-shaped: bracket/quote fields with newline-crossing complements, multiple lines.
    .{ .pat = "(?m)^(\\S+) \\[([^\\]]+)\\] \"([^\"]*)\"", .input = "GET [ok] \"hi\"\nPUT [no] \"bye\"", .spans = &.{ .{ 0, 13 }, .{ 14, 28 } } },
    // log_line span fast path (`lineAnchoredSpan`, v0.5.0): a non-matching middle line must be
    // skipped and matching resume at the next line start (no eager DFA → the line-anchored arm).
    .{ .pat = "(?m)^(\\S+) \\[([^\\]]+)\\] (\\d{3})", .input = "a [x] 200\nbad line\nb [y] 404", .spans = &.{ .{ 0, 9 }, .{ 19, 28 } } },
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

test "new prefilters (case-variant Teddy / leading-class scan): findAll agrees with the Pike VM" {
    // The wide corpus pins the leftmost *single* match; this pins **every** non-overlapping match
    // over multi-hit inputs, so the per-occurrence confirm loop (case-variant / bounded multi-prefix)
    // and the repeated leading-class skip can't drop, duplicate, or misplace a match. `auto` (with the
    // new SIMD prefilters) must produce span-for-span what the Pike VM (no prefilter) does.
    const gpa = testing.allocator;
    const cases = [_]Case{
        // case-variant prefilter, dense + mixed case + near-misses
        .{ .pat = "(?i)the", .input = "The theme: tHe THE then THEATRE, oTHEr the", .expect = null },
        .{ .pat = "(?i)что", .input = "Что? что-то ЧТО! не что иначе, чТо.", .expect = null },
        .{ .pat = "(?i)cat", .input = "car CAT cab Cat caT category scatter", .expect = null },
        .{ .pat = "(?i)sherlock", .input = "she SHERlock sher Sherlock ashes sHeRlOcK", .expect = null },
        .{ .pat = "[Tt]he", .input = "the The tHe THE then", .expect = null },
        // leading-class SIMD scan, sparse and dense digit/number runs across gaps
        .{ .pat = "\\d+", .input = "a1 .... 23 ..... 456 . 7 ...... 89012 z", .expect = null },
        .{ .pat = "\\p{N}+", .input = "no nums then 12, ٤٥٦, 789, ١٢ end", .expect = null },
        .{ .pat = "\\d+", .input = "...................................... 42 ......................", .expect = null },
    };
    for (cases) |c| {
        var ov: [16][2]usize = undefined;
        const on = (try collectSpans(pikevm, gpa, c.pat, c.input, &ov)).?;
        var av: [16][2]usize = undefined;
        const an = (try collectSpans(auto, gpa, c.pat, c.input, &av)).?;
        testing.expectEqual(on, an) catch {
            std.debug.print("/{s}/ on \"{s}\": auto found {d} spans, Pike VM {d}\n", .{ c.pat, c.input, an, on });
            return error.Mismatch;
        };
        for (0..on) |i| {
            try testing.expectEqual(ov[i][0], av[i][0]);
            try testing.expectEqual(ov[i][1], av[i][1]);
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
    // (auto routes searchCaptures to the capture engine, span scan to the DFA). `(\w+)@(\w+)`
    // has a big byte NFA (`\w` joined), so it exceeds `EAGER_BYTE_INST_MAX` and routes to the
    // LAZY DFA span arm ("nfa+dfa") rather than the eager one — captures must still be correct.
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "(\\w+)@(\\w+)", &diag, .{ .strategy = .{ .byte_engine = .enabled } });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);

    try testing.expectEqualStrings("nfa+dfa", auto.route(&re.program));
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
    // Empty-width-loop collapse cases (0.5.1): capture slots must stay identical
    // across backends after the HIR collapse drops a redundant unbounded outer rep.
    "(c*?)+", // collapses to (c*?); slot must be the body's, not the loop's
    "((?:c*?)+)x", // outer capture, inner loop collapsed
    "(?:(c*?)+)x", // inner capture, outer loop collapsed
    "((c*?)){3,}", // nested captures through the collapse
    "(a(b*?)+)b", // collapse inside a larger capture
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
    const inputs = [_][]const u8{ "2026-06-07", "alice@example.com", "abc", "aaabb", "2026-06", "abab", "ccc", "ccx", "abbb", "aaab" };
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

test "one-pass capture path agrees with the Pike VM wherever it applies (front door)" {
    // The one-pass backend fills the SAME slots as the Pike VM on every pattern it accepts;
    // a non-one-pass pattern (e.g. `((a)(b))+`) is declined (`error.Unsupported`) and skipped
    // — soundly handled by the Pike VM. This pins both the one-pass *decision* and its
    // single-thread *executor* against the oracle through the public front door.
    const gpa = testing.allocator;
    const inputs = [_][]const u8{ "2026-06-07", "alice@example.com", "abc", "aaabb", "2026-06", "abab", "user@host.org" };
    for (capture_cases) |pat| {
        for (inputs) |in| {
            var a: [16]?usize = undefined;
            var b: [16]?usize = undefined;
            const ra = try captureSlots(pikevm, gpa, pat, in, &a);
            const rb = captureSlots(onepass, gpa, pat, in, &b) catch |e| switch (e) {
                error.Unsupported => continue, // not one-pass → the Pike VM covers it
                else => return e,
            };
            try testing.expectEqual(ra, rb);
            if (ra) try testing.expectEqualSlices(?usize, &a, &b);
        }
    }
}

test "auto fills one-pass captures through its DFA→one-pass handoff" {
    const gpa = testing.allocator;
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(auto, gpa, "(\\d{4})-(\\d{2})-(\\d{2})", &diag, .{});
    defer re.deinit();
    try testing.expect(re.program.onepass_prog != null); // a one-pass capture table was built
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var slots: [8]?usize = undefined;
    const c = re.captures(&sc, &slots, "on 2026-06-14 ok").?;
    try testing.expectEqualStrings("2026-06-14", c.match().slice("on 2026-06-14 ok"));
    try testing.expectEqualStrings("2026", c.groupSlice(1).?);
    try testing.expectEqualStrings("06", c.groupSlice(2).?);
    try testing.expectEqualStrings("14", c.groupSlice(3).?);
}

test "line-anchored capture path agrees with the Pike VM (log_line shape, v0.5.0)" {
    // A `(?m)^` capture pattern too big for the eager DFA → `auto` takes the line-anchored CAPTURE
    // path (attempt the Pike VM anchored at each line start). The filled slots must equal the Pike
    // VM oracle (which scans unanchored). Covers: match on line 1, match on a later line after a
    // non-matching one (the line-skip), no match at all, and a single line.
    const gpa = testing.allocator;
    const pat = "(?m)^(\\S+) \\[([^\\]]+)\\] (\\d{3})";
    { // confirm `auto` actually engages the line-anchored arm (edfa null, line_anchored set)
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(auto, gpa, pat, &diag, .{});
        defer re.deinit();
        try testing.expect(re.program.edfa_prog == null);
        try testing.expect(re.program.filter.line_anchored);
    }
    const inputs = [_][]const u8{
        "a [x] 200\nb [y] 404", // line 1 matches
        "bad line here\nb [y] 404", // line 1 fails → skip to line 2
        "no match at all\nstill nope", // nothing matches
        "a [x] 200", // single line
        "\na [x] 200", // leading blank line
    };
    for (inputs) |in| {
        var a: [16]?usize = undefined;
        var b: [16]?usize = undefined;
        const ra = try captureSlots(pikevm, gpa, pat, in, &a);
        const rb = try captureSlots(auto, gpa, pat, in, &b);
        testing.expectEqual(ra, rb) catch {
            std.debug.print("line-anchored captures on \"{s}\": auto matched={}, Pike VM={}\n", .{ in, rb, ra });
            return error.Mismatch;
        };
        if (ra) try testing.expectEqualSlices(?usize, &a, &b);
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
    .{ .pat = "\\bword\\b", .input = "a word here", .expect = "word" }, // lit_wb confirm (comptime edfa arm)
    .{ .pat = "\\d{4}-\\d{2}-\\d{2}", .input = "x 2026-06-07 y", .expect = "2026-06-07" }, // interior anchor (v0.5.0)
    .{ .pat = "(?m)^\\w+", .input = "ab\ncd", .expect = "ab" }, // line-anchored (v0.5.0)
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

// ══════════════════════════════════════════════════════════════════════════════
// Regressions for bugs surfaced by the hardened fuzz harness (fuzz/groups)
// ══════════════════════════════════════════════════════════════════════════════

/// Assert `isMatch == (find != null) == want` for backend `B` (a declining backend is skipped).
fn expectIsMatchEqFind(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, want: bool) !void {
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch return; // backend declined → skip
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const found = re.find(&sc, input) != null;
    var sc2 = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc2.deinit(gpa);
    const im = re.isMatch(&sc2, input);
    if (found != im or found != want) {
        std.debug.print("{s} /{s}/ over \"{s}\": find={} isMatch={} want={}\n", .{ @typeName(B), pattern, input, found, im, want });
        return error.IsMatchFindMismatch;
    }
}

// Fixed: the eager/lazy DFA's `isMatch` disagreed with its own `find` for a `text_end`
// (`$`/`\z`) program that is **not** `end_anchored` — `^?\z` and friends, where an *optional*
// line-start `^?` keeps the program `has_text_end` but not `end_anchored`. `isMatchImpl` only
// routed `end_anchored` text_end programs through the reverse automaton and otherwise fell to
// `runUnanchored`, which can never accept a text_end program (no mid-input `match` state) →
// wrong `false`, while `find` correctly matched the empty span at the end anchor. Surfaced by
// the fuzz `isMatch == (find != null)` invariant (anchors group). See `dfa.isMatchImpl`.
test "regression: dfa isMatch agrees with find for optional-^ end anchors (^?\\z family)" {
    const gpa = testing.allocator;
    const cases = [_]struct { p: []const u8, i: []const u8 }{
        .{ .p = "^?\\z", .i = "" },     .{ .p = "^?\\z", .i = "x" },
        .{ .p = "^?\\z", .i = "ab" },   .{ .p = "(?:^)?\\z", .i = "" },
        .{ .p = "^?$", .i = "" },       .{ .p = "^?$", .i = "ab" },
        .{ .p = "\\z", .i = "" },       .{ .p = "a?\\z", .i = "" },
    };
    inline for (.{ pikevm, dfa, edfa, bytepike, backtrack, auto }) |B| {
        for (cases) |c| try expectIsMatchEqFind(B, gpa, c.p, c.i, true); // each matches the empty span at the anchor
    }
}

/// Collect every `findAll` span of `pattern`/`input` on backend `B` into `out`; returns the count.
fn collectFindAll(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, out: [][2]usize) !usize {
    var diag: regex.Diagnostic = .{};
    var re = try regex.compileRuntimeWith(B, gpa, pattern, &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var n: usize = 0;
    var it = re.findAll(&sc, input);
    while (it.next()) |m| : (n += 1) {
        if (n < out.len) out[n] = .{ m.start, m.end };
    }
    return n;
}

// Documented contract surfaced by the fuzz replace/iter differential: the byte engines
// (`bytepike`, eager/lazy DFA) evaluate `\b`/`\B` as **ASCII** word boundaries, so over a
// NON-ASCII byte they can legitimately pick a different match than the code-point engines'
// Unicode `\b`. Minimal trigger: `…|\b.|…` over `{0xBA, 'l'}` — the byte engine sees a boundary
// at offset 1 (`0xBA` is a non-word *byte*) and matches `\b.` → `(1,2)`, while the code-point
// engines decode `0xBA` → U+FFFD (non-word) and, taking the leftmost-first empty branch,
// match `(1,1)`. This is BY DESIGN — `auto` routes a non-ASCII `\b` to the code-point engines
// — so the fuzz harness gates the byte engines on such cases (`byteEnginesSafe`). The pin: the
// CODE-POINT engines (and `auto`, which routes correctly) must all agree on the full sequence.
test "regression: non-ASCII \\b — code-point engines agree; byte engines may differ (by design)" {
    const gpa = testing.allocator;
    const pat = "^\\S?a[^c\\p{L}b\\d]+.+|\\b.|| +";
    const input = [_]u8{ 0xBA, 'l' };
    var ref: [16][2]usize = undefined;
    const nref = try collectFindAll(pikevm, gpa, pat, &input, &ref);
    inline for (.{ backtrack, auto }) |B| {
        var got: [16][2]usize = undefined;
        const n = try collectFindAll(B, gpa, pat, &input, &got);
        try testing.expectEqual(nref, n);
        try testing.expectEqualSlices([2]usize, ref[0..nref], got[0..n]);
    }
    // And the byte engine genuinely takes the ASCII-\b path here (documents *why* it is gated):
    // it matches `\b.` at offset 1 where the code-point engines match empty.
    var bp: [16][2]usize = undefined;
    const nbp = try collectFindAll(bytepike, gpa, pat, &input, &bp);
    try testing.expect(nbp != nref or !std.mem.eql([2]usize, ref[0..nref], bp[0..nbp]));
}

fn faSeqEq(a: []const [2]usize, b: []const [2]usize) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x[0] != y[0] or x[1] != y[1]) return false;
    return true;
}

// Fixed: the bounded backtracker's unanchored scan advanced start positions byte-by-byte
// (`start += 1`), so over **valid multi-byte UTF-8** it attempted matches at interior bytes of
// a code point and reported a spurious **zero-width** match there — e.g. `\B{4}` over U+AAE9
// (`ea ab a9`) matched `(2,2)` (mid-code-point), where the Pike VM (and `auto`) correctly find
// nothing (the input is one code point; positions 0 and 3 are both word boundaries). Surfaced as
// a pikevm-vs-backtrack `findAll` divergence (iter group). **Fixed** by advancing the scan to the
// next code-point boundary (`start += decodeAt(input, start).len`), mirroring the Pike VM's
// `sp += cp_len`. (ASCII / invalid leads advance 1, so byte-level scanning of invalid UTF-8 is
// unchanged.) See `backtrack.run`.
fn expectFindAllAllAgree(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) !void {
    var ref: [64][2]usize = undefined;
    const nref = try collectFindAll(pikevm, gpa, pattern, input, &ref);
    inline for (.{ backtrack, auto }) |B| {
        var got: [64][2]usize = undefined;
        const n = try collectFindAll(B, gpa, pattern, input, &got);
        if (!faSeqEq(ref[0..nref], got[0..n])) {
            std.debug.print("findAll mismatch {s} on /{s}/ over {x}: pike={d} other={d}\n", .{ @typeName(B), pattern, input, nref, n });
            return error.FindAllMismatch;
        }
    }
}

test "regression: backtracker unanchored scan is code-point-aligned (no mid-code-point \\B match)" {
    const gpa = testing.allocator;
    const u_aae9 = [_]u8{ 0xea, 0xab, 0xa9 }; // one valid 3-byte code point, U+AAE9
    // The minimized repro and the bare construct: no spurious mid-code-point empty match.
    try expectFindAllAllAgree(gpa, "\\B{4}", &u_aae9);
    try expectFindAllAllAgree(gpa, "()1|(A|\\B{4}())", &u_aae9);
    // A few more zero-width / empty-matchable shapes over multi-byte input.
    try expectFindAllAllAgree(gpa, "\\B", "\xC3\xA9\xC3\xA9"); // éé
    try expectFindAllAllAgree(gpa, "()", "\xE6\x97\xA5"); // 日 — empty matches only at code-point boundaries
    try expectFindAllAllAgree(gpa, "\\b|\\B", &u_aae9);
    // Control: on ASCII the boundary still matches where it should.
    try expectFindAllAllAgree(gpa, "\\B{4}", "ab");
}

fn checkFindAllVsPike(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, ref: []const [2]usize) !void {
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch return; // backend declined → skip
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    var got: [64][2]usize = undefined;
    var n: usize = 0;
    var it = re.findAll(&sc, input);
    while (it.next()) |m| : (n += 1) {
        if (n < got.len) got[n] = .{ m.start, m.end };
    }
    if (!faSeqEq(ref, got[0..n])) {
        std.debug.print("mid-cp findAll mismatch {s} on /{s}/ over {x}: pike.len={d} other.len={d}\n", .{ @typeName(B), pattern, input, ref.len, n });
        return error.MidCodePointScan;
    }
}

// Fixed (systemic): the lazy DFA (`dfa`), eager DFA (`edfa`), and `bytepike` advanced their
// unanchored start scan byte-by-byte, so over valid multi-byte UTF-8 they attempted a match at an
// interior byte of a code point and a zero-width pattern matched there — disagreeing with the Pike
// VM. Fixed by advancing each scan to the next code-point boundary (`+= nfa.decodeAt(input,s).len`,
// like `onepass`/`pikevm`); `bytepike` seeds its thread-set start only at code-point offsets. The
// `\b`/`\B` byte-engine semantics stay ASCII (gated elsewhere), so these cases are deliberately
// **non-`\b`** zero-width / empty-matchable shapes, where every backend must agree over multibyte.
test "regression: byte engines' unanchored scan is code-point-aligned over multibyte" {
    const gpa = testing.allocator;
    const cases = [_]struct { p: []const u8, i: []const u8 }{
        .{ .p = "()", .i = "\xE6\x97\xA5" }, // 日 — empty match only at offsets 0 and 3
        .{ .p = "a*", .i = "\xC3\xA9\xC3\xA9" }, // éé
        .{ .p = "\\z{0,2}", .i = "\xCE\xB1" }, // α — quantified end anchor
        .{ .p = "x?", .i = "\xF0\x9F\x98\x80" }, // 😀 (4-byte)
        .{ .p = "(?:a{0,2}|\\z{0,2}\\n?)+", .i = "\xE6\x97\xA5" }, // a fuzz repro shape
    };
    for (cases) |c| {
        var ref: [64][2]usize = undefined;
        const nref = try collectFindAll(pikevm, gpa, c.p, c.i, &ref);
        inline for (.{ backtrack, auto, bytepike, dfa, edfa, onepass }) |B| {
            try checkFindAllVsPike(B, gpa, c.p, c.i, ref[0..nref]);
        }
    }
}

// Fixed: the EAGER DFA's `isMatch` used the one-pass `utrans` scan for a `prone` program, but that
// table cannot carry an **interior** `text_start` (`\A`/`^` after a consuming prefix) — so `a*^$`,
// `a*\A$`, `b*^\z`, `(?:a*)^$` over "" reported `isMatch=false` while `find` matched the empty span
// (same class as the lazy-DFA `^?\z` fix, different code path / backend). Fixed by gating the
// one-pass path on `!has_text_start`, so such programs use the anchored restart (which evaluates
// `text_start` per start position), mirroring `searchImpl`. See `edfa.isMatch`.
test "regression: eager-DFA isMatch agrees with find for interior text_start + end anchor" {
    const gpa = testing.allocator;
    const cases = [_][]const u8{ "a*^$", "(?:a*)^$", "a*\\A$", "b*^\\z", "a*^\\z", "a*$", "^$", "a*^" };
    inline for (.{ pikevm, dfa, edfa, bytepike, backtrack, auto }) |B| {
        for (cases) |p| try expectIsMatchEqFind(B, gpa, p, "", true); // each matches the empty span at ""
    }
}

/// Assert `captures(...) != null` equals `find(...) != null` (and `isMatch`) on backend `B` — the
/// internal-consistency invariant across the three entry points. Skips a declining backend.
fn expectCapturesEqFind(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, want: bool) !void {
    var diag: regex.Diagnostic = .{};
    var re = regex.compileRuntimeWith(B, gpa, pattern, &diag, .{}) catch return;
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
    defer sc.deinit(gpa);
    const found = re.find(&sc, input) != null;
    const im = re.isMatch(&sc, input);
    const n = re.slotCount();
    var buf: [32]?usize = undefined;
    const cap = re.captures(&sc, buf[0..n], input) != null;
    if (found != cap or found != im or found != want) {
        std.debug.print("{s} /{s}/ over \"{s}\": find={} isMatch={} captures={} want={}\n", .{ @typeName(B), pattern, input, found, im, cap, want });
        return error.CaptureFindMismatch;
    }
}

// Fixed: `auto`'s line-anchored **capture** path (`lineAnchoredCaptures`, taken for a `(?m)^…`
// pattern with no eager-DFA span arm — e.g. one bearing `\b`) seeded `fillCapturesAnchored` with an
// UNCONFIRMED `{pos,pos}` candidate at each line start, and for a **group-less** pattern that helper
// trusts the seed as the match and never runs the engine — so a trailing assertion like `\b` that
// FAILS at the line start was never checked. `(?m)^\b` over "" then reported a `captures`/`find`
// match where `search`/`isMatch` (which DO confirm, via `lineAnchoredSpan`) correctly found none.
// Surfaced by the fuzz full-backend capture differential. **Fixed** by confirming the match at each
// line start with an anchored capturing run (`confirmCapturesAnchored`). See `auto.lineAnchoredCaptures`.
test "regression: auto line-anchored captures confirm the match (no false (?m)^\\b)" {
    const gpa = testing.allocator;
    // Group-less `(?m)^\b…` over input where every line start is a non-word boundary failure → NO match.
    const no_match = [_]struct { p: []const u8, i: []const u8 }{
        .{ .p = "(?m)^\\b", .i = "" }, // the minimized fuzz repro
        .{ .p = "(?m)^\\b", .i = "\n\n" }, // every line start (0,1,2) is empty → \b fails
        .{ .p = "(?m)^\\b\\B", .i = "" },
        .{ .p = "(?m)^\\b", .i = "\n \n" }, // line start at 2 is ' ' (non-word) → \b fails
    };
    inline for (.{ pikevm, backtrack, auto }) |B| {
        for (no_match) |c| {
            try expectIsMatchEqFind(B, gpa, c.p, c.i, false);
            try expectCapturesEqFind(B, gpa, c.p, c.i, false);
        }
    }
    // Controls — the SAME line-anchored-captures path must still find a real match where `\b` holds.
    const yes = [_]struct { p: []const u8, i: []const u8 }{
        .{ .p = "(?m)^\\bx", .i = "x\ny" }, // line start 0, \b holds (x is word), matches "x"
        .{ .p = "(?m)^\\b\\w", .i = "ab\ncd" }, // matches at offset 0 and (via findAll) line 2
    };
    inline for (.{ pikevm, backtrack, auto }) |B| {
        for (yes) |c| {
            try expectIsMatchEqFind(B, gpa, c.p, c.i, true);
            try expectCapturesEqFind(B, gpa, c.p, c.i, true);
        }
    }
}

// Fixed: `bytepike` (the byte Thompson NFA) executes the **same byte program** as the byte DFAs, so
// it shares their structural limit on a repetition over a **nullable alternation**
// (`hir.Analysis.nullable_alternation_in_repetition`): the split-based loop shapes in `byte.zig`
// cannot encode the leftmost-first **empty-width-loop** priority — when the preferred (earlier)
// branch matches empty the loop must terminate there, but the loop-back arm outranks the exit and a
// later *consuming* branch wins. `(?:z*b*$?|.{2})+` on `"baa"` is `"b"` (leftmost-first), but
// `bytepike` returned `"baa"`. `dfa`/`edfa` already decline this class in `supports`; `bytepike` was
// missing the decline. **Fixed** by declining it in `bytepike.buildAlloc`/`buildComptime`
// (`byteLoweringSupports`) — the code-point engines (`pikevm`/`backtrack`/`onepass`, via `nfa.zig`'s
// empty-loop `.jmp` guard) are correct and `auto` routes here. Surfaced by the fuzz span differential.
test "regression: bytepike declines nullable-alternation-in-repetition (leftmost-first empty loop)" {
    const gpa = testing.allocator;
    const cases = [_]struct { p: []const u8, i: []const u8 }{
        .{ .p = "(())(?:z{,}b*$?|.{2}(?:(?:)(?:)))+", .i = "baa" }, // minimized fuzz repro
        .{ .p = "(?:z*b*$?|.{2})+", .i = "baa" }, // the essence: nullable branch | 2-consume branch
        .{ .p = "(?:|.)+", .i = "c" }, // canonical empty-branch alternation under `+`
        .{ .p = "(a*|b)+", .i = "ab" }, // leftmost-first is "a", not "ab"
    };
    // bytepike must DECLINE every case (so a downstream user / the differential never runs it here).
    for (cases) |c| {
        var diag: regex.Diagnostic = .{};
        if (regex.compileRuntimeWith(bytepike, gpa, c.p, &diag, .{})) |re_| {
            var re2 = re_;
            re2.deinit();
            std.debug.print("bytepike should have declined /{s}/\n", .{c.p});
            return error.BytepikeShouldDecline;
        } else |_| {}
    }
    // The code-point engines and `auto` agree on the leftmost-first span sequence (the oracle).
    for (cases) |c| {
        var ref: [16][2]usize = undefined;
        const nref = try collectFindAll(pikevm, gpa, c.p, c.i, &ref);
        inline for (.{ backtrack, auto, onepass }) |B|
            try checkFindAllVsPike(B, gpa, c.p, c.i, ref[0..nref]);
    }
    // Control: a nullable *concat* body (`(?:a?b??)+`) is NOT this shape — bytepike still accepts it
    // (the do-while empty-width-loop guard is correct there) and agrees with the Pike VM.
    {
        var ref: [16][2]usize = undefined;
        const nref = try collectFindAll(pikevm, gpa, "(?:a?b??)+", "ab", &ref);
        try checkFindAllVsPike(bytepike, gpa, "(?:a?b??)+", "ab", ref[0..nref]);
    }
}

// Fixed: the EAGER DFA (`edfa`) lost leftmost-first priority when a `\b`/`\B` immediately follows a
// **repetition over** a length-varying, overlapping-first alternation (`(?:.|b\n)*\b`, `A{0}(?:\n{0}.|b\n)*\b`).
// The repetition lets the body end at several offsets and the trailing boundary holds at more than one;
// leftmost-first takes the earliest (branch-priority) end, the longest-match eager DFA the latest —
// `(?:.|b\n)*\b` over "b\na" is "b" (`{0,1}`) but `edfa` returned `{0,3}`. The same eager-DFA loss the
// `word_boundary_after_varying_alternation` gate already covers when the boundary follows the alternation
// DIRECTLY; the alternation under a `*`/`+` slipped past because `alternationThroughWrap` saw through a
// capture but not a repetition. **Fixed** by having it see through a repetition too, so the gate fires and
// `edfa.supports` declines — `auto` routes to the lazy `dfa`/Pike VM (both leftmost-first correct).
// Surfaced by the fuzz anchors differential (`auto` vs the Pike VM oracle).
test "regression: edfa declines a boundary after a repetition over a varying alternation" {
    const gpa = testing.allocator;
    // edfa must DECLINE (so the eager longest-match arm never serves these) …
    const decline = [_][]const u8{
        "(?:.|b\n)*\\b", // minimized fuzz repro
        "A{0}(?:\n{0}.|b\n)*\\b", // the raw minimized form (leading `A{0}`/inner `\n{0}` empties)
        "(?:b+|.+)*\\B", // the documented varying-alternation example, now under a `*`
    };
    for (decline) |p| {
        var diag: regex.Diagnostic = .{};
        if (regex.compileRuntimeWith(edfa, gpa, p, &diag, .{})) |re_| {
            var re2 = re_;
            re2.deinit();
            std.debug.print("edfa should have declined /{s}/\n", .{p});
            return error.EdfaShouldDecline;
        } else |_| {}
    }
    // … and every other backend agrees with the Pike-VM oracle on the leftmost-first spans.
    const i = "b\na";
    inline for (.{ "(?:.|b\n)*\\b", "A{0}(?:\n{0}.|b\n)*\\b" }) |p| {
        var ref: [16][2]usize = undefined;
        const nref = try collectFindAll(pikevm, gpa, p, i, &ref);
        try testing.expect(std.meta.eql(ref[0], [2]usize{ 0, 1 })); // leftmost-first is "b", not "b\na"
        inline for (.{ backtrack, auto, dfa, bytepike }) |B|
            try checkFindAllVsPike(B, gpa, p, i, ref[0..nref]);
    }
    // Control: a boundary after a DISJOINT-first alternation under a `*` is unambiguous — edfa keeps it.
    {
        var diag: regex.Diagnostic = .{};
        var re = try regex.compileRuntimeWith(edfa, gpa, "(?:a+|b+)*\\b", &diag, .{}); // a vs b: disjoint first
        re.deinit();
    }
}

// Fixed: `auto`'s lazy-DFA **rare interior-anchor** prefilter (`runByteDfa`, the `confirmReach` loop for a
// single-byte `inner_byte` whose `byteFreq` is rare) reverse-walked `cs` over `inner_lead` — a BYTE-level
// superset that is only EXACT on ASCII (bytes ≥ 0x80 are set conservatively) — then confirmed ANCHORED at
// that single `cs`. Over non-ASCII / invalid-UTF-8 input the walk over-reaches PAST the true start to a byte
// the leading class can't actually consume, the anchored confirm at `cs` fails, and the loop wrongly gave up:
// `[^]]+\}` over "\x80a}" is `{1,3}` and `\s*\|+` over "\x80|" is `{1,2}`, but `auto` returned NO match (the
// individual `dfa`/`edfa`/`bytepike` backends, run directly, were all correct — only `auto`'s pre-backend
// fast path missed). The sibling `bounded_confirm` arm is `input_ascii`-gated for the same reason; the
// rare-anchor arm wasn't. **Fixed** by adding the `input_ascii` gate — non-ASCII falls to one skip + an
// UNANCHORED native find (leftmost-correct regardless of over-reach). Surfaced by the fuzz iter/diff
// differentials over invalid UTF-8.
test "regression: auto rare interior-anchor prefilter is sound over non-ASCII input" {
    const gpa = testing.allocator;
    const cases = [_]struct { p: []const u8, i: []const u8, want: [2]usize }{
        .{ .p = "[^]]+\\}", .i = "\x80a}", .want = .{ 1, 3 } }, // finding C (minimized)
        .{ .p = "\\s*\\|+", .i = "\x80|", .want = .{ 1, 2 } }, // finding D (minimized)
        // a couple of variations around the over-reach boundary
        .{ .p = "[^]]+\\}", .i = "\xff\xfe-x}", .want = .{ 2, 5 } }, // two invalid bytes, then the run
        .{ .p = "\\s*\\|+", .i = "ab\xc3|", .want = .{ 3, 4 } }, // ASCII then a lone lead byte, then `|`
    };
    for (cases) |c| {
        var ref: [8][2]usize = undefined;
        const nref = try collectFindAll(pikevm, gpa, c.p, c.i, &ref);
        try testing.expect(nref >= 1 and std.meta.eql(ref[0], c.want));
        // Every backend (and crucially `auto`, where the bug lived) must agree with the Pike VM.
        inline for (.{ backtrack, auto, dfa, edfa, bytepike }) |B|
            try checkFindAllVsPike(B, gpa, c.p, c.i, ref[0..nref]);
    }
    // Control: the SAME shape over ALL-ASCII input keeps the fast anchored-confirm path and stays correct.
    {
        var ref: [8][2]usize = undefined;
        const nref = try collectFindAll(pikevm, gpa, "[^]]+\\}", "  -f}", &ref);
        inline for (.{ backtrack, auto, dfa, edfa, bytepike }) |B|
            try checkFindAllVsPike(B, gpa, "[^]]+\\}", "  -f}", ref[0..nref]);
    }
}

test {
    testing.refAllDecls(@This());
}
