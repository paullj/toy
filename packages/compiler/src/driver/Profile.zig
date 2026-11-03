//! A build profile: every per-build choice a profile makes, carried as one value from the
//! CLI down to codegen and into the codegen cache key. Later choices (overflow checks,
//! debug info) are read off `name` here rather than added as separate flags, so a profile
//! stays one cache-key input.

const std = @import("std");
const Opt = @import("../opt/Opt.zig");

const Profile = @This();

pub const Name = enum(u8) { debug, release };

/// The chosen profile, which every choice beyond the passes follows; `-O` never changes it.
name: Name = .debug,
/// The IR passes. Starts as the profile's own choice; `-O`, `--opt` and `--no-opt` change it.
opt: Opt.Config = .O0,
/// Every heap allocation collects first, so a missing root or a wrong trace shows up in
/// any allocating program, not only in one that outgrows the collection budget. Only the
/// appended runtime changes, but it joins the key anyway so a stress build never serves a
/// normal one from the cache, whatever later lowering starts to read it.
gc_stress: bool = false,

pub const debug: Profile = of(.debug);
pub const release: Profile = of(.release);

pub fn of(name: Name) Profile {
    return switch (name) {
        .debug => .{ .name = .debug, .opt = .O0 },
        .release => .{ .name = .release, .opt = all_passes },
    };
}

/// Whether integer `+`, `-`, `*` and unary `-` panic on overflow; otherwise they wrap.
pub fn trapsOverflow(p: Profile) bool {
    return p.name == .debug;
}

/// Whether the image carries debug info: an LC_SYMTAB naming every function and DWARF
/// line tables. Release ships without it, as "debug info for debug builds" rules, so its
/// binary stays minimal.
pub fn debugInfo(p: Profile) bool {
    return p.name == .debug;
}

const all_passes: Opt.Config = blk: {
    var c: Opt.Config = .{};
    for (std.enums.values(Opt.Pass)) |p| c.set(p, true);
    break :blk c;
};

/// The fixed bytes the codegen key folds. A field added here must join them, or two
/// profiles that differ in it would share code.
pub fn keyBytes(p: Profile) [3]u8 {
    return .{ @intFromEnum(p.name), p.opt.bits(), @intFromBool(p.gc_stress) };
}

test "debug runs no pass and release runs every pass" {
    try std.testing.expectEqual(Opt.Config.O0, Profile.debug.opt);
    try std.testing.expect(!Profile.debug.opt.any());
    for (std.enums.values(Opt.Pass)) |p| try std.testing.expect(Profile.release.opt.has(p));
    try std.testing.expectEqual(Opt.Config.O1, Profile.release.opt);
    try std.testing.expectEqual(Profile.debug, Profile{});
}

test "the key bytes tell the profiles apart even when their passes match" {
    const debug_o1: Profile = .{ .name = .debug, .opt = .O1 };
    try std.testing.expect(!std.mem.eql(u8, &Profile.release.keyBytes(), &debug_o1.keyBytes()));
    try std.testing.expect(!std.mem.eql(u8, &Profile.release.keyBytes(), &Profile.debug.keyBytes()));
}

test "gc stress joins the key bytes" {
    const stress: Profile = .{ .name = .debug, .opt = .O0, .gc_stress = true };
    try std.testing.expect(!std.mem.eql(u8, &Profile.debug.keyBytes(), &stress.keyBytes()));
}
