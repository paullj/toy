//! The instruction-set interface, and the one place a target's arch picks its ISA.
//!
//! An ISA module is a namespace that `CodegenMir(Isa)` instantiates the backend over, as
//! `LinearScan(Target)` is over its target. It provides:
//!
//!   * `Inst` — its MIR instruction, as `Mir.Function` asks (`operands`, `callRegs`),
//!     plus `caller_saved`, `branchTarget`, `setBranchTarget` and `copyRegs` for linear
//!     scan.
//!   * `Isel` — instruction selection: `Func` (= `Mir.Function(Inst)`), `Input`,
//!     `newFunc(gpa, ir)`, `select(gpa, input, func, literals)` raising
//!     `error.Unsupported` on a shape it does not cover, and `addLiteral`.
//!   * `Peephole` — `run(gpa, func, Options)` over the selected code.
//!   * `Emit` — the encoder: `Out` (code bytes, relocs, line rows, safepoint call
//!     offsets) and `encode(gpa, func, frame, fn_line, guard_stack, out)` raising
//!     `error.BranchOutOfRange`. Instructions may be any length: every offset is in bytes.
//!   * Registers, for the selector's checks and for linear scan: `reserved` (never named
//!     by the selector), `allocatable(class)` in order of preference, `callee_saved`,
//!     `moveScratch(class)`, and the code linear scan adds: `move`, `jump`, `spillLoad`
//!     and `spillStore`.
//!   * `relocs` — its relocation kinds and how each patches its site (`Link.Patcher`).
//!     Link carries a kind opaquely, so no other module names an encoding.
//!   * `hand_builtins` — one body per `runtime.hand_builtins` row, in its order: the
//!     builtins written by hand per ISA until they are toy code in core/rt.
//!   * `c_abis` — the C calling conventions (`Target.CAbi`) its selector places
//!     arguments for.
//!   * `instCount(code)` — how many instructions encoded `code` holds, for
//!     `--opt-stats`.
//!
//! `Backend` is what the rest of the compiler holds: one per ISA and C convention, picked
//! by `of` from the target.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const Link = @import("../link/Link.zig");
const types = @import("../types.zig");
const Target = @import("../Target.zig");
const runtime = @import("runtime/runtime.zig");
const CodegenMir = @import("CodegenMir.zig");
const Diagnostic = @import("../diagnostics/Diagnostic.zig").Diagnostic;

pub const LowerFn = *const fn (
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
    is_entry: bool,
    guard_stack: bool,
    diags: *std.ArrayList(Diagnostic),
) error{OutOfMemory}!Link.FnCode;

pub const FitsFn = *const fn (
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
) error{OutOfMemory}!bool;

pub const BuiltinFn = *const fn (gpa: std.mem.Allocator) error{OutOfMemory}!Link.FnCode;

/// One ISA's backend for one C convention, as the driver and the link tail call it.
pub const Backend = struct {
    /// The convention extern calls and C callback adapters follow; `lower` and `fits`
    /// are bound to it.
    c_abi: Target.CAbi,
    /// `Ir.Function` -> `Link.FnCode`; see `CodegenMir.lowerMir`.
    lower: LowerFn,
    /// Whether `func`'s fixed frame fits this backend's cap; see `FrameLayout.fits`.
    fits: FitsFn,
    relocs: Link.Patcher,
    hand_builtins: *const [runtime.hand_builtins.len]BuiltinFn,
    inst_count: *const fn (code: []const u8) usize,
};

/// The backend for `target`, or null when toy has no ISA module for its arch, or the
/// module does not implement its C convention, yet (the driver stops such a build with
/// R0021 before any work).
pub fn of(target: Target) ?*const Backend {
    for (backendsOf(target.arch)) |*b| if (b.c_abi == target.cAbi()) return b;
    return null;
}

fn backendsOf(arch: Target.Arch) []const Backend {
    return switch (arch) {
        .aarch64 => &CodegenMir.CodegenMir(@import("mir/aarch64/aarch64.zig")).backends,
        .x86_64 => &.{},
    };
}

/// Whether `func`'s fixed frame fits every backend's cap. The IR is cached once for all
/// targets, so a body kept for one target must lower on any.
pub fn fitsEveryBackend(
    gpa: std.mem.Allocator,
    func: *const Ir.Function,
    layouts: []const types.Layout,
    enum_layouts: []const types.EnumLayout,
) error{OutOfMemory}!bool {
    for (std.enums.values(Target.Arch)) |arch| {
        for (backendsOf(arch)) |*b| if (!try b.fits(gpa, func, layouts, enum_layouts)) return false;
    }
    return true;
}

/// Fail the build at compile time when `I` lacks a declaration the interface names.
pub fn check(comptime I: type) void {
    const decls = .{
        "Inst",         "Isel",          "Peephole", "Emit",      "reserved",  "allocatable",
        "callee_saved", "moveScratch",   "move",     "jump",      "spillLoad", "spillStore",
        "relocs",       "hand_builtins", "c_abis",   "instCount",
    };
    inline for (decls) |d| if (!@hasDecl(I, d)) @compileError(@typeName(I) ++ " is no ISA module: it has no `" ++ d ++ "`");
    inline for (.{ "caller_saved", "branchTarget", "setBranchTarget", "copyRegs", "operands", "callRegs" }) |d|
        if (!@hasDecl(I.Inst, d)) @compileError(@typeName(I) ++ ".Inst has no `" ++ d ++ "`");
    inline for (.{ "Func", "Input", "newFunc", "select", "addLiteral" }) |d|
        if (!@hasDecl(I.Isel, d)) @compileError(@typeName(I) ++ ".Isel has no `" ++ d ++ "`");
    inline for (.{ "Out", "encode" }) |d|
        if (!@hasDecl(I.Emit, d)) @compileError(@typeName(I) ++ ".Emit has no `" ++ d ++ "`");
    if (I.Isel.Func != @import("mir/Mir.zig").Function(I.Inst)) @compileError(@typeName(I) ++ ".Isel.Func is not Mir.Function(Inst)");
    const relocs: Link.Patcher = I.relocs;
    const builtins: [runtime.hand_builtins.len]BuiltinFn = I.hand_builtins;
    const c_abis: []const Target.CAbi = &I.c_abis;
    _ = relocs;
    _ = builtins;
    _ = c_abis;
}

test {
    _ = @import("mir/aarch64/aarch64.zig");
}

test "each target gets the backend for its C convention; x86_64 has no ISA module yet" {
    try std.testing.expectEqual(Target.CAbi.aapcs64_apple, of(Target.aarch64_macos).?.c_abi);
    try std.testing.expectEqual(Target.CAbi.aapcs64, of(Target.aarch64_linux).?.c_abi);
    try std.testing.expect(of(Target.x86_64_linux) == null);
}
