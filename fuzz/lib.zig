//! `fuzz_lib` — everything the ezi_gex fuzz binaries share.
//!
//! Each fuzz group (`fuzz/groups/*.zig`) compiles into its OWN test binary so the groups
//! fuzz in parallel; they all import this one module for the generators (`gen`), the
//! independent reference matcher (`ref`), and the check bodies (`check`). The aggregate
//! `fuzz` unit (`fuzz/root.zig`) imports it too. Its own unit tests run as a separate
//! binary chained into `zig build test-fuzz`.

pub const gen = struct {
    pub const replay = @import("gen/replay.zig");
    pub const pattern = @import("gen/pattern.zig");
    pub const input = @import("gen/input.zig");
    pub const props = @import("gen/props.zig");
    pub const tree = @import("gen/tree.zig");
    pub const print = @import("gen/print.zig");
    pub const witness = @import("gen/witness.zig");
    pub const literals = @import("gen/literals.zig");
};

pub const ref = @import("ref/root.zig");

pub const check = struct {
    pub const common = @import("check/common.zig");
    pub const known_open = @import("check/known_open.zig");
    pub const differential = @import("check/differential.zig");
    pub const reference = @import("check/reference.zig");
    pub const metamorphic = @import("check/metamorphic.zig");
    pub const invariants = @import("check/invariants.zig");
    pub const state = @import("check/state.zig");
    pub const large = @import("check/large.zig");
    /// Named `literal_sets` so it doesn't read as `gen.literals`.
    pub const literal_sets = @import("check/literals.zig");
    pub const api = @import("check/api.zig");
    pub const oom = @import("check/oom.zig");
    pub const comptime_parity = @import("check/comptime_parity.zig");
    pub const complexity = @import("check/complexity.zig");
    pub const utf8class = @import("check/utf8class.zig");
    pub const scanner = @import("check/scanner.zig");
    pub const grapheme = @import("check/grapheme.zig");
    pub const chaos = @import("check/chaos.zig");
    pub const registry = @import("check/registry.zig");
    pub const minimize = @import("check/minimize.zig");
};

test {
    _ = @import("gen/replay.zig");
    _ = @import("gen/pattern.zig");
    _ = @import("gen/input.zig");
    _ = @import("gen/props.zig");
    _ = @import("gen/tree.zig");
    _ = @import("gen/print.zig");
    _ = @import("gen/witness.zig");
    _ = @import("gen/literals.zig");
    _ = @import("ref/root.zig");
    _ = @import("ref/uni.zig");
    _ = @import("ref/selfcheck.zig");
    _ = @import("check/common.zig");
    _ = @import("check/known_open.zig");
    _ = @import("check/differential.zig");
    _ = @import("check/reference.zig");
    _ = @import("check/metamorphic.zig");
    _ = @import("check/invariants.zig");
    _ = @import("check/state.zig");
    _ = @import("check/large.zig");
    _ = @import("check/literals.zig");
    _ = @import("check/api.zig");
    _ = @import("check/oom.zig");
    _ = @import("check/comptime_parity.zig");
    _ = @import("check/complexity.zig");
    _ = @import("check/utf8class.zig");
    _ = @import("check/scanner.zig");
    _ = @import("check/grapheme.zig");
    _ = @import("check/chaos.zig");
    _ = @import("check/registry.zig");
    _ = @import("check/minimize.zig");
}
