//! What the target-independent allocators need from AArch64: the scratch registers they
//! may load into and the instructions that move a register to and from a stack slot.

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

pub fn scratch(class: Mir.RegClass) []const Reg {
    return switch (class) {
        .gpr => &gpr_scratch,
        .fpr => &fpr_scratch,
    };
}

pub fn spillLoad(r: Reg, ref: Mir.FrameRef, line: u32) Inst {
    return .{ .op = .{ .load = .{ .rt = r, .mem = Mir.Mem.frame(ref, 0) } }, .line = line };
}

pub fn spillStore(r: Reg, ref: Mir.FrameRef, line: u32) Inst {
    return .{ .op = .{ .store = .{ .rt = r, .mem = Mir.Mem.frame(ref, 0) } }, .line = line };
}
