use std::collections::HashMap;

fn main() {
    let words: Vec<String> = (0..2000).map(|i| format!("w{}", i % 97)).collect();
    let text = words.join(" ");
    let mut counts: HashMap<String, i64> = HashMap::new();
    let mut total: i64 = 0;
    for _ in 0..200 {
        // Collected, as toy's str.split builds a Vec[str].
        let split: Vec<&str> = text.split(' ').collect();
        for w in split {
            match counts.get_mut(w) {
                Some(c) => *c += 1,
                None => {
                    counts.insert(w.to_string(), 1);
                }
            }
        }
        for c in text.chars() {
            if c == 'w' {
                total += 1;
            }
        }
    }
    for (k, v) in &counts {
        total += k.len() as i64 * v;
    }
    println!("{total}");
}
