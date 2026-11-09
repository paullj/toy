//! Computing the value of an expression the body checker has typed: a constant's
//! initializer, a `when` part, or an integer expression made only of literals and
//! constants. Every type comes from the checker's node types, so this file holds no
//! type rule of its own: it reads a node's type for the width to compute at, and says
//! when a value does not exist (`not_const`) or does not fit (`overflow`). The checker
//! reads `isConstInt` to give a literal-only expression its place's width.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const token = @import("../ast/Token.zig");
const Token = token.Token;
const Type = @import("../layout/Type.zig").Type;
const Literal = @import("literal.zig");
const Resolution = @import("../symbols/Resolution.zig").Resolution;
const symbols_res = @import("../symbols/Resolution.zig");
const ControlFlow = @import("../ControlFlow.zig");
const PatternChecker = @import("../PatternChecker.zig");
const ConstSym = @import("../types.zig").ConstSym;

pub const View = struct {
    tree: Ast.Tree,
    tokens: []const Token,
    source: []const u8,
};

/// Whether `node` is an integer constant built from literals alone, which, like a bare
/// literal, has no width of its own until a place or sibling gives it one.
pub fn isConstInt(v: View, node: Ast.Index) bool {
    if (node == Ast.none) return false;
    const n = v.tree.nodes[node.int()];
    return switch (n.tag) {
        .literal_number => true,
        .unary => switch (v.tokens[n.main_token].tag) {
            .minus, .tilde => isConstInt(v, n.lhs),
            else => false,
        },
        .binary => switch (v.tokens[n.main_token].tag) {
            .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret, .plus_percent, .minus_percent, .star_percent, .lt_lt, .gt_gt => isConstInt(v, n.lhs) and isConstInt(v, n.rhs),
            else => false,
        },
        else => false,
    };
}

/// `l op r` for integer operator `op` at integer type `t`, or null when it does not fold:
/// a zero divisor, an i128 overflow, a shift by a negative amount or by `t`'s width or
/// more, or an operator that is no integer operator.
pub fn intBinary(op: token.Tag, l: i128, r: i128, t: Type) ?i128 {
    return switch (op) {
        .plus => std.math.add(i128, l, r) catch null,
        .minus => std.math.sub(i128, l, r) catch null,
        .star => std.math.mul(i128, l, r) catch null,
        .slash => if (r == 0) null else @divTrunc(l, r),
        .percent => if (r == 0) null else @rem(l, r),
        .amp => l & r,
        .pipe => l | r,
        .caret => l ^ r,
        // Wrapping at 128 bits keeps the low bits `wrap` reads, so no operand can trap.
        .plus_percent => Literal.wrap(l +% r, t),
        .minus_percent => Literal.wrap(l -% r, t),
        .star_percent => Literal.wrap(l *% r, t),
        // A shift past the width is no value the program could compute: the machine
        // masks the amount, so it would not mean what it says.
        .lt_lt => if (r < 0 or r >= t.intBits()) null else std.math.shlExact(i128, l, @intCast(r)) catch null,
        .gt_gt => if (r < 0 or r >= t.intBits()) null else l >> @intCast(r),
        else => null,
    };
}

/// A constant's folded value. Its type is kept beside it (`ConstSym.ty`).
pub const Value = union(enum) {
    int: i128,
    float: f64,
    bool: bool,
    /// The codepoint a `char` holds.
    char: u32,
    /// The decoded bytes, owned by the const table.
    str: []const u8,
    /// The index of an enum's unit variant.
    variant: u32,
};

/// Free the bytes a str value owns.
pub fn freeValue(gpa: std.mem.Allocator, v: Value) void {
    if (v == .str) gpa.free(v.str);
}

/// A `when` arm binding in scope: local `slot` names its `when`'s scrutinee value `v`.
pub const Bind = struct { slot: u32, v: Value, next: ?*const Bind };

/// What folding a typed expression gave. `never` is a `compile_error` (an error already
/// reported where it is compiled, or nothing in an arm not taken); `poison` follows a
/// reported error. A str `value` is owned by the caller.
pub const Folded = union(enum) {
    value: Value,
    /// The node with no value at compile time.
    not_const: Ast.Index,
    /// An integer `v` computed at `node` that does not fit its type `ty`; null when no
    /// i128 holds it either.
    overflow: struct { node: Ast.Index, v: ?i128, ty: Type },
    never,
    poison,
};

/// The typed tree a fold reads, and the `when` arm bindings in scope.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    flow: ControlFlow.Ctx,
    consts: []const ConstSym,
    binds: ?*const Bind = null,
};

const Error = error{OutOfMemory};

/// The value of the typed expression at `node`.
pub fn fold(c: *const Ctx, node: Ast.Index) Error!Folded {
    const f = c.flow;
    const n = f.tree.nodes[node.int()];
    const ty = f.node_types[node.int()];
    if (ty.kind == .invalid) return .poison;
    const text = f.tokens[n.main_token].text(f.source);
    switch (n.tag) {
        .literal_number => {
            const v = Literal.intValue(text) orelse return .{ .not_const = node };
            return .{ .value = .{ .int = v } };
        },
        .literal_float => {
            const v = Literal.floatValue(text) orelse return .{ .not_const = node };
            return .{ .value = .{ .float = if (ty.isFloat32()) round32(v) else v } };
        },
        .literal_bool => return .{ .value = .{ .bool = f.tokens[n.main_token].tag == .kw_true } },
        .literal_char => return switch (Literal.decodeChar(text)) {
            .ok => |cp| .{ .value = .{ .char = cp } },
            else => .poison,
        },
        .literal_string => return switch (try Literal.decodeString(c.gpa, text)) {
            .ok => |bytes| .{ .value = .{ .str = bytes } },
            else => .poison,
        },
        .identifier => switch (f.resolutions[node.int()]) {
            .constant => |cid| return constant(c, cid),
            .local => |slot| {
                var b = c.binds;
                while (b) |x| : (b = x.next) if (x.slot == slot) return .{ .value = try dupe(c.gpa, x.v) };
                return .{ .not_const = node };
            },
            else => return .{ .not_const = node },
        },
        .field_access => switch (f.resolutions[node.int()]) {
            .constant => |cid| return constant(c, cid),
            else => return if (symbols_res.isQualifiedVariant(f.tree, f.resolutions, node)) variant(c, node, ty) else .{ .not_const = node },
        },
        .enum_init_unit => return if (n.lhs == Ast.none) variant(c, node, ty) else .{ .not_const = node },
        .unary => return unary(c, node, n, ty),
        .binary => return binary(c, node, n, ty),
        .if_stmt, .match_expr => {
            if (!Ast.isWhen(f.tree, f.tokens, node)) return .{ .not_const = node };
            return if (n.tag == .if_stmt) whenIf(c, n) else whenMatch(c, n);
        },
        .call => return if (isCompileError(f, n)) .never else .{ .not_const = node },
        else => return .{ .not_const = node },
    }
}

fn constant(c: *const Ctx, cid: u32) Error!Folded {
    const k = c.consts[cid];
    if (k.ty.kind == .invalid) return .poison;
    return .{ .value = try dupe(c.gpa, k.value) };
}

fn dupe(gpa: std.mem.Allocator, v: Value) Error!Value {
    return if (v == .str) .{ .str = try gpa.dupe(u8, v.str) } else v;
}

fn isCompileError(f: ControlFlow.Ctx, n: Ast.Node) bool {
    const callee = f.tree.nodes[n.lhs.int()];
    return callee.tag == .identifier and std.mem.eql(u8, f.tokens[callee.main_token].text(f.source), "compile_error") and f.resolutions[n.lhs.int()] == .func;
}

/// A unit variant of enum type `ty`; a payload variant is built at run time.
fn variant(c: *const Ctx, node: Ast.Index, ty: Type) Folded {
    const f = c.flow;
    if (ty.kind != .@"enum") return .{ .not_const = node };
    const name = f.tokens[f.tree.nodes[node.int()].main_token].text(f.source);
    for (f.enums[ty.enum_id].variants, 0..) |vs, i| {
        if (!std.mem.eql(u8, vs.name, name)) continue;
        if (vs.form != .unit) return .{ .not_const = node };
        return .{ .value = .{ .variant = @intCast(i) } };
    }
    return .poison;
}

/// An integer `v` computed at `node` of type `ty`, which it must fit.
fn checked(node: Ast.Index, v: i128, ty: Type) Folded {
    if (!Literal.fitsValue(v, ty)) return .{ .overflow = .{ .node = node, .v = v, .ty = ty } };
    return .{ .value = .{ .int = v } };
}

fn unary(c: *const Ctx, node: Ast.Index, n: Ast.Node, ty: Type) Error!Folded {
    const op = c.flow.tokens[n.main_token].tag;
    const l = try fold(c, n.lhs);
    if (l != .value) return l;
    defer freeValue(c.gpa, l.value);
    return switch (op) {
        .bang => if (l.value == .bool) .{ .value = .{ .bool = !l.value.bool } } else .poison,
        .minus, .tilde => if (l.value == .int and ty.isInteger())
            checked(node, if (op == .tilde) Literal.complement(l.value.int, ty) else -l.value.int, ty)
        else
            .{ .not_const = node },
        else => .{ .not_const = node },
    };
}

fn binary(c: *const Ctx, node: Ast.Index, n: Ast.Node, ty: Type) Error!Folded {
    const op = c.flow.tokens[n.main_token].tag;
    const l = try fold(c, n.lhs);
    if (l != .value) return l;
    defer freeValue(c.gpa, l.value);
    const r = try fold(c, n.rhs);
    if (r != .value) return r;
    defer freeValue(c.gpa, r.value);
    const a = l.value;
    const b = r.value;
    if (std.meta.activeTag(a) != std.meta.activeTag(b) and op != .lt_lt and op != .gt_gt) return .{ .not_const = node };
    switch (op) {
        .amp_amp, .pipe_pipe => {
            if (a != .bool) return .{ .not_const = node };
            return boolean(if (op == .amp_amp) a.bool and b.bool else a.bool or b.bool);
        },
        .plus_dot, .minus_dot, .star_dot, .slash_dot => {
            if (a != .float) return .{ .not_const = node };
            const v = switch (op) {
                .plus_dot => a.float + b.float,
                .minus_dot => a.float - b.float,
                .star_dot => a.float * b.float,
                .slash_dot => a.float / b.float,
                else => unreachable,
            };
            // float32 arithmetic rounds each result; one through f64 rounds the same.
            return .{ .value = .{ .float = if (ty.isFloat32()) round32(v) else v } };
        },
        .lt_dot, .gt_dot, .le_dot, .ge_dot => {
            if (a != .float) return .{ .not_const = node };
            return boolean(switch (op) {
                .lt_dot => a.float < b.float,
                .gt_dot => a.float > b.float,
                .le_dot => a.float <= b.float,
                .ge_dot => a.float >= b.float,
                else => unreachable,
            });
        },
        .eq_eq, .bang_eq => {
            const same = valueEql(a, b);
            return boolean(if (op == .eq_eq) same else !same);
        },
        .lt, .lt_eq, .gt, .gt_eq => {
            // A user `Ord` impl or a float runs at run time; the prelude's scalars fold.
            const ord = order(a, b) orelse return .{ .not_const = node };
            return boolean(switch (op) {
                .lt => ord == .lt,
                .lt_eq => ord != .gt,
                .gt => ord == .gt,
                .gt_eq => ord != .lt,
                else => unreachable,
            });
        },
        .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret, .plus_percent, .minus_percent, .star_percent, .lt_lt, .gt_gt => {
            if (a != .int or b != .int or !ty.isInteger()) return .{ .not_const = node };
            const v = intBinary(op, a.int, b.int, ty) orelse return shiftPast(node, op, a.int, b.int, ty);
            return checked(node, v, ty);
        },
        else => return .{ .not_const = node },
    }
}

/// A left shift of a nonzero value that `intBinary` gave none (by `ty`'s width or more,
/// or past i128) denotes a value of `ty`'s width in bits or more, so it is out of range
/// whatever the amount, as `1 << 10` at `int8` is. Zero shifted has no such value.
fn shiftPast(node: Ast.Index, op: token.Tag, l: i128, r: i128, ty: Type) Folded {
    if (op != .lt_lt or r < 0 or l == 0) return .{ .not_const = node };
    const v: ?i128 = if (r < 127) std.math.shlExact(i128, l, @intCast(r)) catch null else null;
    return .{ .overflow = .{ .node = node, .v = v, .ty = ty } };
}

fn boolean(b: bool) Folded {
    return .{ .value = .{ .bool = b } };
}

fn round32(v: f64) f64 {
    return @as(f32, @floatCast(v));
}

/// `when c { a } else { b }`: every arm must have a value, or be a `compile_error`, and
/// the value is the taken arm's.
fn whenIf(c: *const Ctx, n: Ast.Node) Error!Folded {
    const f = c.flow;
    const cond = try fold(c, n.lhs);
    if (cond != .value) return cond;
    if (cond.value != .bool) {
        freeValue(c.gpa, cond.value);
        return .poison;
    }
    const h = Ast.ifHeaderAt(f.tree, n.rhs.int());
    if (h.else_node == Ast.none) return .poison;
    return arms(c, &.{ h.then_block, h.else_node }, &.{}, null, if (cond.value.bool) 0 else 1);
}

/// `when x { pat -> e, .. }`: the value is the first arm's whose guard holds and whose
/// pattern takes `x`'s.
fn whenMatch(c: *const Ctx, n: Ast.Node) Error!Folded {
    const f = c.flow;
    const s = try fold(c, n.lhs);
    if (s != .value) return s;
    defer freeValue(c.gpa, s.value);
    const st = f.node_types[n.lhs.int()];
    const arm_nodes = Ast.rangeSlice(f.tree, n.rhs.int());
    const bodies = try c.gpa.alloc(Ast.Index, arm_nodes.len);
    defer c.gpa.free(bodies);
    const pats = try c.gpa.alloc(Ast.Index, arm_nodes.len);
    defer c.gpa.free(pats);
    var taken: ?usize = null;
    for (arm_nodes, bodies, pats, 0..) |arm_idx, *body, *pat, i| {
        const an = f.tree.nodes[arm_idx.int()];
        const h = Ast.armHeaderAt(f.tree, an.rhs.int());
        body.* = h.body;
        pat.* = an.lhs;
        if (taken != null) continue;
        var holds = true;
        if (h.guard != Ast.none) {
            var slot: Bind = undefined;
            const inner = withArm(c, &slot, an.lhs, s.value);
            const g = try fold(&inner, h.guard);
            if (g != .value) return g;
            if (g.value != .bool) {
                freeValue(c.gpa, g.value);
                return .poison;
            }
            holds = g.value.bool;
        }
        if (holds and PatternChecker.takes(f, an.lhs, st, s.value)) taken = i;
    }
    return arms(c, bodies, pats, s.value, taken orelse return .poison);
}

/// `c` with the binding arm pattern `pat` names, if any, set in `into` to `scrut`.
pub fn withArm(c: *const Ctx, into: *Bind, pat: Ast.Index, scrut: Value) Ctx {
    var inner = c.*;
    inner.binds = armBind(c.flow, into, pat, scrut, c.binds);
    return inner;
}

/// `outer` with the binding arm pattern `pat` names, if any, set in `into` to `scrut`.
pub fn armBind(f: ControlFlow.Ctx, into: *Bind, pat: Ast.Index, scrut: Value, outer: ?*const Bind) ?*const Bind {
    const b = Ast.patternBinding(f.tree, pat) orelse return outer;
    const slot = switch (f.resolutions[b.int()]) {
        .local => |l| l,
        else => return outer,
    };
    into.* = .{ .slot = slot, .v = scrut, .next = outer };
    return into;
}

/// Fold every arm of a `when`, each bound to `scrut` through its pattern in `pats` (a
/// match form), and keep arm `taken`'s value. An arm not taken may be a `compile_error`.
fn arms(c: *const Ctx, bodies: []const Ast.Index, pats: []const Ast.Index, scrut: ?Value, taken: usize) Error!Folded {
    var result: Folded = .poison;
    errdefer if (result == .value) freeValue(c.gpa, result.value);
    for (bodies, 0..) |body, i| {
        var slot: Bind = undefined;
        const inner = if (i < pats.len and scrut != null) withArm(c, &slot, pats[i], scrut.?) else c.*;
        const v = try arm(&inner, body);
        switch (v) {
            .value => |x| if (i == taken) {
                result = v;
            } else freeValue(c.gpa, x),
            .never => if (i == taken) {
                result = .never;
            },
            else => {
                if (result == .value) freeValue(c.gpa, result.value);
                return v;
            },
        }
    }
    return result;
}

/// An arm of a `when`: a block holding one value, or the `when` an `else when` chains on.
fn arm(c: *const Ctx, node: Ast.Index) Error!Folded {
    const f = c.flow;
    const n = f.tree.nodes[node.int()];
    if (n.tag != .block) return fold(c, node);
    const stmts = Ast.rangeSlice(f.tree, n.lhs.int());
    if (stmts.len != 1) return .{ .not_const = node };
    const s = f.tree.nodes[stmts[0].int()];
    return switch (s.tag) {
        .expr_stmt => fold(c, s.lhs),
        .if_stmt, .block => arm(c, stmts[0]),
        else => .{ .not_const = stmts[0] },
    };
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

pub fn valueEql(a: Value, b: Value) bool {
    return switch (a) {
        .int => |x| x == b.int,
        .float => |x| x == b.float,
        .bool => |x| x == b.bool,
        .char => |x| x == b.char,
        .str => |x| std.mem.eql(u8, x, b.str),
        .variant => |x| x == b.variant,
    };
}

/// Whether `node` is an expression made only of literals, constants and the operators
/// over them: one the body pass folds to range-check.
pub fn isConstExpr(tree: Ast.Tree, resolutions: []const Resolution, node: Ast.Index) bool {
    const n = tree.nodes[node.int()];
    return switch (n.tag) {
        .literal_number, .literal_float, .literal_bool, .literal_char => true,
        .identifier, .field_access => resolutions[node.int()] == .constant,
        .unary => isConstExpr(tree, resolutions, n.lhs),
        .binary => isConstExpr(tree, resolutions, n.lhs) and isConstExpr(tree, resolutions, n.rhs),
        else => false,
    };
}

/// Whether `node` is made of literals alone, so an overflow in it is a literal's rather
/// than a computed value's.
pub fn literalsOnly(tree: Ast.Tree, node: Ast.Index) bool {
    const n = tree.nodes[node.int()];
    return switch (n.tag) {
        .literal_number => true,
        .unary => literalsOnly(tree, n.lhs),
        .binary => literalsOnly(tree, n.lhs) and literalsOnly(tree, n.rhs),
        else => false,
    };
}
