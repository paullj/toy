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
//!   * The two intrinsics core/rt is written over, which `Isel` selects from IR ops:
//!     `Ir.Op.frame_addr`, the current fn's frame record, and `Ir.Op.text_base`, the
//!     runtime address of the text's first byte. The rest of the runtime (panic and its
//!     backtrace, the collector's stack walk, the str builders) is toy code in core/rt
//!     over them, so a new ISA writes no runtime of its own.
//!   * `c_abis` — the C calling conventions (`Target.CAbi`) its selector places
//!     arguments for.
//!   * `abi` — its calling-convention and frame facts, which the target-neutral placement
//!     walk (`abi/Abi.zig`) and frame layout (`frame/FrameLayout.zig`) read:
//!     `facts(c_abi)`, a `FrameLayout.Facts` per C convention (toy's and the C
//!     convention's `Abi.Desc`, the saved-register area between a frame and its caller's
//!     stack arguments, the stack alignment, the frame and incoming-offset limits);
//!     and the registers the placement indices name: `gpr_args`, `fpr_args`, `gpr_rets`
//!     (at least 2, for a reg pair), `fpr_rets` (at least 4 under an `hfa` convention)
//!     and `sret_reg` (`gpr_args[0]` under `sret_uses_gpr`).
//!   * `instCount(code)` — how many instructions encoded `code` holds, for
//!     `--opt-stats`.
//!   * `entryStub(gpa, main)` — the fn the loader calls in `main`'s place with argc and
//!     argv in its first two argument registers: it stores them in the control block
//!     words core reads (#60 T10), then jumps to `main`, which keeps toy's own no-param
//!     convention so toy code may call it too.
//!   * `startStub(gpa, entry)` — the `_start` of a target whose C library starts the
//!     process (glibc, #60 T9): it passes `entry` and the kernel's arguments to
//!     `__libc_start_main`. A target whose loader calls the entry itself (dyld) never
//!     asks for it.
//!
//! `Backend` is what the rest of the compiler holds: one per ISA and C convention, picked
//! by `of` from the target.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");
const Link = @import("../link/Link.zig");
const types = @import("../types.zig");
const Target = @import("../Target.zig");
const CodegenMir = @import("CodegenMir.zig");
const Abi = @import("abi/Abi.zig");
const FrameLayout = @import("frame/FrameLayout.zig");
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
    inst_count: *const fn (code: []const u8) usize,
    entry_stub: StubFn,
    start_stub: StubFn,
};

pub const StubFn = *const fn (gpa: std.mem.Allocator, callee: Link.SymName) error{OutOfMemory}!Link.FnCode;

/// The backend for `target`, or null when toy has no ISA module for its arch, or the
/// module does not implement its C convention, yet (the driver stops such a build with
/// R0021 before any work).
pub fn of(target: Target) ?*const Backend {
    for (backendsOf(target.arch)) |*b| if (b.c_abi == target.cAbi()) return b;
    return null;
}

fn moduleOf(comptime arch: Target.Arch) ?type {
    return switch (arch) {
        .aarch64 => @import("mir/aarch64/aarch64.zig"),
        .x86_64 => null,
    };
}

fn backendsOf(arch: Target.Arch) []const Backend {
    switch (arch) {
        inline else => |a| return if (comptime moduleOf(a)) |I| &CodegenMir.CodegenMir(I).backends else &.{},
    }
}

/// The largest frame every ISA addresses. The checker caps every struct and enum at it
/// (T0077): a value of one has to fit in a frame, and the IR is shared by all targets.
pub const max_frame: u32 = blk: {
    var m: u32 = std.math.maxInt(u32);
    for (std.enums.values(Target.Arch)) |a| if (moduleOf(a)) |I| {
        for (I.c_abis) |c_abi| m = @min(m, I.abi.facts(c_abi).max_frame);
    };
    break :blk m;
};

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
        "Inst",         "Isel",        "Peephole",  "Emit", "reserved",  "allocatable",
        "callee_saved", "moveScratch", "move",      "jump", "spillLoad", "spillStore",
        "relocs",       "c_abis",      "instCount", "abi",  "startStub", "entryStub",
    };
    inline for (decls) |d| if (!@hasDecl(I, d)) @compileError(@typeName(I) ++ " is no ISA module: it has no `" ++ d ++ "`");
    inline for (.{ "caller_saved", "branchTarget", "setBranchTarget", "copyRegs", "operands", "callRegs" }) |d|
        if (!@hasDecl(I.Inst, d)) @compileError(@typeName(I) ++ ".Inst has no `" ++ d ++ "`");
    inline for (.{ "Func", "Input", "newFunc", "select", "addLiteral" }) |d|
        if (!@hasDecl(I.Isel, d)) @compileError(@typeName(I) ++ ".Isel has no `" ++ d ++ "`");
    inline for (.{ "Out", "encode" }) |d|
        if (!@hasDecl(I.Emit, d)) @compileError(@typeName(I) ++ ".Emit has no `" ++ d ++ "`");
    if (I.Isel.Func != @import("mir/Mir.zig").Function(I.Inst)) @compileError(@typeName(I) ++ ".Isel.Func is not Mir.Function(Inst)");
    inline for (.{ "facts", "gpr_args", "fpr_args", "gpr_rets", "fpr_rets", "sret_reg" }) |d|
        if (!@hasDecl(I.abi, d)) @compileError(@typeName(I) ++ ".abi has no `" ++ d ++ "`");
    const Reg = @import("mir/Mir.zig").Reg;
    const sret_reg: Reg = I.abi.sret_reg;
    const gpr_args: []const Reg = &I.abi.gpr_args;
    const fpr_args: []const Reg = &I.abi.fpr_args;
    const gpr_rets: []const Reg = &I.abi.gpr_rets;
    const fpr_rets: []const Reg = &I.abi.fpr_rets;
    // Isel returns a 2-word reg pair in gpr_rets[0..2] and an HFA in fpr_rets[0..4].
    if (gpr_rets.len < 2) @compileError(@typeName(I) ++ ".abi: `gpr_rets` holds fewer than 2 registers");
    for (I.c_abis) |c_abi| {
        const f: FrameLayout.Facts = I.abi.facts(c_abi);
        for ([_]Abi.Desc{ f.toy, f.c }) |d| {
            if (d.gprs != gpr_args.len or d.fprs != fpr_args.len)
                @compileError(@typeName(I) ++ ".abi: a convention's register counts differ from its register lists");
            if (d.hfa and fpr_rets.len < 4) @compileError(@typeName(I) ++ ".abi: an HFA convention needs 4 `fpr_rets`");
            // The walk reserves GPR argument 0 for the buffer while the prologue and call
            // site name `sret_reg`; they must be the same register.
            if (d.sret_uses_gpr and sret_reg != gpr_args[0]) @compileError(@typeName(I) ++ ".abi: `sret_uses_gpr` but `sret_reg` is not `gpr_args[0]`");
        }
        if (!std.math.isPowerOfTwo(f.stack_align)) @compileError(@typeName(I) ++ ".abi: the stack alignment is not a power of two");
    }
    const relocs: Link.Patcher = I.relocs;
    const c_abis: []const Target.CAbi = &I.c_abis;
    const entry_stub: StubFn = I.entryStub;
    const start_stub: StubFn = I.startStub;
    _ = entry_stub;
    _ = start_stub;
    _ = relocs;
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
