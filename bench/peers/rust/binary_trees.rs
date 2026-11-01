struct Tree {
    kids: Option<Box<(Tree, Tree)>>,
}

fn make(d: u32) -> Tree {
    if d == 0 {
        return Tree { kids: None };
    }
    Tree {
        kids: Some(Box::new((make(d - 1), make(d - 1)))),
    }
}

fn check(t: &Tree) -> i64 {
    match &t.kids {
        None => 1,
        Some(k) => 1 + check(&k.0) + check(&k.1),
    }
}

fn main() {
    let max_depth = 13;
    let mut total = check(&make(max_depth + 1));
    let long_lived = make(max_depth);
    let mut d = 4;
    while d <= max_depth {
        let iters = 1 << (max_depth - d + 4);
        for _ in 0..iters {
            total += check(&make(d));
        }
        d += 2;
    }
    println!("{}", total + check(&long_lived));
}
