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
| Integer overflow | panics | wraps |
| Default output | `.toy/<stamp>/debug/<name>` | `.toy/<stamp>/release/<name>` |

When a new pass is added, `release` runs it too.

Index bounds, division and remainder by zero, and `expect` are checked in both profiles.

## Integer overflow

In a debug build, integer `+`, `-`, `*`, unary `-` and the compound forms `+=`, `-=` and
`*=` panic when the result does not fit the operand type, for every width and
signedness. The panic names the operator and prints the backtrace, which ends at `main`:

```toy
fn big(n: int) -> int { n * 4611686018427387904 }
```

`big(4)` panics with `integer overflow in '*'` in a debug build and returns `0` in a
release build, which wraps at the operand width as two's complement. Unary `-` on an
unsigned value is `0 - u`, so it panics for any value but 0. Signed `/` and `/=` panic
on the one quotient that does not fit, the type's minimum divided by -1; `%` never
overflows, as `min % -1` is 0.

The wrapping operators `+%`, `-%` and `*%`, and their compound forms `+%=`, `-%=` and
`*%=`, wrap in both profiles. They take integers only and bind like `+`, `-` and `*`.
Use them where wrapping is meant, as in a hash or a random number generator; the
standard library does (`std/rand`), so it behaves the same in both profiles.

```toy
h: uint64 = 14695981039346656037
h = (h ^ b) *% 1099511628211
```

The checks follow the profile, not the passes: `toy build -O1` is still a debug build
and still panics. The passes never fold an overflow into a wrapped value in a debug
build: a constant that overflows, such as `x := 4 * 4611686018427387904`, folds to a
panic at run time. A constant with a known width is checked when it is compiled instead
(`c: int8 = 100 + 100` is T0034); with the wrapping operators it wraps
(`c: int8 = 100 +% 100` is -56). A negated literal is a constant too, so
`-9223372036854775808` never panics.

`try_into` is the checked narrowing conversion in both profiles; `into` only widens.

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
