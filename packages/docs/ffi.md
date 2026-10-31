# Calling C (FFI)

A program calls a C function by declaring it as an `extern` and calling it inside
`unsafe { }`. Run examples: `tests/corpora/language-features/ffi/` (`cstr.toy` and `cstr_libc.toy`
for C strings, `f32.toy`, `structs.toy`, `struct_ptr.toy` and `struct_libc.toy` for `f32`
and C structs) and
`tests/corpora/language-features/modules/ffi_extern/` and `ffi_dylib/`.

```toy
extern fn putchar(c: int32) -> int32

extern {
    fn labs(x: int) -> int
    fn toupper(c: int32) -> int32
}

fn main() -> int {
    unsafe { putchar(toupper(104)) }
    unsafe { putchar(10) }
    return unsafe { labs(-7) }
}
```

## Declaring externs

- A bare `extern fn name(params) -> R` declares one C function. It has no body and no
  type parameters, and its name is the C symbol, never qualified by the module. A `mut`
  param must be an extern struct; it is a C pointer (see [Structs](#structs)).
- An `extern "lib" { .. }` block declares several functions of one library, one per
  line, and links that library (see [Libraries](#libraries)). A block without a name,
  `extern { .. }`, and a bare `extern fn` both bind to libSystem, which holds libc and
  libm.
- An extern follows the `pub` rules of any fn: without `pub` it is private to its
  module, and `pub extern fn` or a `pub fn` inside a block exports it to importers,
  qualified (`c.labs`) or selected (`import c.{labs}`). `pub` goes on each function
  of a block, not on the block (P0003).
- The bundled `core/` modules declare the standard library's own externs. A module
  outside `core/` cannot name them (R0005); std wraps them in safe functions.

## Types

An extern's params and return use C ABI types: an integer of any width, `float` (C
`double`), `f32` (C `float`), `bool`, `rawptr` (C `void*`), `cstr` (C `const char*`, see
[C strings](#c-strings)) and an extern struct (see [Structs](#structs)). Omitting
`-> R` is a `void` return, and `-> never` is a C function that does not return (`exit`,
`abort`). Any other type is T0037, reported once at the type; the extern stays
declared, so its calls add no second error.

Calls follow Apple's arm64 C convention: a narrow integer or `bool` returned by C is
widened to its toy width, a `float` or `f32` goes in a V register (`d` or `s`), and
arguments that go on the stack are packed at their own size and alignment, as C
expects.

### f32

`f32` is a single-precision float, a type of its own beside `float`; it works in toy code
as well as at the C boundary.

- A float literal is an `f32` where one is expected (`x: f32 = 0.1`, an `f32` param, or
  beside an `f32` operand: `x *. 2.0`), rounded to the nearest `f32`.
- The dotted operators (`+. -. *. /.`, `<. >. <=. >=.`) and `==`/`!=` take two `f32`s.
  An `f32` and a `float` do not mix (T0044); convert one.
- `x.into()` converts between `f32` and `float`: to `float` exactly, to `f32` rounded
  to nearest (a value past the `f32` range becomes `inf`, as in C). An integer converts
  to `f32` with `into` as it does to `float`, and an `f32` to an `int` with `try_into`.
- With std/float (which std/io brings), an `f32` prints the fewest digits that read back
  as the same `f32`: `0.1`, not `0.10000000149011612`.

## Structs

An `extern struct` is a struct whose fields are C types: integers of any width, `f32`,
`float`, `bool`, `rawptr`, `cstr` and other extern structs. Any other field is T0037. It
cannot be generic (P0003). In toy code it is an ordinary struct: it is built, copied,
compared and printed like any other, and can have methods.

```toy
import std/io

extern struct DivT { quot: int32, rem: int32 }
extern struct Timeval { sec: int, usec: int32 }

extern {
    fn div(num: int32, den: int32) -> DivT
    fn gettimeofday(mut tv: Timeval, tz: int) -> int32
}

fn main() -> int {
    d := unsafe { div(17, 5) }
    io.println(d)                            # DivT{quot: 3, rem: 2}
    tv := Timeval { sec: 0, usec: 0 }
    unsafe { gettimeofday(tv, 0) }           # C writes tv in place
    io.println(tv.sec > 0)
    return 0
}
```

At an extern call it crosses in C layout: each field at its C size and alignment, the
struct padded to its largest alignment, as C lays out the same declaration.

- **By value** it follows Apple's arm64 convention: a struct of one to four fields that
  are all `f32` or all `float` (nested structs counted field by field) goes in V
  registers; any other struct of up to 16 bytes in one or two X registers; a larger one
  as a pointer to a copy the callee may change. A struct result comes back the same way,
  a large one through the buffer the caller points `x8` at. A struct that does not fit in
  the registers left goes on the stack whole.
- **By pointer**, a `mut` param (`fn fill(mut s: S)` is C's `void fill(struct S *s)`):
  the argument must be a variable or another place, as for a toy `mut` param, and C
  reads and writes it in place. The pointer is valid only during the call, so a C
  library must not keep it.

Toy code holds an extern struct in its own layout and copies it to and from C layout
at each call, so the pointer a `mut` param passes is to that copy, written back when the
call returns. A struct holding a `cstr` or a `rawptr` keeps what they point at alive
like any other struct field.

A `str` is not allowed in a program's extern (T0037): it is a pointer and a length
with no NUL at the end, so a C function reading a `const char*` would run past it.
Use `cstr`. Only `core/` uses a `str` there, spread to a C `buf, len` pair for
functions such as `write`.

## C strings

A `cstr` is one pointer to NUL-terminated bytes, passed and returned as a single C
argument. It is a builtin type, like `rawptr`; its conversions come with
`import std/ffi`:

```toy
import std/ffi
import std/io

extern {
    fn strlen(s: cstr) -> int
    fn getenv(name: cstr) -> cstr
    fn free(p: cstr)
}

extern "toyffi" {
    fn toyffi_shout(s: cstr) -> cstr  # returns a malloc'd copy the caller frees
}

fn main() -> int {
    n := unsafe { strlen("hello".to_cstr()) }
    home := unsafe { getenv("HOME".to_cstr()) }
    if !home.is_null() { io.println(home.to_str()) }
    loud := unsafe { toyffi_shout("hi".to_cstr()) }
    io.println(loud.to_str())
    unsafe { free(loud) }
    return n
}
```

- `s.to_cstr()` copies `s` into a new NUL-terminated buffer on the gc heap. The
  collector owns it and keeps it alive while toy code holds the `cstr` (a local, a
  field, a `Vec` element), and frees it after that. A C function may read it during the
  call; if C keeps the pointer after the call returns (a callback context, a cache),
  that is the program's risk: keep the `cstr` alive in toy for as long as C uses it, or
  give C a copy it owns. A NUL inside `s` ends the C string there.
- `c.to_str()` copies the bytes up to the NUL into a new `str`, so the `str` never
  points into C memory. It panics on a null `cstr`.
- `c.is_null()` tells whether C returned `NULL`. A `cstr` is nullable, as the C
  pointer is: check it before `to_str` when the C function may return `NULL`.
- Toy never frees a `cstr` that C returns. When the C API says the caller owns the
  string, copy it with `to_str` and then call the library's free function through an
  extern, as above. A `cstr` from `to_cstr` must not be passed to `free`: the collector
  owns it.
- The collector traces a `cstr` like a `rawptr`: a pointer into its heap (the start of
  a `to_cstr` buffer, or a pointer into it that C returned, such as `strchr`'s) keeps the
  buffer alive, and a pointer into C memory is left alone.

## unsafe

The compiler cannot check what a C function does with its arguments, so every call to
an extern sits lexically inside `unsafe { }`, or it is T0079. The rule covers a bare
call, a qualified call (`c.labs(x)`), a pipe (`x |> labs`) and a call in a lambda
written inside the `unsafe` block. `unsafe { .. }` is an expression with the value of
its last line, so it wraps just the call: `n := unsafe { labs(x) }`. In a condition,
put it in parentheses: `if (unsafe { read(fd, p, 1) }) <= 0 { .. }`.

An extern is a symbol of another library, not toy code, so it cannot be used as a
value (T0049): wrap it in a toy function to pass it around.

A safe API wraps the call once and checks what C cannot:

```toy
extern { fn putchar(c: int32) -> int32 }

pub fn put(c: int32) {
    unsafe { putchar(c) }
}
```

## Libraries

Each library a program names becomes one `LC_LOAD_DYLIB` in the binary, and each C
function binds to the library of its block, so dyld looks it up there (a two-level
namespace). libSystem is always loaded first.

```toy
extern "sqlite3" {
    fn sqlite3_libversion_number() -> int32
}

extern "toyffi" {
    fn toyffi_add(a: int, b: int) -> int
}

fn main() -> int {
    if (unsafe { sqlite3_libversion_number() }) < 3000000 { return 1 }
    unsafe { toyffi_add(40, 2) }
}
```

```
toy build main.toy -L path/to/lib     # finds path/to/lib/libtoyffi.dylib
toy run main.toy -L path/to/lib -l z  # also loads libz
```

**Finding a library.** A name such as `"toyffi"` or `-l toyffi` is looked up as
`libtoyffi.dylib` in each `-L` folder in order, then in `/usr/local/lib` and
`/usr/lib`, then in the dyld shared cache, where macOS keeps its system libraries
(`z`, `sqlite3`, `curl`, ...) with no file on disk. A name that contains a `/` or ends
in `.dylib` is a path, used as given, relative to the working directory. `"c"`, `"m"`,
`"pthread"`, `"dl"` and `"System"` name libSystem itself and add nothing. The same
library named twice, by blocks in several modules or by `-l`, is loaded once. A block
with no functions binds nothing, so it links nothing; use `-l` to load a library
without declaring a function of it.

**`-l` and `-L`.** `build`, `run` and `check` take both, repeatable, attached or not
(`-lz`, `-L lib`). `-l name` loads a library even when no block names it; a function
still binds to a library only through an `extern "name"` block, and a bare `extern fn`
always binds to libSystem. `check` resolves the libraries as `build` does, so it
reports the same errors. A `-L` that is not a folder is a usage error.

**Errors.** Each is reported once, at the block's library string, or for a `-l` as a
usage error (exit 2) naming the flag:

| code | when |
|---|---|
| R0015 | the name is a static archive or object (`.a`, `.o`), or only `lib<name>.a` exists |
| R0016 | no `lib<name>.dylib` in any searched folder; the error lists them |
| R0017 | the file is not an arm64 Mach-O dynamic library |
| R0018 | one C symbol is bound to two different libraries, or a block binds one the toy runtime or std imports from libSystem |

Static linking (`.a`, `.o`) is not supported; build the library with `cc -shared`.

**Where dyld finds it at run time.** The binary records each library by its own
install name (its `LC_ID_DYLIB`), as the system linker does:

- An absolute install name (`/usr/lib/libz.1.dylib`, `/opt/homebrew/opt/x/lib/libx.dylib`)
  is recorded as is; the library must be there when the program runs.
- `@rpath/libx.dylib` (what Zig and CMake write) is recorded as is, plus an
  `LC_RPATH` for the folder the library was found in, so the program runs where it
  was built. To ship it elsewhere, put the library where the rpath points, or run
  with `DYLD_LIBRARY_PATH`.
- `@loader_path/..` and `@executable_path/..` are recorded as is: the library must sit
  at that place relative to the binary.
- A bare install name (`libx.dylib`, what `cc -shared` writes without
  `-install_name`) would make dyld look in the working directory, so the absolute path
  the library was found at is recorded instead.

The libraries are worked out again on every build from the sources and flags; the
linked image is never cached, so a warm build after changing `-l`, `-L` or a block's
library relinks against the new set.

## Not yet

- Static libraries (`.a`, `.o`), and libraries in a project manifest.
- Fixed-size arrays in an extern struct, and a C pointer to a struct that C returns or
  keeps (a `rawptr` toy cannot read).
- C callbacks and varargs (`printf`): #152, #153.
