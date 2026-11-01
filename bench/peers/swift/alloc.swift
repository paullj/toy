func main() {
    var keep: [[Int]] = []
    var total = 0
    for i in 0..<1000000 {
        let v = [i, i + 1, i + 2]
        total += v[1]
        if i % 20 == 0 { keep.append(v) }
    }
    print(total + keep.count)
}

main()
