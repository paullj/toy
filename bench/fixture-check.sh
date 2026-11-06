#!/usr/bin/env bash
# The corpus runs checked-in snapshots of the compiler-set generators, so CI only tests
# the generators if each snapshot still equals a fresh run. A snapshot's main.toy adds
# its `# expect:` line, which the generator cannot know.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
check() {
  local fixture="$1"; shift
  bash "$here/compiler/$1" "$work/$fixture" "${@:2}" >/dev/null
  if ! diff -r -I '^# expect: ' "$here/compiler/$fixture" "$work/$fixture"; then
    echo "FAIL: bench/compiler/$fixture differs from '$*'; regenerate it and keep its # expect: line"
    fails=$((fails + 1))
  fi
}

check medium gen.sh 100 12
check feature feature.sh 3 2
[ "$fails" -eq 0 ] && echo "fixture-check: snapshots match their generators"
exit "$fails"
