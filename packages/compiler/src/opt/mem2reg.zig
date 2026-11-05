//! PASS — mem2reg: promote a scalar local slot whose address never escapes to SSA
//! values, carried across joins as block params.
//!
//! WHY: lowering keeps every named local in a slot, and `forward` reasons inside one
//! block only, so loop state round-trips through the frame on every iteration. Once a
//! slot is a value, linear scan can keep it in a register.
//!
//! CANDIDATE: a slot of a register type (int, bool, float, rawptr, cstr) that no
//! operand names directly (an aggregate call arg, a ret slot, a branch arg) and whose
//! every `slot_addr` is used only as the address of a `load` or `store`. Every value
//! stored and loaded must fit the slot's type exactly (any int width counts as one int,
//! a load and store are a full word): a promoted value keeps the register class and the
//! GC reference-ness its type gives it, so a reference stays in a stack map at every
//! safepoint the way its slot did.
//!
//! CONSTRUCTION (pruned SSA plus trivial-param removal, Braun et al. §3.2): a block with
//! two or more predecessors gets one param per promoted slot live into it. Blocks are
//! renamed in reverse postorder: a load reads the current value, a store sets it, a
//! single-predecessor block starts from its predecessor's values. A param whose incoming
//! values are all one value (or itself) is replaced by that value, to a fixpoint. A slot
//! read before any store on some path reads its memory once at the entry: that is a
//! param's incoming argument, and garbage nothing observes otherwise.
//!
//! EDGES: `cond_br` is argless, so an edge from one into a block that keeps a param gets
//! a new block holding the `br` with the args, placed right after that predecessor. Its
//! args follow the dest's own params, which a `br` leaves off when they are unit.
//! Unreachable blocks are dropped first so every predecessor has values to pass.
//!
//! MEMORY: blocks, params, br args and instrs are rebuilt alloc-copy-free-old; the dead
//! `slot_addr`s and slots are left for DCE.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const Opt = @import("Opt.zig");
const walk = @import("walk.zig");
const branch = @import("branch.zig");

const none = Ir.none_value;
const no_slot = std.math.maxInt(u32);

pub fn run(gpa: std.mem.Allocator, func: *Ir.Function, stats: *Opt.Stats) error{OutOfMemory}!bool {
    if (func.slots.len == 0 or func.blocks.len == 0) return false;
    const promote = try candidates(gpa, func);
    defer gpa.free(promote);
    if (std.mem.indexOfScalar(bool, promote, true) == null) return false;

    const dropped = try branch.elimUnreachable(gpa, func, stats);
    var cfg = try Cfg.init(gpa, func);
    defer cfg.deinit(gpa);
    if (cfg.predsOf(func.entry).len != 0) return dropped;
    try promoteSlots(gpa, func, &cfg, promote, stats);
    return true;
}

fn registerType(t: Ir.Type) bool {
    return switch (t.kind) {
        .int, .bool, .float, .rawptr, .cstr => true,
        else => false,
    };
}

fn fits(t: Ir.Type, slot: Ir.Type) bool {
    return t.eql(slot) or (t.kind == .int and slot.kind == .int);
}

/// Which of `func`'s slots this pass promotes.
pub fn candidates(gpa: std.mem.Allocator, func: *const Ir.Function) error{OutOfMemory}![]bool {
    const ok = try gpa.alloc(bool, func.slots.len);
    errdefer gpa.free(ok);
    for (func.slots, ok) |s, *o| o.* = registerType(s.type);

    const sites = try gpa.alloc(u32, func.slots.len);
    defer gpa.free(sites);
    @memset(sites, 0);
    walk.forEachSlotUse(func, sites, struct {
        fn count(c: []u32, s: Ir.SlotId) void {
            if (s < c.len) c[s] += 1;
        }
    }.count);

    const slot_of = try gpa.alloc(Ir.SlotId, func.values.len);
    defer gpa.free(slot_of);
    @memset(slot_of, no_slot);
    for (func.blocks) |b| for (b.instrs) |ins| switch (ins.op) {
        .slot_addr => |s| if (s < sites.len) {
            sites[s] -= 1;
            if (ins.result != none) slot_of[ins.result] = s;
        },
        else => {},
    };
    for (sites, ok) |n, *o| if (n != 0) {
        o.* = false;
    };

    const uses = try gpa.alloc(u32, func.values.len);
    defer gpa.free(uses);
    @memset(uses, 0);
    walk.forEachValueUse(func, uses, struct {
        fn count(c: []u32, v: Ir.ValueId) void {
            if (v < c.len) c[v] += 1;
        }
    }.count);
    const addr_uses = try gpa.alloc(u32, func.values.len);
    defer gpa.free(addr_uses);
    @memset(addr_uses, 0);
    for (func.blocks) |b| for (b.instrs) |ins| switch (ins.op) {
        .load => |l| if (l.addr < slot_of.len and slot_of[l.addr] != no_slot and ins.result != none) {
            if (fits(func.values[ins.result].type, func.slots[slot_of[l.addr]].type)) addr_uses[l.addr] += 1;
        },
        .store => |st| if (st.addr < slot_of.len and slot_of[st.addr] != no_slot and st.val < func.values.len) {
            if (fits(func.values[st.val].type, func.slots[slot_of[st.addr]].type)) addr_uses[st.addr] += 1;
        },
        else => {},
    };
    for (slot_of, uses, addr_uses) |s, u, a| if (s != no_slot and u != a) {
        ok[s] = false;
    };
    return ok;
}

/// Distinct predecessors per block (ascending id) and a reverse postorder from the entry.
const Cfg = struct {
    start: []u32,
    preds: []Ir.BlockId,
    rpo: []Ir.BlockId,

    fn init(gpa: std.mem.Allocator, func: *const Ir.Function) error{OutOfMemory}!Cfg {
        const n = func.blocks.len;
        const start = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        for (func.blocks) |b| {
            var s: [2]Ir.BlockId = undefined;
            for (s[0..walk.successors(b.term, &s)]) |x| start[x + 1] += 1;
        }
        for (1..n + 1) |i| start[i] += start[i - 1];
        const preds = try gpa.alloc(Ir.BlockId, start[n]);
        errdefer gpa.free(preds);
        const fill = try gpa.dupe(u32, start[0..n]);
        defer gpa.free(fill);
        for (func.blocks, 0..) |b, i| {
            var s: [2]Ir.BlockId = undefined;
            for (s[0..walk.successors(b.term, &s)]) |x| {
                preds[fill[x]] = @intCast(i);
                fill[x] += 1;
            }
        }

        const rpo = try gpa.alloc(Ir.BlockId, n);
        errdefer gpa.free(rpo);
        const seen = try gpa.alloc(bool, n);
        defer gpa.free(seen);
        @memset(seen, false);
        const Frame = struct { b: Ir.BlockId, next: u8 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        var at = n;
        try stack.append(gpa, .{ .b = func.entry, .next = 0 });
        seen[func.entry] = true;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            var s: [2]Ir.BlockId = undefined;
            const k = walk.successors(func.blocks[top.b].term, &s);
            if (top.next < k) {
                const x = s[top.next];
                top.next += 1;
                if (!seen[x]) {
                    seen[x] = true;
                    try stack.append(gpa, .{ .b = x, .next = 0 });
                }
            } else {
                at -= 1;
                rpo[at] = top.b;
                _ = stack.pop();
            }
        }
        // Unreachable blocks were dropped, so the walk saw every block.
        std.debug.assert(at == 0);
        return .{ .start = start, .preds = preds, .rpo = rpo };
    }

    fn deinit(c: *Cfg, gpa: std.mem.Allocator) void {
        gpa.free(c.start);
        gpa.free(c.preds);
        gpa.free(c.rpo);
    }

    fn predsOf(c: *const Cfg, b: Ir.BlockId) []const Ir.BlockId {
        return c.preds[c.start[b]..c.start[b + 1]];
    }
};

const Bits = struct {
    words: []u64,
    w: usize,

    fn init(gpa: std.mem.Allocator, rows: usize, cols: usize) error{OutOfMemory}!Bits {
        const w = (cols + 63) / 64;
        const words = try gpa.alloc(u64, rows * w);
        @memset(words, 0);
        return .{ .words = words, .w = w };
    }
    fn row(b: Bits, r: usize) []u64 {
        return b.words[r * b.w ..][0..b.w];
    }
    fn get(b: Bits, r: usize, c: usize) bool {
        return b.words[r * b.w + c / 64] >> @intCast(c % 64) & 1 != 0;
    }
    fn set(b: Bits, r: usize, c: usize) void {
        b.words[r * b.w + c / 64] |= @as(u64, 1) << @intCast(c % 64);
    }
};

const State = struct {
    gpa: std.mem.Allocator,
    func: *Ir.Function,
    /// Promoted slot ids, by promoted index.
    slots: []const Ir.SlotId,
    /// Value defs appended past `func.values`.
    new_values: std.ArrayList(Ir.ValueDef) = .empty,
    /// Per value, the value it was replaced by (itself when kept).
    remap: std.ArrayList(Ir.ValueId) = .empty,
    /// Per promoted slot, its memory read once at the entry, or `none`.
    initial: []Ir.ValueId,
    /// The entry reads behind `initial`, placed before the entry's own instrs.
    prefix: std.ArrayList(Ir.Instr) = .empty,

    fn value(s: *State, ty: Ir.Type) error{OutOfMemory}!Ir.ValueId {
        const id: Ir.ValueId = @intCast(s.func.values.len + s.new_values.items.len);
        try s.new_values.append(s.gpa, .{ .type = ty });
        try s.remap.append(s.gpa, id);
        return id;
    }

    fn entryValue(s: *State, p: usize) error{OutOfMemory}!Ir.ValueId {
        if (s.initial[p] != none) return s.initial[p];
        const slot = s.slots[p];
        const addr = try s.value(Ir.Type.int);
        const v = try s.value(s.func.slots[slot].type);
        try s.prefix.append(s.gpa, .{ .result = addr, .op = .{ .slot_addr = slot } });
        try s.prefix.append(s.gpa, .{ .result = v, .op = .{ .load = .{ .addr = addr, .ty = s.func.slots[slot].type } } });
        s.initial[p] = v;
        return v;
    }

    fn resolve(s: *const State, v: Ir.ValueId) Ir.ValueId {
        var x = v;
        while (x < s.remap.items.len and s.remap.items[x] != x) x = s.remap.items[x];
        return x;
    }
};

fn promoteSlots(gpa: std.mem.Allocator, func: *Ir.Function, cfg: *const Cfg, promote: []const bool, stats: *Opt.Stats) error{OutOfMemory}!void {
    const n = func.blocks.len;
    var slot_list: std.ArrayList(Ir.SlotId) = .empty;
    defer slot_list.deinit(gpa);
    const pidx = try gpa.alloc(u32, func.slots.len);
    defer gpa.free(pidx);
    for (promote, pidx, 0..) |ok, *p, s| {
        p.* = if (ok) @intCast(slot_list.items.len) else no_slot;
        if (ok) try slot_list.append(gpa, @intCast(s));
    }
    const np = slot_list.items.len;

    // Per value, the promoted index of the slot it is the address of.
    const prom_of = try gpa.alloc(u32, func.values.len);
    defer gpa.free(prom_of);
    @memset(prom_of, no_slot);
    for (func.blocks) |b| for (b.instrs) |ins| switch (ins.op) {
        .slot_addr => |s| if (ins.result != none) {
            prom_of[ins.result] = pidx[s];
        },
        else => {},
    };
    const Access = struct {
        fn of(po: []const u32, op: Ir.Op) ?u32 {
            const addr = switch (op) {
                .load => |l| l.addr,
                .store => |st| st.addr,
                else => return null,
            };
            if (addr >= po.len or po[addr] == no_slot) return null;
            return po[addr];
        }
    };

    // Liveness of each promoted slot at block entry.
    const gen = try Bits.init(gpa, n, np);
    defer gpa.free(gen.words);
    const kill = try Bits.init(gpa, n, np);
    defer gpa.free(kill.words);
    const live = try Bits.init(gpa, n, np);
    defer gpa.free(live.words);
    for (func.blocks, 0..) |b, bi| for (b.instrs) |ins| {
        const p = Access.of(prom_of, ins.op) orelse continue;
        switch (ins.op) {
            .load => if (!kill.get(bi, p)) gen.set(bi, p),
            .store => kill.set(bi, p),
            else => unreachable,
        }
    };
    @memcpy(live.words, gen.words);
    var changed = true;
    while (changed) {
        changed = false;
        var i = n;
        while (i > 0) {
            i -= 1;
            const b = cfg.rpo[i];
            var s: [2]Ir.BlockId = undefined;
            const k = walk.successors(func.blocks[b].term, &s);
            for (0..live.w) |w| {
                var out: u64 = 0;
                for (s[0..k]) |x| out |= live.row(x)[w];
                const in = gen.row(b)[w] | (out & ~kill.row(b)[w]);
                if (in != live.row(b)[w]) {
                    live.row(b)[w] = in;
                    changed = true;
                }
            }
        }
    }

    var st: State = .{ .gpa = gpa, .func = func, .slots = slot_list.items, .initial = try gpa.alloc(Ir.ValueId, np) };
    defer {
        gpa.free(st.initial);
        st.new_values.deinit(gpa);
        st.remap.deinit(gpa);
        st.prefix.deinit(gpa);
    }
    @memset(st.initial, none);
    try st.remap.ensureTotalCapacity(gpa, func.values.len);
    for (0..func.values.len) |v| st.remap.appendAssumeCapacity(@intCast(v));

    const param = try gpa.alloc(Ir.ValueId, n * np);
    defer gpa.free(param);
    @memset(param, none);
    for (0..n) |b| {
        if (b == func.entry or cfg.predsOf(@intCast(b)).len < 2) continue;
        for (0..np) |p| if (live.get(b, p)) {
            param[b * np + p] = try st.value(func.slots[slot_list.items[p]].type);
        };
    }

    const out = try gpa.alloc(Ir.ValueId, n * np);
    defer gpa.free(out);
    @memset(out, none);
    for (cfg.rpo) |b| {
        const cur = out[b * np ..][0..np];
        const preds = cfg.predsOf(b);
        for (cur, 0..) |*c, p| {
            c.* = param[b * np + p];
            if (c.* == none and preds.len == 1) c.* = out[preds[0] * np + p];
        }
        for (func.blocks[b].instrs) |ins| {
            const p = Access.of(prom_of, ins.op) orelse continue;
            switch (ins.op) {
                .load => {
                    if (cur[p] == none) cur[p] = try st.entryValue(p);
                    st.remap.items[ins.result] = cur[p];
                },
                .store => |s| cur[p] = s.val,
                else => unreachable,
            }
        }
    }

    for (0..n) |b| for (0..np) |p| if (param[b * np + p] != none) {
        for (cfg.predsOf(@intCast(b))) |q| {
            if (out[q * np + p] == none) out[q * np + p] = try st.entryValue(p);
        }
    };

    changed = true;
    while (changed) {
        changed = false;
        for (0..n) |b| for (0..np) |p| {
            const v = param[b * np + p];
            if (v == none or st.remap.items[v] != v) continue;
            var same: Ir.ValueId = none;
            const trivial = for (cfg.predsOf(@intCast(b))) |q| {
                const a = st.resolve(out[q * np + p]);
                if (a == v or a == same) continue;
                if (same != none) break false;
                same = a;
            } else true;
            if (trivial and same != none) {
                st.remap.items[v] = same;
                changed = true;
            }
        };
    }

    var added: std.ArrayList(Ir.Block) = .empty;
    defer added.deinit(gpa);
    var added_pred: std.ArrayList(Ir.BlockId) = .empty;
    defer added_pred.deinit(gpa);
    for (0..n) |b| {
        var k: usize = 0;
        for (0..np) |p| {
            const v = param[b * np + p];
            if (v != none and st.remap.items[v] == v) k += 1;
        }
        if (k == 0) continue;
        const blk = &func.blocks[b];
        const orig = blk.params.len;
        const params = try gpa.alloc(Ir.ValueId, blk.params.len + k);
        @memcpy(params[0..blk.params.len], blk.params);
        var j = blk.params.len;
        for (0..np) |p| {
            const v = param[b * np + p];
            if (v == none or st.remap.items[v] != v) continue;
            params[j] = v;
            j += 1;
        }
        gpa.free(blk.params);
        blk.params = params;

        for (cfg.predsOf(@intCast(b))) |q| {
            // Lower leaves unit args off the end of a `br`, so the new args go after the
            // dest's own params, not after the args it happens to carry.
            const args = try gpa.alloc(Ir.Operand, orig + k);
            @memset(args[0..orig], .none);
            var a: usize = orig;
            for (0..np) |p| {
                const v = param[b * np + p];
                if (v == none or st.remap.items[v] != v) continue;
                args[a] = .{ .value = st.resolve(out[q * np + p]) };
                a += 1;
            }
            const pred = &func.blocks[q];
            switch (pred.term) {
                .br => |*br| {
                    std.debug.assert(br.args.len <= orig);
                    @memcpy(args[0..br.args.len], br.args);
                    gpa.free(br.args);
                    br.args = args;
                },
                .cond_br => |*c| {
                    const e: Ir.BlockId = @intCast(n + added.items.len);
                    try added.append(gpa, .{
                        .params = &.{},
                        .instrs = &.{},
                        .term = .{ .br = .{ .dest = @intCast(b), .args = args } },
                        .term_line = pred.term_line,
                    });
                    try added_pred.append(gpa, q);
                    if (c.t == b) c.t = e;
                    if (c.f == b) c.f = e;
                },
                .ret, .@"unreachable", .panic => unreachable,
            }
        }
    }
    for (func.blocks[0..n], 0..) |*blk, b| {
        const lead = if (b == func.entry) st.prefix.items else &.{};
        var kept: usize = lead.len;
        for (blk.instrs) |ins| {
            if (Access.of(prom_of, ins.op) == null) kept += 1;
        }
        if (lead.len == 0 and kept == blk.instrs.len) continue;
        const instrs = try gpa.alloc(Ir.Instr, kept);
        @memcpy(instrs[0..lead.len], lead);
        var j = lead.len;
        for (blk.instrs) |ins| {
            if (Access.of(prom_of, ins.op) != null) continue;
            instrs[j] = ins;
            j += 1;
        }
        gpa.free(blk.instrs);
        blk.instrs = instrs;
    }

    if (added.items.len != 0) try placeEdges(gpa, func, added.items, added_pred.items);

    if (st.new_values.items.len != 0) {
        const values = try gpa.alloc(Ir.ValueDef, func.values.len + st.new_values.items.len);
        @memcpy(values[0..func.values.len], func.values);
        @memcpy(values[func.values.len..], st.new_values.items);
        gpa.free(func.values);
        func.values = values;
    }
    for (st.remap.items, 0..) |*r, v| r.* = st.resolve(@intCast(v));
    walk.remapUses(func, @as([]const Ir.ValueId, st.remap.items), struct {
        fn map(m: []const Ir.ValueId, v: Ir.ValueId) Ir.ValueId {
            return if (v < m.len) m[v] else v;
        }
    }.map);
    stats.slots_promoted += np;
}

/// Splices each split-edge block in right after its predecessor and renumbers: blocks
/// emit in id order, so an edge block at the end would turn a fallthrough into a jump
/// out of line and back. A back edge stays at or before its source, as Isel expects.
fn placeEdges(gpa: std.mem.Allocator, func: *Ir.Function, added: []const Ir.Block, pred: []const Ir.BlockId) error{OutOfMemory}!void {
    const n = func.blocks.len;
    const total = n + added.len;
    const after = try gpa.alloc(u32, n + 1);
    defer gpa.free(after);
    @memset(after, 0);
    for (pred) |q| after[q + 1] += 1;
    for (1..n + 1) |i| after[i] += after[i - 1];
    const order = try gpa.alloc(u32, added.len);
    defer gpa.free(order);
    const fill = try gpa.dupe(u32, after[0..n]);
    defer gpa.free(fill);
    for (pred, 0..) |q, i| {
        order[fill[q]] = @intCast(i);
        fill[q] += 1;
    }

    const map = try gpa.alloc(Ir.BlockId, total);
    defer gpa.free(map);
    const blocks = try gpa.alloc(Ir.Block, total);
    var at: Ir.BlockId = 0;
    for (0..n) |b| {
        map[b] = at;
        blocks[at] = func.blocks[b];
        at += 1;
        for (order[after[b]..after[b + 1]]) |i| {
            map[n + i] = at;
            blocks[at] = added[i];
            at += 1;
        }
    }
    for (blocks) |*blk| walk.remapBlockTargets(blk, @as([]const Ir.BlockId, map), struct {
        fn f(m: []const Ir.BlockId, x: Ir.BlockId) Ir.BlockId {
            return m[x];
        }
    }.f);
    func.entry = map[func.entry];
    if (func.exit < n) func.exit = map[func.exit];
    gpa.free(func.blocks);
    func.blocks = blocks;
}

// Tests — hand-built IR under std.testing.allocator (catches leak/double-free).

const testing = std.testing;

/// Builds a function block by block. `slots` are the slot types, `nvals` int values
/// unless `types` overrides one.
const Build = struct {
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(Ir.Block) = .empty,

    fn block(b: *Build, params: []const Ir.ValueId, instrs: []const Ir.Instr, term: Ir.Terminator) !void {
        const t: Ir.Terminator = switch (term) {
            .br => |br| .{ .br = .{ .dest = br.dest, .args = try b.gpa.dupe(Ir.Operand, br.args) } },
            else => term,
        };
        try b.blocks.append(b.gpa, .{ .params = try b.gpa.dupe(Ir.ValueId, params), .instrs = try b.gpa.dupe(Ir.Instr, instrs), .term = t });
    }

    fn finish(b: *Build, slots: []const Ir.Type, params: []const Ir.SlotId, types: []const Ir.Type) !Ir.Function {
        const sl = try b.gpa.alloc(Ir.Slot, slots.len);
        for (sl, slots) |*s, t| s.* = .{ .type = t };
        const vals = try b.gpa.alloc(Ir.ValueDef, types.len);
        for (vals, types) |*v, t| v.* = .{ .type = t };
        return .{
            .name = .{ .kind = .user_fn, .name = "t" },
            .params = try b.gpa.dupe(Ir.SlotId, params),
            .ret_type = Ir.Type.int,
            .slots = sl,
            .values = vals,
            .blocks = try b.blocks.toOwnedSlice(b.gpa),
            .entry = 0,
            .exit = @intCast(b.blocks.items.len),
        };
    }
};

fn ints(comptime n: usize) [n]Ir.Type {
    return @splat(Ir.Type.int);
}

fn sa(r: Ir.ValueId, s: Ir.SlotId) Ir.Instr {
    return .{ .result = r, .op = .{ .slot_addr = s } };
}
fn ld(r: Ir.ValueId, a: Ir.ValueId) Ir.Instr {
    return .{ .result = r, .op = .{ .load = .{ .addr = a, .ty = Ir.Type.int } } };
}
fn sto(a: Ir.ValueId, v: Ir.ValueId) Ir.Instr {
    return .{ .result = none, .op = .{ .store = .{ .addr = a, .val = v, .ty = Ir.Type.int } } };
}
fn iconst(r: Ir.ValueId, k: i64) Ir.Instr {
    return .{ .result = r, .op = .{ .iconst = k } };
}

fn countMemOps(func: *const Ir.Function) usize {
    var k: usize = 0;
    for (func.blocks) |b| for (b.instrs) |ins| switch (ins.op) {
        .load, .store => k += 1,
        else => {},
    };
    return k;
}

test "mem2reg: straight line store then load reads the stored value" {
    const gpa = testing.allocator;
    var b: Build = .{ .gpa = gpa };
    // %0=iconst 5; store s0,%0; %2=load s0; store s0,%2+... ; ret load s0
    try b.block(&.{}, &.{ iconst(0, 5), sa(1, 0), sto(1, 0), sa(2, 0), ld(3, 2), iconst(4, 7), sto(2, 4), ld(5, 1) }, .{ .ret = .{ .value = 5 } });
    var func = try b.finish(&.{Ir.Type.int}, &.{}, &ints(6));
    func.exit = 0;
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 1), st.slots_promoted);
    try testing.expectEqual(@as(usize, 0), countMemOps(&func));
    try testing.expectEqual(@as(Ir.ValueId, 4), func.blocks[0].term.ret.value);
}

test "mem2reg: an if/else join gets a param, and a cond_br edge into it is split" {
    const gpa = testing.allocator;
    var b: Build = .{ .gpa = gpa };
    // b0: x=1; cond_br %c, b1, b2     b1: x=2; br b2     b2: ret x
    try b.block(&.{}, &.{ iconst(0, 1), sa(1, 0), sto(1, 0), .{ .result = 2, .op = .{ .bconst = true } } }, .{ .cond_br = .{ .cond = 2, .t = 1, .f = 2 } });
    try b.block(&.{}, &.{ iconst(3, 2), sa(4, 0), sto(4, 3) }, .{ .br = .{ .dest = 2, .args = &.{} } });
    try b.block(&.{}, &.{ sa(5, 0), ld(6, 5) }, .{ .ret = .{ .value = 6 } });
    var types = ints(7);
    types[2] = Ir.Type.bool;
    var func = try b.finish(&.{Ir.Type.int}, &.{}, &types);
    func.exit = 2;
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 0), countMemOps(&func));
    try testing.expectEqual(@as(usize, 4), func.blocks.len);
    try testing.expectEqual(@as(Ir.BlockId, 3), func.exit);
    const join = func.blocks[3];
    try testing.expectEqual(@as(usize, 1), join.params.len);
    try testing.expectEqual(join.params[0], join.term.ret.value);
    // The false edge runs through a new block, laid out right after the entry, that
    // passes the entry's value; the old b1 moves up to b2.
    try testing.expectEqual(@as(Ir.BlockId, 2), func.blocks[0].term.cond_br.t);
    try testing.expectEqual(@as(Ir.BlockId, 1), func.blocks[0].term.cond_br.f);
    try testing.expectEqual(@as(Ir.BlockId, 3), func.blocks[1].term.br.dest);
    try testing.expectEqual(@as(Ir.ValueId, 0), func.blocks[1].term.br.args[0].value);
    try testing.expectEqual(@as(Ir.BlockId, 3), func.blocks[2].term.br.dest);
    try testing.expectEqual(@as(Ir.ValueId, 3), func.blocks[2].term.br.args[0].value);
}

test "mem2reg: new args follow a join's own params even when a br leaves its unit arg off" {
    const gpa = testing.allocator;
    var b: Build = .{ .gpa = gpa };
    // b0: x=1; cond_br %c, b1, b2     b1: x=2; br b2()     b2(%5:unit): ret x
    try b.block(&.{}, &.{ iconst(0, 1), sa(1, 0), sto(1, 0), .{ .result = 2, .op = .{ .bconst = true } } }, .{ .cond_br = .{ .cond = 2, .t = 1, .f = 2 } });
    try b.block(&.{}, &.{ iconst(3, 2), sa(4, 0), sto(4, 3) }, .{ .br = .{ .dest = 2, .args = &.{} } });
    try b.block(&.{5}, &.{ sa(6, 0), ld(7, 6) }, .{ .ret = .{ .value = 7 } });
    var types = ints(8);
    types[2] = Ir.Type.bool;
    types[5] = Ir.Type.unit;
    var func = try b.finish(&.{Ir.Type.int}, &.{}, &types);
    func.exit = 2;
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    const join = func.blocks[func.exit];
    try testing.expectEqual(@as(usize, 2), join.params.len);
    try testing.expectEqual(@as(Ir.ValueId, 5), join.params[0]);
    try testing.expectEqual(join.params[1], join.term.ret.value);
    const from_then = func.blocks[func.blocks[0].term.cond_br.t].term.br.args;
    try testing.expectEqual(@as(usize, 2), from_then.len);
    try testing.expect(from_then[0] == .none);
    try testing.expectEqual(@as(Ir.ValueId, 3), from_then[1].value);
    const edge = func.blocks[func.blocks[0].term.cond_br.f].term.br.args;
    try testing.expectEqual(@as(usize, 2), edge.len);
    try testing.expect(edge[0] == .none);
    try testing.expectEqual(@as(Ir.ValueId, 0), edge[1].value);
}

test "mem2reg: a loop header gets a param fed by the back edge; an unchanged local gets none" {
    const gpa = testing.allocator;
    var b: Build = .{ .gpa = gpa };
    // b0: i=0; k=10; br b1    b1: cond_br i<k, b2, b3
    // b2: i=i+1; br b1        b3: ret i
    try b.block(&.{}, &.{ iconst(0, 0), sa(1, 0), sto(1, 0), iconst(2, 10), sa(3, 1), sto(3, 2) }, .{ .br = .{ .dest = 1, .args = &.{} } });
    try b.block(&.{}, &.{ sa(4, 0), ld(5, 4), sa(6, 1), ld(7, 6), .{ .result = 8, .op = .{ .icmp = .{ .cc = .lt, .lhs = 5, .rhs = 7 } } } }, .{ .cond_br = .{ .cond = 8, .t = 2, .f = 3 } });
    try b.block(&.{}, &.{ sa(9, 0), ld(10, 9), iconst(11, 1), .{ .result = 12, .op = .{ .add = .{ .lhs = 10, .rhs = 11 } } }, sto(9, 12) }, .{ .br = .{ .dest = 1, .args = &.{} } });
    try b.block(&.{}, &.{ sa(13, 0), ld(14, 13) }, .{ .ret = .{ .value = 14 } });
    var types = ints(15);
    types[8] = Ir.Type.bool;
    var func = try b.finish(&.{ Ir.Type.int, Ir.Type.int }, &.{}, &types);
    func.exit = 3;
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 2), st.slots_promoted);
    try testing.expectEqual(@as(usize, 0), countMemOps(&func));
    const head = func.blocks[1];
    try testing.expectEqual(@as(usize, 1), head.params.len);
    const i = head.params[0];
    const cmp = head.instrs[head.instrs.len - 1].op.icmp;
    try testing.expectEqual(i, cmp.lhs);
    try testing.expectEqual(@as(Ir.ValueId, 2), cmp.rhs);
    try testing.expectEqual(@as(Ir.ValueId, 0), func.blocks[0].term.br.args[0].value);
    try testing.expectEqual(@as(Ir.ValueId, 12), func.blocks[2].term.br.args[0].value);
    try testing.expectEqual(i, func.blocks[2].instrs[2].op.add.lhs);
    try testing.expectEqual(i, func.blocks[3].term.ret.value);
}

test "mem2reg: a slot whose address reaches a call stays in memory" {
    const gpa = testing.allocator;
    var b: Build = .{ .gpa = gpa };
    const args = try gpa.alloc(Ir.Operand, 1);
    args[0] = .{ .value = 1 };
    try b.block(&.{}, &.{
        iconst(0, 5),                                                                                                                      sa(1, 0), sto(1, 0),
        .{ .result = none, .op = .{ .call = .{ .callee = .{ .kind = .user_fn, .name = "f" }, .args = args, .ret_slot = Ir.none_slot } } }, ld(2, 1),
    }, .{ .ret = .{ .value = 2 } });
    var func = try b.finish(&.{Ir.Type.int}, &.{}, &ints(3));
    func.exit = 0;
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try testing.expect(!try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 2), countMemOps(&func));
}

test "mem2reg: a reference slot becomes a value of its reference type; a mistyped store keeps a slot" {
    const gpa = testing.allocator;
    var b: Build = .{ .gpa = gpa };
    // s0: rawptr param, overwritten on one arm; s1: rawptr fed an int, never promoted.
    // b0: cond_br %c, b1, b2    b1: s0 = %p2; br b2    b2: ret load s0 (as rawptr)
    try b.block(&.{}, &.{ .{ .result = 0, .op = .{ .bconst = true } }, sa(5, 1), iconst(6, 0), sto(5, 6), ld(7, 5) }, .{ .cond_br = .{ .cond = 0, .t = 1, .f = 2 } });
    try b.block(&.{}, &.{ .{ .result = 1, .op = .{ .fn_addr = .{ .kind = .user_fn, .name = "g" } } }, sa(2, 0), sto(2, 1) }, .{ .br = .{ .dest = 2, .args = &.{} } });
    try b.block(&.{}, &.{ sa(3, 0), .{ .result = 4, .op = .{ .load = .{ .addr = 3, .ty = Ir.Type.rawptr } } } }, .{ .ret = .{ .value = 4 } });
    var types = ints(8);
    types[0] = Ir.Type.bool;
    types[1] = Ir.Type.rawptr;
    types[4] = Ir.Type.rawptr;
    types[7] = Ir.Type.rawptr;
    var func = try b.finish(&.{ Ir.Type.rawptr, Ir.Type.rawptr }, &.{0}, &types);
    func.exit = 2;
    defer func.deinit(gpa);

    var st: Opt.Stats = .{};
    try testing.expect(try run(gpa, &func, &st));
    try testing.expectEqual(@as(usize, 1), st.slots_promoted);
    const join = func.blocks[func.exit];
    try testing.expectEqual(@as(usize, 1), join.params.len);
    try testing.expect(func.values[join.params[0]].type.eql(Ir.Type.rawptr));
    try testing.expectEqual(join.params[0], join.term.ret.value);
    // The param's value on the edge that never stores it is its incoming value, read
    // once at the top of the entry.
    const entry = func.blocks[0];
    try testing.expect(entry.instrs[0].op == .slot_addr and entry.instrs[0].op.slot_addr == 0);
    try testing.expectEqual(entry.instrs[1].result, func.blocks[entry.term.cond_br.f].term.br.args[0].value);
    try testing.expectEqual(@as(Ir.ValueId, 1), func.blocks[entry.term.cond_br.t].term.br.args[0].value);
    // s1 keeps its store and load.
    try testing.expectEqual(@as(usize, 3), countMemOps(&func));
}
