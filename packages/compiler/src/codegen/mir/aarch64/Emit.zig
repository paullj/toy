//! The AArch64 MIR encoder: MIR on physical registers to machine words, relocs and the line
//! table, through the `Aarch64.zig` word encoders. It lays blocks out in index order,
//! drops a `b` to the next block, turns a conditional branch to the next block followed
//! by a `b` into one inverted branch, aims a branch at a block that is only a `b` at that
//! `b`'s target instead, and resolves branches by backpatching.
//!
//! It owns the frame shape: the prologue saves x29/x30 and points x29 at them (the frame
//! chain every profile keeps), then opens `Frame.size()` bytes that stay fixed until the
//! epilogue, and stores the callee-saved registers the allocator used just below x29
//! (`Frame.saved`), which every epilogue reloads. It records the offset of each safepoint
//! call's `bl`/`blr`, where the collector finds the call's stack map. x12-x15 are its own
//! scratch: x12/x13 hold an address base when an offset
//! leaves an instruction's immediate (and the two cursors of a long copy), x14 a whole
//! offset past 16 MiB, x15 the word a copy moves. No other code may use them.

const std = @import("std");
const Aarch64 = @import("../../Aarch64.zig");
const Link = @import("../../../link/Link.zig");
const Ir = @import("../../../ir/Ir.zig");
const rt_emit = @import("../../runtime/emit.zig");
const Mir = @import("../Mir.zig");
const Inst = @import("Inst.zig");

const Reg = Mir.Reg;
const Func = Mir.Function(Inst);

pub const FA: u32 = 12;
pub const FB: u32 = 13;
pub const FO: u32 = 14;
pub const CD: u32 = 15;

const BranchWidth = enum { imm19, imm26 };
const Fixup = struct { site: u32, block: u32, width: BranchWidth };

pub const Out = struct {
    code: std.ArrayList(u8) = .empty,
    relocs: std.ArrayList(Link.Reloc) = .empty,
    lines: std.ArrayList(Link.LineRow) = .empty,
    /// The code offset of each safepoint call instruction, in code order.
    safepoints: std.ArrayList(u32) = .empty,

    pub fn deinit(o: *Out, gpa: std.mem.Allocator) void {
        o.code.deinit(gpa);
        for (o.relocs.items) |r| if (r.target.name()) |nm| gpa.free(nm);
        o.relocs.deinit(gpa);
        o.lines.deinit(gpa);
        o.safepoints.deinit(gpa);
    }
};

const E = struct {
    gpa: std.mem.Allocator,
    frame: *const Mir.Frame,
    frame_size: u32,
    out: *Out,
    fixups: std.ArrayList(Fixup) = .empty,
    /// Per block, where a branch to it lands once blocks that only hold a `b` are skipped.
    fwd: []const u32 = &.{},

    fn word(e: *E, w: u32) error{OutOfMemory}!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, w, .little);
        try e.out.code.appendSlice(e.gpa, &buf);
    }

    fn here(e: *const E) u32 {
        return @intCast(e.out.code.items.len);
    }

    /// `rd = base + off` for any offset: `add rd, base, #off` while it fits the unshifted
    /// imm12, else the 4 KiB pages then the rest while the page count fits an imm12, else
    /// `off` built whole in FO. Frames and types (T0077) stop below 16 MiB, so the last
    /// form is a backstop that keeps an offset past them correct instead of truncated.
    fn regAddr(e: *E, rd: u32, base: u32, off: u32) error{OutOfMemory}!void {
        std.debug.assert(rd != Aarch64.SP);
        if (off <= 0xFFF) return e.word(Aarch64.addImm(rd, base, @intCast(off)));
        if (off >> 12 <= 0xFFF) {
            try e.word(Aarch64.addImmLsl12(rd, base, @intCast(off >> 12)));
            if (off & 0xFFF != 0) try e.word(Aarch64.addImm(rd, rd, @intCast(off & 0xFFF)));
            return;
        }
        try e.word(Aarch64.movz(FO, @truncate(off), 0));
        try e.word(Aarch64.movk(FO, @intCast(off >> 16), 1));
        try e.word(Aarch64.addRegExt(rd, base, FO));
    }

    const Addr = struct { base: u32, off: u32 };

    fn raw(e: *const E, m: Mir.Mem) Addr {
        return switch (m.base) {
            .reg => |r| .{ .base = r.hw(), .off = m.off },
            .frame => |f| switch (f) {
                .incoming => .{ .base = Aarch64.FP, .off = 16 + m.off },
                else => .{ .base = Aarch64.SP, .off = e.frame.spOffset(f) + m.off },
            },
        };
    }

    /// A base and an offset an access of `scale` bytes encodes: the address itself while its
    /// scaled immediate reaches, else through FA.
    fn access(e: *E, m: Mir.Mem, scale: u32) error{OutOfMemory}!Addr {
        const a = e.raw(m);
        if (a.off % scale == 0 and a.off / scale <= Aarch64.max_scaled) return a;
        const rest = a.off & 0xFFF;
        if (rest % scale == 0) {
            try e.regAddr(FA, a.base, a.off - rest);
            return .{ .base = FA, .off = rest };
        }
        try e.regAddr(FA, a.base, a.off);
        return .{ .base = FA, .off = 0 };
    }

    fn markLine(e: *E, line: u32) error{OutOfMemory}!void {
        if (line == Ir.no_line) return;
        const off = e.here();
        const lines = &e.out.lines;
        if (lines.items.len > 0) {
            const last = &lines.items[lines.items.len - 1];
            if (last.line == line) return;
            if (last.off == off) {
                last.line = line;
                if (lines.items.len > 1 and lines.items[lines.items.len - 2].line == line) _ = lines.pop();
                return;
            }
        }
        try lines.append(e.gpa, .{ .off = off, .line = line });
    }

    fn branch(e: *E, w: u32, block: u32, width: BranchWidth) error{OutOfMemory}!void {
        try e.fixups.append(e.gpa, .{ .site = e.here(), .block = e.fwd[block], .width = width });
        try e.word(w);
    }

    /// `sub sp, sp, #frame`, a 4 KiB page at a time past the imm12, touching each page so an
    /// overflow faults on the guard page instead of stepping over it.
    fn openFrame(e: *E) error{OutOfMemory}!void {
        const frame = e.frame_size;
        if (frame == 0) return;
        if (frame <= 0xFFF) return e.word(Aarch64.subImm(Aarch64.SP, Aarch64.SP, @intCast(frame)));
        try e.word(Aarch64.movz(FA, @intCast(frame >> 12), 0));
        try e.word(Aarch64.subImmLsl12(Aarch64.SP, Aarch64.SP, 1));
        try e.word(Aarch64.strSp(Aarch64.XZR, 0));
        try e.word(Aarch64.subsImm(FA, FA, 1));
        try e.word(Aarch64.bCond(.ne, -3));
        if (frame & 0xFFF != 0) try e.word(Aarch64.subImm(Aarch64.SP, Aarch64.SP, @intCast(frame & 0xFFF)));
    }

    /// Store (or, for the epilogue, load) the callee-saved registers in `Frame.saved` at
    /// `[x29 - 8, x29 - 16, ...]`, in pairs within each file.
    fn calleeSaves(e: *E, load: bool) error{OutOfMemory}!void {
        var off: i32 = 0;
        inline for (.{ Mir.RegClass.gpr, Mir.RegClass.fpr }) |class| {
            const file: Aarch64.File = if (class == .gpr) .x else .d;
            var regs: [16]u32 = undefined;
            var n: usize = 0;
            var set = e.frame.saved;
            while (set != 0) : (set &= set - 1) {
                const r: Reg = @enumFromInt(@ctz(set));
                if (r.physClass() == class) {
                    regs[n] = r.hw();
                    n += 1;
                }
            }
            var k: usize = 0;
            while (k + 1 < n) : (k += 2) {
                off -= 16;
                try e.word(Aarch64.pairOff(file, load, regs[k], regs[k + 1], Aarch64.FP, off));
            }
            if (k < n) {
                off -= 8;
                try e.word(Aarch64.unscaledOff(file, load, regs[k], Aarch64.FP, off));
            }
        }
    }

    fn epilogue(e: *E) error{OutOfMemory}!void {
        try e.calleeSaves(true);
        if (e.frame_size > 0xFFF) {
            try e.word(Aarch64.addImm(Aarch64.SP, Aarch64.FP, 0));
        } else if (e.frame_size > 0) {
            try e.word(Aarch64.addImm(Aarch64.SP, Aarch64.SP, @intCast(e.frame_size)));
        }
        try e.word(Aarch64.ldpFpLrPost);
        try e.word(Aarch64.ret);
    }

    /// Copy `size` bytes, a word at a time through CD, with no branch.
    fn copy(e: *E, dst_m: Mir.Mem, src_m: Mir.Mem, size: u32) error{OutOfMemory}!void {
        if (size == 0) return;
        const dst = e.raw(dst_m);
        const src = e.raw(src_m);
        const last = (size - 1) / 8 * 8;
        if (dst.off % 8 == 0 and src.off % 8 == 0 and (dst.off + last) / 8 <= Aarch64.max_scaled and (src.off + last) / 8 <= Aarch64.max_scaled) {
            var o: u32 = 0;
            while (o < size) : (o += 8) {
                try e.word(Aarch64.ldrRegUoff(CD, src.base, src.off + o));
                try e.word(Aarch64.strRegUoff(CD, dst.base, dst.off + o));
            }
            return;
        }
        const window: u32 = (Aarch64.max_scaled + 1) * 8;
        try e.regAddr(FA, dst.base, dst.off);
        try e.regAddr(FB, src.base, src.off);
        var o: u32 = 0;
        while (o < size) : (o += 8) {
            if (o != 0 and o % window == 0) {
                try e.word(Aarch64.addImmLsl12(FA, FA, window >> 12));
                try e.word(Aarch64.addImmLsl12(FB, FB, window >> 12));
            }
            try e.word(Aarch64.ldrRegUoff(CD, FB, o % window));
            try e.word(Aarch64.strRegUoff(CD, FA, o % window));
        }
    }

    fn reloc(e: *E, target: Link.SymbolId, kind: Link.RelocKind) error{OutOfMemory}!void {
        try e.out.relocs.append(e.gpa, .{ .site = e.here(), .target = target, .kind = kind });
    }

    fn funcTarget(e: *E, s: Ir.SymName) error{OutOfMemory}!Link.SymbolId {
        return .{ .func = .{ .kind = s.kind, .name = try e.gpa.dupe(u8, s.name) } };
    }

    fn inst(e: *E, i: Inst, block: u32) error{OutOfMemory}!void {
        switch (i.op) {
            .mov_imm => |o| {
                var words: [16]u8 = undefined;
                var len: usize = 0;
                Aarch64.movImm64(&words, &len, o.rd.hw(), o.imm);
                try e.out.code.appendSlice(e.gpa, words[0..len]);
            },
            .mov => |o| {
                const rd = o.rd.hw();
                const rn = o.rn.hw();
                try e.word(switch (o.rd.physClass()) {
                    .gpr => switch (o.rn.physClass()) {
                        .gpr => Aarch64.movReg(rd, rn),
                        .fpr => if (o.single) Aarch64.fmovWS(rd, rn) else Aarch64.fmovXD(rd, rn),
                    },
                    .fpr => switch (o.rn.physClass()) {
                        .gpr => Aarch64.fmovDX(rd, rn),
                        .fpr => if (o.single) Aarch64.fmovSS(rd, rn) else Aarch64.fmovDD(rd, rn),
                    },
                });
            },
            .alu => |o| {
                const rd = o.rd.hw();
                const rn = o.rn.hw();
                const rm = o.rm.hw();
                try e.word(switch (o.op) {
                    .add => Aarch64.addReg(rd, rn, rm),
                    .adds => Aarch64.addsReg(rd, rn, rm),
                    .sub => Aarch64.subReg(rd, rn, rm),
                    .mul => Aarch64.mul(rd, rn, rm),
                    .sdiv => Aarch64.sdiv(rd, rn, rm),
                    .udiv => Aarch64.udiv(rd, rn, rm),
                    .@"and" => Aarch64.andReg(rd, rn, rm),
                    .orr => Aarch64.orrReg(rd, rn, rm),
                    .eor => Aarch64.eorReg(rd, rn, rm),
                    .lslv => Aarch64.lslv(rd, rn, rm),
                    .lsrv => Aarch64.lsrv(rd, rn, rm),
                    .asrv => Aarch64.asrv(rd, rn, rm),
                    .smulh => Aarch64.smulh(rd, rn, rm),
                    .umulh => Aarch64.umulh(rd, rn, rm),
                });
            },
            .msub => |o| try e.word(Aarch64.msub(o.rd.hw(), o.rn.hw(), o.rm.hw(), o.ra.hw())),
            .add_imm => |o| try e.regAddr(o.rd.hw(), o.rn.hw(), o.imm),
            .sub_imm => |o| try e.word(Aarch64.subImm(o.rd.hw(), o.rn.hw(), o.imm)),
            .alu_sh => |o| try e.word(switch (o.op) {
                .add => Aarch64.addShifted(o.rd.hw(), o.rn.hw(), o.rm.hw(), o.shift, o.amt),
                .sub => Aarch64.subShifted(o.rd.hw(), o.rn.hw(), o.rm.hw(), o.shift, o.amt),
            }),
            .shift_imm => |o| try e.word(Aarch64.shiftImm(o.op, o.rd.hw(), o.rn.hw(), o.amt)),
            .unary => |o| {
                const rd = o.rd.hw();
                const rn = o.rn.hw();
                try e.word(switch (o.op) {
                    .neg => Aarch64.neg(rd, rn),
                    .mvn => Aarch64.mvn(rd, rn),
                    .sxtb => Aarch64.sxtb(rd, rn),
                    .sxth => Aarch64.sxth(rd, rn),
                    .sxtw => Aarch64.sxtw(rd, rn),
                    .uxtb => Aarch64.andLowBits(rd, rn, 7),
                    .uxth => Aarch64.andLowBits(rd, rn, 15),
                    .uxtw => Aarch64.andLowBits(rd, rn, 31),
                    .asr63 => Aarch64.asrImm(rd, rn, 63),
                });
            },
            .cmp => |o| try e.word(Aarch64.cmpReg(o.rn.hw(), o.rm.hw())),
            .cmp_imm => |o| try e.word(Aarch64.cmpImm(o.rn.hw(), o.imm)),
            .cmn_imm => |o| try e.word(Aarch64.cmnImm(o.rn.hw(), o.imm)),
            .cset => |o| try e.word(Aarch64.cset(o.rd.hw(), o.cond)),
            .csel => |o| try e.word(Aarch64.csel(o.rd.hw(), o.rn.hw(), o.rm.hw(), o.cond)),
            .fp_alu => |o| {
                const w = switch (o.op) {
                    .fadd => Aarch64.fadd(o.rd.hw(), o.rn.hw(), o.rm.hw()),
                    .fsub => Aarch64.fsub(o.rd.hw(), o.rn.hw(), o.rm.hw()),
                    .fmul => Aarch64.fmul(o.rd.hw(), o.rn.hw(), o.rm.hw()),
                    .fdiv => Aarch64.fdiv(o.rd.hw(), o.rn.hw(), o.rm.hw()),
                };
                try e.word(if (o.single) Aarch64.fpSingle(w) else w);
            },
            .fcmp => |o| {
                const w = Aarch64.fcmp(o.rn.hw(), o.rm.hw());
                try e.word(if (o.single) Aarch64.fpSingle(w) else w);
            },
            .cvt => |o| try e.word(switch (o.op) {
                .scvtf => if (o.single) Aarch64.scvtfS(o.rd.hw(), o.rn.hw()) else Aarch64.scvtf(o.rd.hw(), o.rn.hw()),
                .fcvtzs => if (o.single) Aarch64.fcvtzsS(o.rd.hw(), o.rn.hw()) else Aarch64.fcvtzs(o.rd.hw(), o.rn.hw()),
                .fcvt => if (o.single) Aarch64.fcvtDS(o.rd.hw(), o.rn.hw()) else Aarch64.fcvtSD(o.rd.hw(), o.rn.hw()),
            }),
            .load => |o| {
                const rt = o.rt.hw();
                const a = try e.access(o.mem, scaleOf(o.size));
                if (o.rt.physClass() == .fpr) return e.word(switch (o.size) {
                    .b8 => Aarch64.ldrFpRegUoff(rt, a.base, a.off),
                    .b4 => Aarch64.ldrSRegUoff(rt, a.base, a.off),
                    .b1, .b2 => unreachable,
                });
                try e.word(switch (o.size) {
                    .b8 => Aarch64.ldrRegUoff(rt, a.base, a.off),
                    .b4 => if (o.signed) Aarch64.ldrswX(rt, a.base, a.off) else Aarch64.ldrwRegUoff(rt, a.base, a.off),
                    .b2 => if (o.signed) Aarch64.ldrshX(rt, a.base, a.off) else Aarch64.ldrh(rt, a.base, a.off),
                    .b1 => if (o.signed) Aarch64.ldrsbX(rt, a.base, @intCast(a.off)) else Aarch64.ldrbRegUoff(rt, a.base, @intCast(a.off)),
                });
            },
            .store => |o| {
                const rt = o.rt.hw();
                const a = try e.access(o.mem, scaleOf(o.size));
                if (o.rt.physClass() == .fpr) return e.word(switch (o.size) {
                    .b8 => Aarch64.strFpRegUoff(rt, a.base, a.off),
                    .b4 => Aarch64.strSRegUoff(rt, a.base, a.off),
                    .b1, .b2 => unreachable,
                });
                try e.word(switch (o.size) {
                    .b8 => Aarch64.strRegUoff(rt, a.base, a.off),
                    .b4 => Aarch64.strW(rt, a.base, a.off),
                    .b2 => Aarch64.strh(rt, a.base, a.off),
                    .b1 => Aarch64.strb(rt, a.base, @intCast(a.off)),
                });
            },
            .addr => |o| {
                const a = e.raw(o.mem);
                try e.regAddr(o.rd.hw(), a.base, a.off);
            },
            .copy => |o| try e.copy(o.dst, o.src, o.size),
            .sym_addr => |o| {
                const rd = o.rd.hw();
                switch (o.target) {
                    inline .cstr, .data => |v, tag| {
                        const t = @unionInit(Link.SymbolId, @tagName(tag), v);
                        try e.reloc(t, .adrp_page);
                        try e.word(Aarch64.adrp(rd, 0));
                        try e.reloc(t, .add_lo12);
                        try e.word(Aarch64.addImm(rd, rd, 0));
                    },
                    .func => |s| {
                        inline for (.{ Link.RelocKind.adrp_page, Link.RelocKind.add_lo12 }) |kind| {
                            const t = try e.funcTarget(s);
                            e.reloc(t, kind) catch |err| {
                                e.gpa.free(t.func.name);
                                return err;
                            };
                            try e.word(if (kind == .adrp_page) Aarch64.adrp(rd, 0) else Aarch64.addImm(rd, rd, 0));
                        }
                    },
                }
            },
            .call => |o| switch (o.callee) {
                .func => |s| {
                    const t = try e.funcTarget(s);
                    e.reloc(t, .call26) catch |err| {
                        e.gpa.free(t.func.name);
                        return err;
                    };
                    try e.safepoint(o.safepoint);
                    try e.word(Aarch64.bl(0));
                },
                .import => |name| {
                    try rt_emit.emitImportPreamble(&e.out.code, &e.out.relocs, e.gpa, name, 16);
                    try e.safepoint(o.safepoint);
                    try e.word(Aarch64.blr(16));
                },
                .reg => |r| {
                    try e.safepoint(o.safepoint);
                    try e.word(Aarch64.blr(r.hw()));
                },
            },
            .brk => try e.word(Aarch64.brk0),
            .safepoint_poll, .keep => {},
            .b => |target| if (e.fwd[target] != block + 1) try e.branch(Aarch64.b(0), target, .imm26),
            .cbnz => |o| try e.branch(Aarch64.cbnz(o.rn.hw(), 0), o.target, .imm19),
            .b_cond => |o| try e.branch(Aarch64.bCond(o.cond, 0), o.target, .imm19),
            .ret => try e.epilogue(),
        }
    }

    fn safepoint(e: *E, is: bool) error{OutOfMemory}!void {
        if (is) try e.out.safepoints.append(e.gpa, e.here());
    }

    fn resolve(e: *E, block_off: []const u32) void {
        const code = e.out.code.items;
        for (e.fixups.items) |fx| {
            const delta: i64 = @divExact(@as(i64, block_off[fx.block]) - @as(i64, fx.site), 4);
            const old = std.mem.readInt(u32, code[fx.site..][0..4], .little);
            const new = switch (fx.width) {
                .imm19 => if ((old & 0xFF000000) == 0x54000000) Aarch64.patchBCond(old, @intCast(delta)) else Aarch64.patchCbz(old, @intCast(delta)),
                .imm26 => Aarch64.patchB(old, @intCast(delta)),
            };
            std.mem.writeInt(u32, code[fx.site..][0..4], new, .little);
        }
    }
};

/// `cond -> next block; b F` as the one branch `!cond -> F` (its placeholder word), or
/// null when the pair is not that shape.
fn inverted(i: Inst, after: Inst, block: u32, fwd: []const u32) ?u32 {
    if (after.op != .b) return null;
    return switch (i.op) {
        .cbnz => |c| if (fwd[c.target] == block + 1) Aarch64.cbz(c.rn.hw(), 0) else null,
        .b_cond => |c| if (fwd[c.target] == block + 1) Aarch64.bCond(Aarch64.invert(c.cond), 0) else null,
        else => null,
    };
}

/// Per block, the block a branch to it reaches through any chain of blocks that hold only
/// a `b` (lower's empty arms, split edges a later pass moved away from their source). A
/// block holding a safepoint poll is not skipped, so every back edge still polls. A chain
/// that loops on itself is left alone.
fn forwards(gpa: std.mem.Allocator, func: *const Func) error{OutOfMemory}![]u32 {
    const n = func.blocks.len;
    const fwd = try gpa.alloc(u32, n);
    for (fwd, 0..) |*f, b| {
        var t: u32 = @intCast(b);
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            const insts = func.blocks[t].insts.items;
            if (insts.len != 1 or insts[0].op != .b) break;
            t = insts[0].op.b;
        } else t = @intCast(b);
        f.* = t;
    }
    return fwd;
}

fn scaleOf(s: Inst.Size) u32 {
    return switch (s) {
        .b1 => 1,
        .b2 => 2,
        .b4 => 4,
        .b8 => 8,
    };
}

pub const Error = error{ OutOfMemory, BranchOutOfRange };

/// Encode `func`, whose registers are all physical, into `out`. `fn_line` is the line the
/// prologue is charged to.
pub fn encode(gpa: std.mem.Allocator, func: *const Func, frame: *const Mir.Frame, fn_line: u32, out: *Out) Error!void {
    var e: E = .{ .gpa = gpa, .frame = frame, .frame_size = @intCast(frame.size()), .out = out };
    defer e.fixups.deinit(gpa);
    const fwd = try forwards(gpa, func);
    defer gpa.free(fwd);
    e.fwd = fwd;
    const block_off = try gpa.alloc(u32, func.blocks.len);
    defer gpa.free(block_off);

    try e.markLine(fn_line);
    try e.word(Aarch64.stpFpLrPre);
    try e.word(Aarch64.movFpSp);
    try e.openFrame();
    try e.calleeSaves(false);
    for (func.blocks, 0..) |*blk, bi| {
        block_off[bi] = e.here();
        const insts = blk.insts.items;
        var k: usize = 0;
        while (k < insts.len) : (k += 1) {
            const i = insts[k];
            try e.markLine(i.line);
            if (k + 1 < insts.len) if (inverted(i, insts[k + 1], @intCast(bi), fwd)) |w| {
                try e.branch(w, insts[k + 1].op.b, .imm19);
                k += 1;
                continue;
            };
            try e.inst(i, @intCast(bi));
        }
    }
    for (e.fixups.items) |fx| {
        const delta = (@as(i64, block_off[fx.block]) - @as(i64, fx.site)) >> 2;
        const bits: u6 = if (fx.width == .imm19) 18 else 25;
        if (delta < -(@as(i64, 1) << bits) or delta >= (@as(i64, 1) << bits)) return error.BranchOutOfRange;
    }
    e.resolve(block_off);
}

const testing = std.testing;

fn wordAt(code: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, code[i * 4 ..][0..4], .little);
}

test "encode: prologue, a frame load past the scaled immediate goes through x12, fallthrough b is dropped" {
    const gpa = testing.allocator;
    var f = try Func.init(gpa, 2);
    defer f.deinit(gpa);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .load = .{ .rt = Reg.gp(9), .mem = Mir.Mem.frame(.{ .slot = 0 }, 0) } }, .line = 3 });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .ret, .line = 4 });

    var slot_off = [_]u32{40000};
    var value_off = [_]u32{};
    const frame: Mir.Frame = .{ .layout = .{ .frame = 40016, .out_base = 0, .sret_save_off = 0, .slot_off = &slot_off, .value_off = &value_off } };
    var out: Out = .{};
    defer out.deinit(gpa);
    try encode(gpa, &f, &frame, 2, &out);

    const code = out.code.items;
    try testing.expectEqual(Aarch64.stpFpLrPre, wordAt(code, 0));
    try testing.expectEqual(Aarch64.movFpSp, wordAt(code, 1));
    // 40016 = 9 pages + 3152: the paged open (6 words), then the load.
    const load_at = 2 + 6;
    try testing.expectEqual(Aarch64.addImmLsl12(FA, Aarch64.SP, 9), wordAt(code, load_at));
    try testing.expectEqual(Aarch64.ldrRegUoff(9, FA, 40000 - 9 * 4096), wordAt(code, load_at + 1));
    // No branch: block 1 follows; then the epilogue restores sp from x29.
    try testing.expectEqual(Aarch64.addImm(Aarch64.SP, Aarch64.FP, 0), wordAt(code, load_at + 2));
    try testing.expectEqual(Aarch64.ret, wordAt(code, code.len / 4 - 1));
    try testing.expectEqual(@as(usize, 3), out.lines.items.len);
    try testing.expectEqual(@as(u32, 2), out.lines.items[0].line);
    try testing.expectEqual(@as(u32, (load_at) * 4), out.lines.items[1].off);
}

test "encode: a backward cbnz resolves to its block, float32 moves use the single forms" {
    const gpa = testing.allocator;
    var f = try Func.init(gpa, 3);
    defer f.deinit(gpa);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .mov = .{ .rd = Reg.fp(16), .rn = Reg.fp(0), .single = true } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .cbnz = .{ .rn = Reg.gp(9), .target = 1 } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .b = 2 } });
    try f.blocks[2].insts.append(gpa, .{ .op = .ret });
    var none = [_]u32{};
    const frame: Mir.Frame = .{ .layout = .{ .frame = 0, .out_base = 0, .sret_save_off = 0, .slot_off = &none, .value_off = &none } };
    var out: Out = .{};
    defer out.deinit(gpa);
    try encode(gpa, &f, &frame, Ir.no_line, &out);
    const code = out.code.items;
    try testing.expectEqual(Aarch64.fmovSS(16, 0), wordAt(code, 2));
    try testing.expectEqual(Aarch64.cbnz(9, -1), wordAt(code, 3));
    try testing.expectEqual(Aarch64.ldpFpLrPost, wordAt(code, 4));
    try testing.expectEqual(@as(usize, 0), out.lines.items.len);
}

test "encode: callee-saved registers are paired below x29 and reloaded before the frame closes; safepoint calls are recorded" {
    const gpa = testing.allocator;
    var f = try Func.init(gpa, 1);
    defer f.deinit(gpa);
    const sym: Inst.Callee = .{ .func = .{ .kind = .user_fn, .name = "g" } };
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .call = .{ .callee = sym } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .call = .{ .callee = sym, .safepoint = false } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .ret });
    var none = [_]u32{};
    var frame: Mir.Frame = .{ .layout = .{ .frame = 16, .out_base = 0, .sret_save_off = 0, .slot_off = &none, .value_off = &none } };
    frame.saved = Mir.regBit(Reg.gp(19)) | Mir.regBit(Reg.gp(20)) | Mir.regBit(Reg.gp(21)) | Mir.regBit(Reg.fp(8));
    try testing.expectEqual(@as(u64, 16 + 32), frame.size());
    var out: Out = .{};
    defer out.deinit(gpa);
    try encode(gpa, &f, &frame, Ir.no_line, &out);
    const code = out.code.items;
    try testing.expectEqual(Aarch64.subImm(Aarch64.SP, Aarch64.SP, 48), wordAt(code, 2));
    try testing.expectEqual(Aarch64.pairOff(.x, false, 19, 20, Aarch64.FP, -16), wordAt(code, 3));
    try testing.expectEqual(Aarch64.unscaledOff(.x, false, 21, Aarch64.FP, -24), wordAt(code, 4));
    try testing.expectEqual(Aarch64.unscaledOff(.d, false, 8, Aarch64.FP, -32), wordAt(code, 5));
    // Only the first call is a safepoint.
    try testing.expectEqualSlices(u32, &.{6 * 4}, out.safepoints.items);
    try testing.expectEqual(Aarch64.pairOff(.x, true, 19, 20, Aarch64.FP, -16), wordAt(code, 8));
    try testing.expectEqual(Aarch64.unscaledOff(.d, true, 8, Aarch64.FP, -32), wordAt(code, 10));
    try testing.expectEqual(Aarch64.addImm(Aarch64.SP, Aarch64.SP, 48), wordAt(code, 11));
}

test "encode: a branch to a block that only holds a b lands on that b's target" {
    const gpa = testing.allocator;
    var f = try Func.init(gpa, 5);
    defer f.deinit(gpa);
    // b0: b.lt b2; b b3    b1: ret    b2: b b1    b3: b b4    b4: b b3 (a loop of forwarders)
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b_cond = .{ .cond = .lt, .target = 2 } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 3 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .ret });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[3].insts.append(gpa, .{ .op = .{ .b = 4 } });
    try f.blocks[4].insts.append(gpa, .{ .op = .{ .b = 3 } });
    var none = [_]u32{};
    const frame: Mir.Frame = .{ .layout = .{ .frame = 0, .out_base = 0, .sret_save_off = 0, .slot_off = &none, .value_off = &none } };
    var out: Out = .{};
    defer out.deinit(gpa);
    try encode(gpa, &f, &frame, Ir.no_line, &out);
    const code = out.code.items;
    // b.lt reaches b1 through b2, the next block, so it inverts onto b3: b.ge at word 2.
    // b1's epilogue is words 3-4 and b2's b to b1 word 5. b3 falls into b4, whose b
    // back to b3 is word 6: the forwarder loop is kept, not followed.
    try testing.expectEqual(Aarch64.bCond(.ge, 4), wordAt(code, 2));
    try testing.expectEqual(Aarch64.b(-2), wordAt(code, 5));
    try testing.expectEqual(Aarch64.b(0), wordAt(code, 6));
    try testing.expectEqual(@as(usize, 7 * 4), code.len);
}

test "encode: a conditional branch to the next block and a b become one inverted branch" {
    const gpa = testing.allocator;
    var f = try Func.init(gpa, 4);
    defer f.deinit(gpa);
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b_cond = .{ .cond = .lt, .target = 1 } } });
    try f.blocks[0].insts.append(gpa, .{ .op = .{ .b = 2 } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .cbnz = .{ .rn = Reg.gp(3), .target = 2 } } });
    try f.blocks[1].insts.append(gpa, .{ .op = .{ .b = 3 } });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .cbnz = .{ .rn = Reg.gp(4), .target = 3 } } });
    try f.blocks[2].insts.append(gpa, .{ .op = .{ .b = 1 } });
    try f.blocks[3].insts.append(gpa, .{ .op = .ret });
    var none = [_]u32{};
    const frame: Mir.Frame = .{ .layout = .{ .frame = 0, .out_base = 0, .sret_save_off = 0, .slot_off = &none, .value_off = &none } };
    var out: Out = .{};
    defer out.deinit(gpa);
    try encode(gpa, &f, &frame, Ir.no_line, &out);
    const code = out.code.items;
    // One word per block: b.ge -> b2, cbz x3 -> b3, cbz x4 -> b1 (back), then b3.
    try testing.expectEqual(Aarch64.bCond(.ge, 2), wordAt(code, 2));
    try testing.expectEqual(Aarch64.cbz(3, 2), wordAt(code, 3));
    try testing.expectEqual(Aarch64.cbz(4, -1), wordAt(code, 4));
    try testing.expectEqual(Aarch64.ldpFpLrPost, wordAt(code, 5));
}
