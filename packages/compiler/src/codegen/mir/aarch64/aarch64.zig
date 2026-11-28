//! The AArch64 ISA module (the interface is `codegen/Isa.zig`): the selector, the
//! encoder and the relocation kinds, plus what the
//! target-independent allocator needs: the registers it may hand out, the scratch
//! register its move resolver uses, and the instructions that move a value between
//! registers and stack slots.

const std = @import("std");
const Mir = @import("../Mir.zig");
const Link = @import("../../../link/Link.zig");
const Isa = @import("../../Isa.zig");
const Target = @import("../../../Target.zig");
pub const Inst = @import("Inst.zig");
pub const Isel = @import("Isel.zig");
pub const Emit = @import("Emit.zig");
pub const Peephole = @import("Peephole.zig");
pub const abi = @import("abi.zig");
const reloc = @import("reloc.zig");

pub const relocs: Link.Patcher = reloc.patcher;

pub const c_abis = [_]Target.CAbi{ .aapcs64_apple, .aapcs64 };

/// Every AArch64 instruction is one 4-byte word.
pub fn instCount(code: []const u8) usize {
    return code.len / 4;
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

/// The fn the loader calls in `main`'s place, with argc in x0 and argv in x1 (dyld, and
/// glibc's `__libc_start_main`): it stores both in the control block words core reads
/// (#60 T10), then tail-jumps to `main`, so `main` returns straight to the loader and
/// keeps toy's no-param convention for calls from toy code. Caller owns the result.
pub fn entryStub(gpa: std.mem.Allocator, main: Link.SymName) error{OutOfMemory}!Link.FnCode {
    comptime std.debug.assert(Link.argv_off == Link.argc_off + 8);
    const words = [_]u32{
        Aarch64.adrp(16, 0),
        Aarch64.addImm(16, 16, 0),
        Aarch64.strRegUoff(0, 16, 0),
        Aarch64.strRegUoff(1, 16, 8),
        Aarch64.b(0),
    };
    const code = try gpa.alloc(u8, words.len * 4);
    errdefer gpa.free(code);
    for (words, 0..) |w, i| std.mem.writeInt(u32, code[i * 4 ..][0..4], w, .little);
    const rels = try gpa.alloc(Link.Reloc, 3);
    errdefer gpa.free(rels);
    const target = try gpa.dupe(u8, main.name);
    errdefer gpa.free(target);
    const name = try gpa.dupe(u8, "_toy_entry");
    rels[0] = .{ .site = 0, .target = .{ .data = Link.argc_off }, .kind = reloc.of(.adrp_page) };
    rels[1] = .{ .site = 4, .target = .{ .data = Link.argc_off }, .kind = reloc.of(.add_lo12) };
    rels[2] = .{ .site = 16, .target = .{ .func = .{ .kind = main.kind, .name = target } }, .kind = reloc.of(.jump26) };
    return .{ .sym = .{ .kind = .builtin, .name = name }, .code = code, .relocs = rels, .literals = &.{} };
}

/// The `_start` a glibc process enters at, as glibc's `csu/start.S` writes it (#60 T9):
/// glibc must finish its own setup before `main`, so `_start` hands `entry` (the
/// `entryStub` in `main`'s place) to
/// `__libc_start_main(entry, argc, argv, init, fini, rtld_fini, stack_end)`, which calls
/// `exit` with what `main` returns. The kernel leaves argc at `[sp]` with argv above it,
/// and the dynamic linker's finalizer in x0. A zero frame record ends every stack walk
/// here. Caller owns the result.
pub fn startStub(gpa: std.mem.Allocator, entry: Link.SymName) error{OutOfMemory}!Link.FnCode {
    const words = [_]u32{
        Aarch64.movz(Aarch64.FP, 0, 0),
        Aarch64.movz(Aarch64.LR, 0, 0),
        Aarch64.movReg(5, 0),
        Aarch64.ldrSp(1, 0),
        Aarch64.addImm(2, Aarch64.SP, 8),
        Aarch64.addImm(6, Aarch64.SP, 0),
        Aarch64.adrp(0, 0),
        Aarch64.addImm(0, 0, 0),
        Aarch64.movz(3, 0, 0),
        Aarch64.movz(4, 0, 0),
        Aarch64.adrp(16, 0),
        Aarch64.ldrRegUoff(16, 16, 0),
        Aarch64.blr(16),
        Aarch64.brk0,
    };
    const code = try gpa.alloc(u8, words.len * 4);
    errdefer gpa.free(code);
    for (words, 0..) |w, i| std.mem.writeInt(u32, code[i * 4 ..][0..4], w, .little);
    const rels = try gpa.alloc(Link.Reloc, 4);
    var named: usize = 0;
    errdefer {
        for (rels[0..named]) |r| gpa.free(r.target.name().?);
        gpa.free(rels);
    }
    const sites = [_]struct { u32, reloc.Kind, bool }{ .{ 24, .adrp_page, true }, .{ 28, .add_lo12, true }, .{ 40, .adrp_page, false }, .{ 44, .ldr_lo12, false } };
    for (sites, rels) |st, *r| {
        const target: Link.SymbolId = if (st[2])
            .{ .func = .{ .kind = entry.kind, .name = try gpa.dupe(u8, entry.name) } }
        else
            .{ .import = .{ .kind = .import, .name = try gpa.dupe(u8, "__libc_start_main") } };
        r.* = .{ .site = st[0], .target = target, .kind = reloc.of(st[1]) };
        named += 1;
    }
    const name = try gpa.dupe(u8, "_start");
    return .{ .sym = .{ .kind = .builtin, .name = name }, .code = code, .relocs = rels, .literals = &.{} };
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
    var func = try refAcrossCallFn(gpa, .{ .kind = .user_fn, .name = "core/rt/str.str_eq" });
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

test "mir: a call to a core/rt fn is no safepoint and keeps the reference in a register" {
    const gpa = testing.allocator;
    var func = try refAcrossCallFn(gpa, .{ .kind = .user_fn, .name = "core/rt/str.str_eq" });
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
}

test "the entry stub stores argc and argv in the control block and tail-jumps to main" {
    const gpa = testing.allocator;
    var fc = try entryStub(gpa, .{ .kind = .user_fn, .name = "main" });
    defer fc.deinit(gpa);
    const w = wordsOf(fc);
    // Reference words from GNU as.
    try testing.expectEqual(@as(u32, 0xF9000200), w[2]); // str x0, [x16]
    try testing.expectEqual(@as(u32, 0xF9000601), w[3]); // str x1, [x16, #8]
    try testing.expectEqual(@as(u32, 0x14000000), w[4]); // b .
    try testing.expectEqual(@as(usize, 3), fc.relocs.len);
    try testing.expectEqual(@as(u32, Link.argc_off), fc.relocs[0].target.data);
    try testing.expectEqual(reloc.of(.add_lo12), fc.relocs[1].kind);
    try testing.expectEqualStrings("main", fc.relocs[2].target.func.name);
    try testing.expectEqual(reloc.of(.jump26), fc.relocs[2].kind);
    try testing.expectEqual(@as(u32, 16), fc.relocs[2].site);
}

test "the glibc _start sets up __libc_start_main's arguments as crt1.o does and never returns" {
    const gpa = testing.allocator;
    var fc = try startStub(gpa, .{ .kind = .user_fn, .name = "main" });
    defer fc.deinit(gpa);
    try testing.expectEqualStrings("_start", fc.sym.name);
    const w = wordsOf(fc);
    // Reference words from GNU as for glibc's aarch64 start.S.
    try testing.expectEqual(@as(u32, 0xD280001D), w[0]); // mov x29, #0
    try testing.expectEqual(@as(u32, 0xD280001E), w[1]); // mov x30, #0
    try testing.expectEqual(@as(u32, 0xAA0003E5), w[2]); // mov x5, x0
    try testing.expectEqual(@as(u32, 0xF94003E1), w[3]); // ldr x1, [sp]
    try testing.expectEqual(@as(u32, 0x910023E2), w[4]); // add x2, sp, #8
    try testing.expectEqual(@as(u32, 0x910003E6), w[5]); // mov x6, sp
    try testing.expectEqual(@as(u32, 0xD2800003), w[8]); // mov x3, #0
    try testing.expectEqual(@as(u32, 0xD2800004), w[9]); // mov x4, #0
    try testing.expectEqual(@as(u32, 0xD63F0200), w[12]); // blr x16
    try testing.expectEqual(Aarch64.brk0, w[13]);
    try testing.expectEqual(@as(usize, 4), fc.relocs.len);
    try testing.expectEqualStrings("main", fc.relocs[0].target.func.name);
    try testing.expectEqual(@as(u32, 24), fc.relocs[0].site);
    try testing.expectEqualStrings("main", fc.relocs[1].target.func.name);
    try testing.expectEqualStrings("__libc_start_main", fc.relocs[2].target.import.name);
    try testing.expectEqual(reloc.of(.ldr_lo12), fc.relocs[3].kind);
    try testing.expectEqual(@as(u32, 44), fc.relocs[3].site);
}
