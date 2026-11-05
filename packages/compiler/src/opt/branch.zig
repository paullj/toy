//! PASS b — branch folding + unreachable-block elimination.
//!
//! PHASE 1 (branch-fold): a `cond_br cond,t,f` whose `cond` is a constant bool
//! (an SSA value defined by `bconst`) becomes an argless unconditional `br` to the
//! taken target — `t` if true, `f` if false. `cond_br` is argless by design, so
//! the replacement carries no merge args; `br.args` is a static empty slice
//! (`Function.deinit`'s `gpa.free` no-ops on a 0-len slice — Opt.zig strategy (b)).
//!
//! PHASE 1b (merge, `mergeChains`): a block whose only predecessor edge is an
//! unconditional `br` is appended to that predecessor, its params becoming copies of
//! the edge's values; the merged block is left empty and orphaned for phase 2, and
//! `func.exit` follows the exit block into the block it merged into.
//!
//! PHASE 2 (unreachable-elim): whenever phase 1 or 1b changed a terminator, recompute
//! reachability from `func.entry` (iterate-to-fixpoint over successors, ascending
//! block id for determinism). Drop every block not reachable: free its owned
//! slices through the shared `Ir.Block.freeOwned` (once), then compact survivors
//! with a single alloc-copy-free-old. Rewrite every surviving terminator's block refs and
//! `func.entry`/`func.exit` through an ascending-id block remap.
//!
//! INVARIANTS: phase 2 drops only WHOLE unreachable blocks, so no live predecessor
//! loses a `br.arg` and no block-param/predecessor pairing is broken (`cond_br` is
//! argless; `br.args` reference values/slots, not blocks). Phase 1b removes an edge and
//! its params together, only where that edge is the block's sole predecessor. The single EXIT block
//! stays reachable in well-formed lowered IR (asserted in tests). Deterministic:
//! all worklists/remaps walk block ids ascending — no hash-map iteration.
//!
//! This pass does NOT re-derive fold's in-pass `known` table; it independently
//! scans `bconst` defs (cheap, deterministic). The Opt fixpoint runs fold BEFORE
//! branch, so an `icmp`/`bnot`-folded `bconst` is already visible here.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const Opt = @import("Opt.zig");
const walk = @import("walk.zig");

pub fn run(gpa: std.mem.Allocator, func: *Ir.Function, stats: *Opt.Stats) error{OutOfMemory}!bool {
    if (func.values.len == 0 and func.blocks.len == 0) return false;

    // Indexed const-bool table by ValueId (NOT a hash map). Only `bconst` defs
    // are recorded; everything else stays null. Re-derived each pass.
    const value_const = try gpa.alloc(?bool, func.values.len);
    defer gpa.free(value_const);
    @memset(value_const, null);
    for (func.blocks) |b| {
        for (b.instrs) |ins| {
            if (ins.result == Ir.none_value) continue;
            switch (ins.op) {
                .bconst => |v| value_const[ins.result] = v,
                else => {},
            }
        }
    }

    var folded_any = false;
    for (func.blocks) |*b| {
        switch (b.term) {
            .cond_br => |c| {
                const taken_const = constBool(value_const, c.cond) orelse continue;
                const taken: Ir.BlockId = if (taken_const) c.t else c.f;
                // Replace argless cond_br with an argless br to the taken target;
                // `br.args` is a static empty slice (deinit's free no-ops on len 0).
                b.term = .{ .br = .{ .dest = taken, .args = &.{} } };
                stats.branches_folded += 1;
                folded_any = true;
            },
            else => {},
        }
    }

    // Elim runs only after a fold or a merge, the two ways this pass orphans a block.
    // Lowering's own orphan (the `never` merge block) is left alone otherwise, so the
    // pass stays a no-op on IR it did not change.
    const merged = try mergeChains(gpa, func);
    if (!folded_any and !merged) return false;

    const dropped = try elimUnreachable(gpa, func, stats);
    return folded_any or merged or dropped;
}

/// PHASE 1b (merge): a block `c` whose ONLY predecessor edge is `b`'s unconditional
/// `br c(args)` is appended to `b`. Each of `c`'s params is a copy of its one incoming
/// value arg, so its uses read that value instead (sound in SSA: the arg's def dominates
/// `b`, which dominates every use of the param). `c` is left empty and orphaned for
/// phase 2. This is what makes an inlined body pay: forwarding is intra-block, and the
/// splice's edges (into the callee, out of it) each carry the values it must see.
/// A param carried in a slot (an aggregate) has no value to copy, so its edge stays.
fn mergeChains(gpa: std.mem.Allocator, func: *Ir.Function) error{OutOfMemory}!bool {
    const n = func.blocks.len;
    const preds = try gpa.alloc(u32, n);
    defer gpa.free(preds);
    @memset(preds, 0);
    for (func.blocks) |b| {
        var succ: [2]Ir.BlockId = undefined;
        for (succ[0..walk.successors(b.term, &succ)]) |sb| if (sb < n) {
            preds[sb] += 1;
        };
    }
    const copy_of = try gpa.alloc(Ir.ValueId, func.values.len);
    defer gpa.free(copy_of);
    for (copy_of, 0..) |*c, v| c.* = @intCast(v);

    // Each chain b -> c1 -> c2 ... is gathered first and its instrs copied once.
    var chain: std.ArrayList(Ir.BlockId) = .empty;
    defer chain.deinit(gpa);
    var merged = false;
    for (0..n) |b| {
        chain.clearRetainingCapacity();
        var tail: usize = b;
        var len = func.blocks[b].instrs.len;
        while (mergeable(func, preds, b, tail)) |c| {
            try chain.append(gpa, c);
            len += func.blocks[c].instrs.len;
            tail = c;
        }
        if (chain.items.len == 0) continue;

        const instrs = try gpa.alloc(Ir.Instr, len);
        var at = func.blocks[b].instrs.len;
        @memcpy(instrs[0..at], func.blocks[b].instrs);
        gpa.free(func.blocks[b].instrs);
        var from: usize = b;
        for (chain.items) |c| {
            const br = func.blocks[from].term.br;
            const cb = func.blocks[c];
            @memcpy(instrs[at..][0..cb.instrs.len], cb.instrs);
            at += cb.instrs.len;
            for (cb.params, br.args) |p, a| copy_of[p] = a.value;
            gpa.free(cb.params);
            gpa.free(br.args);
            if (from != b) func.blocks[from] = .{ .params = &.{}, .instrs = &.{}, .term = .@"unreachable" };
            gpa.free(cb.instrs);
            func.blocks[c].instrs = &.{};
            from = c;
        }
        func.blocks[b].instrs = instrs;
        func.blocks[b].term = func.blocks[from].term;
        func.blocks[b].term_line = func.blocks[from].term_line;
        func.blocks[from] = .{ .params = &.{}, .instrs = &.{}, .term = .@"unreachable" };
        if (std.mem.indexOfScalar(Ir.BlockId, chain.items, func.exit) != null) func.exit = @intCast(b);
        merged = true;
    }
    if (merged) walk.remapUses(func, copy_of, struct {
        fn root(m: []const Ir.ValueId, v: Ir.ValueId) Ir.ValueId {
            var x = v;
            while (x < m.len and m[x] != x) x = m[x];
            return x;
        }
    }.root);
    return merged;
}

/// The block `tail` (the end of a chain starting at `head`) merges with next: the one
/// successor of its unconditional `br`, when that edge is the successor's only
/// predecessor and carries a value for each of its params.
fn mergeable(func: *const Ir.Function, preds: []const u32, head: usize, tail: usize) ?Ir.BlockId {
    const br = switch (func.blocks[tail].term) {
        .br => |br| br,
        else => return null,
    };
    const c = br.dest;
    if (c == head or c == func.entry or c >= func.blocks.len or preds[c] != 1) return null;
    if (br.args.len != func.blocks[c].params.len) return null;
    for (br.args) |a| if (a != .value or a.value == Ir.none_value) return null;
    return c;
}

fn constBool(value_const: []const ?bool, v: Ir.ValueId) ?bool {
    if (v == Ir.none_value or v >= value_const.len) return null;
    return value_const[v];
}

/// Drop blocks unreachable from `func.entry`. Returns true if any were dropped.
/// Frees dropped blocks' owned slices once, compacts survivors, remaps refs.
pub fn elimUnreachable(gpa: std.mem.Allocator, func: *Ir.Function, stats: *Opt.Stats) error{OutOfMemory}!bool {
    const n = func.blocks.len;
    if (n == 0) return false;

    const reachable = try gpa.alloc(bool, n);
    defer gpa.free(reachable);
    @memset(reachable, false);

    // Iterate-to-fixpoint reachability from entry, ascending-id sweeps (no queue
    // ordering dependence => deterministic). entry is always reachable.
    if (func.entry < n) reachable[func.entry] = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (func.blocks, 0..) |b, i| {
            if (!reachable[i]) continue;
            var succ: [2]Ir.BlockId = undefined;
            const cnt = walk.successors(b.term, &succ);
            for (succ[0..cnt]) |s| {
                if (s < n and !reachable[s]) {
                    reachable[s] = true;
                    changed = true;
                }
            }
        }
    }

    // Count survivors; bail if all reachable.
    var kept: usize = 0;
    for (reachable) |r| {
        if (r) kept += 1;
    }
    if (kept == n) return false;

    // Build ascending-id remap old->new for survivors (holes removed).
    const remap = try gpa.alloc(Ir.BlockId, n);
    defer gpa.free(remap);
    {
        var next: Ir.BlockId = 0;
        for (reachable, 0..) |r, i| {
            if (r) {
                remap[i] = next;
                next += 1;
            } else {
                remap[i] = Ir.none_block;
            }
        }
    }

    // Free each DROPPED block's owned slices through the shared `freeOwned`.
    for (func.blocks, 0..) |b, i| {
        if (reachable[i]) continue;
        b.freeOwned(gpa);
    }

    // Compact survivors (single alloc-copy-free-old), in old-id order.
    const new_blocks = try gpa.alloc(Ir.Block, kept);
    {
        var j: usize = 0;
        for (func.blocks, 0..) |b, i| {
            if (reachable[i]) {
                new_blocks[j] = b;
                j += 1;
            }
        }
    }
    gpa.free(func.blocks);
    func.blocks = new_blocks;

    // Rewrite surviving terminators' block refs and entry/exit through remap.
    for (func.blocks) |*b| {
        walk.remapBlockTargets(b, @as([]const Ir.BlockId, remap), struct {
            fn each(m: []const Ir.BlockId, x: Ir.BlockId) Ir.BlockId {
                return m[x];
            }
        }.each);
    }
    if (func.entry < n) func.entry = remap[func.entry];
    // A fn that never returns loses its exit block: `exit` then names no block.
    if (func.exit < n) func.exit = remap[func.exit];

    stats.blocks_removed += (n - kept);
    return true;
}

// Tests — hand-built IR under std.testing.allocator (catches leak/double-free).

const testing = std.testing;

fn intVals(gpa: std.mem.Allocator, n: usize) ![]Ir.ValueDef {
    const v = try gpa.alloc(Ir.ValueDef, n);
    for (v) |*x| x.* = .{ .type = Ir.Type.int };
    return v;
}

test "cond_br on bconst true -> br t with empty args" {
    const gpa = testing.allocator;
    // b0: %0=bconst true; cond_br %0,b1,b2
    // b1: ret  ;  b2: ret  (both kept reachable only via the cond_br targets)
    var b0_instrs = try gpa.alloc(Ir.Instr, 1);
    b0_instrs[0] = .{ .result = 0, .op = .{ .bconst = true } };
    var blocks = try gpa.alloc(Ir.Block, 3);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = b0_instrs, .term = .{ .cond_br = .{ .cond = 0, .t = 1, .f = 2 } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };

    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "t" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = try intVals(gpa, 1),
        .blocks = blocks,
        .entry = 0,
        .exit = 1,
    };
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    const changed = try run(gpa, &func, &st);
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 1), st.branches_folded);
    // b2 (false target) dropped; b1, now b0's only successor with b0 its only
    // predecessor, merges into b0, which becomes the exit.
    try testing.expectEqual(@as(usize, 2), st.blocks_removed);
    try testing.expectEqual(@as(usize, 1), func.blocks.len);
    try testing.expect(func.blocks[0].term == .ret);
    try testing.expectEqual(@as(Ir.BlockId, 0), func.exit);
}

test "cond_br on bconst false -> br f, drops the true target" {
    const gpa = testing.allocator;
    var b0_instrs = try gpa.alloc(Ir.Instr, 1);
    b0_instrs[0] = .{ .result = 0, .op = .{ .bconst = false } };
    var blocks = try gpa.alloc(Ir.Block, 3);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = b0_instrs, .term = .{ .cond_br = .{ .cond = 0, .t = 1, .f = 2 } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };

    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "t" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = try intVals(gpa, 1),
        .blocks = blocks,
        .entry = 0,
        .exit = 2,
    };
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    const changed = try run(gpa, &func, &st);
    try testing.expect(changed);
    // true target b1 dropped; b2, the false target, merges into b0.
    try testing.expectEqual(@as(usize, 1), func.blocks.len);
    try testing.expect(func.blocks[0].term == .ret);
    try testing.expectEqual(@as(Ir.BlockId, 0), func.exit);
}

test "unreachable-elim drops + remaps a 4-block function" {
    const gpa = testing.allocator;
    // b0: %0=bconst true; cond_br %0,b1,b2
    // b1: br b3
    // b2: br b3   (becomes unreachable after fold)
    // b3: ret
    var b0_instrs = try gpa.alloc(Ir.Instr, 1);
    b0_instrs[0] = .{ .result = 0, .op = .{ .bconst = true } };
    var blocks = try gpa.alloc(Ir.Block, 4);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = b0_instrs, .term = .{ .cond_br = .{ .cond = 0, .t = 1, .f = 2 } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .br = .{ .dest = 3, .args = try gpa.alloc(Ir.Operand, 0) } } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .br = .{ .dest = 3, .args = try gpa.alloc(Ir.Operand, 0) } } };
    blocks[3] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };

    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "t" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = try intVals(gpa, 1),
        .blocks = blocks,
        .entry = 0,
        .exit = 3,
    };
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    const changed = try run(gpa, &func, &st);
    try testing.expect(changed);
    // b2 unreachable after folding to br b1. b3 keeps two predecessor edges (b1, b2) while
    // the merge runs, so only b1 joins b0; elim then drops b1 and b2.
    try testing.expectEqual(@as(usize, 2), st.blocks_removed);
    try testing.expectEqual(@as(usize, 2), func.blocks.len);
    // b0 -> br b3 (b3 remaps 3->1).
    try testing.expectEqual(@as(Ir.BlockId, 1), func.blocks[0].term.br.dest);
    try testing.expectEqual(@as(Ir.BlockId, 1), func.exit);
}

/// b0 ends `br b1(%0)`; b1 has param %1 and `ret %2` where `%2 = add %1, %1`. `preds`
/// extra edges into b1 come from b2, a self-looping block nothing reaches.
fn chainFn(gpa: std.mem.Allocator, arg: Ir.Operand, extra_pred: bool) !Ir.Function {
    var b0_instrs = try gpa.alloc(Ir.Instr, 1);
    b0_instrs[0] = .{ .result = 0, .op = .{ .iconst = 4 } };
    const args = try gpa.alloc(Ir.Operand, 1);
    args[0] = arg;
    var b1_instrs = try gpa.alloc(Ir.Instr, 1);
    b1_instrs[0] = .{ .result = 2, .op = .{ .add = .{ .lhs = 1, .rhs = 1 } } };
    const p1 = try gpa.alloc(Ir.ValueId, 1);
    p1[0] = 1;
    var blocks = try gpa.alloc(Ir.Block, if (extra_pred) 3 else 2);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = b0_instrs, .term = .{ .br = .{ .dest = 1, .args = args } } };
    blocks[1] = .{ .params = p1, .instrs = b1_instrs, .term = .{ .ret = .{ .value = 2 } } };
    if (extra_pred) {
        const a2 = try gpa.alloc(Ir.Operand, 1);
        a2[0] = .{ .value = 0 };
        blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .br = .{ .dest = 1, .args = a2 } } };
    }
    const slots = try gpa.alloc(Ir.Slot, 1);
    slots[0] = .{ .type = Ir.Type.int };
    return .{
        .name = .{ .kind = .user_fn, .name = "t" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.int,
        .slots = slots,
        .values = try intVals(gpa, 3),
        .blocks = blocks,
        .entry = 0,
        .exit = 1,
    };
}

test "merge: a block with one predecessor joins it, its param reading the edge's arg" {
    const gpa = testing.allocator;
    var func = try chainFn(gpa, .{ .value = 0 }, false);
    defer func.deinit(gpa);
    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 1), func.blocks.len);
    try testing.expectEqual(@as(usize, 2), func.blocks[0].instrs.len);
    const add = func.blocks[0].instrs[1].op.add;
    try testing.expectEqual(@as(Ir.ValueId, 0), add.lhs);
    try testing.expectEqual(@as(Ir.ValueId, 0), add.rhs);
    try testing.expect(func.blocks[0].term == .ret);
    try testing.expectEqual(@as(Ir.BlockId, 0), func.exit);
}

test "merge: not into a block with a second predecessor, nor across a slot arg" {
    const gpa = testing.allocator;
    for ([_]struct { Ir.Operand, bool }{ .{ .{ .value = 0 }, true }, .{ .{ .slot = 0 }, false } }) |case| {
        var func = try chainFn(gpa, case[0], case[1]);
        defer func.deinit(gpa);
        var st: Opt.Stats = .{};
        _ = try run(gpa, &func, &st);
        try testing.expect(func.blocks[0].term == .br);
        try testing.expectEqual(@as(usize, 1), func.blocks[0].instrs.len);
    }
}

test "unreachable-elim: dropping the exit block of a fn that never returns leaves exit naming no block" {
    const gpa = testing.allocator;
    // b0: %0=bconst false; cond_br %0,b1,b2   b1 (exit): ret   b2: panic
    var b0_instrs = try gpa.alloc(Ir.Instr, 1);
    b0_instrs[0] = .{ .result = 0, .op = .{ .bconst = false } };
    var blocks = try gpa.alloc(Ir.Block, 3);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = b0_instrs, .term = .{ .cond_br = .{ .cond = 0, .t = 1, .f = 2 } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .panic = .div_by_zero } };
    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "t" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = try intVals(gpa, 1),
        .blocks = blocks,
        .entry = 0,
        .exit = 1,
    };
    defer func.deinit(gpa);
    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 1), func.blocks.len);
    try testing.expectEqual(Ir.none_block, func.exit);
}

test "no-op when cond is not a constant" {
    const gpa = testing.allocator;
    // b0: %0=slot_addr s0; %1=load %0; cond_br %1,b1,b2 — %1 not const.
    var b0_instrs = try gpa.alloc(Ir.Instr, 2);
    b0_instrs[0] = .{ .result = 0, .op = .{ .slot_addr = 0 } };
    b0_instrs[1] = .{ .result = 1, .op = .{ .load = .{ .addr = 0, .ty = Ir.Type.bool } } };
    var blocks = try gpa.alloc(Ir.Block, 3);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = b0_instrs, .term = .{ .cond_br = .{ .cond = 1, .t = 1, .f = 2 } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };

    var slots = try gpa.alloc(Ir.Slot, 1);
    slots[0] = .{ .type = Ir.Type.bool };
    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "t" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.unit,
        .slots = slots,
        .values = try intVals(gpa, 2),
        .blocks = blocks,
        .entry = 0,
        .exit = 1,
    };
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    const changed = try run(gpa, &func, &st);
    try testing.expect(!changed);
    try testing.expectEqual(@as(usize, 0), st.branches_folded);
    try testing.expect(func.blocks[0].term == .cond_br);
    try testing.expectEqual(@as(usize, 3), func.blocks.len);
}
