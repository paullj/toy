//! Exact constant-fold arithmetic for the opt stage.
//!
//! These helpers compute what the language defines (`docs/typesystem.md`, #60 D11), and
//! every ISA's selector must give the same bits, otherwise opt-on diverges from opt-off
//! (the differential test is the backstop). The rules:
//!   add/sub/mul : 64-bit two's-complement WRAPPING (`+%`/`-%`/`*%`); a debug build's
//!                 overflow test is a separate `overflow` instruction.
//!   div/rem     : truncate toward zero; a remainder takes the dividend's sign. A zero
//!                 divisor has no value: lowering panics before every divide, so `divide`
//!                 returns null and the op is left for that guard. `INT_MIN / -1` wraps to
//!                 `INT_MIN` and `INT_MIN % -1` is 0 (release; debug panics first).
//!   neg         : `0 -% v` (so neg(INT_MIN) == INT_MIN).
//!   bnot        : logical "== 0" on a BOOL, i.e. `!b`.
//!   icmp        : SIGNED i64 comparison → bool.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");

pub const BinKind = enum { add, sub, mul, band, bor, bxor };

/// Fold a binary integer op on two constant i64 operands.
pub fn foldBin(kind: BinKind, l: i64, r: i64) i64 {
    return switch (kind) {
        .add => l +% r,
        .sub => l -% r,
        .mul => l *% r,
        .band => l & r,
        .bor => l | r,
        .bxor => l ^ r,
    };
}

pub const ShiftKind = enum { shl, lshr, ashr };

/// Go-semantics shift fold — the value-domain mirror of `Isel.shift`.
/// The amount is compared UNSIGNED against `width` (matching the `csel …,hs`
/// guard): amt>=width → 0 (shl/lshr) or sign-fill (ashr, = `l >> 63`). Below width
/// the amount is < 64, so a plain native shift in the u64/i64 domain. Returns the
/// raw 64-bit value; the caller applies `wrapTo` (≡ codegen's `normalizeWidth`).
pub fn foldShift(kind: ShiftKind, l: i64, r: i64, width: u16) i64 {
    if (@as(u64, @bitCast(r)) >= width) {
        return switch (kind) {
            .shl, .lshr => 0,
            .ashr => l >> 63,
        };
    }
    const amt: u6 = @intCast(r); // r < width <= 64 ⇒ r in [0,63]
    return switch (kind) {
        .shl => @bitCast(@as(u64, @bitCast(l)) << amt),
        .lshr => @bitCast(@as(u64, @bitCast(l)) >> amt),
        .ashr => l >> amt,
    };
}

/// Bitwise complement over the full 64 bits; the caller width-normalizes via `wrapTo`.
pub fn bcompl(v: i64) i64 {
    return ~v;
}

pub const DivKind = enum { sdiv, udiv, smod, umod };

/// A division or remainder on two constant i64 operands (an unsigned one reads them as
/// `u64`), or null for a zero divisor, which has no value.
pub fn divide(kind: DivKind, l: i64, r: i64) ?i64 {
    if (r == 0) return null;
    return switch (kind) {
        .sdiv => if (r == -1) 0 -% l else @divTrunc(l, r),
        .smod => if (r == -1) 0 else @rem(l, r),
        .udiv => @bitCast(@as(u64, @bitCast(l)) / @as(u64, @bitCast(r))),
        .umod => @bitCast(@as(u64, @bitCast(l)) % @as(u64, @bitCast(r))),
    };
}

/// Wrapping negate.
pub fn neg(v: i64) i64 {
    return 0 -% v;
}

/// Width-normalize a folded 64-bit result to its result type's canonical form —
/// the value-domain mirror of `Isel.normalize` (signed narrow →
/// sign-extend, unsigned narrow → zero-extend). Exhaustive over `IntWidth` (no
/// `else`) so a new width class is a build break, not a silent fold divergence.
/// Identity for non-integers and platform/w64 ints → byte-identical for existing
/// programs.
pub fn wrapTo(ty: Ir.Type, x: i64) i64 {
    if (!ty.isInteger()) return x;
    return switch (ty.int_desc.width) {
        .plat, .w64 => x,
        .w8 => if (ty.int_desc.signed) @as(i64, @as(i8, @truncate(x))) else x & 0xFF,
        .w16 => if (ty.int_desc.signed) @as(i64, @as(i16, @truncate(x))) else x & 0xFFFF,
        .w32 => if (ty.int_desc.signed) @as(i64, @as(i32, @truncate(x))) else x & 0xFFFFFFFF,
    };
}

/// Whether `l op r` overflows integer type `ty`, the value-domain mirror of
/// `Isel.overflow`. A narrow type's operands fit 32 bits, so the 64-bit result is
/// exact and overflows when it does not survive `wrapTo`; a 64-bit type is judged exactly.
pub fn overflows(kind: Ir.Overflow.Kind, l: i64, r: i64, ty: Ir.Type) bool {
    if (ty.intBits() < 64) {
        const x = foldBin(switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
        }, l, r);
        return wrapTo(ty, x) != x;
    }
    if (ty.int_desc.signed) return switch (kind) {
        .add => @addWithOverflow(l, r)[1] == 1,
        .sub => @subWithOverflow(l, r)[1] == 1,
        .mul => @mulWithOverflow(l, r)[1] == 1,
    };
    const a: u64 = @bitCast(l);
    const b: u64 = @bitCast(r);
    return switch (kind) {
        .add => @addWithOverflow(a, b)[1] == 1,
        .sub => @subWithOverflow(a, b)[1] == 1,
        .mul => @mulWithOverflow(a, b)[1] == 1,
    };
}

/// Logical not on a bool.
pub fn bnot(b: bool) bool {
    return !b;
}

/// Signed or unsigned comparison → bool. Signedness rides on `cc` (the
/// `u*` conds compare the operands as `u64`), so this stays correct under
/// operand-rewriting opt passes.
pub fn icmp(cc: Ir.Cond, l: i64, r: i64) bool {
    return switch (cc) {
        .eq => l == r,
        .ne => l != r,
        .lt => l < r,
        .le => l <= r,
        .gt => l > r,
        .ge => l >= r,
        .ult => @as(u64, @bitCast(l)) < @as(u64, @bitCast(r)),
        .ule => @as(u64, @bitCast(l)) <= @as(u64, @bitCast(r)),
        .ugt => @as(u64, @bitCast(l)) > @as(u64, @bitCast(r)),
        .uge => @as(u64, @bitCast(l)) >= @as(u64, @bitCast(r)),
    };
}

// Tests — the fold-divergence edge cases (run under std.testing.allocator).

test "divide: a zero divisor has no value, for every kind" {
    for ([_]DivKind{ .sdiv, .udiv, .smod, .umod }) |k| {
        try std.testing.expectEqual(@as(?i64, null), divide(k, 5, 0));
        try std.testing.expectEqual(@as(?i64, null), divide(k, 0, 0));
        try std.testing.expectEqual(@as(?i64, null), divide(k, std.math.minInt(i64), 0));
    }
}

test "divide: INT_MIN / -1 wraps to INT_MIN and INT_MIN % -1 is 0" {
    const min = std.math.minInt(i64);
    try std.testing.expectEqual(@as(?i64, min), divide(.sdiv, min, -1));
    try std.testing.expectEqual(@as(?i64, 0), divide(.smod, min, -1));
    // A narrow width computes on its sign-extended value; wrapTo gives the width's INT_MIN.
    try std.testing.expectEqual(@as(i64, -128), wrapTo(Ir.Type.int8, divide(.sdiv, -128, -1).?));
    try std.testing.expectEqual(@as(i64, 0), wrapTo(Ir.Type.int8, divide(.smod, -128, -1).?));
    try std.testing.expectEqual(@as(i64, -32768), wrapTo(Ir.Type.int16, divide(.sdiv, -32768, -1).?));
    try std.testing.expectEqual(@as(i64, -2147483648), wrapTo(Ir.Type.int32, divide(.sdiv, -2147483648, -1).?));
}

test "divide: truncates toward zero; a remainder takes the dividend's sign" {
    try std.testing.expectEqual(@as(?i64, -2), divide(.sdiv, -7, 3));
    try std.testing.expectEqual(@as(?i64, 2), divide(.sdiv, 7, 3));
    try std.testing.expectEqual(@as(?i64, -2), divide(.sdiv, 7, -3));
    try std.testing.expectEqual(@as(?i64, 7), divide(.sdiv, -7, -1));
    try std.testing.expectEqual(@as(?i64, -2), divide(.smod, -17, 5));
    try std.testing.expectEqual(@as(?i64, 2), divide(.smod, 17, -5));
    try std.testing.expectEqual(@as(?i64, 2), divide(.smod, 17, 5));
}

test "divide: unsigned reads the raw bit patterns" {
    const two_63 = std.math.minInt(i64);
    try std.testing.expectEqual(@as(?i64, 0x4000000000000000), divide(.udiv, two_63, 2));
    try std.testing.expectEqual(@as(?i64, 3), divide(.udiv, 7, 2));
    try std.testing.expectEqual(@as(?i64, 0), divide(.udiv, 5, -1));
    try std.testing.expectEqual(@as(?i64, 1), divide(.umod, 7, 2));
    try std.testing.expectEqual(@as(?i64, 2), divide(.umod, two_63, 3));
}

test "neg(INT_MIN) == INT_MIN" {
    const min = std.math.minInt(i64);
    try std.testing.expectEqual(min, neg(min));
    try std.testing.expectEqual(@as(i64, -5), neg(5));
}

test "wrapping add/sub/mul overflow" {
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try std.testing.expectEqual(min, foldBin(.add, max, 1));
    try std.testing.expectEqual(max, foldBin(.sub, min, 1));
    try std.testing.expectEqual(@as(i64, 0), foldBin(.mul, min, 2)); // min*2 wraps to 0
}

test "signed icmp on negatives" {
    try std.testing.expect(icmp(.lt, -3, 0));
    try std.testing.expect(!icmp(.gt, -3, 0));
    try std.testing.expect(icmp(.le, -5, -5));
    try std.testing.expect(icmp(.ge, 2, -2));
    try std.testing.expect(icmp(.eq, -1, -1));
    try std.testing.expect(icmp(.ne, -1, 1));
}

test "bnot" {
    try std.testing.expect(bnot(false));
    try std.testing.expect(!bnot(true));
}

test "wrapTo normalizes narrow widths (mirrors codegen)" {
    // int8 200 (as -56 after wrap) and -56 both canonicalize to -56.
    try std.testing.expectEqual(@as(i64, -56), wrapTo(Ir.Type.int8, 200));
    try std.testing.expectEqual(@as(i64, 44), wrapTo(Ir.Type.uint8, 300));
    try std.testing.expectEqual(@as(i64, -1), wrapTo(Ir.Type.int16, 0xFFFF));
    try std.testing.expectEqual(@as(i64, 0xFFFF), wrapTo(Ir.Type.uint16, 0xFFFF));
    try std.testing.expectEqual(@as(i64, -1), wrapTo(Ir.Type.int32, 0xFFFFFFFF));
    try std.testing.expectEqual(@as(i64, 0xFFFFFFFF), wrapTo(Ir.Type.uint32, -1));
    // plat / w64 / bool are identity.
    try std.testing.expectEqual(@as(i64, 200), wrapTo(Ir.Type.int, 200));
    try std.testing.expectEqual(@as(i64, -56), wrapTo(Ir.Type.int64, -56));
    try std.testing.expectEqual(@as(i64, 5), wrapTo(Ir.Type.bool, 5));
}

test "unsigned icmp contrasts signed on bit63-set operands" {
    const min = std.math.minInt(i64); // top-bit-set: huge unsigned, negative signed
    try std.testing.expect(icmp(.ugt, min, 1)); // unsigned: 2^63 > 1
    try std.testing.expect(!icmp(.gt, min, 1)); // signed: -2^63 > 1 is false
    try std.testing.expect(icmp(.ult, 1, min));
    try std.testing.expect(icmp(.uge, min, min));
    try std.testing.expect(icmp(.ule, 1, min));
}

test "foldShift Go semantics — below width, signed vs unsigned, and >= width" {
    // Below width: logical vs arithmetic right shift on a bit7-set value.
    try std.testing.expectEqual(@as(i64, 64), foldShift(.lshr, 0x80, 1, 8));
    try std.testing.expectEqual(@as(i64, -64), foldShift(.ashr, -128, 1, 8));
    // bit63-set value: lshr != ashr.
    const bit63 = std.math.minInt(i64);
    try std.testing.expectEqual(@as(i64, 0x4000000000000000), foldShift(.lshr, bit63, 1, 64));
    try std.testing.expectEqual(@as(i64, @bitCast(@as(u64, 0xC000000000000000))), foldShift(.ashr, bit63, 1, 64));
    // amt >= width: shl/lshr -> 0, ashr -> sign-fill.
    try std.testing.expectEqual(@as(i64, 0), foldShift(.lshr, 0xFF, 8, 8));
    try std.testing.expectEqual(@as(i64, 0), foldShift(.shl, 0xFF, 8, 8));
    try std.testing.expectEqual(@as(i64, -1), foldShift(.ashr, -1, 8, 8));
    try std.testing.expectEqual(@as(i64, 0), foldShift(.ashr, 5, 8, 8));
    // amt >= 64 (the mask-wrap region — the guard's raison d'être).
    try std.testing.expectEqual(@as(i64, 0), foldShift(.lshr, 0xFF, 64, 8));
    try std.testing.expectEqual(@as(i64, 0), foldShift(.shl, 0xFF, 64, 8));
    try std.testing.expectEqual(@as(i64, 0), foldShift(.lshr, -1, 64, 64));
    try std.testing.expectEqual(@as(i64, -1), foldShift(.ashr, -1, 64, 64));
    // negative amount (huge unsigned) -> >= width.
    try std.testing.expectEqual(@as(i64, 0), foldShift(.lshr, 0xFF, -1, 8));
    try std.testing.expectEqual(@as(i64, -1), foldShift(.ashr, -1, -1, 64));
}

test "foldBin bitwise and bcompl, then narrow wrapTo" {
    try std.testing.expectEqual(@as(i64, 0x0A), foldBin(.band, 0xAA, 0x0F));
    try std.testing.expectEqual(@as(i64, 0xAF), foldBin(.bor, 0xAA, 0x0F));
    try std.testing.expectEqual(@as(i64, 0xA5), foldBin(.bxor, 0xAA, 0x0F));
    try std.testing.expectEqual(~@as(i64, 48), bcompl(48));
    try std.testing.expectEqual(@as(i64, 207), wrapTo(Ir.Type.uint8, bcompl(48))); // demo's ~c
    try std.testing.expectEqual(@as(i64, 65280), wrapTo(Ir.Type.uint16, bcompl(0x00FF)));
}

test "overflows: each op at the edges of signed and unsigned, narrow and 64-bit" {
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try std.testing.expect(overflows(.add, max, 1, Ir.Type.int));
    try std.testing.expect(!overflows(.add, max, 0, Ir.Type.int));
    try std.testing.expect(overflows(.sub, min, 1, Ir.Type.int));
    try std.testing.expect(overflows(.sub, 0, min, Ir.Type.int));
    try std.testing.expect(overflows(.mul, 4, 4611686018427387904, Ir.Type.int));
    try std.testing.expect(overflows(.mul, min, -1, Ir.Type.int64));
    try std.testing.expect(!overflows(.mul, -1, max, Ir.Type.int));
    try std.testing.expect(overflows(.add, 127, 1, Ir.Type.int8));
    try std.testing.expect(!overflows(.add, -128, 127, Ir.Type.int8));
    try std.testing.expect(overflows(.sub, 0, 1, Ir.Type.uint8));
    try std.testing.expect(overflows(.mul, 16, 16, Ir.Type.uint8));
    try std.testing.expect(!overflows(.mul, 15, 17, Ir.Type.uint8));
    try std.testing.expect(overflows(.add, -1, 1, Ir.Type.uint64));
    try std.testing.expect(!overflows(.add, -2, 1, Ir.Type.uint64));
    try std.testing.expect(overflows(.sub, 0, 1, Ir.Type.uint));
    try std.testing.expect(overflows(.mul, 1 << 32, 1 << 32, Ir.Type.uint64));
    try std.testing.expect(overflows(.mul, 65536, 32768, Ir.Type.int32));
    // A literal `int` operand of 128 negated at int8 is -128, which fits.
    try std.testing.expect(!overflows(.sub, 0, 128, Ir.Type.int8));
}
