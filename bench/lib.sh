# shellcheck shell=bash
# Shared by run.sh and peers/run.sh; source it.

# The checksum a runtime benchmark must print: its `# expect: stdout` line, which the
# corpus checks in CI too, so the checksum has one source.
expected_checksum() {
  sed -n 's/^# expect: stdout "\(.*\)\\n"$/\1/p' "$1"
}

# bench_metrics HYPERFINE_JSON TIME_L_OUTPUT: one metrics object from a hyperfine export
# (wall, user and sys time) and one `/usr/bin/time -l` run (instructions, cycles, memory).
bench_metrics() {
  local t
  t="$(awk '
    /instructions retired/      { i = $1 }
    /cycles elapsed/            { c = $1 }
    /maximum resident set size/ { r = $1 }
    /peak memory footprint/     { p = $1 }
    END {
      # A field this macOS does not print must fail the run, not be recorded as 0.
      if (i == "" || c == "" || r == "" || p == "") { print "time -l lacks a field: " FILENAME > "/dev/stderr"; exit 1 }
      printf "{\"instructions\":%d,\"cycles\":%d,\"max_rss_bytes\":%d,\"peak_footprint_bytes\":%d}\n", i, c, r, p
    }
  ' "$2")"
  jq -c --argjson t "$t" '.results[0].summary as $s
    | $t + {wall_median_s: $s.time_wall_clock.median, wall_mean_s: $s.time_wall_clock.mean,
        wall_stddev_s: $s.time_wall_clock.stddev, wall_min_s: $s.time_wall_clock.min,
        wall_max_s: $s.time_wall_clock.max, user_s: $s.time_user.mean, sys_s: $s.time_system.mean}' "$1"
}

# release_toy ROOT: build a ReleaseFast toy and print its path.
release_toy() {
  local out="$1/zig-out/bench"
  echo "building toy (ReleaseFast) into zig-out/bench..." >&2
  # A separate prefix keeps the Debug zig-out/bin/toy the tests use untouched. Callers
  # run this in $(...), where set -e is off, so a failed build must return by hand.
  (cd "$1" && zig build -Doptimize=ReleaseFast -p "$out") >&2 || return 1
  echo "$out/bin/toy"
}
