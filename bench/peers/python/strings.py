def main():
    words = ["w" + str(i % 97) for i in range(2000)]
    text = " ".join(words)
    counts = {}
    total = 0
    for _ in range(200):
        for w in text.split(" "):
            counts[w] = counts.get(w, 0) + 1
        for c in text:
            if c == "w":
                total += 1
    for k, v in counts.items():
        total += len(k) * v
    print(total)


main()
