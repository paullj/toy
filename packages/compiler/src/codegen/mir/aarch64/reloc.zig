//! AArch64's relocation kinds and how each one patches its site. Link carries a kind
//! opaquely and resolves it through `patcher`, so it never names an encoding.

const std = @import("std");
const Aarch64 = @import("encode.zig");
const Link = @import("../../../link/Link.zig");
const Image = @import("../../../link/Image.zig");

///   * `.call26`    — a `bl`: imm26 = (target − site)/4. Intra-module.
///   * `.adrp_page` — an `adrp`: page delta between the site and a cstring/GOT vmaddr.
///   * `.add_lo12`  — an `add (imm12)`: the low-12 bits of the cstring vmaddr.
///   * `.ldr_lo12`  — an `ldr (unsigned offset)`: the low-12 bits of the GOT-slot vmaddr.
///   * `.movw_g0` / `.movw_g1` — bake a SELF-RELATIVE __text offset (`site_abs + addend`)
///                    into a `movz`/`movk` imm16 (low / high halfword). Intra-module.
///
/// Only `.movw_g0`/`.movw_g1` read the addend: it names an instruction relative to the
/// site (the `__panic` self-locate `adr`).
pub const Kind = enum(u8) {
    call26,
    adrp_page,
    add_lo12,
    ldr_lo12,
    movw_g0,
    movw_g1,

    fn phase(k: Kind) Link.RelocPhase {
        return switch (k) {
            .call26, .movw_g0, .movw_g1 => .intra,
            .adrp_page, .add_lo12, .ldr_lo12 => .cross,
        };
    }
};

pub fn of(k: Kind) Link.RelocKind {
    return @enumFromInt(@intFromEnum(k));
}

fn kindOf(k: Link.RelocKind) Kind {
    return @enumFromInt(@intFromEnum(k));
}

const phases = blk: {
    const tags = std.enums.values(Kind);
    var out: [tags.len]Link.RelocPhase = undefined;
    for (tags) |k| out[@intFromEnum(k)] = k.phase();
    break :blk out;
};

pub const patcher: Link.Patcher = .{ .phases = &phases, .patchIntra = patchIntra, .patchCross = patchCross };

/// Raises `CallTargetTooFar` if a `bl` displacement overflows imm26 — it cannot occur
/// within one 0x4000 page, but surface it rather than truncate-and-miscompile.
fn patchIntra(text: []u8, kind: Link.RelocKind, site_abs: u32, target_off: u32, addend: i64) Link.IntraError!void {
    const k = kindOf(kind);
    switch (k) {
        .call26 => {
            const target_abs: i64 = @as(i64, target_off) + addend;
            const delta: i64 = target_abs - @as(i64, site_abs);
            std.debug.assert(@mod(delta, 4) == 0); // BL targets are word-aligned
            const imm: i64 = @divExact(delta, 4);
            if (imm < -(@as(i64, 1) << 25) or imm > (@as(i64, 1) << 25) - 1) return error.CallTargetTooFar;
            std.mem.writeInt(u32, text[site_abs..][0..4], Aarch64.bl(@intCast(imm)), .little);
        },
        .movw_g0, .movw_g1 => {
            // An offset, not an address, so no runtime reloc (PIE-safe).
            const val: u32 = @intCast(@as(i64, site_abs) + addend);
            const imm: u16 = if (k == .movw_g0) @truncate(val) else @truncate(val >> 16);
            const word = std.mem.readInt(u32, text[site_abs..][0..4], .little);
            std.mem.writeInt(u32, text[site_abs..][0..4], Aarch64.patchMovImm16(word, imm), .little);
        },
        .adrp_page, .add_lo12, .ldr_lo12 => unreachable,
    }
}

/// The page delta uses the 4096-byte ARM page (`>>12`), not the 0x4000 Mach-O page;
/// every segment is page-aligned and slides together under PIE/ASLR, so it is exact at
/// run time.
fn patchCross(text: []u8, kind: Link.RelocKind, site: u32, site_vmaddr: u64, target_vmaddr: u64, addend: i64) void {
    std.debug.assert(addend == 0);
    const at = text[site..][0..4];
    std.mem.writeInt(u32, at, patchWord(std.mem.readInt(u32, at, .little), kindOf(kind), site_vmaddr, target_vmaddr), .little);
}

fn patchWord(word: u32, kind: Kind, site_vmaddr: u64, target_vmaddr: u64) u32 {
    return switch (kind) {
        .adrp_page => blk: {
            const pages: i64 = @as(i64, @intCast(target_vmaddr >> 12)) - @as(i64, @intCast(site_vmaddr >> 12));
            break :blk Aarch64.patchAdrp(word, @intCast(pages));
        },
        .add_lo12 => Aarch64.patchAddImm12(word, @intCast(target_vmaddr & 0xFFF)),
        .ldr_lo12 => blk: {
            std.debug.assert(target_vmaddr & 7 == 0);
            break :blk Aarch64.patchLdrUoff(word, @intCast(target_vmaddr & 0xFFF));
        },
        .call26, .movw_g0, .movw_g1 => unreachable,
    };
}

const testing = std.testing;

test "each kind resolves in its phase" {
    try testing.expectEqual(Link.RelocPhase.intra, patcher.phase(of(.call26)));
    try testing.expectEqual(Link.RelocPhase.intra, patcher.phase(of(.movw_g0)));
    try testing.expectEqual(Link.RelocPhase.intra, patcher.phase(of(.movw_g1)));
    try testing.expectEqual(Link.RelocPhase.cross, patcher.phase(of(.adrp_page)));
    try testing.expectEqual(Link.RelocPhase.cross, patcher.phase(of(.add_lo12)));
    try testing.expectEqual(Link.RelocPhase.cross, patcher.phase(of(.ldr_lo12)));
}

test "call26 encodes the signed word delta; overflow surfaces" {
    var text = [_]u8{0} ** 12;
    // bl at site 8 targeting offset 0 → delta −8 → 0x97FFFFFE (ground truth).
    try patchIntra(&text, of(.call26), 8, 0, 0);
    try testing.expectEqual(@as(u32, 0x97FFFFFE), std.mem.readInt(u32, text[8..12], .little));
    // A displacement past ±128 MiB (via addend) overflows imm26.
    try testing.expectError(error.CallTargetTooFar, patchIntra(&text, of(.call26), 0, 0, (@as(i64, 1) << 27) + 4));
}

test "call26 through the link: forward +8, backward −12 and self 0 match the assembler" {
    // Ground truth from `as -arch arm64` + objdump: forward +8 → 0x94000002, backward
    // −12 → 0x97fffffd, self (delta 0) → 0x94000000.
    var text = [_]u8{0} ** 16;
    try patchIntra(&text, of(.call26), 0, 8, 0);
    try testing.expectEqual(@as(u32, 0x94000002), std.mem.readInt(u32, text[0..4], .little));
    try patchIntra(&text, of(.call26), 12, 0, 0);
    try testing.expectEqual(@as(u32, 0x97FFFFFD), std.mem.readInt(u32, text[12..16], .little));
    try patchIntra(&text, of(.call26), 4, 4, 0);
    try testing.expectEqual(@as(u32, 0x94000000), std.mem.readInt(u32, text[4..8], .little));
}

test "movw bakes the site-relative offset halfwords" {
    var text: [8]u8 = undefined;
    std.mem.writeInt(u32, text[0..4], Aarch64.movz(10, 0, 0), .little);
    std.mem.writeInt(u32, text[4..8], Aarch64.movk(10, 0, 1), .little);
    // site 0, addend +0x12340 → value 0x12340; g0 = low16 (0x2340), g1 = high16 (0x0001).
    try patchIntra(&text, of(.movw_g0), 0, 0, 0x12340);
    try patchIntra(&text, of(.movw_g1), 4, 0, 0x12340 - 4);
    try testing.expectEqual(Aarch64.movz(10, 0x2340, 0), std.mem.readInt(u32, text[0..4], .little));
    try testing.expectEqual(Aarch64.movk(10, 0x0001, 1), std.mem.readInt(u32, text[4..8], .little));
}

test "adrp/add/ldr reproduce the clang reference words" {
    // Ground truth from the clang `write` reference:
    //   adrp x8,<cstr> @ site 0x478, target 0x4b0 → 0x90000008
    //   add  x8,x8,#0x4b0                          → 0x9112C108
    //   ldr  x16,[x16]  @ target GOT 0x4000        → 0xF9400210
    const base: u64 = 0x100000000;
    try testing.expectEqual(@as(u32, 0x90000008), patchWord(Aarch64.adrp(8, 0), .adrp_page, base + 0x478, base + 0x4b0));
    try testing.expectEqual(@as(u32, 0x9112C108), patchWord(Aarch64.addImm(8, 8, 0), .add_lo12, base + 0x47c, base + 0x4b0));
    try testing.expectEqual(@as(u32, 0xF9400210), patchWord(Aarch64.ldrRegUoff(16, 16, 0), .ldr_lo12, base + 0x4a8, base + 0x4000));
}

test "Image.patch reaches the cstring, GOT and bss words through the patcher" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();
    const base: u64 = 0x100000000;
    const cstring_vmaddr: u64 = base + 0x4b0;
    const got_vmaddr: u64 = base + 0x4000;
    const imports = [_]Image.Import{.{ .name = "write" }};
    const Case = struct { word: u32, target: Link.SymbolId, kind: Kind, site: u64, want: u32 };
    for ([_]Case{
        .{ .word = Aarch64.adrp(8, 0), .target = .{ .cstr = 0 }, .kind = .adrp_page, .site = 0x478, .want = 0x90000008 },
        .{ .word = Aarch64.addImm(8, 8, 0), .target = .{ .cstr = 0 }, .kind = .add_lo12, .site = 0x47c, .want = 0x9112C108 },
        .{ .word = Aarch64.adrp(16, 0), .target = .{ .import = .{ .kind = .import, .name = "write" } }, .kind = .adrp_page, .site = 0x4a4, .want = 0x90000030 },
        .{ .word = Aarch64.ldrRegUoff(16, 16, 0), .target = .{ .import = .{ .kind = .import, .name = "write" } }, .kind = .ldr_lo12, .site = 0x4a8, .want = 0xF9400210 },
    }) |c| {
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, c.word, .little);
        const r = [_]Link.Reloc{.{ .site = 0, .target = c.target, .kind = of(c.kind) }};
        const img: Image = .{ .arch = .aarch64, .text = &w, .entry_off = 0, .relocs = &r, .patcher = &patcher, .imports = &imports };
        img.patch(io, &w, .{ .text = base + c.site, .cstrings = cstring_vmaddr, .got = got_vmaddr });
        try testing.expectEqual(c.want, std.mem.readInt(u32, &w, .little));
    }
    // A `.data` target lands in the bss segment: two pages up, at its offset.
    var w: [8]u8 = undefined;
    std.mem.writeInt(u32, w[0..4], Aarch64.adrp(9, 0), .little);
    std.mem.writeInt(u32, w[4..8], Aarch64.addImm(9, 9, 0), .little);
    const r = [_]Link.Reloc{
        .{ .site = 0, .target = .{ .data = 0x10 }, .kind = of(.adrp_page) },
        .{ .site = 4, .target = .{ .data = 0x10 }, .kind = of(.add_lo12) },
    };
    const img: Image = .{ .arch = .aarch64, .text = &w, .entry_off = 0, .relocs = &r, .patcher = &patcher, .imports = &imports };
    img.patch(io, &w, .{ .text = base + 0x478, .cstrings = cstring_vmaddr, .got = got_vmaddr, .bss = base + 0x2000 });
    try testing.expectEqual(Aarch64.adrp(9, 2), std.mem.readInt(u32, w[0..4], .little));
    try testing.expectEqual(Aarch64.addImm(9, 9, 0x10), std.mem.readInt(u32, w[4..8], .little));
}
