//! An AArch64 MIR instruction: one target operation over `Mir.Reg`s, plus its source line.
//! Most ops are one machine instruction; `mov_imm`, `add_imm`, `copy`, `sym_addr`, `call`
//! and a memory access whose offset leaves the immediate expand into a few, using only
//! the encoder's reserved scratch registers (`Emit`). The allocator sees an op only
//! through `operands` and `callRegs`.

const std = @import("std");
const Mir = @import("../Mir.zig");
const Ir = @import("../../../ir/Ir.zig");
const Aarch64 = @import("../../Aarch64.zig");

const Reg = Mir.Reg;
const Mem = Mir.Mem;
const Inst = @This();

op: Op,
line: u32 = Ir.no_line,

pub const Cond = Aarch64.Cond;
pub const Shift = Aarch64.Shift;

pub const AluOp = enum { add, adds, sub, mul, sdiv, udiv, @"and", orr, eor, lslv, lsrv, asrv, smulh, umulh };
pub const ShiftedOp = enum { add, sub };
pub const UnaryOp = enum { neg, mvn, sxtb, sxth, sxtw, uxtb, uxth, uxtw, asr63 };
pub const FpAluOp = enum { fadd, fsub, fmul, fdiv };
/// `scvtf`: int to float, `fcvtzs`: float to int, `fcvt`: between the float widths; the
/// source or result width is in `single`.
pub const CvtOp = enum { scvtf, fcvtzs, fcvt };
/// The bytes a load or store moves. A narrow GPR load zero-extends unless `signed`; an FP
/// register moves 8 or, as a float32, 4.
pub const Size = enum { b1, b2, b4, b8 };

pub const SymTarget = union(enum) {
    cstr: u64,
    /// Borrowed from the IR, which outlives the MIR.
    func: Ir.SymName,
    /// A byte offset into the image's zero-fill `__bss`.
    data: u32,
};

pub const Callee = union(enum) {
    func: Ir.SymName,
    /// A dyld symbol, reached through its GOT slot in x16.
    import: []const u8,
    reg: Reg,
};

pub const Op = union(enum) {
    mov_imm: struct { rd: Reg, imm: i64 },
    /// A copy between any two registers; across files it moves the raw bits. `single`
    /// moves a float32: FP to FP zeroes the upper bits, FP to GPR zero-extends.
    mov: struct { rd: Reg, rn: Reg, single: bool = false },
    alu: struct { op: AluOp, rd: Reg, rn: Reg, rm: Reg },
    /// rd = ra - rn * rm.
    msub: struct { rd: Reg, rn: Reg, rm: Reg, ra: Reg },
    add_imm: struct { rd: Reg, rn: Reg, imm: u32 },
    sub_imm: struct { rd: Reg, rn: Reg, imm: u12 },
    /// rd = rn op (rm shifted by `amt`).
    alu_sh: struct { op: ShiftedOp, rd: Reg, rn: Reg, rm: Reg, shift: Shift, amt: u6 },
    shift_imm: struct { op: Shift, rd: Reg, rn: Reg, amt: u6 },
    unary: struct { op: UnaryOp, rd: Reg, rn: Reg },
    cmp: struct { rn: Reg, rm: Reg },
    cmp_imm: struct { rn: Reg, imm: u12 },
    /// The flags of `rn + imm`.
    cmn_imm: struct { rn: Reg, imm: u12 },
    cset: struct { rd: Reg, cond: Cond },
    csel: struct { rd: Reg, rn: Reg, rm: Reg, cond: Cond },
    fp_alu: struct { op: FpAluOp, rd: Reg, rn: Reg, rm: Reg, single: bool },
    fcmp: struct { rn: Reg, rm: Reg, single: bool },
    cvt: struct { op: CvtOp, rd: Reg, rn: Reg, single: bool },
    load: struct { rt: Reg, mem: Mem, size: Size = .b8, signed: bool = false },
    store: struct { rt: Reg, mem: Mem, size: Size = .b8 },
    /// rd = the address of `mem`.
    addr: struct { rd: Reg, mem: Mem },
    /// `size` bytes, rounded up to whole words, with no branch in between.
    copy: struct { dst: Mem, src: Mem, size: u32 },
    sym_addr: struct { rd: Reg, target: SymTarget },
    /// Reads the physical registers in `uses`, writes those in `defs`, clobbers every
    /// caller-saved register. A safepoint unless the callee is known never to reach the
    /// collector.
    call: struct {
        callee: Callee,
        uses: Mir.RegSet = 0,
        defs: Mir.RegSet = 0,
        safepoint: bool = true,
    },
    /// Holds a value live to here without reading it (`Operand.Kind.keep`). Encodes to
    /// nothing; the allocator drops it.
    keep: Reg,
    brk,
    /// Where a loop back edge polls for a pending safepoint (#83). Encodes to nothing.
    safepoint_poll,
    b: u32,
    cbnz: struct { rn: Reg, target: u32 },
    b_cond: struct { cond: Cond, target: u32 },
    /// The epilogue and `ret`.
    ret,
};

/// The registers a call may overwrite under AAPCS64 (Apple keeps x18): x0-x17, x30,
/// v0-v7 and v16-v31.
pub const caller_saved: Mir.RegSet = blk: {
    var s: Mir.RegSet = 0;
    for (0..18) |n| s |= Mir.regBit(Reg.gp(n));
    s |= Mir.regBit(Reg.gp(30));
    for (0..8) |n| s |= Mir.regBit(Reg.fp(n));
    for (16..32) |n| s |= Mir.regBit(Reg.fp(n));
    break :blk s;
};

pub fn callRegs(inst: Inst) ?Mir.CallRegs {
    return switch (inst.op) {
        .call => |c| .{ .uses = c.uses, .defs = c.defs, .clobbers = caller_saved, .safepoint = c.safepoint },
        else => null,
    };
}

/// The block a branch jumps to, or null for any other instruction.
pub fn branchTarget(inst: Inst) ?u32 {
    return switch (inst.op) {
        .b => |t| t,
        .cbnz => |c| c.target,
        .b_cond => |c| c.target,
        else => null,
    };
}

pub fn setBranchTarget(inst: *Inst, target: u32) void {
    switch (inst.op) {
        .b => |*t| t.* = target,
        .cbnz => |*c| c.target = target,
        .b_cond => |*c| c.target = target,
        else => unreachable,
    }
}

/// The registers of a whole-register copy within one file, which an allocator may
/// coalesce and drop once both sides share a register.
pub fn copyRegs(inst: Inst) ?struct { dst: Reg, src: Reg } {
    return switch (inst.op) {
        .mov => |m| if (m.single) null else .{ .dst = m.rd, .src = m.rn },
        else => null,
    };
}

pub fn operands(inst: *Inst, buf: *[Mir.max_operands]Mir.Operand) []Mir.Operand {
    var n: usize = 0;
    const B = struct {
        fn add(b: *[Mir.max_operands]Mir.Operand, len: *usize, r: *Reg, kind: Mir.Operand.Kind) void {
            b[len.*] = .{ .reg = r, .kind = kind };
            len.* += 1;
        }
        fn mem(b: *[Mir.max_operands]Mir.Operand, len: *usize, m: *Mem) void {
            switch (m.base) {
                .reg => |*r| add(b, len, r, .use),
                .frame => {},
            }
        }
    };
    switch (inst.op) {
        .mov_imm => |*o| B.add(buf, &n, &o.rd, .def),
        .mov => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .alu => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .msub => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
            B.add(buf, &n, &o.ra, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .add_imm => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .sub_imm => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .alu_sh => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .shift_imm => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .unary => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .cmp => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
        },
        .cmp_imm => |*o| B.add(buf, &n, &o.rn, .use),
        .cmn_imm => |*o| B.add(buf, &n, &o.rn, .use),
        .cset => |*o| B.add(buf, &n, &o.rd, .def),
        .csel => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .fp_alu => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .fcmp => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rm, .use);
        },
        .cvt => |*o| {
            B.add(buf, &n, &o.rn, .use);
            B.add(buf, &n, &o.rd, .def);
        },
        .load => |*o| {
            B.mem(buf, &n, &o.mem);
            B.add(buf, &n, &o.rt, .def);
        },
        .store => |*o| {
            B.add(buf, &n, &o.rt, .use);
            B.mem(buf, &n, &o.mem);
        },
        .addr => |*o| {
            B.mem(buf, &n, &o.mem);
            B.add(buf, &n, &o.rd, .def);
        },
        .copy => |*o| {
            B.mem(buf, &n, &o.dst);
            B.mem(buf, &n, &o.src);
        },
        .sym_addr => |*o| B.add(buf, &n, &o.rd, .def),
        .call => |*o| switch (o.callee) {
            .reg => |*r| B.add(buf, &n, r, .use),
            .func, .import => {},
        },
        .cbnz => |*o| B.add(buf, &n, &o.rn, .use),
        .keep => |*r| B.add(buf, &n, r, .keep),
        .brk, .safepoint_poll, .b, .b_cond, .ret => {},
    }
    return buf[0..n];
}

test "operands: uses before defs, memory bases are uses, calls name only a register callee" {
    var buf: [Mir.max_operands]Mir.Operand = undefined;
    var add: Inst = .{ .op = .{ .alu = .{ .op = .add, .rd = Reg.virt(2), .rn = Reg.virt(0), .rm = Reg.virt(1) } } };
    const ops = add.operands(&buf);
    try std.testing.expectEqual(@as(usize, 3), ops.len);
    try std.testing.expectEqual(Mir.Operand.Kind.def, ops[2].kind);
    try std.testing.expectEqual(Reg.virt(2), ops[2].reg.*);

    var st: Inst = .{ .op = .{ .store = .{ .rt = Reg.virt(0), .mem = Mem.reg(Reg.virt(1), 8) } } };
    for (st.operands(&buf)) |o| try std.testing.expectEqual(Mir.Operand.Kind.use, o.kind);

    var frame_load: Inst = .{ .op = .{ .load = .{ .rt = Reg.virt(3), .mem = Mem.frame(.{ .slot = 0 }, 0) } } };
    try std.testing.expectEqual(@as(usize, 1), frame_load.operands(&buf).len);

    var call: Inst = .{ .op = .{ .call = .{ .callee = .{ .func = .{ .kind = .user_fn, .name = "f" } } } } };
    try std.testing.expect(call.callRegs() != null);
    try std.testing.expectEqual(@as(usize, 0), call.operands(&buf).len);
    try std.testing.expect(caller_saved & Mir.regBit(Reg.gp(19)) == 0);
    try std.testing.expect(caller_saved & Mir.regBit(Reg.fp(17)) != 0);
}

test "callRegsAgree: argument and result registers must match the call's sets" {
    const gpa = std.testing.allocator;
    const F = Mir.Function(Inst);
    const x0 = Reg.gp(0);
    const x1 = Reg.gp(1);
    const d0 = Reg.fp(0);
    const f_sym: Callee = .{ .func = .{ .kind = .user_fn, .name = "f" } };
    const Case = struct { ok: bool, uses: Mir.RegSet, defs: Mir.RegSet, read: Reg };
    const cases = [_]Case{
        .{ .ok = true, .uses = Mir.regBit(x0) | Mir.regBit(d0), .defs = Mir.regBit(x0) | Mir.regBit(x1), .read = x1 },
        // d0 is written for the call but missing from its uses.
        .{ .ok = false, .uses = Mir.regBit(x0), .defs = Mir.regBit(x0) | Mir.regBit(x1), .read = x1 },
        // x1 is read after the call, which defines only x0.
        .{ .ok = false, .uses = Mir.regBit(x0) | Mir.regBit(d0), .defs = Mir.regBit(x0), .read = x1 },
    };
    for (cases) |c| {
        var f = try F.init(gpa, 2);
        defer f.deinit(gpa);
        const a = try f.newVReg(gpa, .gpr, .{ .value = 0 });
        const b = try f.newVReg(gpa, .fpr, .{ .value = 1 });
        const insts = &f.blocks[1].insts;
        try insts.append(gpa, .{ .op = .{ .mov = .{ .rd = x0, .rn = a } } });
        try insts.append(gpa, .{ .op = .{ .mov = .{ .rd = d0, .rn = b } } });
        try insts.append(gpa, .{ .op = .{ .call = .{ .callee = f_sym, .uses = c.uses, .defs = c.defs } } });
        try insts.append(gpa, .{ .op = .{ .mov = .{ .rd = a, .rn = c.read } } });
        try std.testing.expectEqual(c.ok, f.callRegsAgree(~caller_saved));
    }

    // Outside block 0 a caller-saved register must be written in the block before it is read.
    var f = try F.init(gpa, 2);
    defer f.deinit(gpa);
    const a = try f.newVReg(gpa, .gpr, .{ .value = 0 });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .mov = .{ .rd = a, .rn = x0 } } });
    try std.testing.expect(f.callRegsAgree(~caller_saved));
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .mov = .{ .rd = a, .rn = x0 } } });
    try std.testing.expect(!f.callRegsAgree(~caller_saved));
}
