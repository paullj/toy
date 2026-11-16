//! The hand-emitted builtins: the `HandBuiltin` table the link tail scans + appends
//! off. Each ISA module writes one body per row (`Isa.zig`, `hand_builtins`).

const std = @import("std");
const StdNames = @import("../../symbols/StdNames.zig");

/// A hand-emitted builtin's stable name. The link tail both scans for referenced
/// builtins and appends their bodies off this one list, so the image stays a pure
/// function of the fn set.
pub const HandBuiltin = struct {
    name: []const u8,
    /// The `core/rt` fns this body calls. The linker keeps a toy fn only when a kept fn
    /// calls it, and a builtin body is appended after that walk, so each row names what
    /// it calls.
    runtime_calls: []const StdNames.RuntimeFn = &.{},
};

/// The FIXED append order of the hand-emitted builtins. Load-bearing: it makes the
/// linked image order-independent of the fn set's discovery/thread order. Append,
/// never reorder.
pub const hand_builtins = [_]HandBuiltin{
    .{ .name = "panic" },
    .{ .name = "text_base" },
    .{ .name = "__int_to_str", .runtime_calls = &.{.alloc} },
    .{ .name = "__str_concat", .runtime_calls = &.{.alloc} },
    .{ .name = "__uint_to_str", .runtime_calls = &.{.alloc} },
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

test "mayCollect: a builtin that allocates may; panic and text_base never do" {
    try std.testing.expect(mayCollect("__str_concat"));
    try std.testing.expect(mayCollect("__int_to_str"));
    try std.testing.expect(mayCollect("no_such_builtin"));
    try std.testing.expect(!mayCollect("panic"));
    try std.testing.expect(!mayCollect("text_base"));
}
