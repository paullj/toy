//! The AArch64 calling-convention and frame facts (the `abi` of `codegen/Isa.zig`): what
//! the target-neutral placement walk (`codegen/abi/Abi.zig`) and frame layout
//! (`codegen/frame/FrameLayout.zig`) read, for toy's convention, `aapcs64_apple` and
//! `aapcs64`, and the registers their argument indices name.
//!
//!   * x0-x7 and v0-v7 carry arguments, x0/x1 and v0-v3 results; an indirect result's
//!     buffer pointer goes in x8, which is not an argument register (`sret_uses_gpr`
//!     false).
//!   * An aggregate that does not fit the x registers left goes wholly to the stack and
//!     exhausts them: no later argument backfills one.
//!   * Apple passes every C vararg in its own 8-byte stack slot and packs a C stack
//!     argument at its own size and alignment; standard AAPCS64 places varargs as fixed
//!     arguments and gives every stack argument an 8-byte slot.
//!   * The frame record (x29, x30) sits between a frame and its caller's stack arguments:
//!     16 bytes. The stack stays 16-aligned.
//!   * Limits from the encoding: an incoming stack argument is read at its x29 offset
//!     directly, so its scaled imm12 bounds it (4095 * 8). The encoder reaches any other
//!     offset through a base built from its 4 KiB-page part (`add xN, sp, #pages, lsl
//!     #12`), so the frame stops where the page count leaves the imm12: 16 MiB, twice
//!     macOS's default 8 MiB stack.

const std = @import("std");
const Abi = @import("../../abi/Abi.zig");
const FrameLayout = @import("../../frame/FrameLayout.zig");
const Mir = @import("../Mir.zig");
const Target = @import("../../../Target.zig");

const Reg = Mir.Reg;

pub const gpr_args = [_]Reg{ Reg.gp(0), Reg.gp(1), Reg.gp(2), Reg.gp(3), Reg.gp(4), Reg.gp(5), Reg.gp(6), Reg.gp(7) };
pub const fpr_args = [_]Reg{ Reg.fp(0), Reg.fp(1), Reg.fp(2), Reg.fp(3), Reg.fp(4), Reg.fp(5), Reg.fp(6), Reg.fp(7) };
pub const gpr_rets = [_]Reg{ Reg.gp(0), Reg.gp(1) };
/// Up to four, for a C homogeneous float aggregate.
pub const fpr_rets = [_]Reg{ Reg.fp(0), Reg.fp(1), Reg.fp(2), Reg.fp(3) };
pub const sret_reg = Reg.gp(8);

pub const toy: Abi.Desc = .{ .gprs = gpr_args.len, .fprs = fpr_args.len };

const aapcs64: Abi.Desc = .{ .gprs = gpr_args.len, .fprs = fpr_args.len, .c_structs = true, .hfa = true };

const aapcs64_apple: Abi.Desc = blk: {
    var d = aapcs64;
    d.stack_slots = .@"packed";
    d.varargs = .stack;
    break :blk d;
};

/// The frame record, x29 and x30.
pub const saved_area: u32 = 16;

/// The widest scalable ldr/str immediate offset (imm12 * 8).
const max_incoming_off: u32 = 4095 * 8;

/// Every offset below it splits into a 4 KiB page count and a remainder that each fit an
/// imm12.
pub const max_frame: u32 = (4095 << 12) | 0xFF0;

/// The facts of the backend for C convention `c_abi`.
pub fn facts(comptime c_abi: Target.CAbi) FrameLayout.Facts {
    return .{
        .toy = toy,
        .c = switch (c_abi) {
            .aapcs64_apple => aapcs64_apple,
            .aapcs64 => aapcs64,
            .sysv64 => @compileError("sysv64 is x86-64's C convention"),
        },
        .saved_area = saved_area,
        .stack_align = 16,
        .max_frame = max_frame,
        .max_incoming_off = max_incoming_off,
    };
}

const testing = std.testing;
const types = @import("../../../types.zig");
const Type = types.Type;
const Layout = types.Layout;
const EnumLayout = types.EnumLayout;
const ParamLoc = Abi.ParamLoc;
const ArgLoc = Abi.ArgLoc;
const CLayout = Abi.CLayout;
const Hfa = Abi.Hfa;
const CRet = Abi.CRet;
const cLayout = Abi.cLayout;
const cFieldOffset = Abi.cFieldOffset;
const hfaOf = Abi.hfaOf;

const apple = aapcs64_apple;
const standard = aapcs64;

fn planParams(gpa: std.mem.Allocator, params: []const Type, ret: Type, ls: []const Layout, el: []const EnumLayout) !Abi.ParamPlan {
    return Abi.planParams(gpa, toy, params, ret, ls, el);
}

fn planParamsConv(gpa: std.mem.Allocator, d: Abi.Desc, params: []const Type, ret: Type, ls: []const Layout, el: []const EnumLayout) !Abi.ParamPlan {
    return Abi.planParams(gpa, d, params, ret, ls, el);
}

fn planCall(gpa: std.mem.Allocator, args: []const Type, ret: Type, ls: []const Layout, el: []const EnumLayout) !Abi.CallPlan {
    return Abi.planCall(gpa, toy, args, args.len, ret, ls, el);
}

fn planCallConv(gpa: std.mem.Allocator, d: Abi.Desc, args: []const Type, fixed: usize, ret: Type, ls: []const Layout, el: []const EnumLayout) !Abi.CallPlan {
    return Abi.planCall(gpa, d, args, fixed, ret, ls, el);
}

const mkLayouts = Abi.mkLayouts;
const structOf = Abi.structOf;

test "planParams: (int,float,int,float) — NSRN independent of NGRN" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    // i→x0 (NGRN), x→v0 (NSRN), j→x1 (NGRN), y→v1 (NSRN): the two sequences
    // advance independently.
    const params = [_]Type{ Type.int, Type.float, Type.int, Type.float };
    var plan = try planParams(gpa, &params, Type.float, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u8, 0), plan.locs[1].fpr);
    try testing.expectEqual(@as(u8, 1), plan.locs[2].gpr.first);
    try testing.expectEqual(@as(u8, 1), plan.locs[3].fpr);
}

test "planCall: 9 floats — v0..v7 then a stack spill (NSAA)" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const args = [_]Type{ Type.float, Type.float, Type.float, Type.float, Type.float, Type.float, Type.float, Type.float, Type.float };
    var plan = try planCall(gpa, &args, Type.float, ls, el);
    defer plan.deinit(gpa);

    var i: u8 = 0;
    while (i < 8) : (i += 1) try testing.expectEqual(i, plan.locs[i].fpr);
    // The 9th float overflows v7 → a shared-NSAA stack slot of 8 bytes.
    try testing.expectEqual(@as(u32, 0), plan.locs[8].stack.off);
    try testing.expectEqual(@as(u32, 8), plan.locs[8].stack.bytes);
    try testing.expectEqual(@as(u32, 8), plan.stack_bytes);
}

test "planCall: floats do NOT consume GPR slots — 8 ints + a float still place the float in v0" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    // 8 ints exhaust x0..x7; a trailing float rides v0 (NSRN), NOT the stack —
    // proof the NSRN pool is untouched by the exhausted NGRN pool.
    const args = [_]Type{ Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.float };
    var plan = try planCall(gpa, &args, Type.unit, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), plan.locs[8].fpr);
    try testing.expectEqual(@as(u32, 0), plan.stack_bytes);
}

test "planParams: all-scalar in x0..x7" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const params = [_]Type{ Type.int, Type.bool, Type.int };
    var plan = try planParams(gpa, &params, Type.int, ls, el);
    defer plan.deinit(gpa);

    try testing.expect(!plan.sret);
    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u8, 1), plan.locs[0].gpr.count);
    try testing.expectEqual(@as(u8, 1), plan.locs[1].gpr.first);
    try testing.expectEqual(@as(u8, 2), plan.locs[2].gpr.first);
}

test "planParams: str occupies a 2-reg run (eightbytes pair)" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    // int, str, int: str takes x1,x2; the trailing int gets x3.
    const params = [_]Type{ Type.int, Type.str, Type.int };
    var plan = try planParams(gpa, &params, Type.unit, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u8, 1), plan.locs[1].gpr.first);
    try testing.expectEqual(@as(u8, 2), plan.locs[1].gpr.count);
    try testing.expectEqual(@as(u8, 3), plan.locs[2].gpr.first);
}

test "planParams: <=16B struct reg-pair, >16B struct indirect (gpr_ptr)" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{ 16, 24 });
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};
    const params = [_]Type{ structOf(0), structOf(1) }; // 16B pair, 24B indirect
    var plan = try planParams(gpa, &params, Type.unit, ls, el);
    defer plan.deinit(gpa);

    // 16B struct => 2-reg pair x0,x1.
    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u8, 2), plan.locs[0].gpr.count);
    // 24B struct => indirect pointer in x2.
    try testing.expectEqual(@as(u8, 2), plan.locs[1].gpr_ptr);
}

test "planParams: sret return reserves x8 but does NOT consume a GPR" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{24}); // 24B -> sret
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};
    const params = [_]Type{ Type.int, Type.int };
    var plan = try planParams(gpa, &params, structOf(0), ls, el);
    defer plan.deinit(gpa);

    try testing.expect(plan.sret);
    // x8 is separate: the two int params STILL start at x0.
    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u8, 1), plan.locs[1].gpr.first);
}

test "planCall: >=9 scalar args overflow to the stack (NSAA)" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const args = [_]Type{ Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int };
    var plan = try planCall(gpa, &args, Type.int, ls, el);
    defer plan.deinit(gpa);

    // First 8 -> x0..x7.
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        try testing.expectEqual(i, plan.locs[i].gpr.first);
        try testing.expectEqual(@as(u8, 1), plan.locs[i].gpr.count);
    }
    // args 9,10 -> stack at NSAA 0, 8.
    try testing.expectEqual(@as(u32, 0), plan.locs[8].stack.off);
    try testing.expectEqual(@as(u32, 8), plan.locs[8].stack.bytes);
    try testing.expectEqual(@as(u32, 8), plan.locs[9].stack.off);
    try testing.expectEqual(@as(u32, 16), plan.stack_bytes);
    try testing.expect(!plan.sret);
}

test "aapcs64_apple: stack args past x7 pack at their own size and alignment" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const i8_: Type = .{ .kind = .int, .int_desc = .{ .width = .w8 } };
    const i16_: Type = .{ .kind = .int, .int_desc = .{ .width = .w16 } };
    const i32_: Type = .{ .kind = .int, .int_desc = .{ .width = .w32 } };
    const args = [_]Type{ Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, i8_, i16_, i8_, i32_, Type.bool, Type.int };
    var plan = try planCallConv(gpa, apple, &args, args.len, Type.int, ls, el);
    defer plan.deinit(gpa);
    const want = [_][2]u32{ .{ 0, 1 }, .{ 2, 2 }, .{ 4, 1 }, .{ 8, 4 }, .{ 12, 1 }, .{ 16, 8 } };
    for (want, 8..) |w, i| {
        try testing.expectEqual(w[0], plan.locs[i].stack.off);
        try testing.expectEqual(w[1], plan.locs[i].stack.bytes);
    }
    try testing.expectEqual(@as(u32, 24), plan.stack_bytes);

    var toy_plan = try planCall(gpa, &args, Type.int, ls, el);
    defer toy_plan.deinit(gpa);
    try testing.expectEqual(@as(u32, 48), toy_plan.stack_bytes);
}

test "aapcs64_apple: varargs each take an 8-byte stack slot, ints and floats alike, with registers left" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const args = [_]Type{ Type.cstr, Type.int, Type.float, Type.cstr, Type.int };
    var plan = try planCallConv(gpa, apple, &args, 1, Type.int32, ls, el);
    defer plan.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    for (1..args.len) |i| {
        try testing.expectEqual(@as(u32, @intCast((i - 1) * 8)), plan.locs[i].stack.off);
        try testing.expectEqual(@as(u32, 8), plan.locs[i].stack.bytes);
    }
    try testing.expectEqual(@as(u32, 32), plan.stack_bytes);

    var none = try planCallConv(gpa, apple, args[0..1], 1, Type.int32, ls, el);
    defer none.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), none.stack_bytes);
}

fn cStruct(name: []const u8, fields: []const Type) Layout {
    return .{ .name = name, .field_names = &.{}, .field_types = @constCast(fields), .offsets = &.{}, .size = @intCast(fields.len * 8), .@"align" = 8, .is_extern = true };
}

test "cLayout: C alignment and padding, nested extern structs" {
    const small = [_]Type{ Type.int32, Type.int8, Type.int16 };
    const vec2f = [_]Type{ Type.float32, Type.float32 };
    const rect = [_]Type{ Type.structT(1), Type.structT(1) };
    const mixed = [_]Type{ Type.uint8, Type.uint8, Type.uint8, Type.float32 };
    const big = [_]Type{ Type.int, Type.int, Type.int, Type.int8 };
    const ls = [_]Layout{ cStruct("Small", &small), cStruct("Vec2f", &vec2f), cStruct("Rect", &rect), cStruct("Mixed", &mixed), cStruct("Big", &big) };
    try testing.expectEqual(CLayout{ .size = 8, .@"align" = 4 }, cLayout(Type.structT(0), &ls));
    try testing.expectEqual(@as(u32, 4), cFieldOffset(Type.structT(0), 1, &ls));
    try testing.expectEqual(@as(u32, 6), cFieldOffset(Type.structT(0), 2, &ls));
    try testing.expectEqual(CLayout{ .size = 16, .@"align" = 4 }, cLayout(Type.structT(2), &ls));
    try testing.expectEqual(@as(u32, 8), cFieldOffset(Type.structT(2), 1, &ls));
    try testing.expectEqual(@as(u32, 4), cFieldOffset(Type.structT(3), 3, &ls));
    try testing.expectEqual(CLayout{ .size = 32, .@"align" = 8 }, cLayout(Type.structT(4), &ls));

    try testing.expectEqual(Hfa{ .count = 4, .single = true }, hfaOf(Type.structT(2), &ls).?);
    try testing.expect(hfaOf(Type.structT(3), &ls) == null);
    try testing.expectEqual(CRet{ .regs = 1 }, Abi.cRet(apple, Type.structT(0), &ls));
    try testing.expectEqual(CRet.sret, Abi.cRet(apple, Type.structT(4), &ls));
}

test "aapcs64_apple: extern structs by C size, HFAs in V-registers, the rest whole on the stack" {
    const gpa = testing.allocator;
    const pair = [_]Type{ Type.int, Type.int32, Type.bool };
    const vec4d = [_]Type{ Type.float, Type.float, Type.float, Type.float };
    const vec2f = [_]Type{ Type.float32, Type.float32 };
    const big = [_]Type{ Type.int, Type.int, Type.int, Type.int8 };
    const ls = [_]Layout{ cStruct("Pair", &pair), cStruct("Vec4d", &vec4d), cStruct("Vec2f", &vec2f), cStruct("Big", &big) };
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const args = [_]Type{ i, i, i, i, i, i, i, Type.structT(0), Type.structT(1), Type.structT(1), Type.structT(2), Type.structT(3) };
    var plan = try planCallConv(gpa, apple, &args, args.len, Type.structT(3), &ls, el);
    defer plan.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), plan.locs[7].stack.off);
    try testing.expectEqual(@as(u32, 16), plan.locs[7].stack.bytes);
    try testing.expectEqual(@as(u8, 0), plan.locs[8].fpr_run.first);
    try testing.expectEqual(@as(u8, 4), plan.locs[9].fpr_run.first);
    try testing.expectEqual(@as(u32, 16), plan.locs[10].stack.off);
    try testing.expectEqual(@as(u32, 8), plan.locs[10].stack.bytes);
    // NGRN went to 8 when the pair spilled, so the big struct's pointer is on the stack.
    try testing.expectEqual(@as(u32, 24), plan.locs[11].stack_ptr);
    try testing.expect(plan.sret);

    const fl = [_]Type{ Type.float32, Type.float32, Type.float32, Type.float32, Type.float32, Type.float32, Type.float32, Type.float32, Type.float32, Type.float32 };
    var fp = try planCallConv(gpa, apple, &fl, fl.len, Type.float32, &ls, el);
    defer fp.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), fp.locs[9].stack.off);
    try testing.expectEqual(@as(u32, 4), fp.locs[9].stack.bytes);
}

test "aapcs64_apple: a C callback's params arrive as a C call places them; its sret by C size" {
    const gpa = testing.allocator;
    // C size 12 (x registers), toy size 24 (which toy would return through x8).
    const three = [_]Type{ Type.int32, Type.int32, Type.int32 };
    const ls = [_]Layout{cStruct("Three", &three)};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const params = [_]Type{ i, i, i, i, i, i, i, i, Type.int8, Type.structT(0) };
    var c = try planParamsConv(gpa, apple, &params, Type.structT(0), &ls, el);
    defer c.deinit(gpa);
    var call = try planCallConv(gpa, apple, &params, params.len, Type.structT(0), &ls, el);
    defer call.deinit(gpa);
    for (c.locs, call.locs) |p, a| try testing.expectEqualDeep(a, p);
    try testing.expectEqual(@as(u32, 1), c.locs[8].stack.bytes);
    try testing.expect(!c.sret);
    var toy_plan = try planParams(gpa, &params, Type.structT(0), &ls, el);
    defer toy_plan.deinit(gpa);
    try testing.expect(toy_plan.sret);
    try testing.expectEqual(@as(u32, 8), toy_plan.locs[8].stack.bytes);
}

test "aapcs64_apple: a pointer to a C struct over 16 bytes on the stack is 8-aligned after a packed arg" {
    const gpa = testing.allocator;
    const big = [_]Type{ Type.int, Type.int, Type.int, Type.int8 };
    const ls = [_]Layout{cStruct("Big", &big)};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const args = [_]Type{ i, i, i, i, i, i, i, i, Type.int8, Type.structT(0) };
    var call = try planCallConv(gpa, apple, &args, args.len, Type.int, &ls, el);
    defer call.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), call.locs[8].stack.off);
    try testing.expectEqual(@as(u32, 8), call.locs[9].stack_ptr);
    try testing.expectEqual(@as(u32, 16), call.stack_bytes);
    var params = try planParamsConv(gpa, apple, &args, Type.int, &ls, el);
    defer params.deinit(gpa);
    try testing.expectEqual(@as(u32, 8), params.locs[9].stack_ptr);
}

test "planCall: AAPCS no-split — reg-pair that doesn't fit goes wholly to stack and forbids backfill" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    // 7 ints (x0..x6, NGRN=7) then a str (2 eightbytes): 7+2 > 8, so the str
    // spills WHOLLY to the stack and NGRN becomes 8 — a trailing int must NOT
    // backfill x7; it spills too.
    const args = [_]Type{ Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.str, Type.int };
    var plan = try planCall(gpa, &args, Type.unit, ls, el);
    defer plan.deinit(gpa);

    var i: u8 = 0;
    while (i < 7) : (i += 1) try testing.expectEqual(i, plan.locs[i].gpr.first);
    // str: wholly on stack (16 bytes) at NSAA 0.
    try testing.expectEqual(@as(u32, 0), plan.locs[7].stack.off);
    try testing.expectEqual(@as(u32, 16), plan.locs[7].stack.bytes);
    // trailing int: NO backfill into x7 — it lands on the stack at NSAA 16.
    try testing.expectEqual(@as(u32, 16), plan.locs[8].stack.off);
    try testing.expectEqual(@as(u32, 24), plan.stack_bytes);
}

test "planCall: indirect aggregate beyond x7 passes its pointer on the stack (stack_ptr)" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{24}); // 24B indirect
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};
    // 8 ints fill x0..x7; the 9th arg (a >16B struct) passes its pointer on the
    // stack (8 bytes), NOT in a GPR.
    const args = [_]Type{ Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, Type.int, structOf(0) };
    var plan = try planCall(gpa, &args, Type.unit, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), plan.locs[8].stack_ptr);
    try testing.expectEqual(@as(u32, 8), plan.stack_bytes);
}

test "planCall: aggregate return sets sret" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{24});
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};
    const args = [_]Type{Type.int};
    var plan = try planCall(gpa, &args, structOf(0), ls, el);
    defer plan.deinit(gpa);

    try testing.expect(plan.sret);
    // the result does not consume a GPR; the int arg is still x0.
    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u32, 0), plan.stack_bytes);
}

test "walkAbi: a unit param does not shift adjacent ints" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const params = [_]Type{ Type.int, Type.unit, Type.int };
    var plan = try planParams(gpa, &params, Type.int, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(ParamLoc.zero, plan.locs[1]);
    // The trailing int backfills x1 — the unit consumed no GPR.
    try testing.expectEqual(@as(u8, 1), plan.locs[2].gpr.first);
}

test "planCall: a unit arg consumes 0 GPR / 0 NSAA" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    {
        const args = [_]Type{Type.unit};
        var plan = try planCall(gpa, &args, Type.int, ls, el);
        defer plan.deinit(gpa);
        try testing.expectEqual(ArgLoc.zero, plan.locs[0]);
        try testing.expectEqual(@as(u32, 0), plan.stack_bytes);
    }
    {
        // A leading unit does not push the int off x0.
        const args = [_]Type{ Type.unit, Type.int };
        var plan = try planCall(gpa, &args, Type.int, ls, el);
        defer plan.deinit(gpa);
        try testing.expectEqual(ArgLoc.zero, plan.locs[0]);
        try testing.expectEqual(@as(u8, 0), plan.locs[1].gpr.first);
    }
    {
        // A trailing unit does not add a stack byte.
        const args = [_]Type{ Type.int, Type.unit };
        var plan = try planCall(gpa, &args, Type.int, ls, el);
        defer plan.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
        try testing.expectEqual(ArgLoc.zero, plan.locs[1]);
        try testing.expectEqual(@as(u32, 0), plan.stack_bytes);
    }
}

test "planCall: unit does not disturb NSRN" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const args = [_]Type{ Type.unit, Type.float, Type.unit };
    var plan = try planCall(gpa, &args, Type.unit, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(ArgLoc.zero, plan.locs[0]);
    try testing.expectEqual(@as(u8, 0), plan.locs[1].fpr);
    try testing.expectEqual(ArgLoc.zero, plan.locs[2]);
    try testing.expectEqual(@as(u32, 0), plan.stack_bytes);
}

test "planCall: no args -> empty locs, zero nsaa" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const args = [_]Type{};
    var plan = try planCall(gpa, &args, Type.int, ls, el);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), plan.locs.len);
    try testing.expectEqual(@as(u32, 0), plan.stack_bytes);
}

test "aapcs64: varargs take registers like fixed args, then 8-byte stack slots" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const args = [_]Type{ Type.cstr, i, Type.float, Type.cstr, Type.float32, i, i, i, i, i, Type.int8, Type.float };
    var plan = try planCallConv(gpa, standard, &args, 1, Type.int32, ls, el);
    defer plan.deinit(gpa);
    try testing.expectEqual(@as(u8, 0), plan.locs[0].gpr.first);
    try testing.expectEqual(@as(u8, 1), plan.locs[1].gpr.first);
    try testing.expectEqual(@as(u8, 0), plan.locs[2].fpr);
    try testing.expectEqual(@as(u8, 2), plan.locs[3].gpr.first);
    try testing.expectEqual(@as(u8, 1), plan.locs[4].fpr);
    for (5..9, 3..) |k, r| try testing.expectEqual(@as(u8, @intCast(r)), plan.locs[k].gpr.first);
    try testing.expectEqual(@as(u8, 7), plan.locs[9].gpr.first);
    try testing.expectEqual(@as(u32, 0), plan.locs[10].stack.off);
    try testing.expectEqual(@as(u32, 8), plan.locs[10].stack.bytes);
    try testing.expectEqual(@as(u8, 2), plan.locs[11].fpr);
    try testing.expectEqual(@as(u32, 8), plan.stack_bytes);
}

test "aapcs64: more than 8 int or float args spill to 8-byte stack slots" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const ints = [_]Type{ i, i, i, i, i, i, i, i, Type.int32, i };
    var ip = try planCallConv(gpa, standard, &ints, ints.len, i, ls, el);
    defer ip.deinit(gpa);
    for (0..8) |k| try testing.expectEqual(@as(u8, @intCast(k)), ip.locs[k].gpr.first);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 0, .bytes = 8 } }, ip.locs[8]);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 8, .bytes = 8 } }, ip.locs[9]);
    try testing.expectEqual(@as(u32, 16), ip.stack_bytes);

    const f = Type.float32;
    const floats = [_]Type{ f, f, f, f, f, f, f, f, f, Type.float };
    var fp = try planCallConv(gpa, standard, &floats, floats.len, f, ls, el);
    defer fp.deinit(gpa);
    for (0..8) |k| try testing.expectEqual(@as(u8, @intCast(k)), fp.locs[k].fpr);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 0, .bytes = 8 } }, fp.locs[8]);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 8, .bytes = 8 } }, fp.locs[9]);
    try testing.expectEqual(@as(u32, 16), fp.stack_bytes);
}

test "aapcs64: small ints on the stack each take an 8-byte slot" {
    const gpa = testing.allocator;
    const ls: []const Layout = &.{};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const args = [_]Type{ i, i, i, i, i, i, i, i, Type.int8, Type.int16, Type.uint8, Type.int32, Type.bool, i };
    var plan = try planCallConv(gpa, standard, &args, args.len, i, ls, el);
    defer plan.deinit(gpa);
    for (8..args.len) |k| try testing.expectEqual(ParamLoc{ .stack = .{ .off = @intCast((k - 8) * 8), .bytes = 8 } }, plan.locs[k]);
    try testing.expectEqual(@as(u32, 48), plan.stack_bytes);
}

test "aapcs64: HFAs in V-registers, a 16-byte pair in x registers or whole on the stack, larger structs indirect, sret by C size" {
    const gpa = testing.allocator;
    const pair = [_]Type{ Type.int, Type.int32, Type.bool };
    const vec4d = [_]Type{ Type.float, Type.float, Type.float, Type.float };
    const vec2f = [_]Type{ Type.float32, Type.float32 };
    const big = [_]Type{ Type.int, Type.int, Type.int, Type.int8 };
    const three = [_]Type{ Type.int32, Type.int32, Type.int32 };
    const ls = [_]Layout{ cStruct("Pair", &pair), cStruct("Vec4d", &vec4d), cStruct("Vec2f", &vec2f), cStruct("Big", &big), cStruct("Three", &three) };
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const pair_t = Type.structT(0);
    const big_t = Type.structT(3);

    const fits = [_]Type{ pair_t, big_t, i, i, i, i, Type.structT(1), Type.structT(2) };
    var a = try planCallConv(gpa, standard, &fits, fits.len, big_t, &ls, el);
    defer a.deinit(gpa);
    try testing.expectEqual(ParamLoc{ .gpr = .{ .first = 0, .count = 2 } }, a.locs[0]);
    try testing.expectEqual(ParamLoc{ .gpr_ptr = 2 }, a.locs[1]);
    try testing.expectEqual(ParamLoc{ .fpr_run = .{ .first = 0, .count = 4, .single = false } }, a.locs[6]);
    try testing.expectEqual(ParamLoc{ .fpr_run = .{ .first = 4, .count = 2, .single = true } }, a.locs[7]);
    try testing.expect(a.sret);
    try testing.expectEqual(@as(u32, 0), a.stack_bytes);

    const spills = [_]Type{ i, i, i, i, i, i, i, pair_t, Type.structT(1), Type.structT(1), Type.structT(2), big_t };
    var b = try planCallConv(gpa, standard, &spills, spills.len, Type.structT(4), &ls, el);
    defer b.deinit(gpa);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 0, .bytes = 16 } }, b.locs[7]);
    try testing.expectEqual(@as(u8, 0), b.locs[8].fpr_run.first);
    try testing.expectEqual(@as(u8, 4), b.locs[9].fpr_run.first);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 16, .bytes = 8 } }, b.locs[10]);
    try testing.expectEqual(ParamLoc{ .stack_ptr = 24 }, b.locs[11]);
    try testing.expectEqual(@as(u32, 32), b.stack_bytes);
    try testing.expect(!b.sret);
}

test "aapcs64: a C callback's params arrive where a C call puts them" {
    const gpa = testing.allocator;
    const three = [_]Type{ Type.int32, Type.int32, Type.int32 };
    const ls = [_]Layout{cStruct("Three", &three)};
    const el: []const EnumLayout = &.{};
    const i = Type.int;
    const params = [_]Type{ i, i, i, i, i, i, i, i, Type.int8, Type.float32, Type.structT(0) };
    var p = try planParamsConv(gpa, standard, &params, Type.structT(0), &ls, el);
    defer p.deinit(gpa);
    var c = try planCallConv(gpa, standard, &params, params.len, Type.structT(0), &ls, el);
    defer c.deinit(gpa);
    for (p.locs, c.locs) |x, y| try testing.expectEqualDeep(y, x);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 0, .bytes = 8 } }, p.locs[8]);
    try testing.expectEqual(@as(u8, 0), p.locs[9].fpr);
    try testing.expectEqual(ParamLoc{ .stack = .{ .off = 8, .bytes = 16 } }, p.locs[10]);
    try testing.expect(!p.sret);
}

const Ir = @import("../../../ir/Ir.zig");

test "frame: an extern call's stack args can fit Apple's frame but not aapcs64's; every backend is checked" {
    const gpa = testing.allocator;
    // Eight ints fill x0-x7; four int8s go to the stack: 4 packed bytes on Apple (out_base
    // 16), four 8-byte slots on aapcs64 (out_base 32).
    var vtypes: [12]Type = undefined;
    for (vtypes[0..8]) |*v| v.* = Type.int;
    for (vtypes[8..]) |*v| v.* = Type.int8;
    const args = try gpa.alloc(Ir.Operand, 12);
    for (args, 0..) |*a, i| a.* = .{ .value = @intCast(i) };
    const instrs = try gpa.alloc(Ir.Instr, 1);
    instrs[0] = .{ .result = Ir.none_value, .op = .{ .call = .{
        .callee = .{ .kind = .import, .name = "c" },
        .args = args,
        .ret_slot = Ir.none_slot,
    } } };
    const values = try gpa.alloc(Ir.ValueDef, vtypes.len);
    for (values, vtypes) |*v, ty| v.* = .{ .type = ty };
    const slots = try gpa.alloc(Ir.Slot, 1);
    slots[0] = .{ .type = Type.structT(0) };
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = instrs, .term = .{ .ret = .none } };
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
    const ls = [_]Layout{.{ .name = "S", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = max_frame - 16, .@"align" = 8 }};
    try testing.expect(try FrameLayout.fits(gpa, &func, facts(.aapcs64_apple), &ls, &.{}));
    try testing.expect(!try FrameLayout.fits(gpa, &func, facts(.aapcs64), &ls, &.{}));
    try testing.expect(!try @import("../../Isa.zig").fitsEveryBackend(gpa, &func, &ls, &.{}));
}

test "frame: ParamOffsetTooLarge when an incoming stack-arg offset exceeds imm12" {
    const gpa = testing.allocator;
    // Need a param whose incoming stack offset 16+off > 4095*8 = 32760. Each
    // overflow param is 8 bytes, starting after 8 GPR params. off for param k
    // (k>=8) is (k-8)*8. Solve 16 + (k-8)*8 > 32760 -> k-8 > 4093 -> k >= 4102.
    // Use 4110 int params (well past the threshold). All ints (scalar) so the
    // frame itself stays tiny (no slots/values besides params).
    const n = 4110;
    const slots = try gpa.alloc(Ir.Slot, n);
    for (slots) |*sl| sl.* = .{ .type = Type.int };
    const params = try gpa.alloc(Ir.SlotId, n);
    for (params, 0..) |*sid, i| sid.* = @intCast(i);
    const blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{ .params = try gpa.alloc(Ir.ValueId, 0), .instrs = try gpa.alloc(Ir.Instr, 0), .term = .{ .ret = .none } };
    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = params,
        .ret_type = Type.unit,
        .slots = slots,
        .values = try gpa.alloc(Ir.ValueDef, 0),
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
    defer func.deinit(gpa);

    try testing.expectError(error.ParamOffsetTooLarge, FrameLayout.compute(gpa, &func, facts(.aapcs64_apple), &.{}, &.{}));
}
