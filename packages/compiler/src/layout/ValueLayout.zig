//! The target-neutral layout of toy values: each type's size and alignment, the
//! allocator's size classes, and the per-type descriptor record. The front end, the
//! linker and every C calling convention (`codegen/abi/Abi.zig`) read sizes from here,
//! so no target can disagree with another about where a field lies.

const std = @import("std");
const types = @import("../types.zig");

pub const Type = types.Type;
pub const Layout = types.Layout;
pub const EnumLayout = types.EnumLayout;

/// The allocator's size-class ladder (bytes). `gc_alloc` rounds a small request up to
/// the first class `>= size`; a request past the last class is a large object. The one
/// authority for the taxonomy — the collector (`core/rt/gc.toy`) mirrors it, which a test in
/// `types/runtime.zig` pins, and `sizeClassFor` derives a type's static class from it, so
/// the descriptor and the allocator agree.
pub const size_classes = [_]u16{ 16, 32, 48, 64, 96, 128, 192, 256, 512, 1024, 2048, 4096, 8192 };

/// The static allocation size class for `size`: the first ladder class `>= size`, or `0`
/// (the large-object marker — a direct span-aligned mmap, no class arena) when `size`
/// exceeds the largest class.
pub fn sizeClassFor(size: u32) u16 {
    for (size_classes) |cls| if (size <= cls) return cls;
    return 0;
}

/// The static per-type descriptor the allocator / a later precise-tracing milestone reads:
/// the type's byte size, its natural alignment, and its allocation size class. A pure
/// function of the layout snapshot; provisioned minimally (its runtime consumer is a later
/// milestone).
pub const Descriptor = struct { size: u32, @"align": u32, size_class: u16 };

/// The `Descriptor` for a reified type over the layout snapshot.
pub fn descriptorFor(ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) Descriptor {
    const size = typeSize(ty, layouts, enum_layouts);
    return .{ .size = size, .@"align" = typeAlign(ty, layouts, enum_layouts), .size_class = sizeClassFor(size) };
}

/// Byte layout of the emitted per-type descriptor RECORD: a fixed `stride`-byte, all-8-byte
/// little-endian record `{size, align, size_class, hash_off, eq_off}`, where each `*_off` is
/// an erased unit's `__text` byte offset (0 = absent). This is the SINGLE authority for those
/// offsets: `link.buildDescTable` writes them and `link.emit` reserves table entries by
/// `stride`. The `.toy` runtime hard-codes the same numbers and cannot import this authority
/// (no Zig consts in `.toy`) — the `descriptor record layout` test below pins the mirror.
pub const desc = struct {
    pub const size_off: u32 = 0;
    pub const align_off: u32 = 8;
    pub const size_class_off: u32 = 16;
    pub const hash_off: u32 = 24;
    pub const eq_off: u32 = 32;
    pub const stride: u32 = 40;
};

test "descriptor record layout is five contiguous 8-byte fields the .toy runtime mirrors" {
    // Each field is 8 bytes, so every offset is the previous + 8 and `stride` closes the record.
    try std.testing.expectEqual(@as(u32, 0), desc.size_off);
    try std.testing.expectEqual(desc.size_off + 8, desc.align_off);
    try std.testing.expectEqual(desc.align_off + 8, desc.size_class_off);
    try std.testing.expectEqual(desc.size_class_off + 8, desc.hash_off);
    try std.testing.expectEqual(desc.hash_off + 8, desc.eq_off);
    try std.testing.expectEqual(desc.eq_off + 8, desc.stride);
    // The `.toy` runtime hard-codes these exact byte offsets. If a change here trips this
    // assertion, update the mirrors before shipping:
    //   core/mem.toy  (mp_find/mp_set/mp_grow): `load(offset(dp, 24))` = hash, `(dp, 32)` = eq
    //   core/desc_selftest.toy: the same hash@24 / eq@32 descriptor reads
    try std.testing.expectEqual(@as(u32, 24), desc.hash_off);
    try std.testing.expectEqual(@as(u32, 32), desc.eq_off);
    try std.testing.expectEqual(@as(u32, 40), desc.stride);
}

/// Byte size of a type (int/bool 8, str 16, struct/enum → its layout size).
pub fn typeSize(ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) u32 {
    return switch (ty.kind) {
        .int, .bool, .float, .rawptr, .cstr => 8,
        .str => 16,
        .@"struct" => layouts[ty.struct_id].size,
        .@"enum" => enum_layouts[ty.enum_id].size,
        else => 0,
    };
}

/// Natural alignment of a type (8 for scalars/str; a struct/enum's layout
/// alignment).
pub fn typeAlign(ty: Type, layouts: []const Layout, enum_layouts: []const EnumLayout) u32 {
    return switch (ty.kind) {
        .int, .bool, .float, .str, .rawptr, .cstr => 8,
        .@"struct" => layouts[ty.struct_id].@"align",
        .@"enum" => enum_layouts[ty.enum_id].@"align",
        else => 1,
    };
}

const testing = std.testing;

fn mkLayouts(gpa: std.mem.Allocator, sizes: []const u32) ![]Layout {
    const ls = try gpa.alloc(Layout, sizes.len);
    for (sizes, 0..) |s, i| {
        ls[i] = .{ .name = "T", .field_names = &.{}, .field_types = &.{}, .offsets = &.{}, .size = s, .@"align" = 8 };
    }
    return ls;
}

test "sizeClassFor: rounds up to the first class, large past the ladder marks 0" {
    try testing.expectEqual(@as(u16, 16), sizeClassFor(8)); // scalar → smallest class
    try testing.expectEqual(@as(u16, 16), sizeClassFor(16)); // exact boundary
    try testing.expectEqual(@as(u16, 32), sizeClassFor(17)); // just over → next class
    try testing.expectEqual(@as(u16, 48), sizeClassFor(48)); // a non-pow2 class, exact
    try testing.expectEqual(@as(u16, 8192), sizeClassFor(8192)); // the last class, exact
    try testing.expectEqual(@as(u16, 0), sizeClassFor(8193)); // past the ladder → large marker
}

test "descriptorFor: reads size/align off the layout, classes by size" {
    const gpa = testing.allocator;
    const ls = try mkLayouts(gpa, &.{24}); // struct#0 is 24 bytes, align 8
    defer gpa.free(ls);
    const el: []const EnumLayout = &.{};
    const d = descriptorFor(Type.structT(0), ls, el);
    try testing.expectEqual(@as(u32, 24), d.size);
    try testing.expectEqual(@as(u32, 8), d.@"align");
    try testing.expectEqual(@as(u16, 32), d.size_class);
    // A bare int: 8 bytes, align 8, smallest class.
    const di = descriptorFor(Type.int, &.{}, el);
    try testing.expectEqual(@as(u32, 8), di.size);
    try testing.expectEqual(@as(u16, 16), di.size_class);
}
