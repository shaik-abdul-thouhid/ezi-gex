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
    pub const differential = @import("check/differential.zig");
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
    _ = @import("check/differential.zig");
}
