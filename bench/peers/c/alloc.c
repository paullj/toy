#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    size_t keep_len = 0, keep_cap = 0;
    int64_t **keep = NULL;
    int64_t total = 0;
    for (int64_t i = 0; i < 1000000; i++) {
        int64_t *v = malloc(3 * sizeof *v);
        v[0] = i;
        v[1] = i + 1;
        v[2] = i + 2;
        total += v[1];
        if (i % 20 == 0) {
            if (keep_len == keep_cap) {
                keep_cap = keep_cap ? keep_cap * 2 : 8;
                keep = realloc(keep, keep_cap * sizeof *keep);
            }
            keep[keep_len++] = v;
        } else {
            free(v);
        }
    }
    printf("%lld\n", (long long)(total + (int64_t)keep_len));
    for (size_t i = 0; i < keep_len; i++) free(keep[i]);
    free(keep);
    return 0;
}
