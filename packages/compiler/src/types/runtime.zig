//! The `core/rt` rule (T0082): no runtime fn may reach a GC allocation, so a call to one is
//! never a point where the collector runs. Checked once every body is checked, over the call
//! graph `Alloc` reads.

const std = @import("std");
const Body = @import("../symbols/Body.zig");
const Alloc = @import("../symbols/Alloc.zig");
const Mono = @import("../symbols/Mono.zig");
const StdNames = @import("../symbols/StdNames.zig");
const Sig = @import("../symbols/Sig.zig").Sig;
const Layout = @import("../layout/Engine.zig").Layout;
const Walk = @import("../ast/Walk.zig");
const Typecheck = @import("../types.zig");

/// Report T0082 on every `core/rt` body that can reach an allocation.
pub fn check(
    t: *Typecheck,
    bodies: Body.List,
    sigs: []const Sig,
    methods: []const Typecheck.Method,
    instances: []const Mono.Instance,
    derives: []const Typecheck.DeriveRecipe,
    layouts: []const Layout,
) error{OutOfMemory}!void {
    const gpa = t.gpa;
    const mods = t.graph.mods;
    const modules = try gpa.alloc(Alloc.Module, mods.len);
    defer gpa.free(modules);
    for (mods, modules) |*mc, *m| m.* = .{ .src = .{ .tree = mc.tree, .tokens = mc.tokens, .source = mc.source }, .resolutions = mc.resolutions };
    const p: Alloc.Program = .{
        .modules = modules,
        .prog = .{ .sigs = sigs, .methods = methods, .instances = instances, .layouts = layouts },
        .bodies = bodies,
        .derives = derives,
        .prelude_ids = Typecheck.gatherPreludeIds(t),
        .elem_prims = Alloc.elemPrims(sigs),
    };
    var memo: Alloc.Memo = .{};
    defer memo.deinit(gpa);

    const checked = t.sink.items().len;
    var reported = false;
    for (bodies.items, 0..) |b, bi| {
        const mc = &mods[b.mod];
        if (!StdNames.isRuntimeModule(mc.path)) continue;
        const path = try Alloc.pathFrom(gpa, p, &memo, @intCast(bi)) orelse continue;
        defer gpa.free(path);
        // A body that failed to check has holes (an unresolved callee or operator) the walk
        // reads as allocating, and its own error already stops the build.
        if (pathHasError(t.sink.items()[0..checked], p, path)) continue;

        var msg: std.Io.Writer.Allocating = .init(gpa);
        defer msg.deinit();
        const name_tok = mc.tokens[mc.tree.nodes[b.decl.int()].main_token];
        const name = name_tok.text(mc.source);
        writePath(&msg.writer, p, name, path) catch return error.OutOfMemory;
        const first = Walk.nodeSpan(modules[b.mod].src, path[0].step.node);
        try t.sink.report(.{
            .span = .{ .start = name_tok.start, .end = name_tok.end },
            .code = .T0082,
            .related = .{ .start = first.start, .end = first.end },
            .scope = b.mod,
        }, "core/rt fn '{s}' can reach a GC allocation: {s}", .{ name, msg.written() });
        reported = true;
    }
    if (reported) t.sink.sort();
}

fn pathHasError(diags: []const Typecheck.Diagnostic, p: Alloc.Program, path: []const Alloc.Link) bool {
    for (path) |l| {
        const b = p.bodies.items[l.body];
        const span = Walk.nodeSpan(p.modules[b.mod].src, b.decl);
        for (diags) |d| {
            if (d.severity == .err and d.scope == b.mod and d.byte_offset >= span.start and d.byte_offset < span.end) return true;
        }
    }
    return false;
}

/// `f -> g -> h -> what allocates`: the root by its own name, each callee by its symbol.
fn writePath(w: *std.Io.Writer, p: Alloc.Program, root: []const u8, path: []const Alloc.Link) std.Io.Writer.Error!void {
    try w.writeAll(root);
    for (path[1..]) |l| try w.print(" -> {s}", .{p.bodies.items[l.body].sig.name});
    try w.writeAll(" -> ");
    try Alloc.describe(w, p, path[path.len - 1].step.to.alloc);
}

const testing = std.testing;
const Io = std.Io;
const Graph = @import("../driver/Graph.zig");
const ResolveGraph = @import("../resolve_graph.zig");
const Cache = @import("../query/Cache.zig");

const File = struct { path: []const u8, source: []const u8 };

/// The T0082 messages a program gets, its entry `main.toy` importing the dev-build
/// `core/rt/t` (on disk, as `--dev-core-imports` allows) that `files` hold. Owned by `gpa`.
/// With `other_errors`, other error diagnostics are expected and skipped, else they fail.
/// `on_sigs` sees the checked program's sigs.
fn runtimeErrors(gpa: std.mem.Allocator, comptime dir: []const u8, rt: []const u8, extra: []const File, other_errors: bool, on_sigs: ?*const fn ([]const Sig) anyerror!void) ![]const []const u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir ++ "/core/rt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/main.toy", .data = "import core/rt/t\nfn main() -> int {\n    return 0\n}\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/core/rt/t.toy", .data = rt });
    for (extra) |f| {
        var buf: [256]u8 = undefined;
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, f.path }), .data = f.source });
    }
    const cache = try Cache.init(io, dir ++ "/.cache");
    var graph = try Graph.discover(gpa, io, cache, "native", dir ++ "/main.toy", .{ .allow_core_imports = true });
    defer graph.deinit(gpa);
    try testing.expect(graph.err == null);
    var res = try ResolveGraph.resolveGraph(gpa, &graph);
    defer res.deinit(gpa);
    for (res.diags) |d| if (d.severity == .err) {
        std.debug.print("resolve: {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    };
    var tr = try @import("../types_graph.zig").checkGraph(gpa, &graph, &res, io, 8);
    defer tr.deinit(gpa);
    if (on_sigs) |f| try f(tr.sigs);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |m| gpa.free(m);
        out.deinit(gpa);
    }
    for (tr.diags) |d| {
        if (d.code == .T0082) {
            try out.append(gpa, try gpa.dupe(u8, d.message));
        } else if (d.severity == .err and !other_errors) {
            std.debug.print("unexpected: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freeAll(gpa: std.mem.Allocator, msgs: []const []const u8) void {
    for (msgs) |m| gpa.free(m);
    gpa.free(msgs);
}

fn expectErrors(comptime dir: []const u8, rt: []const u8, extra: []const File, want: []const []const u8) !void {
    return expectErrorsOpt(dir, rt, extra, want, false);
}

fn expectErrorsOpt(comptime dir: []const u8, rt: []const u8, extra: []const File, want: []const []const u8, other_errors: bool) !void {
    const gpa = testing.allocator;
    const got = try runtimeErrors(gpa, dir, rt, extra, other_errors, null);
    defer freeAll(gpa, got);
    errdefer for (got) |m| std.debug.print("got: {s}\n", .{m});
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "T0082: the shipped runtime reaches no allocation" {
    try expectErrors(".toy-test-rt-shipped", "pub fn f() -> int {\n    return 1\n}\n", &.{}, &.{});
}

test "T0082: a runtime fn that calls Vec.new names the call path to gc_alloc" {
    try expectErrors(".toy-test-rt-vec",
        \\import std/vec
        \\pub fn first(s: str) -> int {
        \\    return helper(s)
        \\}
        \\fn helper(s: str) -> int {
        \\    xs := Vec[str].new()
        \\    xs.push(s)
        \\    return xs.len()
        \\}
        \\
    , &.{}, &.{
        "core/rt fn 'first' can reach a GC allocation: first -> core/rt/t.helper -> std/vec.Vec.new$str -> core/mem.ga_new$str -> gc_alloc",
        "core/rt fn 'helper' can reach a GC allocation: helper -> std/vec.Vec.new$str -> core/mem.ga_new$str -> gc_alloc",
    });
}

test "T0082: scalar work, str compares, panics and Vec reads allocate nothing" {
    try expectErrors(".toy-test-rt-clean",
        \\import std/vec
        \\pub fn eq(a: str, b: str) -> bool {
        \\    if a.len() != b.len() { panic("len") }
        \\    return a == b && a < b || a.byte_at(0) == 1
        \\}
        \\pub fn at(xs: Vec[int], i: int) -> int {
        \\    if i > 0 { return xs[i] + at(xs, i - 1) }
        \\    return xs.len()
        \\}
        \\
    , &.{}, &.{});
}

test "T0082: closures, fn values and str concat allocate" {
    try expectErrors(".toy-test-rt-sugar",
        \\pub fn cat(a: str, b: str) -> str {
        \\    return a.concat(b)
        \\}
        \\pub fn call(f: fn(int) -> int) -> int {
        \\    return f(1)
        \\}
        \\pub fn make(k: int) -> int {
        \\    g := fn(x: int) -> int { x + k }
        \\    return 0
        \\}
        \\
    , &.{}, &.{
        "core/rt fn 'cat' can reach a GC allocation: cat -> str concat",
        "core/rt fn 'call' can reach a GC allocation: call -> a call through a fn value",
        "core/rt fn 'make' can reach a GC allocation: make -> a closure",
    });
}

test "T0082: generic instances, methods, fn references and other modules are followed" {
    try expectErrors(".toy-test-rt-follow",
        \\import core/rt/u
        \\pub struct Box { v: int }
        \\impl Box {
        \\    fn show(self) -> str {
        \\        return show_one(self.v)
        \\    }
        \\}
        \\fn show_one[T has Display](x: T) -> str {
        \\    return x.to_string()
        \\}
        \\pub fn method(b: Box) -> int {
        \\    return b.show().len()
        \\}
        \\pub fn other() -> int {
        \\    return u.grow()
        \\}
        \\pub fn named() -> int {
        \\    f := u.grow
        \\    return 0
        \\}
        \\
    , &.{.{ .path = "core/rt/u.toy", .source = "import std/vec\npub fn grow() -> int {\n    return [1, 2].len()\n}\n" }}, &.{
        "core/rt fn 'show' can reach a GC allocation: show -> core/rt/t.show_one$int -> to_string",
        "core/rt fn 'show_one' can reach a GC allocation: show_one -> to_string",
        "core/rt fn 'method' can reach a GC allocation: method -> core/rt/t.Box.show -> core/rt/t.show_one$int -> to_string",
        "core/rt fn 'other' can reach a GC allocation: other -> core/rt/u.grow -> a list literal",
        "core/rt fn 'named' can reach a GC allocation: named -> core/rt/u.grow -> a list literal",
        "core/rt fn 'grow' can reach a GC allocation: grow -> a list literal",
    });
}

test "T0082: protocol witnesses, operators on structs, '?', for-in and Ref.new allocate" {
    try expectErrors(".toy-test-rt-more",
        \\import std/vec
        \\import std/ref
        \\pub protocol Size {
        \\    fn size(self) -> int
        \\}
        \\pub struct P { x: int }
        \\impl P has Size {
        \\    fn size(self) -> int {
        \\        return [self.x].len()
        \\    }
        \\}
        \\fn total[T has Size](x: T) -> int {
        \\    return x.size()
        \\}
        \\pub fn witness(p: P) -> int {
        \\    return total(p)
        \\}
        \\pub struct Q { x: int }
        \\impl Q has Eq {
        \\    fn eq(self, other: Q) -> bool {
        \\        return [self.x].len() == other.x
        \\    }
        \\}
        \\pub fn same(p: Q, q: Q) -> bool {
        \\    return p == q
        \\}
        \\fn same_t[T has Eq](a: T, b: T) -> bool {
        \\    return a == b
        \\}
        \\pub fn same_g(p: Q, q: Q) -> bool {
        \\    return same_t(p, q)
        \\}
        \\pub fn half(x: Option[int]) -> Option[int] {
        \\    v := x?
        \\    return Option.some(v)
        \\}
        \\pub fn walk(xs: Vec[int]) -> int {
        \\    n := 0
        \\    for x in xs { n += x }
        \\    return n
        \\}
        \\pub fn cell() -> int {
        \\    r := Ref.new(1)
        \\    return r.get()
        \\}
        \\
    , &.{}, &.{
        "core/rt fn 'size' can reach a GC allocation: size -> a list literal",
        "core/rt fn 'total' can reach a GC allocation: total -> core/rt/t.P.size$Size -> a list literal",
        "core/rt fn 'witness' can reach a GC allocation: witness -> core/rt/t.total$s0 -> core/rt/t.P.size$Size -> a list literal",
        "core/rt fn 'eq' can reach a GC allocation: eq -> a list literal",
        "core/rt fn 'same' can reach a GC allocation: same -> core/rt/t.Q.eq$Eq -> a list literal",
        "core/rt fn 'same_t' can reach a GC allocation: same_t -> core/rt/t.Q.eq$Eq -> a list literal",
        "core/rt fn 'same_g' can reach a GC allocation: same_g -> core/rt/t.same_t$s1 -> core/rt/t.Q.eq$Eq -> a list literal",
        "core/rt fn 'half' can reach a GC allocation: half -> a '?' conversion",
        "core/rt fn 'walk' can reach a GC allocation: walk -> a for-in loop",
        "core/rt fn 'cell' can reach a GC allocation: cell -> std/ref.Ref.new$int -> ref_new",
    });
}

test "T0082: float, char, fn and derived compares are heap-free" {
    try expectErrors(".toy-test-rt-scalar",
        \\pub struct P { x: int, s: str }
        \\pub fn fl(a: float, b: float) -> bool {
        \\    return a == b && a *. b != 1.0
        \\}
        \\pub fn ch(a: char, b: char) -> bool {
        \\    return a == b || a < b
        \\}
        \\pub fn fv(f: fn(int) -> int, g: fn(int) -> int) -> bool {
        \\    return f == g
        \\}
        \\pub fn derived(p: P, q: P) -> bool {
        \\    return p == q
        \\}
        \\
    , &.{}, &.{});
}

test "T0082: a body with a type error gets no second, T0082 error" {
    try expectErrorsOpt(".toy-test-rt-typeerr",
        \\import std/map
        \\import std/vec
        \\pub fn idx(m: Map[str, int]) -> int {
        \\    return m["k"]
        \\}
        \\pub fn mul(a: float, b: float) -> float {
        \\    return a * b
        \\}
        \\pub fn caller(m: Map[str, int]) -> int {
        \\    return idx(m)
        \\}
        \\pub fn grow() -> int {
        \\    return [1].len()
        \\}
        \\
    , &.{}, &.{
        "core/rt fn 'grow' can reach a GC allocation: grow -> a list literal",
    }, true);
}
