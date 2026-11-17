//! The AArch64 ISA module (the interface is `codegen/Isa.zig`): the selector, the
//! encoder, the relocation kinds and the hand-written builtins, plus what the
//! target-independent allocator needs: the registers it may hand out, the scratch
//! register its move resolver uses, and the instructions that move a value between
//! registers and stack slots.

const std = @import("std");
const Mir = @import("../Mir.zig");
const Link = @import("../../../link/Link.zig");
const runtime = @import("../../runtime/runtime.zig");
const Isa = @import("../../Isa.zig");
const Target = @import("../../../Target.zig");
pub const Inst = @import("Inst.zig");
pub const Isel = @import("Isel.zig");
pub const Emit = @import("Emit.zig");
pub const Peephole = @import("Peephole.zig");
pub const abi = @import("abi.zig");
const reloc = @import("reloc.zig");
const panic = @import("runtime/panic.zig");
const str = @import("runtime/str.zig");

pub const relocs: Link.Patcher = reloc.patcher;

pub const c_abis = [_]Target.CAbi{ .aapcs64_apple, .aapcs64 };

/// Every AArch64 instruction is one 4-byte word.
pub fn instCount(code: []const u8) usize {
    return code.len / 4;
}

/// By name, so a reorder of `runtime.hand_builtins` cannot pair a row with another body.
pub const hand_builtins = blk: {
    var out: [runtime.hand_builtins.len]Isa.BuiltinFn = undefined;
    for (runtime.hand_builtins, &out) |hb, *f| f.* = lowerFor(hb.name);
    break :blk out;
};

fn lowerFor(comptime name: []const u8) Isa.BuiltinFn {
    const pairs = .{
        .{ "panic", panic.lowerPanic },
        .{ "text_base", panic.lowerTextBase },
        .{ "__int_to_str", str.lowerIntToStr },
        .{ "__str_concat", str.lowerStrConcat },
        .{ "__uint_to_str", str.lowerUintToStr },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
    @compileError("no aarch64 body for hand builtin " ++ name);
}

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

const testing = std.testing;
const Ir = @import("../../../ir/Ir.zig");
const types = @import("../../../types.zig");
const Type = types.Type;
const FrameLayout = @import("../../frame/FrameLayout.zig");
const Diagnostic = @import("../../../diagnostics/Diagnostic.zig").Diagnostic;
const Aarch64 = @import("encode.zig");
const lowerMir = @import("../../CodegenMir.zig").CodegenMir(@This()).lowerMir;

fn wordsOf(fc: Link.FnCode) []align(1) const u32 {
    return std.mem.bytesAsSlice(u32, fc.code);
}

fn hasWord(fc: Link.FnCode, w: u32) bool {
    for (wordsOf(fc)) |x| if (x == w) return true;
    return false;
}

/// `lowerMir` on a fn it must lower without a diagnostic.
fn lowerOk(gpa: std.mem.Allocator, func: *const Ir.Function) !Link.FnCode {
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(gpa);
    var fc = try lowerMir(gpa, func, &.{}, &.{}, .aapcs64_apple, false, false, &diags);
    errdefer fc.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
    return fc;
}

/// `fn f(a: int, b: int) -> int { ret a + b }`, both params in slots.
fn addFn(gpa: std.mem.Allocator) !Ir.Function {
    const values = try gpa.alloc(Ir.ValueDef, 5);
    for (values) |*v| v.* = .{ .type = Type.int };
    const slots = try gpa.alloc(Ir.Slot, 2);
    for (slots) |*s| s.* = .{ .type = Type.int };
    const instrs = try gpa.alloc(Ir.Instr, 5);
    instrs[0] = .{ .result = 0, .op = .{ .slot_addr = 0 }, .line = 1 };
    instrs[1] = .{ .result = 1, .op = .{ .load = .{ .addr = 0, .ty = Type.int } }, .line = 1 };
    instrs[2] = .{ .result = 2, .op = .{ .slot_addr = 1 }, .line = 1 };
    instrs[3] = .{ .result = 3, .op = .{ .load = .{ .addr = 2, .ty = Type.int } }, .line = 1 };
    instrs[4] = .{ .result = 4, .op = .{ .add = .{ .lhs = 1, .rhs = 3 } }, .line = 2 };
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .{ .value = 4 } }, .term_line = 2 };
    const params = try gpa.alloc(Ir.SlotId, 2);
    params[0] = 0;
    params[1] = 1;
    return .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = params,
        .ret_type = Type.int,
        .slots = slots,
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
        .line = 0,
    };
}

test "mir: a fn lowers through MIR with the x29 frame, its int params kept in their registers, its lines kept" {
    const gpa = testing.allocator;
    var func = try addFn(gpa);
    defer func.deinit(gpa);
    var fl = try FrameLayout.compute(gpa, &func, abi.facts(.aapcs64_apple), &.{}, &.{});
    defer fl.deinit(gpa);

    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    try testing.expectEqual(Aarch64.stpFpLrPre, wordsOf(fc)[0]);
    try testing.expectEqual(Aarch64.movFpSp, wordsOf(fc)[1]);
    try testing.expectEqual(Aarch64.ret, wordsOf(fc)[wordsOf(fc).len - 1]);
    // No param slot holds a reference, so neither is written or read.
    try testing.expect(!hasWord(fc, Aarch64.strRegUoff(0, Aarch64.SP, fl.slot_off[0])));
    try testing.expect(!hasWord(fc, Aarch64.strRegUoff(1, Aarch64.SP, fl.slot_off[1])));
    try testing.expectEqual(@as(u32, 0), fc.lines[0].line);
    try testing.expectEqual(@as(u32, 2), fc.lines[fc.lines.len - 1].line);
}

test "mir: linear scan keeps the values in registers: no value cells, the sum straight into x0" {
    const gpa = testing.allocator;
    var func = try addFn(gpa);
    defer func.deinit(gpa);
    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    // Two param slots only: 16 bytes, and no cell for any of the five values.
    try testing.expect(hasWord(fc, Aarch64.subImm(Aarch64.SP, Aarch64.SP, 16)));
    try testing.expect(hasWord(fc, Aarch64.addReg(0, 0, 1)));
    // prologue (3) + add + epilogue (3)
    try testing.expectEqual(@as(usize, 7), wordsOf(fc).len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, fc.root_bitmap);
    try testing.expectEqual(@as(usize, 0), fc.safepoint_maps.len);
}

/// `fn f(p: rawptr) -> rawptr { g(); ret p }` with `p` loaded into a value before the
/// call: a reference live across a safepoint.
fn refAcrossCallFn(gpa: std.mem.Allocator, callee: Ir.SymName) !Ir.Function {
    const values = try gpa.alloc(Ir.ValueDef, 2);
    values[0] = .{ .type = Type.int };
    values[1] = .{ .type = Type.rawptr };
    const slots = try gpa.alloc(Ir.Slot, 1);
    slots[0] = .{ .type = Type.rawptr };
    const instrs = try gpa.alloc(Ir.Instr, 3);
    instrs[0] = .{ .result = 0, .op = .{ .slot_addr = 0 } };
    instrs[1] = .{ .result = 1, .op = .{ .load = .{ .addr = 0, .ty = Type.rawptr } } };
    instrs[2] = .{ .result = Ir.none_value, .op = .{ .call = .{
        .callee = callee,
        .args = try gpa.alloc(Ir.Operand, 0),
        .ret_slot = Ir.none_slot,
    } } };
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .{ .value = 1 } } };
    const params = try gpa.alloc(Ir.SlotId, 1);
    params[0] = 0;
    return .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = params,
        .ret_type = Type.rawptr,
        .slots = slots,
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
}

test "mir: a reference live across a safepoint gets a stack-map row naming its spill slot" {
    const gpa = testing.allocator;
    var func = try refAcrossCallFn(gpa, .{ .kind = .user_fn, .name = "g" });
    defer func.deinit(gpa);
    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    // The fn-start row: the rawptr param slot at sp+0.
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }, fc.root_bitmap);
    var rows: Link.SafepointRows = .{ .bytes = fc.safepoint_maps };
    const row = rows.next().?;
    try testing.expect(rows.next() == null);
    // The row sits on the bl, and names the param slot and the value's spill slot after it.
    try testing.expectEqual(Aarch64.bl(0), wordsOf(fc)[row.code_off / 4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, row.payload[0..4], .little));
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, row.payload[8..12], .little));
}

test "mir: a reference param keeps its store, the collector's root, and is not reloaded" {
    const gpa = testing.allocator;
    var func = try refAcrossCallFn(gpa, .{ .kind = .builtin, .name = "text_base" });
    defer func.deinit(gpa);
    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    var stores: usize = 0;
    for (wordsOf(fc)) |w| {
        if (w & ~@as(u32, 0x1F) == Aarch64.strRegUoff(0, Aarch64.SP, 0)) stores += 1;
        try testing.expect(w & ~@as(u32, 0x1F) != Aarch64.ldrRegUoff(0, Aarch64.SP, 0));
    }
    try testing.expectEqual(@as(usize, 1), stores);
}

/// `fn f(x: T) -> T { ret x <op> k }` for the shift `op` and a constant amount `k`.
fn shiftFn(gpa: std.mem.Allocator, ty: Type, op: std.meta.Tag(Ir.Op), k: i64) !Ir.Function {
    const values = try gpa.alloc(Ir.ValueDef, 4);
    values[0] = .{ .type = Type.int };
    for (values[1..]) |*v| v.* = .{ .type = ty };
    const slots = try gpa.alloc(Ir.Slot, 1);
    slots[0] = .{ .type = ty };
    const instrs = try gpa.alloc(Ir.Instr, 4);
    instrs[0] = .{ .result = 0, .op = .{ .slot_addr = 0 } };
    instrs[1] = .{ .result = 1, .op = .{ .load = .{ .addr = 0, .ty = ty } } };
    instrs[2] = .{ .result = 2, .op = .{ .iconst = k } };
    const bin: Ir.Bin = .{ .lhs = 1, .rhs = 2 };
    instrs[3] = .{ .result = 3, .op = switch (op) {
        .shl => .{ .shl = bin },
        .lshr => .{ .lshr = bin },
        else => .{ .ashr = bin },
    } };
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .{ .value = 3 } } };
    const params = try gpa.alloc(Ir.SlotId, 1);
    params[0] = 0;
    return .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = params,
        .ret_type = ty,
        .slots = slots,
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
}

test "mir: a shift by a constant is one immediate shift, or the 0 or sign fill past the width" {
    const gpa = testing.allocator;
    const Case = struct { ty: Type, op: std.meta.Tag(Ir.Op), k: i64, word: ?u32 };
    const int32 = Type.int32;
    for ([_]Case{
        .{ .ty = Type.int, .op = .ashr, .k = 14, .word = Aarch64.shiftImm(.asr, 0, 0, 14) },
        .{ .ty = Type.int, .op = .lshr, .k = 63, .word = Aarch64.shiftImm(.lsr, 0, 0, 63) },
        .{ .ty = Type.int, .op = .shl, .k = 1, .word = Aarch64.shiftImm(.lsl, 0, 0, 1) },
        .{ .ty = Type.int, .op = .shl, .k = 0, .word = null },
        .{ .ty = Type.int, .op = .shl, .k = 64, .word = Aarch64.movz(0, 0, 0) },
        .{ .ty = Type.int, .op = .lshr, .k = -1, .word = Aarch64.movz(0, 0, 0) },
        .{ .ty = Type.int, .op = .ashr, .k = 64, .word = Aarch64.asrImm(0, 0, 63) },
        .{ .ty = Type.int, .op = .ashr, .k = std.math.minInt(i64), .word = Aarch64.asrImm(0, 0, 63) },
        .{ .ty = int32, .op = .ashr, .k = 32, .word = Aarch64.asrImm(0, 0, 63) },
        .{ .ty = int32, .op = .shl, .k = 31, .word = Aarch64.sxtw(0, 0) },
    }) |c| {
        var func = try shiftFn(gpa, c.ty, c.op, c.k);
        defer func.deinit(gpa);
        var fc = try lowerOk(gpa, &func);
        defer fc.deinit(gpa);
        // No guard: no compare, no select, no register-amount shift.
        for (wordsOf(fc)) |w| {
            try testing.expect(w & 0xFF20001F != 0xEB00001F and w & 0xFF00001F != 0xF100001F);
            try testing.expect(w & 0xFFE00C00 != 0x9A800000);
            try testing.expect(w & 0xFFE0F000 != 0x9AC02000);
        }
        if (c.word) |w| try testing.expect(hasWord(fc, w));
        // prologue (3) + at most a shift and a re-normalize + epilogue (3)
        try testing.expect(wordsOf(fc).len <= 8);
    }
}

test "mir: a call to a core/rt fn is no safepoint and gets no stack-map row" {
    const gpa = testing.allocator;
    var func = try refAcrossCallFn(gpa, .{ .kind = .user_fn, .name = "core/rt/str.str_eq" });
    defer func.deinit(gpa);
    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), fc.safepoint_maps.len);
}

test "mir: a call to a builtin that never collects is no safepoint and keeps the reference in a register" {
    const gpa = testing.allocator;
    var func = try refAcrossCallFn(gpa, .{ .kind = .builtin, .name = "text_base" });
    defer func.deinit(gpa);
    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), fc.safepoint_maps.len);
    // Only the param slot: no spill slot, but x19 saved below x29.
    try testing.expect(hasWord(fc, Aarch64.subImm(Aarch64.SP, Aarch64.SP, 32)));
    try testing.expect(hasWord(fc, Aarch64.unscaledOff(.x, false, 19, Aarch64.FP, -8)));
}

test "mir: a shape the selector does not cover is an internal-error diagnostic and an empty fn" {
    const gpa = testing.allocator;
    var func = try addFn(gpa);
    defer func.deinit(gpa);
    func.values[1].type = Type.unit;
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(gpa);
    var fc = try lowerMir(gpa, &func, &.{}, &.{}, .aapcs64_apple, false, false, &diags);
    defer fc.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expect(std.mem.startsWith(u8, diags.items[0].message, "internal compiler error"));
    try testing.expectEqual(@as(usize, 0), fc.code.len);
}

fn slotsOnlyFn(gpa: std.mem.Allocator, slot_types: []const Type) !Ir.Function {
    var blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    const slots = try gpa.alloc(Ir.Slot, slot_types.len);
    for (slots, slot_types) |*sl, t| sl.* = .{ .type = t };
    return .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Type.unit,
        .slots = slots,
        .values = try gpa.alloc(Ir.ValueDef, 0),
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
        .literals = try gpa.alloc(Ir.Literal, 0),
    };
}

test "mir: a frame that one value nearly fills says so, not too many locals" {
    const gpa = testing.allocator;
    const Case = struct { sizes: []const u32, message: []const u8 };
    const cases = [_]Case{
        .{ .sizes = &.{ abi.max_frame, 8 }, .message = "function frame too large for codegen (one value nearly fills the 16 MiB frame; hold large data in a Vec)" },
        .{ .sizes = &.{ 14 << 20, 14 << 20 }, .message = "function frame too large for codegen (too many locals)" },
    };
    for (cases) |k| {
        var layouts: [2]types.Layout = undefined;
        for (&layouts, k.sizes) |*l, sz| l.* = .{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = sz, .@"align" = 8 };
        var func = try slotsOnlyFn(gpa, &.{ Type.structT(0), Type.structT(1) });
        defer func.deinit(gpa);
        var diags: std.ArrayList(Diagnostic) = .empty;
        defer diags.deinit(gpa);
        var fc = try lowerMir(gpa, &func, &layouts, &.{}, .aapcs64_apple, false, false, &diags);
        defer fc.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), diags.items.len);
        try testing.expectEqualStrings(k.message, diags.items[0].message);
    }
}

test "mir: a back edge carries the safepoint placeholder and emits no poll" {
    const gpa = testing.allocator;
    // b0: br b1 ; b1: %0 = bconst true ; cond_br %0, b1, b2 ; b2: ret
    const values = try gpa.alloc(Ir.ValueDef, 1);
    values[0] = .{ .type = Type.bool };
    const body = try gpa.alloc(Ir.Instr, 1);
    body[0] = .{ .result = 0, .op = .{ .bconst = true } };
    const blocks = try gpa.alloc(Ir.Block, 4);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .br = .{ .dest = 1, .args = try gpa.alloc(Ir.Operand, 0) } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = body, .term = .{ .cond_br = .{ .cond = 0, .t = 2, .f = 3 } } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .br = .{ .dest = 1, .args = try gpa.alloc(Ir.Operand, 0) } } };
    blocks[3] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    var func: Ir.Function = .{
        .name = .{ .kind = .user_fn, .name = "loop" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 3,
    };
    defer func.deinit(gpa);

    var frame: Mir.Frame = .{ .layout = try FrameLayout.compute(gpa, &func, abi.facts(.aapcs64_apple), &.{}, &.{}) };
    defer frame.deinit(gpa);
    var mf = try Isel.newFunc(gpa, &func);
    defer mf.deinit(gpa);
    var literals: std.ArrayList(Link.Literal) = .empty;
    defer literals.deinit(gpa);
    try Isel.select(gpa, .{ .ir = &func, .layouts = &.{}, .enum_layouts = &.{}, .facts = &comptime abi.facts(.aapcs64_apple), .is_entry = false, .fl = &frame.layout, .roots = &.{} }, &mf, &literals);
    var polls: usize = 0;
    for (mf.blocks, 0..) |b, bi| for (b.insts.items) |i| if (i.op == .safepoint_poll) {
        polls += 1;
        try testing.expectEqual(@as(usize, 3), bi);
    };
    try testing.expectEqual(@as(usize, 1), polls);
    try testing.expect(try mf.tempsStayLocal(gpa));
}

test "mir: a loop closed by a cond_br polls too" {
    const gpa = testing.allocator;
    // b0: br b1 ; b1: %0 = bconst true ; cond_br %0, b1, b2 ; b2: ret
    const values = try gpa.alloc(Ir.ValueDef, 1);
    values[0] = .{ .type = Type.bool };
    const body = try gpa.alloc(Ir.Instr, 1);
    body[0] = .{ .result = 0, .op = .{ .bconst = true } };
    const blocks = try gpa.alloc(Ir.Block, 3);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .br = .{ .dest = 1, .args = try gpa.alloc(Ir.Operand, 0) } } };
    blocks[1] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = body, .term = .{ .cond_br = .{ .cond = 0, .t = 1, .f = 2 } } };
    blocks[2] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    var func: Ir.Function = .{
        .name = .{ .kind = .user_fn, .name = "loop" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 2,
    };
    defer func.deinit(gpa);

    var frame: Mir.Frame = .{ .layout = try FrameLayout.compute(gpa, &func, abi.facts(.aapcs64_apple), &.{}, &.{}) };
    defer frame.deinit(gpa);
    var mf = try Isel.newFunc(gpa, &func);
    defer mf.deinit(gpa);
    var literals: std.ArrayList(Link.Literal) = .empty;
    defer literals.deinit(gpa);
    try Isel.select(gpa, .{ .ir = &func, .layouts = &.{}, .enum_layouts = &.{}, .facts = &comptime abi.facts(.aapcs64_apple), .is_entry = false, .fl = &frame.layout, .roots = &.{} }, &mf, &literals);
    var polls: usize = 0;
    for (mf.blocks, 0..) |b, bi| for (b.insts.items) |i| if (i.op == .safepoint_poll) {
        polls += 1;
        try testing.expectEqual(@as(usize, 2), bi);
    };
    try testing.expectEqual(@as(usize, 1), polls);
}

const StdNames = @import("../../../symbols/StdNames.zig");

test "runtime_calls lists every core/rt fn a body calls, so the linker keeps it" {
    const gpa = testing.allocator;
    for (runtime.hand_builtins, hand_builtins) |hb, lower| {
        var fc = try lower(gpa);
        defer fc.deinit(gpa);
        for (fc.relocs) |r| {
            if (r.kind != reloc.of(.call26) or r.target != .func) continue;
            const f = StdNames.RuntimeFn.lookup(r.target.func.name) orelse return error.UnknownCallee;
            if (std.mem.indexOfScalar(StdNames.RuntimeFn, hb.runtime_calls, f) == null) {
                std.debug.print("{s} calls {s}, missing from its runtime_calls\n", .{ hb.name, f.name() });
                return error.UnlistedCall;
            }
        }
    }
}

test "no returning builtin writes a callee-saved register it does not save" {
    const gpa = testing.allocator;
    for (runtime.hand_builtins, hand_builtins) |hb, lower| {
        // panic never returns.
        if (std.mem.eql(u8, hb.name, "panic")) continue;
        var fc = try lower(gpa);
        defer fc.deinit(gpa);
        const words = std.mem.bytesAsSlice(u32, fc.code);
        var written: u32 = 0;
        var saved: u32 = 0;
        for (words) |w| {
            const rt = w & 0x1F;
            // str xN, [sp, #imm] (unsigned offset, base sp): a save of rt.
            if (w & 0xFFC003E0 == 0xF90003E0) saved |= bitOf(rt);
            // Any instruction class whose destination field is rt and that writes a GPR:
            // data processing (immediate and register) and loads.
            const op0 = (w >> 25) & 0xF;
            const writes = op0 == 0b1000 or op0 == 0b1001 or op0 == 0b0101 or op0 == 0b1101 or
                (op0 & 0b0101 == 0b0100 and (w >> 22) & 1 == 1);
            if (writes) written |= bitOf(rt);
        }
        const callee_saved_x: u32 = 0x1FF80000; // x19-x28
        try testing.expectEqual(@as(u32, 0), written & ~saved & callee_saved_x);
    }
}

fn bitOf(r: u32) u32 {
    return @as(u32, 1) << @intCast(r);
}

test "libsystem_imports lists every symbol a hand builtin imports" {
    const gpa = testing.allocator;
    var seen: [runtime.libsystem_imports.len]bool = @splat(false);
    for (hand_builtins) |lower| {
        var fc = try lower(gpa);
        defer fc.deinit(gpa);
        for (fc.relocs) |r| if (r.target == .import) {
            for (runtime.libsystem_imports, 0..) |nm, i| {
                if (std.mem.eql(u8, nm, r.target.import.name)) {
                    seen[i] = true;
                    break;
                }
            } else return error.UnlistedImport;
        };
    }
    for (seen) |s| try testing.expect(s);
    for (runtime.libsystem_imports[1..], 0..) |nm, i| try testing.expect(std.mem.lessThan(u8, runtime.libsystem_imports[i], nm));
}

test "a hand-built main links to an image that returns 42 (no front-end)" {
    if (@import("builtin").os.tag != .macos or @import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;

    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A `main` that returns 42, built WITHOUT the front-end: just the two AArch64
    // words `movz w0, #42` (0x52800540) and `ret` (0xD65F03C0), little-endian.
    const code = try gpa.alloc(u8, 8);
    std.mem.writeInt(u32, code[0..4], 0x52800540, .little); // movz w0, #42
    std.mem.writeInt(u32, code[4..8], 0xD65F03C0, .little); // ret

    var fns = [_]Link.FnCode{.{
        .sym = .{ .kind = .user_fn, .name = try gpa.dupe(u8, "main") },
        .code = code,
        .relocs = try gpa.alloc(Link.Reloc, 0),
        .literals = try gpa.alloc(Link.Literal, 0),
    }};

    const image = try @import("../../../link/emit.zig").emitExecutable(io, gpa, &@import("../../CodegenMir.zig").CodegenMir(@This()).backends[0], &fns, .{ .kind = .user_fn, .name = "main" }, .{ .identifier = "m" });
    defer gpa.free(image);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_name_buf: [64]u8 = undefined;
    const dir_name = std.fmt.bufPrint(&dir_name_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const out_path = std.fmt.allocPrint(gpa, "{s}/m", .{dir_name}) catch unreachable;
    defer gpa.free(out_path);
    {
        const perms: std.Io.File.Permissions = .fromMode(0o755);
        var f = try std.Io.Dir.cwd().createFile(io, out_path, .{ .permissions = perms });
        defer f.close(io);
        try f.writeStreamingAll(io, image);
        try f.setPermissions(io, perms);
    }

    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, out_path, gpa);
    defer gpa.free(abs);
    {
        var cs = try std.process.spawn(io, .{ .argv = &.{ "codesign", "-v", abs } });
        const cs_term = try cs.wait(io);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, cs_term);
    }

    var child = try std.process.spawn(io, .{ .argv = &.{abs} });
    const term = try child.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test {
    _ = Inst;
    _ = Isel;
    _ = Emit;
    _ = Peephole;
    _ = reloc;
    _ = panic;
    _ = str;
    _ = @import("runtime/emit.zig");
}
