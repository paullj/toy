//! Find a user dynamic library and read what a binary must record to load it.
//!
//! The writer emits one LC_LOAD_DYLIB per library and binds each import to its
//! library's ordinal, so the linker must know, for every library, the install name
//! dyld will look up and the versions dyld checks. A library on disk supplies both
//! through its LC_ID_DYLIB. A system library under /usr/lib has no file on disk on
//! current macOS (it lives in the dyld shared cache), so it is accepted when the
//! cache holds it and recorded by the install name dyld reports for it.
//!
//! The linker also checks that each extern's symbol is exported by its library, since
//! dyld would otherwise abort the program at launch. An on-disk library is read
//! through its export trie. A shared-cache library has no file to read, so dyld itself
//! is asked: the library is opened with RTLD_FIRST, which makes `dlsym` search only
//! that library and what it re-exports, the same set a two-level-namespace bind sees.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const MachO = @import("MachO.zig");

/// Searched after every `-L` directory, as the system linker does. /usr/lib is
/// also where the shared-cache fallback looks.
pub const default_dirs = [_][]const u8{ "/usr/local/lib", "/usr/lib" };

const libsystem_path = "/usr/lib/libSystem.B.dylib";

/// Names whose library is libSystem itself: libc, libm, libpthread and libdl are
/// part of it, so naming one adds no load command.
const libsystem_names = [_][]const u8{ "System", "c", "m", "pthread", "dl" };

/// What a program links beyond libSystem: the libraries to load, the LC_RPATH
/// entries their `@rpath/` install names need, and the C symbols bound to a library
/// other than libSystem. Every slice is borrowed from whoever built it.
pub const Linking = struct {
    dylibs: []const MachO.Dylib = &.{},
    rpaths: []const []const u8 = &.{},
    /// Sorted by name, one entry per symbol.
    bindings: []const Binding = &.{},

    pub fn load(self: Linking) MachO.Libraries {
        return .{ .dylibs = self.dylibs, .rpaths = self.rpaths };
    }

    /// The import ordinal of the bare C symbol `name`; a symbol no library claims
    /// binds to libSystem.
    pub fn ordinalOf(self: Linking, name: []const u8) u8 {
        var lo: usize = 0;
        var hi: usize = self.bindings.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.bindings[mid].name, name)) {
                .eq => return self.bindings[mid].ordinal,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return 1;
    }
};

pub const Binding = struct { name: []const u8, ordinal: u8 };

/// Where a library name led. Strings are allocated in the allocator `find` got.
pub const Found = union(enum) {
    libsystem,
    dylib: struct { dylib: MachO.Dylib, rpath: ?[]const u8, exports: Exports },
    /// Only a static archive or object matched: the path of the first one.
    static: []const u8,
    not_found,
    not_dylib: struct { path: []const u8, why: []const u8 },
};

/// True for a name that is a static archive or an object file, which cannot be
/// loaded at run time.
pub fn isStatic(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".a") or std.mem.endsWith(u8, name, ".o");
}

/// True when `name` is a path to use as given rather than a library to search for.
pub fn isPath(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '/') != null or std.mem.endsWith(u8, name, ".dylib");
}

/// Look `name` up: a path (`isPath`) as given, relative to the working directory;
/// otherwise `lib<name>.dylib` in each of `dirs`, then `default_dirs`, then the
/// shared cache. A directory holding only `lib<name>.a` does not stop the search,
/// but if no dylib turns up the archive is reported, so the user learns why.
pub fn find(arena: std.mem.Allocator, io: Io, name: []const u8, dirs: []const []const u8) !Found {
    if (isStatic(name)) return .{ .static = name };
    for (libsystem_names) |n| if (std.mem.eql(u8, n, name)) return .libsystem;
    if (isPath(name)) {
        if (!exists(io, name)) return if (std.fs.path.isAbsolute(name) and inSharedCache(name)) cached(arena, name) else .not_found;
        return open(arena, io, name);
    }
    var static: ?[]const u8 = null;
    for ([2][]const []const u8{ dirs, &default_dirs }) |group| for (group) |dir| {
        const dylib = try std.fmt.allocPrint(arena, "{s}/lib{s}.dylib", .{ dir, name });
        if (exists(io, dylib)) return open(arena, io, dylib);
        if (static == null) {
            const archive = try std.fmt.allocPrint(arena, "{s}/lib{s}.a", .{ dir, name });
            if (exists(io, archive)) static = archive;
        }
    };
    const system = try std.fmt.allocPrint(arena, "/usr/lib/lib{s}.dylib", .{name});
    if (inSharedCache(system)) return cached(arena, system);
    return if (static) |s| .{ .static = s } else .not_found;
}

/// A shared-cache library, recorded by its install name so that two paths to one
/// library (`/usr/lib/libz.dylib` and `/usr/lib/libz.1.dylib`) load it once, and
/// with the versions of its LC_ID_DYLIB, as the system linker records them.
fn cached(arena: std.mem.Allocator, path: []const u8) !Found {
    const dylib: MachO.Dylib = (try cachedId(arena, path)) orelse .{ .install_name = path };
    if (std.mem.eql(u8, dylib.install_name, libsystem_path)) return .libsystem;
    return .{ .dylib = .{ .dylib = dylib, .rpath = null, .exports = .{ .cached = path } } };
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Read the library at `path` and choose the install name the binary records.
fn open(arena: std.mem.Allocator, io: Io, path: []const u8) !Found {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .not_dylib = .{ .path = path, .why = "it cannot be read" } },
    };
    const id = switch (readId(bytes)) {
        .ok => |id| id,
        .bad => |why| return .{ .not_dylib = .{ .path = path, .why = why } },
    };
    const real = Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch try arena.dupe(u8, path);
    const choice = try record(arena, id.install_name, real);
    if (std.mem.eql(u8, choice.install_name, libsystem_path)) return .libsystem;
    return .{ .dylib = .{
        .dylib = id.recordAs(choice.install_name),
        .rpath = choice.rpath,
        .exports = .{ .trie = .{ .trie = id.exports, .cmds = id.cmds, .dir = std.fs.path.dirname(real) orelse "/" } },
    } };
}

/// The install name to record for a library whose LC_ID_DYLIB says `install_name`
/// and which was found at the absolute path `real`. An absolute or `@`-relative
/// name is what the library's author chose and dyld resolves it at load time;
/// `@rpath/` also needs the found folder as an LC_RPATH so the binary runs where it
/// was built. A bare or relative name (what `cc -shared` writes by default) would be
/// looked up relative to the working directory at run time, so the found path is
/// recorded instead.
pub fn record(arena: std.mem.Allocator, install_name: []const u8, real: []const u8) !struct { install_name: []const u8, rpath: ?[]const u8 } {
    if (std.mem.startsWith(u8, install_name, "@rpath/"))
        return .{ .install_name = try arena.dupe(u8, install_name), .rpath = std.fs.path.dirname(real) orelse "/" };
    if (install_name.len > 0 and (install_name[0] == '@' or install_name[0] == '/'))
        return .{ .install_name = try arena.dupe(u8, install_name), .rpath = null };
    return .{ .install_name = real, .rpath = null };
}

/// A library's LC_ID_DYLIB: its install name (borrowed from the bytes read) and
/// the versions dyld checks; with its export trie and load commands, also borrowed.
pub const Id = struct {
    install_name: []const u8,
    current_version: u32,
    compat_version: u32,
    exports: []const u8 = &.{},
    cmds: []const u8 = &.{},

    /// The load command for this library under `install_name`, which may differ from
    /// the library's own (see `record`).
    pub fn recordAs(id: Id, install_name: []const u8) MachO.Dylib {
        return .{ .install_name = install_name, .current_version = id.current_version, .compat_version = id.compat_version };
    }
};

/// Where the linker looks up the C symbols a library exports.
pub const Exports = union(enum) {
    /// An on-disk library's export trie, its load commands (for its re-exports and
    /// LC_RPATHs), and the real path of its folder, which is what `@loader_path` means.
    trie: struct { trie: []const u8, cmds: []const u8, dir: []const u8 },
    /// The path of a shared-cache library, opened through dyld.
    cached: []const u8,

    pub const libsystem: Exports = .{ .cached = libsystem_path };

    /// Whether the library exports the C symbol `sym`. It answers true when it cannot
    /// tell (a re-exported library it cannot find, or a host without dyld), so the
    /// check never rejects a symbol dyld would bind.
    pub fn has(self: Exports, arena: std.mem.Allocator, io: Io, cache: *Cache, sym: []const u8) !bool {
        const mangled = try std.fmt.allocPrint(arena, "_{s}", .{sym});
        return self.hasDepth(arena, io, cache, sym, mangled, 0);
    }

    fn hasDepth(self: Exports, arena: std.mem.Allocator, io: Io, cache: *Cache, sym: []const u8, mangled: []const u8, depth: u8) !bool {
        switch (self) {
            .cached => |path| return cachedHas(path, sym),
            .trie => |t| {
                if (trieHas(t.trie, mangled)) return true;
                if (depth == 8) return true;
                var it: CmdIter = .{ .cmds = t.cmds };
                while (it.next()) |c| {
                    if (c.cmd != LC_REEXPORT_DYLIB) continue;
                    const name = c.str() orelse return true;
                    const sub = (try reexported(arena, io, cache, t.cmds, t.dir, name)) orelse return true;
                    if (try sub.hasDepth(arena, io, cache, sym, mangled, depth + 1)) return true;
                }
                return false;
            },
        }
    }
};

/// Re-exported libraries read so far, by path; null for one that is not a readable
/// dylib. Every extern is checked through it, so each library is read once per link.
pub const Cache = std.StringHashMapUnmanaged(?Exports);

/// The library a re-export names, found the way dyld would from the re-exporting
/// library (load commands `cmds`, folder `dir`): `@loader_path/` from `dir`,
/// `@rpath/` through its LC_RPATHs and then `dir`, which is the LC_RPATH the binary
/// records for an `@rpath/` library it links. Null when it cannot be found.
fn reexported(arena: std.mem.Allocator, io: Io, cache: *Cache, cmds: []const u8, dir: []const u8, name: []const u8) !?Exports {
    if (std.fs.path.isAbsolute(name)) {
        if (exists(io, name)) return loadCached(arena, io, cache, name);
        return if (inSharedCache(name)) .{ .cached = name } else null;
    }
    if (std.mem.startsWith(u8, name, "@loader_path/")) {
        const path = try std.fs.path.join(arena, &.{ dir, name["@loader_path/".len..] });
        return if (exists(io, path)) loadCached(arena, io, cache, path) else null;
    }
    if (!std.mem.startsWith(u8, name, "@rpath/")) return null;
    const rest = name["@rpath/".len..];
    var it: CmdIter = .{ .cmds = cmds };
    while (it.next()) |c| {
        if (c.cmd != LC_RPATH) continue;
        const rp = c.str() orelse continue;
        const base = if (std.mem.startsWith(u8, rp, "@loader_path"))
            try std.mem.concat(arena, u8, &.{ dir, rp["@loader_path".len..] })
        else if (std.fs.path.isAbsolute(rp)) rp else continue;
        const path = try std.fs.path.join(arena, &.{ base, rest });
        if (exists(io, path)) return loadCached(arena, io, cache, path);
    }
    const path = try std.fs.path.join(arena, &.{ dir, rest });
    return if (exists(io, path)) loadCached(arena, io, cache, path) else null;
}

fn loadCached(arena: std.mem.Allocator, io: Io, cache: *Cache, path: []const u8) !?Exports {
    const gop = try cache.getOrPut(arena, path);
    if (gop.found_existing) return gop.value_ptr.*;
    gop.key_ptr.* = try arena.dupe(u8, path);
    gop.value_ptr.* = null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    const id = switch (readId(bytes)) {
        .ok => |id| id,
        .bad => return null,
    };
    const real = Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch try arena.dupe(u8, path);
    gop.value_ptr.* = .{ .trie = .{ .trie = id.exports, .cmds = id.cmds, .dir = std.fs.path.dirname(real) orelse "/" } };
    return gop.value_ptr.*;
}

/// One load command: its kind and its bytes, header included.
const Cmd = struct {
    cmd: u32,
    bytes: []const u8,

    /// The string a `dylib_command` or `rpath_command` holds, at the offset its
    /// third word gives.
    fn str(c: Cmd) ?[]const u8 {
        if (c.bytes.len < 12) return null;
        const off = std.mem.readInt(u32, c.bytes[8..12], .little);
        if (off >= c.bytes.len) return null;
        return std.mem.sliceTo(c.bytes[off..], 0);
    }
};

const CmdIter = struct {
    cmds: []const u8,
    off: usize = 0,

    fn next(it: *CmdIter) ?Cmd {
        if (it.off + 8 > it.cmds.len) return null;
        const cmd = std.mem.readInt(u32, it.cmds[it.off..][0..4], .little);
        const size = std.mem.readInt(u32, it.cmds[it.off + 4 ..][0..4], .little);
        if (size < 8 or it.off + size > it.cmds.len) return null;
        defer it.off += size;
        return .{ .cmd = cmd, .bytes = it.cmds[it.off..][0..size] };
    }
};

fn uleb(bytes: []const u8, pos: *usize) ?usize {
    var v: u64 = 0;
    var shift: u7 = 0;
    while (pos.* < bytes.len) {
        const b = bytes[pos.*];
        pos.* += 1;
        if (shift >= 64) return null;
        v |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return std.math.cast(usize, v);
        shift += 7;
    }
    return null;
}

/// True when the Mach-O export trie `trie` has a terminal for `name` (the mangled
/// symbol). Every step consumes a non-empty edge of `name`, so a malformed or cyclic
/// trie still ends.
pub fn trieHas(trie: []const u8, name: []const u8) bool {
    var node: usize = 0;
    var rest = name;
    while (true) {
        var p = node;
        const terminal = uleb(trie, &p) orelse return false;
        if (rest.len == 0) return terminal != 0;
        p = std.math.add(usize, p, terminal) catch return false;
        if (p >= trie.len) return false;
        const children = trie[p];
        p += 1;
        var next: ?usize = null;
        for (0..children) |_| {
            const end = std.mem.indexOfScalarPos(u8, trie, p, 0) orelse return false;
            const edge = trie[p..end];
            p = end + 1;
            const child = uleb(trie, &p) orelse return false;
            if (edge.len > 0 and std.mem.startsWith(u8, rest, edge)) {
                rest = rest[edge.len..];
                next = child;
                break;
            }
        }
        node = next orelse return false;
    }
}

const MH_MAGIC_64: u32 = 0xFEEDFACF;
const FAT_MAGIC: u32 = 0xCAFEBABE;
const FAT_MAGIC_64: u32 = 0xCAFEBABF;
const CPU_TYPE_ARM64: u32 = 0x0100000C;
const MH_DYLIB: u32 = 0x6;
const LC_ID_DYLIB: u32 = 0xd;
const LC_REEXPORT_DYLIB: u32 = 0x8000001f;
const LC_RPATH: u32 = 0x8000001c;
const LC_DYLD_INFO: u32 = 0x22;
const LC_DYLD_INFO_ONLY: u32 = 0x80000022;
const LC_DYLD_EXPORTS_TRIE: u32 = 0x80000033;

/// Parse the arm64 Mach-O dylib in `bytes` (thin, or the arm64 slice of a
/// universal file) for its LC_ID_DYLIB, or say why it is not one.
pub const Read = union(enum) { ok: Id, bad: []const u8 };

pub fn readId(bytes: []const u8) Read {
    const not_macho = "it is not a Mach-O file";
    if (bytes.len < 8) return .{ .bad = not_macho };
    const be = std.mem.readInt(u32, bytes[0..4], .big);
    if (be == FAT_MAGIC or be == FAT_MAGIC_64) {
        const wide = be == FAT_MAGIC_64;
        const n = std.mem.readInt(u32, bytes[4..8], .big);
        const entry: usize = if (wide) 32 else 20;
        for (0..n) |i| {
            const at = 8 + i * entry;
            if (at + entry > bytes.len) return .{ .bad = not_macho };
            if (std.mem.readInt(u32, bytes[at..][0..4], .big) != CPU_TYPE_ARM64) continue;
            const off: u64 = if (wide) std.mem.readInt(u64, bytes[at + 8 ..][0..8], .big) else std.mem.readInt(u32, bytes[at + 8 ..][0..4], .big);
            const size: u64 = if (wide) std.mem.readInt(u64, bytes[at + 16 ..][0..8], .big) else std.mem.readInt(u32, bytes[at + 12 ..][0..4], .big);
            if (off > bytes.len or size > bytes.len - off) return .{ .bad = not_macho };
            return readThin(bytes[@intCast(off)..][0..@intCast(size)]);
        }
        return .{ .bad = "it has no arm64 slice" };
    }
    return readThin(bytes);
}

fn readThin(bytes: []const u8) Read {
    const not_macho = "it is not a Mach-O file";
    if (bytes.len < 32 or std.mem.readInt(u32, bytes[0..4], .little) != MH_MAGIC_64) return .{ .bad = not_macho };
    if (std.mem.readInt(u32, bytes[4..8], .little) != CPU_TYPE_ARM64) return .{ .bad = "it is not built for arm64" };
    if (std.mem.readInt(u32, bytes[12..16], .little) != MH_DYLIB) return .{ .bad = "it is not a dynamic library" };
    const sizeofcmds = std.mem.readInt(u32, bytes[20..24], .little);
    const cmds = bytes[32..][0..@min(sizeofcmds, bytes.len - 32)];
    var id: ?Id = null;
    var exports: []const u8 = &.{};
    var it: CmdIter = .{ .cmds = cmds };
    while (it.next()) |c| switch (c.cmd) {
        LC_ID_DYLIB => if (id == null and c.bytes.len >= 24) {
            const name = c.str() orelse continue;
            id = .{
                .install_name = name,
                .current_version = std.mem.readInt(u32, c.bytes[16..20], .little),
                .compat_version = std.mem.readInt(u32, c.bytes[20..24], .little),
            };
        },
        LC_DYLD_INFO, LC_DYLD_INFO_ONLY => if (c.bytes.len >= 48) {
            exports = fileRange(bytes, std.mem.readInt(u32, c.bytes[40..44], .little), std.mem.readInt(u32, c.bytes[44..48], .little));
        },
        LC_DYLD_EXPORTS_TRIE => if (c.bytes.len >= 16) {
            exports = fileRange(bytes, std.mem.readInt(u32, c.bytes[8..12], .little), std.mem.readInt(u32, c.bytes[12..16], .little));
        },
        else => {},
    };
    if (id) |*found| {
        found.exports = exports;
        found.cmds = cmds;
        return .{ .ok = found.* };
    }
    return .{ .bad = "it has no install name (LC_ID_DYLIB)" };
}

fn fileRange(bytes: []const u8, off: u32, size: u32) []const u8 {
    if (off > bytes.len or size > bytes.len - off) return &.{};
    return bytes[off..][0..size];
}

const dyld = struct {
    const RTLD_LAZY: c_int = 0x1;
    const RTLD_LOCAL: c_int = 0x4;
    const RTLD_NOLOAD: c_int = 0x10;
    const RTLD_FIRST: c_int = 0x100;
    extern "c" fn _dyld_shared_cache_contains_path(p: [*:0]const u8) bool;
    extern "c" fn _dyld_image_count() u32;
    extern "c" fn _dyld_get_image_name(i: u32) ?[*:0]const u8;
    extern "c" fn _dyld_get_image_header(i: u32) ?*const anyopaque;
    extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: *anyopaque, sym: [*:0]const u8) ?*anyopaque;
    extern "c" fn dlclose(handle: *anyopaque) c_int;
};

/// `s` as a NUL-terminated string in `buf`, or null when it does not fit.
fn cstr(buf: *[std.fs.max_path_bytes:0]u8, s: []const u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf;
}

fn openCached(path: []const u8, extra: c_int) ?*anyopaque {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    return dyld.dlopen(cstr(&buf, path) orelse return null, dyld.RTLD_LAZY | dyld.RTLD_LOCAL | dyld.RTLD_FIRST | extra);
}

/// Whether the shared-cache library at `path` exports `sym`; true when dyld cannot
/// open it, which `find` has already ruled out.
fn cachedHas(path: []const u8, sym: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return true;
    const h = openCached(path, 0) orelse return true;
    defer _ = dyld.dlclose(h);
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    return dyld.dlsym(h, cstr(&buf, sym) orelse return true) != null;
}

/// The load command for the shared-cache library at `path`, from its LC_ID_DYLIB,
/// its install name owned by `arena`. dyld has no call from a path to its image, so the library is opened and
/// the loaded image whose handle matches is read in memory; null when none does.
fn cachedId(arena: std.mem.Allocator, path: []const u8) !?MachO.Dylib {
    if (comptime builtin.os.tag != .macos) return null;
    const h = openCached(path, 0) orelse return null;
    defer _ = dyld.dlclose(h);
    for (0..dyld._dyld_image_count()) |i| {
        const name = dyld._dyld_get_image_name(@intCast(i)) orelse continue;
        const other = openCached(std.mem.span(name), dyld.RTLD_NOLOAD) orelse continue;
        _ = dyld.dlclose(other);
        if (other != h) continue;
        const header: [*]const u8 = @ptrCast(dyld._dyld_get_image_header(@intCast(i)) orelse return null);
        const sizeofcmds = std.mem.readInt(u32, header[20..24], .little);
        return switch (readThin(header[0 .. 32 + sizeofcmds])) {
            .ok => |id| id.recordAs(try arena.dupe(u8, id.install_name)),
            .bad => null,
        };
    }
    return null;
}

/// True when the dyld shared cache holds `path`. Only macOS has one; elsewhere (the
/// wasm language server) nothing is cached.
fn inSharedCache(path: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    return dyld._dyld_shared_cache_contains_path(cstr(&buf, path) orelse return false);
}

const testing = std.testing;

/// A minimal thin arm64 Mach-O header with one LC_ID_DYLIB naming `name`, for tests.
pub fn fakeDylib(buf: []u8, name: []const u8, filetype: u32) []u8 {
    return fakeDylibExporting(buf, name, filetype, &.{});
}

/// `fakeDylib` with an LC_DYLD_EXPORTS_TRIE whose trie exports the C symbols `syms`.
pub fn fakeDylibExporting(buf: []u8, name: []const u8, filetype: u32, syms: []const []const u8) []u8 {
    @memset(buf, 0);
    const cmdsize: u32 = @intCast(std.mem.alignForward(usize, 24 + name.len + 1, 8));
    const sizeofcmds = cmdsize + 16;
    std.mem.writeInt(u32, buf[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, buf[4..8], CPU_TYPE_ARM64, .little);
    std.mem.writeInt(u32, buf[12..16], filetype, .little);
    std.mem.writeInt(u32, buf[16..20], 2, .little);
    std.mem.writeInt(u32, buf[20..24], sizeofcmds, .little);
    std.mem.writeInt(u32, buf[32..36], LC_ID_DYLIB, .little);
    std.mem.writeInt(u32, buf[36..40], cmdsize, .little);
    std.mem.writeInt(u32, buf[40..44], 24, .little);
    std.mem.writeInt(u32, buf[48..52], 0x10203, .little);
    std.mem.writeInt(u32, buf[52..56], 0x10000, .little);
    @memcpy(buf[56..][0..name.len], name);

    // A root with one edge per symbol, each to a leaf whose terminal holds flags 0 and
    // address 0; every offset stays below 128, so each uleb is one byte.
    const trie_off = 32 + sizeofcmds;
    var p: usize = trie_off;
    buf[p] = 0;
    buf[p + 1] = @intCast(syms.len);
    p += 2;
    var root_len: usize = 2;
    for (syms) |sym| root_len += sym.len + 3;
    var leaf: usize = root_len;
    for (syms) |sym| {
        buf[p] = '_';
        @memcpy(buf[p + 1 ..][0..sym.len], sym);
        buf[p + 1 + sym.len] = 0;
        buf[p + 2 + sym.len] = @intCast(leaf);
        p += sym.len + 3;
        leaf += 4;
    }
    for (syms) |_| {
        buf[p..][0..4].* = .{ 2, 0, 0, 0 };
        p += 4;
    }
    const lc = 32 + cmdsize;
    std.mem.writeInt(u32, buf[lc..][0..4], LC_DYLD_EXPORTS_TRIE, .little);
    std.mem.writeInt(u32, buf[lc + 4 ..][0..4], 16, .little);
    std.mem.writeInt(u32, buf[lc + 8 ..][0..4], @intCast(trie_off), .little);
    std.mem.writeInt(u32, buf[lc + 12 ..][0..4], @intCast(p - trie_off), .little);
    return buf[0..p];
}

test "readId reads a thin arm64 dylib's install name and versions" {
    var buf: [256]u8 = undefined;
    const id = readId(fakeDylib(&buf, "@rpath/libffi.dylib", MH_DYLIB)).ok;
    try testing.expectEqualStrings("@rpath/libffi.dylib", id.install_name);
    try testing.expectEqual(@as(u32, 0x10203), id.current_version);
    try testing.expectEqual(@as(u32, 0x10000), id.compat_version);
}

test "readId finds the arm64 slice of a universal file" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], FAT_MAGIC, .big);
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0x01000007, .big); // x86_64 first
    std.mem.writeInt(u32, buf[28..32], CPU_TYPE_ARM64, .big);
    std.mem.writeInt(u32, buf[36..40], 128, .big);
    var thin: [256]u8 = undefined;
    const t = fakeDylib(&thin, "/opt/lib/libz.dylib", MH_DYLIB);
    std.mem.writeInt(u32, buf[40..44], @intCast(t.len), .big);
    @memcpy(buf[128..][0..t.len], t);
    try testing.expectEqualStrings("/opt/lib/libz.dylib", readId(&buf).ok.install_name);
}

test "readId explains a file that is not an arm64 dylib" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("it is not a dynamic library", readId(fakeDylib(&buf, "x", 0x2)).bad);
    try testing.expectEqualStrings("it is not a Mach-O file", readId("!<arch>\nfoo.o").bad);
    const t = fakeDylib(&buf, "x", MH_DYLIB);
    std.mem.writeInt(u32, t[4..8], 0x01000007, .little);
    try testing.expectEqualStrings("it is not built for arm64", readId(t).bad);
}

test "record keeps an absolute or @ install name, adds the found folder for @rpath, and pins a bare one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try record(a, "@rpath/libffi.dylib", "/w/zig-out/lib/libffi.dylib");
    try testing.expectEqualStrings("@rpath/libffi.dylib", r.install_name);
    try testing.expectEqualStrings("/w/zig-out/lib", r.rpath.?);
    const abs = try record(a, "/opt/z/libz.1.dylib", "/opt/z/libz.dylib");
    try testing.expectEqualStrings("/opt/z/libz.1.dylib", abs.install_name);
    try testing.expect(abs.rpath == null);
    const loader = try record(a, "@loader_path/libq.dylib", "/q/libq.dylib");
    try testing.expectEqualStrings("@loader_path/libq.dylib", loader.install_name);
    try testing.expect(loader.rpath == null);
    const bare = try record(a, "libf.dylib", "/w/libf.dylib");
    try testing.expectEqualStrings("/w/libf.dylib", bare.install_name);
}

test "names: static inputs, paths and libSystem aliases" {
    try testing.expect(isStatic("libz.a") and isStatic("x.o") and !isStatic("z"));
    try testing.expect(isPath("./libz.dylib") and isPath("libz.dylib") and isPath("/x/y") and !isPath("z"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try testing.expect(try find(arena.allocator(), threaded.io(), "m", &.{}) == .libsystem);
    try testing.expectEqualStrings("libz.a", (try find(arena.allocator(), threaded.io(), "libz.a", &.{})).static);
}

test "find searches -L folders for lib<name>.dylib and reports a folder that holds only an archive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyq.dylib", .data = fakeDylib(&buf, "@rpath/libtoyq.dylib", MH_DYLIB) });
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyarc.a", .data = "!<arch>\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "libtoyexe.dylib", .data = fakeDylib(&buf, "x", 0x2) });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);

    const q = (try find(a, io, "toyq", &.{dir})).dylib;
    try testing.expectEqualStrings("@rpath/libtoyq.dylib", q.dylib.install_name);
    try testing.expectEqualStrings(dir, q.rpath.?);
    try testing.expect(std.mem.endsWith(u8, (try find(a, io, "toyarc", &.{dir})).static, "/libtoyarc.a"));
    try testing.expectEqualStrings("it is not a dynamic library", (try find(a, io, "toyexe", &.{dir})).not_dylib.why);
    try testing.expect(try find(a, io, "toy-no-such-lib", &.{dir}) == .not_found);
}

test "a dylib's export trie answers which C symbols it exports" {
    var buf: [512]u8 = undefined;
    const id = readId(fakeDylibExporting(&buf, "/opt/libq.dylib", MH_DYLIB, &.{ "q_one", "q_two", "q" })).ok;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const e: Exports = .{ .trie = .{ .trie = id.exports, .cmds = id.cmds, .dir = "/opt" } };
    var cache: Cache = .empty;
    for ([_][]const u8{ "q_one", "q_two", "q" }) |sym| try testing.expect(try e.has(arena.allocator(), threaded.io(), &cache, sym));
    for ([_][]const u8{ "q_on", "q_three", "", "q_one_" }) |sym| try testing.expect(!try e.has(arena.allocator(), threaded.io(), &cache, sym));
    try testing.expect(!trieHas(&.{}, "_q"));
}

test "re-exports through @rpath and @loader_path are followed, each library read once" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "m.c", .data = "int mine(int x) { return x; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w.c", .data = "int wrap(int x) { return x; }\n" });
    const cc = [_][]const []const u8{
        &.{ "cc", "-dynamiclib", "-o", "libmy.dylib", "m.c", "-install_name", "@rpath/libmy.dylib" },
        &.{ "cc", "-dynamiclib", "-o", "librw.dylib", "w.c", "-L.", "-Wl,-reexport_library,libmy.dylib", "-install_name", "@rpath/librw.dylib", "-Wl,-rpath,@loader_path" },
        &.{ "cc", "-dynamiclib", "-o", "liblw.dylib", "w.c", "-L.", "-Wl,-reexport_library,libmy.dylib", "-install_name", "@rpath/liblw.dylib" },
    };
    for (cc) |argv| {
        var child = std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = dir }, .stdout = .ignore, .stderr = .ignore }) catch return error.SkipZigTest;
        if (!std.meta.eql(try child.wait(io), std.process.Child.Term{ .exited = 0 })) return error.SkipZigTest;
    }
    var cache: Cache = .empty;
    for ([_][]const u8{ "librw.dylib", "liblw.dylib" }) |lib| {
        const path = try std.fs.path.join(a, &.{ dir, lib });
        const e = (try find(a, io, path, &.{})).dylib.exports;
        for (0..3) |_| {
            try testing.expect(try e.has(a, io, &cache, "wrap"));
            try testing.expect(try e.has(a, io, &cache, "mine"));
            try testing.expect(!try e.has(a, io, &cache, "nope"));
        }
    }
    try testing.expectEqual(@as(u32, 1), cache.count());
}

test "trieHas follows shared prefixes" {
    // "_" -> { "ab" -> terminal, "a" -> { "c" -> terminal } } in the trie layout ld writes.
    const trie = [_]u8{
        0, 1, '_', 0, 5, // root: no terminal, one edge "_" to node 5
        0, 1, 'a', 0, 10, // node 5: edge "a" to node 10
        0, 2, 'b', 0, 20, 'c', 0, 24, // node 10: edges "b" and "c"
        0, 0, // padding
        2, 0, 0, 0, // node 20: terminal
        2, 0, 0, 0, // node 24: terminal
    };
    try testing.expect(trieHas(&trie, "_ab"));
    try testing.expect(trieHas(&trie, "_ac"));
    try testing.expect(!trieHas(&trie, "_a"));
    try testing.expect(!trieHas(&trie, "_ad"));
}

test "shared-cache libraries: dyld answers exports, and aliases share one install name and versions" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const a = arena.allocator();
    const io = threaded.io();
    var cache: Cache = .empty;
    try testing.expect(try Exports.libsystem.has(a, io, &cache, "puts"));
    // libm is re-exported by libSystem, which is how a bare extern reaches sqrt.
    try testing.expect(try Exports.libsystem.has(a, io, &cache, "sqrt"));
    try testing.expect(!try Exports.libsystem.has(a, io, &cache, "putz_toy_nope"));
    // RTLD_FIRST: libz depends on libSystem but does not export its symbols.
    const z = (try find(a, io, "z", &.{})).dylib;
    try testing.expect(try z.exports.has(a, io, &cache, "crc32"));
    try testing.expect(!try z.exports.has(a, io, &cache, "puts"));
    const z1 = (try find(a, io, "/usr/lib/libz.1.dylib", &.{})).dylib;
    try testing.expectEqualStrings(z1.dylib.install_name, z.dylib.install_name);
    try testing.expectEqual(@as(u32, 0x10000), z.dylib.compat_version);
    try testing.expect(z.dylib.current_version >= 0x10200);
    try testing.expectEqual(z1.dylib.current_version, z.dylib.current_version);
    try testing.expect(try find(a, io, "/usr/lib/libc.dylib", &.{}) == .libsystem);
}

test "ordinalOf finds a bound symbol and defaults to libSystem" {
    const l: Linking = .{ .bindings = &.{ .{ .name = "a_fn", .ordinal = 2 }, .{ .name = "m_fn", .ordinal = 3 }, .{ .name = "z_fn", .ordinal = 2 } } };
    try testing.expectEqual(@as(u8, 3), l.ordinalOf("m_fn"));
    try testing.expectEqual(@as(u8, 2), l.ordinalOf("z_fn"));
    try testing.expectEqual(@as(u8, 1), l.ordinalOf("write"));
}
