pub const token = @import("token.zig");
pub const ast = @import("ast.zig");
pub const errors = @import("error.zig");
pub const scanner = @import("scanner.zig");
pub const compile = @import("compile.zig");
pub const hir = @import("hir.zig");

// Pull every submodule's `test {}` blocks into THIS module's test binary, so
// `zig build test-core` (and the `core` unit of `zig build test`) runs them all.
// Without this, the per-module test artifact would discover no tests (the root
// only re-exports — it contains none of its own).
test {
    @import("std").testing.refAllDecls(@This());
}
