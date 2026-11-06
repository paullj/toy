//! The inliner's view of the program: which units are inline candidates, the callee IR
//! a build prepares for every caller, and the candidates a caller's cache key folds.

const std = @import("std");
const AstWalk = @import("AstWalk.zig");
const Cache = @import("Cache.zig");
const Closure = @import("../symbols/Closure.zig");
const Diagnostic = @import("../diagnostics/Diagnostic.zig").Diagnostic;
const Engine = @import("Engine.zig");
const Fingerprint = @import("Fingerprint.zig");
const Ir = @import("../ir/Ir.zig");
const Opt = @import("../opt/Opt.zig");
const Walk = @import("../ast/Walk.zig");
const Ast = @import("../ast/Ast.zig");
const Abi = @import("../codegen/abi/Abi.zig");
const Typecheck = @import("../types.zig");
const lower = @import("../lower.zig");
const DeriveEmit = @import("../lower/derive_emit.zig");
const StdNames = @import("../symbols/StdNames.zig");
const Frozen = Engine.Frozen;

/// Every unit of the program, found by its symbol: a read-only view of the codegen plan.
/// Any job may lower any unit through it, since every unit's lowering is a pure function
/// of its `Frozen` view.
pub const Units = struct {
    ctx: *const anyopaque,
    findFn: *const fn (ctx: *const anyopaque, name: []const u8) ?Frozen,
    cache: *InlineCache,

    pub fn find(u: Units, name: []const u8) ?Frozen {
        return u.findFn(u.ctx, name);
    }
};

/// How many levels of calls an inlined body may carry inlined into it: a caller takes its
/// callees with their own callees inlined, `inline_depth - 1` levels down.
pub const inline_depth = 3;

/// A callee of more AST nodes than this is never lowered to measure it against
/// `Opt.inliner.budget`. Nodes, unlike source bytes, ignore comments and layout; across
/// std and the bench programs no body that fits has more than 46.
const inline_nodes_max = 80;

/// Whether the inliner may splice a unit: a body from source that is no spec unit (so a
/// caller's key can fold its content), not `main`, owning no closure (its lambdas would
/// read an env from a frame that inlining dissolves); or an auto-derive unit, whose recipe
/// and layout (`Engine.deriveFp`) a caller's key folds in place of a source fingerprint.
fn inlineCandidate(fr: *const Frozen) bool {
    const s = switch (fr.body) {
        .source => |s| s,
        .derive => return true,
        else => return false,
    };
    if (s.spec or s.is_entry or fr.closure_facts.len != 0) return false;
    if (fr.in.closure.owner) |o| if (Closure.ownerUnits(fr.in.closure.lambda_units, o).len != 0) return false;
    const src: Walk.Source = .{ .tree = fr.in.tree, .tokens = fr.in.tokens, .source = fr.in.source };
    // A loop never leaves the IR (`Opt.inliner.fits` rejects it), so its body is not
    // lowered to find out.
    var shape: Shape = .{};
    Walk.walk(src, s.decl, &shape) catch unreachable;
    return !shape.loop and (shape.nodes <= inline_nodes_max or spliced(fr.sym.name));
}

const Shape = struct {
    nodes: usize = 0,
    loop: bool = false,

    pub fn on(self: *Shape, ev: Walk.Event) void {
        switch (ev) {
            .enter => |e| {
                self.nodes += 1;
                switch (e.tag) {
                    .while_stmt, .for_stmt, .for_in_stmt, .for_in2_stmt, .loop_expr => self.loop = true,
                    else => {},
                }
            },
            else => {},
        }
    }
};

/// A callee `Opt.inliner.splice` takes whatever its size (`StdNames.RuntimeFn.spliced`).
/// Bundled, so the compiler stamp covers its body in every caller's key.
fn spliced(name: []const u8) bool {
    const f = StdNames.RuntimeFn.lookup(name) orelse return false;
    return f.spliced() and StdNames.isBundledRuntimeSym(name);
}

/// The callees a unit's key folds by name: its call identities (`AstWalk.walkCalls`, a
/// spec unit's direct targets, an instance's conformance witnesses), a derive unit's field
/// witnesses, the symbol an adapter or an erased unit calls.
pub fn appendCallNames(gpa: std.mem.Allocator, fr: *const Frozen, out: *std.ArrayList([]const u8)) !void {
    switch (fr.body) {
        .source => |s| {
            try appendWalked(gpa, fr, s.decl, fr.in.sig, out);
            if (s.spec) for (fr.in.closure.spec_targets) |t| try out.append(gpa, t.sym.name);
        },
        .lambda => |l| try appendWalked(gpa, fr, fr.in.closure.lambda_units[l.unit].node, Engine.lambdaSig(fr, l), out),
        .derive => |d| for (d.field_witnesses) |fw| switch (fw) {
            .eq_call, .cmp_eq, .cmp_call, .hash_call, .display_call => |n| try out.append(gpa, n),
            .inline_kind => {},
        },
        .adapter => |a| try out.append(gpa, a.target.name),
        .erased => |u| if (Engine.erasedCall(fr, u)) |c| try out.append(gpa, c.sym.name),
    }
    for (fr.conformances) |rc| try out.appendSlice(gpa, rc.witness_syms);
}

fn appendWalked(gpa: std.mem.Allocator, fr: *const Frozen, node: Ast.Index, sig: ?Fingerprint.Sig, out: *std.ArrayList([]const u8)) !void {
    var sigs: std.ArrayList(Fingerprint.Sig) = .empty;
    defer sigs.deinit(gpa);
    try AstWalk.walkCalls(gpa, &fr.in, node, sig, &sigs);
    for (sigs.items) |sg| try out.append(gpa, sg.name);
}

/// The callees a unit's own lowering may splice: every callee its key folds, except for a
/// derive unit, whose own unit calls its field witnesses (an inlining caller takes them
/// through the derive's `Facts`).
fn appendInlineNames(gpa: std.mem.Allocator, fr: *const Frozen, out: *std.ArrayList([]const u8)) !void {
    if (fr.body == .derive) return;
    try appendCallNames(gpa, fr, out);
}

/// The inline candidates within `inline_depth` calls of a unit, in breadth-first discovery
/// order: exactly the units whose IR can reach its code, so its key folds each one's
/// content and `--verify` accepts the calls their bodies make.
pub const Reach = struct {
    gpa: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    /// Parallel to `names`; borrowed from the build's `InlineCache`.
    facts: std.ArrayList(Facts) = .empty,

    pub fn init(gpa: std.mem.Allocator, fr: *const Frozen) !Reach {
        var r: Reach = .{ .gpa = gpa };
        errdefer r.deinit();
        const units = fr.units orelse return r;
        if (!fr.profile.opt.@"inline") return r;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        try seen.put(gpa, fr.sym.name, {});
        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(gpa);
        try appendInlineNames(gpa, fr, &frontier);
        var level: usize = 0;
        while (level < inline_depth) : (level += 1) {
            var next: std.ArrayList([]const u8) = .empty;
            defer next.deinit(gpa);
            for (frontier.items) |name| {
                const gop = try seen.getOrPut(gpa, name);
                if (gop.found_existing) continue;
                const f = try units.cache.factsOf(gpa, units, name) orelse continue;
                try r.names.append(gpa, name);
                try r.facts.append(gpa, f);
                try next.appendSlice(gpa, f.calls);
            }
            std.mem.swap(std.ArrayList([]const u8), &frontier, &next);
        }
        return r;
    }

    pub fn deinit(r: *Reach) void {
        r.names.deinit(r.gpa);
        r.facts.deinit(r.gpa);
    }
};

/// What the key fold and the inliner read of one candidate unit, computed once per build.
const Facts = struct {
    /// Its own content: `sourceFp`, or a derive unit's `deriveFp`.
    fp: u64,
    /// The callees its key folds by name (`appendCallNames`). Owned by the cache.
    calls: []const []const u8,
};

/// The callee IR a build's inliner prepared, by `(symbol, passes, depth)`, shared by every
/// unit's lowering so each candidate is lowered once per depth. Depth `inline_depth` is a
/// body as its own unit lowers it, which `Opt.inliner.splice` takes. The passes join the
/// key because one build prepares bodies with two: a unit's own, and a `core/rt` unit's,
/// which a spliced body and its callees take. A prepared body is a pure function of the
/// callee's `Frozen` view and the passes, so when two jobs race to prepare one, either
/// result is the same; the first stored stands and the other is freed.
pub const InlineCache = struct {
    memo: std.HashMapUnmanaged(MemoKey, [inline_depth + 1]Entry, MemoContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Each unit the inliner looked at: its `Facts`, or null when it is no candidate.
    facts: std.StringHashMapUnmanaged(?Facts) = .empty,
    /// Each lambda owner's `sourceFp`, which every lambda key of that owner starts from:
    /// walking the owner once per lambda made an owner of L lambdas cost O(L x owner).
    owner_fps: std.AutoHashMapUnmanaged(Closure.Owner, u64) = .empty,
    spin: Cache.SpinLock = .{},

    const Entry = union(enum) { unknown, none, ir: *Ir.Function };

    /// The name is borrowed from the unit's symbol, which outlives the cache.
    const MemoKey = struct { name: []const u8, cfg: Opt.Config };

    const MemoContext = struct {
        pub fn hash(_: MemoContext, k: MemoKey) u64 {
            return std.hash.Wyhash.hash(@as(u8, @bitCast(k.cfg)), k.name);
        }

        pub fn eql(_: MemoContext, a: MemoKey, b: MemoKey) bool {
            return @as(u8, @bitCast(a.cfg)) == @as(u8, @bitCast(b.cfg)) and std.mem.eql(u8, a.name, b.name);
        }
    };

    pub fn deinit(c: *InlineCache, gpa: std.mem.Allocator) void {
        var it = c.memo.valueIterator();
        while (it.next()) |v| for (v) |e| switch (e) {
            .ir => |p| destroyIr(gpa, p),
            .unknown, .none => {},
        };
        c.memo.deinit(gpa);
        var fit = c.facts.valueIterator();
        while (fit.next()) |f| if (f.*) |x| gpa.free(x.calls);
        c.facts.deinit(gpa);
        c.owner_fps.deinit(gpa);
    }

    /// The `sourceFp` of lambda `l`'s owner. Every lambda of one owner shares the view
    /// that fp reads (the owner's tables, a null own sig), so whichever computes it first
    /// stores the value all of them would.
    pub fn ownerFp(c: *InlineCache, gpa: std.mem.Allocator, fr: *const Frozen, l: Engine.Body.Lambda) !u64 {
        const owner = fr.in.closure.lambda_units[l.unit].owner;
        {
            c.lock();
            defer c.unlock();
            if (c.owner_fps.get(owner)) |fp| return fp;
        }
        const fp = try Engine.sourceFp(gpa, fr, l.owner, l.owner_sig);
        c.lock();
        defer c.unlock();
        try c.owner_fps.put(gpa, owner, fp);
        return fp;
    }

    /// `name`'s `Facts`, or null when it names no inline candidate.
    fn factsOf(c: *InlineCache, gpa: std.mem.Allocator, units: Units, name: []const u8) !?Facts {
        {
            c.lock();
            defer c.unlock();
            if (c.facts.get(name)) |f| return f;
        }
        var mine: ?Facts = null;
        if (units.find(name)) |g| if (inlineCandidate(&g)) {
            var calls: std.ArrayList([]const u8) = .empty;
            defer calls.deinit(gpa);
            try appendCallNames(gpa, &g, &calls);
            const fp = switch (g.body) {
                .source => |s| try Engine.sourceFp(gpa, &g, s.decl, g.in.sig),
                .derive => |d| try Engine.deriveFp(gpa, &g, d),
                else => unreachable,
            };
            mine = .{ .fp = fp, .calls = try calls.toOwnedSlice(gpa) };
        };
        c.lock();
        defer c.unlock();
        const gop = c.facts.getOrPut(gpa, name) catch |err| {
            if (mine) |m| gpa.free(m.calls);
            return err;
        };
        if (gop.found_existing) {
            if (mine) |m| gpa.free(m.calls);
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = mine;
        return mine;
    }

    fn lock(c: *InlineCache) void {
        c.spin.lock();
    }

    fn unlock(c: *InlineCache) void {
        c.spin.unlock();
    }

    fn get(c: *InlineCache, name: []const u8, cfg: Opt.Config, depth: usize) Entry {
        c.lock();
        defer c.unlock();
        const m = c.memo.get(.{ .name = name, .cfg = cfg }) orelse return .unknown;
        return m[depth];
    }

    /// Store `f` as `(name, cfg, depth)`'s IR unless a racing job stored first; returns
    /// what stands. Takes ownership of `f`.
    fn put(c: *InlineCache, gpa: std.mem.Allocator, name: []const u8, cfg: Opt.Config, depth: usize, f: ?*Ir.Function) error{OutOfMemory}!?*Ir.Function {
        c.lock();
        defer c.unlock();
        const m = c.memo.getOrPut(gpa, .{ .name = name, .cfg = cfg }) catch |err| {
            if (f) |p| destroyIr(gpa, p);
            return err;
        };
        if (!m.found_existing) m.value_ptr.* = @splat(.unknown);
        switch (m.value_ptr[depth]) {
            .unknown => {},
            .none => {
                if (f) |p| destroyIr(gpa, p);
                return null;
            },
            .ir => |p| {
                if (f) |q| destroyIr(gpa, q);
                return p;
            },
        }
        m.value_ptr[depth] = if (f) |p| .{ .ir = p } else .none;
        return f;
    }
};

pub fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn destroyIr(gpa: std.mem.Allocator, p: *Ir.Function) void {
    p.deinit(gpa);
    gpa.destroy(p);
}

/// Prepares callee IR into the build's `InlineCache`: each candidate lowered and
/// optimized with its own callees inlined one level less deep. It lowers a callee from
/// that callee's own `Frozen` view, the same pure function its own job runs, so the
/// bytes inlined match what the callee's key describes.
const Inliner = struct {
    gpa: std.mem.Allocator,
    units: Units,
    cfg: Opt.Config,
    /// The program's layouts, which size the slots a recursive caller's budget counts.
    /// A callee's key folds the layouts it touches, so a caller's key covers each size.
    layouts: []const Typecheck.Layout = &.{},
    enum_layouts: []const Typecheck.EnumLayout = &.{},

    /// `name`'s optimized IR with its callees inlined `depth` levels deep, or null when it
    /// is no candidate. Lives as long as the cache.
    fn prepared(self: Inliner, name: []const u8, depth: usize) error{OutOfMemory}!?*const Ir.Function {
        switch (self.units.cache.get(name, self.cfg, depth)) {
            .ir => |p| return p,
            .none => return null,
            .unknown => {},
        }
        return self.units.cache.put(self.gpa, name, self.cfg, depth, try self.build(name, depth));
    }

    fn build(self: Inliner, name: []const u8, depth: usize) error{OutOfMemory}!?*Ir.Function {
        // Leaf first: a callee whose own body, before its callees are inlined, is already
        // over budget or loops is not lowered again deeper.
        // Depth `inline_depth` is a spliced body, which no budget limits.
        if (depth > 0 and depth < inline_depth) {
            const leaf = try self.prepared(name, 0) orelse return null;
            if (!Opt.inliner.fits(leaf, Opt.inliner.budget)) return null;
        }
        const facts = try self.units.cache.factsOf(self.gpa, self.units, name) orelse return null;
        const fr = self.units.find(name).?;
        var diags: std.ArrayList(Diagnostic) = .empty;
        defer diags.deinit(self.gpa);
        var irf = switch (fr.body) {
            .source => |s| try lower.lowerFn(self.gpa, fr.in, s.decl, fr.sym, false, &diags),
            .derive => |d| try DeriveEmit.lower(self.gpa, fr.in, d.*, fr.sym, &diags),
            else => unreachable,
        };
        errdefer irf.deinit(self.gpa);
        if (diags.items.len != 0) {
            irf.deinit(self.gpa);
            return null;
        }
        var scope: Scope = .{ .inliner = self, .depth = depth, .allowed = facts.calls };
        var stats: Opt.Stats = .{};
        try Opt.optimize(self.gpa, &irf, self.cfg, if (depth > 0) scope.lookup() else null, &stats);
        const p = try self.gpa.create(Ir.Function);
        p.* = irf;
        return p;
    }
};

/// One lowering's view of the inliner: which callees it may splice and how deep their
/// own inlining goes.
const Scope = struct {
    inliner: Inliner,
    depth: usize,
    /// The callees this lowering may splice, by name. Borrowed.
    allowed: []const []const u8 = &.{},
    /// The passes a `core/rt` unit builds with, which a spliced body is prepared with
    /// whatever this unit's are: one body for every caller, as its own unit lowers it.
    runtime_cfg: ?Opt.Config = null,

    fn lookup(s: *Scope) Opt.inliner.Lookup {
        return .{ .ctx = s, .findFn = find, .splicedFn = if (s.runtime_cfg != null) findSpliced else null, .bytesFn = bytes };
    }

    fn bytes(ctx: *anyopaque, t: Ir.Type) u32 {
        const s: *Scope = @ptrCast(@alignCast(ctx));
        return Abi.typeSize(t, s.inliner.layouts, s.inliner.enum_layouts);
    }

    fn findSpliced(ctx: *anyopaque, name: []const u8) error{OutOfMemory}!?*const Ir.Function {
        const s: *Scope = @ptrCast(@alignCast(ctx));
        if (!spliced(name)) return null;
        var rt = s.inliner;
        rt.cfg = s.runtime_cfg.?;
        return rt.prepared(name, inline_depth);
    }

    fn find(ctx: *anyopaque, name: []const u8) error{OutOfMemory}!?*const Ir.Function {
        const s: *Scope = @ptrCast(@alignCast(ctx));
        if (s.depth == 0) return null;
        // Never over the budget, and taken whole by `findSpliced` once the unit is done.
        if (spliced(name)) return null;
        if (!containsName(s.allowed, name)) return null;
        return s.inliner.prepared(name, s.depth - 1);
    }
};

/// The inliner as one unit's lowering sees it: none when the profile leaves `inline` out
/// or the build has no `Units`. A unit inlines only what its key folds (`Reach`).
pub const CallerScope = struct {
    gpa: std.mem.Allocator,
    scope: ?Scope = null,
    allowed: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, fr: *const Frozen) !CallerScope {
        var cs: CallerScope = .{ .gpa = gpa };
        const cfg = fr.profile.opt;
        if (!cfg.@"inline") return cs;
        const u = fr.units orelse return cs;
        try appendInlineNames(gpa, fr, &cs.allowed);
        cs.scope = .{ .inliner = .{ .gpa = gpa, .units = u, .cfg = cfg, .layouts = fr.in.layouts, .enum_layouts = fr.in.enum_layouts }, .depth = inline_depth, .runtime_cfg = fr.profile.forRuntime().opt };
        return cs;
    }

    pub fn deinit(cs: *CallerScope) void {
        cs.allowed.deinit(cs.gpa);
    }

    /// Valid while `cs` stays where it is.
    pub fn lookup(cs: *CallerScope) ?Opt.inliner.Lookup {
        const sc = if (cs.scope) |*s| s else return null;
        sc.allowed = cs.allowed.items;
        return sc.lookup();
    }
};

test "a prepared body is kept apart for each set of passes" {
    const gpa = std.testing.allocator;
    var cache: InlineCache = .{};
    defer cache.deinit(gpa);
    const p = try gpa.create(Ir.Function);
    p.* = .{
        .name = .{ .kind = .user_fn, .name = "f" },
        .params = &.{},
        .ret_type = Ir.Type.int,
        .slots = &.{},
        .values = &.{},
        .blocks = &.{},
        .entry = 0,
        .exit = 0,
    };
    try std.testing.expectEqual(p, (try cache.put(gpa, "f", Opt.Config.O1, 1, p)).?);
    try std.testing.expect(cache.get("f", Opt.Config.O1, 1) == .ir);
    var other = Opt.Config.O1;
    other.mem2reg = false;
    try std.testing.expect(cache.get("f", other, 1) == .unknown);
}
