#!/usr/bin/env bash
# Print the machine block of a history record as one JSON line, and warn on stderr when
# the Mac is on battery or loaded. run.sh calls it before the build, so the load is the
# ambient load and the warning comes while the user can still act on it.
# BENCH_MACHINE (a JSON object) replaces the probe, so tests can run anywhere.
set -euo pipefail

probe() {
  local chip model p e ram os zigv power load id
  chip="$(sysctl -n machdep.cpu.brand_string)"
  model="$(sysctl -n hw.model)"
  p="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)"
  e="$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0)"
  ram="$(sysctl -n hw.memsize)"
  os="$(sw_vers -productVersion)"
  zigv="$(zig version)"
  if pmset -g batt | head -1 | grep -q "AC Power"; then power=ac; else power=battery; fi
  load="$(sysctl -n vm.loadavg | awk '{print $2}')"
  # Only the hardware: a macOS or zig update is a change the history should show, not a
  # new series.
  id="$(printf '%s|%s|%s' "$chip" "$model" "$ram" | shasum -a 256 | cut -c1-8)"
  jq -c -n --arg id "$id" --arg chip "$chip" --arg model "$model" --argjson p "$p" \
    --argjson e "$e" --argjson ram "$ram" --arg os "$os" --arg zigv "$zigv" \
    --arg power "$power" --argjson load "$load" \
    '{id: $id, chip: $chip, model: $model, p_cores: $p, e_cores: $e, ram_bytes: $ram,
      macos: $os, zig: $zigv, power: $power, load_avg_1m: $load}'
}

machine="${BENCH_MACHINE:-$(probe)}"
[ "$(jq -r .power <<<"$machine")" = ac ] || echo "warning: on battery power; timings may be throttled" >&2
if jq -e '.load_avg_1m > 2' <<<"$machine" >/dev/null; then
  echo "warning: load average $(jq .load_avg_1m <<<"$machine"); close other programs for stable numbers" >&2
fi
printf '%s\n' "$machine"
