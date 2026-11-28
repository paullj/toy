//! The aarch64-linux image (#433): what the ELF writer lays out, read back through the
//! object reader on any host, and programs that run on the test target.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const harness = @import("harness.zig");
const ObjRead = @import("toy_compiler").ObjRead;

const hello =
    \\import std/io
    \\
    \\fn main() {
    \\    io.println("hello")
    \\}
    \\
;

const allocating =
    \\import std/gc
    \\import std/io
    \\import std/vec
    \\
    \\fn main() -> int {
    \\    words: Vec[str] = []
    \\    for i in 0..3000 {
    \\        words.push("w".concat(i.to_string()))
    \\    }
    \\    joined := ""
    \\    for i in 0..4 {
    \\        joined = joined.concat(words[i]).concat(",")
    \\    }
    \\    gc.collect()
    \\    total := 0
    \\    for w in words {
    \\        total += w.len()
    \\    }
    \\    io.println(joined.concat(total.to_string()))
    \\    return 7
    \\}
    \\
;

const panicking =
    \\fn deep(n: int) -> int {
    \\    if n == 0 { panic("boom") }
    \\    return deep(n - 1) + 1
    \\}
    \\
    \\fn main() -> int {
    \\    return deep(2)
    \\}
    \\
;

const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_INTERP = 3;
const PT_PHDR = 6;
const PT_GNU_STACK = 0x6474e551;
const PF_X = 1;
const PF_W = 2;
const PF_R = 4;
const DT_NEEDED = 1;
const DT_FLAGS = 30;
const DF_BIND_NOW = 8;

test "an aarch64-linux debug build is a glibc PIE entered at _start, with symbols and lines" {
    const gpa = testing.allocator;
    const io = testing.io;
    try harness.requireToy(io);
    const dir = ".zig-cache/tmp/elf-layout";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const prog = try harness.compile(gpa, io, dir, hello, &.{ "--target", "aarch64-linux" });
    defer gpa.free(prog);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, prog, gpa, .unlimited);
    defer gpa.free(bytes);
    const o = try ObjRead.parse(bytes);
    try testing.expectEqual(ObjRead.Format.elf, o.format);

    const segs = try ObjRead.segments(o, gpa);
    defer gpa.free(segs);
    var loads: [3]u32 = undefined;
    var n_loads: usize = 0;
    var interp: []const u8 = "";
    var stack_flags: ?u32 = null;
    var has_dynamic = false;
    try testing.expectEqual(@as(u32, PT_PHDR), segs[0].kind);
    for (segs) |sg| switch (sg.kind) {
        PT_LOAD => {
            try testing.expectEqual(@as(u64, 0x10000), sg.alignment);
            loads[n_loads] = sg.flags;
            n_loads += 1;
        },
        PT_INTERP => interp = bytes[@intCast(sg.offset)..][0..@intCast(sg.file_size)],
        PT_GNU_STACK => stack_flags = sg.flags,
        PT_DYNAMIC => has_dynamic = true,
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), n_loads);
    try testing.expectEqualSlices(u32, &.{ PF_R, PF_R | PF_X, PF_R | PF_W }, &loads);
    try testing.expectEqualStrings("/lib/ld-linux-aarch64.so.1\x00", interp);
    try testing.expectEqual(@as(?u32, PF_R | PF_W), stack_flags);
    try testing.expect(has_dynamic);

    const libs = try ObjRead.libraries(o, gpa);
    defer gpa.free(libs);
    try testing.expectEqual(@as(usize, 2), libs.len);
    try testing.expectEqualStrings("libc.so.6", libs[0].name);
    try testing.expectEqualStrings("libm.so.6", libs[1].name);
    const dyn = try ObjRead.dynamicEntries(o, gpa);
    defer gpa.free(dyn);
    const flags = for (dyn) |d| {
        if (d.tag == DT_FLAGS) break d.value;
    } else 0;
    try testing.expectEqual(@as(u64, DF_BIND_NOW), flags);

    const syms = try ObjRead.symbols(o, gpa);
    defer gpa.free(syms);
    const entry = std.mem.readInt(u64, bytes[24..32], .little);
    var main_addr: ?u64 = null;
    var start_addr: ?u64 = null;
    for (syms) |s| {
        if (std.mem.eql(u8, s.name, "main")) main_addr = s.addr;
        if (std.mem.eql(u8, s.name, "_start")) start_addr = s.addr;
    }
    try testing.expectEqual(o.text_addr, main_addr.?);
    try testing.expectEqual(entry, start_addr.?);

    const lines = (try ObjRead.lineTable(o, gpa)).?;
    defer lines.deinit(gpa);
    const main_rows = for (lines.rows) |r| {
        if (r.addr == main_addr.? and std.mem.endsWith(u8, lines.fileName(r.file) orelse "", "main.toy")) break r.line;
    } else 0;
    try testing.expectEqual(@as(u64, 3), main_rows);
}

test "hello, an allocating program and a panic run on the test target, debug and release, at -O0 and -O1" {
    const gpa = testing.allocator;
    const io = testing.io;
    try harness.skipUnlessRunnable(io);
    const dir = ".zig-cache/tmp/elf-run";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const Case = struct { src: []const u8, exit: u8, stdout: []const u8, stderr: []const u8 };
    const cases = [_]Case{
        .{ .src = hello, .exit = 0, .stdout = "hello\n", .stderr = "" },
        .{ .src = allocating, .exit = 7, .stdout = "w0,w1,w2,w3,13890\n", .stderr = "" },
        .{ .src = panicking, .exit = 1, .stdout = "", .stderr = "boom\n" },
    };
    for (cases) |c| for ([_][]const []const u8{ &.{"-O0"}, &.{"-O1"}, &.{ "-O0", "--release" }, &.{ "-O1", "--release" } }) |flags| {
        errdefer std.debug.print("flags {s} {s}, program:\n{s}\n", .{ flags[0], if (flags.len > 1) flags[1] else "", c.src });
        const prog = try harness.compile(gpa, io, dir, c.src, flags);
        defer gpa.free(prog);
        const r = try harness.run(gpa, io, .{ .argv = &.{prog} });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try testing.expectEqualStrings(c.stdout, r.stdout);
        try testing.expect(std.mem.startsWith(u8, r.stderr, c.stderr));
        try testing.expectEqual(std.process.Child.Term{ .exited = c.exit }, r.term);
        if (c.exit == 1) {
            // The backtrace walks every toy frame to `main`, on Linux as on macOS.
            try testing.expect(std.mem.indexOf(u8, r.stderr, ".deep\n") != null);
            try testing.expect(std.mem.endsWith(u8, r.stderr, " main\n"));
        }
    };
}
