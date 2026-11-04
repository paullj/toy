//! The GC facts a selector hands the allocator, read off the IR alone: which IR values
//! are references, which calls are safepoints, and which arguments a call must keep
//! rooted. Every target's selector takes them from here, so a second target (#60) cannot
//! leave one out and keep a reference where no stack map sees it.

const std = @import("std");
const Ir = @import("../../ir/Ir.zig");
const Abi = @import("../abi/Abi.zig");
const FrameLayout = @import("../frame/FrameLayout.zig");
const runtime = @import("../runtime/runtime.zig");
const types = @import("../../types.zig");
const StdNames = @import("../../symbols/StdNames.zig");

/// Per IR value, whether its register holds a reference. An aggregate value lives in memory the frame's map names, so it has none. A
/// `field_addr` result counts too: it may point into a heap object whose base is dead
/// by the next safepoint. Caller owns the result.
pub fn valueRefs(
    gpa: std.mem.Allocator,
    ir: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
) error{OutOfMemory}![]bool {
    const refs = try gpa.alloc(bool, ir.values.len);
    errdefer gpa.free(refs);
    for (ir.values, refs) |vd, *r| {
        r.* = inRegister(vd.type) and try FrameLayout.isWordRef(gpa, vd.type, layouts, enum_layouts);
    }
    for (ir.blocks) |blk| for (blk.instrs) |ins| switch (ins.op) {
        .field_addr => if (ins.result != Ir.none_value and inRegister(ir.values[ins.result].type)) {
            refs[ins.result] = true;
        },
        else => {},
    };
    return refs;
}

fn inRegister(ty: types.Type) bool {
    return ty.kind != .unit and !Abi.isAggregate(ty);
}

pub const CallFacts = struct {
    /// The call may reach the collector: no register holds a reference across it.
    safepoint: bool = true,
    /// Each reference argument stays live, in its slot, across the call. A C callee may
    /// call back into toy and collect while only its own registers hold the argument, and
    /// no scan reads registers. A toy callee roots its params in its own frame.
    keep_ref_args: bool = false,
};

pub fn callFacts(callee: Ir.SymName) CallFacts {
    return switch (callee.kind) {
        .builtin => .{ .safepoint = runtime.mayCollect(callee.name) },
        .import => .{ .keep_ref_args = true },
        .user_fn => .{ .safepoint = StdNames.userCallMayCollect(callee.name) },
    };
}

const testing = std.testing;
const Type = types.Type;

test "callFacts: builtins that never collect are no safepoint; a C call keeps its reference args" {
    try testing.expect(!callFacts(.{ .kind = .builtin, .name = "panic" }).safepoint);
    try testing.expect(callFacts(.{ .kind = .builtin, .name = "__str_concat" }).safepoint);
    const c = callFacts(.{ .kind = .import, .name = "strlen" });
    try testing.expect(c.safepoint and c.keep_ref_args);
    const t = callFacts(.{ .kind = .user_fn, .name = "f" });
    try testing.expect(t.safepoint and !t.keep_ref_args);
}

test "callFacts: a core/rt fn is no safepoint; a minted unit in a core/rt module still is" {
    try testing.expect(!callFacts(.{ .kind = .user_fn, .name = "core/rt/str.str_eq" }).safepoint);
    try testing.expect(callFacts(.{ .kind = .user_fn, .name = "core/rt/str.f$int" }).safepoint);
    try testing.expect(callFacts(.{ .kind = .user_fn, .name = "core/mem.ga_push$int" }).safepoint);
    try testing.expect(callFacts(.{ .kind = .user_fn, .name = "core/rt/gc.alloc" }).safepoint);
    try testing.expect(!callFacts(.{ .kind = .user_fn, .name = "core/rt/gc.collections" }).safepoint);
}

test "valueRefs: a rawptr value and a field address are references; an int is not" {
    const gpa = testing.allocator;
    const values = try gpa.alloc(Ir.ValueDef, 3);
    values[0] = .{ .type = Type.int };
    values[1] = .{ .type = Type.rawptr };
    values[2] = .{ .type = Type.int };
    const instrs = try gpa.alloc(Ir.Instr, 1);
    instrs[0] = .{ .result = 2, .op = .{ .field_addr = .{ .base = 1, .off = 8, .ty = Type.int } } };
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .none } };
    var func: Ir.Function = .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
    defer func.deinit(gpa);
    const refs = try valueRefs(gpa, &func, &.{}, &.{});
    defer gpa.free(refs);
    try testing.expectEqualSlices(bool, &.{ false, true, true }, refs);
}
