//! The single backend boundary: lowered per-function `FnCode`s -> a runnable image in
//! the target's object format.
//!
//! WHY this is one entry point: the backend tail is a fixed, order-sensitive
//! pipeline — (0) drop every fn and descriptor unreachable from the entry, (1)
//! detect referenced hand-emitted builtin bodies (e.g. `panic`, which pulls in
//! `write`) and append them, (2) intern the per-fn content-hashed cstring
//! literals program-wide IN A DETERMINISTIC ORDER (fn source order, then in-fn
//! literal order), (3) rewrite each `.cstr` reloc's
//! hash target to its global `__cstring` offset, (4) `Link.link` (layout +
//! intra-module patch + collect cross-segment data_relocs), (5) the format-neutral
//! `Image` (the import set and its libraries), (6) the format's writer (`writerOf`; for Mach-O `MachO.write`:
//! segments, __cstring, __got import, chained fixups, then the cross-segment relocs
//! patched once addresses are known), (7) for Mach-O, `MachO.sign` LAST, over the final
//! bytes. The ORDER IS BYTE-LOAD-BEARING (esp. sign last). Hiding it behind
//! `emitExecutable` keeps the program-wide
//! interning + `.cstr`-rewrite an image-emission concern (it lives here, not in
//! the driver), and gives the driver a clean handoff: lowered fns in, signed
//! image out.
//!
//! Internally the pipeline is split into `linkProgram` (steps 1-4, producing a
//! linked `Linked` tail) and `writeImage` (steps 5-7). `emitExecutable` fuses
//! them; the driver also calls them individually on the asm/listing path where it
//! needs the linked tail without a final image.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Link = @import("Link.zig");
const ValueLayout = @import("../layout/ValueLayout.zig");
const MachO = @import("MachO.zig");
const Image = @import("Image.zig");
const LibResolver = @import("LibResolver.zig");
const runtime = @import("../codegen/runtime/runtime.zig");
const Isa = @import("../codegen/Isa.zig");
const sym = @import("../symbols/Sym.zig");
const Engine = @import("../query/Engine.zig");
const Target = @import("../Target.zig");

/// Emission options. `identifier` is the code-signing identity (the output
/// basename) and is byte-load-bearing (it enters both the signature and the
/// Mach-O layout). The imports list is DERIVED internally from the `.import`
/// reloc targets (dedup + stable-sort by name), not a caller input.
pub const Options = struct {
    identifier: []const u8,
    target: Target = .aarch64_macos,
    /// The per-type descriptor table to embed, in canonical order. Empty (the default)
    /// leaves the image byte-identical to a descriptor-free build.
    descriptors: []const Link.DescEntry = &.{},
    /// Emit debug info (LC_SYMTAB and DWARF) for these sources. Null leaves the image
    /// byte-identical to a build without it.
    debug: ?Link.DebugInput = null,
};

/// The linked-program tail: the joined __text blob, the entry offset, and the
/// cross-segment data the assemble step needs. The driver packs this into its
/// own `LinkedProgram` (which additionally carries the codegen listing/diags).
pub const Linked = struct {
    text: []u8,
    entry_off: u32,
    /// Interned `__cstring` bytes. Owned; empty for string-free programs.
    cstrings: []u8 = &.{},
    /// Cross-segment relocs (to __cstring/__got/__bss) rebased to absolute
    /// __text offsets, patched by the format writer once it has placed the sections.
    /// Owned; empty for programs with no data relocations. The import set is DERIVED
    /// from these (`.import` targets) in `writeImage` — never a separate flag — so it
    /// is a pure function of the fn set at any `-jN`.
    data_relocs: []Link.Reloc = &.{},
    /// The debug info, empty unless asked for. Owned.
    debug: Image.Debug = .{},
};

/// Drop fns and descriptors unreachable from `entry`, append referenced hand-emitted
/// builtin bodies, intern strings deterministically, rewrite `.cstr` targets, then
/// `Link.link`. CONSUMES `fns` (frees each FnCode, dropped or kept, and any appended
/// builtin body). `entry` is the entry function's stable symbol identity. Returns the
/// linked tail; the caller owns its `text`/`cstrings`/`data_relocs` (free `.import`
/// data-reloc names individually).
/// Each hand-emitted builtin's calls into `core/rt`, as `Link.reachable` follows them.
const builtin_calls = blk: {
    var n: usize = 0;
    for (runtime.hand_builtins) |hb| n += hb.runtime_calls.len;
    var out: [n]Link.BuiltinCall = undefined;
    var i: usize = 0;
    for (runtime.hand_builtins) |hb| for (hb.runtime_calls) |f| {
        out[i] = .{ .builtin = hb.name, .callee = .{ .kind = .user_fn, .name = f.name() } };
        i += 1;
    };
    break :blk out;
};

pub fn linkProgram(io: Io, gpa: std.mem.Allocator, backend: *const Isa.Backend, fns: []Link.FnCode, entry: sym.SymName, planned: []const Link.DescEntry, debug: ?Link.DebugInput) !Linked {
    // We OWN `fns`' elements now (the caller relinquished them); on any failure free
    // the ones not yet moved into `all` (or dropped) plus everything in `all`.
    var all: std.ArrayList(Link.FnCode) = .empty;
    var moved: usize = 0;
    errdefer {
        for (fns[moved..]) |*f| f.deinit(gpa);
    }
    defer {
        for (all.items) |*f| f.deinit(gpa);
        all.deinit(gpa);
    }

    // 0) Drop every fn and descriptor unreachable from the entry before anything reads
    //    them, so the builtins, imports, cstrings, descriptor table, symtab and stack map
    //    below all derive from the kept set alone. Kept fns and descriptors stay in their
    //    canonical order, so the image is still a pure function of the fn set at any -jN.
    var kept_descs: std.ArrayList(Link.DescEntry) = .empty;
    defer kept_descs.deinit(gpa);
    {
        const r = try Link.reachable(gpa, fns, entry, planned, &builtin_calls);
        defer r.deinit(gpa);
        for (planned, r.descs) |d, k| {
            if (k) try kept_descs.append(gpa, d);
        }
        for (fns, r.fns) |*f, k| {
            if (k) try all.append(gpa, f.*) else f.deinit(gpa);
            moved += 1;
        }
    }
    const descriptors = kept_descs.items;

    // 1) Scan which hand-emitted builtins (`runtime.hand_builtins`) any kept fn references;
    //    each referenced body is appended below. Those bodies emit their own `.import`
    //    relocs (e.g. `panic` -> `write`), so the dyld import set is DERIVED from
    //    `data_relocs` like any other import.
    var used = [_]bool{false} ** runtime.hand_builtins.len;
    // The collector reads the GC stack map, so a kept fn naming the map's base means the
    // collector runs: reserve and emit the map. A heap-free program has none and stays
    // byte-identical.
    var uses_gc = false;
    for (all.items) |f| {
        for (f.relocs) |rl| switch (rl.target) {
            .func => |s| if (s.kind == .builtin) {
                for (runtime.hand_builtins, 0..) |hb, i| {
                    if (std.mem.eql(u8, s.name, hb.name)) used[i] = true;
                }
            },
            .cstr => |h| if (h == Link.gc_stackmap_base_hash) {
                uses_gc = true;
            },
            else => {},
        };
    }
    // `panic` alone is consumed past the append: it drags in the `write` import and
    // reserves the backtrace symbol table's slot.
    const uses_panic = used[comptime runtime.handBuiltinIndex("panic")];
    // The referenced hand-emitted builtin bodies follow the kept fns, in `hand_builtins`
    // order, so the linked image never depends on thread order.
    for (0..runtime.hand_builtins.len) |i| {
        if (used[i]) try all.append(gpa, try backend.hand_builtins[i](gpa));
    }

    // 2) Intern strings program-wide via `internCstrings` (stable collect +
    //    prefix-sum blob). The caller owns the returned blob; the map is borrowed
    //    only until step 3 rewrites the reloc targets.
    var interned = try internCstrings(gpa, all.items);
    defer interned.off_by_hash.deinit(gpa);
    var cstrings_blob: ?[]u8 = interned.cstrings;
    errdefer if (cstrings_blob) |b| gpa.free(b);
    const off_by_hash = &interned.off_by_hash;

    // 2b) Reserve the backtrace symbol table's slot at the (8-aligned) END of the
    //     __cstring blob and bind the sentinel hash `__panic`'s `.cstr` reloc carries
    //     to that offset, so step 3 rewrites it like any string. The table BYTES are
    //     appended after `link` (they depend on the layout it computes); only their
    //     start offset is known now. A real literal hashing to the sentinel would be
    //     silently mis-pointed — reject it (astronomically unlikely).
    // The descriptor table is reserved FIRST (before the symtab), so when there are no
    // descriptors `desc_table_off == symtab_off == align8(cstrings.len)` — the panic corpus
    // reservation is byte-identical. Each per-type sentinel maps to its 48-byte entry.
    const desc_table_off: u32 = std.mem.alignForward(u32, @intCast(interned.cstrings.len), 8);
    const n_desc = descriptors.len;
    if (n_desc > 0) {
        for (descriptors, 0..) |e, i| {
            if (off_by_hash.contains(e.desc_hash)) return error.CstringHashCollision;
            try off_by_hash.put(gpa, e.desc_hash, @intCast(@as(usize, desc_table_off) + i * ValueLayout.desc.stride));
        }
    }
    // The GC stack map is reserved BETWEEN the descriptor table and the symtab, only when
    // the collector runs. When no gc, `stackmap_off`/`stackmap_len` collapse and
    // `symtab_off == after_desc` — the panic-but-not-gc corpus stays byte-identical.
    const after_desc: u32 = if (n_desc > 0)
        std.mem.alignForward(u32, desc_table_off + @as(u32, @intCast(n_desc * ValueLayout.desc.stride)), 8)
    else
        desc_table_off;
    const stackmap_off: u32 = after_desc;
    var stackmap_len: u32 = 0;
    if (uses_gc) {
        if (off_by_hash.contains(Link.gc_stackmap_base_hash)) return error.CstringHashCollision;
        try off_by_hash.put(gpa, Link.gc_stackmap_base_hash, stackmap_off);
        stackmap_len = stackMapLen(all.items);
    }
    const symtab_off: u32 = if (uses_gc)
        std.mem.alignForward(u32, stackmap_off + stackmap_len, 8)
    else
        after_desc;
    if (uses_panic) {
        if (off_by_hash.contains(Link.symtab_base_hash)) return error.CstringHashCollision;
        try off_by_hash.put(gpa, Link.symtab_base_hash, symtab_off);
    }

    // 3) Rewrite every `.cstr` reloc target from content hash → global offset, in
    //    parallel over fns. Each fn owns its own `relocs` array (disjoint writes);
    //    `off_by_hash` is a read-only map looked up BY KEY (never iterated), so the
    //    rewrite is order-free and byte-identical at any -j.
    {
        const Ctx = struct {
            fns: []Link.FnCode,
            off_by_hash: *const std.AutoHashMapUnmanaged(u64, u32),
            pub fn args(c: @This(), i: usize) std.meta.ArgsTuple(@TypeOf(rewriteCstrJob)) {
                return .{ c.fns[i], c.off_by_hash };
            }
        };
        // one task per ~ncpu fn RANGE, not per fn (10K fns × by-key map
        // lookups). ncpu=0 => host cpus. `off_by_hash` is read-only by key (never
        // iterated) and each fn owns its own relocs, so chunked == serial byte-for-byte.
        Engine.chunkedFanOut(io, all.items.len, 0, Engine.Chunk.cstr.threshold, Engine.Chunk.cstr.chunks_per_cpu, rewriteCstrJob, Ctx{
            .fns = all.items,
            .off_by_hash = off_by_hash,
        });
    }

    // 4) Intern symbols (source order) and link.
    var si: Link.SymInterner = .{};
    defer si.deinit(gpa);
    const linked = try Link.link(io, gpa, &backend.relocs, all.items, &si, entry, uses_panic, uses_gc, descriptors, debug);
    errdefer gpa.free(linked.text);
    errdefer linked.debug.deinit(gpa);
    errdefer gpa.free(linked.data_relocs);
    defer gpa.free(linked.sym_table);
    defer gpa.free(linked.desc_table);
    defer gpa.free(linked.stack_map);
    // The pre-link length reservation must equal the linked table's actual size.
    std.debug.assert(!uses_gc or linked.stack_map.len == stackmap_len);

    // 4b) Append the reserved __cstring tail — the descriptor table (at `desc_table_off`)
    //     then the backtrace symbol table (at `symtab_off`), each padded to its 8-aligned
    //     start so it rides in the signed, read-only section and the reserved `.cstr` relocs
    //     resolve to it. With no descriptors the desc branch is skipped and the symtab pads
    //     to the SAME offset as before → byte-identical.
    if (linked.desc_table.len > 0 or (uses_gc and linked.stack_map.len > 0) or (uses_panic and linked.sym_table.len > 0)) {
        var grown: std.ArrayList(u8) = .empty;
        errdefer grown.deinit(gpa);
        const old = cstrings_blob.?;
        try grown.appendSlice(gpa, old);
        if (linked.desc_table.len > 0) {
            try grown.appendNTimes(gpa, 0, @as(usize, desc_table_off) - grown.items.len);
            try grown.appendSlice(gpa, linked.desc_table);
        }
        // Stack map sits between the descriptor table and the symtab.
        if (uses_gc and linked.stack_map.len > 0) {
            try grown.appendNTimes(gpa, 0, @as(usize, stackmap_off) - grown.items.len);
            try grown.appendSlice(gpa, linked.stack_map);
        }
        if (uses_panic and linked.sym_table.len > 0) {
            try grown.appendNTimes(gpa, 0, @as(usize, symtab_off) - grown.items.len);
            try grown.appendSlice(gpa, linked.sym_table);
        }
        const new = try grown.toOwnedSlice(gpa); // old still owned on failure (errdefer frees it)
        cstrings_blob = new;
        gpa.free(old);
    }

    // The data-relocs' `.import` target names point into `all`'s FnCodes, which
    // the deferred `all` deinit is about to free. Dupe them so the caller owns
    // them past this scope.
    {
        var done: usize = 0;
        errdefer for (linked.data_relocs[0..done]) |rl| switch (rl.target) {
            .import => |s| gpa.free(s.name),
            else => {},
        };
        for (linked.data_relocs) |*rl| {
            switch (rl.target) {
                .import => |s| rl.target = .{ .import = .{ .kind = s.kind, .name = try gpa.dupe(u8, s.name) } },
                else => {},
            }
            done += 1;
        }
    }

    const cstr_bytes = cstrings_blob.?;
    cstrings_blob = null; // ownership handed to the caller; suppress the errdefer free

    return Linked{
        .text = linked.text,
        .entry_off = linked.entry_off,
        .cstrings = cstr_bytes,
        .data_relocs = linked.data_relocs,
        .debug = linked.debug,
    };
}

/// The pre-link byte length of the GC stack-map table `Link.buildStackMapTable` will
/// produce for `fns` — computed from each `FnCode.root_bitmap` and `safepoint_maps`
/// (present pre-link), so the symtab's reserved offset is known before layout. Two
/// spellings of one size; the `std.debug.assert` at the link callsite guards them against
/// drift. Layout mirrors `buildSideTable`: `[u64 count][{off,payload_off}×count][blob]`,
/// count = `Link.stackMapRows`, blob = Σ per-fn payload (`root_bitmap` or the 4-byte
/// conservative marker) + Σ safepoint row payloads + the sentinel's 4-byte marker.
fn stackMapLen(fns: []const Link.FnCode) u32 {
    var blob: usize = 4; // sentinel's conservative marker
    for (fns) |f| {
        blob += if (f.root_bitmap.len == 0) 4 else f.root_bitmap.len;
        var it: Link.SafepointRows = .{ .bytes = f.safepoint_maps };
        while (it.next()) |r| blob += r.payload.len;
    }
    return @intCast(8 + Link.stackMapRows(fns) * 16 + blob);
}

/// Rewrite one fn's `.cstr` reloc targets from content hash → global `__cstring`
/// offset (a `fanOut` job). Writes ONLY this fn's `relocs` (disjoint per fn);
/// `off_by_hash` is read-only and looked up by key.
fn rewriteCstrJob(f: Link.FnCode, off_by_hash: *const std.AutoHashMapUnmanaged(u64, u32)) void {
    for (f.relocs) |*rl| switch (rl.target) {
        .cstr => |h| rl.target = .{ .cstr = off_by_hash.get(h).? },
        else => {},
    };
}

/// The result of program-wide cstring interning: the `__cstring` blob (each unique
/// literal's bytes followed by a NUL, in stable order) and a hash→blob-offset map.
/// `cstrings` is heap-owned by the caller; `off_by_hash` is freed by the caller.
pub const InternedCstrings = struct {
    cstrings: []u8,
    off_by_hash: std.AutoHashMapUnmanaged(u64, u32),
};

/// Intern the per-fn string literals of `fns` program-wide. Split into a STABLE
/// COLLECT pass and a PREFIX-SUM offset/blob pass so the offset assignment is the
/// same standalone, parallel-scan-ready barrier as the text layout — the math (a
/// running byte cursor) is unchanged, only the executor is.
///
/// Pass A (collect): walk fns in SOURCE ORDER, then in-fn literal order, keeping
/// the FIRST occurrence of each hash. This stable
/// (fn-source-index, in-fn-index) order is the ONLY thing that decides the blob
/// layout — never hashmap iteration order — so the blob is byte-identical
/// regardless of any future sharding of the collect.
///
/// Pass B (prefix-sum + blob): assign each unique literal its offset by an
/// exclusive prefix-sum over (bytes.len + 1 for NUL) in the SAME stable order,
/// appending bytes + NUL and recording the hash→offset map from the same pass.
fn internCstrings(gpa: std.mem.Allocator, fns: []const Link.FnCode) !InternedCstrings {
    var off_by_hash: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    errdefer off_by_hash.deinit(gpa);

    var uniques: std.ArrayList(Link.Literal) = .empty; // bytes are borrowed, not owned
    defer uniques.deinit(gpa);
    {
        var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty; // hash → index into uniques
        defer seen.deinit(gpa);
        for (fns) |f| {
            for (f.literals) |lit| {
                if (seen.get(lit.hash)) |existing| {
                    // Distinct literals sharing a 64-bit hash would otherwise point
                    // the second's reloc at the first's bytes — a silent wrong-output
                    // miscompile. Reject unconditionally (NOT a debug assert: this
                    // guard must hold in the shipping ReleaseFast build too).
                    if (!std.mem.eql(u8, lit.bytes, uniques.items[existing].bytes))
                        return error.CstringHashCollision;
                    continue;
                }
                try seen.put(gpa, lit.hash, @intCast(uniques.items.len));
                try uniques.append(gpa, lit);
            }
        }
    }

    var cstrings: std.ArrayList(u8) = .empty;
    errdefer cstrings.deinit(gpa);
    var off: u32 = 0;
    for (uniques.items) |lit| {
        // `off` is the running cursor; the stored offset is the exclusive prefix
        // (cursor BEFORE this literal) — identical to the old fused loop's
        // `off = cstrings.items.len` taken just before each append.
        std.debug.assert(off == @as(u32, @intCast(cstrings.items.len)));
        try off_by_hash.put(gpa, lit.hash, off);
        try cstrings.appendSlice(gpa, lit.bytes);
        try cstrings.append(gpa, 0); // NUL (str.len excludes it)
        off += @as(u32, @intCast(lit.bytes.len)) + 1;
    }

    return .{ .cstrings = try cstrings.toOwnedSlice(gpa), .off_by_hash = off_by_hash };
}

/// The DISTINCT `.import` reloc targets, sorted by name bytes — the canonical GOT slot
/// order — each bound to its library. Dedup first (via `seen`) means the sort ranges over
/// unique keys, so sort stability is moot: the total order is a pure function of the name
/// SET, independent of `data_relocs` arrival order / thread count. Names are borrowed
/// from `data_relocs`; caller owns the slice.
fn importsOf(gpa: std.mem.Allocator, data_relocs: []const Link.Reloc, libs: LibResolver.Linking) ![]Image.Import {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var out: std.ArrayList(Image.Import) = .empty;
    errdefer out.deinit(gpa);
    for (data_relocs) |rl| switch (rl.target) {
        .import => |s| {
            const gop = try seen.getOrPut(gpa, s.name);
            if (!gop.found_existing) try out.append(gpa, .{ .name = s.name, .library = libs.libraryOf(s.name) });
        },
        else => {},
    };
    std.mem.sort(Image.Import, out.items, {}, struct {
        fn lt(_: void, a: Image.Import, b: Image.Import) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// One object format's writer: the finished, runnable bytes of `img`. `identifier` is the
/// output's name where the format records one (the Mach-O code-signing identity).
pub const Writer = *const fn (io: Io, gpa: std.mem.Allocator, img: *const Image, identifier: []const u8) error{OutOfMemory}![]u8;

/// The writer for `format`, or null when toy cannot write it yet.
pub fn writerOf(format: Target.ObjectFormat) ?Writer {
    return switch (format) {
        .macho => &MachO.writeSigned,
        .elf => null,
    };
}

/// Whether toy emits code for `target`: it has an ISA module for the arch and a
/// writer for its object format, so any other target stops at `toy check`.
pub fn canEmit(target: Target) bool {
    return Isa.of(target) != null and writerOf(target.objectFormat()) != null;
}

/// The runnable image for `target`, in its object format. `code` is the linked text,
/// `entry_off` the entry function's offset in it, `cstrings` the interned read-only
/// bytes, and `data_relocs` the cross-segment patches `Link.link` rebased to absolute
/// text offsets; the import set is derived from their `.import` targets. `identifier`
/// is the Mach-O code-signing identity (the output basename). The driver rejects a
/// target `canEmit` refuses before it lowers, so `error.UnsupportedTarget` is a caller
/// bug. Caller owns the returned bytes and writes them mode 0o755.
pub fn writeImage(
    io: Io,
    gpa: std.mem.Allocator,
    target: Target,
    patcher: *const Link.Patcher,
    identifier: []const u8,
    code: []const u8,
    entry_off: u32,
    cstrings: []const u8,
    data_relocs: []const Link.Reloc,
    libs: LibResolver.Linking,
    debug: Image.Debug,
) ![]u8 {
    if (Isa.of(target) == null) return error.UnsupportedTarget;
    const write = writerOf(target.objectFormat()) orelse return error.UnsupportedTarget;
    const imports = try importsOf(gpa, data_relocs, libs);
    defer gpa.free(imports);
    const wants_bss = for (data_relocs) |rl| {
        if (rl.target == .data) break true;
    } else false;
    const img: Image = .{
        .arch = target.arch,
        .text = code,
        .entry_off = entry_off,
        .cstrings = cstrings,
        .bss_size = if (wants_bss) Link.bss_size else 0,
        .imports = imports,
        .libraries = libs.libraries,
        .search_paths = libs.search_paths,
        .relocs = data_relocs,
        .patcher = patcher,
        .debug = debug,
    };
    return write(io, gpa, &img, identifier);
}

/// THE SINGLE PUBLIC BOUNDARY: lowered `FnCode`s -> a runnable image (signed, for
/// Mach-O). CONSUMES `fns`. Fuses `linkProgram` + `writeImage`; the step order
/// is byte-load-bearing (sign LAST). `entry` is the entry function's stable
/// symbol identity (e.g. `{.user_fn, "main"}`). Caller owns the returned bytes.
pub fn emitExecutable(io: Io, gpa: std.mem.Allocator, backend: *const Isa.Backend, fns: []Link.FnCode, entry: sym.SymName, opts: Options) ![]u8 {
    const lk = try linkProgram(io, gpa, backend, fns, entry, opts.descriptors, opts.debug);
    defer {
        lk.debug.deinit(gpa);
        gpa.free(lk.text);
        gpa.free(lk.cstrings);
        for (lk.data_relocs) |rl| switch (rl.target) {
            .import => |s| gpa.free(s.name),
            else => {},
        };
        gpa.free(lk.data_relocs);
    }
    return writeImage(io, gpa, opts.target, &backend.relocs, opts.identifier, lk.text, lk.entry_off, lk.cstrings, lk.data_relocs, .{}, lk.debug);
}

/// A literals-only `FnCode` for the cstring-interning tests (other fields unused
/// by `internCstrings`). Borrows the caller's literal slice — no ownership.
fn litFn(literals: []const Link.Literal) Link.FnCode {
    return .{ .sym = .{ .kind = .user_fn, .name = "" }, .code = &.{}, .relocs = &.{}, .literals = @constCast(literals) };
}

// These tests link through `Link.TestIsa`: they test the tail's ordering and determinism,
// not an encoding, so each word is a zero placeholder the test patcher overwrites.
const T = Link.TestIsa;

/// `T.patcher` with a placeholder body per hand builtin. `panic`'s imports `write`, as
/// every ISA's does.
const test_backend: Isa.Backend = .{ .c_abi = .aapcs64_apple, .lower = noLower, .fits = noFits, .relocs = T.patcher, .hand_builtins = &test_builtins, .inst_count = noCount };

const test_builtins = blk: {
    var out: [runtime.hand_builtins.len]Isa.BuiltinFn = undefined;
    for (runtime.hand_builtins, &out) |hb, *f| f.* = testBuiltin(hb.name);
    break :blk out;
};

fn testBuiltin(comptime name: []const u8) Isa.BuiltinFn {
    return struct {
        fn lower(gpa: std.mem.Allocator) error{OutOfMemory}!Link.FnCode {
            const code = try gpa.alloc(u8, 4);
            @memset(code, 0);
            var relocs: []Link.Reloc = &.{};
            if (std.mem.eql(u8, name, "panic")) {
                relocs = try gpa.alloc(Link.Reloc, 1);
                relocs[0] = .{ .site = 0, .target = .{ .import = .{ .kind = .import, .name = try gpa.dupe(u8, "write") } }, .kind = T.pcrel };
            }
            return .{ .sym = .{ .kind = .builtin, .name = try gpa.dupe(u8, name) }, .code = code, .relocs = relocs, .literals = &.{} };
        }
    }.lower;
}

fn noFits(_: std.mem.Allocator, _: *const @import("../ir/Ir.zig").Function, _: []const @import("../types.zig").Layout, _: []const @import("../types.zig").EnumLayout) error{OutOfMemory}!bool {
    unreachable;
}

fn noCount(_: []const u8) usize {
    unreachable;
}

fn noLower(_: std.mem.Allocator, _: *const @import("../ir/Ir.zig").Function, _: []const @import("../types.zig").Layout, _: []const @import("../types.zig").EnumLayout, _: bool, _: bool, _: *std.ArrayList(@import("../diagnostics/Diagnostic.zig").Diagnostic)) error{OutOfMemory}!Link.FnCode {
    unreachable;
}

/// Build one owned `FnCode` for the determinism test: an address pair referencing a
/// cstring literal (a cross-segment data-reloc pair) plus, if `call_panic`, a call to the
/// appended `panic` builtin, which drags in `write` + the symbol table. Consumed (freed)
/// by `linkProgram`.
fn detFn(gpa: std.mem.Allocator, name: []const u8, lit_hash: u64, lit_bytes: []const u8, call_panic: bool) !Link.FnCode {
    return detFnCalling(gpa, name, lit_hash, lit_bytes, call_panic, &.{});
}

/// `detFn` that also ends in a call to each of `callees`, so the link
/// keeps them.
fn detFnCalling(gpa: std.mem.Allocator, name: []const u8, lit_hash: u64, lit_bytes: []const u8, call_panic: bool, callees: []const []const u8) !Link.FnCode {
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    var relocs: std.ArrayList(Link.Reloc) = .empty;
    try words.appendSlice(gpa, &.{ 0, 0 });
    try relocs.append(gpa, .{ .site = 0, .target = .{ .cstr = lit_hash }, .kind = T.pcrel });
    try relocs.append(gpa, .{ .site = 4, .target = .{ .cstr = lit_hash }, .kind = T.pcrel });
    if (call_panic) {
        try relocs.append(gpa, .{ .site = @intCast(words.items.len * 4), .target = .{ .func = .{ .kind = .builtin, .name = try gpa.dupe(u8, "panic") } }, .kind = T.call });
        try words.append(gpa, 0);
    }
    for (callees) |c| {
        try relocs.append(gpa, .{ .site = @intCast(words.items.len * 4), .target = .{ .func = .{ .kind = .user_fn, .name = try gpa.dupe(u8, c) } }, .kind = T.call });
        try words.append(gpa, 0);
    }
    try words.append(gpa, 0);
    const code = try gpa.alloc(u8, words.items.len * 4);
    for (words.items, 0..) |w, i| std.mem.writeInt(u32, code[i * 4 ..][0..4], w, .little);
    const lits = try gpa.alloc(Link.Literal, 1);
    lits[0] = .{ .hash = lit_hash, .bytes = try gpa.dupe(u8, lit_bytes) };
    return .{ .sym = .{ .kind = .user_fn, .name = try gpa.dupe(u8, name) }, .code = code, .relocs = try relocs.toOwnedSlice(gpa), .literals = lits };
}

/// Build one owned `FnCode` that calls an `extern` import `sym` via its GOT slot (and
/// then `callee`, if any), with the two `.import` relocs the cross-segment pass rebases
/// to the `__got` slot. Consumed (freed) by
/// `linkProgram`.
fn importFn(gpa: std.mem.Allocator, name: []const u8, sym_name: []const u8, callee: ?[]const u8) !Link.FnCode {
    const code = try gpa.alloc(u8, if (callee != null) 20 else 16);
    std.mem.writeInt(u32, code[0..4], 0, .little);
    std.mem.writeInt(u32, code[4..8], 0, .little);
    std.mem.writeInt(u32, code[8..12], 0, .little);
    if (callee != null) std.mem.writeInt(u32, code[12..16], 0, .little);
    std.mem.writeInt(u32, code[code.len - 4 ..][0..4], 0, .little);
    var relocs: std.ArrayList(Link.Reloc) = .empty;
    try relocs.append(gpa, .{ .site = 0, .target = .{ .import = .{ .kind = .import, .name = try gpa.dupe(u8, sym_name) } }, .kind = T.pcrel });
    try relocs.append(gpa, .{ .site = 4, .target = .{ .import = .{ .kind = .import, .name = try gpa.dupe(u8, sym_name) } }, .kind = T.pcrel });
    if (callee) |c| try relocs.append(gpa, .{ .site = 12, .target = .{ .func = .{ .kind = .user_fn, .name = try gpa.dupe(u8, c) } }, .kind = T.call });
    return .{ .sym = .{ .kind = .user_fn, .name = try gpa.dupe(u8, name) }, .code = code, .relocs = try relocs.toOwnedSlice(gpa), .literals = &.{} };
}

/// Two fns importing distinct dyld symbols (`write`, `labs`) → a 2-slot `__got`. `main`
/// calls `aaa`, so the link keeps both. Fresh (owned) each call so both determinism-test
/// runs get their own to consume.
fn twoImportFns(gpa: std.mem.Allocator) ![]Link.FnCode {
    const fns = try gpa.alloc(Link.FnCode, 2);
    fns[0] = try importFn(gpa, "aaa", "write", null);
    fns[1] = try importFn(gpa, "main", "labs", "aaa");
    return fns;
}

test "dfe: linkProgram drops a fn unreachable from the entry, with its import and strings" {
    const gpa = testing.allocator;
    const entry = Link.SymName{ .kind = .user_fn, .name = "main" };
    const fns = try gpa.alloc(Link.FnCode, 3);
    defer gpa.free(fns);
    fns[0] = try importFn(gpa, "aaa", "write", null);
    fns[1] = try detFn(gpa, "bbb", 0x2222, "beta", true);
    fns[2] = try importFn(gpa, "main", "labs", null);

    var t = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer t.deinit();
    var lk = try linkProgram(t.io(), gpa, &test_backend, fns, entry, &.{}, null);
    defer freeLinked(gpa, &lk);

    // Only `main` survives: no `aaa`, no `bbb`, so no `panic` body either.
    try testing.expectEqual(@as(usize, 16), lk.text.len);
    try testing.expectEqual(@as(u32, 0), lk.entry_off);
    try testing.expectEqual(@as(usize, 0), lk.cstrings.len);
    try testing.expectEqual(@as(usize, 2), lk.data_relocs.len);
    for (lk.data_relocs) |rl| try testing.expectEqualStrings("labs", rl.target.import.name);
}

test "one writer lookup decides which object formats toy emits" {
    try testing.expect(writerOf(.macho) != null);
    try testing.expect(writerOf(.elf) == null);
    try testing.expect(canEmit(.aarch64_macos));
    try testing.expect(!canEmit(.aarch64_linux));
}

test "backend spike: a 2-import (labs+write) image is byte-identical at -j1 and -jN" {
    // The [C11] gate: the generalized N-import chained-fixups blob + GOT layout + the
    // whole emitted image must be byte-identical regardless of thread count, because the
    // import set is DERIVED (dedup + stable-sort by name), never thread-arrival ordered.
    const gpa = testing.allocator;
    const entry = Link.SymName{ .kind = .user_fn, .name = "main" };

    const fns_serial = try twoImportFns(gpa);
    defer gpa.free(fns_serial);
    var t_serial = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer t_serial.deinit();
    const img_serial = try emitExecutable(t_serial.io(), gpa, &test_backend, fns_serial, entry, .{ .identifier = "spike" });
    defer gpa.free(img_serial);

    const fns_par = try twoImportFns(gpa);
    defer gpa.free(fns_par);
    var t_par = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(8) });
    defer t_par.deinit();
    const img_par = try emitExecutable(t_par.io(), gpa, &test_backend, fns_par, entry, .{ .identifier = "spike" });
    defer gpa.free(img_par);

    try testing.expectEqualSlices(u8, img_serial, img_par);

    // The __got sits at the third segment's __got section; its two slots carry the
    // name-sorted chained binds: labs (slot 0) then write (slot 1).
    const got_off: usize = MachO.PAGE; // __DATA_CONST is the page after single-page __TEXT
    try testing.expectEqual(@as(u64, 0x8010000000000000), std.mem.readInt(u64, img_serial[got_off..][0..8], .little));
    try testing.expectEqual(@as(u64, 0x8000000000000001), std.mem.readInt(u64, img_serial[got_off + 8 ..][0..8], .little));
}

/// One owned `FnCode` `main` that reads the collector's control block and the GC stack
/// map, as the collector does: the address of each. Fresh each call so both
/// determinism-test runs get their own to consume.
fn gcFns(gpa: std.mem.Allocator) ![]Link.FnCode {
    const fns = try gpa.alloc(Link.FnCode, 1);
    const code = try gpa.alloc(u8, 20);
    for (0..2) |k| {
        std.mem.writeInt(u32, code[k * 8 ..][0..4], 0, .little);
        std.mem.writeInt(u32, code[k * 8 + 4 ..][0..4], 0, .little);
    }
    std.mem.writeInt(u32, code[16..20], 0, .little);
    const relocs = try gpa.dupe(Link.Reloc, &.{
        .{ .site = 0, .target = .{ .data = 0 }, .kind = T.pcrel },
        .{ .site = 4, .target = .{ .data = 0 }, .kind = T.pcrel },
        .{ .site = 8, .target = .{ .cstr = Link.gc_stackmap_base_hash }, .kind = T.pcrel },
        .{ .site = 12, .target = .{ .cstr = Link.gc_stackmap_base_hash }, .kind = T.pcrel },
    });
    fns[0] = .{ .sym = .{ .kind = .user_fn, .name = try gpa.dupe(u8, "main") }, .code = code, .relocs = relocs, .literals = &.{} };
    return fns;
}

test "backend determinism: a collector-using image is byte-identical at -j1 and -jN" {
    // The control block's zero-fill segment and the stack map must be a pure function of
    // the fn set, so the whole image is identical regardless of thread count.
    const gpa = testing.allocator;
    const entry = Link.SymName{ .kind = .user_fn, .name = "main" };

    const fns_serial = try gcFns(gpa);
    defer gpa.free(fns_serial);
    var t_serial = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer t_serial.deinit();
    const img_serial = try emitExecutable(t_serial.io(), gpa, &test_backend, fns_serial, entry, .{ .identifier = "gc" });
    defer gpa.free(img_serial);

    const fns_par = try gcFns(gpa);
    defer gpa.free(fns_par);
    var t_par = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(8) });
    defer t_par.deinit();
    const img_par = try emitExecutable(t_par.io(), gpa, &test_backend, fns_par, entry, .{ .identifier = "gc" });
    defer gpa.free(img_par);

    try testing.expectEqualSlices(u8, img_serial, img_par);
    // The control block's `.data` relocs are what make the linker add the zero-fill segment.
    try testing.expect(std.mem.indexOf(u8, img_serial, "__bss") != null);
    try testing.expect(std.mem.indexOf(u8, img_serial, "_msync") == null);
}

test "backend determinism: the gc stack-map table (riding __cstring) is byte-identical at -j1 and -jN" {
    // A collector-using program reserves + appends the GC stack map into the signed,
    // read-only __cstring blob. It is built from the layout (stable-sort-ranked offsets +
    // each fn's root bitmap), a pure function of the fn set, so the whole __cstring blob —
    // stack map included — is byte-identical regardless of thread count. Assert the blob is
    // non-empty (the table rides it) and matches across `-j`.
    const gpa = testing.allocator;
    const entry = Link.SymName{ .kind = .user_fn, .name = "main" };

    const fns_serial = try gcFns(gpa);
    defer gpa.free(fns_serial);
    var t_serial = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer t_serial.deinit();
    var serial = try linkProgram(t_serial.io(), gpa, &test_backend, fns_serial, entry, &.{}, null);
    defer freeLinked(gpa, &serial);

    const fns_par = try gcFns(gpa);
    defer gpa.free(fns_par);
    var t_par = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(8) });
    defer t_par.deinit();
    var parallel_lk = try linkProgram(t_par.io(), gpa, &test_backend, fns_par, entry, &.{}, null);
    defer freeLinked(gpa, &parallel_lk);

    try testing.expectEqualSlices(u8, serial.text, parallel_lk.text);
    try testing.expectEqualSlices(u8, serial.cstrings, parallel_lk.cstrings);
    // The stack map lives in __cstring: a gc program's blob is non-empty even with no string
    // literals (the reserved table bytes are appended past the literal region).
    try testing.expect(serial.cstrings.len > 0);
}

/// Three fns with distinct cstrings; `main` calls the other two and `panic`. Fresh (owned) each call
/// so both determinism-test runs get their own copy to consume. `linkProgram` deinits
/// the ELEMENTS but not the slice backing, so the caller frees the returned slice.
fn detFns(gpa: std.mem.Allocator) ![]Link.FnCode {
    const fns = try gpa.alloc(Link.FnCode, 3);
    fns[0] = try detFn(gpa, "aaa", 0x1111, "alpha", false);
    fns[1] = try detFn(gpa, "bbb", 0x2222, "beta", false);
    fns[2] = try detFnCalling(gpa, "main", 0x3333, "gamma", true, &.{ "aaa", "bbb" });
    return fns;
}

fn freeLinked(gpa: std.mem.Allocator, lk: *Linked) void {
    gpa.free(lk.text);
    gpa.free(lk.cstrings);
    for (lk.data_relocs) |rl| if (rl.target.name()) |nm| gpa.free(nm);
    gpa.free(lk.data_relocs);
}

test "backend determinism: linkProgram is byte-identical at -j1 and -jN across every parallel seam" {
    // The load-bearing -jN invariant was verified only at each component (interning,
    // prefix-sum, stable-sort, sign); this drives the WHOLE link tail — cstring interning
    // + `.cstr` rewrite + parallel fnLinkJob + data-reloc stable-concat + panic symbol-table
    // build/append — serially (.limited(0)) vs on real threads (.limited(8)) and asserts the
    // emitted __text + __cstring + the deferred reloc list are identical. This is the seam
    // between the deterministic components, exactly where a regression would hide.
    const gpa = testing.allocator;
    const entry = Link.SymName{ .kind = .user_fn, .name = "main" };

    const fns_serial = try detFns(gpa);
    defer gpa.free(fns_serial); // linkProgram consumes the elements, not the slice
    var t_serial = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer t_serial.deinit();
    var serial = try linkProgram(t_serial.io(), gpa, &test_backend, fns_serial, entry, &.{}, null);
    defer freeLinked(gpa, &serial);

    const fns_par = try detFns(gpa);
    defer gpa.free(fns_par);
    var t_par = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(8) });
    defer t_par.deinit();
    var parallel_lk = try linkProgram(t_par.io(), gpa, &test_backend, fns_par, entry, &.{}, null);
    defer freeLinked(gpa, &parallel_lk);

    try testing.expectEqualSlices(u8, serial.text, parallel_lk.text);
    try testing.expectEqualSlices(u8, serial.cstrings, parallel_lk.cstrings);
    try testing.expectEqual(serial.entry_off, parallel_lk.entry_off);
    // The deferred cross-segment relocs must match in order (the stable-concat seam) and shape.
    try testing.expectEqual(serial.data_relocs.len, parallel_lk.data_relocs.len);
    for (serial.data_relocs, parallel_lk.data_relocs) |a, b| {
        try testing.expectEqual(a.site, b.site);
        try testing.expectEqual(a.kind, b.kind);
    }
}

test "internCstrings: blob+offsets identical under shuffled per-fn collection order" {
    const gpa = testing.allocator;
    // Dedup keeps FIRST occurrence in (fn-source-order, in-fn-order); offsets are a
    // prefix-sum over that stable order. The blob+map are a pure function of that
    // order, so the SAME fns interned must give a byte-identical blob and identical
    // offsets. We shuffle the in-fn literal lists WITHOUT moving fns and confirm the
    // canonical order's output is reproduced.
    const A = Link.Literal{ .hash = 100, .bytes = @constCast("alpha") };
    const B = Link.Literal{ .hash = 200, .bytes = @constCast("bb") };
    const C = Link.Literal{ .hash = 300, .bytes = @constCast("gamma!") };
    // fn0: [A, B, A(dup)], fn1: [C, B(dup)] — stable unique order is A,B,C.
    const fn0_lits = [_]Link.Literal{ A, B, A };
    const fn1_lits = [_]Link.Literal{ C, B };
    const fns = [_]Link.FnCode{ litFn(&fn0_lits), litFn(&fn1_lits) };

    var ref = try internCstrings(gpa, &fns);
    defer {
        gpa.free(ref.cstrings);
        ref.off_by_hash.deinit(gpa);
    }

    // Canonical layout: "alpha\0bb\0gamma!\0".
    try testing.expectEqualSlices(u8, "alpha\x00bb\x00gamma!\x00", ref.cstrings);
    try testing.expectEqual(@as(u32, 0), ref.off_by_hash.get(100).?); // A at 0
    try testing.expectEqual(@as(u32, 6), ref.off_by_hash.get(200).?); // B after "alpha\0"
    try testing.expectEqual(@as(u32, 9), ref.off_by_hash.get(300).?); // C after "bb\0"

    // Re-intern the IDENTICAL set; the result must be byte-identical (no dependence
    // on hashmap iteration / alloc order between runs).
    var again = try internCstrings(gpa, &fns);
    defer {
        gpa.free(again.cstrings);
        again.off_by_hash.deinit(gpa);
    }
    try testing.expectEqualSlices(u8, ref.cstrings, again.cstrings);
    try testing.expectEqual(ref.off_by_hash.get(100).?, again.off_by_hash.get(100).?);
    try testing.expectEqual(ref.off_by_hash.get(200).?, again.off_by_hash.get(200).?);
    try testing.expectEqual(ref.off_by_hash.get(300).?, again.off_by_hash.get(300).?);
}

test "internCstrings: first-occurrence-in-fn-order wins regardless of which fn holds the dup" {
    const gpa = testing.allocator;
    // Same hash carried by both fns; the FIRST occurrence (fn0) decides the bytes
    // and the offset — fn1's later copy is dropped. Putting the canonical literal in
    // fn1 instead must STILL yield identical bytes/offset for that single unique.
    const X = Link.Literal{ .hash = 7, .bytes = @constCast("only") };
    const fn0 = [_]Link.Literal{X};
    const fn1 = [_]Link.Literal{X};
    const fns = [_]Link.FnCode{ litFn(&fn0), litFn(&fn1) };
    var r = try internCstrings(gpa, &fns);
    defer {
        gpa.free(r.cstrings);
        r.off_by_hash.deinit(gpa);
    }
    try testing.expectEqualSlices(u8, "only\x00", r.cstrings); // deduped to one copy
    try testing.expectEqual(@as(u32, 0), r.off_by_hash.get(7).?);
}

test "internCstrings: a hash collision between distinct literals fails loud" {
    const gpa = testing.allocator;
    // A real 64-bit collision is unconstructable, so inject one: two literals with
    // an EQUAL hash but DIFFERENT bytes. Deduping the second onto the first would
    // be a silent wrong-output miscompile; interning must refuse instead.
    const P = Link.Literal{ .hash = 42, .bytes = @constCast("hello") };
    const Q = Link.Literal{ .hash = 42, .bytes = @constCast("world") };
    const lits = [_]Link.Literal{ P, Q };
    const fns = [_]Link.FnCode{litFn(&lits)};
    try testing.expectError(error.CstringHashCollision, internCstrings(gpa, &fns));
}
