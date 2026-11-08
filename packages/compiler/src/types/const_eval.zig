//! Folding each constant's initializer to the value its uses lower to. A constant is a
//! scalar known while compiling: an int of any width, a float, a bool, a char, a str or
//! an enum's unit variant, built from literals, operators and other constants. Folding
//! runs before the body pass, which reads each constant's type from the result.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Type = @import("../layout/Type.zig").Type;
const Literal = @import("literal.zig");
const const_fold = @import("const_fold.zig");
const symbols_res = @import("../symbols/Resolution.zig");
const Typecheck = @import("../types.zig");
const DiagnosticSink = @import("../diagnostics/Sink.zig");
const ControlFlow = @import("../ControlFlow.zig");
const PatternChecker = @import("../PatternChecker.zig");

const Value = const_fold.Value;
const ConstSym = Typecheck.ConstSym;

/// A folded subexpression. `lit` marks an integer or float built from literals alone,
/// which, like a bare literal, takes the type a typed sibling or the declaration gives it.
const Folded = struct {
    ty: Type,
    v: Value,
    lit: bool = false,
};

const State = enum { unseen, folding, done };

/// Fold every constant, in id order. One that does not fold is poison (`Type.invalid`),
/// so its uses, in bodies and in other constants, report nothing more.
pub fn foldAll(t: *Typecheck) !void {
    const n = t.graph.consts.len;
    try t.consts.ensureTotalCapacity(t.gpa, n);
    t.consts.items.len = n;
    @memset(t.consts.items, poison);
    const state = try t.gpa.alloc(State, n);
    defer t.gpa.free(state);
    @memset(state, .unseen);
    var ev: Eval = .{ .t = t, .state = state };
    defer ev.stack.deinit(t.gpa);
    for (0..n) |cid| _ = try ev.constant(@intCast(cid));
    try ev.whenConds();
}

/// What folding a `when` condition, scrutinee or arm guard in a body gave. The body
/// pass types it itself, so the fold reports nothing and this keeps only what the type
/// check cannot tell: the value an arm is chosen by, or that it is no constant.
pub const WhenCond = union(enum) { bool: bool, int: i128, variant: u32, not_const, invalid };

/// The key of the `when` at `node` of module `mod` in `Typecheck.when_conds`.
pub fn whenKey(mod: u32, node: Ast.Index) u64 {
    return @as(u64, mod) << 32 | node.int();
}

pub const poison: ConstSym = .{ .ty = Type.invalid, .value = .{ .int = 0 } };

/// Free the str bytes a const table owns.
pub fn freeValues(gpa: std.mem.Allocator, consts: []const ConstSym) void {
    for (consts) |c| if (c.value == .str) gpa.free(c.value.str);
}

const Error = error{OutOfMemory};

const Eval = struct {
    t: *Typecheck,
    state: []State,
    /// The name of the constant being folded, for the T0083 message.
    name: []const u8 = "",
    /// The constants being folded, outermost first: a use of one of them is a cycle.
    stack: std.ArrayList(u32) = .empty,
    /// Report nothing, and note in `not_const` that a part had no value.
    quiet: bool = false,
    not_const: bool = false,
    /// Folding a `when` condition, scrutinee or guard (this names which), whose missing
    /// value is T0085 rather than T0083.
    in_when: ?[]const u8 = null,

    fn report(ev: *Eval, at: DiagnosticSink.Report, comptime fmt: []const u8, args: anytype) Error!void {
        if (ev.quiet) return;
        try ev.t.sink.report(at, fmt, args);
    }

    /// Fold the condition or scrutinee of every `when`, and each guard of a match-form
    /// one, quietly, for the body pass to read. A scrutinee is keyed by its `when`, a
    /// guard by itself.
    fn whenConds(ev: *Eval) Error!void {
        const t = ev.t;
        ev.quiet = true;
        defer ev.quiet = false;
        const prev = t.graph_mod;
        defer _ = t.gphSelect(prev);
        for (0..t.graph.mods.len) |m| {
            _ = t.gphSelect(@intCast(m));
            for (t.tree.nodes, 0..) |n, i| {
                const node = Ast.Index.from(@intCast(i));
                if (!Ast.isWhen(t.tree, t.tokens, node)) continue;
                const is_if = n.tag == .if_stmt;
                try ev.foldWhenPart(@intCast(m), node, n.lhs, if (is_if) Type.bool else null);
                if (is_if) continue;
                for (Ast.rangeSlice(t.tree, n.rhs.int())) |arm_idx| {
                    const guard = Ast.armHeaderAt(t.tree, t.tree.nodes[arm_idx.int()].rhs.int()).guard;
                    if (guard != Ast.none) try ev.foldWhenPart(@intCast(m), guard, guard, Type.bool);
                }
            }
        }
    }

    fn foldWhenPart(ev: *Eval, mod: u32, key: Ast.Index, expr: Ast.Index, expected: ?Type) Error!void {
        ev.not_const = false;
        const f = try ev.eval(expr, expected);
        const cond: WhenCond = if (f) |v| whenValue(ev.t.gpa, v.v) else if (ev.not_const) .not_const else .invalid;
        try ev.t.when_conds.put(ev.t.gpa, whenKey(mod, key), cond);
    }

    /// The value a `when` chooses an arm by; one no arm can test is `invalid`. Frees a str.
    fn whenValue(gpa: std.mem.Allocator, v: Value) WhenCond {
        return switch (v) {
            .bool => |b| .{ .bool = b },
            .int => |i| .{ .int = i },
            .variant => |vi| .{ .variant = vi },
            .str => |bytes| blk: {
                gpa.free(bytes);
                break :blk .invalid;
            },
            .float, .char => .invalid,
        };
    }

    fn constant(ev: *Eval, cid: u32) Error!ConstSym {
        switch (ev.state[cid]) {
            .done => return ev.t.consts.items[cid],
            // A cycle has no value; the use that closes it is reported where it is named.
            .folding => return poison,
            .unseen => {},
        }
        ev.state[cid] = .folding;
        try ev.stack.append(ev.t.gpa, cid);
        defer _ = ev.stack.pop();
        const t = ev.t;
        const c = t.graph.consts[cid];
        const prev_mod = t.gphSelect(c.module);
        const prev_name = ev.name;
        defer {
            _ = t.gphSelect(prev_mod);
            ev.name = prev_name;
        }
        const decl = t.tree.nodes[c.decl_node.int()];
        ev.name = t.tokens[decl.main_token].text(t.source);
        const declared: ?Type = if (decl.lhs != Ast.none) try ev.declaredType(c, decl.lhs) else null;
        const sym: ConstSym = blk: {
            if (declared) |d| if (d.kind == .invalid) break :blk poison;
            const f = (try ev.eval(decl.rhs, declared)) orelse break :blk poison;
            break :blk (try ev.bind(decl, f, declared)) orelse {
                if (f.v == .str) t.gpa.free(f.v.str);
                break :blk poison;
            };
        };
        t.consts.items[cid] = sym;
        ev.state[cid] = .done;
        return sym;
    }

    /// A constant's declared type, read with its fn's type parameters in scope so that
    /// naming one is rejected as such rather than as an unknown type: a value has no one
    /// type across the fn's instantiations.
    fn declaredType(ev: *Eval, c: Typecheck.GraphConstInput, type_node: Ast.Index) Error!Type {
        const t = ev.t;
        if (c.owner_fn == Ast.none) return t.typeFromNode(type_node);
        const proto = Ast.protoAt(t.tree, t.tree.nodes[c.owner_fn.int()].lhs.int());
        const names = try t.gpa.alloc([]const u8, proto.generic_params.len);
        defer t.gpa.free(names);
        for (proto.generic_params, names) |gp, *name| name.* = t.tokens[t.tree.nodes[gp.int()].main_token].text(t.source);
        const prev = t.cur_generic_params;
        t.cur_generic_params = names;
        defer t.cur_generic_params = prev;
        const ty = t.typeFromNode(type_node);
        if (ty.kind != .type_var) return ty;
        try ev.report(.{ .span = t.spanOf(type_node), .code = .T0083 }, "constant '{s}' cannot have a type parameter as its type", .{ev.name});
        return Type.invalid;
    }

    /// The constant's type and value once `f` meets its declared type, if any.
    fn bind(ev: *Eval, decl: Ast.Node, f: Folded, declared: ?Type) Error!?ConstSym {
        const t = ev.t;
        const at = t.spanOf(decl.rhs);
        const want = declared orelse switch (f.ty.kind) {
            // An unannotated literal is an `int` or a `float`, as for `x := 5`.
            .int => if (f.lit) Type.int else f.ty,
            .float => if (f.lit) Type.float else f.ty,
            else => f.ty,
        };
        if (f.lit and f.ty.kind == want.kind) return try ev.adopt(f, want, at);
        if (!f.ty.eql(want)) {
            try ev.report(.{ .span = at, .code = .T0041 }, "cannot bind {s} to '{s}' of type {s}", .{ t.typeName(f.ty), ev.name, t.typeName(want) });
            return null;
        }
        return .{ .ty = want, .value = f.v };
    }

    /// Literal `f` at type `want` of its kind: an integer must fit, a float32 rounds.
    fn adopt(ev: *Eval, f: Folded, want: Type, at: anytype) Error!?ConstSym {
        switch (f.v) {
            .int => |v| if (!Literal.fitsValue(v, want)) {
                try ev.report(.{ .span = at, .code = .T0034 }, "literal out of range for type '{s}'", .{ev.t.typeName(want)});
                return null;
            },
            .float => |v| if (want.isFloat32()) return .{ .ty = want, .value = .{ .float = round32(v) } },
            else => {},
        }
        return .{ .ty = want, .value = f.v };
    }

    fn notFolded(ev: *Eval, node: Ast.Index) Error!?Folded {
        ev.not_const = true;
        if (ev.in_when) |part|
            try ev.report(.{ .span = ev.t.spanOf(node), .code = .T0085 }, "when {s} is not known at compile time", .{part})
        else
            try ev.report(.{ .span = ev.t.spanOf(node), .code = .T0083 }, "the value of constant '{s}' is not known at compile time", .{ev.name});
        return null;
    }

    /// `when c { a } else { b }` in a constant's initializer: both arms fold and agree on
    /// a type, as a value `if`'s arms are checked, and the value is the taken arm's.
    fn when(ev: *Eval, n: Ast.Node, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const c = (try ev.whenPart("condition", n.lhs, Type.bool)) orelse return null;
        if (c.v != .bool) {
            if (c.v == .str) t.gpa.free(c.v.str);
            try ev.report(.{ .span = t.spanOf(n.lhs), .code = .T0045 }, "when condition must be bool", .{});
            return null;
        }
        const h = Ast.ifHeaderAt(t.tree, n.rhs.int());
        if (h.else_node == Ast.none) {
            try ev.report(.{ .span = t.tokSpan(n.main_token), .code = .T0059 }, "value-when requires else", .{});
            return null;
        }
        return ev.arms(&.{ h.then_block, h.else_node }, if (c.v.bool) 0 else 1, n.main_token, expected);
    }

    /// `when x { pat -> e, .. }` in a constant's initializer: every arm folds and the
    /// arms agree on a type, the patterns cover every value of `x`, and the value is the
    /// first arm's whose guard holds and whose pattern takes `x`'s.
    fn whenMatch(ev: *Eval, node: Ast.Index, n: Ast.Node, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const s = (try ev.whenPart("scrutinee", n.lhs, null)) orelse return null;
        const st = s.ty;
        const v = whenValue(t.gpa, s.v);
        if (v == .invalid) {
            try ev.report(.{ .span = t.spanOf(n.lhs), .code = .T0067 }, "when scrutinee must be an enum, int, or bool, got {s}", .{t.typeName(st)});
            return null;
        }
        const ctx: ControlFlow.Ctx = .{ .tree = t.tree, .resolutions = t.resolutions, .node_types = t.node_types, .enums = t.enums.items, .tokens = t.tokens, .source = t.source };
        const arm_nodes = Ast.rangeSlice(t.tree, n.rhs.int());
        const bodies = try t.gpa.alloc(Ast.Index, arm_nodes.len);
        defer t.gpa.free(bodies);
        var taken: ?usize = null;
        for (arm_nodes, bodies, 0..) |arm_idx, *body, i| {
            const an = t.tree.nodes[arm_idx.int()];
            const h = Ast.armHeaderAt(t.tree, an.rhs.int());
            body.* = h.body;
            if (!try ev.patternFits(an.lhs, st)) return null;
            var holds = true;
            if (h.guard != Ast.none) {
                const g = (try ev.whenPart("guard", h.guard, Type.bool)) orelse return null;
                if (g.v != .bool) {
                    if (g.v == .str) t.gpa.free(g.v.str);
                    try ev.report(.{ .span = t.spanOf(h.guard), .code = .T0045 }, "match guard must be bool, got {s}", .{t.typeName(g.ty)});
                    return null;
                }
                holds = g.v.bool;
            }
            if (taken == null and holds and PatternChecker.takes(ctx, an.lhs, st, v)) taken = i;
        }
        const span: @import("../diagnostics/model.zig").Span = .{ .start = t.tokSpan(n.main_token).start, .end = t.spanOf(n.lhs).end };
        if (ev.quiet) {
            if (taken == null) return ev.notFolded(node);
        } else if (!try PatternChecker.checkWhenCoverage(ctx, &t.sink, t.gpa, span, arm_nodes, st)) return null;
        return ev.arms(bodies, taken orelse return ev.notFolded(node), n.main_token, expected);
    }

    /// A `when`'s `part` (condition, scrutinee or guard), whose missing value is T0085.
    fn whenPart(ev: *Eval, part: []const u8, node: Ast.Index, expected: ?Type) Error!?Folded {
        const prev = ev.in_when;
        ev.in_when = part;
        defer ev.in_when = prev;
        return ev.eval(node, expected);
    }

    /// Whether a pattern of a `when` in an initializer can test a `ty`: a literal of its
    /// kind, a variant it has, or one that binds or ignores the value.
    fn patternFits(ev: *Eval, pat_idx: Ast.Index, ty: Type) Error!bool {
        const t = ev.t;
        const pat = t.tree.nodes[pat_idx.int()];
        const tok = t.tokens[pat.main_token];
        switch (pat.tag) {
            .pattern_wildcard, .pattern_binding => return true,
            .pattern_or => {
                for (Ast.rangeSlice(t.tree, pat.lhs.int())) |a| if (!try ev.patternFits(a, ty)) return false;
                return true;
            },
            .pattern_literal => {
                const want: @TypeOf(ty.kind) = if (tok.tag == .number) .int else .bool;
                if (ty.kind == want) return true;
            },
            .pattern_variant => if (ty.kind == .@"enum") {
                const name = tok.text(t.source);
                for (t.enums.items[ty.enum_id].variants) |vs| if (std.mem.eql(u8, vs.name, name)) return true;
                try ev.report(.{ .span = t.spanOf(pat_idx), .code = .T0061 }, "enum '{s}' has no variant '{s}'", .{ t.typeName(ty), name });
                return false;
            },
            else => {},
        }
        try ev.report(.{ .span = t.spanOf(pat_idx), .code = .T0067 }, "pattern does not match the when scrutinee's type {s}", .{t.typeName(ty)});
        return false;
    }

    /// Fold the arm `bodies` of a `when` on `kw`: they agree on a type as a value `if`'s
    /// or `match`'s arms do, a literal arm taking a typed arm's type or the declaration's
    /// and fitting it whether taken or not, and the value is arm `taken`'s.
    fn arms(ev: *Eval, bodies: []const Ast.Index, taken: usize, kw: u32, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const folded = try t.gpa.alloc(Folded, bodies.len);
        defer t.gpa.free(folded);
        var n_folded: usize = 0;
        defer for (folded[0..n_folded], 0..) |f, i| {
            if (i != taken and f.v == .str) t.gpa.free(f.v.str);
        };
        var ok = true;
        for (bodies) |body| {
            folded[n_folded] = (try ev.arm(body, expected)) orelse {
                ok = false;
                break;
            };
            n_folded += 1;
        }
        if (ok) ok = try ev.unifyArms(folded, bodies, taken, kw, expected);
        if (!ok) {
            if (taken < n_folded and folded[taken].v == .str) t.gpa.free(folded[taken].v.str);
            return null;
        }
        return folded[taken];
    }

    fn unifyArms(ev: *Eval, folded: []Folded, bodies: []const Ast.Index, taken: usize, kw: u32, expected: ?Type) Error!bool {
        const t = ev.t;
        var typed: ?Type = null;
        for (folded) |f| if (!f.lit) {
            typed = f.ty;
            break;
        };
        for (folded, bodies, 0..) |*f, body, i| {
            const want = typed orelse folded[0].ty;
            const numeric = f.ty.kind == .int or f.ty.kind == .float;
            if (f.lit and numeric and f.ty.kind == want.kind) {
                // An all-literal when is adopted by its declaration; the arms not taken
                // must fit that type too.
                const into = typed orelse if (i != taken) (expected orelse continue) else continue;
                if (into.kind != f.ty.kind) continue;
                const sym = (try ev.adopt(f.*, into, t.spanOf(body))) orelse return false;
                f.* = .{ .ty = sym.ty, .v = sym.value };
                continue;
            }
            if (!f.ty.eql(want)) {
                const a, const b = if (i == 0) .{ f.ty, want } else .{ folded[0].ty, f.ty };
                try ev.report(.{ .span = t.tokSpan(kw), .code = .T0058 }, "branches yield different types ({s} vs {s})", .{ t.typeName(a), t.typeName(b) });
                return false;
            }
        }
        return true;
    }

    /// An arm of a `when` in an initializer: a block holding one value, or the `when`
    /// an `else when` chains on.
    fn arm(ev: *Eval, node: Ast.Index, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const n = t.tree.nodes[node.int()];
        if (n.tag != .block) return ev.eval(node, expected);
        const stmts = Ast.rangeSlice(t.tree, n.lhs.int());
        if (stmts.len != 1) return ev.notFolded(node);
        const s = t.tree.nodes[stmts[0].int()];
        return switch (s.tag) {
            .expr_stmt => ev.eval(s.lhs, expected),
            .if_stmt, .block => ev.arm(stmts[0], expected),
            else => ev.notFolded(stmts[0]),
        };
    }

    fn opText(ev: *Eval, n: Ast.Node) []const u8 {
        return ev.t.tokens[n.main_token].text(ev.t.source);
    }

    fn charType(ev: *Eval) Type {
        if (ev.t.prelude) |p| if (p.char_struct) |cid| return Type.structT(cid);
        return Type.invalid;
    }

    fn eval(ev: *Eval, node: Ast.Index, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const n = t.tree.nodes[node.int()];
        const text = t.tokens[n.main_token].text(t.source);
        switch (n.tag) {
            .literal_number => {
                const v = Literal.intValue(text) orelse return ev.notFolded(node);
                return .{ .ty = Type.int, .v = .{ .int = v }, .lit = true };
            },
            .literal_float => {
                const v = Literal.floatValue(text) orelse return ev.notFolded(node);
                return .{ .ty = Type.float, .v = .{ .float = v }, .lit = true };
            },
            .literal_bool => return .{ .ty = Type.bool, .v = .{ .bool = t.tokens[n.main_token].tag == .kw_true } },
            .literal_char => switch (Literal.decodeChar(text)) {
                .ok => |cp| return .{ .ty = ev.charType(), .v = .{ .char = cp } },
                else => {
                    try ev.report(.{ .span = t.spanOf(node), .code = .T0036 }, "malformed char literal", .{});
                    return null;
                },
            },
            .literal_string => switch (try Literal.decodeString(t.gpa, text)) {
                .ok => |bytes| return .{ .ty = Type.str, .v = .{ .str = bytes } },
                else => {
                    try ev.report(.{ .span = t.spanOf(node), .code = .T0036 }, "malformed string literal", .{});
                    return null;
                },
            },
            .identifier => switch (t.resolutions[node.int()]) {
                .constant => |cid| return ev.use(node, cid),
                else => return ev.notFolded(node),
            },
            // `mod.N`: the resolver bound an imported constant to the access itself.
            .field_access => switch (t.resolutions[node.int()]) {
                .constant => |cid| return ev.use(node, cid),
                else => return ev.variant(node, n, null),
            },
            .enum_init_unit => {
                if (n.lhs != Ast.none) return ev.notFolded(node);
                const e = expected orelse return ev.notFolded(node);
                if (e.kind != .@"enum") return ev.notFolded(node);
                return ev.variant(node, n, e);
            },
            .unary => return ev.unary(node, n, expected),
            .binary => return ev.binary(node, n, expected),
            .if_stmt, .match_expr => {
                if (!Ast.isWhen(t.tree, t.tokens, node)) return ev.notFolded(node);
                return if (n.tag == .if_stmt) ev.when(n, expected) else ev.whenMatch(node, n, expected);
            },
            else => return ev.notFolded(node),
        }
    }

    /// The value of constant `cid`, named at `node`.
    fn use(ev: *Eval, node: Ast.Index, cid: u32) Error!?Folded {
        const t = ev.t;
        if (ev.state[cid] == .folding) {
            try ev.reportCycle(node, cid);
            return null;
        }
        const c = try ev.constant(cid);
        if (c.ty.kind == .invalid) return null;
        const v: Value = if (c.value == .str) .{ .str = try t.gpa.dupe(u8, c.value.str) } else c.value;
        return .{ .ty = c.ty, .v = v };
    }

    /// T0084 at the use of `cid` that closes a cycle, spelling the cycle from `cid` round
    /// to itself. Each constant on it is poison, so this is the cycle's one error.
    fn reportCycle(ev: *Eval, node: Ast.Index, cid: u32) Error!void {
        const t = ev.t;
        var path: std.Io.Writer.Allocating = .init(t.gpa);
        defer path.deinit();
        const from = std.mem.indexOfScalar(u32, ev.stack.items, cid).?;
        for (ev.stack.items[from..]) |c| {
            path.writer.print("{s} -> ", .{ev.constName(c)}) catch return error.OutOfMemory;
        }
        path.writer.writeAll(ev.constName(cid)) catch return error.OutOfMemory;
        try ev.report(.{ .span = t.spanOf(node), .code = .T0084 }, "constant '{s}' depends on itself: {s}", .{ ev.constName(cid), path.written() });
    }

    fn constName(ev: *Eval, cid: u32) []const u8 {
        const t = ev.t;
        const c = t.graph.consts[cid];
        const prev = t.gphSelect(c.module);
        defer _ = t.gphSelect(prev);
        return t.tokens[t.tree.nodes[c.decl_node.int()].main_token].text(t.source);
    }

    /// `E.V` (or `.V` at an expected enum `inferred`): a unit variant of a non-generic enum.
    fn variant(ev: *Eval, node: Ast.Index, n: Ast.Node, inferred: ?Type) Error!?Folded {
        const t = ev.t;
        const ty = inferred orelse blk: {
            if (!symbols_res.isQualifiedVariant(t.tree, t.resolutions, node)) return ev.notFolded(node);
            const head = t.typeFromNode(n.lhs);
            if (head.kind == .invalid) return null;
            if (head.kind != .@"enum") return ev.notFolded(node);
            break :blk head;
        };
        const name = t.tokens[n.main_token].text(t.source);
        for (t.enums.items[ty.enum_id].variants, 0..) |vs, i| {
            if (!std.mem.eql(u8, vs.name, name)) continue;
            // A payload variant is an aggregate built at run time, like a struct literal.
            if (vs.form != .unit) return ev.notFolded(node);
            return .{ .ty = ty, .v = .{ .variant = @intCast(i) } };
        }
        try ev.report(.{ .span = t.spanOf(node), .code = .T0061 }, "enum '{s}' has no variant '{s}'", .{ t.typeName(ty), name });
        return null;
    }

    fn unary(ev: *Eval, node: Ast.Index, n: Ast.Node, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const op = t.tokens[n.main_token].tag;
        const f = (try ev.eval(n.lhs, expected)) orelse return null;
        defer if (f.v == .str) t.gpa.free(f.v.str);
        switch (op) {
            .bang => {
                if (f.v != .bool) return ev.operandError(node, "operand of '!' must be bool");
                return .{ .ty = Type.bool, .v = .{ .bool = !f.v.bool } };
            },
            .minus, .tilde => {
                if (f.v != .int) return ev.operandError(node, if (op == .minus) "operand of '-' must be int" else "operand of '~' must be int");
                const at = ev.width(f, expected);
                const v = if (op == .tilde) Literal.complement(f.v.int, at) else -f.v.int;
                return ev.checked(node, .{ .ty = f.ty, .v = .{ .int = v }, .lit = f.lit }, at);
            },
            else => return ev.notFolded(node),
        }
    }

    fn operandError(ev: *Eval, node: Ast.Index, msg: []const u8) Error!?Folded {
        try ev.report(.{ .span = ev.t.spanOf(node), .code = .T0044 }, "{s}", .{msg});
        return null;
    }

    /// The integer type a literal-only `f` folds at: the expected integer type, else `int`.
    fn width(_: *Eval, f: Folded, expected: ?Type) Type {
        if (!f.lit) return f.ty;
        if (expected) |e| if (e.kind == .int) return e;
        return Type.int;
    }

    /// An integer result must fit the type `at` it was computed at: a typed one as a
    /// debug build would trap on it, and a literal-only one as the body checker
    /// range-checks each literal intermediate at its place's width.
    fn checked(ev: *Eval, node: Ast.Index, f: Folded, at: Type) Error!?Folded {
        if (f.v != .int or Literal.fitsValue(f.v.int, at)) return f;
        const span = ev.t.spanOf(node);
        if (f.lit)
            try ev.report(.{ .span = span, .code = .T0034 }, "literal out of range for type '{s}'", .{ev.t.typeName(at)})
        else
            try ev.report(.{ .span = span, .code = .T0034 }, "constant value {d} out of range for type '{s}'", .{ f.v.int, ev.t.typeName(at) });
        return null;
    }

    fn binary(ev: *Eval, node: Ast.Index, n: Ast.Node, expected: ?Type) Error!?Folded {
        const t = ev.t;
        const op = t.tokens[n.main_token].tag;
        const operand_expected: ?Type = switch (op) {
            .amp_amp, .pipe_pipe => Type.bool,
            .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq, .lt_dot, .gt_dot, .le_dot, .ge_dot => null,
            else => expected,
        };
        var l = (try ev.eval(n.lhs, operand_expected)) orelse return null;
        defer if (l.v == .str) t.gpa.free(l.v.str);
        // The left operand's type is the right one's expectation, so `C == .V` folds.
        var r = (try ev.eval(n.rhs, operand_expected orelse if (l.lit) null else l.ty)) orelse return null;
        defer if (r.v == .str) t.gpa.free(r.v.str);
        switch (op) {
            .amp_amp, .pipe_pipe => {
                if (l.v != .bool or r.v != .bool) return ev.operandError(node, if (op == .amp_amp) "operands of '&&' must be bool" else "operands of '||' must be bool");
                const v = if (op == .amp_amp) l.v.bool and r.v.bool else l.v.bool or r.v.bool;
                return .{ .ty = Type.bool, .v = .{ .bool = v } };
            },
            .plus_dot, .minus_dot, .star_dot, .slash_dot, .lt_dot, .gt_dot, .le_dot, .ge_dot => {
                if (l.v != .float or r.v != .float) return ev.binaryError(node, n, "operands of '{s}' must both be float");
                const ty = (try ev.unify(node, n, &l, &r, expected)) orelse return null;
                const lit = l.lit and r.lit;
                const fty = if (lit) ev.floatWidth(expected) else ty;
                // Each float32 literal is rounded before the operation, as at run time.
                const a = if (lit and fty.isFloat32()) round32(l.v.float) else l.v.float;
                const b = if (lit and fty.isFloat32()) round32(r.v.float) else r.v.float;
                const v: Value = switch (op) {
                    .plus_dot => .{ .float = a + b },
                    .minus_dot => .{ .float = a - b },
                    .star_dot => .{ .float = a * b },
                    .slash_dot => .{ .float = a / b },
                    .lt_dot => return boolean(a < b),
                    .gt_dot => return boolean(a > b),
                    .le_dot => return boolean(a <= b),
                    .ge_dot => return boolean(a >= b),
                    else => unreachable,
                };
                // float32 arithmetic rounds each result; one through f64 rounds the same.
                return .{ .ty = fty, .v = .{ .float = if (fty.isFloat32()) round32(v.float) else v.float }, .lit = lit };
            },
            .eq_eq, .bang_eq => {
                _ = (try ev.unify(node, n, &l, &r, null)) orelse return null;
                const same = valueEql(l.v, r.v);
                return boolean(if (op == .eq_eq) same else !same);
            },
            .lt, .lt_eq, .gt, .gt_eq => {
                _ = (try ev.unify(node, n, &l, &r, null)) orelse return null;
                // A user `Ord` impl or a float runs at run time; the prelude's scalars fold.
                const ord = order(l.v, r.v) orelse return ev.notFolded(node);
                return boolean(switch (op) {
                    .lt => ord == .lt,
                    .lt_eq => ord != .gt,
                    .gt => ord == .gt,
                    .gt_eq => ord != .lt,
                    else => unreachable,
                });
            },
            .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret, .plus_percent, .minus_percent, .star_percent, .lt_lt, .gt_gt => {
                if (std.meta.activeTag(l.v) != std.meta.activeTag(r.v)) return ev.binaryError(node, n, "operands of '{s}' must have the same type");
                if (l.v != .int) return ev.binaryError(node, n, "operands of '{s}' must be integers");
                const shift = op == .lt_lt or op == .gt_gt;
                // A shift's amount has a type of its own; the result takes the left one's.
                const ty = if (shift) l.ty else (try ev.unify(node, n, &l, &r, expected)) orelse return null;
                const lit = if (shift) l.lit else l.lit and r.lit;
                const at = if (lit) ev.width(l, expected) else ty;
                const v = const_fold.intBinary(op, l.v.int, r.v.int, at) orelse return ev.notFolded(node);
                return ev.checked(node, .{ .ty = ty, .v = .{ .int = v }, .lit = lit }, at);
            },
            else => return ev.notFolded(node),
        }
    }

    fn floatWidth(_: *Eval, expected: ?Type) Type {
        if (expected) |e| if (e.isFloat32()) return Type.float32;
        return Type.float;
    }

    fn binaryError(ev: *Eval, node: Ast.Index, n: Ast.Node, comptime fmt: []const u8) Error!?Folded {
        try ev.report(.{ .span = ev.t.spanOf(node), .code = .T0044 }, fmt, .{ev.opText(n)});
        return null;
    }

    /// The one type two operands share. A literal operand takes its typed sibling's type
    /// and must fit it; two typed operands must already agree.
    fn unify(ev: *Eval, node: Ast.Index, n: Ast.Node, l: *Folded, r: *Folded, expected: ?Type) Error!?Type {
        const t = ev.t;
        if (l.ty.kind == r.ty.kind and (l.lit or r.lit) and (l.ty.kind == .int or l.ty.kind == .float)) {
            if (l.lit and r.lit) return if (l.ty.kind == .int) ev.width(l.*, expected) else ev.floatWidth(expected);
            const typed = if (l.lit) r.ty else l.ty;
            const lit = if (l.lit) l else r;
            const lit_node = if (l.lit) n.lhs else n.rhs;
            const sym = (try ev.adopt(lit.*, typed, t.spanOf(lit_node))) orelse return null;
            lit.* = .{ .ty = sym.ty, .v = sym.value };
            return typed;
        }
        if (l.ty.eql(r.ty)) return l.ty;
        try ev.report(.{ .span = t.spanOf(node), .code = .T0044 }, "operands of '{s}' must have the same type", .{ev.opText(n)});
        return null;
    }
};

fn boolean(b: bool) ?Folded {
    return .{ .ty = Type.bool, .v = .{ .bool = b } };
}

fn round32(v: f64) f64 {
    return @as(f32, @floatCast(v));
}

/// The `Ord` order of two values of one type, for the types whose order folds.
fn order(a: Value, b: Value) ?std.math.Order {
    return switch (a) {
        .int => |x| std.math.order(x, b.int),
        .char => |x| std.math.order(x, b.char),
        .bool => |x| std.math.order(@intFromBool(x), @intFromBool(b.bool)),
        .str => |x| std.mem.order(u8, x, b.str),
        .float, .variant => null,
    };
}

fn valueEql(a: Value, b: Value) bool {
    return switch (a) {
        .int => |x| x == b.int,
        .float => |x| x == b.float,
        .bool => |x| x == b.bool,
        .char => |x| x == b.char,
        .str => |x| std.mem.eql(u8, x, b.str),
        .variant => |x| x == b.variant,
    };
}

const testing = std.testing;

/// The folded value of the last constant `src` declares, which must check clean.
fn lastValue(src: []const u8) !struct { ty: Type, value: Value, owned: Typecheck.Checked } {
    var r = try Typecheck.checkSource(src);
    errdefer r.deinit(testing.allocator);
    for (r.result.diags) |d| std.debug.print("{s}\n", .{d.message});
    try testing.expectEqual(@as(usize, 0), r.result.diags.len);
    const c = r.result.consts[r.result.consts.len - 1];
    return .{ .ty = c.ty, .value = c.value, .owned = r };
}

test "each scalar kind folds over literals, operators and other consts" {
    const Case = struct { src: []const u8, ty: Type, value: Value };
    const cases = [_]Case{
        .{ .src = "N :=: 2 * 3 - 10\n", .ty = Type.int, .value = .{ .int = -4 } },
        .{ .src = "N: uint8 =: 250 + 5\n", .ty = Type.uint8, .value = .{ .int = 255 } },
        .{ .src = "N: int8 =: 100 +% 100\n", .ty = Type.int8, .value = .{ .int = -56 } },
        .{ .src = "B: uint16 =: 1 << 4\nN :=: B * 2\n", .ty = Type.uint16, .value = .{ .int = 32 } },
        .{ .src = "N :=: ~0\n", .ty = Type.int, .value = .{ .int = -1 } },
        .{ .src = "N: uint8 =: ~0\n", .ty = Type.uint8, .value = .{ .int = 255 } },
        .{ .src = "N :=: 1.5 +. 1.0\n", .ty = Type.float, .value = .{ .float = 2.5 } },
        .{ .src = "N: float32 =: 0.1\n", .ty = Type.float32, .value = .{ .float = @as(f32, 0.1) } },
        .{ .src = "A :=: 3\nN :=: A > 2 && !false\n", .ty = Type.bool, .value = .{ .bool = true } },
        .{ .src = "N :=: \"a\" == \"b\"\n", .ty = Type.bool, .value = .{ .bool = false } },
        .{ .src = "N :=: \"a\" < \"b\" && 'b' > 'a' && false < true\n", .ty = Type.bool, .value = .{ .bool = true } },
        .{ .src = "N: float32 =: 16777217.0 +. 1.0\n", .ty = Type.float32, .value = .{ .float = 16777216.0 } },
        .{ .src = "enum E { A, B }\nN :=: E.B\n", .ty = Type.enumT(0), .value = .{ .variant = 1 } },
        .{ .src = "enum E { A, B(int) }\nN: E =: .A\n", .ty = Type.enumT(0), .value = .{ .variant = 0 } },
        .{ .src = "C :=: false\nN :=: when C { 1 } else when !C { 2 } else { 3 }\n", .ty = Type.int, .value = .{ .int = 2 } },
        .{ .src = "A: uint8 =: 7\nN :=: when A > 5 { A } else { 255 }\n", .ty = Type.uint8, .value = .{ .int = 7 } },
        .{ .src = "N: str =: when 1 < 2 { \"a\" } else { \"b\" }\n", .ty = Type.str, .value = .{ .str = "a" } },
        .{ .src = "enum E { A, B, C }\nX :=: E.B\nN :=: when X { .A -> 1, .B | .C -> 2 }\n", .ty = Type.int, .value = .{ .int = 2 } },
        .{ .src = "K :=: 3\nN: uint8 =: when K { 0 -> 1, _ if K > 2 -> 200, _ -> 3 }\n", .ty = Type.uint8, .value = .{ .int = 200 } },
        .{ .src = "N: str =: when 1 > 2 { true -> \"t\", false -> \"f\" }\n", .ty = Type.str, .value = .{ .str = "f" } },
    };
    for (cases) |c| {
        var got = try lastValue(c.src);
        defer got.owned.deinit(testing.allocator);
        if (c.ty.kind != .@"enum") try testing.expect(got.ty.eql(c.ty)) else try testing.expect(got.ty.kind == .@"enum");
        try testing.expect(valueEql(got.value, c.value));
    }
}

test "a computed value out of range is named as one, not as a literal" {
    var r = try Typecheck.checkSource("A: uint8 =: 200\nN :=: A + 56\nM: uint8 =: 255 + 1\n");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.result.diags.len);
    try testing.expectEqualStrings("constant value 256 out of range for type 'uint8'", r.result.diags[0].message);
    try testing.expectEqualStrings("literal out of range for type 'uint8'", r.result.diags[1].message);
}

test "a str const owns its decoded bytes and a char const its codepoint" {
    var s = try lastValue("A :=: \"hi\\n\"\nN: str =: A\n");
    defer s.owned.deinit(testing.allocator);
    try testing.expectEqualStrings("hi\n", s.value.str);
    var c = try lastValue("N :=: '\\u{20AC}'\n");
    defer c.owned.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0x20AC), c.value.char);
}

test "an initializer that does not fold, fit or bind is one coded error, and poison after it" {
    const C = @import("../diagnostics/codes.zig").Code;
    try Typecheck.expectDiagCodes("fn f() -> int { 1 }\nN :=: f()\nM :=: N + 1\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("struct P { x: int }\nN :=: P { x: 1 }\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N :=: 1 << 64\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N :=: N\n", &.{C.T0084});
    try Typecheck.expectDiagCodes("A :=: B + 1\nB :=: C\nC :=: A * 2\nD :=: A\n", &.{C.T0084});
    try Typecheck.expectDiagCodes("N: uint8 =: 256\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("A: uint8 =: 200\nN :=: A + 56\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N: uint8 =: 200 + 100 - 100\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N: int8 =: -128 - 1 + 1\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N: uint8 =: -1 + 2\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("enum E { A, B }\nN :=: E.A < E.B\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("fn f[T](x: T) -> T {\n    K: T =: 5\n    x\n}\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N: int =: 1.5\n", &.{C.T0041});
    try Typecheck.expectDiagCodes("A: int8 =: 1\nB: int16 =: 1\nN :=: A + B\n", &.{C.T0044});
    try Typecheck.expectDiagCodes("enum E { A }\nN :=: E.Z\n", &.{C.T0061});
    try Typecheck.expectDiagCodes("fn f() -> bool { true }\nN :=: when f() { 1 } else { 2 }\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("N :=: when 1 { 1 } else { 2 }\n", &.{C.T0045});
    try Typecheck.expectDiagCodes("fn f(n: int) -> int {\n    when n > 0 { 1 } else { 2 }\n}\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f(n: int) -> int {\n    when K > 1 { 1 } else { n + true }\n}\n", &.{C.T0044});
    try Typecheck.expectDiagCodes("N :=: when true { 1 }\n", &.{C.T0059});
    try Typecheck.expectDiagCodes("N :=: when true { 1 } else { \"x\" }\n", &.{C.T0058});
    try Typecheck.expectDiagCodes("N :=: when true { 1 } else { x := 2\n x }\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("A: uint8 =: 1\nN :=: when true { A } else { 256 }\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("enum E { A, B }\nN :=: when E.A { .A -> 1 }\n", &.{C.T0048});
    try Typecheck.expectDiagCodes("N :=: when 3 { 3 -> 1 }\n", &.{C.T0048});
    try Typecheck.expectDiagCodes("N :=: when 3 { true -> 1, _ -> 2 }\n", &.{C.T0067});
    try Typecheck.expectDiagCodes("N :=: when 1.5 { _ -> 1 }\n", &.{C.T0067});
    try Typecheck.expectDiagCodes("N :=: when 3 { 3 if 1 -> 1, _ -> 2 }\n", &.{C.T0045});
    try Typecheck.expectDiagCodes("N: uint8 =: when 3 { 3 -> 1, _ -> 256 }\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("fn f(n: int) -> int {\n    when n { _ -> 1 }\n}\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("enum E { A, B }\nX :=: E.A\nfn f() -> int {\n    when X { .A -> 1 }\n}\n", &.{C.T0048});
}
