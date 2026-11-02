//! The MIR backend (`--backend=mir`): `Ir.Function` -> `Link.FnCode` through instruction
//! selection, the spill-every-vreg allocator and the encoder (see `mir/Mir.zig` for the
//! design). A fn the selector cannot handle yet comes back as a `Fallback`, and the caller
//! lowers it with the spill backend (`CodegenIr`), so a build mixes both per fn.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const FrameLayout = @import("frame/FrameLayout.zig");
const Link = @import("../link/Link.zig");
const types = @import("../types.zig");
const Mir = @import("mir/Mir.zig");
const SpillAll = @import("mir/SpillAll.zig").SpillAll;
const Target = @import("mir/aarch64/Target.zig");
const Isel = @import("mir/aarch64/Isel.zig");
const Emit = @import("mir/aarch64/Emit.zig");

pub const Fallback = Isel.Fallback;

pub const Result = union(enum) {
    code: Link.FnCode,
    fallback: Fallback,
};

/// Lower `func` with the MIR backend, or say why it must take the spill one. A frame the
/// fixed layout already rejects falls back too, so the spill backend reports it.
pub fn lowerMir(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
    is_entry: bool,
) error{OutOfMemory}!Result {
    var frame: Mir.Frame = .{ .layout = FrameLayout.compute(gpa, func, layouts, enum_layouts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FrameTooLarge, error.ParamOffsetTooLarge => return .{ .fallback = .too_large },
    } };
    defer frame.deinit(gpa);
    const roots = try FrameLayout.collectRoots(gpa, func, &frame.layout, layouts, enum_layouts);
    defer gpa.free(roots);

    var literals: std.ArrayList(Link.Literal) = .empty;
    defer {
        for (literals.items) |l| gpa.free(l.bytes);
        literals.deinit(gpa);
    }
    for (func.literals) |lit| try Isel.addLiteral(gpa, &literals, lit.hash, lit.bytes);

    var mf = try Isel.newFunc(gpa, func);
    defer mf.deinit(gpa);
    var why: Fallback = undefined;
    Isel.select(gpa, .{
        .ir = func,
        .layouts = layouts,
        .enum_layouts = enum_layouts,
        .is_entry = is_entry,
        .fl = &frame.layout,
        .roots = roots,
    }, &mf, &literals, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return .{ .fallback = why },
    };
    if (std.debug.runtime_safety) {
        std.debug.assert(try mf.tempsStayLocal(gpa));
        std.debug.assert(!mf.namesAny(Target.reserved));
        std.debug.assert(mf.callRegsAgree(~Target.Inst.caller_saved));
    }

    try SpillAll(Target).run(gpa, &mf, &frame);
    std.debug.assert(mf.allPhysical());
    if (frame.size() > FrameLayout.MAX_FRAME) return .{ .fallback = .too_large };

    var out: Emit.Out = .{};
    defer out.deinit(gpa);
    Emit.encode(gpa, &mf, &frame, func.line, &out) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BranchOutOfRange => return .{ .fallback = .too_large },
    };

    const root_bitmap = try FrameLayout.encodeRoots(gpa, roots);
    errdefer gpa.free(root_bitmap);
    const name = try gpa.dupe(u8, func.name.name);
    errdefer gpa.free(name);
    const code = try out.code.toOwnedSlice(gpa);
    errdefer gpa.free(code);
    const lines = try out.lines.toOwnedSlice(gpa);
    errdefer gpa.free(lines);
    const owned_literals = try literals.toOwnedSlice(gpa);
    errdefer {
        for (owned_literals) |l| gpa.free(l.bytes);
        gpa.free(owned_literals);
    }
    return .{ .code = .{
        .sym = .{ .kind = func.name.kind, .name = name },
        .code = code,
        .relocs = try out.relocs.toOwnedSlice(gpa),
        .literals = owned_literals,
        .root_bitmap = root_bitmap,
        .lines = lines,
    } };
}

comptime {
    _ = Mir;
    _ = @import("mir/SpillAll.zig");
    _ = Target.Inst;
    _ = Isel;
    _ = Emit;
}

const testing = std.testing;
const Type = types.Type;
const Aarch64 = @import("Aarch64.zig");

fn wordsOf(fc: Link.FnCode) []align(1) const u32 {
    return std.mem.bytesAsSlice(u32, fc.code);
}

fn hasWord(fc: Link.FnCode, w: u32) bool {
    for (wordsOf(fc)) |x| if (x == w) return true;
    return false;
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

test "mir: a fn lowers through MIR with the x29 frame, its params stored to their slots, its lines kept" {
    const gpa = testing.allocator;
    var func = try addFn(gpa);
    defer func.deinit(gpa);
    var fl = try FrameLayout.compute(gpa, &func, &.{}, &.{});
    defer fl.deinit(gpa);

    var r = try lowerMir(gpa, &func, &.{}, &.{}, false);
    try testing.expect(r == .code);
    defer r.code.deinit(gpa);
    const fc = r.code;
    try testing.expectEqual(Aarch64.stpFpLrPre, wordsOf(fc)[0]);
    try testing.expectEqual(Aarch64.movFpSp, wordsOf(fc)[1]);
    try testing.expectEqual(Aarch64.ret, wordsOf(fc)[wordsOf(fc).len - 1]);
    try testing.expect(hasWord(fc, Aarch64.strRegUoff(0, Aarch64.SP, fl.slot_off[0])));
    try testing.expect(hasWord(fc, Aarch64.strRegUoff(1, Aarch64.SP, fl.slot_off[1])));
    // The add reads both values from their cells into scratch and stores the sum to its own.
    try testing.expect(hasWord(fc, Aarch64.addReg(11, 9, 10)));
    try testing.expect(hasWord(fc, Aarch64.strRegUoff(11, Aarch64.SP, fl.value_off[4])));
    // The result reaches x0 before the epilogue.
    try testing.expect(hasWord(fc, Aarch64.movReg(0, 9)));
    try testing.expectEqual(@as(usize, 3), fc.lines.len);
    try testing.expectEqual(@as(u32, 0), fc.lines[0].line);
    try testing.expectEqual(@as(u32, 2), fc.lines[2].line);
    // The stack map is the spill backend's: no reference here, so an empty count.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, fc.root_bitmap);
}

test "mir: a shape the selector does not cover falls back with its reason" {
    const gpa = testing.allocator;
    var func = try addFn(gpa);
    defer func.deinit(gpa);
    func.values[1].type = Type.unit;
    const r = try lowerMir(gpa, &func, &.{}, &.{}, false);
    try testing.expectEqual(Result{ .fallback = .non_scalar_value }, r);
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

    var frame: Mir.Frame = .{ .layout = try FrameLayout.compute(gpa, &func, &.{}, &.{}) };
    defer frame.deinit(gpa);
    var mf = try Isel.newFunc(gpa, &func);
    defer mf.deinit(gpa);
    var literals: std.ArrayList(Link.Literal) = .empty;
    defer literals.deinit(gpa);
    var why: Fallback = undefined;
    try Isel.select(gpa, .{ .ir = &func, .layouts = &.{}, .enum_layouts = &.{}, .is_entry = false, .fl = &frame.layout, .roots = &.{} }, &mf, &literals, &why);
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

    var frame: Mir.Frame = .{ .layout = try FrameLayout.compute(gpa, &func, &.{}, &.{}) };
    defer frame.deinit(gpa);
    var mf = try Isel.newFunc(gpa, &func);
    defer mf.deinit(gpa);
    var literals: std.ArrayList(Link.Literal) = .empty;
    defer literals.deinit(gpa);
    var why: Fallback = undefined;
    try Isel.select(gpa, .{ .ir = &func, .layouts = &.{}, .enum_layouts = &.{}, .is_entry = false, .fl = &frame.layout, .roots = &.{} }, &mf, &literals, &why);
    var polls: usize = 0;
    for (mf.blocks, 0..) |b, bi| for (b.insts.items) |i| if (i.op == .safepoint_poll) {
        polls += 1;
        try testing.expectEqual(@as(usize, 2), bi);
    };
    try testing.expectEqual(@as(usize, 1), polls);
}
