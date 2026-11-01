def make(d):
    if d == 0:
        return (None, None)
    return (make(d - 1), make(d - 1))


def check(t):
    left, right = t
    if left is None:
        return 1
    return 1 + check(left) + check(right)


def main():
    max_depth = 13
    total = check(make(max_depth + 1))
    long_lived = make(max_depth)
    for d in range(4, max_depth + 1, 2):
        iters = 1 << (max_depth - d + 4)
        for _ in range(iters):
            total += check(make(d))
    print(total + check(long_lived))


main()
