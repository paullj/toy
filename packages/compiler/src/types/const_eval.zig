//! The order the top-level constants are checked in. Each is checked by the body
//! checker like any expression (`BodyChecker.checkConstDecl`), before the body pass,
//! which reads each constant's type and value from the result. A use of a constant not
//! yet checked checks it first, so the order follows the uses, and a use of one still
//! being checked closes a cycle. A local constant is checked where its body declares it.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Type = @import("../layout/Type.zig").Type;
const Token = @import("../ast/Token.zig").Token;
const const_fold = @import("const_fold.zig");
const Typecheck = @import("../types.zig");
const BodyChecker = @import("../BodyChecker.zig").BodyChecker;

const Value = const_fold.Value;
const ConstSym = Typecheck.ConstSym;
const valueEql = const_fold.valueEql;

pub const poison: ConstSym = .{ .ty = Type.invalid, .value = .{ .int = 0 } };

/// Free the str bytes a const table owns.
pub fn freeValues(gpa: std.mem.Allocator, consts: []const ConstSym) void {
    for (consts) |c| const_fold.freeValue(gpa, c.value);
}

const Error = error{OutOfMemory};

const State = enum { unseen, checking, done };

/// Whether the type at `type_node` is one of the type parameters `params`.
pub fn namesTypeParam(tree: Ast.Tree, tokens: []const Token, source: []const u8, type_node: Ast.Index, params: []const []const u8) bool {
    const tn = tree.nodes[type_node.int()];
    switch (tn.tag) {
        .type_app, .fn_type, .field_access, .literal_unit => return false,
        else => {},
    }
    const name = tokens[tn.main_token].text(source);
    for (params) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

/// Check every top-level constant against the frozen `model`, whose `consts` the
/// checks fill. A local constant typed by its fn's type parameter is reported here,
/// once: a generic fn's body is checked only per instance, where the parameter names
/// a concrete type, and not at all when nothing instantiates it.
pub fn checkAll(t: *Typecheck, model: *const Typecheck.Model) Error!void {
    const n = t.graph.consts.len;
    const state = try t.gpa.alloc(State, n);
    defer t.gpa.free(state);
    @memset(state, .unseen);
    var pass: ConstPass = .{ .t = t, .model = model, .state = state };
    defer pass.stack.deinit(t.gpa);
    for (t.graph.consts, 0..) |c, cid| {
        if (c.owner_fn == Ast.none) try pass.check(@intCast(cid)) else try typeParamConst(t, c);
    }
}

fn typeParamConst(t: *Typecheck, c: Typecheck.GraphConstInput) Error!void {
    const prev = t.gphSelect(c.module);
    defer _ = t.gphSelect(prev);
    const decl = t.tree.nodes[c.decl_node.int()];
    if (decl.lhs == Ast.none) return;
    const proto = Ast.protoAt(t.tree, t.tree.nodes[c.owner_fn.int()].lhs.int());
    if (proto.generic_params.len == 0) return;
    const names = try t.gpa.alloc([]const u8, proto.generic_params.len);
    defer t.gpa.free(names);
    for (proto.generic_params, names) |gp, *name| name.* = t.tokens[t.tree.nodes[gp.int()].main_token].text(t.source);
    if (!namesTypeParam(t.tree, t.tokens, t.source, decl.lhs, names)) return;
    try t.sink.report(.{ .span = t.spanOf(decl.lhs), .code = .T0083 }, "constant '{s}' cannot have a type parameter as its type", .{t.tokens[decl.main_token].text(t.source)});
}

pub const ConstPass = struct {
    t: *Typecheck,
    model: *const Typecheck.Model,
    state: []State,
    /// The constants being checked, outermost first: a use of one of them is a cycle.
    stack: std.ArrayList(u32) = .empty,

    /// Constant `cid` is named at `node`, which `bc` is typing: check it first, or
    /// report the cycle a use of one still being checked closes.
    pub fn use(p: *ConstPass, bc: *BodyChecker, node: Ast.Index, cid: u32) Error!void {
        switch (p.state[cid]) {
            .done => {},
            .checking => try p.reportCycle(bc, node, cid),
            .unseen => try p.check(cid),
        }
    }

    fn check(p: *ConstPass, cid: u32) Error!void {
        if (p.state[cid] != .unseen) return;
        const t = p.t;
        p.state[cid] = .checking;
        try p.stack.append(t.gpa, cid);
        const c = t.graph.consts[cid];
        var bc = t.constCheckerFor(p.model, c.module);
        defer bc.deinit();
        bc.const_pass = p;
        try bc.checkConstDecl(c.decl_node, cid);
        try t.sink.merge(&bc.sink);
        _ = p.stack.pop();
        p.state[cid] = .done;
    }

    /// T0084 at the use of `cid` that closes a cycle, spelling the cycle from `cid` round
    /// to itself. Each constant on it is poison, so this is the cycle's one error.
    fn reportCycle(p: *ConstPass, bc: *BodyChecker, node: Ast.Index, cid: u32) Error!void {
        var path: std.Io.Writer.Allocating = .init(p.t.gpa);
        defer path.deinit();
        const from = std.mem.indexOfScalar(u32, p.stack.items, cid).?;
        for (p.stack.items[from..]) |c| {
            path.writer.print("{s} -> ", .{p.constName(c)}) catch return error.OutOfMemory;
        }
        path.writer.writeAll(p.constName(cid)) catch return error.OutOfMemory;
        try bc.report(.{ .span = bc.spanOf(node), .code = .T0084 }, "constant '{s}' depends on itself: {s}", .{ p.constName(cid), path.written() });
    }

    fn constName(p: *const ConstPass, cid: u32) []const u8 {
        const c = p.t.graph.consts[cid];
        const m = &p.t.graph.mods[c.module];
        return m.tokens[m.tree.nodes[c.decl_node.int()].main_token].text(m.source);
    }
};

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
    try Typecheck.expectDiagCodes("N :=: 1 << 200\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("N :=: 0 << 200\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N :=: 1 << 64\n", &.{C.T0034});
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
    try Typecheck.expectDiagCodes("A: uint8 =: 1\nN: uint8 =: when true { A } else { 256 }\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("A: uint8 =: 1\nN :=: when true { A } else { 256 }\n", &.{C.T0058});
    try Typecheck.expectDiagCodes("enum E { A, B }\nN :=: when E.A { .A -> 1 }\n", &.{C.T0048});
    try Typecheck.expectDiagCodes("N :=: when 3 { 3 -> 1 }\n", &.{C.T0048});
    try Typecheck.expectDiagCodes("N :=: when 3 { true -> 1, _ -> 2 }\n", &.{C.T0067});
    try Typecheck.expectDiagCodes("N :=: when 1.5 { _ -> 1 }\n", &.{C.T0067});
    try Typecheck.expectDiagCodes("N :=: when 3 { 3 if 1 -> 1, _ -> 2 }\n", &.{C.T0045});
    try Typecheck.expectDiagCodes("N: uint8 =: when 3 { 3 -> 1, _ -> 256 }\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("fn f(n: int) -> int {\n    when n { _ -> 1 }\n}\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("enum E { A, B }\nX :=: E.A\nfn f() -> int {\n    when X { .A -> 1 }\n}\n", &.{C.T0048});
}

test "an expression of literals and constants in a body folds, and out of range is T0034" {
    const C = @import("../diagnostics/codes.zig").Code;
    try Typecheck.expectDiagCodes("A: uint8 =: 250\nfn f() -> uint8 {\n    n := A + 10\n    n\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("A: uint8 =: 250\nfn f() -> uint8 {\n    -A\n}\n", &.{C.T0087});
    try Typecheck.expectDiagCodes("A: uint8 =: 250\nfn f() -> uint8 {\n    K :=: A - 50\n    K + 5\n}\n", &.{});
    try Typecheck.expectDiagCodes("fn f() -> int8 {\n    100 + 100 - 100\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("fn f() -> uint8 {\n    1 << 3\n}\n", &.{});
    try Typecheck.expectDiagCodes("fn f() -> int8 {\n    1 << 10\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("fn f() -> int {\n    x := 1 << 127\n    x\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("fn f() -> int {\n    -1 << 200\n}\n", &.{C.T0034});
    try Typecheck.expectDiagCodes("fn f() -> uint8 {\n    -(-1)\n}\n", &.{C.T0034});
    var r = try Typecheck.checkSource("A: uint8 =: 250\nfn f() -> uint8 {\n    A + 10\n}\n");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("constant value 260 out of range for type 'uint8'", r.result.diags[0].message);
}

test "a local const in a when arm not taken is checked as the rest of that arm is" {
    const C = @import("../diagnostics/codes.zig").Code;
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() -> int {\n    when K < 1 {\n        N :=: compile_error(\"no\")\n        return N\n    }\n    0\n}\n", &.{});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() -> int {\n    when K > 1 {\n        N :=: compile_error(\"no\")\n        return N\n    }\n    0\n}\n", &.{C.T0086});
    try Typecheck.expectDiagCodes("K :=: 2\nfn f() -> int {\n    when K < 1 {\n        N: uint8 =: 300\n        return 1\n    }\n    0\n}\n", &.{C.T0034});
}

test "a when arm's binding names the scrutinee's value, in its guard, body and inner whens" {
    try Typecheck.expectDiagCodes("L :=: 4\nfn f() -> int {\n    when L { n if n > 3 -> n * 10, _ -> 1 }\n}\n", &.{});
    try Typecheck.expectDiagCodes("L :=: 4\nfn f() -> int {\n    when L { n -> when n > 3 { 1 } else { 2 } }\n}\n", &.{});
    // A lambda's own locals are no bindings of the arm around it.
    try Typecheck.expectDiagCodes("L :=: 4\nfn f() -> int {\n    when L { n -> { g := fn(x: int) -> int { when x > 3 { 1 } else { 2 } }\n g(n) } }\n}\n", &.{.T0085});
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

test "a non-const when part is T0085 over the whole part, in a body or an initializer" {
    const src = "fn ten() -> int { 10 }\nX :=: when 3 { n if ten() > 3 -> n, _ -> 1 }\n";
    var r = try Typecheck.checkSource(src);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.result.diags.len);
    const d = r.result.diags[0];
    try testing.expectEqualStrings("ten() > 3", src[d.byte_offset..d.end]);
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
