final class Tree {
    let left: Tree?
    let right: Tree?

    init(_ left: Tree?, _ right: Tree?) {
        self.left = left
        self.right = right
    }
}

func make(_ d: Int) -> Tree {
    if d == 0 { return Tree(nil, nil) }
    return Tree(make(d - 1), make(d - 1))
}

func check(_ t: Tree) -> Int {
    guard let l = t.left, let r = t.right else { return 1 }
    return 1 + check(l) + check(r)
}

func main() {
    let maxDepth = 13
    var total = check(make(maxDepth + 1))
    let longLived = make(maxDepth)
    var d = 4
    while d <= maxDepth {
        let iters = 1 << (maxDepth - d + 4)
        for _ in 0..<iters { total += check(make(d)) }
        d += 2
    }
    print(total + check(longLived))
}

main()
