#!/usr/bin/env bash
# Generate the `own` shape of #41 and #104: one module of N small fns that each call
# generic methods of one generic struct at three type args, so typecheck time tracks N.
#   usage: own.sh <out_dir> <n_fns>
set -eu
out="${1:?out_dir}"; N="${2:?n_fns}"
rm -rf "$out"; mkdir -p "$out"
{
  cat <<'X'
import std/vec
struct Box[T] { v: T }
impl Box[T] {
    fn map[U](self, f: fn(T) -> U) -> Box[U] { Box { v: f(self.v) } }
    fn pick[U](self, a: U, _b: U) -> U { a }
    fn with[U](v: T, _tag: U) -> Box[T] { Box { v: v } }
    fn get(self) -> T { self.v }
}
fn _vecs() -> int {
    v := Vec[int].new()
    v.push(1)
    b := Box.with(v.len(), true)
    return b.map(fn(x) { x + 1 }).get() + Box[int].with(2, "s").get()
}
X
  for ((k = 0; k < N; k++)); do
    echo "fn _pad$k(b: Box[int]) -> int { b.pick($k, 1) + (if b.pick(true, false) { 1 } else { 0 }) + b.pick(\"s\", \"t\").len() }"
  done
  echo 'fn main() -> int { return 0 }'
} >"$out/main.toy"
echo "generated the own shape with $N fns -> $out/main.toy"
