#include <stdint.h>
#include <stdio.h>

static int64_t fib(int64_t n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

static int64_t collatz_steps(int64_t start) {
    int64_t n = start, steps = 0;
    while (n != 1) {
        n = n % 2 == 0 ? n / 2 : 3 * n + 1;
        steps++;
    }
    return steps;
}

int main(void) {
    int64_t total = fib(32);
    for (int64_t i = 1; i < 500000; i++) total += collatz_steps(i);
    printf("%lld\n", (long long)total);
    return 0;
}
