//! The execution engine: the backend contract + agnostic operations, the
//! backends, and (later) the `Regex`/`Compiled` front door. Depends on `core/`
//! (one way); `core/` never imports `engine/`.

pub const backend = @import("backend.zig");

/// Shared Thompson-NFA IR + compiler + code-point primitives (not a backend; the
/// pikevm and backtrack backends both execute it, differently).
pub const nfa = @import("nfa.zig");

/// Built-in backends. Each is independently pluggable; `auto` is the default
/// dispatcher that composes them. Third-party backends implementing the contract
/// (see `backend.verifyBackend`) drop in the same way.
pub const backends = struct {
    /// Pike VM — the general, captures-capable, linear-time backstop.
    pub const pikevm = @import("backends/pikevm.zig");
    /// Substring / literal-alternation fast path (stateless).
    pub const literal = @import("backends/literal.zig");
    /// Bounded backtracking — depth-first over the same NFA; fast on small inputs.
    pub const backtrack = @import("backends/backtrack.zig");
    /// The default dispatcher — composes the above, switching on analysis + input.
    pub const auto = @import("backends/auto.zig");
};

/// Cross-backend conformance tests (every backend agrees, runtime + comptime).
pub const conformance = @import("conformance.zig");

/// The front door: `compileRuntime` / `compileComptime` → `Compiled`.
pub const regex = @import("regex.zig");
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
