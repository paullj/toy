//! The backend: `Ir.Function` -> `Link.FnCode` through instruction selection, a register
//! allocator and the encoder (see `mir/Mir.zig` for the design). A fn it cannot lower
//! (a frame past codegen's budget, or a shape the selector does not cover) comes back as a
//! diagnostic and an empty `FnCode`, so the build fails cleanly.
//!
//! STACK MAPS. Under linear scan the fn's `root_bitmap` names only its memory roots (the
//! reference words of its IR slots and aggregate values), and `safepoint_maps` adds one
//! row per safepoint call whose roots differ from the row before it: the memory roots plus
//! the spill slots that hold a reference live across that call. The collector looks a
//! frame up by its return address, so it lands on the row of the call the frame is in.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const FrameLayout = @import("frame/FrameLayout.zig");
const Link = @import("../link/Link.zig");
const types = @import("../types.zig");
const Mir = @import("mir/Mir.zig");
const LinearScan = @import("mir/LinearScan.zig");
const Target = @import("mir/aarch64/Target.zig");
const Isel = @import("mir/aarch64/Isel.zig");
const Emit = @import("mir/aarch64/Emit.zig");

const Diagnostic = @import("../diagnostics/Diagnostic.zig").Diagnostic;

/// Lower `func` to machine code. A fn the backend cannot lower records one diagnostic in
/// `diags` and returns an empty `FnCode`; the caller fails the build on it. Caller owns
/// the result.
pub fn lowerMir(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
    is_entry: bool,
    diags: *std.ArrayList(Diagnostic),
) error{OutOfMemory}!Link.FnCode {
    var frame: Mir.Frame = .{ .layout = FrameLayout.compute(gpa, func, layouts, enum_layouts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FrameTooLarge => return fail(gpa, func, diags, frameTooLargeMessage(func, layouts, enum_layouts)),
        error.ParamOffsetTooLarge => return fail(gpa, func, diags, "too many parameters for codegen (stack-arg offset out of range)"),
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
    Isel.select(gpa, .{
        .ir = func,
        .layouts = layouts,
        .enum_layouts = enum_layouts,
        .is_entry = is_entry,
        .fl = &frame.layout,
        .roots = roots,
    }, &mf, &literals) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return fail(gpa, func, diags, "internal compiler error: codegen met a value shape it does not cover"),
    };
    if (std.debug.runtime_safety) {
        std.debug.assert(try mf.tempsStayLocal(gpa));
        std.debug.assert(!mf.namesAny(Target.reserved));
        std.debug.assert(mf.callRegsAgree(~Target.Inst.caller_saved));
    }

    var maps = LinearScan.LinearScan(Target).run(gpa, &mf, &frame) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unallocatable => return fail(gpa, func, diags, "internal compiler error: an instruction needs more registers than codegen has"),
    };
    defer maps.deinit(gpa);
    std.debug.assert(mf.allPhysical());
    if (frame.size() > FrameLayout.MAX_FRAME) return fail(gpa, func, diags, frameTooLargeMessage(func, layouts, enum_layouts));

    var out: Emit.Out = .{};
    defer out.deinit(gpa);
    Emit.encode(gpa, &mf, &frame, func.line, &out) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BranchOutOfRange => return fail(gpa, func, diags, "function too large for codegen (a branch is out of range)"),
    };

    const root_bitmap = try FrameLayout.encodeRoots(gpa, roots);
    errdefer gpa.free(root_bitmap);
    const safepoint_maps = try encodeSafepoints(gpa, roots, maps.maps, out.safepoints.items, &frame);
    errdefer gpa.free(safepoint_maps);
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
    return .{
        .sym = .{ .kind = func.name.kind, .name = name },
        .code = code,
        .relocs = try out.relocs.toOwnedSlice(gpa),
        .literals = owned_literals,
        .root_bitmap = root_bitmap,
        .safepoint_maps = safepoint_maps,
        .lines = lines,
    };
}

/// Record `message` against `func` and return its empty `FnCode`, so the driver fails the
/// build on the diagnostic rather than linking a half-lowered fn.
fn fail(gpa: std.mem.Allocator, func: *const Ir.Function, diags: *std.ArrayList(Diagnostic), message: []const u8) error{OutOfMemory}!Link.FnCode {
    try diags.append(gpa, .{ .byte_offset = 0, .end = 0, .message = message });
    return .{
        .sym = .{ .kind = func.name.kind, .name = try gpa.dupe(u8, func.name.name) },
        .code = &.{},
        .relocs = &.{},
        .literals = &.{},
    };
}

/// A struct or enum may take a whole frame (T0077 stops only a larger one), and then the
/// frame has no room for the fn's other values; "too many locals" would misname that.
fn frameTooLargeMessage(func: *const Ir.Function, layouts: []const types.Layout, enum_layouts: []const types.EnumLayout) []const u8 {
    if (FrameLayout.largestSlot(func, layouts, enum_layouts) > FrameLayout.MAX_FRAME - 64 * 1024)
        return "function frame too large for codegen (one value nearly fills the 16 MiB frame; hold large data in a Vec)";
    return "function frame too large for codegen (too many locals)";
}

/// The `FnCode.safepoint_maps` rows: per safepoint call at `offs[i]`, the memory roots plus
/// `maps[i]`'s slots, as `[u32 code_off][u32 n][{u32 sp_off, u32 tag} x n]`. A row equal to
/// the one before it (the fn-start row of memory roots, first) is left out: the collector
/// takes the last row at or before a frame's call, which then has the same roots.
fn encodeSafepoints(
    gpa: std.mem.Allocator,
    roots: []const FrameLayout.Root,
    maps: []const []const LinearScan.Root,
    offs: []const u32,
    frame: *const Mir.Frame,
) error{OutOfMemory}![]u8 {
    std.debug.assert(maps.len == 0 or maps.len == offs.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var row: std.ArrayList(FrameLayout.Root) = .empty;
    defer row.deinit(gpa);
    var prev: []const LinearScan.Root = &.{};
    for (maps, offs) |m, off| {
        if (std.mem.eql(u8, std.mem.sliceAsBytes(m), std.mem.sliceAsBytes(prev))) continue;
        prev = m;
        row.clearRetainingCapacity();
        try row.appendSlice(gpa, roots);
        for (m) |r| try row.append(gpa, .{ .off = frame.spOffset(.{ .spill = r.spill }), .tag = r.tag });
        const payload = try FrameLayout.encodeRoots(gpa, row.items);
        defer gpa.free(payload);
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, off, .little);
        try out.appendSlice(gpa, &w);
        try out.appendSlice(gpa, payload);
    }
    return out.toOwnedSlice(gpa);
}

comptime {
    _ = Mir;
    _ = @import("mir/Liveness.zig");
    _ = @import("mir/GcFacts.zig");
    _ = @import("mir/Interval.zig");
    _ = @import("mir/Moves.zig");
    _ = @import("mir/LinearScan.zig");
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

/// `lowerMir` on a fn it must lower without a diagnostic.
fn lowerOk(gpa: std.mem.Allocator, func: *const Ir.Function) !Link.FnCode {
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(gpa);
    var fc = try lowerMir(gpa, func, &.{}, &.{}, false, &diags);
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

test "mir: a fn lowers through MIR with the x29 frame, its params stored to their slots, its lines kept" {
    const gpa = testing.allocator;
    var func = try addFn(gpa);
    defer func.deinit(gpa);
    var fl = try FrameLayout.compute(gpa, &func, &.{}, &.{});
    defer fl.deinit(gpa);

    var fc = try lowerOk(gpa, &func);
    defer fc.deinit(gpa);
    try testing.expectEqual(Aarch64.stpFpLrPre, wordsOf(fc)[0]);
    try testing.expectEqual(Aarch64.movFpSp, wordsOf(fc)[1]);
    try testing.expectEqual(Aarch64.ret, wordsOf(fc)[wordsOf(fc).len - 1]);
    try testing.expect(hasWord(fc, Aarch64.strRegUoff(0, Aarch64.SP, fl.slot_off[0])));
    try testing.expect(hasWord(fc, Aarch64.strRegUoff(1, Aarch64.SP, fl.slot_off[1])));
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
    try testing.expect(hasWord(fc, Aarch64.addReg(0, 10, 11)));
    // prologue (3) + 2 param stores + 2 slot addresses and loads + add + epilogue (3)
    try testing.expect(wordsOf(fc).len <= 13);
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
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, fc.root_bitmap);
    var rows: Link.SafepointRows = .{ .bytes = fc.safepoint_maps };
    const row = rows.next().?;
    try testing.expect(rows.next() == null);
    // The row sits on the bl, and names the param slot and the value's spill slot after it.
    try testing.expectEqual(Aarch64.bl(0), wordsOf(fc)[row.code_off / 4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, row.payload[0..4], .little));
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, row.payload[12..16], .little));
}

test "mir: a call to a builtin that never collects is no safepoint and keeps the reference in a register" {
    const gpa = testing.allocator;
    var func = try refAcrossCallFn(gpa, .{ .kind = .builtin, .name = "gc_span_count" });
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
    var fc = try lowerMir(gpa, &func, &.{}, &.{}, false, &diags);
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
        .{ .sizes = &.{ FrameLayout.MAX_FRAME, 8 }, .message = "function frame too large for codegen (one value nearly fills the 16 MiB frame; hold large data in a Vec)" },
        .{ .sizes = &.{ 14 << 20, 14 << 20 }, .message = "function frame too large for codegen (too many locals)" },
    };
    for (cases) |k| {
        var layouts: [2]types.Layout = undefined;
        for (&layouts, k.sizes) |*l, sz| l.* = .{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = sz, .@"align" = 8 };
        var func = try slotsOnlyFn(gpa, &.{ Type.structT(0), Type.structT(1) });
        defer func.deinit(gpa);
        var diags: std.ArrayList(Diagnostic) = .empty;
        defer diags.deinit(gpa);
        var fc = try lowerMir(gpa, &func, &layouts, &.{}, false, &diags);
        defer fc.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), diags.items.len);
        try testing.expectEqualStrings(k.message, diags.items[0].message);
    }
}

test "mir: the prologue zeroes a frame env's container word" {
    const gpa = testing.allocator;
    // struct 0 = a gc_array box (a Vec); struct 1 = a frame env { n: int, xs: Vec, s: str }.
    var env_types = [_]Type{ Type.int, Type.structT(0), Type.str };
    var env_offs = [_]u32{ 0, 8, 16 };
    const layouts = [_]types.Layout{
        .{ .name = "V", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = 8, .@"align" = 8, .native_family = .gc_array },
        .{ .name = "env$f$l0", .field_names = &.{}, .field_types = &env_types, .offsets = &env_offs, .size = 32, .@"align" = 8 },
    };
    var func = try slotsOnlyFn(gpa, &.{ Type.int, Type.structT(1) });
    defer func.deinit(gpa);
    var fl = try FrameLayout.compute(gpa, &func, &layouts, &.{});
    defer fl.deinit(gpa);

    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(gpa);
    var fc = try lowerMir(gpa, &func, &layouts, &.{}, false, &diags);
    defer fc.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
    const env = fl.slot_off[1];
    try testing.expect(hasWord(fc, Aarch64.strSp(Aarch64.XZR, env + 8)));
    try testing.expect(!hasWord(fc, Aarch64.strSp(Aarch64.XZR, env)));
    try testing.expect(!hasWord(fc, Aarch64.strSp(Aarch64.XZR, env + 16)));
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
    try Isel.select(gpa, .{ .ir = &func, .layouts = &.{}, .enum_layouts = &.{}, .is_entry = false, .fl = &frame.layout, .roots = &.{} }, &mf, &literals);
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
    try Isel.select(gpa, .{ .ir = &func, .layouts = &.{}, .enum_layouts = &.{}, .is_entry = false, .fl = &frame.layout, .roots = &.{} }, &mf, &literals);
    var polls: usize = 0;
    for (mf.blocks, 0..) |b, bi| for (b.insts.items) |i| if (i.op == .safepoint_poll) {
        polls += 1;
        try testing.expectEqual(@as(usize, 2), bi);
    };
    try testing.expectEqual(@as(usize, 1), polls);
}
