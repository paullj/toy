func fib(_ n: Int) -> Int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}

func collatzSteps(_ start: Int) -> Int {
    var n = start
    var steps = 0
    while n != 1 {
        n = n % 2 == 0 ? n / 2 : 3 * n + 1
        steps += 1
    }
    return steps
}

func main() {
    var total = fib(32)
    for i in 1..<500000 { total += collatzSteps(i) }
    print(total)
}

main()
