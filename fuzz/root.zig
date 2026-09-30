//! Aggregator for the ezi_gex fuzz suite.
//!
//! The suite is split into independently-compilable **groups** under `groups/`, each
//! its own test binary (their targets share the differential bodies in
//! `check/differential.zig`). `zig build fuzz` depends on every group, and the build
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
//!     zig build fuzz --fuzz=100K               # all 19 groups in parallel, 100K each
//!     zig build fuzz-reference --fuzz=1M       # one group
//!
//! ⚠️  Bare `--fuzz` (no `=N`) soaks forever by design — always pass `=N`.
//!
//! What each group checks, health floors, and triage: fuzz/README.md.

const std = @import("std");

test {
    _ = @import("groups/scanner.zig");
    _ = @import("groups/diff.zig");
    _ = @import("groups/anchors.zig");
    _ = @import("groups/unicode.zig");
    _ = @import("groups/captures.zig");
    _ = @import("groups/iter.zig");
    _ = @import("groups/search.zig");
    _ = @import("groups/reference.zig");
    _ = @import("groups/metamorphic.zig");
    _ = @import("groups/invariants.zig");
    _ = @import("groups/state.zig");
    _ = @import("groups/large.zig");
    _ = @import("groups/literals.zig");
    _ = @import("groups/api.zig");
    _ = @import("groups/oom.zig");
    _ = @import("groups/comptime_parity.zig");
    _ = @import("groups/complexity.zig");
    _ = @import("groups/utf8class.zig");
    _ = @import("groups/chaos.zig");
    _ = @import("health.zig");
    _ = @import("findings.zig");
    _ = @import("threads.zig");
}
