#!/usr/bin/env bash
# Generate a multi-module toy project that leans on the heavy language features.
#   usage: feature.sh <out_dir> <n_modules> <groups_per_module>
# gen.sh projects are plain int fns, so they flatter the typechecker (#190). Each group
# here declares a generic struct with three instantiations and a generic method, a
# protocol with a plain and a generic conformance and a `has`-bounded fn, a payload
# enum with a `match`, Option and Result chains with `?`, closures and fn values, and
# derived Eq/Hash/Display through Set, Map and to_string, over Vec, Map, Set and str.
# Module k imports module k-1, uses its types, generics and bounded fns, and calls its
# entry, so main reaches every module.
set -eu
out="${1:?out_dir}"; N="${2:?n_modules}"; G="${3:?groups_per_module}"
rm -rf "$out"; mkdir -p "$out"

group() {
  local k="$1" g="$2" s="${1}_${2}"
  cat <<EOF

pub protocol Score_$s { fn score(self) -> int }

pub struct Pair_$s[T] { pub a: T, pub b: T }

impl Pair_$s[T] {
    fn swap(self) -> Pair_$s[T] { Pair_$s { a: self.b, b: self.a } }
    fn map[U](self, f: fn(T) -> U) -> Pair_$s[U] { Pair_$s { a: f(self.a), b: f(self.b) } }
}

pub struct Item_$s { pub id: int, pub name: str }

impl Item_$s has Score_$s {
    fn score(self) -> int { self.id * 2 + self.name.len() }
}

impl Pair_$s[T] has Score_$s {
    fn score(self) -> int { $g + 1 }
}

pub enum Shape_$s { dot, circle(int), rect { w: int, h: int } }

fn area_$s(sh: Shape_$s) -> int {
    match sh {
        .dot -> 0,
        .circle(r) -> 3 * r * r,
        .rect { w, h } -> w * h,
    }
}

pub fn total_$s[T has Score_$s](xs: Vec[T]) -> int {
    xs.fold(0, fn(acc, x) { acc + x.score() })
}

fn or_default_$s[T](o: Option[T], d: T) -> T {
    match o { .some(v) -> v, .none -> d }
}

fn parse_$s(n: int) -> Result[int, str] {
    if n < 0 { return Result[int, str].err("negative") }
    return Result.ok(n + $g)
}

fn chain_$s(n: int) -> Result[int, str] {
    a := parse_$s(n)?
    b := parse_$s(a)?
    return Result.ok(a + b)
}

fn first_even_$s(xs: Vec[int]) -> Option[int] {
    for x in xs { if x % 2 == 0 { return Option.some(x) } }
    return Option.none
}

fn half_first_even_$s(xs: Vec[int]) -> Option[int] {
    v := first_even_$s(xs)?
    return Option.some(v / 2)
}

fn make_scaler_$s(k: int) -> fn(int) -> int { fn(x) { x * k + $g } }

pub fn run_$s(n: int) -> int {
    items: Vec[Item_$s] = []
    for i in 0..4 { items.push(Item_$s { id: i + n, name: "item".concat(i.to_string()) }) }
    seen := Set[Item_$s].new()
    for it in items { seen.add(it) }
    seen.add(Item_$s { id: n, name: "item0" })
    scores := Map[str, int].new()
    for it in items { scores.set(it.name, it.score()) }
    ints := Pair_$s { a: n, b: 2 }.swap().map(make_scaler_$s(3))
    lens := Pair_$s { a: "ab", b: "cde" }.map(fn(t) { t.len() })
    flags := Pair_$s { a: true, b: false }.map(fn(f) { if f { 1 } else { 0 } })
    pairs: Vec[Pair_$s[int]] = [ints, lens, flags]
    shapes: Vec[Shape_$s] = [Shape_$s.dot, Shape_$s.circle(n), Shape_$s.rect { w: n, h: $g + 1 }]
    area := area_$s
    areas := shapes |> .map(area) |> .fold(0, fn(acc, x) { acc + x })
    evens := items |> .map(fn(it) { it.id }) |> .filter(fn(x) { x % 2 == 0 })
    label := Item_$s { id: $g, name: "x" }.to_string()
    probe := Item_$s { id: n, name: "item0" }
    same := if items[0] == probe { 1 } else { 0 }
    ok := match chain_$s(n) { .ok(v) -> v, .err(_) -> 0 }
    return total_$s(items) + total_$s(pairs) + seen.len() + or_default_$s(scores.get("item1"), 0) +
        areas + evens.len() + label.len() + same + ok + or_default_$s(half_first_even_$s(evens), 7)
}
EOF
  if [ "$k" -gt 0 ]; then
    local p="$((k - 1))_$g" m="mod_$((k - 1))"
    cat <<EOF

fn upstream_$s(n: int) -> int {
    xs: Vec[$m.Item_$p] = [$m.Item_$p { id: n, name: "up" }]
    ys: Vec[$m.Pair_$p[str]] = [$m.Pair_$p { a: "u", b: "v" }]
    return $m.total_$p(xs) + $m.total_$p(ys) + $m.run_$p(n)
}
EOF
  fi
}

for k in $(seq 0 $((N - 1))); do
  {
    echo "import std/vec"
    echo "import std/map"
    echo "import std/set"
    echo "import std/str"
    [ "$k" -gt 0 ] && echo "import mod_$((k - 1))"
    for g in $(seq 0 $((G - 1))); do group "$k" "$g"; done
    echo
    echo "pub fn entry(n: int) -> int {"
    echo "    total := 0"
    for g in $(seq 0 $((G - 1))); do
      if [ "$k" -gt 0 ]; then
        echo "    total += run_${k}_$g(n) + upstream_${k}_$g(n)"
      else
        echo "    total += run_${k}_$g(n)"
      fi
    done
    # Chaining entry keeps every module reachable from main, so a build generates code
    # for all of them, not only the two that upstream_ reaches.
    [ "$k" -gt 0 ] && echo "    total += mod_$((k - 1)).entry(n)"
    echo "    return total"
    echo "}"
  } >"$out/mod_$k.toy"
done
# The corpus runs the checked-in feature/ (3 modules x 2 groups), so its main.toy also
# carries `# expect: exit 41`; a regenerated main.toy needs its own.
{
  echo "import mod_$((N - 1))"
  echo "fn main() -> int { return mod_$((N - 1)).entry(7) % 256 }"
} >"$out/main.toy"
echo "generated $N modules x $G feature groups -> $out/main.toy"
