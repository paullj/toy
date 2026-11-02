//! The spill-every-vreg allocator: each virtual register lives in its home stack slot and is
//! loaded into a scratch register before each instruction that reads it and stored back
//! after each one that writes it. No value is in a register between instructions, so it is
//! trivially correct at every safepoint and serves as the oracle the real allocator (#200)
//! is checked against.
//!
//! `Target` provides `Inst` (see `Mir.Function`), `scratch(Mir.RegClass) []const Mir.Reg`
//! (at least as many registers per class as one instruction reads, none of them used by the
//! selector), and `spillLoad`/`spillStore(Mir.Reg, Mir.FrameRef, line) Inst`.

const std = @import("std");
const Mir = @import("Mir.zig");

pub fn SpillAll(comptime Target: type) type {
    return struct {
        const Func = Mir.Function(Target.Inst);

        pub fn run(gpa: std.mem.Allocator, func: *Func, frame: *Mir.Frame) error{OutOfMemory}!void {
            const homes = try gpa.alloc(?Mir.FrameRef, func.vregs.items.len);
            defer gpa.free(homes);
            for (homes, func.vregs.items) |*h, v| h.* = v.home;

            for (func.blocks) |*blk| {
                var out: std.ArrayList(Target.Inst) = .empty;
                errdefer out.deinit(gpa);
                try out.ensureTotalCapacity(gpa, blk.insts.items.len);
                for (blk.insts.items) |orig| {
                    var inst = orig;
                    var buf: [Mir.max_operands]Mir.Operand = undefined;
                    const ops = inst.operands(&buf);

                    var assigned: [Mir.max_operands]struct { v: Mir.Reg, r: Mir.Reg } = undefined;
                    var n_assigned: usize = 0;
                    var taken: [2]usize = .{ 0, 0 };
                    // Uses first: each distinct vreg gets its own scratch and one load.
                    for (ops) |o| {
                        if (o.kind != .use or !o.reg.*.isVirtual()) continue;
                        const v = o.reg.*;
                        const r = for (assigned[0..n_assigned]) |a| {
                            if (a.v == v) break a.r;
                        } else blk2: {
                            const class = func.vregs.items[v.index()].class;
                            const pool = Target.scratch(class);
                            const r = pool[taken[@intFromEnum(class)]];
                            taken[@intFromEnum(class)] += 1;
                            assigned[n_assigned] = .{ .v = v, .r = r };
                            n_assigned += 1;
                            try out.append(gpa, Target.spillLoad(r, home(homes, frame, v), inst.line));
                            break :blk2 r;
                        };
                        o.reg.* = r;
                    }
                    // A def reuses its own use's scratch, else takes a free one; every
                    // instruction reads its sources before it writes, so the first scratch
                    // is safe when all are taken.
                    var defs: [Mir.max_operands]struct { v: Mir.Reg, r: Mir.Reg } = undefined;
                    var n_defs: usize = 0;
                    for (ops) |o| {
                        if (o.kind != .def or !o.reg.*.isVirtual()) continue;
                        const v = o.reg.*;
                        const class = func.vregs.items[v.index()].class;
                        const pool = Target.scratch(class);
                        const r = for (assigned[0..n_assigned]) |a| {
                            if (a.v == v) break a.r;
                        } else if (taken[@intFromEnum(class)] < pool.len) pool[taken[@intFromEnum(class)]] else pool[0];
                        defs[n_defs] = .{ .v = v, .r = r };
                        n_defs += 1;
                        o.reg.* = r;
                    }
                    try out.append(gpa, inst);
                    for (defs[0..n_defs]) |d| try out.append(gpa, Target.spillStore(d.r, home(homes, frame, d.v), inst.line));
                }
                blk.insts.deinit(gpa);
                blk.insts = out;
            }
        }

        fn home(homes: []?Mir.FrameRef, frame: *Mir.Frame, v: Mir.Reg) Mir.FrameRef {
            const h = &homes[v.index()];
            if (h.* == null) h.* = frame.newSpill();
            return h.*.?;
        }
    };
}

const testing = std.testing;

/// A two-op target, enough to see what the allocator inserts.
const TestTarget = struct {
    const Inst = struct {
        op: union(enum) {
            add: struct { rd: Mir.Reg, rn: Mir.Reg, rm: Mir.Reg },
            ld: struct { rt: Mir.Reg, ref: Mir.FrameRef },
            st: struct { rt: Mir.Reg, ref: Mir.FrameRef },
        },
        line: u32 = 0,

        pub fn callRegs(_: Inst) ?Mir.CallRegs {
            return null;
        }
        pub fn operands(i: *Inst, buf: *[Mir.max_operands]Mir.Operand) []Mir.Operand {
            switch (i.op) {
                .add => |*a| {
                    buf[0] = .{ .reg = &a.rn, .kind = .use };
                    buf[1] = .{ .reg = &a.rm, .kind = .use };
                    buf[2] = .{ .reg = &a.rd, .kind = .def };
                    return buf[0..3];
                },
                .ld => |*l| {
                    buf[0] = .{ .reg = &l.rt, .kind = .def };
                    return buf[0..1];
                },
                .st => |*s| {
                    buf[0] = .{ .reg = &s.rt, .kind = .use };
                    return buf[0..1];
                },
            }
        }
    };
    const pool = [_]Mir.Reg{ Mir.Reg.gp(9), Mir.Reg.gp(10), Mir.Reg.gp(11) };
    fn scratch(_: Mir.RegClass) []const Mir.Reg {
        return &pool;
    }
    fn spillLoad(r: Mir.Reg, ref: Mir.FrameRef, line: u32) Inst {
        return .{ .op = .{ .ld = .{ .rt = r, .ref = ref } }, .line = line };
    }
    fn spillStore(r: Mir.Reg, ref: Mir.FrameRef, line: u32) Inst {
        return .{ .op = .{ .st = .{ .rt = r, .ref = ref } }, .line = line };
    }
};

test "spill-all: loads each use once, stores each def to its home, homeless vregs get a spill slot" {
    const gpa = testing.allocator;
    const F = Mir.Function(TestTarget.Inst);
    var f = try F.init(gpa, 1);
    defer f.deinit(gpa);
    const a = try f.newVReg(gpa, .gpr, .{ .value = 0 });
    const t = try f.newVReg(gpa, .gpr, null);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .add = .{ .rd = t, .rn = a, .rm = a } }, .line = 7 });

    var frame: Mir.Frame = .{ .layout = undefined };
    try SpillAll(TestTarget).run(gpa, &f, &frame);
    try testing.expect(f.allPhysical());
    const got = f.blocks[0].insts.items;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Mir.FrameRef{ .value = 0 }, got[0].op.ld.ref);
    try testing.expectEqual(Mir.Reg.gp(9), got[1].op.add.rn);
    try testing.expectEqual(Mir.Reg.gp(9), got[1].op.add.rm);
    try testing.expectEqual(Mir.Reg.gp(10), got[1].op.add.rd);
    try testing.expectEqual(Mir.FrameRef{ .spill = 0 }, got[2].op.st.ref);
    for (got) |i| try testing.expectEqual(@as(u32, 7), i.line);
    try testing.expectEqual(@as(u32, 1), frame.spills);
}
