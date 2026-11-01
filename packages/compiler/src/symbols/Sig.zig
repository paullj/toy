//! A callee's identity-and-signature. A peer data module: types produces it,
//! the fingerprint folds it. Depends on `Sym` (for the symbol kind) and the
//! type checker's `Type`, not sideways on the link backend.

const Sym = @import("Sym.zig");
const types = @import("../types.zig");

/// A callee's identity-and-signature, folded into a caller's fingerprint so a
/// signature OR symbol-identity change (but not a body change) invalidates the
/// caller.
pub const Sig = struct {
    /// Load-bearing, not just decorative: folded into the fingerprint alongside
    /// the sig (see the `(b)` fold site in `query/Fingerprint.zig` for why a
    /// shadow/unshadow of an identical sig must still flip the caller's hash).
    kind: Sym.SymKind,
    /// BORROWED from the resolve fns table (`GraphResult.fns[i].name`); its
    /// lifetime is tied to the sibling resolve result. NEVER freed through a Sig.
    name: []const u8,
    params: []const types.Type,
    ret: types.Type,
    /// Bit i: `params[i]` is `mut`; a method's `self` is `params[0]`. Folded into callers'
    /// keys (#25), since it decides how each argument is passed.
    mut_mask: u64 = 0,
    /// A C variadic extern: a call's args past `params` are C varargs. Not folded: a call
    /// with no extra args passes them as a plain call does, and extra args already
    /// change the caller's own walk.
    variadic: bool = false,

    /// True when this sig is a generic template — some param is a bare `type_var`
    /// (flat generic) OR an `.app`/`.func` (a type-var hidden inside a container or fn
    /// param like `Vec[T]` / `fn(T) -> int`). After reify only a template keeps
    /// `.app`/`.func` params (reify rewrites every non-generic fn's composite params to a
    /// concrete `structT`), so such a param is a sound composite-free template signal.
    /// Gates the bare-inferred-call sites that must resolve to a reified INSTANCE, not
    /// the never-lowered template symbol.
    pub fn isGenericTemplate(sig: Sig) bool {
        for (sig.params) |p| if (p.isTypeVar() or p.isApp() or p.isFunc()) return true;
        return false;
    }

    /// `1 + max type_var ordinal` over the sig's params — the generic-param count
    /// `Infer.infer` needs when only the template's sig (not its `FnSym`) is on hand.
    /// Equals `generic_params.len` for any call that survived Pass C (every var of a
    /// surviving call is bound, hence appears in a value param).
    pub fn genericParamCount(sig: Sig) u32 {
        var m: u32 = 0;
        for (sig.params) |p| if (p.isTypeVar() and p.typeVarOrd() > m) {
            m = p.typeVarOrd();
        };
        return m + 1;
    }
};

/// The args of a call that bind `n_params` params: all of them, or, past a variadic
/// extern's params, only those before its C varargs. Null when the count does not fit.
/// The checker and the C callback table both pair args with params through this, so they
/// agree on which args are callbacks.
pub fn fixedArgs(comptime T: type, args: []const T, n_params: usize, variadic: bool) ?[]const T {
    if (args.len == n_params) return args;
    if (variadic and args.len > n_params) return args[0..n_params];
    return null;
}

test "a template whose only type var is inside a fn param is generic" {
    const Type = types.Type;
    const tmpl: Sig = .{ .kind = .user_fn, .name = "apply", .params = &.{ Type.func(0), Type.int }, .ret = Type.int };
    try @import("std").testing.expect(tmpl.isGenericTemplate());
    const plain: Sig = .{ .kind = .user_fn, .name = "keep", .params = &.{ Type.structT(3), Type.int }, .ret = Type.func(1) };
    try @import("std").testing.expect(!plain.isGenericTemplate());
}

test "fixedArgs drops a variadic call's extra args and rejects a count that does not fit" {
    const testing = @import("std").testing;
    const args = [_]u32{ 1, 2, 3 };
    try testing.expectEqualSlices(u32, &args, fixedArgs(u32, &args, 3, false).?);
    try testing.expectEqualSlices(u32, args[0..2], fixedArgs(u32, &args, 2, true).?);
    try testing.expectEqual(null, fixedArgs(u32, &args, 2, false));
    try testing.expectEqual(null, fixedArgs(u32, &args, 4, true));
}
