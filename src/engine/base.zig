//! `engine_base` — the shared engine substrate, as one named module.
//!
//! These seven files are **not backends**: they are the common substrate every
//! backend executes or builds on (the backend contract, the code-point and
//! byte-grained Thompson-NFA IRs, and the portable/quarantined SIMD prefilters).
//! Bundling them behind a single `b.addModule` boundary lets each *backend* test
//! binary scope to only its own file — a backend imports `engine_base` by name,
//! so the substrate's `test {}` blocks compile into THIS binary, not the
//! backend's. Editing one backend therefore never recompiles the substrate's
//! tests (and vice versa); Zig's build cache reuses whichever side is unchanged.
//!
//! The substrate files import each other by *relative* path (they are one
//! module) and reach `core`/`utils` by *named* import.

const std = @import("std");

/// The backend contract: `Match`, `Captures`, `SearchOptions`, `Caps`, the
/// agnostic `Engine`, `verifyBackend`, and the optional `Cell`/`Carver` scratch
/// helpers (not contract-mandated).
pub const backend = @import("backend.zig");

/// Shared code-point Thompson-NFA IR + HIR→program compiler + match primitives
/// (decode / `inRanges` / `assertionHolds`). Not a backend; pikevm and backtrack
/// both execute it.
pub const nfa = @import("nfa.zig");

/// Byte-grained HIR lowering (the UTF-8 automaton substrate). The byte Pike VM
/// executes it; the DFAs determinize it.
pub const byte = @import("byte.zig");

/// Quarantined architecture-specific SIMD primitives (the dynamic byte shuffle
/// behind Teddy). Scalar fallback + comptime path always correct.
pub const simd = @import("simd.zig");

/// Teddy — the SIMD multi-literal prefilter (built on `simd`'s dynamic shuffle).
pub const teddy = @import("teddy.zig");

/// memmem — a portable two-byte SIMD single-substring search (no arch asm).
pub const memmem = @import("memmem.zig");

/// classscan — a portable SIMD "next byte in a set" scan (built on `simd`).
pub const classscan = @import("classscan.zig");

test {
    std.testing.refAllDecls(@This());
}
