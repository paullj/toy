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
    for (0..n) |cid| _ = try ev.constant(@intCast(cid));
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

    fn constant(ev: *Eval, cid: u32) Error!ConstSym {
        switch (ev.state[cid]) {
            .done => return ev.t.consts.items[cid],
            // A cycle has no value; the use that closes it is reported where it is named.
            .folding => return poison,
            .unseen => {},
        }
        ev.state[cid] = .folding;
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
        const declared: ?Type = if (decl.lhs != Ast.none) t.typeFromNode(decl.lhs) else null;
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
            try t.sink.report(.{ .span = at, .code = .T0041 }, "cannot bind {s} to '{s}' of type {s}", .{ t.typeName(f.ty), ev.name, t.typeName(want) });
            return null;
        }
        return .{ .ty = want, .value = f.v };
    }

    /// Literal `f` at type `want` of its kind: an integer must fit, a float32 rounds.
    fn adopt(ev: *Eval, f: Folded, want: Type, at: anytype) Error!?ConstSym {
        switch (f.v) {
            .int => |v| if (!Literal.fitsValue(v, want)) {
                try ev.t.sink.report(.{ .span = at, .code = .T0034 }, "literal out of range for type '{s}'", .{ev.t.typeName(want)});
                return null;
            },
            .float => |v| if (want.isFloat32()) return .{ .ty = want, .value = .{ .float = round32(v) } },
            else => {},
        }
        return .{ .ty = want, .value = f.v };
    }

    fn notFolded(ev: *Eval, node: Ast.Index) Error!?Folded {
        try ev.t.sink.report(.{ .span = ev.t.spanOf(node), .code = .T0083 }, "the value of constant '{s}' is not known at compile time", .{ev.name});
        return null;
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
                    try t.sink.report(.{ .span = t.spanOf(node), .code = .T0036 }, "malformed char literal", .{});
                    return null;
                },
            },
            .literal_string => switch (try Literal.decodeString(t.gpa, text)) {
                .ok => |bytes| return .{ .ty = Type.str, .v = .{ .str = bytes } },
                else => {
                    try t.sink.report(.{ .span = t.spanOf(node), .code = .T0036 }, "malformed string literal", .{});
                    return null;
                },
            },
            .identifier => switch (t.resolutions[node.int()]) {
                .constant => |cid| {
                    if (ev.state[cid] == .folding) return ev.notFolded(node);
                    const c = try ev.constant(cid);
                    if (c.ty.kind == .invalid) return null;
                    const v: Value = if (c.value == .str) .{ .str = try t.gpa.dupe(u8, c.value.str) } else c.value;
                    return .{ .ty = c.ty, .v = v };
                },
                else => return ev.notFolded(node),
            },
            .field_access => return ev.variant(node, n, null),
            .enum_init_unit => {
                if (n.lhs != Ast.none) return ev.notFolded(node);
                const e = expected orelse return ev.notFolded(node);
                if (e.kind != .@"enum") return ev.notFolded(node);
                return ev.variant(node, n, e);
            },
            .unary => return ev.unary(node, n, expected),
            .binary => return ev.binary(node, n, expected),
            else => return ev.notFolded(node),
        }
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
        try t.sink.report(.{ .span = t.spanOf(node), .code = .T0061 }, "enum '{s}' has no variant '{s}'", .{ t.typeName(ty), name });
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
        try ev.t.sink.report(.{ .span = ev.t.spanOf(node), .code = .T0044 }, "{s}", .{msg});
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
            try ev.t.sink.report(.{ .span = span, .code = .T0034 }, "literal out of range for type '{s}'", .{ev.t.typeName(at)})
        else
            try ev.t.sink.report(.{ .span = span, .code = .T0034 }, "constant value {d} out of range for type '{s}'", .{ f.v.int, ev.t.typeName(at) });
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
        try ev.t.sink.report(.{ .span = ev.t.spanOf(node), .code = .T0044 }, fmt, .{ev.opText(n)});
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
        try t.sink.report(.{ .span = t.spanOf(node), .code = .T0044 }, "operands of '{s}' must have the same type", .{ev.opText(n)});
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
    try Typecheck.expectDiagCodes("N :=: N\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N: uint8 =: 256\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("A: uint8 =: 200\nN :=: A + 56\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N: uint8 =: 200 + 100 - 100\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N: int8 =: -128 - 1 + 1\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N: uint8 =: -1 + 2\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("enum E { A, B }\nN :=: E.A < E.B\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N: int =: 1.5\n", &.{C.T0041});
    try Typecheck.expectDiagCodes("A: int8 =: 1\nB: int16 =: 1\nN :=: A + B\n", &.{C.T0044});
    try Typecheck.expectDiagCodes("enum E { A }\nN :=: E.Z\n", &.{C.T0061});
}
