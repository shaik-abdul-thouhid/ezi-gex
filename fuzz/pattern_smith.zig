//! A `Smith`-driven generator of regex *patterns* for structure-aware fuzzing.
//!
//! Feeding the scanner uniformly-random bytes mostly exercises the "reject as
//! garbage" path: real coverage lives behind balanced groups, well-formed
//! classes, and quantifiers that actually attach to an atom. `PatternSmith`
//! consumes a `*std.testing.Smith` and emits a *syntactically plausible* pattern
//! over a deliberately tiny alphabet, so the fuzzer spends its budget on the
//! parser/HIR/backends rather than on lexer error recovery. The output is not
//! guaranteed valid (that is itself worth fuzzing — the scanner must reject the
//! occasional malformed shape cleanly), but it is valid *far* more often than
//! random bytes.
//!
//! Two knobs keep generated patterns cheap to run so the fuzzer iterates fast:
//!   * a small repetition ceiling (`max_rep_bound`) — backends expand `{m,n}`
//!     into program states, so an unbounded count would dominate wall-clock;
//!   * a bounded recursion `depth` and a fixed output buffer.
//!
//! The alphabet (`a b c` + a digit + a space + newline) is shared with the input
//! generator in `root.zig`, so generated patterns and haystacks overlap and
//! matches actually happen.

const std = @import("std");
const Smith = std.testing.Smith;

/// Upper bound on a generated pattern's byte length. Fits comfortably in the
/// scanner's O(n) buffers and keeps compiled programs small.
pub const max_pattern_len = 96;

/// Largest bound a generated `{m,n}` quantifier uses. Kept tiny because each
/// backend expands counted repetition into states; large counts would make the
/// fuzzer crawl without finding new behaviour.
pub const max_rep_bound = 6;

/// Deepest group nesting the generator will produce.
const max_depth = 4;

/// The shared literal alphabet. Patterns and haystacks both draw from it.
pub const alphabet = "abc1 \n";

/// A bounded pattern builder. Build with `gen`, then use `slice()`.
pub const PatternSmith = struct {
    buf: [max_pattern_len]u8 = undefined,
    len: usize = 0,

    /// The generated pattern bytes.
    pub fn slice(self: *const PatternSmith) []const u8 {
        return self.buf[0..self.len];
    }

    fn put(self: *PatternSmith, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    fn puts(self: *PatternSmith, s: []const u8) void {
        for (s) |c| self.put(c);
    }

    /// True when the buffer is nearly full; callers stop emitting to leave room
    /// for closing brackets/parens so the result stays balanced.
    fn nearlyFull(self: *const PatternSmith) bool {
        return self.len + 8 >= self.buf.len;
    }
};

/// Generate one pattern from `smith`. Always terminates: every loop is bounded by
/// `eosWeightedSimple` (guaranteed to eventually stop), by buffer capacity, and
/// by `max_depth`.
pub fn gen(smith: *Smith) PatternSmith {
    @disableInstrumentation();
    var p: PatternSmith = .{};
    genAlternation(&p, smith, 0);
    return p;
}

/// `branch ('|' branch)*`
fn genAlternation(p: *PatternSmith, smith: *Smith, depth: u8) void {
    genConcat(p, smith, depth);
    // Lean against extra branches (7:1) so most patterns are a single concat.
    while (!p.nearlyFull() and !smith.eosWeightedSimple(7, 1)) {
        p.put('|');
        genConcat(p, smith, depth);
    }
}

/// `quantified*`
fn genConcat(p: *PatternSmith, smith: *Smith, depth: u8) void {
    // Allow an empty branch (valid: `a|` ), but usually emit at least one atom.
    while (!p.nearlyFull() and !smith.eosWeightedSimple(4, 1)) {
        genQuantified(p, smith, depth);
    }
}

/// `atom quantifier?`
fn genQuantified(p: *PatternSmith, smith: *Smith, depth: u8) void {
    genAtom(p, smith, depth);
    if (smith.boolWeighted(2, 1)) return; // ~1/3 of atoms are quantified
    switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => p.put('*'),
        1 => p.put('+'),
        2 => p.put('?'),
        else => genBraceQuant(p, smith),
    }
    // Occasionally make it lazy.
    if (smith.boolWeighted(3, 1)) p.put('?');
}

/// `{m} | {m,} | {m,n}` with small bounds.
fn genBraceQuant(p: *PatternSmith, smith: *Smith) void {
    const lo = smith.valueRangeAtMost(u8, 0, max_rep_bound);
    p.put('{');
    putUint(p, lo);
    switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => {}, // {m}
        1 => p.put(','), // {m,}
        else => { // {m,n} with n >= m
            p.put(',');
            const hi = smith.valueRangeAtMost(u8, lo, max_rep_bound);
            putUint(p, hi);
        },
    }
    p.put('}');
}

/// One repeatable atom.
fn genAtom(p: *PatternSmith, smith: *Smith, depth: u8) void {
    // At max depth, never open a group — only leaf atoms — so recursion ends.
    const kind_max: u8 = if (depth >= max_depth or p.nearlyFull()) 4 else 6;
    switch (smith.valueRangeAtMost(u8, 0, kind_max)) {
        0, 1 => p.put(litByte(smith)), // weight literals heaviest
        2 => p.put('.'),
        3 => genShorthand(p, smith),
        4 => genClass(p, smith),
        5 => { // capturing group
            p.put('(');
            genAlternation(p, smith, depth + 1);
            p.put(')');
        },
        else => { // non-capturing or flagged group
            if (smith.boolWeighted(1, 1)) {
                p.puts("(?:");
            } else {
                p.puts("(?i:");
            }
            genAlternation(p, smith, depth + 1);
            p.put(')');
        },
    }
}

/// `\d \w \s \D \W \S` or an anchor `^ $ \b \B`.
fn genShorthand(p: *PatternSmith, smith: *Smith) void {
    switch (smith.valueRangeAtMost(u8, 0, 9)) {
        0 => p.puts("\\d"),
        1 => p.puts("\\w"),
        2 => p.puts("\\s"),
        3 => p.puts("\\D"),
        4 => p.puts("\\W"),
        5 => p.puts("\\S"),
        6 => p.put('^'),
        7 => p.put('$'),
        8 => p.puts("\\b"),
        else => p.puts("\\B"),
    }
}

/// `[...]` / `[^...]` over the alphabet, with the odd range.
fn genClass(p: *PatternSmith, smith: *Smith) void {
    p.put('[');
    if (smith.boolWeighted(3, 1)) p.put('^');
    var n: u8 = 0;
    while (n < 4 and !smith.eosWeightedSimple(2, 1)) : (n += 1) {
        if (smith.boolWeighted(3, 1)) {
            // a-c style range from the letter sub-alphabet
            p.put('a');
            p.put('-');
            p.put('c');
        } else {
            p.put(litByte(smith));
        }
    }
    p.put(']');
}

/// A single alphabet byte, escaped where it would otherwise be metacharacter-ish.
fn litByte(smith: *Smith) u8 {
    const i = smith.index(alphabet.len);
    return alphabet[i];
}

/// Append `v` in decimal (v <= 255, so at most 3 digits).
fn putUint(p: *PatternSmith, v: u8) void {
    var buf: [3]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    p.puts(s);
}

// ══════════════════════════════════════════════════════════════════════════════
// Anchor / zero-width focused generator
// ══════════════════════════════════════════════════════════════════════════════
//
// A second generator biased hard toward what stresses the byte-DFA `supports`
// gate: anchors (`^ $ \A \z \b \B`, `(?m:…)`), empty alternation branches, empty
// groups, and nullable quantifiers (`* ? {0} {0,2}`). The general `gen` above only
// occasionally produces these in interesting combinations; `genAnchors` produces
// little else. It always emits balanced groups (it recurses for `(` / `(?:` /
// `(?m:`), so it stays parseable far more often than random bytes. This is the
// generator behind the focused supports-gate fuzz target in `root.zig`.

const max_anchor_depth = 3;

/// Generate an anchor/zero-width-heavy pattern from `smith`.
pub fn genAnchors(smith: *Smith) PatternSmith {
    @disableInstrumentation();
    var p: PatternSmith = .{};
    anchorSeq(&p, smith, max_anchor_depth);
    return p;
}

/// `concat ('|' concat)*` — 1..3 branches; an empty concat is a (valid) empty branch.
fn anchorSeq(p: *PatternSmith, smith: *Smith, depth: u8) void {
    const branches = smith.valueRangeAtMost(u8, 1, 3);
    var b: u8 = 0;
    while (b < branches) : (b += 1) {
        if (b > 0) p.put('|');
        anchorConcat(p, smith, depth);
    }
}

/// 0..3 quantified units (0 → an empty branch, deliberately).
fn anchorConcat(p: *PatternSmith, smith: *Smith, depth: u8) void {
    const n = smith.valueRangeAtMost(u8, 0, 3);
    var i: u8 = 0;
    while (i < n and !p.nearlyFull()) : (i += 1) anchorUnitQuant(p, smith, depth);
}

fn anchorUnitQuant(p: *PatternSmith, smith: *Smith, depth: u8) void {
    anchorUnit(p, smith, depth);
    switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0 => p.put('*'),
        1 => p.put('?'),
        2 => p.put('+'),
        3 => p.puts("{0}"),
        4 => p.puts("{0,2}"),
        else => {}, // unquantified
    }
}

fn anchorUnit(p: *PatternSmith, smith: *Smith, depth: u8) void {
    // Leaf-only at max depth / near capacity, so recursion always terminates.
    const max: u8 = if (depth == 0 or p.nearlyFull()) 9 else 12;
    switch (smith.valueRangeAtMost(u8, 0, max)) {
        0 => p.put('a'),
        1 => p.put('b'),
        2 => p.put('.'),
        3 => p.put('^'),
        4 => p.put('$'),
        5 => p.puts("\\b"),
        6 => p.puts("\\B"),
        7 => p.puts("\\A"),
        8 => p.puts("\\z"),
        9 => p.put('\n'),
        10 => {
            p.puts("(?:");
            anchorSeq(p, smith, depth - 1);
            p.put(')');
        },
        11 => {
            p.put('(');
            anchorSeq(p, smith, depth - 1);
            p.put(')');
        },
        else => {
            p.puts("(?m:");
            anchorSeq(p, smith, depth - 1);
            p.put(')');
        },
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Unicode-focused generator
// ══════════════════════════════════════════════════════════════════════════════
//
// A third generator that leans into ezi_gex's reason to exist: Unicode. It emits
// `\p{…}` properties + scripts, the Unicode shorthand classes, literal multi-byte
// code points (é α 日 😀, written as raw UTF-8), case-insensitive groups, and
// classes with non-ASCII ranges — none of which the ASCII-only `gen`/`genAnchors`
// produce. The matching target feeds it both valid multi-byte UTF-8 and raw
// (possibly invalid) bytes, so the engines' Unicode decode + dead-on-invalid
// handling is differenced too. `\X` (grapheme) is deliberately excluded — it is
// backtrack-only, so it has no differential partner (it is fuzzed for no-crash
// separately).

const max_uni_depth = 3;

/// A few literal multi-byte code points, as raw UTF-8 byte strings.
const uni_literals = [_][]const u8{
    "\xC3\xA9", // é  U+00E9 (2-byte)
    "\xCE\xB1", // α  U+03B1 (2-byte)
    "\xE6\x97\xA5", // 日 U+65E5 (3-byte)
    "\xF0\x9F\x98\x80", // 😀 U+1F600 (4-byte)
};

/// Generate a Unicode-heavy pattern from `smith`.
pub fn genUnicode(smith: *Smith) PatternSmith {
    @disableInstrumentation();
    var p: PatternSmith = .{};
    uniSeq(&p, smith, max_uni_depth);
    return p;
}

fn uniSeq(p: *PatternSmith, smith: *Smith, depth: u8) void {
    const branches = smith.valueRangeAtMost(u8, 1, 3);
    var b: u8 = 0;
    while (b < branches) : (b += 1) {
        if (b > 0) p.put('|');
        uniConcat(p, smith, depth);
    }
}

fn uniConcat(p: *PatternSmith, smith: *Smith, depth: u8) void {
    const n = smith.valueRangeAtMost(u8, 0, 3);
    var i: u8 = 0;
    while (i < n and !p.nearlyFull()) : (i += 1) uniUnitQuant(p, smith, depth);
}

fn uniUnitQuant(p: *PatternSmith, smith: *Smith, depth: u8) void {
    uniUnit(p, smith, depth);
    switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0 => p.put('*'),
        1 => p.put('+'),
        2 => p.put('?'),
        3 => p.puts("*?"),
        4 => p.puts("{1,2}"),
        else => {},
    }
}

fn uniUnit(p: *PatternSmith, smith: *Smith, depth: u8) void {
    const max: u8 = if (depth == 0 or p.nearlyFull()) 11 else 13;
    switch (smith.valueRangeAtMost(u8, 0, max)) {
        0 => p.put('a'),
        1 => p.put('.'),
        2 => p.puts(uni_literals[smith.index(uni_literals.len)]),
        3 => p.puts("\\d"),
        4 => p.puts("\\w"),
        5 => p.puts("\\s"),
        6 => p.puts("\\p{L}"),
        7 => p.puts("\\p{Nd}"),
        8 => p.puts("\\p{Lu}"),
        9 => p.puts("\\p{Greek}"),
        10 => p.puts("[a-z\\p{L}]"),
        11 => p.puts("[\xCE\xB1-\xCF\x89]"), // [α-ω]
        12 => {
            p.puts("(?i:");
            uniSeq(p, smith, depth - 1);
            p.put(')');
        },
        else => {
            p.put('(');
            uniSeq(p, smith, depth - 1);
            p.put(')');
        },
    }
}

/// Append a valid-UTF-8 haystack of up to `budget` bytes, assembled from whole
/// code points (so the bytes are never split mid-sequence). Returns the length.
pub fn unicodeInput(smith: *Smith, out: []u8) usize {
    @disableInstrumentation();
    const cps = [_][]const u8{ "a", "b", "1", " ", "\n", "\xC3\xA9", "\xCE\xB1", "\xE6\x97\xA5", "\xF0\x9F\x98\x80" };
    var len: usize = 0;
    var guard: u8 = 0;
    while (guard < 24 and !smith.eosWeightedSimple(3, 1)) : (guard += 1) {
        const s = cps[smith.index(cps.len)];
        if (len + s.len > out.len) break;
        @memcpy(out[len .. len + s.len], s);
        len += s.len;
    }
    return len;
}
