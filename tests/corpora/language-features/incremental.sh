#!/usr/bin/env bash
# Incremental (content-fingerprint early-cutoff) harness — the worthwhile proof.
#
# For each EDIT SCENARIO (body / signature / type-layout / comment-only /
# cross-module) it:
#   (1) cold-builds a base program (primes the content-fp cache),
#   (2) records the FULL codegen count via `--codegen-stats --no-cache`,
#   (3) applies the edit,
#   (4) INCREMENTAL rebuild with `--codegen-stats` (cache serves unchanged fns),
#   (5) `--no-cache` FULL rebuild of the SAME final source,
#   (6) SOUNDNESS: cmp the __text of (4) vs (5) -> must be IDENTICAL. A divergence
#       is a stale-cache miscompile (the critical anti-regression gate).
#   (7) CUTOFF (localized edits): the incremental codegen count is a STRICT SUBSET
#       of a full build (incremental compiled < full compiled). A cache that
#       recomputes everything is "wired but inert".
#
# Cutoff is delivered by the content-fingerprint cache: a fn whose transitive
# fingerprint is unchanged is served from cache, never re-lowered (`--codegen-stats`
# reports `compiled=N cached=M`). The red-green DAG is gone — content-fp is the sole
# correctness/cutoff driver, so `--codegen-stats` is the cutoff signal (was the
# removed `--query-stats`). The wall-clock win is modest on this tiny corpus — it is
# the finer-incrementality FOUNDATION, not a headline speedup.
set -u

root="$(cd "$(dirname "$0")/../../.." && pwd)"
toyc="$root/zig-out/bin/toy"

echo "building toy..."
if command -v zig >/dev/null 2>&1; then zig="zig"
elif command -v mise >/dev/null 2>&1; then zig="mise exec -- zig"
else echo "build failed: no zig (and no mise to provide it)"; exit 1; fi
( cd "$root" && $zig build ) || { echo "build failed"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
texthash() { otool -s __TEXT __text "$1" 2>/dev/null | tail -n +2 | shasum | cut -d' ' -f1; }
compiled_of() { sed -n 's/.*compiled=\([0-9]*\).*/\1/p' <<<"$1"; }

pass=0; fail=0
fail_one() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# $1 name  $2 base source  $3 edited source  $4 expect-strict-subset-cutoff (1/0)
# $5 build flags (a profile), optional
run_scenario() {
  local name="$1" base="$2" edited="$3" expect_cutoff="$4" flags="${5:-}"
  local d="$work/$name"; mkdir -p "$d"; local src="$d/prog.toy"
  ( cd "$d" && rm -rf .toy )

  printf '%s' "$base" > "$src"
  ( cd "$d" && "$toyc" $flags -o base.bin prog.toy >/dev/null 2>&1 ) \
    || { fail_one "$name: cold build failed"; return; }
  local full_compiled
  full_compiled="$( cd "$d" && "$toyc" $flags -o /dev/null --codegen-stats --no-cache prog.toy 2>&1 )"; full_compiled="$(compiled_of "$full_compiled")"

  printf '%s' "$edited" > "$src"
  local inc_out
  inc_out="$( cd "$d" && "$toyc" $flags -o inc.bin --codegen-stats prog.toy 2>&1 )"
  ( cd "$d" && "$toyc" $flags -o force.bin --no-cache prog.toy >/dev/null 2>&1 ) \
    || { fail_one "$name: force build failed"; return; }

  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "$name: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi

  local comp
  comp="$(compiled_of "$inc_out")"

  if [ "$expect_cutoff" = "1" ]; then
    if [ -n "$comp" ] && [ -n "$full_compiled" ] && [ "$comp" -lt "$full_compiled" ]; then
      echo "  OK   $name: SOUND; CUTOFF codegen compiled=$comp < full=$full_compiled"
      pass=$((pass + 1))
    else
      fail_one "$name: CUTOFF — codegen compiled=$comp NOT < full=$full_compiled"
    fi
  else
    echo "  OK   $name: SOUND; codegen compiled=$comp full=$full_compiled (no-cutoff scenario)"
    pass=$((pass + 1))
  fi
}

echo "=== edit battery (soundness + cutoff) ==="

# 1) BODY — the headline: caller cuts off, only the edited fn re-lowers.
run_scenario body \
'fn add(a: int, b: int) -> int { return a + b }
fn mul(a: int, b: int) -> int { return a * b }
fn main() -> int { return add(mul(2, 3), 4) }
' \
'fn add(a: int, b: int) -> int { return a + b }
fn mul(a: int, b: int) -> int { return a * b + 0 }
fn main() -> int { return add(mul(2, 3), 4) }
' 1

# 2) SIGNATURE — a param-type change: the caller MUST rebuild (no cutoff of the
#    caller), but the unrelated fn still cuts off.
run_scenario signature \
'fn add(a: int, b: int) -> int { return a + b }
fn lone(x: int) -> int { return x * x }
fn main() -> int { return add(1, 2) + lone(3) }
' \
'fn add(a: int, b: bool) -> int { return a }
fn lone(x: int) -> int { return x * x }
fn main() -> int { return add(1, true) + lone(3) }
' 0

# 3) TYPE / LAYOUT — add a struct field; fns not touching the struct cut off.
run_scenario layout \
'struct P { x: int, y: int }
fn px(p: P) -> int { return p.x }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    p := P{ x: 5, y: 9 }
    return px(p) + unrelated(1)
}
' \
'struct P { x: int, y: int, z: int }
fn px(p: P) -> int { return p.x }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    p := P{ x: 5, y: 9, z: 0 }
    return px(p) + unrelated(1)
}
' 1

# 3b) GENERIC MONOMORPHIZATION — editing a struct used as a TYPE-ARG recompiles
#     EXACTLY the dependent instance (id[P]) + its constructing caller (main). The
#     other instance id[int] and the unrelated fn cut off. Adding a field to P also
#     crosses the 16-byte reg-pair→sret ABI boundary, so the SOUNDNESS cmp is a real
#     stale-cache miscompile gate (a cached reg-pair id[P] would exit wrong).
run_scenario generic_typearg \
'fn id[T](x: T) -> T { x }
struct P { x: int, y: int }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    a := id[int](7)
    p := id[P](P{ x: 20, y: 15 })
    return a + p.x + p.y + unrelated(0)
}
' \
'fn id[T](x: T) -> T { x }
struct P { x: int, y: int, z: int }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    a := id[int](7)
    p := id[P](P{ x: 20, y: 15, z: 0 })
    return a + p.x + p.y + unrelated(0)
}
' 1

# 3c) BOUNDED CONFORMANCE — a bounded generic `twice[T has Doubler]` instantiated
#     at BOTH X and Y, each conforming via `impl .. has Doubler`. Editing the conforming
#     type X (add a field) must recompile EXACTLY the dependent monomorphization
#     (twice$X) + X.dbl + main; the other instance twice$Y, Y.dbl, and the unrelated fn
#     cut off. The cutoff is carried jointly by the (d) type-arg-layout fold AND the (e)
#     resolved-conformance fold; the SOUNDNESS cmp (inc __text == force __text) is the
#     stale-cache-miscompile gate — a cached twice$X against X's old layout would exit wrong.
run_scenario bounded_conformance \
'protocol Doubler { fn dbl(self) -> int }
struct X { x: int }
struct Y { y: int }
impl X has Doubler { fn dbl(self) -> int { self.x * 2 } }
impl Y has Doubler { fn dbl(self) -> int { self.y * 2 } }
fn twice[T has Doubler](v: T) -> int { v.dbl() + v.dbl() }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    a := twice(X{ x: 3 })
    b := twice(Y{ y: 4 })
    return a + b + unrelated(0)
}
' \
'protocol Doubler { fn dbl(self) -> int }
struct X { x: int, w: int }
struct Y { y: int }
impl X has Doubler { fn dbl(self) -> int { self.x * 2 } }
impl Y has Doubler { fn dbl(self) -> int { self.y * 2 } }
fn twice[T has Doubler](v: T) -> int { v.dbl() + v.dbl() }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    a := twice(X{ x: 3, w: 0 })
    b := twice(Y{ y: 4 })
    return a + b + unrelated(0)
}
' 1

# generic conformance: adding `impl Box[T] has Display` swaps every `to_string` of a
# `Box[X]` from the structural derive to the impl's instance; SOUNDNESS = no cached body
# still calls the derived witness.
run_scenario generic_conformance \
'struct Box[T] { v: T }
fn show[T has Display](t: T) -> int { t.to_string().len() }
fn main() -> int {
    b := Box { v: 1 }
    return show(b) + b.to_string().len()
}
' \
'struct Box[T] { v: T }
impl Box[T has Display] has Display { fn display(self) -> str { "B" } }
fn show[T has Display](t: T) -> int { t.to_string().len() }
fn main() -> int {
    b := Box { v: 1 }
    return show(b) + b.to_string().len()
}
' 0

# std's Vec render calls its element's Display: giving the element type an explicit impl
# must change the render on a warm rebuild, not serve the cached derived-element instance.
run_scenario vec_elem_display \
'import std/vec
struct P { v: int }
fn main() -> int { return [P { v: 1 }].to_string().len() }
' \
'import std/vec
struct P { v: int }
impl P has Display { fn display(self) -> str { "p" } }
fn main() -> int { return [P { v: 1 }].to_string().len() }
' 0
vd="$work/vec_elem_display"
"$vd/base.bin"; vb=$?
"$vd/inc.bin"; vi=$?
if [ "$vb" = 9 ] && [ "$vi" = 3 ]; then
  echo "  OK   vec_elem_display: render [P{v: 1}] -> [p] on the warm rebuild"
  pass=$((pass + 1))
else
  fail_one "vec_elem_display: exit base=$vb inc=$vi, want 9 then 3"
fi

# 4) COMMENT-ONLY — no semantic change; EVERYTHING cuts off (codegen compiled=0),
#    the strongest cutoff (index-free codegen fingerprint).
run_scenario comment \
'fn add(a: int, b: int) -> int { return a + b }
fn main() -> int { return add(40, 2) }
' \
'# a fresh comment that changes nothing semantically
fn add(a: int, b: int) -> int { return a + b }
fn main() -> int { return add(40, 2) }
' 0

# 4b) COMPOUND OPERATOR — `+=` edited to `-=`: the fn holding it MUST re-lower (its key
#     folds the assignment's operator), the unrelated fn cuts off.
run_scenario compound_op \
'fn step(mut n: int) { n += 3 }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    x := 10
    step(x)
    return x + unrelated(1)
}
' \
'fn step(mut n: int) { n -= 3 }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    x := 10
    step(x)
    return x + unrelated(1)
}
' 1

# 4c) COMPOUND WITNESS — `v += w` on a struct calls its Add impl. The key of the fn
#     holding the `+=` folds the witness's signature, not its body (the AstWalk unit test
#     guards that fold), so a body edit stays sound and cuts `grow` off: only the impl
#     re-lowers.
run_scenario compound_witness \
'struct V { a: int }
impl V has Add { fn add(self, o: V) -> V { V { a: self.a + o.a } } }
fn grow(mut v: V, w: V) { v += w }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    v := V { a: 1 }
    grow(v, V { a: 2 })
    return v.a + unrelated(1)
}
' \
'struct V { a: int }
impl V has Add { fn add(self, o: V) -> V { V { a: self.a * 10 + o.a } } }
fn grow(mut v: V, w: V) { v += w }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    v := V { a: 1 }
    grow(v, V { a: 2 })
    return v.a + unrelated(1)
}
' 1

# 5) CROSS-MODULE — a body edit to an imported module PRIVATE helper. The importer
#    depends on the imported fn SIGNATURE, never its body, so the entry cuts off.
run_cross_module() {
  local d="$work/cross"; mkdir -p "$d/lib"
  ( cd "$d" && rm -rf .toy )
  cat > "$d/main.toy" <<'TOY'
import lib/util
fn main() -> int { return util.compute(40) }
TOY
  cat > "$d/lib/util.toy" <<'TOY'
pub fn compute(n: int) -> int { return helper(n) + 2 }
fn helper(n: int) -> int { return n }
TOY
  ( cd "$d" && "$toyc" -o base.bin main.toy >/dev/null 2>&1 ) \
    || { fail_one "cross-module: cold build failed"; return; }
  local full_compiled
  full_compiled="$( cd "$d" && "$toyc" -o /dev/null --codegen-stats --no-cache main.toy 2>&1 )"; full_compiled="$(compiled_of "$full_compiled")"

  cat > "$d/lib/util.toy" <<'TOY'
pub fn compute(n: int) -> int { return helper(n) + 2 }
fn helper(n: int) -> int { return n + 0 }
TOY
  local inc_out
  inc_out="$( cd "$d" && "$toyc" -o inc.bin --codegen-stats main.toy 2>&1 )"
  ( cd "$d" && "$toyc" -o force.bin --no-cache main.toy >/dev/null 2>&1 ) \
    || { fail_one "cross-module: force build failed"; return; }

  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "cross-module: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi
  local comp
  comp="$(compiled_of "$inc_out")"
  if [ -n "$comp" ] && [ -n "$full_compiled" ] && [ "$comp" -lt "$full_compiled" ]; then
    echo "  OK   cross-module: SOUND; CUTOFF codegen compiled=$comp < full=$full_compiled"
    pass=$((pass + 1))
  else
    fail_one "cross-module: CUTOFF — codegen compiled=$comp NOT < full=$full_compiled"
  fi
}
run_cross_module

# 5b) INLINED CALLEE — a release build inlines the small imported `bump` into `main`, so
#     `main`'s key folds `bump`'s body. Editing only `bump` must re-lower `main` too: the
#     warm binary's exit changes with the edit, and equals a --no-cache build. The
#     unrelated fn still cuts off.
run_inline_callee() {
  local d="$work/inline"; mkdir -p "$d/lib"
  ( cd "$d" && rm -rf .toy )
  cat > "$d/main.toy" <<'TOY'
import lib/util
fn unrelated() -> int { return 3 }
fn main() -> int { return util.bump(40) + unrelated() - 3 }
TOY
  cat > "$d/lib/util.toy" <<'TOY'
pub fn bump(n: int) -> int { return n + 1 }
TOY
  ( cd "$d" && "$toyc" --release -o base.bin main.toy >/dev/null 2>&1 ) \
    || { fail_one "inline-callee: cold build failed"; return; }
  if ( cd "$d" && "$toyc" --emit ir --release main.toy 2>/dev/null ) | sed -n '/^fn main()/,/^}/p' | grep -q 'call @lib/util.bump'; then
    fail_one "inline-callee: main still calls bump at release (nothing to test)"
    return
  fi
  local full_compiled
  full_compiled="$( cd "$d" && "$toyc" --release -o /dev/null --codegen-stats --no-cache main.toy 2>&1 )"; full_compiled="$(compiled_of "$full_compiled")"

  cat > "$d/lib/util.toy" <<'TOY'
pub fn bump(n: int) -> int { return n + 2 }
TOY
  local inc_out
  inc_out="$( cd "$d" && "$toyc" --release -o inc.bin --codegen-stats main.toy 2>&1 )"
  ( cd "$d" && "$toyc" --release -o force.bin --no-cache main.toy >/dev/null 2>&1 ) \
    || { fail_one "inline-callee: force build failed"; return; }

  local base_rc inc_rc
  "$d/base.bin"; base_rc=$?
  "$d/inc.bin"; inc_rc=$?
  if [ "$base_rc" != 41 ] || [ "$inc_rc" != 42 ]; then
    fail_one "inline-callee: exit base=$base_rc inc=$inc_rc, want 41 then 42 [STALE INLINED BODY]"
    return
  fi
  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "inline-callee: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi
  local comp
  comp="$(compiled_of "$inc_out")"
  if [ -n "$comp" ] && [ -n "$full_compiled" ] && [ "$comp" -lt "$full_compiled" ]; then
    echo "  OK   inline-callee: SOUND; exit 41->42; CUTOFF codegen compiled=$comp < full=$full_compiled"
    pass=$((pass + 1))
  else
    fail_one "inline-callee: CUTOFF — codegen compiled=$comp NOT < full=$full_compiled"
  fi
}
run_inline_callee

# 5c) INLINED WITNESS — a release build splices `P`'s derived Eq into `same`, and the
#     derive's own field witness, the imported `Key.eq`, into it. The derive has no
#     source: `same`'s key folds its recipe and layout, then the witnesses it calls.
#     Editing only `Key.eq` must re-lower `same`; the unrelated fn still cuts off.
run_inline_witness() {
  local d="$work/inline_witness"; mkdir -p "$d/lib"
  ( cd "$d" && rm -rf .toy )
  cat > "$d/main.toy" <<'TOY'
import lib/key
struct P { k: key.Key }
fn same(a: P, b: P) -> bool { a == b }
fn unrelated() -> int { return 3 }
fn main() -> int {
    a := P { k: key.Key { v: 1 } }
    b := P { k: key.Key { v: 2 } }
    return if same(a, b) { 42 } else { 41 } + unrelated() - 3
}
TOY
  cat > "$d/lib/key.toy" <<'TOY'
pub struct Key { pub v: int }
impl Key has Eq {
    fn eq(self, o: Key) -> bool { self.v == o.v }
}
TOY
  ( cd "$d" && "$toyc" --release -o base.bin main.toy >/dev/null 2>&1 ) \
    || { fail_one "inline-witness: cold build failed"; return; }
  if ( cd "$d" && "$toyc" --emit ir --release main.toy 2>/dev/null ) | sed -n '/^fn main.same(/,/^}/p' | grep -q 'call @'; then
    fail_one "inline-witness: same still calls a witness at release (nothing to test)"
    return
  fi
  local full_compiled
  full_compiled="$( cd "$d" && "$toyc" --release -o /dev/null --codegen-stats --no-cache main.toy 2>&1 )"; full_compiled="$(compiled_of "$full_compiled")"

  cat > "$d/lib/key.toy" <<'TOY'
pub struct Key { pub v: int }
impl Key has Eq {
    fn eq(self, _o: Key) -> bool { true }
}
TOY
  local inc_out
  inc_out="$( cd "$d" && "$toyc" --release -o inc.bin --codegen-stats main.toy 2>&1 )"
  ( cd "$d" && "$toyc" --release -o force.bin --no-cache main.toy >/dev/null 2>&1 ) \
    || { fail_one "inline-witness: force build failed"; return; }

  local base_rc inc_rc
  "$d/base.bin"; base_rc=$?
  "$d/inc.bin"; inc_rc=$?
  if [ "$base_rc" != 41 ] || [ "$inc_rc" != 42 ]; then
    fail_one "inline-witness: exit base=$base_rc inc=$inc_rc, want 41 then 42 [STALE INLINED WITNESS]"
    return
  fi
  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "inline-witness: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi
  local comp
  comp="$(compiled_of "$inc_out")"
  if [ -n "$comp" ] && [ -n "$full_compiled" ] && [ "$comp" -lt "$full_compiled" ]; then
    echo "  OK   inline-witness: SOUND; exit 41->42; CUTOFF codegen compiled=$comp < full=$full_compiled"
    pass=$((pass + 1))
  else
    fail_one "inline-witness: CUTOFF — codegen compiled=$comp NOT < full=$full_compiled"
  fi
}
run_inline_witness

# 6) `?`-FROM CONFORMANCE TOGGLE — `outer`'s `?` WIDENS `inner()`'s error via
#    `impl BigErr has From[SmallErr]`. Base builds; REMOVING the impl makes a warm rebuild a
#    T0033 compile-error (the widen is NOT stale-served from the cached green `outer`);
#    RE-ADDING it rebuilds green with __text byte-identical to a --no-cache full build (soundness),
#    and every fn — incl. the `unrelated` cutoff witness — is served from cache.
#
#    HONEST TEETH: typecheck runs FRESH every build (Orchestrator -> checkGraph, uncached), so
#    remove-impl yields T0033 regardless of the codegen From-witness fold, and concrete-From
#    op_err/ret_err are independently folded elsewhere — no concrete stale-cache miscompile is
#    reachable. This scenario proves end-to-end conformance-toggle SOUNDNESS; it does not, alone,
#    discriminate fold-present from fold-absent for concrete From (that discipline-consistency
#    is pinned by the AstWalk `.try_operator` fold unit test).
run_from_widen() {
  local d="$work/from_widen"; mkdir -p "$d"; local src="$d/prog.toy"
  ( cd "$d" && rm -rf .toy )

  local with_impl='enum SmallErr { bad }
enum BigErr { small, other }
impl BigErr has From[SmallErr] { fn from(s: SmallErr) -> BigErr { BigErr.small } }
fn inner() -> Result[int, SmallErr] { return Result[int, SmallErr].err(SmallErr.bad) }
fn outer() -> Result[int, BigErr] {
  v := inner()?
  return Result.ok(v)
}
fn unrelated(n: int) -> int { return n + n }
fn main() -> int { return match outer() { .ok(_) -> unrelated(0), .err(_) -> 42 } }
'
  local without_impl='enum SmallErr { bad }
enum BigErr { small, other }
fn inner() -> Result[int, SmallErr] { return Result[int, SmallErr].err(SmallErr.bad) }
fn outer() -> Result[int, BigErr] {
  v := inner()?
  return Result.ok(v)
}
fn unrelated(n: int) -> int { return n + n }
fn main() -> int { return match outer() { .ok(_) -> unrelated(0), .err(_) -> 42 } }
'

  # (1) cold build (impl present) primes the content-fp cache.
  printf '%s' "$with_impl" > "$src"
  ( cd "$d" && "$toyc" -o base.bin prog.toy >/dev/null 2>&1 ) \
    || { fail_one "from_widen: cold build (impl present) failed"; return; }
  local full_compiled
  full_compiled="$( cd "$d" && "$toyc" -o /dev/null --codegen-stats --no-cache prog.toy 2>&1 )"; full_compiled="$(compiled_of "$full_compiled")"

  # (2) REMOVE the impl -> warm rebuild MUST fail with T0033 (the widen is not stale-served).
  printf '%s' "$without_impl" > "$src"
  local rm_out rm_rc
  rm_out="$( cd "$d" && "$toyc" -o inc.bin --codegen-stats prog.toy 2>&1 )"; rm_rc=$?
  if [ "$rm_rc" -eq 0 ]; then
    fail_one "from_widen: remove-impl warm rebuild STALE-SUCCEEDED (expected a T0033 compile-error)"
    return
  fi
  if ! grep -q "T0033" <<<"$rm_out"; then
    fail_one "from_widen: remove-impl failed but WITHOUT T0033 [$rm_out]"
    return
  fi

  # (3) RESTORE the impl -> warm rebuild green; its __text must equal a --no-cache full build.
  printf '%s' "$with_impl" > "$src"
  local inc_out inc_rc
  inc_out="$( cd "$d" && "$toyc" -o inc.bin --codegen-stats prog.toy 2>&1 )"; inc_rc=$?
  if [ "$inc_rc" -ne 0 ]; then
    fail_one "from_widen: restore-impl warm rebuild failed (expected green) [$inc_out]"
    return
  fi
  ( cd "$d" && "$toyc" -o force.bin --no-cache prog.toy >/dev/null 2>&1 ) \
    || { fail_one "from_widen: force build failed"; return; }

  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "from_widen: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi

  # (4) CUTOFF: the restore rebuild serves cached fns (incl. `unrelated`) -> compiled < full.
  local comp
  comp="$(compiled_of "$inc_out")"
  if [ -n "$comp" ] && [ -n "$full_compiled" ] && [ "$comp" -lt "$full_compiled" ]; then
    echo "  OK   from_widen: remove->T0033; restore SOUND + CUTOFF codegen compiled=$comp < full=$full_compiled"
    pass=$((pass + 1))
  else
    fail_one "from_widen: CUTOFF — codegen compiled=$comp NOT < full=$full_compiled"
  fi
}
run_from_widen

# core/rt no-allocation rule (T0082) over a warm cache: the runtime fn `first` is unchanged
# while its callee `helper`, in another runtime module, starts to allocate. The warm build
# MUST fail with the call path (the cached `first` does not keep its old verdict); undoing
# the edit builds again, SOUND against a --no-cache build. The runtime modules sit on disk,
# which a dev build's --dev-core-imports allows.
run_core_rt() {
  local d="$work/core_rt"; mkdir -p "$d/core/rt"
  ( cd "$d" && rm -rf .toy )
  printf '%s' 'import core/rt/probe
fn main() -> int { return probe.first("ab") }
' > "$d/prog.toy"
  printf '%s' 'import core/rt/util
pub fn first(s: str) -> int { return util.helper(s) }
' > "$d/core/rt/probe.toy"
  local clean='pub fn helper(s: str) -> int { return s.len() }
'
  local allocating='import std/vec
pub fn helper(s: str) -> int {
    xs := Vec[str].new()
    xs.push(s)
    return xs.len()
}
'
  printf '%s' "$clean" > "$d/core/rt/util.toy"
  ( cd "$d" && "$toyc" --dev-core-imports -o base.bin prog.toy >/dev/null 2>&1 ) \
    || { fail_one "core_rt: cold build failed"; return; }

  printf '%s' "$allocating" > "$d/core/rt/util.toy"
  local out rc
  out="$( cd "$d" && "$toyc" --dev-core-imports -o inc.bin prog.toy 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail_one "core_rt: warm build after the callee allocates STALE-SUCCEEDED (expected T0082)"
    return
  fi
  if ! grep -q "T0082.*first -> core/rt/util.helper -> std/vec.Vec.new\$str" <<<"$out"; then
    fail_one "core_rt: failed but without the T0082 call path [$out]"
    return
  fi

  printf '%s' "$clean" > "$d/core/rt/util.toy"
  ( cd "$d" && "$toyc" --dev-core-imports -o inc.bin prog.toy >/dev/null 2>&1 ) \
    || { fail_one "core_rt: warm build after undoing the edit failed"; return; }
  ( cd "$d" && "$toyc" --dev-core-imports -o force.bin --no-cache prog.toy >/dev/null 2>&1 ) \
    || { fail_one "core_rt: force build failed"; return; }
  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "core_rt: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi
  echo "  OK   core_rt: callee allocates -> T0082 with the path; undo SOUND"
  pass=$((pass + 1))
}
run_core_rt

# alias target flip: the dependent fn's resolved param Type changes (structT id flips),
# so it re-lowers; SOUNDNESS = inc __text == force __text (no stale alias-resolved body).
run_scenario alias_target \
'struct Wrap { v: int }
struct Wrap2 { v: int }
type Cur = Wrap
fn unwrap_v(c: Cur) -> int { return c.v }
fn main() -> int {
    w := Wrap { v: 42 }
    return unwrap_v(w)
}
' \
'struct Wrap { v: int }
struct Wrap2 { v: int }
type Cur = Wrap2
fn unwrap_v(c: Cur) -> int { return c.v }
fn main() -> int {
    w := Wrap2 { v: 42 }
    return unwrap_v(w)
}
' 0

# $1 scenario  $2 base exit  $3 warm exit: the edit reaches the warm binary.
expect_exits() {
  local d="$work/$1" b i
  "$d/base.bin"; b=$?
  "$d/inc.bin"; i=$?
  if [ "$b" = "$2" ] && [ "$i" = "$3" ]; then
    echo "  OK   $1: exit $b -> $i on the warm rebuild"
    pass=$((pass + 1))
  else
    fail_one "$1: exit base=$b inc=$i, want $2 then $3 [STALE UNIT]"
  fi
}

# const value: a use lowers to the folded value, which the using fn's body text does not
# hold, so a value edit must re-lower exactly the fns that name the const.
const_base='N :=: 5
fn get() -> int { N }
fn other(n: int) -> int { n - 2 }
fn main() -> int {
    return get() + other(2)
}
'
const_value="${const_base/N :=: 5/N :=: 7}"
for prof in "" "--release"; do
  tag="${prof:+_release}"
  run_scenario "const_value$tag" "$const_base" "$const_value" 1 "$prof"
  expect_exits "const_value$tag" 5 7
done

# const kinds: a str or enum-variant const lowers to a temp the using fn builds, so a
# change of its bytes or variant must re-lower exactly the fns that name it.
const_kinds_base='enum Mode { Fast, Slow }
NAME :=: "abc"
M: Mode =: .Fast
fn name_len() -> int { NAME.len() }
fn mode() -> int {
    match M {
        .Fast -> 1
        .Slow -> 2
    }
}
fn other(n: int) -> int { n - 2 }
fn main() -> int {
    return name_len() * 10 + mode() + other(2)
}
'
const_kinds_edit="${const_kinds_base/NAME :=: \"abc\"/NAME :=: \"abcde\"}"
const_kinds_edit="${const_kinds_edit/M: Mode =: .Fast/M: Mode =: .Slow}"
for prof in "" "--release"; do
  tag="${prof:+_release}"
  run_scenario "const_kinds$tag" "$const_kinds_base" "$const_kinds_edit" 1 "$prof"
  expect_exits "const_kinds$tag" 31 52
done

# const across modules and in a body: a pub const's value edit in an imported module must
# re-lower exactly the fns that name it (here through `limits.N` and a local const folding
# it); the module's other fns and the importer's other fns are served from the cache.
run_cross_const() {
  local prof="$1" tag="${1:+_release}"
  local name="cross_const$tag" d="$work/cross_const$tag"; mkdir -p "$d/lib"
  ( cd "$d" && rm -rf .toy )
  cat > "$d/main.toy" <<'TOY'
import lib/limits
fn cap() -> int {
    K :=: limits.N * 2
    K
}
fn other(n: int) -> int { n - 2 }
fn main() -> int { return cap() + limits.unrelated() + other(2) }
TOY
  cat > "$d/lib/limits.toy" <<'TOY'
pub N :=: 5
pub fn unrelated() -> int { 1 }
TOY
  ( cd "$d" && "$toyc" $prof -o base.bin main.toy >/dev/null 2>&1 ) \
    || { fail_one "$name: cold build failed"; return; }
  local full_compiled
  full_compiled="$( cd "$d" && "$toyc" $prof -o /dev/null --codegen-stats --no-cache main.toy 2>&1 )"; full_compiled="$(compiled_of "$full_compiled")"
  cat > "$d/lib/limits.toy" <<'TOY'
pub N :=: 7
pub fn unrelated() -> int { 1 }
TOY
  local inc_out
  inc_out="$( cd "$d" && "$toyc" $prof -o inc.bin --codegen-stats main.toy 2>&1 )"
  ( cd "$d" && "$toyc" $prof -o force.bin --no-cache main.toy >/dev/null 2>&1 ) \
    || { fail_one "$name: force build failed"; return; }
  local ih fh
  ih="$(texthash "$d/inc.bin")"; fh="$(texthash "$d/force.bin")"
  if [ "$ih" != "$fh" ]; then
    fail_one "$name: SOUNDNESS — inc __text ($ih) != force __text ($fh) [STALE-CACHE MISCOMPILE]"
    return
  fi
  local comp
  comp="$(compiled_of "$inc_out")"
  if [ -n "$comp" ] && [ -n "$full_compiled" ] && [ "$comp" -lt "$full_compiled" ]; then
    echo "  OK   $name: SOUND; CUTOFF codegen compiled=$comp < full=$full_compiled"
    pass=$((pass + 1))
  else
    fail_one "$name: CUTOFF — codegen compiled=$comp NOT < full=$full_compiled"
  fi
  expect_exits "$name" 11 15
}
run_cross_const ""
run_cross_const "--release"

# 7) LAMBDA, SPEC AND ADAPTER UNITS (#39) — each is cached under a key built from content
#    that already exists: a lambda under its owner's fingerprint, a spec unit under its
#    instance's and its targets', an adapter under what it wraps and the layouts it moves,
#    an erased unit under its key type and witness. Every edit below must reach the warm
#    binary at -O0 and at --release (which inlines into these units), and equal a
#    --no-cache build.
lambda_base='fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    k := 3
    f := fn(x: int) -> int { x + k }
    g := fn(x: int) -> int { x * 2 }
    return f(1) + g(2) + unrelated(0)
}
'
lambda_body='fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    k := 3
    f := fn(x: int) -> int { x + k + 10 }
    g := fn(x: int) -> int { x * 2 }
    return f(1) + g(2) + unrelated(0)
}
'
# Swapping the lambdas swaps their ranks: `main$l0` now names the other body.
lambda_reorder='fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    k := 3
    g := fn(x: int) -> int { x * 3 }
    f := fn(x: int) -> int { x + k }
    return f(1) + g(2) + unrelated(0)
}
'
capture_base='struct S { a: int }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    s := S { a: 5 }
    f := fn(x: int) -> int { x + s.a }
    return f(1) + unrelated(0)
}
'
# The capture's layout moves `a`: the lambda reads it at a new offset.
capture_layout='struct S { z: int, a: int }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    s := S { z: 30, a: 7 }
    f := fn(x: int) -> int { x + s.a }
    return f(1) + unrelated(0)
}
'
spec_base='fn add(a: int, b: int) -> int { a + b }
fn mul(a: int, b: int) -> int { a * b }
fn apply[T](f: fn(T, T) -> T, x: T) -> T { f(x, x) }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int { return apply(add, 3) + unrelated(0) }
'
spec_target_body='fn add(a: int, b: int) -> int { a + b + 1 }
fn mul(a: int, b: int) -> int { a * b }
fn apply[T](f: fn(T, T) -> T, x: T) -> T { f(x, x) }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int { return apply(add, 3) + unrelated(0) }
'
spec_target_swap='fn add(a: int, b: int) -> int { a + b }
fn mul(a: int, b: int) -> int { a * b }
fn apply[T](f: fn(T, T) -> T, x: T) -> T { f(x, x) }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int { return apply(mul, 3) + unrelated(0) }
'
bound_base='struct C { n: int }
impl C { fn get(self) -> int { self.n } }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    c := C { n: 5 }
    f := c.get
    return f() + unrelated(0)
}
'
# The receiver's layout behind the bound method moves `n`.
bound_layout='struct C { z: int, n: int }
impl C { fn get(self) -> int { self.n } }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    c := C { z: 40, n: 6 }
    f := c.get
    return f() + unrelated(0)
}
'
fnval_base='fn add(a: int, b: int) -> int { a + b }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    g := add
    return g(1, 2) + unrelated(0)
}
'
fnval_body='fn add(a: int, b: int) -> int { a * 10 + b }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    g := add
    return g(1, 2) + unrelated(0)
}
'
erased_base='import std/map
struct K { a: int, b: int }
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    m := Map[K, int].new()
    m.set(K { a: 1, b: 2 }, 10)
    return m.get(K { a: 1, b: 9 }).or(4) + unrelated(0)
}
'
# The key gains a Hashable impl that ignores `b`: the erased eq and hash must call it.
erased_impl='import std/map
struct K { a: int, b: int }
impl K has Hashable {
    fn hash(self) -> int { self.a }
    fn eq(self, o: K) -> bool { self.a == o.a }
}
fn unrelated(n: int) -> int { return n + n }
fn main() -> int {
    m := Map[K, int].new()
    m.set(K { a: 1, b: 2 }, 10)
    return m.get(K { a: 1, b: 9 }).or(4) + unrelated(0)
}
'
for prof in "" "--release"; do
  tag="${prof:+_release}"
  run_scenario "lambda_body$tag" "$lambda_base" "$lambda_body" 1 "$prof"
  expect_exits "lambda_body$tag" 8 18
  run_scenario "lambda_reorder$tag" "$lambda_base" "$lambda_reorder" 1 "$prof"
  expect_exits "lambda_reorder$tag" 8 10
  run_scenario "capture_layout$tag" "$capture_base" "$capture_layout" 0 "$prof"
  expect_exits "capture_layout$tag" 6 8
  run_scenario "spec_target_body$tag" "$spec_base" "$spec_target_body" 1 "$prof"
  expect_exits "spec_target_body$tag" 6 7
  run_scenario "spec_target_swap$tag" "$spec_base" "$spec_target_swap" 1 "$prof"
  expect_exits "spec_target_swap$tag" 6 9
  run_scenario "bound_layout$tag" "$bound_base" "$bound_layout" 0 "$prof"
  expect_exits "bound_layout$tag" 5 6
  run_scenario "fnval_body$tag" "$fnval_base" "$fnval_body" 1 "$prof"
  expect_exits "fnval_body$tag" 3 12
  run_scenario "erased_impl$tag" "$erased_base" "$erased_impl" 0 "$prof"
  expect_exits "erased_impl$tag" 4 10
done

# Profile switches over one warm cache: each profile's warm build of a closure-heavy
# program equals its --no-cache build, and a second warm build lowers nothing.
run_profile_switch() {
  local d="$work/profiles"; mkdir -p "$d"
  ( cd "$d" && rm -rf .toy )
  cp "$root/tests/corpora/language-features/closures/escape_std_methods.toy" "$d/prog.toy"
  local prof n=0 ok=1 out comp
  for prof in "-O0" "-O1" "--release" "--gc-stress" "-O0" "--release --gc-stress" "-O1"; do
    n=$((n + 1))
    ( cd "$d" && "$toyc" $prof -o "w$n.bin" prog.toy >/dev/null 2>&1 ) || { fail_one "profiles: $prof warm build failed"; return; }
    out="$( cd "$d" && "$toyc" $prof -o "x$n.bin" --codegen-stats prog.toy 2>&1 )"
    ( cd "$d" && "$toyc" $prof -o "f$n.bin" --no-cache prog.toy >/dev/null 2>&1 ) || { fail_one "profiles: $prof force build failed"; return; }
    if [ "$(texthash "$d/w$n.bin")" != "$(texthash "$d/f$n.bin")" ]; then
      fail_one "profiles: SOUNDNESS — $prof warm __text != force __text [STALE-CACHE MISCOMPILE]"; ok=0
    fi
    comp="$(compiled_of "$out")"
    if [ "$comp" != 0 ]; then fail_one "profiles: $prof no-edit rebuild compiled=$comp, want 0"; ok=0; fi
  done
  if [ "$ok" = 1 ]; then
    echo "  OK   profiles: every profile switch SOUND; no-edit rebuilds compiled=0"
    pass=$((pass + 1))
  fi
}
run_profile_switch

echo "--- incremental battery: $pass scenario(s) sound+cutoff, $fail failed ---"
[ "$fail" -eq 0 ]
