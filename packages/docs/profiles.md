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
| Symbol table | yes | no |
| Line tables (DWARF) | yes | no |
| Default output | `.toy/<stamp>/debug/<name>` | `.toy/<stamp>/release/<name>` |

When a new pass is added, `release` runs it too.

Both profiles share one backend, which keeps values in registers and gives a function's
frame only its locals, its aggregate values and the values it must keep across a call.
So a debug build differs from release only in what the table lists, and its frames are
small enough for deep recursion.

Index bounds, division and remainder by zero, and `expect` are checked in both profiles.

A stack overflow, from deep recursion or a frame bigger than the 8 MiB main stack,
panics with `stack overflow` and a backtrace in both profiles too. The backtrace opens
with the runtime's handler, `core/rt/stack.on_fault`, then the function that overflowed.

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

## Debug info

A debug build carries a symbol table (`LC_SYMTAB`) that names every function at its
address, so `nm`, `lldb` and crash reports show toy names instead of bare addresses:

```sh
$ nm .toy/<stamp>/debug/main
00000001000004bc t _main
0000000100000738 t _main$l0
0000000100000328 t _main.apply
0000000100000810 t _panic
00000001000006f8 t _util.ident$int
0000000100000654 t _util.sq
```

A function is named as the panic backtrace names it: `module.fn`, with `main` bare. A
generic instance adds its type arguments (`util.ident$int`) and a lambda its owner and
index (`main$l0`), and a runtime function its own name (`panic`). Every symbol is local
and carries the leading `_` of a C symbol, which `atos`, crash reports and `lldb` drop, so
they show `util.sq`. To break on a function by name in `lldb`, use its full name with
`-F` (`breakpoint set -F util.sq`): `lldb`'s `-n` and `b util.sq` read the dot as a
module separator and find nothing. A release build has no symbol table.

A debug build also carries DWARF line tables, which map each statement's code to its toy
file and line, so a debugger can stop at a line and a backtrace shows where each frame is:

```sh
$ lldb .toy/<stamp>/debug/main
(lldb) breakpoint set -f util.toy -l 3
(lldb) run
(lldb) bt
```

`atos` and crash reports read them too:

```sh
$ atos -o .toy/<stamp>/debug/main -l 0x100000000 0x100000690 0x1000005c0
util.sq (in main) (util.toy:3)
main (in main) (main.toy:4)
```

The DWARF sits in the executable itself, in a `__DWARF` segment that is never loaded, so
there is no `.dSYM` to make: `lldb` and `atos` find it with the binary, and `dsymutil`
has nothing to gather. A line is the line a statement starts on; an `if` or `else if`
condition and a `match` arm are on their own lines, and a function's return code is on
its closing brace. Each function is described with its name, its declaration's file and
line and its address range; variables and types are not described. A standard library
function names its module under `/<toy>` (`/<toy>/std/io.toy`), a path no real file has,
as it has no file on disk. File names are as the build was given them, and relative ones
resolve against the directory the build ran in. A release build has no DWARF.

## `-O`, `--opt` and `--no-opt`

These are expert overrides of the profile's passes. They change only which passes run,
never the profile:

- `-O0` runs no pass and `-O1` runs every pass, whatever the profile.
- `--opt PASS` (repeatable) runs only the named passes.
- `--no-opt PASS` (repeatable) turns one pass off, from the passes left by the profile,
  `-O` and `--opt`.

So the order is: the profile, then `-O`, then `--opt`, then `--no-opt`. An explicit
`-O` always wins over the profile: `toy build --release -O0` runs no pass.

## Inlining

The `inline` pass copies a small function's body into each place that calls it, so the
call's setup costs nothing and the other passes simplify across it. A function is
inlined when it has no loop, does not call itself, and stays under a small size after its
own small callees are inlined into it, three calls deep at most. It can come from any
module, the standard library included; a function that holds a closure is not inlined.
The code `derive` writes, such as a derived `==` or `hash`, is inlined the same way.

A function that calls itself takes only the inlined bodies that add at most two one-word
slots to its frame. Each extra byte of frame is paid at every level of a recursion, so a
bigger frame would run out of stack sooner than without inlining.

An inlined function has no frame of its own, so a panic inside it shows the caller's
frame, and the function itself drops out of the backtrace:

```toy
fn explode(n: int) -> int { 10 / n }
fn main() -> int { explode(0) }
```

A release build of this panics with `division by zero` and a backtrace that ends at
`main` with no `explode` frame above it. `--no-opt inline` keeps every frame. A debug
build at its default `-O0` runs no pass, so it keeps every frame too.

A caller's cache entry covers the bodies it can inline. In a release build, an edit to a
small function compiles again each function that calls it, up to three calls away; a
debug build at its default `-O0` compiles only the edited function.

## Locals in registers

The `mem2reg` pass keeps a local variable in a register instead of the frame, when nothing
takes a reference to it and its value fits in one: an `int`, `bool`, float or pointer. A
local that a closure captures, or that is passed to a `mut` parameter, stays in the frame.
A statement that only gives such a local a new value then leaves no code of its own, so in
a debug build at `-O1` it has no line in the line table and a breakpoint set on it never
stops. `--no-opt mem2reg` keeps every local in the frame and gives each such statement its
line back.

## The cache

The profile is part of every codegen cache key. A debug build never reuses code that a
release build compiled, and the other way round, even when `-O` makes their passes the
same. Each profile keeps its own cache entries, so switching back to a profile is
a warm build again.

A debug build caches each function's line table with its code, each line counted from the
function's declaration. An edit that moves a function, such as a comment above it, reuses
its code and still writes the new lines; an edit that moves a line inside it lowers that
function again.
