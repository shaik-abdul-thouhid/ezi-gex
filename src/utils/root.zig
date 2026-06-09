//! `utils` — ezi_gex's internal support layer, and its **single seam to the
//! Unicode/encoding backend** (`ezi_code`).
//!
//! Every Unicode / text-encoding capability the regex engine needs — decoding
//! UTF-8, classifying code points (`\w`, `\d`, `\s`), resolving `\p{…}`
//! properties and scripts, case folding, and grapheme segmentation (`\X`) — is
//! delegated to `ezi_code`. To keep that dependency **in exactly one place**, the
//! rest of the engine (`core/`, `engine/`, the backends) never imports `ezi_code`
//! directly: it imports THIS module and reaches the backend through
//! `utils.unicode.*`.
//!
//! The payoff of the single seam:
//!   * **One place to evolve.** Swapping a backend symbol, adding a value-added
//!     wrapper (e.g. full case folding, a grapheme iterator, an invalid-UTF-8
//!     decode policy), or pinning a Unicode version touches one file, not nine.
//!   * **A real boundary, eventually enforced by the build.** The end state makes
//!     `utils` its own Zig module that alone imports `ezi_code`; the `ezi_gex`
//!     module drops its `ezi_code` import, so a stray `@import("ezi_code")`
//!     anywhere else becomes a *compile error*, not a convention violation.
//!     (Until that flip lands, the rule is enforced by review + this header.)
//!
//! ## How to use it (from anywhere in the engine)
//!
//! ```zig
//! const utils = @import("../utils/root.zig"); // adjust the relative depth
//! const CodePoint = utils.unicode.CodePoint;   // the u21 scalar contract
//!
//! // decode one scalar at a byte offset (forward), backend-agnostic:
//! const d = utils.unicode.utf8.validateAndDecodeCodePointBytes(input, sp);
//! // classify a code point for `\w`:
//! _ = utils.unicode.properties.isWord(cp);
//! ```
//!
//! NEVER write `@import("ezi_code")` outside this module. If you need a backend
//! symbol the facade does not yet expose, add it to `unicode.zig` (re-export, or
//! wrap with a doc comment), then use it through `utils.unicode`.

/// The Unicode + text-encoding facade: the one file that imports `ezi_code`.
/// Re-exports the backend vocabulary the engine uses (`CodePoint`, `utf8`,
/// `properties`, `scripts`, `casing`) and is the home for value-added helpers
/// (full case folding, grapheme segmentation, decode policies).
pub const unicode = @import("unicode.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
