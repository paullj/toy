//! Calling-convention placement, target-neutral: the ONE walk that turns typed values
//! into argument registers and stack offsets, for toy's own convention and every C one.
//! Sizes and alignments come from `layout/ValueLayout.zig`. The walk reads only a `Desc`,
//! the facts of one convention on one ISA; the ISA module supplies them (`abi` in
//! `codegen/Isa.zig`), with the registers each argument index names. A location here is
//! an index into the ISA's argument registers of a class, or an offset into the stack
//! argument area, never a register number.
//!
//! WHY one walk: the prologue (`planParams`), the call site (`planCall`) and the frame's
//! outgoing area (`planCall(...).stack_bytes`) once had three copies of it that drifted
//! apart, and a disagreement put an argument at the wrong offset. One walk keeps them
//! consistent by construction.
//!
//! PURITY: every function is pure over `Type` + the read-only layout tables; the plans
//! allocate only their result slice. This keeps the VERIFY byte-identity re-lower sound.
//!
//! THE WALK, per argument, with a GPR counter, an FPR counter and a stack offset:
//!   * a scalar (int/bool/pointer) takes the next GPR, else a stack slot.
//!   * a bare float takes the next FPR, else a stack slot. The two counters are
//!     independent.
//!   * an aggregate of up to 16 bytes takes a run of 1 or 2 GPRs if the whole run fits,
//!     else goes wholly to the stack; `spill_exhausts` then forbids later arguments the
//!     GPRs left over.
//!   * a larger aggregate passes a pointer to a copy, in a GPR or a stack slot.
//!   * a `()` takes nothing.
//!   * an indirect result's buffer pointer goes in the ISA's sret register; it takes the
//!     first GPR argument only when `sret_uses_gpr`.
//!   * under a C convention (`c_structs`) an extern struct goes by its C layout: a
//!     homogeneous float aggregate in FPRs (`hfa`), else by its C size; one over 16 bytes
//!     by pointer or, under `big_c_struct = .memory`, copied whole onto the stack.
//!   * a stack slot is 8 bytes, or a C scalar's own size under `stack_slots = .packed`;
//!     varargs go as fixed arguments, or each in an 8-byte stack slot under
//!     `varargs = .stack`.
//!
//! The AArch64 conventions (`aapcs64_apple`, `aapcs64`, toy's) are in
//! `mir/aarch64/abi.zig`. x86-64's `sysv64` (#60 C3) will supply: 6 GPR arguments
//! (rdi, rsi, rdx, rcx, r8, r9) and 8 XMM ones; `sret_uses_gpr` (the buffer in rdi);
//! `big_c_struct = .memory` (MEMORY-class structs are copied onto the stack);
//! `spill_exhausts = false`; 8-byte stack slots; varargs as fixed arguments, the selector
//! setting %al to the count of `fpr` locations in the plan; no `hfa`. The one SysV rule
//! the description does not hold yet is the per-eightbyte INTEGER/SSE class of a small
//! struct (`{int64, float}` in rdi and xmm0): C3 adds it as a `Desc` rule and a location.

const std = @import("std");
const Typecheck = @import("../../types.zig");
const ValueLayout = @import("../../layout/ValueLayout.zig");

pub const Type = Typecheck.Type;
pub const Layout = Typecheck.Layout;
pub const EnumLayout = Typecheck.EnumLayout;

/// One calling convention on one ISA, as the placement walk reads it.
pub const Desc = struct {
    /// How many argument registers of each class (the ISA's lists have this many).
    gprs: u8,
    fprs: u8,
    /// Whether an indirect result's buffer pointer takes the first GPR argument.
    sret_uses_gpr: bool = false,
    /// Whether an aggregate that does not fit the registers left of its class exhausts
    /// them, so no later argument takes one: the GPRs for a struct, the FPRs for an HFA
    /// (both AAPCS64 rules; SysV has neither).
    spill_exhausts: bool = true,
    stack_slots: enum { word, @"packed" } = .word,
    varargs: enum { as_fixed, stack } = .as_fixed,
    /// Whether an extern struct goes in its C layout (`cLayout`), as a C convention does.
    c_structs: bool = false,
    /// Whether a homogeneous float aggregate of up to 4 elements goes in FPRs.
    hfa: bool = false,
    /// How an extern struct over 16 bytes goes: a pointer to a copy, or the copy itself
    /// on the stack.
    big_c_struct: enum { pointer, memory } = .pointer,
};

/// Argument class:
///   * `scalar`    — an integer/bool: one GPR / one stack slot.
///   * `fp`        — a bare float: one FPR / one stack slot.
///   * `reg_pair`  — aggregate <=16B: a 1- or 2-eightbyte GPR run.
///   * `indirect`  — aggregate >16B: passed/returned via a pointer (sret for a result).
///   * `zero`      — a zero-sized value (`()`): consumes no register and no stack
///                  byte. Gated on `.unit` (never `typeSize==0`, which also matches
///                  `never`/`invalid`), so only a genuine unit value is placed here.
pub const AbiClass = enum { scalar, fp, reg_pair, indirect, zero };

/// Whether a type is a value AGGREGATE (str / struct / enum) — passed in a reg
/// pair (<=16B) or indirect (>16B), copied by bytes.
pub fn isAggregate(ty: Type) bool {
    return ty.isAggregateValue();
}

/// How many 8-byte "eightbytes" a <=16-byte reg-pair value occupies (1 or 2).
pub fn eightbytes(size: u32) u32 {
    return (size + 7) / 8;
}

/// The class of a type: a non-aggregate is `scalar`; an aggregate is
/// `reg_pair` (<=16B) or `indirect` (>16B). Single source of truth for the
/// reg-pair vs indirect split.
pub fn classify(ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) AbiClass {
    // A `()` value occupies no register and no stack byte. Gated on `.unit` (not
    // `typeSize==0`) so `never`/`invalid` (also size 0) keep their historic
    // `.scalar` placement — the additive-vs-baseline invariant.
    if (ty.kind == .unit) return .zero;
    // A bare float rides the FPR sequence. Checked BEFORE the
    // aggregate test so a struct-with-float-field (kind `.@"struct"`, never
    // `.float`) correctly stays on the GPR reg-pair/indirect path.
    if (ty.kind == .float) return .fp;
    if (!isAggregate(ty)) return .scalar;
    return if (ValueLayout.typeSize(ty, layouts, enum_layouts) <= 16) .reg_pair else .indirect;
}

/// Where one parameter (or one outbound call argument) lives. The same encoding serves
/// both directions (incoming prologue + outgoing call). A register is an index into the
/// ISA's argument registers of its class; a stack offset is relative to the stack
/// argument area.
///
///   * `gpr`       — a scalar OR a reg-pair aggregate occupying `count` (1 or 2)
///                   consecutive GPR arguments from index `first`.
///   * `gpr_ptr`   — an INDIRECT (>16B) aggregate whose POINTER is passed in GPR
///                   argument `reg` (the bytes live elsewhere).
///   * `stack`     — a value placed WHOLLY on the stack: `bytes` total at `off`.
///   * `stack_ptr` — an INDIRECT aggregate whose POINTER (8 bytes) sits on the stack at
///                   this offset.
pub const ParamLoc = union(enum) {
    gpr: struct { first: u8, count: u8 },
    gpr_ptr: u8,
    /// A bare float scalar in FPR argument `fpr`. A float past the last FPR reuses
    /// `.stack` (8 raw bytes moved by GPR loads/stores, correct for the f64 bit pattern).
    fpr: u8,
    /// A C homogeneous floating-point aggregate (an extern struct of up to four floats
    /// or four doubles) in `count` consecutive FPR arguments from `first`, one element
    /// each; `single` when the elements are float32.
    fpr_run: struct { first: u8, count: u8, single: bool },
    stack: struct { off: u32, bytes: u32 },
    stack_ptr: u32,
    /// A zero-sized value (`()`): consumes no register and no stack byte; the
    /// emitter stores/loads nothing. Its presence in the union forces every
    /// `ParamLoc`/`ArgLoc` switch to handle it, so a unit param/arg can never silently
    /// mis-place an adjacent argument.
    zero,
};

/// Outbound call arguments use the exact same location encoding as parameters.
pub const ArgLoc = ParamLoc;

/// Where a function's RESULT lands:
///   * `none`   — unit (no result register).
///   * `reg`    — a scalar (1 reg) or a reg-pair aggregate (`regs` = 1 or 2), in the
///                ISA's GPR result registers.
///   * `fp_reg` — a bare float in the first FPR result register.
///   * `sret`   — an indirect (>16B) aggregate: the CALLER passes a buffer pointer in
///                the ISA's sret register; the callee writes through it.
pub const RetLoc = union(enum) {
    none,
    reg: struct { regs: u8 },
    fp_reg,
    sret,
};

/// Classify a function's return type under toy's convention.
pub fn classifyRet(ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) RetLoc {
    if (ty.kind == .unit) return .none;
    switch (classify(ty, layouts, enum_layouts)) {
        .scalar => return .{ .reg = .{ .regs = 1 } },
        .fp => return .fp_reg,
        .reg_pair => return .{ .reg = .{ .regs = @intCast(eightbytes(ValueLayout.typeSize(ty, layouts, enum_layouts))) } },
        .indirect => return .sret,
        // Unreachable in practice (the `.unit` early-out above), but the switch
        // must stay exhaustive over `AbiClass`.
        .zero => return .none,
    }
}

/// The argument-placement walk. Fills `out_locs[i]` for each `types_[i]` (the args from
/// `fixed` on are C varargs) and returns the stack-argument bytes, before any rounding.
fn walk(
    d: Desc,
    types_: []const Type,
    fixed: usize,
    sret: bool,
    out_locs: []ParamLoc,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) u32 {
    std.debug.assert(out_locs.len == types_.len);
    var w: Walk = .{ .d = d, .ngrn = if (sret and d.sret_uses_gpr) 1 else 0 };
    for (types_, 0..) |ty, i| {
        if (i >= fixed and d.varargs == .stack) {
            out_locs[i] = w.stack(8, 8);
            continue;
        }
        if (d.c_structs and isCStruct(ty, layouts)) {
            const size = cLayout(ty, layouts).size;
            if (if (d.hfa) hfaOf(ty, layouts) else null) |h| {
                if (w.nsrn + h.count <= d.fprs) {
                    out_locs[i] = .{ .fpr_run = .{ .first = @intCast(w.nsrn), .count = h.count, .single = h.single } };
                    w.nsrn += h.count;
                } else {
                    if (d.spill_exhausts) w.nsrn = d.fprs;
                    out_locs[i] = w.stack(eightbytes(size) * 8, 8);
                }
            } else if (size > 16) {
                out_locs[i] = switch (d.big_c_struct) {
                    .pointer => w.pointer(),
                    .memory => w.stack(eightbytes(size) * 8, 8),
                };
            } else out_locs[i] = w.gprRun(eightbytes(size));
            continue;
        }
        out_locs[i] = switch (classify(ty, layouts, enum_layouts)) {
            // A zero-sized value touches no counter, so a later real arg keeps its
            // register/offset (a unit param never shifts its neighbours).
            .zero => .zero,
            .fp => w.fpr(ty),
            .indirect => w.pointer(),
            .reg_pair => w.gprRun(eightbytes(ValueLayout.typeSize(ty, layouts, enum_layouts))),
            .scalar => if (w.ngrn < d.gprs) w.gprRun(1) else w.scalarStack(ty),
        };
    }
    return w.nsaa;
}

/// The walk's counters: the next GPR and FPR argument, and the stack offset.
const Walk = struct {
    d: Desc,
    ngrn: u32 = 0,
    nsrn: u32 = 0,
    nsaa: u32 = 0,

    fn stack(w: *Walk, bytes: u32, @"align": u32) ParamLoc {
        const off = std.mem.alignForward(u32, w.nsaa, @"align");
        w.nsaa = off + bytes;
        return .{ .stack = .{ .off = off, .bytes = bytes } };
    }

    fn fpr(w: *Walk, ty: Type) ParamLoc {
        if (w.nsrn >= w.d.fprs) return w.scalarStack(ty);
        w.nsrn += 1;
        return .{ .fpr = @intCast(w.nsrn - 1) };
    }

    fn scalarStack(w: *Walk, ty: Type) ParamLoc {
        const bytes: u32 = if (w.d.stack_slots == .@"packed") cScalarSize(ty) else 8;
        return w.stack(bytes, bytes);
    }

    /// A run of `n` GPRs, or the whole value on the stack when the run does not fit.
    fn gprRun(w: *Walk, n: u32) ParamLoc {
        if (w.ngrn + n <= w.d.gprs) {
            const first = w.ngrn;
            w.ngrn += n;
            return .{ .gpr = .{ .first = @intCast(first), .count = @intCast(n) } };
        }
        if (w.d.spill_exhausts) w.ngrn = w.d.gprs;
        return w.stack(n * 8, 8);
    }

    fn pointer(w: *Walk) ParamLoc {
        if (w.ngrn < w.d.gprs) {
            w.ngrn += 1;
            return .{ .gpr_ptr = @intCast(w.ngrn - 1) };
        }
        // A packed stack arg before the pointer may leave the offset off an 8-byte
        // boundary.
        const off = std.mem.alignForward(u32, w.nsaa, 8);
        w.nsaa = off + 8;
        return .{ .stack_ptr = off };
    }
};

/// The bytes a scalar takes as a C argument on the stack or as a C struct field: a narrow
/// int its width, a `bool` one byte (C `_Bool`), a `float32` four, everything else 8.
pub fn cScalarSize(ty: Type) u32 {
    return switch (ty.kind) {
        .bool => 1,
        .float => if (ty.isFloat32()) 4 else 8,
        .int => switch (ty.int_desc.width) {
            .w8 => 1,
            .w16 => 2,
            .w32 => 4,
            .plat, .w64 => 8,
        },
        else => 8,
    };
}

/// The full incoming-parameter plan for a function: where each param arrives, plus
/// whether an indirect-result buffer pointer arrives in the ISA's sret register.
pub const ParamPlan = struct {
    /// True when the result goes through a caller's buffer: the callee must save the
    /// sret register before the body clobbers it.
    sret: bool,
    /// One location per parameter, in declaration order. Owned by the caller;
    /// free with `gpa.free`.
    locs: []ParamLoc,

    pub fn deinit(self: *ParamPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locs);
        self.* = undefined;
    }
};

/// Plan the incoming parameters of a function with signature `params -> ret` under `d`.
/// The result `locs` slice is allocated with `gpa`.
pub fn planParams(
    gpa: std.mem.Allocator,
    d: Desc,
    params: []const Type,
    ret: Type,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) error{OutOfMemory}!ParamPlan {
    const locs = try gpa.alloc(ParamLoc, params.len);
    errdefer gpa.free(locs);
    const sret = retIsSret(d, ret, layouts, enum_layouts);
    _ = walk(d, params, params.len, sret, locs, layouts, enum_layouts);
    return .{ .sret = sret, .locs = locs };
}

/// Whether a function returning `ret` under `d` returns through a caller's buffer.
pub fn retIsSret(d: Desc, ret: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) bool {
    if (d.c_structs and isCStruct(ret, layouts)) return cRet(d, ret, layouts) == .sret;
    return classifyRet(ret, layouts, enum_layouts) == .sret;
}

/// The full outbound-argument plan for one call site.
pub const CallPlan = struct {
    /// One location per argument, in source order. Owned by the caller; free
    /// with `gpa.free`.
    locs: []ArgLoc,
    /// Total outgoing stack-argument bytes, before the frame rounds its outgoing area
    /// (`FrameLayout.out_base`, the max over calls) to the stack alignment.
    stack_bytes: u32,
    /// True when the callee returns through a buffer: the caller points the sret
    /// register at it before the call.
    sret: bool,

    pub fn deinit(self: *CallPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locs);
        self.* = undefined;
    }
};

/// Plan the outbound arguments of a call to a callee with signature `args -> ret` under
/// `d`; the args from `fixed` on are C varargs (`args.len` for a call that has none).
pub fn planCall(
    gpa: std.mem.Allocator,
    d: Desc,
    args: []const Type,
    fixed: usize,
    ret: Type,
    layouts: []const Layout,
    enum_layouts: []const EnumLayout,
) error{OutOfMemory}!CallPlan {
    const locs = try gpa.alloc(ArgLoc, args.len);
    errdefer gpa.free(locs);
    const sret = retIsSret(d, ret, layouts, enum_layouts);
    const bytes = walk(d, args, fixed, sret, locs, layouts, enum_layouts);
    return .{ .locs = locs, .stack_bytes = bytes, .sret = sret };
}

/// Whether `ty` is an extern struct: toy code holds it in its own layout, and a C call
/// passes it in the C layout `cLayout` gives.
pub fn isCStruct(ty: Type, layouts: []const Layout) bool {
    return ty.isStruct() and ty.struct_id < layouts.len and layouts[ty.struct_id].is_extern;
}

pub const CLayout = struct { size: u32, @"align": u32 };

/// The C size and alignment of a field or extern struct: a scalar its own size, a struct
/// its fields in order, each at its alignment, the size rounded to the largest one.
pub fn cLayout(ty: Type, layouts: []const Layout) CLayout {
    if (!isCStruct(ty, layouts)) {
        const n = cScalarSize(ty);
        return .{ .size = n, .@"align" = n };
    }
    var off: u32 = 0;
    var al: u32 = 1;
    for (layouts[ty.struct_id].field_types) |f| {
        const c = cLayout(f, layouts);
        off = std.mem.alignForward(u32, off, c.@"align") + c.size;
        al = @max(al, c.@"align");
    }
    return .{ .size = std.mem.alignForward(u32, off, al), .@"align" = al };
}

/// The C offset of field `field` of the extern struct `ty`.
pub fn cFieldOffset(ty: Type, field: usize, layouts: []const Layout) u32 {
    var off: u32 = 0;
    for (layouts[ty.struct_id].field_types[0 .. field + 1], 0..) |f, i| {
        const c = cLayout(f, layouts);
        off = std.mem.alignForward(u32, off, c.@"align");
        if (i == field) return off;
        off += c.size;
    }
    unreachable;
}

/// A homogeneous floating-point aggregate: `count` (1-4) elements, all float32 (`single`) or
/// all float, after nested structs are flattened.
pub const Hfa = struct { count: u8, single: bool };

pub fn hfaOf(ty: Type, layouts: []const Layout) ?Hfa {
    var count: u8 = 0;
    var single: ?bool = null;
    if (!hfaWalk(ty, layouts, &count, &single) or count == 0) return null;
    return .{ .count = count, .single = single.? };
}

fn hfaWalk(ty: Type, layouts: []const Layout, count: *u8, single: *?bool) bool {
    if (isCStruct(ty, layouts)) {
        for (layouts[ty.struct_id].field_types) |f| if (!hfaWalk(f, layouts, count, single)) return false;
        return true;
    }
    if (ty.kind != .float) return false;
    if (single.*) |s| if (s != ty.isFloat32()) return false;
    single.* = ty.isFloat32();
    count.* += 1;
    return count.* <= 4;
}

/// Where a C function returns an extern struct: a homogeneous float aggregate in the FPR
/// result registers (under `hfa`), one of up to 16 bytes in two GPRs, a larger one
/// through the buffer the caller points the sret register at.
pub const CRet = union(enum) { hfa: Hfa, regs: u8, sret };

pub fn cRet(d: Desc, ty: Type, layouts: []const Layout) CRet {
    if (d.hfa) if (hfaOf(ty, layouts)) |h| return .{ .hfa = h };
    const size = cLayout(ty, layouts).size;
    return if (size <= 16) .{ .regs = @intCast(eightbytes(size)) } else .sret;
}

const testing = std.testing;

/// Test helpers, shared with each ISA's `abi` tests.
pub fn mkLayouts(gpa: std.mem.Allocator, sizes: []const u32) ![]Layout {
    const ls = try gpa.alloc(Layout, sizes.len);
    for (sizes, 0..) |s, i| {
        ls[i] = .{
            .name = "T",
            .field_names = &.{},
            .field_types = &.{},
            .offsets = &.{},
            .size = s,
            .@"align" = 8,
        };
    }
    return ls;
}

pub fn structOf(id: u32) Type {
    return Type.structT(id);
}

test "classify: scalar / reg_pair / indirect" {
    const gpa = testing.allocator;
    // struct ids: 0 => 8B (reg_pair, 1 ebs), 1 => 16B (reg_pair, 2 ebs),
    //             2 => 24B (indirect)
    const ls = try mkLayouts(gpa, &.{ 8, 16, 24 });
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};

    try testing.expectEqual(AbiClass.scalar, classify(Type.int, ls, el));
    try testing.expectEqual(AbiClass.scalar, classify(Type.bool, ls, el));
    try testing.expectEqual(AbiClass.reg_pair, classify(Type.str, ls, el)); // 16B
    try testing.expectEqual(AbiClass.reg_pair, classify(structOf(0), ls, el));
    try testing.expectEqual(AbiClass.reg_pair, classify(structOf(1), ls, el));
    try testing.expectEqual(AbiClass.indirect, classify(structOf(2), ls, el));

    try testing.expectEqual(@as(u32, 1), eightbytes(8));
    try testing.expectEqual(@as(u32, 2), eightbytes(16));
    try testing.expectEqual(@as(u32, 2), eightbytes(9));
}

test "classify: a bare float is fp, a struct-with-float stays an aggregate" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{16}); // a 16B struct (e.g. two floats)
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};

    try testing.expectEqual(AbiClass.fp, classify(Type.float, ls, el));
    // A struct of floats is `.@"struct"`, never `.float` → the reg-pair GPR path.
    try testing.expectEqual(AbiClass.reg_pair, classify(structOf(0), ls, el));
}

test "classifyRet: a bare float returns in an FPR (fp_reg)" {
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    try testing.expectEqual(RetLoc.fp_reg, classifyRet(Type.float, ls, el));
}

test "classifyRet: unit / scalar / reg_pair / sret" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{ 8, 16, 24 });
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};

    try testing.expectEqual(RetLoc.none, classifyRet(Type.unit, ls, el));
    try testing.expectEqual(@as(u8, 1), classifyRet(Type.int, ls, el).reg.regs);
    try testing.expectEqual(@as(u8, 2), classifyRet(Type.str, ls, el).reg.regs); // 16B pair
    try testing.expectEqual(@as(u8, 1), classifyRet(structOf(0), ls, el).reg.regs); // 8B
    try testing.expectEqual(@as(u8, 2), classifyRet(structOf(1), ls, el).reg.regs); // 16B
    try testing.expectEqual(RetLoc.sret, classifyRet(structOf(2), ls, el)); // 24B
}

test "classify: unit is zero" {
    try testing.expectEqual(AbiClass.zero, classify(Type.unit, &.{}, &.{}));
}

/// The facts x86-64's `sysv64` will supply (#60 C3), to show the description holds them.
const sysv64_shape: Desc = .{ .gprs = 6, .fprs = 8, .sret_uses_gpr = true, .spill_exhausts = false, .c_structs = true, .big_c_struct = .memory };

fn cStruct(name: []const u8, fields: []const Type) Layout {
    return .{ .name = name, .field_names = &.{}, .field_types = @constCast(fields), .offsets = &.{}, .size = @intCast(fields.len * 8), .@"align" = 8, .is_extern = true };
}

test "a sysv64-shaped description: 6 GPRs, sret takes the first, big structs copied onto the stack, no exhaustion" {
    const gpa = testing.allocator;
    const big = [_]Type{ Type.int, Type.int, Type.int };
    const ls = [_]Layout{cStruct("Big", &big)};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const args = [_]Type{ i, i, i, i, Type.str, Type.structT(0), i, Type.float };
    var plan = try planCall(gpa, sysv64_shape, &args, args.len, Type.structT(0), &ls, el);
    defer plan.deinit(gpa);
    try testing.expect(plan.sret);
    for (0..4) |k| try testing.expectEqual(ParamLoc{ .gpr = .{ .first = @intCast(k + 1), .count = 1 } }, plan.locs[k]);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 0, .bytes = 16 } }, plan.locs[4]);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 16, .bytes = 24 } }, plan.locs[5]);
    // The str did not exhaust the GPRs: the int after it takes the last one.
    try testing.expectEqual(ParamLoc{ .gpr = .{ .first = 5, .count = 1 } }, plan.locs[6]);
    try testing.expectEqual(ParamLoc{ .fpr = 0 }, plan.locs[7]);
    try testing.expectEqual(@as(u32, 40), plan.stack_bytes);

    const params = [_]Type{ i, Type.float };
    var pplan = try planParams(gpa, sysv64_shape, &params, Type.structT(0), &ls, el);
    defer pplan.deinit(gpa);
    try testing.expect(pplan.sret);
    try testing.expectEqual(ParamLoc{ .gpr = .{ .first = 1, .count = 1 } }, pplan.locs[0]);
    try testing.expectEqual(ParamLoc{ .fpr = 0 }, pplan.locs[1]);
}
