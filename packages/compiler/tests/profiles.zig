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

const Out = struct { out: []u8, err: []u8, term: std.process.Child.Term };

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
    const o1_nofold = try harness.emitIr(gpa, io, path, &.{ "-O1", "--no-opt", "fold" });
    defer gpa.free(o1_nofold);

    const same = [_]struct { flags: []const []const u8, want: []const u8 }{
        .{ .flags = &.{}, .want = o0 },
        .{ .flags = &.{ "--profile", "debug" }, .want = o0 },
        .{ .flags = &.{"--release"}, .want = o1 },
        .{ .flags = &.{"--profile=release"}, .want = o1 },
        .{ .flags = &.{ "--release", "-O0" }, .want = o0 },
        .{ .flags = &.{ "--profile", "debug", "-O1" }, .want = o1 },
        .{ .flags = &.{ "--release", "--no-opt", "fold" }, .want = o1_nofold },
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
