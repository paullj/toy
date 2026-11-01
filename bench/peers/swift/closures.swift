struct Scale {
    let k: Int
    func apply(_ x: Int) -> Int { x * k }
}

func makeAdder(_ n: Int) -> (Int) -> Int { { x in x + n } }

func main() {
    let xs = Array(0..<1000)
    let scale = Scale(k: 3)
    var total = 0
    for round in 0..<3000 {
        let add = makeAdder(round)
        total += xs
            .map(add)
            .map(scale.apply)
            .filter { $0 % 2 == 0 }
            .reduce(0) { $0 + $1 }
    }
    print(total)
}

main()
