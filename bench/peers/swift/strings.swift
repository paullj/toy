func main() {
    let words = (0..<2000).map { "w" + String($0 % 97) }
    let text = words.joined(separator: " ")
    var counts: [String: Int] = [:]
    var total = 0
    for _ in 0..<200 {
        for w in text.split(separator: " ") {
            counts[String(w), default: 0] += 1
        }
        for c in text where c == "w" { total += 1 }
    }
    for (k, v) in counts { total += k.utf8.count * v }
    print(total)
}

main()
