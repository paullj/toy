//! A live interval: where one virtual register, or one piece of it after a split, is live,
//! as sorted disjoint half-open ranges of positions (the gaps are lifetime holes), with the
//! positions that need it in a register. A physical register's fixed interval has the same
//! shape: where an instruction pins it.

const std = @import("std");
const Mir = @import("Mir.zig");

pub const Range = struct { from: u32, to: u32 };

const Interval = @This();

/// The virtual register, or `fixed` for a physical register's interval.
vreg: u32,
ranges: std.ArrayList(Range) = .empty,
/// Positions of the instructions that read (at their position) or write (one after) it,
/// ascending. Every one needs the value in a register.
uses: std.ArrayList(u32) = .empty,
reg: ?Mir.Reg = null,
/// The piece lives in its register's spill slot.
spilled: bool = false,

pub const fixed = std.math.maxInt(u32);

pub fn deinit(it: *Interval, gpa: std.mem.Allocator) void {
    it.ranges.deinit(gpa);
    it.uses.deinit(gpa);
    it.* = undefined;
}

pub fn isEmpty(it: *const Interval) bool {
    return it.ranges.items.len == 0;
}

pub fn start(it: *const Interval) u32 {
    return it.ranges.items[0].from;
}

pub fn end(it: *const Interval) u32 {
    return it.ranges.items[it.ranges.items.len - 1].to;
}

/// The index of the first range that ends after `pos`. Allocation asks about positions
/// that only grow, but from many intervals at once, and a fixed interval has a range per
/// call: a search, not a walk from the front, keeps a long fn linear-logarithmic.
fn rangeFrom(it: *const Interval, pos: u32) usize {
    return std.sort.upperBound(Range, it.ranges.items, pos, struct {
        fn order(p: u32, r: Range) std.math.Order {
            return std.math.order(p, r.to);
        }
    }.order);
}

pub fn covers(it: *const Interval, pos: u32) bool {
    const k = it.rangeFrom(pos);
    return k < it.ranges.items.len and it.ranges.items[k].from <= pos;
}

/// The first position at or after `from` both intervals cover, if any.
pub fn nextIntersection(a: *const Interval, b: *const Interval, from: u32) ?u32 {
    var i = a.rangeFrom(from);
    var j = b.rangeFrom(from);
    const ra = a.ranges.items;
    const rb = b.ranges.items;
    while (i < ra.len and j < rb.len) {
        const lo = @max(@max(ra[i].from, rb[j].from), from);
        const hi = @min(ra[i].to, rb[j].to);
        if (lo < hi) return lo;
        if (ra[i].to <= rb[j].to) i += 1 else j += 1;
    }
    return null;
}

/// The first use at or after `pos`, if any.
pub fn firstUseFrom(it: *const Interval, pos: u32) ?u32 {
    const k = it.useFrom(pos);
    return if (k < it.uses.items.len) it.uses.items[k] else null;
}

pub fn useFrom(it: *const Interval, pos: u32) usize {
    return std.sort.lowerBound(u32, it.uses.items, pos, struct {
        fn order(p: u32, u: u32) std.math.Order {
            return std.math.order(p, u);
        }
    }.order);
}

/// The first use in `[lo, hi]`, if any.
pub fn useIn(it: *const Interval, lo: u32, hi: u32) ?u32 {
    const u = it.firstUseFrom(lo) orelse return null;
    return if (u <= hi) u else null;
}

/// Split at `pos`: `it` keeps what lies before it, and the returned piece (same register
/// unassigned) takes the rest. `pos` must fall strictly inside the interval.
pub fn split(it: *Interval, gpa: std.mem.Allocator, pos: u32) error{OutOfMemory}!Interval {
    std.debug.assert(pos > it.start() and pos < it.end());
    var child: Interval = .{ .vreg = it.vreg };
    errdefer child.deinit(gpa);
    const rs = it.ranges.items;
    const k = it.rangeFrom(pos);
    if (rs[k].from < pos) {
        try child.ranges.append(gpa, .{ .from = pos, .to = rs[k].to });
        try child.ranges.appendSlice(gpa, rs[k + 1 ..]);
        rs[k].to = pos;
        it.ranges.shrinkRetainingCapacity(k + 1);
    } else {
        try child.ranges.appendSlice(gpa, rs[k..]);
        it.ranges.shrinkRetainingCapacity(k);
    }
    const u = it.useFrom(pos);
    try child.uses.appendSlice(gpa, it.uses.items[u..]);
    it.uses.shrinkRetainingCapacity(u);
    return child;
}

/// Builders for a backward walk over the code, which meets ranges and uses latest first;
/// `finish` puts them in order.
pub fn addRangeBackward(it: *Interval, gpa: std.mem.Allocator, from: u32, to: u32) error{OutOfMemory}!void {
    const rs = it.ranges.items;
    if (rs.len > 0 and rs[rs.len - 1].from <= to) {
        const last = &rs[rs.len - 1];
        last.from = @min(last.from, from);
        last.to = @max(last.to, to);
        return;
    }
    try it.ranges.append(gpa, .{ .from = from, .to = to });
}

/// A def at `pos`: the value is born there, so the range the walk opened at the block's
/// start begins at `pos` instead, or a dead def gets the one position it writes.
pub fn defBackward(it: *Interval, gpa: std.mem.Allocator, pos: u32, live: bool) error{OutOfMemory}!void {
    if (live) {
        it.ranges.items[it.ranges.items.len - 1].from = pos;
    } else try it.addRangeBackward(gpa, pos, pos + 1);
}

pub fn addUseBackward(it: *Interval, gpa: std.mem.Allocator, pos: u32) error{OutOfMemory}!void {
    const us = it.uses.items;
    if (us.len > 0 and us[us.len - 1] == pos) return;
    try it.uses.append(gpa, pos);
}

pub fn finish(it: *Interval) void {
    std.mem.reverse(Range, it.ranges.items);
    std.mem.reverse(u32, it.uses.items);
}

const testing = std.testing;

fn build(gpa: std.mem.Allocator, ranges: []const Range, uses: []const u32) !Interval {
    var it: Interval = .{ .vreg = 0 };
    try it.ranges.appendSlice(gpa, ranges);
    try it.uses.appendSlice(gpa, uses);
    return it;
}

test "interval: covers respects holes; nextIntersection finds the first shared position" {
    const gpa = testing.allocator;
    var a = try build(gpa, &.{ .{ .from = 2, .to = 6 }, .{ .from = 10, .to = 14 } }, &.{});
    defer a.deinit(gpa);
    var b = try build(gpa, &.{.{ .from = 6, .to = 12 }}, &.{});
    defer b.deinit(gpa);
    try testing.expect(a.covers(5));
    try testing.expect(!a.covers(6));
    try testing.expect(!a.covers(8));
    try testing.expect(a.covers(13));
    try testing.expectEqual(@as(?u32, 10), a.nextIntersection(&b, 0));
    try testing.expectEqual(@as(?u32, 11), a.nextIntersection(&b, 11));
    try testing.expectEqual(@as(?u32, null), a.nextIntersection(&b, 12));
}

test "interval: split inside a range and inside a hole moves later ranges and uses" {
    const gpa = testing.allocator;
    var a = try build(gpa, &.{ .{ .from = 2, .to = 6 }, .{ .from = 10, .to = 14 } }, &.{ 2, 5, 11, 13 });
    defer a.deinit(gpa);
    var c = try a.split(gpa, 4);
    defer c.deinit(gpa);
    try testing.expectEqualSlices(Range, &.{.{ .from = 2, .to = 4 }}, a.ranges.items);
    try testing.expectEqualSlices(u32, &.{2}, a.uses.items);
    try testing.expectEqualSlices(Range, &.{ .{ .from = 4, .to = 6 }, .{ .from = 10, .to = 14 } }, c.ranges.items);
    try testing.expectEqualSlices(u32, &.{ 5, 11, 13 }, c.uses.items);
    var d = try c.split(gpa, 8);
    defer d.deinit(gpa);
    try testing.expectEqualSlices(Range, &.{.{ .from = 4, .to = 6 }}, c.ranges.items);
    try testing.expectEqualSlices(Range, &.{.{ .from = 10, .to = 14 }}, d.ranges.items);
    try testing.expectEqual(@as(?u32, 11), d.firstUseFrom(10));
    try testing.expectEqual(@as(?u32, null), d.useIn(14, 20));
}

test "interval: the backward builders merge adjacent ranges and shorten at defs" {
    const gpa = testing.allocator;
    var it: Interval = .{ .vreg = 0 };
    defer it.deinit(gpa);
    // Block [10, 20): used at 16, live out; defined at 13. Block [0, 10): used at 4.
    try it.addRangeBackward(gpa, 10, 20);
    try it.addRangeBackward(gpa, 10, 17);
    try it.addUseBackward(gpa, 16);
    try it.defBackward(gpa, 13, true);
    try it.addUseBackward(gpa, 13);
    try it.addRangeBackward(gpa, 0, 5);
    try it.addUseBackward(gpa, 4);
    it.finish();
    try testing.expectEqualSlices(Range, &.{ .{ .from = 0, .to = 5 }, .{ .from = 13, .to = 20 } }, it.ranges.items);
    try testing.expectEqualSlices(u32, &.{ 4, 13, 16 }, it.uses.items);
}

test "interval: the searches agree with a walk over many ranges and uses" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var a: Interval = .{ .vreg = 0 };
    defer a.deinit(gpa);
    var b: Interval = .{ .vreg = 1 };
    defer b.deinit(gpa);
    inline for (.{ &a, &b }) |it| {
        var p: u32 = rng.uintLessThan(u32, 4);
        for (0..60) |_| {
            const to = p + 1 + rng.uintLessThan(u32, 5);
            try it.ranges.append(gpa, .{ .from = p, .to = to });
            try it.uses.append(gpa, p);
            p = to + 1 + rng.uintLessThan(u32, 4);
        }
    }
    const last = @max(a.end(), b.end()) + 2;
    for (0..last) |pos_usize| {
        const pos: u32 = @intCast(pos_usize);
        var cov = false;
        for (a.ranges.items) |r| cov = cov or (r.from <= pos and pos < r.to);
        try testing.expectEqual(cov, a.covers(pos));
        var want: ?u32 = null;
        var x = pos;
        while (x < last) : (x += 1) if (a.covers(x) and b.covers(x)) {
            want = x;
            break;
        };
        try testing.expectEqual(want, a.nextIntersection(&b, pos));
        var use: ?u32 = null;
        for (a.uses.items) |u| if (u >= pos) {
            use = u;
            break;
        };
        try testing.expectEqual(use, a.firstUseFrom(pos));
    }
}
