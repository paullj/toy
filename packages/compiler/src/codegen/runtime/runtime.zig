//! The hand-emitted AArch64 runtime package root: the `HandBuiltin` table the link
//! tail scans + appends off, re-exporting the surface `link/emit.zig` needs.

const std = @import("std");
const Link = @import("../../link/Link.zig");
const emit = @import("emit.zig");
const str = @import("str.zig");
const panic = @import("panic.zig");
const gc = @import("gc.zig");
const trace = @import("trace.zig");

/// The per-build runtime choices a builtin body may read, taken from the build profile.
pub const Config = struct {
    /// `gc_alloc` collects before every allocation (`--gc-stress`).
    gc_stress: bool = false,
};

/// A hand-emitted AArch64 builtin body and its stable name. The link tail both
/// scans for referenced builtins and appends their bodies off this one list, so
/// the image stays a pure function of the fn set.
pub const HandBuiltin = struct {
    name: []const u8,
    lower: *const fn (std.mem.Allocator, Config) error{OutOfMemory}!Link.FnCode,
    /// Other hand-emitted builtins this body statically calls from WITHIN its appended
    /// machine code (e.g. `gc_alloc` triggers `gc_collect`). Such an edge is invisible to
    /// the link tail's fn-only used-scan, so the linker closes the used set over it — a
    /// program that carries this builtin also carries its callees. Each name must be a
    /// `hand_builtins` row.
    static_call_deps: []const []const u8 = &.{},
    /// Callee-saved registers the body overwrites without restoring, which a caller that
    /// keeps values in registers across the call must treat as clobbered.
    callee_saved_clobbers: []const u32 = &.{},
};

/// The FIXED append order of the hand-emitted builtins. Load-bearing: it makes the
/// linked image order-independent of the fn set's discovery/thread order. Append,
/// never reorder.
pub const hand_builtins = [_]HandBuiltin{
    .{ .name = "panic", .lower = plain(panic.lowerPanic) },
    .{ .name = "gc_alloc", .lower = gcAlloc, .static_call_deps = &.{"gc_collect"} },
    .{ .name = "gc_span_count", .lower = plain(gc.lowerGcSpanCount) },
    .{ .name = "gc_collect", .lower = plain(gc.lowerGcCollect), .static_call_deps = &.{ "ga_trace", "mp_trace" } },
    .{ .name = "gc_stats", .lower = plain(gc.lowerGcStats) },
    // gc_mark sets the collector's push descriptor in x24 and does not restore it. Fixing
    // the body would change every binary with a trace fn; the runtime moves to toy (#209).
    .{ .name = "gc_mark", .lower = plain(gc.lowerGcMark), .callee_saved_clobbers = &.{24} },
    .{ .name = "gc_mark_leaf", .lower = plain(gc.lowerGcMarkLeaf) },
    .{ .name = "ga_trace", .lower = plain(trace.lowerGaTrace), .static_call_deps = &.{"gc_mark_leaf"} },
    .{ .name = "mp_trace", .lower = plain(trace.lowerMpTrace), .static_call_deps = &.{"gc_mark_leaf"} },
    .{ .name = "text_base", .lower = plain(panic.lowerTextBase) },
    .{ .name = "__int_to_str", .lower = plain(str.lowerIntToStr), .static_call_deps = &.{"gc_alloc"} },
    .{ .name = "__str_concat", .lower = plain(str.lowerStrConcat), .static_call_deps = &.{"gc_alloc"} },
    .{ .name = "__uint_to_str", .lower = plain(str.lowerUintToStr), .static_call_deps = &.{"gc_alloc"} },
};

fn row(name: []const u8) ?*const HandBuiltin {
    for (&hand_builtins) |*hb| if (std.mem.eql(u8, hb.name, name)) return hb;
    return null;
}

/// Whether a call to the builtin `name` may run the collector: it is `gc_collect`, or one of
/// its static calls may. A name with no row is assumed to.
pub fn mayCollect(name: []const u8) bool {
    if (std.mem.eql(u8, name, "gc_collect")) return true;
    const hb = row(name) orelse return true;
    for (hb.static_call_deps) |dep| if (mayCollect(dep)) return true;
    return false;
}

/// The callee-saved registers a call to the builtin `name` overwrites (see
/// `HandBuiltin.callee_saved_clobbers`).
pub fn calleeSavedClobbers(name: []const u8) []const u32 {
    const hb = row(name) orelse return &.{};
    return hb.callee_saved_clobbers;
}

/// A `HandBuiltin.lower` for a body that reads no `Config`.
fn plain(comptime f: fn (std.mem.Allocator) error{OutOfMemory}!Link.FnCode) *const fn (std.mem.Allocator, Config) error{OutOfMemory}!Link.FnCode {
    return struct {
        fn lower(gpa: std.mem.Allocator, _: Config) error{OutOfMemory}!Link.FnCode {
            return f(gpa);
        }
    }.lower;
}

fn gcAlloc(gpa: std.mem.Allocator, cfg: Config) error{OutOfMemory}!Link.FnCode {
    return gc.lowerGcAlloc(gpa, cfg.gc_stress);
}

/// Every C symbol a hand-emitted builtin imports, sorted. They bind to libSystem, so
/// a user `extern` block that names one for another library is a conflict.
pub const libsystem_imports = [_][]const u8{ "calloc", "free", "malloc", "mmap", "munmap", "realloc", "write" };

/// The `hand_builtins` index of `name`, resolved at comptime — lets a caller name
/// a specific builtin (e.g. `panic`, which drives the backtrace symbol table)
/// without hardcoding a numeric slot.
pub fn handBuiltinIndex(comptime name: []const u8) usize {
    for (hand_builtins, 0..) |hb, i| {
        if (std.mem.eql(u8, hb.name, name)) return i;
    }
    @compileError("unknown hand builtin: " ++ name);
}

test "hand_builtins static_call_deps name real rows; gc_alloc pulls gc_collect" {
    for (hand_builtins) |hb| {
        for (hb.static_call_deps) |dep| {
            var found = false;
            for (hand_builtins) |other| {
                if (std.mem.eql(u8, other.name, dep)) found = true;
            }
            try std.testing.expect(found);
        }
    }
    const deps = hand_builtins[comptime handBuiltinIndex("gc_alloc")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("gc_collect", deps[0]);

    const its = hand_builtins[comptime handBuiltinIndex("__int_to_str")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 1), its.len);
    try std.testing.expectEqualStrings("gc_alloc", its[0]);

    const uts = hand_builtins[comptime handBuiltinIndex("__uint_to_str")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 1), uts.len);
    try std.testing.expectEqualStrings("gc_alloc", uts[0]);

    const sc = hand_builtins[comptime handBuiltinIndex("__str_concat")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 1), sc.len);
    try std.testing.expectEqualStrings("gc_alloc", sc[0]);

    // The collector's precise container traces: gc_collect may dispatch to ga_trace/mp_trace
    // on a container pop, and each leaf-marks its backings via gc_mark_leaf. These edges are
    // asm-level `bl`s invisible to the fn-only used-scan, so the linker closes over them.
    const gc_deps = hand_builtins[comptime handBuiltinIndex("gc_collect")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 2), gc_deps.len);
    try std.testing.expectEqualStrings("ga_trace", gc_deps[0]);
    try std.testing.expectEqualStrings("mp_trace", gc_deps[1]);
    const gat = hand_builtins[comptime handBuiltinIndex("ga_trace")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 1), gat.len);
    try std.testing.expectEqualStrings("gc_mark_leaf", gat[0]);
    const mpt = hand_builtins[comptime handBuiltinIndex("mp_trace")].static_call_deps;
    try std.testing.expectEqual(@as(usize, 1), mpt.len);
    try std.testing.expectEqualStrings("gc_mark_leaf", mpt[0]);
}

test "static_call_deps lists every builtin a body calls, so mayCollect sees each path to gc_collect" {
    const gpa = std.testing.allocator;
    for (hand_builtins) |hb| for ([_]Config{ .{}, .{ .gc_stress = true } }) |cfg| {
        var fc = try hb.lower(gpa, cfg);
        defer fc.deinit(gpa);
        for (fc.relocs) |r| {
            if (r.kind != .call26 or r.target != .func) continue;
            for (hb.static_call_deps) |dep| {
                if (std.mem.eql(u8, dep, r.target.func.name)) break;
            } else {
                std.debug.print("{s} calls {s}, missing from its static_call_deps\n", .{ hb.name, r.target.func.name });
                return error.UnlistedCall;
            }
        }
    };
}

test "mayCollect follows static calls to gc_collect; panic and the markers never collect" {
    try std.testing.expect(mayCollect("gc_alloc"));
    try std.testing.expect(mayCollect("__str_concat"));
    try std.testing.expect(mayCollect("gc_collect"));
    try std.testing.expect(mayCollect("no_such_builtin"));
    try std.testing.expect(!mayCollect("panic"));
    try std.testing.expect(!mayCollect("gc_mark"));
    try std.testing.expect(!mayCollect("gc_mark_leaf"));
    try std.testing.expect(!mayCollect("gc_span_count"));
    try std.testing.expectEqualSlices(u32, &.{24}, calleeSavedClobbers("gc_mark"));
    try std.testing.expectEqual(@as(usize, 0), calleeSavedClobbers("gc_alloc").len);
}

test "callee_saved_clobbers names every callee-saved register a returning builtin writes and does not save" {
    const gpa = std.testing.allocator;
    for (hand_builtins) |hb| {
        // panic never returns; the collector's own helpers run only inside gc_collect,
        // which saves x19-x28 for its caller.
        if (std.mem.eql(u8, hb.name, "panic")) continue;
        var fc = try hb.lower(gpa, .{});
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
        var listed: u32 = 0;
        for (hb.callee_saved_clobbers) |r| listed |= bitOf(r);
        const callee_saved: u32 = 0x1FF80000; // x19-x28
        try std.testing.expectEqual(written & ~saved & callee_saved, listed);
    }
}

fn bitOf(r: u32) u32 {
    return @as(u32, 1) << @intCast(r);
}

test "libsystem_imports lists every symbol a hand builtin imports" {
    const gpa = std.testing.allocator;
    var seen: [libsystem_imports.len]bool = @splat(false);
    for (hand_builtins) |hb| {
        var fc = try hb.lower(gpa, .{});
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
    _ = gc;
    _ = trace;
}
