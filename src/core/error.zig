//! Error catalogue and diagnostics for the regex scanner.
//!
//! The scanner reports a faulty pattern in two layers:
//!
//!   1. A Zig error (`SyntaxError.InvalidPattern`) that propagates failure.
//!   2. A `Diagnostic` value, written to a caller-supplied out-parameter, that
//!      pins down WHAT went wrong (`ErrorCode`) and WHERE (`Span`, a byte range
//!      into the original pattern).
//!
//! Printing is deliberately NOT done here beyond an optional default renderer.
//! The scanner never writes to a stream itself: the caller decides how to turn
//! a `Diagnostic` into a message. `Diagnostic.faultySlice(pattern)` hands back
//! the exact offending substring; `Diagnostic.message()` gives a short, stable
//! English description; `Diagnostic.render(...)` is a convenience that draws a
//! caret under the span for callers that just want something readable.
//!
//! Everything in this file is comptime-evaluable, so the same diagnostics work
//! whether the pattern is scanned at comptime or at runtime.

const std = @import("std");

/// The single Zig error the scanner raises for a malformed pattern. The precise
/// reason is carried out-of-band in the `Diagnostic`. (Runtime entry points add
/// `error.OutOfMemory` to this set; the comptime path returns the diagnostic in
/// a result union instead of erroring.)
///
/// @stable-since: v0.1.0
pub const SyntaxError = error{InvalidPattern};

// ── Span ────────────────────────────────────────────────────────────────────

/// A half-open byte range `[start, end)` into the pattern string. A zero-width
/// span (`start == end`) marks a single position — used for "expected X here"
/// style errors such as an unterminated group, where the fault is a missing
/// byte rather than a present one.
///
/// @stable-since: v0.1.0
pub const Span = struct {
    start: u32,
    end: u32,

    /// A zero-width span at byte `at`.
    ///
    /// @stable-since: v0.1.0
    pub fn point(at: u32) Span {
        return .{ .start = at, .end = at };
    }

    /// A span covering `[start, end)`.
    ///
    /// @stable-since: v0.1.0
    pub fn range(start: u32, end: u32) Span {
        return .{ .start = start, .end = end };
    }

    /// Number of bytes the span covers.
    ///
    /// @stable-since: v0.1.0
    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    /// The substring of `pattern` this span refers to. Bounds are clamped so a
    /// stale or out-of-range span can never cause an out-of-bounds slice.
    ///
    /// @stable-since: v0.1.0
    pub fn slice(self: Span, pattern: []const u8) []const u8 {
        const hi = @min(self.end, @as(u32, @intCast(pattern.len)));
        const lo = @min(self.start, hi);
        return pattern[lo..hi];
    }
};

// ── Error codes ───────────────────────────────────────────────────────────────

/// Every distinct way a pattern can be rejected. Grouped by the construct that
/// produced it. `none` is the sentinel for "no error" so a `Diagnostic` can be
/// default-initialised before scanning begins.
///
/// Several codes describe constructs that are *syntactically* valid in other
/// regex flavours but are unsupported here because a Thompson NFA cannot express
/// them (backreferences, lookaround, atomic groups, conditionals, recursion).
/// They are rejected with a precise code rather than mis-parsed.
///
/// @stable-since: v0.1.0
pub const ErrorCode = enum {
    /// No error. Sentinel value for an unused diagnostic.
    none,

    // ── Encoding ──────────────────────────────────────────────────────────────
    /// The pattern bytes are not valid UTF-8.
    invalid_utf8,
    /// The pattern ends with a lone `\` that escapes nothing.
    trailing_backslash,

    // ── Escapes ───────────────────────────────────────────────────────────────
    /// `\` followed by a letter with no defined meaning (e.g. `\q`).
    unsupported_escape,
    /// `\1`..`\9` or `\k<name>` — backreferences need backtracking.
    unsupported_backreference,
    /// `\Q...\E` literal quoting is not implemented.
    unsupported_quote,
    /// `\x` not followed by valid hexadecimal where it was required.
    invalid_hex_escape,
    /// `\x{}` with no digits between the braces.
    empty_hex_escape,
    /// `\x{` with no closing `}`.
    unclosed_hex_escape,
    /// `\u` not followed by the required 4 hex digits or a `{...}` group.
    invalid_unicode_escape,
    /// `\u{}` with no digits between the braces.
    empty_unicode_escape,
    /// `\u{` with no closing `}`.
    unclosed_unicode_escape,
    /// A `\x`/`\u` value exceeds U+10FFFF.
    code_point_out_of_range,
    /// A `\x`/`\u` value lands in the UTF-16 surrogate range U+D800..U+DFFF.
    surrogate_code_point,
    /// `\c` not followed by an ASCII letter.
    invalid_control_escape,
    /// `\c` at the very end of the pattern.
    truncated_control_escape,

    // ── Unicode properties ──────────────────────────────────────────────────
    /// `\p` or `\P` at the end of the pattern.
    truncated_property,
    /// `\p` not followed by `{name}` or a single-letter property.
    expected_property_name,
    /// `\p{` with no closing `}`.
    unclosed_property,
    /// `\p{}` with an empty name.
    empty_property_name,
    /// `\p{Name}` where Name resolves to no known property/category/script.
    unknown_property,

    // ── Groups ────────────────────────────────────────────────────────────────
    /// A `(` is never matched by a `)`.
    unclosed_group,
    /// A `)` appears with no open group.
    unmatched_close_paren,
    /// `(?` followed by something that is not a recognised group prefix.
    invalid_group_syntax,
    /// `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)` lookaround.
    unsupported_lookaround,
    /// `(?>...)` atomic group.
    unsupported_atomic_group,
    /// `(?(...)...)` conditional group.
    unsupported_conditional,
    /// `(?P=name)` / `\g<...>` / `(?R)` subroutine or recursion.
    unsupported_subroutine,
    /// `(*VERB)` backtracking-control verb.
    unsupported_inline_verb,
    /// `(?<>...)` with an empty name.
    empty_group_name,
    /// `(?<name...` with no closing `>`.
    unclosed_group_name,
    /// A capture name containing characters outside the identifier syntax.
    invalid_group_name,
    /// Two capture groups declared with the same name.
    duplicate_group_name,
    /// An inline flag letter that is not one of i, m, s.
    unknown_flag,
    /// `(?:)`-style group prefix that declares neither flags nor a body marker,
    /// e.g. a bare `(?)`.
    empty_flag_group,

    // ── Character classes ─────────────────────────────────────────────────────
    /// A `[` class is never closed by a `]`.
    unclosed_class,
    /// A class range `a-b` where `a` sorts after `b`.
    range_out_of_order,
    /// `[[:alpha:]]` POSIX classes are not implemented.
    unsupported_posix_class,

    // ── Quantifiers ─────────────────────────────────────────────────────────
    /// `*`, `+`, `?`, or `{m,n}` with no preceding atom.
    nothing_to_repeat,
    /// A quantifier immediately following another quantifier (e.g. `a**`),
    /// which also covers unsupported possessive quantifiers (`a*+`).
    multiple_quantifiers,
    /// A `{m,n}` bound that does not fit in the count type.
    quantifier_too_large,
    /// `{m,n}` with `m > n`.
    quantifier_out_of_order,

    // ── Limits ──────────────────────────────────────────────────────────────
    /// The pattern needed more nodes/members than the scanner's O(n) buffers
    /// hold. Practically unreachable for sane patterns; reported instead of
    /// overrunning a buffer.
    pattern_too_complex,
};

/// A short, stable, English description of `code`. Safe to embed in a message,
/// a log line, or a comptime `@compileError`. Does not include the location —
/// pair it with `Diagnostic.faultySlice` for that.
///
/// @stable-since: v0.1.0
pub fn messageFor(code: ErrorCode) []const u8 {
    return switch (code) {
        .none => "no error",

        .invalid_utf8 => "pattern is not valid UTF-8",
        .trailing_backslash => "pattern ends with a dangling '\\'",

        .unsupported_escape => "unknown or unsupported escape sequence",
        .unsupported_backreference => "backreferences are not supported (a Thompson NFA cannot backtrack)",
        .unsupported_quote => "'\\Q...\\E' literal quoting is not supported",
        .invalid_hex_escape => "malformed '\\x' hexadecimal escape",
        .empty_hex_escape => "'\\x{}' contains no hexadecimal digits",
        .unclosed_hex_escape => "'\\x{' is missing its closing '}'",
        .invalid_unicode_escape => "malformed '\\u' escape (expected 4 hex digits or '{...}')",
        .empty_unicode_escape => "'\\u{}' contains no hexadecimal digits",
        .unclosed_unicode_escape => "'\\u{' is missing its closing '}'",
        .code_point_out_of_range => "escaped code point is greater than U+10FFFF",
        .surrogate_code_point => "escaped code point is a UTF-16 surrogate (U+D800..U+DFFF)",
        .invalid_control_escape => "'\\c' must be followed by an ASCII letter",
        .truncated_control_escape => "'\\c' at end of pattern",

        .truncated_property => "'\\p' at end of pattern",
        .expected_property_name => "expected '{name}' or a single-letter property after '\\p'",
        .unclosed_property => "'\\p{' is missing its closing '}'",
        .empty_property_name => "empty Unicode property name",
        .unknown_property => "unknown Unicode property, category, or script name",

        .unclosed_group => "'(' is never closed by a matching ')'",
        .unmatched_close_paren => "')' has no matching '('",
        .invalid_group_syntax => "malformed '(?...)' group",
        .unsupported_lookaround => "lookaround assertions are not supported",
        .unsupported_atomic_group => "atomic groups '(?>...)' are not supported",
        .unsupported_conditional => "conditional groups '(?(...)...)' are not supported",
        .unsupported_subroutine => "subroutine calls / recursion are not supported",
        .unsupported_inline_verb => "backtracking-control verbs '(*...)' are not supported",
        .empty_group_name => "empty capture group name",
        .unclosed_group_name => "capture group name is missing its closing '>'",
        .invalid_group_name => "invalid character in capture group name",
        .duplicate_group_name => "duplicate capture group name",
        .unknown_flag => "unknown inline flag (only i, m, s are supported)",
        .empty_flag_group => "'(?...)' group declares neither flags nor a body",

        .unclosed_class => "'[' character class is never closed by a ']'",
        .range_out_of_order => "character class range is out of order (low > high)",
        .unsupported_posix_class => "POSIX character classes '[:name:]' are not supported",

        .nothing_to_repeat => "quantifier has nothing to repeat",
        .multiple_quantifiers => "a quantifier cannot directly follow another quantifier",
        .quantifier_too_large => "quantifier count is too large",
        .quantifier_out_of_order => "quantifier range is out of order (min greater than max)",

        .pattern_too_complex => "pattern exceeds the scanner's complexity limits",
    };
}

// ── Diagnostic ──────────────────────────────────────────────────────────────

/// What went wrong and where. The scanner writes one of these to the caller's
/// out-parameter on failure; it is left at `.none` on success. Carrying the
/// reason out-of-band (rather than as a Zig error per code) keeps the error set
/// tiny while still pinning the exact fault and location.
///
/// @stable-since: v0.1.0
pub const Diagnostic = struct {
    /// Why the pattern was rejected. `.none` means "no error recorded".
    code: ErrorCode = .none,
    /// Where in the pattern the fault is, as a byte range.
    span: Span = .{ .start = 0, .end = 0 },

    /// True when no error has been recorded.
    ///
    /// @stable-since: v0.1.0
    pub fn isOk(self: Diagnostic) bool {
        return self.code == .none;
    }

    /// The exact offending substring of `pattern`. Empty for zero-width spans
    /// (a missing-byte fault, e.g. an unterminated group).
    ///
    /// @stable-since: v0.1.0
    pub fn faultySlice(self: Diagnostic, pattern: []const u8) []const u8 {
        return self.span.slice(pattern);
    }

    /// Short English description of the error code (no location).
    ///
    /// @stable-since: v0.1.0
    pub fn message(self: Diagnostic) []const u8 {
        return messageFor(self.code);
    }

    /// Default renderer: a one-line message plus the pattern with a caret run
    /// under the offending span. Callers wanting different formatting should
    /// read `code`/`span`/`faultySlice` directly instead.
    ///
    /// Example output:
    ///   regex: unknown or unsupported escape sequence
    ///       a\qb
    ///        ^^
    ///
    /// @stable-since: v0.1.0
    pub fn render(self: Diagnostic, pattern: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("regex: {s}\n    ", .{self.message()});
        try w.writeAll(pattern);
        try w.writeAll("\n    ");
        const lo = @min(self.span.start, @as(u32, @intCast(pattern.len)));
        var i: u32 = 0;
        while (i < lo) : (i += 1) {
            // Mirror tabs so the caret stays aligned in tab-indented patterns.
            try w.writeAll(if (pattern[i] == '\t') "\t" else " ");
        }
        const carets = @max(self.span.len(), 1);
        var c: u32 = 0;
        while (c < carets) : (c += 1) try w.writeAll("^");
        try w.writeAll("\n");
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Span.slice returns the covered substring" {
    const pat = "abc\\qdef";
    const s = Span.range(3, 5); // "\\q"
    try testing.expectEqualStrings("\\q", s.slice(pat));
    try testing.expectEqual(@as(u32, 2), s.len());
}

test "Span.point is zero-width and yields an empty slice" {
    const pat = "abc";
    const s = Span.point(3);
    try testing.expectEqual(@as(u32, 0), s.len());
    try testing.expectEqualStrings("", s.slice(pat));
}

test "Span.slice clamps an out-of-range span instead of trapping" {
    const pat = "ab";
    const s = Span.range(1, 99);
    try testing.expectEqualStrings("b", s.slice(pat));

    const s2 = Span.range(50, 99);
    try testing.expectEqualStrings("", s2.slice(pat));
}

test "messageFor is total over every ErrorCode" {
    // Every variant must map to a non-empty message, and only `none` may say
    // "no error". This locks the catalogue and its messages together.
    inline for (std.meta.tags(ErrorCode)) |code| {
        const msg = messageFor(code);
        try testing.expect(msg.len > 0);
        if (code != .none) {
            try testing.expect(!std.mem.eql(u8, msg, "no error"));
        }
    }
}

test "Diagnostic defaults to ok" {
    const d: Diagnostic = .{};
    try testing.expect(d.isOk());
    try testing.expectEqual(ErrorCode.none, d.code);
}

test "Diagnostic surfaces code, message, and faulty slice" {
    const pat = "a\\qb";
    const d: Diagnostic = .{ .code = .unsupported_escape, .span = Span.range(1, 3) };
    try testing.expect(!d.isOk());
    try testing.expectEqualStrings("\\q", d.faultySlice(pat));
    try testing.expectEqualStrings("unknown or unsupported escape sequence", d.message());
}

test "Diagnostic.render draws a caret under the span" {
    const pat = "a\\qb";
    const d: Diagnostic = .{ .code = .unsupported_escape, .span = Span.range(1, 3) };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try d.render(pat, &w);
    const out = w.buffered();
    // Message line, the pattern, then a caret line with two carets after one space.
    try testing.expect(std.mem.indexOf(u8, out, "unknown or unsupported escape sequence") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a\\qb") != null);
    try testing.expect(std.mem.indexOf(u8, out, " ^^") != null);
}

test "Diagnostic.render uses a single caret for a zero-width span" {
    const pat = "(abc";
    const d: Diagnostic = .{ .code = .unclosed_group, .span = Span.point(0) };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try d.render(pat, &w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "^") != null);
}

test "diagnostics work at comptime" {
    const d: Diagnostic = comptime .{ .code = .nothing_to_repeat, .span = Span.range(0, 1) };
    try testing.expectEqualStrings("quantifier has nothing to repeat", comptime d.message());
    try comptime testing.expectEqualStrings("*", d.faultySlice("*abc"));
}

test {
    testing.refAllDecls(@This());
}
