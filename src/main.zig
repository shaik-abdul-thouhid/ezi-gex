const std = @import("std");
const Io = std.Io;

const ezi_gex = @import("ezi_gex");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

// ── Usage examples (also serve as consumer-side API tests) ────────────────────

test "usage: runtime parse, inspect, free" {
    const gpa = std.testing.allocator;
    const pattern = "(\\w+)@(\\w+)";

    var diag: ezi_gex.Diagnostic = .{};
    const re = ezi_gex.parse(gpa, pattern, &diag) catch |err| {
        // Caller decides how to surface the error.
        std.debug.print("regex error: {s} at \"{s}\"\n", .{ diag.message(), diag.faultySlice(pattern) });
        return err;
    };
    defer re.deinit(gpa); // heap AST: free when done

    try std.testing.expectEqual(@as(u32, 2), re.capture_count);
    try std.testing.expect(re.nodes.len > 0);
    // re.nodes[re.root] is the tree root; walk from there.
}

// `compile` runs at compile time, so call it in a comptime context: either at
// container scope (like this) or with the `comptime` keyword inside a function.
const phone_re = ezi_gex.compile("\\d{3}-\\d{4}");

test "usage: comptime compile bakes the AST into the binary (no allocator)" {
    // `phone_re`'s slices point into .rodata. No deinit, no parsing at runtime.
    // An invalid pattern would have been a compile error.
    try std.testing.expect(phone_re.nodes.len > 0);
}

test "usage: bad pattern yields a precise diagnostic" {
    var diag: ezi_gex.Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidPattern,
        ezi_gex.parse(std.testing.allocator, "a(b", &diag),
    );
    try std.testing.expectEqual(ezi_gex.ErrorCode.unclosed_group, diag.code);
    try std.testing.expectEqualStrings("(", diag.faultySlice("a(b"));
}

/// Example AST walk: count how many literal code points a pattern matches
/// unconditionally (ignoring quantifiers/alternation), just to show traversal.
fn countLiterals(re: ezi_gex.Ast, idx: u32) usize {
    const node = re.nodes[idx];
    return switch (node.tag) {
        .literal => 1,
        .concat, .alternation => blk: {
            const d = node.data.children;
            var total: usize = 0;
            for (re.children[d.start .. d.start + d.len]) |c| total += countLiterals(re, c);
            break :blk total;
        },
        .range => countLiterals(re, node.data.range.child),
        .capture => countLiterals(re, node.data.capture.child),
        .non_capture => countLiterals(re, node.data.non_capture.child),
        else => 0,
    };
}

test "usage: walk the AST" {
    const re = comptime ezi_gex.compile("ab(cd)");
    try std.testing.expectEqual(@as(usize, 4), countLiterals(re, re.root));
}
