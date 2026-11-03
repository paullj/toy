//! Random runnable toy programs for the differential fuzzer (`fuzz_diff.zig`).
//!
//! Unlike the front-end generator in `fuzz.zig`, every program here must type-check,
//! terminate and be deterministic, so a difference between two builds of it is a
//! miscompile and not noise. The shapes aim at what a register allocator gets wrong:
//! many int, float and aggregate values live across calls and loops, calls with more
//! arguments than argument registers, `mut` parameters that alias the caller's locals,
//! struct arguments and returns on both sides of the 16-byte line, closures that write a
//! boxed capture, generic instances, bounded recursion, and Vec handles (GC roots) live
//! across allocating calls.
//!
//! Termination holds by construction: helper `fN` only calls helpers with a smaller N, a
//! closure body never calls anything but the generic leaves, `rec` counts a masked depth
//! down, and every loop runs a fresh counter that nothing else may assign or pass as a
//! `mut` argument. Divisors and shift amounts are masked into range. The checked `+`, `-`
//! and `*` stay in on purpose (rarely): their overflow panics are part of what both
//! builds must agree on.

const std = @import("std");

pub const Ty = enum { int, float, bool, s, l, h, vec, fnii };

const max_params = 12;
const max_helpers = 6;

const Param = struct { ty: Ty, mut: bool };

const Sig = struct {
    params: [max_params]Param = undefined,
    n_params: usize = 0,
    ret: Ty,

    fn slice(sig: *const Sig) []const Param {
        return sig.params[0..sig.n_params];
    }
};

/// `by_ref` marks a `mut` parameter, which a closure that escapes may not capture (T0052).
const Var = struct { id: u32, ty: Ty, ro: bool, by_ref: bool = false };

/// Writes one program for `seed` into `out`. The same seed always gives the same text.
pub fn generate(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seed: u64) error{OutOfMemory}!void {
    var prng = std.Random.DefaultPrng.init(seed);
    var g: Gen = .{ .gpa = gpa, .out = out, .rand = prng.random() };
    defer g.vars.deinit(gpa);
    try g.program();
}

const Gen = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rand: std.Random,
    vars: std.ArrayList(Var) = .empty,
    next_id: u32 = 0,
    sigs: [max_helpers]Sig = undefined,
    /// Helpers `f0 .. f(callable-1)` may be called from the code being generated.
    callable: usize = 0,
    /// Inside a closure or `rec`: no calls but the generic leaves, so nothing recurses.
    leaf: bool = false,
    in_lambda: bool = false,
    in_main: bool = false,
    indent: usize = 0,
    block_depth: usize = 0,
    expr_depth: usize = 0,
    budget: usize = 0,

    fn w(g: *Gen, s: []const u8) !void {
        try g.out.appendSlice(g.gpa, s);
    }

    fn p(g: *Gen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.gpa, fmt, args);
    }

    fn nl(g: *Gen) !void {
        try g.out.append(g.gpa, '\n');
        try g.out.appendNTimes(g.gpa, ' ', 4 * g.indent);
    }

    fn chance(g: *Gen, n: u32) bool {
        return g.rand.uintLessThan(u32, n) == 0;
    }

    fn program(g: *Gen) !void {
        try g.w(
            \\import std/io
            \\import std/vec
            \\
            \\struct S { a: int, b: float }
            \\struct L { a: int, b: int, c: float, d: int }
            \\struct H { v: Vec[int], n: int }
            \\
            \\fn id[T](x: T) -> T { x }
            \\
            \\fn pick[T](c: bool, a: T, b: T) -> T { if c { a } else { b } }
            \\
        );
        try g.rec();

        const helpers = g.rand.intRangeAtMost(usize, 0, max_helpers);
        for (0..helpers) |i| {
            g.sigs[i] = g.randomSig();
            g.callable = i;
            try g.helper(i);
        }
        g.callable = helpers;
        try g.main();
    }

    fn randomSig(g: *Gen) Sig {
        var sig: Sig = .{ .ret = switch (g.rand.uintLessThan(u8, 8)) {
            0, 1, 2 => .int,
            3, 4 => .float,
            5 => .s,
            6 => .l,
            else => .h,
        } };
        // Past eight of a class the arguments go on the stack.
        sig.n_params = if (g.chance(4)) g.rand.intRangeAtMost(usize, 9, max_params) else g.rand.intRangeAtMost(usize, 0, 5);
        for (sig.params[0..sig.n_params]) |*prm| {
            prm.ty = g.anyTy();
            prm.mut = switch (prm.ty) {
                .int, .float, .s, .l => g.chance(4),
                else => false,
            };
        }
        return sig;
    }

    fn anyTy(g: *Gen) Ty {
        return switch (g.rand.uintLessThan(u8, 12)) {
            0, 1, 2, 3 => .int,
            4, 5, 6 => .float,
            7 => .bool,
            8 => .s,
            9 => .l,
            10 => .h,
            else => if (g.chance(2)) .vec else .fnii,
        };
    }

    fn rec(g: *Gen) !void {
        g.vars.clearRetainingCapacity();
        g.leaf = true;
        defer g.leaf = false;
        const n = try g.declare(.int, true);
        const a = try g.declare(.int, false);
        const b = try g.declare(.float, false);
        try g.p("\nfn rec(v{d}: int, v{d}: int, v{d}: float) -> int {{", .{ n, a, b });
        g.indent = 1;
        try g.nl();
        try g.p("if v{d} <= 0 {{ return v{d} }}", .{ n, a });
        try g.nl();
        const t = g.fresh();
        try g.p("v{d} := ", .{t});
        try g.expr(.int);
        try g.addVar(t, .int, false);
        try g.nl();
        try g.p("return rec(v{d} - 1, ", .{n});
        try g.expr(.int);
        try g.w(", ");
        try g.expr(.float);
        try g.p(") +% v{d}", .{t});
        g.indent = 0;
        try g.w("\n}\n");
    }

    fn helper(g: *Gen, i: usize) !void {
        g.vars.clearRetainingCapacity();
        const sig = &g.sigs[i];
        try g.p("\nfn f{d}(", .{i});
        for (sig.slice(), 0..) |prm, k| {
            if (k > 0) try g.w(", ");
            const v = try g.declare(prm.ty, false);
            g.vars.items[g.vars.items.len - 1].by_ref = prm.mut;
            try g.p("{s}v{d}: {s}", .{ if (prm.mut) "mut " else "", v, tyName(prm.ty) });
        }
        try g.p(") -> {s} {{", .{tyName(sig.ret)});
        g.indent = 1;
        g.budget = g.rand.intRangeAtMost(usize, 1, 8);
        try g.body();
        try g.nl();
        try g.w("return ");
        try g.expr(sig.ret);
        try g.foldLocals(sig.ret);
        g.indent = 0;
        try g.w("\n}\n");
    }

    fn main(g: *Gen) !void {
        g.vars.clearRetainingCapacity();
        g.in_main = true;
        try g.w("\nfn main() -> int {");
        g.indent = 1;
        // One of each type up front, so a call always finds a place for a `mut` argument.
        for (std.enums.values(Ty)) |ty| try g.decl(ty);
        g.budget = g.rand.intRangeAtMost(usize, 6, 30);
        try g.body();
        // A wrong value only fails the fuzzer once it reaches stdout or the exit code.
        for (g.vars.items) |v| switch (v.ty) {
            .int, .float, .bool => {
                try g.nl();
                try g.p("io.println(v{d})", .{v.id});
            },
            else => {},
        };
        try g.nl();
        try g.w("return (");
        try g.expr(.int);
        try g.w(") & 255");
        g.indent = 0;
        try g.w("\n}\n");
    }

    fn body(g: *Gen) !void {
        while (g.budget > 0) {
            g.budget -= 1;
            try g.stmt();
        }
    }

    /// Fold every local of the result's type into it, so a helper's wrong local shows in
    /// what it returns.
    fn foldLocals(g: *Gen, ty: Ty) !void {
        const op: []const u8 = switch (ty) {
            .int => " ^ ",
            .float => " +. ",
            else => return,
        };
        for (g.vars.items) |v| if (v.ty == ty) try g.p("{s}v{d}", .{ op, v.id });
    }

    fn stmts(g: *Gen) error{OutOfMemory}!void {
        const n = g.rand.intRangeAtMost(usize, 1, 6);
        for (0..n) |_| {
            if (g.budget == 0) return;
            g.budget -= 1;
            try g.stmt();
        }
    }

    fn block(g: *Gen) !void {
        const mark = g.vars.items.len;
        g.indent += 1;
        g.block_depth += 1;
        try g.stmts();
        g.block_depth -= 1;
        g.indent -= 1;
        g.vars.shrinkRetainingCapacity(mark);
        try g.nl();
        try g.w("}");
    }

    fn stmt(g: *Gen) !void {
        const nested = g.block_depth < 3;
        switch (g.rand.uintLessThan(u8, 14)) {
            0, 1, 2 => try g.decl(g.anyTy()),
            3, 4 => try g.assign(),
            5 => try g.fieldStore(),
            6 => try g.print(),
            7 => if (nested) try g.ifStmt() else try g.decl(.int),
            8, 9 => if (nested) try g.loop() else try g.assign(),
            10 => try g.push(),
            11 => try g.closureDecl(),
            12 => try g.indexStore(),
            else => try g.decl(.int),
        }
    }

    fn decl(g: *Gen, ty: Ty) !void {
        try g.nl();
        const v = g.fresh();
        switch (ty) {
            .vec => {
                try g.p("v{d}: Vec[int] = ", .{v});
                try g.vecLit();
            },
            .fnii => {
                try g.p("v{d} := ", .{v});
                try g.lambda();
            },
            else => {
                try g.p("v{d} := ", .{v});
                try g.expr(ty);
            },
        }
        try g.addVar(v, ty, false);
    }

    fn assign(g: *Gen) !void {
        const ty: Ty = switch (g.rand.uintLessThan(u8, 6)) {
            0, 1, 2 => .int,
            3, 4 => .float,
            else => g.anyTy(),
        };
        const v = g.pickVar(ty, true) orelse return g.decl(ty);
        try g.nl();
        switch (ty) {
            .int => {
                const ops = [_][]const u8{ " = ", " +%= ", " -%= ", " *%= ", " ^= ", " |= ", " &= " };
                try g.p("v{d}{s}", .{ v, ops[g.rand.uintLessThan(usize, ops.len)] });
                try g.expr(.int);
            },
            .float => {
                const ops = [_][]const u8{ " = ", " +.= ", " -.= ", " *.= " };
                try g.p("v{d}{s}", .{ v, ops[g.rand.uintLessThan(usize, ops.len)] });
                try g.expr(.float);
            },
            .vec => {
                try g.p("v{d} = ", .{v});
                try g.vecLit();
            },
            .fnii => {
                try g.p("v{d} = ", .{v});
                try g.lambda();
            },
            else => {
                try g.p("v{d} = ", .{v});
                try g.expr(ty);
            },
        }
    }

    fn fieldStore(g: *Gen) !void {
        const ty: Ty = switch (g.rand.uintLessThan(u8, 3)) {
            0 => .s,
            1 => .l,
            else => .h,
        };
        const v = g.pickVar(ty, true) orelse return g.decl(ty);
        try g.nl();
        const place: struct { []const u8, Ty } = switch (ty) {
            .s => if (g.chance(2)) .{ "a", .int } else .{ "b", .float },
            .l => switch (g.rand.uintLessThan(u8, 4)) {
                0 => .{ "a", .int },
                1 => .{ "b", .int },
                2 => .{ "c", .float },
                else => .{ "d", .int },
            },
            else => .{ "n", .int },
        };
        try g.p("v{d}.{s} = ", .{ v, place[0] });
        try g.expr(place[1]);
    }

    fn print(g: *Gen) !void {
        try g.nl();
        try g.w("io.println(");
        switch (g.rand.uintLessThan(u8, 8)) {
            0, 1, 2 => try g.expr(.int),
            3, 4 => try g.expr(.float),
            5 => try g.expr(.bool),
            6 => try g.expr(if (g.chance(2)) .s else .l),
            else => {
                // Each to_string and concat allocates, so this is a GC safepoint with
                // the first operand's string live across the second's.
                try g.expr(.int);
                try g.w(".to_string().concat(");
                try g.expr(.float);
                try g.w(".to_string())");
            },
        }
        try g.w(")");
    }

    fn ifStmt(g: *Gen) !void {
        try g.nl();
        try g.w("if ");
        try g.expr(.bool);
        try g.w(" {");
        try g.block();
        if (g.chance(2)) {
            try g.w(" else {");
            try g.block();
        }
    }

    fn loop(g: *Gen) !void {
        try g.nl();
        const i = g.fresh();
        // Nested loops and loops in helpers that call helpers multiply, and --gc-stress
        // collects the whole heap on every allocation in them.
        const trips = if (g.block_depth == 0 and g.in_main) g.rand.intRangeAtMost(u32, 1, 8) else g.rand.intRangeAtMost(u32, 1, 3);
        try g.p("v{d} := 0", .{i});
        try g.nl();
        try g.p("while v{d} < {d} {{", .{ i, trips });
        const mark = g.vars.items.len;
        try g.addVar(i, .int, true);
        g.indent += 1;
        g.block_depth += 1;
        try g.stmts();
        try g.nl();
        try g.p("v{d} += 1", .{i});
        g.block_depth -= 1;
        g.indent -= 1;
        g.vars.shrinkRetainingCapacity(mark);
        try g.nl();
        try g.w("}");
    }

    fn push(g: *Gen) !void {
        if (g.pickVar(.vec, false)) |v| {
            try g.nl();
            try g.p("v{d}.push(", .{v});
        } else if (g.pickVar(.h, false)) |v| {
            try g.nl();
            try g.p("v{d}.v.push(", .{v});
        } else return g.decl(.vec);
        try g.expr(.int);
        try g.w(")");
    }

    fn indexStore(g: *Gen) !void {
        const v = g.pickVar(.vec, false) orelse return g.decl(.vec);
        try g.nl();
        try g.p("if v{d}.len() > 0 {{ v{d}[", .{ v, v });
        try g.index(v);
        try g.w("] = ");
        try g.expr(.int);
        try g.w(" }");
    }

    fn closureDecl(g: *Gen) !void {
        try g.nl();
        const c = g.fresh();
        try g.p("v{d} := ", .{c});
        try g.lambda();
        try g.addVar(c, .fnii, false);
    }

    /// A `fn(int) -> int` literal. Writing a captured local boxes it, so the owner and
    /// the closure share it through the heap.
    fn lambda(g: *Gen) !void {
        const was_leaf = g.leaf;
        const was_lambda = g.in_lambda;
        g.leaf = true;
        g.in_lambda = true;
        defer {
            g.leaf = was_leaf;
            g.in_lambda = was_lambda;
        }
        const mark = g.vars.items.len;
        defer g.vars.shrinkRetainingCapacity(mark);
        const prm = g.fresh();
        try g.p("fn(v{d}: int) -> int {{", .{prm});
        try g.addVar(prm, .int, false);
        g.indent += 1;
        if (g.chance(2)) {
            if (g.pickVar(.int, true)) |cap| {
                try g.nl();
                try g.p("v{d} = v{d} +% ", .{ cap, cap });
                try g.expr(.int);
            }
        }
        try g.nl();
        try g.expr(.int);
        g.indent -= 1;
        try g.nl();
        try g.w("}");
    }

    fn vecLit(g: *Gen) !void {
        try g.w("[");
        const n = g.rand.uintLessThan(usize, 4);
        for (0..n) |k| {
            if (k > 0) try g.w(", ");
            try g.expr(.int);
        }
        try g.w("]");
    }

    fn index(g: *Gen, v: u32) !void {
        try g.w("(");
        try g.expr(.int);
        try g.p(" & 1023) % v{d}.len()", .{v});
    }

    fn expr(g: *Gen, ty: Ty) error{OutOfMemory}!void {
        g.expr_depth += 1;
        defer g.expr_depth -= 1;
        if (g.expr_depth > 4 or g.chance(3)) return g.atom(ty);
        switch (ty) {
            .int => try g.intExpr(),
            .float => try g.floatExpr(),
            .bool => try g.boolExpr(),
            .s, .l, .h => try g.aggExpr(ty),
            .vec, .fnii => try g.atom(ty),
        }
    }

    fn intExpr(g: *Gen) !void {
        switch (g.rand.uintLessThan(u8, 16)) {
            0, 1, 2 => try g.bin(.int, &.{ " +% ", " -% ", " *% ", " & ", " | ", " ^ " }),
            // A checked operator on two constants overflows when it is compiled (T0034),
            // so one operand is a local.
            3 => if (g.pickVar(.int, false)) |v| {
                const ops = [_][]const u8{ " + ", " - ", " * " };
                try g.p("(v{d}{s}", .{ v, ops[g.rand.uintLessThan(usize, ops.len)] });
                try g.expr(.int);
                try g.w(")");
            } else try g.atom(.int),
            4 => {
                try g.w("(");
                try g.expr(.int);
                try g.w(if (g.chance(2)) " / ((" else " % ((");
                try g.expr(.int);
                try g.w(" & 15) + 1))");
            },
            5 => {
                try g.w("(");
                try g.expr(.int);
                try g.w(if (g.chance(2)) " << (" else " >> (");
                try g.expr(.int);
                try g.w(" & 63))");
            },
            6 => try g.ifExpr(.int),
            7, 8 => if (!g.leaf and try g.call(.int)) {} else try g.atom(.int),
            9 => if (!g.leaf) {
                try g.w("rec((");
                try g.expr(.int);
                try g.w(") & 31, ");
                try g.expr(.int);
                try g.w(", ");
                try g.expr(.float);
                try g.w(")");
            } else try g.atom(.int),
            10 => if (!g.leaf and g.pickVar(.fnii, false) != null) {
                try g.p("v{d}(", .{g.pickVar(.fnii, false).?});
                try g.expr(.int);
                try g.w(")");
            } else try g.atom(.int),
            11 => if (g.pickVar(.vec, false)) |v| {
                try g.p("(if v{d}.len() > 0 {{ v{d}[", .{ v, v });
                try g.index(v);
                try g.w("] } else { ");
                try g.expr(.int);
                try g.w(" })");
            } else try g.atom(.int),
            12 => try g.generic(.int),
            13 => try g.field(.int),
            else => try g.atom(.int),
        }
    }

    fn floatExpr(g: *Gen) !void {
        switch (g.rand.uintLessThan(u8, 10)) {
            0, 1, 2, 3 => try g.bin(.float, &.{ " +. ", " -. ", " *. ", " /. " }),
            4 => try g.ifExpr(.float),
            5, 6 => if (!g.leaf and try g.call(.float)) {} else try g.atom(.float),
            7 => try g.generic(.float),
            8 => try g.field(.float),
            else => try g.atom(.float),
        }
    }

    fn boolExpr(g: *Gen) !void {
        switch (g.rand.uintLessThan(u8, 8)) {
            0, 1 => try g.cmp(.int, &.{ " < ", " <= ", " > ", " >= ", " == ", " != " }),
            2 => try g.cmp(.float, &.{ " <. ", " <=. ", " >. ", " >=. ", " == " }),
            3 => try g.bin(.bool, &.{ " && ", " || " }),
            4 => {
                try g.w("!(");
                try g.expr(.bool);
                try g.w(")");
            },
            5 => try g.generic(.bool),
            else => try g.atom(.bool),
        }
    }

    fn aggExpr(g: *Gen, ty: Ty) !void {
        switch (g.rand.uintLessThan(u8, 4)) {
            0 => if (!g.leaf and try g.call(ty)) {} else try g.atom(ty),
            1 => try g.generic(ty),
            2 => try g.ifExpr(ty),
            else => try g.atom(ty),
        }
    }

    fn bin(g: *Gen, ty: Ty, ops: []const []const u8) !void {
        try g.w("(");
        try g.expr(ty);
        try g.w(ops[g.rand.uintLessThan(usize, ops.len)]);
        try g.expr(ty);
        try g.w(")");
    }

    fn cmp(g: *Gen, ty: Ty, ops: []const []const u8) !void {
        try g.w("(");
        try g.expr(ty);
        try g.w(ops[g.rand.uintLessThan(usize, ops.len)]);
        try g.expr(ty);
        try g.w(")");
    }

    fn ifExpr(g: *Gen, ty: Ty) !void {
        try g.w("(if ");
        try g.expr(.bool);
        try g.w(" { ");
        try g.expr(ty);
        try g.w(" } else { ");
        try g.expr(ty);
        try g.w(" })");
    }

    fn generic(g: *Gen, ty: Ty) !void {
        if (g.chance(2)) {
            try g.w("id(");
            try g.expr(ty);
        } else {
            try g.w("pick(");
            try g.expr(.bool);
            try g.w(", ");
            try g.expr(ty);
            try g.w(", ");
            try g.expr(ty);
        }
        try g.w(")");
    }

    fn field(g: *Gen, ty: Ty) !void {
        const owner: Ty = switch (g.rand.uintLessThan(u8, 3)) {
            0 => .s,
            1 => .l,
            else => .h,
        };
        const v = g.pickVar(owner, false) orelse return g.atom(ty);
        const name: []const u8 = switch (owner) {
            .s => if (ty == .int) "a" else "b",
            .l => if (ty == .float) "c" else switch (g.rand.uintLessThan(u8, 3)) {
                0 => "a",
                1 => "b",
                else => "d",
            },
            else => if (ty == .float) return g.atom(ty) else if (g.chance(2)) "n" else "v.len()",
        };
        try g.p("v{d}.{s}", .{ v, name });
    }

    /// A call of a helper that returns `ty`, or false when no helper fits. A `mut`
    /// argument must be a local the callee may write, so never a loop counter.
    fn call(g: *Gen, ty: Ty) !bool {
        var fits: [max_helpers]usize = undefined;
        var n: usize = 0;
        for (g.sigs[0..g.callable], 0..) |*sig, i| {
            if (sig.ret != ty) continue;
            for (sig.slice()) |prm| {
                if (prm.mut and g.pickVar(prm.ty, true) == null) break;
            } else {
                fits[n] = i;
                n += 1;
            }
        }
        if (n == 0) return false;
        const f = fits[g.rand.uintLessThan(usize, n)];
        try g.p("f{d}(", .{f});
        for (g.sigs[f].slice(), 0..) |prm, k| {
            if (k > 0) try g.w(", ");
            if (prm.mut) {
                try g.p("v{d}", .{g.pickVar(prm.ty, true).?});
            } else try g.arg(prm.ty);
        }
        try g.w(")");
        return true;
    }

    fn arg(g: *Gen, ty: Ty) !void {
        switch (ty) {
            .vec => if (g.pickVar(.vec, false) != null and !g.chance(4)) try g.atom(.vec) else try g.vecLit(),
            .fnii => if (g.pickVar(.fnii, false) != null and !g.chance(4)) try g.atom(.fnii) else try g.lambda(),
            else => try g.expr(ty),
        }
    }

    fn atom(g: *Gen, ty: Ty) error{OutOfMemory}!void {
        if (!g.chance(3)) if (g.pickVar(ty, false)) |v| return g.p("v{d}", .{v});
        switch (ty) {
            .int => try g.intLit(),
            .float => try g.floatLit(),
            .bool => try g.w(if (g.chance(2)) "true" else "false"),
            .s => {
                try g.w("S { a: ");
                try g.expr(.int);
                try g.w(", b: ");
                try g.expr(.float);
                try g.w(" }");
            },
            .l => {
                try g.w("L { a: ");
                try g.expr(.int);
                try g.w(", b: ");
                try g.expr(.int);
                try g.w(", c: ");
                try g.expr(.float);
                try g.w(", d: ");
                try g.expr(.int);
                try g.w(" }");
            },
            .h => {
                try g.w("H { v: ");
                try g.vecLit();
                try g.w(", n: ");
                try g.expr(.int);
                try g.w(" }");
            },
            .vec => if (g.pickVar(.h, false)) |v| try g.p("v{d}.v", .{v}) else try g.vecLit(),
            .fnii => try g.lambda(),
        }
    }

    fn intLit(g: *Gen) !void {
        switch (g.rand.uintLessThan(u8, 10)) {
            0 => try g.p("(-{d})", .{g.rand.uintLessThan(u32, 100)}),
            1 => {
                const big = [_][]const u8{ "9223372036854775807", "(-9223372036854775808)", "4611686018427387904", "4294967296" };
                try g.w(big[g.rand.uintLessThan(usize, big.len)]);
            },
            else => try g.p("{d}", .{g.rand.uintLessThan(u32, 100)}),
        }
    }

    fn floatLit(g: *Gen) !void {
        switch (g.rand.uintLessThan(u8, 10)) {
            0 => try g.w("(0.0 -. 1.5)"),
            1 => try g.w(if (g.chance(2)) "1.0e300" else "5.0e-324"),
            else => try g.p("{d}.{d}", .{ g.rand.uintLessThan(u32, 100), g.rand.uintLessThan(u32, 100) }),
        }
    }

    fn fresh(g: *Gen) u32 {
        defer g.next_id += 1;
        return g.next_id;
    }

    fn declare(g: *Gen, ty: Ty, ro: bool) !u32 {
        const v = g.fresh();
        try g.addVar(v, ty, ro);
        return v;
    }

    fn addVar(g: *Gen, id: u32, ty: Ty, ro: bool) !void {
        try g.vars.append(g.gpa, .{ .id = id, .ty = ty, .ro = ro });
    }

    fn pickVar(g: *Gen, ty: Ty, writable: bool) ?u32 {
        var n: usize = 0;
        for (g.vars.items) |v| {
            if (g.usable(v, ty, writable)) n += 1;
        }
        if (n == 0) return null;
        var k = g.rand.uintLessThan(usize, n);
        for (g.vars.items) |v| {
            if (!g.usable(v, ty, writable)) continue;
            if (k == 0) return v.id;
            k -= 1;
        }
        unreachable;
    }

    fn usable(g: *const Gen, v: Var, ty: Ty, writable: bool) bool {
        return v.ty == ty and !(writable and v.ro) and !(g.in_lambda and v.by_ref);
    }
};

fn tyName(ty: Ty) []const u8 {
    return switch (ty) {
        .int => "int",
        .float => "float",
        .bool => "bool",
        .s => "S",
        .l => "L",
        .h => "H",
        .vec => "Vec[int]",
        .fnii => "fn(int) -> int",
    };
}

test "the same seed gives the same program" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    for (0..50) |seed| {
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        try generate(gpa, &a, seed);
        try generate(gpa, &b, seed);
        try std.testing.expectEqualStrings(a.items, b.items);
    }
}
