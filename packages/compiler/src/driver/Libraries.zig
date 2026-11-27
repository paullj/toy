//! The libraries a program links: every `-l` the command line names, then every
//! library an `extern "name" { .. }` block names, each loaded once, after the target's
//! system libraries. It also binds each extern's C symbol to its block's library. Once
//! the program is checked, `Result.unexportedCalls` checks that each library exports the
//! symbols the program calls. What a library file is and where one is found are the
//! target's object format's, asked through `LibResolver`.
//!
//! It reads only the module ASTs, the checked program and the file system, so `check`
//! reports the same library errors `build` does, and a warm build recomputes the set
//! from the current sources and flags (the linked image is never cached).

const std = @import("std");
const StdNames = @import("../symbols/StdNames.zig");
const Io = std.Io;
const Ast = @import("../ast/Ast.zig");
const Graph = @import("Graph.zig");
const Image = @import("../link/Image.zig");
const LibResolver = @import("../link/LibResolver.zig");
const Walk = @import("../ast/Walk.zig");
const Typecheck = @import("../types.zig");
const Callee = @import("../symbols/Callee.zig").Callee;
const Body = @import("../symbols/Body.zig");
const Sig = @import("../symbols/Sig.zig").Sig;
const codes = @import("../diagnostics/codes.zig");
const Diagnostic = @import("../diagnostics/Diagnostic.zig").Diagnostic;
const model = @import("../diagnostics/model.zig");
const literal = @import("../types/literal.zig");

const sys = LibResolver.system_c_library;

/// The command line's `-l` names and `-L` folders, in order.
pub const Request = struct {
    libs: []const []const u8 = &.{},
    dirs: []const []const u8 = &.{},
};

/// A problem with a `-l` value: a usage error, since it is not in any source file.
/// `note` says what the message's neutral words are on the target.
/// Every code the library checks report. They need a reader of the target's libraries,
/// so a target without one cannot report them.
pub const library_codes = [_]codes.Code{ .R0015, .R0016, .R0017, .R0018, .R0019 };

pub const CliError = struct { code: codes.Code, message: []const u8, note: ?[]const u8 };

/// Everything is allocated in `arena`, so one `deinit` frees it.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    resolver: *const LibResolver.Resolver,
    linking: LibResolver.Linking,
    cli_errors: []const CliError,
    /// At the library string of an `extern "name"` block, or at a conflicting extern.
    diags: []const Diagnostic,
    sites: []const Site,
    /// Parallel to `linking.libraries`.
    exports: []const LibResolver.Exports,
    reexports: LibResolver.Cache,
    conflicted: std.StringHashMapUnmanaged(void),
    /// The notes of `diags` and of `unexported`'s diagnostics.
    note_map: model.Notes.Map,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }

    pub fn ok(self: *const Result) bool {
        return self.cli_errors.len == 0 and self.diags.len == 0;
    }

    /// The notes of the library diagnostics, for a renderer.
    pub fn notes(self: *const Result) model.Notes {
        return .{ .by_message = &self.note_map };
    }

    /// R0019 at each extern the checked program `tc` calls (see `calledExterns`) whose
    /// library does not export it. Allocated in the arena.
    pub fn unexportedCalls(self: *Result, io: Io, graph: *const Graph.Graph, tc: *const Typecheck.GraphResult) ![]const Diagnostic {
        return self.unexported(io, try calledExterns(self.arena.allocator(), graph, tc));
    }

    /// R0019 at each extern whose C symbol is in `called` but whose library does not
    /// export it. Allocated in the arena.
    pub fn unexported(self: *Result, io: Io, called: []const []const u8) ![]const Diagnostic {
        const a = self.arena.allocator();
        var imported: std.StringHashMapUnmanaged(void) = .empty;
        for (called) |s| try imported.put(a, s, {});
        var diags: std.ArrayList(Diagnostic) = .empty;
        // A symbol already in conflict is not checked as well: one error per bad extern.
        for (self.sites) |site| {
            if (!imported.contains(site.sym) or self.conflicted.contains(site.sym)) continue;
            const exports = if (site.bound.library) |l| self.exports[l] else self.resolver.system;
            if (try self.resolver.has(a, io, &self.reexports, exports, site.sym)) continue;
            const s = site.bound.site.?;
            const message = if (site.bare)
                try std.fmt.allocPrint(a, "C symbol '{s}' is not exported by " ++ sys ++ "; a bare 'extern fn' binds to " ++ sys, .{site.sym})
            else
                try std.fmt.allocPrint(a, "C symbol '{s}' is not exported by {f}", .{ site.sym, libPhrase(site.bound.lib) });
            if (site.bare) try putNote(a, &self.note_map, message, try self.resolver.systemNote(a));
            try diags.append(a, .{ .byte_offset = s.start, .end = s.end, .message = message, .scope = s.module, .code = .R0019 });
        }
        return diags.items;
    }
};

/// The C symbols of the externs that some lowered body calls outside an untaken `when`
/// arm. Read from the checked program, not from the lowered code, so the IR passes of
/// one opt level cannot drop a call, and with it an error, that another keeps; and
/// `check` reports what `build` does. A dead fn's calls count: it is lowered too.
pub fn calledExterns(a: std.mem.Allocator, graph: *const Graph.Graph, tc: *const Typecheck.GraphResult) ![]const []const u8 {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    const untaken = try a.alloc(?std.DynamicBitSetUnmanaged, graph.modules.len);
    @memset(untaken, null);
    const has_when = try a.alloc(?bool, graph.modules.len);
    @memset(has_when, null);
    var scanned: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (tc.bodies.items) |body| {
        const m = &graph.modules[body.mod];
        if (has_when[body.mod] == null) has_when[body.mod] = for (m.tokens) |tok| {
            if (tok.tag == .kw_when) break true;
        } else false;
        // With no `when` there is no untaken arm, so the callee table alone names every
        // call; walking each body's tree for the arms cost check ~5% on large programs.
        // A module's fns share its whole table, so each distinct table is scanned once.
        if (!has_when[body.mod].?) {
            const seen = try scanned.getOrPut(a, @intFromPtr(body.nodes.callees.ptr));
            if (seen.found_existing) continue;
            for (body.nodes.callees) |c| switch (c.view()) {
                .direct => |gid| if (tc.sigs[gid].kind == .import) try names.put(a, tc.sigs[gid].name, {}),
                else => {},
            };
            continue;
        }
        if (untaken[body.mod] == null) untaken[body.mod] = try .initEmpty(a, m.nodes.len);
        var v: CallVisitor = .{
            .a = a,
            .src = .{ .tree = m.tree(), .tokens = m.tokens, .source = m.source },
            .nodes = body.nodes,
            .sigs = tc.sigs,
            .untaken = &untaken[body.mod].?,
            .names = &names,
        };
        try Walk.walk(v.src, body.decl, &v);
    }
    return names.keys();
}

/// Records the extern each call in a body names, skipping the arms its `when`s leave out.
/// The walk enters a `when` before its arms, so their nodes are marked before it reaches
/// them; every instance of a template takes the same arm, so marks are per module.
const CallVisitor = struct {
    a: std.mem.Allocator,
    src: Walk.Source,
    nodes: Body.Nodes,
    sigs: []const Sig,
    untaken: *std.DynamicBitSetUnmanaged,
    names: *std.StringArrayHashMapUnmanaged(void),

    pub fn on(v: *CallVisitor, ev: Walk.Event) !void {
        const e = switch (ev) {
            .enter => |e| e,
            else => return,
        };
        if (v.untaken.isSet(e.idx.int())) return;
        const tree = v.src.tree;
        const n = tree.nodes[e.idx.int()];
        if (n.tag == .call) {
            const slot = Callee.callSlot(tree, n) orelse return;
            switch (v.nodes.callee(slot).view()) {
                .direct => |gid| if (v.sigs[gid].kind == .import) try v.names.put(v.a, v.sigs[gid].name, {}),
                else => {},
            }
            return;
        }
        if (!Ast.isWhen(tree, v.src.tokens, e.idx)) return;
        const taken = v.nodes.callee(e.idx).whenTaken() orelse return;
        if (n.tag == .match_expr) {
            for (Ast.rangeSlice(tree, n.rhs.int()), 0..) |arm, k| if (k != taken) try v.mark(arm);
            return;
        }
        const h = Ast.ifHeaderAt(tree, n.rhs.int());
        if (taken != 0) try v.mark(h.then_block) else if (h.else_node != Ast.none) try v.mark(h.else_node);
    }

    fn mark(v: *CallVisitor, arm: Ast.Index) !void {
        var m: struct {
            set: *std.DynamicBitSetUnmanaged,
            pub fn on(self: *@This(), ev: Walk.Event) void {
                switch (ev) {
                    .enter => |e| self.set.set(e.idx.int()),
                    else => {},
                }
            }
        } = .{ .set = v.untaken };
        try Walk.walk(v.src, arm, &m);
    }
};

/// An extern declaration and where it binds its C symbol `sym`.
const Site = struct { bound: Bound, bare: bool, sym: []const u8 };

/// A library lookup's outcome: the library it binds to (null for the system libraries),
/// or nothing when it failed.
const Lookup = ?Bound.Library;

const Builder = struct {
    a: std.mem.Allocator,
    io: Io,
    r: *const LibResolver.Resolver,
    dirs: []const []const u8,
    libraries: std.ArrayList(Image.Library) = .empty,
    /// Parallel to `libraries`.
    exports: std.ArrayList(LibResolver.Exports) = .empty,
    reexports: LibResolver.Cache = .empty,
    search_paths: std.ArrayList([]const u8) = .empty,
    /// Each name looked up so far.
    seen: std.StringHashMapUnmanaged(Lookup) = .empty,

    /// The library a resolved name adds, deduplicated by runtime name.
    fn add(b: *Builder, found: LibResolver.Found) !Bound.Library {
        const d = switch (found) {
            .system => return null,
            .library => |d| d,
            else => unreachable,
        };
        for (b.libraries.items, 0..) |have, i| {
            if (std.mem.eql(u8, have.name, d.library.name)) return @intCast(i);
        }
        if (b.libraries.items.len == b.r.max_libraries) return error.TooManyLibraries;
        try b.libraries.append(b.a, d.library);
        try b.exports.append(b.a, d.exports);
        if (d.search_path) |r| {
            for (b.search_paths.items) |have| {
                if (std.mem.eql(u8, have, r)) break;
            } else try b.search_paths.append(b.a, r);
        }
        return @intCast(b.libraries.items.len - 1);
    }

    /// Why `name` cannot be linked, or null with `library` set.
    fn resolve(b: *Builder, name: []const u8, library: *Bound.Library) !?struct { code: codes.Code, message: []const u8, note: ?[]const u8 } {
        const found = try b.r.find(b.a, b.io, name, b.dirs);
        switch (found) {
            .system, .library => {
                library.* = try b.add(found);
                return null;
            },
            .static => |path| return .{ .code = .R0015, .message = if (std.mem.eql(u8, path, name))
                try std.fmt.allocPrint(b.a, "library '{s}' is a static library; toy links only shared libraries", .{name})
            else
                try std.fmt.allocPrint(b.a, "library '{s}' is only a static library ('{s}'); toy links only shared libraries", .{ name, path }), .note = try b.r.sharedNote(b.a) },
            .not_found => return if (b.r.isPath(name))
                .{ .code = .R0016, .message = try std.fmt.allocPrint(b.a, "library '{s}' not found: no such file", .{name}), .note = null }
            else
                .{ .code = .R0016, .message = try b.notFound(name), .note = try b.r.searchNote(b.a, name) },
            .unusable => |nd| return .{ .code = .R0017, .message = try std.fmt.allocPrint(b.a, "library '{s}' cannot be linked: '{s}': {s}", .{ name, nd.path, nd.why }), .note = try b.r.sharedNote(b.a) },
        }
    }

    fn notFound(b: *Builder, name: []const u8) ![]const u8 {
        var places: std.ArrayList([]const u8) = .empty;
        try places.appendSlice(b.a, b.dirs);
        try places.appendSlice(b.a, b.r.default_dirs);
        if (b.r.cache != null) try places.append(b.a, LibResolver.system_cache);
        var msg: std.ArrayList(u8) = .empty;
        try msg.print(b.a, "library '{s}' not found", .{name});
        for (places.items, 0..) |p, i| {
            const sep = if (i == 0) " in " else if (i + 1 == places.items.len) " or " else ", ";
            try msg.print(b.a, "{s}{s}", .{ sep, p });
        }
        return msg.items;
    }
};

/// A library string's text with its escapes decoded. A malformed escape keeps the raw
/// text, which then fails to resolve with the name as written.
fn libraryName(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    return switch (try literal.decodeString(a, try std.fmt.allocPrint(a, "\"{s}\"", .{raw}))) {
        .ok => |bytes| bytes,
        else => raw,
    };
}

/// Where one extern binds its C symbol. `site` is null for the runtime's own imports.
const Bound = struct {
    library: Library,
    /// The library string, as written; null for the system libraries.
    lib: ?[]const u8,
    site: ?struct { module: u32, start: u32, end: u32 },

    /// An index into the program's libraries; null for the system libraries.
    const Library = ?Image.LibraryIndex;
};

/// R0018 for `sym`, bound by `first` and again by `second` to another library. It sits
/// on a declaration the user can edit: the second, unless that one is in a bundled module
/// and the first is not.
fn conflict(a: std.mem.Allocator, graph: *const Graph.Graph, sym: []const u8, first: Bound, second: Bound) !Diagnostic {
    const s2 = second.site.?;
    const swap = if (first.site) |s1| graph.modules[s2.module].bundled and !graph.modules[s1.module].bundled else false;
    const at = if (swap) first else second;
    const other = if (swap) second else first;
    const where = if (other.site) |o|
        try std.fmt.allocPrint(a, "in module '{s}'", .{graph.modules[o.module].path})
    else
        "by the toy runtime";
    return .{
        .byte_offset = at.site.?.start,
        .end = at.site.?.end,
        .message = try std.fmt.allocPrint(a, "C symbol '{s}' is bound to {f} here but to {f} {s}; a symbol comes from one library", .{ sym, libPhrase(at.lib), libPhrase(other.lib), where }),
        .scope = at.site.?.module,
        .code = .R0018,
    };
}

fn putNote(a: std.mem.Allocator, map: *model.Notes.Map, message: []const u8, note: []const u8) !void {
    try map.put(a, @intFromPtr(message.ptr), .{ .kind = .note, .message = note });
}

/// How a message names the library `lib` (null for the system libraries).
fn libPhrase(lib: ?[]const u8) LibPhrase {
    return .{ .lib = lib };
}

const LibPhrase = struct {
    lib: ?[]const u8,
    pub fn format(p: LibPhrase, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (p.lib) |l| try w.print("library '{s}'", .{l}) else try w.writeAll(sys);
    }
};

/// Whether the program names a library of its own: a `-l`, or an extern in a user
/// module. The bundled modules' externs bind to the system C library, which every
/// target has.
pub fn namesLibraries(graph: *const Graph.Graph, req: Request) bool {
    if (req.libs.len != 0) return true;
    for (graph.modules) |*m| {
        if (m.bundled) continue;
        const tree = m.tree();
        const prog = tree.nodes[Ast.root(tree.nodes).int()];
        if (prog.tag != .program) continue;
        for (Ast.rangeSlice(tree, prog.lhs.int())) |idx| {
            if (tree.nodes[idx.int()].tag == .extern_fn_decl) return true;
        }
    }
    return false;
}

/// Collect and resolve the program's libraries through the target's `resolver`. `graph`
/// must have discovered cleanly.
pub fn collect(gpa: std.mem.Allocator, io: Io, graph: *const Graph.Graph, req: Request, resolver: *const LibResolver.Resolver) !Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .{ .a = a, .io = io, .r = resolver, .dirs = req.dirs };
    var cli_errors: std.ArrayList(CliError) = .empty;
    var diags: std.ArrayList(Diagnostic) = .empty;
    var note_map: model.Notes.Map = .empty;

    for (req.libs) |name| {
        if (b.seen.contains(name)) continue;
        var library: Bound.Library = null;
        if (try b.resolve(name, &library)) |e| {
            try cli_errors.append(a, .{ .code = e.code, .message = try std.fmt.allocPrint(a, "{s} (-l {s})", .{ e.message, name }), .note = e.note });
            try b.seen.put(a, name, null);
        } else try b.seen.put(a, name, library);
    }

    // An import binds by bare C name, so the runtime's own imports are bound first: a
    // block that names one for another library would move the runtime's call there.
    var bound: std.StringArrayHashMapUnmanaged(Bound) = .empty;
    for (graph.modules) |*m| {
        if (!StdNames.isRuntimeModule(m.path)) continue;
        const tree = m.tree();
        const prog = tree.nodes[Ast.root(tree.nodes).int()];
        if (prog.tag != .program) continue;
        for (Ast.rangeSlice(tree, prog.lhs.int())) |idx| {
            const n = tree.nodes[idx.int()];
            if (n.tag != .extern_fn_decl or Ast.externLibrary(tree, m.tokens, m.source, idx) != null) continue;
            try bound.put(a, m.tokens[n.main_token].text(m.source), .{ .library = null, .lib = null, .site = null });
        }
    }
    var sites: std.ArrayList(Site) = .empty;
    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    for (graph.modules, 0..) |*m, mi| {
        const tree = m.tree();
        const prog = tree.nodes[Ast.root(tree.nodes).int()];
        if (prog.tag != .program) continue;
        for (Ast.rangeSlice(tree, prog.lhs.int())) |idx| {
            const n = tree.nodes[idx.int()];
            if (n.tag != .extern_fn_decl) continue;
            const lib = if (Ast.externLibrary(tree, m.tokens, m.source, idx)) |raw| try libraryName(a, raw) else null;
            var library: Bound.Library = null;
            if (lib) |name| {
                const gop = try b.seen.getOrPut(a, name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = null;
                    var l: Bound.Library = null;
                    if (try b.resolve(name, &l)) |e| {
                        const tok = m.tokens[tree.nodes[n.rhs.int()].main_token];
                        if (e.note) |note| try putNote(a, &note_map, e.message, note);
                        try diags.append(a, .{ .byte_offset = tok.start, .end = tok.end, .message = e.message, .scope = @intCast(mi), .code = e.code });
                    } else gop.value_ptr.* = l;
                }
                library = gop.value_ptr.* orelse continue;
            }
            const sym_tok = m.tokens[n.main_token];
            const sym = sym_tok.text(m.source);
            const here: Bound = .{ .library = library, .lib = lib, .site = .{ .module = @intCast(mi), .start = sym_tok.start, .end = sym_tok.end } };
            const gop = try bound.getOrPut(a, sym);
            if (!gop.found_existing) {
                gop.value_ptr.* = here;
            } else if (gop.value_ptr.library != library) {
                const d = try conflict(a, graph, sym, gop.value_ptr.*, here);
                if (gop.value_ptr.library == null or library == null) try putNote(a, &note_map, d.message, try resolver.systemNote(a));
                try diags.append(a, d);
                try conflicted.put(a, sym, {});
            }
            try sites.append(a, .{ .bound = here, .bare = lib == null, .sym = sym });
        }
    }

    var bindings: std.ArrayList(LibResolver.Binding) = .empty;
    for (bound.keys(), bound.values()) |sym, v| {
        if (v.library) |l| try bindings.append(a, .{ .name = sym, .library = l });
    }
    std.mem.sort(LibResolver.Binding, bindings.items, {}, struct {
        fn lt(_: void, x: LibResolver.Binding, y: LibResolver.Binding) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);

    return .{
        .arena = arena,
        .resolver = resolver,
        .linking = .{ .libraries = b.libraries.items, .search_paths = b.search_paths.items, .bindings = bindings.items },
        .cli_errors = cli_errors.items,
        .diags = diags.items,
        .sites = sites.items,
        .exports = b.exports.items,
        .reexports = b.reexports,
        .conflicted = conflicted,
        .note_map = note_map,
    };
}

const testing = std.testing;
const Dylib = @import("../link/Dylib.zig");
const macho = &Dylib.resolver;

fn graphOf(gpa: std.mem.Allocator, src: []const u8) !struct { tokens: []@import("../ast/Token.zig").Token, tree: Ast.Tree, g: Graph.Graph } {
    const tokens = try @import("../lex.zig").tokenize(gpa, src);
    const tree = try @import("../parse.zig").expectTree(gpa, tokens, src);
    const g = try Graph.single(gpa, "main", "", src, tokens, tree.nodes, tree.extra, tree.pub_bits);
    return .{ .tokens = tokens, .tree = tree, .g = g };
}

test "externs bind to their block's library; libSystem names and bare externs stay ordinal 1" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyq.dylib", .data = Dylib.fakeDylibExporting(&buf, "@rpath/libtoyq.dylib", 6, &.{ "q_one", "q_two" }) });

    const src =
        \\extern "toyq" {
        \\    fn q_one() -> int
        \\    fn q_two(x: int) -> int
        \\}
        \\extern "m" { fn sqrt(x: float) -> float }
        \\extern fn labs(x: int) -> int
        \\fn main() -> int { 0 }
        \\
    ;
    var p = try graphOf(gpa, src);
    defer {
        p.g.deinit(gpa);
        gpa.free(p.tree.nodes);
        gpa.free(p.tree.extra);
        gpa.free(p.tokens);
    }
    var r = try collect(gpa, io, &p.g, .{ .dirs = &.{dir} }, macho);
    defer r.deinit();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 1), r.linking.libraries.len);
    try testing.expectEqualStrings(dir, r.linking.search_paths[0]);
    try testing.expectEqual(@as(?Image.LibraryIndex, 0), r.linking.libraryOf("q_one"));
    try testing.expectEqual(@as(?Image.LibraryIndex, 0), r.linking.libraryOf("q_two"));
    try testing.expectEqual(@as(?Image.LibraryIndex, null), r.linking.libraryOf("sqrt"));
    try testing.expectEqual(@as(?Image.LibraryIndex, null), r.linking.libraryOf("labs"));
}

test "a missing or static library is one error at the block; -l problems are usage errors" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const src =
        \\extern "toy-no-such-lib" {
        \\    fn a() -> int
        \\    fn b() -> int
        \\}
        \\extern "libfoo.a" { fn c() }
        \\fn main() -> int { 0 }
        \\
    ;
    var p = try graphOf(gpa, src);
    defer {
        p.g.deinit(gpa);
        gpa.free(p.tree.nodes);
        gpa.free(p.tree.extra);
        gpa.free(p.tokens);
    }
    var r = try collect(gpa, threaded.io(), &p.g, .{ .libs = &.{ "z.o", "toy-no-such-lib" } }, macho);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.cli_errors.len);
    try testing.expectEqual(codes.Code.R0015, r.cli_errors[0].code);
    try testing.expectEqual(codes.Code.R0016, r.cli_errors[1].code);
    try testing.expectEqualStrings("library 'z.o' is a static library; toy links only shared libraries (-l z.o)", r.cli_errors[0].message);
    try testing.expectEqualStrings("library 'toy-no-such-lib' not found in /usr/local/lib, /usr/lib or the system library cache (-l toy-no-such-lib)", r.cli_errors[1].message);
    try testing.expectEqualStrings("on macOS a shared library is lib<name>.dylib", r.cli_errors[0].note.?);
    try testing.expectEqualStrings("on macOS toy looked for libtoy-no-such-lib.dylib, and the system library cache is the dyld shared cache", r.cli_errors[1].note.?);
    // The block's library was already reported for `-l`; the archive is reported once.
    try testing.expectEqual(@as(usize, 1), r.diags.len);
    try testing.expectEqual(codes.Code.R0015, r.diags[0].code);
    try testing.expectEqualStrings("on macOS a shared library is lib<name>.dylib", r.notes().of(r.diags[0])[0].message);
    try testing.expectEqualStrings("\"libfoo.a\"", src[r.diags[0].byte_offset..r.diags[0].end]);
}

test "one C symbol bound to two libraries is R0018 at the second extern" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyz.dylib", .data = Dylib.fakeDylibExporting(&buf, "/opt/libtoyz.dylib", 6, &.{"labs"}) });
    const src =
        \\extern "toyz" { fn labs(x: int) -> int }
        \\extern fn labs(x: int) -> int
        \\fn main() -> int { 0 }
        \\
    ;
    var p = try graphOf(gpa, src);
    defer {
        p.g.deinit(gpa);
        gpa.free(p.tree.nodes);
        gpa.free(p.tree.extra);
        gpa.free(p.tokens);
    }
    var r = try collect(gpa, io, &p.g, .{ .dirs = &.{dir} }, macho);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diags.len);
    try testing.expectEqual(codes.Code.R0018, r.diags[0].code);
    try testing.expectEqualStrings("C symbol 'labs' is bound to the system C library here but to library 'toyz' in module 'main'; a symbol comes from one library", r.diags[0].message);
    try testing.expectEqualStrings("on macOS the system C library is libSystem", r.notes().of(r.diags[0])[0].message);
}

fn graphOfMods(gpa: std.mem.Allocator, mods: []const struct { path: []const u8, src: []const u8, bundled: bool = false }) !Graph.Graph {
    const modules = try gpa.alloc(Graph.Module, mods.len);
    for (mods, modules) |md, *m| {
        const tokens = try @import("../lex.zig").tokenize(gpa, md.src);
        const tree = try @import("../parse.zig").expectTree(gpa, tokens, md.src);
        m.* = .{ .path = md.path, .file = "", .source = @constCast(md.src), .tokens = tokens, .nodes = tree.nodes, .extra = tree.extra, .pub_bits = tree.pub_bits, .bundled = md.bundled };
    }
    return .{ .ownership = .borrowed, .modules = modules };
}

fn freeGraphOfMods(gpa: std.mem.Allocator, g: *Graph.Graph) void {
    for (g.modules) |m| {
        gpa.free(m.tokens);
        gpa.free(m.nodes);
        gpa.free(m.extra);
        if (m.pub_bits.len != 0) gpa.free(m.pub_bits);
    }
    g.deinit(gpa);
}

test "a program names libraries when the command line gives -l or a user module declares an extern" {
    const gpa = testing.allocator;
    var bare = try graphOfMods(gpa, &.{
        .{ .path = "main", .src = "fn main() -> int { 0 }\n" },
        .{ .path = "core/c", .src = "pub extern fn strlen(p: rawptr) -> int\n", .bundled = true },
    });
    defer freeGraphOfMods(gpa, &bare);
    try testing.expect(!namesLibraries(&bare, .{}));
    try testing.expect(namesLibraries(&bare, .{ .libs = &.{"z"} }));
    var ext = try graphOfMods(gpa, &.{.{ .path = "main", .src = "extern fn labs(x: int) -> int\nfn main() -> int { 0 }\n" }});
    defer freeGraphOfMods(gpa, &ext);
    try testing.expect(namesLibraries(&ext, .{}));
}

test "a block that binds a symbol the runtime imports is R0018 at the block's extern" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyz.dylib", .data = Dylib.fakeDylibExporting(&buf, "/opt/libtoyz.dylib", 6, &.{"write"}) });
    const src =
        \\extern "toyz" { fn write(fd: int, p: rawptr, n: int) -> int }
        \\fn main() -> int { 0 }
        \\
    ;
    // The runtime's modules come after the entry's in a graph.
    var g = try graphOfMods(gpa, &.{
        .{ .path = "main", .src = src },
        .{ .path = "core/rt/panic", .src = "extern fn write(fd: int, p: int, n: int) -> int\n", .bundled = true },
    });
    defer freeGraphOfMods(gpa, &g);
    var r = try collect(gpa, io, &g, .{ .dirs = &.{dir} }, macho);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diags.len);
    try testing.expectEqual(codes.Code.R0018, r.diags[0].code);
    try testing.expectEqual(@as(u32, 0), r.diags[0].scope);
    try testing.expectEqualStrings("write", src[r.diags[0].byte_offset..r.diags[0].end]);
    try testing.expect(std.mem.indexOf(u8, r.diags[0].message, "toy runtime") != null);
    try testing.expectEqual(@as(usize, 1), r.notes().of(r.diags[0]).len);
}

test "R0018 against a bundled module's extern sits at the user's extern" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyz.dylib", .data = Dylib.fakeDylibExporting(&buf, "/opt/libtoyz.dylib", 6, &.{"strlen"}) });
    const user =
        \\extern "toyz" { fn strlen(p: rawptr) -> int }
        \\fn main() -> int { 0 }
        \\
    ;
    const core = "pub extern fn strlen(p: rawptr) -> int\n";
    for ([_]bool{ false, true }) |core_first| {
        var g = if (core_first)
            try graphOfMods(gpa, &.{ .{ .path = "core/os", .src = core, .bundled = true }, .{ .path = "main", .src = user } })
        else
            try graphOfMods(gpa, &.{ .{ .path = "main", .src = user }, .{ .path = "core/os", .src = core, .bundled = true } });
        defer freeGraphOfMods(gpa, &g);
        var r = try collect(gpa, io, &g, .{ .dirs = &.{dir} }, macho);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.diags.len);
        try testing.expectEqual(codes.Code.R0018, r.diags[0].code);
        try testing.expectEqual(@as(u32, if (core_first) 1 else 0), r.diags[0].scope);
        try testing.expectEqualStrings("strlen", user[r.diags[0].byte_offset..r.diags[0].end]);
        try testing.expect(std.mem.indexOf(u8, r.diags[0].message, "core/os") != null);
    }
}

test "a block's library string has its escapes decoded" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyq.dylib", .data = Dylib.fakeDylibExporting(&buf, "/opt/libtoyq.dylib", 6, &.{"q_one"}) });
    var g = try graphOfMods(gpa, &.{.{ .path = "main", .src = "extern \"toy\\x71\" { fn q_one() -> int }\n" }});
    defer freeGraphOfMods(gpa, &g);
    var r = try collect(gpa, io, &g, .{ .dirs = &.{dir} }, macho);
    defer r.deinit();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(?Image.LibraryIndex, 0), r.linking.libraryOf("q_one"));
}

test "an extern its library does not export is R0019 at the extern, bare externs against the system C library" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyq.dylib", .data = Dylib.fakeDylibExporting(&buf, "/opt/libtoyq.dylib", 6, &.{"q_one"}) });
    const src =
        \\extern "toyq" {
        \\    fn q_one() -> int
        \\    fn q_nope() -> int
        \\}
        \\extern fn labs(x: int) -> int
        \\extern fn putz(p: rawptr) -> int
        \\fn main() -> int { 0 }
        \\
    ;
    var g = try graphOfMods(gpa, &.{.{ .path = "main", .src = src }});
    defer freeGraphOfMods(gpa, &g);
    var r = try collect(gpa, io, &g, .{ .dirs = &.{dir} }, macho);
    defer r.deinit();
    try testing.expect(r.ok());
    const diags = try r.unexported(io, &.{ "q_one", "q_nope", "labs", "putz" });
    const expect_bare = @import("builtin").os.tag == .macos;
    try testing.expectEqual(@as(usize, if (expect_bare) 2 else 1), diags.len);
    try testing.expectEqual(codes.Code.R0019, diags[0].code);
    try testing.expectEqualStrings("q_nope", src[diags[0].byte_offset..diags[0].end]);
    try testing.expectEqualStrings("C symbol 'q_nope' is not exported by library 'toyq'", diags[0].message);
    try testing.expectEqual(@as(usize, 0), r.notes().of(diags[0]).len);
    if (expect_bare) {
        try testing.expectEqualStrings("on macOS the system C library is libSystem", r.notes().of(diags[1])[0].message);
        try testing.expectEqualStrings("putz", src[diags[1].byte_offset..diags[1].end]);
        try testing.expectEqualStrings("C symbol 'putz' is not exported by the system C library; a bare 'extern fn' binds to the system C library", diags[1].message);
    }
}

test "an extern the program does not call is not checked, in the program or in core" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pa: std.heap.ArenaAllocator = .init(gpa);
    defer pa.deinit();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", pa.allocator());
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyq.dylib", .data = Dylib.fakeDylibExporting(&buf, "/opt/libtoyq.dylib", 6, &.{"q_one"}) });
    const user =
        \\extern "toyq" {
        \\    fn q_one() -> int
        \\    fn q_nope() -> int
        \\}
        \\extern fn putz(p: rawptr) -> int
        \\fn main() -> int { 0 }
        \\
    ;
    const core = "pub extern fn __errno_location() -> rawptr\npub extern fn __error() -> rawptr\n";
    var g = try graphOfMods(gpa, &.{ .{ .path = "main", .src = user }, .{ .path = "core/os", .src = core, .bundled = true } });
    defer freeGraphOfMods(gpa, &g);
    var r = try collect(gpa, io, &g, .{ .dirs = &.{dir} }, macho);
    defer r.deinit();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 0), (try r.unexported(io, &.{ "q_one", "__error" })).len);
    try testing.expectEqual(@as(usize, 0), (try r.unexported(io, &.{})).len);
    if (@import("builtin").os.tag != .macos) return;
    const diags = try r.unexported(io, &.{"__errno_location"});
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(@as(u32, 1), diags[0].scope);
    try testing.expectEqualStrings("__errno_location", core[diags[0].byte_offset..diags[0].end]);
}

test "-l z and /usr/lib/libz.1.dylib load one shared-cache library" {
    if (comptime @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var g = try graphOfMods(gpa, &.{.{ .path = "main", .src = "extern \"/usr/lib/libz.1.dylib\" { fn crc32(c: int, p: rawptr, n: int) -> int }\nfn main() -> int { 0 }\n" }});
    defer freeGraphOfMods(gpa, &g);
    var r = try collect(gpa, threaded.io(), &g, .{ .libs = &.{"z"} }, macho);
    defer r.deinit();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 1), r.linking.libraries.len);
    try testing.expectEqualStrings("/usr/lib/libz.1.dylib", r.linking.libraries[0].name);
    try testing.expectEqual(@as(?Image.LibraryIndex, 0), r.linking.libraryOf("crc32"));
}
