//! ezi_gex with no operating system: the wasm and bare-metal demo.
//!
//! `zig build freestanding` builds this file for `wasm32-freestanding` as a `.wasm` module, and
//! as a static library for bare-metal `aarch64`, `riscv64` and Cortex-M4 `thumb`. It also builds
//! `main.zig`, the full demo, for `wasm32-wasi`. Everything lands in `zig-out/freestanding/`.
//!
//! Nothing here touches an OS, libc or a heap. The two kinds of regex show the two ways to run
//! without one:
//!
//! - **Comptime** (`iso_date`, `words`): the pattern is compiled during the build and the
//!   program stored in the binary's read-only data. A search needs only a scratch, which is a
//!   stack array. There is no allocator anywhere.
//! - **Runtime** (`ezi_compile`): the host supplies the pattern, which is compiled into a fixed
//!   arena (a `FixedBufferAllocator` over a static buffer). The scratch and capture slots are
//!   carved from the same arena at compile time, so a search never allocates.
//!
//! The `ezi_*` exports are a C ABI, so a JavaScript page, a WASI runtime and C firmware all
//! drive them the same way: copy bytes into `ezi_pattern_buffer()` or `ezi_input_buffer()`,
//! then pass the length. Offsets are bytes into the input buffer. From JavaScript:
//!
//! ```js
//! const { instance } = await WebAssembly.instantiate(wasmBytes);
//! const ezi = instance.exports;
//! const put = (ptr, text) => {
//!   const bytes = new TextEncoder().encode(text);
//!   new Uint8Array(ezi.memory.buffer, ptr, bytes.length).set(bytes);
//!   return bytes.length;
//! };
//! ezi.ezi_compile(put(ezi.ezi_pattern_buffer(), "(\\w+)@(\\w+)")); // 0 or 1: compiled
//! const len = put(ezi.ezi_input_buffer(), "mail bob@example now");
//! if (ezi.ezi_captures(len, 0) === 1) {
//!   console.log(ezi.ezi_group_start(1), ezi.ezi_group_end(1)); // 5 8 ("bob")
//! }
//! ezi.ezi_iso_date(put(ezi.ezi_input_buffer(), "2026-10-03")); // 20261003
//! ```

const std = @import("std");
const gex = @import("ezi_gex");

// ── Return codes ──────────────────────────────────────────────────────────────

/// `ezi_compile` succeeded with the byte DFA, `auto`'s fastest span engine.
const ok: i32 = 0;
/// `ezi_compile` succeeded without the byte DFA, because its tables did not fit in the arena.
/// The NFA engines that remain are slower but still linear-time.
const ok_nfa_only: i32 = 1;
/// A search found a match, or did not.
const found: i32 = 1;
const not_found: i32 = 0;
/// A length is past its buffer's capacity, or `start` is past the input.
const err_bounds: i32 = -1;
/// The pattern is malformed or unsupported; `ezi_error_start`/`ezi_error_end` give the span.
const err_invalid: i32 = -2;
/// The pattern needs more memory than the arena holds, or exceeds a size limit.
const err_too_large: i32 = -3;
/// A runtime search before any successful `ezi_compile`.
const err_no_regex: i32 = -4;

// ── Static memory ─────────────────────────────────────────────────────────────

/// Bytes in the arena a runtime regex is compiled into. An arena never frees, so it must hold the
/// compile's temporaries as well as the result. Any pattern takes about 400 KB, mostly the class
/// scratch the HIR builder allocates up front. An ASCII pattern with its DFA fits in 1 MiB. With
/// a Unicode class (`\w`, `\p{L}`) the DFA needs 4–5 MB, so `ezi_compile` falls back to the NFA
/// engines, which fit. On a microcontroller with less RAM, use comptime regexes, which need no
/// arena, and shrink or drop this one.
pub const arena_size = 1024 * 1024;

var arena_mem: [arena_size]u8 align(16) = undefined;
var arena: std.heap.FixedBufferAllocator = .init(&arena_mem);

var pattern_buf: [4 * 1024]u8 = undefined;
var input_buf: [64 * 1024]u8 = undefined;

/// The runtime regex and its search state; all three live in `arena`.
var regex: gex.Regex = undefined;
var scratch: gex.Scratch = undefined;
var slots: []?usize = &.{};
var compiled = false;

/// The faulty byte span of the last pattern `ezi_compile` rejected.
var error_span: [2]usize = .{ 0, 0 };

// ── Buffers the host writes into ──────────────────────────────────────────────

export fn ezi_pattern_buffer() [*]u8 {
    return &pattern_buf;
}

export fn ezi_pattern_capacity() usize {
    return pattern_buf.len;
}

export fn ezi_input_buffer() [*]u8 {
    return &input_buf;
}

export fn ezi_input_capacity() usize {
    return input_buf.len;
}

// ── Runtime regex ─────────────────────────────────────────────────────────────

/// Compile the first `pattern_len` bytes of the pattern buffer, replacing the previous runtime
/// regex. Returns 0, 1 (compiled without the byte DFA to fit the arena), `-1` (longer than the
/// buffer), `-2` (malformed) or `-3` (too large even without the DFA). The regex keeps its own
/// copy of what it needs, so the host may reuse the pattern buffer.
export fn ezi_compile(pattern_len: usize) i32 {
    if (pattern_len > pattern_buf.len) return err_bounds;
    const pattern = pattern_buf[0..pattern_len];
    const status = compileInto(pattern, .{});
    if (status != err_too_large) return status;
    const nfa_status = compileInto(pattern, .{ .strategy = .{ .byte_engine = .disabled } });
    return if (nfa_status == ok) ok_nfa_only else nfa_status;
}

fn compileInto(pattern: []const u8, comptime opts: gex.Options) i32 {
    compiled = false;
    arena.reset(); // frees the previous regex, its scratch and its slots in one go
    const a = arena.allocator();
    var diag: gex.Diagnostic = .{};
    regex = gex.compileRuntime(a, pattern, &diag, opts) catch |err| switch (err) {
        error.InvalidPattern => {
            error_span = .{ diag.span.start, diag.span.end };
            return err_invalid;
        },
        error.Unsupported => {
            error_span = .{ 0, pattern.len };
            return err_invalid;
        },
        error.OutOfMemory, error.PatternTooComplex => return err_too_large,
    };
    const buf = a.alloc(gex.Scratch.Buf, regex.scratchBufferLen()) catch return err_too_large;
    scratch = regex.initScratchBuffer(buf) catch return err_too_large;
    slots = a.alloc(?usize, regex.slotCount()) catch return err_too_large;
    @memset(slots, null);
    compiled = true;
    return ok;
}

/// Start of the faulty span in the last pattern `ezi_compile` rejected with `-2`.
export fn ezi_error_start() usize {
    return error_span[0];
}

/// End (exclusive) of that span.
export fn ezi_error_end() usize {
    return error_span[1];
}

/// Capture groups in the runtime regex, not counting group 0 (the whole match), or `-4`.
export fn ezi_group_count() i32 {
    if (!compiled) return err_no_regex;
    return @intCast(slots.len / 2 - 1);
}

/// Leftmost match of the runtime regex in the first `input_len` input bytes, at or after byte
/// `start`. Returns 1 and records the span as group 0, 0 for no match, or `-1`/`-4`. Faster than
/// `ezi_captures` when only the span is needed.
export fn ezi_find(input_len: usize, start: usize) i32 {
    if (!compiled) return err_no_regex;
    const input = inputSlice(input_len, start) orelse return err_bounds;
    @memset(slots, null);
    const m = regex.findAt(&scratch, input, .{ .start = start }) orelse return not_found;
    slots[0] = m.start;
    slots[1] = m.end;
    return found;
}

/// Like `ezi_find`, but records every capture group.
export fn ezi_captures(input_len: usize, start: usize) i32 {
    if (!compiled) return err_no_regex;
    const input = inputSlice(input_len, start) orelse return err_bounds;
    if (regex.capturesAt(&scratch, slots, input, .{ .start = start }) == null) {
        @memset(slots, null);
        return not_found;
    }
    return found;
}

/// Start of `group` in the last match (group 0 is the whole match), or -1 if that group did
/// not take part, is out of range, or there was no match.
export fn ezi_group_start(group: usize) isize {
    return slotAt(group, 0);
}

/// End (exclusive) of `group` in the last match, or -1 as for `ezi_group_start`.
export fn ezi_group_end(group: usize) isize {
    return slotAt(group, 1);
}

/// Non-overlapping matches of the runtime regex in the first `input_len` input bytes, or
/// `-1`/`-4`.
export fn ezi_count(input_len: usize) i32 {
    if (!compiled) return err_no_regex;
    const input = inputSlice(input_len, 0) orelse return err_bounds;
    return @intCast(regex.count(&scratch, input));
}

fn inputSlice(input_len: usize, start: usize) ?[]const u8 {
    if (input_len > input_buf.len or start > input_len) return null;
    return input_buf[0..input_len];
}

fn slotAt(group: usize, end: usize) isize {
    if (!compiled or group >= slots.len / 2) return -1;
    const at = slots[2 * group + end] orelse return -1;
    return @intCast(at);
}

// ── Comptime regexes ──────────────────────────────────────────────────────────

/// An ISO 8601 calendar date. `[0-9]`, not `\d`: `\d` follows Unicode and also accepts other
/// scripts' digits, which the integer parse in `ezi_iso_date` can't read.
const iso_date = gex.compileComptime("^(?<year>[0-9]{4})-(?<month>0[1-9]|1[0-2])-(?<day>0[1-9]|[12][0-9]|3[01])$", .{});

/// Runs of Unicode letters.
const words = gex.compileComptime("\\p{L}+", .{});

// Checked while compiling: a wrong pattern fails the build, not the device.
comptime {
    std.debug.assert(iso_date.isMatchComptime("2026-10-03"));
    std.debug.assert(!iso_date.isMatchComptime("2026-13-03"));
    std.debug.assert(words.countComptime("Grüße, мир!") == 2);
}

/// The first `input_len` input bytes as an ISO date packed into `yyyymmdd` (`2026-10-03` gives
/// 20261003), -1 if they are not one, or `-1` past the buffer. The program was built at compile
/// time; this call allocates nothing and its scratch is a stack array.
export fn ezi_iso_date(input_len: usize) i32 {
    if (input_len > input_buf.len) return err_bounds;
    var buf: [iso_date.scratchBufferLen()]gex.Scratch.Buf = undefined;
    var sc = iso_date.initScratchBuffer(&buf) catch unreachable; // sized for exactly this program
    var date_slots: [iso_date.slotCount()]?usize = undefined;
    const c = iso_date.captures(&sc, &date_slots, input_buf[0..input_len]) orelse return -1;
    const year = std.fmt.parseInt(i32, c.namedSlice("year").?, 10) catch unreachable;
    const month = std.fmt.parseInt(i32, c.namedSlice("month").?, 10) catch unreachable;
    const day = std.fmt.parseInt(i32, c.namedSlice("day").?, 10) catch unreachable;
    return year * 10000 + month * 100 + day;
}

/// Runs of Unicode letters in the first `input_len` input bytes (`Grüße, мир!` has 2), or `-1`
/// past the buffer. Comptime-built, like `ezi_iso_date`.
export fn ezi_count_words(input_len: usize) i32 {
    if (input_len > input_buf.len) return err_bounds;
    var buf: [words.scratchBufferLen()]gex.Scratch.Buf = undefined;
    var sc = words.initScratchBuffer(&buf) catch unreachable;
    return @intCast(words.count(&sc, input_buf[0..input_len]));
}

// ── Tests (run natively: the exports are ordinary functions) ──────────────────

const testing = std.testing;

fn putPattern(text: []const u8) usize {
    @memcpy(pattern_buf[0..text.len], text);
    return text.len;
}

fn putInput(text: []const u8) usize {
    @memcpy(input_buf[0..text.len], text);
    return text.len;
}

test "runtime regex: find, captures, groups, count" {
    try testing.expectEqual(ok, ezi_compile(putPattern("(\\w+)@(\\w+)")));
    try testing.expectEqual(@as(i32, 2), ezi_group_count());

    const n = putInput("mail bob@example now, amy@site");
    try testing.expectEqual(found, ezi_captures(n, 0));
    try testing.expectEqual(@as(isize, 5), ezi_group_start(0));
    try testing.expectEqual(@as(isize, 16), ezi_group_end(0));
    try testing.expectEqual(@as(isize, 5), ezi_group_start(1));
    try testing.expectEqual(@as(isize, 8), ezi_group_end(1));
    try testing.expectEqual(@as(isize, 9), ezi_group_start(2));
    try testing.expectEqual(@as(isize, 16), ezi_group_end(2));
    try testing.expectEqual(@as(isize, -1), ezi_group_start(3)); // no such group

    // Resume past the first match; ezi_find records group 0 only.
    try testing.expectEqual(found, ezi_find(n, 16));
    try testing.expectEqual(@as(isize, 22), ezi_group_start(0));
    try testing.expectEqual(@as(isize, 30), ezi_group_end(0));
    try testing.expectEqual(@as(isize, -1), ezi_group_start(1));

    try testing.expectEqual(not_found, ezi_find(n, 30));
    try testing.expectEqual(@as(isize, -1), ezi_group_start(0));
    try testing.expectEqual(@as(i32, 2), ezi_count(n));
}

test "runtime regex: a group that does not take part reads -1" {
    try testing.expectEqual(ok, ezi_compile(putPattern("a(x)?(b)")));
    const n = putInput("ab");
    try testing.expectEqual(found, ezi_captures(n, 0));
    try testing.expectEqual(@as(isize, -1), ezi_group_start(1));
    try testing.expectEqual(@as(isize, -1), ezi_group_end(1));
    try testing.expectEqual(@as(isize, 1), ezi_group_start(2));
}

test "runtime regex: errors" {
    compiled = false;
    try testing.expectEqual(err_no_regex, ezi_find(0, 0));
    try testing.expectEqual(err_no_regex, ezi_captures(0, 0));
    try testing.expectEqual(err_no_regex, ezi_count(0));
    try testing.expectEqual(err_no_regex, ezi_group_count());
    try testing.expectEqual(@as(isize, -1), ezi_group_start(0));

    // A malformed pattern reports its faulty span, and leaves no regex behind.
    try testing.expectEqual(err_invalid, ezi_compile(putPattern("a(b|c[d-")));
    try testing.expectEqual(@as(usize, 5), ezi_error_start());
    try testing.expectEqual(@as(usize, 6), ezi_error_end());
    try testing.expectEqual(err_no_regex, ezi_find(0, 0));

    try testing.expectEqual(err_bounds, ezi_compile(pattern_buf.len + 1));
    try testing.expectEqual(ok, ezi_compile(putPattern("a")));
    try testing.expectEqual(err_bounds, ezi_find(input_buf.len + 1, 0));
    try testing.expectEqual(err_bounds, ezi_find(3, 4)); // start past the input
    try testing.expectEqual(found, ezi_find(putInput("bca"), 2));
    try testing.expectEqual(err_bounds, ezi_count(input_buf.len + 1));

    // A pattern bigger than the arena is refused, not a crash, and the next one still compiles.
    try testing.expectEqual(err_too_large, ezi_compile(putPattern("\\w{4000}")));
    try testing.expectEqual(ok, ezi_compile(putPattern("a+")));
    try testing.expectEqual(found, ezi_find(putInput("baa"), 0));
}

test "runtime regex: a pattern whose DFA overflows the arena compiles without it" {
    // `\p{L}`'s DFA tables need several MB, far over the 1 MiB arena; the NFA engines fit.
    try testing.expectEqual(ok_nfa_only, ezi_compile(putPattern("(\\p{L}+) (\\d+)")));
    const n = putInput("12 Grüße 2026!");
    try testing.expectEqual(found, ezi_captures(n, 0));
    try testing.expectEqual(@as(isize, 3), ezi_group_start(1));
    try testing.expectEqual(@as(isize, 10), ezi_group_end(1));
    try testing.expectEqual(@as(isize, 11), ezi_group_start(2));
    try testing.expectEqual(@as(isize, 15), ezi_group_end(2));
    // An ASCII pattern keeps its DFA.
    try testing.expectEqual(ok, ezi_compile(putPattern("[a-z]+ [0-9]+")));
}

test "runtime regex: each compile reuses the whole arena" {
    // Far more compiles than one arena could hold if earlier regexes were never freed.
    for (0..500) |_| try testing.expectEqual(ok, ezi_compile(putPattern("[a-z]+@[a-z]+")));
    try testing.expectEqual(found, ezi_find(putInput("x a@b"), 0));
    try testing.expectEqual(@as(isize, 2), ezi_group_start(0));
}

test "runtime regex: arena + buffer scratch agree with the heap Pike VM at every start" {
    const patterns = [_][]const u8{
        "a", "a+", "(a|ab)(c|bcd)", "\\w+", "\\b\\w+\\b", "[0-9]+(?:\\.[0-9]+)?", "(?i)straße",
        "\\p{Script=Greek}+", "x*", "^\\s*$", "(?m)^\\w+$",       "a.*?c",  "(\\w+)@(\\w+)",  "",
    };
    const inputs = [_][]const u8{
        "",          "a",               "abcd abcd",       "Grüße, мир! 3.14 and 42", "αβγ abc ΔΕ",
        "line one\nsecond\n\n", "STRASSE straße", "abc axxc", "bob@x a@b", "  \t ",
    };
    const gpa = testing.allocator;
    for (patterns) |pat| {
        try testing.expect(ezi_compile(putPattern(pat)) >= ok);
        var diag: gex.Diagnostic = .{};
        var ref = try gex.compileRuntimeWith(gex.backends.pikevm, gpa, pat, &diag, .{});
        defer ref.deinit();
        var ref_sc = try ref.initScratch(gpa);
        defer ref_sc.deinit(gpa);
        const ref_slots = try gpa.alloc(?usize, ref.slotCount());
        defer gpa.free(ref_slots);

        for (inputs) |text| {
            const n = putInput(text);
            try testing.expectEqual(@as(i32, @intCast(ref.count(&ref_sc, text))), ezi_count(n));
            for (0..n + 1) |start| {
                const want = ref.capturesAt(&ref_sc, ref_slots, text, .{ .start = start });
                try testing.expectEqual(@as(i32, if (want == null) not_found else found), ezi_captures(n, start));
                for (0..ref_slots.len / 2) |g| {
                    const ws: isize = if (want == null) -1 else if (ref_slots[2 * g]) |v| @intCast(v) else -1;
                    const we: isize = if (want == null) -1 else if (ref_slots[2 * g + 1]) |v| @intCast(v) else -1;
                    try testing.expectEqual(ws, ezi_group_start(g));
                    try testing.expectEqual(we, ezi_group_end(g));
                }
                try testing.expectEqual(@as(i32, if (want == null) not_found else found), ezi_find(n, start));
                if (want) |m| {
                    try testing.expectEqual(@as(isize, @intCast(m.match().start)), ezi_group_start(0));
                    try testing.expectEqual(@as(isize, @intCast(m.match().end)), ezi_group_end(0));
                }
            }
        }
    }
}

test "comptime regex: ISO dates" {
    try testing.expectEqual(@as(i32, 20261003), ezi_iso_date(putInput("2026-10-03")));
    try testing.expectEqual(@as(i32, 19991231), ezi_iso_date(putInput("1999-12-31")));
    try testing.expectEqual(@as(i32, 20000101), ezi_iso_date(putInput("2000-01-01")));
    try testing.expectEqual(@as(i32, -1), ezi_iso_date(putInput("2026-13-03"))); // month 13
    try testing.expectEqual(@as(i32, -1), ezi_iso_date(putInput("2026-10-32"))); // day 32
    try testing.expectEqual(@as(i32, -1), ezi_iso_date(putInput("2026-10-03 "))); // trailing byte
    try testing.expectEqual(@as(i32, -1), ezi_iso_date(putInput("２０２６-10-03"))); // fullwidth digits
    try testing.expectEqual(@as(i32, -1), ezi_iso_date(putInput("")));
    try testing.expectEqual(err_bounds, ezi_iso_date(input_buf.len + 1));
}

test "comptime regex: Unicode words" {
    try testing.expectEqual(@as(i32, 2), ezi_count_words(putInput("Grüße, мир!")));
    try testing.expectEqual(@as(i32, 3), ezi_count_words(putInput("αβγ 123 δ-ε")));
    try testing.expectEqual(@as(i32, 0), ezi_count_words(putInput("1 + 2 = 3")));
    try testing.expectEqual(@as(i32, 0), ezi_count_words(0));
    try testing.expectEqual(err_bounds, ezi_count_words(input_buf.len + 1));
}
