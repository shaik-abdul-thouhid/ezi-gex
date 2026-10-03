//! Delta debugging for a failing `Case`: re-run the exact check and keep every
//! simplification that still fails with the SAME error. Tree cases shrink node by node
//! (checks re-derive the pattern from the tree); string cases shrink pattern bytes; inputs
//! and templates shrink bytes in both. Bounded: at most 64 passes.

const std = @import("std");
const common = @import("common.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const Case = common.Case;
const testing = std.testing;

pub const Runner = *const fn (std.mem.Allocator, *const Case) anyerror!void;

fn failure(gpa: std.mem.Allocator, c: *const Case, runner: Runner) ?anyerror {
    runner(gpa, c) catch |e| return e;
    return null;
}

fn stillFails(gpa: std.mem.Allocator, c: *const Case, runner: Runner, err0: anyerror) bool {
    const e = failure(gpa, c, runner) orelse return false;
    return e == err0;
}

/// An owned copy of `c` — release with `deinitOwned`.
pub fn dupCase(gpa: std.mem.Allocator, c: *const Case) !Case {
    var out = c.*;
    out.pattern = try gpa.dupe(u8, c.pattern);
    errdefer gpa.free(out.pattern);
    out.input = try gpa.dupe(u8, c.input);
    errdefer gpa.free(out.input);
    out.template = try gpa.dupe(u8, c.template);
    errdefer gpa.free(out.template);
    out.tree = try gpa.dupe(u8, c.tree);
    return out;
}

/// `null` when `start` does not fail ("does not reproduce"); otherwise an owned, minimal case.
pub fn minimize(gpa: std.mem.Allocator, start: *const Case, runner: Runner) !?Case {
    const saved = common.quiet;
    common.quiet = true;
    defer common.quiet = saved;
    const err0 = failure(gpa, start, runner) orelse return null;
    var cur = try dupCase(gpa, start);
    errdefer cur.deinitOwned(gpa);
    var pass: usize = 0;
    while (pass < 64) : (pass += 1) {
        var changed = false;
        if (cur.tree.len > 0) {
            if (try shrinkTree(gpa, &cur, runner, err0)) changed = true;
        } else if (try shrinkField(gpa, &cur, "pattern", runner, err0)) changed = true;
        if (try shrinkField(gpa, &cur, "input", runner, err0)) changed = true;
        if (try shrinkField(gpa, &cur, "template", runner, err0)) changed = true;
        if (!changed) break;
    }
    return cur;
}

fn shrinkField(gpa: std.mem.Allocator, cur: *Case, comptime field: []const u8, runner: Runner, err0: anyerror) !bool {
    var any = false;
    var chunk: usize = @max(@field(cur, field).len / 2, 1);
    while (@field(cur, field).len > 0) {
        var i: usize = 0;
        var progressed = false;
        while (i < @field(cur, field).len) {
            const old = @field(cur, field);
            const n = @min(chunk, old.len - i);
            const cand = try gpa.alloc(u8, old.len - n);
            @memcpy(cand[0..i], old[0..i]);
            @memcpy(cand[i..], old[i + n ..]);
            var trial = cur.*;
            @field(trial, field) = cand;
            if (stillFails(gpa, &trial, runner, err0)) {
                gpa.free(old);
                @field(cur, field) = cand;
                progressed = true;
                any = true;
            } else {
                gpa.free(cand);
                i += n;
            }
        }
        if (!progressed) {
            if (chunk == 1) break;
            chunk /= 2;
        }
    }
    return any;
}

const n_edits = 8;

/// Edit number `k` applied to node `i`; false when it does not apply.
fn edit(t: *tree.Tree, i: u16, k: u8) bool {
    const n = t.nodes[i];
    switch (k) {
        0 => { // node → empty
            if (n.kind == .empty) return false;
            t.nodes[i] = .{ .kind = .empty, .flags = n.flags };
        },
        1 => switch (n.kind) { // node → its only child
            .repeat, .group, .flags => t.nodes[i] = t.nodes[n.first],
            .concat, .alt => {
                if (n.len != 1) return false;
                t.nodes[i] = t.nodes[t.kids[n.first]];
            },
            else => return false,
        },
        2 => { // repeat → exactly once
            if (n.kind != .repeat or (n.b == 1 and n.c == 1)) return false;
            t.nodes[i].b = 1;
            t.nodes[i].c = 1;
        },
        3 => { // bounded repeat → its minimum
            if (n.kind != .repeat or n.c == tree.unbounded or n.c == n.b) return false;
            t.nodes[i].c = n.b;
        },
        4 => { // drop the last kid
            if ((n.kind != .concat and n.kind != .alt) or n.len <= 1) return false;
            t.nodes[i].len -= 1;
        },
        5 => { // drop the first kid
            if ((n.kind != .concat and n.kind != .alt) or n.len <= 1) return false;
            t.nodes[i].first += 1;
            t.nodes[i].len -= 1;
        },
        6 => { // drop the last class item
            if (n.kind != .class or n.len <= 1) return false;
            t.nodes[i].len -= 1;
        },
        7 => switch (n.kind) { // un-negate a class / simplify a literal
            .class => {
                if (n.a == 0) return false;
                t.nodes[i].a = 0;
            },
            .lit => {
                if (n.cp == 'a') return false;
                t.nodes[i].cp = 'a';
            },
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn shrinkTree(gpa: std.mem.Allocator, cur: *Case, runner: Runner, err0: anyerror) !bool {
    var t = tree.Tree.fromBytes(cur.tree) orelse return false;
    var any = false;
    var i: u16 = 1; // node 0 is the shared empty leaf
    while (i < t.n_nodes) : (i += 1) {
        var k: u8 = 0;
        while (k < n_edits) : (k += 1) {
            var cand = t;
            if (!edit(&cand, i, k)) continue;
            cand.renumberGroups();
            if (!cand.wellFormed()) continue;
            const bytes = try gpa.dupe(u8, cand.bytes());
            var trial = cur.*;
            trial.tree = bytes;
            if (stillFails(gpa, &trial, runner, err0)) {
                gpa.free(cur.tree);
                cur.tree = bytes;
                t = cand;
                any = true;
            } else gpa.free(bytes);
        }
    }
    return any;
}

test "minimize reports a case that does not reproduce" {
    const pass = struct {
        fn f(_: std.mem.Allocator, _: *const Case) anyerror!void {}
    }.f;
    try testing.expect((try minimize(testing.allocator, &.{ .check = .span, .pattern = "ab", .input = "x" }, pass)) == null);
}

test "minimize shrinks pattern and input to the essential bytes" {
    const fake = struct {
        fn f(_: std.mem.Allocator, c: *const Case) anyerror!void {
            if (std.mem.findScalar(u8, c.pattern, 'b') != null and std.mem.find(u8, c.input, "xy") != null) return error.Boom;
        }
    }.f;
    const m = (try minimize(testing.allocator, &.{ .check = .span, .pattern = "aabbb", .input = "qqxyzz" }, fake)).?;
    defer m.deinitOwned(testing.allocator);
    try testing.expectEqualStrings("b", m.pattern);
    try testing.expectEqualStrings("xy", m.input);
}

test "minimize shrinks a tree node by node" {
    const fake = struct {
        fn f(_: std.mem.Allocator, c: *const Case) anyerror!void {
            const t = tree.Tree.fromBytes(c.tree) orelse return;
            const pr = print.canonical(&t, t.opt) orelse return;
            if (std.mem.findScalar(u8, pr.slice(), 'z') != null) return error.Boom;
        }
    }.f;
    var b = tree.Builder.init(0);
    const root = b.cat(&.{ b.lit('a'), b.star(b.group(b.alt(&.{ b.lit('z'), b.lit('y') }))), b.lit('q') });
    const t = b.finish(root);
    const m = (try minimize(testing.allocator, &.{ .check = .reference, .tree = t.bytes() }, fake)).?;
    defer m.deinitOwned(testing.allocator);
    const mt = tree.Tree.fromBytes(m.tree).?;
    try testing.expectEqualStrings("z", print.canonical(&mt, mt.opt).?.slice());
}
