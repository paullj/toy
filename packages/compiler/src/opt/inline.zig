//! Inline small callees: splice a callee's optimized IR into its caller in place of a
//! direct `call`, so the existing passes can fold across the old call boundary and the
//! call's prologue, epilogue and argument marshalling disappear.
//!
//! The caller asks a `Lookup` for each direct callee's IR. The lookup owns the callee
//! IR and decides which callees the caller's cache key covers; this pass only decides
//! whether a callee it was handed may be spliced: under `budget` instructions, no loop,
//! not recursive, not calling back into the caller, and a return it can rewrite. A
//! caller that calls itself takes only callees that keep its frame within a small
//! budget (`recursive_bytes`).
//!
//! SPLICE. A block B whose calls at i1 < i2 < ... are inlined becomes a chain:
//!   B:    instrs[0..i1] ++ one store/copy per arg into g1's (renumbered) param slot
//!         br g1.entry'
//!   g1's blocks, renumbered (values and blocks shifted past the caller's, slots
//!         mapped onto a pool every spliced body shares)
//!   g1.exit': `ret o` becomes `br C1(o)` (scalar), `br C1` (unit), or a copy of the
//!         returned aggregate into the call's ret slot then `br C1`
//!   C1:   params [%r1] for a scalar result, instrs[i1+1..i2] ++ g2's param stores, ...
//!   Cn:   ..., instrs[in+1..], B's old terminator
//! Every instruction is copied once, so a block with many inlined calls costs linear
//! time. Params are copied in because codegen's prologue copies every incoming param
//! into its own slot too, so the callee never aliases the caller's storage. Inlined code
//! takes the call's line: a backtrace or line table names the caller, and the callee
//! frame vanishes.
//!
//! MEMORY: nothing in `func` changes until every new slice is built; an allocation
//! failure frees what was built and leaves `func` as it was. On success each rewritten
//! block's old `instrs` slice and each inlined call's `args` are freed once.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const walk = @import("walk.zig");
const mem2reg = @import("mem2reg.zig");
const Stats = @import("Opt.zig").Stats;

/// The largest callee (in IR instructions, after its own optimization) a call site takes.
pub const budget = 30;

/// Where the pass finds a direct callee's IR. Null means "do not inline": the callee has
/// no IR this caller may read, or its cache key would not cover it.
pub const Lookup = struct {
    ctx: *anyopaque,
    findFn: FindFn,
    /// The callees `splice` takes once the unit's own optimization is done, or null for
    /// none: a body lowered to be inlined elsewhere keeps such a call, so it is measured
    /// against the budget as one instruction.
    splicedFn: ?FindFn = null,
    /// The bytes a value of an aggregate type takes, or null when the build has no
    /// layouts: a recursive caller then takes no callee that needs an aggregate slot.
    bytesFn: ?*const fn (ctx: *anyopaque, t: Ir.Type) u32 = null,

    pub const FindFn = *const fn (ctx: *anyopaque, name: []const u8) error{OutOfMemory}!?*const Ir.Function;

    pub fn find(l: Lookup, name: []const u8) error{OutOfMemory}!?*const Ir.Function {
        return l.findFn(l.ctx, name);
    }

    /// The lookup `splice` reads, or null.
    pub fn spliced(l: Lookup) ?Lookup {
        return .{ .ctx = l.ctx, .findFn = l.splicedFn orelse return null, .bytesFn = l.bytesFn };
    }

    /// The frame bytes a slot of type `t` takes, or null when unknown.
    fn slotBytes(l: Lookup, t: Ir.Type) ?u32 {
        if (!t.isAggregateValue()) return 8;
        const f = l.bytesFn orelse return null;
        return std.mem.alignForward(u32, f(l.ctx, t), 8);
    }
};

/// Inline every eligible direct call of `func`'s own code once. Calls inside a spliced
/// body stay calls: the lookup hands over callee IR that already had its own callees
/// inlined, which bounds the depth.
pub fn run(gpa: std.mem.Allocator, func: *Ir.Function, lookup: Lookup, max: usize, stats: *Stats) error{OutOfMemory}!bool {
    return inlineSites(gpa, func, lookup, max, calls(func, func.name.name), stats);
}

/// Splice every direct call whose callee `lookup` hands over, whatever its size, and in a
/// caller that recurses too: the lookup hands over only bodies whose slots are scalar
/// params that mem2reg promotes, so they leave the frame as it was.
pub fn splice(gpa: std.mem.Allocator, func: *Ir.Function, lookup: Lookup, stats: *Stats) error{OutOfMemory}!bool {
    return inlineSites(gpa, func, lookup, std.math.maxInt(usize), false, stats);
}

fn inlineSites(gpa: std.mem.Allocator, func: *Ir.Function, lookup: Lookup, max: usize, recursive: bool, stats: *Stats) error{OutOfMemory}!bool {
    var sp: Splicer = try .init(gpa, func);
    defer sp.deinit();
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(gpa);
    var frame: FrameBudget = .{};
    defer frame.deinit(gpa);
    for (func.blocks, 0..) |blk, b| {
        sites.clearRetainingCapacity();
        for (blk.instrs, 0..) |ins, i| {
            const c = switch (ins.op) {
                .call => |c| c,
                else => continue,
            };
            if (c.callee.kind != .user_fn) continue;
            const callee = (try lookup.find(c.callee.name)) orelse continue;
            if (!inlinable(callee, c, ins.result, max) or calls(callee, func.name.name)) continue;
            if (recursive and !try frame.admit(gpa, lookup, callee)) continue;
            try sites.append(gpa, .{ .at = i, .callee = callee });
        }
        if (sites.items.len == 0) continue;
        try sp.spliceBlock(@intCast(b), sites.items);
        stats.calls_inlined += sites.items.len;
    }
    if (sp.heads.items.len == 0) return false;
    try sp.commit();
    return true;
}

/// Whether `callee` may replace `call` (whose result is `result`): small, loop-free, not
/// calling itself, and returning in a shape the splice rewrites.
pub fn inlinable(callee: *const Ir.Function, call: Ir.Call, result: Ir.ValueId, max: usize) bool {
    if (callee.params.len != call.args.len or !fits(callee, max)) return false;
    const exit = callee.blocks[callee.exit];
    const o = exit.term.ret;
    if (call.ret_slot == Ir.none_slot) return switch (o) {
        .none => result == Ir.none_value,
        .value => true,
        .slot => false,
    };
    return switch (o) {
        .none => false,
        .slot => true,
        .value => |v| exitParamFromSlots(callee, v),
    };
}

/// The part of `inlinable` that needs no call site: small, loop-free, not calling
/// itself, and returning.
pub fn fits(callee: *const Ir.Function, max: usize) bool {
    if (callee.c_abi or Ir.instrCount(callee) > max or calls(callee, callee.name.name)) return false;
    if (hasCycle(callee) or readsFrame(callee)) return false;
    // A callee that never returns had its exit block dropped as unreachable, leaving
    // `exit` naming no block or one that does not `ret`.
    return callee.exit < callee.blocks.len and callee.blocks[callee.exit].term == .ret;
}

/// The most frame bytes the spliced bodies' slots may add to a caller that calls itself.
/// Each spliced body brings its slots and aggregate cells into the frame, and a recursion
/// multiplies that by its depth, so a bigger frame can overflow the stack where the
/// uninlined build does not: four more slots, and the spills they brought, grew
/// frames/deep_recursion.toy's frame from 0x50 to 0x80 bytes and overflowed its
/// 60000-deep recursion. Counted in bytes, not slots, as one pooled slot of a 96-byte
/// struct alone grew a recursive frame by 0x60.
pub const recursive_bytes = 16;

/// The slots the bodies spliced into a recursive caller add, which `admit` keeps within
/// `recursive_bytes`.
const FrameBudget = struct {
    /// The types of the slots the splice will pool, as `Splicer.mapSlots` shares them:
    /// one per type per body, reused by the next body.
    pooled: std.ArrayList(Ir.Type) = .empty,
    need: std.ArrayList(Ir.Type) = .empty,
    bytes: u32 = 0,

    fn deinit(fb: *FrameBudget, gpa: std.mem.Allocator) void {
        fb.pooled.deinit(gpa);
        fb.need.deinit(gpa);
    }

    /// Whether `callee` fits in the budget, taking its slots when it does. A slot mem2reg
    /// promotes once spliced costs nothing; every other slot costs its bytes unless the
    /// pool already holds one of its type. An aggregate value other than the exit's param
    /// (which the splice drops or turns into the call's result) would take a cell of its
    /// own, outside the pool, so it rules the callee out.
    fn admit(fb: *FrameBudget, gpa: std.mem.Allocator, lookup: Lookup, callee: *const Ir.Function) error{OutOfMemory}!bool {
        const exit_params = if (callee.exit < callee.blocks.len) callee.blocks[callee.exit].params else &.{};
        for (callee.values, 0..) |v, id| {
            if (v.type.isAggregateValue() and std.mem.indexOfScalar(Ir.ValueId, exit_params, @intCast(id)) == null) return false;
        }
        const promoted = try mem2reg.candidates(gpa, callee);
        defer gpa.free(promoted);
        fb.need.clearRetainingCapacity();
        for (callee.slots, promoted) |s, p| if (!p) try fb.need.append(gpa, s.type);
        var added: u32 = 0;
        for (fb.need.items, 0..) |t, i| {
            if (firstOf(fb.need.items, t) != i) continue;
            const n = count(fb.need.items, t) -| count(fb.pooled.items, t);
            if (n == 0) continue;
            const each = lookup.slotBytes(t) orelse return false;
            added += @intCast(n * each);
        }
        if (fb.bytes + added > recursive_bytes) return false;
        fb.bytes += added;
        for (fb.need.items, 0..) |t, i| {
            if (firstOf(fb.need.items, t) != i) continue;
            try fb.pooled.appendNTimes(gpa, t, count(fb.need.items, t) -| count(fb.pooled.items, t));
        }
        return true;
    }
};

fn count(types: []const Ir.Type, t: Ir.Type) usize {
    var n: usize = 0;
    for (types) |u| n += @intFromBool(u.eql(t));
    return n;
}

fn firstOf(types: []const Ir.Type, t: Ir.Type) usize {
    for (types, 0..) |u, i| if (u.eql(t)) return i;
    unreachable;
}

/// Whether `func` reads its own frame record, which names the frame its caller sees only
/// while the call stays a call.
fn readsFrame(func: *const Ir.Function) bool {
    for (func.blocks) |blk| for (blk.instrs) |ins| if (ins.op == .frame_addr) return true;
    return false;
}

/// Whether `func` makes a direct call to `name`.
fn calls(func: *const Ir.Function, name: []const u8) bool {
    for (func.blocks) |blk| for (blk.instrs) |ins| switch (ins.op) {
        .call => |c| if (std.mem.eql(u8, c.callee.name, name)) return true,
        else => {},
    };
    return false;
}

/// An aggregate returned through the exit block's param: every edge into the exit must
/// carry the aggregate in a slot, so the splice can copy it into the call's `ret_slot`
/// on the edge instead.
fn exitParamFromSlots(callee: *const Ir.Function, v: Ir.ValueId) bool {
    const exit = callee.blocks[callee.exit];
    if (exit.params.len != 1 or exit.params[0] != v or exit.instrs.len != 0) return false;
    for (callee.blocks) |blk| switch (blk.term) {
        .br => |br| if (br.dest == callee.exit and br.args.len > 0 and br.args[0] != .slot) return false,
        .cond_br => |c| if (c.t == callee.exit or c.f == callee.exit) return false,
        else => {},
    };
    return true;
}

/// Whether a cycle is reachable from the entry. Callees past `max_blocks` count as cyclic:
/// the budget keeps every callee this pass takes far below it.
fn hasCycle(func: *const Ir.Function) bool {
    const max_blocks = 256;
    if (func.blocks.len > max_blocks) return true;
    var state: [max_blocks]enum { unseen, on_path, done } = undefined;
    @memset(state[0..func.blocks.len], .unseen);
    var stack: [max_blocks]struct { b: Ir.BlockId, next: u2 } = undefined;
    var sp: usize = 1;
    stack[0] = .{ .b = func.entry, .next = 0 };
    state[func.entry] = .on_path;
    while (sp > 0) {
        const top = &stack[sp - 1];
        if (successor(func.blocks[top.b].term, top.next)) |s| {
            top.next += 1;
            switch (state[s]) {
                .on_path => return true,
                .done => {},
                .unseen => {
                    state[s] = .on_path;
                    stack[sp] = .{ .b = s, .next = 0 };
                    sp += 1;
                },
            }
        } else {
            state[top.b] = .done;
            sp -= 1;
        }
    }
    return false;
}

fn successor(term: Ir.Terminator, k: u2) ?Ir.BlockId {
    return switch (term) {
        .br => |br| if (k == 0) br.dest else null,
        .cond_br => |c| switch (k) {
            0 => c.t,
            1 => c.f,
            else => null,
        },
        .ret, .@"unreachable", .panic => null,
    };
}

const Shift = struct {
    vo: Ir.ValueId,
    /// Each callee slot's id in the caller.
    smap: []const Ir.SlotId,
    bo: Ir.BlockId,

    fn value(s: Shift, v: Ir.ValueId) Ir.ValueId {
        return if (v == Ir.none_value) v else v + s.vo;
    }
    fn slot(s: Shift, v: Ir.SlotId) Ir.SlotId {
        return if (v == Ir.none_slot) v else s.smap[v];
    }
    fn block(s: Shift, v: Ir.BlockId) Ir.BlockId {
        return v + s.bo;
    }
};

/// Instructions and value defs the splice appends, built up before anything is swapped in.
const Emit = struct {
    gpa: std.mem.Allocator,
    values: *std.ArrayList(Ir.ValueDef),
    line: u32,

    fn value(e: Emit, ty: Ir.Type) error{OutOfMemory}!Ir.ValueId {
        const id: Ir.ValueId = @intCast(e.values.items.len);
        try e.values.append(e.gpa, .{ .type = ty });
        return id;
    }

    /// `dst ← src` for slot `dst` of type `ty`: a store of a scalar value, a byte copy of a
    /// slot.
    fn put(e: Emit, out: *std.ArrayList(Ir.Instr), dst: Ir.SlotId, ty: Ir.Type, src: Ir.Operand) error{OutOfMemory}!void {
        switch (src) {
            .none => {},
            .value => |v| {
                const a = try e.value(Ir.Type.int);
                try out.append(e.gpa, .{ .result = a, .op = .{ .slot_addr = dst }, .line = e.line });
                try out.append(e.gpa, .{ .result = Ir.none_value, .op = .{ .store = .{ .addr = a, .val = v, .ty = ty } }, .line = e.line });
            },
            .slot => |s| {
                const a = try e.value(Ir.Type.int);
                try out.append(e.gpa, .{ .result = a, .op = .{ .slot_addr = dst }, .line = e.line });
                const from = try e.value(Ir.Type.int);
                try out.append(e.gpa, .{ .result = from, .op = .{ .slot_addr = s }, .line = e.line });
                try out.append(e.gpa, .{ .result = Ir.none_value, .op = .{ .copy = .{ .dst = a, .src = from, .ty = ty } }, .line = e.line });
            },
        }
    }
};

fn cloneBlock(gpa: std.mem.Allocator, src: Ir.Block, sh: Shift, line: u32) error{OutOfMemory}!Ir.Block {
    const params = try gpa.dupe(Ir.ValueId, src.params);
    errdefer gpa.free(params);
    const instrs = try gpa.alloc(Ir.Instr, src.instrs.len);
    var done: usize = 0;
    errdefer {
        for (instrs[0..done]) |ins| switch (ins.op) {
            .call => |c| gpa.free(c.args),
            .call_indirect => |c| gpa.free(c.args),
            else => {},
        };
        gpa.free(instrs);
    }
    for (src.instrs, instrs) |s, *d| {
        d.* = s;
        d.line = line;
        switch (d.op) {
            .call => |*c| c.args = try gpa.dupe(Ir.Operand, c.args),
            .call_indirect => |*c| c.args = try gpa.dupe(Ir.Operand, c.args),
            else => {},
        }
        done += 1;
    }
    var b: Ir.Block = .{ .params = params, .instrs = instrs, .term = src.term, .term_line = line };
    if (b.term == .br) b.term.br.args = try gpa.dupe(Ir.Operand, src.term.br.args);
    walk.remapBlockValues(&b, sh, Shift.value);
    walk.remapBlockSlots(&b, sh, Shift.slot);
    walk.remapBlockTargets(&b, sh, Shift.block);
    return b;
}

const Site = struct { at: usize, callee: *const Ir.Function };

/// Builds the rewritten function aside, then swaps it in (`commit`).
const Splicer = struct {
    gpa: std.mem.Allocator,
    func: *Ir.Function,
    values: std.ArrayList(Ir.ValueDef) = .empty,
    slots: std.ArrayList(Ir.Slot) = .empty,
    /// The caller slots spliced bodies use, shared by type: an inlined body's slots are
    /// dead once it reaches its continuation, so two bodies are never live at once and a
    /// recursive caller's frame grows by the largest body, not by their sum.
    pool: std.ArrayList(Ir.SlotId) = .empty,
    /// Per splice: whether this body already took `pool[i]`, and its slot map.
    taken: std.ArrayList(bool) = .empty,
    smap: std.ArrayList(Ir.SlotId) = .empty,
    /// The blocks appended after the caller's, in id order.
    added: std.ArrayList(Ir.Block) = .empty,
    /// Per added block: a spliced callee block, which owns all its slices, or a
    /// continuation, which owns its `instrs` and `params` slices but shares the caller's
    /// nested call args and, for the last, the caller's terminator.
    cloned: std.ArrayList(bool) = .empty,
    /// The caller blocks that now end in a branch into a spliced body.
    heads: std.ArrayList(struct { b: Ir.BlockId, instrs: []Ir.Instr, term_line: u32, dest: Ir.BlockId }) = .empty,
    /// Literals added from callees, owned until `commit`.
    literals: std.ArrayList(Ir.Literal) = .empty,
    /// The args of each spliced call, still owned by the caller's block until `commit`.
    spliced: std.ArrayList([]Ir.Operand) = .empty,

    fn init(gpa: std.mem.Allocator, func: *Ir.Function) error{OutOfMemory}!Splicer {
        var sp: Splicer = .{ .gpa = gpa, .func = func };
        errdefer sp.deinit();
        try sp.values.appendSlice(gpa, func.values);
        try sp.slots.appendSlice(gpa, func.slots);
        return sp;
    }

    fn deinit(sp: *Splicer) void {
        const gpa = sp.gpa;
        for (sp.added.items, sp.cloned.items) |blk, cloned| {
            if (cloned) {
                blk.freeOwned(gpa);
            } else {
                gpa.free(blk.instrs);
                gpa.free(blk.params);
            }
        }
        sp.added.deinit(gpa);
        sp.cloned.deinit(gpa);
        for (sp.heads.items) |h| gpa.free(h.instrs);
        sp.heads.deinit(gpa);
        for (sp.literals.items) |l| gpa.free(l.bytes);
        sp.literals.deinit(gpa);
        sp.spliced.deinit(gpa);
        sp.values.deinit(gpa);
        sp.slots.deinit(gpa);
        sp.pool.deinit(gpa);
        sp.taken.deinit(gpa);
        sp.smap.deinit(gpa);
    }

    /// Map each of `g`'s slots to a pooled caller slot of its type that this body has not
    /// taken yet, adding one when none is free.
    fn mapSlots(sp: *Splicer, g: *const Ir.Function) error{OutOfMemory}![]const Ir.SlotId {
        const gpa = sp.gpa;
        sp.smap.clearRetainingCapacity();
        sp.taken.clearRetainingCapacity();
        try sp.taken.appendNTimes(gpa, false, sp.pool.items.len);
        for (g.slots) |gs| {
            const found = for (sp.pool.items, sp.taken.items, 0..) |id, t, i| {
                if (!t and Ir.Type.eql(sp.slots.items[id].type, gs.type)) break i;
            } else null;
            const i = found orelse blk: {
                try sp.pool.append(gpa, @intCast(sp.slots.items.len));
                try sp.slots.append(gpa, gs);
                try sp.taken.append(gpa, false);
                break :blk sp.pool.items.len - 1;
            };
            sp.taken.items[i] = true;
            try sp.smap.append(gpa, sp.pool.items[i]);
        }
        return sp.smap.items;
    }

    fn nextId(sp: *const Splicer) Ir.BlockId {
        return @intCast(sp.func.blocks.len + sp.added.items.len);
    }

    fn spliceBlock(sp: *Splicer, b: Ir.BlockId, sites: []const Site) error{OutOfMemory}!void {
        const gpa = sp.gpa;
        const old = sp.func.blocks[b];
        var seg: std.ArrayList(Ir.Instr) = .empty;
        defer seg.deinit(gpa);
        var start: usize = 0;
        // The block the next segment fills: `b` itself, then each continuation.
        var cur: ?usize = null;
        for (sites) |site| {
            const call_ins = old.instrs[site.at];
            const call = call_ins.op.call;
            const g = site.callee;
            const e: Emit = .{ .gpa = gpa, .values = &sp.values, .line = call_ins.line };
            const sh: Shift = .{
                .vo = @intCast(sp.values.items.len),
                .smap = try sp.mapSlots(g),
                .bo = sp.nextId(),
            };
            try sp.values.appendSlice(gpa, g.values);
            try seg.appendSlice(gpa, old.instrs[start..site.at]);
            for (g.params, call.args) |ps, arg| try e.put(&seg, sh.slot(ps), g.slots[ps].type, arg);
            try sp.closeSegment(b, cur, &seg, sh.block(g.entry), call_ins.line);

            try sp.added.ensureUnusedCapacity(gpa, g.blocks.len + 1);
            try sp.cloned.ensureUnusedCapacity(gpa, g.blocks.len + 1);
            for (g.blocks) |gb| {
                sp.added.appendAssumeCapacity(try cloneBlock(gpa, gb, sh, call_ins.line));
                sp.cloned.appendAssumeCapacity(true);
            }
            const body = sp.added.items[sp.added.items.len - g.blocks.len ..];
            const cont = sp.nextId();
            const has_result = call.ret_slot == Ir.none_slot and call_ins.result != Ir.none_value;
            try rewriteReturn(gpa, e, body, g.exit, sh.block(g.exit), cont, call, has_result, g.ret_type);
            const params = try gpa.alloc(Ir.ValueId, if (has_result) 1 else 0);
            if (has_result) params[0] = call_ins.result;
            sp.added.appendAssumeCapacity(.{ .params = params, .instrs = &.{}, .term = .@"unreachable" });
            sp.cloned.appendAssumeCapacity(false);
            cur = sp.added.items.len - 1;
            try sp.addLiterals(g.literals);
            try sp.spliced.append(gpa, call.args);
            start = site.at + 1;
        }
        try seg.appendSlice(gpa, old.instrs[start..]);
        const last = &sp.added.items[cur.?];
        last.instrs = try seg.toOwnedSlice(gpa);
        last.term = old.term;
        last.term_line = old.term_line;
    }

    /// End the segment being built in `seg` with a branch to `dest`: into `b` itself when
    /// `cur` is null, else into continuation `cur`.
    fn closeSegment(sp: *Splicer, b: Ir.BlockId, cur: ?usize, seg: *std.ArrayList(Ir.Instr), dest: Ir.BlockId, line: u32) error{OutOfMemory}!void {
        const gpa = sp.gpa;
        if (cur) |k| {
            const blk = &sp.added.items[k];
            blk.instrs = try seg.toOwnedSlice(gpa);
            blk.term = .{ .br = .{ .dest = dest, .args = &.{} } };
            blk.term_line = line;
            return;
        }
        try sp.heads.ensureUnusedCapacity(gpa, 1);
        sp.heads.appendAssumeCapacity(.{ .b = b, .instrs = try seg.toOwnedSlice(gpa), .term_line = line, .dest = dest });
    }

    fn addLiterals(sp: *Splicer, theirs: []const Ir.Literal) error{OutOfMemory}!void {
        for (theirs) |t| {
            const have = for (sp.func.literals) |l| {
                if (l.hash == t.hash) break true;
            } else for (sp.literals.items) |l| {
                if (l.hash == t.hash) break true;
            } else false;
            if (have) continue;
            try sp.literals.ensureUnusedCapacity(sp.gpa, 1);
            sp.literals.appendAssumeCapacity(.{ .hash = t.hash, .bytes = try sp.gpa.dupe(u8, t.bytes) });
        }
    }

    fn commit(sp: *Splicer) error{OutOfMemory}!void {
        const gpa = sp.gpa;
        const f = sp.func;
        const n = f.blocks.len;
        const blocks = try gpa.alloc(Ir.Block, n + sp.added.items.len);
        errdefer gpa.free(blocks);
        const values = try sp.values.toOwnedSlice(gpa);
        errdefer gpa.free(values);
        const slots = try sp.slots.toOwnedSlice(gpa);
        errdefer gpa.free(slots);
        var literals = f.literals;
        if (sp.literals.items.len != 0) {
            literals = try gpa.alloc(Ir.Literal, f.literals.len + sp.literals.items.len);
            @memcpy(literals[0..f.literals.len], f.literals);
            @memcpy(literals[f.literals.len..], sp.literals.items);
        }

        // Nothing below fails.
        @memcpy(blocks[0..n], f.blocks);
        @memcpy(blocks[n..], sp.added.items);
        for (sp.heads.items) |h| {
            gpa.free(f.blocks[h.b].instrs);
            blocks[h.b].instrs = h.instrs;
            blocks[h.b].term = .{ .br = .{ .dest = h.dest, .args = &.{} } };
            blocks[h.b].term_line = h.term_line;
        }
        for (sp.spliced.items) |a| gpa.free(a);
        sp.spliced.clearRetainingCapacity();
        sp.heads.clearRetainingCapacity();
        sp.added.clearRetainingCapacity();
        sp.cloned.clearRetainingCapacity();
        gpa.free(f.blocks);
        f.blocks = blocks;
        gpa.free(f.values);
        f.values = values;
        gpa.free(f.slots);
        f.slots = slots;
        if (sp.literals.items.len != 0) {
            gpa.free(f.literals);
            f.literals = literals;
            sp.literals.clearRetainingCapacity();
        }
    }
};

/// Turn the spliced exit block's `ret` into a branch to the continuation `cont`: carrying
/// a scalar result as the continuation's param, or copying an aggregate into the call's
/// `ret_slot` first. `blocks` are the spliced body, indexed like the callee's; `exit_id`
/// is the exit's id once spliced, which the body's branches already name.
fn rewriteReturn(gpa: std.mem.Allocator, e: Emit, blocks: []Ir.Block, exit: Ir.BlockId, exit_id: Ir.BlockId, cont: Ir.BlockId, call: Ir.Call, has_result: bool, ret_ty: Ir.Type) error{OutOfMemory}!void {
    const o = blocks[exit].term.ret;
    if (call.ret_slot == Ir.none_slot) {
        const args: []Ir.Operand = if (has_result) blk: {
            const a = try gpa.alloc(Ir.Operand, 1);
            a[0] = o;
            break :blk a;
        } else &.{};
        blocks[exit].term = .{ .br = .{ .dest = cont, .args = args } };
        return;
    }
    switch (o) {
        .slot => try appendInstrs(gpa, &blocks[exit], e, call.ret_slot, ret_ty, o),
        .value => {
            for (blocks) |*blk| switch (blk.term) {
                .br => |br| if (br.dest == exit_id and br.args.len > 0) {
                    try appendInstrs(gpa, blk, e, call.ret_slot, ret_ty, br.args[0]);
                    gpa.free(br.args);
                    blk.term.br.args = &.{};
                },
                else => {},
            };
            gpa.free(blocks[exit].params);
            blocks[exit].params = &.{};
        },
        .none => unreachable,
    }
    blocks[exit].term = .{ .br = .{ .dest = cont, .args = &.{} } };
}

fn appendInstrs(gpa: std.mem.Allocator, blk: *Ir.Block, e: Emit, dst: Ir.SlotId, ty: Ir.Type, src: Ir.Operand) error{OutOfMemory}!void {
    var list: std.ArrayList(Ir.Instr) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, blk.instrs);
    try e.put(&list, dst, ty, src);
    const out = try list.toOwnedSlice(gpa);
    gpa.free(blk.instrs);
    blk.instrs = out;
}

// Tests: hand-built IR under std.testing.allocator (catches leak/double-free).

const testing = std.testing;
const Opt = @import("Opt.zig");

/// A lookup over a fixed list of callees, by name.
const Table = struct {
    fns: []const *const Ir.Function,
    /// Whether the lookup sizes aggregates: a `str` takes 16 bytes, any other 96.
    sized: bool = false,

    fn lookup(t: *Table) Lookup {
        return .{ .ctx = t, .findFn = find, .bytesFn = if (t.sized) bytes else null };
    }

    fn bytes(_: *anyopaque, ty: Ir.Type) u32 {
        return if (ty.kind == .str) 16 else 96;
    }

    fn find(ctx: *anyopaque, name: []const u8) error{OutOfMemory}!?*const Ir.Function {
        const t: *Table = @ptrCast(@alignCast(ctx));
        for (t.fns) |f| if (std.mem.eql(u8, f.name.name, name)) return f;
        return null;
    }
};

fn vals(gpa: std.mem.Allocator, n: usize) ![]Ir.ValueDef {
    const v = try gpa.alloc(Ir.ValueDef, n);
    for (v) |*x| x.* = .{ .type = Ir.Type.int };
    return v;
}

fn intSlots(gpa: std.mem.Allocator, n: usize) ![]Ir.Slot {
    const s = try gpa.alloc(Ir.Slot, n);
    for (s) |*x| x.* = .{ .type = Ir.Type.int };
    return s;
}

fn ops(gpa: std.mem.Allocator, os: []const Ir.Operand) ![]Ir.Operand {
    return gpa.dupe(Ir.Operand, os);
}

/// `fn name(s0: int) -> int`: b0 loads s0, adds `k`, `br b1(sum)`; b1(%4) returns %4.
/// With `self_call`, b0 first calls itself, a recursive fn.
fn addK(gpa: std.mem.Allocator, name: []const u8, k: i64, self_call: bool) !Ir.Function {
    var instrs: std.ArrayList(Ir.Instr) = .empty;
    errdefer instrs.deinit(gpa);
    try instrs.append(gpa, .{ .result = 0, .op = .{ .slot_addr = 0 } });
    try instrs.append(gpa, .{ .result = 1, .op = .{ .load = .{ .addr = 0, .ty = Ir.Type.int } } });
    try instrs.append(gpa, .{ .result = 2, .op = .{ .iconst = k } });
    try instrs.append(gpa, .{ .result = 3, .op = .{ .add = .{ .lhs = 1, .rhs = 2 } } });
    if (self_call) try instrs.append(gpa, .{ .result = Ir.none_value, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = name },
        .args = try ops(gpa, &.{.{ .value = 3 }}),
        .ret_slot = Ir.none_slot,
    } } });
    var blocks = try gpa.alloc(Ir.Block, 2);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try instrs.toOwnedSlice(gpa), .term = .{ .br = .{ .dest = 1, .args = try ops(gpa, &.{.{ .value = 3 }}) } } };
    blocks[1] = .{ .params = try gpa.dupe(Ir.ValueId, &.{4}), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .{ .value = 4 } } };
    return .{
        .name = .{ .kind = .user_fn, .name = name },
        .params = try gpa.dupe(Ir.SlotId, &.{0}),
        .ret_type = Ir.Type.int,
        .slots = try intSlots(gpa, 1),
        .values = try vals(gpa, 5),
        .blocks = blocks,
        .entry = 0,
        .exit = 1,
    };
}

/// `fn main() -> int { callee(41) }`.
fn caller(gpa: std.mem.Allocator, callee: []const u8) !Ir.Function {
    var instrs = try gpa.alloc(Ir.Instr, 2);
    instrs[0] = .{ .result = 0, .op = .{ .iconst = 41 } };
    instrs[1] = .{ .result = 1, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = callee },
        .args = try ops(gpa, &.{.{ .value = 0 }}),
        .ret_slot = Ir.none_slot,
    } } };
    var blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .{ .value = 1 } } };
    return .{
        .name = .{ .kind = .user_fn, .name = "main" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.int,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = try vals(gpa, 2),
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
}

fn callCount(func: *const Ir.Function) usize {
    var n: usize = 0;
    for (func.blocks) |b| for (b.instrs) |ins| {
        if (ins.op == .call) n += 1;
    };
    return n;
}

/// The constant `func` returns, when its passes folded it to one.
fn returnedConst(func: *const Ir.Function) ?i64 {
    const o = func.blocks[func.exit].term.ret;
    for (func.blocks) |b| for (b.instrs) |ins| {
        if (o == .value and ins.result == o.value) return switch (ins.op) {
            .iconst => |k| k,
            else => null,
        };
    };
    return null;
}

test "inline splices a small callee and the passes fold across the old call" {
    const gpa = testing.allocator;
    var callee = try addK(gpa, "add1", 1, false);
    defer callee.deinit(gpa);
    var table: Table = .{ .fns = &.{&callee} };
    var func = try caller(gpa, "add1");
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try Opt.optimize(gpa, &func, .O1, table.lookup(), &st);
    try testing.expectEqual(@as(usize, 1), st.calls_inlined);
    try testing.expectEqual(@as(usize, 0), callCount(&func));
    try testing.expectEqual(@as(?i64, 42), returnedConst(&func));
    try testing.expectEqual(@as(usize, 1), func.blocks.len);
}

test "inline leaves a recursive callee, an oversized one and a disabled pass as calls" {
    const gpa = testing.allocator;
    var rec = try addK(gpa, "rec", 1, true);
    defer rec.deinit(gpa);
    var add1 = try addK(gpa, "add1", 1, false);
    defer add1.deinit(gpa);
    var table: Table = .{ .fns = &.{ &rec, &add1 } };

    var no_inline = Opt.Config.O1;
    no_inline.@"inline" = false;
    const Case = struct { callee: []const u8, max: usize, cfg: Opt.Config };
    for ([_]Case{
        .{ .callee = "rec", .max = budget, .cfg = .O1 },
        .{ .callee = "add1", .max = 3, .cfg = .O1 },
        .{ .callee = "add1", .max = budget, .cfg = no_inline },
    }) |case| {
        var func = try caller(gpa, case.callee);
        defer func.deinit(gpa);
        var st: Opt.Stats = .{};
        if (case.cfg.@"inline") _ = try run(gpa, &func, table.lookup(), case.max, &st);
        try Opt.optimize(gpa, &func, case.cfg, null, &st);
        try testing.expectEqual(@as(usize, 0), st.calls_inlined);
        try testing.expectEqual(@as(usize, 1), callCount(&func));
    }
}

test "inline skips a callee with a loop" {
    const gpa = testing.allocator;
    var callee = try addK(gpa, "spin", 1, false);
    defer callee.deinit(gpa);
    // b1 branches back to b0 instead of returning.
    callee.blocks[1].term = .{ .br = .{ .dest = 0, .args = &.{} } };
    var func = try caller(gpa, "spin");
    defer func.deinit(gpa);
    const c = func.blocks[0].instrs[1].op.call;
    try testing.expect(!inlinable(&callee, c, 1, budget));
    // Restore the `ret` so `deinit` and the shape agree.
    callee.blocks[1].term = .{ .ret = .{ .value = 4 } };
    try testing.expect(inlinable(&callee, c, 1, budget));
    // A never-returning callee's exit was dropped, leaving a stale id.
    callee.exit = 2;
    try testing.expect(!inlinable(&callee, c, 1, budget));
    callee.exit = 1;
}

test "inline skips a callee that reads its frame address" {
    const gpa = testing.allocator;
    var callee = try addK(gpa, "entry", 1, false);
    defer callee.deinit(gpa);
    var func = try caller(gpa, "entry");
    defer func.deinit(gpa);
    const c = func.blocks[0].instrs[1].op.call;
    try testing.expect(inlinable(&callee, c, 1, budget));
    const was = callee.blocks[0].instrs[1].op;
    callee.blocks[0].instrs[1].op = .frame_addr;
    try testing.expect(!inlinable(&callee, c, 1, budget));
    callee.blocks[0].instrs[1].op = was;
}

test "inline copies an aggregate returned through the exit param into the call's ret slot" {
    const gpa = testing.allocator;
    // fn mk(s0: int) -> P: b0 stores s0's value into s1 (a P), `br b1(s1)`; b1(%3) ret %3.
    var cinstrs = try gpa.alloc(Ir.Instr, 4);
    cinstrs[0] = .{ .result = 0, .op = .{ .slot_addr = 0 } };
    cinstrs[1] = .{ .result = 1, .op = .{ .load = .{ .addr = 0, .ty = Ir.Type.int } } };
    cinstrs[2] = .{ .result = 2, .op = .{ .slot_addr = 1 } };
    cinstrs[3] = .{ .result = Ir.none_value, .op = .{ .store = .{ .addr = 2, .val = 1, .ty = Ir.Type.int } } };
    var cblocks = try gpa.alloc(Ir.Block, 2);
    cblocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = cinstrs, .term = .{ .br = .{ .dest = 1, .args = try ops(gpa, &.{.{ .slot = 1 }}) } } };
    cblocks[1] = .{ .params = try gpa.dupe(Ir.ValueId, &.{3}), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .{ .value = 3 } } };
    var callee: Ir.Function = .{
        .name = .{ .kind = .user_fn, .name = "mk" },
        .params = try gpa.dupe(Ir.SlotId, &.{0}),
        .ret_type = Ir.Type.int,
        .slots = try intSlots(gpa, 2),
        .values = try vals(gpa, 4),
        .blocks = cblocks,
        .entry = 0,
        .exit = 1,
    };
    defer callee.deinit(gpa);

    // fn main(): %0 = iconst 7; call mk(%0) -> s0; ret
    var instrs = try gpa.alloc(Ir.Instr, 2);
    instrs[0] = .{ .result = 0, .op = .{ .iconst = 7 } };
    instrs[1] = .{ .result = Ir.none_value, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "mk" },
        .args = try ops(gpa, &.{.{ .value = 0 }}),
        .ret_slot = 0,
    } } };
    var blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .{ .slot = 0 } } };
    var func: Ir.Function = .{
        .name = .{ .kind = .user_fn, .name = "main" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.int,
        .slots = try intSlots(gpa, 1),
        .values = try vals(gpa, 1),
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
    defer func.deinit(gpa);

    var table: Table = .{ .fns = &.{&callee} };
    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, table.lookup(), budget, &st));
    // b0 -> mk's b0 (now b1) -> mk's exit (b2, param gone) -> continuation b3.
    try testing.expectEqual(@as(usize, 4), func.blocks.len);
    try testing.expectEqual(@as(usize, 0), func.blocks[2].params.len);
    try testing.expectEqual(@as(usize, 0), func.blocks[1].term.br.args.len);
    const last = func.blocks[1].instrs[func.blocks[1].instrs.len - 1].op;
    try testing.expectEqual(@as(Ir.SlotId, 0), func.blocks[1].instrs[func.blocks[1].instrs.len - 3].op.slot_addr);
    try testing.expectEqual(@as(Ir.SlotId, 1 + 1), func.blocks[1].instrs[func.blocks[1].instrs.len - 2].op.slot_addr);
    try testing.expect(last == .copy);
    try testing.expect(func.blocks[3].term == .ret);
    try testing.expectEqual(@as(usize, 1 + 2), func.slots.len);
}

test "inline splices every call of one block, each continuation feeding the next" {
    const gpa = testing.allocator;
    var callee = try addK(gpa, "add1", 1, false);
    defer callee.deinit(gpa);
    var table: Table = .{ .fns = &.{&callee} };
    var func = try caller(gpa, "add1");
    defer func.deinit(gpa);
    // main: %0 = iconst 41; %1 = call add1(%0); %2 = call add1(%1); ret %2
    const second: Ir.Instr = .{ .result = 2, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "add1" },
        .args = try ops(gpa, &.{.{ .value = 1 }}),
        .ret_slot = Ir.none_slot,
    } } };
    const instrs = try gpa.alloc(Ir.Instr, 3);
    @memcpy(instrs[0..2], func.blocks[0].instrs);
    instrs[2] = second;
    gpa.free(func.blocks[0].instrs);
    func.blocks[0].instrs = instrs;
    func.blocks[0].term = .{ .ret = .{ .value = 2 } };
    gpa.free(func.values);
    func.values = try vals(gpa, 3);

    var st: Opt.Stats = .{};
    try Opt.optimize(gpa, &func, .O1, table.lookup(), &st);
    try testing.expectEqual(@as(usize, 2), st.calls_inlined);
    try testing.expectEqual(@as(usize, 0), callCount(&func));
    try testing.expectEqual(@as(?i64, 43), returnedConst(&func));
}

test "inline shares one slot set between spliced bodies, which are never live at once" {
    const gpa = testing.allocator;
    var add1 = try addK(gpa, "add1", 1, false);
    defer add1.deinit(gpa);
    var add2 = try addK(gpa, "add2", 2, false);
    defer add2.deinit(gpa);
    // A second, bool slot: it cannot share the int one.
    gpa.free(add2.slots);
    add2.slots = try gpa.alloc(Ir.Slot, 2);
    add2.slots[0] = .{ .type = Ir.Type.int };
    add2.slots[1] = .{ .type = Ir.Type.bool };
    var table: Table = .{ .fns = &.{ &add1, &add2 } };
    var func = try caller(gpa, "add1");
    defer func.deinit(gpa);
    // main: %0 = iconst 41; %1 = call add1(%0); %2 = call add2(%1); ret %2
    const instrs = try gpa.alloc(Ir.Instr, 3);
    @memcpy(instrs[0..2], func.blocks[0].instrs);
    instrs[2] = .{ .result = 2, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "add2" },
        .args = try ops(gpa, &.{.{ .value = 1 }}),
        .ret_slot = Ir.none_slot,
    } } };
    gpa.free(func.blocks[0].instrs);
    func.blocks[0].instrs = instrs;
    func.blocks[0].term = .{ .ret = .{ .value = 2 } };
    gpa.free(func.values);
    func.values = try vals(gpa, 3);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, table.lookup(), budget, &st));
    try testing.expectEqual(@as(usize, 2), st.calls_inlined);
    try testing.expectEqual(@as(usize, 2), func.slots.len);
    try testing.expect(Ir.Type.eql(Ir.Type.int, func.slots[0].type));
    try testing.expect(Ir.Type.eql(Ir.Type.bool, func.slots[1].type));
    var addrs: usize = 0;
    for (func.blocks) |b| for (b.instrs) |ins| switch (ins.op) {
        .slot_addr => |s| {
            try testing.expectEqual(@as(Ir.SlotId, 0), s);
            addrs += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 4), addrs);
}

test "inline never splices a callee that calls back into the caller" {
    const gpa = testing.allocator;
    // add1 calls main, so splicing it would make main call itself.
    var calls_main = try addK(gpa, "add1", 1, true);
    defer calls_main.deinit(gpa);
    calls_main.blocks[0].instrs[4].op.call.callee.name = "main";
    var table: Table = .{ .fns = &.{&calls_main} };
    var func = try caller(gpa, "add1");
    defer func.deinit(gpa);
    var st: Opt.Stats = .{};
    try testing.expect(!try run(gpa, &func, table.lookup(), budget, &st));
}

/// `caller(callee)` that also calls itself after `callee`, with one slot per `slots`.
fn recursiveCaller(gpa: std.mem.Allocator, callee: []const u8, slots: []const Ir.Type) !Ir.Function {
    var func = try caller(gpa, callee);
    errdefer func.deinit(gpa);
    const instrs = try gpa.alloc(Ir.Instr, 3);
    @memcpy(instrs[0..2], func.blocks[0].instrs);
    instrs[2] = .{ .result = 2, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "main" },
        .args = try ops(gpa, &.{}),
        .ret_slot = Ir.none_slot,
    } } };
    gpa.free(func.blocks[0].instrs);
    func.blocks[0].instrs = instrs;
    gpa.free(func.values);
    func.values = try vals(gpa, 3);
    gpa.free(func.slots);
    func.slots = &.{};
    func.slots = try gpa.alloc(Ir.Slot, slots.len);
    for (func.slots, slots) |*d, t| d.* = .{ .type = t };
    return func;
}

/// `addK(name, k)` with `extra` slots past its int param, which nothing names.
fn addKSlots(gpa: std.mem.Allocator, name: []const u8, k: i64, extra: []const Ir.Type) !Ir.Function {
    var f = try addK(gpa, name, k, false);
    errdefer f.deinit(gpa);
    gpa.free(f.slots);
    f.slots = &.{};
    f.slots = try gpa.alloc(Ir.Slot, 1 + extra.len);
    f.slots[0] = .{ .type = Ir.Type.int };
    for (f.slots[1..], extra) |*d, t| d.* = .{ .type = t };
    return f;
}

test "a recursive caller takes callees while their unpromoted slots' bytes fit its budget" {
    const gpa = testing.allocator;
    const str = Ir.Type.str;
    const big = Ir.Type.structT(0);
    const Case = struct {
        /// The callee's slots past its int param, which mem2reg promotes; mem2reg never
        /// promotes an aggregate one.
        extra: []const Ir.Type,
        caller_slots: []const Ir.Type = &.{},
        sized: bool = true,
        inlined: bool,
    };
    for ([_]Case{
        .{ .extra = &.{}, .inlined = true },
        .{ .extra = &.{}, .sized = false, .inlined = true },
        .{ .extra = &.{str}, .inlined = true },
        .{ .extra = &.{str}, .sized = false, .inlined = false },
        .{ .extra = &.{ str, str }, .caller_slots = &.{ str, str }, .inlined = false },
        // A caller slot of the type does not bound its size: this one is 96 bytes.
        .{ .extra = &.{big}, .caller_slots = &.{big}, .inlined = false },
    }) |case| {
        var add2 = try addKSlots(gpa, "add2", 2, case.extra);
        defer add2.deinit(gpa);
        var table: Table = .{ .fns = &.{&add2}, .sized = case.sized };
        var func = try recursiveCaller(gpa, "add2", case.caller_slots);
        defer func.deinit(gpa);
        var st: Opt.Stats = .{};
        try testing.expectEqual(case.inlined, try run(gpa, &func, table.lookup(), budget, &st));
        try testing.expectEqual(@as(usize, if (case.inlined) 1 else 2), callCount(&func));
    }
}

test "a recursive caller's spliced bodies share their budget through the slot pool" {
    const gpa = testing.allocator;
    const str = Ir.Type.str;
    var add1 = try addKSlots(gpa, "add1", 1, &.{str});
    defer add1.deinit(gpa);
    var add2 = try addKSlots(gpa, "add2", 2, &.{str});
    defer add2.deinit(gpa);
    var add3 = try addKSlots(gpa, "add3", 3, &.{Ir.Type.structT(0)});
    defer add3.deinit(gpa);
    var table: Table = .{ .fns = &.{ &add1, &add2, &add3 }, .sized = true };
    // main: %0 = iconst 41; %1 = call add1(%0); %2 = call add2(%1); %3 = call add3(%2);
    // call main(); ret %1
    var func = try recursiveCaller(gpa, "add1", &.{});
    defer func.deinit(gpa);
    const instrs = try gpa.alloc(Ir.Instr, 5);
    @memcpy(instrs[0..3], func.blocks[0].instrs);
    instrs[4] = instrs[2];
    instrs[4].result = 4;
    instrs[2] = .{ .result = 2, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "add2" },
        .args = try ops(gpa, &.{.{ .value = 1 }}),
        .ret_slot = Ir.none_slot,
    } } };
    instrs[3] = .{ .result = 3, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "add3" },
        .args = try ops(gpa, &.{.{ .value = 2 }}),
        .ret_slot = Ir.none_slot,
    } } };
    gpa.free(func.blocks[0].instrs);
    func.blocks[0].instrs = instrs;
    gpa.free(func.values);
    func.values = try vals(gpa, 5);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, table.lookup(), budget, &st));
    try testing.expectEqual(@as(usize, 2), st.calls_inlined);
    // One shared int and one shared str; add3's struct slot is over the budget.
    try testing.expectEqual(@as(usize, 2), func.slots.len);
}

test "a recursive caller never takes a callee with an aggregate cell of its own" {
    const gpa = testing.allocator;
    var add2 = try addK(gpa, "add2", 2, false);
    defer add2.deinit(gpa);
    add2.values[3] = .{ .type = Ir.Type.str };
    var table: Table = .{ .fns = &.{&add2} };
    var func = try recursiveCaller(gpa, "add2", &.{Ir.Type.str});
    defer func.deinit(gpa);
    var st: Opt.Stats = .{};
    try testing.expect(!try run(gpa, &func, table.lookup(), budget, &st));
}

test "splice takes an oversized callee, and into a caller that recurses" {
    const gpa = testing.allocator;
    var add1 = try addK(gpa, "add1", 1, false);
    defer add1.deinit(gpa);
    var table: Table = .{ .fns = &.{&add1} };
    var func = try recursiveCaller(gpa, "add1", &.{});
    defer func.deinit(gpa);
    var st: Opt.Stats = .{};
    try testing.expect(!try run(gpa, &func, table.lookup(), 3, &st));
    try testing.expect(!fits(&add1, 3));
    try testing.expect(try splice(gpa, &func, table.lookup(), &st));
    try testing.expectEqual(@as(usize, 1), st.calls_inlined);
    try testing.expectEqual(@as(usize, 1), callCount(&func));
}

var spliced_table: Table = .{ .fns = &.{} };

test "optimize splices last, and only with a spliced lookup" {
    const gpa = testing.allocator;
    var add1 = try addK(gpa, "add1", 1, false);
    defer add1.deinit(gpa);
    var none: Table = .{ .fns = &.{} };
    spliced_table = .{ .fns = &.{&add1} };
    for ([_]bool{ false, true }) |with| {
        var func = try caller(gpa, "add1");
        defer func.deinit(gpa);
        // The regular inliner finds nothing, so only `splicedFn` can take the call.
        var l = none.lookup();
        if (with) l.splicedFn = struct {
            fn f(_: *anyopaque, name: []const u8) error{OutOfMemory}!?*const Ir.Function {
                return Table.find(&spliced_table, name);
            }
        }.f;
        var st: Opt.Stats = .{};
        try Opt.optimize(gpa, &func, .O1, l, &st);
        try testing.expectEqual(@as(usize, if (with) 0 else 1), callCount(&func));
        try testing.expectEqual(@as(?i64, if (with) 42 else null), returnedConst(&func));
    }
}
