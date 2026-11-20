//! The fixed part of a fn's frame: everything whose bytes live in memory, laid out in one
//! deterministic pass over the lowered `Ir.Function`. Every IR `Slot` and every aggregate
//! IR value (a merge of a str/struct/enum) gets its own cell, laid sequentially,
//! type-sized and 8-byte aligned. Scalar values get no cell: the register allocator keeps
//! them in registers and adds its spill slots above this layout (`mir/Mir.zig`, `Frame`).
//! It is target-neutral: what it needs of the ISA and its conventions comes in as `Facts`
//! (the ISA's `abi`, see `codegen/Isa.zig`).
//!
//! LAYOUT (deterministic, in IR index order), offsets from the bottom of the frame:
//!   [ out_base       ]  outgoing stack-arg region (offsets 0..out_base). Every
//!                       slot/value offset is shifted up by this so a call's
//!                       stack args at the bottom never collide with a live slot.
//!                       out_base = the widest call's stack-arg bytes (from
//!                       `Abi.planCall`) rounded to the stack alignment, 0 if the
//!                       fn makes no calls.
//!   [ slot region    ]  each Ir.Slot: roundUp8(running) then its 8-min-aligned
//!                       size (str 16, struct/enum roundUp8(layout size),
//!                       scalar 8).
//!   [ value region   ]  each aggregate Ir.ValueDef: one cell, roundUp8(size).
//!   [ sret save slot ]  one 8-byte cell IF the result goes through a caller's
//!                       buffer (the incoming sret register is saved here once;
//!                       the body's calls clobber it).
//!   [ C scratch      ]  the C images of the extern call that needs the most.
//!   frame = (out_base + slots + values + maybe-sret + C scratch) rounded to the
//!   stack alignment.
//! Above the frame, the allocator's spills and callee-saved registers (`Mir.Frame`), then
//! the ISA's saved-register area (`Facts.saved_area`, a frame link and return address),
//! then the caller's stack arguments (the incoming area). The model names no register: a
//! native ISA addresses the incoming area from its frame pointer, and a target with no
//! machine frame (wasm32) can give it a saved area of 0 and its own frame base.
//!
//! DETERMINISM: pure, slice-indexed, no hashmaps / pointer iteration / globals.
//! Same IR + layouts => same offsets => same bytes. This underpins the VERIFY
//! byte-identity re-lower.
//!
//! GUARDS (surfaced as errors so codegen can emit the SAME diagnostic strings):
//!   * frame > `Facts.max_frame` -> error.FrameTooLarge ("function frame too
//!                              large for codegen (..)", which names one value
//!                              that nearly fills the frame by itself)
//!   * an incoming stack arg past `Facts.max_incoming_off` -> error.ParamOffsetTooLarge
//!                              ("too many parameters for codegen ...")

const std = @import("std");
const Ir = @import("../../ir/Ir.zig");
const Abi = @import("../abi/Abi.zig");
const ValueLayout = @import("../../layout/ValueLayout.zig");
const GcLayout = @import("../../layout/GcLayout.zig");

const types = @import("../../types.zig");
pub const Type = types.Type;
pub const Layout = types.Layout;
pub const EnumLayout = types.EnumLayout;
pub const VariantLayout = types.VariantLayout;

const FrameLayout = @This();

/// What one backend tells the layout: its ISA's frame rules and the two conventions its
/// calls follow. An ISA module supplies one per C convention (`abi.facts`).
pub const Facts = struct {
    /// Toy's own convention on the ISA.
    toy: Abi.Desc,
    /// The target's C convention, for extern calls and C callback adapters.
    c: Abi.Desc,
    /// The bytes between the top of a frame and its caller's stack arguments.
    saved_area: u32,
    /// The alignment of the stack pointer at a call, a power of two.
    stack_align: u32,
    /// The largest frame the encoder addresses.
    max_frame: u32,
    /// The largest offset, from the base of the saved-register area, at which the last
    /// word of an incoming stack argument is read.
    max_incoming_off: u32,

    /// The convention `func` is called in: C for a C callback adapter.
    pub fn convOf(f: *const Facts, func: *const Ir.Function) Abi.Desc {
        return if (func.c_abi) f.c else f.toy;
    }

    /// The convention a call to `callee` follows.
    pub fn callConv(f: *const Facts, callee: Ir.SymName) Abi.Desc {
        return if (isCCall(callee)) f.c else f.toy;
    }

    /// Whether a call to `callee` is a C call: under the C convention, with C images.
    pub fn isCCall(callee: Ir.SymName) bool {
        return callee.kind == .import;
    }
};

/// `sret_save_off == NO_SRET` means the result does not go through a caller's buffer.
pub const NO_SRET: u32 = std.math.maxInt(u32);

/// `value_off[v] == NO_CELL`: scalar value `v` has no cell, because the register
/// allocator keeps it in a register and gives it a spill slot only if it needs one.
pub const NO_CELL: u32 = std.math.maxInt(u32);

pub const Error = error{ OutOfMemory, FrameTooLarge, ParamOffsetTooLarge };

/// Total fixed frame bytes, a multiple of `stack_align` (> 0 only when the fn needs
/// locals/values/outgoing args).
frame: u32,
/// Outgoing stack-arg region size at the bottom of the frame (sp-relative
/// 0..out_base), a multiple of `stack_align`. 0 if the fn makes no calls.
out_base: u32,
/// The ISA's stack alignment (`Facts.stack_align`), which the rest of the frame keeps.
stack_align: u32,
/// sp-relative offset of the saved incoming sret register (the result buffer), or
/// `NO_SRET`.
sret_save_off: u32,
/// sp-relative byte offset of the region an extern call builds its C images in (see
/// `cScratchBytes`); meaningful only when some call has one.
c_scratch_off: u32 = 0,
/// sp-relative byte offset of each `Ir.Slot`, indexed by `SlotId`. Owned.
slot_off: []u32,
/// sp-relative byte offset of each `Ir.ValueDef`, indexed by `ValueId`, or `NO_CELL`.
/// Owned.
value_off: []u32,

pub fn deinit(self: *FrameLayout, gpa: std.mem.Allocator) void {
    gpa.free(self.slot_off);
    gpa.free(self.value_off);
    self.* = undefined;
}

fn roundUp8(n: u32) u32 {
    return (n + 7) / 8 * 8;
}

pub fn roundUp16(n: u32) u32 {
    return (n + 15) / 16 * 16;
}

/// Lay the next `size`-byte cell at the 8-aligned end of `running` and return
/// its offset. The bound is checked per cell in u64 because a fn's cells can sum
/// past 4 GiB; a u32 total would wrap back under `max_frame` and pass the guard.
fn place(running: *u32, out_base: u32, size: u32, max_frame: u32) error{FrameTooLarge}!u32 {
    const off = roundUp8(running.*);
    if (@as(u64, out_base) + off + size > max_frame) return error.FrameTooLarge;
    running.* = off + size;
    return out_base + off;
}

/// The largest slot `func`'s frame holds, over its slots and its values.
pub fn largestSlot(func: *const Ir.Function, layouts: []const Layout, enum_layouts: []const EnumLayout) u32 {
    var max: u32 = 0;
    for (func.slots) |sl| max = @max(max, slotSize(sl.type, layouts, enum_layouts));
    for (func.values) |v| max = @max(max, slotSize(v.type, layouts, enum_layouts));
    return max;
}

/// Per-slot frame size: a slot must hold the WHOLE value. str is 16 (ptr,len);
/// struct/enum take their layout size rounded to 8 (so the next slot stays
/// 8-aligned; struct align is <=8 today). Everything else is one 8-byte word.
fn slotSize(ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) u32 {
    return switch (ty.kind) {
        .str => 16,
        .@"struct", .@"enum" => roundUp8(ValueLayout.typeSize(ty, layouts, enum_layouts)),
        // A `()` slot occupies no bytes; its address is never taken (a unit read
        // yields `.none`), so the next slot simply shares this offset.
        .unit => 0,
        else => 8,
    };
}

/// Compute the fixed frame for `func` under `facts`. Pure over the IR + read-only layout
/// tables; allocates only the two offset slices (owned by the caller).
pub fn compute(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    comptime facts: Facts,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) Error!FrameLayout {
    comptime std.debug.assert(std.math.isPowerOfTwo(facts.stack_align));
    // (1) out_base: the widest outgoing stack-arg region over all call sites.
    // For each `call` instr, plan its outbound args (Abi.planCall) and take the
    // max stack bytes, rounded to the stack alignment so the slot region above it
    // stays aligned. The arg TYPES come from each operand's slot/value type.
    var max_stack: u32 = 0;
    {
        // A reusable scratch buffer for arg types, grown as needed.
        var arg_types: std.ArrayList(Type) = .empty;
        defer arg_types.deinit(gpa);
        for (func.blocks) |blk| {
            for (blk.instrs) |ins| {
                switch (ins.op) {
                    .call => |c| {
                        arg_types.clearRetainingCapacity();
                        try arg_types.ensureTotalCapacity(gpa, c.args.len);
                        for (0..c.args.len) |i| arg_types.appendAssumeCapacity(func.argType(c.args, c.params, c.by_ptr, i));
                        // The callee's return type drives sret, which can take a
                        // GPR argument. Use the call's own ret_slot type if
                        // present, else unit (a scalar/unit result is never sret).
                        const ret_ty: Type = if (c.ret_slot != Ir.none_slot)
                            func.slots[c.ret_slot].type
                        else
                            Type.unit;
                        var plan = try Abi.planCall(gpa, facts.callConv(c.callee), arg_types.items, c.fixedArgs(), ret_ty, layouts, enum_layouts);
                        defer plan.deinit(gpa);
                        if (plan.stack_bytes > max_stack) max_stack = plan.stack_bytes;
                    },
                    .call_indirect => |c| {
                        arg_types.clearRetainingCapacity();
                        try arg_types.ensureTotalCapacity(gpa, c.args.len);
                        for (c.args) |arg| {
                            arg_types.appendAssumeCapacity(func.operandType(arg));
                        }
                        const ret_ty: Type = if (c.ret_slot != Ir.none_slot)
                            func.slots[c.ret_slot].type
                        else
                            Type.unit;
                        var plan = try Abi.planCall(gpa, facts.toy, arg_types.items, arg_types.items.len, ret_ty, layouts, enum_layouts);
                        defer plan.deinit(gpa);
                        if (plan.stack_bytes > max_stack) max_stack = plan.stack_bytes;
                    },
                    else => {},
                }
            }
        }
    }
    const out_base: u32 = std.mem.alignForward(u32, max_stack, facts.stack_align);

    // (2) slot region: each Ir.Slot laid sequentially, 8-aligned, shifted by
    // out_base.
    const slot_off = try gpa.alloc(u32, func.slots.len);
    errdefer gpa.free(slot_off);
    var running: u32 = 0;
    for (func.slots, 0..) |slot, i| {
        slot_off[i] = try place(&running, out_base, slotSize(slot.type, layouts, enum_layouts), facts.max_frame);
    }

    // (3) value region: each aggregate value its own cell, 8-aligned.
    const value_off = try gpa.alloc(u32, func.values.len);
    errdefer gpa.free(value_off);
    for (func.values, 0..) |vdef, i| {
        if (!Abi.isAggregate(vdef.type)) {
            value_off[i] = NO_CELL;
            continue;
        }
        value_off[i] = try place(&running, out_base, slotSize(vdef.type, layouts, enum_layouts), facts.max_frame);
    }

    // (4) sret save slot (8 bytes) when the result goes through a caller's buffer.
    var sret_save_off: u32 = NO_SRET;
    if (Abi.retIsSret(facts.convOf(func), func.ret_type, layouts, enum_layouts)) {
        sret_save_off = try place(&running, out_base, 8, facts.max_frame);
    }

    // (4b) the C image region, sized for the extern call that needs the most.
    var c_scratch_off: u32 = 0;
    {
        var most: u32 = 0;
        for (func.blocks) |blk| for (blk.instrs) |ins| switch (ins.op) {
            .call => |c| most = @max(most, cScratchBytes(func, c, layouts)),
            else => {},
        };
        if (func.c_abi) most = @max(most, cAbiScratchBytes(func, layouts));
        if (most > 0) c_scratch_off = try place(&running, out_base, most, facts.max_frame);
    }

    // (5) frame = the aligned total.
    const frame: u32 = std.mem.alignForward(u32, out_base + running, facts.stack_align);

    if (frame > facts.max_frame) {
        // errdefer (registered above for both offset slices) frees them.
        return error.FrameTooLarge;
    }

    // GUARD: incoming stack args are read above the saved-register area,
    // INDEPENDENT of frame. Plan the incoming params; any stack/stack_ptr loc
    // whose last word lies past the ISA's reach is unencodable.
    {
        var param_types: std.ArrayList(Type) = .empty;
        defer param_types.deinit(gpa);
        try param_types.ensureTotalCapacity(gpa, func.params.len);
        for (func.params) |sid| param_types.appendAssumeCapacity(func.slots[sid].type);
        var pplan = try Abi.planParams(gpa, facts.convOf(func), param_types.items, func.ret_type, layouts, enum_layouts);
        defer pplan.deinit(gpa);
        for (pplan.locs) |loc| {
            const top_in: u32 = switch (loc) {
                .stack => |s| facts.saved_area + s.off + (s.bytes -| 8),
                .stack_ptr => |off| facts.saved_area + off,
                else => 0,
            };
            if (top_in > facts.max_incoming_off) {
                // errdefer (registered above) frees both offset slices.
                return error.ParamOffsetTooLarge;
            }
        }
    }

    return .{
        .frame = frame,
        .out_base = out_base,
        .stack_align = facts.stack_align,
        .sret_save_off = sret_save_off,
        .c_scratch_off = c_scratch_off,
        .slot_off = slot_off,
        .value_off = value_off,
    };
}

/// Whether `func`'s fixed frame under `facts` fits codegen's budget. Only `FrameTooLarge`
/// says no: any other layout error is codegen's to report, whatever the caller does about
/// the frame.
pub fn fits(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    comptime facts: Facts,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) error{OutOfMemory}!bool {
    var fl = compute(gpa, func, facts, layouts, enum_layouts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FrameTooLarge => return false,
        error.ParamOffsetTooLarge => return true,
    };
    fl.deinit(gpa);
    return true;
}

/// The C image an extern call passes argument `i` through: its extern struct type, or null
/// for any other argument.
pub fn cImageType(c: Ir.Call, i: usize, layouts: []const Layout) ?Type {
    if (!Facts.isCCall(c.callee) or i >= c.params.len) return null;
    return if (Abi.isCStruct(c.params[i], layouts)) c.params[i] else null;
}

/// The bytes an extern call's C images take: one per extern struct argument (by value or
/// as a `mut` param) and one for an extern struct result, in that order, each padded to
/// 16. 16 is neutral, not an AArch64 rule: no target's stack alignment is wider, and it
/// keeps any ISA's two-word register load or store (an ldp, a 16-byte vector move)
/// inside the image.
pub fn cScratchBytes(func: *const Ir.Function, c: Ir.Call, layouts: []const Layout) u32 {
    var n: u32 = 0;
    for (0..c.args.len) |i| if (cImageType(c, i, layouts)) |t| {
        n += roundUp16(Abi.cLayout(t, layouts).size);
    };
    if (Facts.isCCall(c.callee) and c.ret_slot != Ir.none_slot and Abi.isCStruct(func.slots[c.ret_slot].type, layouts))
        n += roundUp16(Abi.cLayout(func.slots[c.ret_slot].type, layouts).size);
    return n;
}

/// The C image a C callback adapter receives an extern struct param or returns its result
/// through: the largest one, as each is unpacked or packed on its own.
pub fn cAbiScratchBytes(func: *const Ir.Function, layouts: []const Layout) u32 {
    var n: u32 = 0;
    for (func.params) |sid| {
        const t = func.slots[sid].type;
        if (Abi.isCStruct(t, layouts)) n = @max(n, roundUp16(Abi.cLayout(t, layouts).size));
    }
    if (Abi.isCStruct(func.ret_type, layouts)) n = @max(n, roundUp16(Abi.cLayout(func.ret_type, layouts).size));
    return n;
}

/// One frame root: the sp-relative byte offset of a word that may hold a GC reference.
/// The collector reads how to trace what it points at off the object itself.
pub const Root = struct { off: u32 };

/// Append the roots of a cell of type `ty` based at sp-offset `base` to `out`: the offsets
/// `GcLayout` names, every variant's for an enum (a frame map has no tag to read; the
/// collector's marker checks each word against the heap, so another variant's word at
/// worst keeps something alive).
fn projectCell(
    ty: Type,
    base: u32,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
    out: *std.ArrayList(Root),
    gpa: std.mem.Allocator,
) error{OutOfMemory}!void {
    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(gpa);
    try GcLayout.appendRefOffsets(gpa, ty, base, layouts, enum_layouts, &offs);
    for (offs.items) |o| try out.append(gpa, .{ .off = o });
}

/// The per-fn ROOTS: a byproduct of the (pure) frame layout that names every frame word
/// holding a managed pointer, so the collector enumerates roots by lookup rather than a
/// conservative whole-frame scan. Walks `func.slots` (each based at `fl.slot_off[i]`)
/// then `func.values` (`fl.value_off[i]`) in index order, projecting each cell's managed
/// roots. Pure over the IR + read-only layouts, so it is content-fingerprint cacheable and
/// `-jN` byte-identical. Caller owns the result.
pub fn collectRoots(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    fl: *const FrameLayout,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) error{OutOfMemory}![]Root {
    var roots: std.ArrayList(Root) = .empty;
    errdefer roots.deinit(gpa);
    for (func.slots, 0..) |slot, i| {
        try projectCell(slot.type, fl.slot_off[i], layouts, enum_layouts, &roots, gpa);
    }
    for (func.values, 0..) |vdef, i| {
        if (fl.value_off[i] == NO_CELL) continue;
        try projectCell(vdef.type, fl.value_off[i], layouts, enum_layouts, &roots, gpa);
    }
    return roots.toOwnedSlice(gpa);
}

/// Which of `func`'s slots hold a GC reference anywhere in them. Caller owns the result.
pub fn rootedSlots(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) error{OutOfMemory}![]bool {
    const rooted = try gpa.alloc(bool, func.slots.len);
    errdefer gpa.free(rooted);
    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(gpa);
    for (func.slots, rooted) |slot, *r| {
        offs.clearRetainingCapacity();
        try GcLayout.appendRefOffsets(gpa, slot.type, 0, layouts, enum_layouts, &offs);
        r.* = offs.items.len != 0;
    }
    return rooted;
}

/// Whether a one-word value of type `ty` (a box handle, a raw pointer) is a GC reference.
pub fn isWordRef(
    gpa: std.mem.Allocator,
    ty: Type,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) error{OutOfMemory}!bool {
    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(gpa);
    try GcLayout.appendRefOffsets(gpa, ty, 0, layouts, enum_layouts, &offs);
    return std.mem.indexOfScalar(u32, offs.items, 0) != null;
}

/// The ROOT MAP the runtime reads: `roots` as a count-prefixed packed list of sp offsets,
/// `[u32 n][u32 sp_off × n]`, little-endian. A lowered toy fn always yields ≥4 bytes
/// (`[u32 0]` when root-less), so the stack map's no-row marker names only code outside
/// the text: C. Caller owns the result.
pub fn encodeRoots(gpa: std.mem.Allocator, roots: []const Root) error{OutOfMemory}![]u8 {
    const buf = try gpa.alloc(u8, 4 + roots.len * 4);
    std.mem.writeInt(u32, buf[0..4], @intCast(roots.len), .little);
    for (roots, 0..) |r, i| std.mem.writeInt(u32, buf[4 + i * 4 ..][0..4], r.off, .little);
    return buf;
}

const testing = std.testing;

/// A target with 8 argument registers per class, the shape these tests assume.
const tf: Facts = .{
    .toy = .{ .gprs = 8, .fprs = 8 },
    .c = .{ .gprs = 8, .fprs = 8, .c_structs = true, .hfa = true, .stack_slots = .@"packed", .varargs = .stack },
    .saved_area = 16,
    .stack_align = 16,
    .max_frame = 1 << 24,
    .max_incoming_off = 1 << 15,
};

// A small builder for hand-rolled IR functions. All slices are heap-allocated
// so `Function.deinit` frees them cleanly.
const TestFn = struct {
    func: Ir.Function,

    fn deinit(self: *TestFn, gpa: std.mem.Allocator) void {
        self.func.deinit(gpa);
    }
};

fn mkLayouts(gpa: std.mem.Allocator, sizes: []const u32, aligns: []const u32) ![]Layout {
    const ls = try gpa.alloc(Layout, sizes.len);
    for (sizes, 0..) |s, i| {
        ls[i] = .{
            .name = "T",
            .field_names = &.{},
            .field_types = &.{},
            .offsets = &.{},
            .size = s,
            .@"align" = aligns[i],
        };
    }
    return ls;
}

fn allocSlots(gpa: std.mem.Allocator, types_: []const Type) ![]Ir.Slot {
    const s = try gpa.alloc(Ir.Slot, types_.len);
    for (types_, 0..) |t, i| s[i] = .{ .type = t };
    return s;
}

fn allocValues(gpa: std.mem.Allocator, types_: []const Type) ![]Ir.ValueDef {
    const v = try gpa.alloc(Ir.ValueDef, types_.len);
    for (types_, 0..) |t, i| v[i] = .{ .type = t };
    return v;
}

// Build a 1-block function with the given slots/values and a single ret-none
// terminator (no instrs). For exercising slot/value offset math.
fn buildSimple(
    gpa: std.mem.Allocator,
    slot_types: []const Type,
    value_types: []const Type,
    param_count: usize,
    ret_type: Type,
) !Ir.Function {
    const slots = try allocSlots(gpa, slot_types);
    const values = try allocValues(gpa, value_types);
    const params = try gpa.alloc(Ir.SlotId, param_count);
    for (0..param_count) |i| params[i] = @intCast(i);
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{
        .params = try gpa.alloc(Ir.ValueId, 0),
        .instrs = try gpa.alloc(Ir.Instr, 0),
        .term = .{ .ret = .none },
    };
    return .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = params,
        .ret_type = ret_type,
        .slots = slots,
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
}

test "frame: empty fn (no slots, no values, no calls) -> frame 0" {
    const gpa = testing.allocator;
    var func = try buildSimple(gpa, &.{}, &.{}, 0, Type.unit);
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), fl.frame);
    try testing.expectEqual(@as(u32, 0), fl.out_base);
    try testing.expectEqual(NO_SRET, fl.sret_save_off);
    try testing.expectEqual(@as(usize, 0), fl.slot_off.len);
    try testing.expectEqual(@as(usize, 0), fl.value_off.len);
}

test "frame: slots and aggregate values lay out sequentially, 8-aligned, 16-aligned frame; scalar values get no cell" {
    const gpa = testing.allocator;
    // 2 int slots, an int value, a str value, an int value, no calls.
    var func = try buildSimple(
        gpa,
        &.{ Type.int, Type.int },
        &.{ Type.int, Type.str, Type.int },
        0,
        Type.int,
    );
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);

    // out_base 0; slots at 0,8; the str value at 16; running=32; frame 32.
    try testing.expectEqual(@as(u32, 0), fl.out_base);
    try testing.expectEqual(@as(u32, 0), fl.slot_off[0]);
    try testing.expectEqual(@as(u32, 8), fl.slot_off[1]);
    try testing.expectEqual(NO_CELL, fl.value_off[0]);
    try testing.expectEqual(@as(u32, 16), fl.value_off[1]);
    try testing.expectEqual(NO_CELL, fl.value_off[2]);
    try testing.expectEqual(@as(u32, 32), fl.frame);
    try testing.expectEqual(NO_SRET, fl.sret_save_off);
}

test "frame: a unit slot is 0 bytes and shares the next slot's offset" {
    const gpa = testing.allocator;
    // int, unit, int slots: the unit contributes 0 bytes, so slot 2 shares slot 1's
    // offset — the frame matches an [int, int] layout with a degenerate middle slot.
    var func = try buildSimple(gpa, &.{ Type.int, Type.unit, Type.int }, &.{}, 0, Type.int);
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), fl.slot_off[0]);
    try testing.expectEqual(@as(u32, 8), fl.slot_off[1]);
    try testing.expectEqual(@as(u32, 8), fl.slot_off[2]);
    // slots run 0,8,8..16 (running=16); frame roundUp16(16)=16.
    try testing.expectEqual(@as(u32, 16), fl.frame);
}

test "frame: str slot occupies 16 bytes and keeps following slots 8-aligned" {
    const gpa = testing.allocator;
    // int, str, int slots: offsets 0, 8, 24.
    var func = try buildSimple(
        gpa,
        &.{ Type.int, Type.str, Type.int },
        &.{},
        0,
        Type.unit,
    );
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), fl.slot_off[0]);
    try testing.expectEqual(@as(u32, 8), fl.slot_off[1]); // str
    try testing.expectEqual(@as(u32, 24), fl.slot_off[2]); // 8 + 16
    // running = 32 -> frame roundUp16(32) = 32.
    try testing.expectEqual(@as(u32, 32), fl.frame);
}

test "frame: aggregate slot uses roundUp8 of its layout size" {
    const gpa = testing.allocator;
    // struct 0 = 24B align 8, struct 1 = 12B align 8.
    const ls = try mkLayouts(gpa, &.{ 24, 12 }, &.{ 8, 8 });
    defer gpa.free(ls);

    var func = try buildSimple(
        gpa,
        &.{ Type.structT(0), Type.structT(1), Type.int },
        &.{},
        0,
        Type.unit,
    );
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, ls, &.{});
    defer fl.deinit(gpa);

    // struct0 (24) at 0; struct1 (12 -> roundUp8 16) at 24; int at 40.
    try testing.expectEqual(@as(u32, 0), fl.slot_off[0]);
    try testing.expectEqual(@as(u32, 24), fl.slot_off[1]);
    try testing.expectEqual(@as(u32, 40), fl.slot_off[2]);
    // running = 48 -> frame 48.
    try testing.expectEqual(@as(u32, 48), fl.frame);
}

test "frame: many aggregate merge values each get their own cell" {
    const gpa = testing.allocator;
    // a deeply-nested chain of str merges: 20 str values.
    var vtypes: [20]Type = undefined;
    for (&vtypes) |*v| v.* = Type.str;
    var func = try buildSimple(gpa, &.{}, &vtypes, 0, Type.int);
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);

    // 20 values * 16 = 320; each at i*16.
    for (0..20) |i| {
        try testing.expectEqual(@as(u32, @intCast(i * 16)), fl.value_off[i]);
    }
    try testing.expectEqual(@as(u32, 320), fl.frame);
}

test "frame: out_base reserves the widest outgoing stack-arg region over call sites" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};

    // Build a fn with two call instrs: one with 8 int args (no stack bytes), one with
    // 10 int args (2 stack words, 16 bytes). out_base = 16.
    const slots = try allocSlots(gpa, &.{Type.int}); // one local slot (a result)
    // 10 value defs to serve as scalar args.
    var vtypes: [10]Type = undefined;
    for (&vtypes) |*v| v.* = Type.int;
    const values = try allocValues(gpa, &vtypes);

    // call A: 8 args. call B: 10 args.
    const args_a = try gpa.alloc(Ir.Operand, 8);
    for (0..8) |i| args_a[i] = .{ .value = @intCast(i) };
    const args_b = try gpa.alloc(Ir.Operand, 10);
    for (0..10) |i| args_b[i] = .{ .value = @intCast(i) };

    const instrs = try gpa.alloc(Ir.Instr, 2);
    instrs[0] = .{ .result = Ir.none_value, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "a" },
        .args = args_a,
        .ret_slot = Ir.none_slot,
    } } };
    instrs[1] = .{ .result = Ir.none_value, .op = .{ .call = .{
        .callee = .{ .kind = .user_fn, .name = "b" },
        .args = args_b,
        .ret_slot = Ir.none_slot,
    } } };

    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{
        .params = try gpa.alloc(Ir.ValueId, 0),
        .instrs = instrs,
        .term = .{ .ret = .none },
    };
    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "caller" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Type.unit,
        .slots = slots,
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, ls, el);
    defer fl.deinit(gpa);

    // out_base = 16; slots shifted up by it.
    try testing.expectEqual(@as(u32, 16), fl.out_base);
    try testing.expectEqual(@as(u32, 16), fl.slot_off[0]); // the one slot at out_base
    try testing.expectEqual(@as(u32, 32), fl.frame);
}

test "frame: sret return reserves an 8-byte save slot atop the frame" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{24}, &.{8}); // 24B -> sret
    defer gpa.free(ls);

    // fn returns a 24B struct; one int slot.
    var func = try buildSimple(gpa, &.{Type.int}, &.{}, 0, Type.structT(0));
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, tf, ls, &.{});
    defer fl.deinit(gpa);

    // slot at 0 (8 bytes); sret save at 8; running 16; frame 16.
    try testing.expectEqual(@as(u32, 0), fl.slot_off[0]);
    try testing.expectEqual(@as(u32, 8), fl.sret_save_off);
    try testing.expectEqual(@as(u32, 16), fl.frame);
}

test "frame: a target with no saved area and an 8-aligned stack (an x86-64 or wasm32 shape)" {
    const gpa = testing.allocator;
    const nf: Facts = .{
        .toy = .{ .gprs = 6, .fprs = 8, .sret_uses_gpr = true, .spill_exhausts = false },
        .c = .{ .gprs = 6, .fprs = 8, .sret_uses_gpr = true, .spill_exhausts = false, .c_structs = true },
        .saved_area = 0,
        .stack_align = 8,
        .max_frame = 1 << 24,
        .max_incoming_off = 8,
    };
    const ls = try mkLayouts(gpa, &.{24}, &.{8});
    defer gpa.free(ls);

    // A call with 7 int args puts one word on the stack: out_base 8, not 16.
    const values = try allocValues(gpa, &([_]Type{Type.int} ** 7));
    const args = try gpa.alloc(Ir.Operand, 7);
    for (0..7) |i| args[i] = .{ .value = @intCast(i) };
    const instrs = try gpa.alloc(Ir.Instr, 1);
    instrs[0] = .{ .result = Ir.none_value, .op = .{ .call = .{ .callee = .{ .kind = .user_fn, .name = "g" }, .args = args, .ret_slot = Ir.none_slot } } };
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .none } };
    // 7 int params: the walk gives the sret buffer GPR 0, so params 5 and 6 go on the
    // stack at 0 and 8; with no saved area the last is read at 8, the limit.
    const params = try gpa.alloc(Ir.SlotId, 7);
    for (0..7) |i| params[i] = @intCast(i);
    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = params,
        .ret_type = Type.structT(0),
        .slots = try allocSlots(gpa, &([_]Type{Type.int} ** 8)),
        .values = values,
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
    defer func.deinit(gpa);

    var fl = try compute(gpa, &func, nf, ls, &.{});
    defer fl.deinit(gpa);
    try testing.expectEqual(@as(u32, 8), fl.out_base);
    try testing.expectEqual(@as(u32, 8), fl.slot_off[0]);
    // 8 slots, then the sret save slot: 8 + 64 + 8, a multiple of 8, not rounded to 16.
    try testing.expectEqual(@as(u32, 72), fl.sret_save_off);
    try testing.expectEqual(@as(u32, 80), fl.frame);

    const more = comptime blk: {
        var m = nf;
        m.max_incoming_off = 7;
        break :blk m;
    };
    try testing.expectError(error.ParamOffsetTooLarge, compute(gpa, &func, more, ls, &.{}));
}

test "frame: a C callback adapter sizes sret and its C image by the C layout" {
    const gpa = testing.allocator;
    // Three int32s: 24 bytes in toy layout (sret), 12 in C (x registers).
    const three = [_]Type{ Type.int32, Type.int32, Type.int32 };
    const ls = [_]Layout{.{ .name = "Three", .field_names = &.{}, .field_types = @constCast(&three), .offsets = &.{}, .size = 24, .@"align" = 8, .is_extern = true }};
    var func = try buildSimple(gpa, &.{Type.structT(0)}, &.{}, 1, Type.structT(0));
    defer func.deinit(gpa);
    var toy = try compute(gpa, &func, tf, &ls, &.{});
    defer toy.deinit(gpa);
    try testing.expect(toy.sret_save_off != NO_SRET);
    func.c_abi = true;
    var c = try compute(gpa, &func, tf, &ls, &.{});
    defer c.deinit(gpa);
    try testing.expectEqual(NO_SRET, c.sret_save_off);
    try testing.expectEqual(@as(u32, 24), c.c_scratch_off);
    try testing.expectEqual(@as(u32, 48), c.frame);
}

test "frame: a frame past 4 KiB lays out; FrameTooLarge only past max_frame" {
    const gpa = testing.allocator;
    // 300 str values * 16 = 4800 (#32).
    var vtypes: [300]Type = undefined;
    for (&vtypes) |*v| v.* = Type.str;
    var func = try buildSimple(gpa, &.{}, &vtypes, 0, Type.int);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);
    try testing.expectEqual(@as(u32, 4800), fl.frame);
    try testing.expectEqual(@as(u32, 4784), fl.value_off[299]);

    var slot = try buildSimple(gpa, &.{Type.structT(0)}, &.{}, 0, Type.unit);
    defer slot.deinit(gpa);
    const at_cap_layout = [_]Layout{.{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = tf.max_frame - 8, .@"align" = 8 }};
    var at_cap = try compute(gpa, &slot, tf, &at_cap_layout, &.{});
    defer at_cap.deinit(gpa);
    try testing.expectEqual(tf.max_frame, at_cap.frame);
    const over = [_]Layout{.{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = tf.max_frame + 1, .@"align" = 8 }};
    try testing.expectError(error.FrameTooLarge, compute(gpa, &slot, tf, &over, &.{}));
}

test "frame: fits is false only past max_frame" {
    const gpa = testing.allocator;
    var func = try buildSimple(gpa, &.{Type.structT(0)}, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    const small = [_]Layout{.{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = 4096, .@"align" = 8 }};
    const big = [_]Layout{.{ .name = "B", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = tf.max_frame + 1, .@"align" = 8 }};
    try testing.expect(try fits(gpa, &func, tf, &small, &.{}));
    try testing.expect(!try fits(gpa, &func, tf, &big, &.{}));
}

test "frame: slots summing past 4 GiB give FrameTooLarge, not a wrapped total" {
    const gpa = testing.allocator;
    var slot_types: [257]Type = undefined;
    for (&slot_types) |*t| t.* = Type.structT(0);
    var func = try buildSimple(gpa, &slot_types, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    const max = [_]Layout{.{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = tf.max_frame - 8, .@"align" = 8 }};
    try testing.expectError(error.FrameTooLarge, compute(gpa, &func, tf, &max, &.{}));
}

// A `Layout` with the given fields (owned arrays freed by the caller).
fn mkLayoutFields(gpa: std.mem.Allocator, fts: []const Type, offs: []const u32, size: u32, fam: NativeFam) !Layout {
    return .{
        .name = "T",
        .field_names = &.{},
        .field_types = try gpa.dupe(Type, fts),
        .offsets = try gpa.dupe(u32, offs),
        .size = size,
        .@"align" = 8,
        .native_family = fam,
    };
}

const NativeFam = @import("../../layout/Engine.zig").NativeStructFamily;

test "roots: scalar-only fn yields [u32 0]" {
    const gpa = testing.allocator;
    var func = try buildSimple(gpa, &.{ Type.int, Type.bool }, &.{Type.int}, 0, Type.int);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &.{}, &.{});
    defer gpa.free(bm);
    try testing.expectEqual(@as(usize, 0), bm.len);
    const bytes = try encodeRoots(gpa, bm);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes);
}

test "roots: a str VALUE is projected at its value cell" {
    const gpa = testing.allocator;
    // one int slot (off 0), one str value (off 8): its pointer half is the root.
    var func = try buildSimple(gpa, &.{Type.int}, &.{Type.str}, 0, Type.int);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &.{}, &.{});
    defer gpa.free(bm);
    try testing.expectEqual(@as(usize, 1), bm.len);
    try testing.expectEqual(fl.value_off[0], bm[0].off);
    const bytes = try encodeRoots(gpa, bm);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 8), bytes.len); // [u32 n][u32 off]
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[0..4], .little));
    try testing.expectEqual(fl.value_off[0], std.mem.readInt(u32, bytes[4..8], .little));
}

test "cells: scalar values get no cell and no root; isWordRef names a reference word" {
    const gpa = testing.allocator;
    var func = try buildSimple(gpa, &.{Type.rawptr}, &.{ Type.rawptr, Type.int, Type.str }, 0, Type.int);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);
    try testing.expectEqual(NO_CELL, fl.value_off[0]);
    try testing.expectEqual(NO_CELL, fl.value_off[1]);
    try testing.expectEqual(@as(u32, 8), fl.value_off[2]);
    try testing.expectEqual(@as(u32, 32), fl.frame);
    const bm = try collectRoots(gpa, &func, &fl, &.{}, &.{});
    defer gpa.free(bm);
    // The rawptr slot and the str value's pointer half; the rawptr value lives in a register.
    try testing.expectEqual(@as(usize, 2), bm.len);
    try testing.expectEqual(@as(u32, 0), bm[0].off);
    try testing.expectEqual(@as(u32, 8), bm[1].off);

    try testing.expect(try isWordRef(gpa, Type.rawptr, &.{}, &.{}));
    try testing.expect(!try isWordRef(gpa, Type.int, &.{}, &.{}));
}

test "roots: a str slot projects the ptr half only (base+0), not the len at +8" {
    const gpa = testing.allocator;
    var func = try buildSimple(gpa, &.{ Type.int, Type.str }, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &.{}, &.{});
    defer gpa.free(bm);
    try testing.expectEqual(@as(usize, 1), bm.len);
    try testing.expectEqual(fl.slot_off[1], bm[0].off); // the str slot's ptr half
}

test "roots: a by-value aggregate recurses to its contained box (Bag{Vec[int], int})" {
    const gpa = testing.allocator;
    // struct 0 = the inner gc_array box, size 8, no sub-fields.
    // struct 1 = Vec-like {box @0}, size 8. struct 2 = Bag {Vec @0, int @8}, size 16.
    var ls: [3]Layout = undefined;
    ls[0] = try mkLayoutFields(gpa, &.{}, &.{}, 8, .gc_array);
    ls[1] = try mkLayoutFields(gpa, &.{Type.structT(0)}, &.{0}, 8, .none);
    ls[2] = try mkLayoutFields(gpa, &.{ Type.structT(1), Type.int }, &.{ 0, 8 }, 16, .none);
    defer for (&ls) |*l| {
        gpa.free(l.field_types);
        gpa.free(l.offsets);
    };

    var func = try buildSimple(gpa, &.{Type.structT(2)}, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &ls, &.{});
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &ls, &.{});
    defer gpa.free(bm);
    // Bag → Vec@0 → box@0: one recursed root at the Bag slot's base (offset 0 within).
    try testing.expectEqual(@as(usize, 1), bm.len);
    try testing.expectEqual(fl.slot_off[0], bm[0].off);
}

test "roots: an enum unions its variants' box payload offsets; a () field contributes nothing" {
    const gpa = testing.allocator;
    // box struct 0 (.ref, 8B). enum 0: payload_off 8; variant A carries a box @ local 0,
    // variant B carries a () (no field). Union → one root at slot_base + payload_off.
    var ls: [1]Layout = undefined;
    ls[0] = try mkLayoutFields(gpa, &.{}, &.{}, 8, .ref);
    defer {
        gpa.free(ls[0].field_types);
        gpa.free(ls[0].offsets);
    }

    const va = VariantLayout{ .name = "A", .form = .tuple, .field_names = &.{}, .field_types = try gpa.dupe(Type, &.{Type.structT(0)}), .offsets = try gpa.dupe(u32, &.{0}) };
    const vb = VariantLayout{ .name = "B", .form = .unit, .field_names = &.{}, .field_types = try gpa.dupe(Type, &.{}), .offsets = try gpa.dupe(u32, &.{}) };
    defer {
        gpa.free(va.field_types);
        gpa.free(va.offsets);
        gpa.free(vb.field_types);
        gpa.free(vb.offsets);
    }
    var vars = [_]VariantLayout{ va, vb };
    const el = [_]EnumLayout{.{ .name = "E", .variants = &vars, .tag_size = 8, .payload_off = 8, .size = 16, .@"align" = 8 }};

    var func = try buildSimple(gpa, &.{Type.enumT(0)}, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &ls, &el);
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &ls, &el);
    defer gpa.free(bm);
    try testing.expectEqual(@as(usize, 1), bm.len);
    try testing.expectEqual(fl.slot_off[0] + 8, bm[0].off); // payload_off within the enum slot
}

test "a fn-pair struct slot projects one root at +8" {
    const gpa = testing.allocator;
    // The {code: int @0, env: rawptr @8} pair a function type reifies to: the code word
    // is not a managed pointer, the env word is.
    var ls: [1]Layout = undefined;
    ls[0] = try mkLayoutFields(gpa, &.{ Type.int, Type.rawptr }, &.{ 0, 8 }, 16, .none);
    ls[0].fn_sig = .{ .params = &.{Type.int}, .ret = Type.int };
    defer {
        gpa.free(ls[0].field_types);
        gpa.free(ls[0].offsets);
    }
    var func = try buildSimple(gpa, &.{Type.structT(0)}, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &ls, &.{});
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &ls, &.{});
    defer gpa.free(bm);
    try testing.expectEqual(@as(usize, 1), bm.len);
    try testing.expectEqual(fl.slot_off[0] + 8, bm[0].off);
}

test "roots: an env struct's Vec, str, rawptr, Ref, fn-pair env and Option[Vec] words are roots; an int none" {
    const gpa = testing.allocator;
    // struct 0 = a gc_array box (a Vec), 1 = a Ref box, 2 = a fn pair, 3 = a frame env.
    var ls: [4]Layout = undefined;
    ls[0] = try mkLayoutFields(gpa, &.{}, &.{}, 8, .gc_array);
    ls[1] = try mkLayoutFields(gpa, &.{}, &.{}, 8, .ref);
    ls[2] = try mkLayoutFields(gpa, &.{ Type.int, Type.rawptr }, &.{ 0, 8 }, 16, .none);
    ls[2].fn_sig = .{ .params = &.{}, .ret = Type.int };
    ls[3] = try mkLayoutFields(
        gpa,
        &.{ Type.structT(0), Type.str, Type.rawptr, Type.structT(1), Type.structT(2), Type.int, Type.enumT(0) },
        &.{ 0, 8, 24, 32, 40, 56, 64 },
        80,
        .none,
    );
    defer for (&ls) |*l| {
        gpa.free(l.field_types);
        gpa.free(l.offsets);
    };
    const none_v = VariantLayout{ .name = "none", .form = .unit, .field_names = &.{}, .field_types = try gpa.dupe(Type, &.{}), .offsets = try gpa.dupe(u32, &.{}) };
    const some_v = VariantLayout{ .name = "some", .form = .tuple, .field_names = &.{}, .field_types = try gpa.dupe(Type, &.{Type.structT(0)}), .offsets = try gpa.dupe(u32, &.{0}) };
    defer for ([_]VariantLayout{ none_v, some_v }) |v| {
        gpa.free(v.field_types);
        gpa.free(v.offsets);
    };
    var vars = [_]VariantLayout{ none_v, some_v };
    const el = [_]EnumLayout{.{ .name = "Option", .variants = &vars, .tag_size = 8, .payload_off = 8, .size = 16, .@"align" = 8 }};

    var func = try buildSimple(gpa, &.{Type.structT(3)}, &.{}, 0, Type.unit);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &ls, &el);
    defer fl.deinit(gpa);
    const bm = try collectRoots(gpa, &func, &fl, &ls, &el);
    defer gpa.free(bm);
    const base = fl.slot_off[0];
    const want_off = [_]u32{ 0, 8, 24, 32, 48, 72 };
    try testing.expectEqual(@as(usize, want_off.len), bm.len);
    for (want_off, bm) |o, r| try testing.expectEqual(base + o, r.off);
}

test "roots: projection is deterministic (two calls byte-identical)" {
    const gpa = testing.allocator;
    var func = try buildSimple(gpa, &.{ Type.int, Type.str }, &.{ Type.rawptr, Type.int }, 0, Type.int);
    defer func.deinit(gpa);
    var fl = try compute(gpa, &func, tf, &.{}, &.{});
    defer fl.deinit(gpa);
    const ra = try collectRoots(gpa, &func, &fl, &.{}, &.{});
    defer gpa.free(ra);
    const rb = try collectRoots(gpa, &func, &fl, &.{}, &.{});
    defer gpa.free(rb);
    const a = try encodeRoots(gpa, ra);
    defer gpa.free(a);
    const b = try encodeRoots(gpa, rb);
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, a, b);
}
