//! Build profiles (#154): `--release` / `--profile debug|release` pick the IR passes, `-O`
//! overrides the profile's choice, and the profile is part of every codegen cache key and of
//! the default output folder.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const harness = @import("harness.zig");
const ObjRead = @import("toy_compiler").ObjRead;

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
    return harness.toyIn(gpa, io, cwd_abs, args);
}

/// A macOS tool (codesign, atos, lldb) run over a binary, or null when the host lacks it
/// or the binary is not one this host runs.
fn hostTool(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !?Out {
    if ((try harness.config()).runner != .native) return null;
    return harness.runTool(gpa, io, null, argv);
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
    try harness.requireToy(io);

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

test "profiles: a bad or conflicting profile is a usage error, for check too (#154)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.requireToy(io);

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
        .{ .argv = &.{ "check", "--profile", "fast", path }, .line = bad },
        .{ .argv = &.{ "check", "--release", "--profile", "debug", path }, .line = "error: --release conflicts with --profile\n" },
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

test "profiles: check takes --release and --profile, default debug (#380)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.requireToy(io);

    const dir = ".toy-test-profiles-check";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = dir ++ "/main.toy";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = prog });

    for ([_][]const []const u8{
        &.{ "check", path },
        &.{ "check", "--release", path },
        &.{ "check", "--profile", "release", path },
        &.{ "check", "--profile=debug", path },
    }) |argv| {
        const res = try toyIn(gpa, io, null, argv);
        defer freeOut(gpa, res);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
    }
    const help = try toyIn(gpa, io, null, &.{ "check", "--help" });
    defer freeOut(gpa, help);
    try testing.expect(std.mem.indexOf(u8, help.out, "--release") != null);
    try testing.expect(std.mem.indexOf(u8, help.out, "--profile") != null);
}

test "profiles: core/target reads the target and the profile the build names (#380)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

    const dir = ".toy-test-profiles-target";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const src =
        \\import core/target_selftest
        \\fn main() -> int { return target_selftest.selftest() }
        \\
    ;
    // os macos (1), arch aarch64 (1), then the profile: debug 1, release 2. One cache
    // serves every build, so a stale entry would show as the other profile's digit.
    const cases = [_]struct { flags: []const []const u8, want: u8 }{
        .{ .flags = &.{}, .want = 111 },
        .{ .flags = &.{"--release"}, .want = 112 },
        .{ .flags = &.{ "--profile", "debug", "-O1" }, .want = 111 },
        .{ .flags = &.{ "--profile", "release", "-O0" }, .want = 112 },
        .{ .flags = &.{}, .want = 111 },
    };
    for (cases, 0..) |c, i| {
        const sub = try std.fmt.allocPrint(gpa, "{s}/{d}", .{ dir, i });
        defer gpa.free(sub);
        const flags = try std.mem.concat(gpa, []const u8, &.{ &.{harness.dev_core_imports}, c.flags });
        defer gpa.free(flags);
        const bin = try harness.compile(gpa, io, sub, src, flags);
        defer gpa.free(bin);
        try testing.expectEqual(c.want, try harness.runExit(gpa, io, bin));
    }
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
    try harness.skipUnlessRunnable(io);

    const root = ".toy-test-profiles-cache";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/main.toy", .data = prog });
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
    defer gpa.free(cwd);
    try Io.Dir.cwd().createDirPath(io, root ++ "/only_main");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/only_main/main.toy", .data = "fn main() -> int {\n    return 0\n}\n" });
    const cwd_main = try Io.Dir.cwd().realPathFileAlloc(io, root ++ "/only_main", gpa);
    defer gpa.free(cwd_main);

    const cold = try codegenStats(gpa, io, cwd, &.{});
    try testing.expect(cold[0] > 0);
    try testing.expectEqual(@as(usize, 0), cold[1]);
    const n = cold[0];
    const main_units = (try codegenStats(gpa, io, cwd_main, &.{}))[0];
    // The runtime builds as release under either profile, and its C callback adapters
    // carry no lines, so a release build reuses a debug build's copies of those alone.
    const shared = (try codegenStats(gpa, io, cwd_main, &.{"--release"}))[1];
    try testing.expect(shared > 0 and shared < main_units);

    try testing.expectEqual([2]usize{ n - shared, shared }, try codegenStats(gpa, io, cwd, &.{"--release"}));
    try testing.expectEqual([2]usize{ 0, n }, try codegenStats(gpa, io, cwd, &.{}));
    try testing.expectEqual([2]usize{ 0, n }, try codegenStats(gpa, io, cwd, &.{ "--profile", "release" }));
    // A debug build with release's passes still differs in what the profile decides beyond
    // the passes, so it must not reuse release's code. The runtime's units build as release
    // with debug's line tables under either, so the debug build's copies serve it.
    const runtime_units = main_units - 1;
    try testing.expectEqual([2]usize{ n - runtime_units, runtime_units }, try codegenStats(gpa, io, cwd, &.{"-O1"}));

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

/// One function per checked operator, width and signedness, each called from `main` on
/// the case its first argument names, so one build covers every case without -O1 folding
/// the operands away. `folded` multiplies a literal by a local holding one, which -O1
/// folds; two literals alone would be a constant expression the checker rejects.
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
    \\fn negu8(a: uint8) -> uint8 { 0 -% a }
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
    \\fn rem(a: int, b: int) -> int { a % b }
    \\fn remby16(mut x: int16, d: int16) { x %= d }
    \\fn div32(a: int32, b: int32) -> int32 { a / b }
    \\fn rem32(a: int32, b: int32) -> int32 { a % b }
    \\fn divu8(a: uint8, b: uint8) -> uint8 { a / b }
    \\fn remu(a: uint, b: uint) -> uint { a % b }
    \\fn folded() -> int {
    \\    a := 4
    \\    x := a * 4611686018427387904
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
    \\    if c == 28 { io.println(rem(-9223372036854775808, -1)) }
    \\    if c == 29 {
    \\        x: int16 = -32768
    \\        remby16(x, -1)
    \\        io.println(x)
    \\    }
    \\    if c == 30 { io.println(div32(-2147483648, -1)) }
    \\    if c == 31 { io.println(rem32(-2147483648, -1)) }
    \\    if c == 32 { io.println(rem(-9223372036854775807, -1)) }
    \\    if c == 33 { io.println(div(5, 0)) }
    \\    if c == 34 { io.println(rem(-5, 0)) }
    \\    if c == 35 { io.println(divu8(5, 0)) }
    \\    if c == 36 { io.println(remu(5, 0)) }
    \\}
    \\
;

/// Each case's overflow panic in a debug build (null: it does not overflow) and its output
/// in a release build, which wraps; or the panic it gives in every profile.
const overflow_cases = [_]struct { panic: ?[]const u8 = null, wraps_to: []const u8 = "", always: ?[]const u8 = null }{
    .{ .panic = "'+'", .wraps_to = "-128" },
    .{ .panic = "'-'", .wraps_to = "127" },
    .{ .panic = "'*'", .wraps_to = "-128" },
    .{ .panic = "'*'", .wraps_to = "-128" },
    .{ .panic = "negation", .wraps_to = "-128" },
    .{ .panic = "'+'", .wraps_to = "0" },
    .{ .panic = "'-'", .wraps_to = "255" },
    .{ .panic = "'*'", .wraps_to = "0" },
    .{ .panic = null, .wraps_to = "255" },
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
    .{ .panic = "'%'", .wraps_to = "0" },
    .{ .panic = "'%'", .wraps_to = "0" },
    .{ .panic = "'%'", .wraps_to = "0" },
    .{ .panic = "'/'", .wraps_to = "-2147483648" },
    .{ .panic = "'%'", .wraps_to = "0" },
    .{ .panic = null, .wraps_to = "0" },
    .{ .always = "division by zero" },
    .{ .always = "remainder by zero" },
    .{ .always = "division by zero" },
    .{ .always = "remainder by zero" },
};

fn runCase(gpa: std.mem.Allocator, io: Io, exe: []const u8, case: usize) !Out {
    var arg_buf: [8]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "{d}", .{case});
    const r = try harness.run(gpa, io, .{ .argv = &.{ exe, arg } });
    return .{ .out = r.stdout, .err = r.stderr, .term = r.term };
}

test "profiles: debug panics on integer overflow at -O0 and -O1, release wraps; a zero divisor panics in both (#155, #428)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

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
            if (c.always != null or (b.traps and c.panic != null)) {
                const want = if (c.always) |m| try std.fmt.allocPrint(gpa, "{s}\n", .{m}) else try std.fmt.allocPrint(gpa, "integer overflow in {s}\n", .{c.panic.?});
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

test "profiles: a debug build lists its functions in its symbol table and to lldb, release has no symbols (#156)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

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
        if (try hostTool(gpa, io, &.{ "codesign", "-v", exe })) |cs| {
            defer freeOut(gpa, cs);
            errdefer std.debug.print("codesign: {s}\n", .{cs.err});
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, cs.term);
        }

        const bytes = try Io.Dir.cwd().readFileAlloc(io, exe, gpa, .unlimited);
        defer gpa.free(bytes);
        const syms = try ObjRead.symbols(try ObjRead.parse(bytes), gpa);
        defer gpa.free(syms);
        if (!c.debug) {
            try testing.expectEqual(@as(usize, 0), syms.len);
            continue;
        }
        var sq_addr: ?u64 = null;
        for ([_][]const u8{ "_main", "_main.apply", "_util.sq", "_util.ident$int", "_main$l0" }) |want| {
            const sym = for (syms) |sym| {
                if (std.mem.eql(u8, sym.name, want)) break sym;
            } else {
                std.debug.print("{s}: no symbol {s}\n", .{ c.name, want });
                return error.TestExpectedSymbol;
            };
            // Local text symbols, as `nm` shows with `t`.
            try testing.expect(sym.defined and !sym.external);
            if (std.mem.eql(u8, want, "_util.sq")) sq_addr = sym.addr;
        }

        // Crash reports symbolicate as atos does, from the same table.
        const addr = try std.fmt.allocPrint(gpa, "0x{x}", .{sq_addr.?});
        defer gpa.free(addr);
        if (try hostTool(gpa, io, &.{ "atos", "-o", exe, "-l", "0x100000000", addr })) |atos| {
            defer freeOut(gpa, atos);
            errdefer std.debug.print("atos {s}:\n{s}{s}\n", .{ addr, atos.out, atos.err });
            try testing.expect(std.mem.startsWith(u8, atos.out, "util.sq (in prog)"));
        }

        // lldb's '-n' splits a dotted name like a Swift 'module.fn' and finds nothing; '-F'
        // matches the full symbol name.
        const lldb = (try hostTool(gpa, io, &.{ "lldb", "--batch", "--no-lldbinit", "-o", "breakpoint set -F util.sq", exe })) orelse {
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
    if (lldb_broken) return harness.runner.skip(io, "no working lldb on this host; every other check ran");
}

/// The profiles debug info is checked under: debug at its own -O0 and at -O1 (`-O` stays
/// an override), and release, which carries none. Debug -O1
/// leaves inlining out: an inlined callee's code takes its caller's lines, and the link
/// drops the callee. It leaves mem2reg out too: a statement that only writes a local keeps
/// no code once the local is a value, so its line has no row.
const debug_cases = [_]struct { name: []const u8, flags: []const []const u8, debug: bool }{
    .{ .name = "debug", .flags = &.{ "--profile", "debug" }, .debug = true },
    .{ .name = "debug-O1", .flags = &.{ "--profile", "debug", "-O", "1", "--no-opt", "inline", "--no-opt", "mem2reg" }, .debug = true },
    .{ .name = "release", .flags = &.{ "--profile", "release" }, .debug = false },
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

/// `exe`'s DWARF line table, or null when it carries none (caller deinits).
fn lineTable(gpa: std.mem.Allocator, io: Io, exe: []const u8) !?ObjRead.LineTable {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, exe, gpa, .unlimited);
    defer gpa.free(bytes);
    const t = (try ObjRead.lineTable(try ObjRead.parse(bytes), gpa)) orelse return null;
    // The names point into `bytes`; keep copies past its free.
    const files = try gpa.alloc([]const u8, t.files.len);
    var n: usize = 0;
    errdefer {
        for (files[0..n]) |f| gpa.free(f);
        gpa.free(files);
        t.deinit(gpa);
    }
    for (t.files) |f| {
        files[n] = try gpa.dupe(u8, f);
        n += 1;
    }
    gpa.free(t.files);
    return .{ .files = files, .rows = t.rows };
}

fn freeLineTable(gpa: std.mem.Allocator, t: ObjRead.LineTable) void {
    for (t.files) |f| gpa.free(f);
    t.deinit(gpa);
}

/// Each line-table row's address, line and file index, end-of-sequence rows included.
fn lineRows(gpa: std.mem.Allocator, io: Io, exe: []const u8) !?[]const [3]u64 {
    const t = (try lineTable(gpa, io, exe)) orelse return null;
    defer freeLineTable(gpa, t);
    const rows = try gpa.alloc([3]u64, t.rows.len);
    for (t.rows, rows) |r, *out| out.* = .{ r.addr, r.line, r.file };
    return rows;
}

test "profiles: a debug build maps code to toy lines in DWARF, release carries none (#157)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

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
        if (try hostTool(gpa, io, &.{ "codesign", "-v", exe })) |cs| {
            defer freeOut(gpa, cs);
            errdefer std.debug.print("codesign: {s}\n", .{cs.err});
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, cs.term);
        }

        const rows = (try lineRows(gpa, io, exe)) orelse {
            try testing.expect(!c.debug);
            continue;
        };
        defer gpa.free(rows);
        try testing.expect(c.debug);
        // ObjRead decodes only the line program; the system verifier, where there is one,
        // checks the rest of the DWARF too.
        if (builtin.os.tag == .macos) if (try hostTool(gpa, io, &.{ "dwarfdump", "--verify", exe })) |v| {
            defer freeOut(gpa, v);
            errdefer std.debug.print("dwarfdump --verify:\n{s}{s}\n", .{ v.out, v.err });
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, v.term);
            try testing.expect(std.mem.indexOf(u8, v.out, "No errors.") != null);
        };
        // Every row names a file of the table and a line of a source.
        const t = (try lineTable(gpa, io, exe)).?;
        defer freeLineTable(gpa, t);
        for (rows) |r| {
            try testing.expect(t.fileName(r[2]) != null);
            try testing.expect(r[1] > 0);
        }

        // Every row symbolicates to its toy file and line, as a crash report would.
        var argv: std.ArrayList([]const u8) = .empty;
        defer {
            for (argv.items[5..]) |a| gpa.free(a);
            argv.deinit(gpa);
        }
        try argv.appendSlice(gpa, &.{ "atos", "-o", exe, "-l", "0x100000000" });
        for (rows) |r| try argv.append(gpa, try std.fmt.allocPrint(gpa, "0x{x}", .{r[0]}));
        if (try hostTool(gpa, io, argv.items)) |atos| {
            defer freeOut(gpa, atos);
            errdefer std.debug.print("atos:\n{s}{s}\n", .{ atos.out, atos.err });
            for ([_][]const u8{ "main (in prog) (main.toy:2)", "main (in prog) (main.toy:3)", "main (in prog) (main.toy:4)", "main (in prog) (main.toy:5)", "util.sq (in prog) (util.toy:2)", "util.sq (in prog) (util.toy:3)" }) |want| {
                try testing.expect(std.mem.indexOf(u8, atos.out, want) != null);
            }
        }

        const lldb = (try hostTool(gpa, io, &.{ "lldb", "--batch", "--no-lldbinit", "-o", "breakpoint set -f util.toy -l 3", "-o", "run", "-o", "bt", exe })) orelse {
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
    if (lldb_broken) return harness.runner.skip(io, "no working lldb on this host; every other check ran");
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

/// The line of every row of `t` in the file whose name ends in `/name`.
fn fileLines(gpa: std.mem.Allocator, t: ObjRead.LineTable, name: []const u8) ![]u64 {
    const suffix = try std.fmt.allocPrint(gpa, "/{s}", .{name});
    defer gpa.free(suffix);
    const file: u64 = for (t.files, 1..) |f, i| {
        if (std.mem.endsWith(u8, f, suffix)) break i;
    } else return error.TestUnexpectedResult;
    var lines: std.ArrayList(u64) = .empty;
    errdefer lines.deinit(gpa);
    for (t.rows) |r| if (r.file == file) try lines.append(gpa, r.line);
    return lines.toOwnedSlice(gpa);
}

fn hasFile(t: ObjRead.LineTable, name: []const u8) bool {
    for (t.files) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

test "profiles: an else-if, a match arm and a fn's epilogue each sit on their own line (#157)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

    const dir = ".toy-test-profiles-dwarf-branch";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    for (debug_cases[0..2]) |c| {
        const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, c.name });
        defer gpa.free(sub);
        const exe = try harness.compile(gpa, io, sub, branch_prog, c.flags);
        defer gpa.free(exe);
        try testing.expectEqual(@as(u8, 0), try harness.runExit(gpa, io, exe));

        const t = (try lineTable(gpa, io, exe)).?;
        defer freeLineTable(gpa, t);
        // A bundled module has no file on disk, so it must not name one under the comp dir.
        try testing.expect(hasFile(t, "/<toy>/std/io.toy"));
        try testing.expect(!hasFile(t, "std/io.toy"));

        const lines = try fileLines(gpa, t, "main.toy");
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

/// The lines of the rows in `main.toy`, file 1: the runtime's rows follow in files of
/// their own.
fn rowLines(gpa: std.mem.Allocator, io: Io, exe: []const u8) !?[]u64 {
    const rows = (try lineRows(gpa, io, exe)) orelse return null;
    defer gpa.free(rows);
    var lines: std.ArrayList(u64) = .empty;
    errdefer lines.deinit(gpa);
    for (rows) |r| if (r[2] == 1) try lines.append(gpa, r[1]);
    return try lines.toOwnedSlice(gpa);
}

test "profiles: a warm debug build follows lines an edit moved, reusing the code it can (#157)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

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
    const before = (try rowLines(gpa, io, exe)).?;
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
