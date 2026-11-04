//! The hand-emitted AArch64 runtime package root: the `HandBuiltin` table the link
//! tail scans + appends off, re-exporting the surface `link/emit.zig` needs.

const std = @import("std");
const Link = @import("../../link/Link.zig");
const StdNames = @import("../../symbols/StdNames.zig");
const emit = @import("emit.zig");
const str = @import("str.zig");
const panic = @import("panic.zig");

/// A hand-emitted AArch64 builtin body and its stable name. The link tail both
/// scans for referenced builtins and appends their bodies off this one list, so
/// the image stays a pure function of the fn set.
pub const HandBuiltin = struct {
    name: []const u8,
    lower: *const fn (std.mem.Allocator) error{OutOfMemory}!Link.FnCode,
    /// The `core/rt` fns this body calls. The linker keeps a toy fn only when a kept fn
    /// calls it, and a builtin body is appended after that walk, so each row names what
    /// it calls.
    runtime_calls: []const StdNames.RuntimeFn = &.{},
};

/// The FIXED append order of the hand-emitted builtins. Load-bearing: it makes the
/// linked image order-independent of the fn set's discovery/thread order. Append,
/// never reorder.
pub const hand_builtins = [_]HandBuiltin{
    .{ .name = "panic", .lower = panic.lowerPanic },
    .{ .name = "text_base", .lower = panic.lowerTextBase },
    .{ .name = "__int_to_str", .lower = str.lowerIntToStr, .runtime_calls = &.{.alloc} },
    .{ .name = "__str_concat", .lower = str.lowerStrConcat, .runtime_calls = &.{.alloc} },
    .{ .name = "__uint_to_str", .lower = str.lowerUintToStr, .runtime_calls = &.{.alloc} },
};

fn row(name: []const u8) ?*const HandBuiltin {
    for (&hand_builtins) |*hb| if (std.mem.eql(u8, hb.name, name)) return hb;
    return null;
}

/// Whether a call to the builtin `name` may run the collector: one of the `core/rt` fns
/// it calls may. A name with no row is assumed to.
pub fn mayCollect(name: []const u8) bool {
    const hb = row(name) orelse return true;
    for (hb.runtime_calls) |f| if (f.collects()) return true;
    return false;
}

/// Every C symbol a hand-emitted builtin imports, sorted. They bind to libSystem, so
/// a user `extern` block that names one for another library is a conflict.
pub const libsystem_imports = [_][]const u8{"write"};

/// The `hand_builtins` index of `name`, resolved at comptime — lets a caller name
/// a specific builtin (e.g. `panic`, which drives the backtrace symbol table)
/// without hardcoding a numeric slot.
pub fn handBuiltinIndex(comptime name: []const u8) usize {
    for (hand_builtins, 0..) |hb, i| {
        if (std.mem.eql(u8, hb.name, name)) return i;
    }
    @compileError("unknown hand builtin: " ++ name);
}

test "runtime_calls lists every core/rt fn a body calls, so the linker keeps it" {
    const gpa = std.testing.allocator;
    for (hand_builtins) |hb| {
        var fc = try hb.lower(gpa);
        defer fc.deinit(gpa);
        for (fc.relocs) |r| {
            if (r.kind != .call26 or r.target != .func) continue;
            const f = StdNames.RuntimeFn.lookup(r.target.func.name) orelse return error.UnknownCallee;
            if (std.mem.indexOfScalar(StdNames.RuntimeFn, hb.runtime_calls, f) == null) {
                std.debug.print("{s} calls {s}, missing from its runtime_calls\n", .{ hb.name, f.name() });
                return error.UnlistedCall;
            }
        }
    }
}

test "mayCollect: a builtin that allocates may; panic and text_base never do" {
    try std.testing.expect(mayCollect("__str_concat"));
    try std.testing.expect(mayCollect("__int_to_str"));
    try std.testing.expect(mayCollect("no_such_builtin"));
    try std.testing.expect(!mayCollect("panic"));
    try std.testing.expect(!mayCollect("text_base"));
}

test "no returning builtin writes a callee-saved register it does not save" {
    const gpa = std.testing.allocator;
    for (hand_builtins) |hb| {
        // panic never returns.
        if (std.mem.eql(u8, hb.name, "panic")) continue;
        var fc = try hb.lower(gpa);
        defer fc.deinit(gpa);
        const words = std.mem.bytesAsSlice(u32, fc.code);
        var written: u32 = 0;
        var saved: u32 = 0;
        for (words) |w| {
            const rt = w & 0x1F;
            // str xN, [sp, #imm] (unsigned offset, base sp): a save of rt.
            if (w & 0xFFC003E0 == 0xF90003E0) saved |= bitOf(rt);
            // Any instruction class whose destination field is rt and that writes a GPR:
            // data processing (immediate and register) and loads.
            const op0 = (w >> 25) & 0xF;
            const writes = op0 == 0b1000 or op0 == 0b1001 or op0 == 0b0101 or op0 == 0b1101 or
                (op0 & 0b0101 == 0b0100 and (w >> 22) & 1 == 1);
            if (writes) written |= bitOf(rt);
        }
        const callee_saved: u32 = 0x1FF80000; // x19-x28
        try std.testing.expectEqual(@as(u32, 0), written & ~saved & callee_saved);
    }
}

fn bitOf(r: u32) u32 {
    return @as(u32, 1) << @intCast(r);
}

test "libsystem_imports lists every symbol a hand builtin imports" {
    const gpa = std.testing.allocator;
    var seen: [libsystem_imports.len]bool = @splat(false);
    for (hand_builtins) |hb| {
        var fc = try hb.lower(gpa);
        defer fc.deinit(gpa);
        for (fc.relocs) |r| if (r.target == .import) {
            for (libsystem_imports, 0..) |nm, i| {
                if (std.mem.eql(u8, nm, r.target.import.name)) {
                    seen[i] = true;
                    break;
                }
            } else return error.UnlistedImport;
        };
    }
    for (seen) |s| try std.testing.expect(s);
    for (libsystem_imports[1..], 0..) |nm, i| try std.testing.expect(std.mem.lessThan(u8, libsystem_imports[i], nm));
}

test {
    _ = emit;
    _ = str;
    _ = panic;
}
