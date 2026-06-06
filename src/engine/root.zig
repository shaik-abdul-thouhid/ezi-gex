//! The execution engine: the backend contract + agnostic operations, the
//! backends, and (later) the `Regex`/`Compiled` front door. Depends on `core/`
//! (one way); `core/` never imports `engine/`.

pub const backend = @import("backend.zig");

/// Built-in backends. `auto` (the default dispatcher) lands here later.
pub const backends = struct {
    pub const pikevm = @import("backends/pikevm.zig");
};

/// The front door: `compileRuntime` / `compileComptime` → `Compiled`.
pub const regex = @import("regex.zig");
pub const compileRuntime = regex.compileRuntime;
pub const compileComptime = regex.compileComptime;
pub const compileRuntimeWith = regex.compileRuntimeWith;
pub const compileComptimeWith = regex.compileComptimeWith;
pub const Compiled = regex.Compiled;

// Most-used contract surface, re-exported.
pub const Engine = backend.Engine;
pub const verifyBackend = backend.verifyBackend;
pub const Match = backend.Match;
pub const Captures = backend.Captures;
pub const Meta = backend.Meta;
pub const Caps = backend.Caps;
pub const SearchOptions = backend.SearchOptions;
pub const ScratchOptions = backend.ScratchOptions;
