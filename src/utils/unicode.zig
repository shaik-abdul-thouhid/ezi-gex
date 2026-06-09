//! The Unicode + text-encoding facade — **the only file in ezi_gex that imports
//! `ezi_code`.** Everything the engine knows about Unicode flows through here.
//!
//! Two layers:
//!
//!  1. **Re-exports** of the backend vocabulary the engine uses verbatim — the
//!     `CodePoint` scalar contract, the `utf8` codec, the `properties` /
//!     `scripts` / `casing` tables. These are thin aliases so call sites read
//!     `utils.unicode.utf8.decode…` instead of `ezi_code.encoding.utf8.decode…`,
//!     with no behavioral change.
//!
//!  2. **Value-added helpers** (added incrementally) that wrap the backend with
//!     engine-specific policy so the rest of the codebase stays simple:
//!       * `fold` — case-fold closures (`none` / `simple` / `full`, incl. the
//!         1→many full-fold rewrite like `ß` ↔ `ss`).
//!       * `grapheme` — UAX #29 grapheme-cluster (`\X`) helpers.
//!       * decode policy — a single definition of how invalid UTF-8 is treated
//!         at match time (so every backend agrees — see DESIGN.md §2.3).
//!
//! ## Contract / invariants
//!
//!   * `CodePoint` is a *contract*: a value of this type is assumed to be a valid
//!     Unicode scalar (≤ U+10FFFF, not a surrogate) unless an API says otherwise.
//!   * Re-exported namespaces carry `ezi_code`'s own guarantees unchanged; see
//!     `ezi_code/encoding/README.md` and the `ezi_code` unicode docs.
//!
//! ## Adding to the facade
//!
//! Need a backend symbol that isn't here yet? Add it in THIS file (a re-export,
//! or a documented wrapper) and reach it via `utils.unicode.<thing>`. Do not
//! re-introduce `@import("ezi_code")` elsewhere — that is the whole point.

const ezi_code = @import("ezi_code");

// ── Layer 1: backend vocabulary (verbatim re-exports) ─────────────────────────

/// The Unicode scalar type used throughout the engine: `u21`, holding a valid
/// code point (the contract — see the file header). HIR ranges, literals, and
/// every decode result are `CodePoint`s.
///
/// @stable-since: v0.1.0
pub const CodePoint = ezi_code.encoding.CodePoint;

/// The shared encoding vocabulary: `MAX_ASCII`, `INVALID_CODE_POINT` (U+FFFD),
/// `validateCodePoint`, `isValidCodePoint`, `isAscii`, `isSurrogateCodePoint`,
/// `isSupplementary`, plus the per-codec namespaces. Prefer the narrower aliases
/// below (`utf8`, `CodePoint`) where they fit; reach for `encoding.*` for the
/// constants and predicates.
///
/// @stable-since: v0.1.0
pub const encoding = ezi_code.encoding;

/// The UTF-8 codec: strict / unchecked / lossy validate · decode (forward AND
/// reverse) · encode · views · iterators, with fine-grained error sets. The
/// engine uses the forward/reverse decode entry points for its match loop and
/// for `\b` look-behind. (Bulk SIMD scanners — `asciiRunLength`,
/// `simdLossyIterator`, … — also live here for future byte-engine work.)
///
/// @stable-since: v0.1.0
pub const utf8 = ezi_code.encoding.utf8;

/// Unicode character properties: `isWord` (Perl `\w`), `General_Category` and its
/// groups, `DerivedCoreProperty`, and the `\p{…}` resolution surface. Drives
/// `\w` / `\d` / `\s` and `\p{…}` class resolution in the HIR.
///
/// @stable-since: v0.1.0
pub const properties = ezi_code.unicode.properties;

/// Script + Script_Extensions data and name resolution (`ScriptType`,
/// `fromAbbreviation`). Backs `\p{Script=…}` / `\p{scx=…}`.
///
/// @stable-since: v0.1.0
pub const scripts = ezi_code.unicode.scripts;

/// Case folding + special casing tables (e.g. `case_folding.common_simple_table`).
/// Backs the `(?i)` fold-orbit expansion in the HIR. The richer `fold` helpers
/// below are built on top of this.
///
/// @stable-since: v0.1.0
pub const casing = ezi_code.unicode.casing;

// ── Layer 2: value-added helpers ──────────────────────────────────────────────
//
// Engine-specific Unicode policy wrapping the backend. Implemented incrementally
// (see DESIGN.md): full case folding, grapheme (`\X`) segmentation, and the
// shared invalid-UTF-8 decode policy will be added here so every call site and
// every backend shares one definition. New helpers land in this section with the
// same doc density as the re-exports above.

/// UAX #29 segmentation (grapheme / word / sentence breaking) and its iterators.
/// Backs `\X` (grapheme cluster) via the `grapheme` helper below.
///
/// @stable-since: v0.2.0
pub const segmentation = ezi_code.unicode.segmentation;

/// Grapheme-cluster (`\X`) helpers built on UAX #29 segmentation.
pub const grapheme = struct {
    /// Byte length of the extended grapheme cluster beginning at `bytes[offset..]`.
    /// Returns 0 at/after end-of-input; otherwise always ≥ 1 (a degenerate cluster
    /// still advances one byte, so a scanner using this always makes progress).
    ///
    /// @stable-since: v0.2.0
    pub fn lengthAt(bytes: []const u8, offset: usize) usize {
        if (offset >= bytes.len) return 0;
        var it = segmentation.iterator(bytes[offset..]);
        const g = it.next() orelse return 1;
        return if (g.len == 0) 1 else g.len;
    }
};

test {
    // Touch the re-exports so a backend symbol that vanishes upstream is caught
    // here (at the seam) rather than deep in a call site.
    const std = @import("std");
    std.testing.refAllDecls(@This());
    comptime {
        std.debug.assert(CodePoint == u21);
    }
}
