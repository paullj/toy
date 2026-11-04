//! Linear scan register allocation with live-range splitting (Wimmer and Franz, "Linear
//! Scan Register Allocation on SSA Form", over the interval machinery of Wimmer and
//! Mössenböck, "Optimized Interval Splitting in a Linear Scan Register Allocator").
//!
//! STAGES. `Liveness` numbers the code and finds what is live into and out of each block.
//! `buildIntervals` turns that into one interval per virtual register (with lifetime holes)
//! and a fixed interval per physical register an instruction pins: argument and result
//! registers, and every register a call clobbers. `allocate` walks the intervals by start,
//! giving each a register that is free for as long as possible, and when none is free for
//! its whole life, splits it: the piece that gets no register lives in the register's
//! spill slot until just before its next use. Split positions prefer block boundaries
//! outside loops, so reloads and stores land on loop entries and exits rather than in
//! loop bodies. `assignSlots` gives every spilled register a slot, sharing slots between
//! registers whose lives do not overlap. `rewrite` replaces every virtual register by its
//! location's register, puts moves where a register's pieces meet inside a block, and
//! resolves the edges: where a value's location at the end of a predecessor differs from
//! its location at the start of a successor, a parallel move (`Moves`) goes on the edge,
//! in the predecessor before its jump, at the head of a successor with one predecessor,
//! or in a new block that splits a critical edge.
//!
//! The values the selector's block-argument moves copy are ordinary intervals here, and
//! a hint asks for the copy's source register, so most such moves vanish. A copy's source
//! allocated after its destination (a loop's next value, copied into the loop param)
//! asks for the destination's register instead.
//!
//! SAFEPOINTS. The collector reads roots only from stack slots, so a GC reference must be
//! in its slot across every call that may collect: such a call clobbers every register
//! for a reference. The allocator caps a reference's register at the next safepoint it
//! is live across, which splits it there, and the piece that crosses lives in its slot.
//! `Result.maps` lists, per safepoint in code order, the slots that hold a live reference
//! there: the precise stack map. A call that never collects keeps references in callee-
//! saved registers like any other value.
//!
//! The allocator is target-independent. `Target` provides `Inst` (as `Mir.Function` asks,
//! plus `branchTarget`, `setBranchTarget` and `copyRegs`), `allocatable(class)` in order
//! of preference, `callee_saved`, `moveScratch(class)` (a register nothing else uses), and
//! `move`, `jump`, `spillLoad` and `spillStore` to build the code it adds.

const std = @import("std");
const Mir = @import("Mir.zig");
const Interval = @import("Interval.zig");
const Liveness = @import("Liveness.zig").Liveness;
const Moves = @import("Moves.zig");
const FrameLayout = @import("../frame/FrameLayout.zig");

/// A stack-map entry: a spill slot that holds a live reference at a safepoint.
pub const Root = struct { spill: u32 };

pub const Result = struct {
    /// One per safepoint call, in code order.
    maps: [][]Root,

    pub fn deinit(r: *Result, gpa: std.mem.Allocator) void {
        for (r.maps) |m| gpa.free(m);
        gpa.free(r.maps);
        r.* = undefined;
    }
};

/// `Unallocatable`: an instruction needs more registers at once than the target has.
pub const Error = error{ OutOfMemory, Unallocatable };

const none = std.math.maxInt(u32);

fn evenFloor(pos: u32) u32 {
    return pos & ~@as(u32, 1);
}

fn evenCeil(pos: u32) u32 {
    return (pos + 1) & ~@as(u32, 1);
}

pub fn LinearScan(comptime Target: type) type {
    return struct {
        const Inst = Target.Inst;
        const Func = Mir.Function(Inst);
        const Live = Liveness(Inst);

        /// Where a piece of a register lives.
        const Loc = Moves.Loc;

        pub fn run(gpa: std.mem.Allocator, func: *Func, frame: *Mir.Frame) Error!Result {
            var a: A = .{ .gpa = gpa, .func = func, .frame = frame, .live = try Live.compute(gpa, func) };
            defer a.deinit();
            try a.buildIntervals();
            try a.findHints();
            try a.allocate();
            try a.assignSlots();
            const maps = try a.stackMaps();
            errdefer {
                for (maps) |m| gpa.free(m);
                gpa.free(maps);
            }
            try a.rewrite();
            for (a.intervals.items) |it| {
                if (it.reg) |r| if (Mir.regBit(r) & Target.callee_saved != 0) {
                    frame.saved |= Mir.regBit(r);
                };
            }
            return .{ .maps = maps };
        }

        const A = struct {
            gpa: std.mem.Allocator,
            func: *Func,
            frame: *Mir.Frame,
            live: Live,
            /// Every piece. Piece `v` is the first piece of virtual register `v`.
            intervals: std.ArrayList(Interval) = .empty,
            /// Per virtual register, its pieces in position order.
            pieces: []std.ArrayList(u32) = &.{},
            /// Per physical register, where instructions pin it.
            fixed: [64]Interval = @splat(.{ .vreg = Interval.fixed }),
            safepoints: std.ArrayList(u32) = .empty,
            /// Per virtual register: a physical register a copy pairs it with, the
            /// register a copy reads it from and the copy's position, or the register a
            /// copy writes it to and the position after the copy.
            hint_phys: []?Mir.Reg = &.{},
            hint_vreg: []CopyHint = &.{},
            hint_dst: []CopyHint = &.{},
            /// Pieces not yet allocated, by start descending, so the next is last.
            unhandled: std.ArrayList(u32) = .empty,
            active: std.ArrayList(u32) = .empty,
            inactive: std.ArrayList(u32) = .empty,
            slot_of: []u32 = &.{},

            fn deinit(a: *A) void {
                const gpa = a.gpa;
                a.live.deinit(gpa);
                for (a.intervals.items) |*it| it.deinit(gpa);
                a.intervals.deinit(gpa);
                for (a.pieces) |*p| p.deinit(gpa);
                gpa.free(a.pieces);
                for (&a.fixed) |*it| it.deinit(gpa);
                a.safepoints.deinit(gpa);
                gpa.free(a.hint_phys);
                gpa.free(a.hint_vreg);
                gpa.free(a.hint_dst);
                a.unhandled.deinit(gpa);
                a.active.deinit(gpa);
                a.inactive.deinit(gpa);
                gpa.free(a.slot_of);
            }

            fn tracked(r: Mir.Reg) bool {
                for (Target.allocatable(r.physClass())) |x| if (x == r) return true;
                return false;
            }

            fn classOf(a: *const A, it: *const Interval) Mir.RegClass {
                return a.func.vregs.items[it.vreg].class;
            }

            fn isRef(a: *const A, it: *const Interval) bool {
                return a.func.vregs.items[it.vreg].ref;
            }

            fn buildIntervals(a: *A) Error!void {
                const gpa = a.gpa;
                const f = a.func;
                const nv = f.vregs.items.len;
                try a.intervals.ensureTotalCapacity(gpa, nv);
                for (0..nv) |v| a.intervals.appendAssumeCapacity(.{ .vreg = @intCast(v) });
                a.pieces = try gpa.alloc(std.ArrayList(u32), nv);
                for (a.pieces) |*p| p.* = .empty;

                var live = try std.DynamicBitSetUnmanaged.initEmpty(gpa, nv);
                defer live.deinit(gpa);
                // What the walk set in `live`, so the next block clears only that.
                var touched: std.ArrayList(u32) = .empty;
                defer touched.deinit(gpa);
                var bi = f.blocks.len;
                while (bi > 0) {
                    bi -= 1;
                    const from = a.live.from[bi];
                    for (touched.items) |v| live.unset(v);
                    touched.clearRetainingCapacity();
                    for (a.live.live_out[bi]) |v| {
                        live.set(v);
                        try touched.append(gpa, v);
                        try a.intervals.items[v].addRangeBackward(gpa, from, a.live.to[bi]);
                    }
                    var phys_live: Mir.RegSet = 0;
                    const insts = f.blocks[bi].insts.items;
                    var k = insts.len;
                    while (k > 0) {
                        k -= 1;
                        const p = a.live.instPos(bi, k);
                        var buf: [Mir.max_operands]Mir.Operand = undefined;
                        const ops = insts[k].operands(&buf);
                        const call = insts[k].callRegs();
                        for (ops) |o| if (o.kind == .def) {
                            const r = o.reg.*;
                            if (r.isVirtual()) {
                                const iv = &a.intervals.items[r.index()];
                                try iv.defBackward(gpa, p + 1, live.isSet(r.index()));
                                try iv.addUseBackward(gpa, p + 1);
                                live.unset(r.index());
                            } else try a.fixedDef(r, p + 1, &phys_live);
                        };
                        if (call) |c| {
                            var set = (c.defs | c.clobbers);
                            while (set != 0) : (set &= set - 1) try a.fixedDef(@enumFromInt(@ctz(set)), p + 1, &phys_live);
                            var uses = c.uses;
                            while (uses != 0) : (uses &= uses - 1) try a.fixedUse(@enumFromInt(@ctz(uses)), from, p, &phys_live);
                            if (c.safepoint) try a.safepoints.append(gpa, p);
                        }
                        for (ops) |o| if (o.kind != .def) {
                            const r = o.reg.*;
                            if (r.isVirtual()) {
                                const iv = &a.intervals.items[r.index()];
                                try iv.addRangeBackward(gpa, from, p + 1);
                                if (o.kind == .use) try iv.addUseBackward(gpa, p);
                                live.set(r.index());
                                try touched.append(gpa, r.index());
                            } else try a.fixedUse(r, from, p, &phys_live);
                        };
                    }
                    // Only the prologue block reads a register it did not write: the
                    // incoming arguments, whose fixed intervals reach back to position 0.
                    if (bi != 0 and phys_live != 0) return error.Unallocatable;
                }
                std.mem.reverse(u32, a.safepoints.items);
                for (a.intervals.items, 0..) |*it, v| {
                    it.finish();
                    if (!it.isEmpty()) try a.pieces[v].append(gpa, @intCast(v));
                }
                for (&a.fixed) |*it| it.finish();
            }

            fn fixedDef(a: *A, r: Mir.Reg, pos: u32, phys_live: *Mir.RegSet) Error!void {
                if (!tracked(r)) return;
                try a.fixed[@intFromEnum(r)].defBackward(a.gpa, pos, phys_live.* & Mir.regBit(r) != 0);
                phys_live.* &= ~Mir.regBit(r);
            }

            fn fixedUse(a: *A, r: Mir.Reg, from: u32, pos: u32, phys_live: *Mir.RegSet) Error!void {
                if (!tracked(r)) return;
                try a.fixed[@intFromEnum(r)].addRangeBackward(a.gpa, from, pos + 1);
                phys_live.* |= Mir.regBit(r);
            }

            fn findHints(a: *A) Error!void {
                const nv = a.func.vregs.items.len;
                a.hint_phys = try a.gpa.alloc(?Mir.Reg, nv);
                @memset(a.hint_phys, null);
                a.hint_vreg = try a.gpa.alloc(CopyHint, nv);
                @memset(a.hint_vreg, .{ .v = none, .pos = 0 });
                a.hint_dst = try a.gpa.alloc(CopyHint, nv);
                @memset(a.hint_dst, .{ .v = none, .pos = 0 });
                for (a.func.blocks, 0..) |*b, bi| for (b.insts.items, 0..) |inst, k| {
                    const c = inst.copyRegs() orelse continue;
                    if (a.func.classOf(c.dst) != a.func.classOf(c.src)) continue;
                    if (c.dst.isVirtual() and c.src.isVirtual()) {
                        a.hint_vreg[c.dst.index()] = .{ .v = c.src.index(), .pos = a.live.instPos(bi, k) };
                        a.hint_dst[c.src.index()] = .{ .v = c.dst.index(), .pos = a.live.instPos(bi, k) + 1 };
                    } else if (c.dst.isVirtual() and tracked(c.src)) {
                        if (a.hint_phys[c.dst.index()] == null) a.hint_phys[c.dst.index()] = c.src;
                    } else if (c.src.isVirtual() and tracked(c.dst)) {
                        if (a.hint_phys[c.src.index()] == null) a.hint_phys[c.src.index()] = c.dst;
                    }
                };
            }

            fn pushUnhandled(a: *A, idx: u32) Error!void {
                const s = a.intervals.items[idx].start();
                const list = &a.unhandled;
                // Descending by (start, index), so equal starts pop in index order.
                var lo: usize = 0;
                var hi: usize = list.items.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const m = &a.intervals.items[list.items[mid]];
                    if (m.start() > s or (m.start() == s and list.items[mid] > idx)) lo = mid + 1 else hi = mid;
                }
                try list.insert(a.gpa, lo, idx);
            }

            /// Split piece `idx` at `pos`, keeping the vreg's piece list in order; returns
            /// the new piece.
            fn splitAt(a: *A, idx: u32, pos: u32) Error!u32 {
                const child = try a.intervals.items[idx].split(a.gpa, pos);
                const ci: u32 = @intCast(a.intervals.items.len);
                try a.intervals.append(a.gpa, child);
                const list = &a.pieces[child.vreg];
                const at = std.mem.indexOfScalar(u32, list.items, idx).? + 1;
                try list.insert(a.gpa, at, ci);
                return ci;
            }

            /// The first safepoint a reference piece is live across, if it starts before it.
            fn safepointCrossed(a: *const A, it: *const Interval) ?u32 {
                if (!a.isRef(it)) return null;
                const sp = a.safepoints.items;
                var lo: usize = 0;
                var hi: usize = sp.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (sp[mid] < it.start()) lo = mid + 1 else hi = mid;
                }
                for (sp[lo..]) |s| {
                    if (s >= it.end()) return null;
                    if (it.covers(s) and it.covers(s + 1)) return s;
                }
                return null;
            }

            /// The position in `(lo, hi]` to split at: a block label (whose moves go on its
            /// edges) or an instruction no later than its block's `last_split`, at the
            /// smallest loop depth, and the latest such.
            fn splitPos(a: *const A, lo: u32, hi: u32) ?u32 {
                const l = &a.live;
                var best: ?u32 = null;
                var best_depth: u32 = none;
                const consider = struct {
                    fn f(b: *?u32, bd: *u32, pos: u32, depth: u32) void {
                        if (depth < bd.* or (depth == bd.* and pos > b.*.?)) {
                            b.* = pos;
                            bd.* = depth;
                        }
                    }
                }.f;
                var p = evenFloor(hi);
                if (p > lo) {
                    const b = l.blockOf(p);
                    if (p != l.from[b] and p > l.last_split[b]) p = l.last_split[b];
                    if (p > lo) {
                        best = p;
                        best_depth = if (p == l.from[b]) labelDepth(l, b) else l.depth[b];
                    }
                }
                var b = l.blockOf(hi);
                while (l.from[b] > lo) : (b -= 1) {
                    if (l.from[b] <= hi) consider(&best, &best_depth, l.from[b], labelDepth(l, b));
                    if (b == 0) break;
                }
                return best;
            }

            /// A label's moves run on its incoming edges, so splitting at a loop header
            /// costs what its entry edge does.
            fn labelDepth(l: *const Live, b: u32) u32 {
                return if (b == 0) l.depth[0] else @min(l.depth[b], l.depth[b - 1]);
            }

            fn allocate(a: *A) Error!void {
                // Sorted once, not inserted one by one: each insert shifts the list.
                for (a.pieces) |p| if (p.items.len != 0) try a.unhandled.append(a.gpa, p.items[0]);
                std.mem.sort(u32, a.unhandled.items, a, struct {
                    fn later(c: *A, x: u32, y: u32) bool {
                        const sx = c.intervals.items[x].start();
                        const sy = c.intervals.items[y].start();
                        return sx > sy or (sx == sy and x > y);
                    }
                }.later);
                while (a.unhandled.pop()) |ci| {
                    const pos = a.intervals.items[ci].start();
                    var i: usize = 0;
                    while (i < a.active.items.len) {
                        const it = &a.intervals.items[a.active.items[i]];
                        if (it.end() <= pos) {
                            _ = a.active.swapRemove(i);
                        } else if (!it.covers(pos)) {
                            try a.inactive.append(a.gpa, a.active.swapRemove(i));
                        } else i += 1;
                    }
                    i = 0;
                    while (i < a.inactive.items.len) {
                        const it = &a.intervals.items[a.inactive.items[i]];
                        if (it.end() <= pos) {
                            _ = a.inactive.swapRemove(i);
                        } else if (it.covers(pos)) {
                            try a.active.append(a.gpa, a.inactive.swapRemove(i));
                        } else i += 1;
                    }

                    const cur = &a.intervals.items[ci];
                    if (a.safepointCrossed(cur)) |s| {
                        if (cur.useIn(cur.start(), s) == null) {
                            try a.spillAcross(ci, s);
                            continue;
                        }
                    }
                    if (!try a.tryAllocateFree(ci)) try a.allocateBlocked(ci);
                    if (a.intervals.items[ci].reg != null) try a.active.append(a.gpa, ci);
                }
            }

            /// A reference piece with no use before the safepoint `s` it crosses lives in
            /// its slot until just before its first use after the call.
            fn spillAcross(a: *A, ci: u32, s: u32) Error!void {
                const cur = &a.intervals.items[ci];
                cur.spilled = true;
                const u = cur.firstUseFrom(s + 1) orelse return;
                const pos = a.splitPos(s + 1, u) orelse return error.Unallocatable;
                try a.pushUnhandled(try a.splitAt(ci, pos));
            }

            fn hintFor(a: *const A, it: *const Interval) ?Mir.Reg {
                if (a.hint_phys[it.vreg]) |r| return r;
                for ([_]CopyHint{ a.hint_vreg[it.vreg], a.hint_dst[it.vreg] }) |h| {
                    if (h.v == none) continue;
                    const loc = a.locAt(h.v, h.pos) orelse continue;
                    if (loc == .reg) return loc.reg;
                }
                return null;
            }

            fn tryAllocateFree(a: *A, ci: u32) Error!bool {
                const cur = &a.intervals.items[ci];
                const class = a.classOf(cur);
                const regs = Target.allocatable(class);
                var free: [64]u32 = @splat(0);
                for (regs) |r| free[@intFromEnum(r)] = none;
                for (a.active.items) |ai| {
                    const it = &a.intervals.items[ai];
                    free[@intFromEnum(it.reg.?)] = 0;
                }
                for (a.inactive.items) |ai| {
                    const it = &a.intervals.items[ai];
                    if (it.nextIntersection(cur, cur.start())) |x| {
                        const r = @intFromEnum(it.reg.?);
                        free[r] = @min(free[r], x);
                    }
                }
                for (regs) |r| {
                    if (a.fixed[@intFromEnum(r)].nextIntersection(cur, cur.start())) |x|
                        free[@intFromEnum(r)] = @min(free[@intFromEnum(r)], x);
                }
                if (a.safepointCrossed(cur)) |s| for (regs) |r| {
                    free[@intFromEnum(r)] = @min(free[@intFromEnum(r)], s);
                };

                const end = cur.end();
                var reg: Mir.Reg = regs[0];
                if (a.hintFor(cur)) |h| if (h.physClass() == class and free[@intFromEnum(h)] >= end) {
                    reg = h;
                    cur.reg = reg;
                    return true;
                };
                const whole = for (regs) |r| {
                    if (free[@intFromEnum(r)] >= end) break r;
                } else null;
                if (whole) |r| {
                    cur.reg = r;
                    return true;
                }
                for (regs) |r| if (free[@intFromEnum(r)] > free[@intFromEnum(reg)]) {
                    reg = r;
                };
                const until = free[@intFromEnum(reg)];
                if (until <= cur.start()) return false;
                const pos = a.splitPos(cur.start(), until) orelse return false;
                cur.reg = reg;
                try a.pushUnhandled(try a.splitAt(ci, pos));
                return true;
            }

            fn allocateBlocked(a: *A, ci: u32) Error!void {
                const cur = &a.intervals.items[ci];
                const class = a.classOf(cur);
                const regs = Target.allocatable(class);
                const from = evenFloor(cur.start());
                var use_pos: [64]u32 = @splat(0);
                var block_pos: [64]u32 = @splat(0);
                for (regs) |r| {
                    use_pos[@intFromEnum(r)] = none;
                    block_pos[@intFromEnum(r)] = none;
                }
                for (a.active.items) |ai| {
                    const it = &a.intervals.items[ai];
                    const r = @intFromEnum(it.reg.?);
                    use_pos[r] = @min(use_pos[r], it.firstUseFrom(from) orelse none);
                }
                for (a.inactive.items) |ai| {
                    const it = &a.intervals.items[ai];
                    if (it.nextIntersection(cur, cur.start()) == null) continue;
                    const r = @intFromEnum(it.reg.?);
                    use_pos[r] = @min(use_pos[r], it.firstUseFrom(from) orelse none);
                }
                for (regs) |r| {
                    const n = @intFromEnum(r);
                    if (a.fixed[n].nextIntersection(cur, cur.start())) |x| {
                        block_pos[n] = @min(block_pos[n], x);
                        use_pos[n] = @min(use_pos[n], x);
                    }
                }
                if (a.safepointCrossed(cur)) |s| for (regs) |r| {
                    const n = @intFromEnum(r);
                    block_pos[n] = @min(block_pos[n], s);
                    use_pos[n] = @min(use_pos[n], s);
                };
                var reg = regs[0];
                for (regs) |r| if (use_pos[@intFromEnum(r)] > use_pos[@intFromEnum(reg)]) {
                    reg = r;
                };
                const n = @intFromEnum(reg);

                const first_use = cur.firstUseFrom(cur.start()) orelse {
                    cur.spilled = true;
                    return;
                };
                if (first_use >= use_pos[n]) {
                    // Every register is wanted sooner than this piece needs one.
                    const pos = a.splitPos(cur.start(), first_use) orelse return error.Unallocatable;
                    cur.spilled = true;
                    try a.pushUnhandled(try a.splitAt(ci, pos));
                    return;
                }
                if (block_pos[n] <= cur.start()) return error.Unallocatable;
                cur.reg = reg;
                if (block_pos[n] < cur.end()) {
                    const pos = a.splitPos(cur.start(), block_pos[n]) orelse return error.Unallocatable;
                    try a.pushUnhandled(try a.splitAt(ci, pos));
                }
                const start = a.intervals.items[ci].start();
                var i: usize = 0;
                while (i < a.active.items.len) {
                    const ai = a.active.items[i];
                    if (a.intervals.items[ai].reg != reg) {
                        i += 1;
                        continue;
                    }
                    _ = a.active.swapRemove(i);
                    try a.evict(ai, evenFloor(start));
                }
                i = 0;
                while (i < a.inactive.items.len) {
                    const ai = a.inactive.items[i];
                    const it = &a.intervals.items[ai];
                    if (it.reg != reg or it.nextIntersection(&a.intervals.items[ci], start) == null) {
                        i += 1;
                        continue;
                    }
                    _ = a.inactive.swapRemove(i);
                    try a.evict(ai, evenCeil(start));
                }
            }

            /// Take piece `idx` out of its register from `at` on: the part from `at` lives
            /// in the slot until just before its next use, and from there waits to be
            /// allocated again.
            fn evict(a: *A, idx: u32, at_in: u32) Error!void {
                var tail = idx;
                const victim = &a.intervals.items[idx];
                if (at_in > victim.start()) {
                    if (at_in >= victim.end()) return;
                    // Leave the register as early as its last use before `at_in` allows,
                    // so a value a loop does not read is stored before the loop, not in it.
                    const before = victim.useFrom(at_in);
                    const last = if (before > 0) victim.uses.items[before - 1] else victim.start();
                    const at = a.splitPos(last, at_in) orelse at_in;
                    tail = try a.splitAt(idx, at);
                } else victim.reg = null;
                const it = &a.intervals.items[tail];
                const u = it.firstUseFrom(it.start()) orelse {
                    it.spilled = true;
                    return;
                };
                if (u <= it.start() + 1) {
                    // Needed in a register as soon as it begins: allocate it afresh.
                    try a.pushUnhandled(tail);
                    return;
                }
                const pos = a.splitPos(it.start(), u) orelse return error.Unallocatable;
                it.spilled = true;
                try a.pushUnhandled(try a.splitAt(tail, pos));
            }

            /// The piece of `v` that covers `pos`, if `v` is live there.
            fn pieceAt(a: *const A, v: u32, pos: u32) ?u32 {
                const ps = a.pieces[v].items;
                // The pieces are disjoint and in order: the last one starting at or
                // before `pos` is the only one that may cover it.
                const k = std.sort.upperBound(u32, ps, PosCtx{ .a = a, .pos = pos }, PosCtx.order);
                if (k == 0) return null;
                return if (a.intervals.items[ps[k - 1]].covers(pos)) ps[k - 1] else null;
            }

            const PosCtx = struct {
                a: *const A,
                pos: u32,
                fn order(c: PosCtx, pi: u32) std.math.Order {
                    return std.math.order(c.pos, c.a.intervals.items[pi].start());
                }
            };

            fn locOf(a: *const A, pi: u32) Loc {
                const it = &a.intervals.items[pi];
                if (it.spilled) return .{ .slot = a.slot_of[it.vreg] };
                return .{ .reg = it.reg.? };
            }

            fn locAt(a: *const A, v: u32, pos: u32) ?Loc {
                const pi = a.pieceAt(v, pos) orelse return null;
                const it = &a.intervals.items[pi];
                if (it.spilled) return if (a.slot_of.len != 0) .{ .slot = a.slot_of[it.vreg] } else null;
                return if (it.reg) |r| .{ .reg = r } else null;
            }

            /// One slot per spilled register, shared by registers whose lives (from their
            /// first piece's start to their last piece's end) do not overlap.
            fn assignSlots(a: *A) Error!void {
                const gpa = a.gpa;
                const nv = a.func.vregs.items.len;
                a.slot_of = try gpa.alloc(u32, nv);
                @memset(a.slot_of, none);
                const Span = struct { v: u32, from: u32, to: u32 };
                var spans: std.ArrayList(Span) = .empty;
                defer spans.deinit(gpa);
                for (a.pieces, 0..) |p, v| {
                    if (p.items.len == 0) continue;
                    const any = for (p.items) |pi| {
                        if (a.intervals.items[pi].spilled) break true;
                    } else false;
                    if (!any) continue;
                    try spans.append(gpa, .{
                        .v = @intCast(v),
                        .from = a.intervals.items[p.items[0]].start(),
                        .to = a.intervals.items[p.items[p.items.len - 1]].end(),
                    });
                }
                std.mem.sort(Span, spans.items, {}, struct {
                    fn less(_: void, x: Span, y: Span) bool {
                        return x.from < y.from or (x.from == y.from and x.v < y.v);
                    }
                }.less);
                // Per slot, the position its last tenant's life ends.
                var busy_until: std.ArrayList(u32) = .empty;
                defer busy_until.deinit(gpa);
                for (spans.items) |s| {
                    const reuse = for (busy_until.items, 0..) |u, k| {
                        if (u <= s.from) break k;
                    } else null;
                    const slot: u32 = if (reuse) |k| @intCast(k) else blk: {
                        const ref = a.frame.newSpill();
                        try busy_until.append(gpa, 0);
                        break :blk ref.spill;
                    };
                    busy_until.items[slot] = s.to;
                    a.slot_of[s.v] = slot;
                }
            }

            /// Per safepoint, the slots of the references live across it. Each must be in
            /// its slot there; anything else is an allocator bug.
            fn stackMaps(a: *A) Error![][]Root {
                const gpa = a.gpa;
                const sp = a.safepoints.items;
                var lists = try gpa.alloc(std.ArrayList(Root), sp.len);
                defer gpa.free(lists);
                for (lists) |*l| l.* = .empty;
                defer for (lists) |*l| l.deinit(gpa);
                for (a.intervals.items) |*it| {
                    if (it.isEmpty() or !a.isRef(it)) continue;
                    var k = std.sort.lowerBound(u32, sp, it.start(), struct {
                        fn order(key: u32, x: u32) std.math.Order {
                            return std.math.order(key, x);
                        }
                    }.order);
                    while (k < sp.len) : (k += 1) {
                        const s = sp[k];
                        if (s >= it.end()) break;
                        if (!(it.covers(s) and it.covers(s + 1))) continue;
                        if (!it.spilled) return error.Unallocatable;
                        try lists[k].append(gpa, .{ .spill = a.slot_of[it.vreg] });
                    }
                }
                const maps = try gpa.alloc([]Root, sp.len);
                var done: usize = 0;
                errdefer {
                    for (maps[0..done]) |m| gpa.free(m);
                    gpa.free(maps);
                }
                for (lists, maps) |*l, *m| {
                    std.mem.sort(Root, l.items, {}, struct {
                        fn less(_: void, x: Root, y: Root) bool {
                            return x.spill < y.spill;
                        }
                    }.less);
                    m.* = try l.toOwnedSlice(gpa);
                    done += 1;
                }
                return maps;
            }

            fn emitMoves(a: *A, out: *std.ArrayList(Inst), moves: *std.ArrayList(Moves.Move), line: u32) Error!void {
                if (moves.items.len == 0) return;
                var seq: std.ArrayList(Moves.Move) = .empty;
                defer seq.deinit(a.gpa);
                try Moves.sequence(a.gpa, moves, &Target.moveScratch, &seq);
                for (seq.items) |m| try out.append(a.gpa, switch (m.dst) {
                    .reg => |d| switch (m.src) {
                        .reg => |s| Target.move(d, s, line),
                        .slot => |s| Target.spillLoad(d, .{ .spill = s }, line),
                    },
                    .slot => |d| Target.spillStore(m.src.reg, .{ .spill = d }, line),
                });
                moves.clearRetainingCapacity();
            }

            /// The moves an edge needs: every value live into `succ` whose location at the
            /// end of `pred` differs.
            fn edgeMoves(a: *A, pred: usize, succ: usize, moves: *std.ArrayList(Moves.Move)) Error!void {
                for (a.live.live_in[succ]) |v| {
                    const src = a.locOf(a.pieceAt(@intCast(v), a.live.to[pred] - 1).?);
                    const dst = a.locOf(a.pieceAt(@intCast(v), a.live.from[succ]).?);
                    if (!src.eql(dst)) try moves.append(a.gpa, .{ .dst = dst, .src = src, .class = a.func.vregs.items[v].class });
                }
            }

            fn rewrite(a: *A) Error!void {
                const gpa = a.gpa;
                const f = a.func;
                const n = f.blocks.len;

                // In-line moves where a piece that starts at an instruction is live into it.
                const Inline = struct { pos: u32, move: Moves.Move };
                var inline_moves: std.ArrayList(Inline) = .empty;
                defer inline_moves.deinit(gpa);
                for (a.pieces, 0..) |p, v| {
                    if (p.items.len < 2) continue;
                    for (p.items[1..], p.items[0 .. p.items.len - 1]) |pi, prev| {
                        // A piece that starts at a def (odd) or a label takes no value
                        // in-line: the def writes it, the edges bring it.
                        const s = a.intervals.items[pi].start();
                        if (s % 2 != 0 or a.live.isLabel(s)) continue;
                        const src = a.locOf(prev);
                        const dst = a.locOf(pi);
                        if (src.eql(dst)) continue;
                        try inline_moves.append(gpa, .{ .pos = s, .move = .{ .dst = dst, .src = src, .class = f.vregs.items[v].class } });
                    }
                }
                std.mem.sort(Inline, inline_moves.items, {}, struct {
                    fn less(_: void, x: Inline, y: Inline) bool {
                        return x.pos < y.pos;
                    }
                }.less);

                // Edge moves: per block, those before its final jump and those at its head.
                const tail_moves = try gpa.alloc(std.ArrayList(Moves.Move), n);
                const head_moves = try gpa.alloc(std.ArrayList(Moves.Move), n);
                for (tail_moves, head_moves) |*t, *h| {
                    t.* = .empty;
                    h.* = .empty;
                }
                defer {
                    for (tail_moves, head_moves) |*t, *h| {
                        t.deinit(gpa);
                        h.deinit(gpa);
                    }
                    gpa.free(tail_moves);
                    gpa.free(head_moves);
                }
                const EdgeBlock = struct {
                    pred: u32,
                    /// The branch, by its index before and after the rewrite.
                    inst: usize,
                    new_inst: usize = 0,
                    succ: u32,
                    moves: std.ArrayList(Moves.Move),
                };
                var edge_blocks: std.ArrayList(EdgeBlock) = .empty;
                defer {
                    for (edge_blocks.items) |*e| e.moves.deinit(gpa);
                    edge_blocks.deinit(gpa);
                }
                for (0..n) |bi| {
                    const insts = f.blocks[bi].insts.items;
                    const succs = a.live.succs[bi];
                    for (succs, 0..) |s, e| {
                        const inst_k = insts.len - succs.len + e;
                        var moves: std.ArrayList(Moves.Move) = .empty;
                        errdefer moves.deinit(gpa);
                        try a.edgeMoves(bi, s, &moves);
                        if (moves.items.len == 0) {
                            moves.deinit(gpa);
                            continue;
                        }
                        if (inst_k == insts.len - 1) {
                            std.debug.assert(tail_moves[bi].items.len == 0);
                            tail_moves[bi] = moves;
                        } else if (a.live.preds[s].len == 1) {
                            std.debug.assert(head_moves[s].items.len == 0);
                            head_moves[s] = moves;
                        } else try edge_blocks.append(gpa, .{ .pred = @intCast(bi), .inst = inst_k, .succ = s, .moves = moves });
                    }
                }

                var next_edge: usize = 0;
                var next_inline: usize = 0;
                var pending: std.ArrayList(Moves.Move) = .empty;
                defer pending.deinit(gpa);
                for (f.blocks, 0..) |*blk, bi| {
                    var out: std.ArrayList(Inst) = .empty;
                    errdefer out.deinit(gpa);
                    const insts = blk.insts.items;
                    const head_line = if (insts.len > 0) insts[0].line else @as(u32, 0);
                    try a.emitMoves(&out, &head_moves[bi], head_line);
                    for (insts, 0..) |orig, k| {
                        const p = a.live.instPos(bi, k);
                        while (next_inline < inline_moves.items.len and inline_moves.items[next_inline].pos == p) : (next_inline += 1)
                            try pending.append(gpa, inline_moves.items[next_inline].move);
                        try a.emitMoves(&out, &pending, orig.line);
                        if (k == insts.len - 1) try a.emitMoves(&out, &tail_moves[bi], orig.line);
                        var inst = orig;
                        var buf: [Mir.max_operands]Mir.Operand = undefined;
                        const ops = inst.operands(&buf);
                        if (ops.len > 0 and for (ops) |o| {
                            if (o.kind != .keep) break false;
                        } else true) continue;
                        for (ops) |o| {
                            if (!o.reg.*.isVirtual()) continue;
                            const v = o.reg.*.index();
                            const at = if (o.kind == .use) p else p + 1;
                            const loc = a.locOf(a.pieceAt(v, at) orelse return error.Unallocatable);
                            if (loc != .reg) return error.Unallocatable;
                            o.reg.* = loc.reg;
                        }
                        if (inst.copyRegs()) |c| if (c.dst == c.src) continue;
                        try out.append(gpa, inst);
                        // `edge_blocks` is in (pred, inst) order, as this walk meets them.
                        while (next_edge < edge_blocks.items.len and edge_blocks.items[next_edge].pred == bi and edge_blocks.items[next_edge].inst == k) : (next_edge += 1)
                            edge_blocks.items[next_edge].new_inst = out.items.len - 1;
                    }
                    blk.insts.deinit(gpa);
                    blk.insts = out;
                }
                std.debug.assert(next_inline == inline_moves.items.len);

                if (edge_blocks.items.len == 0) return;
                const grown = try gpa.realloc(f.blocks, n + edge_blocks.items.len);
                f.blocks = grown;
                for (edge_blocks.items, 0..) |*e, k| {
                    const nb: u32 = @intCast(n + k);
                    f.blocks[nb] = .{};
                    const branch = &f.blocks[e.pred].insts.items[e.new_inst];
                    const line = branch.line;
                    branch.setBranchTarget(nb);
                    try a.emitMoves(&f.blocks[nb].insts, &e.moves, line);
                    try f.blocks[nb].insts.append(gpa, Target.jump(e.succ, line));
                }
            }
        };
    };
}

/// A copy's other register, and the position to look its location up at.
const CopyHint = struct { v: u32, pos: u32 };

/// A small target for unit tests: three allocatable registers, one of them callee-saved,
/// so a handful of values already forces splits and spills.
pub const TestTarget = struct {
    pub const Inst = struct {
        op: union(enum) {
            def: Mir.Reg,
            /// rd = imm
            imm: struct { rd: Mir.Reg, imm: u64 },
            use: Mir.Reg,
            keep: Mir.Reg,
            add: struct { rd: Mir.Reg, rn: Mir.Reg, rm: Mir.Reg },
            /// rd = rn - 1
            dec: struct { rd: Mir.Reg, rn: Mir.Reg },
            mov: struct { rd: Mir.Reg, rn: Mir.Reg },
            ld: struct { rt: Mir.Reg, ref: Mir.FrameRef },
            st: struct { rt: Mir.Reg, ref: Mir.FrameRef },
            call: struct { uses: Mir.RegSet = 0, defs: Mir.RegSet = 0, safepoint: bool = true },
            b: u32,
            cbnz: struct { rn: Mir.Reg, target: u32 },
            ret,
        },
        line: u32 = 0,

        pub fn callRegs(i: Inst) ?Mir.CallRegs {
            return switch (i.op) {
                .call => |c| .{ .uses = c.uses, .defs = c.defs, .clobbers = caller_saved, .safepoint = c.safepoint },
                else => null,
            };
        }
        pub fn branchTarget(i: Inst) ?u32 {
            return switch (i.op) {
                .b => |t| t,
                .cbnz => |c| c.target,
                else => null,
            };
        }
        pub fn setBranchTarget(i: *Inst, t: u32) void {
            switch (i.op) {
                .b => |*x| x.* = t,
                .cbnz => |*c| c.target = t,
                else => unreachable,
            }
        }
        pub fn copyRegs(i: Inst) ?struct { dst: Mir.Reg, src: Mir.Reg } {
            return switch (i.op) {
                .mov => |m| .{ .dst = m.rd, .src = m.rn },
                else => null,
            };
        }
        pub fn operands(i: *Inst, buf: *[Mir.max_operands]Mir.Operand) []Mir.Operand {
            switch (i.op) {
                .def => |*r| {
                    buf[0] = .{ .reg = r, .kind = .def };
                    return buf[0..1];
                },
                .imm => |*x| {
                    buf[0] = .{ .reg = &x.rd, .kind = .def };
                    return buf[0..1];
                },
                .dec => |*x| {
                    buf[0] = .{ .reg = &x.rn, .kind = .use };
                    buf[1] = .{ .reg = &x.rd, .kind = .def };
                    return buf[0..2];
                },
                .use => |*r| {
                    buf[0] = .{ .reg = r, .kind = .use };
                    return buf[0..1];
                },
                .keep => |*r| {
                    buf[0] = .{ .reg = r, .kind = .keep };
                    return buf[0..1];
                },
                .add => |*x| {
                    buf[0] = .{ .reg = &x.rn, .kind = .use };
                    buf[1] = .{ .reg = &x.rm, .kind = .use };
                    buf[2] = .{ .reg = &x.rd, .kind = .def };
                    return buf[0..3];
                },
                .mov => |*x| {
                    buf[0] = .{ .reg = &x.rn, .kind = .use };
                    buf[1] = .{ .reg = &x.rd, .kind = .def };
                    return buf[0..2];
                },
                .ld => |*x| {
                    buf[0] = .{ .reg = &x.rt, .kind = .def };
                    return buf[0..1];
                },
                .st => |*x| {
                    buf[0] = .{ .reg = &x.rt, .kind = .use };
                    return buf[0..1];
                },
                .cbnz => |*x| {
                    buf[0] = .{ .reg = &x.rn, .kind = .use };
                    return buf[0..1];
                },
                .call, .b, .ret => return buf[0..0],
            }
        }
    };

    pub const caller_saved: Mir.RegSet = Mir.regBit(Mir.Reg.gp(0)) | Mir.regBit(Mir.Reg.gp(1)) | Mir.regBit(Mir.Reg.gp(9));
    pub const callee_saved: Mir.RegSet = Mir.regBit(Mir.Reg.gp(19));
    const gprs = [_]Mir.Reg{ Mir.Reg.gp(0), Mir.Reg.gp(1), Mir.Reg.gp(19) };
    const fprs = [_]Mir.Reg{Mir.Reg.fp(0)};

    pub fn allocatable(class: Mir.RegClass) []const Mir.Reg {
        return switch (class) {
            .gpr => &gprs,
            .fpr => &fprs,
        };
    }
    pub fn moveScratch(class: Mir.RegClass) Mir.Reg {
        return switch (class) {
            .gpr => Mir.Reg.gp(9),
            .fpr => Mir.Reg.fp(16),
        };
    }
    pub fn move(d: Mir.Reg, s: Mir.Reg, line: u32) Inst {
        return .{ .op = .{ .mov = .{ .rd = d, .rn = s } }, .line = line };
    }
    pub fn jump(t: u32, line: u32) Inst {
        return .{ .op = .{ .b = t }, .line = line };
    }
    pub fn spillLoad(r: Mir.Reg, ref: Mir.FrameRef, line: u32) Inst {
        return .{ .op = .{ .ld = .{ .rt = r, .ref = ref } }, .line = line };
    }
    pub fn spillStore(r: Mir.Reg, ref: Mir.FrameRef, line: u32) Inst {
        return .{ .op = .{ .st = .{ .rt = r, .ref = ref } }, .line = line };
    }
};

const testing = std.testing;
const TF = Mir.Function(TestTarget.Inst);
const TI = TestTarget.Inst;

/// Runs MIR of `TestTarget` on concrete values: before allocation over virtual registers,
/// after it over physical registers and spill slots. A call clobbers every caller-saved
/// register with junk and writes 7777 to x0; a safepoint also runs a moving collector,
/// which relocates every reference: in virtual form all reference registers, after
/// allocation only the slots the safepoint's stack map names. So a reference kept in a
/// register across a safepoint, a map that misses a live reference, or one that names a
/// slot holding a non-reference all change what the program prints.
const Machine = struct {
    regs: [64]u64 = @splat(0),
    vregs: []u64,
    slots: [64]u64 = @splat(0),
    trace: std.ArrayList(u64) = .empty,

    const moved: u64 = 1 << 32;

    fn get(m: *Machine, r: Mir.Reg) u64 {
        return if (r.isVirtual()) m.vregs[r.index()] else m.regs[@intFromEnum(r)];
    }
    fn set(m: *Machine, r: Mir.Reg, v: u64) void {
        if (r.isVirtual()) m.vregs[r.index()] = v else m.regs[@intFromEnum(r)] = v;
    }

    fn run(gpa: std.mem.Allocator, f: *TF, maps: ?[][]Root) ![]u64 {
        var m: Machine = .{ .vregs = try gpa.alloc(u64, f.vregs.items.len) };
        defer gpa.free(m.vregs);
        @memset(m.vregs, 0);
        errdefer m.trace.deinit(gpa);
        // The static safepoint index of each call, in code order.
        var sp_index: std.ArrayList(u32) = .empty;
        defer sp_index.deinit(gpa);
        var block: u32 = 0;
        var k: usize = 0;
        var steps: usize = 0;
        while (true) : (steps += 1) {
            if (steps > 100_000) return error.TestRunaway;
            const inst = f.blocks[block].insts.items[k];
            k += 1;
            switch (inst.op) {
                .def => |r| m.set(r, 0),
                .imm => |x| m.set(x.rd, x.imm),
                .use => |r| try m.trace.append(gpa, m.get(r)),
                .keep => {},
                .add => |x| m.set(x.rd, m.get(x.rn) +% m.get(x.rn) +% m.get(x.rm)),
                .dec => |x| m.set(x.rd, m.get(x.rn) -% 1),
                .mov => |x| m.set(x.rd, m.get(x.rn)),
                .ld => |x| m.set(x.rt, m.slots[x.ref.spill]),
                .st => |x| m.slots[x.ref.spill] = m.get(x.rt),
                .call => |c| {
                    var cs = TestTarget.caller_saved;
                    while (cs != 0) : (cs &= cs - 1) m.regs[@ctz(cs)] = 0xBAD;
                    if (c.defs != 0) m.regs[0] = 7777;
                    if (c.safepoint) {
                        if (maps) |ms| {
                            const idx = safepointIndex(f, block, k - 1);
                            for (ms[idx]) |root| m.slots[root.spill] ^= moved;
                        } else for (f.vregs.items, 0..) |vr, v| {
                            if (vr.ref) m.vregs[v] ^= moved;
                        }
                    }
                },
                .b => |t| {
                    block = t;
                    k = 0;
                },
                .cbnz => |x| if (m.get(x.rn) != 0) {
                    block = x.target;
                    k = 0;
                },
                .ret => return m.trace.toOwnedSlice(gpa),
            }
        }
    }

    fn safepointIndex(f: *TF, block: u32, k: usize) usize {
        var n: usize = 0;
        for (f.blocks, 0..) |b, bi| for (b.insts.items, 0..) |i, ki| {
            if (bi == block and ki == k) return n;
            if (i.op == .call and i.op.call.safepoint) n += 1;
        };
        unreachable;
    }
};

/// Random structured programs over a few virtual registers: straight-line code, two-way
/// branches whose arms both define a value read after the join, and counted loops, with
/// calls (safepoints and not) and references among the values.
const Gen = struct {
    gpa: std.mem.Allocator,
    rng: std.Random,
    f: *TF,
    blocks: std.ArrayList(TF.Block) = .empty,
    cur: u32 = 0,
    avail: std.ArrayList(Mir.Reg) = .empty,
    imm: u64 = 1,

    fn newBlock(g: *Gen) !u32 {
        try g.blocks.append(g.gpa, .{});
        return @intCast(g.blocks.items.len - 1);
    }
    fn emit(g: *Gen, op: @FieldType(TI, "op")) !void {
        try g.blocks.items[g.cur].insts.append(g.gpa, .{ .op = op });
    }
    fn fresh(g: *Gen) !Mir.Reg {
        const ref = g.rng.uintLessThan(u8, 3) == 0;
        const r = try g.f.newVReg(g.gpa, .gpr, null);
        g.f.vregs.items[r.index()].ref = ref;
        return r;
    }
    fn pick(g: *Gen) Mir.Reg {
        return g.avail.items[g.rng.uintLessThan(usize, g.avail.items.len)];
    }
    fn defNew(g: *Gen) !Mir.Reg {
        const r = try g.fresh();
        g.imm += 1;
        try g.emit(.{ .imm = .{ .rd = r, .imm = g.imm * 1000 } });
        return r;
    }

    fn chunk(g: *Gen, n: usize) !void {
        for (0..n) |_| switch (g.rng.uintLessThan(u8, 9)) {
            0, 1 => try g.avail.append(g.gpa, try g.defNew()),
            2, 3 => {
                const into = if (g.rng.boolean()) g.pick() else blk: {
                    const r = try g.fresh();
                    try g.avail.append(g.gpa, r);
                    break :blk r;
                };
                try g.emit(.{ .add = .{ .rd = into, .rn = g.pick(), .rm = g.pick() } });
            },
            4 => try g.emit(.{ .use = g.pick() }),
            5 => {
                const r = try g.fresh();
                try g.emit(.{ .mov = .{ .rd = r, .rn = g.pick() } });
                try g.avail.append(g.gpa, r);
            },
            6 => try g.emit(.{ .call = .{ .safepoint = g.rng.boolean() } }),
            7 => {
                // A call result read through x0, as the selector shapes one.
                try g.emit(.{ .call = .{ .defs = Mir.regBit(Mir.Reg.gp(0)) } });
                const r = try g.fresh();
                try g.emit(.{ .mov = .{ .rd = r, .rn = Mir.Reg.gp(0) } });
                try g.avail.append(g.gpa, r);
            },
            else => {
                // An argument passed in x0, then a call that reads it.
                try g.emit(.{ .mov = .{ .rd = Mir.Reg.gp(0), .rn = g.pick() } });
                try g.emit(.{ .call = .{ .uses = Mir.regBit(Mir.Reg.gp(0)) } });
            },
        };
    }

    fn region(g: *Gen, depth: u32) !void {
        try g.chunk(1 + g.rng.uintLessThan(usize, 5));
        if (depth >= 3) return;
        switch (g.rng.uintLessThan(u8, 4)) {
            0 => {
                const then = try g.newBlock();
                const els = try g.newBlock();
                const join = try g.newBlock();
                const merged = try g.fresh();
                try g.emit(.{ .cbnz = .{ .rn = g.pick(), .target = then } });
                try g.emit(.{ .b = els });
                const saved = g.avail.items.len;
                inline for (.{ then, els }) |arm| {
                    g.cur = arm;
                    try g.region(depth + 1);
                    try g.emit(.{ .mov = .{ .rd = merged, .rn = g.pick() } });
                    try g.emit(.{ .b = join });
                    g.avail.shrinkRetainingCapacity(saved);
                }
                g.cur = join;
                try g.avail.append(g.gpa, merged);
            },
            1 => {
                const counter = try g.fresh();
                g.f.vregs.items[counter.index()].ref = false;
                try g.emit(.{ .imm = .{ .rd = counter, .imm = 1 + g.rng.uintLessThan(u64, 3) } });
                const header = try g.newBlock();
                const body = try g.newBlock();
                const exit = try g.newBlock();
                try g.emit(.{ .b = header });
                g.cur = header;
                try g.emit(.{ .cbnz = .{ .rn = counter, .target = body } });
                try g.emit(.{ .b = exit });
                g.cur = body;
                const saved = g.avail.items.len;
                try g.region(depth + 1);
                g.avail.shrinkRetainingCapacity(saved);
                try g.emit(.{ .dec = .{ .rd = counter, .rn = counter } });
                try g.emit(.{ .b = header });
                g.cur = exit;
            },
            2 => {
                // A one-armed branch: the taken edge goes straight to the join, a critical
                // edge.
                const then = try g.newBlock();
                const join = try g.newBlock();
                const merged = try g.fresh();
                try g.emit(.{ .mov = .{ .rd = merged, .rn = g.pick() } });
                try g.emit(.{ .cbnz = .{ .rn = g.pick(), .target = join } });
                try g.emit(.{ .b = then });
                g.cur = then;
                const saved = g.avail.items.len;
                try g.region(depth + 1);
                try g.emit(.{ .mov = .{ .rd = merged, .rn = g.pick() } });
                try g.emit(.{ .b = join });
                g.avail.shrinkRetainingCapacity(saved);
                g.cur = join;
                try g.avail.append(g.gpa, merged);
            },
            else => {},
        }
        try g.chunk(g.rng.uintLessThan(usize, 4));
    }

    fn program(gpa: std.mem.Allocator, f: *TF, seed: u64) !void {
        var prng = std.Random.DefaultPrng.init(seed);
        var g: Gen = .{ .gpa = gpa, .rng = prng.random(), .f = f };
        defer g.avail.deinit(gpa);
        errdefer {
            for (g.blocks.items) |*b| b.insts.deinit(gpa);
            g.blocks.deinit(gpa);
        }
        _ = try g.newBlock();
        try g.avail.append(gpa, try g.defNew());
        try g.region(0);
        for (g.avail.items) |r| try g.emit(.{ .use = r });
        try g.emit(.ret);
        gpa.free(f.blocks);
        f.blocks = try g.blocks.toOwnedSlice(gpa);
    }
};

fn cloneFunc(gpa: std.mem.Allocator, f: *TF) !TF {
    var c = try TF.init(gpa, f.blocks.len);
    errdefer c.deinit(gpa);
    for (f.blocks, c.blocks) |b, *cb| try cb.insts.appendSlice(gpa, b.insts.items);
    try c.vregs.appendSlice(gpa, f.vregs.items);
    return c;
}

test "linear scan: random programs compute the same before and after allocation, under a moving collector" {
    const gpa = testing.allocator;
    // How many programs needed each mechanism, so the test cannot pass by never using one.
    var spilled: usize = 0;
    var mapped: usize = 0;
    var edge_split: usize = 0;
    var saved: usize = 0;
    var seed: u64 = 0;
    while (seed < 400) : (seed += 1) {
        var f = try TF.init(gpa, 0);
        defer f.deinit(gpa);
        try Gen.program(gpa, &f, seed);
        var before = try cloneFunc(gpa, &f);
        defer before.deinit(gpa);
        const want = try Machine.run(gpa, &before, null);
        defer gpa.free(want);

        var frame: Mir.Frame = .{ .layout = undefined };
        var res = LinearScan(TestTarget).run(gpa, &f, &frame) catch |e| {
            std.debug.print("seed {d}: {t}\n", .{ seed, e });
            return e;
        };
        defer res.deinit(gpa);
        try testing.expect(f.allPhysical());
        const got = try Machine.run(gpa, &f, res.maps);
        defer gpa.free(got);
        testing.expectEqualSlices(u64, want, got) catch |e| {
            std.debug.print("seed {d} differs\n", .{seed});
            return e;
        };
        if (frame.spills > 0) spilled += 1;
        for (res.maps) |m| if (m.len > 0) {
            mapped += 1;
            break;
        };
        if (f.blocks.len > before.blocks.len) edge_split += 1;
        if (frame.saved != 0) saved += 1;
    }
    try testing.expect(spilled > 100 and mapped > 50 and edge_split > 10 and saved > 100);
}

test "linear scan: a value live across a call takes the callee-saved register; a reference goes to its slot" {
    const gpa = testing.allocator;
    var f = try TF.init(gpa, 1);
    defer f.deinit(gpa);
    const n = try f.newVReg(gpa, .gpr, null);
    const r = try f.newVReg(gpa, .gpr, null);
    f.vregs.items[r.index()].ref = true;
    const insts = &f.blocks[0].insts;
    try insts.append(gpa, .{ .op = .{ .imm = .{ .rd = n, .imm = 1 } } });
    try insts.append(gpa, .{ .op = .{ .imm = .{ .rd = r, .imm = 2 } } });
    try insts.append(gpa, .{ .op = .{ .call = .{} } });
    try insts.append(gpa, .{ .op = .{ .use = n } });
    try insts.append(gpa, .{ .op = .{ .use = r } });
    try insts.append(gpa, .{ .op = .ret });

    var frame: Mir.Frame = .{ .layout = undefined };
    var res = try LinearScan(TestTarget).run(gpa, &f, &frame);
    defer res.deinit(gpa);
    const got = f.blocks[0].insts.items;
    try testing.expectEqual(Mir.Reg.gp(19), got[0].op.imm.rd);
    try testing.expectEqual(Mir.regBit(Mir.Reg.gp(19)), frame.saved);
    // The reference is stored before the call and reloaded after it.
    var store_before = false;
    var reload_after = false;
    var seen_call = false;
    for (got) |i| switch (i.op) {
        .call => seen_call = true,
        .st => store_before = !seen_call,
        .ld => reload_after = seen_call,
        else => {},
    };
    try testing.expect(store_before and reload_after);
    try testing.expectEqual(@as(usize, 1), res.maps.len);
    try testing.expectEqualSlices(Root, &.{.{ .spill = 0 }}, res.maps[0]);
}

test "linear scan: a reference kept past a safepoint is in its slot across it, with no reload and no keep left" {
    const gpa = testing.allocator;
    // A C callee can call back into toy and collect while only its own registers hold the
    // argument: the keep holds the caller's copy in a slot the safepoint's map names.
    var f = try TF.init(gpa, 1);
    defer f.deinit(gpa);
    const r = try f.newVReg(gpa, .gpr, null);
    f.vregs.items[r.index()].ref = true;
    const insts = &f.blocks[0].insts;
    try insts.append(gpa, .{ .op = .{ .imm = .{ .rd = r, .imm = 2 } } });
    try insts.append(gpa, .{ .op = .{ .mov = .{ .rd = Mir.Reg.gp(0), .rn = r } } });
    try insts.append(gpa, .{ .op = .{ .call = .{ .uses = Mir.regBit(Mir.Reg.gp(0)) } } });
    try insts.append(gpa, .{ .op = .{ .keep = r } });
    try insts.append(gpa, .{ .op = .ret });
    var frame: Mir.Frame = .{ .layout = undefined };
    var res = try LinearScan(TestTarget).run(gpa, &f, &frame);
    defer res.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), res.maps.len);
    try testing.expectEqualSlices(Root, &.{.{ .spill = 0 }}, res.maps[0]);
    var seen_call = false;
    for (f.blocks[0].insts.items) |i| switch (i.op) {
        .call => seen_call = true,
        .ld => try testing.expect(!seen_call),
        .keep => return error.TestUnexpectedResult,
        else => {},
    };
    try testing.expect(f.allPhysical());
}

test "linear scan: a call that never collects keeps a reference in a register" {
    const gpa = testing.allocator;
    var f = try TF.init(gpa, 1);
    defer f.deinit(gpa);
    const r = try f.newVReg(gpa, .gpr, null);
    f.vregs.items[r.index()].ref = true;
    const insts = &f.blocks[0].insts;
    try insts.append(gpa, .{ .op = .{ .imm = .{ .rd = r, .imm = 2 } } });
    try insts.append(gpa, .{ .op = .{ .call = .{ .safepoint = false } } });
    try insts.append(gpa, .{ .op = .{ .use = r } });
    try insts.append(gpa, .{ .op = .ret });
    var frame: Mir.Frame = .{ .layout = undefined };
    var res = try LinearScan(TestTarget).run(gpa, &f, &frame);
    defer res.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), res.maps.len);
    try testing.expectEqual(@as(u32, 0), frame.spills);
    try testing.expectEqual(Mir.Reg.gp(19), f.blocks[0].insts.items[0].op.imm.rd);
}

test "linear scan: a loop's next value takes the register of the param it is copied into" {
    const gpa = testing.allocator;
    // b0: t = 7 ; p = 3 ; use t ; b 1      (t takes the first register, p the second)
    // b1: cbnz p, 2 ; b 3
    // b2: n = p - 1 ; p = n ; b 1          (n is free to take either; the copy wants p's)
    // b3: use p ; ret
    var f = try TF.init(gpa, 4);
    defer f.deinit(gpa);
    const t = try f.newVReg(gpa, .gpr, null);
    const p = try f.newVReg(gpa, .gpr, null);
    const n = try f.newVReg(gpa, .gpr, null);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .imm = .{ .rd = t, .imm = 7 } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .imm = .{ .rd = p, .imm = 3 } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .use = t } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .cbnz = .{ .rn = p, .target = 2 } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .b = 3 } });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .dec = .{ .rd = n, .rn = p } } });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .mov = .{ .rd = p, .rn = n } } });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[3].insts.append(gpa, .{ .op = .{ .use = p } });
    try f.blocks[3].insts.append(gpa, .{ .op = .ret });

    var before = try cloneFunc(gpa, &f);
    defer before.deinit(gpa);
    var frame: Mir.Frame = .{ .layout = undefined };
    var res = try LinearScan(TestTarget).run(gpa, &f, &frame);
    defer res.deinit(gpa);
    for (f.blocks[2].insts.items) |i| try testing.expect(i.op != .mov);
    const want = try Machine.run(gpa, &before, null);
    defer gpa.free(want);
    const got = try Machine.run(gpa, &f, res.maps);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, want, got);
}

test "linear scan: a value spilled inside a loop reloads at the loop entry, not in the body" {
    const gpa = testing.allocator;
    // b0: v = 5 ; c = 2 ; b 1
    // b1: cbnz c, 2 ; b 3
    // b2: two values and the counter fill every register ; c = c - 1 ; b 1
    // b3: use v ; ret
    var f = try TF.init(gpa, 4);
    defer f.deinit(gpa);
    const v = try f.newVReg(gpa, .gpr, null);
    const c = try f.newVReg(gpa, .gpr, null);
    var t: [2]Mir.Reg = undefined;
    for (&t) |*x| x.* = try f.newVReg(gpa, .gpr, null);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .imm = .{ .rd = v, .imm = 5 } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .imm = .{ .rd = c, .imm = 2 } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .cbnz = .{ .rn = c, .target = 2 } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .b = 3 } });
    const body = &f.blocks[2].insts;
    for (t, 0..) |x, i| try body.append(gpa, .{ .op = .{ .imm = .{ .rd = x, .imm = 10 + i } } });
    for (t) |x| try body.append(gpa, .{ .op = .{ .use = x } });
    try body.append(gpa, .{ .op = .{ .dec = .{ .rd = c, .rn = c } } });
    try body.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[3].insts.append(gpa, .{ .op = .{ .use = v } });
    try f.blocks[3].insts.append(gpa, .{ .op = .ret });

    var before = try cloneFunc(gpa, &f);
    defer before.deinit(gpa);
    var frame: Mir.Frame = .{ .layout = undefined };
    var res = try LinearScan(TestTarget).run(gpa, &f, &frame);
    defer res.deinit(gpa);
    for (f.blocks[2].insts.items) |i| try testing.expect(i.op != .ld);
    const want = try Machine.run(gpa, &before, null);
    defer gpa.free(want);
    const got = try Machine.run(gpa, &f, res.maps);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, want, got);
}
