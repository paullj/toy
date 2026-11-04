//! AArch64 MIR peepholes, between instruction selection and register allocation (#203).
//! The selector stays a plain one-IR-op-at-a-time translation; this pass folds the
//! patterns it leaves behind, on virtual registers, where the allocator then sees fewer
//! and shorter live ranges:
//!
//! - a frame address or a register plus a constant feeding a memory operand folds into
//!   the access (`ldr x, [sp, #off]`, `ldr x, [base, #off]`);
//! - a small constant operand of `cmp`, `add`, `sub` and the `adds` overflow check
//!   becomes the instruction's immediate;
//! - signed and unsigned division by a power of two becomes shifts, and the `msub` of a
//!   remainder by one becomes a shifted `sub`; a multiply by a power of two becomes a left
//!   shift;
//! - `cset` feeding the block's `cbnz` becomes a `b.cond` on the flags;
//! - then every pure instruction whose result nothing reads is dropped.
//!
//! A register's constant or address is only trusted when the register has exactly one
//! definition: IR values are SSA and selector temporaries stay in their block, so that
//! definition dominates every use and still holds there (a block param, written on each
//! edge, or a narrow value the selector re-normalizes, has more and is left alone).

const std = @import("std");
const Mir = @import("../Mir.zig");
const Inst = @import("Inst.zig");
const Aarch64 = @import("../../Aarch64.zig");

const Reg = Mir.Reg;
const Mem = Mir.Mem;
const Func = Mir.Function(Inst);

/// Offsets stay well inside what the encoder reaches with one extra instruction.
const max_off: u64 = 1 << 24;

/// What the one definition of a register says about its value: a constant, a frame
/// address, or another register plus an offset.
const Def = union(enum) {
    none,
    imm: i64,
    frame: struct { ref: Mir.FrameRef, off: u32 },
    reg_off: struct { base: Reg, off: u32 },
};

pub fn run(gpa: std.mem.Allocator, f: *Func) error{OutOfMemory}!void {
    var p: P = .{ .gpa = gpa, .f = f };
    defer p.deinit();
    try p.analyze();
    try p.rewrite();
    try p.fuseBranches();
    try p.dropDead();
}

const P = struct {
    gpa: std.mem.Allocator,
    f: *Func,
    defs: []u32 = &.{},
    known: []Def = &.{},

    fn deinit(p: *P) void {
        p.gpa.free(p.defs);
        p.gpa.free(p.known);
    }

    fn analyze(p: *P) error{OutOfMemory}!void {
        const n = p.f.vregs.items.len;
        p.defs = try p.gpa.alloc(u32, n);
        @memset(p.defs, 0);
        p.known = try p.gpa.alloc(Def, n);
        @memset(p.known, .none);
        for (p.f.blocks) |*b| for (b.insts.items) |*inst| {
            var buf: [Mir.max_operands]Mir.Operand = undefined;
            for (inst.operands(&buf)) |o| {
                if (o.kind == .def and o.reg.*.isVirtual()) p.defs[o.reg.*.index()] += 1;
            }
        };
        for (p.f.blocks) |*b| for (b.insts.items) |inst| {
            const d = rawDef(p.f, inst) orelse p.addConstDef(inst) orelse continue;
            if (p.single(d.reg)) p.known[d.reg.index()] = d.def;
        };
    }

    /// An `add` of a register and a known constant, which `rewrite` turns into an
    /// `add_imm`: known now, so an access through its result folds the constant too.
    fn addConstDef(p: *const P, inst: Inst) ?RegDef {
        const o = switch (inst.op) {
            .alu => |o| o,
            else => return null,
        };
        if (o.op != .add) return null;
        const base, const k = if (p.imm(o.rm)) |k| .{ o.rn, k } else if (p.imm(o.rn)) |k| .{ o.rm, k } else return null;
        if (k < 0 or k >= max_off) return null;
        return .{ .reg = o.rd, .def = memDef(Mem.reg(base, 0), @intCast(k)) };
    }

    fn single(p: *const P, r: Reg) bool {
        return r.isVirtual() and r.index() < p.defs.len and p.defs[r.index()] == 1;
    }

    /// The value of `r` in the most folded terms known: a chain of register-plus-offset
    /// definitions ends at a frame address or at a register defined some other way.
    fn get(p: *const P, r: Reg) Def {
        var cur = r;
        var off: u64 = 0;
        // SSA single definitions cannot form a cycle; the bound is only a backstop.
        for (0..16) |_| {
            if (!p.single(cur)) break;
            switch (p.known[cur.index()]) {
                .none => break,
                .imm => |x| return if (off == 0) .{ .imm = x } else .none,
                .frame => |fr| {
                    const total = off + fr.off;
                    return if (total < max_off) .{ .frame = .{ .ref = fr.ref, .off = @intCast(total) } } else .none;
                },
                .reg_off => |ro| {
                    off += ro.off;
                    cur = ro.base;
                },
            }
        }
        if (cur == r or off >= max_off or !p.single(cur)) return .none;
        // A selector temporary must not outlive its block: it may hold a reference no
        // stack map names across a later safepoint.
        if (p.f.vregs.items[cur.index()].home == null) return .none;
        return .{ .reg_off = .{ .base = cur, .off = @intCast(off) } };
    }

    fn imm(p: *const P, r: Reg) ?i64 {
        return switch (p.get(r)) {
            .imm => |x| x,
            else => null,
        };
    }

    /// `m` with its register base replaced by the address that register is known to hold.
    fn foldMem(p: *const P, m: *Mem) void {
        const r = switch (m.base) {
            .reg => |r| r,
            .frame => return,
        };
        switch (p.get(r)) {
            .frame => |fr| if (fr.off + @as(u64, m.off) < max_off) {
                m.* = Mem.frame(fr.ref, fr.off + m.off);
            },
            .reg_off => |ro| if (ro.off + @as(u64, m.off) < max_off) {
                m.* = Mem.reg(ro.base, ro.off + m.off);
            },
            else => {},
        }
    }

    fn rewrite(p: *P) error{OutOfMemory}!void {
        for (p.f.blocks) |*b| {
            var out: std.ArrayList(Inst) = .empty;
            errdefer out.deinit(p.gpa);
            try out.ensureTotalCapacity(p.gpa, b.insts.items.len);
            for (b.insts.items) |inst| try p.rewriteOne(&out, inst);
            b.insts.deinit(p.gpa);
            b.insts = out;
        }
    }

    fn rewriteOne(p: *P, out: *std.ArrayList(Inst), orig: Inst) error{OutOfMemory}!void {
        var inst = orig;
        const zr = Reg.gp(Aarch64.XZR);
        switch (inst.op) {
            .load => |*o| p.foldMem(&o.mem),
            .store => |*o| p.foldMem(&o.mem),
            .addr => |*o| p.foldMem(&o.mem),
            .copy => |*o| {
                p.foldMem(&o.dst);
                p.foldMem(&o.src);
            },
            .cmp => |o| if (o.rn != zr) if (u12Of(p.imm(o.rm))) |k| {
                inst.op = .{ .cmp_imm = .{ .rn = o.rn, .imm = k } };
            },
            .alu => |o| switch (o.op) {
                .add, .sub => if (o.rd != zr and o.rn != zr) {
                    const lhs_k = if (o.op == .add) p.imm(o.rn) else null;
                    const rn, const k = if (p.imm(o.rm)) |k| .{ o.rn, k } else if (lhs_k) |k| .{ o.rm, k } else return out.append(p.gpa, inst);
                    if (rn == zr) return out.append(p.gpa, inst);
                    const neg_k = if (k == std.math.minInt(i64)) null else -k;
                    const add_k, const sub_k = if (o.op == .add) .{ u12Of(k), u12Of(neg_k) } else .{ u12Of(neg_k), u12Of(k) };
                    if (add_k) |a| {
                        inst.op = .{ .add_imm = .{ .rd = o.rd, .rn = rn, .imm = a } };
                    } else if (sub_k) |s| inst.op = .{ .sub_imm = .{ .rd = o.rd, .rn = rn, .imm = s } };
                },
                .adds => if (o.rd == zr) {
                    if (u12Of(p.imm(o.rm))) |k| {
                        if (o.rn != zr) inst.op = .{ .cmn_imm = .{ .rn = o.rn, .imm = k } };
                    } else if (u12Of(p.imm(o.rn))) |k| {
                        if (o.rm != zr) inst.op = .{ .cmn_imm = .{ .rn = o.rm, .imm = k } };
                    }
                },
                .sdiv => if (log2Of(p.imm(o.rm))) |k| return p.sdivPow2(out, orig, o.rd, o.rn, k),
                .udiv => if (log2Of(p.imm(o.rm))) |k| {
                    inst.op = if (k == 0) .{ .mov = .{ .rd = o.rd, .rn = o.rn } } else .{ .shift_imm = .{ .op = .lsr, .rd = o.rd, .rn = o.rn, .amt = k } };
                },
                .mul => {
                    const rn, const k = if (log2Of(p.imm(o.rm))) |k| .{ o.rn, k } else if (log2Of(p.imm(o.rn))) |k| .{ o.rm, k } else return out.append(p.gpa, inst);
                    inst.op = if (k == 0) .{ .mov = .{ .rd = o.rd, .rn = rn } } else .{ .shift_imm = .{ .op = .lsl, .rd = o.rd, .rn = rn, .amt = k } };
                },
                else => {},
            },
            .msub => |o| {
                const q, const k = if (log2Of(p.imm(o.rm))) |k| .{ o.rn, k } else if (log2Of(p.imm(o.rn))) |k| .{ o.rm, k } else return out.append(p.gpa, inst);
                inst.op = .{ .alu_sh = .{ .op = .sub, .rd = o.rd, .rn = o.ra, .rm = q, .shift = .lsl, .amt = k } };
            },
            else => {},
        }
        try out.append(p.gpa, inst);
    }

    /// Truncating signed division by 2^k: add 2^k - 1 to a negative dividend first, so the
    /// arithmetic shift rounds toward zero as `sdiv` does (int.min included).
    fn sdivPow2(p: *P, out: *std.ArrayList(Inst), orig: Inst, rd: Reg, rn: Reg, k: u6) error{OutOfMemory}!void {
        const line = orig.line;
        if (k == 0) return out.append(p.gpa, .{ .op = .{ .mov = .{ .rd = rd, .rn = rn } }, .line = line });
        const biased = try p.f.newVReg(p.gpa, .gpr, null);
        if (k == 1) {
            try out.append(p.gpa, .{ .op = .{ .alu_sh = .{ .op = .add, .rd = biased, .rn = rn, .rm = rn, .shift = .lsr, .amt = 63 } }, .line = line });
        } else {
            const sign = try p.f.newVReg(p.gpa, .gpr, null);
            try out.append(p.gpa, .{ .op = .{ .shift_imm = .{ .op = .asr, .rd = sign, .rn = rn, .amt = 63 } }, .line = line });
            try out.append(p.gpa, .{ .op = .{ .alu_sh = .{ .op = .add, .rd = biased, .rn = rn, .rm = sign, .shift = .lsr, .amt = @intCast(64 - @as(u32, k)) } }, .line = line });
        }
        try out.append(p.gpa, .{ .op = .{ .shift_imm = .{ .op = .asr, .rd = rd, .rn = biased, .amt = k } }, .line = line });
    }

    /// `cset v, cc` before the block's `cbnz v` with nothing that sets flags between: branch
    /// on the flags instead. The `cset` stays for any other reader of `v`.
    fn fuseBranches(p: *P) error{OutOfMemory}!void {
        for (p.f.blocks) |*b| {
            const insts = b.insts.items;
            for (insts, 0..) |*inst, k| {
                const c = switch (inst.op) {
                    .cbnz => |c| c,
                    else => continue,
                };
                if (!p.single(c.rn)) continue;
                var j = k;
                const cond = while (j > 0) {
                    j -= 1;
                    switch (insts[j].op) {
                        .cset => |s| if (s.rd == c.rn) break s.cond,
                        else => {},
                    }
                    if (setsFlags(insts[j])) break null;
                } else null;
                if (cond) |cc| inst.op = .{ .b_cond = .{ .cond = cc, .target = c.target } };
            }
        }
    }

    /// Drop pure instructions whose virtual result nothing reads, until none is left. Uses
    /// are counted once and a dropped instruction gives its operands' back; sweeping each
    /// block from the end frees a whole chain in one pass when its defs precede its uses,
    /// and a later pass catches the rest.
    fn dropDead(p: *P) error{OutOfMemory}!void {
        const uses = try p.gpa.alloc(u32, p.f.vregs.items.len);
        defer p.gpa.free(uses);
        @memset(uses, 0);
        for (p.f.blocks) |*b| for (b.insts.items) |*inst| {
            var buf: [Mir.max_operands]Mir.Operand = undefined;
            for (inst.operands(&buf)) |o| {
                if (o.kind != .def and o.reg.*.isVirtual()) uses[o.reg.*.index()] += 1;
            }
        };
        var dead: std.ArrayList(bool) = .empty;
        defer dead.deinit(p.gpa);
        var changed = true;
        while (changed) {
            changed = false;
            var bi = p.f.blocks.len;
            while (bi > 0) {
                bi -= 1;
                const insts = &p.f.blocks[bi].insts;
                try dead.resize(p.gpa, insts.items.len);
                @memset(dead.items, false);
                var dropped = false;
                var k = insts.items.len;
                while (k > 0) {
                    k -= 1;
                    const inst = &insts.items[k];
                    const d = pureDef(inst.*) orelse continue;
                    if (!d.isVirtual() or uses[d.index()] != 0) continue;
                    var buf: [Mir.max_operands]Mir.Operand = undefined;
                    for (inst.operands(&buf)) |o| {
                        if (o.kind != .def and o.reg.*.isVirtual()) uses[o.reg.*.index()] -= 1;
                    }
                    dead.items[k] = true;
                    dropped = true;
                }
                if (!dropped) continue;
                changed = true;
                var w: usize = 0;
                for (insts.items, dead.items) |inst, gone| {
                    if (gone) continue;
                    insts.items[w] = inst;
                    w += 1;
                }
                insts.shrinkRetainingCapacity(w);
            }
        }
    }
};

/// Whether an instruction may change the condition flags. The allocator's moves, spills
/// and reloads never do, nor does anything the encoder expands into. No `else`: a new op
/// must say, since one wrongly fused across turns a `b.cond` wrong.
fn setsFlags(inst: Inst) bool {
    return switch (inst.op) {
        .cmp, .cmp_imm, .cmn_imm, .fcmp, .call, .b, .cbnz, .b_cond, .ret, .brk => true,
        .alu => |o| o.op == .adds,
        .mov_imm, .mov, .msub, .add_imm, .sub_imm, .alu_sh, .shift_imm, .unary, .cset, .csel => false,
        .fp_alu, .cvt, .load, .store, .addr, .copy, .sym_addr, .keep, .safepoint_poll => false,
    };
}

/// The register an instruction defines and what it computes, for the kinds `Def` names.
const RegDef = struct { reg: Reg, def: Def };

fn rawDef(f: *Func, inst: Inst) ?RegDef {
    return switch (inst.op) {
        .mov_imm => |o| .{ .reg = o.rd, .def = .{ .imm = o.imm } },
        .addr => |o| .{ .reg = o.rd, .def = memDef(o.mem, 0) },
        .add_imm => |o| .{ .reg = o.rd, .def = memDef(Mem.reg(o.rn, 0), o.imm) },
        .mov => |o| if (!o.single and f.classOf(o.rd) == .gpr and f.classOf(o.rn) == .gpr)
            .{ .reg = o.rd, .def = memDef(Mem.reg(o.rn, 0), 0) }
        else
            null,
        else => null,
    };
}

fn memDef(m: Mem, extra: u32) Def {
    const off = @as(u64, m.off) + extra;
    if (off >= max_off) return .none;
    return switch (m.base) {
        .frame => |ref| .{ .frame = .{ .ref = ref, .off = @intCast(off) } },
        .reg => |r| if (r.isVirtual()) .{ .reg_off = .{ .base = r, .off = @intCast(off) } } else .none,
    };
}

/// The one register an instruction with no other effect writes.
fn pureDef(inst: Inst) ?Reg {
    return switch (inst.op) {
        .mov_imm => |o| o.rd,
        .mov => |o| o.rd,
        .addr => |o| o.rd,
        .add_imm => |o| o.rd,
        .sub_imm => |o| o.rd,
        .alu_sh => |o| o.rd,
        .shift_imm => |o| o.rd,
        .unary => |o| o.rd,
        .cset => |o| o.rd,
        .sym_addr => |o| o.rd,
        .alu => |o| if (o.op == .adds) null else o.rd,
        else => null,
    };
}

fn u12Of(k: ?i64) ?u12 {
    const x = k orelse return null;
    return if (x >= 0 and x <= 0xFFF) @intCast(x) else null;
}

/// k when `x` is 2^k (a positive power of two).
fn log2Of(x: ?i64) ?u6 {
    const v = x orelse return null;
    if (v <= 0 or v & (v - 1) != 0) return null;
    return @intCast(@ctz(v));
}

const testing = std.testing;

fn testFunc(gpa: std.mem.Allocator, n_blocks: usize, n_vregs: u32) !Func {
    var f = try Func.init(gpa, n_blocks);
    errdefer f.deinit(gpa);
    for (0..n_vregs) |i| _ = try f.newVReg(gpa, .gpr, .{ .value = @intCast(i) });
    return f;
}

fn add(gpa: std.mem.Allocator, f: *Func, block: usize, op: Inst.Op) !void {
    try f.blocks[block].insts.append(gpa, .{ .op = op });
}

/// Runs the straight-line integer code of one block over 64-bit registers.
fn evalBlock(f: *const Func, block: usize, regs: []u64) void {
    const at = struct {
        fn i(r: Reg) usize {
            return @intFromEnum(r);
        }
    }.i;
    for (f.blocks[block].insts.items) |inst| switch (inst.op) {
        .mov_imm => |o| regs[at(o.rd)] = @bitCast(o.imm),
        .mov => |o| regs[at(o.rd)] = regs[at(o.rn)],
        .alu => |o| {
            const a = regs[at(o.rn)];
            const b = regs[at(o.rm)];
            const sa: i64 = @bitCast(a);
            const sb: i64 = @bitCast(b);
            regs[at(o.rd)] = switch (o.op) {
                .add => a +% b,
                .sub => a -% b,
                .sdiv => @bitCast(if (sb == -1) -%sa else @divTrunc(sa, sb)),
                .udiv => a / b,
                else => unreachable,
            };
        },
        .msub => |o| regs[at(o.rd)] = regs[at(o.ra)] -% regs[at(o.rn)] *% regs[at(o.rm)],
        .add_imm => |o| regs[at(o.rd)] = regs[at(o.rn)] +% o.imm,
        .sub_imm => |o| regs[at(o.rd)] = regs[at(o.rn)] -% o.imm,
        .shift_imm => |o| regs[at(o.rd)] = shifted(regs[at(o.rn)], o.op, o.amt),
        .alu_sh => |o| {
            const m = shifted(regs[at(o.rm)], o.shift, o.amt);
            regs[at(o.rd)] = if (o.op == .add) regs[at(o.rn)] +% m else regs[at(o.rn)] -% m;
        },
        .store => {},
        else => unreachable,
    };
}

fn shifted(x: u64, s: Inst.Shift, amt: u6) u64 {
    return switch (s) {
        .lsl => x << amt,
        .lsr => x >> amt,
        .asr => @bitCast(@as(i64, @bitCast(x)) >> amt),
    };
}

test "peephole: a frame address, or a register plus a constant, folds into the access" {
    const gpa = testing.allocator;
    var f = try testFunc(gpa, 2, 8);
    defer f.deinit(gpa);
    const v = Reg.virt;
    try add(gpa, &f, 1, .{ .addr = .{ .rd = v(0), .mem = Mem.frame(.{ .slot = 0 }, 0) } });
    try add(gpa, &f, 1, .{ .add_imm = .{ .rd = v(1), .rn = v(0), .imm = 8 } });
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(2), .mem = Mem.reg(v(1), 0) } });
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(3), .mem = Mem.frame(.{ .slot = 1 }, 0) } });
    try add(gpa, &f, 1, .{ .add_imm = .{ .rd = v(4), .rn = v(3), .imm = 16 } });
    try add(gpa, &f, 1, .{ .store = .{ .rt = v(2), .mem = Mem.reg(v(4), 8) } });
    // v5 is written twice (a block param): what it holds at the access is unknown.
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(5), .mem = Mem.frame(.{ .slot = 1 }, 0) } });
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(5), .mem = Mem.frame(.{ .slot = 2 }, 0) } });
    try add(gpa, &f, 1, .{ .add_imm = .{ .rd = v(6), .rn = v(5), .imm = 4 } });
    try add(gpa, &f, 1, .{ .store = .{ .rt = v(2), .mem = Mem.reg(v(6), 0) } });
    try run(gpa, &f);

    const got = f.blocks[1].insts.items;
    try testing.expectEqual(@as(usize, 7), got.len);
    try testing.expectEqualDeep(Mem.frame(.{ .slot = 0 }, 8), got[0].op.load.mem);
    try testing.expectEqualDeep(Mem.reg(v(3), 24), got[2].op.store.mem);
    try testing.expectEqualDeep(Mem.reg(v(6), 0), got[6].op.store.mem);
}

test "peephole: an add of a constant folds into the access through its result" {
    const gpa = testing.allocator;
    var f = try testFunc(gpa, 2, 4);
    defer f.deinit(gpa);
    const v = Reg.virt;
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(0), .mem = Mem.frame(.{ .slot = 0 }, 0) } });
    try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(1), .imm = 216 } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .add, .rd = v(2), .rn = v(0), .rm = v(1) } });
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(3), .mem = Mem.reg(v(2), 0) } });
    try add(gpa, &f, 1, .{ .store = .{ .rt = v(3), .mem = Mem.frame(.{ .slot = 1 }, 0) } });
    try run(gpa, &f);

    const got = f.blocks[1].insts.items;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualDeep(Mem.reg(v(0), 216), got[1].op.load.mem);
}

test "peephole: small constant operands become immediates" {
    const gpa = testing.allocator;
    var f = try testFunc(gpa, 2, 10);
    defer f.deinit(gpa);
    const v = Reg.virt;
    const zr = Reg.gp(Aarch64.XZR);
    const a = v(0);
    try add(gpa, &f, 1, .{ .load = .{ .rt = a, .mem = Mem.frame(.{ .slot = 0 }, 0) } });
    try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(1), .imm = 5 } });
    try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(2), .imm = -3 } });
    try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(3), .imm = 5000 } });
    try add(gpa, &f, 1, .{ .cmp = .{ .rn = a, .rm = v(1) } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .add, .rd = v(4), .rn = v(1), .rm = a } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .add, .rd = v(5), .rn = a, .rm = v(2) } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .sub, .rd = v(6), .rn = a, .rm = v(2) } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .adds, .rd = zr, .rn = v(1), .rm = a } });
    try add(gpa, &f, 1, .{ .cmp = .{ .rn = a, .rm = v(3) } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .sub, .rd = v(7), .rn = v(1), .rm = a } });
    for (4..8) |i| try add(gpa, &f, 1, .{ .store = .{ .rt = v(@intCast(i)), .mem = Mem.frame(.{ .slot = 1 }, 0) } });
    try run(gpa, &f);

    const got = f.blocks[1].insts.items;
    // The load, the two constants still read (5 by `5 - a`, 5000 by its cmp), then:
    try testing.expectEqualDeep(Inst.Op{ .cmp_imm = .{ .rn = a, .imm = 5 } }, got[3].op);
    try testing.expectEqualDeep(Inst.Op{ .add_imm = .{ .rd = v(4), .rn = a, .imm = 5 } }, got[4].op);
    try testing.expectEqualDeep(Inst.Op{ .sub_imm = .{ .rd = v(5), .rn = a, .imm = 3 } }, got[5].op);
    try testing.expectEqualDeep(Inst.Op{ .add_imm = .{ .rd = v(6), .rn = a, .imm = 3 } }, got[6].op);
    try testing.expectEqualDeep(Inst.Op{ .cmn_imm = .{ .rn = a, .imm = 5 } }, got[7].op);
    try testing.expect(got[8].op == .cmp);
    try testing.expect(got[9].op == .alu);
    for (got) |i| try testing.expect(!(i.op == .mov_imm and i.op.mov_imm.rd == v(2)));
}

test "peephole: division and remainder by a power of two become shifts that round as sdiv does" {
    const gpa = testing.allocator;
    const values = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -9, -8, -7, -1, 0, 1, 7, 8, 9, std.math.maxInt(i64) };
    for ([_]u6{ 0, 1, 3, 62 }) |k| for (values) |x| {
        var f = try testFunc(gpa, 2, 6);
        defer f.deinit(gpa);
        const v = Reg.virt;
        try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(0), .imm = x } });
        try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(1), .imm = @as(i64, 1) << k } });
        try add(gpa, &f, 1, .{ .alu = .{ .op = .sdiv, .rd = v(2), .rn = v(0), .rm = v(1) } });
        try add(gpa, &f, 1, .{ .msub = .{ .rd = v(3), .rn = v(2), .rm = v(1), .ra = v(0) } });
        try add(gpa, &f, 1, .{ .alu = .{ .op = .udiv, .rd = v(4), .rn = v(0), .rm = v(1) } });
        for (2..5) |i| try add(gpa, &f, 1, .{ .store = .{ .rt = v(@intCast(i)), .mem = Mem.frame(.{ .slot = 0 }, 0) } });
        try run(gpa, &f);
        for (f.blocks[1].insts.items) |i| try testing.expect(i.op != .msub and !(i.op == .alu and i.op.alu.op != .add));

        var regs: [128]u64 = @splat(0);
        evalBlock(&f, 1, &regs);
        const d = @as(i64, 1) << k;
        const at = Reg.virt;
        try testing.expectEqual(@divTrunc(x, d), @as(i64, @bitCast(regs[@intFromEnum(at(2))])));
        try testing.expectEqual(@rem(x, d), @as(i64, @bitCast(regs[@intFromEnum(at(3))])));
        try testing.expectEqual(@as(u64, @bitCast(x)) >> k, regs[@intFromEnum(at(4))]);
    };
}

test "peephole: a multiply by a power of two becomes a left shift" {
    const gpa = testing.allocator;
    var f = try testFunc(gpa, 2, 6);
    defer f.deinit(gpa);
    const v = Reg.virt;
    try add(gpa, &f, 1, .{ .load = .{ .rt = v(0), .mem = Mem.frame(.{ .slot = 0 }, 0) } });
    try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(1), .imm = 16 } });
    try add(gpa, &f, 1, .{ .mov_imm = .{ .rd = v(2), .imm = 48 } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .mul, .rd = v(3), .rn = v(0), .rm = v(1) } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .mul, .rd = v(4), .rn = v(1), .rm = v(0) } });
    try add(gpa, &f, 1, .{ .alu = .{ .op = .mul, .rd = v(5), .rn = v(0), .rm = v(2) } });
    for (3..6) |i| try add(gpa, &f, 1, .{ .store = .{ .rt = v(@intCast(i)), .mem = Mem.frame(.{ .slot = 1 }, 0) } });
    try run(gpa, &f);

    const got = f.blocks[1].insts.items;
    try testing.expectEqualDeep(Inst.Op{ .shift_imm = .{ .op = .lsl, .rd = v(3), .rn = v(0), .amt = 4 } }, got[2].op);
    try testing.expectEqualDeep(Inst.Op{ .shift_imm = .{ .op = .lsl, .rd = v(4), .rn = v(0), .amt = 4 } }, got[3].op);
    try testing.expect(got[4].op == .alu);
    for (got) |i| try testing.expect(!(i.op == .mov_imm and i.op.mov_imm.rd == v(1)));
}

test "peephole: a cset the block's cbnz reads becomes a b.cond on the flags" {
    const gpa = testing.allocator;
    const Case = struct { also_stored: bool, between: bool, fused: bool, cset_left: bool };
    for ([_]Case{
        .{ .also_stored = false, .between = false, .fused = true, .cset_left = false },
        .{ .also_stored = true, .between = false, .fused = true, .cset_left = true },
        // Another compare between them.
        .{ .also_stored = false, .between = true, .fused = false, .cset_left = true },
    }) |c| {
        var f = try testFunc(gpa, 4, 4);
        defer f.deinit(gpa);
        const v = Reg.virt;
        try add(gpa, &f, 1, .{ .load = .{ .rt = v(0), .mem = Mem.frame(.{ .slot = 0 }, 0) } });
        try add(gpa, &f, 1, .{ .load = .{ .rt = v(1), .mem = Mem.frame(.{ .slot = 1 }, 0) } });
        try add(gpa, &f, 1, .{ .cmp = .{ .rn = v(0), .rm = v(1) } });
        try add(gpa, &f, 1, .{ .cset = .{ .rd = v(2), .cond = .lt } });
        if (c.also_stored) try add(gpa, &f, 1, .{ .store = .{ .rt = v(2), .mem = Mem.frame(.{ .slot = 2 }, 0) } });
        if (c.between) try add(gpa, &f, 1, .{ .cmp = .{ .rn = v(1), .rm = v(0) } });
        try add(gpa, &f, 1, .safepoint_poll);
        try add(gpa, &f, 1, .{ .cbnz = .{ .rn = v(2), .target = 2 } });
        try add(gpa, &f, 1, .{ .b = 3 });
        try run(gpa, &f);
        const got = f.blocks[1].insts.items;
        const br = got[got.len - 2].op;
        if (c.fused) {
            try testing.expectEqualDeep(Inst.Op{ .b_cond = .{ .cond = .lt, .target = 2 } }, br);
        } else try testing.expect(br == .cbnz);
        var has_cset = false;
        for (got) |i| has_cset = has_cset or i.op == .cset;
        try testing.expectEqual(c.cset_left, has_cset);
    }
}
