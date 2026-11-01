from functools import reduce


class Scale:
    def __init__(self, k):
        self.k = k

    def apply(self, x):
        return x * self.k


def make_adder(n):
    return lambda x: x + n


def main():
    xs = list(range(1000))
    scale = Scale(3)
    total = 0
    for round_ in range(3000):
        add = make_adder(round_)
        # Each stage builds a list, as toy's Vec.map and Vec.filter build a new Vec.
        added = list(map(add, xs))
        scaled = list(map(scale.apply, added))
        evens = list(filter(lambda x: x % 2 == 0, scaled))
        total += reduce(lambda a, x: a + x, evens, 0)
    print(total)


main()
