//! Where the GC references of a cell of a given type lie: the one walk over the layout
//! tables that both the frame root maps (`FrameLayout.collectRoots`) and the heap object
//! layouts the collector traces (`program`) are read from.
//!
//! A heap object's layout is a PROGRAM of little-endian u64 words the collector runs over
//! the object's address (`core/rt/gc.toy`, `trace_cell`). Each word's low 2 bits are its op
//! and the rest its argument:
//!   * 0 END
//!   * 1 PTR off: the word at `off` is a reference.
//!   * 2 SWITCH off: the enum tag at `off` picks a variant. The next word is the variant
//!     count `n`, then `n` words each give the word index its variant's ops start at.
//!   * 3 JUMP to: continue at word index `to`; every variant's ops end with one.
//! An enum's variants overlap, so only the live variant's references are visited: a word
//! that is a reference in one variant and an int in another is never taken for a pointer.
//! A program names offsets, never addresses, so a moving collector could use it as is.

const std = @import("std");
const types = @import("../../types.zig");
const Abi = @import("Abi.zig");
const Type = types.Type;
const Layout = types.Layout;
const EnumLayout = types.EnumLayout;

pub const Op = enum(u2) { end = 0, ptr = 1, @"switch" = 2, jump = 3 };

/// The layout word of a Map or Set header, which the collector walks by the header's own
/// fields. No program lies at address 1, so it can never name one.
pub const map_header: u64 = 1;

/// The layout word of a Vec or Map backing whose elements hold references, which only its
/// header traces. Like `map_header`, it is below any program's address.
pub const container: u64 = 2;

/// The low 3 bits of the first word of a Vec header's program (`arrayProgram`). As an op
/// it is END, so no cell program starts with it: an empty one is no program at all.
pub const array_mark: u64 = 4;

/// The Vec header `{len, cap, elems}` core/mem lays out and the collector reads by these
/// offsets. Elements of up to `inline_max` bytes sit in the header's own cell, right past
/// it, so a small literal stays one cell of at most 64 bytes.
pub const VecHeader = struct {
    pub const len = 0;
    pub const cap = 8;
    pub const elems = 16;
    pub const size = 24;
    pub const inline_max = 64 - size;
};

/// Walk the references of a `ty` cell based at `base`, calling `v.ptr(off)` for each and,
/// around an enum's variants, `v.enumBegin(tag_off, n)`, `v.variant(k)` before variant k's
/// references and `v.enumEnd()`. A managed box (`Ref`/`gc_array`), a raw pointer, a
/// `cstr` and a `str`'s pointer half are references; a box is never walked into, since
/// what it points at has a layout of its own. A box is a struct kind, so it is tested
/// first.
pub fn walk(ty: Type, base: u32, layouts: []const Layout, enum_layouts: []const EnumLayout, v: anytype) !void {
    if (types.isRefStruct(ty, layouts)) return v.ptr(base);
    switch (ty.kind) {
        .rawptr, .cstr, .str => try v.ptr(base),
        .@"struct" => {
            if (ty.struct_id >= layouts.len) return;
            const l = layouts[ty.struct_id];
            for (l.field_types, l.offsets) |ft, fo| try walk(ft, base + fo, layouts, enum_layouts, v);
        },
        .@"enum" => {
            if (ty.enum_id >= enum_layouts.len) return;
            const e = enum_layouts[ty.enum_id];
            // The collector reads a SWITCH's tag as a whole word.
            std.debug.assert(e.tag_size == 8);
            try v.enumBegin(base, @intCast(e.variants.len));
            for (e.variants, 0..) |vl, k| {
                try v.variant(@intCast(k));
                for (vl.field_types, vl.offsets) |ft, fo| try walk(ft, base + e.payload_off + fo, layouts, enum_layouts, v);
            }
            try v.enumEnd();
        },
        else => {},
    }
}

/// Builds one program from any number of cells (a closure env is several).
pub const Builder = struct {
    words: std.ArrayList(u64) = .empty,
    gpa: std.mem.Allocator,
    /// Per open enum: where its SWITCH starts, and the words to patch to its end.
    open: std.ArrayList(Open) = .empty,
    patches: std.ArrayList(u32) = .empty,

    const Open = struct { start: u32, patches_from: u32, variant: ?u32 = null, variant_start: u32 = 0, empty: u32 = 0 };

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.words.deinit(b.gpa);
        b.open.deinit(b.gpa);
        b.patches.deinit(b.gpa);
    }

    pub fn cell(b: *Builder, ty: Type, base: u32, layouts: []const Layout, enum_layouts: []const EnumLayout) error{OutOfMemory}!void {
        try walk(ty, base, layouts, enum_layouts, b);
    }

    pub fn ptr(b: *Builder, off: u32) error{OutOfMemory}!void {
        try b.words.append(b.gpa, word(.ptr, off));
    }

    pub fn enumBegin(b: *Builder, tag_off: u32, n: u32) error{OutOfMemory}!void {
        const start: u32 = @intCast(b.words.items.len);
        try b.words.append(b.gpa, word(.@"switch", tag_off));
        try b.words.append(b.gpa, n);
        try b.words.appendNTimes(b.gpa, 0, n);
        try b.open.append(b.gpa, .{ .start = start, .patches_from = @intCast(b.patches.items.len) });
    }

    pub fn variant(b: *Builder, k: u32) error{OutOfMemory}!void {
        try b.closeVariant();
        const o = &b.open.items[b.open.items.len - 1];
        o.variant = k;
        o.variant_start = @intCast(b.words.items.len);
    }

    /// A variant with references ends in a JUMP to the enum's end; one without any
    /// targets the end directly.
    fn closeVariant(b: *Builder) error{OutOfMemory}!void {
        const o = &b.open.items[b.open.items.len - 1];
        const k = o.variant orelse return;
        const target = o.start + 2 + k;
        if (b.words.items.len == o.variant_start) {
            o.empty += 1;
            try b.patches.append(b.gpa, target);
        } else {
            b.words.items[target] = o.variant_start;
            try b.patches.append(b.gpa, @intCast(b.words.items.len));
            try b.words.append(b.gpa, word(.jump, 0));
        }
        o.variant = null;
    }

    pub fn enumEnd(b: *Builder) error{OutOfMemory}!void {
        try b.closeVariant();
        const o = b.open.pop().?;
        const n = b.words.items[o.start + 1];
        const pending = b.patches.items[o.patches_from..];
        // No variant holds a reference: the enum adds nothing.
        if (o.empty == n) {
            b.words.shrinkRetainingCapacity(o.start);
        } else {
            const end: u32 = @intCast(b.words.items.len);
            for (pending) |at| {
                b.words.items[at] = if (at < o.start + 2 + n) end else word(.jump, end);
            }
        }
        b.patches.shrinkRetainingCapacity(o.patches_from);
    }

    /// The program's bytes, owned by the caller: empty when no cell holds a reference,
    /// so such an object is never traced.
    pub fn finish(b: *Builder) error{OutOfMemory}![]u8 {
        std.debug.assert(b.open.items.len == 0);
        if (b.words.items.len == 0) return &.{};
        try b.words.append(b.gpa, word(.end, 0));
        const out = try b.gpa.alloc(u8, b.words.items.len * 8);
        for (b.words.items, 0..) |w, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], w, .little);
        return out;
    }

    fn word(op: Op, arg: u32) u64 {
        return (@as(u64, arg) << 2) | @intFromEnum(op);
    }
};

/// The program of a heap object that is one `ty` cell. Caller owns it; empty for a type
/// with no reference.
pub fn program(gpa: std.mem.Allocator, ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) error{OutOfMemory}![]u8 {
    var b = Builder.init(gpa);
    defer b.deinit();
    try b.cell(ty, 0, layouts, enum_layouts);
    return b.finish();
}

/// The program of a `VecHeader` whose elements are `elem` cells: the
/// element size above `array_mark`, then the element's own program, whose word indexes
/// count from the word after the mark. The collector reads the size and the element layout
/// from here, so a header carries neither and fits a 32-byte cell.
pub fn arrayProgram(gpa: std.mem.Allocator, elem: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) error{OutOfMemory}![]u8 {
    const inner = try program(gpa, elem, layouts, enum_layouts);
    defer gpa.free(inner);
    const words = if (inner.len == 0) 2 else 1 + inner.len / 8;
    const out = try gpa.alloc(u8, words * 8);
    @memset(out, 0);
    const size: u64 = Abi.typeSize(elem, layouts, enum_layouts);
    std.mem.writeInt(u64, out[0..8], (size << 3) | array_mark, .little);
    @memcpy(out[8 .. 8 + inner.len], inner);
    return out;
}

/// Every offset a `ty` cell based at `base` may hold a reference at, appended to `out`:
/// an enum gives each variant's, since a frame root map has no tag to read.
pub fn appendRefOffsets(gpa: std.mem.Allocator, ty: Type, base: u32, layouts: []const Layout, enum_layouts: []const EnumLayout, out: *std.ArrayList(u32)) error{OutOfMemory}!void {
    const V = struct {
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u32),
        pub fn ptr(v: @This(), off: u32) error{OutOfMemory}!void {
            try v.out.append(v.gpa, off);
        }
        pub fn enumBegin(_: @This(), _: u32, _: u32) error{OutOfMemory}!void {}
        pub fn variant(_: @This(), _: u32) error{OutOfMemory}!void {}
        pub fn enumEnd(_: @This()) error{OutOfMemory}!void {}
    };
    try walk(ty, base, layouts, enum_layouts, V{ .gpa = gpa, .out = out });
}

const testing = std.testing;

fn bundledSource(path: []const u8) ![]const u8 {
    for (@import("bundled_std").modules) |m| {
        if (std.mem.eql(u8, m.path, path)) return m.source;
    }
    return error.TestUnexpectedResult;
}

test "the .toy runtime mirrors the ops and the container layouts" {
    // The collector and core/mem are .toy and cannot import these, so each mirror is pinned
    // by its text: trace_cell's op tests, both copies of the map header and container
    // layouts and the collector's array mark.
    var buf: [64]u8 = undefined;
    const gc = try bundledSource("core/rt/gc");
    for ([_]Op{ .ptr, .@"switch", .jump }) |op| {
        const want = try std.fmt.bufPrint(&buf, "op == {d}", .{@intFromEnum(op)});
        try testing.expect(std.mem.indexOf(u8, gc, want) != null);
    }
    try testing.expectEqual(map_header, try returnedInt(gc, "map_header"));
    try testing.expectEqual(array_mark, try returnedInt(gc, "array_mark"));
    try testing.expectEqual(container, try returnedInt(gc, "container"));
    const mem = try bundledSource("core/mem");
    try testing.expectEqual(map_header, try returnedInt(mem, "map_header"));
    try testing.expectEqual(container, try returnedInt(mem, "container"));
}

/// The integer `fn name() -> int` returns, on one line or several, so a reformat of the
/// .toy source does not read as drift.
fn returnedInt(src: []const u8, name: []const u8) !u64 {
    var buf: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&buf, "fn {s}() -> int {{", .{name});
    const at = (std.mem.indexOf(u8, src, head) orelse return error.TestUnexpectedResult) + head.len;
    const body = std.mem.trimStart(u8, src[at..], " \n");
    if (!std.mem.startsWith(u8, body, "return ")) return error.TestUnexpectedResult;
    const digits = body["return ".len..];
    const n = std.mem.indexOfNone(u8, digits, "0123456789") orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(u64, digits[0..n], 10);
}

test "core/mem and the collector agree on the Vec header" {
    // Both are .toy and name the header fields by literal offsets, so each is pinned here.
    var buf: [64]u8 = undefined;
    const gc = try bundledSource("core/rt/gc");
    comptime std.debug.assert(VecHeader.len == 0);
    try testing.expect(std.mem.indexOf(u8, gc, "len := word(header)\n") != null);
    try testing.expect(std.mem.indexOf(u8, gc, try std.fmt.bufPrint(&buf, "word(header + {d})", .{VecHeader.elems})) != null);
    const mem = try bundledSource("core/mem");
    const pins = [_][]const u8{
        try std.fmt.allocPrint(testing.allocator, "load(offset(a, {d}))", .{VecHeader.len}),
        try std.fmt.allocPrint(testing.allocator, "load(offset(a, {d}))", .{VecHeader.cap}),
        try std.fmt.allocPrint(testing.allocator, "load(offset(a, {d}))", .{VecHeader.elems}),
        try std.fmt.allocPrint(testing.allocator, "gc_alloc({d}, array_layout_of[T]())", .{VecHeader.size}),
        try std.fmt.allocPrint(testing.allocator, "store(offset(hdr, {d}), offset(hdr, {d}))", .{ VecHeader.elems, VecHeader.size }),
        try std.fmt.allocPrint(testing.allocator, "if bytes <= {d} {{", .{VecHeader.inline_max}),
    };
    defer for (pins) |p| testing.allocator.free(p);
    for (pins) |p| try testing.expect(std.mem.indexOf(u8, mem, p) != null);
}

test "an array program leads with the element size, then the element's program" {
    const gpa = testing.allocator;
    const i = try arrayProgram(gpa, Type.int, &.{}, &.{});
    defer gpa.free(i);
    try expectProgram(&.{ (8 << 3) | array_mark, 0 }, i);
    const s = try arrayProgram(gpa, Type.str, &.{}, &.{});
    defer gpa.free(s);
    try expectProgram(&.{ (16 << 3) | array_mark, 1, 0 }, s);
}

fn expectProgram(want: []const u64, bytes: []const u8) !void {
    try testing.expectEqual(want.len * 8, bytes.len);
    for (want, 0..) |w, i| try testing.expectEqual(w, std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little));
}

test "a scalar has no program; a str or raw pointer is one PTR" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), (try program(gpa, Type.int, &.{}, &.{})).len);
    const s = try program(gpa, Type.str, &.{}, &.{});
    defer gpa.free(s);
    try expectProgram(&.{ 1, 0 }, s);
}

test "a struct names only its reference fields, nested structs flattened" {
    const gpa = testing.allocator;
    var inner_tys = [_]Type{ Type.int, Type.str };
    var inner_offs = [_]u32{ 0, 8 };
    var outer_tys = [_]Type{ Type.int, Type.structT(0), Type.rawptr };
    var outer_offs = [_]u32{ 0, 8, 32 };
    var no_names = [_][]const u8{ "", "", "" };
    const layouts = [_]Layout{
        .{ .name = "In", .field_names = no_names[0..2], .field_types = &inner_tys, .offsets = &inner_offs, .size = 24, .@"align" = 8 },
        .{ .name = "Out", .field_names = &no_names, .field_types = &outer_tys, .offsets = &outer_offs, .size = 40, .@"align" = 8 },
    };
    const p = try program(gpa, Type.structT(1), &layouts, &.{});
    defer gpa.free(p);
    try expectProgram(&.{ (16 << 2) | 1, (32 << 2) | 1, 0 }, p);
}

test "an enum switches on its tag; a variant without references jumps straight to the end" {
    const gpa = testing.allocator;
    var ref_tys = [_]Type{ Type.int, Type.str };
    var ref_offs = [_]u32{ 0, 8 };
    var int_tys = [_]Type{Type.int};
    var int_offs = [_]u32{0};
    var no_names = [_][]const u8{ "", "" };
    var variants = [_]types.VariantLayout{
        .{ .name = "A", .form = .tuple, .field_names = &.{}, .field_types = &int_tys, .offsets = &int_offs },
        .{ .name = "B", .form = .tuple, .field_names = no_names[0..2], .field_types = &ref_tys, .offsets = &ref_offs },
    };
    const enums = [_]EnumLayout{.{ .name = "E", .variants = &variants, .tag_size = 8, .payload_off = 8, .size = 32, .@"align" = 8 }};
    const p = try program(gpa, Type.enumT(0), &.{}, &enums);
    defer gpa.free(p);
    // [SWITCH@0, n=2, A->6, B->4, PTR 16, JUMP 6, END]
    try expectProgram(&.{ 2, 2, 6, 4, (16 << 2) | 1, (6 << 2) | 3, 0 }, p);

    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(gpa);
    try appendRefOffsets(gpa, Type.enumT(0), 8, &.{}, &enums, &offs);
    try testing.expectEqualSlices(u32, &.{24}, offs.items);
}

test "an enum with no reference in any variant adds nothing" {
    const gpa = testing.allocator;
    var int_tys = [_]Type{Type.int};
    var int_offs = [_]u32{0};
    var variants = [_]types.VariantLayout{
        .{ .name = "A", .form = .tuple, .field_names = &.{}, .field_types = &int_tys, .offsets = &int_offs },
        .{ .name = "B", .form = .unit, .field_names = &.{}, .field_types = &.{}, .offsets = &.{} },
    };
    const enums = [_]EnumLayout{.{ .name = "E", .variants = &variants, .tag_size = 8, .payload_off = 8, .size = 16, .@"align" = 8 }};
    try testing.expectEqual(@as(usize, 0), (try program(gpa, Type.enumT(0), &.{}, &enums)).len);
}
