//! AArch64 instruction selection: `Ir.Function` to MIR on virtual registers.
//!
//! Each scalar IR value becomes the virtual register of the same index (linear scan gives
//! it a slot only if it spills). Aggregate IR values (a merge of a str/struct/enum) stay
//! memory: their bytes live in their cell and the selector copies them. A value shape the
//! selector does not cover (an aggregate or unit value where a scalar register is needed,
//! or a value with no memory where an address is) fails with `error.Unsupported`, which the
//! build reports as an internal error.
//!
//! The calling convention comes from `Abi`. Argument and result registers appear as
//! physical operands next to the virtual ones; the selector never names x9-x15 or v16-v18,
//! which belong to the allocator's and encoder's scratch.
//!
//! GC facts for the allocator (which values are references, which calls are safepoints,
//! what a call keeps rooted) come from `GcFacts`, shared by every target.

const std = @import("std");
const Ir = @import("../../../ir/Ir.zig");
const Abi = @import("../../abi/Abi.zig");
const FrameLayout = @import("../../frame/FrameLayout.zig");
const Link = @import("../../../link/Link.zig");
const types = @import("../../../types.zig");
const Aarch64 = @import("../../Aarch64.zig");
const Mir = @import("../Mir.zig");
const GcFacts = @import("../GcFacts.zig");
const Inst = @import("Inst.zig");

const Type = types.Type;
const Reg = Mir.Reg;
const Mem = Mir.Mem;

pub const Func = Mir.Function(Inst);

pub const Error = error{ OutOfMemory, Unsupported };

pub const Input = struct {
    ir: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
    is_entry: bool,
    fl: *const FrameLayout,
    roots: []const FrameLayout.Root,
};

/// An empty MIR fn for `ir`: one block per IR block, after the prologue block.
pub fn newFunc(gpa: std.mem.Allocator, ir: *const Ir.Function) error{OutOfMemory}!Func {
    return Func.init(gpa, ir.blocks.len + 1);
}

/// Select `in.ir` into `f` (from `newFunc(in.ir)`).
/// Panic messages join `literals`.
pub fn select(gpa: std.mem.Allocator, in: Input, f: *Func, literals: *std.ArrayList(Link.Literal)) Error!void {
    var s: S = .{ .gpa = gpa, .in = in, .ir = in.ir, .f = f, .literals = literals };
    return s.run();
}

const S = struct {
    gpa: std.mem.Allocator,
    in: Input,
    ir: *const Ir.Function,
    f: *Func,
    literals: *std.ArrayList(Link.Literal),
    block: u32 = 0,
    line: u32 = Ir.no_line,
    /// An aggregate value the current instruction writes as a scalar (`def`).
    pending: ?struct { t: Reg, v: Ir.ValueId } = null,

    fn emit(s: *S, op: Inst.Op) error{OutOfMemory}!void {
        try s.f.blocks[s.block].insts.append(s.gpa, .{ .op = op, .line = s.line });
    }

    fn temp(s: *S, class: Mir.RegClass) error{OutOfMemory}!Reg {
        return s.f.newVReg(s.gpa, class, null);
    }

    fn valueType(s: *const S, v: Ir.ValueId) Type {
        return s.ir.values[v].type;
    }

    fn isScalar(ty: Type) bool {
        return ty.kind != .unit and !Abi.isAggregate(ty);
    }

    /// A register holding IR value `v`. An aggregate value read as a scalar is the first
    /// word of its cell.
    fn val(s: *S, v: Ir.ValueId) Error!Reg {
        const ty = s.valueType(v);
        if (ty.kind == .unit) return error.Unsupported;
        if (isScalar(ty)) return Reg.virt(v);
        const t = try s.temp(.gpr);
        try s.emit(.{ .load = .{ .rt = t, .mem = Mem.frame(.{ .value = v }, 0) } });
        return t;
    }

    /// The register an instruction writes IR value `v` to. An aggregate value written as a
    /// scalar goes through a temporary into the first word of its cell, by `flush`.
    fn def(s: *S, v: Ir.ValueId) Error!Reg {
        const ty = s.valueType(v);
        if (ty.kind == .unit) return error.Unsupported;
        if (isScalar(ty)) return Reg.virt(v);
        std.debug.assert(s.pending == null);
        const t = try s.temp(.gpr);
        s.pending = .{ .t = t, .v = v };
        return t;
    }

    fn flush(s: *S) error{OutOfMemory}!void {
        const p = s.pending orelse return;
        s.pending = null;
        try s.emit(.{ .store = .{ .rt = p.t, .mem = Mem.frame(.{ .value = p.v }, 0) } });
    }

    fn typeSize(s: *const S, ty: Type) u32 {
        return Abi.typeSize(ty, s.in.layouts, s.in.enum_layouts);
    }

    /// Where the bytes of an aggregate operand live, or null for a scalar or unit one.
    fn memOf(s: *const S, op: Ir.Operand) ?Mem {
        return switch (op) {
            .slot => |sl| Mem.frame(.{ .slot = sl }, 0),
            .value => |v| if (isScalar(s.valueType(v))) null else Mem.frame(.{ .value = v }, 0),
            .none => null,
        };
    }

    fn run(s: *S) Error!void {
        // Lower makes the entry block 0 and branch compaction keeps it lowest, and the
        // prologue block falls into MIR block 1.
        std.debug.assert(s.ir.entry == 0);
        const refs = try GcFacts.valueRefs(s.gpa, s.ir, s.in.layouts, s.in.enum_layouts);
        defer s.gpa.free(refs);
        for (s.ir.values, refs, 0..) |vd, ref, i| {
            const class: Mir.RegClass = if (vd.type.kind == .float) .fpr else .gpr;
            const r = try s.f.newVReg(s.gpa, class, .{ .value = @intCast(i) });
            s.f.vregs.items[r.index()].ref = ref;
        }

        s.line = s.ir.line;
        try s.prologue();
        try s.emit(.{ .b = 1 });

        for (s.ir.blocks, 0..) |*blk, bid| {
            s.block = @intCast(bid + 1);
            for (blk.instrs) |ins| {
                s.line = ins.line;
                try s.instr(ins);
                try s.flush();
            }
            s.line = blk.term_line;
            try s.term(blk.term, @intCast(bid));
        }
    }

    fn prologue(s: *S) Error!void {
        for (s.in.roots, 0..) |r, i| {
            if (r.tag != .container) continue;
            const seen = for (s.in.roots[0..i]) |o| {
                if (o.off == r.off and o.tag == .container) break true;
            } else false;
            if (!seen) try s.emit(.{ .store = .{ .rt = Reg.gp(Aarch64.XZR), .mem = Mem.frame(.{ .layout = r.off }, 0) } });
        }
        if (s.in.fl.sret_save_off != FrameLayout.NO_SRET)
            try s.emit(.{ .store = .{ .rt = Reg.gp(8), .mem = Mem.frame(.sret_save, 0) } });

        var param_types: std.ArrayList(Type) = .empty;
        defer param_types.deinit(s.gpa);
        for (s.ir.params) |sid| try param_types.append(s.gpa, s.ir.slots[sid].type);
        var plan = try Abi.planParamsConv(s.gpa, FrameLayout.convOf(s.ir), param_types.items, s.ir.ret_type, s.in.layouts, s.in.enum_layouts);
        defer plan.deinit(s.gpa);
        for (plan.locs, s.ir.params) |loc, sid| {
            const slot = Mir.FrameRef{ .slot = sid };
            const ty = s.ir.slots[sid].type;
            if (s.ir.c_abi) {
                try s.cParam(loc, slot, ty);
                continue;
            }
            switch (loc) {
                .gpr => |r| for (0..r.count) |k| {
                    try s.emit(.{ .store = .{ .rt = Reg.gp(r.first + @as(u32, @intCast(k))), .mem = Mem.frame(slot, @intCast(k * 8)) } });
                },
                .fpr => |v| try s.emit(.{ .store = .{ .rt = Reg.fp(v), .mem = Mem.frame(slot, 0) } }),
                .gpr_ptr => |r| try s.emit(.{ .copy = .{ .dst = Mem.frame(slot, 0), .src = Mem.reg(Reg.gp(r), 0), .size = s.typeSize(ty) } }),
                .stack => |st| {
                    var k: u32 = 0;
                    while (k < st.bytes) : (k += 8) {
                        const t = try s.temp(.gpr);
                        try s.emit(.{ .load = .{ .rt = t, .mem = Mem.frame(.incoming, st.nsaa_off + k) } });
                        try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(slot, k) } });
                    }
                },
                .stack_ptr => |off| {
                    const t = try s.temp(.gpr);
                    try s.emit(.{ .load = .{ .rt = t, .mem = Mem.frame(.incoming, off) } });
                    try s.emit(.{ .copy = .{ .dst = Mem.frame(slot, 0), .src = Mem.reg(t, 0), .size = s.typeSize(ty) } });
                },
                .zero => {},
                .fpr_run => unreachable,
            }
        }
    }

    /// A C callback's param, which C passed in its convention, into its slot as toy keeps
    /// it: a narrow int or bool extended, a float32 zero-extended, an extern struct unpacked
    /// from its C image (in registers, on the stack or behind a pointer).
    fn cParam(s: *S, loc: Abi.ParamLoc, slot: Mir.FrameRef, ty: Type) Error!void {
        const img = Mem.frame(.c_scratch, 0);
        if (Abi.isCStruct(ty, s.in.layouts)) {
            switch (loc) {
                .gpr => |r| {
                    for (0..r.count) |k| try s.emit(.{ .store = .{ .rt = Reg.gp(r.first + @as(u32, @intCast(k))), .mem = Mem.frame(.c_scratch, @intCast(k * 8)) } });
                    try s.unpackC(ty, img, Mem.frame(slot, 0));
                },
                .fpr_run => |r| {
                    const size: Inst.Size = if (r.single) .b4 else .b8;
                    const elem: u32 = if (r.single) 4 else 8;
                    for (0..r.count) |k| try s.emit(.{ .store = .{ .rt = Reg.fp(r.first + @as(u32, @intCast(k))), .mem = Mem.frame(.c_scratch, @as(u32, @intCast(k)) * elem), .size = size } });
                    try s.unpackC(ty, img, Mem.frame(slot, 0));
                },
                .gpr_ptr => |r| try s.unpackC(ty, Mem.reg(Reg.gp(r), 0), Mem.frame(slot, 0)),
                .stack => |st| try s.unpackC(ty, Mem.frame(.incoming, st.nsaa_off), Mem.frame(slot, 0)),
                .stack_ptr => |off| {
                    const p = try s.temp(.gpr);
                    try s.emit(.{ .load = .{ .rt = p, .mem = Mem.frame(.incoming, off) } });
                    try s.unpackC(ty, Mem.reg(p, 0), Mem.frame(slot, 0));
                },
                .fpr, .zero => unreachable,
            }
            return;
        }
        switch (loc) {
            .gpr => |r| {
                try s.emit(.{ .store = .{ .rt = Reg.gp(r.first), .mem = Mem.frame(slot, 0) } });
                if (Abi.cScalarSize(ty) < 8) {
                    const t = try s.temp(.gpr);
                    try s.loadC(t, Mem.frame(slot, 0), ty);
                    try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(slot, 0) } });
                }
            },
            .fpr => |v| if (ty.isFloat32()) {
                const t = try s.temp(.gpr);
                try s.emit(.{ .mov = .{ .rd = t, .rn = Reg.fp(v), .single = true } });
                try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(slot, 0) } });
            } else try s.emit(.{ .store = .{ .rt = Reg.fp(v), .mem = Mem.frame(slot, 0) } }),
            .stack => |st| {
                const t = try s.temp(.gpr);
                try s.loadC(t, Mem.frame(.incoming, st.nsaa_off), ty);
                try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(slot, 0) } });
            },
            .zero => {},
            .gpr_ptr, .stack_ptr, .fpr_run => unreachable,
        }
    }

    fn at(m: Mem, off: u32) Mem {
        return .{ .base = m.base, .off = m.off + off };
    }

    /// Load the C scalar of type `ty` at `m` into `rt` as toy keeps it: a narrow signed int
    /// sign-extended, an unsigned one, a bool or a float32's bits zero-extended.
    fn loadC(s: *S, rt: Reg, m: Mem, ty: Type) error{OutOfMemory}!void {
        const size: Inst.Size = switch (Abi.cScalarSize(ty)) {
            1 => .b1,
            2 => .b2,
            4 => .b4,
            else => .b8,
        };
        try s.emit(.{ .load = .{ .rt = rt, .mem = m, .size = size, .signed = ty.isSigned() } });
    }

    /// Copy the extern struct `ty` from its toy layout at `src` into its C layout at `dst`.
    fn packC(s: *S, ty: Type, src: Mem, dst: Mem) error{OutOfMemory}!void {
        const l = s.in.layouts[ty.struct_id];
        for (l.field_types, l.offsets, 0..) |f, toff, i| {
            const coff = Abi.cFieldOffset(ty, i, s.in.layouts);
            if (Abi.isCStruct(f, s.in.layouts)) {
                try s.packC(f, at(src, toff), at(dst, coff));
                continue;
            }
            const t = try s.temp(.gpr);
            try s.emit(.{ .load = .{ .rt = t, .mem = at(src, toff) } });
            const size: Inst.Size = switch (Abi.cScalarSize(f)) {
                1 => .b1,
                2 => .b2,
                4 => .b4,
                else => .b8,
            };
            try s.emit(.{ .store = .{ .rt = t, .mem = at(dst, coff), .size = size } });
        }
    }

    /// The inverse of `packC`: the C layout at `src` into the toy layout at `dst`.
    fn unpackC(s: *S, ty: Type, src: Mem, dst: Mem) error{OutOfMemory}!void {
        const l = s.in.layouts[ty.struct_id];
        for (l.field_types, l.offsets, 0..) |f, toff, i| {
            const coff = Abi.cFieldOffset(ty, i, s.in.layouts);
            if (Abi.isCStruct(f, s.in.layouts)) {
                try s.unpackC(f, at(src, coff), at(dst, toff));
                continue;
            }
            const t = try s.temp(.gpr);
            try s.loadC(t, at(src, coff), f);
            try s.emit(.{ .store = .{ .rt = t, .mem = at(dst, toff) } });
        }
    }

    /// Re-canonicalize a narrow integer in `r` to its width (`opt/arith.zig` folds the
    /// same value).
    fn normalize(s: *S, r: Reg, ty: Type) error{OutOfMemory}!void {
        if (!ty.isInteger()) return;
        const op: Inst.UnaryOp = switch (ty.int_desc.width) {
            .plat, .w64 => return,
            .w8 => if (ty.int_desc.signed) .sxtb else .uxtb,
            .w16 => if (ty.int_desc.signed) .sxth else .uxth,
            .w32 => if (ty.int_desc.signed) .sxtw else .uxtw,
        };
        try s.emit(.{ .unary = .{ .op = op, .rd = r, .rn = r } });
    }

    fn alu(s: *S, result: Ir.ValueId, b: Ir.Bin, op: Inst.AluOp) Error!void {
        const d = try s.def(result);
        try s.emit(.{ .alu = .{ .op = op, .rd = d, .rn = try s.val(b.lhs), .rm = try s.val(b.rhs) } });
        try s.normalize(d, s.valueType(result));
    }

    fn instr(s: *S, ins: Ir.Instr) Error!void {
        const res = ins.result;
        switch (ins.op) {
            .iconst => |v| try s.emit(.{ .mov_imm = .{ .rd = try s.def(res), .imm = v } }),
            .bconst => |v| try s.emit(.{ .mov_imm = .{ .rd = try s.def(res), .imm = @intFromBool(v) } }),
            .unit => {},
            .add => |b| try s.alu(res, b, .add),
            .sub => |b| try s.alu(res, b, .sub),
            .mul => |b| try s.alu(res, b, .mul),
            .sdiv => |b| try s.alu(res, b, .sdiv),
            .udiv => |b| try s.alu(res, b, .udiv),
            .band => |b| try s.alu(res, b, .@"and"),
            .bor => |b| try s.alu(res, b, .orr),
            .bxor => |b| try s.alu(res, b, .eor),
            .smod, .umod => |b| {
                const d = try s.def(res);
                const q = try s.temp(.gpr);
                const lhs = try s.val(b.lhs);
                const rhs = try s.val(b.rhs);
                try s.emit(.{ .alu = .{ .op = if (ins.op == .smod) .sdiv else .udiv, .rd = q, .rn = lhs, .rm = rhs } });
                try s.emit(.{ .msub = .{ .rd = d, .rn = q, .rm = rhs, .ra = lhs } });
                try s.normalize(d, s.valueType(res));
            },
            .neg, .bcompl => |v| {
                const d = try s.def(res);
                try s.emit(.{ .unary = .{ .op = if (ins.op == .neg) .neg else .mvn, .rd = d, .rn = try s.val(v) } });
                try s.normalize(d, s.valueType(res));
            },
            .bnot => |v| {
                try s.emit(.{ .cmp_imm = .{ .rn = try s.val(v), .imm = 0 } });
                try s.emit(.{ .cset = .{ .rd = try s.def(res), .cond = .eq } });
            },
            .icmp => |c| {
                try s.emit(.{ .cmp = .{ .rn = try s.val(c.lhs), .rm = try s.val(c.rhs) } });
                try s.emit(.{ .cset = .{ .rd = try s.def(res), .cond = condOf(c.cc) } });
            },
            .slot_addr => |sid| try s.emit(.{ .addr = .{ .rd = try s.def(res), .mem = Mem.frame(.{ .slot = sid }, 0) } }),
            .field_addr => |fa| {
                const d = try s.def(res);
                const base = try s.val(fa.base);
                try s.emit(if (fa.off == 0) .{ .mov = .{ .rd = d, .rn = base } } else .{ .add_imm = .{ .rd = d, .rn = base, .imm = fa.off } });
            },
            .load => |l| try s.emit(.{ .load = .{ .rt = try s.def(res), .mem = Mem.reg(try s.val(l.addr), 0) } }),
            .load_byte => |a| try s.emit(.{ .load = .{ .rt = try s.def(res), .mem = Mem.reg(try s.val(a), 0), .size = .b1 } }),
            .get_tag => |a| try s.emit(.{ .load = .{ .rt = try s.def(res), .mem = Mem.reg(try s.val(a), 0) } }),
            .store => |st| try s.emit(.{ .store = .{ .rt = try s.val(st.val), .mem = Mem.reg(try s.val(st.addr), 0) } }),
            .store_byte => |st| try s.emit(.{ .store = .{ .rt = try s.val(st.val), .mem = Mem.reg(try s.val(st.addr), 0), .size = .b1 } }),
            .copy => |c| try s.emit(.{ .copy = .{ .dst = Mem.reg(try s.val(c.dst), 0), .src = Mem.reg(try s.val(c.src), 0), .size = s.typeSize(c.ty) } }),
            .cstr_ptr => |h| try s.emit(.{ .sym_addr = .{ .rd = try s.def(res), .target = .{ .cstr = h } } }),
            .fn_addr => |sym| try s.emit(.{ .sym_addr = .{ .rd = try s.def(res), .target = .{ .func = sym } } }),
            .data_addr => |off| try s.emit(.{ .sym_addr = .{ .rd = try s.def(res), .target = .{ .data = off } } }),
            // x29 is the incoming-args base less the 16 bytes of the saved x29/x30, so the
            // frame record needs no physical register in the allocator's view.
            .frame_addr => {
                const rd = try s.def(res);
                try s.emit(.{ .addr = .{ .rd = rd, .mem = Mem.frame(.incoming, 0) } });
                try s.emit(.{ .sub_imm = .{ .rd = rd, .rn = rd, .imm = 16 } });
            },
            .shl, .lshr, .ashr => |b| try s.shift(res, b, ins.op),
            .fconst => |v| {
                const bits: i64 = if (s.valueType(res).isFloat32()) @as(u32, @bitCast(@as(f32, @floatCast(v)))) else @bitCast(v);
                const t = try s.temp(.gpr);
                try s.emit(.{ .mov_imm = .{ .rd = t, .imm = bits } });
                try s.emit(.{ .mov = .{ .rd = try s.def(res), .rn = t } });
            },
            .fadd => |b| try s.fpAlu(res, b, .fadd),
            .fsub => |b| try s.fpAlu(res, b, .fsub),
            .fmul => |b| try s.fpAlu(res, b, .fmul),
            .fdiv => |b| try s.fpAlu(res, b, .fdiv),
            .fcmp => |c| {
                try s.emit(.{ .fcmp = .{ .rn = try s.val(c.lhs), .rm = try s.val(c.rhs), .single = s.valueType(c.lhs).isFloat32() } });
                try s.emit(.{ .cset = .{ .rd = try s.def(res), .cond = fcondOf(c.cc) } });
            },
            .scvtf => |v| try s.emit(.{ .cvt = .{ .op = .scvtf, .rd = try s.def(res), .rn = try s.val(v), .single = s.valueType(res).isFloat32() } }),
            .fcvtzs => |v| try s.emit(.{ .cvt = .{ .op = .fcvtzs, .rd = try s.def(res), .rn = try s.val(v), .single = s.valueType(v).isFloat32() } }),
            .fcvt => |v| try s.emit(.{ .cvt = .{ .op = .fcvt, .rd = try s.def(res), .rn = try s.val(v), .single = s.valueType(v).isFloat32() } }),
            .overflow => |o| try s.overflow(res, o),
            .call => |c| try s.call(res, c),
            .call_indirect => |c| try s.callIndirect(res, c),
        }
    }

    fn fpAlu(s: *S, res: Ir.ValueId, b: Ir.Bin, op: Inst.FpAluOp) Error!void {
        try s.emit(.{ .fp_alu = .{ .op = op, .rd = try s.def(res), .rn = try s.val(b.lhs), .rm = try s.val(b.rhs), .single = s.valueType(res).isFloat32() } });
    }

    /// Go semantics: an amount of the width or more gives 0 (or the sign fill), which the
    /// register-amount shifts, masking the amount mod 64, would not.
    fn shift(s: *S, res: Ir.ValueId, b: Ir.Bin, op: std.meta.Tag(Ir.Op)) Error!void {
        const ty = s.valueType(res);
        const width: u12 = @intCast(ty.intBits());
        const d = try s.def(res);
        const lhs = try s.val(b.lhs);
        const amt = try s.val(b.rhs);
        const zr = Reg.gp(Aarch64.XZR);
        if (op == .ashr) {
            const raw = try s.temp(.gpr);
            try s.emit(.{ .alu = .{ .op = .asrv, .rd = raw, .rn = lhs, .rm = amt } });
            try s.emit(.{ .unary = .{ .op = .asr63, .rd = d, .rn = lhs } });
            try s.emit(.{ .cmp_imm = .{ .rn = amt, .imm = width } });
            try s.emit(.{ .csel = .{ .rd = d, .rn = d, .rm = raw, .cond = .hs } });
        } else {
            try s.emit(.{ .alu = .{ .op = if (op == .shl) .lslv else .lsrv, .rd = d, .rn = lhs, .rm = amt } });
            try s.emit(.{ .cmp_imm = .{ .rn = amt, .imm = width } });
            try s.emit(.{ .csel = .{ .rd = d, .rn = zr, .rm = d, .cond = .hs } });
        }
        try s.normalize(d, ty);
    }

    /// Whether `o.lhs op o.rhs` overflows `o.ty`.
    fn overflow(s: *S, res: Ir.ValueId, o: Ir.Overflow) Error!void {
        const d = try s.def(res);
        const lhs = try s.val(o.lhs);
        const rhs = try s.val(o.rhs);
        const signed = o.ty.int_desc.signed;
        if (o.ty.intBits() < 64) {
            const wide = try s.temp(.gpr);
            const narrow = try s.temp(.gpr);
            try s.emit(.{ .alu = .{ .op = switch (o.kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
            }, .rd = wide, .rn = lhs, .rm = rhs } });
            try s.emit(.{ .mov = .{ .rd = narrow, .rn = wide } });
            try s.normalize(narrow, o.ty);
            try s.emit(.{ .cmp = .{ .rn = wide, .rm = narrow } });
            try s.emit(.{ .cset = .{ .rd = d, .cond = .ne } });
            return;
        }
        switch (o.kind) {
            .add => {
                try s.emit(.{ .alu = .{ .op = .adds, .rd = Reg.gp(Aarch64.XZR), .rn = lhs, .rm = rhs } });
                try s.emit(.{ .cset = .{ .rd = d, .cond = if (signed) .vs else .hs } });
            },
            .sub => {
                try s.emit(.{ .cmp = .{ .rn = lhs, .rm = rhs } });
                try s.emit(.{ .cset = .{ .rd = d, .cond = if (signed) .vs else .lo } });
            },
            .mul => if (signed) {
                const hi = try s.temp(.gpr);
                const lo = try s.temp(.gpr);
                try s.emit(.{ .alu = .{ .op = .smulh, .rd = hi, .rn = lhs, .rm = rhs } });
                try s.emit(.{ .alu = .{ .op = .mul, .rd = lo, .rn = lhs, .rm = rhs } });
                try s.emit(.{ .unary = .{ .op = .asr63, .rd = lo, .rn = lo } });
                try s.emit(.{ .cmp = .{ .rn = hi, .rm = lo } });
                try s.emit(.{ .cset = .{ .rd = d, .cond = .ne } });
            } else {
                const hi = try s.temp(.gpr);
                try s.emit(.{ .alu = .{ .op = .umulh, .rd = hi, .rn = lhs, .rm = rhs } });
                try s.emit(.{ .cmp_imm = .{ .rn = hi, .imm = 0 } });
                try s.emit(.{ .cset = .{ .rd = d, .cond = .ne } });
            },
        }
    }

    fn retType(s: *const S, ret_slot: Ir.SlotId, result: Ir.ValueId) Type {
        if (ret_slot != Ir.none_slot) return s.ir.slots[ret_slot].type;
        if (result != Ir.none_value) return s.valueType(result);
        return Type.unit;
    }

    fn call(s: *S, res: Ir.ValueId, c: Ir.Call) Error!void {
        const conv: Abi.Conv = if (c.callee.kind == .import) .c else .toy;
        const ret_ty = s.retType(c.ret_slot, res);
        var arg_types: std.ArrayList(Type) = .empty;
        defer arg_types.deinit(s.gpa);
        for (0..c.args.len) |i| try arg_types.append(s.gpa, s.ir.argType(c.args, c.params, c.by_ptr, i));
        var plan = try Abi.planCallConv(s.gpa, conv, arg_types.items, c.fixedArgs(), ret_ty, s.in.layouts, s.in.enum_layouts);
        defer plan.deinit(s.gpa);

        // An extern struct crosses in C layout: each one is packed into its image in the C
        // scratch region first, in `FrameLayout.cScratchBytes` order.
        const srcs = try s.gpa.alloc(ArgSrc, if (conv == .c) c.args.len else 0);
        defer s.gpa.free(srcs);
        var img: u32 = 0;
        for (srcs, 0..) |*src, i| {
            src.* = .operand;
            const ty = FrameLayout.cImageType(c, i, s.in.layouts) orelse continue;
            if (Ir.Function.isByPtrArg(c.by_ptr, i)) {
                try s.packC(ty, Mem.reg(try s.val(c.args[i].value), 0), Mem.frame(.c_scratch, img));
                src.* = .{ .image_addr = img };
            } else {
                try s.packC(ty, s.memOf(c.args[i]) orelse return error.Unsupported, Mem.frame(.c_scratch, img));
                src.* = .{ .image = img };
            }
            img += FrameLayout.roundUp16(Abi.cLayout(ty, s.in.layouts).size);
        }
        const c_ret: ?Type = if (conv == .c and c.ret_slot != Ir.none_slot and Abi.isCStruct(ret_ty, s.in.layouts)) ret_ty else null;

        var uses = try s.marshalArgs(c.args, plan, srcs);
        if (plan.sret_in_x8) {
            const buf = if (c_ret != null) Mem.frame(.c_scratch, img) else Mem.frame(.{ .slot = c.ret_slot }, 0);
            try s.emit(.{ .addr = .{ .rd = Reg.gp(8), .mem = buf } });
            uses |= Mir.regBit(Reg.gp(8));
        }
        const callee: Inst.Callee = if (conv == .c) .{ .import = c.callee.name } else .{ .func = c.callee };
        const defs = if (c_ret) |rt| cRetDefs(rt, s.in.layouts) else s.retDefs(ret_ty);
        const facts = GcFacts.callFacts(c.callee);
        try s.emit(.{ .call = .{ .callee = callee, .uses = uses, .defs = defs, .safepoint = facts.safepoint } });
        // A C callee leaves the bits above its result's width unspecified, and toy keeps
        // every value canonical.
        if (conv == .c and res != Ir.none_value) {
            if (ret_ty.kind == .bool)
                try s.emit(.{ .unary = .{ .op = .uxtb, .rd = Reg.gp(0), .rn = Reg.gp(0) } })
            else
                try s.normalize(Reg.gp(0), ret_ty);
        }
        if (c_ret) |rt| {
            // The result's C bytes into its image, then back into toy layout in its slot.
            switch (Abi.cRet(rt, s.in.layouts)) {
                .hfa => |h| for (0..h.count) |k| {
                    const elem: u32 = if (h.single) 4 else 8;
                    try s.emit(.{ .store = .{ .rt = Reg.fp(@intCast(k)), .mem = Mem.frame(.c_scratch, img + @as(u32, @intCast(k)) * elem), .size = if (h.single) .b4 else .b8 } });
                },
                .regs => |n| for (0..n) |k| try s.emit(.{ .store = .{ .rt = Reg.gp(@intCast(k)), .mem = Mem.frame(.c_scratch, img + @as(u32, @intCast(k)) * 8) } }),
                .sret => {},
            }
            try s.unpackC(rt, Mem.frame(.c_scratch, img), Mem.frame(.{ .slot = c.ret_slot }, 0));
        } else try s.placeResult(res, c.ret_slot, ret_ty);
        // Each `mut` extern struct argument back into the variable it points at.
        for (srcs, 0..) |src, i| switch (src) {
            .image_addr => |off| try s.unpackC(c.params[i], Mem.frame(.c_scratch, off), Mem.reg(try s.val(c.args[i].value), 0)),
            else => {},
        };
        if (facts.keep_ref_args and facts.safepoint) for (c.args) |arg| switch (arg) {
            .value => |v| if (s.f.vregs.items[v].ref != null) try s.emit(.{ .keep = Reg.virt(v) }),
            else => {},
        };
    }

    fn callIndirect(s: *S, res: Ir.ValueId, c: Ir.CallIndirect) Error!void {
        const ret_ty = s.retType(c.ret_slot, res);
        var arg_types: std.ArrayList(Type) = .empty;
        defer arg_types.deinit(s.gpa);
        for (c.args) |a| try arg_types.append(s.gpa, s.ir.operandType(a));
        var plan = try Abi.planCall(s.gpa, arg_types.items, ret_ty, s.in.layouts, s.in.enum_layouts);
        defer plan.deinit(s.gpa);

        var uses = try s.marshalArgs(c.args, plan, &.{});
        if (plan.sret_in_x8) {
            try s.emit(.{ .addr = .{ .rd = Reg.gp(8), .mem = Mem.frame(.{ .slot = c.ret_slot }, 0) } });
            uses |= Mir.regBit(Reg.gp(8));
        }
        try s.emit(.{ .mov = .{ .rd = Reg.gp(16), .rn = try s.val(c.target) } });
        uses |= Mir.regBit(Reg.gp(16));
        try s.emit(.{ .call = .{ .callee = .{ .reg = Reg.gp(16) }, .uses = uses, .defs = s.retDefs(ret_ty) } });
        try s.placeResult(res, c.ret_slot, ret_ty);
    }

    fn retDefs(s: *const S, ret_ty: Type) Mir.RegSet {
        return switch (Abi.classifyRet(ret_ty, s.in.layouts, s.in.enum_layouts)) {
            .none, .sret => 0,
            .fp_reg => Mir.regBit(Reg.fp(0)),
            .reg => |r| if (r.regs == 1) Mir.regBit(Reg.gp(0)) else Mir.regBit(Reg.gp(0)) | Mir.regBit(Reg.gp(1)),
        };
    }

    /// Put each argument where `plan` says, returning the argument registers it filled. An
    /// extern call reads an extern struct from its C image (`srcs`) instead of its operand.
    fn marshalArgs(s: *S, args: []const Ir.Operand, plan: Abi.CallPlan, srcs: []const ArgSrc) Error!Mir.RegSet {
        var uses: Mir.RegSet = 0;
        for (plan.locs, args, 0..) |loc, arg, i| {
            if (srcs.len != 0 and srcs[i] != .operand) {
                uses |= try s.marshalImage(loc, srcs[i]);
                continue;
            }
            if (arg == .none) continue;
            const mem = s.memOf(arg);
            switch (loc) {
                .gpr => |r| {
                    if (mem) |m| {
                        for (0..r.count) |k| {
                            const reg = Reg.gp(r.first + @as(u32, @intCast(k)));
                            try s.emit(.{ .load = .{ .rt = reg, .mem = .{ .base = m.base, .off = @intCast(k * 8) } } });
                            uses |= Mir.regBit(reg);
                        }
                    } else {
                        std.debug.assert(r.count == 1);
                        try s.emit(.{ .mov = .{ .rd = Reg.gp(r.first), .rn = try s.val(arg.value) } });
                        uses |= Mir.regBit(Reg.gp(r.first));
                    }
                },
                .fpr => |v| {
                    if (mem) |m| {
                        try s.emit(.{ .load = .{ .rt = Reg.fp(v), .mem = m } });
                    } else try s.emit(.{ .mov = .{ .rd = Reg.fp(v), .rn = try s.val(arg.value) } });
                    uses |= Mir.regBit(Reg.fp(v));
                },
                .gpr_ptr => |r| {
                    try s.emit(.{ .addr = .{ .rd = Reg.gp(r), .mem = mem orelse return error.Unsupported } });
                    uses |= Mir.regBit(Reg.gp(r));
                },
                .stack => |st| {
                    const dst = Mem.frame(.outgoing, st.nsaa_off);
                    const narrow: ?Inst.Size = switch (st.bytes) {
                        1 => .b1,
                        2 => .b2,
                        4 => .b4,
                        else => null,
                    };
                    if (mem) |m| {
                        if (narrow) |n| {
                            const t = try s.temp(.gpr);
                            try s.emit(.{ .load = .{ .rt = t, .mem = m } });
                            try s.emit(.{ .store = .{ .rt = t, .mem = dst, .size = n } });
                        } else try s.emit(.{ .copy = .{ .dst = dst, .src = m, .size = st.bytes } });
                        continue;
                    }
                    var r = try s.val(arg.value);
                    if (narrow != null and s.f.classOf(r) == .fpr) {
                        const t = try s.temp(.gpr);
                        try s.emit(.{ .mov = .{ .rd = t, .rn = r } });
                        r = t;
                    }
                    try s.emit(.{ .store = .{ .rt = r, .mem = dst, .size = narrow orelse .b8 } });
                },
                .stack_ptr => |off| {
                    const t = try s.temp(.gpr);
                    try s.emit(.{ .addr = .{ .rd = t, .mem = mem orelse return error.Unsupported } });
                    try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(.outgoing, off) } });
                },
                .zero => {},
                .fpr_run => unreachable,
            }
        }
        return uses;
    }

    fn marshalImage(s: *S, loc: Abi.ArgLoc, src: ArgSrc) Error!Mir.RegSet {
        var uses: Mir.RegSet = 0;
        switch (src) {
            .operand => unreachable,
            .image => |img| switch (loc) {
                .gpr => |r| for (0..r.count) |k| {
                    const reg = Reg.gp(r.first + @as(u32, @intCast(k)));
                    try s.emit(.{ .load = .{ .rt = reg, .mem = Mem.frame(.c_scratch, img + @as(u32, @intCast(k)) * 8) } });
                    uses |= Mir.regBit(reg);
                },
                .fpr_run => |r| for (0..r.count) |k| {
                    const reg = Reg.fp(r.first + @as(u32, @intCast(k)));
                    const elem: u32 = if (r.single) 4 else 8;
                    try s.emit(.{ .load = .{ .rt = reg, .mem = Mem.frame(.c_scratch, img + @as(u32, @intCast(k)) * elem), .size = if (r.single) .b4 else .b8 } });
                    uses |= Mir.regBit(reg);
                },
                // The image is already the copy a C callee may write.
                .gpr_ptr => |r| {
                    try s.emit(.{ .addr = .{ .rd = Reg.gp(r), .mem = Mem.frame(.c_scratch, img) } });
                    uses |= Mir.regBit(Reg.gp(r));
                },
                .stack => |st| try s.emit(.{ .copy = .{ .dst = Mem.frame(.outgoing, st.nsaa_off), .src = Mem.frame(.c_scratch, img), .size = st.bytes } }),
                .stack_ptr => |off| {
                    const t = try s.temp(.gpr);
                    try s.emit(.{ .addr = .{ .rd = t, .mem = Mem.frame(.c_scratch, img) } });
                    try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(.outgoing, off) } });
                },
                .fpr, .zero => unreachable,
            },
            .image_addr => |img| switch (loc) {
                .gpr => |r| {
                    try s.emit(.{ .addr = .{ .rd = Reg.gp(r.first), .mem = Mem.frame(.c_scratch, img) } });
                    uses |= Mir.regBit(Reg.gp(r.first));
                },
                .stack => |st| {
                    const t = try s.temp(.gpr);
                    try s.emit(.{ .addr = .{ .rd = t, .mem = Mem.frame(.c_scratch, img) } });
                    try s.emit(.{ .store = .{ .rt = t, .mem = Mem.frame(.outgoing, st.nsaa_off) } });
                },
                else => unreachable,
            },
        }
        return uses;
    }

    fn placeResult(s: *S, res: Ir.ValueId, ret_slot: Ir.SlotId, ret_ty: Type) Error!void {
        switch (Abi.classifyRet(ret_ty, s.in.layouts, s.in.enum_layouts)) {
            .none, .sret => {},
            .fp_reg => if (res != Ir.none_value) {
                try s.emit(.{ .mov = .{ .rd = try s.def(res), .rn = Reg.fp(0), .single = ret_ty.isFloat32() } });
            },
            .reg => |r| {
                if (ret_slot != Ir.none_slot) {
                    for (0..r.regs) |k| try s.emit(.{ .store = .{ .rt = Reg.gp(@intCast(k)), .mem = Mem.frame(.{ .slot = ret_slot }, @intCast(k * 8)) } });
                } else if (res != Ir.none_value) {
                    try s.emit(.{ .mov = .{ .rd = try s.def(res), .rn = Reg.gp(0) } });
                }
            },
        }
    }

    /// Lower lays a loop header out before its body and the opt passes keep block order,
    /// so every back edge targets a block at or before its source. An edge that is not one
    /// but matches (say, from an inliner continuation block) only adds a spare poll.
    fn term(s: *S, t: Ir.Terminator, bid: u32) Error!void {
        switch (t) {
            .br => |br| {
                const params = s.ir.blocks[br.dest].params;
                std.debug.assert(br.args.len <= params.len);
                try s.writeParams(params, br.args);
                if (br.dest <= bid) try s.emit(.safepoint_poll);
                try s.emit(.{ .b = br.dest + 1 });
            },
            .cond_br => |c| {
                const cond = try s.val(c.cond);
                if (c.t <= bid or c.f <= bid) try s.emit(.safepoint_poll);
                try s.emit(.{ .cbnz = .{ .rn = cond, .target = c.t + 1 } });
                try s.emit(.{ .b = c.f + 1 });
            },
            .ret => |o| {
                try s.placeReturn(o);
                try s.emit(.ret);
            },
            .@"unreachable" => {},
            .panic => |reason| try s.panicCall(reason.message()),
        }
    }

    /// An edge's arguments into its destination's params. mem2reg can feed one param of an
    /// edge from another (a swap carried round a loop), so a scalar argument that is a
    /// param of the destination is read into a temporary before any param is written.
    fn writeParams(s: *S, params: []const Ir.ValueId, args: []const Ir.Operand) Error!void {
        const held = try s.gpa.alloc(?Reg, args.len);
        defer s.gpa.free(held);
        for (args, held) |arg, *h| {
            h.* = null;
            const v = switch (arg) {
                .value => |v| v,
                .slot, .none => continue,
            };
            if (!isScalar(s.valueType(v)) or std.mem.indexOfScalar(Ir.ValueId, params, v) == null) continue;
            const t = try s.temp(s.f.classOf(Reg.virt(v)));
            try s.emit(.{ .mov = .{ .rd = t, .rn = Reg.virt(v) } });
            h.* = t;
        }
        for (args, held, 0..) |arg, h, i| {
            if (h) |t| {
                try s.emit(.{ .mov = .{ .rd = try s.def(params[i]), .rn = t } });
                try s.flush();
            } else try s.writeParam(params[i], arg);
        }
    }

    /// An edge argument into block param `p`.
    fn writeParam(s: *S, p: Ir.ValueId, arg: Ir.Operand) Error!void {
        const pty = s.valueType(p);
        if (pty.kind == .unit or arg == .none) return;
        if (Abi.isAggregate(pty)) {
            const dst = Mem.frame(.{ .value = p }, 0);
            if (s.memOf(arg)) |src| return s.emit(.{ .copy = .{ .dst = dst, .src = src, .size = s.typeSize(pty) } });
            // A one-word aggregate (a box) fed by its handle as a scalar value.
            if (s.typeSize(pty) > 8) return error.Unsupported;
            return s.emit(.{ .store = .{ .rt = try s.val(arg.value), .mem = dst } });
        }
        const d = try s.def(p);
        if (s.memOf(arg)) |m| {
            try s.emit(.{ .load = .{ .rt = d, .mem = m } });
        } else try s.emit(.{ .mov = .{ .rd = d, .rn = try s.val(arg.value) } });
        try s.flush();
    }

    fn placeReturn(s: *S, o: Ir.Operand) Error!void {
        const ret_ty = s.ir.ret_type;
        if (s.ir.c_abi and Abi.isCStruct(ret_ty, s.in.layouts)) return s.placeCStructReturn(o, ret_ty);
        switch (Abi.classifyRet(ret_ty, s.in.layouts, s.in.enum_layouts)) {
            .none => if (s.in.is_entry) try s.emit(.{ .mov_imm = .{ .rd = Reg.gp(0), .imm = 0 } }),
            .reg => |r| {
                if (o == .none) return;
                if (s.memOf(o)) |m| {
                    for (0..r.regs) |k| try s.emit(.{ .load = .{ .rt = Reg.gp(@intCast(k)), .mem = .{ .base = m.base, .off = @intCast(k * 8) } } });
                } else try s.emit(.{ .mov = .{ .rd = Reg.gp(0), .rn = try s.val(o.value) } });
            },
            .fp_reg => {
                if (o == .none) return;
                if (s.memOf(o)) |m| {
                    try s.emit(.{ .load = .{ .rt = Reg.fp(0), .mem = m } });
                } else try s.emit(.{ .mov = .{ .rd = Reg.fp(0), .rn = try s.val(o.value) } });
            },
            .sret => {
                const src = s.memOf(o) orelse return;
                const buf = try s.temp(.gpr);
                try s.emit(.{ .load = .{ .rt = buf, .mem = Mem.frame(.sret_save, 0) } });
                try s.emit(.{ .copy = .{ .dst = Mem.reg(buf, 0), .src = src, .size = s.typeSize(ret_ty) } });
            },
        }
    }

    /// A C callback's extern struct result, packed into C layout where C reads it: the buffer
    /// it passed in x8, or the C image loaded into x0/x1 or, for an HFA, v0...
    fn placeCStructReturn(s: *S, o: Ir.Operand, ty: Type) Error!void {
        const src = s.memOf(o) orelse return;
        const img = Mem.frame(.c_scratch, 0);
        switch (Abi.cRet(ty, s.in.layouts)) {
            .sret => {
                const buf = try s.temp(.gpr);
                try s.emit(.{ .load = .{ .rt = buf, .mem = Mem.frame(.sret_save, 0) } });
                try s.packC(ty, src, Mem.reg(buf, 0));
            },
            .regs => |n| {
                try s.packC(ty, src, img);
                for (0..n) |k| try s.emit(.{ .load = .{ .rt = Reg.gp(@intCast(k)), .mem = at(img, @as(u32, @intCast(k)) * 8) } });
            },
            .hfa => |h| {
                try s.packC(ty, src, img);
                const elem: u32 = if (h.single) 4 else 8;
                for (0..h.count) |k| try s.emit(.{ .load = .{ .rt = Reg.fp(@intCast(k)), .mem = at(img, @as(u32, @intCast(k)) * elem), .size = if (h.single) .b4 else .b8 } });
            },
        }
    }

    /// `panic(msg, len)`, which prints a backtrace and exits; a `brk` backstops it.
    fn panicCall(s: *S, msg: []const u8) Error!void {
        const h = std.hash.Wyhash.hash(Ir.lit_seed, msg);
        try addLiteral(s.gpa, s.literals, h, msg);
        try s.emit(.{ .sym_addr = .{ .rd = Reg.gp(0), .target = .{ .cstr = h } } });
        try s.emit(.{ .mov_imm = .{ .rd = Reg.gp(1), .imm = @intCast(msg.len) } });
        const uses = Mir.regBit(Reg.gp(0)) | Mir.regBit(Reg.gp(1));
        try s.emit(.{ .call = .{ .callee = .{ .func = .{ .kind = .builtin, .name = "panic" } }, .uses = uses, .safepoint = false } });
        try s.emit(.brk);
    }
};

/// Where an extern call reads argument `i` instead of its operand: the bytes of its C
/// image (a by-value extern struct), or the image's address (a `mut` one), as offsets into
/// the C scratch region.
const ArgSrc = union(enum) { operand, image: u32, image_addr: u32 };

fn cRetDefs(ty: Type, layouts: []const types.Layout) Mir.RegSet {
    var set: Mir.RegSet = 0;
    switch (Abi.cRet(ty, layouts)) {
        .hfa => |h| for (0..h.count) |k| {
            set |= Mir.regBit(Reg.fp(@intCast(k)));
        },
        .regs => |n| for (0..n) |k| {
            set |= Mir.regBit(Reg.gp(@intCast(k)));
        },
        .sret => {},
    }
    return set;
}

/// Add a copy of `bytes` to `literals` unless it is there.
pub fn addLiteral(gpa: std.mem.Allocator, literals: *std.ArrayList(Link.Literal), hash: u64, bytes: []const u8) error{OutOfMemory}!void {
    for (literals.items) |l| if (l.hash == hash and std.mem.eql(u8, l.bytes, bytes)) return;
    const copy = try gpa.dupe(u8, bytes);
    errdefer gpa.free(copy);
    try literals.append(gpa, .{ .hash = hash, .bytes = copy });
}

fn condOf(cc: Ir.Cond) Inst.Cond {
    return switch (cc) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .ult => .lo,
        .ule => .ls,
        .ugt => .hi,
        .uge => .hs,
    };
}

/// NaN-safe: an unordered compare sets C and V, under which `mi`/`ls` are false where
/// `lt`/`le` would be true.
fn fcondOf(cc: Ir.FCond) Inst.Cond {
    return switch (cc) {
        .eq => .eq,
        .ne => .ne,
        .lt => .mi,
        .le => .ls,
        .gt => .gt,
        .ge => .ge,
    };
}
