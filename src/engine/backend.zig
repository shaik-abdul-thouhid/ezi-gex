//! The backend contract + the backend-agnostic operations every regex exposes.
//!
//! A **backend** is a `type` (namespace) that knows how to turn a HIR into an
//! executable `Program` and run two primitive searches over it. Everything a user
//! thinks of as "the regex API" — `isMatch`, `find`, `findAll`, `captures`,
//! `capturesAll`, `count`, `split`, `replaceAll` — is implemented **once, here,
//! generically over any backend**, on top of just two primitives the backend
//! provides (`search` and `searchCaptures`). Backends never implement iteration,
//! capture views, or substitution; they only locate a match and fill a `slots`
//! array. That is what makes captures/replace/split backend-agnostic.
//!
//! The contract is duck-typed at comptime (no vtable): `Engine(Backend)` is a
//! comptime function returning a namespace of operations specialized to that
//! backend, fully inlined. See `docs/regex-engine-design.md` §3.
//!
//! This file depends only on `std` — it is the stable seam between `core/` (which
//! produces the HIR) and the backends (which consume it). The HIR itself appears
//! only in a backend's `build*` signatures, not here.

const std = @import("std");

// ── Shared value types ──────────────────────────────────────────────────────────

/// A match span, as byte offsets into the input.
pub const Match = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Match, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
    pub fn len(self: Match) usize {
        return self.end - self.start;
    }
    pub fn isEmpty(self: Match) bool {
        return self.start == self.end;
    }
};

/// Where/how a single search runs. `start` is a byte offset; `anchored` forces the
/// match to begin exactly at `start` (no leftward scan).
pub const SearchOptions = struct {
    start: usize = 0,
    anchored: bool = false,
};

/// Budget/behaviour hints a backend may accept when its `Scratch` is constructed.
/// Backends with no growable part (e.g. the Pike VM) ignore these; only a lazy-DFA
/// memo consults them. `grow` is impossible for a fixed-buffer `Scratch.initBuffer`.
pub const ScratchOptions = struct {
    max_bytes: usize = 1 << 20,
    on_full: enum { reset, give_up, grow } = .reset,
};

/// What a backend can do (comptime). The dispatcher/front door reads these to
/// route and to gate capability-specific methods.
pub const Caps = struct {
    /// Can report submatches (`searchCaptures`)?
    captures: bool,
    /// No per-search state needed (`Scratch == struct{}`)?
    stateless: bool = false,
    /// Can match `\X` (grapheme) nodes?
    grapheme: bool = false,
    /// Only supports anchored search?
    anchored_only: bool = false,
};

/// Capture metadata, derived once from the HIR by the front door and carried
/// alongside a `Program`. The backend does not need this — only the agnostic
/// capture view does (to size `slots` and resolve names).
pub const Meta = struct {
    /// Number of capturing groups, excluding the whole match (group 0).
    capture_count: u32 = 0,
    /// `group_names[g]` is the name of group `g`, or `null`. Length, when present,
    /// is `capture_count + 1` (index 0 — the whole match — is always `null`).
    /// Empty means "no named groups".
    group_names: []const ?[]const u8 = &.{},

    /// Required `slots` length for `searchCaptures`: two offsets per group + the
    /// whole match.
    pub fn slotLen(self: Meta) usize {
        return 2 * (self.capture_count + 1);
    }
};

/// Suggested error sets (backends may use their own supersets).
pub const BuildError = error{ PatternTooComplex, Unsupported } || std.mem.Allocator.Error;
pub const ScratchError = error{ BufferTooSmall, Unsupported } || std.mem.Allocator.Error;

// ── A resolved set of captures (backend-agnostic view over `slots`) ──────────────

/// A read-only view of one match's captures. Holds only the caller's `slots`
/// buffer, the `Meta`, and the `input` — so it is identical for every backend.
/// Borrows `slots` and `input`; valid until the `slots` buffer is reused (e.g. the
/// next `CaptureIterator.next`).
pub const Captures = struct {
    slots: []const ?usize,
    meta: Meta,
    input: []const u8,

    /// The whole match (group 0).
    pub fn match(self: Captures) Match {
        return self.group(0).?;
    }
    /// Number of slots' worth of groups (whole match + capture groups).
    pub fn count(self: Captures) usize {
        return self.meta.capture_count + 1;
    }
    /// Group `i` (0 = whole match), or null if it did not participate.
    pub fn group(self: Captures, i: usize) ?Match {
        const lo = i * 2;
        if (lo + 1 >= self.slots.len) return null;
        const s = self.slots[lo] orelse return null;
        const e = self.slots[lo + 1] orelse return null;
        return .{ .start = s, .end = e };
    }
    /// The text of group `i`, or null.
    pub fn groupSlice(self: Captures, i: usize) ?[]const u8 {
        return if (self.group(i)) |m| m.slice(self.input) else null;
    }
    /// The group with the given name, or null (no such name, or didn't participate).
    pub fn named(self: Captures, name: []const u8) ?Match {
        for (self.meta.group_names, 0..) |gn, g| {
            if (gn) |n| {
                if (std.mem.eql(u8, n, name)) return self.group(g);
            }
        }
        return null;
    }
    /// The text of the named group, or null.
    pub fn namedSlice(self: Captures, name: []const u8) ?[]const u8 {
        return if (self.named(name)) |m| m.slice(self.input) else null;
    }
};

// ── Contract verification ────────────────────────────────────────────────────────

/// Comptime-assert that `B` satisfies the **mandatory** (Lean) contract, with
/// clear errors. Everything beyond this is optional and `@hasDecl`-gated at the
/// call site — a missing optional decl errors only when actually used.
pub fn verifyBackend(comptime B: type) void {
    comptime {
        const who = @typeName(B);
        if (!@hasDecl(B, "caps")) @compileError("backend `" ++ who ++ "` is missing `pub const caps: Caps`");
        if (@TypeOf(B.caps) != Caps) @compileError("backend `" ++ who ++ "`.caps must be of type `backend.Caps`");
        if (!@hasDecl(B, "Program")) @compileError("backend `" ++ who ++ "` is missing `pub const Program: type`");
        if (@TypeOf(B.Program) != type) @compileError("backend `" ++ who ++ "`.Program must be a type");
        if (!@hasDecl(B, "Scratch")) @compileError("backend `" ++ who ++ "` is missing `pub const Scratch: type` (use `struct{}` if stateless)");
        if (@TypeOf(B.Scratch) != type) @compileError("backend `" ++ who ++ "`.Scratch must be a type");
        if (!@hasDecl(B, "isMatch")) @compileError("backend `" ++ who ++ "` is missing `pub fn isMatch(...)`");
        if (!@hasDecl(B, "buildComptime") and !@hasDecl(B, "buildAlloc"))
            @compileError("backend `" ++ who ++ "` must define `buildComptime` and/or `buildAlloc`");
        if (B.caps.captures and !@hasDecl(B, "searchCaptures"))
            @compileError("backend `" ++ who ++ "` sets caps.captures = true but has no `searchCaptures`");
    }
}

// ── The agnostic operation layer ─────────────────────────────────────────────────

/// `Engine(Backend)` is the namespace of regex operations specialized to a
/// backend. The front door (`Regex`/`Compiled`) is a thin wrapper that stores a
/// `Program` + `Scratch` + `Meta` and forwards to these. All of it is generic over
/// the two backend primitives (`search`/`searchCaptures`) — backends contribute no
/// iteration/capture/replace code.
pub fn Engine(comptime Backend: type) type {
    comptime verifyBackend(Backend);
    return struct {
        pub const B = Backend;
        pub const Program = Backend.Program;
        pub const Scratch = Backend.Scratch;
        pub const supports_captures = Backend.caps.captures;

        // ── single-shot ─────────────────────────────────────────────────────────

        pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
            return Backend.isMatch(program, scratch, input, opts);
        }

        pub fn find(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
            if (comptime !@hasDecl(Backend, "search"))
                @compileError("backend `" ++ @typeName(Backend) ++ "` has no `search` (find/findAll/split/replaceAll need it)");
            return Backend.search(program, scratch, input, opts);
        }

        /// Resolve the first match's captures into the caller-owned `slots` (length
        /// `meta.slotLen()`). `slots` is zeroed first, so a non-participating group
        /// reads back `null` — no stale state from a prior search.
        pub fn captures(
            program: *const Program,
            scratch: *Scratch,
            input: []const u8,
            slots: []?usize,
            meta: Meta,
            opts: SearchOptions,
        ) ?Captures {
            if (comptime !Backend.caps.captures)
                @compileError("backend `" ++ @typeName(Backend) ++ "` does not support captures");
            @memset(slots, null);
            _ = Backend.searchCaptures(program, scratch, input, slots, opts) orelse return null;
            return .{ .slots = slots, .meta = meta, .input = input };
        }

        /// Count non-overlapping matches.
        pub fn count(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) usize {
            var it = findAll(program, scratch, input, opts);
            var n: usize = 0;
            while (it.next()) |_| n += 1;
            return n;
        }

        // ── iterate matches ───────────────────────────────────────────────────────

        pub const MatchIterator = struct {
            program: *const Program,
            scratch: *Scratch,
            input: []const u8,
            pos: usize,
            anchored: bool,

            pub fn next(self: *MatchIterator) ?Match {
                if (self.pos > self.input.len) return null;
                const m = Backend.search(self.program, self.scratch, self.input, .{
                    .start = self.pos,
                    .anchored = self.anchored,
                }) orelse {
                    self.pos = self.input.len + 1;
                    return null;
                };
                // Non-overlapping; an empty match advances one code_point so the
                // iterator makes progress instead of looping forever.
                self.pos = if (m.end > m.start) m.end else advanceCodePoint(self.input, m.end);
                return m;
            }
        };

        pub fn findAll(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) MatchIterator {
            if (comptime !@hasDecl(Backend, "search"))
                @compileError("backend `" ++ @typeName(Backend) ++ "` has no `search`");
            return .{ .program = program, .scratch = scratch, .input = input, .pos = opts.start, .anchored = opts.anchored };
        }

        // ── iterate captures ────────────────────────────────────────────────────────

        /// Yields a `Captures` per match into the **shared** `slots` buffer. Each
        /// `Captures` is valid only until the next `next()` (the slots are reused).
        pub const CaptureIterator = struct {
            program: *const Program,
            scratch: *Scratch,
            input: []const u8,
            slots: []?usize,
            meta: Meta,
            pos: usize,
            anchored: bool,

            pub fn next(self: *CaptureIterator) ?Captures {
                if (self.pos > self.input.len) return null;
                @memset(self.slots, null);
                const m = Backend.searchCaptures(self.program, self.scratch, self.input, self.slots, .{
                    .start = self.pos,
                    .anchored = self.anchored,
                }) orelse {
                    self.pos = self.input.len + 1;
                    return null;
                };
                self.pos = if (m.end > m.start) m.end else advanceCodePoint(self.input, m.end);
                return .{ .slots = self.slots, .meta = self.meta, .input = self.input };
            }
        };

        pub fn capturesAll(
            program: *const Program,
            scratch: *Scratch,
            input: []const u8,
            slots: []?usize,
            meta: Meta,
            opts: SearchOptions,
        ) CaptureIterator {
            if (comptime !Backend.caps.captures)
                @compileError("backend `" ++ @typeName(Backend) ++ "` does not support captures");
            return .{
                .program = program,
                .scratch = scratch,
                .input = input,
                .slots = slots,
                .meta = meta,
                .pos = opts.start,
                .anchored = opts.anchored,
            };
        }

        // ── split ───────────────────────────────────────────────────────────────────

        /// Yields the substrings of `input` between successive matches. Empty
        /// matches are skipped (they would otherwise split between every code_point).
        /// The final piece (after the last match) is always yielded.
        pub const SplitIterator = struct {
            it: MatchIterator,
            input: []const u8,
            last: usize,
            finished: bool,

            pub fn next(self: *SplitIterator) ?[]const u8 {
                if (self.finished) return null;
                while (self.it.next()) |m| {
                    if (m.isEmpty()) continue;
                    const piece = self.input[self.last..m.start];
                    self.last = m.end;
                    return piece;
                }
                self.finished = true;
                return self.input[self.last..];
            }
        };

        pub fn split(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) SplitIterator {
            return .{ .it = findAll(program, scratch, input, opts), .input = input, .last = opts.start, .finished = false };
        }

        // ── replace ───────────────────────────────────────────────────────────────────

        /// Replace every match, writing the result to `writer`. `template` may
        /// reference captures: `$0`/`$1`/… by number, `${name}` by name (or
        /// `${0}`/`${12}` for disambiguation), and `$$` for a literal `$`. Needs a
        /// capture-capable backend and a `slots` buffer of `meta.slotLen()`.
        pub fn replaceAll(
            program: *const Program,
            scratch: *Scratch,
            input: []const u8,
            template: []const u8,
            slots: []?usize,
            meta: Meta,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (comptime !Backend.caps.captures)
                @compileError("backend `" ++ @typeName(Backend) ++ "` does not support captures (replaceAll needs them)");
            var written: usize = 0; // input consumed/emitted up to here
            var from: usize = 0; // next search start
            while (from <= input.len) {
                @memset(slots, null);
                const m = Backend.searchCaptures(program, scratch, input, slots, .{ .start = from }) orelse break;
                try writer.writeAll(input[written..m.start]);
                try expandTemplate(writer, template, .{ .slots = slots, .meta = meta, .input = input });
                written = m.end;
                from = if (m.end > m.start) m.end else advanceCodePoint(input, m.end);
            }
            try writer.writeAll(input[written..]);
        }
    };
}

// ── helpers ──────────────────────────────────────────────────────────────────────

/// Advance one UTF-8 code_point from byte offset `i` (≥ end-of-input ⇒ i+1, so
/// loops terminate). Lone/invalid lead bytes advance by 1.
fn advanceCodePoint(input: []const u8, i: usize) usize {
    if (i >= input.len) return i + 1;
    return i + (std.unicode.utf8ByteSequenceLength(input[i]) catch 1);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Expand a `$`-template against one set of captures (`$$`, `$N`, `${N}`, `${name}`).
fn expandTemplate(writer: *std.Io.Writer, template: []const u8, caps: Captures) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c != '$' or i + 1 >= template.len) {
            try writer.writeByte(c);
            i += 1;
            continue;
        }
        const n = template[i + 1];
        switch (n) {
            '$' => {
                try writer.writeByte('$');
                i += 2;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, template, i + 2, '}') orelse {
                    try writer.writeByte('$'); // unterminated ${ — emit literally
                    i += 1;
                    continue;
                };
                try writeGroupByKey(writer, caps, template[i + 2 .. close]);
                i = close + 1;
            },
            '0'...'9' => {
                var j = i + 1;
                var num: usize = 0;
                while (j < template.len and isDigit(template[j])) : (j += 1) num = num * 10 + (template[j] - '0');
                if (caps.group(num)) |m| try writer.writeAll(m.slice(caps.input));
                i = j;
            },
            else => {
                try writer.writeByte('$'); // `$` followed by something else — literal `$`
                i += 1;
            },
        }
    }
}

fn writeGroupByKey(writer: *std.Io.Writer, caps: Captures, key: []const u8) std.Io.Writer.Error!void {
    var all_digits = key.len > 0;
    for (key) |c| {
        if (!isDigit(c)) {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        var num: usize = 0;
        for (key) |c| num = num * 10 + (c - '0');
        if (caps.group(num)) |m| try writer.writeAll(m.slice(caps.input));
    } else if (caps.named(key)) |m| {
        try writer.writeAll(m.slice(caps.input));
    }
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests — exercised against a mock backend, proving the agnostic layer works
// before any real backend exists.
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// A trivial substring backend that satisfies the contract. `Program` is the
/// literal needle; `Scratch` is empty (stateless). It writes group 0 always, and a
/// fake group 1 == whole match when the caller's `slots` has room — enough to drive
/// the agnostic capture/iterator/replace/split code paths.
const MockLiteral = struct {
    pub const caps = Caps{ .captures = true, .stateless = true };
    pub const Program = struct { needle: []const u8 };
    pub const Scratch = struct {};

    // Present so verifyBackend passes; never called in these tests (Program is
    // hand-built).
    pub fn buildAlloc(_: std.mem.Allocator, _: anytype, _: anytype) BuildError!Program {
        return error.Unsupported;
    }

    pub fn search(p: *const Program, _: *Scratch, input: []const u8, o: SearchOptions) ?Match {
        var i = o.start;
        while (i + p.needle.len <= input.len) : (i += 1) {
            if (std.mem.eql(u8, input[i .. i + p.needle.len], p.needle))
                return .{ .start = i, .end = i + p.needle.len };
            if (o.anchored) return null;
        }
        return null;
    }

    pub fn isMatch(p: *const Program, s: *Scratch, input: []const u8, o: SearchOptions) bool {
        return search(p, s, input, o) != null;
    }

    pub fn searchCaptures(p: *const Program, s: *Scratch, input: []const u8, slots: []?usize, o: SearchOptions) ?Match {
        const m = search(p, s, input, o) orelse return null;
        if (slots.len >= 2) {
            slots[0] = m.start;
            slots[1] = m.end;
        }
        if (slots.len >= 4) { // fake group 1 == whole match
            slots[2] = m.start;
            slots[3] = m.end;
        }
        return m;
    }
};

const E = Engine(MockLiteral);

test "verifyBackend accepts a conforming backend" {
    comptime verifyBackend(MockLiteral); // compiles ⇒ pass
}

test "isMatch / find" {
    var prog = MockLiteral.Program{ .needle = "bc" };
    var s = MockLiteral.Scratch{};
    try testing.expect(E.isMatch(&prog, &s, "abcabc", .{}));
    try testing.expect(!E.isMatch(&prog, &s, "axc", .{}));
    const m = E.find(&prog, &s, "abcabc", .{}).?;
    try testing.expectEqual(@as(usize, 1), m.start);
    try testing.expectEqual(@as(usize, 3), m.end);
    try testing.expectEqualStrings("bc", m.slice("abcabc"));
}

test "findAll + count (non-overlapping)" {
    var prog = MockLiteral.Program{ .needle = "ab" };
    var s = MockLiteral.Scratch{};
    const input = "ababXab";
    try testing.expectEqual(@as(usize, 3), E.count(&prog, &s, input, .{}));
    var it = E.findAll(&prog, &s, input, .{});
    try testing.expectEqual(@as(usize, 0), it.next().?.start);
    try testing.expectEqual(@as(usize, 2), it.next().?.start);
    try testing.expectEqual(@as(usize, 5), it.next().?.start);
    try testing.expect(it.next() == null);
}

test "findAll terminates on empty matches (one per code_point + end)" {
    var prog = MockLiteral.Program{ .needle = "" }; // matches empty everywhere
    var s = MockLiteral.Scratch{};
    try testing.expectEqual(@as(usize, 3), E.count(&prog, &s, "ab", .{})); // at 0,1,2
}

test "captures: whole match + (mock) group 1, with slot reset" {
    var prog = MockLiteral.Program{ .needle = "bc" };
    var s = MockLiteral.Scratch{};
    var slots: [4]?usize = .{ 999, 999, 999, 999 }; // pre-dirtied → must be reset to null
    const meta = Meta{ .capture_count = 1 };
    const c = E.captures(&prog, &s, "abc", &slots, meta, .{}).?;
    try testing.expectEqualStrings("bc", c.match().slice("abc"));
    try testing.expectEqualStrings("bc", c.groupSlice(1).?);
    try testing.expect(c.group(2) == null); // beyond capture_count → null, not stale 999
    try testing.expect(E.captures(&prog, &s, "zzz", &slots, meta, .{}) == null);
}

test "capturesAll iterates groups" {
    var prog = MockLiteral.Program{ .needle = "x" };
    var s = MockLiteral.Scratch{};
    var slots: [2]?usize = undefined;
    var it = E.capturesAll(&prog, &s, "axbxc", &slots, .{ .capture_count = 0 }, .{});
    try testing.expectEqualStrings("x", it.next().?.match().slice("axbxc"));
    try testing.expectEqualStrings("x", it.next().?.match().slice("axbxc"));
    try testing.expect(it.next() == null);
}

test "named capture lookup (hand-built view, no backend needed)" {
    const input = "2026-06";
    var slots = [_]?usize{ 0, 7, 0, 4, 5, 7 }; // whole, group1=year, group2=month
    const names = [_]?[]const u8{ null, "year", "month" };
    const c = Captures{ .slots = &slots, .meta = .{ .capture_count = 2, .group_names = &names }, .input = input };
    try testing.expectEqualStrings("2026", c.namedSlice("year").?);
    try testing.expectEqualStrings("06", c.namedSlice("month").?);
    try testing.expect(c.named("day") == null);
}

test "split on a separator" {
    var prog = MockLiteral.Program{ .needle = "," };
    var s = MockLiteral.Scratch{};
    var it = E.split(&prog, &s, "a,bb,,c", .{});
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("bb", it.next().?);
    try testing.expectEqualStrings("", it.next().?); // empty field between ",,"
    try testing.expectEqualStrings("c", it.next().?);
    try testing.expect(it.next() == null);
}

test "replaceAll with $ template expansion" {
    var prog = MockLiteral.Program{ .needle = "bc" };
    var s = MockLiteral.Scratch{};
    var slots: [4]?usize = undefined;
    const meta = Meta{ .capture_count = 1 };
    var buf: [64]u8 = undefined;

    var w = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&prog, &s, "abcabc", "<$0>", &slots, meta, &w);
    try testing.expectEqualStrings("a<bc>a<bc>", w.buffered());

    var w2 = std.Io.Writer.fixed(&buf);
    try E.replaceAll(&prog, &s, "abc", "[$1|$$]", &slots, meta, &w2);
    try testing.expectEqualStrings("a[bc|$]", w2.buffered());
}

test {
    testing.refAllDecls(@This());
}
