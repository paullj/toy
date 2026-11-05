//! IR optimization stage: a small pass manager driving ir→ir transforms
//! between `lower` and `codegen`. Peer to `lower`/`codegen`; reachable through
//! the `toy_compiler` module (src/root.zig). The pipeline becomes
//! lex→parse→resolve→types→lower→OPT→codegen→link.
//!
//! PASSES (each its own file): fold, branch, dce, forward. They run behind this
//! manager's bounded fixpoint so fold→branch→forward→DCE cascade. `inline` runs once
//! before the fixpoint (`optimize`), since it needs callee IR the caller supplies, then
//! `mem2reg` once, so the fixpoint and the spliced bodies see locals as SSA values.
//!
//! MEMORY STRATEGY (no arena; in-place mutate + mark-then-compact-once)
//! A block's owned slices are freed once by `Ir.Block.freeOwned` (the single
//! definition of that set); `Ir.Function.deinit` frees every block through it,
//! then `blocks`, `params`, `slots`, `values`, `literals.bytes`, `literals`.
//! Every transform MUST preserve that invariant so deinit neither leaks nor
//! double-frees:
//!   (a) FOLD replaces an `Instr.op` with `.iconst`/`.bconst` IN PLACE. Neither
//!       the new op nor the displaced add/icmp/neg/bnot owns a nested slice, so
//!       this is leak-free and allocation-free.
//!   (b) BRANCH-FOLD replaces a `.cond_br` (argless, owns nothing) with
//!       `.br{ dest, args = &.{} }` — a static empty slice; deinit's `gpa.free`
//!       no-ops on a 0-len slice (freeing a NON-empty static slice is the bug).
//!   (c) UNREACHABLE-ELIM frees each DROPPED block via `Block.freeOwned` (once),
//!       then compacts survivors with one alloc-copy-free-old. Per-block instr
//!       DCE compacts with one alloc-copy-free-old too.
//!   (d) VALUE PRUNING rebuilds `func.values` (alloc-copy-free-old) and renumbers
//!       EVERY ValueId site through the shared `walk.zig` helper (so liveness and
//!       remap can't drift). `entry`/`exit` are BlockIds (remapped by the block
//!       remap, never the value remap). Slots are left stable.
//! Use `std.testing.allocator` in every pass unit test to catch leak/double-free.

const std = @import("std");
const Ir = @import("../ir/Ir.zig");

pub const arith = @import("arith.zig");
pub const walk = @import("walk.zig");
pub const fold = @import("fold.zig");
pub const branch = @import("branch.zig");
pub const dce = @import("dce.zig");
pub const forward = @import("forward.zig");
pub const inliner = @import("inline.zig");
pub const mem2reg = @import("mem2reg.zig");

/// The passes `--opt`/`--no-opt` name. The fixpoint loop runs the first four each round
/// in declaration order; `inline` and then `mem2reg` run once before it (`optimize`).
pub const Pass = enum(u3) { fold, branch, forward, dce, @"inline", mem2reg };

/// Which passes are enabled. A `packed struct` over a fixed `u8` so its `bits()`
/// is a stable wire byte for the codegen fingerprint mix — toggling `-O` lands on
/// a different cache key. Field order is locked to the `Pass` enum order and the
/// `comptime` block below fails the build on any divergence (a reorder would
/// silently change `bits()`, hence cache keys).
pub const Config = packed struct(u8) {
    fold: bool = false,
    branch: bool = false,
    forward: bool = false,
    dce: bool = false,
    @"inline": bool = false,
    mem2reg: bool = false,
    _pad: u2 = 0,

    pub const O0: Config = .{};
    pub const O1: Config = .{ .fold = true, .branch = true, .forward = true, .dce = true, .@"inline" = true, .mem2reg = true };

    pub fn has(self: Config, p: Pass) bool {
        return switch (p) {
            .fold => self.fold,
            .branch => self.branch,
            .forward => self.forward,
            .dce => self.dce,
            .@"inline" => self.@"inline",
            .mem2reg => self.mem2reg,
        };
    }

    pub fn set(self: *Config, p: Pass, on: bool) void {
        switch (p) {
            .fold => self.fold = on,
            .branch => self.branch = on,
            .forward => self.forward = on,
            .dce => self.dce = on,
            .@"inline" => self.@"inline" = on,
            .mem2reg => self.mem2reg = on,
        }
    }

    /// The fixed wire byte folded into the codegen fingerprint. `_pad` is always
    /// 0 so this is deterministic.
    pub fn bits(self: Config) u8 {
        return @bitCast(self);
    }

    pub fn any(self: Config) bool {
        return self.fold or self.branch or self.forward or self.dce or self.@"inline" or self.mem2reg;
    }

    comptime {
        // Pin the wire-byte layout: pass `p` MUST occupy bit `@intFromEnum(p)` in
        // `bits()`. Setting only `p` must light exactly that bit; a field-order slip
        // (or a Pass/Config order divergence) fails the build instead of silently
        // changing a codegen cache key.
        for (@typeInfo(Pass).@"enum".fields) |f| {
            const p: Pass = @enumFromInt(f.value);
            var c: Config = .{};
            c.set(p, true);
            if (c.bits() != (@as(u8, 1) << @intFromEnum(p)))
                @compileError("Opt.Config field order must match the Pass enum order");
        }
    }
};

/// Per-pass counters, summed deterministically across functions and fixpoint
/// rounds (fixed field order). Surfaced via `--opt-stats`.
pub const Stats = struct {
    consts_folded: usize = 0,
    branches_folded: usize = 0,
    blocks_removed: usize = 0,
    instrs_dced: usize = 0,
    values_pruned: usize = 0,
    loads_forwarded: usize = 0,
    calls_inlined: usize = 0,
    slots_promoted: usize = 0,
    rounds: usize = 0,
    ir_instrs_before: usize = 0,
    ir_instrs_after: usize = 0,

    pub fn add(self: *Stats, o: Stats) void {
        self.consts_folded += o.consts_folded;
        self.branches_folded += o.branches_folded;
        self.blocks_removed += o.blocks_removed;
        self.instrs_dced += o.instrs_dced;
        self.values_pruned += o.values_pruned;
        self.loads_forwarded += o.loads_forwarded;
        self.calls_inlined += o.calls_inlined;
        self.slots_promoted += o.slots_promoted;
        self.rounds += o.rounds;
        self.ir_instrs_before += o.ir_instrs_before;
        self.ir_instrs_after += o.ir_instrs_after;
    }
};

const PassFn = *const fn (std.mem.Allocator, *Ir.Function, *Stats) error{OutOfMemory}!bool;

/// Dispatch table: Pass → its transform. Indexed by `@intFromEnum(Pass)`.
fn dispatch(p: Pass) PassFn {
    return switch (p) {
        .fold => fold.run,
        .branch => branch.run,
        .forward => forward.run,
        .dce => dce.run,
        .@"inline", .mem2reg => unreachable,
    };
}

/// Bounded fixpoint cap; documented in the locked design (≤8 rounds).
pub const MAX_ROUNDS = 8;

/// Run the enabled fixpoint passes on `func` in-place to a bounded fixpoint. Records the
/// dual-metric IR instruction count (before/after) and per-pass counters into
/// `stats`. With no passes enabled this is a pure no-op (the O0==O1 scaffold gate).
pub fn run(gpa: std.mem.Allocator, func: *Ir.Function, cfg: Config, stats: *Stats) error{OutOfMemory}!void {
    return optimize(gpa, func, cfg, null, stats);
}

/// `run`, after inlining the callees `callees` hands over when `cfg` enables `inline`.
/// The fixpoint then folds across the spliced bodies.
pub fn optimize(gpa: std.mem.Allocator, func: *Ir.Function, cfg: Config, callees: ?inliner.Lookup, stats: *Stats) error{OutOfMemory}!void {
    stats.ir_instrs_before = Ir.instrCount(func);
    defer stats.ir_instrs_after = Ir.instrCount(func);
    defer std.debug.assert(func.exit == Ir.none_block or func.exit < func.blocks.len);

    if (cfg.@"inline") if (callees) |l| {
        _ = try inliner.run(gpa, func, l, inliner.budget, stats);
    };
    if (cfg.mem2reg) _ = try mem2reg.run(gpa, func, stats);
    try fixpoint(gpa, func, cfg, stats);

    // Last, so a spliced callee's size never decides whether this unit is inlined, and
    // its args arrive folded.
    if (cfg.@"inline") if (callees) |l| if (l.spliced()) |sl| {
        if (!try inliner.splice(gpa, func, sl, stats)) return;
        if (cfg.mem2reg) _ = try mem2reg.run(gpa, func, stats);
        try fixpoint(gpa, func, cfg, stats);
    };
}

/// The fold, branch, forward and DCE passes `cfg` enables, to a bounded fixpoint.
fn fixpoint(gpa: std.mem.Allocator, func: *Ir.Function, cfg: Config, stats: *Stats) error{OutOfMemory}!void {
    var fix = cfg;
    fix.@"inline" = false;
    fix.mem2reg = false;
    if (!fix.any()) return;

    // Count rounds actually executed (a round is one full pass over the enabled
    // passes). The loop runs at least once; the final round that reports no change
    // still counts as executed.
    var rounds: usize = 0;
    while (rounds < MAX_ROUNDS) {
        rounds += 1;
        var changed = false;
        inline for (.{ .fold, .branch, .forward, .dce }) |p| {
            if (fix.has(p)) {
                const c = try dispatch(p)(gpa, func, stats);
                changed = changed or c;
            }
        }
        if (!changed) break;
    }
    stats.rounds += rounds;
}

test {
    _ = arith;
    _ = walk;
    _ = fold;
    _ = branch;
    _ = dce;
    _ = forward;
    _ = inliner;
    _ = mem2reg;
}

test "Config.bits is a stable wire byte; O0 != O1" {
    try std.testing.expectEqual(@as(u8, 0), Config.O0.bits());
    try std.testing.expect(Config.O1.bits() != Config.O0.bits());
    // Individual toggles produce distinct bytes.
    var c: Config = .{};
    c.set(.fold, true);
    try std.testing.expect(c.bits() != Config.O0.bits());
    try std.testing.expect(c.has(.fold) and !c.has(.dce));
}

test "run with no passes is a no-op recording instr count" {
    const gpa = std.testing.allocator;
    var blocks = try gpa.alloc(Ir.Block, 1);
    blocks[0] = .{
        .params = try gpa.alloc(Ir.ValueId, 0),
        .instrs = try gpa.alloc(Ir.Instr, 0),
        .term = .{ .ret = .none },
    };
    var func = Ir.Function{
        .name = .{ .kind = .user_fn, .name = "main" },
        .params = try gpa.alloc(Ir.SlotId, 0),
        .ret_type = Ir.Type.unit,
        .slots = try gpa.alloc(Ir.Slot, 0),
        .values = try gpa.alloc(Ir.ValueDef, 0),
        .blocks = blocks,
        .entry = 0,
        .exit = 0,
    };
    defer func.deinit(gpa);

    var st: Stats = .{};
    try run(gpa, &func, .O0, &st);
    try std.testing.expectEqual(@as(usize, 0), st.ir_instrs_before);
    try std.testing.expectEqual(@as(usize, 0), st.ir_instrs_after);
    try std.testing.expectEqual(@as(usize, 0), st.rounds);
}
