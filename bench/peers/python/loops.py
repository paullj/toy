def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def collatz_steps(start):
    n = start
    steps = 0
    while n != 1:
        n = n // 2 if n % 2 == 0 else 3 * n + 1
        steps += 1
    return steps


def main():
    total = fib(32)
    for i in range(1, 500000):
        total += collatz_steps(i)
    print(total)


main()
