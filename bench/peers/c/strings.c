#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The C standard library has no hash map: a small open-addressing one, keyed by
   owned copies of the words. */
typedef struct {
    char *key;
    size_t len;
    int64_t value;
} Slot;

typedef struct {
    Slot *slots;
    size_t cap, count;
} Map;

typedef struct {
    const char *p;
    size_t n;
} Word;

static uint64_t hash(const char *s, size_t n) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 1099511628211ull;
    return h;
}

static Slot *find(Slot *slots, size_t cap, const char *k, size_t n) {
    size_t i = hash(k, n) & (cap - 1);
    while (slots[i].key && !(slots[i].len == n && memcmp(slots[i].key, k, n) == 0))
        i = (i + 1) & (cap - 1);
    return &slots[i];
}

static void grow(Map *m) {
    size_t cap = m->cap ? m->cap * 2 : 16;
    Slot *slots = calloc(cap, sizeof *slots);
    for (size_t i = 0; i < m->cap; i++)
        if (m->slots[i].key) *find(slots, cap, m->slots[i].key, m->slots[i].len) = m->slots[i];
    free(m->slots);
    m->slots = slots;
    m->cap = cap;
}

static int64_t *entry(Map *m, const char *k, size_t n) {
    if (2 * (m->count + 1) > m->cap) grow(m);
    Slot *s = find(m->slots, m->cap, k, n);
    if (!s->key) {
        s->key = malloc(n);
        memcpy(s->key, k, n);
        s->len = n;
        s->value = 0;
        m->count++;
    }
    return &s->value;
}

int main(void) {
    size_t cap = 16, len = 0;
    char *text = malloc(cap);
    for (int i = 0; i < 2000; i++) {
        char word[16];
        int n = snprintf(word, sizeof word, "%sw%d", i ? " " : "", i % 97);
        while (len + n + 1 > cap) text = realloc(text, cap *= 2);
        memcpy(text + len, word, n + 1);
        len += n;
    }
    Map counts = {0};
    int64_t total = 0;
    for (int round = 0; round < 200; round++) {
        /* A fresh list of words each round, as toy's str.split builds a Vec[str]. */
        size_t wcap = 16, wlen = 0;
        Word *words = malloc(wcap * sizeof *words);
        for (const char *w = text;;) {
            const char *end = strchr(w, ' ');
            if (wlen == wcap) words = realloc(words, (wcap *= 2) * sizeof *words);
            words[wlen++] = (Word){w, end ? (size_t)(end - w) : strlen(w)};
            if (!end) break;
            w = end + 1;
        }
        for (size_t i = 0; i < wlen; i++) *entry(&counts, words[i].p, words[i].n) += 1;
        free(words);
        for (const char *c = text; *c; c++)
            if (*c == 'w') total++;
    }
    for (size_t i = 0; i < counts.cap; i++)
        if (counts.slots[i].key) total += (int64_t)counts.slots[i].len * counts.slots[i].value;
    printf("%lld\n", (long long)total);
    return 0;
}
