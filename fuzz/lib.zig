//! `fuzz_lib` — everything the ezi_gex fuzz binaries share.
//!
//! Each fuzz group (`fuzz/groups/*.zig`) compiles into its OWN test binary so the groups
//! fuzz in parallel; they all import this one module for the generators (`gen`), the
//! independent reference matcher (`ref`), and the check bodies (`check`). The aggregate
//! `fuzz` unit (`fuzz/root.zig`) imports it too. Its own unit tests run as a separate
//! binary chained into `zig build test-fuzz`.

const std = @import("std");

pub const gen = struct {
    pub const pattern = @import("gen/pattern.zig");
    pub const input = @import("gen/input.zig");
};

pub const check = struct {
    pub const common = @import("check/common.zig");
    pub const differential = @import("check/differential.zig");
};

test {
    _ = @import("gen/pattern.zig");
    _ = @import("gen/input.zig");
    _ = @import("check/common.zig");
    _ = @import("check/differential.zig");
}
