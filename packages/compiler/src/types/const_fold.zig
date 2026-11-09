//! Computing the value of an expression the body checker has typed: a constant's
//! initializer, a `when` part, or an integer expression made only of literals and
//! constants. Every type comes from the checker's node types, so this file holds no
//! type rule of its own: it reads a node's type for the width to compute at, and says
//! when a value does not exist (`not_const`) or does not fit (`overflow`). The checker
//! reads `isConstInt` and `isConstFloat` to give a literal-only expression its place's
//! width or precision.

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
    resolutions: []const Resolution,
    consts: []const ConstSym,
};

/// The kind of value a constant declared with no type holds when its initializer is
/// built only from literals and other such constants: like a literal, it has no width
/// or precision of its own until a use gives it one.
pub const Untyped = enum { none, int, float };

fn untypedConst(v: View, node: Ast.Index) Untyped {
    return switch (v.resolutions[node.int()]) {
        .constant => |cid| v.consts[cid].untyped,
        else => .none,
    };
}

/// Whether `node` is an integer constant built from literals and untyped constants
/// alone, which, like a bare literal, has no width of its own until a place or sibling
/// gives it one.
pub fn isConstInt(v: View, node: Ast.Index) bool {
    if (node == Ast.none) return false;
    const n = v.tree.nodes[node.int()];
    return switch (n.tag) {
        .literal_number => true,
        .identifier, .field_access => untypedConst(v, node) == .int,
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

/// Whether `node` is a float constant built from literals, untyped constants and the
/// dotted operators, which takes `float32` where one is expected as an integer
/// constant takes a width.
pub fn isConstFloat(v: View, node: Ast.Index) bool {
    if (node == Ast.none) return false;
    const n = v.tree.nodes[node.int()];
    return switch (n.tag) {
        .literal_float => true,
        .identifier, .field_access => untypedConst(v, node) == .float,
        .binary => switch (v.tokens[n.main_token].tag) {
            .plus_dot, .minus_dot, .star_dot, .slash_dot => isConstFloat(v, n.lhs) and isConstFloat(v, n.rhs),
            else => false,
        },
        else => false,
    };
}

/// `l op r` for integer operator `op` at integer type `t`, or null when it does not fold:
/// a zero divisor, an i128 overflow, or an operator that is no integer operator.
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
        // Run-time shifts never trap: they drop the bits shifted out, and an amount out
        // of range gives 0 (or -1 for a negative value shifted right). A fold must give
        // the same value, since a compile-time error is only for code that would panic.
        .lt_lt => if (r < 0 or r >= t.intBits()) 0 else Literal.wrap(l << @as(u7, @intCast(r)), t),
        .gt_gt => if (r < 0 or r >= t.intBits()) (if (l < 0) -1 else 0) else l >> @as(u7, @intCast(r)),
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
            .constant => |cid| return constant(c, cid, ty),
            .local => |slot| {
                var b = c.binds;
                while (b) |x| : (b = x.next) if (x.slot == slot) return .{ .value = try dupe(c.gpa, x.v) };
                return .{ .not_const = node };
            },
            else => return .{ .not_const = node },
        },
        .field_access => switch (f.resolutions[node.int()]) {
            .constant => |cid| return constant(c, cid, ty),
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

/// Constant `cid` named where its use is typed `ty`: an untyped float const used as a
/// `float32` holds the float32 value, as a float literal there does.
fn constant(c: *const Ctx, cid: u32, ty: Type) Error!Folded {
    const k = c.consts[cid];
    if (k.ty.kind == .invalid) return .poison;
    if (k.value == .float and ty.isFloat32()) return .{ .value = .{ .float = round32(k.value.float) } };
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
    const eid = f.enumId(ty) orelse return .{ .not_const = node };
    const name = f.tokens[f.tree.nodes[node.int()].main_token].text(f.source);
    for (f.enums[eid].variants, 0..) |vs, i| {
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
            const v = intBinary(op, a.int, b.int, ty) orelse return .{ .not_const = node };
            return checked(node, v, ty);
        },
        else => return .{ .not_const = node },
    }
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

const testing = std.testing;
const Typecheck = @import("../types.zig");

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
        .{ .src = "N :=: when true { 1 } else { compile_error(\"no\") }\n", .ty = Type.int, .value = .{ .int = 1 } },
        .{ .src = "enum E { A, B }\nN: uint8 =: when E.B { .A -> compile_error(\"no\"), .B -> 9 }\n", .ty = Type.uint8, .value = .{ .int = 9 } },
        .{ .src = "N :=: when true { 1 } else when false { compile_error(\"no\") } else { compile_error(\"no\") }\n", .ty = Type.int, .value = .{ .int = 1 } },
        .{ .src = "enum E { A, B, C }\nX :=: E.B\nN :=: when X { .A -> 1, .B | .C -> 2 }\n", .ty = Type.int, .value = .{ .int = 2 } },
        .{ .src = "K :=: 3\nN: uint8 =: when K { 0 -> 1, _ if K > 2 -> 200, _ -> 3 }\n", .ty = Type.uint8, .value = .{ .int = 200 } },
        .{ .src = "N: str =: when 1 > 2 { true -> \"t\", false -> \"f\" }\n", .ty = Type.str, .value = .{ .str = "f" } },
        .{ .src = "L :=: 4\nN :=: when L { 0 -> 1, n -> n * 10 }\n", .ty = Type.int, .value = .{ .int = 40 } },
        .{ .src = "L :=: 4\nN :=: when L { n if n > 3 -> n, _ -> 1 }\n", .ty = Type.int, .value = .{ .int = 4 } },
        .{ .src = "L :=: 4\nN :=: when L { 0 -> 0, n -> when n > 3 { n } else { 0 } }\n", .ty = Type.int, .value = .{ .int = 4 } },
    };
    for (cases) |c| {
        var got = try lastValue(c.src);
        defer got.owned.deinit(testing.allocator);
        if (c.ty.kind != .@"enum") try testing.expect(got.ty.eql(c.ty)) else try testing.expect(got.ty.kind == .@"enum");
        try testing.expect(valueEql(got.value, c.value));
    }
}

test "a generic enum's unit variant is a const, its type args from the declared type or the variant" {
    const C = @import("../diagnostics/codes.zig").Code;
    const srcs = [_][]const u8{
        "enum P[T] { E, V(T) }\nN: P[int] =: .E\n",
        "enum P[T] { E, V(T) }\nN :=: P[int].E\n",
        "N: Option[int] =: Option[int].none\n",
        "enum P[T] { V(T), E }\nfn f() -> P[str] {\n    K: P[str] =: .E\n    K\n}\nN :=: P[bool].E\n",
    };
    for (srcs) |src| {
        var got = try lastValue(src);
        defer got.owned.deinit(testing.allocator);
        try testing.expect(got.ty.isApp());
        try testing.expect(got.value == .variant);
    }
    var w = try lastValue("enum P[T] { V(T), E }\nX :=: P[int].E\nN :=: when X { .V(_) -> 1, .E -> 2 }\n");
    defer w.owned.deinit(testing.allocator);
    try testing.expect(valueEql(w.value, .{ .int = 2 }));
    try Typecheck.expectDiagCodes("enum P[T] { E, V(T) }\nN :=: P.E\n", &.{C.T0016});
    try Typecheck.expectDiagCodes("enum P[T] { E, V(T) }\nN: P[int] =: .V(1)\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("enum P[T] { E, V(T) }\nN: P[int] =: P[bool].E\n", &.{C.T0041});
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

test "a when part that overflows while folding is its fold's error, not a crash" {
    const C = @import("../diagnostics/codes.zig").Code;
    const big = "BIG :=: 9223372036854775807\n";
    try Typecheck.expectDiagCodes(big ++ "fn f() -> int {\n    when BIG + 1 > 0 { 1 } else { 2 }\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes(big ++ "fn f() -> int {\n    when BIG + 1 > 0 { return 3 }\n    0\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes(big ++ "fn f() -> int {\n    when BIG + 1 > 0 { true -> 1, false -> 2 }\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes(big ++ "fn f() -> int {\n    when BIG { _ if BIG + 1 > 0 -> 1, _ -> 2 }\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes(big ++ "fn f() -> int {\n    when BIG + 1 { _ -> 1 }\n}\n", &.{C.T0034});
    // An error the body pass reports in the condition is the only one.
    try Typecheck.expectDiagCodes("A: int8 =: 1\nB: int16 =: 1\nfn f() -> int {\n    when A + B > 0 { 1 } else { 2 }\n}\n", &.{C.T0044});
}

test "compile_error is an error only where it is compiled" {
    const C = @import("../diagnostics/codes.zig").Code;
    try Typecheck.expectDiagCodes("N :=: when false { 1 } else { compile_error(\"no\") }\n", &.{C.T0086});
    try Typecheck.expectDiagCodes("N :=: compile_error(\"no\")\n", &.{C.T0086});
    try Typecheck.expectDiagCodes("N :=: compile_error()\n", &.{C.T0039});
    try Typecheck.expectDiagCodes("N :=: when false { 1 } else { compile_error(2) }\n", &.{C.T0040});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() -> int {\n    when K > 1 { 1 } else { compile_error(\"no\") }\n}\n", &.{});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() -> int {\n    when K < 1 { 1 } else { compile_error(\"no\") }\n}\n", &.{C.T0086});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() -> str {\n    when K { 2 -> \"two\", _ -> compile_error(\"no\") }\n}\n", &.{});
    try Typecheck.expectDiagCodes("K :=: 3\nfn f() -> str {\n    when K { 2 -> \"two\", _ -> compile_error(\"no\") }\n}\n", &.{C.T0086});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() {\n    when K < 1 { when true { compile_error(\"no\") } }\n}\n", &.{});
    try Typecheck.expectDiagCodes("fn f() -> int {\n    compile_error(\"no\")\n}\n", &.{C.T0086});
    try Typecheck.expectDiagCodes("fn f(s: str) -> int {\n    compile_error(s)\n}\n", &.{C.T0040});
}

test "a compile_error message that is not plain UTF-8 text shows as written" {
    const src = "N :=: compile_error(\"bad \\xff\")\nfn f() -> int {\n    compile_error(\"a\\nb\")\n}\n";
    var r = try Typecheck.checkSource(src);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.result.diags.len);
    try testing.expectEqualStrings("bad \\xff", r.result.diags[0].message);
    try testing.expectEqualStrings("a\\nb", r.result.diags[1].message);
}
