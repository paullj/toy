//! Where the tests run the programs they build. `TOY_TEST_TARGET` (a `--target` triple;
//! the host by default) picks what toy builds for, and `TOY_TEST_RUNNER` how the binary
//! runs: `native` (the default) on this machine, or `docker:<platform>` (for example
//! `docker:linux/arm64`) in a container, so a Mac runs Linux binaries.
//!
//! A test that runs a binary asks `skipReason` first: a runner that cannot run the target,
//! or a target toy cannot emit yet, is a skip that names why, never a failure.

const std = @import("std");
const Io = std.Io;
const toyc = @import("toy_compiler");
pub const Target = toyc.Target;

/// The script that starts a container; scripts and agents call the same one.
const docker_script: []const u8 = @import("runner_options").docker_script;

pub const Runner = union(enum) {
    native,
    /// A Linux container of this arch.
    docker: Target.Arch,

    pub fn parse(s: []const u8) error{UnknownRunner}!Runner {
        if (std.mem.eql(u8, s, "native")) return .native;
        if (std.mem.startsWith(u8, s, "docker:")) {
            const platform = s["docker:".len..];
            for (std.enums.values(Target.Arch)) |a| {
                if (std.mem.eql(u8, platform, dockerPlatform(a))) return .{ .docker = a };
            }
        }
        return error.UnknownRunner;
    }

    /// Whether this runner can run a binary built for `t`, or why not. A container shares
    /// the kernel of the Linux VM docker runs in, so it runs only Linux binaries.
    pub fn cannotRun(r: Runner, t: Target) ?[]const u8 {
        switch (r) {
            .native => {
                const h = Target.host orelse return "this host is not a target toy builds for";
                if (!h.eql(t)) return "TOY_TEST_RUNNER=native runs only binaries for this host; set TOY_TEST_RUNNER=docker:<platform> for a Linux target";
            },
            .docker => |a| {
                if (t.os != .linux) return "a docker runner runs only Linux binaries";
                if (t.arch != a) return "the docker platform's arch is not the target's";
            },
        }
        return null;
    }
};

/// The `--platform` docker takes for a Linux container of `arch`.
pub fn dockerPlatform(arch: Target.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "linux/arm64",
        .x86_64 => "linux/amd64",
    };
}

pub const Config = struct {
    target: Target,
    runner: Runner,
    /// Whether `TOY_TEST_TARGET` named the target. Only then do builds pass `--target`,
    /// so a default run drives toy exactly as a user does.
    explicit_target: bool,

    /// From the two variables' values (null or empty: unset).
    pub fn parse(target: ?[]const u8, runner: ?[]const u8) !Config {
        const t_set = target != null and target.?.len != 0;
        const r_set = runner != null and runner.?.len != 0;
        return .{
            .target = if (t_set) try Target.parse(target.?) else Target.host orelse return error.UnsupportedHost,
            .runner = if (r_set) try Runner.parse(runner.?) else .native,
            .explicit_target = t_set,
        };
    }

    /// From the environment's `TOY_TEST_TARGET` and `TOY_TEST_RUNNER`, through `get`
    /// (a `Environ.getPosix` or a `Environ.Map.get`).
    pub fn fromEnv(env: anytype, get: anytype) !Config {
        return parse(get(env, "TOY_TEST_TARGET"), get(env, "TOY_TEST_RUNNER"));
    }

    /// The flags that point a `toy build` at the target, in `buf`: none unless
    /// `TOY_TEST_TARGET` named one, so a default run builds exactly as a user does.
    pub fn targetArgs(c: Config, buf: *[2][]const u8) []const []const u8 {
        if (!c.explicit_target) return &.{};
        buf.* = .{ "--target", c.target.name() };
        return buf;
    }

    /// Why a test that builds and runs a binary cannot, or null when it can.
    pub fn skipReason(c: Config) ?[]const u8 {
        if (!toyc.link.canEmit(c.target)) return "toy cannot emit code for the test target yet (R0021)";
        return c.runner.cannotRun(c.target);
    }
};

/// Say why a test skips, then skip it. The reason goes to a terminal only: under
/// `zig build test` the test's stderr is the build runner's, which reports any output of
/// a passing test as a failed command.
pub fn skip(io: Io, reason: []const u8) error{SkipZigTest} {
    note(io, "skip: {s}\n", .{reason});
    return error.SkipZigTest;
}

/// `std.debug.print`, to a terminal only (see `skip`).
pub fn note(io: Io, comptime fmt: []const u8, args: anytype) void {
    if (Io.File.stderr().isTty(io) catch false) std.debug.print(fmt, args);
}

pub const RunOptions = struct {
    /// The binary's host path, then its arguments.
    argv: []const []const u8,
    /// Absolute; the binary's own folder in a container when null.
    cwd: ?[]const u8 = null,
    /// The program's whole environment; the runner's own when null.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Written to the program's stdin, which is then closed; no stdin when null. All of it
    /// is written before any output is read, so the program must read it before it writes
    /// a pipe buffer (64 KiB) of output, or the run deadlocks.
    stdin: ?[]const u8 = null,
    stdout_limit: Io.Limit = .limited(1 << 22),
    stderr_limit: Io.Limit = .limited(1 << 22),
    timeout: Io.Timeout = .none,
    /// The stack limit the program starts with, in KiB; the runner's own when null.
    stack_kib: ?u32 = null,
};

/// Run a built binary through `r`, both output streams captured (caller frees them).
/// Under `zig build test` the test binary's stdio is the build runner's protocol pipe, so
/// nothing is inherited.
pub fn run(r: Runner, gpa: std.mem.Allocator, io: Io, o: RunOptions) !std.process.RunResult {
    switch (r) {
        .native => {
            const kib = o.stack_kib orelse return spawnCapture(gpa, io, o.argv, o.cwd, o.environ_map, o);
            // The limit is set in a shell that then becomes the program, as `ulimit` only
            // changes the process it runs in.
            const script = try std.fmt.allocPrint(gpa, "ulimit -s {d} && exec \"$0\" \"$@\"", .{kib});
            defer gpa.free(script);
            const argv = try std.mem.concat(gpa, []const u8, &.{ &.{ "/bin/sh", "-c", script }, o.argv });
            defer gpa.free(argv);
            return spawnCapture(gpa, io, argv, o.cwd, o.environ_map, o);
        },
        .docker => |a| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            var owned: std.ArrayList([]u8) = .empty;
            defer {
                for (owned.items) |s| gpa.free(s);
                owned.deinit(gpa);
            }
            // The container's name and the file the script records the program's end in,
            // both unique per run. The status file sits by the binary, which the container
            // mounts anyway.
            var nonce: [8]u8 = undefined;
            io.random(&nonce);
            const hex = std.fmt.bytesToHex(nonce, .lower);
            const name = try std.fmt.allocPrint(gpa, "toy-run-{s}", .{&hex});
            try owned.append(gpa, name);
            const status = try std.fmt.allocPrint(gpa, "{s}/.toy-run-{s}.status", .{ std.fs.path.dirname(o.argv[0]) orelse ".", &hex });
            try owned.append(gpa, status);
            defer Io.Dir.cwd().deleteFile(io, status) catch {};

            try argv.appendSlice(gpa, &.{ "bash", docker_script, dockerPlatform(a), "-n", name, "-S", status });
            if (o.cwd) |c| try argv.appendSlice(gpa, &.{ "-C", c });
            if (o.stack_kib) |kib| {
                const s = try std.fmt.allocPrint(gpa, "{d}", .{kib});
                try owned.append(gpa, s);
                try argv.appendSlice(gpa, &.{ "-s", s });
            }
            if (o.environ_map) |env| {
                var it = env.iterator();
                while (it.next()) |kv| {
                    const s = try std.fmt.allocPrint(gpa, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* });
                    try owned.append(gpa, s);
                    try argv.appendSlice(gpa, &.{ "-e", s });
                }
            }
            try argv.append(gpa, "--");
            try argv.appendSlice(gpa, o.argv);
            // Killing the docker client on a timeout leaves its container running, so the
            // container is killed by name.
            var res = spawnCapture(gpa, io, argv.items, null, null, o) catch |err| {
                killContainer(io, name);
                return err;
            };
            errdefer {
                gpa.free(res.stdout);
                gpa.free(res.stderr);
            }
            res.term = readStatus(gpa, io, status) catch |err| {
                std.debug.print("{s} failed ({any}): {s}\n", .{ docker_script, res.term, res.stderr });
                return err;
            };
            return res;
        },
    }
}

fn killContainer(io: Io, name: []const u8) void {
    var child = std.process.spawn(io, .{ .argv = &.{ "docker", "kill", name }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

/// How the program ended, from the line `run-docker.sh -S` wrote. No line means it never
/// ran: docker or the exec failed.
fn readStatus(gpa: std.mem.Allocator, io: Io, path: []const u8) !std.process.Child.Term {
    const line = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return error.RunnerFailed,
        else => return err,
    };
    defer gpa.free(line);
    return parseStatus(line) orelse error.RunnerFailed;
}

fn parseStatus(line: []const u8) ?std.process.Child.Term {
    var it = std.mem.tokenizeAny(u8, line, " \n");
    const how = it.next() orelse return null;
    const n = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (std.mem.eql(u8, how, "exit")) return .{ .exited = n };
    if (std.mem.eql(u8, how, "signal")) return .{ .signal = @enumFromInt(n) };
    return null;
}

fn spawnCapture(gpa: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map, o: RunOptions) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .stdin = if (o.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    if (o.stdin) |bytes| {
        // A program that exits without reading its input closes the pipe first; that is
        // the program's business.
        child.stdin.?.writeStreamingAll(io, bytes) catch |err| switch (err) {
            error.BrokenPipe => {},
            else => return err,
        };
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, o.timeout)) |_| {
        if (o.stdout_limit.toInt()) |l| if (mr.reader(0).buffered().len > l) return error.StreamTooLong;
        if (o.stderr_limit.toInt()) |l| if (mr.reader(1).buffered().len > l) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    const out = try mr.toOwnedSlice(0);
    errdefer gpa.free(out);
    return .{ .term = term, .stdout = out, .stderr = try mr.toOwnedSlice(1) };
}

const testing = std.testing;

test "runner: TOY_TEST_RUNNER names native or a docker platform" {
    try testing.expectEqual(Runner.native, try Runner.parse("native"));
    try testing.expectEqual(Runner{ .docker = .aarch64 }, try Runner.parse("docker:linux/arm64"));
    try testing.expectEqual(Runner{ .docker = .x86_64 }, try Runner.parse("docker:linux/amd64"));
    for ([_][]const u8{ "", "docker", "docker:", "docker:linux/riscv64", "docker:arm64", "qemu" }) |s|
        try testing.expectError(error.UnknownRunner, Runner.parse(s));
}

test "runner: unset variables mean the host and native" {
    const c = Config.parse(null, "") catch |e| switch (e) {
        error.UnsupportedHost => return error.SkipZigTest,
        else => return e,
    };
    try testing.expect(c.target.eql(Target.host.?));
    try testing.expectEqual(Runner.native, c.runner);
    try testing.expect(!c.explicit_target);
    const x = try Config.parse("x86_64-linux", "docker:linux/amd64");
    try testing.expect(x.target.eql(Target.x86_64_linux) and x.explicit_target);
    try testing.expectError(error.UnknownTarget, Config.parse("bogus", null));
    var buf: [2][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), c.targetArgs(&buf).len);
    const args = x.targetArgs(&buf);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x86_64-linux", args[1]);
}

test "runner: native runs the host's binaries, docker the Linux ones of its arch" {
    const docker_arm: Runner = .{ .docker = .aarch64 };
    try testing.expect(docker_arm.cannotRun(Target.aarch64_linux) == null);
    try testing.expect(docker_arm.cannotRun(Target.x86_64_linux) != null);
    try testing.expect(docker_arm.cannotRun(Target.aarch64_macos) != null);
    const docker_x86: Runner = .{ .docker = .x86_64 };
    try testing.expect(docker_x86.cannotRun(Target.x86_64_linux) == null);
    const native: Runner = .native;
    for ([_]Target{ Target.aarch64_macos, Target.aarch64_linux, Target.x86_64_linux }) |t| {
        const native_ok = if (Target.host) |h| h.eql(t) else false;
        try testing.expectEqual(native_ok, native.cannotRun(t) == null);
    }
}

test "runner: a target toy cannot emit is a skip with a reason" {
    for ([_]Target{ Target.aarch64_macos, Target.aarch64_linux, Target.x86_64_linux }) |t| {
        const c: Config = .{ .target = t, .runner = .{ .docker = t.arch }, .explicit_target = true };
        if (!toyc.link.canEmit(t)) try testing.expect(std.mem.indexOf(u8, c.skipReason().?, "R0021") != null);
    }
}

test "runner: native passes args, stdin, env, cwd and the stack limit, and captures both streams" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try expectScriptRuns(gpa, io, .native, ".toy-test-runner-native");
}

// The docker path cannot run a toy binary until toy emits Linux code, so a shell script
// stands in for one: it proves the mount, the arguments, stdin, the environment, the
// working directory, the stack limit and the exit code cross the container.
test "runner: docker runs a program in a Linux container" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!try haveDocker(gpa, io)) return skip(io, "no docker daemon on this host");
    const arch: Target.Arch = if (Target.host) |h| h.arch else .aarch64;
    try expectScriptRuns(gpa, io, .{ .docker = arch }, ".toy-test-runner-docker");
}

/// Whether a docker daemon answers; without one the docker runner tests skip.
fn haveDocker(gpa: std.mem.Allocator, io: Io) !bool {
    const probe = std.process.run(gpa, io, .{ .argv = &.{ "docker", "info", "--format", "{{.OSType}}" } }) catch return false;
    defer gpa.free(probe.stdout);
    defer gpa.free(probe.stderr);
    return probe.term == .exited and probe.term.exited == 0;
}

test "runner: a docker run that times out leaves no container running" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!try haveDocker(gpa, io)) return skip(io, "no docker daemon on this host");
    const dir = ".toy-test-runner-docker-timeout";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/sleeper", .data = "#!/bin/sh\nsleep 120\n", .flags = .{ .permissions = .fromMode(0o755) } });
    const prog = try Io.Dir.cwd().realPathFileAlloc(io, dir ++ "/sleeper", gpa);
    defer gpa.free(prog);
    const arch: Target.Arch = if (Target.host) |h| h.arch else .aarch64;
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
    try testing.expectError(error.Timeout, run(.{ .docker = arch }, gpa, io, .{ .argv = &.{prog}, .timeout = timeout }));

    const dirname = std.fs.path.dirname(prog).?;
    const filter = try std.fmt.allocPrint(gpa, "volume={s}", .{dirname});
    defer gpa.free(filter);
    const ps = try std.process.run(gpa, io, .{ .argv = &.{ "docker", "ps", "-q", "--filter", filter } });
    defer gpa.free(ps.stdout);
    defer gpa.free(ps.stderr);
    try testing.expectEqualStrings("", ps.stdout);
}

fn expectScriptRuns(gpa: std.mem.Allocator, io: Io, r: Runner, comptime dir: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir ++ "/bin");
    try Io.Dir.cwd().createDirPath(io, dir ++ "/work");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/work/marker", .data = "here\n" });
    const perms: Io.File.Permissions = .fromMode(0o755);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir ++ "/bin/prog",
        .data = "#!/bin/sh\nread line\necho \"$line|$1|$2|$GREETING\"\ncat marker\necho oops >&2\nexit 3\n",
        .flags = .{ .permissions = perms },
    });
    const prog = try Io.Dir.cwd().realPathFileAlloc(io, dir ++ "/bin/prog", gpa);
    defer gpa.free(prog);
    const work = try Io.Dir.cwd().realPathFileAlloc(io, dir ++ "/work", gpa);
    defer gpa.free(work);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("GREETING", "hi there");

    const res = try run(r, gpa, io, .{ .argv = &.{ prog, "a b", "c" }, .cwd = work, .environ_map = &env, .stdin = "in\n" });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, res.term);
    try testing.expectEqualStrings("in|a b|c|hi there\nhere\n", res.stdout);
    try testing.expectEqualStrings("oops\n", res.stderr);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/bin/stack", .data = "#!/bin/sh\nulimit -s\n", .flags = .{ .permissions = perms } });
    const stack = try Io.Dir.cwd().realPathFileAlloc(io, dir ++ "/bin/stack", gpa);
    defer gpa.free(stack);
    const big = try run(r, gpa, io, .{ .argv = &.{stack}, .stack_kib = 32768 });
    defer gpa.free(big.stdout);
    defer gpa.free(big.stderr);
    try testing.expectEqualStrings("32768\n", big.stdout);

    // A program's own exit code is never read as a signal or a runner failure, and a
    // program that kills itself dies by that signal.
    const ends = [_]struct { body: []const u8, term: std.process.Child.Term }{
        .{ .body = "exit 127", .term = .{ .exited = 127 } },
        .{ .body = "exit 129", .term = .{ .exited = 129 } },
        .{ .body = "exit 155", .term = .{ .exited = 155 } },
        .{ .body = "kill -HUP $$", .term = .{ .signal = @enumFromInt(1) } },
        .{ .body = "kill -ABRT $$", .term = .{ .signal = @enumFromInt(6) } },
    };
    for (ends, 0..) |e, i| {
        const body = try std.fmt.allocPrint(gpa, "#!/bin/sh\n{s}\n", .{e.body});
        defer gpa.free(body);
        // One file per case: rewriting one path with a different length can reach the
        // container stale through the bind mount, and sh then exits 2 on a bad script.
        const sub = try std.fmt.allocPrint(gpa, dir ++ "/bin/end{d}", .{i});
        defer gpa.free(sub);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = sub, .data = body, .flags = .{ .permissions = perms } });
        const end = try Io.Dir.cwd().realPathFileAlloc(io, sub, gpa);
        defer gpa.free(end);
        const got = try run(r, gpa, io, .{ .argv = &.{end} });
        defer gpa.free(got.stdout);
        defer gpa.free(got.stderr);
        errdefer std.debug.print("{s}: {any}\n", .{ e.body, got.term });
        try testing.expectEqual(e.term, got.term);
    }
}
