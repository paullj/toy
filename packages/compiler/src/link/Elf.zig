//! The ELF writer: `write` turns a format-neutral `Image` into a runnable Linux executable
//! against glibc, with no system linker (#433).
//!
//! The output is a PIE (`ET_DYN` with `DF_1_PIE`) that loads glibc's dynamic linker
//! (`PT_INTERP`) and `libc.so.6` and `libm.so.6` (`DT_NEEDED`, #60 T13), then each user
//! library. Imports bind through `.got`: one slot per import, filled at load by an
//! `R_*_GLOB_DAT` relocation against an unversioned `.dynsym` entry (#60 T15), all of them
//! before the program runs (`BIND_NOW`), so no PLT or lazy binding exists. ELF's
//! namespace is flat, so an import names no library.
//!
//! Three `PT_LOAD` segments, in file order: read-only (the headers, the dynamic linking
//! tables and `.rodata`, which holds the image's `cstrings`), read-execute (`.text`), and
//! read-write (`.dynamic`, `.got`, then the zero-fill `.bss`). Each starts on its own
//! 64 KiB boundary in memory while the file stays packed, so the image loads under a 4,
//! 16 or 64 KiB page kernel alike. The entry is the image's `entry_off`, the ISA's
//! `_start` (`emit.linkProgram`).
//!
//! Section headers name every part for readelf and debuggers. A debug build adds
//! `.symtab`/`.strtab` (each function, as given: ELF has no `_` prefix) and the
//! `.debug_*` sections, none of them loaded.

const std = @import("std");
const Io = std.Io;
const Dwarf = @import("Dwarf.zig");
const Image = @import("Image.zig");
const Target = @import("../Target.zig");

const EHDR_SIZE = 64;
const PHDR_SIZE = 56;
const SHDR_SIZE = 64;
const SYM_SIZE = 24;
const RELA_SIZE = 24;
const DYN_SIZE = 16;

const ET_DYN = 3;
const EM_AARCH64 = 183;
const EM_X86_64 = 62;

const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_INTERP = 3;
const PT_PHDR = 6;
const PT_GNU_STACK = 0x6474e551;
const PF_X = 1;
const PF_W = 2;
const PF_R = 4;

const SHT_PROGBITS = 1;
const SHT_SYMTAB = 2;
const SHT_STRTAB = 3;
const SHT_RELA = 4;
const SHT_HASH = 5;
const SHT_DYNAMIC = 6;
const SHT_NOBITS = 8;
const SHT_DYNSYM = 11;
const SHF_WRITE = 1;
const SHF_ALLOC = 2;
const SHF_EXECINSTR = 4;

const STB_LOCAL = 0;
const STB_GLOBAL = 1;
const STT_NOTYPE = 0;
const STT_FUNC = 2;

const DT_NULL = 0;
const DT_NEEDED = 1;
const DT_HASH = 4;
const DT_STRTAB = 5;
const DT_SYMTAB = 6;
const DT_RELA = 7;
const DT_RELASZ = 8;
const DT_RELAENT = 9;
const DT_STRSZ = 10;
const DT_SYMENT = 11;
const DT_DEBUG = 21;
const DT_RUNPATH = 29;
const DT_FLAGS = 30;
const DT_FLAGS_1 = 0x6ffffffb;
const DF_BIND_NOW = 0x8;
const DF_1_NOW = 0x1;
const DF_1_PIE = 0x08000000;

/// The largest page any Linux kernel toy targets uses (arm64 can run 64 KiB pages).
pub const segment_align: u64 = 0x10000;

/// The C libraries every program loads (#60 T13), before any user library.
pub const system_libraries = [_][]const u8{ "libc.so.6", "libm.so.6" };

/// What the format writes per ISA: the header's machine, the relocation that fills a GOT
/// slot with a symbol's address, and glibc's dynamic linker.
const Machine = struct { e_machine: u16, glob_dat: u32, interp: []const u8 };

fn machineOf(arch: Target.Arch) Machine {
    return switch (arch) {
        .aarch64 => .{ .e_machine = EM_AARCH64, .glob_dat = 1025, .interp = "/lib/ld-linux-aarch64.so.1" },
        .x86_64 => .{ .e_machine = EM_X86_64, .glob_dat = 6, .interp = "/lib64/ld-linux-x86-64.so.2" },
    };
}

const Sect = enum { interp, dynsym, dynstr, hash, rela, rodata, text, dynamic, got, bss, symtab, strtab, debug_info, debug_abbrev, debug_line, debug_str, shstrtab };

fn sectName(s: Sect) []const u8 {
    return switch (s) {
        .rela => ".rela.dyn",
        inline else => |t| "." ++ @tagName(t),
    };
}

/// Where each part of the image goes: a file offset, and a load address for each loaded
/// part.
const Layout = struct {
    off: std.EnumArray(Sect, u64) = .initFill(0),
    addr: std.EnumArray(Sect, u64) = .initFill(0),
    size: std.EnumArray(Sect, u64) = .initFill(0),
    /// The sections the image carries, in header order (after the null one).
    present: std.EnumSet(Sect) = .initEmpty(),
    phnum: u32,
    shoff: u64,
    total: u64,

    fn index(l: *const Layout, s: Sect) u16 {
        var i: u16 = 1;
        var it = l.present.iterator();
        while (it.next()) |p| {
            if (p == s) return i;
            i += 1;
        }
        unreachable;
    }
};

/// The image's dynamic string table: the libraries, the search path and each import, each
/// NUL-terminated after a leading NUL.
const DynStr = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn add(d: *DynStr, gpa: std.mem.Allocator, s: []const u8) !u32 {
        const at: u32 = @intCast(d.bytes.items.len);
        try d.bytes.appendSlice(gpa, s);
        try d.bytes.append(gpa, 0);
        return at;
    }
};

/// The finished executable for `img`. Caller owns the result. ELF records no name of its
/// own, so `identifier` is unused.
pub fn write(io: Io, gpa: std.mem.Allocator, img: *const Image, identifier: []const u8) error{OutOfMemory}![]u8 {
    _ = identifier;
    const m = machineOf(img.arch);
    const n_imports = img.imports.len;

    var dynstr: DynStr = .{};
    defer dynstr.bytes.deinit(gpa);
    try dynstr.bytes.append(gpa, 0);
    var needed: std.ArrayList(u32) = .empty;
    defer needed.deinit(gpa);
    for (system_libraries) |l| try needed.append(gpa, try dynstr.add(gpa, l));
    for (img.libraries) |l| try needed.append(gpa, try dynstr.add(gpa, l.name));
    var runpath: ?u32 = null;
    if (img.search_paths.len > 0) {
        const joined = try std.mem.join(gpa, ":", img.search_paths);
        defer gpa.free(joined);
        runpath = try dynstr.add(gpa, joined);
    }
    const import_names = try gpa.alloc(u32, n_imports);
    defer gpa.free(import_names);
    for (img.imports, import_names) |im, *at| at.* = try dynstr.add(gpa, im.name);

    const n_dyn: usize = needed.items.len + @intFromBool(runpath != null) + 12;
    const symbols = img.debug.symbols.list;
    const strtab_len: u64 = if (symbols.len == 0) 0 else 1 + img.debug.symbols.names.len + symbols.len;

    var l: Layout = .{ .phnum = 7, .shoff = 0, .total = 0 };
    for (std.enums.values(Sect)) |s| {
        const keep = switch (s) {
            .symtab, .strtab => symbols.len > 0,
            .debug_info, .debug_abbrev, .debug_line, .debug_str => !img.debug.dwarf.isEmpty(),
            else => true,
        };
        if (keep) l.present.insert(s);
    }
    l.size.set(.interp, m.interp.len + 1);
    l.size.set(.dynsym, (n_imports + 1) * SYM_SIZE);
    l.size.set(.dynstr, dynstr.bytes.items.len);
    l.size.set(.hash, 4 * (2 + 1 + n_imports + 1));
    l.size.set(.rela, n_imports * RELA_SIZE);
    l.size.set(.rodata, img.cstrings.len);
    l.size.set(.text, img.text.len);
    l.size.set(.dynamic, n_dyn * DYN_SIZE);
    l.size.set(.got, n_imports * 8);
    l.size.set(.bss, img.bss_size);
    l.size.set(.symtab, if (symbols.len == 0) 0 else (symbols.len + 1) * SYM_SIZE);
    l.size.set(.strtab, strtab_len);
    l.size.set(.debug_info, img.debug.dwarf.info.len);
    l.size.set(.debug_abbrev, img.debug.dwarf.abbrev.len);
    l.size.set(.debug_line, img.debug.dwarf.line.len);
    l.size.set(.debug_str, img.debug.dwarf.str.len);
    var shstrtab: std.ArrayList(u8) = .empty;
    defer shstrtab.deinit(gpa);
    var sh_name: std.EnumArray(Sect, u32) = .initFill(0);
    try shstrtab.append(gpa, 0);
    {
        var it = l.present.iterator();
        while (it.next()) |s| {
            sh_name.set(s, @intCast(shstrtab.items.len));
            try shstrtab.appendSlice(gpa, sectName(s));
            try shstrtab.append(gpa, 0);
        }
    }
    l.size.set(.shstrtab, shstrtab.items.len);

    // The read-only segment loads at 0 with the headers; each later segment starts on a
    // fresh 64 KiB boundary of memory at the same offset within it as in the file.
    var off: u64 = EHDR_SIZE + @as(u64, l.phnum) * PHDR_SIZE;
    var addr: u64 = off;
    const place = struct {
        fn at(lay: *Layout, o: *u64, a: *u64, s: Sect, alignment: u64) void {
            o.* = std.mem.alignForward(u64, o.*, alignment);
            a.* = std.mem.alignForward(u64, a.*, alignment);
            lay.off.set(s, o.*);
            lay.addr.set(s, a.*);
            o.* += lay.size.get(s);
            a.* += lay.size.get(s);
        }
        fn segment(o: u64, a: *u64) void {
            a.* = std.mem.alignForward(u64, a.*, segment_align) + o % segment_align;
        }
    };
    for ([_]struct { Sect, u64 }{ .{ .interp, 1 }, .{ .dynsym, 8 }, .{ .dynstr, 1 }, .{ .hash, 8 }, .{ .rela, 8 }, .{ .rodata, 16 } }) |p|
        place.at(&l, &off, &addr, p[0], p[1]);
    const ro_end = off;
    off = std.mem.alignForward(u64, off, 16);
    place.segment(off, &addr);
    place.at(&l, &off, &addr, .text, 16);
    off = std.mem.alignForward(u64, off, 8);
    place.segment(off, &addr);
    place.at(&l, &off, &addr, .dynamic, 8);
    place.at(&l, &off, &addr, .got, 8);
    const rw_file_end = off;
    // No file bytes: the loader zero-fills it past the segment's file end.
    addr = std.mem.alignForward(u64, addr, 64);
    l.off.set(.bss, off);
    l.addr.set(.bss, addr);
    const rw_mem_end = addr + img.bss_size;
    for ([_]Sect{ .symtab, .strtab, .debug_info, .debug_abbrev, .debug_line, .debug_str, .shstrtab }) |s| {
        if (!l.present.contains(s)) continue;
        off = std.mem.alignForward(u64, off, if (s == .symtab) 8 else 1);
        l.off.set(s, off);
        off += l.size.get(s);
    }
    l.shoff = std.mem.alignForward(u64, off, 8);
    const shnum: u64 = l.present.count() + 1;
    l.total = l.shoff + shnum * SHDR_SIZE;

    const image = try gpa.alloc(u8, @intCast(l.total));
    errdefer gpa.free(image);
    @memset(image, 0);
    var w: Writer = .{ .buf = image };

    // ELF header.
    w.pos = 0;
    w.bytes(&.{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0 });
    w.pos = 16;
    w.put16(ET_DYN);
    w.put16(m.e_machine);
    w.put32(1);
    w.put64(l.addr.get(.text) + img.entry_off);
    w.put64(EHDR_SIZE);
    w.put64(l.shoff);
    w.put32(0);
    w.put16(EHDR_SIZE);
    w.put16(PHDR_SIZE);
    w.put16(@intCast(l.phnum));
    w.put16(SHDR_SIZE);
    w.put16(@intCast(shnum));
    w.put16(l.index(.shstrtab));

    // Program headers.
    const phdrs_size: u64 = @as(u64, l.phnum) * PHDR_SIZE;
    w.phdr(.{ .type = PT_PHDR, .flags = PF_R, .off = EHDR_SIZE, .addr = EHDR_SIZE, .filesz = phdrs_size, .memsz = phdrs_size, .alignment = 8 });
    w.phdr(.{ .type = PT_INTERP, .flags = PF_R, .off = l.off.get(.interp), .addr = l.addr.get(.interp), .filesz = l.size.get(.interp), .memsz = l.size.get(.interp), .alignment = 1 });
    w.phdr(.{ .type = PT_LOAD, .flags = PF_R, .off = 0, .addr = 0, .filesz = ro_end, .memsz = ro_end, .alignment = segment_align });
    w.phdr(.{ .type = PT_LOAD, .flags = PF_R | PF_X, .off = l.off.get(.text), .addr = l.addr.get(.text), .filesz = l.size.get(.text), .memsz = l.size.get(.text), .alignment = segment_align });
    const rw_off = l.off.get(.dynamic);
    const rw_addr = l.addr.get(.dynamic);
    w.phdr(.{ .type = PT_LOAD, .flags = PF_R | PF_W, .off = rw_off, .addr = rw_addr, .filesz = rw_file_end - rw_off, .memsz = rw_mem_end - rw_addr, .alignment = segment_align });
    w.phdr(.{ .type = PT_DYNAMIC, .flags = PF_R | PF_W, .off = rw_off, .addr = rw_addr, .filesz = l.size.get(.dynamic), .memsz = l.size.get(.dynamic), .alignment = 8 });
    w.phdr(.{ .type = PT_GNU_STACK, .flags = PF_R | PF_W, .off = 0, .addr = 0, .filesz = 0, .memsz = 0, .alignment = 16 });
    std.debug.assert(w.pos == EHDR_SIZE + phdrs_size);

    w.pos = l.off.get(.interp);
    w.bytes(m.interp);

    // .dynsym: the null symbol, then each import, undefined and global.
    w.pos = l.off.get(.dynsym) + SYM_SIZE;
    for (import_names) |name| w.sym(.{ .name = name, .info = (STB_GLOBAL << 4) | STT_NOTYPE, .shndx = 0, .value = 0, .size = 0 });

    w.pos = l.off.get(.dynstr);
    w.bytes(dynstr.bytes.items);

    // One bucket: every symbol is undefined here, so a lookup in this image never needs to
    // find one, and the chain lists them all.
    w.pos = l.off.get(.hash);
    w.put32(1);
    w.put32(@intCast(n_imports + 1));
    w.put32(@intCast(n_imports));
    w.put32(0);
    for (1..n_imports + 1) |i| w.put32(@intCast(i - 1));

    w.pos = l.off.get(.rela);
    for (0..n_imports) |i| {
        w.put64(l.addr.get(.got) + i * 8);
        w.put64((@as(u64, i + 1) << 32) | m.glob_dat);
        w.put64(0);
    }

    w.pos = l.off.get(.rodata);
    w.bytes(img.cstrings);

    const text = image[@intCast(l.off.get(.text))..][0..img.text.len];
    @memcpy(text, img.text);

    w.pos = l.off.get(.dynamic);
    for (needed.items) |at| w.dyn(DT_NEEDED, at);
    if (runpath) |at| w.dyn(DT_RUNPATH, at);
    w.dyn(DT_HASH, l.addr.get(.hash));
    w.dyn(DT_STRTAB, l.addr.get(.dynstr));
    w.dyn(DT_SYMTAB, l.addr.get(.dynsym));
    w.dyn(DT_STRSZ, l.size.get(.dynstr));
    w.dyn(DT_SYMENT, SYM_SIZE);
    w.dyn(DT_RELA, l.addr.get(.rela));
    w.dyn(DT_RELASZ, l.size.get(.rela));
    w.dyn(DT_RELAENT, RELA_SIZE);
    w.dyn(DT_DEBUG, 0);
    w.dyn(DT_FLAGS, DF_BIND_NOW);
    w.dyn(DT_FLAGS_1, DF_1_NOW | DF_1_PIE);
    w.dyn(DT_NULL, 0);
    std.debug.assert(w.pos == l.off.get(.dynamic) + l.size.get(.dynamic));

    if (symbols.len > 0) {
        // Each function's size runs to the next symbol, the last one's to the end of text.
        var str_at: u32 = 1;
        w.pos = l.off.get(.symtab) + SYM_SIZE;
        for (symbols, 0..) |s, i| {
            const end: u64 = if (i + 1 < symbols.len) symbols[i + 1].text_off else img.text.len;
            w.sym(.{ .name = str_at, .info = (STB_LOCAL << 4) | STT_FUNC, .shndx = l.index(.text), .value = l.addr.get(.text) + s.text_off, .size = end -| s.text_off });
            str_at += @intCast(s.name.len + 1);
        }
        w.pos = l.off.get(.strtab) + 1;
        for (symbols) |s| {
            w.bytes(s.name);
            w.pos += 1;
        }
    }

    if (!img.debug.dwarf.isEmpty()) {
        const dw = img.debug.dwarf;
        dw.relocate(
            image[@intCast(l.off.get(.debug_info))..][0..dw.info.len],
            image[@intCast(l.off.get(.debug_line))..][0..dw.line.len],
            l.addr.get(.text),
        );
        @memcpy(image[@intCast(l.off.get(.debug_abbrev))..][0..dw.abbrev.len], dw.abbrev);
        @memcpy(image[@intCast(l.off.get(.debug_str))..][0..dw.str.len], dw.str);
    }

    w.pos = l.off.get(.shstrtab);
    w.bytes(shstrtab.items);

    // Section headers: the null one, then each present section.
    w.pos = l.shoff + SHDR_SIZE;
    var it = l.present.iterator();
    while (it.next()) |s| {
        const alloc = @intFromEnum(s) <= @intFromEnum(Sect.bss);
        const h: Shdr = switch (s) {
            .interp, .rodata => .{ .type = SHT_PROGBITS, .flags = SHF_ALLOC, .alignment = if (s == .rodata) 16 else 1 },
            .dynsym => .{ .type = SHT_DYNSYM, .flags = SHF_ALLOC, .link = l.index(.dynstr), .info = 1, .alignment = 8, .entsize = SYM_SIZE },
            .dynstr => .{ .type = SHT_STRTAB, .flags = SHF_ALLOC, .alignment = 1 },
            .hash => .{ .type = SHT_HASH, .flags = SHF_ALLOC, .link = l.index(.dynsym), .alignment = 8, .entsize = 4 },
            .rela => .{ .type = SHT_RELA, .flags = SHF_ALLOC, .link = l.index(.dynsym), .alignment = 8, .entsize = RELA_SIZE },
            .text => .{ .type = SHT_PROGBITS, .flags = SHF_ALLOC | SHF_EXECINSTR, .alignment = 16 },
            .dynamic => .{ .type = SHT_DYNAMIC, .flags = SHF_ALLOC | SHF_WRITE, .link = l.index(.dynstr), .alignment = 8, .entsize = DYN_SIZE },
            .got => .{ .type = SHT_PROGBITS, .flags = SHF_ALLOC | SHF_WRITE, .alignment = 8, .entsize = 8 },
            .bss => .{ .type = SHT_NOBITS, .flags = SHF_ALLOC | SHF_WRITE, .alignment = 64 },
            .symtab => .{ .type = SHT_SYMTAB, .link = l.index(.strtab), .info = @intCast(symbols.len + 1), .alignment = 8, .entsize = SYM_SIZE },
            .strtab, .shstrtab => .{ .type = SHT_STRTAB, .alignment = 1 },
            .debug_info, .debug_abbrev, .debug_line, .debug_str => .{ .type = SHT_PROGBITS, .alignment = 1 },
        };
        w.put32(sh_name.get(s));
        w.put32(h.type);
        w.put64(h.flags);
        w.put64(if (alloc) l.addr.get(s) else 0);
        w.put64(l.off.get(s));
        w.put64(l.size.get(s));
        w.put32(h.link);
        w.put32(h.info);
        w.put64(h.alignment);
        w.put64(h.entsize);
    }
    std.debug.assert(w.pos == l.total);

    if (img.relocs.len > 0) img.patch(io, text, .{
        .text = l.addr.get(.text),
        .cstrings = l.addr.get(.rodata),
        .got = l.addr.get(.got),
        .bss = l.addr.get(.bss),
    });
    return image;
}

const Shdr = struct { type: u32, flags: u64 = 0, link: u32 = 0, info: u32 = 0, alignment: u64, entsize: u64 = 0 };

const Writer = struct {
    buf: []u8,
    pos: u64 = 0,

    fn bytes(w: *Writer, b: []const u8) void {
        @memcpy(w.buf[@intCast(w.pos)..][0..b.len], b);
        w.pos += b.len;
    }

    fn put16(w: *Writer, v: u16) void {
        std.mem.writeInt(u16, w.buf[@intCast(w.pos)..][0..2], v, .little);
        w.pos += 2;
    }

    fn put32(w: *Writer, v: u32) void {
        std.mem.writeInt(u32, w.buf[@intCast(w.pos)..][0..4], v, .little);
        w.pos += 4;
    }

    fn put64(w: *Writer, v: u64) void {
        std.mem.writeInt(u64, w.buf[@intCast(w.pos)..][0..8], v, .little);
        w.pos += 8;
    }

    const Phdr = struct { type: u32, flags: u32, off: u64, addr: u64, filesz: u64, memsz: u64, alignment: u64 };

    fn phdr(w: *Writer, p: Phdr) void {
        w.put32(p.type);
        w.put32(p.flags);
        w.put64(p.off);
        w.put64(p.addr);
        w.put64(p.addr);
        w.put64(p.filesz);
        w.put64(p.memsz);
        w.put64(p.alignment);
    }

    const Sym = struct { name: u32, info: u8, shndx: u16, value: u64, size: u64 };

    fn sym(w: *Writer, s: Sym) void {
        w.put32(s.name);
        w.buf[@intCast(w.pos)] = s.info;
        w.pos += 2;
        w.put16(s.shndx);
        w.put64(s.value);
        w.put64(s.size);
    }

    fn dyn(w: *Writer, tag: u64, val: u64) void {
        w.put64(tag);
        w.put64(val);
    }
};

const testing = std.testing;
const ObjRead = @import("ObjRead.zig");
const reloc = @import("reloc.zig");
const TestIsa = reloc.TestIsa;

const code = [_]u8{0} ** 24;

fn writeTest(gpa: std.mem.Allocator, img: Image) ![]u8 {
    var t = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer t.deinit();
    return write(t.io(), gpa, &img, "unused");
}

fn segmentOf(segs: []const ObjRead.Segment, kind: u32, flags: u32) ?ObjRead.Segment {
    for (segs) |sg| if (sg.kind == kind and (kind != PT_LOAD or sg.flags == flags)) return sg;
    return null;
}

test "a glibc PIE: the interpreter, three 64 KiB-aligned loads, the dynamic section and a non-exec stack" {
    const gpa = testing.allocator;
    const imports = [_]Image.Import{ .{ .name = "__libc_start_main" }, .{ .name = "write" } };
    const bytes = try writeTest(gpa, .{ .arch = .aarch64, .text = &code, .entry_off = 8, .cstrings = "hi\x00", .bss_size = 1024, .imports = &imports, .patcher = &TestIsa.patcher });
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, "\x7fELF\x02\x01\x01", bytes[0..7]);
    try testing.expectEqual(@as(u16, ET_DYN), std.mem.readInt(u16, bytes[16..18], .little));
    try testing.expectEqual(@as(u16, EM_AARCH64), std.mem.readInt(u16, bytes[18..20], .little));

    const o = try ObjRead.parse(bytes);
    try testing.expectEqual(ObjRead.Format.elf, o.format);
    try testing.expectEqualSlices(u8, &code, o.text);
    try testing.expectEqual(o.text_addr + 8, std.mem.readInt(u64, bytes[24..32], .little));

    const segs = try ObjRead.segments(o, gpa);
    defer gpa.free(segs);
    try testing.expectEqual(PT_PHDR, segs[0].kind);
    try testing.expectEqual(PT_INTERP, segs[1].kind);
    const interp = bytes[@intCast(segs[1].offset)..][0..@intCast(segs[1].file_size)];
    try testing.expectEqualStrings("/lib/ld-linux-aarch64.so.1\x00", interp);
    const ro = segmentOf(segs, PT_LOAD, PF_R).?;
    const rx = segmentOf(segs, PT_LOAD, PF_R | PF_X).?;
    const rw = segmentOf(segs, PT_LOAD, PF_R | PF_W).?;
    try testing.expectEqual(@as(u64, 0), ro.offset);
    try testing.expectEqual(o.text_addr, rx.addr);
    try testing.expectEqual(@as(u64, code.len), rx.file_size);
    for ([_]ObjRead.Segment{ ro, rx, rw }) |sg| {
        try testing.expectEqual(segment_align, sg.alignment);
        try testing.expectEqual(sg.offset % segment_align, sg.addr % segment_align);
    }
    // No two loads share a 64 KiB page, so each keeps its own permissions on any kernel.
    try testing.expect(ro.addr + ro.mem_size <= rx.addr / segment_align * segment_align);
    try testing.expect(rx.addr + rx.mem_size <= rw.addr / segment_align * segment_align);
    // The bss is memory past the file bytes.
    try testing.expect(rw.mem_size >= rw.file_size + 1024);
    const dyn_seg = segmentOf(segs, PT_DYNAMIC, 0).?;
    try testing.expectEqual(rw.addr, dyn_seg.addr);
    const stack = segmentOf(segs, PT_GNU_STACK, 0).?;
    try testing.expectEqual(@as(u32, PF_R | PF_W), stack.flags);

    const libs = try ObjRead.libraries(o, gpa);
    defer gpa.free(libs);
    try testing.expectEqual(@as(usize, 2), libs.len);
    try testing.expectEqualStrings("libc.so.6", libs[0].name);
    try testing.expectEqualStrings("libm.so.6", libs[1].name);

    const dyn = try ObjRead.dynamicEntries(o, gpa);
    defer gpa.free(dyn);
    var flags: u64 = 0;
    var flags_1: u64 = 0;
    var rela: u64 = 0;
    var relasz: u64 = 0;
    var hash = false;
    for (dyn) |d| switch (d.tag) {
        DT_FLAGS => flags = d.value,
        DT_FLAGS_1 => flags_1 = d.value,
        DT_RELA => rela = d.value,
        DT_RELASZ => relasz = d.value,
        DT_HASH => hash = true,
        else => {},
    };
    try testing.expectEqual(@as(u64, DF_BIND_NOW), flags);
    try testing.expectEqual(@as(u64, DF_1_NOW | DF_1_PIE), flags_1);
    try testing.expect(hash);
    // One GLOB_DAT per import, against its .dynsym entry, into its GOT slot.
    try testing.expectEqual(@as(u64, 2 * RELA_SIZE), relasz);
    const r1 = bytes[@intCast(rela + RELA_SIZE)..][0..RELA_SIZE];
    try testing.expectEqual((@as(u64, 2) << 32) | 1025, std.mem.readInt(u64, r1[8..16], .little));
    try testing.expectEqual(rw.addr + dyn_seg.file_size + 8, std.mem.readInt(u64, r1[0..8], .little));

    // A release build carries no symbol table or line table.
    const syms = try ObjRead.symbols(o, gpa);
    defer gpa.free(syms);
    try testing.expectEqual(@as(usize, 0), syms.len);
    try testing.expect(try ObjRead.lineTable(o, gpa) == null);
}

test "a debug build adds each function to .symtab as given, and the line table at the text's address" {
    const gpa = testing.allocator;
    const st = try Image.Symbols.build(gpa, &.{ .{ .name = "main", .text_off = 0 }, .{ .name = "m.f", .text_off = 8 }, .{ .name = "_start", .text_off = 16 } });
    defer st.deinit(gpa);
    const files = [_][]const u8{"main.toy"};
    const fns = [_]Dwarf.Fn{.{ .name = "main", .text_off = 0, .size = 8, .file = 0, .rows = &.{ .{ .off = 0, .line = 1 }, .{ .off = 4, .line = 2 } } }};
    const dw = try Dwarf.build(gpa, .{ .files = &files, .cu_file = 0, .comp_dir = "/", .fns = &fns, .text_size = code.len });
    defer dw.deinit(gpa);
    const libs_in = [_]Image.Library{.{ .name = "libz.so.1" }};
    const imports = [_]Image.Import{.{ .name = "__libc_start_main" }};
    const bytes = try writeTest(gpa, .{ .arch = .aarch64, .text = &code, .entry_off = 16, .imports = &imports, .libraries = &libs_in, .search_paths = &.{ "/opt/z", "$ORIGIN" }, .patcher = &TestIsa.patcher, .debug = .{ .symbols = st, .dwarf = dw } });
    defer gpa.free(bytes);
    const o = try ObjRead.parse(bytes);

    const syms = try ObjRead.symbols(o, gpa);
    defer gpa.free(syms);
    try testing.expectEqual(@as(usize, 3), syms.len);
    try testing.expectEqualStrings("main", syms[0].name);
    try testing.expectEqualStrings("m.f", syms[1].name);
    try testing.expectEqualStrings("_start", syms[2].name);
    try testing.expectEqual(o.text_addr + 8, syms[1].addr);
    try testing.expect(!syms[0].external and syms[0].defined);

    const libs = try ObjRead.libraries(o, gpa);
    defer gpa.free(libs);
    try testing.expectEqual(@as(usize, 3), libs.len);
    try testing.expectEqualStrings("libz.so.1", libs[2].name);
    const dyn = try ObjRead.dynamicEntries(o, gpa);
    defer gpa.free(dyn);
    const runpath = for (dyn) |d| {
        if (d.tag == DT_RUNPATH) break std.mem.sliceTo(o.dynstr[@intCast(d.value)..], 0);
    } else "";
    try testing.expectEqualStrings("/opt/z:$ORIGIN", runpath);

    const lines = (try ObjRead.lineTable(o, gpa)).?;
    defer lines.deinit(gpa);
    try testing.expectEqualStrings("main.toy", lines.fileName(1).?);
    try testing.expectEqual(@as(usize, 3), lines.rows.len);
    try testing.expectEqual(o.text_addr + 4, lines.rows[1].addr);
    try testing.expectEqual(@as(u64, 2), lines.rows[1].line);
}

test "the writer patches references to the rodata, GOT and bss at their load addresses" {
    const gpa = testing.allocator;
    var text = [_]u8{0} ** 24;
    const r = [_]reloc.Reloc{
        .{ .site = 0, .target = .{ .cstr = 1 }, .kind = TestIsa.pcrel },
        .{ .site = 8, .target = .{ .import = .{ .kind = .import, .name = "write" } }, .kind = TestIsa.pcrel },
        .{ .site = 16, .target = .{ .data = 8 }, .kind = TestIsa.pcrel },
    };
    const imports = [_]Image.Import{ .{ .name = "__libc_start_main" }, .{ .name = "write" } };
    const bytes = try writeTest(gpa, .{ .arch = .aarch64, .text = &text, .entry_off = 0, .cstrings = "ab\x00", .bss_size = 64, .imports = &imports, .relocs = &r, .patcher = &TestIsa.patcher });
    defer gpa.free(bytes);
    const o = try ObjRead.parse(bytes);
    const targets = blk: {
        var t: [3]u64 = undefined;
        for (&t, 0..) |*v, k| {
            const delta = std.mem.readInt(i32, o.text[k * 8 ..][0..4], .little);
            v.* = @intCast(@as(i64, @intCast(o.text_addr + k * 8)) + delta);
        }
        break :blk t;
    };
    // The read-only load maps the file at address 0, so the string's address is its offset.
    try testing.expectEqual(@as(u8, 'b'), bytes[@intCast(targets[0])]);
    const dyn = try ObjRead.dynamicEntries(o, gpa);
    defer gpa.free(dyn);
    const rela = for (dyn) |d| {
        if (d.tag == DT_RELA) break d.value;
    } else unreachable;
    try testing.expectEqual(std.mem.readInt(u64, bytes[@intCast(rela + RELA_SIZE)..][0..8], .little), targets[1]);
    const segs = try ObjRead.segments(o, gpa);
    defer gpa.free(segs);
    const rw = segmentOf(segs, PT_LOAD, PF_R | PF_W).?;
    try testing.expect(targets[2] >= rw.addr + rw.file_size and targets[2] + 56 <= rw.addr + rw.mem_size);
    try testing.expectEqual(@as(u64, 8), targets[2] % 64);
}
