//! End-to-end coverage for std/io's stdin readers on input far larger than a pipe buffer
//! and than either reader's first buffer, so both grow many times. The corpus `# stdin:`
//! directive cannot carry input this large.

const std = @import("std");
const Io = std.Io;
const harness = @import("harness.zig");

const line_len = 70_000;
const rest_len = 100_000;

fn patternByte(i: usize) u8 {
    return @intCast('a' + i % 26);
}

test "io: read_line then read_all over more than 64 KiB of stdin" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessRunnable(io);

    const dir = ".toy-test-io-large-stdin";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const prog = try harness.compile(gpa, io, dir,
        \\import std/io
        \\fn main() {
        \\    first := match io.read_line() {
        \\        .some(l) -> l,
        \\        .none -> "",
        \\    }
        \\    rest := io.read_all()
        \\    sum := 0
        \\    for i in 0..rest.len() { sum += rest.byte_at(i) }
        \\    io.print(first.len())
        \\    io.print(" ")
        \\    io.print(first.byte_at(first.len() - 1))
        \\    io.print(" ")
        \\    io.print(rest.len())
        \\    io.print(" ")
        \\    io.println(sum)
        \\}
        \\
    , &.{});
    defer gpa.free(prog);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    for (0..line_len) |i| try input.append(gpa, patternByte(i));
    try input.append(gpa, '\n');
    var sum: u64 = 0;
    for (0..rest_len) |i| {
        try input.append(gpa, patternByte(i));
        sum += patternByte(i);
    }

    // The program reads all of stdin before it writes anything, so the runner writing the
    // whole input before reading its output cannot deadlock.
    const res = try harness.run(gpa, io, .{ .argv = &.{prog}, .stdin = input.items, .stdout_limit = .limited(1 << 16) });
    gpa.free(res.stderr);
    const out = res.stdout;
    defer gpa.free(out);
    try std.testing.expect(res.term == .exited and res.term.exited == 0);

    const want = try std.fmt.allocPrint(gpa, "{d} {d} {d} {d}\n", .{ line_len, patternByte(line_len - 1), rest_len, sum });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, out);
}
