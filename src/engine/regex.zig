//! The front door: turn a pattern into a ready-to-use, backend-parametric regex.
//!
//! Two entry points, both returning the same `Compiled(Backend)` setup so callers
//! write the same code either way:
//!   * `compileRuntime(allocator, pattern, *Diagnostic)` — heap `Program`; on a
//!     bad pattern returns `error.InvalidPattern` and fills the diagnostic (no
//!     crash). Free with `re.deinit()`.
//!   * `compileComptime(pattern)` — `Program` baked into `ro_data`; a bad pattern
//!     is a `@compileError`. No allocator, no deinit.
//!
//! The compiled value exposes the user-facing API — `isMatch`, `find`, `captures`,
//! `findAll`, `capturesAll`, `count`, `split`, `replaceAll` — all delegating to the
//! backend-agnostic `Engine`. Per the contract, the **caller owns the `Scratch`**
//! and creates it at the call site — `var sc = try re.initScratch(alloc);` (or
//! `re.initScratchBuffer(buf)` for a no-allocator buffer); the regex methods take
//! `&sc`. `re.Scratch` is a thin front-door wrapper over the backend's own scratch
//! (`Compiled(B).Scratch` wraps `B.Scratch` in its `.inner` field); the older
//! spelling `@TypeOf(re).Scratch.init(alloc, &re.program)` still works. The default
//! backend is the `auto` dispatcher (`default_backend`), which picks literal /
//! backtrack / Pike VM from the pattern + input; pass a specific backend to the
//! `*With` constructors to override it.
//!
//! ══════════════════════════════════════════════════════════════════════════════
//! USAGE GUIDE
//! ══════════════════════════════════════════════════════════════════════════════
//!
//! ## Pick an entry point
//!
//!   * `compileRuntime(gpa, pattern, &diag, opts)` — heap-backed; a bad pattern is
//!     `error.InvalidPattern` + a filled `Diagnostic` (never a crash). `re.deinit()`.
//!   * `compileComptime(pattern, opts)` — baked into `ro_data`; a bad pattern is a
//!     `@compileError`. No allocator, no `deinit`.
//!   * `compileRuntimeWith(B, …)` / `compileComptimeWith(B, …)` — same, with an
//!     explicit backend `B` (`backends.pikevm` / `.backtrack` / `.literal` / `.auto`).
//!
//! ## Use it (runtime)
//!
//! ```zig
//! var diag: gex.Diagnostic = .{};
//! var re = try gex.compileRuntime(gpa, "\\d+", &diag, .{}); // .{} = default Options
//! defer re.deinit();
//! var sc = try re.initScratch(gpa); // caller-owned, per thread
//! defer sc.deinit(gpa);
//!
//! _ = re.isMatch(&sc, "abc123"); //          bool
//! _ = re.find(&sc, "abc123"); //             ?Match → "123"
//! var it = re.findAll(&sc, "a1 b22 c333"); // iterate non-overlapping matches
//! while (it.next()) |m| _ = m;
//! ```
//!
//! ## Use it (comptime — no allocator)
//!
//! ```zig
//! const re = comptime gex.compileComptime("\\d{3}-\\d{4}", .{});
//! // (a) match AT comptime — the result is a compile-time constant:
//! const ok = comptime re.isMatchComptime("call 555-1234"); // true
//! // (b) or match at RUNTIME with a buffer Scratch (still no allocator): the
//! //     regex is comptime-known, so `scratchBufferLen()` sizes a stack array.
//! var buf: [re.scratchBufferLen()]gex.Scratch.Buf = undefined;
//! var sc = try re.initScratchBuffer(&buf);
//! _ = re.find(&sc, "call 555-1234");
//! _ = ok;
//! ```
//!
//! See `Compiled` for the full method set incl. captures/replace, and
//! `docs/usage-guide.md` for a from-scratch tour (lexer → AST → HIR → backend).

const std = @import("std");

const core = @import("core");
const hir = core.hir;
const parser = core.compile;
const backend = @import("engine_base").backend;
const auto = @import("auto");
const simd = @import("engine_base").simd;

/// Re-export: a parse-failure report — error code + byte span + message + caret renderer.
pub const Diagnostic = parser.Diagnostic;
/// Re-export: a match span as half-open byte offsets (`backend.Match`).
pub const Match = backend.Match;
/// Re-export: a read-only view of one match's captures (`backend.Captures`).
pub const Captures = backend.Captures;

/// The default backend used by `compileRuntime`/`compileComptime`: the `auto`
/// dispatcher, which picks the literal / backtrack / Pike VM strategy from the
/// pattern's analysis and the input. Power users pass a specific backend to the
/// `*With` constructors instead.
///
/// @stable-since: v0.1.0
pub const default_backend = auto;

/// Errors from the full compile pipeline (parse → HIR → program).
///
/// @stable-since: v0.1.0
pub const Error = error{
    /// The pattern is malformed; see the `Diagnostic` for code + span.
    InvalidPattern,
    /// The pattern exceeds an internal size bound.
    PatternTooComplex,
    /// The chosen backend cannot handle a construct in the pattern (e.g. `\X`).
    Unsupported,
    OutOfMemory,
};

/// Pipeline settings, comptime-known on both paths (so the HIR shape and backend
/// can specialize). Every field has a default; pass `.{}` for all defaults or set
/// only what you need. These flow into the HIR builder (and, later, the backend).
///
/// @stable-since: v0.1.0
pub const Options = struct {
    /// How `(?i)` case-insensitivity is realized (`.none` / `.simple` / `.full`).
    /// See `hir.CaseFold` — `.full` adds the 1→many expansions (`ß`→`ss`).
    case_fold: hir.CaseFold = .simple,

    /// Seed the `i` flag (case-insensitive) for the WHOLE pattern, as if it began
    /// with `(?i)`. Inline flags still compose on top — a scoped `(?-i:…)` turns it
    /// back off within that group. Default off.
    case_insensitive: bool = false,
    /// Seed the `m` flag (multiline): `^`/`$` also match at line boundaries, as if
    /// the pattern began with `(?m)`. Default off.
    multiline: bool = false,
    /// Seed the `s` flag (dot-all): `.` also matches `\n`, as if the pattern began
    /// with `(?s)`. Default off.
    dot_matches_newline: bool = false,

    /// Unicode mode for `\d`/`\w`/`\s` (default `true`). Set `false` for the classic
    /// ASCII shorthand sets (`\d`=`[0-9]`, `\w`=`[0-9A-Za-z_]`, `\s`=`[ \t\n\v\f\r]`),
    /// which keeps automata small. Affects only the shorthand classes — `.` and `\b`
    /// stay code-point / Unicode-aware. See `hir.Options.unicode`.
    unicode: bool = true,

    /// Ceiling on a bounded-repetition count (`{m,n}`, `{m}`, `{m,}`). A finite
    /// bound past this is rejected **at scan time** with `error.InvalidPattern` and
    /// a `.quantifier_exceeds_limit` diagnostic (a `@compileError` on the comptime
    /// path) — a DoS guard so an absurd `a{900000000}` can't blow up the automaton.
    /// The default (`scanner.default_max_repetition`, 100_000) clears any realistic
    /// hand-written count; raise it for genuinely huge counts, lower it to harden
    /// against adversarial patterns. The hard u32 ceiling
    /// (`.quantifier_too_large`) still applies above whatever you set here.
    ///
    /// @stable-since: v0.5.0
    max_repetition: u32 = core.scanner.default_max_repetition,

    /// Ceiling on the pattern's EXPANDED size (`hir.expandedSize` — about one unit per
    /// code-point NFA instruction once counted repetitions are unrolled). `max_repetition`
    /// bounds each `{m,n}` count on its own; nested counts multiply —
    /// `(?:(?:a{1000}){1000}){1000}` unrolls to ~10⁹ copies — so this bounds the product.
    /// A pattern over it fails with `error.PatternTooComplex` (`diag.code =
    /// .pattern_too_complex`, spanning the whole pattern) or, on the comptime path, a
    /// `@compileError` — BEFORE any program is built, so rejecting costs O(pattern) time
    /// and no allocation proportional to the expansion. The default
    /// (`hir.default_size_limit`, 1 000 000) clears realistic patterns (`a{100000}`,
    /// `\p{L}{500}`) by a wide margin; lower it to harden a service that compiles
    /// untrusted patterns, raise it for genuinely huge unrolled programs.
    ///
    /// @stable-since: v0.8.0
    size_limit: u64 = hir.default_size_limit,

    /// Execution-strategy knobs. **Results-invariant by contract:** changing any
    /// field here may affect only speed/memory, never which text matches (the
    /// conformance suite fuzzes over them and pins the match). The byte engine wiring
    /// consults these at build; the shape is locked so growing it stays non-breaking.
    strategy: Strategy = .{},

    /// The strategy tier (see `strategy`). Kept physically separate from the semantic
    /// flags above so "these never change a match result" is a type-level boundary the
    /// conformance suite can fuzz over.
    ///
    /// @stable-since: v0.2.0
    pub const Strategy = struct {
        /// Byte lazy-DFA selection (runtime only — the DFA's cache mutates while
        /// matching, so the comptime path always stays on the code-point NFA):
        ///   * `.auto` (default) / `.enabled` — build the byte DFA on an eligible
        ///     pattern and use it for `isMatch`/`find` (one cached DFA state per byte;
        ///     5–9× the code-point engine on class scans, never slower) with captures
        ///     filled by the Pike VM anchored at the DFA span. **Results-invariant.**
        ///   * `.disabled` — the compact code-point NFA only (minimal memory, no
        ///     determinization cache; the right pick for match-once / tiny-input use).
        ///
        /// @stable-since: v0.3.0 (was inert before — now wired and on by default)
        byte_engine: enum { auto, enabled, disabled } = .auto,
        /// Bake full Unicode `\b` into the (future) byte-DFA state, vs. the default
        /// quit-to-NFA fallback. Currently inert (reserved).
        unicode_word_boundary_in_dfa: bool = false,
        /// Enable the sound literal/required-byte prefilter (`memchr` start-skip and
        /// fast-reject from the HIR `Analysis`). On by default; set `false` to force
        /// the engine to scan without it (benchmarking / pathological inputs where the
        /// prefilter's probe cost is not repaid).
        ///
        /// @stable-since: v0.3.0
        prefilter: bool = true,

        /// SIMD policy (a **permission, not a command**): `.auto` (default) uses the native
        /// dynamic-shuffle accelerator (Teddy) for literal-alternation scans where the build
        /// target supports it, falling back to the portable scan elsewhere; `.off` forces the
        /// portable/scalar path everywhere. There is no "force on" — a target without a native
        /// shuffle resolves to scalar regardless, so no setting yields a broken binary.
        /// Results-invariant (only speed changes). See `simd.SimdMode`.
        ///
        /// @stable-since: v0.4.0
        simd: simd.SimdMode = .auto,
    };

    /// Project these front-door options onto the HIR builder's options.
    fn toHir(self: Options) hir.Options {
        return .{ .case_fold = self.case_fold, .unicode = self.unicode };
    }

    /// Project these front-door options onto the scanner's scan-time limits.
    fn scanLimits(self: Options) core.scanner.Limits {
        return .{ .max_repetition = self.max_repetition };
    }

    /// The initial inline-flag state to seed the pattern with. OR-merged with any
    /// bare `(?…)` flags the pattern sets, so `Options` provides the defaults and
    /// inline flags add to them. (A bare `(?-i)` cannot remove an `Options` seed —
    /// set the option to `false` instead; scoped `(?-i:…)` groups still scope
    /// normally because they are applied during lowering, not to the global state.)
    fn initialFlags(self: Options) hir.Flags {
        return .{
            .case_insensitive = self.case_insensitive,
            .multiline = self.multiline,
            .dot_all = self.dot_matches_newline,
        };
    }
};

/// A compiled regex over backend `B`: an immutable `Program` + capture `Meta`.
/// Returned by `compileRuntime`/`compileComptime` (and the `*With` variants). This is
/// the front-door value type — `re.isMatch`/`find`/`captures`/`findAll`/`split`/
/// `replaceAll` live here and forward to `Engine(B)`.
///
/// Thread-safe to SHARE (immutable, `*const`-borrowed by every method); each thread
/// brings its OWN `Scratch`. Per the contract the caller owns the `Scratch`: make one
/// with `re.initScratch(gpa)` (heap) or `re.initScratchBuffer(buf)` (caller storage,
/// no allocator) and pass `&sc` to every search. `Compiled(B).Scratch` is a thin
/// wrapper around the backend's `B.Scratch` (see `Scratch`); the older spelling
/// `@TypeOf(re).Scratch.init(gpa, &re.program)` still works and yields the same type.
///
/// Step by step (runtime):
///
/// ```zig
/// // 1) compile (heap-backed; free with deinit). A bad pattern fills `diag`.
/// var diag: gex.Diagnostic = .{};
/// var re = try gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &diag, .{});
/// defer re.deinit();
///
/// // 2) make a Scratch — caller-owned, one per thread.
/// var sc = try re.initScratch(gpa);
/// defer sc.deinit(gpa);
///
/// // 3) use the API; pass &sc to each call.
/// _ = re.isMatch(&sc, "x a@b y"); //                       bool
/// if (re.find(&sc, "x a@b y")) |m| _ = m.slice("x a@b y"); // ?Match
/// _ = re.count(&sc, "a@b c@d"); //                         non-overlapping match count
///
/// // 4) captures: size the slot array with slotCount().
/// const slots = try gpa.alloc(?usize, re.slotCount());
/// defer gpa.free(slots);
/// if (re.captures(&sc, slots, "user@host")) |c| _ = c.groupSlice(1); // "user"
/// ```
///
/// Comptime (no allocator, no deinit): `const re = comptime compileComptime("\\d+", .{});`
/// then either use the runtime methods with a buffer `Scratch`
/// (`var buf: [re.scratchBufferLen()]gex.Scratch.Buf = undefined;` +
/// `re.initScratchBuffer(&buf)`), or the `*Comptime` methods that run the match
/// itself at compile time (`isMatchComptime`, `findComptime`, `capturesComptime`, …).
///
/// @stable-since: v0.1.0
pub fn Compiled(comptime B: type) type {
    const Eng = backend.Engine(B);
    return struct {
        const Self = @This();

        /// The per-search state type: the front-door **wrapper** over the backend's own
        /// `B.Scratch`, which lives in `.inner`. Make one with `re.initScratch(gpa)` /
        /// `re.initScratchBuffer(buf)`; every search method takes `*Scratch`.
        ///
        /// The wrapper exists so users never spell `@TypeOf(re)` or `&re.program`: it
        /// forwards the backend's lifecycle (`init`/`initBuffer`/`bufferLen`/`reset`/
        /// `deinit`) when the backend provides it and substitutes a sensible default
        /// when it doesn't (a stateless `struct{}` scratch needs none of them). The
        /// forwarders are trivial functions the optimizer inlines (zero cost in a
        /// release build); backends are unaware of the wrapper and `Engine(B)` still
        /// takes the raw `B.Scratch`.
        ///
        /// Escape hatches for code that drives `Engine(B)` or a backend directly:
        /// `&sc.inner` hands the raw backend scratch out, and `Scratch.fromBackend(raw)`
        /// wraps a backend scratch you built yourself (e.g. `dfa.Scratch.initOptions`
        /// with a custom cache budget).
        ///
        /// The pre-0.7 spelling `@TypeOf(re).Scratch.init(gpa, &re.program)` still
        /// compiles and yields this same type.
        ///
        /// @stable-since: v0.1.0 (a wrapper over `B.Scratch` since v0.7.0)
        pub const Scratch = struct {
            /// The backend's own per-search state — what `Engine(B)` and the backend's
            /// `search`/`isMatch` primitives take. Pass `&sc.inner` to those directly.
            /// (The default `auto` backend's scratch has a field of the same name for
            /// its routed sub-scratch, so a debugger shows `sc.inner.inner` there.)
            ///
            /// @stable-since: v0.7.0
            inner: B.Scratch,

            /// Buffer element type for `initBuffer` (the backend's `Scratch.Buf`, e.g.
            /// `backend.Cell` for the built-ins); `void` for a backend without the
            /// buffer convention.
            ///
            /// @stable-since: v0.1.0
            pub const Buf = if (@hasDecl(B.Scratch, "Buf")) B.Scratch.Buf else void;

            /// Heap-backed construction (`re.initScratch(gpa)` is the front-door form).
            /// Forwards `B.Scratch.init`; a backend whose scratch has no `init` is
            /// default-constructed (`.{}`). The error set is the backend's own.
            ///
            /// @stable-since: v0.1.0
            pub fn init(gpa: std.mem.Allocator, program: *const B.Program) !Scratch {
                if (comptime @hasDecl(B.Scratch, "init")) {
                    return .{ .inner = try B.Scratch.init(gpa, program) };
                } else {
                    return .{ .inner = .{} };
                }
            }

            /// Caller-buffer construction (`re.initScratchBuffer(buf)` is the front-door
            /// form): carve the scratch out of `buf`, which must hold at least
            /// `bufferLen(program)` words; no allocator, works at comptime. A backend
            /// without `initBuffer` makes this a `@compileError`.
            ///
            /// @stable-since: v0.1.0
            pub fn initBuffer(buf: []Buf, program: *const B.Program) backend.ScratchError!Scratch {
                if (comptime !@hasDecl(B.Scratch, "initBuffer"))
                    @compileError("backend `" ++ @typeName(B) ++ "`'s Scratch has no `initBuffer` (the buffer/no-allocator path needs Buf/bufferLen/initBuffer)");
                return .{ .inner = try B.Scratch.initBuffer(buf, program) };
            }

            /// How many `Buf` words `initBuffer` needs for `program`
            /// (`re.scratchBufferLen()` is the front-door form). 0 for a backend
            /// without the buffer convention.
            ///
            /// @stable-since: v0.1.0
            pub fn bufferLen(program: *const B.Program) usize {
                if (comptime @hasDecl(B.Scratch, "bufferLen")) return B.Scratch.bufferLen(program);
                return 0;
            }

            /// Wrap a backend scratch you built yourself — the escape hatch for backends
            /// whose scratch takes extra configuration (e.g. `dfa.Scratch.initOptions(gpa,
            /// &re.program, .{ .max_bytes = … })`). The wrapper takes ownership: `deinit`
            /// releases it.
            ///
            /// @stable-since: v0.7.0
            pub fn fromBackend(inner: B.Scratch) Scratch {
                return .{ .inner = inner };
            }

            /// Clear per-search state so the scratch can be reused on a new input
            /// (forwards `B.Scratch.reset`; a no-op for a backend without one).
            ///
            /// @stable-since: v0.1.0
            pub fn reset(self: *Scratch) void {
                if (comptime @hasDecl(B.Scratch, "reset")) self.inner.reset();
            }

            /// Release the scratch's heap memory (forwards `B.Scratch.deinit`; a no-op
            /// for a backend without one). Pass the allocator `init` received.
            ///
            /// @stable-since: v0.1.0
            pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
                if (comptime @hasDecl(B.Scratch, "deinit")) self.inner.deinit(gpa);
            }
        };
        /// The backend type `B` this regex was compiled with (e.g. `backends.auto`).
        pub const Backend = B;

        /// The backend's immutable executable form (NFA insts, literal set, …),
        /// shareable across threads. **Internal / advanced use:** the front door's
        /// own methods and `initScratch` reach it for you; take `&re.program` only to
        /// drive `Engine(B)` or a backend primitive directly (with `&sc.inner`).
        program: B.Program,
        /// Capture metadata (group count + names): sizes `slots` and resolves names.
        meta: backend.Meta,
        /// Non-null for `compileRuntime` (used by `deinit`); null for comptime.
        allocator: ?std.mem.Allocator,

        /// Release heap memory (no-op for a comptime-compiled regex).
        ///
        /// @stable-since: v0.1.0
        pub fn deinit(self: *Self) void {
            const a = self.allocator orelse return;
            if (@hasDecl(B, "freeProgram")) B.freeProgram(a, &self.program);
            for (self.meta.group_names) |gn| {
                if (gn) |name| a.free(name);
            }
            if (self.meta.group_names.len != 0) a.free(self.meta.group_names);
        }

        /// How many `?usize` capture slots `captures`/`capturesAll`/`replaceAll`
        /// need: `2 * (captureCount + 1)`. Pre-allocate exactly this many.
        ///
        /// @stable-since: v0.1.0
        pub fn slotCount(self: Self) usize {
            return self.meta.slotLen();
        }
        /// Number of capturing groups (excluding the whole match).
        ///
        /// @stable-since: v0.1.0
        pub fn captureCount(self: Self) usize {
            return self.meta.capture_count;
        }

        // ── the caller-owned Scratch ────────────────────────────────────────────

        /// Make a heap-backed `Scratch` for this regex: `var sc = try re.initScratch(gpa);`
        /// then `defer sc.deinit(gpa);`. One per thread, reused across searches.
        /// The error set is the backend's (`OutOfMemory` for every built-in).
        ///
        /// @stable-since: v0.7.0
        pub fn initScratch(self: *const Self, gpa: std.mem.Allocator) !Scratch {
            return Scratch.init(gpa, &self.program);
        }
        /// Make a `Scratch` over caller-owned storage — no allocator, no allocation
        /// during a search, and usable at comptime. `buf` must hold at least
        /// `scratchBufferLen()` words of `Scratch.Buf` (else `error.BufferTooSmall`).
        /// Needs the backend's buffer convention (every built-in except the lazy `dfa`).
        ///
        /// @stable-since: v0.7.0
        pub fn initScratchBuffer(self: *const Self, buf: []Scratch.Buf) backend.ScratchError!Scratch {
            return Scratch.initBuffer(buf, &self.program);
        }
        /// How many `Scratch.Buf` words `initScratchBuffer` needs for this regex. For a
        /// comptime regex this is comptime-known, so it sizes a stack array:
        /// `var buf: [re.scratchBufferLen()]gex.Scratch.Buf = undefined;`.
        ///
        /// @stable-since: v0.7.0
        pub fn scratchBufferLen(self: *const Self) usize {
            return Scratch.bufferLen(&self.program);
        }

        // ── the user-facing API ──────────────────────────────────────────────────

        /// Does the pattern match anywhere in `input`? (Unanchored; cheapest op —
        /// stops at the first match, fills no captures.)
        ///
        /// @stable-since: v0.1.0
        pub fn isMatch(self: *const Self, scratch: *Scratch, input: []const u8) bool {
            return Eng.isMatch(&self.program, &scratch.inner, input, .{});
        }
        /// `isMatch` with explicit `SearchOptions` (`.start` offset, `.anchored`).
        ///
        /// @stable-since: v0.1.0
        pub fn isMatchAt(self: *const Self, scratch: *Scratch, input: []const u8, opts: backend.SearchOptions) bool {
            return Eng.isMatch(&self.program, &scratch.inner, input, opts);
        }
        /// The leftmost match in `input`, or null. The returned `Match` is byte
        /// offsets; use `m.slice(input)` for the text.
        ///
        /// @stable-since: v0.1.0
        pub fn find(self: *const Self, scratch: *Scratch, input: []const u8) ?Match {
            return Eng.find(&self.program, &scratch.inner, input, .{});
        }
        /// `find` with explicit `SearchOptions` (resume at `.start`, or `.anchored`).
        ///
        /// @stable-since: v0.1.0
        pub fn findAt(self: *const Self, scratch: *Scratch, input: []const u8, opts: backend.SearchOptions) ?Match {
            return Eng.find(&self.program, &scratch.inner, input, opts);
        }
        /// Resolve the first match's submatches into `slots` (length `slotCount()`),
        /// returning a `Captures` view (or null on no match). Read groups via
        /// `c.group(i)`/`c.groupSlice(i)`/`c.named(...)`.
        ///
        /// @stable-since: v0.1.0
        pub fn captures(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8) ?Captures {
            return Eng.captures(&self.program, &scratch.inner, input, slots, self.meta, .{});
        }
        /// Iterator over every non-overlapping match, left to right. Empty matches
        /// advance one code point so iteration always terminates.
        ///
        /// @stable-since: v0.1.0
        pub fn findAll(self: *const Self, scratch: *Scratch, input: []const u8) Eng.MatchIterator {
            return Eng.findAll(&self.program, &scratch.inner, input, .{});
        }
        /// Iterator yielding a `Captures` per non-overlapping match into the SHARED
        /// `slots` — each view is valid only until the next `next()` reuses `slots`.
        ///
        /// @stable-since: v0.1.0
        pub fn capturesAll(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8) Eng.CaptureIterator {
            return Eng.capturesAll(&self.program, &scratch.inner, input, slots, self.meta, .{});
        }
        /// Count the non-overlapping matches in `input`.
        ///
        /// @stable-since: v0.1.0
        pub fn count(self: *const Self, scratch: *Scratch, input: []const u8) usize {
            return Eng.count(&self.program, &scratch.inner, input, .{});
        }
        /// Iterator over the substrings between successive matches (the pattern is the
        /// separator). Empty matches are skipped; the final piece is always yielded.
        ///
        /// @stable-since: v0.1.0
        pub fn split(self: *const Self, scratch: *Scratch, input: []const u8) Eng.SplitIterator {
            return Eng.split(&self.program, &scratch.inner, input, .{});
        }
        /// Replace every match, writing the result to `writer`. `template` may
        /// reference captures: `$0`/`$1`/… by number, `${name}` by name, `$$` for a
        /// literal `$`. Needs a `slots` buffer of `slotCount()`.
        ///
        /// @stable-since: v0.1.0
        pub fn replaceAll(
            self: *const Self,
            scratch: *Scratch,
            input: []const u8,
            template: []const u8,
            slots: []?usize,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            return Eng.replaceAll(&self.program, &scratch.inner, input, template, slots, self.meta, writer);
        }

        /// `captures` with explicit `SearchOptions` (resume at `.start`, or `.anchored`) —
        /// the capture-filling peer of `findAt`/`isMatchAt`.
        ///
        /// @stable-since: v0.5.0
        pub fn capturesAt(self: *const Self, scratch: *Scratch, slots: []?usize, input: []const u8, opts: backend.SearchOptions) ?Captures {
            return Eng.captures(&self.program, &scratch.inner, input, slots, self.meta, opts);
        }
        /// Replace only the **first** match (template syntax as `replaceAll`).
        ///
        /// @stable-since: v0.5.0
        pub fn replace(
            self: *const Self,
            scratch: *Scratch,
            input: []const u8,
            template: []const u8,
            slots: []?usize,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            return Eng.replace(&self.program, &scratch.inner, input, template, slots, self.meta, writer);
        }
        /// Replace the first **`n`** matches (`n == 0` copies the input verbatim).
        ///
        /// @stable-since: v0.5.0
        pub fn replaceN(
            self: *const Self,
            scratch: *Scratch,
            input: []const u8,
            template: []const u8,
            slots: []?usize,
            writer: *std.Io.Writer,
            n: usize,
        ) std.Io.Writer.Error!void {
            return Eng.replaceN(&self.program, &scratch.inner, input, template, slots, self.meta, writer, n);
        }
        /// Replace every match and return the result as a freshly **allocated** `[]u8`
        /// (caller frees). The convenience over `replaceAll` for when you just want the
        /// string and don't have a `Writer` (errors are `OutOfMemory`).
        ///
        /// @stable-since: v0.5.0
        pub fn replaceAllAlloc(
            self: *const Self,
            allocator: std.mem.Allocator,
            scratch: *Scratch,
            input: []const u8,
            template: []const u8,
            slots: []?usize,
        ) std.mem.Allocator.Error![]u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            // An Allocating writer fails only on OOM, so `WriteFailed` ⇒ `OutOfMemory`.
            Eng.replaceAll(&self.program, &scratch.inner, input, template, slots, self.meta, &out.writer) catch return error.OutOfMemory;
            return out.toOwnedSlice();
        }
        /// Replace every match, computing each replacement with a **callback**
        /// `replacer(context, captures, writer)` instead of a `$`-template — the escape
        /// hatch for replacements the template DSL can't express (uppercase the match,
        /// look up a table, format a number from a group).
        ///
        /// @stable-since: v0.5.0
        pub fn replaceAllWith(
            self: *const Self,
            scratch: *Scratch,
            input: []const u8,
            slots: []?usize,
            writer: *std.Io.Writer,
            context: anytype,
            comptime replacer: fn (@TypeOf(context), Captures, *std.Io.Writer) std.Io.Writer.Error!void,
        ) std.Io.Writer.Error!void {
            return Eng.replaceAllWith(&self.program, &scratch.inner, input, slots, self.meta, writer, context, replacer);
        }
        /// Iterator over the substrings between matches, yielding **at most `n` pieces**
        /// (the remainder after `n − 1` separators is the final piece). The `splitn` form.
        ///
        /// @stable-since: v0.5.0
        pub fn splitN(self: *const Self, scratch: *Scratch, input: []const u8, n: usize) Eng.SplitIterator {
            return Eng.splitN(&self.program, &scratch.inner, input, n, .{});
        }
        /// The index of the capture group named `name` (1-based; group 0 is the whole
        /// match), or null if there is no such name. Resolves from the compiled metadata —
        /// no match required.
        ///
        /// @stable-since: v0.5.0
        pub fn groupIndex(self: Self, name: []const u8) ?usize {
            for (self.meta.group_names, 0..) |gn, g| {
                if (gn) |n| if (std.mem.eql(u8, n, name)) return g;
            }
            return null;
        }
        /// The name of capture group `index`, or null (no name, or out of range).
        ///
        /// @stable-since: v0.5.0
        pub fn groupName(self: Self, index: usize) ?[]const u8 {
            if (index >= self.meta.group_names.len) return null;
            return self.meta.group_names[index];
        }

        // ── comptime matching (no allocator, no runtime cost) ─────────────────────
        //
        // When the whole regex is comptime-known (`compileComptime`), these run the
        // match at comptime over a buffer `Scratch` declared inline. They need the
        // backend's buffer convention (`Buf`/`bufferLen`/`initBuffer`) — the
        // built-ins all provide it.

        fn requireBufferConvention() void {
            if (!@hasDecl(B.Scratch, "initBuffer") or !@hasDecl(B.Scratch, "bufferLen") or !@hasDecl(B.Scratch, "Buf"))
                @compileError("the buffer-scratch / comptime-matching path requires the backend's Scratch to expose Buf/bufferLen/initBuffer");
        }

        /// @stable-since: v0.1.0
        pub fn isMatchComptime(comptime self: Self, comptime input: []const u8) bool {
            return self.isMatchAtComptime(input, .{});
        }
        /// @stable-since: v0.1.0
        pub fn isMatchAtComptime(comptime self: Self, comptime input: []const u8, comptime opts: backend.SearchOptions) bool {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.isMatch(&self.program, &sc, input, opts);
            }
        }
        /// @stable-since: v0.1.0
        pub fn findComptime(comptime self: Self, comptime input: []const u8) ?Match {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.find(&self.program, &sc, input, .{});
            }
        }
        /// @stable-since: v0.1.0
        pub fn countComptime(comptime self: Self, comptime input: []const u8) usize {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                return Eng.count(&self.program, &sc, input, .{});
            }
        }
        /// Comptime captures: resolve the first match's groups at compile time. The
        /// returned `Captures` references `ro_data` (the slot offsets and the input
        /// are frozen into the binary), so `groupSlice`/`namedSlice` work on it at
        /// comptime *and* at runtime. This rounds out `findComptime` with submatch
        /// access; the backend must support captures (`caps.captures`).
        ///
        /// @stable-since: v0.2.0
        pub fn capturesComptime(comptime self: Self, comptime input: []const u8) ?Captures {
            comptime {
                requireBufferConvention();
                @setEvalBranchQuota(comptimeQuota(input.len));
                var buf: [B.Scratch.bufferLen(&self.program)]B.Scratch.Buf = undefined;
                var sc = B.Scratch.initBuffer(&buf, &self.program) catch unreachable;
                var slots: [self.meta.slotLen()]?usize = undefined;
                _ = Eng.captures(&self.program, &sc, input, &slots, self.meta, .{}) orelse return null;
                // Freeze the resolved slots into ro_data so the returned view does
                // not dangle on this block's comptime-local array — the same const-
                // promotion trick `comptimeGroupNames` uses below.
                const frozen = slots;
                return .{ .slots = &frozen, .meta = self.meta, .input = input };
            }
        }
    };
}

/// A roomy comptime eval-branch ceiling for a match over `input_len` bytes (a
/// guard, not a cost — Zig only spends branches on work actually done).
fn comptimeQuota(input_len: usize) u32 {
    return @intCast(@min(1_000_000 + input_len * 20_000, std.math.maxInt(u32)));
}

// ── constructors ────────────────────────────────────────────────────────────────

/// Runtime: compile `pattern` into a heap-backed regex (default backend). On a
/// malformed pattern, returns `error.InvalidPattern` and writes `diag` — the
/// caller decides how to surface it. Free the result with `re.deinit()`.
///
/// @stable-since: v0.1.0
pub fn compileRuntime(allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic, comptime opts: Options) Error!Compiled(default_backend) {
    return compileRuntimeWith(default_backend, allocator, pattern, diag, opts);
}

/// Comptime: compile `pattern` into a ro_data regex (default backend). A bad
/// pattern is a compile error. No allocator; `deinit` is a no-op.
///
/// @stable-since: v0.1.0
pub fn compileComptime(comptime pattern: []const u8, comptime opts: Options) Compiled(default_backend) {
    return compileComptimeWith(default_backend, pattern, opts);
}

/// Project the front-door `Options` onto a backend's build `Options`. Most backends
/// take an empty `Options{}`; a backend that exposes a `byte_engine` field (the `auto`
/// dispatcher) receives the strategy tier's `byte_engine`, so a user can opt the byte
/// lazy DFA in/out from the front door. Backends without the field are unaffected (the
/// `@hasField` branch is comptime-pruned for them).
fn backendOptions(comptime B: type, comptime opts: Options) B.Options {
    var bo: B.Options = .{};
    if (comptime @hasField(B.Options, "byte_engine")) {
        bo.byte_engine = switch (opts.strategy.byte_engine) {
            .auto => .auto,
            .enabled => .enabled,
            .disabled => .disabled,
        };
    }
    if (comptime @hasField(B.Options, "prefilter")) {
        bo.prefilter = opts.strategy.prefilter;
    }
    if (comptime @hasField(B.Options, "simd")) {
        bo.simd = opts.strategy.simd;
    }
    return bo;
}

/// `compileRuntime` with an explicit backend.
///
/// @stable-since: v0.1.0
pub fn compileRuntimeWith(comptime B: type, allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic, comptime opts: Options) Error!Compiled(B) {
    const ast = parser.parseWith(allocator, pattern, diag, opts.scanLimits()) catch |e| switch (e) {
        error.InvalidPattern => return error.InvalidPattern,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer ast.deinit(allocator);

    // Seed the front-door flag options onto the AST's flags (OR-merged with any
    // bare inline flags the pattern set) before lowering. `seeded` shares `ast`'s
    // arrays — only the flag bits change — so `ast.deinit` above still owns them.
    var seeded = ast;
    seeded.flags = opts.initialFlags().merge(ast.flags);

    const h = hir.buildAlloc(allocator, seeded, opts.toHir()) catch |e| switch (e) {
        error.PatternTooComplex => return error.PatternTooComplex,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer hir.deinitHir(allocator, h);
    if (hir.expandedSize(h) > opts.size_limit) {
        diag.* = .{ .code = .pattern_too_complex, .span = .{ .start = 0, .end = @intCast(pattern.len) } };
        return error.PatternTooComplex;
    }

    var program = try B.buildAlloc(allocator, h, backendOptions(B, opts));
    errdefer if (@hasDecl(B, "freeProgram")) B.freeProgram(allocator, &program);

    const group_names = try buildGroupNames(allocator, h);
    return .{ .program = program, .meta = .{ .capture_count = h.capture_count, .group_names = group_names }, .allocator = allocator };
}

/// `compileComptime` with an explicit backend.
///
/// @stable-since: v0.1.0
pub fn compileComptimeWith(comptime B: type, comptime pattern: []const u8, comptime opts: Options) Compiled(B) {
    const ast = comptime parser.compileWith(pattern, opts.scanLimits()); // @compileError on a bad pattern
    // Seed the front-door flag options (OR-merged with any bare inline flags).
    const seeded = comptime blk: {
        var a = ast;
        a.flags = opts.initialFlags().merge(ast.flags);
        break :blk a;
    };
    // HIR lowering with case folding scans ezi_code's fold tables per literal,
    // which at comptime can exceed the default branch budget; raise it (a ceiling,
    // not a cost — spent only on work actually done).
    @setEvalBranchQuota(@intCast(@min(@as(u64, pattern.len) * 20_000 + 200_000, std.math.maxInt(u32))));
    const h = comptime switch (hir.buildComptime(seeded, opts.toHir())) {
        .ok => |x| x,
        .fail => @compileError("ezi_gex: HIR build failed for pattern \"" ++ pattern ++ "\""),
    };
    if (comptime hir.expandedSize(h) > opts.size_limit)
        @compileError("ezi_gex: pattern \"" ++ pattern ++ "\" exceeds Options.size_limit (its counted repetitions unroll past the limit)");
    const program = comptime B.buildComptime(h, backendOptions(B, opts));
    const names = comptime comptimeGroupNames(h);
    return .{
        .program = program,
        .meta = .{ .capture_count = h.capture_count, .group_names = names },
        .allocator = null,
    };
}

// ── group-name table (group index → name), built from the HIR ─────────────────────

fn buildGroupNames(allocator: std.mem.Allocator, h: hir.Hir) std.mem.Allocator.Error![]const ?[]const u8 {
    if (h.capture_count == 0) return &.{};
    const arr = try allocator.alloc(?[]const u8, h.capture_count + 1);
    errdefer allocator.free(arr);
    @memset(arr, null);
    var done: usize = 0;
    errdefer for (arr[0..]) |gn| {
        if (gn) |name| allocator.free(name);
    };
    for (h.nodes) |node| {
        if (node.tag == .capture) {
            const c = node.data.capture;
            if (c.name) |ni| {
                arr[c.index] = try allocator.dupe(u8, h.names[ni]); // own it; pattern may not outlive us
                done += 1;
            }
        }
    }
    return arr;
}

fn comptimeGroupNames(comptime h: hir.Hir) []const ?[]const u8 {
    if (h.capture_count == 0) return &.{};
    var arr: [h.capture_count + 1]?[]const u8 = undefined;
    @memset(&arr, null);
    for (h.nodes) |node| {
        if (node.tag == .capture) {
            const c = node.data.capture;
            if (c.name) |ni| arr[c.index] = h.names[ni];
        }
    }
    const final = arr;
    return &final;
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "compileRuntime: full API over a heap-backed regex" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(\\w+)@(\\w+)", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);

    try testing.expect(re.isMatch(&sc, "x a@b y"));
    try testing.expect(!re.isMatch(&sc, "nope"));
    try testing.expectEqualStrings("a@b", re.find(&sc, "x a@b y").?.slice("x a@b y"));

    try testing.expectEqual(@as(usize, 6), re.slotCount()); // 2 * (2 groups + whole match)
    const slots = try testing.allocator.alloc(?usize, re.slotCount());
    defer testing.allocator.free(slots);
    const c = re.captures(&sc, slots, "user@host").?;
    try testing.expectEqualStrings("user", c.groupSlice(1).?);
    try testing.expectEqualStrings("host", c.groupSlice(2).?);
}

test "compileRuntime: invalid pattern returns error + diagnostic, no crash" {
    var diag: Diagnostic = .{};
    const r = compileRuntime(testing.allocator, "a(b", &diag, .{});
    try testing.expectError(error.InvalidPattern, r);
    try testing.expectEqual(core.errors.ErrorCode.unclosed_group, diag.code);
    try testing.expectEqualStrings("(", diag.faultySlice("a(b"));
}

test "Options.max_repetition: a custom ceiling is enforced at the front door" {
    var diag: Diagnostic = .{};
    // Within the ceiling: compiles and matches as usual.
    var re = try compileRuntime(testing.allocator, "a{3}", &diag, .{ .max_repetition = 3 });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "aaa"));

    // Over the ceiling: InvalidPattern, surfaced at scan time with the dedicated code.
    const r = compileRuntime(testing.allocator, "a{4}", &diag, .{ .max_repetition = 3 });
    try testing.expectError(error.InvalidPattern, r);
    try testing.expectEqual(core.errors.ErrorCode.quantifier_exceeds_limit, diag.code);
}

test "Options.max_repetition: the default ceiling accepts large but sane counts" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "a{4000}", &diag, .{});
    defer re.deinit();
    // And rejects beyond the 100_000 default.
    const r = compileRuntime(testing.allocator, "a{100001}", &diag, .{});
    try testing.expectError(error.InvalidPattern, r);
    try testing.expectEqual(core.errors.ErrorCode.quantifier_exceeds_limit, diag.code);
}

test "Options.size_limit: a nested repetition bomb is rejected before it is expanded" {
    // Each count is under max_repetition; their product (10^9) is not under size_limit.
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var diag: Diagnostic = .{};
    const r = compileRuntime(counting.allocator(), "(?:(?:a{1000}){1000}){1000}", &diag, .{});
    try testing.expectError(error.PatternTooComplex, r);
    try testing.expectEqual(core.errors.ErrorCode.pattern_too_complex, diag.code);
    // Rejected from the HIR alone: nothing proportional to the expansion was allocated.
    try testing.expect(counting.allocated_bytes < 1 << 20);
}

test "Options.size_limit: the default keeps large but sane patterns" {
    var diag: Diagnostic = .{};
    inline for (.{ "a{100000}", "\\w{200}", "(?:ab|cd){1000}", "\\p{L}{500}" }) |p| {
        var re = try compileRuntime(testing.allocator, p, &diag, .{});
        re.deinit();
    }
}

test "Options.size_limit: a tightened limit rejects, and the error is located" {
    var diag: Diagnostic = .{};
    var ok = try compileRuntime(testing.allocator, "a{20}", &diag, .{ .size_limit = 50 });
    ok.deinit();
    const r = compileRuntime(testing.allocator, "a{40}", &diag, .{ .size_limit = 50 });
    try testing.expectError(error.PatternTooComplex, r);
    try testing.expectEqual(core.errors.ErrorCode.pattern_too_complex, diag.code);
    try testing.expectEqual(@as(u32, 0), diag.span.start);
    try testing.expectEqual(@as(u32, 5), diag.span.end);
}

test "Options.size_limit: threads through the comptime path" {
    const re = comptime compileComptime("a{20}", .{ .size_limit = 50 });
    try testing.expect(comptime re.isMatchComptime("aaaaaaaaaaaaaaaaaaaa"));
    // An over-limit pattern here is a @compileError (not testable in-process).
}

test "Options.max_repetition: the option threads through the comptime path" {
    // A count within the (here tightened) ceiling compiles and matches; the
    // ceiling flows all the way to the comptime scanner. (An over-limit count on
    // this path is a located `@compileError`, exercised in compile.zig's
    // `parseComptimeWith` test, which stops at the scanner before NFA expansion.)
    const Re = compileComptime("a{6}", .{ .max_repetition = 10 });
    var re = Re;
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "aaaaaa"));
    try testing.expect(!re.isMatch(&sc, "aaaaa"));
}

test "compileComptime: program in ro_data, used at runtime" {
    const Re = compileComptime("\\d{3}-\\d{4}", .{});
    var re = Re; // a value; methods take *const Self
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "call 555-1234 now"));
    try testing.expectEqualStrings("555-1234", re.find(&sc, "call 555-1234 now").?.slice("call 555-1234 now"));
    // capture slots can be a comptime-sized stack array (capture_count is comptime)
    try testing.expectEqual(@as(usize, 2), re.slotCount());
}

test "compileComptime: named captures resolve" {
    const Re = compileComptime("(?<y>\\d+)-(?<m>\\d+)", .{});
    var re = Re;
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    var slots: [6]?usize = undefined;
    const c = re.captures(&sc, &slots, "2026-06").?;
    try testing.expectEqualStrings("2026", c.namedSlice("y").?);
    try testing.expectEqualStrings("06", c.namedSlice("m").?);
}

test "comptime and runtime compile agree" {
    const pat = "[a-z]+\\d*";
    const input = "  abc123  ";
    var diag: Diagnostic = .{};
    var rt = try compileRuntime(testing.allocator, pat, &diag, .{});
    defer rt.deinit();
    var rsc = try @TypeOf(rt).Scratch.init(testing.allocator, &rt.program);
    defer rsc.deinit(testing.allocator);

    var ct = compileComptime(pat, .{});
    var csc = try @TypeOf(ct).Scratch.init(testing.allocator, &ct.program);
    defer csc.deinit(testing.allocator);

    try testing.expectEqualStrings("abc123", rt.find(&rsc, input).?.slice(input));
    try testing.expectEqualStrings("abc123", ct.find(&csc, input).?.slice(input));
}

test "front door: comptime isMatch / find / count (default auto backend)" {
    const Re = comptime compileComptime("\\d+", .{});
    try testing.expect(comptime Re.isMatchComptime("abc123"));
    try testing.expect(!comptime Re.isMatchComptime("abcdef"));
    const m = comptime Re.findComptime("x123y").?;
    try testing.expectEqualStrings("123", m.slice("x123y"));
    try testing.expectEqual(@as(usize, 3), comptime Re.countComptime("a1b22c333"));
}

test "front door: comptime literal route runs at comptime too" {
    const Re = comptime compileComptime("cat|dog", .{});
    try testing.expect(comptime Re.isMatchComptime("a dog here"));
    const m = comptime Re.findComptime("a dog here").?;
    try testing.expectEqualStrings("dog", m.slice("a dog here"));
}

test "front door: runtime buffer scratch needs no allocator for matching" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "[a-z]+\\d+", &diag, .{});
    defer re.deinit();
    var buf: [4096]@TypeOf(re).Scratch.Buf = undefined; // Buf == the backend's Cell
    var sc = try @TypeOf(re).Scratch.initBuffer(&buf, &re.program);
    try testing.expectEqualStrings("abc12", re.find(&sc, "??abc12!!").?.slice("??abc12!!"));
    try testing.expect(!re.isMatch(&sc, "ABC"));
}

test "front-door iterators and replace" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), re.count(&sc, "a1b22c333"));

    var split_re = try compileRuntime(testing.allocator, "\\s+", &diag, .{});
    defer split_re.deinit();
    var ssc = try @TypeOf(split_re).Scratch.init(testing.allocator, &split_re.program);
    defer ssc.deinit(testing.allocator);
    var it = split_re.split(&ssc, "the  quick fox");
    try testing.expectEqualStrings("the", it.next().?);
    try testing.expectEqualStrings("quick", it.next().?);
    try testing.expectEqualStrings("fox", it.next().?);
    try testing.expect(it.next() == null);
}

// ── v0.5.0 API additions: replace family, capturesAt, splitN, group name/index ──

test "replace / replaceN: bounded replacement counts" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    var slots: [2]?usize = undefined;
    var buf: [64]u8 = undefined;

    var w = std.Io.Writer.fixed(&buf);
    try re.replace(&sc, "a1b22c333", "#", &slots, &w); // first only
    try testing.expectEqualStrings("a#b22c333", w.buffered());

    var w2 = std.Io.Writer.fixed(&buf);
    try re.replaceN(&sc, "a1b22c333", "#", &slots, &w2, 2); // first two
    try testing.expectEqualStrings("a#b#c333", w2.buffered());

    var w3 = std.Io.Writer.fixed(&buf);
    try re.replaceN(&sc, "a1b22c333", "#", &slots, &w3, 0); // none → verbatim
    try testing.expectEqualStrings("a1b22c333", w3.buffered());
}

test "replaceAllAlloc returns an owned slice" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(\\w+)@(\\w+)", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(?usize, re.slotCount());
    defer testing.allocator.free(slots);
    const out = try re.replaceAllAlloc(testing.allocator, &sc, "to bob@host now", "$2/$1", slots);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("to host/bob now", out);
}

const UpperCtx = struct {
    fn run(_: UpperCtx, caps: Captures, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (caps.match().slice(caps.input)) |c| try w.writeByte(std.ascii.toUpper(c));
    }
};

test "replaceAllWith: callback computes each replacement" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "[a-z]+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    var slots: [2]?usize = undefined;
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try re.replaceAllWith(&sc, "say hi to bob", &slots, &w, UpperCtx{}, UpperCtx.run);
    try testing.expectEqualStrings("SAY HI TO BOB", w.buffered());
}

test "replace fast path is results-identical to the capture path (revert-failing)" {
    // A group-referencing template MUST still fill captures — if `templateRefsGroup` wrongly
    // returned false, `$2$1` would expand to empty. And a group-LESS pattern with a `$0`/literal
    // template runs the span-only fast path and must produce the same bytes as before.
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(\\d)(\\d)", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(?usize, re.slotCount());
    defer testing.allocator.free(slots);
    var buf: [64]u8 = undefined;

    var w = std.Io.Writer.fixed(&buf);
    try re.replaceAll(&sc, "x12y34z", "$2$1", slots, &w); // refs groups → must swap digits
    try testing.expectEqualStrings("x21y43z", w.buffered());

    // Group-less pattern, `$0` + literal template → fast (span-only) path, same result.
    var re2 = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    var slots2: [2]?usize = undefined;
    var w2 = std.Io.Writer.fixed(&buf);
    try re2.replaceAll(&sc2, "a1b22c", "<$0>", &slots2, &w2);
    try testing.expectEqualStrings("a<1>b<22>c", w2.buffered());
}

test "captures on a group-less pattern (fillCapturesAnchored short-circuit) still gives group 0" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    var slots: [2]?usize = undefined;
    const c = re.captures(&sc, &slots, "ab123cd").?;
    try testing.expectEqualStrings("123", c.groupSlice(0).?);
    try testing.expectEqual(@as(usize, 1), c.count());
}

test "capturesAt resumes a capture search at an offset" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(\\d+)", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    var slots: [4]?usize = undefined;
    // Skip the first number by starting past it.
    const c = re.capturesAt(&sc, &slots, "11 22 33", .{ .start = 3 }).?;
    try testing.expectEqualStrings("22", c.groupSlice(1).?);
}

test "splitN: at most n pieces, remainder unsplit" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, ",", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);

    var it = re.splitN(&sc, "a,b,c,d", 2);
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b,c,d", it.next().?); // remainder, unsplit
    try testing.expect(it.next() == null);

    var it1 = re.splitN(&sc, "a,b,c", 1);
    try testing.expectEqualStrings("a,b,c", it1.next().?); // whole input
    try testing.expect(it1.next() == null);

    var it0 = re.splitN(&sc, "a,b,c", 0);
    try testing.expect(it0.next() == null); // no pieces
}

test "groupIndex / groupName resolve named groups without a match" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?<year>\\d{4})-(?<mon>\\d{2})", &diag, .{});
    defer re.deinit();
    try testing.expectEqual(@as(?usize, 1), re.groupIndex("year"));
    try testing.expectEqual(@as(?usize, 2), re.groupIndex("mon"));
    try testing.expectEqual(@as(?usize, null), re.groupIndex("nope"));
    try testing.expectEqualStrings("year", re.groupName(1).?);
    try testing.expectEqualStrings("mon", re.groupName(2).?);
    try testing.expect(re.groupName(0) == null); // whole match has no name
    try testing.expect(re.groupName(9) == null); // out of range
}

// ── Full case folding (case_fold = .full) ─────────────────────────────────────

test "full folding: (?i)ß also matches its expansion ss" {
    var diag: Diagnostic = .{};
    // `.full` lowers ß to (?:[ßẞ] | [sSſ][sSſ]) — both the sharp-s code points
    // AND the spelled-out "ss" in any case.
    var re = try compileRuntime(testing.allocator, "(?i)ß", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);

    try testing.expect(re.isMatch(&sc, "ß")); //  the code point itself
    try testing.expect(re.isMatch(&sc, "ẞ")); //  U+1E9E, simple-folds to ß
    try testing.expect(re.isMatch(&sc, "ss")); // the expansion …
    try testing.expect(re.isMatch(&sc, "SS")); // … in any case
    try testing.expect(re.isMatch(&sc, "Ss"));
    try testing.expect(!re.isMatch(&sc, "s")); // a lone s is not enough
    try testing.expectEqualStrings("ss", re.find(&sc, "<<ss>>").?.slice("<<ss>>"));
}

test "full folding: ligature (?i)ﬀ also matches ff" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?i)ﬀ", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ﬀ"));
    try testing.expect(re.isMatch(&sc, "ff"));
    try testing.expect(re.isMatch(&sc, "FF"));
}

test "simple folding leaves ß un-expanded (the .full / .simple contrast)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?i)ß", &diag, .{ .case_fold = .simple });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ß"));
    try testing.expect(re.isMatch(&sc, "ẞ"));
    try testing.expect(!re.isMatch(&sc, "ss")); // simple folding: no 1→many expansion
}

test "full folding in a class stays simple (a class matches one code point)" {
    var diag: Diagnostic = .{};
    // Inside [...] there is no multi-code-point expansion; [ß] under .full still
    // matches only the single sharp-s code points, never the two-char "ss".
    var re = try compileRuntime(testing.allocator, "(?i)[ß]", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ß"));
    try testing.expect(!re.isMatch(&sc, "ss"));
}

test "full folding: plain ASCII literals are unaffected (run coalescing intact)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?i)abc", &diag, .{ .case_fold = .full });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ABC"));
    try testing.expect(re.isMatch(&sc, "aBc"));
    try testing.expect(!re.isMatch(&sc, "abd"));
}

// ── Options-seeded inline flags (case_insensitive / multiline / dot_matches_newline)

test "Options.case_insensitive seeds (?i) for the whole pattern" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "abc", &diag, .{ .case_insensitive = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "ABC"));
    try testing.expect(re.isMatch(&sc, "aBc"));

    // The default (no option) stays case-sensitive.
    var re2 = try compileRuntime(testing.allocator, "abc", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(!re2.isMatch(&sc2, "ABC"));
}

test "Options.multiline seeds (?m): ^ matches at line starts" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "^b", &diag, .{ .multiline = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "a\nb")); // ^ matches just after the \n

    var re2 = try compileRuntime(testing.allocator, "^b", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(!re2.isMatch(&sc2, "a\nb")); // without (?m), ^ is input start only
}

test "Options.dot_matches_newline seeds (?s): . matches newline" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "a.b", &diag, .{ .dot_matches_newline = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "a\nb"));

    var re2 = try compileRuntime(testing.allocator, "a.b", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(!re2.isMatch(&sc2, "a\nb"));
}

test "Options flags seed the comptime path too" {
    const Re = comptime compileComptime("abc", .{ .case_insensitive = true });
    try testing.expect(comptime Re.isMatchComptime("ABC"));
    const Re2 = comptime compileComptime("abc", .{});
    try testing.expect(!comptime Re2.isMatchComptime("ABC"));
}

// ── ASCII mode for shorthand classes (Options.unicode = false) ────────────────

test "unicode=false: \\w is ASCII [0-9A-Za-z_] only" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\w+", &diag, .{ .unicode = false });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    // \w stops before é (not an ASCII word char):
    try testing.expectEqualStrings("abc", re.find(&sc, "abc-é").?.slice("abc-é"));

    // Unicode mode (the default): \w is Unicode-aware, so é is a word char.
    var ure = try compileRuntime(testing.allocator, "\\w+", &diag, .{});
    defer ure.deinit();
    var usc = try @TypeOf(ure).Scratch.init(testing.allocator, &ure.program);
    defer usc.deinit(testing.allocator);
    try testing.expectEqualStrings("abcé", ure.find(&usc, "abcé-").?.slice("abcé-"));
}

test "unicode=false: \\d is ASCII [0-9] (no other Unicode digits)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{ .unicode = false });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "123"));
    try testing.expect(!re.isMatch(&sc, "٣")); // U+0663 is a Unicode digit, not ASCII

    // Unicode mode matches it:
    var ure = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer ure.deinit();
    var usc = try @TypeOf(ure).Scratch.init(testing.allocator, &ure.program);
    defer usc.deinit(testing.allocator);
    try testing.expect(ure.isMatch(&usc, "٣"));
}

// ── Grapheme \X (front door, routed through auto → backtrack) ──────────────────

test "grapheme \\X matches whole extended clusters" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\X", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    // "e" + combining acute U+0301 is ONE grapheme cluster (3 bytes):
    try testing.expectEqualStrings("e\u{0301}", re.find(&sc, "e\u{0301}z").?.slice("e\u{0301}z"));
    // a · 😀 (one cluster) · b → three clusters:
    try testing.expectEqual(@as(usize, 3), re.count(&sc, "a😀b"));
}

test "grapheme \\X composes (a\\Xc over a combining-mark cluster)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "a\\Xc", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    // a, then one cluster (e+U+0301), then c:
    try testing.expect(re.isMatch(&sc, "ae\u{0301}c"));
    try testing.expect(!re.isMatch(&sc, "ac")); // \X requires one cluster between
}

test "Options.strategy is results-invariant (reserved tier)" {
    var diag: Diagnostic = .{};
    var a = try compileRuntime(testing.allocator, "\\w+", &diag, .{});
    defer a.deinit();
    var b = try compileRuntime(testing.allocator, "\\w+", &diag, .{ .strategy = .{
        .byte_engine = .disabled,
        .prefilter = false,
        .unicode_word_boundary_in_dfa = true,
        .simd = .off,
    } });
    defer b.deinit();
    var sa = try @TypeOf(a).Scratch.init(testing.allocator, &a.program);
    defer sa.deinit(testing.allocator);
    var sb = try @TypeOf(b).Scratch.init(testing.allocator, &b.program);
    defer sb.deinit(testing.allocator);
    const input = "  héllo_42  ";
    // Flipping every strategy knob must not change which text matches.
    try testing.expectEqualStrings(a.find(&sa, input).?.slice(input), b.find(&sb, input).?.slice(input));

    // The `simd` knob reaches the literal arm (front-door projection): a literal
    // alternation must match identically with Teddy on (`.auto`) vs off (`.off`).
    var la = try compileRuntime(testing.allocator, "cat|dog|fish", &diag, .{ .strategy = .{ .simd = .auto } });
    defer la.deinit();
    var lb = try compileRuntime(testing.allocator, "cat|dog|fish", &diag, .{ .strategy = .{ .simd = .off } });
    defer lb.deinit();
    var sla = try @TypeOf(la).Scratch.init(testing.allocator, &la.program);
    defer sla.deinit(testing.allocator);
    var slb = try @TypeOf(lb).Scratch.init(testing.allocator, &lb.program);
    defer slb.deinit(testing.allocator);
    const lin = "no pets here until a dog then a fish, never a cat first";
    try testing.expectEqualStrings(la.find(&sla, lin).?.slice(lin), lb.find(&slb, lin).?.slice(lin));
}

test "SearchOptions.span_end limits the search to a sub-range" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    const input = "ab123cd456"; // digits "123" at [2,5), "456" at [7,10)

    try testing.expectEqualStrings("123", re.find(&sc, input).?.slice(input)); // full search

    // span_end = 4 ⇒ haystack "ab12" ⇒ matches "12":
    try testing.expectEqualStrings("12", re.findAt(&sc, input, .{ .span_end = 4 }).?.slice(input));
    // span_end before any digit ⇒ no match:
    try testing.expect(re.findAt(&sc, input, .{ .span_end = 2 }) == null);
    // start + span_end window [5,9) over "cd45" ⇒ "45":
    try testing.expectEqualStrings("45", re.findAt(&sc, input, .{ .start = 5, .span_end = 9 }).?.slice(input));
    // span_end past the end clamps to input.len (no panic):
    try testing.expectEqualStrings("123", re.findAt(&sc, input, .{ .span_end = 999 }).?.slice(input));
}

test "(?x) verbose mode ignores unescaped whitespace and # comments" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?x) a b c  # a trailing comment", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "abc")); //  whitespace + comment stripped → "abc"
    try testing.expect(!re.isMatch(&sc, "a b c")); // literal spaces are NOT in the pattern
}

test "(?x:...) scoped verbose skips whitespace only inside the group" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "a(?x: b c )d", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    // Inside (?x:...) the spaces are ignored → the group matches "bc":
    try testing.expect(re.isMatch(&sc, "abcd"));

    // A literal space OUTSIDE the scoped group stays significant.
    var re2 = try compileRuntime(testing.allocator, "a (?x:b)", &diag, .{});
    defer re2.deinit();
    var sc2 = try @TypeOf(re2).Scratch.init(testing.allocator, &re2.program);
    defer sc2.deinit(testing.allocator);
    try testing.expect(re2.isMatch(&sc2, "a b"));
}

test "(?x) verbose: an escaped space is still a literal space" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(?x) a\\ b", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    try testing.expect(re.isMatch(&sc, "a b")); // `\ ` matches a literal space
    try testing.expect(!re.isMatch(&sc, "ab"));
}

// ── dead-on-invalid UTF-8 (input is matched, never substituted) ───────────────

test "dead-on-invalid: a match never spans an invalid UTF-8 byte" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "a.c", &diag, .{ .dot_matches_newline = true });
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    // 0xFF is an invalid UTF-8 byte — `.` must NOT match it (no U+FFFD substitution):
    try testing.expect(!re.isMatch(&sc, "a\xFFc"));
    try testing.expect(re.isMatch(&sc, "axc")); // a valid scalar still matches
}

test "dead-on-invalid: the scan resyncs and matches the valid region after a bad byte" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    var sc = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer sc.deinit(testing.allocator);
    // The leading 0xFF is skipped; the digits after it still match.
    try testing.expectEqualStrings("42", re.find(&sc, "\xFF42").?.slice("\xFF42"));
}


// ── front-door Scratch wrapper (`re.initScratch` & co.) ──────────────────────────

test "front door: re.initScratch + find/captures/replaceAll (auto)" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "(\\w+)@(\\w+)", &diag, .{});
    defer re.deinit();
    var sc = try re.initScratch(testing.allocator);
    defer sc.deinit(testing.allocator);

    try testing.expectEqualStrings("a@b", re.find(&sc, "x a@b y").?.slice("x a@b y"));
    const slots = try testing.allocator.alloc(?usize, re.slotCount());
    defer testing.allocator.free(slots);
    const c = re.captures(&sc, slots, "user@host").?;
    try testing.expectEqualStrings("user", c.groupSlice(1).?);
    try testing.expectEqualStrings("host", c.groupSlice(2).?);

    const out = try re.replaceAllAlloc(testing.allocator, &sc, "a@b c@d", "$2@$1", slots);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("b@a d@c", out);

    sc.reset(); // the wrapper forwards reset; the scratch stays usable afterwards
    try testing.expectEqual(@as(usize, 2), re.count(&sc, "a@b c@d"));
}

test "front door: comptime regex + initScratchBuffer needs no allocator" {
    const re = comptime compileComptime("[a-z]+\\d+", .{});
    var buf: [re.scratchBufferLen()]Compiled(default_backend).Scratch.Buf = undefined;
    var sc = try re.initScratchBuffer(&buf);
    try testing.expectEqualStrings("abc12", re.find(&sc, "??abc12!!").?.slice("??abc12!!"));
    try testing.expect(!re.isMatch(&sc, "ABC"));
}

test "front door: runtime regex + initScratchBuffer over a heap-sized buffer" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "[a-z]+\\d+", &diag, .{});
    defer re.deinit();
    const buf = try testing.allocator.alloc(@TypeOf(re).Scratch.Buf, re.scratchBufferLen());
    defer testing.allocator.free(buf);
    var sc = try re.initScratchBuffer(buf);
    try testing.expectEqualStrings("abc12", re.find(&sc, "??abc12!!").?.slice("??abc12!!"));
    // A too-small buffer is the contract's BufferTooSmall, surfaced through the wrapper
    // (an empty buffer can never hold the Pike VM's thread lists for an NFA program).
    try testing.expectError(error.BufferTooSmall, re.initScratchBuffer(buf[0..0]));
}

test "front door: old @TypeOf(re).Scratch.init form and re.initScratch agree" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\b\\w+\\b", &diag, .{});
    defer re.deinit();
    var old = try @TypeOf(re).Scratch.init(testing.allocator, &re.program);
    defer old.deinit(testing.allocator);
    var new = try re.initScratch(testing.allocator);
    defer new.deinit(testing.allocator);
    const input = "héllo wörld 42";
    try testing.expectEqual(re.count(&old, input), re.count(&new, input));
    try testing.expectEqualStrings(re.find(&old, input).?.slice(input), re.find(&new, input).?.slice(input));
    // Both are the same type: the old spelling is the wrapper too.
    try testing.expect(@TypeOf(old) == @TypeOf(new));
    // The backend's own scratch is reachable through `.inner` for Engine(B) callers.
    try testing.expect(@TypeOf(new.inner) == default_backend.Scratch);
    try testing.expectEqual(re.count(&new, input), backend.Engine(default_backend).count(&re.program, &new.inner, input, .{}));
}

/// A minimal backend whose `Scratch` has NO lifecycle decls at all (no `init`,
/// `deinit`, `reset`, `Buf`, `bufferLen`, `initBuffer`) — the contract's bare
/// minimum. No built-in backend exercises this path, so the wrapper's
/// missing-decl fallbacks are pinned here. Matches a single ASCII literal run.
const BareLiteral = struct {
    pub const caps = backend.Caps{ .captures = false, .stateless = true };
    pub const Program = struct { needle: []const u8 };
    pub const Scratch = struct {};
    pub const Options = struct {};

    pub fn buildAlloc(gpa: std.mem.Allocator, h: hir.Hir, _: BareLiteral.Options) backend.BuildError!Program {
        const root = h.nodes[h.root];
        if (root.tag != .literal) return error.Unsupported;
        const run = root.data.run;
        const needle = try gpa.alloc(u8, run.len);
        errdefer gpa.free(needle);
        for (h.literals[run.start..][0..run.len], 0..) |cp, i| {
            if (cp > 0x7F) return error.Unsupported;
            needle[i] = @intCast(cp);
        }
        return .{ .needle = needle };
    }
    pub fn buildComptime(comptime h: hir.Hir, comptime _: BareLiteral.Options) Program {
        const root = h.nodes[h.root];
        if (root.tag != .literal) @compileError("BareLiteral: not a literal");
        const run = root.data.run;
        var needle: [run.len]u8 = undefined;
        for (h.literals[run.start..][0..run.len], 0..) |cp, i| needle[i] = @intCast(cp);
        const frozen = needle;
        return .{ .needle = &frozen };
    }
    pub fn freeProgram(gpa: std.mem.Allocator, p: *Program) void {
        gpa.free(p.needle);
    }
    pub fn search(p: *const Program, _: *Scratch, input: []const u8, o: backend.SearchOptions) ?Match {
        var i = o.start;
        while (i + p.needle.len <= input.len) : (i += 1) {
            if (std.mem.eql(u8, input[i .. i + p.needle.len], p.needle))
                return .{ .start = i, .end = i + p.needle.len };
            if (o.anchored) return null;
        }
        return null;
    }
    pub fn isMatch(p: *const Program, s: *Scratch, input: []const u8, o: backend.SearchOptions) bool {
        return search(p, s, input, o) != null;
    }
};

test "front door: a backend Scratch with no lifecycle decls still works through the wrapper" {
    comptime backend.verifyBackend(BareLiteral);
    var diag: Diagnostic = .{};
    var re = try compileRuntimeWith(BareLiteral, testing.allocator, "dog", &diag, .{});
    defer re.deinit();
    var sc = try re.initScratch(testing.allocator); // no `init` on B.Scratch → `.{ .inner = .{} }`
    defer sc.deinit(testing.allocator); // no `deinit` → no-op
    sc.reset(); // no `reset` → no-op
    try testing.expectEqualStrings("dog", re.find(&sc, "hot dog").?.slice("hot dog"));
    try testing.expectEqual(@as(usize, 2), re.count(&sc, "dog dog"));
    try testing.expectEqual(@as(usize, 0), re.scratchBufferLen()); // no `bufferLen` → 0
    try testing.expect(@TypeOf(re).Scratch.Buf == void); // no `Buf` → void

    const cre = comptime compileComptimeWith(BareLiteral, "cat", .{});
    var csc = try cre.initScratch(testing.allocator);
    defer csc.deinit(testing.allocator);
    try testing.expect(cre.isMatch(&csc, "a cat"));
    try testing.expect(!cre.isMatch(&csc, "a dog"));
}

test "front door: Scratch.fromBackend wraps a hand-built backend scratch" {
    var diag: Diagnostic = .{};
    var re = try compileRuntime(testing.allocator, "\\d+", &diag, .{});
    defer re.deinit();
    const raw = try default_backend.Scratch.init(testing.allocator, &re.program);
    var sc = @TypeOf(re).Scratch.fromBackend(raw);
    defer sc.deinit(testing.allocator);
    try testing.expectEqualStrings("42", re.find(&sc, "x42y").?.slice("x42y"));
}

test {
    testing.refAllDecls(@This());
}

test "compile memory is linear in unrolled capture groups" {
    // The one-pass accelerator sized its transition table for states × insts up front, so
    // `(?:(a)){10000}` (40 002 units, far under `size_limit`) allocated 21 GB and
    // `(?:(a)){100000}` ~100 GB. Doubling the count must now roughly double the bytes.
    const gpa = testing.allocator;
    var totals: [2]usize = undefined;
    inline for (.{ "(?:(a)){5000}", "(?:(a)){10000}" }, 0..) |p, i| {
        var counting = std.testing.FailingAllocator.init(gpa, .{});
        var diag: Diagnostic = .{};
        var re = try compileRuntime(counting.allocator(), p, &diag, .{});
        re.deinit();
        totals[i] = counting.allocated_bytes;
    }
    try testing.expect(totals[1] < 32 << 20);
    try testing.expect(totals[1] <= 3 * totals[0] + (1 << 20));
}
