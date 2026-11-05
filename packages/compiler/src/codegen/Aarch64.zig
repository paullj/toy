//! Pure aarch64 (AArch64 / ARM64) instruction-word emitter.
//!
//! WHY: all the bit-twiddling needed to turn a mnemonic into a 32-bit machine
//! word lives here, behind named functions, so `Codegen` and the unit tests
//! never hand-encode an instruction. Every helper is a pure function (no IO, no
//! allocation) returning the little-endian-on-disk `u32` word; callers serialize
//! with `std.mem.writeInt(u32, buf, word, .little)`.
//!
//! Each expected word in the tests below was cross-checked against the real
//! assembler on this host: write the mnemonics to a `.s` file, `as -arch arm64`,
//! then `objdump -d` — the disassembly's hex column is the ground truth the
//! tests assert (see the comments next to each constant/function).
//!
//! Scope is the initial subset only: movz/movk (+ an i64 materializer), reg/reg moves,
//! add/sub (reg and imm12), mul, sdiv, neg, the frame stp/ldp pair, ldr/str
//! unsigned-offset against sp, sp add/sub, bl, and ret.

const std = @import("std");

pub const XZR: u32 = 31;
/// The widest scaled imm12 of a load/store: past it the offset bits spill into the opcode.
pub const max_scaled: u32 = 4095;
pub const SP: u32 = 31;
pub const FP: u32 = 29;
pub const LR: u32 = 30;

/// movz rd, #imm16, lsl #(hw*16) — load a 16-bit immediate into a lane, zeroing
/// the rest. `hw` selects the lane (0..3). movz x0,#40 → 0xD2800500.
pub fn movz(rd: u32, imm16: u16, hw: u2) u32 {
    return 0xD2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}

/// movk rd, #imm16, lsl #(hw*16) — overwrite a 16-bit lane, keeping the others.
/// movk x0,#0x1234,lsl#16 → 0xF2A24680.
pub fn movk(rd: u32, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}

/// movn rd, #imm16, lsl #(hw*16) — load the bitwise-NOT of a shifted 16-bit
/// immediate. `movn rd,#0` yields all-ones (−1), the `mmap`/`mincore` `fd = -1`
/// an anonymous mapping requires. movn x4,#0 → 0x92800004.
pub fn movn(rd: u32, imm16: u16, hw: u2) u32 {
    return 0x92800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}

/// add rd, rn, #imm12. With rd/rn = SP this is the sp adjust. add sp,sp,#16 →
/// 0x910043FF.
pub fn addImm(rd: u32, rn: u32, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (rn << 5) | rd;
}

/// sub rd, rn, #imm12. sub sp,sp,#16 → 0xD10043FF.
pub fn subImm(rd: u32, rn: u32, imm12: u12) u32 {
    return 0xD1000000 | (@as(u32, imm12) << 10) | (rn << 5) | rd;
}

/// add rd, rn, #imm12, lsl #12 — adds imm12 × 4096. add x12,sp,#1,lsl #12 → 0x914007EC.
pub fn addImmLsl12(rd: u32, rn: u32, imm12: u12) u32 {
    return 0x91400000 | (@as(u32, imm12) << 10) | (rn << 5) | rd;
}

/// sub rd, rn, #imm12, lsl #12 — subtracts imm12 × 4096. sub sp,sp,#1,lsl #12 → 0xD14007FF.
pub fn subImmLsl12(rd: u32, rn: u32, imm12: u12) u32 {
    return 0xD1400000 | (@as(u32, imm12) << 10) | (rn << 5) | rd;
}

/// subs rd, rn, #imm12 — subtract and set flags. subs x12,x12,#1 → 0xF100058C.
pub fn subsImm(rd: u32, rn: u32, imm12: u12) u32 {
    return 0xF1000000 | (@as(u32, imm12) << 10) | (rn << 5) | rd;
}

/// add rd, rn, rm. add x0,x0,x1 → 0x8B010000.
pub fn addReg(rd: u32, rn: u32, rm: u32) u32 {
    return 0x8B000000 | (rm << 16) | (rn << 5) | rd;
}

/// adds rd, rn, rm — add and set flags (V on signed overflow, C on unsigned carry).
/// adds x9,x9,x10 → 0xAB0A0129.
pub fn addsReg(rd: u32, rn: u32, rm: u32) u32 {
    return 0xAB000000 | (rm << 16) | (rn << 5) | rd;
}

/// smulh rd, rn, rm — the high 64 bits of the signed 128-bit product.
/// smulh x11,x9,x10 → 0x9B4A7D2B.
pub fn smulh(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9B407C00 | (rm << 16) | (rn << 5) | rd;
}

/// umulh rd, rn, rm — the high 64 bits of the unsigned 128-bit product.
/// umulh x11,x9,x10 → 0x9BCA7D2B.
pub fn umulh(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9BC07C00 | (rm << 16) | (rn << 5) | rd;
}

/// add rd, rn, rm, uxtx — the extended-register form, the one whose `rn` may be sp
/// (in `addReg`'s shifted-register form, register 31 is xzr). add x9,x9,x14,uxtx →
/// 0x8B2E6129; add x1,sp,x14 → 0x8B2E63E1.
pub fn addRegExt(rd: u32, rn: u32, rm: u32) u32 {
    return 0x8B206000 | (rm << 16) | (rn << 5) | rd;
}

/// sub rd, rn, rm. sub x5,x0,x1 → 0xCB010005.
pub fn subReg(rd: u32, rn: u32, rm: u32) u32 {
    return 0xCB000000 | (rm << 16) | (rn << 5) | rd;
}

/// mul rd, rn, rm (alias of madd with the accumulator = XZR). mul x2,x0,x1 →
/// 0x9B017C02.
pub fn mul(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9B007C00 | (rm << 16) | (rn << 5) | rd;
}

/// msub rd, rn, rm, ra -> rd = ra - rn*rm (MADD family, bit15 set). Used by smod/
/// umod for r = a - (a/b)*b. Words verified on-host (`as -arch arm64` + `otool`):
/// msub x0,x1,x2,x3 -> 0x9B028C20, msub x3,x0,x1,x2 -> 0x9B018803.
pub fn msub(rd: u32, rn: u32, rm: u32, ra: u32) u32 {
    return 0x9B008000 | (rm << 16) | (ra << 10) | (rn << 5) | rd;
}

/// sdiv rd, rn, rm (signed division; arm64 sdiv by 0 yields 0, no trap). sdiv
/// x3,x0,x1 → 0x9AC10C03.
pub fn sdiv(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9AC00C00 | (rm << 16) | (rn << 5) | rd;
}

/// udiv rd, rn, rm (unsigned division; arm64 udiv by 0 yields 0, no trap). Mirrors
/// `sdiv` with bit10 cleared. udiv x0,x0,x0 → 0x9AC00800.
pub fn udiv(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9AC00800 | (rm << 16) | (rn << 5) | rd;
}

/// neg rd, rm — alias of `sub rd, xzr, rm`. neg x4,x0 → 0xCB0003E4.
pub fn neg(rd: u32, rm: u32) u32 {
    return subReg(rd, XZR, rm);
}

/// sxtb rd, rn — sign-extend low byte to 64-bit (SBFM alias). sxtb x0,x0 →
/// 0x93401C00. Used to re-canonicalize a signed narrow (int8) result after a
/// full-width op wraps it.
pub fn sxtb(rd: u32, rn: u32) u32 {
    return 0x93401C00 | (rn << 5) | rd;
}

/// sxth rd, rn — sign-extend low halfword to 64-bit. sxth x0,x0 → 0x93403C00.
pub fn sxth(rd: u32, rn: u32) u32 {
    return 0x93403C00 | (rn << 5) | rd;
}

/// sxtw rd, rn — sign-extend low word to 64-bit. sxtw x0,x0 → 0x93407C00.
pub fn sxtw(rd: u32, rn: u32) u32 {
    return 0x93407C00 | (rn << 5) | rd;
}

/// and rd, rn, #mask — AND with a low-bits bitmask immediate (N=1, immr=0; `imms`
/// = mask width − 1). imms 7/15/31 encode #0xff / #0xffff / #0xffffffff, the
/// zero-extend masks for an unsigned narrow (uint8/16/32) result. and x0,x0,#0xff
/// → 0x92401C00; and x0,x0,#0xffff → 0x92403C00; and x0,x0,#0xffffffff → 0x92407C00.
pub fn andLowBits(rd: u32, rn: u32, imms: u6) u32 {
    return 0x92400000 | (@as(u32, imms) << 10) | (rn << 5) | rd;
}

/// The N:immr:imms field of a logical immediate for `x`, or null when `x` is no bitmask
/// immediate: a run of ones, rotated, repeated in elements of 2 to 64 bits. 0 and ~0 are
/// none.
pub fn bitmaskImm(x: u64) ?u13 {
    if (x == 0 or x == ~@as(u64, 0)) return null;
    var size: u7 = 64;
    while (size > 2) {
        const half: u6 = @intCast(size / 2);
        const mask = (@as(u64, 1) << half) - 1;
        if (x & mask != (x >> half) & mask) break;
        size = half;
    }
    const mask: u64 = if (size == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(size)) - 1;
    const elem = x & mask;
    const ones: u7 = @popCount(elem);
    const run: u64 = if (ones == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(ones)) - 1;
    var r: u7 = 0;
    while (r < size) : (r += 1) {
        const rot = if (r == 0) elem else ((elem >> @intCast(r)) | (elem << @intCast(size - r))) & mask;
        if (rot == run) break;
    } else return null;
    const immr: u13 = (size - r) % size;
    const n: u13 = @intFromBool(size == 64);
    const imms: u13 = ((~(@as(u13, size) * 2) + 1) & 0x3F) | (ones - 1);
    return (n << 12) | (immr << 6) | imms;
}

pub const LogicOp = enum { @"and", orr, eor };

/// and/orr/eor rd, rn, #imm, with `imm` encoded by `bitmaskImm`. rd 31 would be sp.
/// and x1,x2,#0x3fff → 0x92403441; orr x1,x2,#0x1000 → 0xB2740041.
pub fn logicImm(op: LogicOp, rd: u32, rn: u32, enc: u13) u32 {
    std.debug.assert(rd != SP);
    const base: u32 = switch (op) {
        .@"and" => 0x92000000,
        .orr => 0xB2000000,
        .eor => 0xD2000000,
    };
    return base | (@as(u32, enc) << 10) | (rn << 5) | rd;
}

/// and rd, rn, rm — bitwise AND (logical-shifted-reg, LSL#0). and x0,x0,x1 → 0x8A010000.
pub fn andReg(rd: u32, rn: u32, rm: u32) u32 {
    return 0x8A000000 | (rm << 16) | (rn << 5) | rd;
}

/// orr rd, rn, rm — bitwise OR. orr x0,x0,x1 → 0xAA010000.
pub fn orrReg(rd: u32, rn: u32, rm: u32) u32 {
    return 0xAA000000 | (rm << 16) | (rn << 5) | rd;
}

/// eor rd, rn, rm — bitwise XOR. eor x0,x0,x1 → 0xCA010000.
pub fn eorReg(rd: u32, rn: u32, rm: u32) u32 {
    return 0xCA000000 | (rm << 16) | (rn << 5) | rd;
}

/// orn rd, rn, rm — OR-NOT (ORR with N=1). orn x0,xzr,x1 → 0xAA2103E0.
pub fn orn(rd: u32, rn: u32, rm: u32) u32 {
    return 0xAA200000 | (rm << 16) | (rn << 5) | rd;
}

/// mvn rd, rm — bitwise complement, alias of `orn rd, xzr, rm` (mirrors `neg`=`sub
/// rd,xzr,rm`). mvn x0,x0 → 0xAA2003E0.
pub fn mvn(rd: u32, rm: u32) u32 {
    return orn(rd, XZR, rm);
}

/// lslv rd, rn, rm — logical shift left by register (masks amt mod 64). lslv
/// x0,x0,x1 → 0x9AC12000.
pub fn lslv(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9AC02000 | (rm << 16) | (rn << 5) | rd;
}

/// lsrv rd, rn, rm — logical shift right by register. lsrv x0,x0,x1 → 0x9AC12400.
pub fn lsrv(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9AC02400 | (rm << 16) | (rn << 5) | rd;
}

/// asrv rd, rn, rm — arithmetic shift right by register. asrv x0,x0,x1 → 0x9AC12800.
pub fn asrv(rd: u32, rn: u32, rm: u32) u32 {
    return 0x9AC02800 | (rm << 16) | (rn << 5) | rd;
}

/// asr rd, rn, #shift — arithmetic shift right by immediate (SBFM Xd,Xn,#shift,#63).
/// Used with #63 to broadcast the sign bit for the Go ashr amt>=width fill.
/// asr x0,x0,#63 → 0x937FFC00.
pub fn asrImm(rd: u32, rn: u32, shift: u6) u32 {
    return 0x93400000 | (@as(u32, shift) << 16) | (@as(u32, 63) << 10) | (rn << 5) | rd;
}

/// cmn rn, #imm12 — alias of ADDS XZR, Xn, #imm12: the flags of `rn + imm12`.
/// cmn x3,#5 → 0xB100147F.
pub fn cmnImm(rn: u32, imm12: u12) u32 {
    return 0xB1000000 | (@as(u32, imm12) << 10) | (rn << 5) | XZR;
}

/// The shift a shifted-register operand or a shift-by-immediate applies.
pub const Shift = enum(u2) { lsl = 0, lsr = 1, asr = 2 };

/// add rd, rn, rm, <shift> #amt. add x1,x2,x3,lsr #63 → 0x8B43FC41.
pub fn addShifted(rd: u32, rn: u32, rm: u32, shift: Shift, amt: u6) u32 {
    return 0x8B000000 | (@as(u32, @intFromEnum(shift)) << 22) | (rm << 16) | (@as(u32, amt) << 10) | (rn << 5) | rd;
}

/// sub rd, rn, rm, <shift> #amt. sub x1,x2,x3,lsl #1 → 0xCB030441.
pub fn subShifted(rd: u32, rn: u32, rm: u32, shift: Shift, amt: u6) u32 {
    return 0xCB000000 | (@as(u32, @intFromEnum(shift)) << 22) | (rm << 16) | (@as(u32, amt) << 10) | (rn << 5) | rd;
}

/// lsl/lsr/asr rd, rn, #amt (UBFM/SBFM aliases). lsr x1,x2,#1 → 0xD341FC41; lsl x1,x2,#1
/// → 0xD37FF841.
pub fn shiftImm(shift: Shift, rd: u32, rn: u32, amt: u6) u32 {
    return switch (shift) {
        .lsr => 0xD340FC00 | (@as(u32, amt) << 16) | (rn << 5) | rd,
        .asr => asrImm(rd, rn, amt),
        .lsl => 0xD3400000 | (@as(u32, (64 - @as(u32, amt)) % 64) << 16) | (@as(u32, 63 - @as(u32, amt)) << 10) | (rn << 5) | rd,
    };
}

/// csel rd, rn, rm, cond — rd = cond ? rn : rm; cond in bits[15:12].
/// csel x0,xzr,x0,hs → 0x9A8023E0.
pub fn csel(rd: u32, rn: u32, rm: u32, c: Cond) u32 {
    return 0x9A800000 | (rm << 16) | (@as(u32, @intFromEnum(c)) << 12) | (rn << 5) | rd;
}

/// str rt, [sp, #byteOff] — 64-bit store; byteOff must be a multiple of 8 (the
/// encoded imm12 is the scaled word index). str x0,[sp,#8] → 0xF90007E0.
pub fn strSp(rt: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 8 == 0);
    const scaled: u32 = byteOff / 8;
    std.debug.assert(scaled <= max_scaled);
    return 0xF9000000 | (scaled << 10) | (SP << 5) | rt;
}

/// ldr rt, [sp, #byteOff] — 64-bit load; byteOff multiple of 8. ldr x1,[sp,#8]
/// → 0xF94007E1.
pub fn ldrSp(rt: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 8 == 0);
    const scaled: u32 = byteOff / 8;
    std.debug.assert(scaled <= max_scaled);
    return 0xF9400000 | (scaled << 10) | (SP << 5) | rt;
}

/// bl #(imm26 words) — branch-and-link, PC-relative by a signed *word* offset
/// (the raw imm26 field). The linker patches the placeholder `bl #0` with
/// imm26 = (target_off − site_off) / 4 for each `.call26` relocation.
/// bl #0 → 0x94000000.
pub fn bl(imm26: i26) u32 {
    const bits: u32 = @as(u26, @bitCast(imm26));
    return 0x94000000 | bits;
}

// These four encoders are how codegen reaches data the linker only sizes at the very
// end: a string in `__cstring` and the `_write` slot in `__got`. `adrp` forms a
// 4 KiB-page-relative base, `addImm` adds the in-page byte offset (for a cstring
// literal address), `ldrRegUoff` loads the GOT slot, and `blr` calls it. The
// `page_delta`/offset placeholders are 0 at emit time; the post-vmaddr pass
// (`Link.applyDataRelocs`, via the `patch*` helpers below) rewrites them once
// MachO assigns the final segment vmaddrs. Each word was assembler-verified on
// this host (see the tests).

/// adrp rd, #(page_delta pages) — form the address of a 4 KiB *page* PC-relative
/// by a signed 21-bit page count (units of 4096, NOT 0x4000). The placeholder
/// emit uses page_delta = 0. adrp x8,0 → 0x90000008; adrp x16,4 → 0x90000030.
pub fn adrp(rd: u32, page_delta: i21) u32 {
    const u: u21 = @bitCast(page_delta);
    return 0x90000000 | ((@as(u32, u) & 3) << 29) | (((@as(u32, u) >> 2) & 0x7FFFF) << 5) | rd;
}

/// adr rd, #imm21 — form a PC-relative address by a signed 21-bit *byte* offset
/// (immlo = imm[1:0] at bits[30:29], immhi = imm[20:2] at bits[23:5]). Used to
/// self-locate __text at runtime (`adr rd, .` → the instruction's own address).
/// adr x9,. → 0x10000009; adr x0,#4 → 0x10000020; adr x11,#-8 → 0x10FFFFCB.
pub fn adr(rd: u32, imm21: i21) u32 {
    const u: u21 = @bitCast(imm21);
    return 0x10000000 | ((@as(u32, u) & 3) << 29) | (((@as(u32, u) >> 2) & 0x7FFFF) << 5) | rd;
}

/// ldr rt, [rn, #byteOff] — 64-bit load, unsigned scaled offset, arbitrary base
/// register `rn`. byteOff must be a multiple of 8. ldr x16,[x16] → 0xF9400210;
/// ldr x16,[x16,#0x18] → 0xF9400E10.
pub fn ldrRegUoff(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 8 == 0);
    const scaled: u32 = byteOff / 8;
    std.debug.assert(scaled <= max_scaled);
    return 0xF9400000 | (scaled << 10) | (rn << 5) | rt;
}

/// ldrb wt, [rn, #byteOff] — zero-extended single-byte load, unsigned offset (the
/// imm12 is UNSCALED for a byte access, so `byteOff` is a raw byte displacement,
/// unlike `ldrRegUoff`'s /8 scaling). ldrb w0,[x0] → 0x39400000; ldrb w0,[x0,#1] →
/// 0x39400400. The str byte-compare reads `ptr[i]` with this.
pub fn ldrbRegUoff(rt: u32, rn: u32, byteOff: u12) u32 {
    return 0x39400000 | (@as(u32, byteOff) << 10) | (rn << 5) | rt;
}

/// ldr wt, [rn, #byteOff] — 32-bit zero-extended word load, unsigned scaled offset
/// (byteOff a multiple of 4). ldr w0,[x0] → 0xB9400000; ldr w0,[x0,#4] → 0xB9400400.
/// The GC root scan reads the packed `[u32 n][u32 sp_off …]` stack-map payload with it.
pub fn ldrwRegUoff(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 4 == 0);
    const scaled: u32 = byteOff / 4;
    std.debug.assert(scaled <= max_scaled);
    return 0xB9400000 | (scaled << 10) | (rn << 5) | rt;
}

/// str rt, [rn, #byteOff] — 64-bit store, unsigned scaled offset, arbitrary base
/// register `rn`. byteOff must be a multiple of 8. str x0,[x8] → 0xF9000100;
/// str x1,[x8,#8] → 0xF9000501. Symmetric to `ldrRegUoff`; used for the
/// indirect/x8 sret store-through-pointer and struct byte-copies.
pub fn strRegUoff(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 8 == 0);
    const scaled: u32 = byteOff / 8;
    std.debug.assert(scaled <= max_scaled);
    return 0xF9000000 | (scaled << 10) | (rn << 5) | rt;
}

/// blr rn — indirect branch-and-link through a register. blr x16 → 0xD63F0200.
pub fn blr(rn: u32) u32 {
    return 0xD63F0000 | (rn << 5);
}

/// strb wt, [rn, #byteOff] — single-byte store, unsigned offset (the imm12 is UNSCALED
/// for a byte access, mirroring `ldrbRegUoff`). strb w13,[x10] → 0x3900014D;
/// strb w0,[x0,#1] → 0x39000400. The int-renderer writes each ASCII digit this way.
pub fn strb(rt: u32, rn: u32, byteOff: u12) u32 {
    return 0x39000000 | (@as(u32, byteOff) << 10) | (rn << 5) | rt;
}

/// strh wt, [rn, #byteOff] — halfword store, unsigned offset scaled by 2.
/// strh w9,[sp,#2] → 0x790007E9.
pub fn strh(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 2 == 0 and byteOff / 2 <= 0xFFF);
    return 0x79000000 | ((byteOff / 2) << 10) | (rn << 5) | rt;
}

/// str wt, [rn, #byteOff] — 32-bit store, unsigned offset scaled by 4.
/// str w9,[sp,#8] → 0xB9000BE9.
pub fn strW(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 4 == 0 and byteOff / 4 <= 0xFFF);
    return 0xB9000000 | ((byteOff / 4) << 10) | (rn << 5) | rt;
}

/// cbz rt, #(imm19 words) — branch if rt == 0, PC-relative signed word offset. The
/// renderer never uses it directly but it completes the cbz/cbnz pair; symmetric to
/// `cbnz`. cbz x0,#0 → 0xB4000000; cbz x0,#-4 → 0xB4FFFF80.
pub fn cbz(rt: u32, imm19: i19) u32 {
    return 0xB4000000 | (@as(u32, @as(u19, @bitCast(imm19))) << 5) | rt;
}

/// b.cond #(imm19 words) — conditional branch, PC-relative signed word offset in
/// bits[23:5], cond in bits[3:0]. Emits the RESOLVED word directly (compile-time-known
/// local offset), unlike the `#0`-placeholder + `patchBCond` codegen path. b.ge #+2 →
/// 0x5400004A; b.ge #+4 → 0x5400008A.
pub fn bCond(cond: Cond, imm19: i19) u32 {
    return 0x54000000 | (@as(u32, @as(u19, @bitCast(imm19))) << 5) | @as(u32, @intFromEnum(cond));
}

/// mov rd, rm — register move (alias of `orr rd, xzr, rm`). mov x2,x1 →
/// 0xAA0103E2; mov x1,x0 → 0xAA0003E1.
pub fn movReg(rd: u32, rm: u32) u32 {
    return 0xAA0003E0 | (rm << 16) | rd;
}

// The placeholder words carry the destination register(s) in their low fields;
// these recover those and re-encode with the resolved page delta / offset, so
// the patch needs no separate record of which register the emitter chose.

/// Re-encode an `adrp` placeholder with the resolved page delta, keeping its rd.
pub fn patchAdrp(word: u32, page_delta: i21) u32 {
    const rd: u32 = word & 0x1F;
    return adrp(rd, page_delta);
}

/// Re-encode an `add (imm12)` placeholder with the resolved low-12 offset,
/// keeping its rd/rn.
pub fn patchAddImm12(word: u32, imm12: u12) u32 {
    const rd: u32 = word & 0x1F;
    const rn: u32 = (word >> 5) & 0x1F;
    return addImm(rd, rn, imm12);
}

/// Re-encode a `movz`/`movk` placeholder with a resolved 16-bit immediate,
/// keeping its opcode + shift-lane (hw) + rd (the imm16 field is bits[20:5]).
/// The linker uses this to bake a link-time text offset into the __panic
/// self-locate sequence. patchMovImm16(movz(10,0,0), 0x1234) → movz x10,#0x1234.
pub fn patchMovImm16(word: u32, imm16: u16) u32 {
    return (word & 0xFFE0001F) | (@as(u32, imm16) << 5);
}

/// Re-encode an `ldr (unsigned-offset)` placeholder with the resolved byte
/// offset, keeping its rt/rn.
pub fn patchLdrUoff(word: u32, byteOff: u32) u32 {
    const rt: u32 = word & 0x1F;
    const rn: u32 = (word >> 5) & 0x1F;
    return ldrRegUoff(rt, rn, byteOff);
}

// WHY: codegen needs to test values and jump. Comparisons set NZCV via SUBS-to-XZR
// (`cmp`), a condition turns NZCV into 0/1 (`cset`) in VALUE context or steers a
// `b.cond`/`cbz`/`cbnz` in CONTROL context, and `b` is the unconditional jump.
// Branch targets are intra-function byte offsets resolved by Codegen backpatch
// (NOT relocations): the imm field is (target_byte − site_byte)/4, two's
// complement, so a `#0` placeholder is emitted then rewritten by the patchers.
// Every word below was assembler-verified on this host (see the tests).

/// AArch64 condition codes. Equality (eq/ne), the SIGNED magnitude comparisons
/// (ge/lt/gt/le), and — since codegen dispatches unsigned integer compares by operand
/// signedness — the UNSIGNED magnitude comparisons (hs/lo/hi/ls). Values are the
/// 4-bit cond field encoding (e.g. b.cond carries cond in bits[3:0]).
pub const Cond = enum(u4) {
    eq = 0x0, // equal (Z==1)
    ne = 0x1, // not equal (Z==0)
    hs = 0x2, // unsigned >=
    lo = 0x3, // unsigned <
    mi = 0x4, // N==1 (float <: unordered→false, NOT `lt` which is unordered→true)
    pl = 0x5, // N==0 (the inverse of `mi`)
    vs = 0x6, // signed overflow (V==1)
    vc = 0x7, // no signed overflow (V==0)
    hi = 0x8, // unsigned >
    ls = 0x9, // unsigned <=
    ge = 0xA, // signed >=
    lt = 0xB, // signed <
    gt = 0xC, // signed >
    le = 0xD, // signed <=
};

/// Logical negation of a condition (swaps the branch sense). Used by genCond to
/// branch on the inverse, and by `cset` which physically encodes the inverted
/// condition (CSINC reads the inverse).
pub fn invert(c: Cond) Cond {
    return switch (c) {
        .eq => .ne,
        .ne => .eq,
        .lt => .ge,
        .ge => .lt,
        .gt => .le,
        .le => .gt,
        .lo => .hs,
        .hs => .lo,
        .hi => .ls,
        .ls => .hi,
        .mi => .pl,
        .pl => .mi,
        .vs => .vc,
        .vc => .vs,
    };
}

/// cmp rn, rm — alias of SUBS XZR, Xn, Xm (subtract, set flags, discard result).
/// cmp x1,x0 → 0xEB00003F; cmp x0,x1 → 0xEB01001F.
pub fn cmpReg(rn: u32, rm: u32) u32 {
    return 0xEB000000 | (rm << 16) | (rn << 5) | XZR;
}

/// cmp rn, #imm12 — alias of SUBS XZR, Xn, #imm12 (unshifted). cmp x0,#5 →
/// 0xF100141F; cmp x0,#0 → 0xF100001F; cmp x1,#0 → 0xF100003F.
pub fn cmpImm(rn: u32, imm12: u12) u32 {
    return 0xF1000000 | (@as(u32, imm12) << 10) | (rn << 5) | XZR;
}

/// cset rd, cond — alias of CSINC Xd, XZR, XZR, invert(cond): set rd to 1 if the
/// condition holds, else 0. The encoding stores the INVERTED condition in
/// bits[15:12] (CSINC increments the false-source when the inverse holds).
/// cset x0,eq → 0x9A9F17E0; cset x0,lt → 0x9A9FA7E0; cset x2,lt → 0x9A9FA7E2.
pub fn cset(rd: u32, c: Cond) u32 {
    return 0x9A9F07E0 | (@as(u32, @intFromEnum(invert(c))) << 12) | rd;
}

/// cbnz rt, #(imm19 words) — branch if rt != 0. cbnz x0,#0 → 0xB5000000;
/// cbnz x0,#-4 → 0xB5FFFF80.
pub fn cbnz(rt: u32, imm19: i19) u32 {
    return 0xB5000000 | (@as(u32, @as(u19, @bitCast(imm19))) << 5) | rt;
}

/// b #(imm26 words) — unconditional branch, PC-relative signed word offset in
/// bits[25:0]. b #0 → 0x14000000; b #+2 → 0x14000002; b #-2 → 0x17FFFFFE.
pub fn b(imm26: i26) u32 {
    return 0x14000000 | @as(u32, @as(u26, @bitCast(imm26)));
}

// Emit a branch with a #0 placeholder, record its site + target label, then
// rewrite only the imm field once the label's byte offset is known. The opcode
// + identity (cond for b.cond, rt for cbz/cbnz) is preserved. For b.cond and
// cbz/cbnz the mask 0xFF00001F keeps the top byte (0x54/0xB4/0xB5) and the low 5
// bits (cond ⊂ low4, or rt = low5) while clearing the imm19 field at bits[23:5].

/// Rewrite a b.cond placeholder's imm19, keeping opcode + cond. Round-trips:
/// patchBCond(0x54000000, 2) → 0x54000040.
pub fn patchBCond(word: u32, imm19: i19) u32 {
    return (word & 0xFF00001F) | (@as(u32, @as(u19, @bitCast(imm19))) << 5);
}

/// Rewrite a cbz/cbnz placeholder's imm19, keeping opcode + rt. Round-trips:
/// patchCbz(0xB4000000, -4) → 0xB4FFFF80.
pub fn patchCbz(word: u32, imm19: i19) u32 {
    return (word & 0xFF00001F) | (@as(u32, @as(u19, @bitCast(imm19))) << 5);
}

/// Rewrite a `b` placeholder's imm26 (full opcode is fixed). Round-trips:
/// patchB(b(0), -2) → 0x17FFFFFE.
pub fn patchB(word: u32, imm26: i26) u32 {
    _ = word;
    return b(imm26);
}

/// stp x29, x30, [sp, #-16]! — pre-index store of the FP/LR pair; opens the
/// frame in one instruction. → 0xA9BF7BFD.
pub const stpFpLrPre: u32 = 0xA9BF7BFD;

/// mov x29, sp (add x29, sp, #0) — set the frame pointer. → 0x910003FD.
pub const movFpSp: u32 = 0x910003FD;

/// ldp x29, x30, [sp], #16 — post-index load of the FP/LR pair; closes the
/// frame. → 0xA8C17BFD.
pub const ldpFpLrPost: u32 = 0xA8C17BFD;

/// ret (returns to x30). → 0xD65F03C0.
pub const ret: u32 = 0xD65F03C0;

/// The register file a pair or unscaled access moves: X registers or the D view of the
/// FP registers.
pub const File = enum { x, d };

/// stp/ldp rt, rt2, [rn, #off] (signed offset, no writeback): off a multiple of 8 in
/// -512..504. stp x19, x20, [x29, #-16] → 0xA93F53B3.
pub fn pairOff(file: File, load: bool, rt: u32, rt2: u32, rn: u32, off: i32) u32 {
    std.debug.assert(@mod(off, 8) == 0 and off >= -512 and off <= 504);
    const imm7: u32 = @as(u32, @bitCast(@divExact(off, 8))) & 0x7F;
    const base: u32 = switch (file) {
        .x => 0xA9000000,
        .d => 0x6D000000,
    };
    return base | (@as(u32, @intFromBool(load)) << 22) | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt;
}

/// stur/ldur rt, [rn, #off] (unscaled signed offset): off in -256..255.
/// stur x21, [x29, #-24] → 0xF81E83B5.
pub fn unscaledOff(file: File, load: bool, rt: u32, rn: u32, off: i32) u32 {
    std.debug.assert(off >= -256 and off <= 255);
    const imm9: u32 = @as(u32, @bitCast(off)) & 0x1FF;
    const base: u32 = switch (file) {
        .x => 0xF8000000,
        .d => 0xFC000000,
    };
    return base | (@as(u32, @intFromBool(load)) << 22) | (imm9 << 12) | (rn << 5) | rt;
}

/// brk #0 — a software breakpoint that aborts with SIGILL. The backstop after the
/// `bl panic` that the `.panic` IR terminator emits, should `panic` ever
/// return. → 0xD4200000.
pub const brk0: u32 = 0xD4200000;

/// svc #0x80 — the macOS/XNU supervisor-call gate. XNU takes the syscall number
/// from x16 (the immediate is ignored) and args from x0..; #0x80 is the BSD
/// convention. SVC = 0xD4000001 | (imm16<<5); 0x80<<5 = 0x1000 -> 0xD4001001. The
/// panic exit path issues `movz x0,#1; movz x16,#1 (SYS_exit); svc #0x80`.
pub const svc0x80: u32 = 0xD4001001;

/// Materialize an arbitrary i64 `value` into register `rd` in the fewest words: one
/// `orr rd, xzr, #imm` for a bitmask immediate, else `movz` at the first nonzero lane or,
/// when more lanes are 0xFFFF than 0, `movn` at the first lane that is not, then a `movk`
/// per remaining lane that differs from the fill. At most 4 words; 0 is `movz rd, #0`.
pub fn movImm64(out: []u8, len: *usize, rd: u32, value: i64) void {
    const u: u64 = @bitCast(value);
    var zeros: u3 = 0;
    var ones: u3 = 0;
    for (0..4) |k| switch (@as(u16, @truncate(u >> @intCast(k * 16)))) {
        0 => zeros += 1,
        0xFFFF => ones += 1,
        else => {},
    };
    if (zeros < 3 and ones < 3) if (bitmaskImm(u)) |enc| return writeWord(out, len, logicImm(.orr, rd, XZR, enc));
    const inverted = ones > zeros;
    const fill: u16 = if (inverted) 0xFFFF else 0;
    if (u == 0 or u == ~@as(u64, 0)) return writeWord(out, len, if (inverted) movn(rd, 0, 0) else movz(rd, 0, 0));
    var first = true;
    for (0..4) |k| {
        const hw: u2 = @intCast(k);
        const lane: u16 = @truncate(u >> @intCast(k * 16));
        if (lane == fill) continue;
        if (first) {
            writeWord(out, len, if (inverted) movn(rd, ~lane, hw) else movz(rd, lane, hw));
            first = false;
        } else writeWord(out, len, movk(rd, lane, hw));
    }
}

inline fn writeWord(out: []u8, len: *usize, word: u32) void {
    std.mem.writeInt(u32, out[len.*..][0..4], word, .little);
    len.* += 4;
}

// Scalar double-precision FP. D-registers are the SIMD&FP file (0..31); codegen
// uses D16/D17 (caller-saved scratch). fadd/fsub/fmul/fdiv/fcmp are the
// double-precision floating-point data-processing forms (type field = 01). Each
// word assembler-verified on this host (`as -arch arm64` + `objdump -d`), same
// protocol as the integer encoders above.

/// fadd dd, dn, dm — double add. fadd d16,d16,d17 → 0x1E712A10.
pub fn fadd(dd: u32, dn: u32, dm: u32) u32 {
    return 0x1E602800 | (dm << 16) | (dn << 5) | dd;
}

/// fsub dd, dn, dm — double subtract. fsub d16,d16,d17 → 0x1E713A10.
pub fn fsub(dd: u32, dn: u32, dm: u32) u32 {
    return 0x1E603800 | (dm << 16) | (dn << 5) | dd;
}

/// fmul dd, dn, dm — double multiply. fmul d16,d16,d17 → 0x1E710A10.
pub fn fmul(dd: u32, dn: u32, dm: u32) u32 {
    return 0x1E600800 | (dm << 16) | (dn << 5) | dd;
}

/// fdiv dd, dn, dm — double divide (IEEE: /0 → ±inf/NaN, no trap). fdiv
/// d16,d16,d17 → 0x1E711A10.
pub fn fdiv(dd: u32, dn: u32, dm: u32) u32 {
    return 0x1E601800 | (dm << 16) | (dn << 5) | dd;
}

/// fcmp dn, dm — double compare, sets NZCV (unordered → C=1,V=1). fcmp d16,d17 →
/// 0x1E712200.
pub fn fcmp(dn: u32, dm: u32) u32 {
    return 0x1E602000 | (dm << 16) | (dn << 5);
}

/// ldr dt, [rn, #byteOff] — 64-bit FP load, arbitrary base. ldr d16,[x12,#8] → 0xFD400590.
pub fn ldrFpRegUoff(dt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 8 == 0 and byteOff / 8 <= max_scaled);
    return 0xFD400000 | ((byteOff / 8) << 10) | (rn << 5) | dt;
}

/// str dt, [rn, #byteOff] — 64-bit FP store, arbitrary base. str d17,[x12,#4088] → 0xFD07FD91.
pub fn strFpRegUoff(dt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 8 == 0 and byteOff / 8 <= max_scaled);
    return 0xFD000000 | ((byteOff / 8) << 10) | (rn << 5) | dt;
}

/// SCVTF Dd, Xn — signed 64-bit int in a GPR → f64 in a D reg (round-to-nearest-even, FPCR default).
pub fn scvtf(dd: u32, xn: u32) u32 {
    return 0x9E620000 | (xn << 5) | dd;
}

/// FCVTZS Xd, Dn — f64 → signed 64-bit int, truncating toward zero. SATURATES on NaN /
/// out-of-range; the float→int witness fcmp-range-guards BEFORE emitting this, so it only
/// runs on in-range finite inputs (the fallible-narrow ruling wants Err, not saturation).
pub fn fcvtzs(xd: u32, dn: u32) u32 {
    return 0x9E780000 | (dn << 5) | xd;
}

/// The single-precision twin of a double-precision FP data-processing or compare word
/// (`fadd`..`fcmp`): the `ftype` field at bits 22-23 is 01 for double, 00 for single.
pub fn fpSingle(word: u32) u32 {
    return word & ~@as(u32, 0x00400000);
}

/// SCVTF Sd, Xn — signed 64-bit int → f32.
pub fn scvtfS(sd: u32, xn: u32) u32 {
    return 0x9E220000 | (xn << 5) | sd;
}

/// FCVTZS Xd, Sn — f32 → signed 64-bit int, truncating toward zero.
pub fn fcvtzsS(xd: u32, sn: u32) u32 {
    return 0x9E380000 | (sn << 5) | xd;
}

/// FCVT Dd, Sn — f32 → f64, exact.
pub fn fcvtDS(dd: u32, sn: u32) u32 {
    return 0x1E22C000 | (sn << 5) | dd;
}

/// FCVT Sd, Dn — f64 → f32, rounding to nearest.
pub fn fcvtSD(sd: u32, dn: u32) u32 {
    return 0x1E624000 | (dn << 5) | sd;
}

/// FMOV Wd, Sn — the f32 bits into a GPR, zero-extending to 64 bits.
pub fn fmovWS(wd: u32, sn: u32) u32 {
    return 0x1E260000 | (sn << 5) | wd;
}

/// FMOV Dd, Dn — copy a double between FP registers.
pub fn fmovDD(dd: u32, dn: u32) u32 {
    return 0x1E604000 | (dn << 5) | dd;
}

/// FMOV Sd, Sn — copy a single between FP registers, zeroing the upper bits of `dd`.
pub fn fmovSS(sd: u32, sn: u32) u32 {
    return 0x1E204000 | (sn << 5) | sd;
}

/// FMOV Dd, Xn — the 64 bits of a GPR into an FP register.
pub fn fmovDX(dd: u32, xn: u32) u32 {
    return 0x9E670000 | (xn << 5) | dd;
}

/// FMOV Xd, Dn — the 64 bits of an FP register into a GPR.
pub fn fmovXD(xd: u32, dn: u32) u32 {
    return 0x9E660000 | (dn << 5) | xd;
}

/// ldr st, [rn, #byteOff] — 32-bit FP load, offset scaled by 4.
pub fn ldrSRegUoff(st: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 4 == 0 and byteOff / 4 <= 0xFFF);
    return 0xBD400000 | ((byteOff / 4) << 10) | (rn << 5) | st;
}

/// str st, [rn, #byteOff] — 32-bit FP store, offset scaled by 4.
pub fn strSRegUoff(st: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 4 == 0 and byteOff / 4 <= 0xFFF);
    return 0xBD000000 | ((byteOff / 4) << 10) | (rn << 5) | st;
}

/// ldrsb xt, [rn, #byteOff] — sign-extended byte load, unscaled offset.
pub fn ldrsbX(rt: u32, rn: u32, byteOff: u12) u32 {
    return 0x39800000 | (@as(u32, byteOff) << 10) | (rn << 5) | rt;
}

/// ldrh wt, [rn, #byteOff] — zero-extended halfword load, offset scaled by 2.
pub fn ldrh(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 2 == 0 and byteOff / 2 <= 0xFFF);
    return 0x79400000 | ((byteOff / 2) << 10) | (rn << 5) | rt;
}

/// ldrsh xt, [rn, #byteOff] — sign-extended halfword load, offset scaled by 2.
pub fn ldrshX(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 2 == 0 and byteOff / 2 <= 0xFFF);
    return 0x79800000 | ((byteOff / 2) << 10) | (rn << 5) | rt;
}

/// ldrsw xt, [rn, #byteOff] — sign-extended word load, offset scaled by 4.
pub fn ldrswX(rt: u32, rn: u32, byteOff: u32) u32 {
    std.debug.assert(byteOff % 4 == 0 and byteOff / 4 <= 0xFFF);
    return 0xB9800000 | ((byteOff / 4) << 10) | (rn << 5) | rt;
}

// Tests — each expected word is the objdump hex for the matching mnemonic,
// assembled on this host with `as -arch arm64` (see the file doc comment).

const testing = std.testing;

test "single-precision and narrow-access encoders" {
    try testing.expectEqual(@as(u32, 0x1E312A10), fpSingle(fadd(16, 16, 17))); // fadd s16,s16,s17
    try testing.expectEqual(@as(u32, 0x1E313A10), fpSingle(fsub(16, 16, 17)));
    try testing.expectEqual(@as(u32, 0x1E310A10), fpSingle(fmul(16, 16, 17)));
    try testing.expectEqual(@as(u32, 0x1E311A10), fpSingle(fdiv(16, 16, 17)));
    try testing.expectEqual(@as(u32, 0x1E312200), fpSingle(fcmp(16, 17))); // fcmp s16,s17
    try testing.expectEqual(@as(u32, 0x9E220130), scvtfS(16, 9)); // scvtf s16,x9
    try testing.expectEqual(@as(u32, 0x9E380209), fcvtzsS(9, 16)); // fcvtzs x9,s16
    try testing.expectEqual(@as(u32, 0x1E22C210), fcvtDS(16, 16)); // fcvt d16,s16
    try testing.expectEqual(@as(u32, 0x1E624210), fcvtSD(16, 16)); // fcvt s16,d16
    try testing.expectEqual(@as(u32, 0x1E26020B), fmovWS(11, 16)); // fmov w11,s16
    try testing.expectEqual(@as(u32, 0xBD400BF0), ldrSRegUoff(16, SP, 8)); // ldr s16,[sp,#8]
    try testing.expectEqual(@as(u32, 0xBD000BF0), strSRegUoff(16, SP, 8)); // str s16,[sp,#8]
    try testing.expectEqual(@as(u32, 0x39800529), ldrsbX(9, 9, 1)); // ldrsb x9,[x9,#1]
    try testing.expectEqual(@as(u32, 0x79400529), ldrh(9, 9, 2)); // ldrh w9,[x9,#2]
    try testing.expectEqual(@as(u32, 0x79800529), ldrshX(9, 9, 2)); // ldrsh x9,[x9,#2]
    try testing.expectEqual(@as(u32, 0xB9800529), ldrswX(9, 9, 4)); // ldrsw x9,[x9,#4]
}

test "fp encoders" {
    // Each expected word is the objdump hex for the matching mnemonic assembled on
    // this host: write to `/tmp/x.s`, `as -arch arm64 -o /tmp/x.o /tmp/x.s`,
    // `objdump -d /tmp/x.o` — the disassembly's hex column is the ground truth.
    try testing.expectEqual(@as(u32, 0x1E712A10), fadd(16, 16, 17)); // fadd d16,d16,d17
    try testing.expectEqual(@as(u32, 0x1E713A10), fsub(16, 16, 17)); // fsub d16,d16,d17
    try testing.expectEqual(@as(u32, 0x1E710A10), fmul(16, 16, 17)); // fmul d16,d16,d17
    try testing.expectEqual(@as(u32, 0x1E711A10), fdiv(16, 16, 17)); // fdiv d16,d16,d17
    try testing.expectEqual(@as(u32, 0x1E712200), fcmp(16, 17)); // fcmp d16,d17
    try testing.expectEqual(@as(u32, 0x9E620010), scvtf(16, 0)); // scvtf d16, x0
    try testing.expectEqual(@as(u32, 0x9E620020), scvtf(0, 1)); // scvtf d0, x1
    try testing.expectEqual(@as(u32, 0x9E780200), fcvtzs(0, 16)); // fcvtzs x0, d16
    try testing.expectEqual(@as(u32, 0x9E780062), fcvtzs(2, 3)); // fcvtzs x2, d3
    try testing.expectEqual(@as(u32, 0x9A9F57E0), cset(0, .mi)); // cset x0,mi
    try testing.expectEqual(@as(u32, 0x9A9F47E0), cset(0, .pl)); // cset x0,pl
    try testing.expectEqual(Cond.pl, invert(.mi));
    try testing.expectEqual(Cond.mi, invert(.pl));
    try testing.expectEqual(@as(u32, 0x1E604230), fmovDD(16, 17)); // fmov d16,d17
    try testing.expectEqual(@as(u32, 0x1E204230), fmovSS(16, 17)); // fmov s16,s17
    try testing.expectEqual(@as(u32, 0x9E670130), fmovDX(16, 9)); // fmov d16,x9
    try testing.expectEqual(@as(u32, 0x9E660209), fmovXD(9, 16)); // fmov x9,d16
}

test "pair and unscaled callee-save encoders (assembler-verified)" {
    try testing.expectEqual(@as(u32, 0xA93F53B3), pairOff(.x, false, 19, 20, FP, -16)); // stp x19,x20,[x29,#-16]
    try testing.expectEqual(@as(u32, 0xA97F53B3), pairOff(.x, true, 19, 20, FP, -16)); // ldp x19,x20,[x29,#-16]
    try testing.expectEqual(@as(u32, 0x6D3D27A8), pairOff(.d, false, 8, 9, FP, -48)); // stp d8,d9,[x29,#-48]
    try testing.expectEqual(@as(u32, 0x6D7D27A8), pairOff(.d, true, 8, 9, FP, -48)); // ldp d8,d9,[x29,#-48]
    try testing.expectEqual(@as(u32, 0xF81E83B5), unscaledOff(.x, false, 21, FP, -24)); // stur x21,[x29,#-24]
    try testing.expectEqual(@as(u32, 0xF85E83B5), unscaledOff(.x, true, 21, FP, -24)); // ldur x21,[x29,#-24]
    try testing.expectEqual(@as(u32, 0xFC1C83AA), unscaledOff(.d, false, 10, FP, -56)); // stur d10,[x29,#-56]
    try testing.expectEqual(@as(u32, 0xFC5C83AA), unscaledOff(.d, true, 10, FP, -56)); // ldur d10,[x29,#-56]
}

test "move-wide immediates" {
    try testing.expectEqual(@as(u32, 0xD2800500), movz(0, 40, 0)); // movz x0,#40
    try testing.expectEqual(@as(u32, 0xD2800030), movz(16, 1, 0)); // movz x16,#1
    try testing.expectEqual(@as(u32, 0xF2A24680), movk(0, 0x1234, 1)); // movk x0,#0x1234,lsl#16
    try testing.expectEqual(@as(u32, 0xF2BFFFE0), movk(0, 0xFFFF, 1));
    try testing.expectEqual(@as(u32, 0xF2DFFFE0), movk(0, 0xFFFF, 2));
    try testing.expectEqual(@as(u32, 0xF2FFFFE0), movk(0, 0xFFFF, 3));
    try testing.expectEqual(@as(u32, 0x92800004), movn(4, 0, 0)); // movn x4,#0 (→ -1)
    try testing.expectEqual(@as(u32, 0x92800000), movn(0, 0, 0)); // movn x0,#0
}

test "large-offset frame encoders (assembler-verified)" {
    try std.testing.expectEqual(@as(u32, 0x914007EC), addImmLsl12(12, SP, 1));
    try std.testing.expectEqual(@as(u32, 0x917FFFEC), addImmLsl12(12, SP, 4095));
    try std.testing.expectEqual(@as(u32, 0x91400BE9), addImmLsl12(9, SP, 2));
    try std.testing.expectEqual(@as(u32, 0xD14007FF), subImmLsl12(SP, SP, 1));
    try std.testing.expectEqual(@as(u32, 0xD17FFFFF), subImmLsl12(SP, SP, 4095));
    try std.testing.expectEqual(@as(u32, 0xF100058C), subsImm(12, 12, 1));
    try std.testing.expectEqual(@as(u32, 0xAB0A0129), addsReg(9, 9, 10));
    try std.testing.expectEqual(@as(u32, 0x9B4A7D2B), smulh(11, 9, 10));
    try std.testing.expectEqual(@as(u32, 0x9BCA7D2B), umulh(11, 9, 10));
    try std.testing.expectEqual(@as(u32, 0x9A9F77E9), cset(9, .vs));
    try std.testing.expectEqual(@as(u32, 0x9A9F37E9), cset(9, .hs));
    try std.testing.expectEqual(@as(u32, 0x9A9F27E9), cset(9, .lo));
    try std.testing.expectEqual(@as(u32, 0x910003BF), addImm(SP, FP, 0)); // mov sp, x29
    try std.testing.expectEqual(@as(u32, 0xFD400590), ldrFpRegUoff(16, 12, 8));
    try std.testing.expectEqual(@as(u32, 0xFD07FD91), strFpRegUoff(17, 12, 4088));
    try std.testing.expectEqual(@as(u32, 0xF947FD80), ldrRegUoff(0, 12, 4088));
    try std.testing.expectEqual(@as(u32, 0xF90003FF), strSp(XZR, 0));
    try std.testing.expectEqual(@as(u32, 0xF900099F), strRegUoff(XZR, 12, 16));
    try std.testing.expectEqual(@as(u32, 0x54000001), bCond(.ne, 0));
}

test "add/sub immediate" {
    try testing.expectEqual(@as(u32, 0x910043FF), addImm(SP, SP, 16)); // add sp,sp,#16
    try testing.expectEqual(@as(u32, 0xD10043FF), subImm(SP, SP, 16)); // sub sp,sp,#16
}

test "data-processing register" {
    try testing.expectEqual(@as(u32, 0x8B010000), addReg(0, 0, 1)); // add x0,x0,x1
    try testing.expectEqual(@as(u32, 0x8B2E6129), addRegExt(9, 9, 14)); // add x9,x9,x14,uxtx
    try testing.expectEqual(@as(u32, 0x8B2E63E1), addRegExt(1, SP, 14)); // add x1,sp,x14
    try testing.expectEqual(@as(u32, 0x8B2E600C), addRegExt(12, 0, 14)); // add x12,x0,x14,uxtx
    try testing.expectEqual(@as(u32, 0xCB010005), subReg(5, 0, 1)); // sub x5,x0,x1
    try testing.expectEqual(@as(u32, 0xCB010000), subReg(0, 0, 1)); // sub x0,x0,x1
    try testing.expectEqual(@as(u32, 0x9B017C02), mul(2, 0, 1)); // mul x2,x0,x1
    try testing.expectEqual(@as(u32, 0x9B017C00), mul(0, 0, 1)); // mul x0,x0,x1
    try testing.expectEqual(@as(u32, 0x9AC10C03), sdiv(3, 0, 1)); // sdiv x3,x0,x1
    try testing.expectEqual(@as(u32, 0x9AC10C00), sdiv(0, 0, 1)); // sdiv x0,x0,x1
    try testing.expectEqual(@as(u32, 0xCB0003E4), neg(4, 0)); // neg x4,x0
    try testing.expectEqual(@as(u32, 0xCB0003E0), neg(0, 0)); // neg x0,x0
    try testing.expectEqual(@as(u32, 0x9B028C20), msub(0, 1, 2, 3)); // msub x0,x1,x2,x3
    try testing.expectEqual(@as(u32, 0x9B018803), msub(3, 0, 1, 2)); // msub x3,x0,x1,x2
    try testing.expectEqual(@as(u32, 0x9B018040), msub(0, 2, 1, 0)); // msub x0,x2,x1,x0 (the genRem shape)
}

test "width-correct encoders (udiv + sign-extend + low-bits mask)" {
    try testing.expectEqual(@as(u32, 0x9AC00800), udiv(0, 0, 0)); // udiv x0,x0,x0
    try testing.expectEqual(@as(u32, 0x9AC10803), udiv(3, 0, 1)); // udiv x3,x0,x1
    try testing.expectEqual(@as(u32, 0x93401C00), sxtb(0, 0)); // sxtb x0,x0
    try testing.expectEqual(@as(u32, 0x93403C00), sxth(0, 0)); // sxth x0,x0
    try testing.expectEqual(@as(u32, 0x93407C00), sxtw(0, 0)); // sxtw x0,x0
    try testing.expectEqual(@as(u32, 0x92401C00), andLowBits(0, 0, 7)); // and x0,x0,#0xff
    try testing.expectEqual(@as(u32, 0x92403C00), andLowBits(0, 0, 15)); // and x0,x0,#0xffff
    try testing.expectEqual(@as(u32, 0x92407C00), andLowBits(0, 0, 31)); // and x0,x0,#0xffffffff
}

test "logical immediates (assembler-verified)" {
    const Case = struct { op: LogicOp, imm: u64, word: u32 };
    for ([_]Case{
        .{ .op = .@"and", .imm = 0xff, .word = 0x92401c41 },
        .{ .op = .@"and", .imm = 0x3fff, .word = 0x92403441 },
        .{ .op = .orr, .imm = 0x1000, .word = 0xb2740041 },
        .{ .op = .eor, .imm = 0x5555555555555555, .word = 0xd200f041 },
        .{ .op = .@"and", .imm = 0xfffffffffffffff0, .word = 0x927cec41 },
        .{ .op = .@"and", .imm = 0x8000000000000000, .word = 0x92410041 },
        .{ .op = .eor, .imm = 0x7fffffffffffffff, .word = 0xd240f841 },
        .{ .op = .@"and", .imm = 0xff00ff00ff00ff00, .word = 0x92089c41 },
        .{ .op = .orr, .imm = 3, .word = 0xb2400441 },
        .{ .op = .@"and", .imm = 0x7ffffffffffffffe, .word = 0x927ff441 },
    }) |c| try testing.expectEqual(c.word, logicImm(c.op, 1, 2, bitmaskImm(c.imm).?));
    try testing.expectEqual(@as(u32, 0xb2407fe3), logicImm(.orr, 3, XZR, bitmaskImm(0xffffffff).?));
    for ([_]u64{ 0, ~@as(u64, 0), 5, 0x1234, 0xff00ff00ff00ff01, 0x8000000000000005 }) |x|
        try testing.expectEqual(@as(?u13, null), bitmaskImm(x));
}

test "logical immediates decode back to their value" {
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    var n: usize = 0;
    while (n < 20000) : (n += 1) {
        const x = switch (n % 3) {
            0 => rand.int(u64),
            1 => blk: {
                const size: u7 = @as(u7, 2) << rand.uintLessThan(u3, 6);
                const ones = rand.uintLessThan(u7, size - 1) + 1;
                var e: u64 = if (ones == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(ones)) - 1;
                const r = rand.uintLessThan(u7, size);
                const m: u64 = if (size == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(size)) - 1;
                if (r != 0) e = ((e << @intCast(r)) | (e >> @intCast(size - r))) & m;
                var v: u64 = 0;
                var k: u7 = 0;
                while (k < 64) : (k += size) v |= e << @intCast(k);
                break :blk v;
            },
            else => rand.int(u64) & rand.int(u64) & rand.int(u64),
        };
        const enc = bitmaskImm(x) orelse continue;
        try testing.expectEqual(x, decodeBitmask(enc));
    }
}

/// The ARM DecodeBitMasks pseudocode, as the oracle for `bitmaskImm`.
fn decodeBitmask(enc: u13) u64 {
    const n = enc >> 12;
    const immr: u6 = @intCast((enc >> 6) & 0x3F);
    const imms: u6 = @intCast(enc & 0x3F);
    const combined: u7 = (@as(u7, @intCast(n)) << 6) | (~imms & 0x3F);
    const len: u3 = @intCast(6 - @clz(combined));
    const size: u7 = @as(u7, 1) << len;
    const levels: u6 = @intCast(size - 1);
    const s = imms & levels;
    const r = immr & levels;
    const m: u64 = if (size == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(size)) - 1;
    const welem: u64 = if (s + 1 == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(@as(u7, s) + 1)) - 1;
    const elem = if (r == 0) welem else ((welem >> r) | (welem << @intCast(size - r))) & m;
    var v: u64 = 0;
    var k: u7 = 0;
    while (k < 64) : (k += size) v |= elem << @intCast(k);
    return v;
}

test "bitwise, shift, and select encoders" {
    try testing.expectEqual(@as(u32, 0x8A010000), andReg(0, 0, 1)); // and x0,x0,x1
    try testing.expectEqual(@as(u32, 0xAA010000), orrReg(0, 0, 1)); // orr x0,x0,x1
    try testing.expectEqual(@as(u32, 0xCA010000), eorReg(0, 0, 1)); // eor x0,x0,x1
    try testing.expectEqual(@as(u32, 0xAA2103E0), orn(0, XZR, 1)); // orn x0,xzr,x1
    try testing.expectEqual(@as(u32, 0xAA2003E0), mvn(0, 0)); // mvn x0,x0
    try testing.expectEqual(@as(u32, 0x9AC02000), lslv(0, 0, 0)); // lslv x0,x0,x0
    try testing.expectEqual(@as(u32, 0x9AC12000), lslv(0, 0, 1)); // lslv x0,x0,x1
    try testing.expectEqual(@as(u32, 0x9AC12400), lsrv(0, 0, 1)); // lsrv x0,x0,x1
    try testing.expectEqual(@as(u32, 0x9AC12800), asrv(0, 0, 1)); // asrv x0,x0,x1
    try testing.expectEqual(@as(u32, 0x937FFC00), asrImm(0, 0, 63)); // asr x0,x0,#63
    try testing.expectEqual(@as(u32, 0x937FFC02), asrImm(2, 0, 63)); // asr x2,x0,#63
    try testing.expectEqual(@as(u32, 0x9A8023E0), csel(0, XZR, 0, .hs)); // csel x0,xzr,x0,hs
    try testing.expectEqual(@as(u32, 0x9A8123E0), csel(0, XZR, 1, .hs)); // csel x0,xzr,x1,hs
}

test "flag-setting immediate, shifted-register and shift-immediate encoders (assembler-verified)" {
    try testing.expectEqual(@as(u32, 0xB100147F), cmnImm(3, 5)); // cmn x3,#5
    try testing.expectEqual(@as(u32, 0xB13FFC1F), cmnImm(0, 4095)); // cmn x0,#4095
    try testing.expectEqual(@as(u32, 0x8B43FC41), addShifted(1, 2, 3, .lsr, 63)); // add x1,x2,x3,lsr #63
    try testing.expectEqual(@as(u32, 0x8B031041), addShifted(1, 2, 3, .lsl, 4)); // add x1,x2,x3,lsl #4
    try testing.expectEqual(@as(u32, 0x8B830841), addShifted(1, 2, 3, .asr, 2)); // add x1,x2,x3,asr #2
    try testing.expectEqual(@as(u32, 0xCB030441), subShifted(1, 2, 3, .lsl, 1)); // sub x1,x2,x3,lsl #1
    try testing.expectEqual(@as(u32, 0xD37FFC41), shiftImm(.lsr, 1, 2, 63)); // lsr x1,x2,#63
    try testing.expectEqual(@as(u32, 0xD341FC41), shiftImm(.lsr, 1, 2, 1)); // lsr x1,x2,#1
    try testing.expectEqual(@as(u32, 0xD37FF841), shiftImm(.lsl, 1, 2, 1)); // lsl x1,x2,#1
    try testing.expectEqual(@as(u32, 0xD3410041), shiftImm(.lsl, 1, 2, 63)); // lsl x1,x2,#63
    try testing.expectEqual(@as(u32, 0x9341FC41), shiftImm(.asr, 1, 2, 1)); // asr x1,x2,#1
    try testing.expectEqual(@as(u32, 0xB4000005), cbz(5, 0)); // cbz x5,#0
    try testing.expectEqual(@as(u32, 0x54000000), bCond(.eq, 0)); // b.eq #0
}

test "unsigned condition codes invert and cset" {
    try testing.expectEqual(Cond.lo, invert(.hs));
    try testing.expectEqual(Cond.hs, invert(.lo));
    try testing.expectEqual(Cond.ls, invert(.hi));
    try testing.expectEqual(Cond.hi, invert(.ls));
    try testing.expectEqual(@as(u32, 0x9A9F97E0), cset(0, .hi)); // cset x0,hi
}

test "load/store sp-relative" {
    try testing.expectEqual(@as(u32, 0xF90007E0), strSp(0, 8)); // str x0,[sp,#8]
    try testing.expectEqual(@as(u32, 0xF90003E0), strSp(0, 0)); // str x0,[sp,#0]
    try testing.expectEqual(@as(u32, 0xF94007E0), ldrSp(0, 8)); // ldr x0,[sp,#8]
    try testing.expectEqual(@as(u32, 0xF94007E1), ldrSp(1, 8)); // ldr x1,[sp,#8]
}

test "branch/system and frame constants" {
    try testing.expectEqual(@as(u32, 0x94000000), bl(0)); // bl #0
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), stpFpLrPre);
    try testing.expectEqual(@as(u32, 0x910003FD), movFpSp);
    try testing.expectEqual(@as(u32, 0xA8C17BFD), ldpFpLrPost);
    try testing.expectEqual(@as(u32, 0xD65F03C0), ret);
    try testing.expectEqual(@as(u32, 0xD4200000), brk0); // brk #0
    try testing.expectEqual(@as(u32, 0xD4001001), svc0x80); // svc #0x80
}

test "pc-relative data addressing + indirect call" {
    try testing.expectEqual(@as(u32, 0x90000008), adrp(8, 0)); // adrp x8, 0
    try testing.expectEqual(@as(u32, 0x90000010), adrp(16, 0)); // adrp x16, 0
    try testing.expectEqual(@as(u32, 0x90000030), adrp(16, 4)); // adrp x16, +4 pages
    try testing.expectEqual(@as(u32, 0xF9400210), ldrRegUoff(16, 16, 0)); // ldr x16,[x16]
    try testing.expectEqual(@as(u32, 0xF9400E10), ldrRegUoff(16, 16, 0x18)); // ldr x16,[x16,#0x18]
    try testing.expectEqual(@as(u32, 0xD63F0200), blr(16)); // blr x16
    try testing.expectEqual(@as(u32, 0xAA0103E2), movReg(2, 1)); // mov x2, x1
    try testing.expectEqual(@as(u32, 0xAA0003E1), movReg(1, 0)); // mov x1, x0
    // adr — assembler-verified on this host (`as -arch arm64` + objdump).
    try testing.expectEqual(@as(u32, 0x10000009), adr(9, 0)); // adr x9, .
    try testing.expectEqual(@as(u32, 0x10000020), adr(0, 4)); // adr x0, #4
    try testing.expectEqual(@as(u32, 0x10FFFFCB), adr(11, -8)); // adr x11, #-8
    // patchMovImm16 bakes a 16-bit immediate, preserving opcode/hw/rd.
    try testing.expectEqual(movz(10, 0x1234, 0), patchMovImm16(movz(10, 0, 0), 0x1234));
    try testing.expectEqual(movk(10, 0xBEEF, 1), patchMovImm16(movk(10, 0, 1), 0xBEEF));
}

test "str via arbitrary base register (indirect/x8 sret + struct copy)" {
    try testing.expectEqual(@as(u32, 0xF9000100), strRegUoff(0, 8, 0)); // str x0, [x8]
    try testing.expectEqual(@as(u32, 0xF9000501), strRegUoff(1, 8, 8)); // str x1, [x8, #8]
    try testing.expectEqual(@as(u32, 0xF9000909), strRegUoff(9, 8, 16)); // str x9, [x8, #16]
}

test "ldrb zero-extended byte load (str byte-compare)" {
    try testing.expectEqual(@as(u32, 0x39400000), ldrbRegUoff(0, 0, 0)); // ldrb w0,[x0]
    try testing.expectEqual(@as(u32, 0x39400400), ldrbRegUoff(0, 0, 1)); // ldrb w0,[x0,#1]
    try testing.expectEqual(@as(u32, 0x39401441), ldrbRegUoff(1, 2, 5)); // ldrb w1,[x2,#5]
    try testing.expectEqual(@as(u32, 0x397FFC00), ldrbRegUoff(0, 0, 4095)); // ldrb w0,[x0,#4095]
}

test "in-place patchers preserve register fields and resolve immediates" {
    // adrp x8,0 placeholder → adrp x8,0 (delta 0) stays 0x90000008.
    try testing.expectEqual(@as(u32, 0x90000008), patchAdrp(adrp(8, 0), 0));
    // adrp x16,0 placeholder patched to +4 pages → 0x90000030 (rd preserved).
    try testing.expectEqual(@as(u32, 0x90000030), patchAdrp(adrp(16, 0), 4));
    // add x8,x8,#0 placeholder patched to #0x4b0 → 0x9112c108 (rd/rn preserved).
    try testing.expectEqual(@as(u32, 0x9112C108), patchAddImm12(addImm(8, 8, 0), 0x4b0));
    // ldr x16,[x16,#0] placeholder patched to offset 0 → 0xf9400210 (rt/rn kept).
    try testing.expectEqual(@as(u32, 0xF9400210), patchLdrUoff(ldrRegUoff(16, 16, 0), 0));
    try testing.expectEqual(@as(u32, 0xF9400E10), patchLdrUoff(ldrRegUoff(16, 16, 0), 0x18));
}

test "compare + condition codes" {
    try testing.expectEqual(@as(u32, 0xEB00003F), cmpReg(1, 0)); // cmp x1,x0
    try testing.expectEqual(@as(u32, 0xEB01001F), cmpReg(0, 1)); // cmp x0,x1
    try testing.expectEqual(@as(u32, 0xF100141F), cmpImm(0, 5)); // cmp x0,#5
    try testing.expectEqual(@as(u32, 0xF100001F), cmpImm(0, 0)); // cmp x0,#0
    try testing.expectEqual(@as(u32, 0xF100003F), cmpImm(1, 0)); // cmp x1,#0

    try testing.expectEqual(@as(u32, 0x9A9F17E0), cset(0, .eq)); // cset x0,eq
    try testing.expectEqual(@as(u32, 0x9A9F07E0), cset(0, .ne)); // cset x0,ne
    try testing.expectEqual(@as(u32, 0x9A9FA7E0), cset(0, .lt)); // cset x0,lt
    try testing.expectEqual(@as(u32, 0x9A9FC7E0), cset(0, .le)); // cset x0,le
    try testing.expectEqual(@as(u32, 0x9A9FD7E0), cset(0, .gt)); // cset x0,gt
    try testing.expectEqual(@as(u32, 0x9A9FB7E0), cset(0, .ge)); // cset x0,ge
    try testing.expectEqual(@as(u32, 0x9A9FA7E2), cset(2, .lt)); // cset x2,lt

    try testing.expectEqual(Cond.ge, invert(.lt));
    try testing.expectEqual(Cond.ne, invert(.eq));
    try testing.expectEqual(Cond.le, invert(.gt));
    try testing.expectEqual(Cond.eq, invert(.ne));
    try testing.expectEqual(Cond.lt, invert(.ge));
    try testing.expectEqual(Cond.gt, invert(.le));
}

test "conditional + unconditional branches" {
    try testing.expectEqual(@as(u32, 0xB5000000), cbnz(0, 0)); // cbnz x0,.+0
    try testing.expectEqual(@as(u32, 0xB5FFFF80), cbnz(0, -4)); // cbnz x0,.-16

    try testing.expectEqual(@as(u32, 0x14000000), b(0)); // b .+0
    try testing.expectEqual(@as(u32, 0x14000002), b(2)); // b .+8
    try testing.expectEqual(@as(u32, 0x17FFFFFE), b(-2)); // b .-8
    try testing.expectEqual(@as(u32, 0x14000004), b(4)); // b .+16
    try testing.expectEqual(@as(u32, 0x17FFFFFC), b(-4)); // b .-16
}

test "byte-store + conditional-branch encoders" {
    // strb wt,[xn,#imm] — byte store, unscaled imm12 (mirrors ldrb).
    try testing.expectEqual(@as(u32, 0x3900014D), strb(13, 10, 0)); // strb w13,[x10]
    try testing.expectEqual(@as(u32, 0x39000400), strb(0, 0, 1)); // strb w0,[x0,#1]
    try testing.expectEqual(@as(u32, 0x3900002D), strb(13, 1, 0)); // strb w13,[x1]
    try testing.expectEqual(@as(u32, 0x390017E9), strb(9, SP, 5)); // strb w9,[sp,#5]
    try testing.expectEqual(@as(u32, 0x790007E9), strh(9, SP, 2)); // strh w9,[sp,#2]
    try testing.expectEqual(@as(u32, 0xB9000BE9), strW(9, SP, 8)); // str w9,[sp,#8]
    // cbz — symmetric to cbnz (opcode 0xB4 vs 0xB5).
    try testing.expectEqual(@as(u32, 0xB4000000), cbz(0, 0)); // cbz x0,.+0
    try testing.expectEqual(@as(u32, 0xB4FFFF80), cbz(0, -4)); // cbz x0,.-16
    // b.cond — resolved-offset conditional branch (cond in low 4 bits).
    try testing.expectEqual(@as(u32, 0x5400004A), bCond(.ge, 2)); // b.ge .+8
    try testing.expectEqual(@as(u32, 0x5400008A), bCond(.ge, 4)); // b.ge .+16
    try testing.expectEqual(@as(u32, 0x54000000), bCond(.eq, 0)); // b.eq .+0
    // A resolved b.cond round-trips through the placeholder patcher (same imm field).
    try testing.expectEqual(bCond(.lt, -2), patchBCond(bCond(.lt, 0), -2));
}

test "branch patchers preserve opcode + identity" {
    try testing.expectEqual(@as(u32, 0x54000040), patchBCond(0x54000000, 2)); // keep .eq, set +2
    try testing.expectEqual(@as(u32, 0x54FFFFCB), patchBCond(0x5400000B, -2)); // keep .lt, set -2
    try testing.expectEqual(@as(u32, 0xB4FFFF80), patchCbz(0xB4000000, -4)); // keep cbz x0, set -4
    try testing.expectEqual(@as(u32, 0xB5FFFF80), patchCbz(cbnz(0, 0), -4)); // keep cbnz x0, set -4
    try testing.expectEqual(@as(u32, 0x17FFFFFE), patchB(b(0), -2)); // b -2
    try testing.expectEqual(@as(u32, 0x14000004), patchB(b(0), 4)); // b +4
}

test "movImm64 round-trips in the fewest words" {
    const Case = struct { value: i64, words: usize };
    const cases = [_]Case{
        .{ .value = 0, .words = 1 },
        .{ .value = 40, .words = 1 },
        .{ .value = -1, .words = 1 },
        .{ .value = std.math.minInt(i64), .words = 1 },
        .{ .value = std.math.maxInt(i64), .words = 1 },
        .{ .value = 0x10000, .words = 1 },
        .{ .value = 0xFFFFFFFF, .words = 1 },
        .{ .value = 0x12345678, .words = 2 },
        .{ .value = -2, .words = 1 },
        .{ .value = -0x12340001, .words = 1 },
        .{ .value = 0x1234_0000_5678, .words = 2 },
        .{ .value = @bitCast(@as(u64, 0x1234_5678_9ABC_DEF0)), .words = 4 },
        .{ .value = @bitCast(@as(u64, 0xFFFF_1234_FFFF_5678)), .words = 2 },
        .{ .value = @bitCast(@as(u64, 0x0000_FFFF_0000_1234)), .words = 2 },
    };
    for (cases) |c| {
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        movImm64(&buf, &len, 3, c.value);
        try testing.expectEqual(c.words * 4, len);

        var reg: u64 = 0;
        var i: usize = 0;
        while (i < len) : (i += 4) {
            const w = std.mem.readInt(u32, buf[i..][0..4], .little);
            try testing.expectEqual(@as(u32, 3), w & 0x1F); // rd == x3
            const hw: u6 = @intCast((w >> 21) & 0x3);
            const imm16: u64 = (w >> 5) & 0xFFFF;
            const lane_mask = @as(u64, 0xFFFF) << (hw * 16);
            switch (w & 0xFF800000) {
                0xD2800000 => reg = imm16 << (hw * 16),
                0x92800000 => reg = ~(imm16 << (hw * 16)),
                0xF2800000 => reg = (reg & ~lane_mask) | (imm16 << (hw * 16)),
                else => {
                    try testing.expectEqual(@as(u32, 0xB2000000 | (XZR << 5) | 3), w & 0xFF8003FF);
                    reg = decodeBitmask(@intCast((w >> 10) & 0x1FFF));
                },
            }
        }
        try testing.expectEqual(@as(u64, @bitCast(c.value)), reg);
    }
}
