fn fib(n: i64) -> i64 {
    if n < 2 {
        return n;
    }
    fib(n - 1) + fib(n - 2)
}

fn collatz_steps(start: i64) -> i64 {
    let mut n = start;
    let mut steps = 0;
    while n != 1 {
        n = if n % 2 == 0 { n / 2 } else { 3 * n + 1 };
        steps += 1;
    }
    steps
}

fn main() {
    let mut total = fib(32);
    for i in 1..500000 {
        total += collatz_steps(i);
    }
    println!("{total}");
}
