//! Relocations: the vocabulary Link resolves, in one place.
//!
//! The `Reloc`/`SymbolId` types, the single source of truth for which targets own a heap
//! name (`SymbolId.name`), and the `Patcher` an ISA hands Link: which phase each of its
//! kinds resolves in and how each patches its site. The kinds and their encodings are the
//! ISA's (`codegen/Isa.zig`), so `Link` keeps only the orchestration — laying out code,
//! resolving handles and vmaddrs, and calling the patcher — and stays ISA-neutral. `Link`
//! re-exports the types so every `Link.Reloc`/`Link.SymbolId` callsite is unchanged.

const std = @import("std");
const symbols = @import("../symbols/Sym.zig");

pub const SymKind = symbols.SymKind;
pub const SymName = symbols.SymName;

/// A symbolic reference to a definition. NEVER an address — the linker (for
/// `.func`/intra-module) or the post-vmaddr pass (for the cross-segment cases) maps it
/// to a final address.
///
///   * `.func`   — a function, named by its stable `SymName`. Patched by `link`
///                 (a PC-relative call).
///   * `.cstr`   — a string literal. While lowered (and on disk) this holds the
///                 literal's CONTENT HASH; the relink tail rewrites it to a byte offset
///                 into the program-wide `__cstring` blob, after which the cross-segment
///                 pass reads it as that offset.
///   * `.import` — an external symbol, named by its stable `SymName` (always
///                 `{.import,"write"}`). Reached through its `__got` slot; patched by
///                 the cross-segment pass.
///   * `.none`   — no target. For a reloc whose patched value is derived purely from its
///                 own site + addend (a self-locate), so there is
///                 nothing to name or free.
///   * `.data`   — a byte offset into the writable zero-fill `__DATA,__bss` section
///                 (the GC control block). Patched by the cross-segment pass.
///   * `.text_off` — a `__text` byte offset, link-internal: `link` rewrites a `.func`
///                 address reloc (a function's address) to it once the callee's offset
///                 is known, so the cross-segment pass needs no symbol table. Never
///                 lowered and never cached.
pub const SymbolId = union(enum) {
    func: SymName,
    cstr: u64,
    import: SymName,
    none,
    data: u32,
    text_off: u32,

    /// The heap-owned name this target carries, if any. THE single source of truth for
    /// the "which targets own a name" rule — every free/dupe boundary asks here instead
    /// of re-deciding, so a new variant is a one-line change, not a six-site edit.
    pub fn name(self: SymbolId) ?[]const u8 {
        return switch (self) {
            .func, .import => |s| s.name,
            .cstr, .none, .data, .text_off => null,
        };
    }
};

/// A relocation kind, named by the ISA that emits it. Link carries it opaquely and
/// resolves it through that ISA's `Patcher`, so no encoding is named here.
pub const RelocKind = enum(u8) { _ };

/// Where a kind resolves. `.intra` — link time, from `__text` offsets alone (an offset,
/// not an address, so PIE-safe with no runtime reloc; patched in place by `link`).
/// `.cross` — once the object format has placed every section (`Image.patch`).
pub const Phase = enum { intra, cross };

/// One patch to apply during linking. `site` is the byte offset, within its owning
/// function's `code`, of the field to patch. `addend` shifts the resolved value; what
/// it means is the kind's.
pub const Reloc = struct {
    site: u32,
    target: SymbolId,
    kind: RelocKind,
    addend: i64 = 0,
};

pub const IntraError = error{CallTargetTooFar};

/// What Link needs from an ISA to resolve its relocations.
pub const Patcher = struct {
    /// Each kind's phase, indexed by the kind's value; a value past the end is no kind.
    phases: []const Phase,
    /// Patch an `.intra` kind in place at `text[site_abs..]`. `target_off` is the
    /// resolved `__text` offset of a `.func` target, else 0.
    patchIntra: *const fn (text: []u8, kind: RelocKind, site_abs: u32, target_off: u32, addend: i64) IntraError!void,
    /// Patch a `.cross` kind in place at `text[site..]`, the site loading at
    /// `site_vmaddr` and its target at `target_vmaddr`.
    patchCross: *const fn (text: []u8, kind: RelocKind, site: u32, site_vmaddr: u64, target_vmaddr: u64, addend: i64) void,

    pub fn phase(p: *const Patcher, kind: RelocKind) Phase {
        return p.phases[@intFromEnum(kind)];
    }

    pub fn names(p: *const Patcher, kind: u8) bool {
        return kind < p.phases.len;
    }
};

/// A two-kind ISA for the link tests, which test layout and resolution, not an
/// encoding: `call` writes the i32 byte delta from its site to its target's `__text`
/// offset, and `pcrel` the i32 delta from the site's address to its target's.
pub const TestIsa = struct {
    pub const call: RelocKind = @enumFromInt(0);
    pub const pcrel: RelocKind = @enumFromInt(1);
    pub const patcher: Patcher = .{ .phases = &.{ .intra, .cross }, .patchIntra = patchIntra, .patchCross = patchCross };

    fn patchIntra(text: []u8, kind: RelocKind, site_abs: u32, target_off: u32, addend: i64) IntraError!void {
        std.debug.assert(kind == call);
        const delta = @as(i64, target_off) + addend - site_abs;
        std.mem.writeInt(i32, text[site_abs..][0..4], std.math.cast(i32, delta) orelse return error.CallTargetTooFar, .little);
    }

    fn patchCross(text: []u8, kind: RelocKind, site: u32, site_vmaddr: u64, target_vmaddr: u64, addend: i64) void {
        std.debug.assert(kind == pcrel);
        const delta = @as(i64, @intCast(target_vmaddr)) + addend - @as(i64, @intCast(site_vmaddr));
        std.mem.writeInt(i32, text[site..][0..4], @intCast(delta), .little);
    }
};

/// The content-hash sentinel a `.cstr` reloc carries to name the backtrace symbol
/// table's base. The relink tail reserves it in the cstring offset map (→ the table's
/// byte offset in the appended `__cstring` blob), so `core/rt/panic` reaches the table via the
/// same `.cstr` path a string literal uses. Not a real hash (astronomically unlikely to
/// collide; the relink tail rejects an actual collision).
pub const symtab_base_hash: u64 = 0x5717_ab1e_ba5e_0000;

/// The content-hash sentinel naming the descriptor table's base. A distinct high prefix
/// from `symtab_base_hash` so the two reserved sentinels never alias; the per-type
/// `descHash(T)` sentinels share this prefix (see `Link.descHash`). Reserved in the
/// cstring offset map by the relink tail exactly like `symtab_base_hash`.
pub const desc_table_base_hash: u64 = 0xDE5C_0000_0000_0000;

/// The content-hash sentinel naming the GC stack-map table's base. A distinct high prefix
/// from the other two reserved sentinels so none alias; reserved in the cstring offset map
/// by the relink tail exactly like `symtab_base_hash`, and reached via the same
/// `.cstr` path (no new `RelocKind`/`SymbolId`). The collector loads the table base through
/// it to look up a frame's precise root map.
pub const gc_stackmap_base_hash: u64 = 0x57AC_C0DE_BA5E_0000;

/// Bytes of the writable zero-fill `__bss` an image gets when any reloc targets `.data`.
/// Only the GC control block lives there, whose fields `core/rt/gc` names by offset; a
/// test below holds every one of them inside.
pub const bss_size: u32 = 1024;

comptime {
    std.debug.assert(gc_stackmap_base_hash != symtab_base_hash and
        gc_stackmap_base_hash != desc_table_base_hash and gc_stackmap_base_hash != 0);
}

const testing = std.testing;

test "reserved side-table base hashes are pairwise distinct and nonzero" {
    try testing.expect(symtab_base_hash != desc_table_base_hash);
    try testing.expect(symtab_base_hash != gc_stackmap_base_hash);
    try testing.expect(desc_table_base_hash != gc_stackmap_base_hash);
    try testing.expect(gc_stackmap_base_hash != 0);
}

test "every control block field core/rt/gc names fits in __bss" {
    const classes = @import("../layout/ValueLayout.zig").size_classes.len;
    const src = for (@import("bundled_std").modules) |m| {
        if (std.mem.eql(u8, m.path, "core/rt/gc")) break m.source;
    } else return error.TestUnexpectedResult;
    // A per-list field has a head for each size class of each span kind.
    try testing.expectEqual(classes, try returnedInt(src, "fn class_count() -> int { return "));
    const lists = classes * try returnedInt(src, "fn list_count() -> int { return ");
    var fields: usize = 0;
    var end: usize = 0;
    var used = [_]bool{false} ** (bss_size / 8);
    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "fn ") or std.mem.indexOf(u8, line, "(cb: int") == null) continue;
        const at = std.mem.indexOf(u8, line, "{ return cb") orelse continue;
        var rest = line[at + "{ return cb".len ..];
        var off: usize = 0;
        if (std.mem.startsWith(u8, rest, " + ")) {
            rest = rest[3..];
            const n = std.mem.indexOfScalar(u8, rest, ' ').?;
            off = try std.fmt.parseInt(usize, rest[0..n], 10);
        }
        const words: usize = if (std.mem.indexOf(u8, rest, "list * 8") != null) lists else 1;
        end = @max(end, off + words * 8);
        try testing.expect(end <= bss_size);
        for (used[off / 8 ..][0..words]) |*w| {
            try testing.expect(!w.*);
            w.* = true;
        }
        fields += 1;
    }
    try testing.expect(fields >= 15);
}

/// The integer a one-line .toy fn returns, as in `fn f() -> int { return 13 }`, or the
/// factor in `{ return 3 * class_count() }`.
fn returnedInt(src: []const u8, head: []const u8) !usize {
    const at = (std.mem.indexOf(u8, src, head) orelse return error.TestUnexpectedResult) + head.len;
    const digits = std.mem.indexOfNone(u8, src[at..], "0123456789") orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(usize, src[at..][0..digits], 10);
}

test "SymbolId.name is the single source of truth for name ownership" {
    try testing.expectEqualStrings("f", (SymbolId{ .func = .{ .kind = .user_fn, .name = "f" } }).name().?);
    try testing.expectEqualStrings("write", (SymbolId{ .import = .{ .kind = .import, .name = "write" } }).name().?);
    try testing.expect((SymbolId{ .cstr = 7 }).name() == null);
    try testing.expect(@as(SymbolId, .none).name() == null);
}
