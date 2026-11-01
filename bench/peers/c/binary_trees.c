#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct Tree {
    struct Tree *left, *right;
} Tree;

static Tree *make(int d) {
    Tree *t = malloc(sizeof *t);
    if (d == 0) {
        t->left = t->right = NULL;
    } else {
        t->left = make(d - 1);
        t->right = make(d - 1);
    }
    return t;
}

static int64_t check(const Tree *t) {
    int64_t n = 1;
    if (t->left) n += check(t->left) + check(t->right);
    return n;
}

static void destroy(Tree *t) {
    if (t->left) {
        destroy(t->left);
        destroy(t->right);
    }
    free(t);
}

static int64_t check_and_free(Tree *t) {
    int64_t n = check(t);
    destroy(t);
    return n;
}

int main(void) {
    int max_depth = 13;
    int64_t total = check_and_free(make(max_depth + 1));
    Tree *long_lived = make(max_depth);
    for (int d = 4; d <= max_depth; d += 2) {
        int64_t iters = (int64_t)1 << (max_depth - d + 4);
        for (int64_t i = 0; i < iters; i++) total += check_and_free(make(d));
    }
    printf("%lld\n", (long long)(total + check_and_free(long_lived)));
    return 0;
}
