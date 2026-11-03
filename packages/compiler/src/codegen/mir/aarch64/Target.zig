//! What the target-independent allocator needs from AArch64: the registers it may hand
//! out, the scratch register its move resolver uses, and the instructions that move a
//! value between registers and stack slots.

const Mir = @import("../Mir.zig");
pub const Inst = @import("Inst.zig");
const Emit = @import("Emit.zig");

const Reg = Mir.Reg;

/// x9-x11 and v16-v18: caller-saved, never an argument or result register, and never named
/// by the selector, so spill code cannot overwrite a value an instruction is about to read.
const gpr_scratch = [_]Reg{ Reg.gp(9), Reg.gp(10), Reg.gp(11) };
const fpr_scratch = [_]Reg{ Reg.fp(16), Reg.fp(17), Reg.fp(18) };

/// Registers the selector must never name: the allocator's scratch and the encoder's own.
pub const reserved: Mir.RegSet = blk: {
    var set: Mir.RegSet = 0;
    for (gpr_scratch ++ fpr_scratch) |r| set |= Mir.regBit(r);
    for ([_]u32{ Emit.FA, Emit.FB, Emit.FO, Emit.CD }) |n| set |= Mir.regBit(Reg.gp(n));
    break :blk set;
};

fn scratch(class: Mir.RegClass) []const Reg {
    return switch (class) {
        .gpr => &gpr_scratch,
        .fpr => &fpr_scratch,
    };
}

/// The registers linear scan hands out, caller-saved first so a value that crosses no
/// call does not cost a save in the prologue. The argument and result registers are in:
/// their fixed intervals keep a value out of them while a call needs them. Left out: x9
/// and v16 (the move resolver's scratch), x12-x15 (the encoder's), x16-x17 (the import
/// stub and indirect calls), x18 (Apple's) and x29-x31.
const gpr_alloc = [_]Reg{
    Reg.gp(10), Reg.gp(11), Reg.gp(8),  Reg.gp(7),  Reg.gp(6),  Reg.gp(5),  Reg.gp(4),
    Reg.gp(3),  Reg.gp(2),  Reg.gp(1),  Reg.gp(0),  Reg.gp(19), Reg.gp(20), Reg.gp(21),
    Reg.gp(22), Reg.gp(23), Reg.gp(24), Reg.gp(25), Reg.gp(26), Reg.gp(27), Reg.gp(28),
};
const fpr_alloc = [_]Reg{
    Reg.fp(17), Reg.fp(18), Reg.fp(19), Reg.fp(20), Reg.fp(21), Reg.fp(22), Reg.fp(23),
    Reg.fp(24), Reg.fp(25), Reg.fp(26), Reg.fp(27), Reg.fp(28), Reg.fp(29), Reg.fp(30),
    Reg.fp(31), Reg.fp(7),  Reg.fp(6),  Reg.fp(5),  Reg.fp(4),  Reg.fp(3),  Reg.fp(2),
    Reg.fp(1),  Reg.fp(0),  Reg.fp(8),  Reg.fp(9),  Reg.fp(10), Reg.fp(11), Reg.fp(12),
    Reg.fp(13), Reg.fp(14), Reg.fp(15),
};

pub fn allocatable(class: Mir.RegClass) []const Reg {
    return switch (class) {
        .gpr => &gpr_alloc,
        .fpr => &fpr_alloc,
    };
}

/// The registers a callee must preserve (AAPCS64): x19-x28 and the low halves of v8-v15,
/// which is all a value of either file uses.
pub const callee_saved: Mir.RegSet = blk: {
    var s: Mir.RegSet = 0;
    for (19..29) |n| s |= Mir.regBit(Reg.gp(n));
    for (8..16) |n| s |= Mir.regBit(Reg.fp(n));
    break :blk s;
};

/// The register the move resolver breaks a cycle through and moves slot to slot with.
pub fn moveScratch(class: Mir.RegClass) Reg {
    return scratch(class)[0];
}

pub fn move(dst: Reg, src: Reg, line: u32) Inst {
    return .{ .op = .{ .mov = .{ .rd = dst, .rn = src } }, .line = line };
}

pub fn jump(target: u32, line: u32) Inst {
    return .{ .op = .{ .b = target }, .line = line };
}

pub fn spillLoad(r: Reg, ref: Mir.FrameRef, line: u32) Inst {
    return .{ .op = .{ .load = .{ .rt = r, .mem = Mir.Mem.frame(ref, 0) } }, .line = line };
}

pub fn spillStore(r: Reg, ref: Mir.FrameRef, line: u32) Inst {
    return .{ .op = .{ .store = .{ .rt = r, .mem = Mir.Mem.frame(ref, 0) } }, .line = line };
}
