# Build profiles

A profile picks how `toy` builds a program. There are two: `debug` (the default) and
`release`.

```sh
toy build main.toy                    # debug
toy build main.toy --release          # release
toy run main.toy --profile release    # the same as --release
```

`--release` and `--profile debug|release` work on every command that builds: `toy build`,
`toy run` and a bare `toy <file>`. `toy check` builds nothing, so it does not take them.
`--release` together with `--profile` is an error, even when they agree.

## What each profile sets

| | `debug` | `release` |
|---|---|---|
| IR passes | none (as `-O0`) | all of them (as `-O1`) |
| Default output | `.toy/<stamp>/debug/<name>` | `.toy/<stamp>/release/<name>` |

When a new pass is added, `release` runs it too.

## `-O`, `--opt` and `--no-opt`

These are expert overrides of the profile's passes. They change only which passes run,
never the profile:

- `-O0` runs no pass and `-O1` runs every pass, whatever the profile.
- `--opt PASS` (repeatable) runs only the named passes.
- `--no-opt PASS` (repeatable) turns one pass off, from the passes left by the profile,
  `-O` and `--opt`.

So the order is: the profile, then `-O`, then `--opt`, then `--no-opt`. An explicit
`-O` always wins over the profile: `toy build --release -O0` runs no pass.

## The cache

The profile is part of every codegen cache key. A debug build never reuses code that a
release build compiled, and the other way round, even when `-O` makes their passes the
same. Each profile keeps its own cache entries, so switching back to a profile is
a warm build again.
