//! The facts linear scan reads off a MIR fn before it allocates: the control-flow graph,
//! a position for every instruction, which virtual registers are live into and out of each
//! block, and how deeply each block sits in loops.
//!
//! POSITIONS. Blocks are numbered in layout order. Block `b` covers `[from[b], to[b])`:
//! `from[b]` is its label, which no instruction has, and its k-th instruction is at
//! `from[b] + 2 + 2k`. An instruction reads its uses at its own (even) position and writes
//! its defs at the next (odd) one, so a value can die and another be born in the same
//! register at one instruction. Moves an allocator adds go before the instruction at an
//! even position, or on a control-flow edge when the position is a label.

const std = @import("std");
const Mir = @import("Mir.zig");

pub fn Liveness(comptime Inst: type) type {
    return struct {
        const Self = @This();
        const Func = Mir.Function(Inst);

        from: []u32,
        to: []u32,
        /// Each block's successors, one entry per edge (a two-way exit to one block counts
        /// twice), in the order its branches name them.
        succs: [][]u32,
        /// Each block's predecessors, one entry per edge.
        preds: [][]u32,
        /// Per block, the virtual registers live into and out of it, ascending. Sparse
        /// lists, not a bit per register per block: a long fn has many of both, and few
        /// of its registers are live at any one block.
        live_in: [][]u32,
        live_out: [][]u32,
        /// How many loops each block is in.
        depth: []u32,
        /// The last position in each block where moves may go in-line: the first of its
        /// trailing branches, so a move never runs on one exit of a two-way branch only.
        last_split: []u32,
        /// The memory of the per-block lists above, one buffer each: a block's list is a
        /// slice of it, so a fn of many small blocks costs four allocations, not four per
        /// block.
        store: [4][]u32 = @splat(&.{}),

        pub fn deinit(l: *Self, gpa: std.mem.Allocator) void {
            gpa.free(l.from);
            gpa.free(l.to);
            gpa.free(l.succs);
            gpa.free(l.preds);
            gpa.free(l.live_in);
            gpa.free(l.live_out);
            for (l.store) |buf| gpa.free(buf);
            gpa.free(l.depth);
            gpa.free(l.last_split);
            l.* = undefined;
        }

        pub fn instPos(l: *const Self, block: usize, k: usize) u32 {
            return l.from[block] + 2 + 2 * @as(u32, @intCast(k));
        }

        /// The block whose positions include `pos`.
        pub fn blockOf(l: *const Self, pos: u32) u32 {
            var lo: usize = 0;
            var hi: usize = l.from.len;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (l.from[mid] <= pos) lo = mid else hi = mid;
            }
            return @intCast(lo);
        }

        pub fn isLiveIn(l: *const Self, block: usize, v: u32) bool {
            return contains(l.live_in[block], v);
        }

        pub fn isLiveOut(l: *const Self, block: usize, v: u32) bool {
            return contains(l.live_out[block], v);
        }

        fn contains(set: []const u32, v: u32) bool {
            return std.sort.binarySearch(u32, set, v, struct {
                fn order(key: u32, x: u32) std.math.Order {
                    return std.math.order(key, x);
                }
            }.order) != null;
        }

        pub fn isLabel(l: *const Self, pos: u32) bool {
            return l.from[l.blockOf(pos)] == pos;
        }

        pub fn compute(gpa: std.mem.Allocator, f: *Func) error{OutOfMemory}!Self {
            const n = f.blocks.len;
            var l: Self = .{
                .from = try gpa.alloc(u32, n),
                .to = try gpa.alloc(u32, n),
                .succs = try gpa.alloc([]u32, n),
                .preds = try gpa.alloc([]u32, n),
                .live_in = try gpa.alloc([]u32, n),
                .live_out = try gpa.alloc([]u32, n),
                .depth = try gpa.alloc(u32, n),
                .last_split = try gpa.alloc(u32, n),
            };
            for (l.succs, l.preds, l.live_in, l.live_out) |*s, *p, *i, *o| {
                s.* = &.{};
                p.* = &.{};
                i.* = &.{};
                o.* = &.{};
            }
            errdefer l.deinit(gpa);

            var pos: u32 = 0;
            for (f.blocks, 0..) |*b, bi| {
                l.from[bi] = pos;
                pos += 2 + 2 * @as(u32, @intCast(b.insts.items.len));
                l.to[bi] = pos;
            }
            try l.edges(gpa, f);
            try l.liveness(gpa, f);
            try l.loops(gpa);
            return l;
        }

        fn edges(l: *Self, gpa: std.mem.Allocator, f: *Func) error{OutOfMemory}!void {
            const n = f.blocks.len;
            const n_preds = try gpa.alloc(u32, n);
            defer gpa.free(n_preds);
            @memset(n_preds, 0);
            var n_edges: usize = 0;
            for (f.blocks, 0..) |*b, bi| {
                var trailing: usize = b.insts.items.len;
                while (trailing > 0 and b.insts.items[trailing - 1].branchTarget() != null) trailing -= 1;
                n_edges += b.insts.items.len - trailing;
                l.last_split[bi] = if (b.insts.items.len == 0)
                    l.from[bi]
                else
                    l.instPos(bi, @min(trailing, b.insts.items.len - 1));
            }
            l.store[0] = try gpa.alloc(u32, n_edges);
            l.store[1] = try gpa.alloc(u32, n_edges);
            var at: usize = 0;
            for (f.blocks, 0..) |*b, bi| {
                const start = at;
                var k = b.insts.items.len;
                while (k > 0 and b.insts.items[k - 1].branchTarget() != null) k -= 1;
                for (b.insts.items[k..]) |i| {
                    const t = i.branchTarget().?;
                    l.store[0][at] = t;
                    at += 1;
                    n_preds[t] += 1;
                }
                l.succs[bi] = l.store[0][start..at];
            }
            at = 0;
            for (l.preds, n_preds) |*p, c| {
                p.* = l.store[1][at..][0..c];
                at += c;
            }
            @memset(n_preds, 0);
            for (l.succs, 0..) |ss, bi| for (ss) |s| {
                l.preds[s][n_preds[s]] = @intCast(bi);
                n_preds[s] += 1;
            };
        }

        /// Per register, from each block that reads it before writing it, walk back
        /// through predecessors until the blocks that write it: those it reaches are
        /// where it is live in, and their predecessors where it is live out. The work is
        /// the size of the live sets, where a dataflow over dense sets costs blocks times
        /// registers per pass.
        fn liveness(l: *Self, gpa: std.mem.Allocator, f: *Func) error{OutOfMemory}!void {
            const n = f.blocks.len;
            const nv = f.vregs.items.len;
            const none = std.math.maxInt(u32);
            const Pair = struct { v: u32, b: u32 };
            // Per block, its upward-exposed reads and its writes, by register.
            var reads: std.ArrayList(Pair) = .empty;
            defer reads.deinit(gpa);
            var writes: std.ArrayList(Pair) = .empty;
            defer writes.deinit(gpa);
            const written_in = try gpa.alloc(u32, nv);
            defer gpa.free(written_in);
            const read_in = try gpa.alloc(u32, nv);
            defer gpa.free(read_in);
            @memset(written_in, none);
            @memset(read_in, none);
            for (f.blocks, 0..) |*b, bi_usize| {
                const bi: u32 = @intCast(bi_usize);
                for (b.insts.items) |*inst| {
                    var buf: [Mir.max_operands]Mir.Operand = undefined;
                    const ops = inst.operands(&buf);
                    for (ops) |o| if (o.kind != .def and o.reg.*.isVirtual()) {
                        const v = o.reg.*.index();
                        if (written_in[v] == bi or read_in[v] == bi) continue;
                        read_in[v] = bi;
                        try reads.append(gpa, .{ .v = v, .b = bi });
                    };
                    for (ops) |o| if (o.kind == .def and o.reg.*.isVirtual()) {
                        const v = o.reg.*.index();
                        if (written_in[v] == bi) continue;
                        written_in[v] = bi;
                        try writes.append(gpa, .{ .v = v, .b = bi });
                    };
                }
            }
            const byReg = struct {
                fn less(_: void, x: Pair, y: Pair) bool {
                    return x.v < y.v or (x.v == y.v and x.b < y.b);
                }
            }.less;
            std.mem.sort(Pair, reads.items, {}, byReg);
            std.mem.sort(Pair, writes.items, {}, byReg);

            // (block, register) in the order found, which is by register: bucketed by
            // block afterwards, in that order, each block's list comes out sorted.
            var ins: std.ArrayList(Pair) = .empty;
            defer ins.deinit(gpa);
            var outs: std.ArrayList(Pair) = .empty;
            defer outs.deinit(gpa);
            // Per block, the last register found live in, live out, or written there; the
            // registers go in ascending order, so each list comes out sorted.
            const in_mark = try gpa.alloc(u32, n);
            defer gpa.free(in_mark);
            const out_mark = try gpa.alloc(u32, n);
            defer gpa.free(out_mark);
            const write_mark = try gpa.alloc(u32, n);
            defer gpa.free(write_mark);
            @memset(in_mark, none);
            @memset(out_mark, none);
            @memset(write_mark, none);
            var work: std.ArrayList(u32) = .empty;
            defer work.deinit(gpa);
            var r: usize = 0;
            var w: usize = 0;
            while (r < reads.items.len) {
                const v = reads.items[r].v;
                while (w < writes.items.len and writes.items[w].v < v) w += 1;
                while (w < writes.items.len and writes.items[w].v == v) : (w += 1) write_mark[writes.items[w].b] = v;
                while (r < reads.items.len and reads.items[r].v == v) : (r += 1) {
                    const b = reads.items[r].b;
                    if (in_mark[b] == v) continue;
                    in_mark[b] = v;
                    try ins.append(gpa, .{ .v = v, .b = b });
                    try work.append(gpa, b);
                }
                while (work.pop()) |b| for (l.preds[b]) |p| {
                    if (out_mark[p] != v) {
                        out_mark[p] = v;
                        try outs.append(gpa, .{ .v = v, .b = p });
                    }
                    if (write_mark[p] == v or in_mark[p] == v) continue;
                    in_mark[p] = v;
                    try ins.append(gpa, .{ .v = v, .b = p });
                    try work.append(gpa, p);
                };
            }
            l.store[2] = try bucket(gpa, ins.items, l.live_in, in_mark);
            l.store[3] = try bucket(gpa, outs.items, l.live_out, in_mark);
        }

        /// Stable counting sort of `pairs` by block into one buffer, with `lists[b]` the
        /// slice of block `b`. `count` is scratch of one entry per block.
        fn bucket(gpa: std.mem.Allocator, pairs: anytype, lists: [][]u32, count: []u32) error{OutOfMemory}![]u32 {
            const buf = try gpa.alloc(u32, pairs.len);
            @memset(count, 0);
            for (pairs) |pr| count[pr.b] += 1;
            var at: u32 = 0;
            for (lists, count) |*list, *c| {
                list.* = buf[at..][0..c.*];
                const len = c.*;
                c.* = at;
                at += len;
            }
            for (pairs) |pr| {
                buf[count[pr.b]] = pr.v;
                count[pr.b] += 1;
            }
            return buf;
        }

        /// Loop depth from natural loops: an edge to a block that dominates its source is a
        /// back edge, and the loop is every block that reaches the source without passing
        /// the header. Dominators come from the Cooper-Harvey-Kennedy iteration over
        /// reverse postorder.
        fn loops(l: *Self, gpa: std.mem.Allocator) error{OutOfMemory}!void {
            const n = l.from.len;
            @memset(l.depth, 0);
            const none = std.math.maxInt(u32);
            const rpo_num = try gpa.alloc(u32, n);
            defer gpa.free(rpo_num);
            @memset(rpo_num, none);
            var order: std.ArrayList(u32) = .empty;
            defer order.deinit(gpa);
            {
                // Iterative DFS: (block, next successor index).
                var stack: std.ArrayList([2]u32) = .empty;
                defer stack.deinit(gpa);
                const seen = try gpa.alloc(bool, n);
                defer gpa.free(seen);
                @memset(seen, false);
                seen[0] = true;
                try stack.append(gpa, .{ 0, 0 });
                while (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    if (top[1] < l.succs[top[0]].len) {
                        const s = l.succs[top[0]][top[1]];
                        top[1] += 1;
                        if (!seen[s]) {
                            seen[s] = true;
                            try stack.append(gpa, .{ s, 0 });
                        }
                    } else {
                        try order.append(gpa, top[0]);
                        _ = stack.pop();
                    }
                }
                std.mem.reverse(u32, order.items);
                for (order.items, 0..) |b, i| rpo_num[b] = @intCast(i);
            }
            const idom = try gpa.alloc(u32, n);
            defer gpa.free(idom);
            @memset(idom, none);
            idom[0] = 0;
            var changed = true;
            while (changed) {
                changed = false;
                for (order.items[1..]) |b| {
                    var new: u32 = none;
                    for (l.preds[b]) |p| {
                        if (idom[p] == none) continue;
                        if (new == none) {
                            new = p;
                            continue;
                        }
                        var x = p;
                        var y = new;
                        while (x != y) {
                            while (rpo_num[x] > rpo_num[y]) x = idom[x];
                            while (rpo_num[y] > rpo_num[x]) y = idom[y];
                        }
                        new = x;
                    }
                    if (new != idom[b]) {
                        idom[b] = new;
                        changed = true;
                    }
                }
            }
            const in_loop = try gpa.alloc(bool, n);
            defer gpa.free(in_loop);
            var work: std.ArrayList(u32) = .empty;
            defer work.deinit(gpa);
            @memset(in_loop, false);
            // The current loop's blocks, so only they are reset.
            var body: std.ArrayList(u32) = .empty;
            defer body.deinit(gpa);
            for (0..n) |h| {
                if (rpo_num[h] == none) continue;
                for (l.preds[h]) |s| {
                    if (rpo_num[s] == none or !dominates(idom, rpo_num, @intCast(h), s)) continue;
                    if (!in_loop[h]) {
                        in_loop[h] = true;
                        try body.append(gpa, @intCast(h));
                    }
                    if (!in_loop[s]) {
                        in_loop[s] = true;
                        try body.append(gpa, s);
                        try work.append(gpa, s);
                    }
                }
                if (body.items.len == 0) continue;
                while (work.pop()) |b| for (l.preds[b]) |p| {
                    if (rpo_num[p] == none or in_loop[p]) continue;
                    in_loop[p] = true;
                    try body.append(gpa, p);
                    try work.append(gpa, p);
                };
                for (body.items) |b| {
                    l.depth[b] += 1;
                    in_loop[b] = false;
                }
                body.clearRetainingCapacity();
            }
        }

        fn dominates(idom: []const u32, rpo_num: []const u32, a: u32, b_in: u32) bool {
            var b = b_in;
            while (true) {
                if (b == a) return true;
                if (b == 0 or rpo_num[b] <= rpo_num[a]) return false;
                b = idom[b];
            }
        }
    };
}

const testing = std.testing;
const TestInst = @import("LinearScan.zig").TestTarget.Inst;

test "liveness: positions, edges, a value live around a loop, loop depth" {
    const gpa = testing.allocator;
    const F = Mir.Function(TestInst);
    // b0: v0 = 1 ; b 1
    // b1: v1 = v0 + v0 ; cbnz v1, 1 ; b 2
    // b2: use v0 ; ret
    var f = try F.init(gpa, 3);
    defer f.deinit(gpa);
    const v0 = try f.newVReg(gpa, .gpr, null);
    const v1 = try f.newVReg(gpa, .gpr, null);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .def = v0 } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .add = .{ .rd = v1, .rn = v0, .rm = v0 } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .cbnz = .{ .rn = v1, .target = 1 } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .b = 2 } });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .use = v0 } });
    try f.blocks[2].insts.append(gpa, .{ .op = .ret });

    var l = try Liveness(TestInst).compute(gpa, &f);
    defer l.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{ 0, 6, 14 }, l.from);
    try testing.expectEqualSlices(u32, &.{ 6, 14, 20 }, l.to);
    try testing.expectEqual(@as(u32, 10), l.instPos(1, 1));
    try testing.expectEqual(@as(u32, 1), l.blockOf(13));
    try testing.expect(l.isLabel(14));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, l.succs[1]);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, l.preds[1]);
    try testing.expectEqualSlices(u32, &.{0}, l.live_in[1]);
    try testing.expectEqualSlices(u32, &.{0}, l.live_out[1]);
    try testing.expectEqualSlices(u32, &.{0}, l.live_out[0]);
    try testing.expectEqualSlices(u32, &.{}, l.live_in[0]);
    try testing.expect(l.isLiveIn(2, 0) and !l.isLiveIn(1, 1) and l.isLiveOut(1, 0));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, l.depth);
    // Two-way exit: in-line moves stop at the cbnz; a one-way exit allows its b.
    try testing.expectEqual(@as(u32, 10), l.last_split[1]);
    try testing.expectEqual(@as(u32, 4), l.last_split[0]);
}
