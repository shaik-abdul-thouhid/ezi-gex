//! Regex scanner: a UTF-8 tokenizing lexer plus a single-pass parser that
//! builds the flat AST (see ast.zig). It is the front end of an engine that
//! compiles to a Thompson NFA, so it rejects constructs an NFA cannot express
//! (backreferences, lookaround, atomic/conditional groups) with precise errors
//! rather than silently mis-parsing them.
//!
//! Design
//! ------
//! * One pass, O(n). The driver `Scanner.run` pulls tokens from `Scanner.next`
//!   (the iterator) and folds each into the AST as it arrives. There is no
//!   recursion: nesting is tracked with an explicit stack of `Frame`s, which is
//!   easier to reason about and immune to deep-pattern stack overflow.
//! * Mark and rewind. `next` is a pure function of `(pos, mode)`, so the rare
//!   places that need lookahead — a `{` that may or may not be a quantifier, a
//!   `-` that may or may not be a class range — just save `pos`, peek, and
//!   restore. No token buffer, no backtracking beyond a couple of bytes.
//! * Context via mode. `next` lexes differently inside `[...]` and inside a
//!   `{m,n}` count than at top level; the driver sets `Scanner.mode` around
//!   those regions. `]`, `}`, `,`, `-` are ordinary literals at top level and
//!   only become structural tokens in their own context.
//!
//! Comptime and runtime
//! --------------------
//! The same parsing core runs both ways; only storage differs.
//!   * `parse`        — runtime: heap-allocates exactly-sized AST arrays.
//!   * `parseComptime`/`compile` — comptime: writes into fixed comptime arrays
//!     sized to an O(n) upper bound, then returns slices of comptime const data.
//!
//! Errors
//! ------
//! Failure is reported two ways at once (see error.zig): the Zig error
//! `error.InvalidPattern` propagates, and a `Diagnostic` (code + byte span) is
//! written to the caller's out-parameter. Printing is the caller's job —
//! `Diagnostic.faultySlice(pattern)` and `Diagnostic.message()` give the pieces,
//! `parseReporting` hands them to a caller-supplied context, and `compile`
//! turns them into a `@compileError`.

const std = @import("std");

const ast = @import("ast.zig");
const token = @import("token.zig");
const errors = @import("error.zig");

const ezi_code = @import("ezi_code");
const utf8 = ezi_code.utf8;
const u_props = ezi_code.unicode.properties;
const CodePoint = ezi_code.encoding.CodePoint;

// ── Public re-exports ─────────────────────────────────────────────────────────

pub const Ast = ast.Ast;
pub const Diagnostic = errors.Diagnostic;
pub const ErrorCode = errors.ErrorCode;
pub const Span = errors.Span;

/// Error returned by the runtime entry points. `InvalidPattern` carries its
/// detail in the `Diagnostic`; `OutOfMemory` comes from the allocator.
pub const Error = errors.SyntaxError || std.mem.Allocator.Error;

/// Result of the comptime entry point. Comptime code cannot thread an
/// out-parameter the way runtime code does, so the diagnostic rides along here.
pub const Outcome = union(enum) {
    ok: Ast,
    fail: Diagnostic,
};

/// The internal failure type: a malformed pattern, with detail in the
/// Diagnostic. Allocation never happens inside the parsing core, so this is the
/// only error the core can raise.
const Fail = errors.SyntaxError; // error{InvalidPattern}

// ── Lexer support types ───────────────────────────────────────────────────────

/// Lexing context. `next` consults `Scanner.mode` to decide how bytes map to
/// tokens; the driver flips it around `[...]` and `{...}` regions.
const Mode = enum { normal, class, brace };

/// A token together with the byte range it occupies in the pattern.
const Lexeme = struct {
    tok: token.Token,
    span: Span,
};

inline fn mk(tok: token.Token, span: Span) Lexeme {
    return .{ .tok = tok, .span = span };
}

/// A parsed `{m,n}` count. `max == null` means unbounded (`{m,}`).
const BraceQuant = struct {
    min: u32,
    max: ?u32,
};

/// One level of group nesting on the explicit parse stack. A frame owns a slice
/// of the `seq` stack (the atoms of the concatenation currently being built)
/// and a slice of the `alt` stack (the `|`-separated branches gathered so far).
/// Public only because it is the element type of the caller-provided scratch in
/// `Buffers`; callers never construct one.
pub const Frame = struct {
    const Kind = enum { root, capture, non_capture };

    kind: Kind,
    /// `seq` index where this frame's current concatenation begins.
    seq_base: u32,
    /// `alt` index where this frame's alternation branches begin.
    alt_base: u32,
    /// 1-based capture number (only meaningful when kind == .capture).
    group_index: u32 = 0,
    /// Index into `names` for a named capture, else null.
    name: ?u32 = null,
    /// Scoped-flag delta for a `(?flags:...)` group; empty otherwise.
    flags_add: token.Flags = .{},
    flags_remove: token.Flags = .{},
    /// Byte offset of the opening `(` — used to point at an unclosed group.
    open_pos: u32 = 0,
};

/// What the previous token contributed, for quantifier legality.
///   start      — beginning of a branch / right after `(` or `|`: nothing to
///                repeat.
///   atom       — a repeatable atom is on top of `seq`.
///   quantifier — a quantifier was just applied; a following `?` means "lazy".
///   lazy       — a lazy marker was just applied; nothing more may stack on it.
const Prev = enum { start, atom, quantifier, lazy };

// ── Scanner ───────────────────────────────────────────────────────────────────

/// The lexer + parser state. Storage (the `nodes`/`children`/`items`/`names`
/// AST arrays and the `seq`/`alt`/`frames` scratch stacks) is supplied by the
/// caller as pre-sized slices, so the same struct drives both the comptime and
/// runtime paths; only the backing memory differs.
pub const Scanner = struct {
    // input
    pattern: []const u8,
    len: u32,
    pos: u32 = 0,
    mode: Mode = .normal,
    diag: *Diagnostic,

    // AST output (pre-sized; lengths track usage)
    nodes: []ast.Node,
    node_len: u32 = 0,
    children: []u32,
    child_len: u32 = 0,
    items: []ast.ClassItem,
    item_len: u32 = 0,
    names: [][]const u8,
    name_len: u32 = 0,

    // scratch stacks (freed after parsing)
    seq: []u32,
    seq_len: u32 = 0,
    alt: []u32,
    alt_len: u32 = 0,
    frames: []Frame,
    frame_len: u32 = 0,

    // running state
    capture_count: u32 = 0,
    flags: token.Flags = .{},
    prev: Prev = .start,
    count_overflow: bool = false,

    inline fn atEnd(self: *const Scanner) bool {
        return self.pos >= self.len;
    }

    fn fail(self: *Scanner, code: ErrorCode, span: Span) Fail {
        self.diag.* = .{ .code = code, .span = span };
        return error.InvalidPattern;
    }

    // ── Byte / code_point helpers ───────────────────────────────────────────

    /// Decode the code_point at `pos`, advance past it, and return it. Fails on
    /// invalid UTF-8 in the pattern itself.
    fn bumpCp(self: *Scanner) Fail!CodePoint {
        const d = utf8.validateAndDecodeCodePointBytes(self.pattern, self.pos) catch {
            return self.fail(.invalid_utf8, Span.range(self.pos, @min(self.len, self.pos + 1)));
        };
        self.pos += d.len;
        return d.code_point;
    }

    // ── Emit / push helpers (with capacity guards) ─────────────────────────

    fn emitNode(self: *Scanner, node: ast.Node) Fail!u32 {
        if (self.node_len >= self.nodes.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        const idx = self.node_len;
        self.nodes[idx] = node;
        self.node_len += 1;
        return idx;
    }

    fn pushChild(self: *Scanner, idx: u32) Fail!void {
        if (self.child_len >= self.children.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        self.children[self.child_len] = idx;
        self.child_len += 1;
    }

    fn pushItem(self: *Scanner, item: ast.ClassItem) Fail!void {
        if (self.item_len >= self.items.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        self.items[self.item_len] = item;
        self.item_len += 1;
    }

    fn pushName(self: *Scanner, name: []const u8) Fail!void {
        if (self.name_len >= self.names.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        self.names[self.name_len] = name;
        self.name_len += 1;
    }

    fn pushSeq(self: *Scanner, idx: u32) Fail!void {
        if (self.seq_len >= self.seq.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        self.seq[self.seq_len] = idx;
        self.seq_len += 1;
    }

    fn pushAlt(self: *Scanner, idx: u32) Fail!void {
        if (self.alt_len >= self.alt.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        self.alt[self.alt_len] = idx;
        self.alt_len += 1;
    }

    fn pushFrame(self: *Scanner, fr: Frame) Fail!void {
        if (self.frame_len >= self.frames.len) return self.fail(.pattern_too_complex, Span.point(self.pos));
        self.frames[self.frame_len] = fr;
        self.frame_len += 1;
    }

    inline fn topFrame(self: *Scanner) *Frame {
        return &self.frames[self.frame_len - 1];
    }

    // ════════════════════════════════════════════════════════════════════════
    // Lexer — the token iterator
    // ════════════════════════════════════════════════════════════════════════

    /// Yield the next token under the current `mode`. This is the iterator the
    /// parser drives; everything else is bookkeeping around it.
    fn next(self: *Scanner) Fail!Lexeme {
        return switch (self.mode) {
            .normal => self.nextNormal(),
            .class => self.nextClass(),
            .brace => self.nextBrace(),
        };
    }

    fn commentAhead(self: *const Scanner) bool {
        return self.pos + 2 < self.len and
            self.pattern[self.pos] == '(' and
            self.pattern[self.pos + 1] == '?' and
            self.pattern[self.pos + 2] == '#';
    }

    fn skipComment(self: *Scanner) Fail!void {
        const start = self.pos;
        self.pos += 3; // "(?#"
        while (!self.atEnd() and self.pattern[self.pos] != ')') self.pos += 1;
        if (self.atEnd()) return self.fail(.unclosed_group, Span.range(start, start + 1));
        self.pos += 1; // ")"
    }

    fn nextNormal(self: *Scanner) Fail!Lexeme {
        while (true) {
            if (self.atEnd()) return mk(.eof, Span.point(self.pos));
            // `(?#...)` comments are whitespace to the parser: skip and re-lex.
            if (self.commentAhead()) {
                try self.skipComment();
                continue;
            }
            const start = self.pos;
            const b = self.pattern[self.pos];
            switch (b) {
                '\\' => return self.lexEscape(start, false),
                '.' => {
                    self.pos += 1;
                    return mk(.dot, Span.range(start, self.pos));
                },
                '|' => {
                    self.pos += 1;
                    return mk(.pipe, Span.range(start, self.pos));
                },
                '*' => {
                    self.pos += 1;
                    return mk(.star, Span.range(start, self.pos));
                },
                '+' => {
                    self.pos += 1;
                    return mk(.plus, Span.range(start, self.pos));
                },
                '?' => {
                    self.pos += 1;
                    return mk(.question, Span.range(start, self.pos));
                },
                '(' => return self.lexOpenParen(start),
                ')' => {
                    self.pos += 1;
                    return mk(.r_paren, Span.range(start, self.pos));
                },
                '[' => {
                    self.pos += 1;
                    return mk(.l_bracket, Span.range(start, self.pos));
                },
                '{' => {
                    self.pos += 1;
                    return mk(.l_brace, Span.range(start, self.pos));
                },
                '^' => {
                    self.pos += 1;
                    return mk(.caret, Span.range(start, self.pos));
                },
                '$' => {
                    self.pos += 1;
                    return mk(.dollar, Span.range(start, self.pos));
                },
                // ']' '}' ',' '-' and any non-meta byte are ordinary literals.
                else => {
                    const cp = try self.bumpCp();
                    return mk(.{ .literal = cp }, Span.range(start, self.pos));
                },
            }
        }
    }

    fn nextClass(self: *Scanner) Fail!Lexeme {
        if (self.atEnd()) return mk(.eof, Span.point(self.pos));
        const start = self.pos;
        const b = self.pattern[self.pos];
        switch (b) {
            '\\' => return self.lexEscape(start, true),
            ']' => {
                self.pos += 1;
                return mk(.r_bracket, Span.range(start, self.pos));
            },
            '-' => {
                self.pos += 1;
                return mk(.dash, Span.range(start, self.pos));
            },
            '[' => {
                // POSIX classes "[:name:]" are intentionally unsupported; a bare
                // "[" is otherwise just a literal inside a class.
                if (self.pos + 1 < self.len and self.pattern[self.pos + 1] == ':') {
                    return self.fail(.unsupported_posix_class, Span.range(self.pos, self.pos + 2));
                }
                self.pos += 1;
                return mk(.{ .literal = '[' }, Span.range(start, self.pos));
            },
            else => {
                const cp = try self.bumpCp();
                return mk(.{ .literal = cp }, Span.range(start, self.pos));
            },
        }
    }

    fn nextBrace(self: *Scanner) Fail!Lexeme {
        if (self.atEnd()) return mk(.eof, Span.point(self.pos));
        const start = self.pos;
        const b = self.pattern[self.pos];
        switch (b) {
            '0'...'9' => {
                var val: u64 = 0;
                while (!self.atEnd() and isDigit(self.pattern[self.pos])) {
                    val = val * 10 + (self.pattern[self.pos] - '0');
                    if (val > std.math.maxInt(u32)) {
                        self.count_overflow = true;
                        val = std.math.maxInt(u32);
                    }
                    self.pos += 1;
                }
                return mk(.{ .number = @intCast(val) }, Span.range(start, self.pos));
            },
            ',' => {
                self.pos += 1;
                return mk(.comma, Span.range(start, self.pos));
            },
            '}' => {
                self.pos += 1;
                return mk(.r_brace, Span.range(start, self.pos));
            },
            // Anything else means "this isn't a quantifier"; hand back a literal
            // so the caller bails out and rewinds.
            else => {
                const cp = try self.bumpCp();
                return mk(.{ .literal = cp }, Span.range(start, self.pos));
            },
        }
    }

    // ── Escapes ────────────────────────────────────────────────────────────

    fn lexEscape(self: *Scanner, start: u32, in_class: bool) Fail!Lexeme {
        self.pos += 1; // consume '\'
        if (self.atEnd()) return self.fail(.trailing_backslash, Span.range(start, self.pos));
        const eb = self.pattern[self.pos];
        switch (eb) {
            'n' => return self.escLiteral(start, 0x0A),
            'r' => return self.escLiteral(start, 0x0D),
            't' => return self.escLiteral(start, 0x09),
            'f' => return self.escLiteral(start, 0x0C),
            'v' => return self.escLiteral(start, 0x0B),
            'a' => return self.escLiteral(start, 0x07),
            'e' => return self.escLiteral(start, 0x1B),
            '0' => return self.escLiteral(start, 0x00),

            'd' => return self.escTok(start, .class_digit),
            'D' => return self.escTok(start, .class_non_digit),
            'w' => return self.escTok(start, .class_word),
            'W' => return self.escTok(start, .class_non_word),
            's' => return self.escTok(start, .class_space),
            'S' => return self.escTok(start, .class_non_space),

            // Inside a class, \b is backspace; outside, it is a word boundary.
            'b' => {
                self.pos += 1;
                if (in_class) return mk(.{ .literal = 0x08 }, Span.range(start, self.pos));
                return mk(.word_boundary, Span.range(start, self.pos));
            },
            'B' => {
                self.pos += 1;
                if (in_class) return mk(.{ .literal = 'B' }, Span.range(start, self.pos));
                return mk(.non_word_boundary, Span.range(start, self.pos));
            },
            'A' => {
                self.pos += 1;
                if (in_class) return mk(.{ .literal = 'A' }, Span.range(start, self.pos));
                return mk(.anchor_start, Span.range(start, self.pos));
            },
            'z' => {
                self.pos += 1;
                if (in_class) return mk(.{ .literal = 'z' }, Span.range(start, self.pos));
                return mk(.anchor_end, Span.range(start, self.pos));
            },
            // \Z (end, or before a trailing newline) is simplified to \z here.
            'Z' => {
                self.pos += 1;
                if (in_class) return mk(.{ .literal = 'Z' }, Span.range(start, self.pos));
                return mk(.anchor_end, Span.range(start, self.pos));
            },
            'X' => {
                self.pos += 1;
                if (in_class) return mk(.{ .literal = 'X' }, Span.range(start, self.pos));
                return mk(.grapheme, Span.range(start, self.pos));
            },

            'p' => return self.lexProperty(start, false),
            'P' => return self.lexProperty(start, true),
            'x' => return self.lexHex(start),
            'u' => return self.lexUnicode(start),
            'c' => return self.lexControl(start),

            'k' => return self.fail(.unsupported_backreference, Span.range(start, self.pos + 1)),
            'Q', 'E' => return self.fail(.unsupported_quote, Span.range(start, self.pos + 1)),
            '1'...'9' => return self.fail(.unsupported_backreference, Span.range(start, self.pos + 1)),

            else => {
                // Escaping a punctuation/symbol/non-ASCII code_point yields it
                // literally; an unknown *letter* escape is an error.
                const cp = try self.bumpCp();
                if (isAsciiAlpha(cp)) return self.fail(.unsupported_escape, Span.range(start, self.pos));
                return mk(.{ .literal = cp }, Span.range(start, self.pos));
            },
        }
    }

    inline fn escLiteral(self: *Scanner, start: u32, cp: CodePoint) Lexeme {
        self.pos += 1; // consume the single escape letter
        return mk(.{ .literal = cp }, Span.range(start, self.pos));
    }

    inline fn escTok(self: *Scanner, start: u32, tok: token.Token) Lexeme {
        self.pos += 1;
        return mk(tok, Span.range(start, self.pos));
    }

    fn lexProperty(self: *Scanner, start: u32, negated: bool) Fail!Lexeme {
        self.pos += 1; // consume 'p'/'P'
        if (self.atEnd()) return self.fail(.truncated_property, Span.range(start, self.pos));
        const c = self.pattern[self.pos];
        if (c == '{') {
            self.pos += 1; // '{'
            const name_start = self.pos;
            while (!self.atEnd() and self.pattern[self.pos] != '}') self.pos += 1;
            if (self.atEnd()) return self.fail(.unclosed_property, Span.range(start, self.pos));
            const name = self.pattern[name_start..self.pos];
            self.pos += 1; // '}'
            if (name.len == 0) return self.fail(.empty_property_name, Span.range(start, self.pos));
            const pid = token.resolveProperty(name) orelse
                return self.fail(.unknown_property, Span.range(name_start, self.pos - 1));
            return mk(if (negated) .{ .unicode_non_prop = pid } else .{ .unicode_prop = pid }, Span.range(start, self.pos));
        } else if (isAsciiAlpha(c)) {
            // Single-letter form: \pL == \p{L}.
            const name = self.pattern[self.pos .. self.pos + 1];
            self.pos += 1;
            const pid = token.resolveProperty(name) orelse
                return self.fail(.unknown_property, Span.range(self.pos - 1, self.pos));
            return mk(if (negated) .{ .unicode_non_prop = pid } else .{ .unicode_prop = pid }, Span.range(start, self.pos));
        }
        return self.fail(.expected_property_name, Span.range(start, self.pos));
    }

    fn lexHex(self: *Scanner, start: u32) Fail!Lexeme {
        self.pos += 1; // consume 'x'
        if (!self.atEnd() and self.pattern[self.pos] == '{') {
            self.pos += 1;
            const ds = self.pos;
            while (!self.atEnd() and self.pattern[self.pos] != '}') self.pos += 1;
            if (self.atEnd()) return self.fail(.unclosed_hex_escape, Span.range(start, self.pos));
            const digits = self.pattern[ds..self.pos];
            self.pos += 1; // '}'
            if (digits.len == 0) return self.fail(.empty_hex_escape, Span.range(start, self.pos));
            const cp = try self.parseHexDigits(digits, start, .invalid_hex_escape);
            return mk(.{ .literal = cp }, Span.range(start, self.pos));
        }
        // Bare \xHH: 0..2 hex digits (PCRE treats \x with no digits as NUL).
        var val: u32 = 0;
        var count: u8 = 0;
        while (count < 2 and !self.atEnd() and isHexDigit(self.pattern[self.pos])) : (count += 1) {
            val = val * 16 + hexValue(self.pattern[self.pos]);
            self.pos += 1;
        }
        return mk(.{ .literal = @intCast(val) }, Span.range(start, self.pos));
    }

    fn lexUnicode(self: *Scanner, start: u32) Fail!Lexeme {
        self.pos += 1; // consume 'u'
        if (!self.atEnd() and self.pattern[self.pos] == '{') {
            self.pos += 1;
            const ds = self.pos;
            while (!self.atEnd() and self.pattern[self.pos] != '}') self.pos += 1;
            if (self.atEnd()) return self.fail(.unclosed_unicode_escape, Span.range(start, self.pos));
            const digits = self.pattern[ds..self.pos];
            self.pos += 1; // '}'
            if (digits.len == 0) return self.fail(.empty_unicode_escape, Span.range(start, self.pos));
            const cp = try self.parseHexDigits(digits, start, .invalid_unicode_escape);
            return mk(.{ .literal = cp }, Span.range(start, self.pos));
        }
        // Bare \uHHHH: exactly 4 hex digits.
        var val: u32 = 0;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            if (self.atEnd() or !isHexDigit(self.pattern[self.pos]))
                return self.fail(.invalid_unicode_escape, Span.range(start, self.pos));
            val = val * 16 + hexValue(self.pattern[self.pos]);
            self.pos += 1;
        }
        if (val >= 0xD800 and val <= 0xDFFF) return self.fail(.surrogate_code_point, Span.range(start, self.pos));
        return mk(.{ .literal = @intCast(val) }, Span.range(start, self.pos));
    }

    fn parseHexDigits(self: *Scanner, digits: []const u8, start: u32, bad: ErrorCode) Fail!CodePoint {
        var val: u32 = 0;
        for (digits) |c| {
            if (!isHexDigit(c)) return self.fail(bad, Span.range(start, self.pos));
            val = val * 16 + hexValue(c);
            if (val > 0x10FFFF) return self.fail(.code_point_out_of_range, Span.range(start, self.pos));
        }
        if (val >= 0xD800 and val <= 0xDFFF) return self.fail(.surrogate_code_point, Span.range(start, self.pos));
        return @intCast(val);
    }

    fn lexControl(self: *Scanner, start: u32) Fail!Lexeme {
        self.pos += 1; // consume 'c'
        if (self.atEnd()) return self.fail(.truncated_control_escape, Span.range(start, self.pos));
        const c = self.pattern[self.pos];
        if (!isAsciiAlpha(c)) return self.fail(.invalid_control_escape, Span.range(start, self.pos + 1));
        self.pos += 1;
        const upper = c & 0xDF; // fold to uppercase
        return mk(.{ .literal = upper ^ 0x40 }, Span.range(start, self.pos));
    }

    // ── Group openers: '(' and the '(?...' family ──────────────────────────

    fn lexOpenParen(self: *Scanner, start: u32) Fail!Lexeme {
        self.pos += 1; // consume '('
        if (self.atEnd() or self.pattern[self.pos] != '?') {
            return mk(.l_paren, Span.range(start, self.pos));
        }
        self.pos += 1; // consume '?'
        if (self.atEnd()) return self.fail(.invalid_group_syntax, Span.range(start, self.pos));
        const c = self.pattern[self.pos];
        switch (c) {
            ':' => {
                self.pos += 1;
                return mk(.group_non_capture, Span.range(start, self.pos));
            },
            '<' => {
                // (?<= and (?<! are lookbehind; (?<name> is a named capture.
                if (self.pos + 1 < self.len and (self.pattern[self.pos + 1] == '=' or self.pattern[self.pos + 1] == '!')) {
                    return self.fail(.unsupported_lookaround, Span.range(start, self.pos + 2));
                }
                return self.lexNamedGroup(start, '>');
            },
            '\'' => return self.lexNamedGroup(start, '\''),
            'P' => {
                if (self.pos + 1 < self.len and self.pattern[self.pos + 1] == '<') {
                    self.pos += 1; // consume 'P'; lexNamedGroup eats '<'
                    return self.lexNamedGroup(start, '>');
                }
                // (?P=name) is a backreference.
                return self.fail(.unsupported_subroutine, Span.range(start, self.pos + 1));
            },
            '=', '!' => return self.fail(.unsupported_lookaround, Span.range(start, self.pos + 1)),
            '>' => return self.fail(.unsupported_atomic_group, Span.range(start, self.pos + 1)),
            '(' => return self.fail(.unsupported_conditional, Span.range(start, self.pos + 1)),
            'R', '&', '+' => return self.fail(.unsupported_subroutine, Span.range(start, self.pos + 1)),
            else => return self.lexFlags(start),
        }
    }

    fn lexNamedGroup(self: *Scanner, start: u32, close: u8) Fail!Lexeme {
        self.pos += 1; // consume '<' or '\''
        const name_start = self.pos;
        while (!self.atEnd() and self.pattern[self.pos] != close) self.pos += 1;
        if (self.atEnd()) return self.fail(.unclosed_group_name, Span.range(start, self.pos));
        const name = self.pattern[name_start..self.pos];
        self.pos += 1; // consume close
        if (name.len == 0) return self.fail(.empty_group_name, Span.range(start, self.pos));
        try self.validateName(name, name_start);
        return mk(.{ .group_named = name }, Span.range(start, self.pos));
    }

    fn validateName(self: *Scanner, name: []const u8, name_start: u32) Fail!void {
        var i: usize = 0;
        var first = true;
        while (i < name.len) {
            const d = utf8.validateAndDecodeCodePointBytes(name, i) catch
                return self.fail(.invalid_group_name, Span.range(name_start, name_start + @as(u32, @intCast(name.len))));
            const ok = if (first) u_props.isIdentifierStart(d.code_point) else u_props.isIdentifierContinue(d.code_point);
            if (!ok) return self.fail(.invalid_group_name, Span.range(name_start + @as(u32, @intCast(i)), name_start + @as(u32, @intCast(i)) + d.len));
            i += d.len;
            first = false;
        }
    }

    fn lexFlags(self: *Scanner, start: u32) Fail!Lexeme {
        var add: token.Flags = .{};
        var remove: token.Flags = .{};
        var neg = false;
        var any = false;
        while (true) {
            if (self.atEnd()) return self.fail(.invalid_group_syntax, Span.range(start, self.pos));
            const c = self.pattern[self.pos];
            switch (c) {
                'i', 'm', 's' => {
                    const bit = flagBit(c);
                    if (neg) remove = remove.merge(bit) else add = add.merge(bit);
                    self.pos += 1;
                    any = true;
                },
                '-' => {
                    if (neg) return self.fail(.invalid_group_syntax, Span.range(start, self.pos + 1));
                    neg = true;
                    self.pos += 1;
                    any = true;
                },
                ':' => {
                    self.pos += 1;
                    return mk(.{ .group_flag = .{ .add = add, .remove = remove, .scoped = true } }, Span.range(start, self.pos));
                },
                ')' => {
                    self.pos += 1;
                    if (!any) return self.fail(.empty_flag_group, Span.range(start, self.pos));
                    return mk(.{ .group_flag = .{ .add = add, .remove = remove, .scoped = false } }, Span.range(start, self.pos));
                },
                else => {
                    if (isAsciiAlpha(c)) return self.fail(.unknown_flag, Span.range(self.pos, self.pos + 1));
                    return self.fail(.invalid_group_syntax, Span.range(start, self.pos + 1));
                },
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // Parser — the single pass
    // ════════════════════════════════════════════════════════════════════════

    /// Drive the lexer to completion, folding tokens into the AST, and return
    /// the root node index. The root frame is pushed here.
    fn run(self: *Scanner) Fail!u32 {
        try self.pushFrame(.{ .kind = .root, .seq_base = 0, .alt_base = 0 });
        self.prev = .start;

        while (true) {
            const lx = try self.next();
            switch (lx.tok) {
                .eof => break,

                .pipe => try self.onPipe(),

                .l_paren => try self.openGroup(.capture, null, .{}, .{}, lx.span.start),
                .group_non_capture => try self.openGroup(.non_capture, null, .{}, .{}, lx.span.start),
                .group_named => |name| try self.onOpenNamed(name, lx.span),
                .group_flag => |gf| try self.onGroupFlag(gf, lx.span),
                .r_paren => try self.onCloseGroup(lx.span),

                .star => try self.onRepeat(0, null, lx.span),
                .plus => try self.onRepeat(1, null, lx.span),
                .question => try self.onQuestion(lx.span),
                .l_brace => try self.onBrace(lx.span),

                .l_bracket => try self.onClass(lx.span),

                .dot => try self.pushAtom(ast.makeDot()),
                .caret => try self.pushAtom(ast.makeAnchor(.line_begin)),
                .dollar => try self.pushAtom(ast.makeAnchor(.line_end)),
                .literal => |cp| try self.pushAtom(ast.makeLiteral(cp)),

                .class_digit => try self.pushPerl(.digit, false),
                .class_non_digit => try self.pushPerl(.digit, true),
                .class_word => try self.pushPerl(.word, false),
                .class_non_word => try self.pushPerl(.word, true),
                .class_space => try self.pushPerl(.space, false),
                .class_non_space => try self.pushPerl(.space, true),

                .unicode_prop => |pid| try self.pushAtom(ast.makeUnicodeProp(pid, false)),
                .unicode_non_prop => |pid| try self.pushAtom(ast.makeUnicodeProp(pid, true)),
                .grapheme => try self.pushAtom(ast.makeGraphemeCluster()),

                .word_boundary => try self.pushAtom(ast.makeAnchor(.word)),
                .non_word_boundary => try self.pushAtom(ast.makeAnchor(.non_word)),
                .anchor_start => try self.pushAtom(ast.makeAnchor(.input_begin)),
                .anchor_end => try self.pushAtom(ast.makeAnchor(.input_end)),

                // These only ever come back from class/brace mode, never here.
                .number, .comma, .dash, .r_bracket, .r_brace, .question_lazy => unreachable,
            }
        }

        return self.finishRoot();
    }

    fn pushAtom(self: *Scanner, node: ast.Node) Fail!void {
        const idx = try self.emitNode(node);
        try self.pushSeq(idx);
        self.prev = .atom;
    }

    fn pushPerl(self: *Scanner, kind: token.PerlClassKind, negated: bool) Fail!void {
        const start = self.item_len;
        try self.pushItem(.{ .perl = .{ .kind = kind, .negated = negated } });
        try self.pushAtom(ast.makeCharClass(start, 1, false));
    }

    fn onPipe(self: *Scanner) Fail!void {
        try self.finalizeConcat();
        self.prev = .start;
    }

    /// Collapse the current concatenation (the `seq` atoms above the active
    /// frame's base) into a single node and push it as a branch onto `alt`.
    fn finalizeConcat(self: *Scanner) Fail!void {
        const base = self.topFrame().seq_base;
        const n = self.seq_len - base;
        var branch: u32 = undefined;
        if (n == 0) {
            branch = try self.emitNode(ast.makeConcat(self.child_len, 0));
        } else if (n == 1) {
            branch = self.seq[base];
        } else {
            const cstart = self.child_len;
            var i = base;
            while (i < self.seq_len) : (i += 1) try self.pushChild(self.seq[i]);
            branch = try self.emitNode(ast.makeConcat(cstart, n));
        }
        self.seq_len = base;
        try self.pushAlt(branch);
    }

    /// Collapse the alternation branches above `alt_base` into one node.
    fn buildAlternation(self: *Scanner, alt_base: u32) Fail!u32 {
        const n = self.alt_len - alt_base;
        var result: u32 = undefined;
        if (n == 1) {
            result = self.alt[alt_base];
        } else {
            const cstart = self.child_len;
            var i = alt_base;
            while (i < self.alt_len) : (i += 1) try self.pushChild(self.alt[i]);
            result = try self.emitNode(ast.makeAlternation(cstart, n));
        }
        self.alt_len = alt_base;
        return result;
    }

    fn openGroup(self: *Scanner, kind: Frame.Kind, name: ?u32, add: token.Flags, remove: token.Flags, open_pos: u32) Fail!void {
        var fr = Frame{
            .kind = kind,
            .seq_base = self.seq_len,
            .alt_base = self.alt_len,
            .name = name,
            .flags_add = add,
            .flags_remove = remove,
            .open_pos = open_pos,
        };
        if (kind == .capture) {
            self.capture_count += 1;
            fr.group_index = self.capture_count;
        }
        try self.pushFrame(fr);
        self.prev = .start;
    }

    fn onOpenNamed(self: *Scanner, name: []const u8, span: Span) Fail!void {
        var i: u32 = 0;
        while (i < self.name_len) : (i += 1) {
            if (std.mem.eql(u8, self.names[i], name)) return self.fail(.duplicate_group_name, span);
        }
        const idx = self.name_len;
        try self.pushName(name);
        try self.openGroup(.capture, idx, .{}, .{}, span.start);
    }

    fn onGroupFlag(self: *Scanner, gf: anytype, span: Span) Fail!void {
        if (gf.scoped) {
            try self.openGroup(.non_capture, null, gf.add, gf.remove, span.start);
        } else {
            // Bare (?flags): a whole-pattern flag change (a deliberate
            // simplification of per-group scoping the flat AST cannot store).
            self.flags = applyDelta(self.flags, gf.add, gf.remove);
            self.prev = .start;
        }
    }

    fn onCloseGroup(self: *Scanner, span: Span) Fail!void {
        if (self.topFrame().kind == .root) return self.fail(.unmatched_close_paren, span);
        try self.finalizeConcat();
        const fr = self.topFrame().*;
        const body = try self.buildAlternation(fr.alt_base);
        self.frame_len -= 1;

        const group_node = switch (fr.kind) {
            .capture => try self.emitNode(ast.makeCapture(body, fr.group_index, fr.name)),
            .non_capture => if (fr.flags_add.isEmpty() and fr.flags_remove.isEmpty())
                try self.emitNode(ast.makeNonCapture(body))
            else
                try self.emitNode(ast.makeNonCaptureScoped(body, fr.flags_add, fr.flags_remove)),
            .root => unreachable,
        };
        try self.pushSeq(group_node);
        self.prev = .atom; // a group is itself a repeatable atom
    }

    fn finishRoot(self: *Scanner) Fail!u32 {
        if (self.frame_len > 1) {
            const fr = self.topFrame().*;
            return self.fail(.unclosed_group, Span.range(fr.open_pos, fr.open_pos + 1));
        }
        try self.finalizeConcat();
        const fr = self.topFrame().*;
        const root = try self.buildAlternation(fr.alt_base);
        self.frame_len -= 1;
        return root;
    }

    // ── Quantifiers ────────────────────────────────────────────────────────

    fn onRepeat(self: *Scanner, min: u32, max: ?u32, span: Span) Fail!void {
        switch (self.prev) {
            .start => return self.fail(.nothing_to_repeat, span),
            .quantifier, .lazy => return self.fail(.multiple_quantifiers, span),
            .atom => {},
        }
        const child = self.seq[self.seq_len - 1];
        const node = try self.emitNode(ast.makeRange(child, min, max, true));
        self.seq[self.seq_len - 1] = node;
        self.prev = .quantifier;
    }

    fn onQuestion(self: *Scanner, span: Span) Fail!void {
        switch (self.prev) {
            .start => return self.fail(.nothing_to_repeat, span),
            .quantifier => {
                // The `?` after a quantifier makes it lazy, e.g. a*? a+? a{2}?
                const top = self.seq[self.seq_len - 1];
                self.nodes[top].data.range.quantifier.greedy = false;
                self.prev = .lazy;
            },
            .lazy => return self.fail(.multiple_quantifiers, span),
            .atom => {
                const child = self.seq[self.seq_len - 1];
                const node = try self.emitNode(ast.makeRange(child, 0, 1, true));
                self.seq[self.seq_len - 1] = node;
                self.prev = .quantifier;
            },
        }
    }

    fn onBrace(self: *Scanner, span: Span) Fail!void {
        // Only treat `{` as a quantifier when it directly follows a repeatable
        // atom; otherwise (and on malformed counts) it is a literal '{'.
        if (self.prev == .atom) {
            const after = self.pos;
            if (try self.tryParseBrace()) |bq| {
                if (self.count_overflow) return self.fail(.quantifier_too_large, Span.range(span.start, self.pos));
                if (bq.max) |mx| {
                    if (bq.min > mx) return self.fail(.quantifier_out_of_order, Span.range(span.start, self.pos));
                }
                const child = self.seq[self.seq_len - 1];
                const node = try self.emitNode(ast.makeRange(child, bq.min, bq.max, true));
                self.seq[self.seq_len - 1] = node;
                self.prev = .quantifier;
                return;
            }
            self.pos = after; // rewind: not a quantifier after all
        }
        try self.pushAtom(ast.makeLiteral('{'));
    }

    /// Attempt to read a `{m}` / `{m,}` / `{m,n}` / `{,n}` count starting just
    /// after the `{`. Returns null (without committing the read) when the text
    /// is not a well-formed count, so the caller can fall back to a literal.
    fn tryParseBrace(self: *Scanner) Fail!?BraceQuant {
        self.mode = .brace;
        self.count_overflow = false;
        defer self.mode = .normal;

        var min: u32 = 0;
        var have_min = false;

        var lx = try self.next();
        switch (lx.tok) {
            .number => |num| {
                min = num;
                have_min = true;
                lx = try self.next();
            },
            else => {},
        }

        switch (lx.tok) {
            .r_brace => {
                if (!have_min) return null; // "{}" is not a quantifier
                return BraceQuant{ .min = min, .max = min };
            },
            .comma => {
                var max: ?u32 = null;
                var lx2 = try self.next();
                switch (lx2.tok) {
                    .number => |num| {
                        max = num;
                        lx2 = try self.next();
                    },
                    else => {},
                }
                if (lx2.tok != .r_brace) return null;
                return BraceQuant{ .min = if (have_min) min else 0, .max = max };
            },
            else => return null,
        }
    }

    // ── Character classes ──────────────────────────────────────────────────

    fn onClass(self: *Scanner, open: Span) Fail!void {
        const items_start = self.item_len;
        var negated = false;
        if (!self.atEnd() and self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }
        self.mode = .class;
        errdefer self.mode = .normal;

        var first = true;
        while (true) {
            const cx = try self.next();
            switch (cx.tok) {
                .eof => return self.fail(.unclosed_class, Span.range(open.start, open.start + 1)),
                .r_bracket => {
                    if (first) {
                        // A ']' as the first member is a literal ']'.
                        try self.pushItem(.{ .range = .{ .lo = ']', .hi = ']' } });
                        first = false;
                    } else break;
                },
                .literal => |cp| {
                    try self.classLiteralOrRange(cp, cx.span.start);
                    first = false;
                },
                .dash => {
                    try self.pushItem(.{ .range = .{ .lo = '-', .hi = '-' } });
                    first = false;
                },
                .class_digit => {
                    try self.pushItem(.{ .perl = .{ .kind = .digit, .negated = false } });
                    first = false;
                },
                .class_non_digit => {
                    try self.pushItem(.{ .perl = .{ .kind = .digit, .negated = true } });
                    first = false;
                },
                .class_word => {
                    try self.pushItem(.{ .perl = .{ .kind = .word, .negated = false } });
                    first = false;
                },
                .class_non_word => {
                    try self.pushItem(.{ .perl = .{ .kind = .word, .negated = true } });
                    first = false;
                },
                .class_space => {
                    try self.pushItem(.{ .perl = .{ .kind = .space, .negated = false } });
                    first = false;
                },
                .class_non_space => {
                    try self.pushItem(.{ .perl = .{ .kind = .space, .negated = true } });
                    first = false;
                },
                .unicode_prop => |pid| {
                    try self.pushItem(.{ .property = .{ .property = pid, .negated = false } });
                    first = false;
                },
                .unicode_non_prop => |pid| {
                    try self.pushItem(.{ .property = .{ .property = pid, .negated = true } });
                    first = false;
                },
                else => unreachable, // class mode yields nothing else
            }
        }

        self.mode = .normal;
        const len = self.item_len - items_start;
        const node = try self.emitNode(ast.makeCharClass(items_start, len, negated));
        try self.pushSeq(node);
        self.prev = .atom;
    }

    fn classLiteralOrRange(self: *Scanner, lo: CodePoint, lo_start: u32) Fail!void {
        const save = self.pos; // before a possible '-'
        const nx = try self.next();
        if (nx.tok != .dash) {
            self.pos = save; // rewind; just a single member
            try self.pushItem(.{ .range = .{ .lo = lo, .hi = lo } });
            return;
        }
        // We have "lo -"; decide whether a valid upper bound follows.
        const hx = try self.next();
        switch (hx.tok) {
            .literal => |hi| {
                if (lo > hi) return self.fail(.range_out_of_order, Span.range(lo_start, self.pos));
                try self.pushItem(.{ .range = .{ .lo = lo, .hi = hi } });
            },
            else => {
                // '-' before ']' or a shorthand/property is a literal dash;
                // rewind so it is re-lexed as such on the next turn.
                self.pos = save;
                try self.pushItem(.{ .range = .{ .lo = lo, .hi = lo } });
            },
        }
    }
};

// ── small byte helpers ────────────────────────────────────────────────────────

inline fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

inline fn isHexDigit(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
}

inline fn hexValue(b: u8) u32 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => 0,
    };
}

inline fn isAsciiAlpha(cp: CodePoint) bool {
    return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
}

fn flagBit(c: u8) token.Flags {
    return switch (c) {
        'i' => .{ .case_insensitive = true },
        'm' => .{ .multiline = true },
        's' => .{ .dot_all = true },
        else => .{},
    };
}

fn applyDelta(base: token.Flags, add: token.Flags, remove: token.Flags) token.Flags {
    return .{
        .case_insensitive = (base.case_insensitive or add.case_insensitive) and !remove.case_insensitive,
        .multiline = (base.multiline or add.multiline) and !remove.multiline,
        .dot_all = (base.dot_all or add.dot_all) and !remove.dot_all,
    };
}

// ── Buffer sizing ─────────────────────────────────────────────────────────────
//
// Every node, child slot, class member, and scratch entry is produced by
// consuming pattern bytes, so all counts are O(pattern.len). `requiredSizes`
// returns generous upper bounds. The scanner additionally guards every write
// and raises `pattern_too_complex` rather than overrun, so a loose bound can
// never become memory-unsafety.

/// Minimum length of each buffer for a pattern of `pattern_len` bytes.
pub const Sizes = struct {
    nodes: usize,
    children: usize,
    class_items: usize,
    names: usize,
    seq: usize,
    alt: usize,
    frames: usize,
};

pub fn requiredSizes(pattern_len: usize) Sizes {
    const n = pattern_len;
    return .{
        .nodes = 4 * n + 16,
        .children = 4 * n + 16,
        .class_items = 2 * n + 16,
        .names = n + 1,
        .seq = 4 * n + 16,
        .alt = 4 * n + 16,
        .frames = n + 2,
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Entry points
// ════════════════════════════════════════════════════════════════════════════

/// All backing storage the scanner needs, supplied by the caller. The first
/// four slices hold the AST and are what the returned `Ast` points into; the
/// last three are transient scratch the scanner uses and then abandons. Every
/// slice must be at least the length given by `requiredSizes(pattern.len)`.
///
/// The scanner never allocates or frees and contains no comptime/runtime mode
/// switch: it does not care whether these slices live in `ro_data` (comptime
/// arrays) or on the heap. That is entirely the caller's decision — `parse`
/// makes the heap choice, `parseComptime`/`compile` make the comptime choice,
/// and a caller with special needs (arena, stack buffer, …) calls `scan`.
pub const Buffers = struct {
    nodes: []ast.Node,
    children: []u32,
    class_items: []ast.ClassItem,
    names: [][]const u8,
    seq: []u32,
    alt: []u32,
    frames: []Frame,
};

/// The storage-agnostic scanning core. Fills `buffers` and returns an `Ast`
/// whose arrays are sub-slices of the AST buffers (`buffers.nodes[0..used]`,
/// etc.). The caller owns `buffers` and decides their lifetime and location;
/// nothing here is heap-bound, and the same code runs at comptime and runtime.
/// On a malformed pattern, returns `error.InvalidPattern` and writes the detail
/// into `diag`.
pub fn scan(pattern: []const u8, diag: *Diagnostic, buffers: Buffers) Fail!Ast {
    diag.* = .{};
    var sc = Scanner{
        .pattern = pattern,
        .len = @intCast(pattern.len),
        .diag = diag,
        .nodes = buffers.nodes,
        .children = buffers.children,
        .items = buffers.class_items,
        .names = buffers.names,
        .seq = buffers.seq,
        .alt = buffers.alt,
        .frames = buffers.frames,
    };
    const root = try sc.run();
    return Ast{
        .nodes = sc.nodes[0..sc.node_len],
        .children = sc.children[0..sc.child_len],
        .class_items = sc.items[0..sc.item_len],
        .names = sc.names[0..sc.name_len],
        .root = root,
        .capture_count = sc.capture_count,
        .flags = sc.flags,
    };
}

/// Parse `pattern` at runtime into a heap-allocated AST. A storage wrapper over
/// `scan`: it provisions oversized scratch + AST buffers from `allocator`, runs
/// the agnostic core, then copies the used portions into exactly-sized owned
/// arrays and releases the scratch. On success the returned AST owns its arrays;
/// free them with `Ast.deinit(allocator)`. On a malformed pattern,
/// `error.InvalidPattern` is returned and `diag` carries the precise code and
/// byte span (see error.zig).
pub fn parse(allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic) Error!Ast {
    const sizes = requiredSizes(pattern.len);

    // Oversized backing storage. Released unconditionally on the way out; the
    // exact-size AST arrays are duplicated from it on success.
    const nodes = try allocator.alloc(ast.Node, sizes.nodes);
    defer allocator.free(nodes);
    const children = try allocator.alloc(u32, sizes.children);
    defer allocator.free(children);
    const items = try allocator.alloc(ast.ClassItem, sizes.class_items);
    defer allocator.free(items);
    const names = try allocator.alloc([]const u8, sizes.names);
    defer allocator.free(names);
    const seq = try allocator.alloc(u32, sizes.seq);
    defer allocator.free(seq);
    const alt = try allocator.alloc(u32, sizes.alt);
    defer allocator.free(alt);
    const frames = try allocator.alloc(Frame, sizes.frames);
    defer allocator.free(frames);

    const raw = try scan(pattern, diag, .{
        .nodes = nodes,
        .children = children,
        .class_items = items,
        .names = names,
        .seq = seq,
        .alt = alt,
        .frames = frames,
    });

    const final_nodes = try allocator.dupe(ast.Node, raw.nodes);
    errdefer allocator.free(final_nodes);
    const final_children = if (raw.children.len == 0) &[_]u32{} else try allocator.dupe(u32, raw.children);
    errdefer if (final_children.len != 0) allocator.free(final_children);
    const final_items = if (raw.class_items.len == 0) &[_]ast.ClassItem{} else try allocator.dupe(ast.ClassItem, raw.class_items);
    errdefer if (final_items.len != 0) allocator.free(final_items);
    const final_names = if (raw.names.len == 0) &[_][]const u8{} else try allocator.dupe([]const u8, raw.names);

    return Ast{
        .nodes = final_nodes,
        .children = final_children,
        .class_items = final_items,
        .names = final_names,
        .root = raw.root,
        .capture_count = raw.capture_count,
        .flags = raw.flags,
    };
}

/// Parse `pattern` at runtime, and on failure hand the diagnostic to a
/// caller-supplied context before returning the error. `ctx` is anything with a
///   `pub fn report(self, Diagnostic, pattern: []const u8) void`
/// method — that is where the caller does its own formatting/printing. The
/// allocation error path does not call `report` (there is no diagnostic for it).
pub fn parseReporting(allocator: std.mem.Allocator, pattern: []const u8, ctx: anytype) Error!Ast {
    var diag: Diagnostic = .{};
    return parse(allocator, pattern, &diag) catch |e| {
        if (e == error.InvalidPattern) ctx.report(diag, pattern);
        return e;
    };
}

/// Parse `pattern` at comptime. A storage wrapper over `scan`: it provisions the
/// buffers as comptime arrays, runs the agnostic core, then copies the used
/// portions into const arrays that land in `ro_data`. Returns `.ok` with an AST
/// whose slices point at that const data, or `.fail` with the diagnostic.
/// Callers that just want a hard compile error should use `compile`.
pub fn parseComptime(comptime pattern: []const u8) Outcome {
    // The quota is a CEILING on comptime backward-branches (a runaway-loop
    // guard), not a cost — raising it is free unless the work reaches it, and
    // the compiler stops at the actual work done. It must scale with the input
    // (a fixed quota would reject large patterns), but the real cost is small:
    // measured at well under ~25 branches/byte even for property-heavy patterns,
    // since the scan is a single O(n) pass. 1000/byte is a ~40x safety margin.
    // Saturate into u32 so an absurdly large comptime pattern fails with a clean
    // "exceeded backwards branches" rather than an integer-overflow message.
    const quota = @min(@as(u64, pattern.len) * 1000 + 1000, std.math.maxInt(u32));
    @setEvalBranchQuota(@intCast(quota));
    const sizes = comptime requiredSizes(pattern.len);

    var nodes: [sizes.nodes]ast.Node = undefined;
    var children: [sizes.children]u32 = undefined;
    var items: [sizes.class_items]ast.ClassItem = undefined;
    var names: [sizes.names][]const u8 = undefined;
    var seq: [sizes.seq]u32 = undefined;
    var alt: [sizes.alt]u32 = undefined;
    var frames: [sizes.frames]Frame = undefined;
    var diag: Diagnostic = .{};

    const raw = scan(pattern, &diag, .{
        .nodes = &nodes,
        .children = &children,
        .class_items = &items,
        .names = &names,
        .seq = &seq,
        .alt = &alt,
        .frames = &frames,
    }) catch return .{ .fail = diag };

    // Copy the used sub-slices into const arrays; `&` promotes them to ro_data
    // so the returned AST outlives this function's comptime locals.
    const final_nodes = raw.nodes[0..raw.nodes.len].*;
    const final_children = raw.children[0..raw.children.len].*;
    const final_items = raw.class_items[0..raw.class_items.len].*;
    const final_names = raw.names[0..raw.names.len].*;

    return .{ .ok = Ast{
        .nodes = &final_nodes,
        .children = &final_children,
        .class_items = &final_items,
        .names = &final_names,
        .root = raw.root,
        .capture_count = raw.capture_count,
        .flags = raw.flags,
    } };
}

/// Parse `pattern` at comptime, failing compilation with a located message if
/// the pattern is invalid. This is the comptime analogue of "pretty-print the
/// error": the build stops and the developer sees exactly what and where.
pub fn compile(comptime pattern: []const u8) Ast {
    comptime {
        return switch (parseComptime(pattern)) {
            .ok => |a| a,
            .fail => |d| @compileError(std.fmt.comptimePrint(
                "invalid regex: {s}\n  pattern: \"{s}\"\n  here:    \"{s}\" (bytes {d}..{d})",
                .{ d.message(), pattern, d.faultySlice(pattern), d.span.start, d.span.end },
            )),
        };
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Debug: s-expression serialization (used heavily by the tests)
// ════════════════════════════════════════════════════════════════════════════

/// Write a compact s-expression for `a` to `w`. Stable, lossless enough to
/// pin down structure in tests, and handy when eyeballing a parse.
///
/// Grammar of the output:
///   (alt X Y ...)              alternation
///   (cat X Y ...) / (cat)      concatenation (possibly empty)
///   (rep MIN MAX G X)          quantifier; MAX is a number or "inf";
///                              G is "g" (greedy) or "l" (lazy)
///   (cap N X) / (cap N=name X) capturing group
///   (grp X) / (grp+i-s X)      non-capturing group (with optional flag delta)
///   (anc KIND)                 anchor
///   (lit c) / (lit U+XX)       single code_point
///   .                          dot
///   (cls ITEM ...) / (cls^ ..) character class (^ = negated)
///   (uprop) / (unprop)         standalone \p{...} / \P{...}
///   (graph)                    \X
pub fn formatAst(a: Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNode(a, a.root, w);
}

fn writeNode(a: Ast, idx: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const node = a.nodes[idx];
    switch (node.tag) {
        .alternation => {
            try w.writeAll("(alt");
            const d = node.data.children;
            for (a.children[d.start .. d.start + d.len]) |c| {
                try w.writeAll(" ");
                try writeNode(a, c, w);
            }
            try w.writeAll(")");
        },
        .concat => {
            const d = node.data.children;
            if (d.len == 0) {
                try w.writeAll("(cat)");
                return;
            }
            try w.writeAll("(cat");
            for (a.children[d.start .. d.start + d.len]) |c| {
                try w.writeAll(" ");
                try writeNode(a, c, w);
            }
            try w.writeAll(")");
        },
        .range => {
            const r = node.data.range;
            try w.print("(rep {d} ", .{r.quantifier.min});
            if (r.quantifier.max) |mx| try w.print("{d}", .{mx}) else try w.writeAll("inf");
            try w.writeAll(if (r.quantifier.greedy) " g " else " l ");
            try writeNode(a, r.child, w);
            try w.writeAll(")");
        },
        .capture => {
            const c = node.data.capture;
            if (c.name) |ni| {
                try w.print("(cap {d}={s} ", .{ c.index, a.names[ni] });
            } else {
                try w.print("(cap {d} ", .{c.index});
            }
            try writeNode(a, c.child, w);
            try w.writeAll(")");
        },
        .non_capture => {
            const c = node.data.non_capture;
            try w.writeAll("(grp");
            try writeFlagDelta(c.flags_add, c.flags_remove, w);
            try w.writeAll(" ");
            try writeNode(a, c.child, w);
            try w.writeAll(")");
        },
        .anchor => try w.print("(anc {s})", .{@tagName(node.data.anchor.kind)}),
        .literal => {
            try w.writeAll("(lit ");
            try writeCp(node.data.literal.code_point, w);
            try w.writeAll(")");
        },
        .dot => try w.writeAll("."),
        .char_class => {
            const d = node.data.char_class;
            try w.writeAll(if (d.negated) "(cls^" else "(cls");
            for (a.class_items[d.start .. d.start + d.len]) |it| {
                try w.writeAll(" ");
                try writeClassItem(it, w);
            }
            try w.writeAll(")");
        },
        .unicode_property => try w.writeAll(if (node.data.unicode_prop.negated) "(unprop)" else "(uprop)"),
        .grapheme_cluster => try w.writeAll("(graph)"),
    }
}

fn writeFlagDelta(add: token.Flags, remove: token.Flags, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (add.case_insensitive) try w.writeAll("+i");
    if (add.multiline) try w.writeAll("+m");
    if (add.dot_all) try w.writeAll("+s");
    if (remove.case_insensitive) try w.writeAll("-i");
    if (remove.multiline) try w.writeAll("-m");
    if (remove.dot_all) try w.writeAll("-s");
}

fn writeClassItem(it: ast.ClassItem, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (it) {
        .range => |r| {
            if (r.lo == r.hi) {
                try writeCp(r.lo, w);
            } else {
                try writeCp(r.lo, w);
                try w.writeAll("-");
                try writeCp(r.hi, w);
            }
        },
        .perl => |p| {
            const ch: u8 = switch (p.kind) {
                .digit => 'd',
                .word => 'w',
                .space => 's',
            };
            try w.print("\\{c}", .{if (p.negated) std.ascii.toUpper(ch) else ch});
        },
        .property => |p| try w.writeAll(if (p.negated) "\\P" else "\\p"),
    }
}

fn writeCp(cp: CodePoint, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (cp >= 0x21 and cp <= 0x7E) {
        try w.print("{c}", .{@as(u8, @intCast(cp))});
    } else {
        try w.print("U+{X}", .{cp});
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Parse at runtime and assert the AST renders to `expected`. Frees the AST.
fn expectSexpr(pattern: []const u8, expected: []const u8) !void {
    var diag: Diagnostic = .{};
    const a = parse(testing.allocator, pattern, &diag) catch |e| {
        std.debug.print("unexpected error {s} ({s}) parsing \"{s}\"\n", .{ @errorName(e), @tagName(diag.code), pattern });
        return e;
    };
    defer a.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatAst(a, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

/// Parse at runtime and assert it fails with exactly `code`.
fn expectError(pattern: []const u8, code: ErrorCode) !void {
    var diag: Diagnostic = .{};
    const result = parse(testing.allocator, pattern, &diag);
    if (result) |a| {
        a.deinit(testing.allocator);
        std.debug.print("expected error {s} for \"{s}\" but it parsed\n", .{ @tagName(code), pattern });
        return error.TestUnexpectedSuccess;
    } else |e| {
        try testing.expectEqual(error.InvalidPattern, e);
        if (diag.code != code) {
            std.debug.print("for \"{s}\": expected {s}, got {s}\n", .{ pattern, @tagName(code), @tagName(diag.code) });
            return error.TestWrongErrorCode;
        }
    }
}

// ── Literals and concatenation ─────────────────────────────────────────────

test "single literal" {
    try expectSexpr("a", "(lit a)");
}

test "empty pattern is an empty concat" {
    try expectSexpr("", "(cat)");
}

test "concatenation of literals" {
    try expectSexpr("abc", "(cat (lit a) (lit b) (lit c))");
}

test "non-meta punctuation is literal" {
    try expectSexpr("a]b", "(cat (lit a) (lit ]) (lit b))");
    try expectSexpr("a}b", "(cat (lit a) (lit }) (lit b))");
    try expectSexpr("a,b", "(cat (lit a) (lit ,) (lit b))");
    try expectSexpr("-", "(lit -)");
}

test "dot" {
    try expectSexpr("a.c", "(cat (lit a) . (lit c))");
}

// ── Alternation ────────────────────────────────────────────────────────────

test "simple alternation" {
    try expectSexpr("a|b", "(alt (lit a) (lit b))");
}

test "alternation of concats" {
    try expectSexpr("ab|cd", "(alt (cat (lit a) (lit b)) (cat (lit c) (lit d)))");
}

test "alternation with three branches" {
    try expectSexpr("a|b|c", "(alt (lit a) (lit b) (lit c))");
}

test "empty alternation branches" {
    try expectSexpr("a|", "(alt (lit a) (cat))");
    try expectSexpr("|a", "(alt (cat) (lit a))");
    try expectSexpr("a||b", "(alt (lit a) (cat) (lit b))");
}

// ── Quantifiers ──────────────────────────────────────────────────────────

test "star plus question greedy" {
    try expectSexpr("a*", "(rep 0 inf g (lit a))");
    try expectSexpr("a+", "(rep 1 inf g (lit a))");
    try expectSexpr("a?", "(rep 0 1 g (lit a))");
}

test "lazy quantifiers" {
    try expectSexpr("a*?", "(rep 0 inf l (lit a))");
    try expectSexpr("a+?", "(rep 1 inf l (lit a))");
    try expectSexpr("a??", "(rep 0 1 l (lit a))");
}

test "counted quantifiers" {
    try expectSexpr("a{3}", "(rep 3 3 g (lit a))");
    try expectSexpr("a{2,}", "(rep 2 inf g (lit a))");
    try expectSexpr("a{2,5}", "(rep 2 5 g (lit a))");
    try expectSexpr("a{,5}", "(rep 0 5 g (lit a))");
    try expectSexpr("a{2,5}?", "(rep 2 5 l (lit a))");
}

test "quantifier binds the last atom only" {
    try expectSexpr("ab*", "(cat (lit a) (rep 0 inf g (lit b)))");
}

test "malformed braces fall back to literal" {
    try expectSexpr("a{", "(cat (lit a) (lit {))");
    try expectSexpr("a{x}", "(cat (lit a) (lit {) (lit x) (lit }))");
    try expectSexpr("a{2,1x}", "(cat (lit a) (lit {) (lit 2) (lit ,) (lit 1) (lit x) (lit }))");
    try expectSexpr("{3}", "(cat (lit {) (lit 3) (lit }))");
}

test "quantifier errors" {
    try expectError("*", .nothing_to_repeat);
    try expectError("+a", .nothing_to_repeat);
    try expectError("?", .nothing_to_repeat);
    try expectError("a**", .multiple_quantifiers);
    try expectError("a*+", .multiple_quantifiers);
    try expectError("a+?*", .multiple_quantifiers);
    try expectError("a{2,1}", .quantifier_out_of_order);
    try expectError("a{99999999999}", .quantifier_too_large);
    try expectError("|*", .nothing_to_repeat);
    try expectError("(*)", .nothing_to_repeat);
}

// ── Groups ─────────────────────────────────────────────────────────────────

test "capturing group" {
    try expectSexpr("(a)", "(cap 1 (lit a))");
    try expectSexpr("(ab)", "(cap 1 (cat (lit a) (lit b)))");
}

test "capture numbering follows opening parens" {
    try expectSexpr("(a)(b)", "(cat (cap 1 (lit a)) (cap 2 (lit b)))");
    try expectSexpr("((a)b)", "(cap 1 (cat (cap 2 (lit a)) (lit b)))");
}

test "non-capturing group" {
    try expectSexpr("(?:ab)", "(grp (cat (lit a) (lit b)))");
    try expectSexpr("(?:a)(b)", "(cat (grp (lit a)) (cap 1 (lit b)))");
}

test "named group" {
    try expectSexpr("(?<year>a)", "(cap 1=year (lit a))");
    try expectSexpr("(?P<x>a)", "(cap 1=x (lit a))");
}

test "group with alternation and quantifier" {
    try expectSexpr("(a|b)*", "(rep 0 inf g (cap 1 (alt (lit a) (lit b))))");
}

test "empty group" {
    try expectSexpr("()", "(cap 1 (cat))");
    try expectSexpr("(?:)", "(grp (cat))");
}

test "group errors" {
    try expectError("(a", .unclosed_group);
    try expectError("a)", .unmatched_close_paren);
    try expectError(")", .unmatched_close_paren);
    try expectError("(a(b)", .unclosed_group);
    try expectError("(?<a>x)(?<a>y)", .duplicate_group_name);
    try expectError("(?<>x)", .empty_group_name);
    try expectError("(?<ab", .unclosed_group_name);
    try expectError("(?<1a>x)", .invalid_group_name);
    try expectError("(?", .invalid_group_syntax);
}

test "unsupported constructs are rejected precisely" {
    try expectError("(?=a)", .unsupported_lookaround);
    try expectError("(?!a)", .unsupported_lookaround);
    try expectError("(?<=a)", .unsupported_lookaround);
    try expectError("(?<!a)", .unsupported_lookaround);
    try expectError("(?>a)", .unsupported_atomic_group);
    try expectError("(?(1)a)", .unsupported_conditional);
    try expectError("(?R)", .unsupported_subroutine);
    try expectError("\\1", .unsupported_backreference);
    try expectError("\\k<n>", .unsupported_backreference);
    try expectError("a\\Qb\\E", .unsupported_quote);
}

// ── Inline flags ───────────────────────────────────────────────────────────

test "scoped inline flags become a group delta" {
    try expectSexpr("(?i:a)", "(grp+i (lit a))");
    try expectSexpr("(?ims:a)", "(grp+i+m+s (lit a))");
    try expectSexpr("(?-i:a)", "(grp-i (lit a))");
    try expectSexpr("(?i-s:a)", "(grp+i-s (lit a))");
}

test "global inline flags set the ast flags" {
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, "(?i)abc", &diag);
    defer a.deinit(testing.allocator);
    try testing.expect(a.flags.case_insensitive);
    try testing.expect(!a.flags.multiline);
    try expectSexpr("(?i)abc", "(cat (lit a) (lit b) (lit c))");
}

test "flag errors" {
    try expectError("(?q)", .unknown_flag);
    try expectError("(?x:a)", .unknown_flag);
    try expectError("(?)", .empty_flag_group);
}

// ── Anchors ──────────────────────────────────────────────────────────────

test "anchors" {
    try expectSexpr("^a$", "(cat (anc line_begin) (lit a) (anc line_end))");
    try expectSexpr("\\Aa\\z", "(cat (anc input_begin) (lit a) (anc input_end))");
    try expectSexpr("a\\bb", "(cat (lit a) (anc word) (lit b))");
    try expectSexpr("a\\Bb", "(cat (lit a) (anc non_word) (lit b))");
}

// ── Shorthand classes ──────────────────────────────────────────────────────

test "standalone shorthands are single-member classes" {
    try expectSexpr("\\d", "(cls \\d)");
    try expectSexpr("\\D", "(cls \\D)");
    try expectSexpr("\\w", "(cls \\w)");
    try expectSexpr("\\W", "(cls \\W)");
    try expectSexpr("\\s", "(cls \\s)");
    try expectSexpr("\\S", "(cls \\S)");
}

test "grapheme escape" {
    try expectSexpr("\\X", "(graph)");
}

// ── Escapes ─────────────────────────────────────────────────────────────

test "control escapes resolve to code_points" {
    try expectSexpr("\\n", "(lit U+A)");
    try expectSexpr("\\t", "(lit U+9)");
    try expectSexpr("\\r", "(lit U+D)");
    try expectSexpr("\\0", "(lit U+0)");
}

test "escaped metacharacters are literal" {
    try expectSexpr("\\.", "(lit .)");
    try expectSexpr("\\*", "(lit *)");
    try expectSexpr("\\\\", "(lit \\)");
    try expectSexpr("\\(", "(lit ()");
    try expectSexpr("\\+", "(lit +)");
    try expectSexpr("\\{", "(lit {)");
}

test "hex and unicode escapes" {
    try expectSexpr("\\x41", "(lit A)");
    try expectSexpr("\\x{1F600}", "(lit U+1F600)");
    try expectSexpr("\\u0041", "(lit A)");
    try expectSexpr("\\u{41}", "(lit A)");
    try expectSexpr("\\cA", "(lit U+1)");
}

test "escape errors" {
    try expectError("\\", .trailing_backslash);
    try expectError("\\q", .unsupported_escape);
    try expectError("\\x{}", .empty_hex_escape);
    try expectError("\\x{110000}", .code_point_out_of_range);
    try expectError("\\x{D800}", .surrogate_code_point);
    try expectError("\\x{1G}", .invalid_hex_escape);
    try expectError("\\x{41", .unclosed_hex_escape);
    try expectError("\\u00", .invalid_unicode_escape);
    try expectError("\\u{}", .empty_unicode_escape);
    try expectError("\\c", .truncated_control_escape);
    try expectError("\\c1", .invalid_control_escape);
}

test "control letter sequences" {
    // \cZ is a valid control escape; a following Z is just a literal.
    try expectSexpr("\\cZZ", "(cat (lit U+1A) (lit Z))");
}

// ── Unicode properties ─────────────────────────────────────────────────────

test "unicode property escapes" {
    try expectSexpr("\\p{L}", "(uprop)");
    try expectSexpr("\\P{L}", "(unprop)");
    try expectSexpr("\\pL", "(uprop)");
    try expectSexpr("\\p{Script=Latin}", "(uprop)");
}

test "property errors" {
    try expectError("\\p", .truncated_property);
    try expectError("\\p{", .unclosed_property);
    try expectError("\\p{}", .empty_property_name);
    try expectError("\\p{Nonexistent}", .unknown_property);
    try expectError("\\p9", .expected_property_name);
}

// ── Character classes ──────────────────────────────────────────────────────

test "simple class" {
    try expectSexpr("[abc]", "(cls a b c)");
}

test "negated class" {
    try expectSexpr("[^abc]", "(cls^ a b c)");
}

test "class range" {
    try expectSexpr("[a-z]", "(cls a-z)");
    try expectSexpr("[a-zA-Z0-9]", "(cls a-z A-Z 0-9)");
}

test "class with shorthand and property members" {
    try expectSexpr("[\\d\\s]", "(cls \\d \\s)");
    try expectSexpr("[a-z\\d]", "(cls a-z \\d)");
    try expectSexpr("[\\p{L}0-9]", "(cls \\p 0-9)");
    try expectSexpr("[^\\W]", "(cls^ \\W)");
}

test "literal dash placements in class" {
    try expectSexpr("[-a]", "(cls - a)");
    try expectSexpr("[a-]", "(cls a -)");
    try expectSexpr("[a-z-]", "(cls a-z -)");
}

test "literal close-bracket as first member" {
    try expectSexpr("[]]", "(cls ])");
    try expectSexpr("[^]]", "(cls^ ])");
    try expectSexpr("[]a]", "(cls ] a)");
}

test "class with escapes" {
    try expectSexpr("[\\n\\t]", "(cls U+A U+9)");
    try expectSexpr("[\\x41-\\x5A]", "(cls A-Z)");
    // Inside a class, \b is backspace, not a word boundary.
    try expectSexpr("[\\b]", "(cls U+8)");
}

test "class errors" {
    try expectError("[", .unclosed_class);
    try expectError("[]", .unclosed_class);
    try expectError("[abc", .unclosed_class);
    try expectError("[z-a]", .range_out_of_order);
    try expectError("[[:alpha:]]", .unsupported_posix_class);
}

// ── Comments ───────────────────────────────────────────────────────────────

test "inline comments are skipped" {
    try expectSexpr("a(?#hi)b", "(cat (lit a) (lit b))");
    try expectSexpr("(?#c)a", "(lit a)");
    try expectSexpr("a(?#one)(?#two)b", "(cat (lit a) (lit b))");
    try expectError("a(?#unterminated", .unclosed_group);
}

// ── UTF-8 in the pattern ────────────────────────────────────────────────────

test "multibyte literals decode to code_points" {
    try expectSexpr("é", "(lit U+E9)");
    try expectSexpr("a→b", "(cat (lit a) (lit U+2192) (lit b))");
    try expectSexpr("[α-ω]", "(cls U+3B1-U+3C9)");
}

test "invalid utf-8 in pattern is rejected" {
    try expectError("a\xFF", .invalid_utf8);
}

// ── Nesting / integration ──────────────────────────────────────────────────

test "nested groups, alternation, quantifiers" {
    try expectSexpr(
        "(?:ab|c)+d",
        "(cat (rep 1 inf g (grp (alt (cat (lit a) (lit b)) (lit c)))) (lit d))",
    );
}

test "capture count is reported" {
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, "(a)(?:b)(c(d))", &diag);
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), a.capture_count);
}

test "deeply nested groups do not overflow (explicit stack, no recursion)" {
    const pattern = "((((((((((((((((a))))))))))))))))";
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, pattern, &diag);
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 16), a.capture_count);
}

// ── Diagnostic spans ────────────────────────────────────────────────────────

test "diagnostic points at the faulty slice" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidPattern, parse(testing.allocator, "ab\\qcd", &diag));
    try testing.expectEqual(ErrorCode.unsupported_escape, diag.code);
    try testing.expectEqualStrings("\\q", diag.faultySlice("ab\\qcd"));
}

test "diagnostic for unclosed group points at the paren" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidPattern, parse(testing.allocator, "ab(cd", &diag));
    try testing.expectEqual(ErrorCode.unclosed_group, diag.code);
    try testing.expectEqualStrings("(", diag.faultySlice("ab(cd"));
}

// ── parseReporting ──────────────────────────────────────────────────────────

const CollectCtx = struct {
    code: ErrorCode = .none,
    slice: []const u8 = "",
    fn report(self: *CollectCtx, diag: Diagnostic, pattern: []const u8) void {
        self.code = diag.code;
        self.slice = diag.faultySlice(pattern);
    }
};

test "parseReporting hands the diagnostic to the caller context" {
    var ctx = CollectCtx{};
    const r = parseReporting(testing.allocator, "a)", &ctx);
    try testing.expectError(error.InvalidPattern, r);
    try testing.expectEqual(ErrorCode.unmatched_close_paren, ctx.code);
    try testing.expectEqualStrings(")", ctx.slice);
}

test "parseReporting does not invoke report on success" {
    var ctx = CollectCtx{};
    const a = try parseReporting(testing.allocator, "abc", &ctx);
    defer a.deinit(testing.allocator);
    try testing.expectEqual(ErrorCode.none, ctx.code);
}

// ── Comptime parity ──────────────────────────────────────────────────────────

/// Render a comptime-built AST to a comptime string for comparison.
fn comptimeSexpr(comptime pattern: []const u8) []const u8 {
    comptime {
        const a = compile(pattern);
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        formatAst(a, &w) catch unreachable;
        const out = w.buffered();
        const arr = out[0..out.len].*;
        return &arr;
    }
}

test "comptime parse matches runtime parse" {
    try testing.expectEqualStrings("(cat (lit a) (rep 0 inf g (lit b)))", comptime comptimeSexpr("ab*"));
    try testing.expectEqualStrings("(alt (lit a) (lit b))", comptime comptimeSexpr("a|b"));
    try testing.expectEqualStrings("(cap 1 (alt (lit a) (lit b)))", comptime comptimeSexpr("(a|b)"));
    try testing.expectEqualStrings("(cls a-z \\d)", comptime comptimeSexpr("[a-z\\d]"));
}

test "comptime parse surfaces diagnostics without compiling" {
    const outcome = comptime parseComptime("a(b");
    switch (outcome) {
        .ok => return error.TestUnexpectedSuccess,
        .fail => |d| {
            try testing.expectEqual(ErrorCode.unclosed_group, d.code);
            try comptime testing.expectEqualStrings("(", d.faultySlice("a(b"));
        },
    }
}

// ── Extra edge cases ────────────────────────────────────────────────────────

test "quantified group" {
    try expectSexpr("(ab){2,3}", "(rep 2 3 g (cap 1 (cat (lit a) (lit b))))");
    try expectSexpr("(?:a)+", "(rep 1 inf g (grp (lit a)))");
}

test "lenient dash before a shorthand is literal" {
    try expectSexpr("[a-\\d]", "(cls a - \\d)");
}

test "alternation with multiple multi-atom branches" {
    try expectSexpr("ab|cd|ef", "(alt (cat (lit a) (lit b)) (cat (lit c) (lit d)) (cat (lit e) (lit f)))");
}

test "scoped flags stay on the group and do not touch ast flags" {
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, "(?i:a)b", &diag);
    defer a.deinit(testing.allocator);
    try testing.expect(!a.flags.case_insensitive); // scoped, not global
    try expectSexpr("(?i:a)b", "(cat (grp+i (lit a)) (lit b))");
}

test "global flags accumulate and clear" {
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, "(?im)a", &diag);
    defer a.deinit(testing.allocator);
    try testing.expect(a.flags.case_insensitive);
    try testing.expect(a.flags.multiline);
    try testing.expect(!a.flags.dot_all);
}

test "empty branches inside a group" {
    try expectSexpr("(|a)", "(cap 1 (alt (cat) (lit a)))");
}

test "scan can run on caller-owned stack buffers (storage-agnostic)" {
    // Demonstrates the agnostic core: the caller supplies the storage. Here it
    // is an on-stack buffer set; it could equally be ro_data or an arena. Sizes
    // are comptime here because the pattern length is comptime-known.
    const pattern = "a(b|c)*";
    const sizes = comptime requiredSizes(pattern.len);
    var nodes: [sizes.nodes]ast.Node = undefined;
    var children: [sizes.children]u32 = undefined;
    var items: [sizes.class_items]ast.ClassItem = undefined;
    var names: [sizes.names][]const u8 = undefined;
    var seq: [sizes.seq]u32 = undefined;
    var alt: [sizes.alt]u32 = undefined;
    var frames: [sizes.frames]Frame = undefined;
    var diag: Diagnostic = .{};
    const a = try scan(pattern, &diag, .{
        .nodes = &nodes,
        .children = &children,
        .class_items = &items,
        .names = &names,
        .seq = &seq,
        .alt = &alt,
        .frames = &frames,
    });
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatAst(a, &w);
    try testing.expectEqualStrings("(cat (lit a) (rep 0 inf g (cap 1 (alt (lit b) (lit c)))))", w.buffered());
}

test "comptime compiles a realistic, non-trivial pattern" {
    // A ~70-byte email-ish pattern with named groups, classes, counted and
    // unbounded quantifiers, and anchors — proves the comptime quota is ample
    // for real patterns (measured cost is well under ~25 branches/byte).
    const re = comptime compile(
        "^(?<user>[A-Za-z0-9._%+-]+)@(?<host>[A-Za-z0-9.-]+)\\.(?<tld>[A-Za-z]{2,63})$",
    );
    try testing.expectEqual(@as(u32, 3), re.capture_count);
    try testing.expectEqualStrings("user", re.names[0]);
    try testing.expectEqualStrings("tld", re.names[2]);
}

test {
    testing.refAllDecls(@This());
}
