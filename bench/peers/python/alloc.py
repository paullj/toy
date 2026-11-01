def main():
    keep = []
    total = 0
    for i in range(1000000):
        v = [i, i + 1, i + 2]
        total += v[1]
        if i % 20 == 0:
            keep.append(v)
    print(total + len(keep))


main()
