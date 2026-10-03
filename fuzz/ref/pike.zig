//! A naive Pike VM over `nfa.Prog`: per-position thread lists in priority order; an
//! epsilon closure that visits each state at most once per position (the Thompson/Rust
//! dedup that defines the empty-loop tiebreak); per-thread capture slots; the unanchored
//! start thread appended at LOWEST priority until the first match. Steps by decoded
//! scalar; a malformed byte kills every consuming thread and the next position is one
//! byte on (dead-on-invalid). Slow and simple on purpose.

const std = @import("std");
const tree = @import("../gen/tree.zig");
const nfa = @import("nfa.zig");
const uni = @import("uni.zig");

pub const Search = struct { start: usize = 0, anchored: bool = false, span_end: ?usize = null };

const Threads = struct {
    sparse: []u32,
    dense: []u32,
    len: u32 = 0,
    slots: []?usize,
    ns: usize,

    fn init(gpa: std.mem.Allocator, n: usize, ns: usize) !Threads {
        const sparse = try gpa.alloc(u32, n);
        errdefer gpa.free(sparse);
        @memset(sparse, 0);
        const dense = try gpa.alloc(u32, n);
        errdefer gpa.free(dense);
        const slots = try gpa.alloc(?usize, n * ns);
        return .{ .sparse = sparse, .dense = dense, .slots = slots, .ns = ns };
    }

    fn deinit(self: *Threads, gpa: std.mem.Allocator) void {
        gpa.free(self.sparse);
        gpa.free(self.dense);
        gpa.free(self.slots);
    }

    fn contains(self: *const Threads, pc: u32) bool {
        const i = self.sparse[pc];
        return i < self.len and self.dense[i] == pc;
    }

    fn insert(self: *Threads, pc: u32) void {
        self.sparse[pc] = self.len;
        self.dense[self.len] = pc;
        self.len += 1;
    }

    fn slotsOf(self: *Threads, pc: u32) []?usize {
        return self.slots[pc * self.ns ..][0..self.ns];
    }
};

const Frame = union(enum) {
    explore: u32,
    restore: struct { slot: u32, val: ?usize },
};

fn wordBefore(input: []const u8, at: usize) bool {
    const d = uni.decodeBefore(input, at) orelse return false;
    return d.valid and uni.isWord(d.cp);
}

fn wordAfter(input: []const u8, at: usize) bool {
    if (at >= input.len) return false;
    const d = uni.decode(input, at);
    return d.valid and uni.isWord(d.cp);
}

pub fn assertHolds(k: tree.Assert, input: []const u8, at: usize) bool {
    return switch (k) {
        .text_start => at == 0,
        .text_end => at == input.len,
        .line_start => at == 0 or input[at - 1] == '\n',
        .line_end => at == input.len or input[at] == '\n',
        .word_boundary => wordBefore(input, at) != wordAfter(input, at),
        .not_word_boundary => wordBefore(input, at) == wordAfter(input, at),
    };
}

pub const Vm = struct {
    gpa: std.mem.Allocator,
    prog: *const nfa.Prog,
    t: *const tree.Tree,
    sem: tree.OptSem,

    /// Leftmost-first search. `slots_out.len == prog.n_slots`; on a match it holds the
    /// winning thread's slots (0/1 = the span). The haystack is clamped to `span_end`
    /// first, exactly as ezi_gex's `Engine` clamps it (assertions see the clamped end).
    pub fn search(vm: *const Vm, input_full: []const u8, so: Search, slots_out: []?usize) !bool {
        std.debug.assert(slots_out.len == vm.prog.n_slots);
        @memset(slots_out, null);
        const end = if (so.span_end) |e| @min(e, input_full.len) else input_full.len;
        if (so.start > end) return false;
        const input = input_full[0..end];
        const n = vm.prog.insts.len;
        const ns: usize = vm.prog.n_slots;
        var clist = try Threads.init(vm.gpa, n, ns);
        defer clist.deinit(vm.gpa);
        var nlist = try Threads.init(vm.gpa, n, ns);
        defer nlist.deinit(vm.gpa);
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(vm.gpa);
        const cur = try vm.gpa.alloc(?usize, ns);
        defer vm.gpa.free(cur);

        var matched = false;
        var at = so.start;
        while (true) {
            if (clist.len == 0 and (matched or (so.anchored and at > so.start))) break;
            if (!matched and (!so.anchored or at == so.start)) {
                @memset(cur, null);
                try vm.closure(input, at, vm.prog.start, cur, &clist, &stack);
            }
            const d: ?uni.Decoded = if (at < input.len) uni.decode(input, at) else null;
            const next_at = if (d) |dd| at + dd.len else at + 1;
            nlist.len = 0;
            for (clist.dense[0..clist.len]) |pc| {
                const inst = vm.prog.insts[pc];
                switch (inst.op) {
                    .match => {
                        @memcpy(slots_out, clist.slotsOf(pc));
                        matched = true;
                        break; // lower-priority threads are cut
                    },
                    .char => if (d) |dd| {
                        if (dd.valid and uni.charMatches(vm.t, vm.t.nodes[inst.arg], dd.cp, vm.sem)) {
                            @memcpy(cur, clist.slotsOf(pc));
                            try vm.closure(input, next_at, inst.x, cur, &nlist, &stack);
                        }
                    },
                    else => {},
                }
            }
            if (at >= input.len) break;
            std.mem.swap(Threads, &clist, &nlist);
            at = next_at;
        }
        return matched;
    }

    fn closure(vm: *const Vm, input: []const u8, at: usize, pc0: u32, cur: []?usize, list: *Threads, stack: *std.ArrayList(Frame)) !void {
        try stack.append(vm.gpa, .{ .explore = pc0 });
        while (stack.pop()) |f| {
            switch (f) {
                .restore => |r| cur[r.slot] = r.val,
                .explore => |start_pc| {
                    var pc = start_pc;
                    while (true) {
                        if (list.contains(pc)) break;
                        list.insert(pc);
                        const inst = vm.prog.insts[pc];
                        switch (inst.op) {
                            .match, .char => {
                                @memcpy(list.slotsOf(pc), cur);
                                break;
                            },
                            .jmp => pc = inst.x,
                            .split => {
                                try stack.append(vm.gpa, .{ .explore = inst.y });
                                pc = inst.x;
                            },
                            .save => {
                                if (inst.arg < cur.len) {
                                    try stack.append(vm.gpa, .{ .restore = .{ .slot = inst.arg, .val = cur[inst.arg] } });
                                    cur[inst.arg] = at;
                                }
                                pc = inst.x;
                            },
                            .assert => {
                                if (!assertHolds(@fromBackingInt(@intCast(inst.arg)), input, at)) break;
                                pc = inst.x;
                            },
                        }
                    }
                },
            }
        }
    }
};
