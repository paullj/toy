# Benchmarks

Benchmarks run locally on the reference Mac (Apple M2 Pro, 32 GB), never in CI. CI only
checks that each runtime benchmark still prints its checksum (the corpus runs
`bench/runtime/` like any other `# expect:` fixture).

## Run

```sh
mise run bench                    # every benchmark, 5 timed runs each
mise run bench alloc              # only names matching the regex "alloc"
mise run bench --runs 10 'loops|closures'
mise run bench '^(check|build)_'  # only the compiler set
```

`mise` provides the pinned `hyperfine` and `jq` (see `mise.toml`). The task builds a
ReleaseFast toy into `zig-out/bench/` (the Debug `zig-out/bin/toy` stays as it is), then
for each benchmark:

- wall time: `hyperfine`, one warmup run then N timed runs (N >= 2); the report shows the median,
  the standard deviation and the min..max range;
- instructions retired, cycles and peak memory: one `/usr/bin/time -l` run;
- checksum: the runtime program's stdout must equal its `# expect: stdout` line, or the
  run fails;
- lines per second, for a compiler benchmark: the lines of the project's own `.toy` files
  (the bundled std is not counted) over the wall-time median.

The table is printed at the end: instructions, cycles, the wall-time median, stddev and
min..max, lines per second, user/sys time and peak memory, with the change of
instructions, wall time and peak memory against the latest `main` record of the same
machine in `bench/history.jsonl` (see History).

A full run takes about 2.5 minutes once the ReleaseFast toy is built (70 s of runtime
benchmarks, 90 s of compiler benchmarks), and 3 to 4 minutes with that build. Close other
heavy programs first; the numbers are only comparable between runs on the same machine.

## Layout

| Path | What |
|---|---|
| `benchmarks.json` | the manifest: one entry per benchmark |
| `run.sh` | the runner `mise run bench` calls |
| `machine.sh` | the machine block of a record; warns on battery power, Low Power Mode or high load |
| `record.sh` | turns one run into history records, appends or writes a temp file, prints the table |
| `record-test.sh` | the append rules, against a scratch git repo |
| `history.jsonl` | the history on `main`; append-only |
| `runtime/` | runtime benchmarks: toy programs with a fixed input that print a checksum |
| `compiler/gen.sh` | generates a multi-module project of a given size |
| `compiler/own.sh` | generates the `own` shape of #41 and #104: N small fns over one generic struct |
| `compiler/feature.sh` | generates a multi-module project that uses the heavy language features |
| `compiler/copy.sh` | copies a real program from the repo into a project dir |
| `compiler/medium/` | a checked-in `gen.sh` project (100 modules); a corpus fixture |
| `compiler/feature/` | a checked-in `feature.sh` project (3 modules x 2 groups); a corpus fixture |
| `fixture-check.sh` | the CI gate: `medium/` and `feature/` still equal a fresh run of their generators, so the corpus tests the generators |
| `opt-check.sh` | the CI gate: -O0 against -O1 over the corpus, and each opt pass's win |
| `profile.sh` | per-stage compile-time profile and a `-j` sweep of one entry file |
| `lib.sh` | helpers `run.sh` and `peers/run.sh` share: checksum, metrics, the ReleaseFast build |
| `peers/` | peer programs, `peers/<lang>/<name>.<ext>`, their runner and toolchain pins |
| `results/peers.json` | the last committed peer run |

## The runtime set

| Group | Benchmarks |
|---|---|
| first set | `loops` (calls and a tight loop), `binary_trees` (a small binary-trees with `Vec` children), `alloc` (the #75 program at 1M iterations), `closures` (closures, a bound method and a map/filter/fold chain together), `strings` (`str` and a `Map` word count together) |
| Benchmarks Game | `binary_trees_spec`, `fannkuch_redux`, `n_body`, `spectral_norm`, `mandelbrot`, `fasta`, `k_nucleotide` |
| micro | `closure_calls`, `bound_method_loop` (the #40 loop), `map_filter`, `str_concat`, `str_split_join`, `vec_push_index`, `map_insert_lookup`, `set_insert_lookup`, `deep_recursion` |

The Benchmarks Game programs follow the published algorithms of the simple, single-threaded
entries, without SIMD, at a smaller input. Each prints one checksum line rather than the
published output: the bench runner and the corpus compare one line. Where a program
departs from the published one, the comment at its top says how and why: `mandelbrot`
and `fasta` hash the bytes they would write, `k_nucleotide` makes its input in-process
and keys its tables by an int that packs the k-mer, since `str` has no slicing (#249).

## The compiler set

Each compiler benchmark is named `<command>_<cache>[_j1]_<project>`: `check` or `build`
(`build -o out.bin`), a cold cache (the project's `.toy/` removed before every run) or a
warm one (hyperfine's warmup run fills it), and `-j1` or the default jobs (one worker per
core).

| Group | Projects | Benchmarks |
|---|---|---|
| generated | `gen.sh` at 20, 200 and 600 modules of 50 fns: `20x50` (about 8k lines), `200x50` (82k), `600x50` (245k) | check and build, cold and warm, `-j1` and default |
| `own` (#104) | `own.sh` at N = 4480, 8960 and 30000 fns: `own4480`, `own8960`, `own30000` | check and build, cold, `-j1` and default |
| feature-heavy | `feature.sh` at 30 modules of 4 groups: `feature30x4` (11k lines) | check and build, cold and warm, `-j1` and default |
| real programs | `copy.sh` of the largest corpus programs (`aggregate_values`, `gc_layouts`, `escape_std_methods`), a multi-module one (`modules_app`) and a Benchmarks Game program (`n_body`) | build, cold and warm, `-j1` and default |

`gen.sh` projects are plain int fns, so they flatter compile speed. Each `feature.sh` group
declares a generic struct used at three type args with a generic method, a protocol with a
plain and a generic conformance and a `has`-bounded fn, a payload enum and a `match`,
Option and Result chains with `?`, closures and fn values, derived `==`, `hash` and
`to_string` through `Set`, `Map` and `str`, and each module uses the types and generics of
the module before it and calls its entry, so a build compiles every module. The project
stays at 120 groups: about 150 groups reach the compiler's limit of 10,000 generic
instances (T0014). The real programs are small, so process start and the std dominate
them; they catch a regression on ordinary code that the generated projects miss.

## Add a benchmark

A runtime benchmark:

1. Write `runtime/<name>.toy`. It takes no input, runs about 0.4 to 0.9 s at `--release`,
   and prints one checksum line that depends on all the work, so no pass can delete it.
   Give it a `# expect: stdout "<checksum>\n"` line so the corpus checks it in CI.
2. Add `{ "name": "<name>", "kind": "runtime", "source": "runtime/<name>.toy" }` to
   `benchmarks.json`. The runner reads the checksum from the `# expect:` line too.
3. Bump the `bench/runtime` count in `packages/compiler/tests/corpus_manifest.zon`.

A compiler benchmark runs `toy <args>` in a project dir. `project` names a generator in
`compiler/` and its arguments; the runner calls `compiler/<generator> <dir> <args...>`, and
benchmarks with the same `project` share one dir. `cache` is `cold` (the default) or
`warm`:

```json
{ "name": "check_cold_200x50", "kind": "compiler", "project": ["gen.sh", "200", "50"], "args": ["check", "main.toy"] }
{ "name": "build_warm_n_body", "kind": "compiler", "project": ["copy.sh", "bench/runtime/n_body.toy"], "args": ["build", "-o", "out.bin", "n_body.toy"], "cache": "warm" }
```

A new name starts a new line in the history, so keep a name's project and command as they
are; change them under a new name.

## Peers

`mise run bench:peers` runs every runtime benchmark as toy and as a peer program in C,
Rust, Go, Swift, JS (Node) and Python, and checks that every program prints the toy
checksum. The peers give a rough sense of scale only: take them with a pinch of salt.

```sh
mise run bench:peers                    # every benchmark and language, 5 timed runs each
mise run bench:peers --runs 10 loops    # FILTER matches "<benchmark>/<lang>"
mise run bench:peers /rust
```

Each peer runs the same algorithm as the toy program: idiomatic, single-threaded, the
standard library only, no explicit SIMD, `unsafe` or arena tricks, written by us. Where a
language has no closures or hash map in its standard library (C), the program writes the
small one it needs. A peer builds the collections toy builds: toy's `Vec.map`,
`Vec.filter` and `str.split` each return a new `Vec`, so a peer collects each stage rather
than fusing a lazy iterator chain that would skip that work.

| Language | Toolchain | Build |
|---|---|---|
| C | Xcode `cc` | `cc -O2` |
| Rust | mise, `peers/mise.toml` | `rustc -C opt-level=3` |
| Go | mise, `peers/mise.toml` | `go build` |
| Swift | Xcode `swiftc` | `swiftc -O` |
| JS | mise (Node), `peers/mise.toml` | `node` |
| Python | mise, `peers/mise.toml` | `python3` |

The peer toolchains are optional: they are pinned in `peers/mise.toml`, not the root
`mise.toml`, so `mise install` at the root does not download them. The task runs
`mise install` in `bench/peers/` first, so the first run installs them.

Each program is timed the same way as `mise run bench` (hyperfine, then one
`/usr/bin/time -l` run). A full run with every checksum right writes
`results/peers.json`: the date, the toy commit (and `toy_dirty`, whether `packages/` or
`build.zig*` had uncommitted changes), the machine block, the number of runs, each
toolchain's version and flags, and one result per benchmark and language (`name`, `lang`,
`source`, the program's path from the repo root, `metrics` as in the history,
`checksum`). A run with a FILTER or a wrong checksum writes a temp file instead. Commit
`results/peers.json` yourself after a run on the reference Mac. CI neither builds nor runs
the peers. The bottom of the site's `/benchmarks` page draws the committed file, one bar
chart per benchmark, and hides that view when the file is absent.

To add a peer, write `peers/<lang>/<name>.<ext>` for a runtime benchmark `<name>`. A
benchmark with no peer in a language, where a peer would mean nothing, is skipped for it.
A benchmark with no peer in any language is skipped whole, and the site lists it by name
under the peer view, with no chart.

## History

`bench/history.jsonl` holds the speed of toy on `main`, one line per commit and benchmark:
`sha`, `subject`, `commit_date`, `run_date`, `name`, `kind`, `runs`, `lines` (a compiler
benchmark's project lines, else null), `metrics`
(`instructions`, `cycles`, `peak_footprint_bytes`, `max_rss_bytes`, `wall_median_s`,
`wall_mean_s`, `wall_stddev_s`, `wall_min_s`, `wall_max_s`, `user_s`, `sys_s`), the checksum,
and `machine` (chip, model, P and E cores, RAM, macOS and zig versions, AC or battery, Low
Power Mode, load average, and `id`, a hash of chip, model and RAM). The site's `/benchmarks`
page draws it.

`mise run bench` appends to it only when all of these hold:

- the branch is `main` (rebase merges change the shas of PR branches);
- the tree is clean, apart from `bench/history.jsonl` itself;
- this machine has not recorded HEAD, and the diff from its last recorded commit changes more
  than `bench/history.jsonl`, so committing the history does not make a new point;
- every benchmark ran (no FILTER) and every checksum matched;
- the Mac is on AC power and not in Low Power Mode, which leave instructions and cycles
  alone but inflate wall time.

Then commit the file yourself; the tool never commits or pushes. Otherwise it appends
nothing, writes the records to a temp file and prints its path. On a branch, the table's
changes against the latest `main` record are the dev loop for performance work. A branch
reads that record from `main`'s committed `bench/history.jsonl`, so it need not be rebased
to see a newer one.

Before the build, it warns when the Mac is on battery, in Low Power Mode or the load
average is above 2; a high load only warns. `bash bench/record-test.sh`
checks the rules on a scratch repo; CI runs it.

