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
//! backend, fully inlined. See `docs/architecture.md` §4 (the backend contract).
//!
//! This file depends only on `std` — it is the stable seam between `core/` (which
//! produces the HIR) and the backends (which consume it). The HIR itself appears
//! only in a backend's `build*` signatures, not here.
//!
//! ══════════════════════════════════════════════════════════════════════════════
//! USAGE GUIDE
//! ══════════════════════════════════════════════════════════════════════════════
//!
//! ## The two roles
//!
//! 1. **Backend author** — implement a `type` satisfying the contract below. The job
//!    is narrow: turn a `Hir` into a `Program`, and locate a match / fill a `slots`
//!    array. You write NO iteration, capture-view, or replace code.
//! 2. **Backend user** — pick a backend and drive it, either through the front door
//!    (`engine/regex.zig` → `Compiled`) or directly via `Engine(Backend)`.
//!
//! ## The contract (what a backend `type` must expose)
//!
//! MANDATORY (checked by `verifyBackend`):
//!
//! ```zig
//! pub const caps: Caps; //     comptime capabilities (captures? stateless? grapheme?)
//! pub const Program: type; //  the executable form — slices/POD only (ro_data- or heap-able)
//! pub const Scratch: type; //  per-search state TYPE (use `struct{}` if stateless)
//! pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, o: SearchOptions) bool;
//! // …and AT LEAST ONE build path:
//! pub fn buildAlloc(allocator, hir: Hir, opts) BuildError!Program; //  → heap
//! pub fn buildComptime(comptime hir: Hir, comptime opts) Program; //   → ro_data
//! ```
//!
//! OPTIONAL (used only behind `@hasDecl` — a hard error only when actually called):
//!
//! ```zig
//! pub fn search(program, scratch, input, o) ?Match; //                       find/findAll/split/replace
//! pub fn searchCaptures(program, scratch, input, slots: []?usize, o) ?Match; // if caps.captures
//! pub fn freeProgram(allocator, program) void; //                            if you buildAlloc
//! // Scratch lifecycle (the caller constructs it, ArrayList-style):
//! pub fn Scratch.init(allocator, program) ScratchError!Scratch;
//! pub fn Scratch.initBuffer(buf: []Buf, program) ScratchError!Scratch; //    fixed buffer → comptime-able
//! pub fn Scratch.reset(self) void;
//! pub fn Scratch.deinit(self, allocator) void;
//! ```
//!
//! `Engine(Backend)` then implements `find`/`findAll`/`captures`/`capturesAll`/
//! `count`/`split`/`replaceAll` on top of `search`/`searchCaptures` — once, for any
//! backend (see `Engine` and `Captures` below for step-by-step usage).
//!
//! ## Driving a backend (user side)
//!
//! ```zig
//! comptime verifyBackend(B); //                assert the contract at compile time
//! const E = Engine(B); //                       the agnostic op layer for B
//! var program = try B.buildAlloc(gpa, h, .{}); // Hir → Program (self-contained; free the Hir now)
//! defer B.freeProgram(gpa, &program);
//! var sc = try B.Scratch.init(gpa, &program); // the caller OWNS the Scratch (one per thread)
//! defer sc.deinit(gpa);
//! _ = E.find(&program, &sc, input, .{}); //     …and every other op
//! ```
//!
//! ## Invariants a backend MAY rely on (the contract's fine print)
//!
//!   * `CodePoint` is a contract: HIR literals / range bounds are valid scalars.
//!   * HIR ranges are sorted, merged, non-overlapping, POSITIVE (negation already
//!     applied); a `class` with `len == 0` is unmatchable, not a wildcard.
//!   * The `Program` is self-contained after build — copy out what you need; the
//!     caller frees the HIR immediately. Keep the `Program` immutable + shareable.
//!   * ALL mutable per-search state lives in the caller-owned `Scratch`; reset it at
//!     the top of each search (the built-ins do this in O(1) via generation stamps).
//!   * `slots` length is `2 * (capture_count + 1)`; write only what fits and leave
//!     the rest untouched (`Engine` pre-zeroes them to `null`).
//!
//! See `docs/architecture.md` §4–§5 and §9, and `docs/usage-guide.md`, for the full
//! treatment and a complete, runnable example backend.

const std = @import("std");

const utils = @import("utils");
const utf8 = utils.unicode.utf8;

// ── Shared value types ──────────────────────────────────────────────────────────

/// A match span, as half-open BYTE offsets `[start, end)` into the input. Returned
/// by `find`/`search`, yielded by `MatchIterator`, and carried by `Captures.group`.
/// Offsets are byte indices (not code points) and always land on UTF-8 boundaries.
///
/// ```zig
/// const input = "x a@b y";
/// const m = re.find(&sc, input).?; //  locate the first match
/// _ = m.slice(input); //               "a@b" — the matched substring
/// _ = m.len(); //                      3      — end - start, in bytes
/// _ = m.isEmpty(); //                  false  — true only for a zero-width match
/// ```
///
/// @stable-since: v0.1.0
pub const Match = struct {
    /// Byte offset where the match begins (inclusive).
    start: usize,
    /// Byte offset where the match ends (exclusive). `end == start` ⇒ an empty match.
    end: usize,
    /// Which pattern produced this match — for the (future) multi-pattern / set API.
    /// **Reserved:** always `0` today (single-pattern). It is threaded through the
    /// public surface now so adding a set API later does not change `Match`'s shape.
    /// Defaulted, so every existing `Match{ .start, .end }`
    /// literal keeps compiling unchanged.
    ///
    /// @stable-since: v0.2.0
    pattern: u32 = 0,

    /// @stable-since: v0.1.0
    pub fn slice(self: Match, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
    /// @stable-since: v0.1.0
    pub fn len(self: Match) usize {
        return self.end - self.start;
    }
    /// @stable-since: v0.1.0
    pub fn isEmpty(self: Match) bool {
        return self.start == self.end;
    }
};

/// Where/how a single search runs. Passed to every `Engine` op and to a backend's
/// `search`/`isMatch`/`searchCaptures` primitives.
///
/// ```zig
/// _ = E.find(&prog, &sc, input, .{}); //                     default: scan from offset 0
/// _ = E.find(&prog, &sc, input, .{ .start = 10 }); //        resume the scan from byte 10
/// _ = E.find(&prog, &sc, input, .{ .anchored = true }); //   must match AT start; no scan
/// _ = E.find(&prog, &sc, input, .{ .start = 10, .anchored = true }); // exactly at byte 10
/// ```
///
/// @stable-since: v0.1.0
pub const SearchOptions = struct {
    /// Byte offset at which to begin the search (and, when `anchored`, the ONLY
    /// position tried). Must be ≤ `input.len`.
    start: usize = 0,
    /// When true the match must begin EXACTLY at `start` — no leftward/rightward
    /// scan. Used to confirm a prefilter hit or to walk anchored matches by hand.
    anchored: bool = false,
    /// Upper bound for the search: no match may end past this byte offset, and the
    /// engine never looks past it. `null` ⇒ end of input. Must be ≥ `start`
    /// (a `span_end < start` simply yields no match). Lets you search a sub-range
    /// without copying. The agnostic `Engine` ops enforce it by clamping the
    /// haystack, so backends never see it; returned offsets still index the full
    /// `input`.
    span_end: ?usize = null,
    /// Return as soon as ANY match is found rather than pursuing a longer/leftmost
    /// one. The built-in leftmost-first engines already return the leftmost match
    /// (and `isMatch` already short-circuits), so this is currently a no-op for
    /// them; it is reserved for an engine with a distinct earliest-match mode (e.g.
    /// a future byte DFA).
    earliest: bool = false,
};

/// Budget/behaviour hints a backend may accept when its `Scratch` is constructed.
/// Backends with no growable part (e.g. the Pike VM) ignore these; only a lazy-DFA
/// memo consults them. `grow` is impossible for a fixed-buffer `Scratch.initBuffer`.
///
/// @stable-since: v0.1.0
pub const ScratchOptions = struct {
    /// Soft ceiling on a growable `Scratch`'s memory, in bytes. Consulted only by a
    /// backend with a growable part (e.g. a lazy-DFA memo); fixed backends ignore it.
    max_bytes: usize = 1 << 20,
    /// What to do when a growable `Scratch` reaches `max_bytes`: `reset` (clear and
    /// continue, the default), `give_up` (fail the search), or `grow` (allocate
    /// more — impossible for a fixed-buffer `Scratch.initBuffer`).
    on_full: enum { reset, give_up, grow } = .reset,
};

/// What a backend can do (comptime). The dispatcher/front door reads these to route
/// and to gate capability-specific methods (e.g. `captures` is a `@compileError` on
/// a backend whose `caps.captures == false`). A backend declares it as a `const`:
///
/// ```zig
/// // a captures-capable, stateful, non-grapheme backend:
/// pub const caps = backend.Caps{ .captures = true };
/// // a stateless substring matcher (whole-match captures only):
/// pub const caps = backend.Caps{ .captures = true, .stateless = true };
/// ```
///
/// @stable-since: v0.1.0
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
/// alongside a `Program`. The backend does not need this — only the agnostic capture
/// view does (to size the `slots` array and resolve group names). You build one from
/// a HIR and pass it to every capture op:
///
/// ```zig
/// const meta = backend.Meta{ .capture_count = h.capture_count };   // names optional
/// const slots = try gpa.alloc(?usize, meta.slotLen());             // 2*(groups+1)
/// defer gpa.free(slots);
/// const caps = E.captures(&prog, &sc, input, slots, meta, .{}).?;  // resolve group 0..N
/// _ = caps.groupSlice(1);                                          // text of group 1
/// ```
///
/// @stable-since: v0.1.0
pub const Meta = struct {
    /// Number of capturing groups, excluding the whole match (group 0).
    capture_count: u32 = 0,
    /// `group_names[g]` is the name of group `g`, or `null`. Length, when present,
    /// is `capture_count + 1` (index 0 — the whole match — is always `null`).
    /// Empty means "no named groups".
    group_names: []const ?[]const u8 = &.{},

    /// Required `slots` length for `searchCaptures`: two offsets per group + the
    /// whole match.
    ///
    /// @stable-since: v0.1.0
    pub fn slotLen(self: Meta) usize {
        return 2 * (self.capture_count + 1);
    }
};

/// Suggested error sets (backends may use their own supersets).
///
/// @stable-since: v0.1.0
pub const BuildError = error{ PatternTooComplex, Unsupported } || std.mem.Allocator.Error;
/// @stable-since: v0.1.0
pub const ScratchError = error{ BufferTooSmall, Unsupported } || std.mem.Allocator.Error;

// ── OPTIONAL shared scratch helpers (NOT part of the contract) ────────────────────
//
// `Cell`/`Carver` are a convenience the *built-in* backends (pikevm, literal,
// backtrack, auto) opt into; they are **not** required by the contract and
// `verifyBackend` never checks for them. A third-party backend is free to use ANY
// `Scratch` representation it likes — an `ArrayList`, a fixed struct, nothing at
// all — with whatever `init`/`initBuffer` signatures it chooses (or none). The
// front door only ever reaches for these behind `@hasDecl`, so a backend that
// omits them still works; it simply doesn't get the buffer/comptime convenience.

/// One word of scratch storage used by the built-in backends, so a SINGLE typed
/// `[]Cell` buffer can back all of a backend's working arrays — and so `auto` can
/// hand the same buffer to whichever sub-backend it selects. A **bare union**:
/// integer/pc/bitset words live in `.w`, capture offsets in `.slot` (a natural
/// `?usize`, no sentinel). Each region only ever touches one field, keeping the
/// untagged access well-defined.
///
/// Why a homogeneous typed buffer rather than a `[]u8` arena: carving it is plain
/// slicing (`buf[a..b]`) with **no pointer reinterpretation**, so the same
/// `initBuffer` code runs at **comptime** — a caller writes `var buf: [N]Cell` —
/// as at runtime. A `[]u8` arena cannot: `@ptrCast`/`@intFromPtr` are runtime-only.
/// The built-in backends therefore expose, **by convention** (gated, not enforced):
///   * `pub const Buf = Cell;`            — the buffer element type
///   * `pub fn bufferLen(program) usize;` — words a buffer must hold
///   * `pub fn initBuffer(buf: []Buf, program) ScratchError!Scratch;`
///
/// @stable-since: v0.1.0
pub const Cell = union {
    /// A plain machine word — a pc, counter, bitset word, or stack entry. The field
    /// every region except capture slots reads/writes.
    w: usize,
    /// A capture offset: a natural `?usize`, so "not captured" is just `null` (no
    /// sentinel). The field a capture-slot region reads/writes.
    slot: ?usize,
};

/// A bump-carver that slices a `[]Cell` buffer into typed sub-arrays. Pure slicing,
/// so it runs at comptime as well as runtime; a short buffer yields
/// `error.BufferTooSmall` (the "with limits" failure mode), never UB. A backend's
/// `initBuffer` uses it to lay several working arrays over one caller buffer:
///
/// ```zig
/// // inside your backend, given `buf: []backend.Cell` sized by `bufferLen`:
/// pub fn initBuffer(buf: []backend.Cell, p: *const Program) backend.ScratchError!Scratch {
///     var c = backend.Carver{ .buf = buf };
///     const visited = try c.take(p.insts.len); //  []Cell for a pc bitset (read as .w)
///     const stack   = try c.take(p.insts.len); //  []Cell for a work stack  (read as .w)
///     const slots   = try c.take(p.slot_count); // []Cell for captures      (read as .slot)
///     return .{ .visited = visited, .stack = stack, .slots = slots };
/// }
/// ```
///
/// @stable-since: v0.1.0
pub const Carver = struct {
    /// The caller-owned buffer being carved. The Carver only sub-slices it; it never
    /// writes through it.
    buf: []Cell,
    /// Bump cursor — index of the next free `Cell`. Starts at 0; each `take(n)`
    /// advances it by `n`.
    off: usize = 0,
    /// @stable-since: v0.1.0
    pub fn take(self: *Carver, n: usize) ScratchError![]Cell {
        const end = self.off + n;
        if (end > self.buf.len) return error.BufferTooSmall;
        const out = self.buf[self.off..end];
        self.off = end;
        return out;
    }
};

// ── A resolved set of captures (backend-agnostic view over `slots`) ──────────────

/// A read-only view of ONE match's captures. Holds only the caller's `slots` buffer,
/// the `Meta`, and the `input`, so it is identical for every backend. Borrows `slots`
/// and `input`: it is valid only until the `slots` buffer is reused (e.g. the next
/// `CaptureIterator.next()` overwrites it).
///
/// Step by step:
///
/// ```zig
/// // 1) size + allocate the slot array from the regex's capture count:
/// const slots = try gpa.alloc(?usize, re.slotCount()); // 2 * (capture_count + 1)
/// defer gpa.free(slots);
///
/// // 2) resolve the first match's captures into `slots`:
/// const caps = re.captures(&sc, slots, "2026-06-08") orelse return; // null ⇒ no match
///
/// // 3) read groups. Group 0 is the whole match; 1..N are the parens, left to right.
/// const whole = caps.match(); //      Match for the entire match (group 0)
/// _ = caps.count(); //                number of groups, incl. group 0
/// if (caps.group(1)) |m| _ = m; //    Match for group 1, or null if it didn't participate
/// _ = caps.groupSlice(1); //          the TEXT of group 1 (?[]const u8), or null
///
/// // 4) named groups (?<name>…), by name:
/// _ = caps.named("year"); //          ?Match
/// _ = caps.namedSlice("year"); //     ?[]const u8
/// _ = whole;
/// ```
///
/// A non-participating group (e.g. the unmatched side of `(a)|(b)`) reads back as
/// `null`, never as stale data — `Engine` zeroes `slots` before each search.
///
/// @stable-since: v0.1.0
pub const Captures = struct {
    /// The resolved capture offsets: `slots[2*g]` / `slots[2*g + 1]` are group `g`'s
    /// start/end byte offsets, or `null` if the group did not participate. Borrowed.
    slots: []const ?usize,
    /// Group count + name table for this regex (drives `count` and named lookups).
    meta: Meta,
    /// The input the offsets index into; the backing for `groupSlice`/`namedSlice`.
    /// Borrowed — keep it alive while you read slices from this view.
    input: []const u8,

    /// The whole match (group 0).
    ///
    /// @stable-since: v0.1.0
    pub fn match(self: Captures) Match {
        return self.group(0).?;
    }
    /// Number of slots' worth of groups (whole match + capture groups).
    ///
    /// @stable-since: v0.1.0
    pub fn count(self: Captures) usize {
        return self.meta.capture_count + 1;
    }
    /// Group `i` (0 = whole match), or null if it did not participate.
    ///
    /// @stable-since: v0.1.0
    pub fn group(self: Captures, i: usize) ?Match {
        const lo = i * 2;
        if (lo + 1 >= self.slots.len) return null;
        const s = self.slots[lo] orelse return null;
        const e = self.slots[lo + 1] orelse return null;
        return .{ .start = s, .end = e };
    }
    /// The text of group `i`, or null.
    ///
    /// @stable-since: v0.1.0
    pub fn groupSlice(self: Captures, i: usize) ?[]const u8 {
        return if (self.group(i)) |m| m.slice(self.input) else null;
    }
    /// The group with the given name, or null (no such name, or didn't participate).
    ///
    /// @stable-since: v0.1.0
    pub fn named(self: Captures, name: []const u8) ?Match {
        for (self.meta.group_names, 0..) |gn, g| {
            if (gn) |n| {
                if (std.mem.eql(u8, n, name)) return self.group(g);
            }
        }
        return null;
    }
    /// The text of the named group, or null.
    ///
    /// @stable-since: v0.1.0
    pub fn namedSlice(self: Captures, name: []const u8) ?[]const u8 {
        return if (self.named(name)) |m| m.slice(self.input) else null;
    }
};

// ── Contract verification ────────────────────────────────────────────────────────

/// Comptime-assert that `B` satisfies the **mandatory** (Lean) contract, with clear
/// errors. Everything beyond this is optional and `@hasDecl`-gated at the call site —
/// a missing optional decl errors only when actually used. Call it once (a `test`, or
/// the top of `Engine`) so a contract mistake is a precise compile error, not a
/// confusing failure deep in a generic op:
///
/// ```zig
/// test "MyBackend satisfies the contract" {
///     comptime backend.verifyBackend(MyBackend); // compiles ⇒ pass
/// }
/// ```
///
/// @stable-since: v0.1.0
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

/// `Engine(Backend)` is the namespace of regex operations specialized to a backend:
/// `isMatch`, `find`, `findAll`, `captures`, `capturesAll`, `count`, `split`,
/// `replaceAll`. It implements ALL of them ONCE, generically, on top of just the
/// backend's two primitives (`search` / `searchCaptures`) — so a backend writes no
/// iteration, capture-view, or template code. The front door (`Compiled`) is a thin
/// wrapper over this; reach for `Engine` directly to drive a chosen backend WITHOUT
/// the wrapper (e.g. in a backend's own tests).
///
/// ```zig
/// const B = gex.engine.backends.pikevm; // any backend type
/// const E = backend.Engine(B); //         specialize the op layer to it
///
/// // build a Program (HIR → program) and a caller-owned Scratch:
/// var program = try B.buildAlloc(gpa, h, .{});
/// defer B.freeProgram(gpa, &program);
/// var sc = try B.Scratch.init(gpa, &program);
/// defer sc.deinit(gpa);
/// const meta = backend.Meta{ .capture_count = h.capture_count };
///
/// // every op takes (program, scratch, input, …):
/// _ = E.isMatch(&program, &sc, input, .{});
/// if (E.find(&program, &sc, input, .{})) |m| _ = m.slice(input);
/// var it = E.findAll(&program, &sc, input, .{}); //   iterate non-overlapping matches
/// while (it.next()) |m| _ = m;
/// var slots: [8]?usize = undefined; //                2 * (capture_count + 1)
/// var ci = E.capturesAll(&program, &sc, input, &slots, meta, .{});
/// while (ci.next()) |c| _ = c.groupSlice(1);
/// ```
///
/// `find`/`findAll`/`split`/`replaceAll` require the backend's `search`; the capture
/// ops and `replaceAll` additionally require `caps.captures == true` — otherwise a
/// compile error names the offending backend.
///
/// @stable-since: v0.1.0
pub fn Engine(comptime Backend: type) type {
    comptime verifyBackend(Backend);
    return struct {
        pub const B = Backend;
        pub const Program = Backend.Program;
        pub const Scratch = Backend.Scratch;
        pub const supports_captures = Backend.caps.captures;

        /// Clamp the haystack to `opts.span_end` (the upper search bound). Backends
        /// never see `span_end`; the agnostic layer enforces it by shortening the
        /// input here. Offsets stay 0-based, so a returned `Match` indexes the
        /// original `input` too. `span_end < start` ⇒ an empty range ⇒ no match.
        fn clampHaystack(input: []const u8, opts: SearchOptions) []const u8 {
            const end = if (opts.span_end) |e| @min(e, input.len) else input.len;
            return input[0..end];
        }

        // ── single-shot ─────────────────────────────────────────────────────────

        pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) bool {
            return Backend.isMatch(program, scratch, clampHaystack(input, opts), opts);
        }

        pub fn find(program: *const Program, scratch: *Scratch, input: []const u8, opts: SearchOptions) ?Match {
            if (comptime !@hasDecl(Backend, "search"))
                @compileError("backend `" ++ @typeName(Backend) ++ "` has no `search` (find/findAll/split/replaceAll need it)");
            return Backend.search(program, scratch, clampHaystack(input, opts), opts);
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
            const hay = clampHaystack(input, opts);
            @memset(slots, null);
            _ = Backend.searchCaptures(program, scratch, hay, slots, opts) orelse return null;
            return .{ .slots = slots, .meta = meta, .input = hay };
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
            return .{ .program = program, .scratch = scratch, .input = clampHaystack(input, opts), .pos = opts.start, .anchored = opts.anchored };
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
                .input = clampHaystack(input, opts),
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
    // `codePointLenLossy` returns the lead byte's optimistic length (1–4), or 0
    // for an invalid lead byte — map that to a 1-byte advance.
    const len = utf8.codePointLenLossy(input[i]);
    return i + (if (len == 0) 1 else @as(usize, len));
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
