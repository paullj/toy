//! User dylibs through the CLI: `extern "name"` blocks and `-l`/`-L` against the C
//! libraries build.zig builds into zig-out/test-lib (tests/corpora/language-features/
//! ffi/clib). Each library is its own LC_LOAD_DYLIB, the binary runs at -O0 and -O1, a
//! -j1 build equals a -j8 one, and a warm rebuild follows a changed library set.

const std = @import("std");
const Io = std.Io;
const harness = @import("harness.zig");

const test_lib_dir: []const u8 = @import("test_options").test_lib_dir;

const calls_src =
    \\import std/io
    \\
    \\extern "toyffi" {
    \\    fn toyffi_add(a: int, b: int) -> int
    \\    fn toyffi_neg32(x: int32) -> int32
    \\    fn toyffi_scale(x: float, k: float) -> float
    \\    fn toyffi_mix(n: int, x: float) -> float
    \\    fn toyffi_counter_new(start: int) -> rawptr
    \\    fn toyffi_counter_bump(p: rawptr) -> int
    \\    fn toyffi_counter_free(p: rawptr)
    \\}
    \\
    \\extern "toyffi2" { fn toyffi2_twice(x: int) -> int }
    \\
    \\fn main() -> int {
    \\    a := unsafe { toyffi_add(40, 2) }
    \\    b := unsafe { toyffi_neg32(-5) }
    \\    s := unsafe { toyffi_scale(1.5, 4.0) }
    \\    m := unsafe { toyffi_mix(2, 0.25) }
    \\    c := unsafe { toyffi_counter_new(1) }
    \\    unsafe { toyffi_counter_bump(c) }
    \\    n := unsafe { toyffi_counter_bump(c) }
    \\    unsafe { toyffi_counter_free(c) }
    \\    t := unsafe { toyffi2_twice(n) }
    \\    io.println(if a == 42 && b == 5 && s == 6.0 && m == 2.25 && t == 6 { "ok" } else { "bad" })
    \\    0
    \\}
    \\
;

test "user dylibs: int, float and rawptr calls run at -O0 and -O1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    try harness.expectStdoutAtBothLevelsWith(gpa, io, ".toy-test-ffi-levels", calls_src, &.{ "-L", test_lib_dir }, "ok\n");
}

const cstr_src =
    \\import std/io
    \\import std/ffi
    \\import std/gc
    \\
    \\extern "toyffi" {
    \\    fn toyffi_greeting() -> cstr
    \\    fn toyffi_nothing() -> cstr
    \\    fn toyffi_echo(s: cstr) -> cstr
    \\    fn toyffi_shout(s: cstr) -> cstr
    \\}
    \\
    \\extern {
    \\    fn strlen(s: cstr) -> int
    \\    fn free(p: cstr)
    \\}
    \\
    \\fn main() -> int {
    \\    back := unsafe { toyffi_echo("round ".concat("trip").to_cstr()) }
    \\    gc.collect()
    \\    loud := unsafe { toyffi_shout(back) }
    \\    s := loud.to_str()
    \\    unsafe { free(loud) }
    \\    g := unsafe { toyffi_greeting() }
    \\    ok := back.to_str() == "round trip" && s == "ROUND TRIP!" && unsafe { strlen(g) } == 12 && unsafe { toyffi_nothing() }.is_null()
    \\    io.println(if ok { g.to_str() } else { "bad" })
    \\    0
    \\}
    \\
;

test "user dylibs: cstr params and returns run at -O0 and -O1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    try harness.expectStdoutAtBothLevelsWith(gpa, io, ".toy-test-ffi-cstr", cstr_src, &.{ "-L", test_lib_dir }, "hello from C\n");
}

const structs_src =
    \\import std/io
    \\import std/ffi
    \\import std/gc
    \\
    \\extern struct Small { a: int32, b: int8, c: int16 }
    \\extern struct Big { a: int, b: int, c: int, d: int8 }
    \\extern struct Vec2f { x: f32, y: f32 }
    \\extern struct Rect { min: Vec2f, max: Vec2f }
    \\extern struct Named { name: cstr, data: rawptr, n: uint16 }
    \\
    \\extern "toyffi" {
    \\    fn toyffi_small_make(a: int32, b: int8, c: int16) -> Small
    \\    fn toyffi_big_make(a: int) -> Big
    \\    fn toyffi_rect_grow(r: Rect, d: f32) -> Rect
    \\    fn toyffi_small_fill(mut s: Small, a: int32)
    \\    fn toyffi_named_echo(n: Named) -> Named
    \\    fn toyffi_scalef(x: f32, k: f32) -> f32
    \\    fn toyffi_counter_new(start: int) -> rawptr
    \\    fn toyffi_counter_bump(p: rawptr) -> int
    \\}
    \\
    \\fn main() -> int {
    \\    s := unsafe { toyffi_small_make(1, -2, 3) }
    \\    unsafe { toyffi_small_fill(s, 4) }
    \\    b := unsafe { toyffi_big_make(2) }
    \\    r := unsafe { toyffi_rect_grow(Rect { min: Vec2f { x: 1.0, y: 1.0 }, max: Vec2f { x: 2.0, y: 3.0 } }, 0.5) }
    \\    n := Named { name: "na".concat("me").to_cstr(), data: unsafe { toyffi_counter_new(s.a.into()) }, n: 1 }
    \\    gc.collect()
    \\    e := unsafe { toyffi_named_echo(n) }
    \\    gc.collect()
    \\    k := unsafe { toyffi_scalef(r.max.y, 2.0) }
    \\    ok := s.a == 5 && s.b == -1 && s.c == 300 && b.c == 6 && b.d == -2 && r.min.x == 0.5 && k == 7.0 && e.n == 2 && unsafe { toyffi_counter_bump(e.data) } == 6
    \\    io.println(if ok { e.name.to_str() } else { "bad" })
    \\    0
    \\}
    \\
;

test "user dylibs: f32 and extern structs by value and by pointer run at -O0 and -O1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    try harness.expectStdoutAtBothLevelsWith(gpa, io, ".toy-test-ffi-structs", structs_src, &.{ "-L", test_lib_dir }, "name\n");
}

const callbacks_src =
    \\import std/io
    \\import std/gc
    \\import std/vec
    \\
    \\extern struct Small { a: int32, b: int8, c: int16 }
    \\extern struct Big { a: int, b: int, c: int, d: int8 }
    \\extern struct I64 { v: int }
    \\extern struct Three { a: int, b: int, c: int }
    \\
    \\extern "toyffi" {
    \\    fn toyffi_each(n: int, cb: fn(int) -> int) -> int
    \\    fn toyffi_cb_narrow(cb: fn(int8, uint16, int32, bool, f32) -> int32) -> int
    \\    fn toyffi_cb_small(cb: fn(Small, int32) -> Small) -> int
    \\    fn toyffi_cb_big(cb: fn(Big) -> Big) -> int
    \\}
    \\
    \\extern {
    \\    fn qsort(mut base: Three, n: int, size: int, cmp: fn(rawptr, rawptr) -> int32)
    \\    fn memcpy(mut dst: I64, src: rawptr, n: int) -> rawptr
    \\}
    \\
    \\struct Ops { n: int }
    \\
    \\impl Ops {
    \\    fn tri(i: int) -> int { i * 3 }
    \\}
    \\
    \\struct Wrap[T] { v: T }
    \\
    \\impl Wrap[T] {
    \\    fn quad(i: int) -> int { i * 4 }
    \\}
    \\
    \\fn read(p: rawptr) -> int {
    \\    c := I64 { v: 0 }
    \\    unsafe { memcpy(c, p, 8) }
    \\    c.v
    \\}
    \\
    \\fn desc(a: rawptr, b: rawptr) -> int32 {
    \\    junk: Vec[str] = []
    \\    junk.push("x".concat("y"))
    \\    gc.collect()
    \\    if read(a) < read(b) { 1 } else if read(a) > read(b) { -1 } else { 0 }
    \\}
    \\
    \\fn main() -> int {
    \\    keep: Vec[str] = []
    \\    keep.push("o".concat("k"))
    \\    fn twice(i: int) -> int { i * 2 }
    \\    a := unsafe { toyffi_each(5, twice) }
    \\    b := unsafe { toyffi_each(3, fn(i) { i + 1 }) }
    \\    n := unsafe { toyffi_cb_narrow(fn(x, y, z, t, f) { if x == -3 && y == 65535 && z == -100000 && t && f == 1.5 { 7 } else { 0 } }) }
    \\    s := unsafe { toyffi_cb_small(fn(sm, k) { Small { a: sm.a + k, b: sm.b, c: sm.c } }) }
    \\    g := unsafe { toyffi_cb_big(fn(bg) { bg }) }
    \\    c := unsafe { toyffi_each(4, Ops.tri) } + unsafe { toyffi_each(3, Wrap[int].quad) }
    \\    t := Three { a: 1, b: 3, c: 2 }
    \\    unsafe { qsort(t, 3, 8, desc) }
    \\    ok := a == 20 && b == 6 && c == 30 && n == 7 && s == 29998017 && g == -3679 && t.a == 3 && t.b == 2 && t.c == 1
    \\    io.println(if ok { keep[0] } else { "bad" })
    \\    0
    \\}
    \\
;

test "user dylibs: capture-free toy fns as C callbacks run at -O0 and -O1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    try harness.expectStdoutAtBothLevelsWith(gpa, io, ".toy-test-ffi-callbacks", callbacks_src, &.{ "-L", test_lib_dir }, "ok\n");
}

const varargs_src =
    \\import std/io
    \\import std/ffi
    \\
    \\extern struct Pair {
    \\    x: int,
    \\    y: int32,
    \\    z: bool,
    \\}
    \\
    \\extern "toyffi" {
    \\    fn toyffi_va_sum(scale: float, kinds: cstr, ...) -> float
    \\    fn toyffi_va_pair(p: Pair, n: int32, ...) -> int
    \\    fn toyffi_va_spill(a: int, b: int, c: int, d: int, e: int, f: int, g: int, h: int, i: int32, ...) -> int
    \\    fn toyffi_va_map(cb: fn(int) -> int, n: int, ...) -> int
    \\}
    \\
    \\extern {
    \\    fn snprintf(buf: cstr, n: int, f: cstr, ...) -> int32
    \\    fn malloc(n: int) -> cstr
    \\    fn free(p: cstr)
    \\}
    \\
    \\fn sq(x: int) -> int { x * x }
    \\
    \\fn main() -> int {
    \\    q := unsafe { toyffi_va_map(sq, 3, 1, 2, 3) }
    \\    r := unsafe { toyffi_va_map(fn(x) { x + 1 }, 2, 10, 20) }
    \\    s := unsafe { toyffi_va_sum(2.0, "ifif".to_cstr(), 1, 0.5, 3, 0.25) }
    \\    none := unsafe { toyffi_va_sum(1.0, "".to_cstr()) }
    \\    p := unsafe { toyffi_va_pair(Pair { x: 100, y: 20, z: true }, 3, 1, 2, 3) }
    \\    m := unsafe { toyffi_va_spill(1, 2, 3, 4, 5, 6, 7, 8, 9, 1000, 2.5, "A".to_cstr()) }
    \\    buf := unsafe { malloc(64) }
    \\    n := unsafe { snprintf(buf, 64, "%s=%lld/%.2f".to_cstr(), "k".to_cstr(), -12, 0.125) }
    \\    t := buf.to_str()
    \\    unsafe { free(buf) }
    \\    ok := q == 14 && r == 32 && s == 9.5 && none == 0.0 && p == 135 && m == 45 + 1000 + 25 + 65 && n == 10 && t == "k=-12/0.12"
    \\    io.println(if ok { t } else { "bad" })
    \\    0
    \\}
    \\
;

test "user dylibs: C varargs (ints, floats, cstr; a struct and stack args before them) run at -O0 and -O1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    try harness.expectStdoutAtBothLevelsWith(gpa, io, ".toy-test-ffi-varargs", varargs_src, &.{ "-L", test_lib_dir }, "k=-12/0.12\n");
}

test "user dylibs: a -j1 build equals a -j8 build at -O0 and -O1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-j0", calls_src, &.{ "-O0", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-j1", calls_src, &.{ "-O1", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-sj0", structs_src, &.{ "-O0", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-sj1", structs_src, &.{ "-O1", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-cj0", callbacks_src, &.{ "-O0", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-cj1", callbacks_src, &.{ "-O1", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-vj0", varargs_src, &.{ "-O0", "-L", test_lib_dir }, 0);
    try harness.expectDeterministicBuild(gpa, io, ".toy-test-ffi-vj1", varargs_src, &.{ "-O1", "-L", test_lib_dir }, 0);
}

/// Run the built `toy` with `args` in `cwd_abs`, capturing its output (caller frees).
fn toyIn(gpa: std.mem.Allocator, io: Io, cwd_abs: []const u8, args: []const []const u8) !struct { out: []u8, err: []u8, code: u8 } {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, harness.toy_exe);
    try argv.appendSlice(gpa, args);
    var child = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = cwd_abs }, .stdout = .pipe, .stderr = .pipe });
    var ro = child.stdout.?.readerStreaming(io, &.{});
    const out = try ro.interface.allocRemaining(gpa, .limited(1 << 20));
    errdefer gpa.free(out);
    var re = child.stderr.?.readerStreaming(io, &.{});
    const err = try re.interface.allocRemaining(gpa, .limited(1 << 20));
    errdefer gpa.free(err);
    const term = try child.wait(io);
    return .{ .out = out, .err = err, .code = if (term == .exited) term.exited else 255 };
}

fn expectToy(gpa: std.mem.Allocator, io: Io, cwd: []const u8, args: []const []const u8, code: u8, stream: enum { out, err }, needles: []const []const u8) !void {
    const r = try toyIn(gpa, io, cwd, args);
    defer gpa.free(r.out);
    defer gpa.free(r.err);
    const text = if (stream == .out) r.out else r.err;
    errdefer std.debug.print("toy {s} {s} -> {d}\nstdout: {s}\nstderr: {s}\n", .{ args[0], args[1], r.code, r.out, r.err });
    try std.testing.expectEqual(code, r.code);
    for (needles) |n| {
        if (std.mem.indexOf(u8, text, n) == null) return error.TestExpectedSubstring;
    }
}

/// A fresh `root` with `files` written under it; returns its absolute path (owned).
fn project(gpa: std.mem.Allocator, io: Io, root: []const u8, files: []const [2][]const u8) ![:0]u8 {
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    for (files) |f| {
        const path = try std.fs.path.join(gpa, &.{ root, f[0] });
        defer gpa.free(path);
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = f[1] });
    }
    return Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
}

const add_src = "extern \"toyffi\" { fn toyffi_add(a: int, b: int) -> int }\nfn main() -> int { unsafe { toyffi_add(40, 2) } }\n";

test "library errors: a bad -l is a coded usage error, a bad extern library a diagnostic at its block" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    const root = ".toy-test-ffi-errors";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const w = try project(gpa, io, root, &.{
        .{ "main.toy", add_src },
        .{ "missing.toy", "extern \"toy-no-such-lib\" { fn f() -> int }\nfn main() -> int { unsafe { f() } }\n" },
        .{ "vendor/libbad.dylib", "not a library\n" },
        .{ "vendor/libarc.a", "!<arch>\n" },
    });
    defer gpa.free(w);

    inline for (.{ "build", "check" }) |verb| {
        try expectToy(gpa, io, w, &.{ verb, "main.toy", "-L", test_lib_dir, "-l", "toy-no-such-lib" }, 2, .err, &.{ "error[R0016]: library 'toy-no-such-lib' not found: no libtoy-no-such-lib.dylib in ", "/usr/local/lib, /usr/lib, the dyld shared cache (-l toy-no-such-lib)" });
        try expectToy(gpa, io, w, &.{ verb, "main.toy", "-L", test_lib_dir, "-lfoo.a" }, 2, .err, &.{"error[R0015]: library 'foo.a' is a static library; toy links only dynamic libraries (.dylib) (-l foo.a)"});
        try expectToy(gpa, io, w, &.{ verb, "main.toy", "-L", test_lib_dir, "-L", "vendor", "-l", "arc" }, 2, .err, &.{"error[R0015]: library 'arc' is only a static library ('vendor/libarc.a')"});
        try expectToy(gpa, io, w, &.{ verb, "main.toy", "-L", test_lib_dir, "-L", "vendor", "-l", "bad" }, 2, .err, &.{"error[R0017]: library 'bad' cannot be linked: 'vendor/libbad.dylib': it is not a Mach-O file"});
        try expectToy(gpa, io, w, &.{ verb, "main.toy", "-L", "no-such-dir" }, 2, .err, &.{"invalid value 'no-such-dir' for -L (a directory)"});
        try expectToy(gpa, io, w, &.{ verb, "missing.toy" }, 1, .out, &.{ "error[R0016]: library 'toy-no-such-lib' not found", "missing.toy:1:8" });
        try expectToy(gpa, io, w, &.{ verb, "main.toy" }, 1, .out, &.{"error[R0016]: library 'toyffi' not found"});
    }
    try expectToy(gpa, io, w, &.{ "check", "main.toy", "-L", test_lib_dir, "-l", "toyffi2" }, 0, .out, &.{});
    try expectToy(gpa, io, w, &.{ "run", "main.toy", "-L", test_lib_dir, "-o", "p0" }, 42, .out, &.{"p0 exited with code 42"});
}

test "warm rebuild: a changed library set relinks, and equals a cold build" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try harness.skipUnlessBackend(io);
    const root = ".toy-test-ffi-warm";
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    const lib = try Io.Dir.cwd().readFileAlloc(io, test_lib_dir ++ "/libtoyffi.dylib", gpa, .unlimited);
    defer gpa.free(lib);
    const w = try project(gpa, io, root, &.{ .{ "main.toy", add_src }, .{ "alt/libtoyffi.dylib", lib } });
    defer gpa.free(w);
    const alt = try std.fs.path.join(gpa, &.{ w, "alt" });
    defer gpa.free(alt);

    try harness.buildIn(gpa, io, w, &.{ "build", "main.toy", "-L", test_lib_dir, "-o", "p1" });
    try std.testing.expectEqual(@as(u8, 42), try harness.runExitIn(gpa, io, w, "p1"));
    const first = try readIn(gpa, io, w, "p1");
    defer gpa.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, test_lib_dir) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "libtoyffi2") == null);

    // Warm: the same sources, but the library now comes from alt/ and a second one is
    // loaded, so the rpath and the load commands must change.
    try harness.buildIn(gpa, io, w, &.{ "build", "main.toy", "-L", alt, "-L", test_lib_dir, "-l", "toyffi2", "-o", "p2" });
    try std.testing.expectEqual(@as(u8, 42), try harness.runExitIn(gpa, io, w, "p2"));
    const warm = try readIn(gpa, io, w, "p2");
    defer gpa.free(warm);
    try std.testing.expect(std.mem.indexOf(u8, warm, alt) != null);
    try std.testing.expect(std.mem.indexOf(u8, warm, "@rpath/libtoyffi2.dylib") != null);

    try harness.buildIn(gpa, io, w, &.{ "build", "main.toy", "-L", alt, "-L", test_lib_dir, "-l", "toyffi2", "-o", "p2", "--no-cache" });
    const cold = try readIn(gpa, io, w, "p2");
    defer gpa.free(cold);
    try std.testing.expectEqualSlices(u8, cold, warm);
}

fn readIn(gpa: std.mem.Allocator, io: Io, cwd_abs: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ cwd_abs, rel });
    defer gpa.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}
