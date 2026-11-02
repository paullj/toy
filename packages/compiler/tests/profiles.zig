//! Build profiles (#154): `--release` / `--profile debug|release` pick the IR passes, `-O`
//! overrides the profile's choice, and the profile is part of every codegen cache key and of
//! the default output folder.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const harness = @import("harness.zig");

/// `fold` turns `2 + 3` into a constant, so a build that ran the passes has different IR.
const prog =
    \\fn sq(x: int) -> int { x * x }
    \\fn main() -> int {
    \\    return sq(2 + 3) - 25
    \\}
    \\
;

const Out = harness.ToolOutput;

fn toyIn(gpa: std.mem.Allocator, io: Io, cwd_abs: ?[]const u8, args: []const []const u8) !Out {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, harness.toy_exe);
    try argv.appendSlice(gpa, args);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (cwd_abs) |c| .{ .path = c } else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var rdr = child.stdout.?.readerStreaming(io, &.{});
    const out = try rdr.interface.allocRemaining(gpa, .limited(1 << 22));
    errdefer gpa.free(out);
    var erdr = child.stderr.?.readerStreaming(io, &.{});
    const err = try erdr.interface.allocRemaining(gpa, .limited(1 << 16));
    return .{ .out = out, .err = err, .term = try child.wait(io) };
}

fn freeOut(gpa: std.mem.Allocator, o: Out) void {
    gpa.free(o.out);
    gpa.free(o.err);
}

test "profiles: release runs every pass, debug none, and -O overrides the profile (#154)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const dir = ".toy-test-profiles-ir";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/main.toy";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = prog });

    const o0 = try harness.emitIr(gpa, io, path, &.{"-O0"});
    defer gpa.free(o0);
    const o1 = try harness.emitIr(gpa, io, path, &.{"-O1"});
    defer gpa.free(o1);
    try testing.expect(!std.mem.eql(u8, o0, o1));
    // Release drops debug's overflow tests whatever passes run.
    const r0 = try harness.emitIr(gpa, io, path, &.{ "--release", "-O0" });
    defer gpa.free(r0);
    const r1 = try harness.emitIr(gpa, io, path, &.{ "--release", "-O1" });
    defer gpa.free(r1);
    try testing.expect(!std.mem.eql(u8, r0, r1));
    try testing.expect(!std.mem.eql(u8, o0, r0));
    try testing.expect(std.mem.indexOf(u8, o0, "overflow mul") != null);
    try testing.expect(std.mem.indexOf(u8, r0, "overflow") == null);
    const r1_nofold = try harness.emitIr(gpa, io, path, &.{ "-O1", "--release", "--no-opt", "fold" });
    defer gpa.free(r1_nofold);

    const same = [_]struct { flags: []const []const u8, want: []const u8 }{
        .{ .flags = &.{}, .want = o0 },
        .{ .flags = &.{ "--profile", "debug" }, .want = o0 },
        .{ .flags = &.{"--release"}, .want = r1 },
        .{ .flags = &.{"--profile=release"}, .want = r1 },
        .{ .flags = &.{ "--profile", "release", "-O0" }, .want = r0 },
        .{ .flags = &.{ "--profile", "debug", "-O1" }, .want = o1 },
        .{ .flags = &.{ "--release", "--no-opt", "fold" }, .want = r1_nofold },
    };
    for (same) |c| {
        const got = try harness.emitIr(gpa, io, path, c.flags);
        defer gpa.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "profiles: a bad or conflicting profile is a usage error, and check declines it (#154)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const dir = ".toy-test-profiles-usage";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/main.toy";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = prog });

    const bad = "error: invalid value 'fast' for --profile (one of: debug|release)\n";
    const runs = [_]struct { argv: []const []const u8, line: []const u8 }{
        .{ .argv = &.{ "build", "--profile", "fast", path }, .line = bad },
        .{ .argv = &.{ "run", "--profile", "fast", path }, .line = bad },
        .{ .argv = &.{ "--profile=fast", path }, .line = bad },
        .{ .argv = &.{ "build", "--profile", "relase", path }, .line = "did you mean 'release'?\n" },
        .{ .argv = &.{ "build", "--release", "--profile", "debug", path }, .line = "error: --release conflicts with --profile\n" },
        .{ .argv = &.{ "run", "--profile", "release", "--release", path }, .line = "error: --release conflicts with --profile\n" },
        .{ .argv = &.{ "check", "--release", path }, .line = "error: '--release' is a build option; 'check' does not take it\n" },
        .{ .argv = &.{ "check", "--profile", "release", path }, .line = "error: '--profile' is a build option; 'check' does not take it\n" },
    };
    for (runs) |r| {
        const res = try toyIn(gpa, io, null, r.argv);
        defer freeOut(gpa, res);
        try testing.expectEqual(std.process.Child.Term{ .exited = 2 }, res.term);
        try testing.expectEqualStrings("", res.out);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, res.err, r.line));
    }

    const help = try toyIn(gpa, io, null, &.{ "build", "--help" });
    defer freeOut(gpa, help);
    try testing.expect(std.mem.indexOf(u8, help.out, "--release") != null);
    try testing.expect(std.mem.indexOf(u8, help.out, "--profile") != null);
}

fn codegenStats(gpa: std.mem.Allocator, io: Io, cwd: []const u8, flags: []const []const u8) ![2]usize {
    const args = try std.mem.concat(gpa, []const u8, &.{ &.{ "build", "main.toy", "--codegen-stats" }, flags });
    defer gpa.free(args);
    const res = try toyIn(gpa, io, cwd, args);
    defer freeOut(gpa, res);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
    const head = "codegen: compiled=";
    const at = std.mem.indexOf(u8, res.out, head) orelse return error.NoStats;
    var it = std.mem.tokenizeAny(u8, res.out[at + head.len ..], " cached=\n");
    const compiled = try std.fmt.parseInt(usize, it.next().?, 10);
    const cached = try std.fmt.parseInt(usize, it.next().?, 10);
    return .{ compiled, cached };
}

test "profiles: debug and release never reuse each other's cache entries or output (#154)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const root = ".toy-test-profiles-cache";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/main.toy", .data = prog });
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
    defer gpa.free(cwd);

    const cold = try codegenStats(gpa, io, cwd, &.{});
    try testing.expect(cold[0] > 0);
    try testing.expectEqual(@as(usize, 0), cold[1]);
    const n = cold[0];

    try testing.expectEqual([2]usize{ n, 0 }, try codegenStats(gpa, io, cwd, &.{"--release"}));
    try testing.expectEqual([2]usize{ 0, n }, try codegenStats(gpa, io, cwd, &.{}));
    try testing.expectEqual([2]usize{ 0, n }, try codegenStats(gpa, io, cwd, &.{ "--profile", "release" }));
    // A debug build with release's passes still differs in what the profile decides beyond
    // the passes, so it must not reuse release's code.
    try testing.expectEqual([2]usize{ n, 0 }, try codegenStats(gpa, io, cwd, &.{"-O1"}));

    // The default output sits in a folder per profile, as `.toy/<stamp>/<profile>/main`.
    var toy_dir = try Io.Dir.cwd().openDir(io, root ++ "/.toy", .{ .iterate = true });
    defer toy_dir.close(io);
    var walker = toy_dir.iterate();
    var found = false;
    while (try walker.next(io)) |e| {
        if (e.kind != .directory) continue;
        var stamp = try toy_dir.openDir(io, e.name, .{});
        defer stamp.close(io);
        stamp.access(io, "debug/main", .{}) catch continue;
        try stamp.access(io, "release/main", .{});
        found = true;
    }
    try testing.expect(found);
}

/// The `--codegen-stats` counts of a `--backend=mir` build: compiled, cached, lowered
/// through MIR, fallen back to spill.
fn mirStats(gpa: std.mem.Allocator, io: Io, cwd: []const u8, flags: []const []const u8) ![4]usize {
    const args = try std.mem.concat(gpa, []const u8, &.{ &.{ "build", "main.toy", "--codegen-stats", "--backend", "mir" }, flags });
    defer gpa.free(args);
    const res = try toyIn(gpa, io, cwd, args);
    defer freeOut(gpa, res);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
    var got: [4]usize = undefined;
    inline for (.{ "compiled=", "cached=", "lowered=", "fallback=" }, 0..) |key, i| {
        const at = std.mem.indexOf(u8, res.out, key) orelse return error.NoStats;
        const rest = res.out[at + key.len ..];
        const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
        got[i] = try std.fmt.parseInt(usize, rest[0..end], 10);
    }
    return got;
}

test "profiles: --backend=mir lowers every fn through MIR and shares no cache entry with spill (#199)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const root = ".toy-test-profiles-mir";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/main.toy", .data = prog });
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
    defer gpa.free(cwd);

    const n = (try codegenStats(gpa, io, cwd, &.{}))[0];
    try testing.expect(n > 0);
    try testing.expectEqual([4]usize{ n, 0, n, 0 }, try mirStats(gpa, io, cwd, &.{}));
    try testing.expectEqual([2]usize{ 0, n }, try codegenStats(gpa, io, cwd, &.{}));
    // A cached unit was lowered by an earlier build, so it counts toward neither.
    try testing.expectEqual([4]usize{ 0, n, 0, 0 }, try mirStats(gpa, io, cwd, &.{}));
    // A --verify build still reports the units cached but re-lowers each one fresh to
    // check the cached bytes, so MIR counts it lowered.
    try testing.expectEqual([4]usize{ 0, n, n, 0 }, try mirStats(gpa, io, cwd, &.{"--verify"}));
    try testing.expectEqual([4]usize{ n, 0, n, 0 }, try mirStats(gpa, io, cwd, &.{"--release"}));

    // The default backend prints no MIR line.
    const res = try toyIn(gpa, io, cwd, &.{ "build", "main.toy", "--codegen-stats" });
    defer freeOut(gpa, res);
    try testing.expect(std.mem.indexOf(u8, res.out, "mir:") == null);
}

/// One function per checked operator, width and signedness, each called from `main` on
/// the case its first argument names, so one build covers every case without -O1 folding
/// the operands away. `folded` multiplies two literals with no width to range-check them
/// against, which -O1 does fold.
const overflow_prog =
    \\import std/io
    \\import std/os
    \\import std/str
    \\import std/vec
    \\fn add8(a: int8, b: int8) -> int8 { a + b }
    \\fn sub8(a: int8, b: int8) -> int8 { a - b }
    \\fn mul8(a: int8, b: int8) -> int8 { a * b }
    \\fn neg8(a: int8) -> int8 { -a }
    \\fn addu8(a: uint8, b: uint8) -> uint8 { a + b }
    \\fn subu8(a: uint8, b: uint8) -> uint8 { a - b }
    \\fn mulu8(a: uint8, b: uint8) -> uint8 { a * b }
    \\fn negu8(a: uint8) -> uint8 { -a }
    \\fn add(a: int, b: int) -> int { a + b }
    \\fn sub(a: int, b: int) -> int { a - b }
    \\fn mul(a: int, b: int) -> int { a * b }
    \\fn neg(a: int) -> int { -a }
    \\fn addu(a: uint64, b: uint64) -> uint64 { a + b }
    \\fn subu(a: uint64, b: uint64) -> uint64 { a - b }
    \\fn mulu(a: uint64, b: uint64) -> uint64 { a * b }
    \\fn inc32(mut x: int32) { x += 1 }
    \\fn dec16u(mut x: uint16) { x -= 1 }
    \\fn triple(mut x: int) { x *= 3 }
    \\fn div8(a: int8, b: int8) -> int8 { a / b }
    \\fn rem8(a: int8, b: int8) -> int8 { a % b }
    \\fn div(a: int, b: int) -> int { a / b }
    \\fn divby16(mut x: int16, d: int16) { x /= d }
    \\fn folded() -> int {
    \\    x := 4 * 4611686018427387904
    \\    return x
    \\}
    \\fn main() {
    \\    c := os.args()[1].parse_int().or(-1)
    \\    if c == 0 { io.println(add8(127, 1)) }
    \\    if c == 1 { io.println(sub8(-128, 1)) }
    \\    if c == 2 { io.println(mul8(64, 2)) }
    \\    if c == 3 { io.println(mul8(-128, -1)) }
    \\    if c == 4 { io.println(neg8(-128)) }
    \\    if c == 5 { io.println(addu8(255, 1)) }
    \\    if c == 6 { io.println(subu8(0, 1)) }
    \\    if c == 7 { io.println(mulu8(16, 16)) }
    \\    if c == 8 { io.println(negu8(1)) }
    \\    if c == 9 { io.println(add(9223372036854775807, 1)) }
    \\    if c == 10 { io.println(sub(-9223372036854775808, 1)) }
    \\    if c == 11 { io.println(mul(4, 4611686018427387904)) }
    \\    if c == 12 { io.println(mul(-1, -9223372036854775808)) }
    \\    if c == 13 { io.println(neg(-9223372036854775808)) }
    \\    if c == 14 { io.println(addu(18446744073709551615, 1)) }
    \\    if c == 15 { io.println(subu(0, 1)) }
    \\    if c == 16 { io.println(mulu(4294967296, 4294967296)) }
    \\    if c == 17 {
    \\        x: int32 = 2147483647
    \\        inc32(x)
    \\        io.println(x)
    \\    }
    \\    if c == 18 {
    \\        x: uint16 = 0
    \\        dec16u(x)
    \\        io.println(x)
    \\    }
    \\    if c == 19 {
    \\        x := 4611686018427387904
    \\        triple(x)
    \\        io.println(x)
    \\    }
    \\    if c == 20 { io.println(folded()) }
    \\    if c == 21 { io.println(mul(-1, 9223372036854775807)) }
    \\    if c == 22 { io.println(div8(-128, -1)) }
    \\    if c == 23 { io.println(div(-9223372036854775808, -1)) }
    \\    if c == 24 {
    \\        x: int16 = -32768
    \\        divby16(x, -1)
    \\        io.println(x)
    \\    }
    \\    if c == 25 { io.println(div8(-128, 1)) }
    \\    if c == 26 { io.println(div(-9223372036854775807, -1)) }
    \\    if c == 27 { io.println(rem8(-128, -1)) }
    \\}
    \\
;

/// Each case's panic message in a debug build (null: it does not overflow) and its output
/// in a release build, which wraps.
const overflow_cases = [_]struct { panic: ?[]const u8, wraps_to: []const u8 }{
    .{ .panic = "'+'", .wraps_to = "-128" },
    .{ .panic = "'-'", .wraps_to = "127" },
    .{ .panic = "'*'", .wraps_to = "-128" },
    .{ .panic = "'*'", .wraps_to = "-128" },
    .{ .panic = "negation", .wraps_to = "-128" },
    .{ .panic = "'+'", .wraps_to = "0" },
    .{ .panic = "'-'", .wraps_to = "255" },
    .{ .panic = "'*'", .wraps_to = "0" },
    .{ .panic = "negation", .wraps_to = "255" },
    .{ .panic = "'+'", .wraps_to = "-9223372036854775808" },
    .{ .panic = "'-'", .wraps_to = "9223372036854775807" },
    .{ .panic = "'*'", .wraps_to = "0" },
    .{ .panic = "'*'", .wraps_to = "-9223372036854775808" },
    .{ .panic = "negation", .wraps_to = "-9223372036854775808" },
    .{ .panic = "'+'", .wraps_to = "0" },
    .{ .panic = "'-'", .wraps_to = "18446744073709551615" },
    .{ .panic = "'*'", .wraps_to = "0" },
    .{ .panic = "'+'", .wraps_to = "-2147483648" },
    .{ .panic = "'-'", .wraps_to = "65535" },
    .{ .panic = "'*'", .wraps_to = "-4611686018427387904" },
    .{ .panic = "'*'", .wraps_to = "0" },
    .{ .panic = null, .wraps_to = "-9223372036854775807" },
    .{ .panic = "'/'", .wraps_to = "-128" },
    .{ .panic = "'/'", .wraps_to = "-9223372036854775808" },
    .{ .panic = "'/'", .wraps_to = "-32768" },
    .{ .panic = null, .wraps_to = "-128" },
    .{ .panic = null, .wraps_to = "9223372036854775807" },
    .{ .panic = null, .wraps_to = "0" },
};

fn runCase(gpa: std.mem.Allocator, io: Io, exe: []const u8, case: usize) !Out {
    var arg_buf: [8]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "{d}", .{case});
    var child = try std.process.spawn(io, .{ .argv = &.{ exe, arg }, .stdout = .pipe, .stderr = .pipe });
    var rdr = child.stdout.?.readerStreaming(io, &.{});
    const out = try rdr.interface.allocRemaining(gpa, .limited(1 << 16));
    errdefer gpa.free(out);
    var erdr = child.stderr.?.readerStreaming(io, &.{});
    const err = try erdr.interface.allocRemaining(gpa, .limited(1 << 16));
    return .{ .out = out, .err = err, .term = try child.wait(io) };
}

test "profiles: debug panics on integer overflow at -O0 and -O1, release wraps (#155)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const dir = ".toy-test-profiles-overflow";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    const builds = [_]struct { sub: []const u8, flags: []const []const u8, traps: bool }{
        .{ .sub = dir ++ "/debug", .flags = &.{}, .traps = true },
        .{ .sub = dir ++ "/debug-O1", .flags = &.{"-O1"}, .traps = true },
        .{ .sub = dir ++ "/release", .flags = &.{"--release"}, .traps = false },
        .{ .sub = dir ++ "/release-O0", .flags = &.{ "--release", "-O0" }, .traps = false },
    };
    for (builds) |b| {
        const exe = try harness.compile(gpa, io, b.sub, overflow_prog, b.flags);
        defer gpa.free(exe);
        for (overflow_cases, 0..) |c, i| {
            const res = try runCase(gpa, io, exe, i);
            defer freeOut(gpa, res);
            errdefer std.debug.print("{s} case {d}: exit {any} stdout '{s}' stderr '{s}'\n", .{ b.sub, i, res.term, res.out, res.err });
            if (b.traps and c.panic != null) {
                const want = try std.fmt.allocPrint(gpa, "integer overflow in {s}\n", .{c.panic.?});
                defer gpa.free(want);
                try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, res.term);
                try testing.expect(std.mem.startsWith(u8, res.err, want));
                try testing.expectEqualStrings("", res.out);
            } else {
                try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
                try testing.expectEqualStrings(c.wraps_to, std.mem.trimEnd(u8, res.out, "\n"));
            }
        }
    }
}

const symtab_util =
    \\pub fn sq(x: int) -> int { x * x }
    \\pub fn ident[T](x: T) -> T { x }
    \\
;

/// A module fn, a generic instance and a closure, so every kind of unit name is listed.
const symtab_prog =
    \\import util
    \\fn apply(f: fn(int) -> int, x: int) -> int { f(x) }
    \\fn main() -> int {
    \\    k := 3
    \\    g := fn(x: int) -> int { x + k }
    \\    return apply(g, util.sq(util.ident(2)))
    \\}
    \\
;

test "profiles: a debug build lists its functions to nm and lldb, release has no symbols (#156)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const dir = ".toy-test-profiles-symtab";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var lldb_broken = false;
    for (debug_cases) |c| {
        const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, c.name });
        defer gpa.free(sub);
        try Io.Dir.cwd().createDirPath(io, sub);
        const util_path = try std.fmt.allocPrint(gpa, "{s}/util.toy", .{sub});
        defer gpa.free(util_path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = util_path, .data = symtab_util });
        const exe = try harness.compile(gpa, io, sub, symtab_prog, c.flags);
        defer gpa.free(exe);

        try testing.expectEqual(@as(u8, 7), try harness.runExit(gpa, io, exe));
        if (try harness.runTool(gpa, io, null, &.{ "codesign", "-v", exe })) |cs| {
            defer freeOut(gpa, cs);
            errdefer std.debug.print("codesign: {s}\n", .{cs.err});
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, cs.term);
        }

        const nm = (try harness.runTool(gpa, io, null, &.{ "nm", exe })) orelse return error.SkipZigTest;
        defer freeOut(gpa, nm);
        errdefer std.debug.print("{s} nm:\n{s}{s}\n", .{ c.name, nm.out, nm.err });
        if (!c.debug) {
            try testing.expectEqualStrings("", nm.out);
            continue;
        }
        for ([_][]const u8{ " t _main\n", " t _main.apply\n", " t _util.sq\n", " t _util.ident$int\n", " t _main$l0\n" }) |want| {
            try testing.expect(std.mem.indexOf(u8, nm.out, want) != null);
        }

        // Crash reports symbolicate as atos does, from the same table.
        const sq_line = std.mem.indexOf(u8, nm.out, " t _util.sq\n").?;
        const line_start = if (std.mem.lastIndexOfScalar(u8, nm.out[0..sq_line], '\n')) |n| n + 1 else 0;
        const addr = try std.fmt.allocPrint(gpa, "0x{s}", .{nm.out[line_start..sq_line]});
        defer gpa.free(addr);
        if (try harness.runTool(gpa, io, null, &.{ "atos", "-o", exe, "-l", "0x100000000", addr })) |atos| {
            defer freeOut(gpa, atos);
            errdefer std.debug.print("atos {s}:\n{s}{s}\n", .{ addr, atos.out, atos.err });
            try testing.expect(std.mem.startsWith(u8, atos.out, "util.sq (in prog)"));
        }

        // lldb's '-n' splits a dotted name like a Swift 'module.fn' and finds nothing; '-F'
        // matches the full symbol name.
        const lldb = (try harness.runTool(gpa, io, null, &.{ "lldb", "--batch", "--no-lldbinit", "-o", "breakpoint set -F util.sq", exe })) orelse {
            lldb_broken = true;
            continue;
        };
        defer freeOut(gpa, lldb);
        if (lldbCrashed(lldb)) {
            lldb_broken = true;
            continue;
        }
        errdefer std.debug.print("lldb:\n{s}{s}\n", .{ lldb.out, lldb.err });
        try testing.expect(std.mem.indexOf(u8, lldb.out, "prog`util.sq") != null);
    }
    // Every other check ran; the skip marks that the lldb one could not.
    if (lldb_broken) return error.SkipZigTest;
}

/// The profiles debug info is checked under: debug at its own -O0 and at -O1 (`-O` stays
/// an override), and release, which carries none; each with both backends. Debug -O1
/// leaves inlining out: an inlined callee's code takes its caller's lines, and the link
/// drops the callee.
const debug_cases = [_]struct { name: []const u8, flags: []const []const u8, debug: bool }{
    .{ .name = "debug", .flags = &.{ "--profile", "debug" }, .debug = true },
    .{ .name = "debug-O1", .flags = &.{ "--profile", "debug", "-O", "1", "--no-opt", "inline" }, .debug = true },
    .{ .name = "release", .flags = &.{ "--profile", "release" }, .debug = false },
    .{ .name = "debug-mir", .flags = &.{ "--profile", "debug", "--backend", "mir" }, .debug = true },
    .{ .name = "debug-O1-mir", .flags = &.{ "--profile", "debug", "-O", "1", "--no-opt", "inline", "--backend", "mir" }, .debug = true },
    .{ .name = "release-mir", .flags = &.{ "--profile", "release", "--backend", "mir" }, .debug = false },
};

/// Some hosts ship an lldb that crashes on any target. Only a crash is that; a working lldb
/// that exits non-zero failed the check.
fn lldbCrashed(o: Out) bool {
    return o.term != .exited or std.mem.indexOf(u8, o.err, "PLEASE submit a bug report") != null;
}

// `return y - x` keeps code on line 3 at -O1: a bare `return y` forwards to nothing.
const dwarf_util =
    \\pub fn sq(x: int) -> int {
    \\    y := x * x
    \\    return y - x
    \\}
    \\
;

const dwarf_prog =
    \\import util
    \\fn main() -> int {
    \\    x := 5
    \\    y := util.sq(x)
    \\    return y - 20
    \\}
    \\
;

/// The address and line of every row of `exe`'s DWARF line table, from `dwarfdump`, or
/// null when it is not installed.
fn lineRows(gpa: std.mem.Allocator, io: Io, exe: []const u8) !?[]const [2]u64 {
    const dd = (try harness.runTool(gpa, io, null, &.{ "dwarfdump", "--debug-line", exe })) orelse return null;
    defer freeOut(gpa, dd);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, dd.term);
    var rows: std.ArrayList([2]u64) = .empty;
    errdefer rows.deinit(gpa);
    var it = std.mem.splitScalar(u8, dd.out, '\n');
    while (it.next()) |l| {
        if (!std.mem.startsWith(u8, l, "0x")) continue;
        var f = std.mem.tokenizeScalar(u8, l, ' ');
        const addr = try std.fmt.parseInt(u64, f.next().?[2..], 16);
        const line = try std.fmt.parseInt(u64, f.next().?, 10);
        try rows.append(gpa, .{ addr, line });
    }
    return try rows.toOwnedSlice(gpa);
}

test "profiles: a debug build maps code to toy lines in DWARF, release carries none (#157)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const dir = ".toy-test-profiles-dwarf";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var lldb_broken = false;
    for (debug_cases) |c| {
        const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, c.name });
        defer gpa.free(sub);
        try Io.Dir.cwd().createDirPath(io, sub);
        const util_path = try std.fmt.allocPrint(gpa, "{s}/util.toy", .{sub});
        defer gpa.free(util_path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = util_path, .data = dwarf_util });
        const exe = try harness.compile(gpa, io, sub, dwarf_prog, c.flags);
        defer gpa.free(exe);
        try testing.expectEqual(@as(u8, 0), try harness.runExit(gpa, io, exe));
        if (try harness.runTool(gpa, io, null, &.{ "codesign", "-v", exe })) |cs| {
            defer freeOut(gpa, cs);
            errdefer std.debug.print("codesign: {s}\n", .{cs.err});
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, cs.term);
        }

        const otool = (try harness.runTool(gpa, io, null, &.{ "otool", "-l", exe })) orelse return error.SkipZigTest;
        defer freeOut(gpa, otool);
        const has_dwarf = std.mem.indexOf(u8, otool.out, "segname __DWARF") != null;
        try testing.expectEqual(c.debug, has_dwarf);
        if (!has_dwarf) continue;

        if (try harness.runTool(gpa, io, null, &.{ "dwarfdump", "--verify", exe })) |v| {
            defer freeOut(gpa, v);
            errdefer std.debug.print("dwarfdump --verify:\n{s}{s}\n", .{ v.out, v.err });
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, v.term);
            try testing.expect(std.mem.indexOf(u8, v.out, "No errors.") != null);
        }

        // Every row symbolicates to its toy file and line, as a crash report would.
        const rows = (try lineRows(gpa, io, exe)) orelse return error.SkipZigTest;
        defer gpa.free(rows);
        var argv: std.ArrayList([]const u8) = .empty;
        defer {
            for (argv.items[5..]) |a| gpa.free(a);
            argv.deinit(gpa);
        }
        try argv.appendSlice(gpa, &.{ "atos", "-o", exe, "-l", "0x100000000" });
        for (rows) |r| try argv.append(gpa, try std.fmt.allocPrint(gpa, "0x{x}", .{r[0]}));
        if (try harness.runTool(gpa, io, null, argv.items)) |atos| {
            defer freeOut(gpa, atos);
            errdefer std.debug.print("atos:\n{s}{s}\n", .{ atos.out, atos.err });
            for ([_][]const u8{ "main (in prog) (main.toy:2)", "main (in prog) (main.toy:3)", "main (in prog) (main.toy:4)", "main (in prog) (main.toy:5)", "util.sq (in prog) (util.toy:2)", "util.sq (in prog) (util.toy:3)" }) |want| {
                try testing.expect(std.mem.indexOf(u8, atos.out, want) != null);
            }
        }

        const lldb = (try harness.runTool(gpa, io, null, &.{ "lldb", "--batch", "--no-lldbinit", "-o", "breakpoint set -f util.toy -l 3", "-o", "run", "-o", "bt", exe })) orelse {
            lldb_broken = true;
            continue;
        };
        defer freeOut(gpa, lldb);
        if (lldbCrashed(lldb)) {
            lldb_broken = true;
            continue;
        }
        errdefer std.debug.print("lldb:\n{s}{s}\n", .{ lldb.out, lldb.err });
        try testing.expect(std.mem.indexOf(u8, lldb.out, "stop reason = breakpoint") != null);
        try testing.expect(std.mem.indexOf(u8, lldb.out, "util.toy:3") != null);
        try testing.expect(std.mem.indexOf(u8, lldb.out, "main.toy:4") != null);
    }
    // Every other check ran; the skip marks that the lldb one could not.
    if (lldb_broken) return error.SkipZigTest;
}

const branch_prog =
    \\import std/io
    \\fn pick(n: int) -> int {
    \\    if n == 1 {
    \\        return 10
    \\    } else if n == 2 {
    \\        return 20
    \\    }
    \\    r := match n {
    \\        3 -> 30,
    \\        _ -> 40
    \\    }
    \\    return r
    \\}
    \\fn main() -> int {
    \\    io.println(pick(3))
    \\    return pick(4) - 40
    \\}
    \\
;

/// The line of every row `dwarfdump --debug-line` output `dd` lists in the file whose name
/// ends in `/name`.
fn fileLines(gpa: std.mem.Allocator, dd: []const u8, name: []const u8) ![]u64 {
    const quoted = try std.fmt.allocPrint(gpa, "/{s}\"", .{name});
    defer gpa.free(quoted);
    var file: ?u64 = null;
    var index: u64 = 0;
    var lines: std.ArrayList(u64) = .empty;
    errdefer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, dd, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "file_names[")) {
            const close = std.mem.indexOfScalar(u8, l, ']').?;
            index = try std.fmt.parseInt(u64, std.mem.trim(u8, l["file_names[".len..close], " "), 10);
        } else if (std.mem.indexOf(u8, l, "name: ") != null and std.mem.endsWith(u8, l, quoted)) {
            file = index;
        } else if (std.mem.startsWith(u8, l, "0x")) {
            var f = std.mem.tokenizeScalar(u8, l, ' ');
            _ = f.next();
            const line = try std.fmt.parseInt(u64, f.next().?, 10);
            _ = f.next();
            if (try std.fmt.parseInt(u64, f.next().?, 10) == file orelse return error.TestUnexpectedResult) try lines.append(gpa, line);
        }
    }
    return lines.toOwnedSlice(gpa);
}

test "profiles: an else-if, a match arm and a fn's epilogue each sit on their own line (#157)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const dir = ".toy-test-profiles-dwarf-branch";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    for (debug_cases[0..2]) |c| {
        const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, c.name });
        defer gpa.free(sub);
        const exe = try harness.compile(gpa, io, sub, branch_prog, c.flags);
        defer gpa.free(exe);
        try testing.expectEqual(@as(u8, 0), try harness.runExit(gpa, io, exe));

        const dd = (try harness.runTool(gpa, io, null, &.{ "dwarfdump", "--debug-line", exe })) orelse return error.SkipZigTest;
        defer freeOut(gpa, dd);
        errdefer std.debug.print("{s}:\n{s}\n", .{ c.name, dd.out });
        // A bundled module has no file on disk, so it must not name one under the comp dir.
        try testing.expect(std.mem.indexOf(u8, dd.out, "name: \"/<toy>/std/io.toy\"") != null);
        try testing.expect(std.mem.indexOf(u8, dd.out, "name: \"std/io.toy\"") == null);

        const lines = try fileLines(gpa, dd.out, "main.toy");
        defer gpa.free(lines);
        var seen = [_]bool{false} ** 32;
        for (lines) |l| seen[@min(l, seen.len - 1)] = true;
        // `pick`'s `else if`, both arms, and the closing brace that holds its shared epilogue.
        for ([_]u64{ 2, 3, 4, 5, 6, 8, 9, 10, 12, 13 }) |want| {
            errdefer std.debug.print("{s}: no row for line {d}\n", .{ c.name, want });
            try testing.expect(seen[want]);
        }
    }
}

const lines_prog =
    \\fn add(a: int, b: int) -> int {
    \\    c := a + b
    \\    return c
    \\}
    \\fn main() -> int {
    \\    x := add(2, 3)
    \\    return x - 5
    \\}
    \\
;

fn rowLines(gpa: std.mem.Allocator, io: Io, exe: []const u8) !?[]u64 {
    const rows = (try lineRows(gpa, io, exe)) orelse return null;
    defer gpa.free(rows);
    const lines = try gpa.alloc(u64, rows.len);
    for (rows, lines) |r, *l| l.* = r[1];
    return lines;
}

test "profiles: a warm debug build follows lines an edit moved, reusing the code it can (#157)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);

    const root = ".toy-test-profiles-lines";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root ++ "/cold");
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/main.toy", .data = lines_prog });
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
    defer gpa.free(cwd);

    const n = (try codegenStats(gpa, io, cwd, &.{ "-o", "p" }))[0];
    const exe = try std.fs.path.join(gpa, &.{ cwd, "p" });
    defer gpa.free(exe);
    const before = (try rowLines(gpa, io, exe)) orelse return error.SkipZigTest;
    defer gpa.free(before);
    // Each fn: its prologue, its statements, its epilogue on the closing brace (the exit
    // block follows the entry block), then the overflow checks' continuation and panic.
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 2, 3, 2, 2, 5, 6, 7, 8, 7, 7 }, before);

    // A comment inside `main` moves its return down a line: only `main` is lowered again.
    const in_main = try std.mem.replaceOwned(u8, gpa, lines_prog, "    return x - 5", "    # why\n    return x - 5");
    defer gpa.free(in_main);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/main.toy", .data = in_main });
    try testing.expectEqual([2]usize{ 1, n - 1 }, try codegenStats(gpa, io, cwd, &.{ "-o", "p" }));
    const moved = (try rowLines(gpa, io, exe)).?;
    defer gpa.free(moved);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 2, 3, 2, 2, 5, 6, 8, 9, 8, 8 }, moved);

    // A line above every function moves them all: the code is reused, the lines follow.
    const top = try std.mem.concat(gpa, u8, &.{ "# top\n", in_main });
    defer gpa.free(top);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/main.toy", .data = top });
    try testing.expectEqual([2]usize{ 0, n }, try codegenStats(gpa, io, cwd, &.{ "-o", "p" }));
    const shifted = (try rowLines(gpa, io, exe)).?;
    defer gpa.free(shifted);
    try testing.expectEqualSlices(u64, &.{ 2, 3, 5, 3, 4, 3, 3, 6, 7, 9, 10, 9, 9 }, shifted);

    // The warm image is the one a cold build makes.
    const warm = try Io.Dir.cwd().readFileAlloc(io, root ++ "/p", gpa, .unlimited);
    defer gpa.free(warm);
    _ = try codegenStats(gpa, io, cwd, &.{ "-o", "cold/p", "--no-cache" });
    const cold = try Io.Dir.cwd().readFileAlloc(io, root ++ "/cold/p", gpa, .unlimited);
    defer gpa.free(cold);
    try testing.expectEqualSlices(u8, cold, warm);
}
