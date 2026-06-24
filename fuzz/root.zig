//! Aggregator for the ezi_gex fuzz suite.
//!
//! The suite is split into independently-compilable **groups** under `groups/`, each
//! its own test binary (their targets share the differential bodies in
//! `groups/harness.zig`). `zig build fuzz` depends on every group, and the build
//! scheduler runs independent run-steps concurrently — exactly like `zig build test`
//! runs the unit binaries at once — so the groups fuzz in PARALLEL, one process per
//! core, with no shell glue. Each group also has its own `zig build fuzz-<group>`.
//!
//! This file pulls every group into ONE binary so the suite also runs as an
//! ordinary, FINITE regression test: under a plain
//!
//!     zig build test-fuzz            # or the `fuzz` unit of `zig build test`
//!
//! `std.testing.fuzz` replays each group's seed corpus plus one empty input and
//! returns — a few iterations, milliseconds, no instrumentation. This is the
//! regression mode and is always safe to run in CI.
//!
//! To actually fuzz, bound it with `=N` (N iterations PER group):
//!
//!     zig build fuzz --fuzz=1M                 # all groups in parallel, 1M each (7M total)
//!     zig build fuzz-diff --fuzz=2M            # just the cross-backend differential
//!
//! ⚠️  Bare `--fuzz` (no `=N`) soaks forever by design — always pass `=N`.
//!
//! WHAT IS COVERED — see `harness.zig` (the differential bodies) and each group:
//!   scanner   — parse robustness + the `{m,n}` repetition ceiling (parse-only).
//!   diff      — span/find/isMatch across ALL backends (Pike VM oracle).
//!   anchors   — anchors + zero-width across all backends.
//!   unicode   — `\p{}`/scripts/folding over valid + raw UTF-8; `\X` no-crash.
//!   captures  — full capture-slot arrays across the capture backends.
//!   iter      — findAll sequence + count, and `$`-template replaceAll output.
//!   search    — findAt offset/anchored/span_end, and strategy results-invariance.

const std = @import("std");

test {
    _ = @import("groups/scanner.zig");
    _ = @import("groups/diff.zig");
    _ = @import("groups/anchors.zig");
    _ = @import("groups/unicode.zig");
    _ = @import("groups/captures.zig");
    _ = @import("groups/iter.zig");
    _ = @import("groups/search.zig");
}
