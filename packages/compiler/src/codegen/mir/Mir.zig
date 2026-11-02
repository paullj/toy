//! MIR: machine IR, the backend between `Ir` and machine code (#199, epic #38).
//!
//! PIPELINE (per fn): `Ir.Function` -> instruction selection (a target's `Isel`) -> MIR on
//! virtual registers -> register allocator -> MIR on physical registers -> encoder (a
//! target's `Emit`) -> `Link.FnCode`. Only the selector and the encoder know the target; the
//! data model here and the allocators are written against the small interface below, so a
//! second target (#60) adds a selector, an `Inst` type and an encoder, nothing else.
//!
//! DATA MODEL. A `Function(Inst)` is a list of blocks, each a list of target instructions.
//! Block 0 is the prologue block (stack-map clearing, the sret save, incoming params); IR
//! block `i` is MIR block `i + 1`, laid out in that order. An instruction names its
//! registers as `Reg`s: a physical register of either file or a virtual register (`VReg`,
//! with a class and an optional spill home). It reports them through `Inst.operands`, each
//! a use or a def, and a call also reports, through `Inst.callRegs`, the physical registers
//! it reads (arguments), the ones it writes (results) and its clobber set. Every instruction carries the source line
//! of the IR instruction it came from, and the encoder builds the DWARF line table from
//! those lines, so allocator-inserted code takes the line of the instruction it serves.
//! Memory operands are `Mem`: a register or a frame object (`FrameRef`) plus a byte offset.
//! Frame objects are symbolic until encoding: IR slots, the cells of IR values, allocator
//! spill slots, the outgoing and incoming argument areas. `Frame` turns them into offsets.
//!
//! ALLOCATOR INTERFACE. An allocator is `run(gpa, *Function(Inst), *Frame)`: it rewrites
//! every virtual register to a physical one, adding spill code, and takes the stack slots it
//! needs from `Frame.newSpill`. Afterwards no virtual register remains (`allPhysical`). The
//! target supplies the allocator with its scratch registers per class and with the load and
//! store instructions for a spill slot (`SpillAll` names the exact declarations). The first
//! allocator, `SpillAll`, keeps every virtual register in its home slot and loads it into a
//! scratch register around each instruction: the reference oracle the next ones are checked
//! against. #200 adds Wimmer-Franz linear scan behind the same `run`, using the liveness the
//! operands and clobber sets give.
//!
//! SAFEPOINTS AND STACK MAPS. A call is a safepoint: the collector may run inside it and
//! reads the caller's roots from the frame through the fn's stack map, a list of frame
//! offsets. Today the map is `FrameLayout.collectRoots`, the same one the spill backend
//! emits: every IR value's virtual register has that IR value's cell as its home, and
//! SpillAll stores each def to its home at once, so a live reference is always in the cell
//! the map names. Virtual registers the selector makes for its own temporaries have no
//! home and must never be live across a call (`tempsStayLocal` checks it), so no reference
//! hides in one at a safepoint. For #200, a reference live across a call must sit in a
//! stack slot at the call (calls clobber every allocatable register for references), and
//! the allocator reports those slots to build a map per safepoint instead of the per-fn one.
//! A loop back edge carries a `safepoint_poll` placeholder where a concurrent collector's
//! poll goes (#83). It encodes to nothing now.
//!
//! FRAME. The frame keeps the x29 chain in every profile (backtraces, the GC walk and
//! profilers follow it), and `sp` stays fixed after the prologue, so a callee's `x29 + 16`
//! is the caller's `sp`, which the collector's frame walk relies on. Its fixed part is the
//! spill backend's `FrameLayout` (outgoing args, slots, IR value cells, sret save); spill
//! slots follow it. Once #200 keeps values in registers, value cells become spill slots
//! only for values that need one.

const std = @import("std");
const Ir = @import("../../ir/Ir.zig");
const FrameLayout = @import("../frame/FrameLayout.zig");

pub const RegClass = enum(u1) { gpr, fpr };

/// A physical register (32 per file) or a virtual register.
pub const Reg = enum(u32) {
    _,

    const fp_base: u32 = 32;
    const virt_base: u32 = 64;

    pub fn gp(n: u32) Reg {
        std.debug.assert(n < 32);
        return @enumFromInt(n);
    }
    pub fn fp(n: u32) Reg {
        std.debug.assert(n < 32);
        return @enumFromInt(fp_base + n);
    }
    pub fn virt(i: u32) Reg {
        return @enumFromInt(virt_base + i);
    }
    pub fn isVirtual(r: Reg) bool {
        return @intFromEnum(r) >= virt_base;
    }
    /// A virtual register's index into `Function.vregs`.
    pub fn index(r: Reg) u32 {
        std.debug.assert(r.isVirtual());
        return @intFromEnum(r) - virt_base;
    }
    /// A physical register's number within its file.
    pub fn hw(r: Reg) u32 {
        std.debug.assert(!r.isVirtual());
        return @intFromEnum(r) % fp_base;
    }
    pub fn physClass(r: Reg) RegClass {
        std.debug.assert(!r.isVirtual());
        return if (@intFromEnum(r) >= fp_base) .fpr else .gpr;
    }
};

/// A set of physical registers, bit `n` for `Reg` `n`.
pub const RegSet = u64;

pub fn regBit(r: Reg) RegSet {
    return @as(RegSet, 1) << @intCast(@intFromEnum(r));
}

pub const VReg = struct {
    class: RegClass,
    /// The frame cell the register lives in when spilled, fixed by the selector when the
    /// stack map names it (an IR value's cell). A temporary has none; the allocator gives
    /// it a spill slot if it needs one.
    home: ?FrameRef = null,
};

/// A frame object, resolved to an offset only by the encoder through `Frame`.
pub const FrameRef = union(enum) {
    slot: Ir.SlotId,
    /// The cell of an IR value: a scalar's spill home, or an aggregate value's bytes.
    value: Ir.ValueId,
    spill: u32,
    sret_save,
    /// Where an extern call or a C callback builds the C images of extern structs.
    c_scratch,
    /// The bottom of the frame, where a call's stack arguments go.
    outgoing,
    /// The caller's stack arguments, above the saved x29/x30.
    incoming,
    /// A word at this offset of the fixed layout: a stack-map word the prologue clears.
    layout: u32,
};

pub const Mem = struct {
    base: Base,
    off: u32 = 0,

    pub const Base = union(enum) { reg: Reg, frame: FrameRef };

    pub fn frame(ref: FrameRef, off: u32) Mem {
        return .{ .base = .{ .frame = ref }, .off = off };
    }
    pub fn reg(r: Reg, off: u32) Mem {
        return .{ .base = .{ .reg = r }, .off = off };
    }
};

/// One register an instruction names, for allocators and checks.
pub const Operand = struct {
    reg: *Reg,
    kind: Kind,

    pub const Kind = enum { use, def };
};

pub const max_operands = 4;

/// The fixed physical registers of a call, which its operands do not show: what it reads
/// (arguments), what it writes (results) and what it may overwrite (a superset of `defs`).
pub const CallRegs = struct { uses: RegSet, defs: RegSet, clobbers: RegSet };

/// A fn in MIR form over a target's `Inst`, which provides `operands(*Inst, *[max_operands]
/// Operand) []Operand` and `callRegs(Inst) ?CallRegs` (null for an instruction that is not
/// a call).
pub fn Function(comptime Inst: type) type {
    return struct {
        const Self = @This();

        blocks: []Block,
        vregs: std.ArrayList(VReg) = .empty,

        pub const Block = struct {
            insts: std.ArrayList(Inst) = .empty,
        };

        pub fn init(gpa: std.mem.Allocator, n_blocks: usize) error{OutOfMemory}!Self {
            const blocks = try gpa.alloc(Block, n_blocks);
            for (blocks) |*b| b.* = .{};
            return .{ .blocks = blocks };
        }

        pub fn deinit(f: *Self, gpa: std.mem.Allocator) void {
            for (f.blocks) |*b| b.insts.deinit(gpa);
            gpa.free(f.blocks);
            f.vregs.deinit(gpa);
            f.* = undefined;
        }

        pub fn newVReg(f: *Self, gpa: std.mem.Allocator, class: RegClass, home: ?FrameRef) error{OutOfMemory}!Reg {
            const i: u32 = @intCast(f.vregs.items.len);
            try f.vregs.append(gpa, .{ .class = class, .home = home });
            return Reg.virt(i);
        }

        pub fn classOf(f: *const Self, r: Reg) RegClass {
            return if (r.isVirtual()) f.vregs.items[r.index()].class else r.physClass();
        }

        /// No virtual register is left: the allocator's postcondition.
        pub fn allPhysical(f: *Self) bool {
            for (f.blocks) |*b| for (b.insts.items) |*inst| {
                var buf: [max_operands]Operand = undefined;
                for (inst.operands(&buf)) |o| if (o.reg.*.isVirtual()) return false;
            };
            return true;
        }

        /// Whether an instruction names a physical register in `set`: the selector must
        /// leave the allocator's and the encoder's scratch registers alone.
        pub fn namesAny(f: *Self, set: RegSet) bool {
            for (f.blocks) |*b| for (b.insts.items) |*inst| {
                var buf: [max_operands]Operand = undefined;
                for (inst.operands(&buf)) |o| {
                    if (!o.reg.*.isVirtual() and regBit(o.reg.*) & set != 0) return true;
                }
            };
            return false;
        }

        /// Physical registers flow as the call constraints say: an instruction reads one only
        /// after something in its block wrote it (a call's `defs` included), every argument
        /// register written before a call is in its `uses`, and a call's clobbers kill what
        /// it does not define. Registers in `block_in` (those no call clobbers) may be read
        /// anywhere, and block 0 may read every register (the incoming arguments).
        pub fn callRegsAgree(f: *Self, block_in: RegSet) bool {
            for (f.blocks, 0..) |*b, bi| {
                var avail: RegSet = if (bi == 0) ~@as(RegSet, 0) else block_in;
                // Written in this block and not yet read.
                var pending: RegSet = 0;
                for (b.insts.items) |*inst| {
                    var buf: [max_operands]Operand = undefined;
                    const ops = inst.operands(&buf);
                    for (ops) |o| {
                        if (o.kind != .use or o.reg.*.isVirtual()) continue;
                        if (avail & regBit(o.reg.*) == 0) return false;
                        pending &= ~regBit(o.reg.*);
                    }
                    if (inst.callRegs()) |c| {
                        if (c.uses & ~avail != 0) return false;
                        if (pending & c.clobbers & ~c.uses != 0) return false;
                        avail = (avail & ~c.clobbers) | c.defs;
                        pending &= ~c.clobbers;
                    }
                    for (ops) |o| {
                        if (o.kind != .def or o.reg.*.isVirtual()) continue;
                        avail |= regBit(o.reg.*);
                        pending |= regBit(o.reg.*);
                    }
                }
            }
            return true;
        }

        /// Every homeless virtual register is defined and used inside one block with no
        /// call in between, so it never holds a reference across a safepoint the stack map
        /// cannot see.
        pub fn tempsStayLocal(f: *Self, gpa: std.mem.Allocator) error{OutOfMemory}!bool {
            // Per vreg: the block it was defined in, and whether a call has passed since.
            const def_block = try gpa.alloc(u32, f.vregs.items.len);
            defer gpa.free(def_block);
            const crossed = try gpa.alloc(bool, f.vregs.items.len);
            defer gpa.free(crossed);
            @memset(def_block, std.math.maxInt(u32));
            @memset(crossed, false);
            var live: std.ArrayList(u32) = .empty;
            defer live.deinit(gpa);
            for (f.blocks, 0..) |*b, bi| {
                live.clearRetainingCapacity();
                for (b.insts.items) |*inst| {
                    var buf: [max_operands]Operand = undefined;
                    const ops = inst.operands(&buf);
                    for (ops) |o| {
                        if (o.kind != .use or !o.reg.*.isVirtual()) continue;
                        const v = o.reg.*.index();
                        if (f.vregs.items[v].home != null) continue;
                        if (def_block[v] != bi or crossed[v]) return false;
                    }
                    if (inst.callRegs() != null) for (live.items) |v| {
                        crossed[v] = true;
                    };
                    for (ops) |o| {
                        if (o.kind != .def or !o.reg.*.isVirtual()) continue;
                        const v = o.reg.*.index();
                        if (f.vregs.items[v].home != null) continue;
                        if (def_block[v] == std.math.maxInt(u32)) try live.append(gpa, v);
                        def_block[v] = @intCast(bi);
                        crossed[v] = false;
                    }
                }
            }
            return true;
        }
    };
}

/// The frame: the fixed `FrameLayout` part, then the allocator's spill slots, 8 bytes each.
pub const Frame = struct {
    layout: FrameLayout,
    spills: u32 = 0,

    pub fn deinit(f: *Frame, gpa: std.mem.Allocator) void {
        f.layout.deinit(gpa);
        f.* = undefined;
    }

    pub fn newSpill(f: *Frame) FrameRef {
        f.spills += 1;
        return .{ .spill = f.spills - 1 };
    }

    /// The bytes the prologue opens, 16-aligned.
    pub fn size(f: *const Frame) u64 {
        return (@as(u64, f.layout.frame) + @as(u64, f.spills) * 8 + 15) / 16 * 16;
    }

    /// The sp-relative offset of a frame object. `incoming` is x29-relative instead: the
    /// encoder handles it.
    pub fn spOffset(f: *const Frame, ref: FrameRef) u32 {
        return switch (ref) {
            .slot => |s| f.layout.slot_off[s],
            .value => |v| f.layout.value_off[v],
            .spill => |i| f.layout.frame + i * 8,
            .sret_save => f.layout.sret_save_off,
            .c_scratch => f.layout.c_scratch_off,
            .outgoing => 0,
            .layout => |off| off,
            .incoming => unreachable,
        };
    }
};

const testing = std.testing;

test "Reg: physical and virtual registers keep their file and number" {
    try testing.expectEqual(@as(u32, 9), Reg.gp(9).hw());
    try testing.expectEqual(RegClass.gpr, Reg.gp(9).physClass());
    try testing.expectEqual(@as(u32, 16), Reg.fp(16).hw());
    try testing.expectEqual(RegClass.fpr, Reg.fp(16).physClass());
    try testing.expect(!Reg.fp(31).isVirtual());
    try testing.expect(Reg.virt(0).isVirtual());
    try testing.expectEqual(@as(u32, 7), Reg.virt(7).index());
    try testing.expect(regBit(Reg.gp(0)) != regBit(Reg.fp(0)));
}
