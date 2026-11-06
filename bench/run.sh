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
# shellcheck source=bench/lib.sh
. "$here/lib.sh"
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

toy="$(release_toy "$root")"

# A fresh dir per run: macOS can kill a binary rebuilt over the path of one it ran before.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: >"$work/results.jsonl"

fails=0
while IFS= read -r bench; do
  name="$(jq -r .name <<<"$bench")"
  kind="$(jq -r .kind <<<"$bench")"
  if [ -n "$filter" ] && ! [[ "$name" =~ $filter ]]; then continue; fi
  echo "running $name ($kind, $runs runs)..."
  checksum=""
  lines=""
  cache=cold

  case "$kind" in
    runtime)
      src="$here/$(jq -r .source <<<"$bench")"
      checksum="$(expected_checksum "$src")"
      [ -n "$checksum" ] || { echo "  $name: no '# expect: stdout' checksum line in ${src#"$root"/}"; exit 2; }
      bin="$work/$name"
      (cd "$work" && "$toy" build --release -o "$bin" "$src") >/dev/null
      dir="$work"
      cmd=("$bin")
      prepare=()
      ;;
    compiler)
      # The project is a generator under compiler/ and its arguments; benchmarks that
      # name the same project share one generated dir.
      gen="$(jq -r '.project[0]' <<<"$bench")"
      dir="$work/$(jq -r '.project | join("_") | gsub("[^A-Za-z0-9_.-]"; "_")' <<<"$bench")"
      if ! [ -d "$dir" ]; then
        gen_args=()
        while IFS= read -r a; do gen_args+=("$a"); done < <(jq -r '.project[1:][]' <<<"$bench")
        bash "$here/compiler/$gen" "$dir" ${gen_args[@]+"${gen_args[@]}"} >/dev/null
      fi
      lines="$(find "$dir" -name .toy -prune -o -type f -name '*.toy' -print0 | xargs -0 cat | wc -l | tr -d ' ')"
      cmd=("$toy")
      while IFS= read -r a; do cmd+=("$a"); done < <(jq -r '.args[]' <<<"$bench")
      cache="$(jq -r '.cache // "cold"' <<<"$bench")"
      case "$cache" in
        # Cold: every timed run starts without the project's .toy/ cache.
        cold) prepare=(--prepare "rm -rf .toy") ;;
        # Warm: hyperfine's warmup run fills the cache the timed runs reuse.
        warm) prepare=() ;;
        *) echo "  $name: unknown cache '$cache'"; exit 2 ;;
      esac
      ;;
    *) echo "  $name: unknown kind '$kind'"; exit 2 ;;
  esac

  (cd "$dir" && hyperfine -N --warmup 1 --runs "$runs" ${prepare[@]+"${prepare[@]}"} --style none \
    --export-json "$work/$name.json" "$(printf '%q ' "${cmd[@]}")")
  if [ "$cache" = cold ]; then rm -rf "$dir/.toy"; fi
  (cd "$dir" && /usr/bin/time -l "${cmd[@]}" >"$work/$name.out" 2>"$work/$name.time")

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

  m="$(bench_metrics "$work/$name.json" "$work/$name.time")"
  jq -c -n --arg name "$name" --arg kind "$kind" --argjson runs "$runs" \
    --arg checksum "$got" --argjson ok "$ok" --argjson m "$m" --arg lines "$lines" \
    '{name: $name, kind: $kind, runs: $runs, metrics: $m,
      lines: (if $lines == "" then null else ($lines | tonumber) end),
      checksum: (if $checksum == "" then null else $checksum end), checksum_ok: $ok}' \
    >>"$work/results.jsonl"
done < <(jq -c '.[]' "$here/benchmarks.json")

[ -s "$work/results.jsonl" ] || { echo "no benchmark matches '$filter'"; exit 2; }

(cd "$root" && bash "$here/record.sh" "$work/results.jsonl")
[ "$fails" -eq 0 ] || { echo "$fails checksum mismatch(es)"; exit 1; }
