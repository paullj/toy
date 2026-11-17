//! Library discovery: one interface, one reader per object format.
//!
//! The driver (`driver/Libraries.zig`) resolves each library a program names and checks
//! that it exports the C symbols the program calls. What a library file is, where the
//! system keeps libraries, which names mean the system C library and which name a
//! binary records to load one are the format's, so each reader answers them behind
//! `Resolver`, and `of` picks it from the target. The Mach-O reader is `Dylib.zig`. An
//! ELF reader (#435) reads a library's SONAME and `.dynsym`. A cross build takes a
//! library missing from disk by its exact runtime name and skips its symbol check with a
//! note (#60 T14); `Found` cannot say that yet, so #435 extends it. wasm (#79) has no
//! library files: a library string is an import module name, so its resolver finds
//! every name and checks no export.

const std = @import("std");
const Io = std.Io;
const Image = @import("Image.zig");
const Target = @import("../Target.zig");

/// A library's export table, as its reader holds it. Opaque outside the reader.
pub const Exports = *const anyopaque;

/// Libraries the export check read on the way to another's (re-exports, dependencies),
/// by path; null for one that is not a readable library. Each is read once per link.
pub const Cache = std.StringHashMapUnmanaged(?Exports);

/// Where a library name led. Strings are allocated in the arena `find` got.
pub const Found = union(enum) {
    /// One of the system libraries every program loads.
    system,
    library: struct {
        library: Image.Library,
        /// A folder the binary must ask the loader to search, for a library recorded by
        /// a relative name.
        search_path: ?[]const u8,
        exports: Exports,
    },
    /// Only a static archive or object matched: the path of the first one.
    static: []const u8,
    not_found,
    /// A file that is not a library this target loads, and why.
    unusable: struct { path: []const u8, why: []const u8 },
};

pub const FindError = error{OutOfMemory};

/// One object format's reader.
pub const Resolver = struct {
    /// What a diagnostic calls the system libraries every program loads.
    system_name: []const u8,
    /// A shared library's file name ending, as in `lib<name><suffix>`.
    suffix: []const u8,
    /// Searched after every `-L` folder, as the system linker does.
    default_dirs: []const []const u8,
    /// Where a search looks after the folders, as a diagnostic names it; null for nowhere.
    fallback: ?[]const u8,
    /// How many libraries beyond the system libraries one binary can load.
    max_libraries: Image.LibraryIndex,
    /// The system libraries' exports.
    system: Exports,
    /// Look `name` up: a path (`isPath`) as given, else in `dirs` then `default_dirs`.
    find: *const fn (arena: std.mem.Allocator, io: Io, name: []const u8, dirs: []const []const u8) FindError!Found,
    /// True when `name` is a path to use as given rather than a library to search for.
    isPath: *const fn (name: []const u8) bool,
    /// Whether `exports` holds the C symbol `sym`. True when the reader cannot tell, so
    /// the check never rejects a symbol the loader would bind.
    has: *const fn (arena: std.mem.Allocator, io: Io, cache: *Cache, exports: Exports, sym: []const u8) FindError!bool,
};

/// The reader for `target`'s libraries, or null when toy cannot read them yet.
pub fn of(target: Target) ?*const Resolver {
    return switch (target.objectFormat()) {
        .macho => &@import("Dylib.zig").resolver,
        .elf => null,
    };
}

/// What a program links beyond the system libraries: the libraries to load, the folders
/// their relative names need, and the C symbols bound to one of them. Every slice is
/// borrowed from whoever built it.
pub const Linking = struct {
    libraries: []const Image.Library = &.{},
    search_paths: []const []const u8 = &.{},
    /// Sorted by name, one entry per symbol.
    bindings: []const Binding = &.{},

    /// The library (an index into `libraries`) the bare C symbol `name` binds to; null
    /// for the system libraries.
    pub fn libraryOf(self: Linking, name: []const u8) ?Image.LibraryIndex {
        const i = Image.indexByName(Binding, self.bindings, name) orelse return null;
        return self.bindings[i].library;
    }
};

pub const Binding = struct { name: []const u8, library: Image.LibraryIndex };

const testing = std.testing;

test "libraryOf finds a bound symbol and defaults to the system libraries" {
    const l: Linking = .{ .bindings = &.{ .{ .name = "crc32", .library = 0 }, .{ .name = "q_one", .library = 1 }, .{ .name = "z_far", .library = 300 } } };
    try testing.expectEqual(@as(?Image.LibraryIndex, 0), l.libraryOf("crc32"));
    try testing.expectEqual(@as(?Image.LibraryIndex, 1), l.libraryOf("q_one"));
    try testing.expectEqual(@as(?Image.LibraryIndex, 300), l.libraryOf("z_far"));
    try testing.expectEqual(@as(?Image.LibraryIndex, null), l.libraryOf("write"));
}

test "the target picks its reader: Mach-O for macOS, none yet for ELF" {
    try testing.expect(of(.aarch64_macos) != null);
    try testing.expect(of(.aarch64_linux) == null);
    try testing.expect(of(.x86_64_linux) == null);
}
