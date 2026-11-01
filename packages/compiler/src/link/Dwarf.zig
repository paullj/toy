//! DWARF 4 line tables for a debug build: one compile unit for the whole program, a
//! `DW_TAG_subprogram` per function written in toy source, and a line program mapping
//! each function's statement boundaries to its file and line.
//!
//! Version 4 over 5: it needs no `__debug_line_str` or string-offsets table, and every
//! Apple tool reads it. Variables and types are out of scope (#73).
//!
//! Addresses are written relative to `__text` and patched by `MachO` once it has placed
//! the code (`Sections.relocate`): the section sizes do not depend on the address, so
//! the image is laid out once.

const std = @import("std");
const Io = std.Io;

/// The built section bytes, empty (the default) for a build without debug info.
pub const Sections = struct {
    info: []u8 = &.{},
    abbrev: []u8 = &.{},
    line: []u8 = &.{},
    str: []u8 = &.{},
    /// Where an 8-byte address relative to `__text` sits, in `info` and in `line`.
    info_addrs: []u32 = &.{},
    line_addrs: []u32 = &.{},

    pub fn isEmpty(s: Sections) bool {
        return s.info.len == 0;
    }

    pub fn deinit(s: Sections, gpa: std.mem.Allocator) void {
        gpa.free(s.info);
        gpa.free(s.abbrev);
        gpa.free(s.line);
        gpa.free(s.str);
        gpa.free(s.info_addrs);
        gpa.free(s.line_addrs);
    }

    /// The four sections in the order `MachO` lays them out, with their Mach-O names.
    pub fn parts(s: *const Sections) [4]struct { name: []const u8, bytes: []const u8 } {
        return .{
            .{ .name = "__debug_info", .bytes = s.info },
            .{ .name = "__debug_abbrev", .bytes = s.abbrev },
            .{ .name = "__debug_line", .bytes = s.line },
            .{ .name = "__debug_str", .bytes = s.str },
        };
    }

    /// Add `text_addr` to every address in the built bytes (`info` and `line`, copied
    /// into `info_out`/`line_out`).
    pub fn relocate(s: *const Sections, info_out: []u8, line_out: []u8, text_addr: u64) void {
        @memcpy(info_out, s.info);
        @memcpy(line_out, s.line);
        for (s.info_addrs) |at| addTo(info_out, at, text_addr);
        for (s.line_addrs) |at| addTo(line_out, at, text_addr);
    }

    fn addTo(buf: []u8, at: u32, base: u64) void {
        const p = buf[at..][0..8];
        std.mem.writeInt(u64, p, std.mem.readInt(u64, p, .little) + base, .little);
    }
};

/// One line-table row: the first code byte of a statement, relative to its function,
/// and the source line it starts on.
pub const Row = struct { off: u32, line: u32 };

/// One function to describe. `rows` are in code order and never empty; the first is at
/// offset 0, on the declaration's line.
pub const Fn = struct {
    name: []const u8,
    text_off: u32,
    size: u32,
    /// Index into `files`.
    file: u32,
    rows: []const Row,
};

pub const Input = struct {
    /// Each source file's name, as the line program's file table lists it.
    files: []const []const u8,
    /// Which file names the compile unit: the entry module's.
    cu_file: u32,
    /// The directory relative file names are resolved against.
    comp_dir: []const u8,
    /// In `text_off` order.
    fns: []const Fn,
    text_size: u32,
};

const DW_TAG_compile_unit = 0x11;
const DW_TAG_subprogram = 0x2e;
const DW_AT_name = 0x03;
const DW_AT_stmt_list = 0x10;
const DW_AT_low_pc = 0x11;
const DW_AT_high_pc = 0x12;
const DW_AT_language = 0x13;
const DW_AT_comp_dir = 0x1b;
const DW_AT_producer = 0x25;
const DW_AT_decl_file = 0x3a;
const DW_AT_decl_line = 0x3b;
const DW_FORM_addr = 0x01;
const DW_FORM_data2 = 0x05;
const DW_FORM_data4 = 0x06;
const DW_FORM_strp = 0x0e;
const DW_FORM_udata = 0x0f;
const DW_FORM_sec_offset = 0x17;
// No language code names toy; C99 is what lldb and dwarfdump handle best when a
// producer has none of its own.
const DW_LANG_C99 = 0x000c;

const DW_LNS_copy = 0x01;
const DW_LNS_advance_pc = 0x02;
const DW_LNS_advance_line = 0x03;
const DW_LNS_set_file = 0x04;
const DW_LNE_end_sequence = 0x01;
const DW_LNE_set_address = 0x02;
const opcode_base = 13;
const std_opcode_lengths = [opcode_base - 1]u8{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 };

const abbrev_cu = 1;
const abbrev_subprogram = 2;

const producer = "toy";

/// Build the sections for `in`. Caller owns the result (`Sections.deinit`).
pub fn build(gpa: std.mem.Allocator, in: Input) error{OutOfMemory}!Sections {
    // Every writer here is an allocating one, which fails only when it cannot grow.
    return buildAll(gpa, in) catch |e| switch (e) {
        error.WriteFailed => error.OutOfMemory,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn buildAll(gpa: std.mem.Allocator, in: Input) !Sections {
    var str: Io.Writer.Allocating = .init(gpa);
    defer str.deinit();
    var info: Io.Writer.Allocating = .init(gpa);
    defer info.deinit();
    var line: Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var info_addrs: std.ArrayList(u32) = .empty;
    defer info_addrs.deinit(gpa);
    var line_addrs: std.ArrayList(u32) = .empty;
    defer line_addrs.deinit(gpa);

    try buildLine(&line.writer, gpa, &line_addrs, in);

    const iw = &info.writer;
    try iw.writeInt(u32, 0, .little); // unit_length, patched below
    try iw.writeInt(u16, 4, .little);
    try iw.writeInt(u32, 0, .little); // debug_abbrev_offset
    try iw.writeByte(8);
    try iw.writeUleb128(abbrev_cu);
    try iw.writeInt(u32, try strp(&str, producer), .little);
    try iw.writeInt(u16, DW_LANG_C99, .little);
    try iw.writeInt(u32, try strp(&str, in.files[in.cu_file]), .little);
    try iw.writeInt(u32, try strp(&str, in.comp_dir), .little);
    try iw.writeInt(u32, 0, .little); // stmt_list: the one line program
    try info_addrs.append(gpa, @intCast(iw.end));
    try iw.writeInt(u64, 0, .little);
    try iw.writeInt(u32, in.text_size, .little);
    for (in.fns) |f| {
        try iw.writeUleb128(abbrev_subprogram);
        try iw.writeInt(u32, try strp(&str, f.name), .little);
        try iw.writeUleb128(f.file + 1);
        try iw.writeUleb128(f.rows[0].line);
        try info_addrs.append(gpa, @intCast(iw.end));
        try iw.writeInt(u64, f.text_off, .little);
        try iw.writeInt(u32, f.size, .little);
    }
    try iw.writeByte(0);
    std.mem.writeInt(u32, info.written()[0..4], @intCast(iw.end - 4), .little);

    const abbrev = try gpa.dupe(u8, &abbrev_table);
    errdefer gpa.free(abbrev);
    const info_out = try info.toOwnedSlice();
    errdefer gpa.free(info_out);
    const line_out = try line.toOwnedSlice();
    errdefer gpa.free(line_out);
    const str_out = try str.toOwnedSlice();
    errdefer gpa.free(str_out);
    const ia = try info_addrs.toOwnedSlice(gpa);
    errdefer gpa.free(ia);
    return .{
        .info = info_out,
        .abbrev = abbrev,
        .line = line_out,
        .str = str_out,
        .info_addrs = ia,
        .line_addrs = try line_addrs.toOwnedSlice(gpa),
    };
}

// Each abbreviation: code, tag, has-children, then (attribute, form) pairs ending in 0, 0.
const abbrev_table = [_]u8{ abbrev_cu, DW_TAG_compile_unit, 1 } ++
    [_]u8{ DW_AT_producer, DW_FORM_strp } ++
    [_]u8{ DW_AT_language, DW_FORM_data2 } ++
    [_]u8{ DW_AT_name, DW_FORM_strp } ++
    [_]u8{ DW_AT_comp_dir, DW_FORM_strp } ++
    [_]u8{ DW_AT_stmt_list, DW_FORM_sec_offset } ++
    [_]u8{ DW_AT_low_pc, DW_FORM_addr } ++
    [_]u8{ DW_AT_high_pc, DW_FORM_data4 } ++
    [_]u8{ 0, 0 } ++
    [_]u8{ abbrev_subprogram, DW_TAG_subprogram, 0 } ++
    [_]u8{ DW_AT_name, DW_FORM_strp } ++
    [_]u8{ DW_AT_decl_file, DW_FORM_udata } ++
    [_]u8{ DW_AT_decl_line, DW_FORM_udata } ++
    [_]u8{ DW_AT_low_pc, DW_FORM_addr } ++
    [_]u8{ DW_AT_high_pc, DW_FORM_data4 } ++
    [_]u8{ 0, 0 } ++
    [_]u8{0};

fn strp(str: *Io.Writer.Allocating, s: []const u8) !u32 {
    const at: u32 = @intCast(str.writer.end);
    try str.writer.writeAll(s);
    try str.writer.writeByte(0);
    return at;
}

/// The line program: one sequence per function, so each starts from its own address
/// and the rows of two functions never interleave.
fn buildLine(w: *Io.Writer, gpa: std.mem.Allocator, addrs: *std.ArrayList(u32), in: Input) !void {
    try w.writeInt(u32, 0, .little); // unit_length, patched below
    try w.writeInt(u16, 4, .little);
    try w.writeInt(u32, 0, .little); // header_length, patched below
    const header_start = w.end;
    try w.writeByte(1); // minimum_instruction_length
    try w.writeByte(1); // maximum_operations_per_instruction
    try w.writeByte(1); // default_is_stmt
    try w.writeByte(@bitCast(@as(i8, -5))); // line_base
    try w.writeByte(14); // line_range
    try w.writeByte(opcode_base);
    try w.writeAll(&std_opcode_lengths);
    try w.writeByte(0); // no include_directories
    for (in.files) |f| {
        try w.writeAll(f);
        try w.writeByte(0);
        try w.writeUleb128(0); // directory: the compile unit's
        try w.writeUleb128(0); // mtime
        try w.writeUleb128(0); // length
    }
    try w.writeByte(0);
    std.mem.writeInt(u32, w.buffer[6..10], @intCast(w.end - header_start), .little);

    for (in.fns) |f| {
        try w.writeByte(0);
        try w.writeUleb128(9);
        try w.writeByte(DW_LNE_set_address);
        try addrs.append(gpa, @intCast(w.end));
        try w.writeInt(u64, f.text_off, .little);
        if (f.file != 0) {
            try w.writeByte(DW_LNS_set_file);
            try w.writeUleb128(f.file + 1);
        }
        var off: u32 = 0;
        var ln: i64 = 1;
        for (f.rows) |r| {
            if (r.off > off) {
                try w.writeByte(DW_LNS_advance_pc);
                try w.writeUleb128(r.off - off);
                off = r.off;
            }
            if (r.line != ln) {
                try w.writeByte(DW_LNS_advance_line);
                try w.writeSleb128(@as(i64, r.line) - ln);
                ln = r.line;
            }
            try w.writeByte(DW_LNS_copy);
        }
        if (f.size > off) {
            try w.writeByte(DW_LNS_advance_pc);
            try w.writeUleb128(f.size - off);
        }
        try w.writeByte(0);
        try w.writeUleb128(1);
        try w.writeByte(DW_LNE_end_sequence);
    }
    std.mem.writeInt(u32, w.buffer[0..4], @intCast(w.end - 4), .little);
}

const testing = std.testing;

const DecodedRow = struct { addr: u64, file: u64, line: i64, end: bool };

/// A line-program reader for the opcodes `buildLine` writes, so the tests check what a
/// consumer sees rather than the bytes.
fn decodeLine(gpa: std.mem.Allocator, bytes: []const u8, files_out: *std.ArrayList([]const u8)) ![]DecodedRow {
    var r: Io.Reader = .fixed(bytes);
    const unit_len = try r.takeInt(u32, .little);
    try testing.expectEqual(bytes.len - 4, unit_len);
    try testing.expectEqual(@as(u16, 4), try r.takeInt(u16, .little));
    const hdr_len = try r.takeInt(u32, .little);
    const prog_start = r.seek + hdr_len;
    try testing.expectEqual(@as(u8, 1), try r.takeByte());
    try testing.expectEqual(@as(u8, 1), try r.takeByte());
    try testing.expectEqual(@as(u8, 1), try r.takeByte());
    _ = try r.takeByte();
    _ = try r.takeByte();
    try testing.expectEqual(@as(u8, opcode_base), try r.takeByte());
    try r.discardAll(opcode_base - 1);
    try testing.expectEqual(@as(u8, 0), try r.takeByte());
    while (true) {
        const name = try r.takeSentinel(0);
        if (name.len == 0) break;
        try files_out.append(gpa, name);
        _ = try r.takeLeb128(u64);
        _ = try r.takeLeb128(u64);
        _ = try r.takeLeb128(u64);
    }
    try testing.expectEqual(prog_start, r.seek);

    var rows: std.ArrayList(DecodedRow) = .empty;
    errdefer rows.deinit(gpa);
    var addr: u64 = 0;
    var file: u64 = 1;
    var ln: i64 = 1;
    while (r.seek < bytes.len) {
        switch (try r.takeByte()) {
            0 => {
                const len = try r.takeLeb128(u64);
                const sub = try r.takeByte();
                switch (sub) {
                    DW_LNE_set_address => addr = try r.takeInt(u64, .little),
                    DW_LNE_end_sequence => {
                        try rows.append(gpa, .{ .addr = addr, .file = file, .line = ln, .end = true });
                        addr = 0;
                        file = 1;
                        ln = 1;
                    },
                    else => try r.discardAll(len - 1),
                }
            },
            DW_LNS_copy => try rows.append(gpa, .{ .addr = addr, .file = file, .line = ln, .end = false }),
            DW_LNS_advance_pc => addr += try r.takeLeb128(u64),
            DW_LNS_advance_line => ln += try r.takeLeb128(i64),
            DW_LNS_set_file => file = try r.takeLeb128(u64),
            else => return error.UnexpectedOpcode,
        }
    }
    return rows.toOwnedSlice(gpa);
}

test "the line program maps each statement's code to its file and line, one sequence per fn" {
    const gpa = testing.allocator;
    const files = [_][]const u8{ "main.toy", "util.toy" };
    const fns = [_]Fn{
        .{ .name = "main", .text_off = 0, .size = 40, .file = 0, .rows = &.{ .{ .off = 0, .line = 3 }, .{ .off = 12, .line = 4 }, .{ .off = 28, .line = 3 } } },
        .{ .name = "util.sq", .text_off = 40, .size = 16, .file = 1, .rows = &.{ .{ .off = 0, .line = 200 }, .{ .off = 8, .line = 201 } } },
    };
    const s = try build(gpa, .{ .files = &files, .cu_file = 0, .comp_dir = "/src", .fns = &fns, .text_size = 56 });
    defer s.deinit(gpa);

    const base: u64 = 0x100000400;
    const info = try gpa.alloc(u8, s.info.len);
    defer gpa.free(info);
    const line = try gpa.alloc(u8, s.line.len);
    defer gpa.free(line);
    s.relocate(info, line, base);

    var got_files: std.ArrayList([]const u8) = .empty;
    defer got_files.deinit(gpa);
    const rows = try decodeLine(gpa, line, &got_files);
    defer gpa.free(rows);
    try testing.expectEqual(@as(usize, 2), got_files.items.len);
    try testing.expectEqualStrings("main.toy", got_files.items[0]);
    try testing.expectEqualStrings("util.toy", got_files.items[1]);
    const want = [_]DecodedRow{
        .{ .addr = base, .file = 1, .line = 3, .end = false },
        .{ .addr = base + 12, .file = 1, .line = 4, .end = false },
        .{ .addr = base + 28, .file = 1, .line = 3, .end = false },
        .{ .addr = base + 40, .file = 1, .line = 3, .end = true },
        .{ .addr = base + 40, .file = 2, .line = 200, .end = false },
        .{ .addr = base + 48, .file = 2, .line = 201, .end = false },
        .{ .addr = base + 56, .file = 2, .line = 201, .end = true },
    };
    try testing.expectEqualSlices(DecodedRow, &want, rows);
}

test "the compile unit spans __text and names each fn with its range and declaration" {
    const gpa = testing.allocator;
    const files = [_][]const u8{ "a/main.toy", "std/io.toy" };
    const fns = [_]Fn{
        .{ .name = "io.println", .text_off = 0, .size = 8, .file = 1, .rows = &.{.{ .off = 0, .line = 7 }} },
        .{ .name = "main", .text_off = 8, .size = 20, .file = 0, .rows = &.{.{ .off = 0, .line = 2 }} },
    };
    const s = try build(gpa, .{ .files = &files, .cu_file = 0, .comp_dir = "/w", .fns = &fns, .text_size = 28 });
    defer s.deinit(gpa);
    const info = try gpa.alloc(u8, s.info.len);
    defer gpa.free(info);
    const line = try gpa.alloc(u8, s.line.len);
    defer gpa.free(line);
    s.relocate(info, line, 0x1000);

    var r: Io.Reader = .fixed(info);
    try testing.expectEqual(@as(u32, @intCast(info.len - 4)), try r.takeInt(u32, .little));
    try testing.expectEqual(@as(u16, 4), try r.takeInt(u16, .little));
    try testing.expectEqual(@as(u32, 0), try r.takeInt(u32, .little));
    try testing.expectEqual(@as(u8, 8), try r.takeByte());
    try testing.expectEqual(@as(u64, abbrev_cu), try r.takeLeb128(u64));
    const str = s.str;
    const strAt = struct {
        fn f(tab: []const u8, at: u32) []const u8 {
            return std.mem.sliceTo(tab[at..], 0);
        }
    }.f;
    try testing.expectEqualStrings("toy", strAt(str, try r.takeInt(u32, .little)));
    try testing.expectEqual(@as(u16, DW_LANG_C99), try r.takeInt(u16, .little));
    try testing.expectEqualStrings("a/main.toy", strAt(str, try r.takeInt(u32, .little)));
    try testing.expectEqualStrings("/w", strAt(str, try r.takeInt(u32, .little)));
    try testing.expectEqual(@as(u32, 0), try r.takeInt(u32, .little));
    try testing.expectEqual(@as(u64, 0x1000), try r.takeInt(u64, .little));
    try testing.expectEqual(@as(u32, 28), try r.takeInt(u32, .little));
    const want = [_]struct { name: []const u8, file: u64, line: u64, lo: u64, size: u32 }{
        .{ .name = "io.println", .file = 2, .line = 7, .lo = 0x1000, .size = 8 },
        .{ .name = "main", .file = 1, .line = 2, .lo = 0x1008, .size = 20 },
    };
    for (want) |w| {
        try testing.expectEqual(@as(u64, abbrev_subprogram), try r.takeLeb128(u64));
        try testing.expectEqualStrings(w.name, strAt(str, try r.takeInt(u32, .little)));
        try testing.expectEqual(w.file, try r.takeLeb128(u64));
        try testing.expectEqual(w.line, try r.takeLeb128(u64));
        try testing.expectEqual(w.lo, try r.takeInt(u64, .little));
        try testing.expectEqual(w.size, try r.takeInt(u32, .little));
    }
    try testing.expectEqual(@as(u8, 0), try r.takeByte());
    try testing.expectEqual(info.len, r.seek);
}
