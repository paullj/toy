//! The backend: `Ir.Function` -> `Link.FnCode` through instruction selection, a register
//! allocator and the encoder (see `mir/Mir.zig` for the design), generic over the ISA
//! module that provides the selector and the encoder (`Isa.zig` names what it provides).
//! A fn it cannot lower (a frame past codegen's budget, or a shape the selector does not
//! cover) comes back as a diagnostic and an empty `FnCode`, so the build fails cleanly.
//!
//! STACK MAPS. Under linear scan the fn's `root_bitmap` names only its memory roots (the
//! reference words of its IR slots and aggregate values), and `safepoint_maps` adds one
//! row per safepoint call whose roots differ from the row before it: the memory roots plus
//! the spill slots that hold a reference live across that call. The collector looks a
//! frame up by its return address, so it lands on the row of the call the frame is in.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const FrameLayout = @import("frame/FrameLayout.zig");
const Link = @import("../link/Link.zig");
const types = @import("../types.zig");
const Mir = @import("mir/Mir.zig");
const LinearScan = @import("mir/LinearScan.zig");
const Isa = @import("Isa.zig");
const Target = @import("../Target.zig");

const Diagnostic = @import("../diagnostics/Diagnostic.zig").Diagnostic;

pub fn CodegenMir(comptime I: type) type {
    comptime Isa.check(I);
    return struct {
        /// One backend per C convention the ISA implements.
        pub const backends = blk: {
            var out: [I.c_abis.len]Isa.Backend = undefined;
            for (I.c_abis, &out) |c_abi, *b| b.* = backendFor(c_abi);
            break :blk out;
        };

        fn backendFor(comptime c_abi: Target.CAbi) Isa.Backend {
            const For = struct {
                fn lower(
                    gpa: std.mem.Allocator,
                    func: *const Ir.Function,
                    layouts: []const types.Layout,
                    enum_layouts: []const types.EnumLayout,
                    is_entry: bool,
                    guard_stack: bool,
                    diags: *std.ArrayList(Diagnostic),
                ) error{OutOfMemory}!Link.FnCode {
                    return lowerMir(gpa, func, layouts, enum_layouts, c_abi, is_entry, guard_stack, diags);
                }

                fn fits(
                    gpa: std.mem.Allocator,
                    func: *const Ir.Function,
                    layouts: []const types.Layout,
                    enum_layouts: []const types.EnumLayout,
                ) error{OutOfMemory}!bool {
                    return FrameLayout.fits(gpa, func, comptime I.abi.facts(c_abi), layouts, enum_layouts);
                }
            };
            return .{ .c_abi = c_abi, .lower = For.lower, .fits = For.fits, .relocs = I.relocs, .hand_builtins = &I.hand_builtins, .inst_count = I.instCount };
        }

        /// Lower `func` to machine code. A fn the backend cannot lower records one diagnostic in
        /// `diags` and returns an empty `FnCode`; the caller fails the build on it. Caller owns
        /// the result.
        pub fn lowerMir(
            gpa: std.mem.Allocator,
            func: *const Ir.Function,
            layouts: []const types.Layout,
            enum_layouts: []const types.EnumLayout,
            comptime c_abi: Target.CAbi,
            is_entry: bool,
            guard_stack: bool,
            diags: *std.ArrayList(Diagnostic),
        ) error{OutOfMemory}!Link.FnCode {
            const facts = comptime I.abi.facts(c_abi);
            var frame: Mir.Frame = .{ .layout = FrameLayout.compute(gpa, func, facts, layouts, enum_layouts) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FrameTooLarge => return fail(gpa, func, diags, frameTooLargeMessage(func, facts.max_frame, layouts, enum_layouts)),
                error.ParamOffsetTooLarge => return fail(gpa, func, diags, "too many parameters for codegen (stack-arg offset out of range)"),
            } };
            defer frame.deinit(gpa);
            const roots = try FrameLayout.collectRoots(gpa, func, &frame.layout, layouts, enum_layouts);
            defer gpa.free(roots);

            var literals: std.ArrayList(Link.Literal) = .empty;
            defer {
                for (literals.items) |l| gpa.free(l.bytes);
                literals.deinit(gpa);
            }
            for (func.literals) |lit| try I.Isel.addLiteral(gpa, &literals, lit.hash, lit.bytes);

            var mf = try I.Isel.newFunc(gpa, func);
            defer mf.deinit(gpa);
            I.Isel.select(gpa, .{
                .ir = func,
                .layouts = layouts,
                .enum_layouts = enum_layouts,
                .facts = &facts,
                .is_entry = is_entry,
                .fl = &frame.layout,
                .roots = roots,
            }, &mf, &literals) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unsupported => return fail(gpa, func, diags, "internal compiler error: codegen met a value shape it does not cover"),
            };
            const rooted_slots = try FrameLayout.rootedSlots(gpa, func, layouts, enum_layouts);
            defer gpa.free(rooted_slots);
            try I.Peephole.run(gpa, &mf, .{ .rooted_slots = rooted_slots });
            if (std.debug.runtime_safety) {
                std.debug.assert(try mf.tempsStayLocal(gpa));
                std.debug.assert(!mf.namesAny(I.reserved));
                std.debug.assert(mf.callRegsAgree(~I.Inst.caller_saved));
            }

            var maps = LinearScan.LinearScan(I).run(gpa, &mf, &frame) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unallocatable => return fail(gpa, func, diags, "internal compiler error: an instruction needs more registers than codegen has"),
            };
            defer maps.deinit(gpa);
            std.debug.assert(mf.allPhysical());
            if (frame.size() > facts.max_frame) return fail(gpa, func, diags, frameTooLargeMessage(func, facts.max_frame, layouts, enum_layouts));

            var out: I.Emit.Out = .{};
            defer out.deinit(gpa);
            I.Emit.encode(gpa, &mf, &frame, func.line, guard_stack, &out) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BranchOutOfRange => return fail(gpa, func, diags, "function too large for codegen (a branch is out of range)"),
            };

            const root_bitmap = try FrameLayout.encodeRoots(gpa, roots);
            errdefer gpa.free(root_bitmap);
            const safepoint_maps = try encodeSafepoints(gpa, roots, maps.maps, out.safepoints.items, &frame);
            errdefer gpa.free(safepoint_maps);
            const name = try gpa.dupe(u8, func.name.name);
            errdefer gpa.free(name);
            const code = try out.code.toOwnedSlice(gpa);
            errdefer gpa.free(code);
            const lines = try out.lines.toOwnedSlice(gpa);
            errdefer gpa.free(lines);
            const owned_literals = try literals.toOwnedSlice(gpa);
            errdefer {
                for (owned_literals) |l| gpa.free(l.bytes);
                gpa.free(owned_literals);
            }
            return .{
                .sym = .{ .kind = func.name.kind, .name = name },
                .code = code,
                .relocs = try out.relocs.toOwnedSlice(gpa),
                .literals = owned_literals,
                .root_bitmap = root_bitmap,
                .safepoint_maps = safepoint_maps,
                .lines = lines,
            };
        }
    };
}

/// Record `message` against `func` and return its empty `FnCode`, so the driver fails the
/// build on the diagnostic rather than linking a half-lowered fn.
fn fail(gpa: std.mem.Allocator, func: *const Ir.Function, diags: *std.ArrayList(Diagnostic), message: []const u8) error{OutOfMemory}!Link.FnCode {
    try diags.append(gpa, .{ .byte_offset = 0, .end = 0, .message = message });
    return .{
        .sym = .{ .kind = func.name.kind, .name = try gpa.dupe(u8, func.name.name) },
        .code = &.{},
        .relocs = &.{},
        .literals = &.{},
    };
}

/// A struct or enum may take a whole frame (T0077 stops only a larger one), and then the
/// frame has no room for the fn's other values; "too many locals" would misname that.
fn frameTooLargeMessage(func: *const Ir.Function, comptime max_frame: u32, layouts: []const types.Layout, enum_layouts: []const types.EnumLayout) []const u8 {
    if (FrameLayout.largestSlot(func, layouts, enum_layouts) > max_frame -| 64 * 1024)
        return comptime std.fmt.comptimePrint("function frame too large for codegen (one value nearly fills the {d} MiB frame; hold large data in a Vec)", .{std.math.divCeil(u32, max_frame, 1 << 20) catch unreachable});
    return "function frame too large for codegen (too many locals)";
}

/// The `FnCode.safepoint_maps` rows: per safepoint call at `offs[i]`, the memory roots plus
/// `maps[i]`'s slots, as `[u32 code_off][u32 n][u32 sp_off x n]`. A row equal to
/// the one before it (the fn-start row of memory roots, first) is left out: the collector
/// takes the last row at or before a frame's call, which then has the same roots.
fn encodeSafepoints(
    gpa: std.mem.Allocator,
    roots: []const FrameLayout.Root,
    maps: []const []const LinearScan.Root,
    offs: []const u32,
    frame: *const Mir.Frame,
) error{OutOfMemory}![]u8 {
    std.debug.assert(maps.len == 0 or maps.len == offs.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var row: std.ArrayList(FrameLayout.Root) = .empty;
    defer row.deinit(gpa);
    var prev: []const LinearScan.Root = &.{};
    for (maps, offs) |m, off| {
        if (std.mem.eql(u8, std.mem.sliceAsBytes(m), std.mem.sliceAsBytes(prev))) continue;
        prev = m;
        row.clearRetainingCapacity();
        try row.appendSlice(gpa, roots);
        for (m) |r| try row.append(gpa, .{ .off = frame.spOffset(.{ .spill = r.spill }) });
        const payload = try FrameLayout.encodeRoots(gpa, row.items);
        defer gpa.free(payload);
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, off, .little);
        try out.appendSlice(gpa, &w);
        try out.appendSlice(gpa, payload);
    }
    return out.toOwnedSlice(gpa);
}

test {
    _ = Mir;
    _ = @import("mir/Liveness.zig");
    _ = @import("mir/GcFacts.zig");
    _ = @import("mir/Interval.zig");
    _ = @import("mir/Moves.zig");
    _ = @import("mir/LinearScan.zig");
    _ = Isa;
}
