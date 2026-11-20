//! Differential coverage for core/fmt's float digits: toy's Ryu `shortest` and
//! `shortest32` against Zig std's Ryu on every OS, and exact `rounded` (with `shortest`)
//! against the C library's dtoa they replaced where there is one (macOS's `__dtoa`,
//! modes 0 and 2), over random doubles and float32 values and the edge cases. Each value
//! goes to the toy program as its exact parts (sign, integer mantissa, binary exponent),
//! which it rebuilds with exact doublings.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const harness = @import("harness.zig");

extern "c" fn __dtoa(d: f64, mode: c_int, ndigits: c_int, decpt: *c_int, sign: *c_int, rve: ?*[*:0]u8) [*:0]u8;
extern "c" fn __freedtoa(s: [*:0]u8) void;

const src =
    \\import core/fmt
    \\import std/io
    \\import std/str
    \\import std/vec
    \\
    \\fn num(s: str) -> int {
    \\    return s.parse_int().expect("an int")
    \\}
    \\
    \\# Every step is exact: each partial product is the mantissa times a power of two
    \\# between 1 and the target's, so it is a multiple of the target's ulp in range.
    \\fn value(kind: int, m: int, e: int) -> float {
    \\    if kind == 4 { return 0.0 /. 0.0 }
    \\    f: float = m.into()
    \\    if kind >= 2 { f = 1.0 /. 0.0 }
    \\    k := e
    \\    while k > 0 {
    \\        f = f *. 2.0
    \\        k -= 1
    \\    }
    \\    while k < 0 {
    \\        f = f *. 0.5
    \\        k += 1
    \\    }
    \\    if kind == 1 || kind == 3 { f = f *. (0.0 -. 1.0) }
    \\    return f
    \\}
    \\
    \\fn part(s: fmt.Shortest) -> str {
    \\    neg := "+"
    \\    if s.neg { neg = "-" }
    \\    return neg.concat(s.digits).concat("@").concat(s.point.to_string())
    \\}
    \\
    \\fn main() {
    \\    for l in io.read_all().split("\n") {
    \\        if l.len() > 0 {
    \\            p := l.split(" ")
    \\            kind := num(p[0])
    \\            f := value(kind % 10, num(p[1]), num(p[2]))
    \\            narrow: float32 = f.into()
    \\            out := part(fmt.shortest(f))
    \\            if kind >= 10 { out = part(fmt.shortest32(narrow)) }
    \\            for i in 3..p.len() {
    \\                out = out.concat(" ").concat(part(fmt.rounded(f, num(p[i]))))
    \\            }
    \\            io.println(out)
    \\        }
    \\    }
    \\}
    \\
;

const small_ns = [_]c_int{ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 25, 40 };
const large_ns = [_]c_int{ 120, 400, 800 };

const have_dtoa = builtin.os.tag == .macos;

/// `bits` holds a float32's bits when `narrow`, and then only `shortest32` is checked.
const Case = struct { bits: u64, large: bool, narrow: bool = false };

fn edgeCases(list: *std.ArrayList(Case), gpa: std.mem.Allocator) !void {
    const values = [_]f64{
        0.0,                     -0.0,                    std.math.inf(f64),
        -std.math.inf(f64),      std.math.nan(f64),       5e-324,
        -5e-324,                 1e-323,                  2.2250738585072009e-308,
        2.2250738585072014e-308, 2.2250738585072019e-308, std.math.floatMax(f64),
        -std.math.floatMax(f64), 1.7976931348623155e308,  1e23,
        9007199254740993.0,      9007199254740992,        9007199254740991,
        0.1,                     0.2,                     0.3,
        1.0 / 3.0,               2.0 / 3.0,               0.125,
        0.375,                   2.5,                     3.5,
        2.675,                   1.005,                   0.5,
        1.5,                     123456.789,              1e21,
        1e-7,                    5e-5,                    4.35,
        8.5,                     9.5,                     0.95,
        0.05,                    999999.5,                9.999999999999999e22,
        1e300,                   1e-300,                  2.0e-308,
        1.0,                     10.0,                    100.0,
    };
    for (values) |v| try list.append(gpa, .{ .bits = @bitCast(v), .large = true });
    var p: f64 = 1;
    for (0..309) |_| {
        try list.append(gpa, .{ .bits = @bitCast(p), .large = false });
        p *= 10;
    }
    p = 1;
    for (0..324) |_| {
        p /= 10;
        try list.append(gpa, .{ .bits = @bitCast(p), .large = false });
    }
    var e: i32 = -1074;
    while (e <= 1023) : (e += 1) {
        try list.append(gpa, .{ .bits = @bitCast(std.math.ldexp(@as(f64, 1), e)), .large = @mod(e, 97) == 0 });
    }
    // The largest subnormal, the smallest normal and every subnormal with one bit set.
    try list.append(gpa, .{ .bits = 0x000F_FFFF_FFFF_FFFF, .large = true });
    try list.append(gpa, .{ .bits = 0x0010_0000_0000_0000, .large = true });
    for (0..52) |i| try list.append(gpa, .{ .bits = @as(u64, 1) << @intCast(i), .large = false });
    try list.append(gpa, .{ .bits = @bitCast(@as(f64, std.math.floatMax(f32))), .large = true });
    try list.append(gpa, .{ .bits = @bitCast(@as(f64, std.math.floatTrueMin(f32))), .large = true });

    const narrow = [_]f32{
        0.0,                     -0.0,                   std.math.inf(f32),
        -std.math.inf(f32),      std.math.nan(f32),      std.math.floatMax(f32),
        -std.math.floatMax(f32), std.math.floatMin(f32), 0.1,
        0.3,                     1.0 / 3.0,              16777217.0,
        1e10,                    1e-10,                  3.4e38,
    };
    for (narrow) |v| try list.append(gpa, .{ .bits = @as(u32, @bitCast(v)), .large = false, .narrow = true });
    // Every power of two, where the gap below is half the gap above, and every subnormal
    // with one bit set.
    var e32: i32 = -149;
    while (e32 <= 127) : (e32 += 1) {
        const v: f32 = std.math.ldexp(@as(f32, 1), e32);
        try list.append(gpa, .{ .bits = @as(u32, @bitCast(v)), .large = false, .narrow = true });
    }
    for (0..23) |i| try list.append(gpa, .{ .bits = @as(u64, 1) << @intCast(i), .large = false, .narrow = true });
}

fn randomCases(list: *std.ArrayList(Case), gpa: std.mem.Allocator, n: usize) !void {
    var prng = std.Random.DefaultPrng.init(0x7e57_f107);
    const r = prng.random();
    for (0..n) |i| {
        const bits = r.int(u64);
        const f: f64 = @bitCast(bits);
        if (std.math.isNan(f)) continue;
        try list.append(gpa, .{ .bits = bits, .large = i % 64 == 0 });
    }
    for (0..n / 2) |_| {
        const b32 = r.int(u32);
        const f: f32 = @bitCast(b32);
        if (std.math.isNan(f)) continue;
        try list.append(gpa, .{ .bits = @bitCast(@as(f64, f)), .large = false });
        try list.append(gpa, .{ .bits = b32, .large = false, .narrow = true });
    }
    // Short decimals, whose halfway roundings dtoa rounds to even.
    for (0..n / 4) |_| {
        const mant = r.intRangeAtMost(u64, 1, 99999);
        const exp = r.intRangeAtMost(i32, -12, 12);
        const f = @as(f64, @floatFromInt(mant)) * std.math.pow(f64, 10, @floatFromInt(exp));
        try list.append(gpa, .{ .bits = @bitCast(f), .large = false });
    }
}

/// The value `c` stands for, as a double: a float32 widens exactly.
fn wide(c: Case) u64 {
    if (!c.narrow) return c.bits;
    const f: f32 = @bitCast(@as(u32, @intCast(c.bits)));
    return @bitCast(@as(f64, f));
}

/// The toy program's input line for `c`: kind (0 +, 1 -, 2 +inf, 3 -inf, 4 NaN, plus 10
/// for a float32), mantissa, binary exponent, then the digit counts for `rounded`.
fn inputLine(w: *std.ArrayList(u8), gpa: std.mem.Allocator, c: Case) !void {
    const bits = wide(c);
    const neg = bits >> 63 != 0;
    const frac = bits & ((@as(u64, 1) << 52) - 1);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    var kind: u8 = if (neg) 1 else 0;
    var m: u64 = frac | (@as(u64, 1) << 52);
    var e: i32 = biased - 1075;
    if (biased == 0x7ff) {
        kind = if (frac != 0) 4 else if (neg) 3 else 2;
        m = 0;
        e = 0;
    } else if (biased == 0) {
        m = frac;
        e = -1074;
    }
    if (c.narrow) kind += 10;
    try w.print(gpa, "{d} {d} {d}", .{ kind, m, e });
    for (small_ns) |n| try w.print(gpa, " {d}", .{n});
    if (c.large) for (large_ns) |n| try w.print(gpa, " {d}", .{n});
    try w.append(gpa, '\n');
}

fn dtoaPart(w: *std.ArrayList(u8), gpa: std.mem.Allocator, f: f64, mode: c_int, n: c_int) !void {
    var point: c_int = 0;
    var sign: c_int = 0;
    const p = __dtoa(f, mode, n, &point, &sign, null);
    defer __freedtoa(p);
    // On one path, an integer below 10^15 rounded down at an exact tie, dtoa keeps the
    // trailing zeros (6705000 to 3 digits is "670", not "67"). Both spell the same value
    // and render the same, so toy always drops them.
    var digits: []const u8 = std.mem.span(p);
    while (digits.len > 1 and digits[digits.len - 1] == '0') digits.len -= 1;
    try w.print(gpa, "{s}{s}@{d}", .{ if (sign != 0) "-" else "+", digits, point });
}

fn expectedLine(w: *std.ArrayList(u8), gpa: std.mem.Allocator, c: Case) !void {
    const f: f64 = @bitCast(c.bits);
    try dtoaPart(w, gpa, f, 0, 0);
    for (small_ns) |n| {
        try w.append(gpa, ' ');
        try dtoaPart(w, gpa, f, 2, n);
    }
    if (c.large) for (large_ns) |n| {
        try w.append(gpa, ' ');
        try dtoaPart(w, gpa, f, 2, n);
    };
    try w.append(gpa, '\n');
}

/// Zig std's Ryu shortest for `c` as `<sign><digits>@<point>`, trailing zeros dropped.
fn zigShortest(buf: []u8, c: Case) []const u8 {
    const fl = std.fmt.float;
    const d = if (c.narrow)
        fl.binaryToDecimal(u64, c.bits, 23, 8, false, &fl.Backend64_TablesFull)
    else
        fl.binaryToDecimal(u64, c.bits, 52, 11, false, &fl.Backend64_TablesFull);
    const sign: []const u8 = if (d.sign) "-" else "+";
    if (d.exponent == 0x7fffffff) return std.fmt.bufPrint(buf, "{s}{s}@9999", .{ sign, if (d.mantissa != 0) "NaN" else "Infinity" }) catch unreachable;
    if (d.mantissa == 0) return std.fmt.bufPrint(buf, "{s}0@1", .{sign}) catch unreachable;
    var m = d.mantissa;
    var e = d.exponent;
    while (m % 10 == 0) {
        m /= 10;
        e += 1;
    }
    var digits: [24]u8 = undefined;
    const ds = std.fmt.bufPrint(&digits, "{d}", .{m}) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}{s}@{d}", .{ sign, ds, e + @as(i32, @intCast(ds.len)) }) catch unreachable;
}

fn run(gpa: std.mem.Allocator, io: Io) !void {
    try harness.skipUnlessBackend(io);

    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(gpa);
    try edgeCases(&cases, gpa);
    try randomCases(&cases, gpa, 10000);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    for (cases.items) |c| {
        try inputLine(&input, gpa, c);
        if (have_dtoa and !c.narrow) try expectedLine(&want, gpa, c);
    }

    const dir = ".toy-test-fmt-dtoa";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const prog = try harness.compile(gpa, io, dir, src, &.{harness.dev_core_imports});
    defer gpa.free(prog);

    var child = try std.process.spawn(io, .{ .argv = &.{prog}, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    errdefer child.kill(io);
    // The program reads all of stdin before it writes anything, so writing the whole
    // input before reading its output cannot deadlock.
    try child.stdin.?.writeStreamingAll(io, input.items);
    child.stdin.?.close(io);
    child.stdin = null;
    var rdr = child.stdout.?.readerStreaming(io, &.{});
    const out = try rdr.interface.allocRemaining(gpa, .limited(64 << 20));
    defer gpa.free(out);
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);

    var got_lines = std.mem.splitScalar(u8, out, '\n');
    var want_lines = std.mem.splitScalar(u8, want.items, '\n');
    var bad: usize = 0;
    for (cases.items) |c| {
        const got = got_lines.next() orelse return error.MissingOutput;
        const exp = if (have_dtoa and !c.narrow) want_lines.next().? else "";
        var zbuf: [64]u8 = undefined;
        const f: f64 = @bitCast(wide(c));
        const zig = zigShortest(&zbuf, c);
        const got_short = got[0 .. std.mem.indexOfScalar(u8, got, ' ') orelse got.len];
        const zig_ok = std.math.isNan(f) or std.mem.eql(u8, got_short, zig);
        const dtoa_ok = !have_dtoa or c.narrow or std.mem.eql(u8, got, exp);
        if (!dtoa_ok or !zig_ok) {
            bad += 1;
            if (bad <= 10) std.debug.print("fmt: bits 0x{x:0>16} ({e})\n  toy   {s}\n  dtoa  {s}\n  zig   {s}\n", .{ c.bits, f, got, exp, zig });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "fmt: shortest and rounded match dtoa and Zig std's Ryu" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    try run(gpa, threaded.io());
}
