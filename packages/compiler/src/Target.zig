//! What a build compiles for: an ISA, an OS and that OS's C ABI. Parsed once from the
//! `--target` triple at the CLI; every later stage takes this value, never a string.
//! `native` is resolved to the host here, so `native` and its explicit triple are one
//! value and share every cache entry.

const std = @import("std");
const builtin = @import("builtin");

const Target = @This();

arch: Arch,
os: Os,
abi: Abi,

/// Names match the `Arch` enum of `core/target`, whose consts the driver writes by tag name.
pub const Arch = enum { aarch64, x86_64 };
/// Names match the `Os` enum of `core/target`.
pub const Os = enum { macos, linux };
pub const Abi = enum { apple, gnu };

pub const ObjectFormat = enum { macho, elf };

/// The C calling convention family. Apple's arm64 ABI departs from AAPCS64 (varargs on
/// the stack, packed stack arguments), so it is its own family.
pub const CAbi = enum { aapcs64_apple, aapcs64, sysv64 };

pub const aarch64_macos: Target = .{ .arch = .aarch64, .os = .macos, .abi = .apple };
pub const aarch64_linux: Target = .{ .arch = .aarch64, .os = .linux, .abi = .gnu };
pub const x86_64_linux: Target = .{ .arch = .x86_64, .os = .linux, .abi = .gnu };

/// Every `--target` spelling the CLI takes, `native` first.
pub const spellings = [_][:0]const u8{ "native", "aarch64-macos", "aarch64-linux", "aarch64-linux-gnu", "x86_64-linux", "x86_64-linux-gnu" };

/// The host, or null when toy cannot build for the machine it runs on.
pub const host: ?Target = fromParts(builtin.cpu.arch, builtin.os.tag);

pub const ParseError = error{
    /// Not a triple toy builds for.
    UnknownTarget,
    /// `native` on a host toy cannot build for.
    UnsupportedHost,
};

pub fn parse(triple: []const u8) ParseError!Target {
    if (std.mem.eql(u8, triple, "native")) return host orelse error.UnsupportedHost;
    var it = std.mem.splitScalar(u8, triple, '-');
    const arch = std.meta.stringToEnum(Arch, it.next().?) orelse return error.UnknownTarget;
    const os = std.meta.stringToEnum(Os, it.next() orelse return error.UnknownTarget) orelse return error.UnknownTarget;
    const abi = if (it.next()) |a| std.meta.stringToEnum(Abi, a) orelse return error.UnknownTarget else defaultAbi(os);
    if (it.next() != null) return error.UnknownTarget;
    const t: Target = .{ .arch = arch, .os = os, .abi = abi };
    if (!t.supported()) return error.UnknownTarget;
    return t;
}

fn fromParts(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ?Target {
    const a: Arch = switch (arch) {
        .aarch64 => .aarch64,
        .x86_64 => .x86_64,
        else => return null,
    };
    const o: Os = switch (os) {
        .macos => .macos,
        .linux => .linux,
        else => return null,
    };
    const t: Target = .{ .arch = a, .os = o, .abi = defaultAbi(o) };
    return if (t.supported()) t else null;
}

fn defaultAbi(os: Os) Abi {
    return switch (os) {
        .macos => .apple,
        .linux => .gnu,
    };
}

/// The targets of #60: no x86_64-macos, and each OS with its own C library's ABI.
fn supported(t: Target) bool {
    if (t.abi != defaultAbi(t.os)) return false;
    return !(t.arch == .x86_64 and t.os == .macos);
}

pub fn eql(a: Target, b: Target) bool {
    return a.arch == b.arch and a.os == b.os and a.abi == b.abi;
}

/// The short triple, as a diagnostic names the target. The ABI is left out: each OS has
/// one.
pub fn name(t: Target) []const u8 {
    return switch (t.arch) {
        inline else => |a| switch (t.os) {
            inline else => |o| @tagName(a) ++ "-" ++ @tagName(o),
        },
    };
}

pub fn objectFormat(t: Target) ObjectFormat {
    return switch (t.os) {
        .macos => .macho,
        .linux => .elf,
    };
}

pub fn cAbi(t: Target) CAbi {
    return switch (t.arch) {
        .aarch64 => switch (t.abi) {
            .apple => .aapcs64_apple,
            .gnu => .aapcs64,
        },
        .x86_64 => .sysv64,
    };
}

/// The bytes a cache key folds: one per field, so two targets share a key only when
/// they are equal.
pub fn keyBytes(t: Target) [3]u8 {
    return .{ @intFromEnum(t.arch), @intFromEnum(t.os), @intFromEnum(t.abi) };
}

const testing = std.testing;

test "parse takes each spelling, with the -gnu suffix optional on linux" {
    try testing.expect((try parse("aarch64-macos")).eql(aarch64_macos));
    try testing.expect((try parse("aarch64-linux")).eql(aarch64_linux));
    try testing.expect((try parse("aarch64-linux-gnu")).eql(aarch64_linux));
    try testing.expect((try parse("x86_64-linux")).eql(x86_64_linux));
    try testing.expect((try parse("x86_64-linux-gnu")).eql(x86_64_linux));
    for (spellings[1..]) |s| _ = try parse(s);
}

test "parse rejects what is not a target toy builds for" {
    for ([_][]const u8{ "", "bogus", "aarch64", "aarch64-", "aarch64-mac", "x86_64-macos", "aarch64-macos-gnu", "aarch64-linux-apple", "aarch64-linux-gnu-x", "riscv64-linux", "aarch64-linux-musl" }) |s|
        try testing.expectError(error.UnknownTarget, parse(s));
}

test "native is the host, so it keys the same as the host's triple" {
    if (host) |h| {
        const n = try parse("native");
        try testing.expect(n.eql(h));
        try testing.expect(n.eql(try parse(h.name())));
        try testing.expectEqualSlices(u8, &h.keyBytes(), &n.keyBytes());
    } else try testing.expectError(error.UnsupportedHost, parse("native"));
}

test "the object format and the C ABI follow from the target" {
    try testing.expectEqual(ObjectFormat.macho, aarch64_macos.objectFormat());
    try testing.expectEqual(ObjectFormat.elf, aarch64_linux.objectFormat());
    try testing.expectEqual(ObjectFormat.elf, x86_64_linux.objectFormat());
    try testing.expectEqual(CAbi.aapcs64_apple, aarch64_macos.cAbi());
    try testing.expectEqual(CAbi.aapcs64, aarch64_linux.cAbi());
    try testing.expectEqual(CAbi.sysv64, x86_64_linux.cAbi());
}

test "name is the short triple and parses back to the same target" {
    try testing.expectEqualStrings("aarch64-macos", aarch64_macos.name());
    try testing.expectEqualStrings("aarch64-linux", aarch64_linux.name());
    try testing.expectEqualStrings("x86_64-linux", x86_64_linux.name());
    for ([_]Target{ aarch64_macos, aarch64_linux, x86_64_linux }) |t| try testing.expect((try parse(t.name())).eql(t));
}

test "keyBytes tells every target apart" {
    const all = [_]Target{ aarch64_macos, aarch64_linux, x86_64_linux };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b|
        try testing.expect(!std.mem.eql(u8, &a.keyBytes(), &b.keyBytes()));
}
