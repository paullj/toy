struct Scale {
    k: i64,
}

impl Scale {
    fn apply(&self, x: i64) -> i64 {
        x * self.k
    }
}

fn make_adder(n: i64) -> impl Fn(i64) -> i64 {
    move |x| x + n
}

fn main() {
    let xs: Vec<i64> = (0..1000).collect();
    let scale = Scale { k: 3 };
    let mut total = 0;
    for round in 0..3000 {
        let add = make_adder(round);
        // Each stage collects, as toy's Vec.map and Vec.filter build a new Vec.
        let added: Vec<i64> = xs.iter().map(|&x| add(x)).collect();
        let scaled: Vec<i64> = added.iter().map(|&x| scale.apply(x)).collect();
        let evens: Vec<i64> = scaled.into_iter().filter(|x| x % 2 == 0).collect();
        let sum = evens.iter().fold(0, |a, x| a + x);
        total += sum;
    }
    println!("{total}");
}
