//! The linked program, in no object format: what the link stage hands a format writer.
//!
//! Link lays out the code and patches every reference inside it; what is left depends on
//! where the format puts each section, so it travels here as data. A writer (one per
//! object format, picked by `emit.writerOf` from `Target.objectFormat`) places the
//! sections, calls `patch` with the addresses it chose, and writes the format's headers. Everything a format names (section and segment names,
//! the `_` symbol prefix, page size, base address, machine type, load commands or
//! program headers, how the loader binds an import) is the writer's, never Link's.
//!
//! Each field and its format:
//!
//!   field          Mach-O (`MachO.write`)                  ELF (`Elf.write`, #433)
//!   ------------   --------------------------------------  -----------------------------
//!   arch           cputype/cpusubtype                      e_machine
//!   text           __TEXT,__text                           .text in a PT_LOAD r-x
//!   entry_off      LC_MAIN entryoff (dyld calls `main`)    the `_start` stub's call target
//!   cstrings       __TEXT,__cstring                        .rodata (r--, or in the r-x load)
//!   bss_size       __DATA,__bss (zero-fill)                .bss in a PT_LOAD rw- (memsz > filesz)
//!   imports        __DATA_CONST,__got + chained fixups     .got + R_*_GLOB_DAT + .dynsym
//!   libraries      LC_LOAD_DYLIB (ordinal = index + 2)     DT_NEEDED (flat namespace)
//!   search_paths   LC_RPATH                                DT_RUNPATH
//!   debug.symbols  LC_SYMTAB nlists, names with `_`        .symtab/.strtab, names as given
//!   debug.dwarf    __DWARF,__debug_<kind>                  .debug_<kind> (non-alloc)
//!
//! The GOT is not a field: it is one pointer slot per import, in `imports` order, so a
//! reloc names an import by name and `slotOf` gives its slot. The system libraries every
//! program loads (libSystem; glibc's libc.so.6 and libm.so.6, #60 T13) are the writer's
//! too: an import whose `library` is null binds there. ELF's PT_INTERP, its dynamic
//! section and segment alignment follow from the target, as dyld's path and the 16 KiB
//! page do for Mach-O. No section holds initialized writable data yet; one joins as a
//! field when something emits it.
//!
//! wasm32 (#79) does not link machine code this way: its backend emits a module whose
//! functions, data and imports are its own sections. `Isa.Backend` will carry its own
//! image path there, and only `imports` (a library is the import module name) and
//! `debug` carry over.

const std = @import("std");
const Io = std.Io;
const reloc = @import("reloc.zig");
const Engine = @import("../query/Engine.zig");
const Dwarf = @import("Dwarf.zig");
const Target = @import("../Target.zig");

const Image = @This();

arch: Target.Arch,
/// The code, every reference inside it patched; `relocs` are patched in the writer's copy.
text: []const u8,
/// The entry function's offset in `text`.
entry_off: u32,
/// Read-only bytes: interned strings, then the side tables Link reserved after them.
cstrings: []const u8 = &.{},
/// Bytes of writable zero-fill data; 0 for none.
bss_size: u32 = 0,
/// Sorted by name, one per symbol: the index is the symbol's GOT slot.
imports: []const Import = &.{},
/// The libraries loaded beyond the system libraries, in load order.
libraries: []const Library = &.{},
/// Folders the loader searches for a library recorded by a relative name.
search_paths: []const []const u8 = &.{},
/// References out of `text`, to `cstrings`, the GOT, the bss or `text` itself, at
/// absolute `text` offsets.
relocs: []const reloc.Reloc = &.{},
/// The ISA's patcher, which writes each of `relocs` once its target is placed.
patcher: *const reloc.Patcher,
debug: Debug = .{},

pub const Import = struct {
    /// The C symbol, with no format's prefix.
    name: []const u8,
    /// Index into `libraries`; null for the system libraries.
    library: ?LibraryIndex = null,
};

/// Wide enough for any format: a Mach-O writer's 8-bit ordinal is its own limit
/// (`MachO.max_libraries`), which its resolver enforces.
pub const LibraryIndex = u16;

pub const Library = struct {
    /// The name the loader looks for: a Mach-O install name, an ELF SONAME.
    name: []const u8,
    /// The versions a Mach-O loader checks against the library's own; 0 elsewhere.
    current_version: u32 = 0,
    compat_version: u32 = 0,
};

/// The GOT slot of import `name`. Every reloc's import is in `imports`.
pub fn slotOf(imports: []const Import, name: []const u8) u32 {
    return @intCast(indexByName(Import, imports, name).?);
}

/// The index of the entry named `name` in `items`, sorted by `.name`; null for none.
pub fn indexByName(comptime T: type, items: []const T, name: []const u8) ?usize {
    return std.sort.binarySearch(T, items, name, struct {
        fn order(key: []const u8, item: T) std.math.Order {
            return std.mem.order(u8, key, item.name);
        }
    }.order);
}

/// Patch every reloc into `text`, the writer's copy of `img.text`, once `at` places the
/// sections they name.
pub fn patch(img: *const Image, io: Io, text: []u8, at: Placement) void {
    // Each reloc owns a disjoint site, so the fan-out is race-free and its output does
    // not depend on dispatch order. Reloc counts are small, so the high threshold keeps
    // it serial except on the largest images.
    Engine.chunkedFanOut(io, img.relocs.len, 0, Engine.Chunk.small_count.threshold, Engine.Chunk.small_count.chunks_per_cpu, patchJob, PatchCtx{ .img = img, .text = text, .at = at });
}

const PatchCtx = struct {
    img: *const Image,
    text: []u8,
    at: Placement,
    pub fn args(c: PatchCtx, i: usize) std.meta.ArgsTuple(@TypeOf(patchJob)) {
        return .{ c.img, c.text, c.img.relocs[i], c.at };
    }
};

fn patchJob(img: *const Image, text: []u8, rl: reloc.Reloc, at: Placement) void {
    const target: u64 = switch (rl.target) {
        .cstr => |off| at.cstrings + off,
        .import => |s| at.got + @as(u64, slotOf(img.imports, s.name)) * 8,
        .data => |off| at.bss + off,
        .text_off => |off| at.text + off,
        // Link patched these itself; only references out of `text`'s own layout remain.
        .func, .none => unreachable,
    };
    img.patcher.patchCross(text, rl.kind, rl.site, at.text + rl.site, target, rl.addend);
}

/// Where a writer placed each section a reloc can name, as load addresses.
pub const Placement = struct {
    text: u64,
    cstrings: u64 = 0,
    got: u64 = 0,
    bss: u64 = 0,
};

/// A debug build's debug info; empty (the default) for a build without it.
pub const Debug = struct {
    symbols: Symbols = .{},
    dwarf: Dwarf.Sections = .{},

    pub fn deinit(self: Debug, gpa: std.mem.Allocator) void {
        self.symbols.deinit(gpa);
        self.dwarf.deinit(gpa);
    }
};

/// One function's name and its `text` offset, in the order the table lists them.
pub const Symbol = struct { name: []const u8, text_off: u32 };

pub const Symbols = struct {
    list: []const Symbol = &.{},
    /// Every name in `list`, back to back: the one allocation `list` slices.
    names: []const u8 = &.{},

    /// A table of `entries`, its names copied. Caller owns the result (`deinit`).
    pub fn build(gpa: std.mem.Allocator, entries: []const Symbol) !Symbols {
        if (entries.len == 0) return .{};
        var len: usize = 0;
        for (entries) |e| len += e.name.len;
        const names = try gpa.alloc(u8, len);
        errdefer gpa.free(names);
        const list = try gpa.alloc(Symbol, entries.len);
        var pos: usize = 0;
        for (entries, list) |e, *s| {
            @memcpy(names[pos..][0..e.name.len], e.name);
            s.* = .{ .name = names[pos..][0..e.name.len], .text_off = e.text_off };
            pos += e.name.len;
        }
        return .{ .list = list, .names = names };
    }

    pub fn deinit(self: Symbols, gpa: std.mem.Allocator) void {
        gpa.free(self.list);
        gpa.free(self.names);
    }
};

const testing = std.testing;

test "slotOf is the import's index in name order" {
    const imports = [_]Import{ .{ .name = "labs" }, .{ .name = "q_one", .library = 0 }, .{ .name = "write" } };
    try testing.expectEqual(@as(u32, 0), slotOf(&imports, "labs"));
    try testing.expectEqual(@as(u32, 1), slotOf(&imports, "q_one"));
    try testing.expectEqual(@as(u32, 2), slotOf(&imports, "write"));
}

test "Symbols.build copies the names into one allocation, with no format's prefix" {
    const gpa = testing.allocator;
    var name = "m.f".*;
    const s = try Symbols.build(gpa, &.{ .{ .name = "main", .text_off = 0 }, .{ .name = &name, .text_off = 8 } });
    defer s.deinit(gpa);
    name[0] = 'x';
    try testing.expectEqualStrings("mainm.f", s.names);
    try testing.expectEqualStrings("main", s.list[0].name);
    try testing.expectEqualStrings("m.f", s.list[1].name);
    try testing.expectEqual(@as(u32, 8), s.list[1].text_off);
    const empty = try Symbols.build(gpa, &.{});
    empty.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), empty.list.len);
}
