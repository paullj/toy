#!/usr/bin/env bash
# Run the benchmarks in bench/benchmarks.json on the working tree and report each one.
#   usage: bench/run.sh [--runs N] [FILTER]
# FILTER is a regex matched against benchmark names. Wall time comes from hyperfine
# (N timed runs after one warmup); instructions, cycles and peak memory come from one
# `/usr/bin/time -l` run, since they barely move between runs. record.sh then prints
# the table and either appends to bench/history.jsonl or writes a temp file. A checksum
# mismatch fails the run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
runs=5
filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--runs) runs="${2:?--runs needs a count}"; shift 2 ;;
    -h|--help) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) filter="$1"; shift ;;
  esac
done

# hyperfine reports no stddev for a single run, and the spread is half the report.
[[ "$runs" =~ ^[0-9]+$ ]] && [ "$runs" -ge 2 ] || { echo "--runs needs a count of at least 2"; exit 2; }

for tool in hyperfine jq zig; do
  command -v "$tool" >/dev/null || { echo "missing $tool: run through mise (mise run bench)"; exit 2; }
done

# Before the build: the record wants the ambient load, not the load of this run.
BENCH_MACHINE="$(bash "$here/machine.sh")"
export BENCH_MACHINE

out="$root/zig-out/bench"
echo "building toy (ReleaseFast) into ${out#"$root"/}..."
# A separate prefix keeps the Debug zig-out/bin/toy the tests use untouched.
(cd "$root" && zig build -Doptimize=ReleaseFast -p "$out")
toy="$out/bin/toy"

# A fresh dir per run: macOS can kill a binary rebuilt over the path of one it ran before.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: >"$work/results.jsonl"

time_metrics() {
  awk '
    /instructions retired/      { i = $1 }
    /cycles elapsed/            { c = $1 }
    /maximum resident set size/ { r = $1 }
    /peak memory footprint/     { p = $1 }
    END {
      # A field this macOS does not print must fail the run, not be recorded as 0.
      if (i == "" || c == "" || r == "" || p == "") { print "time -l lacks a field: " FILENAME > "/dev/stderr"; exit 1 }
      printf "{\"instructions\":%d,\"cycles\":%d,\"max_rss_bytes\":%d,\"peak_footprint_bytes\":%d}\n", i, c, r, p
    }
  ' "$1"
}

fails=0
while IFS= read -r bench; do
  name="$(jq -r .name <<<"$bench")"
  kind="$(jq -r .kind <<<"$bench")"
  if [ -n "$filter" ] && ! [[ "$name" =~ $filter ]]; then continue; fi
  echo "running $name ($kind, $runs runs)..."
  checksum=""

  case "$kind" in
    runtime)
      src="$here/$(jq -r .source <<<"$bench")"
      # The corpus checks the same line in CI, so the checksum has one source.
      checksum="$(sed -n 's/^# expect: stdout "\(.*\)\\n"$/\1/p' "$src")"
      [ -n "$checksum" ] || { echo "  $name: no '# expect: stdout' checksum line in ${src#"$root"/}"; exit 2; }
      bin="$work/$name"
      (cd "$work" && "$toy" build --release -o "$bin" "$src") >/dev/null
      dir="$work"
      cmd=("$bin")
      prepare=()
      ;;
    compiler)
      read -r n m < <(jq -r '.project | "\(.[0]) \(.[1])"' <<<"$bench")
      dir="$work/gen_${n}x${m}"
      [ -d "$dir" ] || bash "$here/compiler/gen.sh" "$dir" "$n" "$m" >/dev/null
      cmd=("$toy")
      while IFS= read -r a; do cmd+=("$a"); done < <(jq -r '.args[]' <<<"$bench")
      # Cold cache: every timed run starts without the project's .toy/ cache.
      prepare=(--prepare "rm -rf .toy")
      ;;
    *) echo "  $name: unknown kind '$kind'"; exit 2 ;;
  esac

  (cd "$dir" && hyperfine -N --warmup 1 --runs "$runs" ${prepare[@]+"${prepare[@]}"} --style none \
    --export-json "$work/$name.json" "$(printf '%q ' "${cmd[@]}")")
  (cd "$dir" && rm -rf .toy && /usr/bin/time -l "${cmd[@]}" >"$work/$name.out" 2>"$work/$name.time")

  got=""
  ok=true
  if [ -n "$checksum" ]; then
    got="$(tr -d '\n' <"$work/$name.out")"
    if [ "$got" != "$checksum" ]; then
      echo "  FAIL: $name printed '$got', expected checksum '$checksum'"
      ok=false
      fails=$((fails + 1))
    fi
  fi

  t="$(time_metrics "$work/$name.time")"
  jq -c -n --arg name "$name" --arg kind "$kind" --argjson runs "$runs" \
    --arg checksum "$got" --argjson ok "$ok" \
    --slurpfile h "$work/$name.json" --argjson t "$t" \
    '$h[0].results[0].summary as $s
     | {name: $name, kind: $kind, runs: $runs,
        metrics: ($t + {wall_median_s: $s.time_wall_clock.median, wall_mean_s: $s.time_wall_clock.mean,
          wall_stddev_s: $s.time_wall_clock.stddev, wall_min_s: $s.time_wall_clock.min,
          wall_max_s: $s.time_wall_clock.max, user_s: $s.time_user.mean, sys_s: $s.time_system.mean}),
        checksum: (if $checksum == "" then null else $checksum end), checksum_ok: $ok}' \
    >>"$work/results.jsonl"
done < <(jq -c '.[]' "$here/benchmarks.json")

[ -s "$work/results.jsonl" ] || { echo "no benchmark matches '$filter'"; exit 2; }

(cd "$root" && bash "$here/record.sh" "$work/results.jsonl")
[ "$fails" -eq 0 ] || { echo "$fails checksum mismatch(es)"; exit 1; }
