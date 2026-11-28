//! Reads back what a linked toy binary holds, for tests and scripts on any host: its
//! code, its symbol table, the shared libraries it loads and its DWARF line rows. It
//! stands in for otool, nm and dwarfdump, which exist only on macOS and read only
//! Mach-O.
//!
//! Each format fills the same `Object`; the readers past `parse` look at the format only
//! to decode a table in its own layout. ELF is read through its section headers: `.text`,
//! `.symtab`, `.dynamic` (`DT_NEEDED`) and `.debug_line`; its program headers and dynamic
//! entries are readable too, for tests of the ELF writer.
//!
//! The reader depends on std alone, so the `toy-objdump` tool builds it without the
//! compiler.

const std = @import("std");

pub const Format = enum { macho, elf };

pub const Object = struct {
    format: Format,
    bytes: []const u8,
    /// The code section's bytes and load address.
    text: []const u8,
    text_addr: u64,
    /// The symbol table's entries and string table, in the format's layout; empty when
    /// the binary has none.
    symtab: []const u8 = &.{},
    strtab: []const u8 = &.{},
    debug_line: ?[]const u8 = null,
    /// The load commands (Mach-O) or the dynamic section (ELF).
    libs_raw: []const u8 = &.{},
    /// The string table the dynamic section's names index (ELF).
    dynstr: []const u8 = &.{},
    /// The program headers (ELF).
    phdrs: []const u8 = &.{},
};

pub const ParseError = error{ Truncated, UnknownFormat, UnsupportedFormat, NoText };

pub fn parse(bytes: []const u8) ParseError!Object {
    if (bytes.len < 4) return error.Truncated;
    const magic = std.mem.readInt(u32, bytes[0..4], .little);
    if (magic == macho.MH_MAGIC_64) return macho.parse(bytes);
    if (std.mem.eql(u8, bytes[0..4], "\x7fELF")) return elf.parse(bytes);
    return error.UnknownFormat;
}

pub const Symbol = struct {
    /// As the format stores it: a Mach-O name keeps its leading `_`.
    name: []const u8,
    addr: u64,
    /// Visible to other images, as opposed to local to this one.
    external: bool,
    /// Defined by this image, as opposed to bound from a library.
    defined: bool,
};

/// Every symbol in the symbol table, debugger-only (stab) entries left out. The names
/// point into `o.bytes`.
pub fn symbols(o: Object, gpa: std.mem.Allocator) ![]Symbol {
    return switch (o.format) {
        .macho => macho.symbols(o, gpa),
        .elf => elf.symbols(o, gpa),
    };
}

pub const Library = struct {
    /// The name the loader looks up: a Mach-O install name, an ELF SONAME.
    name: []const u8,
    /// Mach-O's packed `x.y.z` versions; 0 on ELF.
    current_version: u32 = 0,
    compat_version: u32 = 0,
};

/// The shared libraries the binary loads, in load order.
pub fn libraries(o: Object, gpa: std.mem.Allocator) ![]Library {
    return switch (o.format) {
        .macho => macho.libraries(o, gpa),
        .elf => elf.libraries(o, gpa),
    };
}

pub const Segment = struct {
    /// `p_type`, as `PT_LOAD`.
    kind: u32,
    /// `PF_R`/`PF_W`/`PF_X` bits.
    flags: u32,
    offset: u64,
    addr: u64,
    file_size: u64,
    mem_size: u64,
    alignment: u64,
};

/// An ELF binary's program headers, in file order.
pub fn segments(o: Object, gpa: std.mem.Allocator) ![]Segment {
    if (o.format != .elf) return error.UnsupportedFormat;
    const out = try gpa.alloc(Segment, o.phdrs.len / elf.PHDR_SIZE);
    for (out, 0..) |*sg, i| {
        const p = o.phdrs[i * elf.PHDR_SIZE ..][0..elf.PHDR_SIZE];
        sg.* = .{
            .kind = std.mem.readInt(u32, p[0..4], .little),
            .flags = std.mem.readInt(u32, p[4..8], .little),
            .offset = std.mem.readInt(u64, p[8..16], .little),
            .addr = std.mem.readInt(u64, p[16..24], .little),
            .file_size = std.mem.readInt(u64, p[32..40], .little),
            .mem_size = std.mem.readInt(u64, p[40..48], .little),
            .alignment = std.mem.readInt(u64, p[48..56], .little),
        };
    }
    return out;
}

pub const Dynamic = struct { tag: u64, value: u64 };

/// An ELF binary's dynamic entries up to `DT_NULL`, which is left out.
pub fn dynamicEntries(o: Object, gpa: std.mem.Allocator) ![]Dynamic {
    if (o.format != .elf) return error.UnsupportedFormat;
    var out: std.ArrayList(Dynamic) = .empty;
    errdefer out.deinit(gpa);
    var off: usize = 0;
    while (off + 16 <= o.libs_raw.len) : (off += 16) {
        const tag = std.mem.readInt(u64, o.libs_raw[off..][0..8], .little);
        if (tag == 0) break;
        try out.append(gpa, .{ .tag = tag, .value = std.mem.readInt(u64, o.libs_raw[off + 8 ..][0..8], .little) });
    }
    return out.toOwnedSlice(gpa);
}

pub const Row = struct {
    addr: u64,
    line: u64,
    /// The line program's file register: 1-based into `LineTable.files`.
    file: u64,
    /// The row that ends a sequence, one past its last instruction.
    end_sequence: bool,
};

pub const LineTable = struct {
    /// Each file's name as the table records it, without its directory.
    files: []const []const u8,
    /// Every row of every unit, in program order.
    rows: []Row,

    pub fn deinit(t: LineTable, gpa: std.mem.Allocator) void {
        gpa.free(t.files);
        gpa.free(t.rows);
    }

    /// The name of a row's file; null for an index the table does not hold.
    pub fn fileName(t: LineTable, file: u64) ?[]const u8 {
        return if (file >= 1 and file <= t.files.len) t.files[@intCast(file - 1)] else null;
    }
};

pub const LineError = error{ OutOfMemory, BadLineProgram, UnsupportedDwarf };

/// The rows of the binary's DWARF line table, or null when it carries none. File indices
/// are per unit; toy writes one unit.
pub fn lineTable(o: Object, gpa: std.mem.Allocator) LineError!?LineTable {
    const sect = o.debug_line orelse return null;
    return try decodeLines(gpa, sect);
}

/// A DWARF 2-4 line program, every unit of `sect`.
pub fn decodeLines(gpa: std.mem.Allocator, sect: []const u8) LineError!LineTable {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(gpa);
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);
    var r: std.Io.Reader = .fixed(sect);
    while (r.seek < sect.len) decodeUnit(gpa, &r, &files, &rows) catch |e| switch (e) {
        error.OutOfMemory, error.UnsupportedDwarf => |x| return x,
        else => return error.BadLineProgram,
    };
    return .{ .files = try files.toOwnedSlice(gpa), .rows = try rows.toOwnedSlice(gpa) };
}

const DW_LNS_copy = 0x01;
const DW_LNS_advance_pc = 0x02;
const DW_LNS_advance_line = 0x03;
const DW_LNS_set_file = 0x04;
const DW_LNS_set_column = 0x05;
const DW_LNS_negate_stmt = 0x06;
const DW_LNS_set_basic_block = 0x07;
const DW_LNS_const_add_pc = 0x08;
const DW_LNS_fixed_advance_pc = 0x09;
const DW_LNE_end_sequence = 0x01;
const DW_LNE_set_address = 0x02;

fn decodeUnit(gpa: std.mem.Allocator, r: *std.Io.Reader, files: *std.ArrayList([]const u8), rows: *std.ArrayList(Row)) !void {
    const unit_len = try r.takeInt(u32, .little);
    if (unit_len >= 0xfffffff0) return error.UnsupportedDwarf; // 64-bit DWARF
    const end = r.seek + unit_len;
    if (end > r.end) return error.BadLineProgram;
    const version = try r.takeInt(u16, .little);
    if (version < 2 or version > 4) return error.UnsupportedDwarf;
    const header_len = try r.takeInt(u32, .little);
    const prog_start = r.seek + header_len;
    if (prog_start > end) return error.BadLineProgram;
    const min_inst = try r.takeByte();
    if (version >= 4) _ = try r.takeByte(); // maximum_operations_per_instruction
    _ = try r.takeByte(); // default_is_stmt
    const line_base: i8 = @bitCast(try r.takeByte());
    const line_range = try r.takeByte();
    const opcode_base = try r.takeByte();
    if (line_range == 0 or opcode_base == 0) return error.BadLineProgram;
    const lengths = try r.take(opcode_base - 1);
    while ((try r.takeSentinel(0)).len != 0) {} // include_directories
    while (true) {
        const name = try r.takeSentinel(0);
        if (name.len == 0) break;
        try files.append(gpa, name);
        for (0..3) |_| _ = try r.takeLeb128(u64); // directory, mtime, length
    }
    r.seek = prog_start;

    var addr: u64 = 0;
    var file: u64 = 1;
    var line: i64 = 1;
    while (r.seek < end) {
        const op = try r.takeByte();
        if (op >= opcode_base) {
            const adj = op - opcode_base;
            addr = try advance(addr, adj / line_range, min_inst);
            line = std.math.add(i64, line, @as(i64, line_base) + adj % line_range) catch return error.BadLineProgram;
            try rows.append(gpa, try row(addr, line, file, false));
            continue;
        }
        switch (op) {
            0 => {
                const len = try r.takeLeb128(u64);
                if (len == 0) return error.BadLineProgram;
                if (len > end - r.seek) return error.BadLineProgram;
                const sub_end = r.seek + len;
                switch (try r.takeByte()) {
                    DW_LNE_end_sequence => {
                        try rows.append(gpa, try row(addr, line, file, true));
                        addr = 0;
                        file = 1;
                        line = 1;
                    },
                    DW_LNE_set_address => addr = switch (len - 1) {
                        8 => try r.takeInt(u64, .little),
                        4 => try r.takeInt(u32, .little),
                        else => return error.BadLineProgram,
                    },
                    else => {},
                }
                r.seek = sub_end;
            },
            DW_LNS_copy => try rows.append(gpa, try row(addr, line, file, false)),
            DW_LNS_advance_pc => addr = try advance(addr, try r.takeLeb128(u64), min_inst),
            DW_LNS_advance_line => line = std.math.add(i64, line, try r.takeLeb128(i64)) catch return error.BadLineProgram,
            DW_LNS_set_file => file = try r.takeLeb128(u64),
            DW_LNS_set_column => _ = try r.takeLeb128(u64),
            DW_LNS_negate_stmt, DW_LNS_set_basic_block => {},
            DW_LNS_const_add_pc => addr = try advance(addr, (255 - opcode_base) / line_range, min_inst),
            DW_LNS_fixed_advance_pc => addr = try advance(addr, try r.takeInt(u16, .little), 1),
            // A standard opcode this reader does not know: skip its operands, as the
            // header's lengths allow any consumer to.
            else => for (0..lengths[op - 1]) |_| {
                _ = try r.takeLeb128(u64);
            },
        }
    }
    if (r.seek != end) return error.BadLineProgram;
}

fn advance(addr: u64, n: u64, min_inst: u8) error{BadLineProgram}!u64 {
    const by = std.math.mul(u64, n, min_inst) catch return error.BadLineProgram;
    return std.math.add(u64, addr, by) catch error.BadLineProgram;
}

/// A row of the registers. Line 0 is DWARF's "no source line"; below it, the program
/// is broken.
fn row(addr: u64, line: i64, file: u64, end_sequence: bool) error{BadLineProgram}!Row {
    if (line < 0) return error.BadLineProgram;
    return .{ .addr = addr, .line = @intCast(line), .file = file, .end_sequence = end_sequence };
}

/// `x.y.z` from a Mach-O packed version (`x` in the top 16 bits).
pub fn formatVersion(v: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v >> 16, (v >> 8) & 0xff, v & 0xff }) catch unreachable;
}

fn rd64(b: []const u8, off: usize) ParseError!u64 {
    if (off + 8 > b.len) return error.Truncated;
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

fn slice(b: []const u8, off: u64, len: u64) ParseError![]const u8 {
    if (off > b.len or len > b.len - off) return error.Truncated;
    return b[@intCast(off)..][0..@intCast(len)];
}

const macho = struct {
    const MH_MAGIC_64: u32 = 0xfeedfacf;
    const LC_SEGMENT_64: u32 = 0x19;
    const LC_SYMTAB: u32 = 0x2;
    const LC_LOAD_DYLIB: u32 = 0xc;
    const LC_LOAD_WEAK_DYLIB: u32 = 0x80000018;
    const LC_REEXPORT_DYLIB: u32 = 0x8000001f;
    const N_STAB: u8 = 0xe0;
    const N_TYPE: u8 = 0x0e;
    const N_EXT: u8 = 0x01;
    const N_UNDF: u8 = 0x0;
    const NLIST_SIZE = 16;
    const HEADER_SIZE = 32;
    const SECT_SIZE = 80;
    const SEG_SIZE = 72;

    fn rd32(b: []const u8, off: usize) ParseError!u32 {
        if (off + 4 > b.len) return error.Truncated;
        return std.mem.readInt(u32, b[off..][0..4], .little);
    }

    fn parse(b: []const u8) ParseError!Object {
        var o: Object = .{ .format = .macho, .bytes = b, .text = &.{}, .text_addr = 0 };
        var found_text = false;
        const ncmds = try rd32(b, 16);
        const cmds_end = HEADER_SIZE + @as(usize, try rd32(b, 20));
        o.libs_raw = try slice(b, HEADER_SIZE, cmds_end - HEADER_SIZE);
        var off: usize = HEADER_SIZE;
        for (0..ncmds) |_| {
            const cmd = try rd32(b, off);
            const size = try rd32(b, off + 4);
            if (size < 8 or off + size > cmds_end) return error.Truncated;
            switch (cmd) {
                LC_SEGMENT_64 => {
                    const nsects = try rd32(b, off + 64);
                    for (0..nsects) |i| {
                        const s = off + SEG_SIZE + i * SECT_SIZE;
                        const hdr = try slice(b, s, SECT_SIZE);
                        const sect = std.mem.sliceTo(hdr[0..16], 0);
                        const seg = std.mem.sliceTo(hdr[16..32], 0);
                        const addr = try rd64(b, s + 32);
                        const len = try rd64(b, s + 40);
                        const at = try rd32(b, s + 48);
                        if (std.mem.eql(u8, seg, "__TEXT") and std.mem.eql(u8, sect, "__text")) {
                            o.text = try slice(b, at, len);
                            o.text_addr = addr;
                            found_text = true;
                        } else if (std.mem.eql(u8, seg, "__DWARF") and std.mem.eql(u8, sect, "__debug_line")) {
                            o.debug_line = try slice(b, at, len);
                        }
                    }
                },
                LC_SYMTAB => {
                    o.symtab = try slice(b, try rd32(b, off + 8), @as(u64, try rd32(b, off + 12)) * NLIST_SIZE);
                    o.strtab = try slice(b, try rd32(b, off + 16), try rd32(b, off + 20));
                },
                else => {},
            }
            off += size;
        }
        if (!found_text) return error.NoText;
        return o;
    }

    fn symbols(o: Object, gpa: std.mem.Allocator) ![]Symbol {
        var out: std.ArrayList(Symbol) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < o.symtab.len) : (i += NLIST_SIZE) {
            const n = o.symtab[i..][0..NLIST_SIZE];
            const n_type = n[4];
            if (n_type & N_STAB != 0) continue;
            const strx = std.mem.readInt(u32, n[0..4], .little);
            if (strx >= o.strtab.len) return error.Truncated;
            try out.append(gpa, .{
                .name = std.mem.sliceTo(o.strtab[strx..], 0),
                .addr = std.mem.readInt(u64, n[8..16], .little),
                .external = n_type & N_EXT != 0,
                .defined = n_type & N_TYPE != N_UNDF,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    fn libraries(o: Object, gpa: std.mem.Allocator) ![]Library {
        var out: std.ArrayList(Library) = .empty;
        errdefer out.deinit(gpa);
        const b = o.libs_raw;
        var off: usize = 0;
        while (off + 8 <= b.len) {
            const cmd = try rd32(b, off);
            const size = try rd32(b, off + 4);
            if (size < 8 or off + size > b.len) return error.Truncated;
            switch (cmd) {
                LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB => {
                    const name_off = try rd32(b, off + 8);
                    if (name_off >= size) return error.Truncated;
                    try out.append(gpa, .{
                        .name = std.mem.sliceTo(b[off + name_off .. off + size], 0),
                        .current_version = try rd32(b, off + 16),
                        .compat_version = try rd32(b, off + 20),
                    });
                },
                else => {},
            }
            off += size;
        }
        return out.toOwnedSlice(gpa);
    }
};

const elf = struct {
    const PHDR_SIZE = 56;
    const SHDR_SIZE = 64;
    const SYM_SIZE = 24;
    const SHT_SYMTAB = 2;
    const SHT_DYNAMIC = 6;
    const SHT_NOBITS = 8;
    const STT_SECTION = 3;
    const STT_FILE = 4;
    const DT_NEEDED = 1;

    fn parse(b: []const u8) ParseError!Object {
        if (b.len < 64) return error.Truncated;
        // 64-bit, little-endian: the only kind toy writes.
        if (b[4] != 2 or b[5] != 1) return error.UnsupportedFormat;
        var o: Object = .{ .format = .elf, .bytes = b, .text = &.{}, .text_addr = 0 };
        const phoff = rd64(b, 32) catch unreachable;
        const shoff = rd64(b, 40) catch unreachable;
        const phnum = std.mem.readInt(u16, b[56..58], .little);
        const shnum = std.mem.readInt(u16, b[60..62], .little);
        const shstrndx = std.mem.readInt(u16, b[62..64], .little);
        o.phdrs = try slice(b, phoff, @as(u64, phnum) * PHDR_SIZE);
        const shdrs = try slice(b, shoff, @as(u64, shnum) * SHDR_SIZE);
        if (shstrndx >= shnum) return error.NoText;
        const names = try sectionBytes(b, shdrs, shstrndx);
        var found_text = false;
        for (0..shnum) |i| {
            const h = shdrs[i * SHDR_SIZE ..][0..SHDR_SIZE];
            const name_at = std.mem.readInt(u32, h[0..4], .little);
            if (name_at >= names.len) return error.Truncated;
            const name = std.mem.sliceTo(names[name_at..], 0);
            const kind = std.mem.readInt(u32, h[4..8], .little);
            const link = std.mem.readInt(u32, h[40..44], .little);
            if (std.mem.eql(u8, name, ".text")) {
                o.text = try sectionBytes(b, shdrs, i);
                o.text_addr = std.mem.readInt(u64, h[16..24], .little);
                found_text = true;
            } else if (std.mem.eql(u8, name, ".debug_line")) {
                o.debug_line = try sectionBytes(b, shdrs, i);
            } else if (kind == SHT_SYMTAB) {
                o.symtab = try sectionBytes(b, shdrs, i);
                if (link >= shnum) return error.Truncated;
                o.strtab = try sectionBytes(b, shdrs, link);
            } else if (kind == SHT_DYNAMIC) {
                o.libs_raw = try sectionBytes(b, shdrs, i);
                if (link >= shnum) return error.Truncated;
                o.dynstr = try sectionBytes(b, shdrs, link);
            }
        }
        if (!found_text) return error.NoText;
        return o;
    }

    fn sectionBytes(b: []const u8, shdrs: []const u8, i: usize) ParseError![]const u8 {
        const h = shdrs[i * SHDR_SIZE ..][0..SHDR_SIZE];
        if (std.mem.readInt(u32, h[4..8], .little) == SHT_NOBITS) return &.{};
        return slice(b, std.mem.readInt(u64, h[24..32], .little), std.mem.readInt(u64, h[32..40], .little));
    }

    fn symbols(o: Object, gpa: std.mem.Allocator) ![]Symbol {
        var out: std.ArrayList(Symbol) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = SYM_SIZE;
        while (i + SYM_SIZE <= o.symtab.len) : (i += SYM_SIZE) {
            const n = o.symtab[i..][0..SYM_SIZE];
            const kind = n[4] & 0xf;
            if (kind == STT_SECTION or kind == STT_FILE) continue;
            const strx = std.mem.readInt(u32, n[0..4], .little);
            if (strx >= o.strtab.len) return error.Truncated;
            try out.append(gpa, .{
                .name = std.mem.sliceTo(o.strtab[strx..], 0),
                .addr = std.mem.readInt(u64, n[8..16], .little),
                .external = n[4] >> 4 != 0,
                .defined = std.mem.readInt(u16, n[6..8], .little) != 0,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    fn libraries(o: Object, gpa: std.mem.Allocator) ![]Library {
        const dyn = try dynamicEntries(o, gpa);
        defer gpa.free(dyn);
        var out: std.ArrayList(Library) = .empty;
        errdefer out.deinit(gpa);
        for (dyn) |d| {
            if (d.tag != DT_NEEDED) continue;
            if (d.value >= o.dynstr.len) return error.Truncated;
            try out.append(gpa, .{ .name = std.mem.sliceTo(o.dynstr[@intCast(d.value)..], 0) });
        }
        return out.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

test "the line reader follows every opcode toy's line program writes" {
    const Dwarf = @import("Dwarf.zig");
    const gpa = testing.allocator;
    const files = [_][]const u8{ "main.toy", "util.toy" };
    const fns = [_]Dwarf.Fn{
        .{ .name = "main", .text_off = 0, .size = 40, .file = 0, .rows = &.{ .{ .off = 0, .line = 3 }, .{ .off = 12, .line = 4 }, .{ .off = 28, .line = 3 } } },
        .{ .name = "util.sq", .text_off = 40, .size = 16, .file = 1, .rows = &.{ .{ .off = 0, .line = 200 }, .{ .off = 8, .line = 201 } } },
    };
    const s = try Dwarf.build(gpa, .{ .files = &files, .cu_file = 0, .comp_dir = "/src", .fns = &fns, .text_size = 56 });
    defer s.deinit(gpa);
    const t = try decodeLines(gpa, s.line);
    defer t.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), t.files.len);
    try testing.expectEqualStrings("util.toy", t.fileName(2).?);
    try testing.expect(t.fileName(3) == null);
    const want = [_]Row{
        .{ .addr = 0, .line = 3, .file = 1, .end_sequence = false },
        .{ .addr = 12, .line = 4, .file = 1, .end_sequence = false },
        .{ .addr = 28, .line = 3, .file = 1, .end_sequence = false },
        .{ .addr = 40, .line = 3, .file = 1, .end_sequence = true },
        .{ .addr = 40, .line = 200, .file = 2, .end_sequence = false },
        .{ .addr = 48, .line = 201, .file = 2, .end_sequence = false },
        .{ .addr = 56, .line = 201, .file = 2, .end_sequence = true },
    };
    try testing.expectEqualSlices(Row, &want, t.rows);
}

test "the line reader takes the special and fixed opcodes other producers write" {
    // A version 2 unit (no maximum_operations_per_instruction): min_inst 4, line_base -5,
    // line_range 14, opcode_base 10, one directory, one file.
    const prog = [_]u8{
        2, 0, // version
        0, 0, 0, 0, // header_length, patched below
        4, 1, @bitCast(@as(i8, -5)), 14, 10, // min_inst .. opcode_base
        0, 1, 1, 1, 1, 0, 0, 0, 1, // standard_opcode_lengths
        'd', 0, 0, // include_directories
        'a', '.', 'c', 0, 1, 0, 0, 0, // file_names
        0, 9, DW_LNE_set_address, 0x00, 0x10, 0, 0, 0, 0, 0, 0, // addr = 0x1000
        0x14, // special: adj 10 -> addr += 0, line += 5
        0x32, // special: adj 40 -> addr += 2*4, line += -5 + 12
        DW_LNS_const_add_pc, // addr += (255-10)/14*4 = 68
        DW_LNS_fixed_advance_pc, 2, 0, // addr += 2
        DW_LNS_copy, // a row
        DW_LNS_set_column, 7, // ignored
        DW_LNS_negate_stmt, // ignored
        DW_LNS_copy, // a row
        0, 1, DW_LNE_end_sequence, // the last row
    };
    var unit: [prog.len + 4]u8 = undefined;
    std.mem.writeInt(u32, unit[0..4], prog.len, .little);
    @memcpy(unit[4..], &prog);
    std.mem.writeInt(u32, unit[6..10], 25, .little);
    const t = try decodeLines(testing.allocator, &unit);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("a.c", t.fileName(1).?);
    const want = [_]Row{
        .{ .addr = 0x1000, .line = 6, .file = 1, .end_sequence = false },
        .{ .addr = 0x1008, .line = 13, .file = 1, .end_sequence = false },
        .{ .addr = 0x1008 + 68 + 2, .line = 13, .file = 1, .end_sequence = false },
        .{ .addr = 0x1008 + 68 + 2, .line = 13, .file = 1, .end_sequence = false },
        .{ .addr = 0x1008 + 68 + 2, .line = 13, .file = 1, .end_sequence = true },
    };
    try testing.expectEqualSlices(Row, &want, t.rows);
}

test "a truncated or foreign file is an error, not a crash" {
    try testing.expectError(error.Truncated, parse("ab"));
    try testing.expectError(error.UnknownFormat, parse("#!/bin/sh\n"));
    try testing.expectError(error.Truncated, parse("\x7fELF\x02\x01\x01\x00"));
    var elf32 = [_]u8{0} ** 64;
    @memcpy(elf32[0..6], "\x7fELF\x01\x01");
    try testing.expectError(error.UnsupportedFormat, parse(&elf32));
    var hdr = [_]u8{0} ** 32;
    std.mem.writeInt(u32, hdr[0..4], macho.MH_MAGIC_64, .little);
    std.mem.writeInt(u32, hdr[16..20], 1, .little);
    std.mem.writeInt(u32, hdr[20..24], 72, .little);
    try testing.expectError(error.Truncated, parse(&hdr));
    try testing.expectError(error.BadLineProgram, decodeLines(testing.allocator, &.{ 5, 0, 0, 0, 4, 0 }));
}

/// A DWARF 2 line unit with one file, `line_base` -5 and `opcode_base` 10, around `prog`.
fn lineUnit(comptime prog: []const u8) []const u8 {
    const header = [_]u8{ 1, 1, 0xfb, 14, 10 } ++ [_]u8{ 0, 1, 1, 1, 1, 0, 0, 0, 1 } ++ [_]u8{0} ++ "a".* ++ [_]u8{ 0, 0, 0, 0, 0 };
    const unit = comptime std.mem.toBytes(std.mem.nativeToLittle(u32, 2 + 4 + header.len + prog.len)) ++
        std.mem.toBytes(std.mem.nativeToLittle(u16, 2)) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, header.len)) ++ header ++ prog[0..prog.len].*;
    return &unit;
}

test "a line program that leaves its registers' range is an error, not a crash" {
    const gpa = testing.allocator;
    const ok = try decodeLines(gpa, lineUnit(&.{ DW_LNS_advance_line, 2, DW_LNS_copy }));
    defer gpa.free(ok.files);
    defer gpa.free(ok.rows);
    try testing.expectEqual(@as(u64, 3), ok.rows[0].line);
    // The line register below 1.
    try testing.expectError(error.BadLineProgram, decodeLines(gpa, lineUnit(&.{ DW_LNS_advance_line, 0x7b, DW_LNS_copy })));
    // Two advances of 2^63 overflow the address.
    const half = [_]u8{0x80} ** 9 ++ [_]u8{0x01};
    try testing.expectError(error.BadLineProgram, decodeLines(gpa, lineUnit(&([_]u8{DW_LNS_advance_pc} ++ half ++ [_]u8{DW_LNS_advance_pc} ++ half))));
    // An extended opcode whose length runs past the unit.
    try testing.expectError(error.BadLineProgram, decodeLines(gpa, lineUnit(&([_]u8{0} ++ [_]u8{0xff} ** 9 ++ [_]u8{ 0x01, DW_LNE_end_sequence }))));
}

test "versions print as x.y.z" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1.2.12", formatVersion(0x1020c, &buf));
    try testing.expectEqualStrings("406.0.0", formatVersion(0x1960000, &buf));
}
