// The C library the FFI fixtures link. build.zig builds it as libtoyffi.dylib into
// zig-out/test-lib, with the @rpath install name a Zig-built dylib gets.
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

long toyffi_add(long a, long b) { return a + b; }

int32_t toyffi_neg32(int32_t x) { return -x; }

double toyffi_scale(double x, double k) { return x * k; }

double toyffi_mix(long n, double x) { return (double)n + x; }

struct toyffi_counter {
    long n;
};

void *toyffi_counter_new(long start) {
    struct toyffi_counter *c = malloc(sizeof *c);
    c->n = start;
    return c;
}

long toyffi_counter_bump(void *p) { return ++((struct toyffi_counter *)p)->n; }

void toyffi_counter_free(void *p) { free(p); }

int8_t toyffi_neg8(int8_t x) { return -x; }

uint8_t toyffi_inc8(uint8_t x) { return x + 1; }

int16_t toyffi_sum16(int8_t a, int16_t b, int32_t c) { return a + b + c; }

uint32_t toyffi_max32(void) { return 0xFFFFFFFFu; }

bool toyffi_isneg(long x) { return x < 0; }

// Past x7 Apple's arm64 ABI packs each argument at its own size and alignment.
long toyffi_stack(int8_t a, long b, long c, long d, long e, long f, long g, long h, int8_t i,
                  int16_t j, int8_t k, int32_t l, bool m, uint8_t n) {
    return a + b + c + d + e + f + g + h + i * 10 + j * 100 + k * 1000 + l * 10000 + m * 100000 +
           n * 1000000;
}

const char *toyffi_greeting(void) { return "hello from C"; }

const char *toyffi_nothing(void) { return NULL; }

// Returns its argument, so a toy string can make a round trip through C.
const char *toyffi_echo(const char *s) { return s; }

// The caller owns the result and frees it with free().
char *toyffi_shout(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    char *out = malloc(n + 2);
    for (size_t i = 0; i < n; i++) out[i] = (s[i] >= 'a' && s[i] <= 'z') ? s[i] - 32 : s[i];
    out[n] = '!';
    out[n + 1] = 0;
    return out;
}

// float32 rides the s registers; past v7 Apple packs each at 4 bytes.
float toyffi_scalef(float x, float k) { return x * k; }

double toyffi_widenf(float x) { return x; }

float toyffi_sumf10(float a, float b, float c, float d, float e, float f, float g, float h,
                    float i, float j) {
    return a + b + c + d + e + f + g + h + i * 10 + j * 100;
}

// C layouts: small (8 bytes, padded), pair (16 bytes), big (> 16, by hidden pointer),
// HFAs of floats and doubles (v registers), mixed (x registers), nested.
struct toyffi_small {
    int32_t a;
    int8_t b;
    int16_t c;
};

struct toyffi_pair {
    long x;
    int32_t y;
    bool z;
};

struct toyffi_big {
    long a, b, c;
    int8_t d;
};

struct toyffi_vec2f {
    float x, y;
};

struct toyffi_vec4d {
    double x, y, z, w;
};

struct toyffi_mixed {
    uint8_t r, g, b;
    float alpha;
};

struct toyffi_rect {
    struct toyffi_vec2f min, max;
};

struct toyffi_named {
    const char *name;
    void *data;
    uint16_t n;
};

struct toyffi_small toyffi_small_make(int32_t a, int8_t b, int16_t c) {
    struct toyffi_small s = {a, b, c};
    return s;
}

long toyffi_small_sum(struct toyffi_small s) { return s.a + s.b * 1000 + s.c * 100000L; }

struct toyffi_pair toyffi_pair_flip(struct toyffi_pair p) {
    struct toyffi_pair r = {p.y, (int32_t)p.x, !p.z};
    return r;
}

struct toyffi_big toyffi_big_make(long a) {
    struct toyffi_big b = {a, a * 2, a * 3, (int8_t)-a};
    return b;
}

// Writes its copy, which must not reach the caller's value.
long toyffi_big_sum(struct toyffi_big b) {
    long s = b.a + b.b + b.c + b.d;
    b.a = 0;
    return s;
}

struct toyffi_vec2f toyffi_vec2f_add(struct toyffi_vec2f a, struct toyffi_vec2f b) {
    struct toyffi_vec2f r = {a.x + b.x, a.y + b.y};
    return r;
}

struct toyffi_vec4d toyffi_vec4d_scale(struct toyffi_vec4d v, double k) {
    struct toyffi_vec4d r = {v.x * k, v.y * k, v.z * k, v.w * k};
    return r;
}

double toyffi_vec4d_dot(struct toyffi_vec4d a, struct toyffi_vec4d b) {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

struct toyffi_mixed toyffi_mixed_dim(struct toyffi_mixed m, float k) {
    struct toyffi_mixed r = {(uint8_t)(m.r / 2), (uint8_t)(m.g / 2), (uint8_t)(m.b / 2), m.alpha * k};
    return r;
}

float toyffi_rect_area(struct toyffi_rect r) { return (r.max.x - r.min.x) * (r.max.y - r.min.y); }

struct toyffi_rect toyffi_rect_grow(struct toyffi_rect r, float d) {
    struct toyffi_rect o = {{r.min.x - d, r.min.y - d}, {r.max.x + d, r.max.y + d}};
    return o;
}

struct toyffi_named toyffi_named_echo(struct toyffi_named n) {
    n.n += 1;
    return n;
}

// Through a pointer: the callee reads and writes the caller's struct.
void toyffi_small_fill(struct toyffi_small *s, int32_t a) {
    s->a += a;
    s->b = -1;
    s->c = 300;
}

double toyffi_vec4d_norm1(const struct toyffi_vec4d *v) { return v->x + v->y + v->z + v->w; }

// Seven ints leave one GPR, so the pair goes to the stack whole; two vec4d fill v0-v7,
// so the vec2f goes to the stack too.
double toyffi_spill(long a, long b, long c, long d, long e, long f, long g, struct toyffi_pair p,
                    struct toyffi_vec4d v, struct toyffi_vec4d w, struct toyffi_vec2f q) {
    return (double)(a + b + c + d + e + f + g) + (double)(p.x + p.y + p.z) + v.x + w.w +
           (double)(q.x * q.y);
}

// Callbacks: C calls a toy function through a plain function pointer.
long toyffi_each(long n, long (*cb)(long)) {
    long s = 0;
    for (long i = 0; i < n; i++) s += cb(i);
    return s;
}

// Narrow ints, a bool and a float32 arrive as C passes them: only the low bits are defined.
long toyffi_cb_narrow(int32_t (*cb)(int8_t, uint16_t, int32_t, bool, float)) {
    return cb(-3, 65535, -100000, true, 1.5f);
}

// Nine longs and an int8 leave the last two on the stack, packed as C packs them; nine
// floats leave the last on the stack at 4 bytes.
long toyffi_cb_stack(long (*cb)(long, long, long, long, long, long, long, long, long, int8_t)) {
    return cb(1, 2, 3, 4, 5, 6, 7, 8, 9, -10);
}

double toyffi_cb_floats(float (*cb)(float, float, float, float, float, float, float, float, float)) {
    return cb(1, 2, 3, 4, 5, 6, 7, 8, 9);
}

// Extern structs by value, both ways: in x registers, an HFA in v registers, and a big one
// through a pointer (x8 for the result).
long toyffi_cb_small(struct toyffi_small (*cb)(struct toyffi_small, int32_t)) {
    struct toyffi_small s = {7, -2, 300};
    struct toyffi_small r = cb(s, 10);
    return r.a + r.b * 1000 + r.c * 100000L;
}

double toyffi_cb_vec4d(struct toyffi_vec4d (*cb)(struct toyffi_vec4d, double)) {
    struct toyffi_vec4d v = {1, 2, 3, 4};
    struct toyffi_vec4d r = cb(v, 0.5);
    return r.x + r.y * 10 + r.z * 100 + r.w * 1000;
}

long toyffi_cb_big(struct toyffi_big (*cb)(struct toyffi_big)) {
    struct toyffi_big b = {1, 2, 3, -4};
    struct toyffi_big r = cb(b);
    return r.a + r.b * 10 + r.c * 100 + r.d * 1000;
}

const char *toyffi_cb_str(const char *(*cb)(const char *)) { return cb("from C"); }

double toyffi_cb_vec2f(struct toyffi_vec2f (*cb)(struct toyffi_vec2f, struct toyffi_vec2f)) {
    struct toyffi_vec2f a = {1.5f, 2.5f}, b = {2.5f, 4.0f};
    struct toyffi_vec2f r = cb(a, b);
    return r.x + r.y * 100;
}

// As toyffi_spill: the pair and the vec2f reach the callback on the stack.
double toyffi_cb_spill(double (*cb)(long, long, long, long, long, long, long, struct toyffi_pair,
                                    struct toyffi_vec4d, struct toyffi_vec4d, struct toyffi_vec2f)) {
    struct toyffi_pair p = {10, 20, true};
    struct toyffi_vec4d v = {0.5, 0, 0, 0}, w = {0, 0, 0, 2};
    struct toyffi_vec2f q = {2.0f, 0.5f};
    return cb(1, 2, 3, 4, 5, 6, 7, p, v, w, q);
}

// Variadic drivers: each vararg is a long ('i') or a double ('f') as `kinds` spells it.
double toyffi_va_sum(double scale, const char *kinds, ...) {
    va_list ap;
    va_start(ap, kinds);
    double s = 0;
    for (const char *k = kinds; *k; k++) s += *k == 'f' ? va_arg(ap, double) : (double)va_arg(ap, long);
    va_end(ap);
    return s * scale;
}

// A struct by value among the named params, then `n` longs.
long toyffi_va_pair(struct toyffi_pair p, int32_t n, ...) {
    va_list ap;
    va_start(ap, n);
    long s = p.x + p.y + p.z;
    for (int32_t i = 0; i < n; i++) s += va_arg(ap, long) * (i + 1);
    va_end(ap);
    return s;
}

// The ninth named param goes on the stack at its C size, the varargs after it.
long toyffi_va_spill(long a, long b, long c, long d, long e, long f, long g, long h, int32_t i, ...) {
    va_list ap;
    va_start(ap, i);
    long x = va_arg(ap, long);
    double y = va_arg(ap, double);
    const char *z = va_arg(ap, const char *);
    va_end(ap);
    return a + b + c + d + e + f + g + h + i + x + (long)(y * 10) + z[0];
}

// A callback among the named params, applied to each of the `n` long varargs.
long toyffi_va_map(long (*cb)(long), long n, ...) {
    va_list ap;
    va_start(ap, n);
    long s = 0;
    for (long i = 0; i < n; i++) s += cb(va_arg(ap, long));
    va_end(ap);
    return s;
}
