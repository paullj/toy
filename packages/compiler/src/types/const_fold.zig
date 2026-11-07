//! Folding an integer expression built from literals alone, and the integer arithmetic
//! a constant's initializer folds with. The body checker reads `isConstInt`/`constValue`
//! to give such an expression the width of its place, and the const evaluator folds its
//! integer operators through `intBinary`, so the two can never disagree on a value.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const token = @import("../ast/Token.zig");
const Token = token.Token;
const Type = @import("../layout/Type.zig").Type;
const Literal = @import("literal.zig");

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
            // A shift is left out: its amount is no sibling of the left operand, and
            // `constValue` gives no value for an amount of the place's width or more, so
            // a narrow width it took would go unchecked and wrap (`b + (1 << 10)` at int8).
            .plus, .minus, .star, .slash, .percent, .amp, .pipe, .caret, .plus_percent, .minus_percent, .star_percent => isConstInt(v, n.lhs) and isConstInt(v, n.rhs),
            else => false,
        },
        else => false,
    };
}

/// The value constant `node` denotes at integer type `t`, or null when it does not
/// fold: a zero divisor or an i128 overflow, which a range check cannot judge.
pub fn constValue(v: View, node: Ast.Index, t: Type) ?i128 {
    const n = v.tree.nodes[node.int()];
    const op = v.tokens[n.main_token].tag;
    if (n.tag == .literal_number) return Literal.intValue(v.tokens[n.main_token].text(v.source));
    const l = constValue(v, n.lhs, t) orelse return null;
    if (n.tag == .unary) return if (op == .tilde) Literal.complement(l, t) else -l;
    const r = constValue(v, n.rhs, t) orelse return null;
    return intBinary(op, l, r, t);
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

const testing = std.testing;

fn foldSource(comptime expr: []const u8) !?i128 {
    const gpa = testing.allocator;
    const source = "N :=: " ++ expr ++ "\n";
    const tokens = try @import("../lex.zig").tokenize(gpa, source);
    defer gpa.free(tokens);
    const res = try @import("../parse.zig").parse(gpa, tokens, source);
    defer {
        gpa.free(res.diags);
        gpa.free(res.tree.nodes);
        gpa.free(res.tree.extra);
    }
    try testing.expectEqual(@as(usize, 0), res.diags.len);
    const decl = Ast.rangeSlice(res.tree, res.tree.nodes[Ast.root(res.tree.nodes).int()].lhs.int())[0];
    const v: View = .{ .tree = res.tree, .tokens = tokens, .source = source };
    const init = res.tree.nodes[decl.int()].rhs;
    if (!isConstInt(v, init)) return error.NotConst;
    return constValue(v, init, Type.int);
}

test "a literal expression folds at int; a zero divisor does not" {
    try testing.expectEqual(@as(?i128, 5), try foldSource("5"));
    try testing.expectEqual(@as(?i128, 10), try foldSource("-2 + 3 * 4"));
    try testing.expectEqual(@as(?i128, -1), try foldSource("~0"));
    try testing.expectEqual(@as(?i128, null), try foldSource("1 / 0"));
    try testing.expectError(error.NotConst, foldSource("1 << 2"));
}
