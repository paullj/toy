//! The parallel move resolver: a set of moves that happen at once (every source read
//! before any destination written), as a sequence of single moves. A move is ready when no
//! other pending move still reads its destination; when none is, the moves form cycles
//! through registers, and one is broken by parking a destination's old value in the
//! class's scratch register.
//!
//! Each value has one spill slot, so a set never moves slot to slot, and a slot is never
//! both written and read in one set: only registers can form a cycle.

const std = @import("std");
const Mir = @import("Mir.zig");

pub const Loc = union(enum) {
    reg: Mir.Reg,
    /// A spill slot, by the index `Frame.newSpill` gave it.
    slot: u32,

    pub fn eql(a: Loc, b: Loc) bool {
        return std.meta.eql(a, b);
    }
};

pub const Move = struct { dst: Loc, src: Loc, class: Mir.RegClass };

/// Append to `out` the single moves that perform `moves` in parallel, using `scratch` of a
/// move's class to break a cycle. `moves` is reordered and rewritten in place.
pub fn sequence(
    gpa: std.mem.Allocator,
    moves: *std.ArrayList(Move),
    scratch: *const fn (Mir.RegClass) Mir.Reg,
    out: *std.ArrayList(Move),
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < moves.items.len) {
        const m = moves.items[i];
        std.debug.assert(!(m.dst == .slot and m.src == .slot));
        if (m.dst.eql(m.src)) {
            _ = moves.swapRemove(i);
        } else i += 1;
    }
    while (moves.items.len > 0) {
        const ready = for (moves.items, 0..) |m, k| {
            const blocked = for (moves.items) |o| {
                if (o.src.eql(m.dst)) break true;
            } else false;
            if (!blocked) break k;
        } else null;
        if (ready) |k| {
            try out.append(gpa, moves.items[k]);
            _ = moves.orderedRemove(k);
            continue;
        }
        const m = moves.items[0];
        std.debug.assert(m.dst == .reg);
        const park: Loc = .{ .reg = scratch(m.class) };
        try out.append(gpa, .{ .dst = park, .src = m.dst, .class = m.class });
        for (moves.items) |*o| {
            if (o.src.eql(m.dst)) o.src = park;
        }
    }
}

const testing = std.testing;

fn testScratch(class: Mir.RegClass) Mir.Reg {
    return switch (class) {
        .gpr => Mir.Reg.gp(9),
        .fpr => Mir.Reg.fp(16),
    };
}

fn r(n: u32) Loc {
    return .{ .reg = Mir.Reg.gp(n) };
}

/// Run `seq` on a machine of named locations and check each `want` destination ends up
/// with the original value of its source.
fn simulate(moves: []const Move, seq: []const Move) !void {
    var vals: [64 + 8]u32 = undefined;
    for (&vals, 0..) |*v, k| v.* = @intCast(k);
    const idx = struct {
        fn of(l: Loc) usize {
            return switch (l) {
                .reg => |x| @intFromEnum(x),
                .slot => |s| 64 + s,
            };
        }
    };
    const before = vals;
    for (seq) |m| vals[idx.of(m.dst)] = vals[idx.of(m.src)];
    for (moves) |m| try testing.expectEqual(before[idx.of(m.src)], vals[idx.of(m.dst)]);
}

test "moves: a chain runs back to front, a swap goes through the scratch, slots never block" {
    const gpa = testing.allocator;
    const cases = [_][]const Move{
        // x1 <- x0, x2 <- x1: x2 must read x1 before x1 is overwritten.
        &.{ .{ .dst = r(1), .src = r(0), .class = .gpr }, .{ .dst = r(2), .src = r(1), .class = .gpr } },
        // swap
        &.{ .{ .dst = r(1), .src = r(0), .class = .gpr }, .{ .dst = r(0), .src = r(1), .class = .gpr } },
        // a 3-cycle plus a store of one of its registers and a reload into another register
        &.{
            .{ .dst = r(1), .src = r(0), .class = .gpr },
            .{ .dst = r(2), .src = r(1), .class = .gpr },
            .{ .dst = r(0), .src = r(2), .class = .gpr },
            .{ .dst = .{ .slot = 3 }, .src = r(2), .class = .gpr },
            .{ .dst = r(5), .src = .{ .slot = 1 }, .class = .gpr },
            .{ .dst = r(6), .src = r(6), .class = .gpr },
        },
    };
    for (cases) |c| {
        var moves: std.ArrayList(Move) = .empty;
        defer moves.deinit(gpa);
        try moves.appendSlice(gpa, c);
        var out: std.ArrayList(Move) = .empty;
        defer out.deinit(gpa);
        try sequence(gpa, &moves, &testScratch, &out);
        try simulate(c, out.items);
        for (out.items) |m| try testing.expect(!m.dst.eql(m.src));
    }
}
