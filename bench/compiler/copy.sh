#!/usr/bin/env bash
# Copy a real program from the repo into a fresh project dir, so a benchmark's .toy/
# cache never lands in the source tree.
#   usage: copy.sh <out_dir> <repo_path>
# A file is copied as is; a directory (a multi-module program) is copied whole.
set -eu
out="${1:?out_dir}"; src="${2:?repo_path}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf "$out"; mkdir -p "$out"
if [ -d "$root/$src" ]; then cp -R "$root/$src/." "$out/"; else cp "$root/$src" "$out/"; fi
