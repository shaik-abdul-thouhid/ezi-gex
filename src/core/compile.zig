//! Build an AST from a regex pattern, choosing where the AST lives based on
//! comptime vs runtime. This is the storage/mode layer that sits on top of the
//! mode-agnostic parser in scanner.zig.
//!
//! Naming note: "compile" here is the `re.compile`-style front door — it turns a
//! pattern into the engine's in-memory form. That form is currently the AST
//! (parse → AST). It is NOT yet automaton compilation (AST → Thompson NFA);
//! that stage will be added later and will also live behind this module.
//!
//!   runtime  → `parse`  (heap-allocated AST; free with `Ast.deinit`)
//!   runtime  → `parseReporting` (same, but routes the diagnostic to a context)
//!   comptime → `parseComptime` (AST in `ro_data`; returns `.ok`/`.fail`)
//!   comptime → `compile` (AST in `ro_data`; `@compileError` on a bad pattern)
//!
//! The scanner itself knows nothing about comptime/runtime or allocation: it
//! fills caller-provided `Buffers`. Each function below just provisions those
//! buffers from the appropriate place (heap or comptime arrays), runs
//! `scanner.scan`, and finalizes the storage (dupe-to-exact on the heap, or
//! promote-to-const for ro_data).

const std = @import("std");

const ast = @import("ast.zig");
const errors = @import("error.zig");
const scanner = @import("scanner.zig");

pub const Ast = ast.Ast;
pub const Diagnostic = errors.Diagnostic;
pub const ErrorCode = errors.ErrorCode;
pub const Span = errors.Span;

/// Error returned by the runtime entry points. `InvalidPattern` carries its
/// detail in the `Diagnostic`; `OutOfMemory` comes from the allocator.
///
/// @stable-since: v0.1.0
pub const Error = errors.SyntaxError || std.mem.Allocator.Error;

/// Result of the comptime entry point. Comptime code cannot thread an
/// out-parameter the way runtime code does, so the diagnostic rides along here.
///
/// @stable-since: v0.1.0
pub const Outcome = union(enum) {
    ok: Ast,
    fail: Diagnostic,
};

// ── Runtime: heap ─────────────────────────────────────────────────────────────

/// Build an AST at runtime into heap memory. Provisions oversized scratch + AST
/// buffers from `allocator`, runs the agnostic scanner, then copies the used
/// portions into exactly-sized owned arrays and releases the scratch. On success
/// the returned AST owns its arrays; free them with `Ast.deinit(allocator)`. On a
/// malformed pattern, returns `error.InvalidPattern` and fills `diag` with the
/// precise code and byte span (see error.zig).
///
/// @stable-since: v0.1.0
pub fn parse(allocator: std.mem.Allocator, pattern: []const u8, diag: *Diagnostic) Error!Ast {
    const sizes = scanner.requiredSizes(pattern.len);

    // Oversized backing storage. Released unconditionally on the way out; the
    // exact-size AST arrays are duplicated from it on success.
    const nodes = try allocator.alloc(ast.Node, sizes.nodes);
    defer allocator.free(nodes);
    const children = try allocator.alloc(u32, sizes.children);
    defer allocator.free(children);
    const items = try allocator.alloc(ast.ClassItem, sizes.class_items);
    defer allocator.free(items);
    const names = try allocator.alloc([]const u8, sizes.names);
    defer allocator.free(names);
    const seq = try allocator.alloc(u32, sizes.seq);
    defer allocator.free(seq);
    const alt = try allocator.alloc(u32, sizes.alt);
    defer allocator.free(alt);
    const frames = try allocator.alloc(scanner.Frame, sizes.frames);
    defer allocator.free(frames);

    const raw = try scanner.scan(pattern, diag, .{
        .nodes = nodes,
        .children = children,
        .class_items = items,
        .names = names,
        .seq = seq,
        .alt = alt,
        .frames = frames,
    });

    const final_nodes = try allocator.dupe(ast.Node, raw.nodes);
    errdefer allocator.free(final_nodes);
    const final_children = if (raw.children.len == 0) &[_]u32{} else try allocator.dupe(u32, raw.children);
    errdefer if (final_children.len != 0) allocator.free(final_children);
    const final_items = if (raw.class_items.len == 0) &[_]ast.ClassItem{} else try allocator.dupe(ast.ClassItem, raw.class_items);
    errdefer if (final_items.len != 0) allocator.free(final_items);
    const final_names = if (raw.names.len == 0) &[_][]const u8{} else try allocator.dupe([]const u8, raw.names);

    return Ast{
        .nodes = final_nodes,
        .children = final_children,
        .class_items = final_items,
        .names = final_names,
        .root = raw.root,
        .capture_count = raw.capture_count,
        .flags = raw.flags,
    };
}

/// Build an AST at runtime, and on failure hand the diagnostic to a
/// caller-supplied context before returning the error. `ctx` is anything with a
///   `pub fn report(self, Diagnostic, pattern: []const u8) void`
/// method — that is where the caller does its own formatting/printing. The
/// allocation error path does not call `report` (there is no diagnostic for it).
///
/// @stable-since: v0.1.0
pub fn parseReporting(allocator: std.mem.Allocator, pattern: []const u8, ctx: anytype) Error!Ast {
    var diag: Diagnostic = .{};
    return parse(allocator, pattern, &diag) catch |e| {
        if (e == error.InvalidPattern) ctx.report(diag, pattern);
        return e;
    };
}

// ── Comptime: ro_data ─────────────────────────────────────────────────────────

/// Build an AST at comptime. Provisions the buffers as comptime arrays, runs the
/// agnostic scanner, then copies the used portions into const arrays that land
/// in `ro_data`. Returns `.ok` with an AST whose slices point at that const data,
/// or `.fail` with the diagnostic. Callers that want a hard compile error should
/// use `compile`.
///
/// @stable-since: v0.1.0
pub fn parseComptime(comptime pattern: []const u8) Outcome {
    // The quota is a CEILING on comptime backward-branches (a runaway-loop
    // guard), not a cost — raising it is free unless the work reaches it, and
    // the compiler stops at the actual work done. It must scale with the input
    // (a fixed quota would reject large patterns), but the real cost is small:
    // measured at well under ~25 branches/byte even for property-heavy patterns,
    // since the scan is a single O(n) pass. 1000/byte is a ~40x safety margin.
    // Saturate into u32 so an absurdly large comptime pattern fails with a clean
    // "exceeded backwards branches" rather than an integer-overflow message.
    const quota = @min(@as(u64, pattern.len) * 1000 + 1000, std.math.maxInt(u32));
    @setEvalBranchQuota(@intCast(quota));
    const sizes = comptime scanner.requiredSizes(pattern.len);

    var nodes: [sizes.nodes]ast.Node = undefined;
    var children: [sizes.children]u32 = undefined;
    var items: [sizes.class_items]ast.ClassItem = undefined;
    var names: [sizes.names][]const u8 = undefined;
    var seq: [sizes.seq]u32 = undefined;
    var alt: [sizes.alt]u32 = undefined;
    var frames: [sizes.frames]scanner.Frame = undefined;
    var diag: Diagnostic = .{};

    const raw = scanner.scan(pattern, &diag, .{
        .nodes = &nodes,
        .children = &children,
        .class_items = &items,
        .names = &names,
        .seq = &seq,
        .alt = &alt,
        .frames = &frames,
    }) catch return .{ .fail = diag };

    // Copy the used sub-slices into const arrays; `&` promotes them to ro_data
    // so the returned AST outlives this function's comptime locals.
    const final_nodes = raw.nodes[0..raw.nodes.len].*;
    const final_children = raw.children[0..raw.children.len].*;
    const final_items = raw.class_items[0..raw.class_items.len].*;
    const final_names = raw.names[0..raw.names.len].*;

    return .{ .ok = Ast{
        .nodes = &final_nodes,
        .children = &final_children,
        .class_items = &final_items,
        .names = &final_names,
        .root = raw.root,
        .capture_count = raw.capture_count,
        .flags = raw.flags,
    } };
}

/// Build an AST at comptime, failing compilation with a located message if the
/// pattern is invalid. The comptime analogue of "pretty-print the error": the
/// build stops and the developer sees exactly what and where.
///
/// @stable-since: v0.1.0
pub fn compile(comptime pattern: []const u8) Ast {
    comptime {
        return switch (parseComptime(pattern)) {
            .ok => |a| a,
            .fail => |d| @compileError(std.fmt.comptimePrint(
                "invalid regex: {s}\n  pattern: \"{s}\"\n  here:    \"{s}\" (bytes {d}..{d})",
                .{ d.message(), pattern, d.faultySlice(pattern), d.span.start, d.span.end },
            )),
        };
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Runtime parse, render to s-expr, compare, and free. Exercises the full heap
/// path (alloc → scan → dupe → deinit) under the leak-checking test allocator.
fn expectParseSExpr(pattern: []const u8, expected: []const u8) !void {
    var diag: Diagnostic = .{};
    const a = parse(testing.allocator, pattern, &diag) catch |e| {
        std.debug.print("unexpected {s} ({s}) parsing \"{s}\"\n", .{ @errorName(e), @tagName(diag.code), pattern });
        return e;
    };
    defer a.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try scanner.formatAst(a, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

/// Comptime parse, render to a comptime s-expr string.
fn comptimeSExpr(comptime pattern: []const u8) []const u8 {
    comptime {
        const a = compile(pattern);
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        scanner.formatAst(a, &w) catch unreachable;
        const out = w.buffered();
        const arr = out[0..out.len].*;
        return &arr;
    }
}

// ── Runtime / heap ──────────────────────────────────────────────────────────

test "parse builds an owned AST and frees cleanly" {
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, "(a|b)+c", &diag);
    defer a.deinit(testing.allocator);
    try testing.expect(a.nodes.len > 0);
    try testing.expectEqual(@as(u32, 1), a.capture_count);
    try testing.expect(diag.isOk());
}

test "parse round-trips through the heap (no leaks under the test allocator)" {
    try expectParseSExpr("a(b|c)*d", "(cat (lit a) (rep 0 inf g (cap 1 (alt (lit b) (lit c)))) (lit d))");
    try expectParseSExpr("\\d+", "(rep 1 inf g (cls \\d))");
    try expectParseSExpr("[a-z]{2,4}?", "(rep 2 4 l (cls a-z))");
}

test "parse reports a precise diagnostic on a bad pattern" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidPattern, parse(testing.allocator, "ab\\qcd", &diag));
    try testing.expectEqual(ErrorCode.unsupported_escape, diag.code);
    try testing.expectEqualStrings("\\q", diag.faultySlice("ab\\qcd"));
}

test "parse exposes capture count, names, and flags" {
    var diag: Diagnostic = .{};
    const a = try parse(testing.allocator, "(?i)(?<y>\\d{4})-(\\d{2})", &diag);
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), a.capture_count);
    try testing.expectEqual(@as(usize, 1), a.names.len);
    try testing.expectEqualStrings("y", a.names[0]);
    try testing.expect(a.flags.case_insensitive);
}

// ── parseReporting ──────────────────────────────────────────────────────────

const CollectCtx = struct {
    code: ErrorCode = .none,
    slice: []const u8 = "",
    fn report(self: *CollectCtx, diag: Diagnostic, pattern: []const u8) void {
        self.code = diag.code;
        self.slice = diag.faultySlice(pattern);
    }
};

test "parseReporting hands the diagnostic to the caller context" {
    var ctx = CollectCtx{};
    const r = parseReporting(testing.allocator, "a)", &ctx);
    try testing.expectError(error.InvalidPattern, r);
    try testing.expectEqual(ErrorCode.unmatched_close_paren, ctx.code);
    try testing.expectEqualStrings(")", ctx.slice);
}

test "parseReporting does not invoke report on success" {
    var ctx = CollectCtx{};
    const a = try parseReporting(testing.allocator, "abc", &ctx);
    defer a.deinit(testing.allocator);
    try testing.expectEqual(ErrorCode.none, ctx.code);
}

// ── Comptime / ro_data ──────────────────────────────────────────────────────

test "compile produces a usable ro_data AST" {
    const re = comptime compile("\\d{3}-\\d{4}");
    try testing.expect(re.nodes.len > 0);
    // The AST is const data baked into the binary — no allocator, no deinit.
    try testing.expectEqual(re.root, @as(u32, re.nodes.len - 1));
}

test "comptime build matches runtime build (parity)" {
    try testing.expectEqualStrings("(cat (lit a) (rep 0 inf g (lit b)))", comptime comptimeSExpr("ab*"));
    try testing.expectEqualStrings("(alt (lit a) (lit b))", comptime comptimeSExpr("a|b"));
    try testing.expectEqualStrings("(cap 1 (alt (lit a) (lit b)))", comptime comptimeSExpr("(a|b)"));
    try testing.expectEqualStrings("(cls a-z \\d)", comptime comptimeSExpr("[a-z\\d]"));
    // Same pattern, both paths, identical structure.
    try expectParseSExpr("(a|b)*", "(rep 0 inf g (cap 1 (alt (lit a) (lit b))))");
    try testing.expectEqualStrings("(rep 0 inf g (cap 1 (alt (lit a) (lit b))))", comptime comptimeSExpr("(a|b)*"));
}

test "parseComptime surfaces diagnostics without compiling" {
    const outcome = comptime parseComptime("a(b");
    switch (outcome) {
        .ok => return error.TestUnexpectedSuccess,
        .fail => |d| {
            try testing.expectEqual(ErrorCode.unclosed_group, d.code);
            try comptime testing.expectEqualStrings("(", d.faultySlice("a(b"));
        },
    }
}

test "comptime compiles a realistic, non-trivial pattern" {
    // ~70 bytes: named groups, classes, counted + unbounded quantifiers, anchors.
    // Proves the comptime quota is ample for real patterns.
    const re = comptime compile(
        "^(?<user>[A-Za-z0-9._%+-]+)@(?<host>[A-Za-z0-9.-]+)\\.(?<tld>[A-Za-z]{2,63})$",
    );
    try testing.expectEqual(@as(u32, 3), re.capture_count);
    try testing.expectEqualStrings("user", re.names[0]);
    try testing.expectEqualStrings("tld", re.names[2]);
}

test {
    testing.refAllDecls(@This());
}
