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

The table is printed at the end: instructions, cycles, the wall-time median, stddev and
min..max, user/sys time and peak memory, with the change of instructions, wall time and
peak memory against the latest `main` record of the same machine in `bench/history.jsonl`
(see History).

A full run takes under a minute today. Close other heavy programs first; the numbers
are only comparable between runs on the same machine.

## Layout

| Path | What |
|---|---|
| `benchmarks.json` | the manifest: one entry per benchmark |
| `run.sh` | the runner `mise run bench` calls |
| `machine.sh` | the machine block of a record; warns on battery power or high load |
| `record.sh` | turns one run into history records, appends or writes a temp file, prints the table |
| `record-test.sh` | the append rules, against a scratch git repo |
| `history.jsonl` | the history on `main`; append-only |
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

`bench/history.jsonl` holds the speed of toy on `main`, one line per commit and benchmark:
`sha`, `subject`, `commit_date`, `run_date`, `name`, `kind`, `runs`, `metrics`
(`instructions`, `cycles`, `peak_footprint_bytes`, `max_rss_bytes`, `wall_median_s`,
`wall_mean_s`, `wall_stddev_s`, `wall_min_s`, `wall_max_s`, `user_s`, `sys_s`), the checksum,
and `machine` (chip, model, P and E cores, RAM, macOS and zig versions, AC or battery, load
average, and `id`, a hash of chip, model and RAM). The site's `/benchmarks` page draws it.

`mise run bench` appends to it only when all of these hold:

- the branch is `main` (rebase merges change the shas of PR branches);
- the tree is clean, apart from `bench/history.jsonl` itself;
- this machine has not recorded HEAD, and the diff from its last recorded commit changes more
  than `bench/history.jsonl`, so committing the history does not make a new point;
- every benchmark ran (no FILTER) and every checksum matched.

Then commit the file yourself; the tool never commits or pushes. Otherwise it appends
nothing, writes the records to a temp file and prints its path. On a branch, the table's
changes against the latest `main` record are the dev loop for performance work. A branch
reads that record from `main`'s committed `bench/history.jsonl`, so it need not be rebased
to see a newer one.

Before the build, it warns when the Mac is on battery or the load average is above 2. `bash bench/record-test.sh`
checks the rules on a scratch repo; CI runs it.

