//! Which bodies can reach a GC allocation, and by what call path. A peer data module like
//! `Escape`: types runs it once every body is checked, to hold every `core/rt` fn to the
//! no-allocation rule (T0082).
//!
//! It reads the checker's call selections over `Body.List`, the call graph the escape pass
//! and the spec table walk. Anything whose target it cannot see is taken to allocate: a call
//! through a fn value, a protocol method, a derived witness over an aggregate field, a
//! sugar that runs library methods. So an answer of "no allocation" is a proof, and a
//! `core/rt` body that needs one of those constructs gets a precise target first.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Walk = @import("../ast/Walk.zig");
const Callee = @import("Callee.zig").Callee;
const Body = @import("Body.zig");
const Derive = @import("Derive.zig");
const Escape = @import("Escape.zig");
const Typecheck = @import("../types.zig");
const LayoutEngine = @import("../layout/Engine.zig");
const Mono = @import("Mono.zig");
const Intrinsic = @import("Intrinsic.zig");
const StdNames = @import("StdNames.zig");
const Resolution = @import("Resolution.zig").Resolution;
const leftmostHeadIsValue = @import("Resolution.zig").leftmostHeadIsValue;

/// What allocates at a step, when the step is not a call into another body.
pub const Reason = union(enum) {
    /// A builtin fn that allocates or collects (`gc_alloc`, `ref_new`, `gc_collect`), or one
    /// this pass does not know: its global id.
    builtin_fn: u32,
    /// A compiler-provided method that builds a heap value (`to_string`, str `concat`).
    builtin_method: Callee.Builtin,
    /// A derived witness, by its index in the method table: it has no source to walk.
    derive: u32,
    value_call,
    protocol_call,
    generic_call,
    /// A call whose target the checker left unknown.
    unknown_call,
    bound_method,
    closure,
    list_literal,
    for_in,
    operator,
    try_operator,
    boxed_local,
};

/// One thing a body does that matters here: a call into another body, or an allocation.
pub const Step = struct {
    node: Ast.Index,
    to: union(enum) { body: Body.Index, alloc: Reason },
};

/// A module's tables, by module id.
pub const Module = struct { src: Walk.Source, resolutions: []const Resolution };

pub const Program = struct {
    modules: []const Module,
    /// Its `layouts` tell a `Ref` or fn value, which compare by identity, from a struct.
    prog: Body.ProgramView,
    bodies: Body.List,
    derives: []const Derive.Derive,
    prelude_ids: Typecheck.PreludeProtocolIds,
    elem_prims: ElemPrims,
};

/// The global fn id of each `core/mem` element primitive, or null when the program has none.
pub const ElemPrims = std.enums.EnumArray(StdNames.ElemPrim, ?u32);

pub fn elemPrims(sigs: []const @import("Sig.zig").Sig) ElemPrims {
    var out: ElemPrims = .initFill(null);
    for (sigs, 0..) |s, g| {
        if (s.kind != .user_fn) continue;
        for (std.enums.values(StdNames.ElemPrim)) |prim| {
            if (std.mem.eql(u8, s.name, prim.name())) out.set(prim, @intCast(g));
        }
    }
    return out;
}

/// The steps of body `bi`, in walk order. Caller owns the result.
pub fn stepsOf(gpa: std.mem.Allocator, p: Program, bi: Body.Index) error{OutOfMemory}![]Step {
    const b = p.bodies.items[bi];
    const m = p.modules[b.mod];
    var v: Visitor = .{ .gpa = gpa, .p = p, .src = m.src, .body = b.view(m.src.tree, m.resolutions) };
    errdefer v.steps.deinit(gpa);
    if (b.boxed.len != 0) try v.alloc(b.decl, .boxed_local);
    try Walk.walk(m.src, b.decl, &v);
    return v.steps.toOwnedSlice(gpa);
}

const Visitor = struct {
    gpa: std.mem.Allocator,
    p: Program,
    src: Walk.Source,
    body: Body.BodyView,
    steps: std.ArrayList(Step) = .empty,

    fn alloc(v: *Visitor, node: Ast.Index, r: Reason) error{OutOfMemory}!void {
        try v.steps.append(v.gpa, .{ .node = node, .to = .{ .alloc = r } });
    }

    fn call(v: *Visitor, node: Ast.Index, to: Body.Index) error{OutOfMemory}!void {
        try v.steps.append(v.gpa, .{ .node = node, .to = .{ .body = to } });
    }

    pub fn on(v: *Visitor, ev: Walk.Event) error{OutOfMemory}!void {
        switch (ev) {
            .enter => |e| try v.enter(e.idx, e.tag),
            .operator => |o| try v.operator(o.idx),
            .try_operator => |t| try v.alloc(t.idx, .try_operator),
            else => {},
        }
    }

    fn enter(v: *Visitor, idx: Ast.Index, tag: Ast.Node.Tag) error{OutOfMemory}!void {
        const tree = v.body.tree;
        switch (tag) {
            .lambda, .local_fn => return v.alloc(idx, .closure),
            .list_literal, .empty_list => return v.alloc(idx, .list_literal),
            .for_in_stmt, .for_in2_stmt => return v.alloc(idx, .for_in),
            .index => return v.element(idx),
            .type_app => if (leftmostHeadIsValue(tree, v.body.resolutions, tree.nodes[idx.int()].lhs)) return v.element(idx),
            .call => {
                const slot = Callee.callSlot(tree, tree.nodes[idx.int()]) orelse return v.alloc(idx, .unknown_call);
                if (v.body.nodes.callee(slot).view() == .none) return v.typeCall(idx);
            },
            else => {},
        }
        if (!v.body.nodes.has(idx)) return;
        switch (v.body.nodes.callee(idx).view()) {
            .none => {},
            .direct => |gid| try v.named(idx, gid),
            .instance => |ii| try v.call(idx, v.p.bodies.ofInstance(ii)),
            .method => |mi| try v.method(idx, mi),
            .builtin => |k| if (builtinAllocates(k)) try v.alloc(idx, .{ .builtin_method = k }),
            .value => try v.alloc(idx, .value_call),
            .protocol => try v.alloc(idx, .protocol_call),
            .generic => try v.alloc(idx, .generic_call),
            // A named fn as a value may be called through it, or by C as a callback.
            .fn_ref => |gid| try v.named(idx, gid),
            .bound_method => |mi| if (mi < v.p.prog.methods.len and v.p.prog.methods[mi].is_static)
                try v.method(idx, mi)
            else
                try v.alloc(idx, .bound_method),
        }
    }

    /// A call of fn `gid`, or a reference to it.
    fn named(v: *Visitor, idx: Ast.Index, gid: u32) error{OutOfMemory}!void {
        if (v.p.bodies.ofFn(gid)) |to| return v.call(idx, to);
        if (gid >= v.p.prog.sigs.len) return v.alloc(idx, .unknown_call);
        const sig = v.p.prog.sigs[gid];
        switch (sig.kind) {
            // C allocates nothing on the toy heap, and any toy fn it calls back is passed as
            // a reference this walk follows.
            .import => {},
            .builtin => if (builtinFnAllocates(sig.name)) try v.alloc(idx, .{ .builtin_fn = gid }),
            .user_fn => try v.alloc(idx, .unknown_call),
        }
    }

    fn method(v: *Visitor, idx: Ast.Index, mi: u32) error{OutOfMemory}!void {
        if (mi >= v.p.prog.methods.len) return v.alloc(idx, .unknown_call);
        if (v.p.prog.methods[mi].derive) |di| {
            if (!heapFreeDerive(v.p.derives, di)) try v.alloc(idx, .{ .derive = mi });
            return;
        }
        const to = Escape.methodUnit(v.p.prog, v.p.bodies, mi) orelse return v.alloc(idx, .unknown_call);
        try v.call(idx, to);
    }

    /// A call with no selection: a type intrinsic (`size_of[T]()`) or a constructor, which
    /// lower builds in place.
    fn typeCall(v: *Visitor, idx: Ast.Index) error{OutOfMemory}!void {
        const tree = v.body.tree;
        var head = tree.nodes[idx.int()].lhs;
        if (tree.nodes[head.int()].tag == .type_app) head = tree.nodes[head.int()].lhs;
        if (head.int() >= v.body.resolutions.len) return;
        switch (v.body.resolutions[head.int()]) {
            .func => |gid| try v.named(idx, gid),
            else => {},
        }
    }

    /// A Vec element read or write, which lower turns into calls of the `core/mem` element
    /// primitives the checker's mark names.
    fn element(v: *Visitor, idx: Ast.Index) error{OutOfMemory}!void {
        const elem = v.body.nodes.typeOf(idx);
        for (StdNames.ElemPrim.of(v.body.nodes.callee(idx))) |prim| {
            const gid = v.p.elem_prims.get(prim) orelse return v.alloc(idx, .unknown_call);
            const ii = Mono.find(v.p.prog.instances, gid, &.{elem}) orelse return v.alloc(idx, .unknown_call);
            try v.call(idx, v.p.bodies.ofInstance(@intCast(ii)));
        }
    }

    /// A desugaring operator, dispatched as lower does: a scalar, `float` or `()` operand
    /// is an inline machine op, a `Ref` or fn value compares by identity, and a struct or
    /// enum calls the witness the operator's protocol selects. A `str` compare is an inline
    /// byte loop or a call of `core/rt` `str_eq`, which this rule holds itself.
    fn operator(v: *Visitor, idx: Ast.Index) error{OutOfMemory}!void {
        const n = v.body.tree.nodes[idx.int()];
        const ty = v.body.nodes.typeOf(n.lhs);
        switch (ty.kind) {
            .@"struct", .@"enum" => {},
            .int, .bool, .float, .str, .unit, .rawptr, .cstr, .never => return,
            .invalid, .type_var, .app, .func => return v.alloc(idx, .operator),
        }
        const layouts = v.p.prog.layouts;
        if (LayoutEngine.isRefStruct(ty, layouts) or LayoutEngine.isFnStruct(ty, layouts)) return;
        const op = Walk.operatorOf(v.src.tokens[n.main_token].tag);
        for (Walk.opMethods(op)) |name| {
            const pid = Typecheck.witnessProtocolId(v.p.prelude_ids, name);
            switch (Typecheck.pickMethodIndex(v.p.prog.methods, ty, name, pid, null, .program)) {
                .one => |mi| return v.method(idx, mi),
                .none, .ambiguous => {},
            }
        }
        try v.alloc(idx, .operator);
    }
};

/// A derived Eq, Ord or Hash over a struct whose fields all compare inline: it calls no
/// witness, and its one call, `core/rt` `str_eq` on a `str` field, this rule holds itself.
fn heapFreeDerive(derives: []const Derive.Derive, di: u32) bool {
    if (di >= derives.len) return false;
    const d = derives[di];
    switch (d.kind) {
        .eq, .ord, .hash => {},
        else => return false,
    }
    if (!d.conform_ty.isStruct()) return false;
    for (d.field_witnesses) |w| if (w != .inline_kind) return false;
    return true;
}

fn builtinAllocates(k: Callee.Builtin) bool {
    return switch (k) {
        .str_concat, .scalar_to_string, .display_to_string => true,
        .scalar_eq, .scalar_hash, .str_len, .str_byte_at, .conv_into, .conv_try_into, .opt_is_tag0, .opt_is_tag1, .opt_expect, .opt_or, .scalar_cmp => false,
    };
}

fn builtinFnAllocates(name: []const u8) bool {
    const k = Intrinsic.lookup(name) orelse return !std.mem.eql(u8, name, "panic");
    return Intrinsic.allocates(k);
}

/// One step of a path: the body it is in, and the step.
pub const Link = struct { body: Body.Index, step: Step };

/// The shortest call path from body `root` to an allocation, or null when it reaches none.
/// Caller owns the result; `memo` caches each body's steps across calls and owns them.
pub fn pathFrom(gpa: std.mem.Allocator, p: Program, memo: *Memo, root: Body.Index) error{OutOfMemory}!?[]Link {
    // Per body reached: the step in its caller that reached it.
    var via: std.AutoHashMapUnmanaged(Body.Index, ?Link) = .empty;
    defer via.deinit(gpa);
    var queue: std.ArrayList(Body.Index) = .empty;
    defer queue.deinit(gpa);
    try via.put(gpa, root, null);
    try queue.append(gpa, root);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const bi = queue.items[head];
        const steps = try memo.get(gpa, p, bi);
        const hit = for (steps) |s| {
            if (s.to == .alloc) break s;
        } else null;
        if (hit) |s| {
            var path: std.ArrayList(Link) = .empty;
            errdefer path.deinit(gpa);
            try path.append(gpa, .{ .body = bi, .step = s });
            var cur = via.get(bi).?;
            while (cur) |l| : (cur = via.get(l.body).?) try path.append(gpa, l);
            std.mem.reverse(Link, path.items);
            return try path.toOwnedSlice(gpa);
        }
        for (steps) |s| switch (s.to) {
            .body => |to| {
                const gop = try via.getOrPut(gpa, to);
                if (gop.found_existing) continue;
                gop.value_ptr.* = .{ .body = bi, .step = s };
                try queue.append(gpa, to);
            },
            .alloc => unreachable,
        };
    }
    return null;
}

/// Each body's steps, computed once.
pub const Memo = struct {
    map: std.AutoHashMapUnmanaged(Body.Index, []Step) = .empty,

    fn get(m: *Memo, gpa: std.mem.Allocator, p: Program, bi: Body.Index) error{OutOfMemory}![]const Step {
        const gop = try m.map.getOrPut(gpa, bi);
        if (!gop.found_existing) {
            gop.value_ptr.* = stepsOf(gpa, p, bi) catch |e| {
                m.map.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        return gop.value_ptr.*;
    }

    pub fn deinit(m: *Memo, gpa: std.mem.Allocator) void {
        var it = m.map.valueIterator();
        while (it.next()) |s| gpa.free(s.*);
        m.map.deinit(gpa);
    }
};

/// What an allocating step does, as the end of a path in a diagnostic.
pub fn describe(w: *std.Io.Writer, p: Program, r: Reason) std.Io.Writer.Error!void {
    switch (r) {
        .builtin_fn => |gid| try w.print("{s}", .{p.prog.sigs[gid].name}),
        .builtin_method => |k| try w.writeAll(switch (k) {
            .str_concat => "str concat",
            else => "to_string",
        }),
        .derive => |mi| try w.print("the derived '{s}'", .{p.prog.methods[mi].name}),
        .value_call => try w.writeAll("a call through a fn value"),
        .protocol_call => try w.writeAll("a protocol method call"),
        .generic_call => try w.writeAll("a generic call"),
        .unknown_call => try w.writeAll("a call with no known target"),
        .bound_method => try w.writeAll("a method bound as a value"),
        .closure => try w.writeAll("a closure"),
        .list_literal => try w.writeAll("a list literal"),
        .for_in => try w.writeAll("a for-in loop"),
        .operator => try w.writeAll("an operator impl"),
        .try_operator => try w.writeAll("a '?' conversion"),
        .boxed_local => try w.writeAll("a boxed local"),
    }
}
