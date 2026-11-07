//! The incremental query engine: one testable seam that owns the on-disk memo
//! (`Cache`) and the uniform `query(key, compute) -> result` entry. Lifts the
//! distributed query/cache/fingerprint/force-verify/parallel logic out of the
//! driver and into this module; the driver becomes a thin orchestrator that
//! sequences phases and demands each unit through here.
//!
//! This is a BEHAVIOR-PRESERVING refactor: each query is still pull-computed or
//! served from the on-disk content-addressed cache exactly as before. The cache
//! stays the SOLE memo (lock-free atomic-rename writers, determinism); no
//! shared mutable in-memory map is introduced — each unit is computed once per
//! build, so a map would only race for zero gain.
//!
//! Scaffold stage: the engine owns the borrowed `Cache` + the build `Mode`, and
//! exposes the generic `query` entry plus the `lex` front-end helper as the first
//! query routed through it. Later stages fold codegen / force-verify / parallel
//! fan-out in behind the same seam.

const std = @import("std");
const Io = std.Io;
const Token = @import("../ast/Token.zig").Token;
const Lexer = @import("../lex.zig");
const Cache = @import("Cache.zig");
const Key = @import("Key.zig");
const CodegenMir = @import("../codegen/CodegenMir.zig");
const Diagnostic = @import("../diagnostics/Diagnostic.zig").Diagnostic;
const FrameLayout = @import("../codegen/frame/FrameLayout.zig");
const Ast = @import("../ast/Ast.zig");
const Fingerprint = @import("Fingerprint.zig");
const AstWalk = @import("AstWalk.zig");
const Walk = @import("../ast/Walk.zig");
const Link = @import("../link/Link.zig");
const Ir = @import("../ir/Ir.zig");
const Opt = @import("../opt/Opt.zig");
const Profile = @import("../driver/Profile.zig");
const lower = @import("../lower.zig");
const DeriveEmit = @import("../lower/derive_emit.zig");
const AdapterEmit = @import("../lower/adapter_emit.zig");
const LowerClosure = @import("../lower/closure.zig");
const Closure = @import("../symbols/Closure.zig");
const Mono = @import("../symbols/Mono.zig");
const Derive = @import("../symbols/Derive.zig");
const StdNames = @import("../symbols/StdNames.zig");
const Typecheck = @import("../types.zig");
const Phase = @import("Phase.zig");
const InlineUnits = @import("InlineUnits.zig");

const Engine = @This();

/// How force/verify behave for cached queries (threaded from `main.zig`), the
/// cache/verify policy this engine owns and the verify gate enforces:
///   normal — use a cached blob if present, else lower+cache.
///   force  — ignore cache, always re-lower (cold build).
///   verify — re-lower every fn TWICE and assert byte-identity,
///            independent of cache state. Implies force (the gate must hold on
///            a cold build, not only on a primed cache hit).
pub const Mode = enum { normal, force, verify };

/// The on-disk content-addressed memo. Borrowed; must outlive the engine (the CLI
/// keeps the cache + its dir buffer on its stack for the whole run).
cache: Cache,

/// force/verify mode for cached compute queries. Front-end queries (lex/parse)
/// ignore it — they are pure source-hash lookups with no re-lower gate.
mode: Mode = .normal,

/// `--timings` per-stage compute/cache probe (see `StageProbe`). BORROWED; null on a
/// plain build so the query path reads no clock. EVERY cache-backed query — `lex` and
/// `parse` (the `discover` stage) and `codegen` (the `lower` stage) — charges the
/// engine's probe, so each stage attributes compute vs cache-get vs cache-put. A
/// different probe instance is threaded per stage (discover's vs lower's), so the two
/// don't co-mingle even though both run through this one field.
probe: ?*StageProbe = null,

pub const StageProbe = @import("StageProbe.zig");

/// The original name of `StageProbe`, kept so call sites that wired the lower-only
/// probe keep compiling. The probe is stage-agnostic (three compute/get/put buckets),
/// so the generalized name is `StageProbe`; this alias is the lower stage's view of it.
pub const LowerProbe = StageProbe;

pub fn init(cache: Cache, mode: Mode) Engine {
    return .{ .cache = cache, .mode = mode };
}

/// Like `init` but also threads a borrowed `--timings` sub-stage probe.
pub fn initProbe(cache: Cache, mode: Mode, probe: ?*LowerProbe) Engine {
    return .{ .cache = cache, .mode = mode, .probe = probe };
}

/// The result of a single query: the value plus whether it was served from the
/// on-disk cache (vs freshly computed). `cached` preserves the per-phase
/// `*_cached` bookkeeping the driver reports.
pub fn Result(comptime T: type) type {
    return struct { value: []T, cached: bool };
}

/// The uniform demand entry: serve `key` from the cache, else run `compute` and
/// store the result. `compute` returns a freshly allocated `[]T` the caller owns
/// on a miss; on a hit the cached slice is returned (also caller-owned).
///
/// `tmp_tag` must be unique among concurrent writers (the file/fn index) so temp
/// files never collide on store. `swallow_put` mirrors the front-end's policy of
/// treating a cache-write failure as non-fatal (`cache.put(...) catch {}`): a
/// failed store just means the next build re-runs the query. `get` errors always
/// propagate.
pub fn query(
    self: Engine,
    comptime T: type,
    gpa: std.mem.Allocator,
    io: Io,
    key: Cache.Key,
    tmp_tag: usize,
    comptime swallow_get: bool,
    comptime swallow_put: bool,
    compute: anytype,
) !Result(T) {
    // get->compute->put, with the `--timings` probe laps gated on `self.probe != null`
    // so a plain build reads no clock (matching the codegen path's discipline).
    const get_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
    const hit: ?[]T = if (swallow_get) (self.cache.get(T, gpa, io, key) catch null) else (try self.cache.get(T, gpa, io, key));
    if (self.probe) |p| StageProbe.lap(io, &p.get_ns, get_t0);
    if (hit) |h| {
        return .{ .value = h, .cached = true };
    }
    const comp_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
    const fresh = try compute.run();
    if (self.probe) |p| StageProbe.lap(io, &p.compute_ns, comp_t0);
    const put_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
    if (swallow_put) {
        self.cache.put(T, io, key, tmp_tag, fresh) catch {};
    } else {
        try self.cache.put(T, io, key, tmp_tag, fresh);
    }
    if (self.probe) |p| StageProbe.lap(io, &p.put_ns, put_t0);
    return .{ .value = fresh, .cached = false };
}

/// lex query: tokenize `source` for `target`, served from
/// cache or freshly lexed. Preserves the pipeline's policy: `get` propagates,
/// `put` is swallowed, `tmp_tag` is the caller's file index.
pub fn lex(
    self: Engine,
    gpa: std.mem.Allocator,
    io: Io,
    target: []const u8,
    source: []const u8,
    tmp_tag: usize,
    comptime swallow_get: bool,
) !Result(Token) {
    const LexCompute = struct {
        gpa: std.mem.Allocator,
        source: []const u8,
        fn run(c: @This()) ![]Token {
            return Lexer.tokenize(c.gpa, c.source);
        }
    };
    return self.query(Token, gpa, io, Key.lex(target, source), tmp_tag, swallow_get, true, LexCompute{
        .gpa = gpa,
        .source = source,
    });
}

/// The parse query: serve the file's `Ast.Tree` from cache or freshly parse. The
/// parse artifact is a flat `[]u8` blob (`Ast.pack`/`unpack`); a hit must be
/// VALIDATED by `Ast.unpack`, which treats a corrupt/foreign blob as a miss (so
/// the query re-parses rather than trusting a bad blob). Unlike the generic
/// `query`, parse cannot use the raw memo path because of this unpack validation.
///
/// `swallow_get` selects the caller's read policy: the per-file pipeline propagates
/// `get`/`unpack` errors (`false`), while module-graph discovery swallows them and
/// treats a failed read as a plain miss (`true`). `put` is always swallowed (a
/// failed store just means the next build re-parses).
///
/// The parser now ALWAYS produces a tree, so `tree` is non-optional. A TAINTED
/// parse (any accumulated diagnostic) sets `diags` non-empty; the caller must not
/// proceed to codegen and reports every diagnostic. The cache PUT is gated on
/// `diags.len == 0`, so a poisoned partial tree never becomes a cached "good"
/// parse. `diags` is owned by the caller (freed via `gpa.free`); a cache HIT (a
/// clean parse, never tainted) yields an empty `diags`.
pub const ParseResult = struct {
    tree: Ast.Tree,
    cached: bool = false,
    diags: []const @import("../parse.zig").Diagnostic = &.{},
};

pub fn parse(
    self: Engine,
    gpa: std.mem.Allocator,
    io: Io,
    target: []const u8,
    source: []const u8,
    tokens: []const Token,
    tmp_tag: usize,
    comptime swallow_get: bool,
) !ParseResult {
    const Parser = @import("../parse.zig");
    const cache = self.cache;
    const key = Key.parse(target, source);

    // `--timings`: the read+unpack-validate is the GET cost; gated on `self.probe`
    // so a plain build reads no clock (the codegen-probe discipline).
    const get_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
    const blob: ?[]u8 = if (swallow_get) (cache.get(u8, gpa, io, key) catch null) else (try cache.get(u8, gpa, io, key));
    if (blob) |bytes| {
        defer gpa.free(bytes);
        const unpacked: ?Ast.Tree = if (swallow_get) (Ast.unpack(gpa, bytes) catch null) else (try Ast.unpack(gpa, bytes));
        if (unpacked) |t| {
            if (self.probe) |p| StageProbe.lap(io, &p.get_ns, get_t0);
            return .{ .tree = t, .cached = true };
        }
    }
    if (self.probe) |p| StageProbe.lap(io, &p.get_ns, get_t0);

    const comp_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
    const res = try Parser.parse(gpa, tokens, source);
    if (self.probe) |p| StageProbe.lap(io, &p.compute_ns, comp_t0);
    // Gate the cache PUT on a clean parse: a tainted (diagnostic-bearing) partial
    // tree must never become a cached "good" parse — the next build would serve it
    // as a hit and skip the diagnostics. A clean parse caches as before.
    if (res.diags.len == 0) {
        if (Ast.pack(gpa, res.tree) catch null) |b| {
            defer gpa.free(b);
            const put_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
            cache.put(u8, io, key, tmp_tag, b) catch {};
            if (self.probe) |p| StageProbe.lap(io, &p.put_ns, put_t0);
        }
    }
    return .{ .tree = res.tree, .cached = false, .diags = res.diags };
}

/// The parallel fan-out COORDINATOR: dispatch `n` jobs onto the `Io` runtime's
/// worker threads, then await them. Lifts the `concurrent(...) catch <inline>`
/// pattern used identically by the per-file front-end and the per-fn codegen
/// (single-file + graph). Each job writes ONLY its own caller-owned slot, so no
/// locks are taken; the inline fallback (when the runtime can't provide true
/// concurrency) is LOAD-BEARING for single-threaded determinism and is preserved
/// verbatim.
///
/// `jobFn` is the per-unit work function; `ctx.args(i)` returns the exact
/// `ArgsTuple` for job `i` (including its slot pointer and its `tmp_tag` index).
/// Determinism is unaffected: jobs are independent and order-free, and the
/// caller's collect loop reads slots in deterministic index order afterward.
pub fn fanOut(io: Io, n: usize, comptime jobFn: anytype, ctx: anytype) void {
    var group: Io.Group = .init;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const args = ctx.args(i);
        group.concurrent(io, jobFn, args) catch @call(.auto, jobFn, args);
    }
    group.await(io) catch {};
}

/// PER-STAGE chunking heuristics for `chunkedFanOut`, tuned by the work-per-unit of
/// each fan-out site. `threshold` = stay serial at or below this unit
/// count (chunking would cost more than it saves); `chunks_per_cpu` = how many ranges
/// per cpu (more = finer ranges = better load-balance when unit cost varies, at a few
/// more enqueues). The ratio "per-unit work vs per-task overhead" sets both: the
/// tinier the unit, the LOWER the threshold has to be to ever activate on real
/// programs, and a slightly higher chunk count keeps any one fat range from stalling.
pub const Chunk = struct {
    /// Per-fn body type-check (`types.checkBodies`): the TINIEST unit (~0.05-0.5ms, an
    /// AST walk), so the worst overhead ratio — chunk aggressively. Low threshold so a
    /// few-hundred-fn program already benefits; 8 ranges/cpu to even out fat bodies.
    pub const body = .{ .threshold = 64, .chunks_per_cpu = 8 };
    /// Per-fn codegen lower (`Driver.lowerGraphProgram`): more work/unit than body
    /// (~1-5ms cold; a warm cache hit is ~0.02ms = back to tiny, so still chunk). 8
    /// ranges/cpu because a warm/cold MIX makes per-unit cost highly uneven.
    pub const codegen = .{ .threshold = 64, .chunks_per_cpu = 8 };
    /// Per-fn link copy+call26 patch (`Link.link`): ~0.01-0.1ms/fn, one memcpy + a few
    /// reloc patches. 4 ranges/cpu — units are uniform (no cache mix) so coarse is fine.
    pub const fn_link = .{ .threshold = 128, .chunks_per_cpu = 4 };
    /// Per-fn cstring-reloc rewrite (`emit.rewriteCstr`): ~0.001-0.01ms/fn, by-key map
    /// lookups only. Tiny + uniform; chunk only on big programs, coarse ranges.
    pub const cstr = .{ .threshold = 256, .chunks_per_cpu = 4 };
    /// Per-reloc data-reloc patch (`Link.applyDataRelocs`) and per-page code-sign hash
    /// (`CodeSign`): small unit COUNT (relocs/pages), not 10K, so contention is already
    /// bounded. High threshold leaves them serial except on the largest images.
    pub const small_count = .{ .threshold = 256, .chunks_per_cpu = 2 };
};

/// The host CPU count, the default chunk-count basis when a caller passes no `-j`
/// hint (`ncpu_hint == 0`). It is the runtime knob — NOT a hardcoded constant — and
/// over-providing chunks vs. the real pool size is harmless: surplus ranges queue on
/// the pool and run as workers free up, and at `-j1` (`.limited(0)`) every range
/// takes the inline serial path regardless of count, so byte-identity is unaffected.
pub fn hostCpus() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// The worker pool for `threads` jobs (0 => `hostCpus()`). One job gets `.limited(0)`,
/// which runs every fan-out inline: the serial byte-identity baseline. Any other count
/// caps the pool, because an `.unlimited` pool spawns one thread per fan-out chunk (8
/// per cpu), and the surplus threads then contend on the allocator and the shared
/// tables (#104).
pub fn pool(gpa: std.mem.Allocator, threads: usize) std.Io.Threaded {
    const n = if (threads != 0) threads else hostCpus();
    return .init(gpa, .{ .concurrent_limit = if (n <= 1) .limited(0) else .limited(n) });
}

/// CHUNKED parallel fan-out: the primitive that makes `-jN` actually scale.
///
/// `Engine.fanOut` dispatches ONE task per unit; with 10K µs-scale units that is 10K
/// `group.concurrent` enqueues on the main thread plus 10K completion atomics, and the
/// per-task overhead (enqueue lock + worker dequeue + completion signal, all on shared
/// cache lines) swamps the work — so `-jN` ends up SLOWER than `-j1`, worse with more
/// cores. This splits `[0,n)` into ~`ncpu` CONTIGUOUS ranges and dispatches ONE task
/// per range; each range loops its units SERIALLY. Dispatch count drops from `n` to
/// ~`ncpu`, the shared-atomic traffic with it, so contention stops and it scales.
///
/// `threshold`: below it, run every unit inline on this thread (no dispatch) — the
/// verbatim serial path for small programs where chunking would only add overhead.
/// `chunks_per_cpu`: ranges = `min(n, ncpu * chunks_per_cpu)`; >1 gives the pool more,
/// smaller ranges so an uneven unit-cost distribution still load-balances (static
/// ranges, no work-stealing). `ncpu_hint`: the `-j` jobs knob; `0` => `hostCpus()`.
///
/// DETERMINISM: ranges own DISJOINT unit spans (range r writes only units
/// `start..end`); there is NO shared mutable state across ranges, and each range calls
/// the SAME `jobFn(ctx.args(i))` the per-unit `fanOut` would, in ascending `i`. The
/// caller still reads its slots back in unit-index order, so the merged result is
/// byte-identical to `-j1` regardless of range count or thread-arrival order. The
/// inline fallback (when `group.concurrent` can't provide concurrency, e.g. `-j1`'s
/// `.limited(0)`) runs the ranges in order on this thread = a plain serial loop over
/// all `n` units, the exact serial baseline.
pub fn chunkedFanOut(
    io: Io,
    n: usize,
    ncpu_hint: usize,
    threshold: usize,
    chunks_per_cpu: usize,
    comptime jobFn: anytype,
    ctx: anytype,
) void {
    if (n == 0) return;
    // Small `n`: the serial path. Chunking here only pays dispatch overhead for work
    // that is already a rounding error, and it keeps tiny programs byte-for-byte on
    // the same code path `-j1` takes.
    if (n <= threshold) {
        var i: usize = 0;
        while (i < n) : (i += 1) @call(.auto, jobFn, ctx.args(i));
        return;
    }

    const ncpu = if (ncpu_hint != 0) ncpu_hint else hostCpus();
    const target_chunks = @max(@as(usize, 1), ncpu * @max(@as(usize, 1), chunks_per_cpu));
    const nchunks = @min(n, target_chunks);

    // One task per CONTIGUOUS range; each runs its units serially. The range job
    // closes over the user's `ctx`/`jobFn` and the `[start,end)` it owns. Args is a
    // 3-tuple `{ctx, start, end}` — ONE enqueue per range, not per unit.
    const RangeJob = struct {
        fn run(c: @TypeOf(ctx), start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) @call(.auto, jobFn, c.args(i));
        }
    };

    var group: Io.Group = .init;
    // Balanced split: the first `rem` ranges get one extra unit so every unit is
    // covered with at most a 1-unit imbalance (no padding, no leftover tail).
    const base = n / nchunks;
    const rem = n % nchunks;
    var start: usize = 0;
    var c: usize = 0;
    while (c < nchunks) : (c += 1) {
        const len = base + @as(usize, if (c < rem) 1 else 0);
        const end = start + len;
        group.concurrent(io, RangeJob.run, .{ ctx, start, end }) catch RangeJob.run(ctx, start, end);
        start = end;
    }
    group.await(io) catch {};
}

/// A DETERMINISTIC, ORDER-INDEPENDENT fold of a contributor multiset into one u64 —
/// the aggregate identity of a fan-in BARRIER (e.g. "the global tables built from all
/// module parse-result digests"). Each contributor is Wyhash'd, the per-element hashes
/// are SUMMED (commutative => the fold is identical regardless of contributor order or
/// the thread-arrival order that produced them), then a final Wyhash mix breaks the
/// linearity of a raw sum. Summing (not XOR) so duplicate contributors do not cancel.
/// This is the set-fold the two-region scheduler's BARRIER nodes are keyed by; its
/// order-independence is what keeps -j1 and -jN byte-identical across a barrier.
pub fn aggKey(contributors: []const u64) u64 {
    var acc: u64 = 0;
    for (contributors) |c| {
        acc +%= std.hash.Wyhash.hash(0x42_41_52_52, std.mem.asBytes(&c)); // "BARR"
    }
    return std.hash.Wyhash.hash(0x46_4f_4c_44, std.mem.asBytes(&acc)); // "FOLD"
}

/// The result of an `Engine.barrier`: the compute's aggregate `value` plus the
/// order-independent `fold` of the contributors that fed it (the barrier node's id).
pub fn BarrierResult(comptime T: type) type {
    return struct { value: T, fold: u64 };
}

/// The success payload `T` of a barrier `compute`'s `pub fn run(self) error{...}!T`.
/// Used in the `barrier` return type, where `try` is illegal (it is outside function
/// scope there); resolved via the call's type (`@TypeOf` never executes it).
fn ComputePayload(comptime Compute: type) type {
    const ret = @TypeOf(@as(Compute, undefined).run());
    return @typeInfo(ret).error_union.payload;
}

/// The fan-IN seam: a JOIN between two fan-out regions. Folds `contributors` (the
/// upstream region's per-unit result digests) into one order-independent barrier id
/// and runs `compute` ONCE to build the aggregate the downstream region depends on.
/// The aggregate is a build-local value, never an on-disk artifact (barriers are
/// joins, not cacheable units), so nothing is cached.
///
/// This is the seam the StageGraph interpreter calls at each BARRIER transition;
/// `kind` is the stage's `Phase.Kind` (carried for `--timings` attribution).
/// `compute` is `anytype` with a `pub fn run(self) !T` method (it crosses the module
/// boundary into here, so `run` must be `pub` — unlike `query`'s same-file computes).
pub fn barrier(
    self: Engine,
    gpa: std.mem.Allocator,
    kind: Phase.Kind,
    contributors: []const u64,
    compute: anytype,
) !BarrierResult(ComputePayload(@TypeOf(compute))) {
    _ = self;
    _ = gpa;
    _ = kind;
    const fold = aggKey(contributors);
    const value = try compute.run();
    return .{ .value = value, .fold = fold };
}

/// Dual-metric output of a fresh lowering: the summed opt counters for this unit and its
/// post-opt IR instruction count. Surfaced via `--opt-stats`.
const OptOut = struct {
    stats: Opt.Stats = .{},
    ir_instrs: usize = 0,
    /// The first lowering diagnostic of a unit that failed with `error.CodegenDiagnostic`.
    diag: ?Diagnostic = null,
};

/// One codegen job's slot. Each job owns exactly one slot (no locks).
pub const Slot = struct {
    fc: ?Link.FnCode = null,
    cached: bool = false,
    err: ?anyerror = null,
    /// With `err == error.CodegenDiagnostic`: the lowering's first diagnostic.
    diag: ?Diagnostic = null,
    /// dual-metric, set only when the unit is freshly lowered (cached units leave these at
    /// 0). Accumulated into the LinkedProgram in the collect loop.
    opt_stats: Opt.Stats = .{},
    ir_instrs: usize = 0,
};

/// What one codegen unit lowers. Every unit is cached under `unitKey`.
pub const Body = union(enum) {
    /// A body written in source: a base fn or an instance, or a spec unit, its instance's
    /// body with some value calls made direct.
    source: Source,
    /// A lambda unit, lowered under its owner's tables.
    lambda: Lambda,
    /// A source-less auto-derive unit.
    derive: *const Derive.Derive,
    /// An erased hash/eq unit.
    erased: *const Typecheck.ErasedUnit,
    /// A fn-value thunk.
    adapter: *const Closure.Adapter,

    /// `guard_stack`: the entry calls the runtime's stack overflow guard first thing.
    pub const Source = struct { decl: Ast.Index, is_entry: bool = false, guard_stack: bool = false, spec: bool = false };

    /// `unit` indexes `in.closure.lambda_units`; `owner` and `owner_sig` are the declaration
    /// and signature of the body it is written in, whose content its key starts from.
    pub const Lambda = struct { unit: u32, owner: Ast.Index, owner_sig: ?Fingerprint.Sig };
};

/// The read-only view one codegen job runs against; nothing in it is mutated during the
/// fan-out.
pub const Frozen = struct {
    /// The unit's lowering inputs: `in.sig` is the unit's own signature.
    in: lower.Inputs,
    body: Body,
    sym: Link.SymName,
    /// Mixed into the codegen key, so another profile or `-O` lands on a different entry.
    profile: Profile,
    /// An instance's own concrete type-args and resolved `[T has P]` bounds, folded into its
    /// key so two instances of one template never share an entry and toggling a sibling
    /// conformance invalidates exactly the dependent instances. A lambda or spec unit of an
    /// instance carries its instance's. Empty for every other unit.
    type_args: []const Typecheck.Type = &.{},
    conformances: []const Mono.ResolvedConformance = &.{},
    /// The closure facts (`Fingerprint.ownerFacts`) of the body a unit is cut from (its own, a
    /// lambda's owner's, a spec unit's instance's), folded into its key; empty for a
    /// source-less unit and for a body with no env slot and no boxed local.
    closure_facts: []const u8 = &.{},
    /// The program's other units, which the inliner reads callee IR from. Null lowers
    /// every call as a call.
    units: ?InlineUnits.Units = null,
};

/// Fail a unit's lowering, keeping its first diagnostic where the driver reports it: such
/// a diagnostic is an internal error, and its text must reach the user.
fn failLowering(diags: []const Diagnostic, out: ?*OptOut) error{CodegenDiagnostic} {
    if (out) |o| o.diag = diags[0];
    return error.CodegenDiagnostic;
}

/// A body `lowerFitted` lowers: one from source, or a lambda unit by index.
pub const Fitted = union(enum) {
    source: struct { decl: Ast.Index, is_entry: bool },
    lambda: u32,

    fn run(f: Fitted, gpa: std.mem.Allocator, in: lower.Inputs, sym: Link.SymName, diags: *std.ArrayList(Diagnostic)) error{OutOfMemory}!Ir.Function {
        return switch (f) {
            .source => |s| lower.lowerFn(gpa, in, s.decl, sym, s.is_entry, diags),
            .lambda => |ui| LowerClosure.lowerLambda(gpa, in, ui, sym, diags),
        };
    }
};

/// Lower one body and run the opt stage on it in place. This is the one place that decides
/// where an env, or a boxed local the escape pass unboxes, lives: the escape pass marks
/// every closure that never outlives its maker as one whose env may live in a frame, and
/// every local only such closures capture as one that may leave its cell, with no budget,
/// since only the lowering knows the frame. When the optimized fixed frame of a body that
/// keeps either in its frame would overflow codegen's cap (`FrameLayout.MAX_FRAME`), the
/// body is lowered again with every env and every box in a GC cell, as at -O0, so frame
/// storage alone does not fail an -O1 build that builds at -O0. A lambda unit reads its env
/// the same way wherever it lives, and reads an unboxed local through the address its env
/// holds as it reads a cell (the cell stays rooted by its owner's frame and the env), so
/// the fallback stays local to this body, and it is a pure function of the body's inputs.
/// A lambda unit's own fallback keeps its owner's storage, which decides what its env
/// words hold. Only the fixed layout is measured, since the allocator's spill slots are
/// known only after codegen: a body within a few spill slots of the cap can still fail -O1
/// with codegen's frame diagnostic where its -O0 build fits. A lowering that reports a
/// diagnostic is returned before the opt stage sees it, for the caller to fail on. `stats`
/// are the final lowering's.
pub fn lowerFitted(
    gpa: std.mem.Allocator,
    in: lower.Inputs,
    cfg: Opt.Config,
    body: Fitted,
    sym: Link.SymName,
    diags: *std.ArrayList(Diagnostic),
    stats: *Opt.Stats,
    callees: ?Opt.inliner.Lookup,
) error{OutOfMemory}!Ir.Function {
    const before = diags.items.len;
    stats.* = .{};
    {
        var irf = try body.run(gpa, in, sym, diags);
        errdefer irf.deinit(gpa);
        if (diags.items.len != before) return irf;
        try Opt.optimize(gpa, &irf, cfg, callees, stats);
        const c = in.closure;
        const owner = c.owner orelse return irf;
        const frame_env = c.frame_envs and Closure.ownerHasFrameEnv(c.lambda_units, owner);
        const unboxed = body == .source and c.storage.frame_addrs.len != 0;
        if (!frame_env and !unboxed) return irf;
        if (try FrameLayout.fits(gpa, &irf, in.layouts, in.enum_layouts)) return irf;
        irf.deinit(gpa);
    }
    var heap = in;
    heap.closure.frame_envs = false;
    if (body == .source) heap.closure.storage.frame_addrs = &.{};
    var irf = try body.run(gpa, heap, sym, diags);
    errdefer irf.deinit(gpa);
    stats.* = .{};
    if (diags.items.len != before) return irf;
    try Opt.optimize(gpa, &irf, cfg, callees, stats);
    return irf;
}

/// Lower one unit to optimized IR: the stage `--emit ir` renders and codegen packs. A
/// spec unit needs no heap fallback, since a template with a lambda or local fn has no
/// eligible param (`Spec.eligibleMask`), but `lowerFitted` gives it none anyway: its
/// owner has no lambda unit. A lowering that reports a diagnostic is returned before the
/// opt stage sees it, for the caller to fail on.
pub fn lowerUnit(gpa: std.mem.Allocator, fr: *const Frozen, diags: *std.ArrayList(Diagnostic), stats: *Opt.Stats) error{OutOfMemory}!Ir.Function {
    const in = fr.in;
    const before = diags.items.len;
    const cfg = fr.profile.opt;
    var scope = try InlineUnits.CallerScope.init(gpa, fr);
    defer scope.deinit();
    const callees = scope.lookup();
    var irf = switch (fr.body) {
        .source => |s| return lowerFitted(gpa, in, cfg, .{ .source = .{ .decl = s.decl, .is_entry = s.is_entry } }, fr.sym, diags, stats, callees),
        .lambda => |l| return lowerFitted(gpa, in, cfg, .{ .lambda = l.unit }, fr.sym, diags, stats, callees),
        .derive => |d| try DeriveEmit.lower(gpa, in, d.*, fr.sym, diags),
        .erased => |u| try DeriveEmit.lowerErased(gpa, in, u.ty, u.kind, fr.sym, diags),
        .adapter => |a| try AdapterEmit.lowerAdapter(gpa, in, a.*, fr.sym, diags),
    };
    errdefer irf.deinit(gpa);
    stats.* = .{};
    if (diags.items.len != before) return irf;
    try Opt.optimize(gpa, &irf, cfg, callees, stats);
    return irf;
}

/// Lower one unit to machine code (Ast→Ir→OPT→FnCode) with a throwaway diag sink (a
/// diagnostic fails the build at relink, surfaced via `error.CodegenDiagnostic`). The IR
/// is built and freed here and never escapes, keeping the codegen cache ONE-TIER [C8].
fn lowerCode(gpa: std.mem.Allocator, fr: *const Frozen, opt_out: ?*OptOut) !Link.FnCode {
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(gpa);
    var opt_st: Opt.Stats = .{};
    var irf = try lowerUnit(gpa, fr, &diags, &opt_st);
    defer irf.deinit(gpa);
    if (diags.items.len > 0) return failLowering(diags.items, opt_out);
    if (opt_out) |o| o.* = .{ .stats = opt_st, .ir_instrs = Ir.instrCount(&irf) };

    const src: Body.Source = switch (fr.body) {
        .source => |s| s,
        else => .{ .decl = Ast.none },
    };
    var fc = try CodegenMir.lowerMir(gpa, &irf, fr.in.layouts, fr.in.enum_layouts, src.is_entry, src.guard_stack, &diags);
    errdefer fc.deinit(gpa);
    // A codegen diagnostic means an unsupported construct slipped past the front-end; the
    // build fails cleanly rather than emitting a half-lowered function.
    if (diags.items.len > 0) return failLowering(diags.items, opt_out);
    return fc;
}

/// The per-unit codegen query: fold the unit's content key and serve it from the cache or
/// lower it fresh, honoring `self.mode` (normal / force / verify). Writes ONLY the
/// caller-owned `slot` (no locks).
///
/// REUSE = CONTENT-FP CACHE HIT, the SOLE driver. A `.normal` build serves the prior blob
/// iff `cache.get(Key.codegen(...))` hits the unit's transitive content fingerprint; the
/// StageGraph schedules, the content cache decides. `.force` skips the cache; `.verify`
/// re-lowers fresh and audits the bytes. One-tier: the IR is built and freed inside
/// `lowerCode`; only the packed `FnCode` blob is cached.
pub fn codegen(
    self: Engine,
    gpa: std.mem.Allocator,
    io: Io,
    target: []const u8,
    fr: *const Frozen,
    tmp_tag: usize,
    slot: *Slot,
) !void {
    return self.serve(gpa, io, try unitKey(gpa, target, fr), tmp_tag, slot, fr);
}

/// A unit's key: its own content (`unitFp`) and that of every callee the inliner can
/// splice into it (`InlineUnits.Reach`), xor'd with the profile and the unit's OWN emitted
/// symbol (`Key.codegen` is the one place that fold lives).
pub fn unitKey(gpa: std.mem.Allocator, target: []const u8, fr: *const Frozen) !Cache.Key {
    var fp = try unitFp(gpa, fr);
    var reach = try InlineUnits.Reach.init(gpa, fr);
    defer reach.deinit();
    if (reach.names.items.len != 0) {
        var h = std.hash.Wyhash.init(fp);
        for (reach.names.items, reach.facts.items) |name, f| {
            h.update(name);
            h.update(std.mem.asBytes(&f.fp));
        }
        fp = h.final();
    }
    return Key.codegen(target, fp, fr.profile, fr.sym);
}

/// What a unit's own code is a pure function of, besides the callees it inlines:
///   * a body from source: its `sourceFp`; a spec unit also its direct targets.
///   * a lambda unit: its owner's `sourceFp`, which covers the lambda's body, its rank (the
///     owner's AST fixes every rank) and the env facts its owner writes, then the calls
///     its own body makes, walked under its own signature.
///   * a derive unit: its recipe (`deriveFp`).
///   * an adapter: its kind, the symbol it calls and the layouts of the types it moves.
///   * an erased unit: its kind, its key type's layout and the witness it calls.
pub fn unitFp(gpa: std.mem.Allocator, fr: *const Frozen) !u64 {
    switch (fr.body) {
        .source => |s| {
            var fp = try sourceFp(gpa, fr, s.decl, fr.in.sig);
            if (s.guard_stack) fp = std.hash.Wyhash.hash(fp, "guard_stack");
            if (s.spec) {
                var h = std.hash.Wyhash.init(fp);
                h.update("spec");
                for (fr.in.closure.spec_targets) |t| {
                    AstWalk.updateU32(&h, t.param);
                    h.update(&[_]u8{ @intFromEnum(t.kind), @intFromEnum(t.sym.kind) });
                    AstWalk.updateLeaf(&h, t.sym.name);
                }
                fp = h.final();
            }
            return fp;
        },
        .lambda => |l| {
            const owner_fp = if (fr.units) |u| try u.cache.ownerFp(gpa, fr, l) else try sourceFp(gpa, fr, l.owner, l.owner_sig);
            var h = std.hash.Wyhash.init(owner_fp);
            h.update("lambda");
            var sigs: std.ArrayList(Fingerprint.Sig) = .empty;
            defer sigs.deinit(gpa);
            try AstWalk.walkCalls(gpa, &fr.in, fr.in.closure.lambda_units[l.unit].node, lambdaSig(fr, l), &sigs);
            Fingerprint.foldSigs(&h, sigs.items);
            return h.final();
        },
        .derive => |d| return deriveFp(gpa, fr, d),
        .adapter => |a| return adapterFp(gpa, fr, a),
        .erased => |u| return erasedFp(gpa, fr, u),
    }
}

/// A lambda unit's own signature, which the `?` in its body widens into.
pub fn lambdaSig(fr: *const Frozen, l: Body.Lambda) Fingerprint.Sig {
    const u = fr.in.closure.lambda_units[l.unit];
    return .{ .kind = .user_fn, .name = u.name, .params = u.sig.params, .ret = u.sig.ret };
}

/// Fold `ty`'s index-free layout descriptor (`AstWalk.appendTouched`) into `h`.
fn foldType(gpa: std.mem.Allocator, h: *std.hash.Wyhash, fr: *const Frozen, ty: Typecheck.Type) !void {
    var list: std.ArrayList(Fingerprint.TouchedType) = .empty;
    defer {
        AstWalk.freeTouched(gpa, list.items);
        list.deinit(gpa);
    }
    try AstWalk.appendTouched(gpa, fr.in.layouts, fr.in.enum_layouts, ty, &list);
    for (list.items) |t| Fingerprint.foldTouched(h, t);
}

/// An adapter is pure over its entry and the layouts of the types it moves
/// (`AdapterEmit.lowerAdapter`).
fn adapterFp(gpa: std.mem.Allocator, fr: *const Frozen, a: *const Closure.Adapter) !u64 {
    var h = std.hash.Wyhash.init(0x41_44_41_50); // "ADAP"
    h.update(&[_]u8{ @intFromEnum(a.kind), @intFromBool(a.mut_self), @intFromEnum(a.target.kind) });
    AstWalk.updateLeaf(&h, a.target.name);
    AstWalk.updateU32(&h, @intCast(a.sig.params.len));
    for (a.sig.params) |p| try foldType(gpa, &h, fr, p);
    try foldType(gpa, &h, fr, a.sig.ret);
    try foldType(gpa, &h, fr, a.recv);
    return h.final();
}

/// An erased unit is pure over its kind, its key type's layout and the witness it calls
/// for an aggregate key (`DeriveEmit.erasedWitness`), with that witness's signature.
fn erasedFp(gpa: std.mem.Allocator, fr: *const Frozen, u: *const Typecheck.ErasedUnit) !u64 {
    var h = std.hash.Wyhash.init(0x45_52_41_53); // "ERAS"
    h.update(&[_]u8{@intFromEnum(u.kind)});
    try foldType(gpa, &h, fr, u.ty);
    if (erasedCall(fr, u)) |c| {
        h.update(&[_]u8{ 1, @intFromBool(c.via_cmp) });
        Fingerprint.foldSigs(&h, &.{c.sig});
        for (c.sig.params) |p| try foldType(gpa, &h, fr, p);
        try foldType(gpa, &h, fr, c.sig.ret);
    } else h.update(&[_]u8{0});
    return h.final();
}

pub const ErasedCall = struct { sym: Link.SymName, sig: Fingerprint.Sig, via_cmp: bool };

/// The witness erased unit `u` calls, with its symbol and signature, or null.
pub fn erasedCall(fr: *const Frozen, u: *const Typecheck.ErasedUnit) ?ErasedCall {
    const in = &fr.in;
    const w = DeriveEmit.erasedWitness(in.methods, in.prelude_ids, u.ty, u.kind) orelse return null;
    const sym = Typecheck.witnessSym(w.m, in.derives, in.instances, in.names) orelse return null;
    const sig = Typecheck.witnessSig(w.m, in.derives, in.instances, in.sigs) orelse return null;
    return .{ .sym = sym, .sig = .{ .kind = sym.kind, .name = sym.name, .params = sig.params, .ret = sig.ret, .mut_mask = sig.mut_mask }, .via_cmp = w.via_cmp };
}

/// A body's own content: its AST fingerprint over its callees' identities and signatures
/// in walk order, the layouts it touches, an instance's type-args and bounds, its closure
/// facts, and its lines when the profile tracks them. `sig` is the body's signature.
pub fn sourceFp(gpa: std.mem.Allocator, fr: *const Frozen, decl: Ast.Index, sig: ?Fingerprint.Sig) !u64 {
    const in = &fr.in;
    var callee_sigs: std.ArrayList(Fingerprint.Sig) = .empty;
    defer callee_sigs.deinit(gpa);
    try AstWalk.walkCalls(gpa, in, decl, sig, &callee_sigs);
    var touched: std.ArrayList(Fingerprint.TouchedType) = .empty;
    defer {
        AstWalk.freeTouched(gpa, touched.items);
        touched.deinit(gpa);
    }
    try AstWalk.walkTouchedSig(gpa, in, decl, sig, &touched);
    var type_args: std.ArrayList(Fingerprint.TouchedType) = .empty;
    defer {
        AstWalk.freeTouched(gpa, type_args.items);
        type_args.deinit(gpa);
    }
    try AstWalk.walkTypeArgs(gpa, in, fr.type_args, &type_args);
    var confs: std.ArrayList(Fingerprint.ResolvedConformance) = .empty;
    defer {
        AstWalk.freeConformances(gpa, confs.items);
        confs.deinit(gpa);
    }
    try AstWalk.walkConformances(gpa, in, fr.conformances, &confs);
    var consts: std.ArrayList(Typecheck.ConstSym) = .empty;
    defer consts.deinit(gpa);
    try AstWalk.walkConsts(gpa, in, decl, &consts);
    var fp = Fingerprint.foldConsts(Fingerprint.foldClosure(Fingerprint.fingerprint(in.tree, in.tokens, in.source, decl, callee_sigs.items, touched.items, type_args.items, confs.items), fr.closure_facts), consts.items);
    if (in.lines.tracked()) {
        var h = std.hash.Wyhash.init(fp);
        var lv = AstWalk.LineVisitor{ .h = &h, .in = in };
        Walk.walk(.{ .tree = in.tree, .tokens = in.tokens, .source = in.source }, decl, &lv) catch unreachable;
        fp = h.final();
    }
    return fp;
}

/// [C2] checked: the first symbol a unit's code `fc` relocates to that its key does not
/// fold, or null. A miss serves a caller lowered against a stale callee, or one program's
/// code to another that shares the cache (#35), so `--verify` fails on it. Exempt are a
/// compiler builtin and a bundled `core/rt` fn (the compiler build fixes either's
/// signature), the unit itself, the lambda units of the body it is cut from (whose
/// content that body's fingerprint holds) and the adapters of what its key folds.
pub fn uncoveredReloc(gpa: std.mem.Allocator, fr: *const Frozen, fc: *const Link.FnCode) !?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try InlineUnits.appendCallNames(gpa, fr, &names);
    // An inlined body's calls are folded through that callee's own content.
    var reach = try InlineUnits.Reach.init(gpa, fr);
    defer reach.deinit();
    for (reach.facts.items) |f| try names.appendSlice(gpa, f.calls);
    const c = fr.in.closure;
    const siblings: []const Closure.LambdaUnit = if (c.owner) |o| Closure.ownerUnits(c.lambda_units, o) else &.{};
    for (fc.relocs) |r| {
        const t: Link.SymName = switch (r.target) {
            .func, .import => |sn| sn,
            else => continue,
        };
        if (t.kind == .builtin or StdNames.isBundledRuntimeSym(t.name) or std.mem.eql(u8, t.name, fr.sym.name)) continue;
        const base = for ([_][]const u8{ "$fnval", "$bound", "$boundbox", "$boundref", "$cfn" }) |suf| {
            if (std.mem.endsWith(u8, t.name, suf)) break t.name[0 .. t.name.len - suf.len];
        } else t.name;
        if (InlineUnits.containsName(names.items, base)) continue;
        if (for (siblings) |u| {
            if (std.mem.eql(u8, u.name, base)) break true;
        } else false) continue;
        return t.name;
    }
    return null;
}

/// A derive unit's own content, which its key and the key of every caller that inlines it
/// fold.
pub fn deriveFp(gpa: std.mem.Allocator, fr: *const Frozen, d: *const Derive.Derive) !u64 {
    var conform_list: std.ArrayList(Fingerprint.TouchedType) = .empty;
    defer {
        AstWalk.freeTouched(gpa, conform_list.items);
        conform_list.deinit(gpa);
    }
    try AstWalk.appendTouched(gpa, fr.in.layouts, fr.in.enum_layouts, d.conform_ty, &conform_list);
    const conform: Fingerprint.TouchedType = if (conform_list.items.len > 0) conform_list.items[0] else .{ .kind = d.conform_ty.kind };
    return Fingerprint.deriveFingerprint(d.protocol_name, d.kind, conform, d.field_witnesses);
}

/// The cache/verify/fresh-lower state machine of a unit, honoring `self.mode`:
///   * `.verify` — always re-lower fresh and audit the packed bytes against a
///     reference (a cache HIT compares the stored blob for cache-soundness; a MISS
///     lowers a SECOND time and requires the two fresh lowerings agree, for pure
///     determinism), and requires its key to fold every symbol its code relocates to
///     (`uncoveredReloc`). The checks are REAL runtime comparisons returning an error on
///     mismatch — NOT `std.debug.assert`, which compiles out under ReleaseFast/Small
///     and would make the whole safety net silently no-op in a release build.
///   * `.normal` — serve the prior blob on a content-fp cache hit, else lower fresh.
///   * `.force` — skip the cache and lower fresh.
/// The `--timings` probe laps are gated on `self.probe != null`, so a plain build
/// reads no clock.
fn serve(
    self: Engine,
    gpa: std.mem.Allocator,
    io: Io,
    key: Cache.Key,
    tmp_tag: usize,
    slot: *Slot,
    fr: *const Frozen,
) !void {
    const cache = self.cache;
    const mode = self.mode;

    if (mode == .verify) {
        var opt_out: OptOut = .{};
        var fresh = lowerCode(gpa, fr, &opt_out) catch |e| {
            slot.diag = opt_out.diag;
            return e;
        };
        errdefer fresh.deinit(gpa);
        const fb = try Link.pack(gpa, fresh);
        defer gpa.free(fb);

        if (try uncoveredReloc(gpa, fr, &fresh) != null) return error.VerifyKeyHole;
        var was_cached = false;
        if (cache.get(u8, gpa, io, key) catch null) |blob| {
            defer gpa.free(blob);
            if (!std.mem.eql(u8, fb, blob)) return error.VerifyCacheMismatch;
            was_cached = true;
        } else {
            var fresh2 = try lowerCode(gpa, fr, null);
            defer fresh2.deinit(gpa);
            const fb2 = try Link.pack(gpa, fresh2);
            defer gpa.free(fb2);
            if (!std.mem.eql(u8, fb, fb2)) return error.VerifyNondeterministic;
            cache.put(u8, io, key, tmp_tag, fb) catch {};
        }
        // A verify build re-lowers fresh, so it has honest opt stats even on a
        // cache hit (was_cached==true). Record them.
        slot.* = .{ .fc = fresh, .cached = was_cached, .opt_stats = opt_out.stats, .ir_instrs = opt_out.ir_instrs };
        return;
    }

    if (mode != .force) {
        const get_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
        const got = cache.get(u8, gpa, io, key) catch null;
        if (self.probe) |p| StageProbe.lap(io, &p.get_ns, get_t0);
        if (got) |blob| {
            defer gpa.free(blob);
            if (Link.unpack(gpa, blob) catch null) |fc| {
                slot.* = .{ .fc = fc, .cached = true };
                return;
            }
        }
    }

    var opt_out: OptOut = .{};
    const comp_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
    var fc = lowerCode(gpa, fr, &opt_out) catch |e| {
        slot.diag = opt_out.diag;
        return e;
    };
    if (self.probe) |p| StageProbe.lap(io, &p.compute_ns, comp_t0);
    errdefer fc.deinit(gpa);
    if (Link.pack(gpa, fc) catch null) |b| {
        defer gpa.free(b);
        const put_t0: i128 = if (self.probe != null) StageProbe.now(io) else 0;
        cache.put(u8, io, key, tmp_tag, b) catch {};
        if (self.probe) |p| StageProbe.lap(io, &p.put_ns, put_t0);
    }
    slot.* = .{ .fc = fc, .cached = false, .opt_stats = opt_out.stats, .ir_instrs = opt_out.ir_instrs };
}

const testing = std.testing;

test "aggKey is order-independent and does not cancel duplicates" {
    const a = [_]u64{ 0x11, 0x22, 0x33 };
    const a_rev = [_]u64{ 0x33, 0x22, 0x11 };
    const a_shuf = [_]u64{ 0x22, 0x11, 0x33 };
    // The set-fold is identical regardless of contributor order (the property that
    // keeps a barrier byte-identical at -j1 and -jN).
    try testing.expectEqual(aggKey(&a), aggKey(&a_rev));
    try testing.expectEqual(aggKey(&a), aggKey(&a_shuf));

    // A different multiset yields a different fold.
    const b = [_]u64{ 0x11, 0x22, 0x44 };
    try testing.expect(aggKey(&a) != aggKey(&b));

    // Summing (not XOR) so a duplicated contributor does NOT cancel: {x,x} != {} and
    // != {x}.
    const dup = [_]u64{ 0xABCD, 0xABCD };
    const one = [_]u64{0xABCD};
    try testing.expect(aggKey(&dup) != aggKey(&one));
    try testing.expect(aggKey(&dup) != aggKey(&.{}));
}

test "barrier folds contributors and runs compute exactly once" {
    const gpa = testing.allocator;
    const cache: Cache = .{ .dir = "unused-barrier-test" }; // barrier never touches it
    const engine = Engine.init(cache, .normal);

    var runs: usize = 0;
    const Compute = struct {
        runs: *usize,
        pub fn run(c: @This()) !u32 {
            c.runs.* += 1;
            return 7;
        }
    };

    const contributors = [_]u64{ 0xDEAD, 0xBEEF, 0xC0DE };
    const res = try engine.barrier(gpa, .signature, &contributors, Compute{ .runs = &runs });

    // compute ran EXACTLY once; the aggregate flows through unchanged.
    try testing.expectEqual(@as(usize, 1), runs);
    try testing.expectEqual(@as(u32, 7), res.value);
    // The fold matches the standalone set-fold of the same contributors.
    try testing.expectEqual(aggKey(&contributors), res.fold);
}

test "chunkedFanOut covers every unit exactly once, in disjoint ranges (any ncpu)" {
    const gpa = testing.allocator;
    // .limited(0) forces the inline path (every range runs on this thread): the
    // serial baseline. A real pool is exercised by the integration/perf suite; here
    // we assert the partition is total + disjoint regardless of the chunk count.
    var threaded = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        hits: []u32,
        pub fn args(c: @This(), i: usize) std.meta.ArgsTuple(@TypeOf(job)) {
            return .{ c.hits, i };
        }
        fn job(hits: []u32, i: usize) void {
            hits[i] += 1;
        }
    };

    // n=1000, threshold=10 so chunking activates; sweep ncpu incl. cases where n is
    // NOT divisible by the chunk count (1000 % 7, % 13, % 64 != 0).
    for ([_]usize{ 1, 2, 3, 4, 7, 8, 13, 64, 1000, 2000 }) |ncpu| {
        const hits = try gpa.alloc(u32, 1000);
        defer gpa.free(hits);
        @memset(hits, 0);
        chunkedFanOut(io, 1000, ncpu, 10, 4, Ctx.job, Ctx{ .hits = hits });
        for (hits) |h| try testing.expectEqual(@as(u32, 1), h);
    }
}

test "chunkedFanOut below threshold runs the serial inline path" {
    const gpa = testing.allocator;
    // .unlimited would still let a tiny n go inline, but pin .limited(0) so the test
    // asserts the threshold branch (not pool behavior): n <= threshold => inline.
    var threaded = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();

    var order: std.ArrayListUnmanaged(usize) = .empty;
    defer order.deinit(gpa);
    const Ctx = struct {
        order: *std.ArrayListUnmanaged(usize),
        gpa: std.mem.Allocator,
        pub fn args(c: @This(), i: usize) std.meta.ArgsTuple(@TypeOf(job)) {
            return .{ c.order, c.gpa, i };
        }
        fn job(o: *std.ArrayListUnmanaged(usize), g: std.mem.Allocator, i: usize) void {
            o.append(g, i) catch {};
        }
    };
    // n=5, threshold=100 => serial: the inline path visits units in ascending order.
    chunkedFanOut(io, 5, 8, 100, 4, Ctx.job, Ctx{ .order = &order, .gpa = gpa });
    try testing.expectEqual(@as(usize, 5), order.items.len);
    for (order.items, 0..) |v, i| try testing.expectEqual(i, v);
}

test "chunkedFanOut result is identical to fanOut (per-unit slot writes)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        out: []u64,
        pub fn args(c: @This(), i: usize) std.meta.ArgsTuple(@TypeOf(job)) {
            return .{ c.out, i };
        }
        fn job(out: []u64, i: usize) void {
            // A deterministic per-unit value written to the unit's OWN slot.
            out[i] = std.hash.Wyhash.hash(0xABCD, std.mem.asBytes(&i));
        }
    };

    const a = try gpa.alloc(u64, 777);
    defer gpa.free(a);
    const b = try gpa.alloc(u64, 777);
    defer gpa.free(b);
    @memset(a, 0);
    @memset(b, 0);

    fanOut(io, 777, Ctx.job, Ctx{ .out = a });
    chunkedFanOut(io, 777, 8, 16, 4, Ctx.job, Ctx{ .out = b });
    try testing.expectEqualSlices(u64, a, b);
}

test "barrier returns the fold for any kind" {
    const gpa = testing.allocator;
    const cache: Cache = .{ .dir = "unused-barrier-test" };
    const engine = Engine.init(cache, .normal);

    const Compute = struct {
        pub fn run(_: @This()) !u32 {
            return 42;
        }
    };
    const contributors = [_]u64{ 1, 2, 3 };
    const res = try engine.barrier(gpa, .layout, &contributors, Compute{});
    try testing.expectEqual(@as(u32, 42), res.value);
    try testing.expectEqual(aggKey(&contributors), res.fold);
}

// Engine boundary tests (hit/miss/force/verify/invalidation + key discrimination)
// are an INTEGRATION suite (temp-dir cache + threaded runtime), so they live in
// `src/tests/query_engine.zig` rather than inline here; `root.zig` pulls them.

test "pool: -j1 runs inline, -jN caps at N, 0 caps at the host cpus" {
    const gpa = std.testing.allocator;
    var one = pool(gpa, 1);
    defer one.deinit();
    try std.testing.expectEqual(std.Io.Limit.limited(0), one.concurrent_limit);
    var four = pool(gpa, 4);
    defer four.deinit();
    try std.testing.expectEqual(std.Io.Limit.limited(4), four.concurrent_limit);
    var host = pool(gpa, 0);
    defer host.deinit();
    try std.testing.expectEqual(if (hostCpus() <= 1) std.Io.Limit.limited(0) else std.Io.Limit.limited(hostCpus()), host.concurrent_limit);
}
