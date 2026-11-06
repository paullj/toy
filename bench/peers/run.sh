#!/usr/bin/env bash
# Run each runtime benchmark of bench/benchmarks.json as toy and as its peer programs
# (bench/peers/<lang>/<name>.<ext>), check every checksum and write the results.
#   usage: bench/peers/run.sh [--runs N] [FILTER]
# FILTER is a regex matched against "<benchmark>/<lang>", e.g. "loops" or "/rust".
# Wall time comes from hyperfine (N timed runs after one warmup), instructions, cycles
# and peak memory from one `/usr/bin/time -l` run, the same as bench/run.sh. A benchmark
# with no peer program is skipped. A full run with every checksum right writes
# bench/results/peers.json; otherwise the results go to a temp file. A checksum mismatch
# fails the run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bench="$(dirname "$here")"
root="$(dirname "$bench")"
# shellcheck source=bench/lib.sh
. "$bench/lib.sh"
runs=5
filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--runs) runs="${2:?--runs needs a count}"; shift 2 ;;
    -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) filter="$1"; shift ;;
  esac
done
[[ "$runs" =~ ^[0-9]+$ ]] && [ "$runs" -ge 2 ] || { echo "--runs needs a count of at least 2"; exit 2; }

command -v mise >/dev/null || { echo "missing mise: the peer toolchains come from bench/peers/mise.toml"; exit 2; }
# The peer toolchains are optional, so a plain `mise install` at the root skips them and
# the first peer run installs them.
(cd "$here" && mise install)
eval "$(cd "$here" && mise env -s bash)"
for tool in hyperfine jq zig cc swiftc rustc go node python3; do
  command -v "$tool" >/dev/null || { echo "missing $tool"; exit 2; }
done

BENCH_MACHINE="$(bash "$bench/machine.sh")"
toy="$(release_toy "$root")"

toolchains="$(jq -n \
  --arg zig "$(zig version)" \
  --arg cc "$(cc --version | head -1)" \
  --arg rustc "$(rustc --version)" \
  --arg go "$(go version)" \
  --arg swiftc "$(swiftc --version 2>&1 | sed -n 's/.*\(Apple Swift version [^ ]*\).*/\1/p')" \
  --arg node "$(node --version)" \
  --arg python "$(python3 --version)" \
  '{toy: {version: ("zig " + $zig), flags: "zig build -Doptimize=ReleaseFast; toy build --release"},
    c: {version: $cc, flags: "cc -O2"},
    rust: {version: $rustc, flags: "rustc -C opt-level=3"},
    go: {version: $go, flags: "go build"},
    swift: {version: $swiftc, flags: "swiftc -O"},
    js: {version: ("node " + $node), flags: "node"},
    python: {version: $python, flags: "python3"}}')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: >"$work/results.jsonl"

langs=(toy c rust go swift js python)
# peer_src LANG NAME: the path of a peer program.
peer_src() {
  local e="$1"
  case "$1" in rust) e=rs ;; python) e=py ;; esac
  echo "$here/$1/$2.$e"
}

# program LANG NAME TOY_SOURCE: build one program and set cmd to the command that runs it.
program() {
  local lang="$1" bin="$work/$1-$2" src
  src="$(peer_src "$1" "$2")"
  case "$lang" in
    toy) (cd "$work" && "$toy" build --release -o "$bin" "$3") >/dev/null; cmd=("$bin") ;;
    c) cc -O2 -o "$bin" "$src"; cmd=("$bin") ;;
    rust) rustc -C opt-level=3 -o "$bin" "$src"; cmd=("$bin") ;;
    go) go build -o "$bin" "$src"; cmd=("$bin") ;;
    swift) swiftc -O -o "$bin" "$src"; cmd=("$bin") ;;
    js) cmd=(node "$src") ;;
    python) cmd=(python3 "$src") ;;
  esac
}

fails=0
while IFS= read -r b; do
  name="$(jq -r .name <<<"$b")"
  toy_src="$bench/$(jq -r .source <<<"$b")"
  checksum="$(expected_checksum "$toy_src")"
  [ -n "$checksum" ] || { echo "  $name: no '# expect: stdout' checksum line"; exit 2; }
  # Toy alone compares nothing; the site draws no chart for it.
  has_peer=false
  for lang in "${langs[@]:1}"; do
    if [ -f "$(peer_src "$lang" "$name")" ]; then has_peer=true; fi
  done
  if ! $has_peer; then
    echo "  $name: no peers"
    continue
  fi
  for lang in "${langs[@]}"; do
    if [ -n "$filter" ] && ! [[ "$name/$lang" =~ $filter ]]; then continue; fi
    if [ "$lang" != toy ] && [ ! -f "$(peer_src "$lang" "$name")" ]; then
      echo "  $name: no $lang peer"
      continue
    fi
    echo "running $name/$lang ($runs runs)..."
    program "$lang" "$name" "$toy_src"
    id="$name-$lang"
    (cd "$work" && hyperfine -N --warmup 1 --runs "$runs" --style none \
      --export-json "$work/$id.json" "$(printf '%q ' "${cmd[@]}")")
    (cd "$work" && /usr/bin/time -l "${cmd[@]}" >"$work/$id.out" 2>"$work/$id.time")
    got="$(tr -d '\n' <"$work/$id.out")"
    ok=true
    if [ "$got" != "$checksum" ]; then
      echo "  FAIL: $name/$lang printed '$got', expected checksum '$checksum'"
      ok=false
      fails=$((fails + 1))
    fi
    m="$(bench_metrics "$work/$id.json" "$work/$id.time")"
    src="$toy_src"
    [ "$lang" = toy ] || src="$(peer_src "$lang" "$name")"
    jq -c -n --arg name "$name" --arg lang "$lang" --arg source "${src#"$root"/}" \
      --arg checksum "$got" --argjson ok "$ok" --argjson m "$m" \
      '{name: $name, lang: $lang, source: $source, metrics: $m, checksum: $checksum, checksum_ok: $ok}' \
      >>"$work/results.jsonl"
  done
done < <(jq -c '.[] | select(.kind == "runtime")' "$bench/benchmarks.json")

[ -s "$work/results.jsonl" ] || { echo "nothing matches '$filter'"; exit 2; }

out="$bench/results/peers.json"
why=""
[ -z "$filter" ] || why="a FILTER was given"
[ "$fails" -eq 0 ] || why="a checksum failed"
if [ -n "$why" ]; then out="$(mktemp "${TMPDIR:-/tmp}/toy-peers.XXXXXX")"; fi
mkdir -p "$(dirname "$out")"
# Name the last commit that changed what toy's numbers depend on, not HEAD: a
# PR that only touches peers or the site is rehashed by its rebase merge, but
# this commit is already on main.
toy_paths=(packages/compiler packages/cli packages/lib build.zig build.zig.zon bench/runtime)
jq -n --slurpfile r "$work/results.jsonl" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg commit "$(git -C "$root" log -1 --format=%H -- "${toy_paths[@]}")" \
  --argjson dirty "$([ -z "$(git -C "$root" status --porcelain -- "${toy_paths[@]}")" ] && echo false || echo true)" \
  --argjson machine "$BENCH_MACHINE" --argjson toolchains "$toolchains" --argjson runs "$runs" \
  '{date: $date, toy_commit: $commit, toy_dirty: $dirty, runs: $runs, machine: $machine,
    toolchains: $toolchains, results: $r}' >"$out"

jq -r '(.results | map(select(.lang == "toy")) | map({key: .name, value: .metrics.wall_median_s}) | from_entries) as $toy
  | ["benchmark", "lang", "wall", "stddev", "x toy", "instructions", "peak mem"],
    (.results[] | .metrics as $m
     | [.name, .lang, "\($m.wall_median_s * 1000 | round) ms", "\($m.wall_stddev_s * 1000 | round) ms",
        (if $toy[.name] then "\($m.wall_median_s / $toy[.name] * 100 | round / 100)" else "-" end),
        "\($m.instructions)", "\($m.peak_footprint_bytes / 1048576 * 10 | round / 10) MB"])
  | @tsv' "$out" | column -t -s $'\t'

if [ -n "$why" ]; then echo "not written to bench/results/peers.json ($why): $out"; else echo "wrote bench/results/peers.json"; fi
[ "$fails" -eq 0 ] || { echo "$fails checksum mismatch(es)"; exit 1; }
