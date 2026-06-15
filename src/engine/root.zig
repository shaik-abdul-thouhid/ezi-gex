//! The execution engine: the backend contract + agnostic operations, the
//! backends, and the `Regex`/`Compiled` front door. Depends on `core/`
//! (one way); `core/` never imports `engine/`.
//!
//! This is the engine **aggregate** — a thin re-export over the per-unit modules
//! (`engine_base`, each backend, `regex`, `conformance`, `redos`). Each of those
//! is its own `b.addModule` boundary so its tests cache independently; this file
//! just gathers their public surface for the `ezi_gex` facade and downstream
//! consumers. It carries no `test {}` of its own — every test lives in (and runs
//! from) its owning unit's test binary.

const engine_base = @import("engine_base");

pub const backend = engine_base.backend;

/// Shared Thompson-NFA IR + compiler + code-point primitives (not a backend; the
/// pikevm and backtrack backends both execute it, differently).
pub const nfa = engine_base.nfa;

/// Byte-grained HIR lowering (UTF-8 automaton substrate; not a backend). The byte
/// Pike VM executes it; the lazy DFA (`backends.dfa`) determinizes it.
pub const byte = engine_base.byte;

/// Quarantined architecture-specific SIMD primitives (the dynamic byte shuffle that
/// backs the Teddy prefilter). The only file in the engine that emits target-specific
/// inline asm; everything else stays portable `@Vector`. Scalar fallback + comptime
/// path always correct.
pub const simd = engine_base.simd;

/// Teddy — the SIMD multi-literal prefilter (built on `simd`'s dynamic shuffle). Not a
/// backend; an accelerator for literal alternations / multi-prefix start-skips.
pub const teddy = engine_base.teddy;

/// memmem — a portable two-byte SIMD single-substring search (no arch asm). Not a backend;
/// the single-literal accelerator for the `literal` backend (Teddy's single-needle peer).
pub const memmem = engine_base.memmem;

/// classscan — a portable SIMD "next byte in a set" scan (built on `simd`'s dynamic shuffle,
/// scalar fallback + comptime path). Not a backend; the leading-class start-skip accelerator
/// `auto` uses for class-led patterns (`\d+`, `\p{N}+`) with no fixed leading literal.
pub const classscan = engine_base.classscan;

/// Built-in backends. Each is independently pluggable; `auto` is the default
/// dispatcher that composes them. Third-party backends implementing the contract
/// (see `backend.verifyBackend`) drop in the same way.
pub const backends = struct {
    /// Pike VM — the general, captures-capable, linear-time backstop.
    pub const pikevm = @import("pikevm");
    /// Substring / literal-alternation fast path (stateless).
    pub const literal = @import("literal");
    /// Bounded backtracking — depth-first over the same NFA; fast on small inputs.
    pub const backtrack = @import("backtrack");
    /// Byte Pike VM — executes the byte-grained `byte.Program` (zero-decode match).
    /// The reference executor for the byte lowering / substrate for the lazy DFA;
    /// not `auto`'s default. Refuses `\X` and `\b`/`\B` (not byte-lowerable).
    pub const bytepike = @import("bytepike");
    /// Lazy DFA — determinizes the byte automaton on the fly (cached transitions),
    /// one DFA state per input byte. The throughput backend: span-only
    /// (`caps.captures = false`) and runtime-only (no comptime). `auto` uses it for
    /// the span scan on eligible patterns; `pikevm` fills captures. Refuses `\X`,
    /// `\b`/`\B`, and zero-width anchors (not yet byte-DFA-able).
    pub const dfa = @import("dfa");
    /// Eager DFA — the **fully determinized**, frozen byte DFA. Span-only like `dfa`
    /// but **stateless** (the complete table is the whole matcher) and so usable at
    /// **comptime** (`buildComptime` bakes the table into `ro_data`) as well as runtime.
    /// The CTRE-lane DFA: a literal / ASCII-class pattern is a handful of states
    /// (`abc` → 5), ideal to bake; a big Unicode class is a few hundred (`\w+` → ~323).
    /// Bounded — a pattern whose full DFA exceeds `edfa.max_states` is declined (use
    /// `dfa` at runtime). Same capability gate as `dfa` (`supports`).
    pub const edfa = @import("edfa");
    /// One-pass NFA — a linear-time **capture** fast path for unambiguous patterns
    /// (`(\d{4})-(\d{2})-(\d{2})`, `(\w+)@(\w+)`): a single deterministic thread fills the
    /// slots, no thread set. Captures-capable and **stateless** (a frozen table), so it runs
    /// at **comptime** too. Declines (→ Pike VM) any pattern that is not provably one-pass, or
    /// that carries an assertion / `\X`. `auto` uses it for the anchored capture handoff.
    pub const onepass = @import("onepass");
    /// The default dispatcher — composes the above, switching on analysis + input.
    pub const auto = @import("auto");
};

/// Cross-backend conformance tests (every backend agrees, runtime + comptime).
pub const conformance = @import("conformance");

/// ReDoS-immunity regression suite — deterministic linear-work + crash-free guards.
pub const redos = @import("redos");

/// The front door: `compileRuntime` / `compileComptime` → `Compiled`.
pub const regex = @import("regex");
pub const compileRuntime = regex.compileRuntime;
pub const compileComptime = regex.compileComptime;
pub const compileRuntimeWith = regex.compileRuntimeWith;
pub const compileComptimeWith = regex.compileComptimeWith;
pub const Compiled = regex.Compiled;
pub const Options = regex.Options;
/// The default backend (the `auto` dispatcher).
pub const default_backend = regex.default_backend;

// Most-used contract surface, re-exported.
pub const Engine = backend.Engine;
pub const verifyBackend = backend.verifyBackend;
pub const Match = backend.Match;
pub const Captures = backend.Captures;
pub const Meta = backend.Meta;
pub const Caps = backend.Caps;
pub const SearchOptions = backend.SearchOptions;
pub const ScratchOptions = backend.ScratchOptions;
