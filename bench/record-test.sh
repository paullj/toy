#!/usr/bin/env bash
# Check when record.sh appends to bench/history.jsonl, against a scratch git repo and
# canned results, so it runs in CI without timing anything.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# record.sh writes its temp files here, so the trap removes them.
mkdir "$work/tmp"
export TMPDIR="$work/tmp"
repo="$work/repo"
fails=0

export BENCH_MACHINE='{"id":"m1","chip":"Test Chip","model":"Test1,1","p_cores":4,"e_cores":4,"ram_bytes":1024,"macos":"1.0","zig":"0.16.0","power":"ac","low_power":false,"load_avg_1m":0.5}'

# result NAME INSTRUCTIONS [STDDEV]
result() {
  printf '{"name":"%s","kind":"runtime","runs":2,"metrics":{"instructions":%d,"cycles":1,"max_rss_bytes":1,"peak_footprint_bytes":1048576,"wall_median_s":0.5,"wall_mean_s":0.5,"wall_stddev_s":%s,"wall_min_s":0.49,"wall_max_s":0.51,"user_s":0.4,"sys_s":0.1},"checksum":"1","checksum_ok":true}\n' "$1" "$2" "${3:-0.01}"
}
result a 1000 >"$work/run1.jsonl"
result b 2000 >>"$work/run1.jsonl"
result a 1100 >"$work/run2.jsonl"
result b 2000 >>"$work/run2.jsonl"
result a 1000 >"$work/partial.jsonl"
result a 1210 >"$work/run3.jsonl"
result b 2000 >>"$work/run3.jsonl"
result a 1000 null >"$work/nostddev.jsonl"
result b 2000 >>"$work/nostddev.jsonl"

g() { git -C "$repo" "$@"; }
mkdir -p "$repo/bench"
g init -q -b main
g config user.email bench@example.com
g config user.name bench
echo '[{"name":"a"},{"name":"b"}]' >"$repo/bench/benchmarks.json"
: >"$repo/bench/history.jsonl"
echo 1 >"$repo/src.txt"
g add -A
g commit -q -m "first"

# run RESULTS EXPECTED_NEW_LINES WHAT [OUTPUT_PATTERN]
run() {
  local before after out
  before="$(wc -l <"$repo/bench/history.jsonl")"
  out="$(cd "$repo" && bash "$here/record.sh" "$work/$1" 2>&1)" || { echo "FAIL: $3: record.sh exited non-zero"; echo "$out"; fails=$((fails + 1)); return; }
  after="$(wc -l <"$repo/bench/history.jsonl")"
  if [ $((after - before)) -ne "$2" ]; then
    echo "FAIL: $3: appended $((after - before)) lines, expected $2"
    echo "$out"
    fails=$((fails + 1))
  elif [ -n "${4:-}" ] && ! grep -qE "$4" <<<"$out"; then
    echo "FAIL: $3: output lacks /$4/"
    echo "$out"
    fails=$((fails + 1))
  else
    echo "ok: $3"
  fi
  last_out="$out"
}

run run1.jsonl 2 "main, clean, new commit appends one line per benchmark" "appended 2 records"
if [ "$(jq -s -c '[.[] | {sha, subject, name, id: .machine.id}] | map(.sha |= .[:0])' "$repo/bench/history.jsonl")" != \
  '[{"sha":"","subject":"first","name":"a","id":"m1"},{"sha":"","subject":"first","name":"b","id":"m1"}]' ] ||
  [ "$(jq -r .sha "$repo/bench/history.jsonl" | sort -u)" != "$(g rev-parse HEAD)" ]; then
  echo "FAIL: the records lack the commit or machine"; fails=$((fails + 1))
fi

run run2.jsonl 0 "a second run at the same commit appends nothing" "already recorded"
tmp="$(sed -n 's/^records: //p' <<<"$last_out")"
[ -s "$tmp" ] && [ "$(wc -l <"$tmp")" -eq 2 ] || { echo "FAIL: no temp file with the records"; fails=$((fails + 1)); }
grep -qE '^a .*\+10%' <<<"$last_out" || { echo "FAIL: no +10% change against the main record"; echo "$last_out"; fails=$((fails + 1)); }
grep -qE '^benchmark .*cycles.*min\.\.max.*user/sys' <<<"$last_out" || { echo "FAIL: the table lacks cycles, min..max or user/sys"; echo "$last_out"; fails=$((fails + 1)); }

run nostddev.jsonl 0 "a result without a stddev still reports and keeps its records" "records: "
grep -qE '^a ' <<<"$last_out" && ! grep -q 'error' <<<"$last_out" || { echo "FAIL: no row for the result without a stddev"; echo "$last_out"; fails=$((fails + 1)); }

g add bench/history.jsonl
g commit -q -m "bench: record first"
run run2.jsonl 0 "a commit of only the history file is not a new point" "nothing but bench/history.jsonl"

echo 2 >"$repo/src.txt"
run run2.jsonl 0 "a dirty tree appends nothing" "the tree has changes"
echo untracked >"$repo/new.txt"
g checkout -q src.txt
run run2.jsonl 0 "an untracked file counts as dirty" "the tree has changes"
rm "$repo/new.txt"

g commit -q -am "change" --allow-empty
echo 3 >"$repo/src.txt"
g commit -q -am "change src"
run partial.jsonl 0 "a filtered run appends nothing" "only some benchmarks ran"

g checkout -q -b feature
echo 4 >"$repo/src.txt"
g commit -q -am "feature work"
run run2.jsonl 0 "another branch appends nothing" "not on main"
grep -qE '^a .*\+10%' <<<"$last_out" || { echo "FAIL: branch run lacks the change against main"; fails=$((fails + 1)); }

g checkout -q main
# An uncommitted history file does not make the tree dirty.
echo '{"sha":"0000000","name":"x","machine":{"id":"other"}}' >>"$repo/bench/history.jsonl"
run run2.jsonl 2 "main at a new commit appends, the history file's own edits aside" "appended 2 records"

other='{"id":"m2","chip":"Other","model":"O1,1","p_cores":8,"e_cores":4,"ram_bytes":2048,"macos":"1.0","zig":"0.16.0","power":"ac","low_power":false,"load_avg_1m":9}'
battery="$(jq -c '.power = "battery"' <<<"$other")"
low_power="$(jq -c '.low_power = true' <<<"$other")"
BENCH_MACHINE="$battery" run run1.jsonl 0 "a run on battery appends nothing" "not recorded: on battery power"
BENCH_MACHINE="$low_power" run run1.jsonl 0 "a run in Low Power Mode appends nothing" "not recorded: Low Power Mode is on"
grep -q '^records: ' <<<"$last_out" || { echo "FAIL: a Low Power Mode run does not keep its records"; fails=$((fails + 1)); }
BENCH_MACHINE="$other" run run1.jsonl 2 "another machine records the same commit, a high load only warns" "appended 2 records"

# run.sh probes before the build, so the warnings come while the user can still act.
probe="$(BENCH_MACHINE="$battery" bash "$here/machine.sh" 2>"$work/warn")" || true
[ "$probe" = "$battery" ] || { echo "FAIL: machine.sh does not pass BENCH_MACHINE through: $probe"; fails=$((fails + 1)); }
grep -q "on battery" "$work/warn" && grep -q "load average 9" "$work/warn" ||
  { echo "FAIL: machine.sh does not warn on battery and load"; cat "$work/warn"; fails=$((fails + 1)); }
grep -q "Low Power Mode" <<<"$(BENCH_MACHINE="$low_power" bash "$here/machine.sh" 2>&1 >/dev/null)" ||
  { echo "FAIL: machine.sh does not warn in Low Power Mode"; fails=$((fails + 1)); }
[ -z "$(BENCH_MACHINE="$BENCH_MACHINE" bash "$here/machine.sh" 2>&1 >/dev/null)" ] || { echo "FAIL: machine.sh warns on an idle machine"; fails=$((fails + 1)); }
jq -e '.id and .chip and .p_cores and .ram_bytes and .power and (.low_power | type == "boolean") and (.load_avg_1m | type == "number")' <<<"$(bash "$here/machine.sh" 2>/dev/null)" >/dev/null ||
  { echo "FAIL: the machine probe lacks fields"; fails=$((fails + 1)); }

# A branch made before the latest main record compares with that record, not with its own
# stale copy of the history.
g commit -q -m "bench: record change src" bench/history.jsonl
g checkout -q feature
run run3.jsonl 0 "a stale branch compares with main's latest record" "not on main"
grep -qE '^a .*\+10%' <<<"$last_out" || { echo "FAIL: the stale branch does not compare with main's latest record"; echo "$last_out"; fails=$((fails + 1)); }

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all record.sh rules hold"
