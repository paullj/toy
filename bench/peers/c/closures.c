#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* C has no closures: a function pointer plus the environment it captured. */
typedef struct {
    int64_t (*call)(const void *env, int64_t x);
    const void *env;
} Fn;

typedef struct {
    int64_t n;
} Adder;

static int64_t adder_call(const void *env, int64_t x) { return x + ((const Adder *)env)->n; }

typedef struct {
    int64_t k;
} Scale;

static int64_t scale_apply(const void *env, int64_t x) { return x * ((const Scale *)env)->k; }

static int64_t is_even(const void *env, int64_t x) {
    (void)env;
    return x % 2 == 0;
}

static int64_t *map(const int64_t *xs, size_t n, Fn f) {
    int64_t *out = malloc(n * sizeof *out);
    for (size_t i = 0; i < n; i++) out[i] = f.call(f.env, xs[i]);
    return out;
}

static int64_t *filter(const int64_t *xs, size_t n, Fn f, size_t *out_n) {
    int64_t *out = malloc(n * sizeof *out);
    size_t m = 0;
    for (size_t i = 0; i < n; i++)
        if (f.call(f.env, xs[i])) out[m++] = xs[i];
    *out_n = m;
    return out;
}

static int64_t sum(const int64_t *xs, size_t n) {
    int64_t a = 0;
    for (size_t i = 0; i < n; i++) a += xs[i];
    return a;
}

int main(void) {
    enum { N = 1000 };
    int64_t xs[N];
    for (int64_t i = 0; i < N; i++) xs[i] = i;
    Scale scale = {3};
    int64_t total = 0;
    for (int64_t round = 0; round < 3000; round++) {
        Adder adder = {round};
        int64_t *added = map(xs, N, (Fn){adder_call, &adder});
        int64_t *scaled = map(added, N, (Fn){scale_apply, &scale});
        size_t m;
        int64_t *evens = filter(scaled, N, (Fn){is_even, NULL}, &m);
        total += sum(evens, m);
        free(added);
        free(scaled);
        free(evens);
    }
    printf("%lld\n", (long long)total);
    return 0;
}
