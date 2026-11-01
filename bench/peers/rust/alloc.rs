fn main() {
    let mut keep: Vec<Vec<i64>> = Vec::new();
    let mut total: i64 = 0;
    for i in 0..1000000 {
        let v = vec![i, i + 1, i + 2];
        total += v[1];
        if i % 20 == 0 {
            keep.push(v);
        }
    }
    println!("{}", total + keep.len() as i64);
}
