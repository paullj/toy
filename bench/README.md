# Benchmarks

Benchmarks run locally on the reference Mac (Apple M2 Pro, 32 GB), never in CI. CI only
checks that each runtime benchmark still prints its checksum (the corpus runs
`bench/runtime/` like any other `# expect:` fixture).

## Run

```sh
mise run bench                    # every benchmark, 5 timed runs each
mise run bench alloc              # only names matching the regex "alloc"
mise run bench --runs 10 'loops|closures'
```

`mise` provides the pinned `hyperfine` and `jq` (see `mise.toml`). The task builds a
ReleaseFast toy into `zig-out/bench/` (the Debug `zig-out/bin/toy` stays as it is), then
for each benchmark:

- wall time: `hyperfine`, one warmup run then N timed runs (N >= 2); the report shows the median,
  the standard deviation and the min..max range;
- instructions retired, cycles and peak memory: one `/usr/bin/time -l` run;
- checksum: the runtime program's stdout must equal its `# expect: stdout` line, or the
  run fails.

The table is printed at the end, and the full record goes to `zig-out/bench/results.json`
(commit, dirty flag, date, and per benchmark the wall-time summary in seconds,
`instructions`, `cycles`, `max_rss_bytes`, `peak_footprint_bytes` and the checksum).

A full run takes under a minute today. Close other heavy programs first; the numbers
are only comparable between runs on the same machine.

## Layout

| Path | What |
|---|---|
| `benchmarks.json` | the manifest: one entry per benchmark |
| `run.sh` | the runner `mise run bench` calls |
| `runtime/` | runtime benchmarks: toy programs with a fixed input that print a checksum |
| `compiler/gen.sh` | generates a multi-module project of a given size |
| `compiler/medium/` | a checked-in `gen.sh` project (100 modules); a corpus fixture |
| `opt-check.sh` | the CI gate: -O0 against -O1 over the corpus, and each opt pass's win |
| `profile.sh` | per-stage compile-time profile and a `-j` sweep of one entry file |

## Add a benchmark

A runtime benchmark:

1. Write `runtime/<name>.toy`. It takes no input, runs about 0.5 to 1 s at `--release`,
   and prints one checksum line that depends on all the work, so no pass can delete it.
   Give it a `# expect: stdout "<checksum>\n"` line so the corpus checks it in CI.
2. Add `{ "name": "<name>", "kind": "runtime", "source": "runtime/<name>.toy" }` to
   `benchmarks.json`. The runner reads the checksum from the `# expect:` line too.
3. Bump the `bench/runtime` count in `packages/compiler/tests/corpus_manifest.zon`.

A compiler benchmark runs `toy <args>` in a project that `compiler/gen.sh` generates
from `project` (`[modules, fns_per_module]`), with the project's `.toy/` cache removed
before every run (cold cache):

```json
{ "name": "check_cold_200x50", "kind": "compiler", "project": [200, 50], "args": ["check", "main.toy"] }
```

## History

`bench/history.jsonl` and the `/benchmarks` site page come next (#312).
