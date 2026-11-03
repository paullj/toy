//! The differential half of `zig build fuzz`: build one generated program
//! (`fuzz_program.zig`) at each optimization level, with and without `--gc-stress`, run
//! every binary, and require the same exit and the same stdout from all of them. Each
//! level hands the register allocator different code for the same program: -O0 keeps
//! every call and slot, -O1 folds, forwards and inlines, and -O1 without the inliner
//! keeps the calls but not the loads. So a difference is a pass miscompile, an allocator
//! or selector bug that only some shapes reach, or a GC root the stress collector freed
//! under one of them. Debug -O0 is the oracle.
//!
//! The release profile wraps where debug panics on overflow, so release builds are
//! compared with their own oracle, plain `--release`.

const std = @import("std");
const Io = std.Io;
const fuzz_program = @import("fuzz_program.zig");

pub const Variant = struct {
    name: []const u8,
    flags: []const []const u8,
    /// The variant whose result this one must reproduce.
    oracle: usize,
};

pub const variants = [_]Variant{
    .{ .name = "-O0", .flags = &.{"-O0"}, .oracle = 0 },
    .{ .name = "-O1", .flags = &.{"-O1"}, .oracle = 0 },
    .{ .name = "-O1 --no-opt inline", .flags = &.{ "-O1", "--no-opt", "inline" }, .oracle = 0 },
    .{ .name = "-O0 --gc-stress", .flags = &.{ "-O0", "--gc-stress" }, .oracle = 0 },
    .{ .name = "-O1 --gc-stress", .flags = &.{ "-O1", "--gc-stress" }, .oracle = 0 },
    .{ .name = "--release", .flags = &.{"--release"}, .oracle = 5 },
    .{ .name = "--release --gc-stress", .flags = &.{ "--release", "--gc-stress" }, .oracle = 5 },
};

/// How a run ended. A run past `run_timeout` is a result too: a miscompiled loop bound
/// must fail the fuzzer, not hang it.
pub const End = union(enum) {
    exited: u8,
    signal: u32,
    timeout,
    other,

    fn of(term: std.process.Child.Term) End {
        return switch (term) {
            .exited => |c| .{ .exited = c },
            .signal => |s| .{ .signal = @intFromEnum(s) },
            else => .other,
        };
    }

    pub fn format(e: End, w: *Io.Writer) Io.Writer.Error!void {
        switch (e) {
            .exited => |c| try w.print("exit {d}", .{c}),
            .signal => |s| try w.print("signal {d}", .{s}),
            .timeout => try w.writeAll("timeout"),
            .other => try w.writeAll("abnormal end"),
        }
    }
};

pub const Outcome = struct {
    end: End,
    stdout: []const u8,

    pub fn same(a: Outcome, b: Outcome) bool {
        return std.meta.eql(a.end, b.end) and std.mem.eql(u8, a.stdout, b.stdout);
    }
};

pub const Verdict = union(enum) {
    agree,
    /// The program did not build under `variant`; `log` is what toy printed.
    build_failed: struct { variant: usize, log: []u8 },
    /// Every variant ran, and these are their outcomes, in `variants` order.
    differ: [variants.len]Outcome,

    pub fn deinit(v: *Verdict, gpa: std.mem.Allocator) void {
        switch (v.*) {
            .agree => {},
            .build_failed => |b| gpa.free(b.log),
            .differ => |outs| for (outs) |o| gpa.free(o.stdout),
        }
    }
};

/// The index of the first variant whose outcome differs from its oracle's, if any.
pub fn firstMismatch(outs: []const Outcome) ?usize {
    for (variants, 0..) |v, i| {
        if (!outs[i].same(outs[v.oracle])) return i;
    }
    return null;
}

const build_timeout: Io.Duration = .fromSeconds(120);
const run_timeout: Io.Duration = .fromSeconds(30);

/// Build `src` with every variant, run each, and compare. Variant k builds in
/// `work_dir/k`, its own toy cache, so the variants build and run at once. Binaries are
/// named after `tag` so no two builds of a run share a path (macOS may kill a binary
/// rewritten in place), and are deleted once run.
pub fn check(gpa: std.mem.Allocator, io: Io, toy: []const u8, work_dir: []const u8, tag: []const u8, src: []const u8) !Verdict {
    var results: [variants.len]anyerror!Result = undefined;
    var group: Io.Group = .init;
    for (0..variants.len) |k| group.async(io, variantInto, .{ gpa, io, toy, work_dir, tag, src, k, &results[k] });
    try group.await(io);

    var outs: [variants.len]Outcome = undefined;
    var done: usize = 0;
    defer for (results[done..]) |r| if (r) |res| res.deinit(gpa) else |_| {};
    errdefer for (outs[0..done]) |o| gpa.free(o.stdout);
    var failed: ?Verdict = null;
    while (done < variants.len) {
        const res = try results[done];
        done += 1;
        switch (res) {
            .ran => |o| outs[done - 1] = o,
            .build_failed => |log| {
                if (failed == null) failed = .{ .build_failed = .{ .variant = done - 1, .log = log } } else gpa.free(log);
                outs[done - 1] = .{ .end = .other, .stdout = try gpa.dupe(u8, "") };
            },
        }
    }
    if (failed) |f| {
        for (outs) |o| gpa.free(o.stdout);
        return f;
    }
    if (firstMismatch(&outs) == null) {
        for (outs) |o| gpa.free(o.stdout);
        return .agree;
    }
    return .{ .differ = outs };
}

const Result = union(enum) {
    ran: Outcome,
    build_failed: []u8,

    fn deinit(r: Result, gpa: std.mem.Allocator) void {
        switch (r) {
            .ran => |o| gpa.free(o.stdout),
            .build_failed => |log| gpa.free(log),
        }
    }
};

fn variantInto(gpa: std.mem.Allocator, io: Io, toy: []const u8, work_dir: []const u8, tag: []const u8, src: []const u8, k: usize, slot: *anyerror!Result) void {
    slot.* = variant(gpa, io, toy, work_dir, tag, src, k);
}

fn variant(gpa: std.mem.Allocator, io: Io, toy: []const u8, work_dir: []const u8, tag: []const u8, src: []const u8, k: usize) !Result {
    var sub_buf: [16]u8 = undefined;
    const dir_path = try std.fs.path.join(gpa, &.{ work_dir, try std.fmt.bufPrint(&sub_buf, "{d}", .{k}) });
    defer gpa.free(dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "main.toy", .data = src });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ toy, "build", "main.toy", "-o", tag, "--color", "never", "--no-cache" });
    try argv.appendSlice(gpa, variants[k].flags);
    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = dir_path },
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = build_timeout, .clock = .awake }) },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        return .{ .build_failed = try std.mem.concat(gpa, u8, &.{ res.stdout, res.stderr }) };
    }
    defer dir.deleteFile(io, tag) catch {};

    const bin = try std.fs.path.join(gpa, &.{ dir_path, tag });
    defer gpa.free(bin);
    const ran = std.process.run(gpa, io, .{
        .argv = &.{bin},
        .stdout_limit = .limited(1 << 20),
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = run_timeout, .clock = .awake }) },
    }) catch |e| switch (e) {
        error.Timeout => return .{ .ran = .{ .end = .timeout, .stdout = try gpa.dupe(u8, "") } },
        else => return e,
    };
    gpa.free(ran.stderr);
    return .{ .ran = .{ .end = End.of(ran.term), .stdout = ran.stdout } };
}

/// Run `count` generated programs, the k-th from seed `seed +% k`. Returns false (after
/// printing the program, every variant's outcome and where the program was saved) on
/// the first that does not agree.
pub fn fuzz(gpa: std.mem.Allocator, io: Io, toy: []const u8, work_dir: []const u8, seed: u64, count: usize) !bool {
    try Io.Dir.cwd().createDirPath(io, work_dir);
    // toy keeps its cache in its cwd, and opening a cache that earlier runs filled
    // costs more than a cold build of these programs.
    for (0..variants.len) |k| {
        var sub_buf: [16]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "{d}", .{k});
        var dir = try Io.Dir.cwd().openDir(io, work_dir, .{});
        defer dir.close(io);
        dir.deleteTree(io, sub) catch {};
        try dir.createDirPath(io, sub);
    }
    const stamp: u64 = @bitCast(@as(i64, @truncate(Io.Clock.real.now(io).nanoseconds)));

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..count) |k| {
        const prog_seed = seed +% k;
        src.clearRetainingCapacity();
        try fuzz_program.generate(gpa, &src, prog_seed);

        var tag_buf: [64]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "p{x}-{d}", .{ stamp, k });
        var verdict = try check(gpa, io, toy, work_dir, tag, src.items);
        defer verdict.deinit(gpa);
        if (verdict == .agree) {
            if ((k + 1) % 50 == 0) std.debug.print("fuzz: differential: {d}/{d}\n", .{ k + 1, count });
            continue;
        }

        var name_buf: [64]u8 = undefined;
        const saved = try std.fmt.bufPrint(&name_buf, "fail-{d}.toy", .{prog_seed});
        var dir = try Io.Dir.cwd().openDir(io, work_dir, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = saved, .data = src.items });

        std.debug.print("\n==== DIFFERENTIAL FAILURE ====\nprogram seed {d} (saved as {s}/{s}):\n{s}\n", .{ prog_seed, work_dir, saved, src.items });
        switch (verdict) {
            .agree => unreachable,
            .build_failed => |b| std.debug.print("it does not build with {s}:\n{s}\n", .{ variants[b.variant].name, b.log }),
            .differ => |outs| {
                const bad = firstMismatch(&outs).?;
                std.debug.print("{s} differs from {s}:\n", .{ variants[bad].name, variants[variants[bad].oracle].name });
                for (variants, outs) |v, o| std.debug.print("  {s:<22} {f}, stdout:\n{s}\n", .{ v.name, o.end, o.stdout });
            },
        }
        return false;
    }
    return true;
}

test "an outcome matches only the same end and the same stdout" {
    const a: Outcome = .{ .end = .{ .exited = 3 }, .stdout = "1\n" };
    try std.testing.expect(a.same(.{ .end = .{ .exited = 3 }, .stdout = "1\n" }));
    try std.testing.expect(!a.same(.{ .end = .{ .exited = 4 }, .stdout = "1\n" }));
    try std.testing.expect(!a.same(.{ .end = .{ .exited = 3 }, .stdout = "2\n" }));
    try std.testing.expect(!a.same(.{ .end = .timeout, .stdout = "1\n" }));
    try std.testing.expect(!a.same(.{ .end = .{ .signal = 3 }, .stdout = "1\n" }));
}

test "each variant is held to its own profile's oracle" {
    var outs: [variants.len]Outcome = undefined;
    for (&outs, variants) |*o, v| o.* = .{ .end = .{ .exited = if (v.oracle == 0) 1 else 0 }, .stdout = "" };
    try std.testing.expectEqual(null, firstMismatch(&outs));
    outs[3].stdout = "x";
    try std.testing.expectEqual(3, firstMismatch(&outs));
    outs[3].stdout = "";
    outs[variants.len - 1].end = .{ .exited = 1 };
    try std.testing.expectEqual(variants.len - 1, firstMismatch(&outs));
}

test "generated programs build and agree across levels and gc stress" {
    const harness = @import("harness.zig");
    try harness.skipUnlessBackend(std.testing.io);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const work = "zig-out/fuzz-diff-test";
    Io.Dir.cwd().deleteTree(io, work) catch {};
    defer Io.Dir.cwd().deleteTree(io, work) catch {};
    try std.testing.expect(try fuzz(gpa, io, harness.toy_exe, work, 1, 4));
}

test {
    _ = fuzz_program;
}
