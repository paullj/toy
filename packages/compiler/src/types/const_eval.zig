//! The order the top-level constants are checked in. Each is checked by the body
//! checker like any expression (`BodyChecker.checkConstDecl`), before the body pass,
//! which reads each constant's type and value from the result. A use of a constant not
//! yet checked checks it first, so the order follows the uses, and a use of one still
//! being checked closes a cycle. A local constant is checked where its body declares it,
//! except that one typed by its fn's type parameter is rejected here, once. Before any
//! of it, `markUntyped` reads off the syntax which constants are untyped, so a use takes
//! their width as it would a literal's.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Type = @import("../layout/Type.zig").Type;
const Token = @import("../ast/Token.zig").Token;
const const_fold = @import("const_fold.zig");
const Typecheck = @import("../types.zig");
const BodyChecker = @import("../BodyChecker.zig").BodyChecker;

const ConstSym = Typecheck.ConstSym;

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
        if (!c.local) try pass.check(@intCast(cid)) else if (c.owner_fn != Ast.none) try typeParamConst(t, c);
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

/// Mark each constant declared with no type over literals and other such constants,
/// which takes its width or precision from each use (`const_fold.Untyped`). The body
/// checker asks this before typing a use, when the constant may not be checked yet, so
/// it is read off the syntax, over the constants alone.
pub fn markUntyped(t: *Typecheck) Error!void {
    const state = try t.gpa.alloc(State, t.graph.consts.len);
    defer t.gpa.free(state);
    @memset(state, .unseen);
    for (0..state.len) |cid| markOne(t, state, @intCast(cid));
}

fn markOne(t: *Typecheck, state: []State, cid: u32) void {
    if (state[cid] != .unseen) return;
    state[cid] = .checking;
    defer state[cid] = .done;
    const c = t.graph.consts[cid];
    const m = &t.graph.mods[c.module];
    const decl = m.tree.nodes[c.decl_node.int()];
    if (decl.lhs != Ast.none or decl.rhs == Ast.none) return;
    markRefs(t, state, m, decl.rhs);
    const v: const_fold.View = .{ .tree = m.tree, .tokens = m.tokens, .source = m.source, .resolutions = m.resolutions, .consts = t.consts.items };
    t.consts.items[cid].untyped = if (const_fold.isConstInt(v, decl.rhs)) .int else if (const_fold.isConstFloat(v, decl.rhs)) .float else .none;
}

/// Mark the constants an initializer's operands name, so its own mark can read theirs.
/// One met again while it is being marked closes a cycle, reported when it is checked.
fn markRefs(t: *Typecheck, state: []State, m: *const Typecheck.GraphCtx.ModuleCtx, node: Ast.Index) void {
    if (node == Ast.none) return;
    const n = m.tree.nodes[node.int()];
    switch (n.tag) {
        .identifier, .field_access => switch (m.resolutions[node.int()]) {
            .constant => |cid| markOne(t, state, cid),
            else => {},
        },
        .unary => markRefs(t, state, m, n.lhs),
        .binary => {
            markRefs(t, state, m, n.lhs);
            markRefs(t, state, m, n.rhs);
        },
        else => {},
    }
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

test "an initializer that does not fold, fit or bind is one coded error, and poison after it" {
    const C = @import("../diagnostics/codes.zig").Code;
    try Typecheck.expectDiagCodes("fn f() -> int { 1 }\nN :=: f()\nM :=: N + 1\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("struct P { x: int }\nN :=: P { x: 1 }\n", &.{C.T0083});
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
    try Typecheck.expectDiagCodes("N :=: when false { 1 } else { x := 2\n x }\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("N :=: when true { 1 } else { x := 2\n x }\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("fn ten() -> int { 10 }\nN :=: when true { 1 } else { ten() }\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn ten() -> int { 10 }\nN :=: when X { .A -> 1, .B(x) -> x + ten() }\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn ten() -> int { 10 }\nN :=: when X { .A -> 1, .B(x) if x > ten() -> x, _ -> 2 }\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn f() -> int {\n    when X { .A -> 1, .B(z) -> { L :=: z\n L } }\n}\n", &.{C.T0083});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn f(n: int) -> int {\n    when X { .A -> 1, .B(z) if z > n -> z, _ -> 5 }\n}\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn f(n: int) -> int {\n    when X { .A -> 1, .B(z) -> when z > n { z } else { 0 } }\n}\n", &.{C.T0085});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn f() -> int {\n    when X { .A -> 1, .B(z) -> when z > 1 { z } else { 0 } }\n}\n", &.{});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn f() -> int {\n    when X { .A -> 1, .B(z) if z > 1 -> z, _ -> 5 }\n}\n", &.{});
    try Typecheck.expectDiagCodes("enum E { A, B(int) }\nX: E =: .A\nfn f() -> int {\n    when X { .B(z) if z > 1 -> z, _ -> 5 }\n}\n", &.{});
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
