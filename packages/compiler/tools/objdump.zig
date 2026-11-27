//! `toy-objdump <command> <binary>`: what a linked toy binary holds, read the same way on
//! every host (`ObjRead`), for scripts that must not depend on otool, nm or dwarfdump.
//!
//!   text       the code section's raw bytes
//!   symbols    `<addr> <local|global> <defined|undefined> <name>` per symbol
//!   libraries  `<name> <compat> <current>` per shared library, in load order
//!   lines      `<addr> <line> <file index> <file name>[ end]` per DWARF line row

const std = @import("std");
const ObjRead = @import("ObjRead");

const usage = "usage: toy-objdump text|symbols|libraries|lines <binary>\n";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var err_buf: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writerStreaming(io, &err_buf);
    if (args.len != 3) {
        try ew.interface.writeAll(usage);
        try ew.interface.flush();
        return 2;
    }
    const cmd = args[1];
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .unlimited) catch |e| {
        try ew.interface.print("toy-objdump: cannot read {s}: {t}\n", .{ args[2], e });
        try ew.interface.flush();
        return 1;
    };
    defer gpa.free(bytes);
    const o = ObjRead.parse(bytes) catch |e| {
        try ew.interface.print("toy-objdump: {s}: {t}\n", .{ args[2], e });
        try ew.interface.flush();
        return 1;
    };

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &ow.interface;
    if (std.mem.eql(u8, cmd, "text")) {
        try w.writeAll(o.text);
    } else if (std.mem.eql(u8, cmd, "symbols")) {
        const syms = try ObjRead.symbols(o, gpa);
        defer gpa.free(syms);
        for (syms) |s| try w.print("0x{x:0>16} {s} {s} {s}\n", .{
            s.addr,
            if (s.external) "global" else "local",
            if (s.defined) "defined" else "undefined",
            s.name,
        });
    } else if (std.mem.eql(u8, cmd, "libraries")) {
        const libs = try ObjRead.libraries(o, gpa);
        defer gpa.free(libs);
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        for (libs) |l| try w.print("{s} {s} {s}\n", .{ l.name, ObjRead.formatVersion(l.compat_version, &a), ObjRead.formatVersion(l.current_version, &b) });
    } else if (std.mem.eql(u8, cmd, "lines")) {
        const t = (try ObjRead.lineTable(o, gpa)) orelse return 0;
        defer t.deinit(gpa);
        for (t.rows) |r| try w.print("0x{x:0>16} {d} {d} {s}{s}\n", .{
            r.addr,
            r.line,
            r.file,
            t.fileName(r.file) orelse "?",
            if (r.end_sequence) " end" else "",
        });
    } else {
        try ew.interface.writeAll(usage);
        try ew.interface.flush();
        return 2;
    }
    try w.flush();
    return 0;
}
