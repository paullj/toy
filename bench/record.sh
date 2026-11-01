#!/usr/bin/env bash
# Turn one run's results into history records and report them.
#   usage: bench/record.sh RESULTS_JSONL
# Called by run.sh from the root of the repo under test. Each input line is one
# benchmark's result; each output line adds the commit and the machine. The lines are
# appended to bench/history.jsonl only on main, on a tree that is clean apart from that
# file, at a commit this machine has not recorded whose diff from the last recorded one
# touches more than that file. Otherwise they go to a temp file. The table compares each
# benchmark with the latest main record from the same machine. Nothing is committed.
# BENCH_MACHINE (a JSON object, from machine.sh) is the machine block; run.sh probes it
# before the build. Without it, record.sh probes the machine itself.
set -euo pipefail

results="${1:?usage: record.sh RESULTS_JSONL}"
root="$(git rev-parse --show-toplevel)"
hist_rel="bench/history.jsonl"
hist="$root/$hist_rel"
[ -f "$hist" ] || : >"$hist"

here="$(cd "$(dirname "$0")" && pwd)"
machine="${BENCH_MACHINE:-$(bash "$here/machine.sh")}"
mid="$(jq -r .id <<<"$machine")"

head="$(git -C "$root" rev-parse HEAD)"
records="$(jq -c --arg sha "$head" \
  --arg subject "$(git -C "$root" log -1 --format=%s)" \
  --arg commit_date "$(git -C "$root" log -1 --format=%cI)" \
  --arg run_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson machine "$machine" \
  '{sha: $sha, subject: $subject, commit_date: $commit_date, run_date: $run_date} + . + {machine: $machine}' \
  "$results")"

last="$(jq -r --arg m "$mid" 'select(.machine.id == $m) | .sha' "$hist" | tail -1)"
why=""
if [ "$(git -C "$root" symbolic-ref --short -q HEAD || true)" != main ]; then
  why="not on main"
elif [ -n "$(git -C "$root" status --porcelain -- . ":(exclude)$hist_rel")" ]; then
  why="the tree has changes"
elif jq -e --arg m "$mid" --arg sha "$head" 'select(.machine.id == $m and .sha == $sha)' "$hist" >/dev/null; then
  why="$(git -C "$root" rev-parse --short HEAD) is already recorded"
elif [ -n "$last" ] && git -C "$root" cat-file -e "$last^{commit}" 2>/dev/null &&
  [ -z "$(git -C "$root" diff --name-only "$last" HEAD -- . ":(exclude)$hist_rel")" ]; then
  why="HEAD changes nothing but $hist_rel since the last record"
fi
if jq -e 'select(.checksum_ok == false)' <<<"$records" >/dev/null; then
  why="a checksum failed"
fi
# A filtered run would mark the commit recorded with the other benchmarks missing.
if [ "$(jq -c '[.[].name] | sort' "$root/bench/benchmarks.json")" != "$(jq -c -s '[.[].name] | sort' "$results")" ]; then
  why="only some benchmarks ran"
fi

# The baseline is read before appending, so an appended run compares with the previous one.
# A branch reads main's history: its own copy stops at the branch point, while main gains
# records.
base_src="$hist"
if [ "$(git -C "$root" symbolic-ref --short -q HEAD || true)" != main ] &&
  git -C "$root" cat-file -e "main:$hist_rel" 2>/dev/null; then
  base_src="$(mktemp "${TMPDIR:-/tmp}/toy-bench-base.XXXXXX")"
  trap 'rm -f "$base_src"' EXIT
  git -C "$root" show "main:$hist_rel" >"$base_src"
fi
baseline="$(jq -c -s --arg m "$mid" \
  'map(select(.machine.id == $m)) | group_by(.name) | map({key: .[0].name, value: last}) | from_entries' \
  "$base_src")"

# The records are kept before the table is printed, so a formatting error cannot lose a run.
if [ -z "$why" ]; then
  printf '%s\n' "$records" >>"$hist"
else
  tmpdir="${TMPDIR:-/tmp}"
  tmp="$(mktemp "${tmpdir%/}/toy-bench.XXXXXX")"
  printf '%s\n' "$records" >"$tmp"
fi

echo
{
  printf 'benchmark\tinstructions\tΔ\tcycles\twall median\t± stddev\tmin..max\tΔ\tuser/sys\tpeak mem\tΔ\tchecksum\n'
  jq -r --argjson base "$baseline" '
    def num(f): if . == null then "-" else f end;
    def mega: num(. / 1e6 | . * 10 | round / 10 | tostring + "M");
    def ms: num(. * 1000 | . * 10 | round / 10 | tostring + " ms");
    def mib: num(. / 1048576 | . * 10 | round / 10 | tostring + " MiB");
    def delta($old; $new):
      if $old == null or $old == 0 or $new == null then "-"
      else ($new / $old - 1) * 100 | . * 10 | round / 10
        | (if . > 0 then "+" else "" end) + tostring + "%" end;
    $base[.name].metrics as $b
    | .metrics as $m
    | [.name,
       ($m.instructions | mega), delta($b.instructions; $m.instructions),
       ($m.cycles | mega),
       ($m.wall_median_s | ms), ($m.wall_stddev_s | ms),
       "\($m.wall_min_s | ms)..\($m.wall_max_s | ms)",
       delta($b.wall_median_s; $m.wall_median_s),
       "\($m.user_s | ms)/\($m.sys_s | ms)",
       ($m.peak_footprint_bytes | mib),
       delta($b.peak_footprint_bytes; $m.peak_footprint_bytes),
       (if .checksum == null then "-" elif .checksum_ok then "ok" else "FAIL" end)] | @tsv' \
    <<<"$records"
} | column -t -s "$(printf '\t')"
echo

if [ "$(jq -r 'length' <<<"$baseline")" -gt 0 ]; then
  echo "Δ: against the latest main record of machine $mid ($(jq -r '[.[] | .sha[:7]] | unique | join(", ")' <<<"$baseline"))"
fi

if [ -z "$why" ]; then
  echo "appended $(wc -l <<<"$records" | tr -d ' ') records to $hist_rel; commit it to keep them"
else
  echo "not recorded: $why"
  echo "records: $tmp"
fi
